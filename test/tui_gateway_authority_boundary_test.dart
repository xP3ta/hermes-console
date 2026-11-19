import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/recovery_proof.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';


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

/// Sessionless test-only event used as an in-order delivery barrier.
const _barrierType = 'test.delivery_barrier';

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
    await for (final raw in socket) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      // The client advertises its capabilities right after connect() marks
      // the transport connected, so the frame under test is judged by a
      // connected client rather than racing the readiness handshake.
      if (frame['method'] != 'client.capabilities') continue;
      socket.add(rawFrame);
      // Frames are handled one at a time in arrival order: once this barrier
      // is delivered, the client has already accepted or rejected rawFrame.
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': _barrierType,
            'payload': const {'barrier': 0},
          },
        }),
      );
    }
  });
  final client = _client(server);
  final events = <TuiGatewayEvent>[];
  final errors = <Object>[];
  final judged = Completer<void>();
  final subscription = client.events.listen(
    (event) {
      if (event.type == _barrierType && event.sessionId.isEmpty) {
        if (!judged.isCompleted) judged.complete();
        return;
      }
      events.add(event);
    },
    onError: (Object error) {
      errors.add(error);
      if (!judged.isCompleted) judged.complete();
    },
  );
  try {
    await client.connect();
    await judged.future;
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
    // C3 re-anchor (revisión 2026-11-16): the original seeded the quarantine
    // with a `truncated` replay, which hunk 4 no longer quarantines (Desktop
    // skips the window, json-rpc-gateway.ts:620-631). The quarantine that
    // still exists on the reconnect replay is another epoch; the property is
    // unchanged: only an exact typed recovery proof releases it.
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
                  'epoch': 'epoch-b',
                  'truncated': false,
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
}
