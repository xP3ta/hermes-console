import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/recovery_proof.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/rpc_frame_helpers.dart';

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 'audit');
}

TuiGatewayClient _client(
  HttpServer server, {
  Duration heartbeatInterval = const Duration(hours: 1),
  Duration heartbeatDeadline = const Duration(hours: 2),
  Duration? fanoutInactivityDeadline,
  DateTime Function()? now,
}) => TuiGatewayClient(
  SavedConnection(
    id: 'authority-boundary',
    label: 'Authority boundary',
    host: '127.0.0.1',
    port: 8642,
    apiKey: String.fromCharCodes(const [113, 97]),
    dashboardUrl: 'http://127.0.0.1:${server.port}',
  ),
  dashboard: _TicketDashboardClient(),
  heartbeatInterval: heartbeatInterval,
  heartbeatDeadline: heartbeatDeadline,
  fanoutInactivityDeadline: fanoutInactivityDeadline,
  now: now,
);

String _ready({String epoch = 'epoch-a', bool heartbeat = false}) =>
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {
        'type': 'gateway.ready',
        'payload': {'replay_epoch': epoch, 'heartbeat': heartbeat},
      },
    });

String _event({
  String type = 'message.delta',
  Object? sessionId = 'runtime-a',
  Object? sequence = 1,
  Object? payload = const {'text': 'visible'},
  bool includeSession = true,
  bool includeSequence = true,
  bool includePayload = true,
}) => jsonEncode({
  'jsonrpc': '2.0',
  'method': 'event',
  'params': {
    'type': type,
    if (includeSession) 'session_id': sessionId,
    if (includeSequence) 'seq': sequence,
    if (includePayload) 'payload': payload,
  },
});

final class _WatchdogFixture {
  final HttpServer server;
  final List<WebSocket> sockets = <WebSocket>[];
  final List<String> probes = <String>[];
  final Map<String, Map<String, dynamic>> snapshots =
      <String, Map<String, dynamic>>{};
  final Set<String> gapRuntimes = <String>{};
  final List<({WebSocket socket, Map<String, dynamic> frame})> heldProbes = [];
  DateTime now = DateTime.utc(2026);
  bool holdProbes = false;
  int _eventSequence = 0;
  final Completer<WebSocket> _connected = Completer<WebSocket>();
  final Completer<void> _probeArrived = Completer<void>();

  _WatchdogFixture._(this.server);

  static Future<_WatchdogFixture> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _WatchdogFixture._(server);
    server.listen(fixture._accept);
    return fixture;
  }

  TuiGatewayClient createClient() => _client(
    server,
    fanoutInactivityDeadline: const Duration(seconds: 10),
    now: () => now,
  );

  Future<void> _accept(HttpRequest request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    sockets.add(socket);
    _connected.complete(socket);
    socket.add(_ready(heartbeat: true));
    await for (final raw in socket) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      final method = frame['method'];
      final params = frame['params'] as Map<String, dynamic>? ?? const {};
      if (method == 'gateway.ping') {
        _reply(socket, frame, const {'ok': true});
      } else if (method == 'gateway.capabilities') {
        _reply(socket, frame, const {'per_session_exclusive_submit': true});
      } else if (method == 'session.resume') {
        final stored = params['session_id'] as String;
        _reply(socket, frame, snapshots[stored] ?? _snapshot(stored, false));
      } else if (method == 'session.create') {
        _reply(socket, frame, const {
          'session_id': 'runtime-created',
          'stored_session_id': 'stored-created',
          'created': true,
          'running': true,
          'status': 'running',
        });
      } else if (method == 'session.activate') {
        final runtime = params['session_id'] as String;
        _reply(
          socket,
          frame,
          snapshots[runtime] ??
              {
                'session_id': runtime,
                'stored_session_id': 'stored-$runtime',
                'created': false,
                'running': true,
                'status': 'running',
              },
        );
      } else if (method == 'session.close') {
        _reply(socket, frame, const {'closed': true});
      } else if (method == 'prompt.submit') {
        final clientTurnId = params['client_turn_id'];
        _reply(
          socket,
          frame,
          clientTurnId is String
              ? {
                  'accepted': true,
                  'client_turn_id': clientTurnId,
                  'server_turn_id': 'server-$clientTurnId',
                  'state': 'running',
                  'duplicate': false,
                }
              : const {'accepted': true},
        );
      } else if (method == 'session.events.since') {
        final runtime = params['session_id'] as String;
        probes.add(runtime);
        if (!_probeArrived.isCompleted) _probeArrived.complete();
        if (holdProbes) {
          heldProbes.add((socket: socket, frame: frame));
        } else {
          replyProbe(socket, frame);
        }
      }
    }
  }

  Map<String, dynamic> _snapshot(String stored, bool running) => {
    'session_id': 'runtime-$stored',
    'stored_session_id': stored,
    'created': false,
    'running': running,
    'status': running ? 'running' : 'idle',
  };

  void setSnapshot(String requestId, String runtime, {required bool running}) {
    snapshots[requestId] = {
      'session_id': runtime,
      'stored_session_id': requestId.startsWith('runtime-')
          ? 'stored-$requestId'
          : requestId,
      'created': false,
      'running': running,
      'status': running ? 'running' : 'idle',
    };
  }

  void _reply(
    WebSocket socket,
    Map<String, dynamic> frame,
    Map<String, dynamic> result,
  ) {
    socket.add(
      jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
    );
  }

  void replyProbe(WebSocket socket, Map<String, dynamic> frame) {
    final params = frame['params'] as Map<String, dynamic>;
    final runtime = params['session_id'] as String;
    final lastSeen = params['last_seen'] as int;
    final gap = gapRuntimes.contains(runtime);
    _reply(socket, frame, {
      'epoch': 'epoch-a',
      'truncated': false,
      'latest_seq': gap ? lastSeen + 1 : lastSeen,
      'events': gap
          ? [
              {
                'type': 'message.delta',
                'session_id': runtime,
                'seq': lastSeen + 1,
                'payload': const {'text': 'held until snapshot'},
              },
            ]
          : const <Object>[],
    });
  }

  Future<void> waitForProbe() => _probeArrived.future;

  Future<WebSocket> get connected => _connected.future;

  void advance(Duration duration) => now = now.add(duration);

  Future<void> emit(
    String runtime,
    String type,
    Map<String, dynamic> payload,
  ) async {
    final delivered = Completer<void>();
    final socket = await connected;
    _eventSequence += 1;
    socket.add(
      _event(
        type: type,
        sessionId: runtime,
        sequence: _eventSequence,
        payload: payload,
      ),
    );
    scheduleMicrotask(delivered.complete);
    await delivered.future;
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> dispose(TuiGatewayClient client) async {
    await client.close();
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }
}

Future<Object> _rpcFailureForRaw(String rawResponse) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final sockets = <WebSocket>[];
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    sockets.add(socket);
    socket.add(_ready());
    await for (final raw in socket) {
      final requestFrame = jsonDecode(raw as String) as Map<String, dynamic>;
      if (requestFrame['method'] == 'clarify.respond') socket.add(rawResponse);
    }
  });
  final client = _client(server);
  try {
    await client.connect();
    return await client
        .respondToClarify('request-a', 'answer')
        .then<Object>((_) => StateError('unexpected success'))
        .catchError((Object error) => error);
  } finally {
    await client.close();
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }
}

Future<bool> _rpcSurvivesInertRaw(Object rawResponse) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final sockets = <WebSocket>[];
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    sockets.add(socket);
    socket.add(_ready());
    await for (final raw in socket) {
      final requestFrame = jsonDecode(raw as String) as Map<String, dynamic>;
      if (requestFrame['method'] != 'clarify.respond') continue;
      socket.add(rawResponse);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': requestFrame['id'],
          'result': {'status': 'ok'},
        }),
      );
    }
  });
  final client = _client(server);
  try {
    await client.connect();
    final response = await client.respondToClarify('request-a', 'answer');
    return response.status == DesktopPromptResponseStatus.ok &&
        client.isConnected;
  } finally {
    await client.close();
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }
}

Future<List<TuiGatewayEvent>> _eventsForRaw(String rawFrame) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    socket.add(_ready());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    socket.add(rawFrame);
  });
  final client = _client(server);
  final events = <TuiGatewayEvent>[];
  final errors = <Object>[];
  final subscription = client.events.listen(events.add, onError: errors.add);
  try {
    await client.connect();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    if (errors.isNotEmpty) throw errors.single;
    return events;
  } finally {
    await subscription.cancel();
    await client.close();
    await server.close(force: true);
  }
}

Future<List<String>> _replayScenario(Map<String, dynamic> result) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var connection = 0;
  final seeded = Completer<void>();
  final disconnected = Completer<void>();
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    connection += 1;
    socket.add(_ready());
    if (connection == 1) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      socket.add(_event(payload: const {'text': 'seed'}));
      await seeded.future;
      await socket.close();
      return;
    }
    await for (final raw in socket) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      if (frame['method'] == 'session.events.since') {
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
        );
      }
    }
  });
  final client = _client(server);
  final texts = <String>[];
  final subscription = client.events.listen(
    (event) {
      final text = event.payload['text'];
      if (text is String) texts.add(text);
      if (text == 'seed' && !seeded.isCompleted) seeded.complete();
    },
    onError: (Object _) {
      if (!disconnected.isCompleted) disconnected.complete();
    },
  );
  try {
    await client.connect();
    await disconnected.future.timeout(const Duration(seconds: 2));
    await client.connect();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return texts;
  } finally {
    await subscription.cancel();
    await client.close();
    await server.close(force: true);
  }
}

void main() {
  test(
    'slice 1 ignores scalar text without settling the pending RPC',
    () async {
      expect(await _rpcSurvivesInertRaw('7'), isTrue);
    },
  );

  test(
    'slice 2 rejects duplicate top-level id before pending lookup',
    () async {
      final failure = await _rpcFailureForRaw(
        '{"jsonrpc":"2.0","id":1,"id":999,"result":{"status":"ok"}}',
      );
      expect(failure, isA<TuiGatewayRpcError>());
    },
  );

  test('slice 3 rejects duplicate nested error data keys', () async {
    final failure = await _rpcFailureForRaw(
      '{"jsonrpc":"2.0","id":1,"error":{"code":4009,"message":"x","data":{"reason":"a","reason":"b"}}}',
    );
    expect(failure, isA<TuiGatewayRpcError>());
  });

  test(
    'slice 4 preserves transport for a valid unknown notification',
    () async {
      final events = await _eventsForRaw(
        '{"jsonrpc":"2.0","method":"future.notice","params":[]}',
      );
      expect(events.where((event) => event.type == 'future.notice'), isEmpty);
    },
  );

  test('slice 5 rejects an integral double response id', () async {
    final failure = await _rpcFailureForRaw(
      '{"jsonrpc":"2.0","id":1.0,"result":{"status":"ok"}}',
    );
    expect(failure, isA<TuiGatewayRpcError>());
  });

  test(
    'slice 6 connect does not complete at upgrade before gateway.ready',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        await release.future;
        socket.add(_ready());
      });
      final client = _client(server);
      try {
        var completed = false;
        final connecting = client.connect().then((_) => completed = true);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(completed, isFalse);
        release.complete();
        await connecting;
        expect(client.isConnected, isTrue);
      } finally {
        await client.close();
        await server.close(force: true);
      }
    },
  );

  test('slice 7 rejects whitespace-normalized gateway epoch', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(_ready(epoch: ' epoch-a '));
    });
    final client = _client(server);
    try {
      await expectLater(client.connect(), throwsA(isA<Object>()));
      expect(client.isConnected, isFalse);
    } finally {
      await client.close();
      await server.close(force: true);
    }
  });

  test('slice 8 rejects whitespace-wrapped event type', () async {
    await expectLater(
      _eventsForRaw(_event(type: ' message.delta ')),
      throwsA(isA<TuiGatewayRpcError>()),
    );
  });

  test('slice 9 rejects whitespace-wrapped session identity', () async {
    await expectLater(
      _eventsForRaw(_event(sessionId: ' runtime-a ')),
      throwsA(isA<TuiGatewayRpcError>()),
    );
  });

  test('slice 10 accepts a valid sessionless global event', () async {
    final events = await _eventsForRaw(
      _event(
        type: 'future.global',
        includeSession: false,
        includeSequence: false,
      ),
    );
    expect(
      events.any(
        (event) => event.type == 'future.global' && event.sessionId.isEmpty,
      ),
      isTrue,
    );
  });

  test('slice 10b accepts upstream empty-session global event', () async {
    final events = await _eventsForRaw(
      _event(
        type: 'future.global.empty',
        sessionId: '',
        includeSequence: false,
      ),
    );
    expect(
      events.any(
        (event) =>
            event.type == 'future.global.empty' && event.sessionId.isEmpty,
      ),
      isTrue,
    );
  });

  test('slice 10c rejects sequenced empty-session global event', () async {
    await expectLater(
      _eventsForRaw(_event(type: 'future.global.seq', sessionId: '')),
      throwsA(isA<TuiGatewayRpcError>()),
    );
  });

  test('slice 10d rejects null non-string and whitespace session identities '
      'without sequence', () async {
    for (final rawSession in <Object?>[null, 7, ' session-1 ']) {
      final raw = jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {
          'type': 'future.global',
          'payload': const <String, Object?>{},
          'session_id': rawSession,
        },
      });
      await expectLater(
        _eventsForRaw(raw),
        throwsA(isA<TuiGatewayRpcError>()),
        reason: '$rawSession',
      );
    }
  });

  test('slice 11 rejects a sequenced global event', () async {
    await expectLater(
      _eventsForRaw(_event(includeSession: false)),
      throwsA(isA<TuiGatewayRpcError>()),
    );
  });

  test('slice 12 replay rejects missing latest_seq without dispatch', () async {
    final texts = await _replayScenario({
      'epoch': 'epoch-a',
      'truncated': false,
      'events': [
        {
          'type': 'message.delta',
          'session_id': 'runtime-a',
          'seq': 2,
          'payload': {'text': 'unsafe'},
        },
      ],
    });
    expect(texts, ['seed']);
  });

  test(
    'slice 13 replay rejects out-of-order evidence without sorting',
    () async {
      final texts = await _replayScenario({
        'epoch': 'epoch-a',
        'truncated': false,
        'latest_seq': 3,
        'events': [
          {
            'type': 'message.delta',
            'session_id': 'runtime-a',
            'seq': 3,
            'payload': {'text': 'unsafe-3'},
          },
          {
            'type': 'message.delta',
            'session_id': 'runtime-a',
            'seq': 2,
            'payload': {'text': 'unsafe-2'},
          },
        ],
      });
      expect(texts, ['seed']);
    },
  );

  test('slice 14 replay rejects count mismatch atomically', () async {
    final texts = await _replayScenario({
      'epoch': 'epoch-a',
      'truncated': false,
      'latest_seq': 2,
      'count': 0,
      'events': [
        {
          'type': 'message.delta',
          'session_id': 'runtime-a',
          'seq': 2,
          'payload': {'text': 'unsafe'},
        },
      ],
    });
    expect(texts, ['seed']);
  });

  test('slice 15 replay rejects raw-mismatched runtime identity', () async {
    final texts = await _replayScenario({
      'epoch': 'epoch-a',
      'truncated': false,
      'latest_seq': 2,
      'events': [
        {
          'type': 'message.delta',
          'session_id': ' runtime-a ',
          'seq': 2,
          'payload': {'text': 'unsafe'},
        },
      ],
    });
    expect(texts, ['seed']);
  });

  test('slice 16 sensitive remote data is discarded recursively', () async {
    const marker = 'PRIVATE_SECRET_MARKER';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(_ready());
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'error': {
              'code': 4009,
              'message': marker,
              'data': {
                'reason': marker,
                'nested': [marker],
              },
            },
          }),
        );
      }
    });
    final client = _client(server);
    final value = EphemeralSensitiveValue(marker);
    try {
      Object? failure;
      try {
        await client.respondToSecret('secret-a', value);
      } catch (error) {
        failure = error;
      }
      expect(failure, isA<TuiGatewayRpcError>());
      final rpc = failure! as TuiGatewayRpcError;
      expect(rpc.data, isEmpty);
      expect(rpc.reason, isNull);
      expect(rpc.toString(), isNot(contains(marker)));
    } finally {
      await client.close();
      await server.close(force: true);
    }
  });

  test('slice 17 accepts a valid UTF-8 binary WebSocket frame', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(_ready());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      socket.add(utf8.encode('{"jsonrpc":"2.0","method":"future.notice"}'));
    });
    final client = _client(server);
    final errors = <Object>[];
    final subscription = client.events.listen((_) {}, onError: errors.add);
    try {
      await client.connect();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(client.isConnected, isTrue);
      expect(errors, isEmpty);
    } finally {
      await subscription.cancel();
      await client.close();
      await server.close(force: true);
    }
  });

  test(
    'slice 18 only an exact typed recovery proof releases quarantine',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var connection = 0;
      final seeded = Completer<void>();
      final disconnected = Completer<void>();
      WebSocket? recoverySocket;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        connection += 1;
        socket.add(_ready());
        if (connection == 1) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          socket.add(_event(payload: const {'text': 'seed'}));
          await seeded.future;
          await socket.close();
          return;
        }
        recoverySocket = socket;
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (frame['method'] == 'session.events.since') {
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': {
                  'epoch': 'epoch-a',
                  'truncated': true,
                  'latest_seq': 1,
                  'events': const [],
                },
              }),
            );
          }
        }
      });
      final client = _client(server);
      final texts = <String>[];
      final subscription = client.events.listen(
        (event) {
          final text = event.payload['text'];
          if (text is String) texts.add(text);
          if (text == 'seed' && !seeded.isCompleted) seeded.complete();
        },
        onError: (Object _) {
          if (!disconnected.isCompleted) disconnected.complete();
        },
      );
      try {
        await client.connect();
        await disconnected.future.timeout(const Duration(seconds: 2));
        await client.connect();
        client.commitRecoveryRuntime('runtime-a');
        recoverySocket!.add(
          _event(sequence: 2, payload: const {'text': 'unsafe-string'}),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(texts, ['seed']);

        const snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-a',
          storedSessionId: 'stored-a',
          created: false,
          messagesProvided: true,
          messageCount: 0,
          status: 'idle',
          pendingClarifyProvided: true,
        );
        final incomplete = client.recoveryProofForSnapshot(
          snapshot,
          connectionId: 'conn-authority',
          profile: '',
          bindGeneration: 1,
          sessionGeneration: 1,
          turnGeneration: 1,
          coverage: const {RecoveryDomain.transcript},
        );
        expect(client.commitRecovery(incomplete), isFalse);
        final overclaimed = client.recoveryProofForSnapshot(
          snapshot,
          connectionId: 'conn-authority',
          profile: '',
          bindGeneration: 1,
          sessionGeneration: 1,
          turnGeneration: 1,
          coverage: RecoveryDomain.values.toSet(),
          postSnapshotSequence: 2,
        );
        // Neither caller-supplied coverage nor a caller-supplied cursor can
        // upgrade the current upstream snapshot into recovery authority.
        expect(client.commitRecovery(overclaimed), isFalse);
        recoverySocket!.add(
          _event(sequence: 3, payload: const {'text': 'still-held'}),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(texts, ['seed']);
      } finally {
        await subscription.cancel();
        await client.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'healthy ping cannot mask silent fanout gap and requests rehydration',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      var pingCalls = 0;
      var replayCalls = 0;
      var now = DateTime.utc(2026);
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.add(_ready(heartbeat: true));
        socket.add(_event(payload: const {'text': 'seed'}));
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          final method = frame['method'];
          if (isClientCapabilitiesFrame(frame)) {
            socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
          } else if (method == 'gateway.ping') {
            pingCalls += 1;
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': const {'ok': true},
              }),
            );
          } else if (method == 'gateway.capabilities') {
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': const {'per_session_exclusive_submit': true},
              }),
            );
          } else if (method == 'session.resume') {
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': const {
                  'session_id': 'runtime-a',
                  'stored_session_id': 'stored-a',
                  'created': false,
                  'running': true,
                  'status': 'running',
                },
              }),
            );
          } else if (method == 'session.events.since') {
            replayCalls += 1;
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': {
                  'epoch': 'epoch-a',
                  'truncated': false,
                  'latest_seq': 2,
                  'events': [
                    {
                      'type': 'message.delta',
                      'session_id': 'runtime-a',
                      'seq': 2,
                      'payload': {'text': 'must await snapshot proof'},
                    },
                  ],
                },
              }),
            );
          }
        }
      });
      final client = TuiGatewayClient(
        SavedConnection(
          id: 'silent-fanout-watchdog',
          label: 'Silent fanout watchdog',
          host: '127.0.0.1',
          port: 8642,
          apiKey: String.fromCharCodes(const [113, 97]),
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
        // The test drives exactly one heartbeat with `debugHeartbeatTick` on
        // the fake clock. A 20 ms REAL periodic timer also fired whenever
        // connect + resume took longer than 20 ms of wall time, sending extra
        // pings (pingCalls == 2): it failed when run alone and passed in
        // warmed-up full-suite runs. Keep the real timer out of the window;
        // the watchdog deadline stays on the fake clock.
        heartbeatInterval: const Duration(hours: 1),
        heartbeatDeadline: const Duration(milliseconds: 200),
        fanoutInactivityDeadline: const Duration(milliseconds: 20),
        now: () => now,
      );
      final texts = <String>[];
      final errors = <Object>[];
      final recoveryRequested = Completer<void>();
      final subscription = client.events.listen(
        (event) {
          final text = event.payload['text'];
          if (text is String) texts.add(text);
        },
        onError: (Object error) {
          errors.add(error);
          if (!recoveryRequested.isCompleted) recoveryRequested.complete();
        },
      );
      try {
        await client.connect();
        await client.resumeExisting('stored-a');
        now = now.add(const Duration(milliseconds: 20));
        await client.debugHeartbeatTick();
        await recoveryRequested.future;

        expect(pingCalls, 1);
        expect(replayCalls, 1);
        expect(client.isConnected, isTrue);
        expect(texts, ['seed']);
        expect(
          errors.single,
          isA<TuiGatewayRpcError>()
              .having((error) => error.method, 'method', 'session.events.since')
              .having(
                (error) => error.failureKind,
                'failureKind',
                TuiGatewayRpcFailureKind.connectionLost,
              ),
        );
      } finally {
        await subscription.cancel();
        await client.close();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
      }
    },
  );

  test('silent fanout watchdog probes only the resumed busy runtime', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    final connected = Completer<WebSocket>();
    final watchdogRuntime = Completer<String>();
    var now = DateTime.utc(2026);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      if (!connected.isCompleted) connected.complete(socket);
      socket.add(_ready(heartbeat: true));
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        final method = frame['method'];
        if (method == 'gateway.ping') {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': const {'ok': true},
            }),
          );
        } else if (method == 'gateway.capabilities') {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': const {'per_session_exclusive_submit': true},
            }),
          );
        } else if (method == 'session.resume') {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': const {
                'session_id': 'runtime-b',
                'stored_session_id': 'stored-b',
                'created': false,
                'running': true,
                'status': 'running',
              },
            }),
          );
        } else if (method == 'session.events.since') {
          final params = frame['params'] as Map<String, dynamic>;
          final runtime = params['session_id'] as String;
          if (!watchdogRuntime.isCompleted) watchdogRuntime.complete(runtime);
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': {
                'epoch': 'epoch-a',
                'truncated': false,
                'latest_seq': params['last_seen'],
                'events': const <Object>[],
              },
            }),
          );
        }
      }
    });
    final client = _client(
      server,
      fanoutInactivityDeadline: const Duration(seconds: 10),
      now: () => now,
    );
    try {
      await client.connect();
      final socket = await connected.future;
      socket.add(
        _event(sessionId: 'runtime-a', payload: const {'text': 'old'}),
      );
      await Future<void>.delayed(Duration.zero);
      final snapshot = await client.resumeExisting('stored-b');
      expect(snapshot.runtimeSessionId, 'runtime-b');
      now = now.add(const Duration(seconds: 10));
      await client.debugProbeSilentFanout();

      expect(await watchdogRuntime.future, 'runtime-b');
    } finally {
      await client.close();
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
    }
  });

  test('idle snapshot stays dormant until prompt submit succeeds', () async {
    final fixture = await _WatchdogFixture.start();
    fixture.setSnapshot('stored-a', 'runtime-a', running: false);
    final client = fixture.createClient();
    try {
      await client.connect();
      await client.resumeExisting('stored-a');
      fixture.advance(const Duration(seconds: 10));
      await client.debugProbeSilentFanout();
      expect(fixture.probes, isEmpty);

      await client.submitPrompt('runtime-a', 'hello');
      fixture.advance(const Duration(seconds: 10));
      await client.debugProbeSilentFanout();
      expect(fixture.probes, ['runtime-a']);
    } finally {
      await fixture.dispose(client);
    }
  });

  test('busy create snapshot replaces the watchdog runtime', () async {
    final fixture = await _WatchdogFixture.start();
    fixture.setSnapshot('stored-a', 'runtime-a', running: true);
    final client = fixture.createClient();
    try {
      await client.connect();
      await client.resumeExisting('stored-a');
      final binding = await client.createForFirstSubmit();
      expect(binding.runtimeSessionId, 'runtime-created');
      fixture.advance(const Duration(seconds: 10));
      await client.debugProbeSilentFanout();
      expect(fixture.probes, ['runtime-created']);
    } finally {
      await fixture.dispose(client);
    }
  });

  test('valid idempotent submit registers its exact runtime as busy', () async {
    final fixture = await _WatchdogFixture.start();
    fixture.setSnapshot('stored-a', 'runtime-a', running: false);
    final client = fixture.createClient();
    try {
      await client.connect();
      await client.resumeExisting('stored-a');
      final ack = await client.submitPromptIdempotent(
        'runtime-a',
        'hello once',
        'client-turn-a',
      );
      expect(ack.state, DesktopTurnState.running);
      fixture.advance(const Duration(seconds: 10));
      await client.debugProbeSilentFanout();
      expect(fixture.probes, ['runtime-a']);
    } finally {
      await fixture.dispose(client);
    }
  });

  test('old no-gap runtime cannot starve replacement busy gap', () async {
    final fixture = await _WatchdogFixture.start();
    fixture.setSnapshot('stored-a', 'runtime-a', running: true);
    fixture.setSnapshot('stored-b', 'runtime-b', running: true);
    fixture.gapRuntimes.add('runtime-b');
    final client = fixture.createClient();
    final errors = <Object>[];
    final subscription = client.events.listen((_) {}, onError: errors.add);
    try {
      await client.connect();
      await client.resumeExisting('stored-a');
      await fixture.emit('runtime-a', 'message.delta', const {'text': 'seed'});
      fixture.advance(const Duration(seconds: 10));
      await client.debugProbeSilentFanout();
      expect(fixture.probes, ['runtime-a']);
      expect(errors, isEmpty);

      await fixture.emit('runtime-a', 'message.complete', const {
        'text': 'done',
      });
      await client.resumeExisting('stored-b');
      fixture.advance(const Duration(seconds: 10));
      await client.debugProbeSilentFanout();
      await Future<void>.delayed(Duration.zero);
      expect(fixture.probes, ['runtime-a', 'runtime-b']);
      expect(errors, hasLength(1));
    } finally {
      await subscription.cancel();
      await fixture.dispose(client);
    }
  });

  test(
    'runtime replacement retires old and ignores unrelated watermark',
    () async {
      final fixture = await _WatchdogFixture.start();
      fixture.setSnapshot('stored-a', 'runtime-a', running: true);
      fixture.setSnapshot('runtime-b', 'runtime-b', running: true);
      final client = fixture.createClient();
      try {
        await client.connect();
        await client.resumeExisting('stored-a');
        await fixture.emit('runtime-unrelated', 'message.delta', const {
          'text': 'must not become a candidate',
        });
        await client.activateSession(
          'runtime-b',
          storedSessionId: 'stored-runtime-b',
        );
        fixture.advance(const Duration(seconds: 10));
        await client.debugProbeSilentFanout();
        expect(fixture.probes, ['runtime-b']);
      } finally {
        await fixture.dispose(client);
      }
    },
  );

  test('terminal event and successful session close stop probes', () async {
    final fixture = await _WatchdogFixture.start();
    fixture.setSnapshot('stored-a', 'runtime-a', running: true);
    fixture.setSnapshot('stored-b', 'runtime-b', running: true);
    final client = fixture.createClient();
    try {
      await client.connect();
      await client.resumeExisting('stored-a');
      await fixture.emit('runtime-a', 'message.complete', const {
        'text': 'done',
      });
      fixture.advance(const Duration(seconds: 10));
      await client.debugProbeSilentFanout();
      expect(fixture.probes, isEmpty);

      await client.resumeExisting('stored-b');
      expect(await client.closeSession('runtime-b'), isTrue);
      fixture.advance(const Duration(seconds: 10));
      await client.debugProbeSilentFanout();
      expect(fixture.probes, isEmpty);
    } finally {
      await fixture.dispose(client);
    }
  });

  test('no-gap probes are bounded to one per inactivity window', () async {
    final fixture = await _WatchdogFixture.start();
    fixture.setSnapshot('stored-a', 'runtime-a', running: true);
    final client = fixture.createClient();
    try {
      await client.connect();
      await client.resumeExisting('stored-a');
      await fixture.emit('runtime-a', 'message.delta', const {'text': 'seed'});
      fixture.advance(const Duration(seconds: 10));
      await client.debugProbeSilentFanout();
      await client.debugProbeSilentFanout();
      fixture.advance(const Duration(seconds: 9));
      await client.debugProbeSilentFanout();
      expect(fixture.probes, ['runtime-a']);

      fixture.advance(const Duration(seconds: 1));
      await client.debugProbeSilentFanout();
      expect(fixture.probes, ['runtime-a', 'runtime-a']);
    } finally {
      await fixture.dispose(client);
    }
  });

  test(
    'stale runtime probe cannot publish recovery after replacement',
    () async {
      final fixture = await _WatchdogFixture.start();
      fixture.setSnapshot('stored-a', 'runtime-a', running: true);
      fixture.setSnapshot('runtime-b', 'runtime-b', running: true);
      fixture.holdProbes = true;
      fixture.gapRuntimes.addAll(const {'runtime-a', 'runtime-b'});
      final client = fixture.createClient();
      final errors = <Object>[];
      final subscription = client.events.listen((_) {}, onError: errors.add);
      try {
        await client.connect();
        await client.resumeExisting('stored-a');
        fixture.advance(const Duration(seconds: 10));
        final staleProbe = client.debugProbeSilentFanout();
        await fixture.waitForProbe();
        await client.activateSession(
          'runtime-b',
          storedSessionId: 'stored-runtime-b',
        );
        final held = fixture.heldProbes.single;
        fixture.replyProbe(held.socket, held.frame);
        await staleProbe;
        await Future<void>.delayed(Duration.zero);
        expect(errors, isEmpty);

        fixture.holdProbes = false;
        fixture.advance(const Duration(seconds: 10));
        await client.debugProbeSilentFanout();
        await Future<void>.delayed(Duration.zero);
        expect(fixture.probes, ['runtime-a', 'runtime-b']);
        expect(errors, hasLength(1));
      } finally {
        await subscription.cancel();
        await fixture.dispose(client);
      }
    },
  );

  test('transport retirement and client close stop stale recovery', () async {
    final fixture = await _WatchdogFixture.start();
    fixture.setSnapshot('stored-a', 'runtime-a', running: true);
    fixture.holdProbes = true;
    fixture.gapRuntimes.add('runtime-a');
    final client = fixture.createClient();
    final errors = <Object>[];
    final subscription = client.events.listen((_) {}, onError: errors.add);
    try {
      await client.connect();
      await client.resumeExisting('stored-a');
      fixture.advance(const Duration(seconds: 10));
      final staleProbe = client.debugProbeSilentFanout();
      await fixture.waitForProbe();
      await client.disconnectIdle();
      await staleProbe;
      await Future<void>.delayed(Duration.zero);
      expect(errors, isEmpty);
      expect(fixture.probes, ['runtime-a']);

      await client.close();
      fixture.advance(const Duration(seconds: 20));
      await client.debugProbeSilentFanout();
      expect(fixture.probes, ['runtime-a']);
    } finally {
      await subscription.cancel();
      await fixture.dispose(client);
    }
  });
}
