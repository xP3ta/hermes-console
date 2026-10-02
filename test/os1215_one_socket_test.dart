import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';

/// os1215: every open chat of a (connection, profile) rides ONE gateway
/// WebSocket, like Desktop's single JsonRpcGatewayClient. This fake speaks
/// the v7 replay contract (`replay_epoch`, sequenced session events) and
/// maps each stored session `stored-X` to the runtime `runtime-X`.
class _Gateway {
  _Gateway._(this.server) {
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {
              'heartbeat': false,
              'change_events': true,
              if (replayEpoch != null) 'replay_epoch': replayEpoch,
            },
          },
        }),
      );
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        frames.add((socket, frame));
        if (!_frames.isClosed) _frames.add(frame);
        if (socket.closeCode != null) continue;
        final method = frame['method'];
        if (method is! String) continue; // a server-request answer
        final params = (frame['params'] as Map?) ?? const {};
        if (method == 'session.resume') {
          _resumed.add('runtime-${_suffix(params['session_id'])}');
        }
        final result = switch (method) {
          'client.capabilities' => {
            'server_requests': ['approval', 'clarify', 'sudo', 'secret'],
          },
          'gateway.capabilities' => {'per_session_exclusive_submit': true},
          'session.resume' => {
            'session_id': 'runtime-${_suffix(params['session_id'])}',
            'stored_session_id': params['session_id'],
            'running': busy.contains(params['session_id']),
            'status': busy.contains(params['session_id']) ? 'working' : 'idle',
          },
          'session.events.since' => {
            'epoch': replayEpoch,
            'events': <Object>[],
            'latest_seq':
                (params['last_seen'] as int) +
                (silentGap.contains(params['session_id']) ? 1 : 0),
            'truncated': false,
            'count': 0,
          },
          'session.active_list' => {
            'sessions': [
              for (final runtime in _sequences.keys.toSet().union(_resumed))
                {
                  'id': runtime,
                  'session_key': 'stored-${runtime.substring(8)}',
                  'stored_session_id': 'stored-${runtime.substring(8)}',
                  'status': 'idle',
                  'current': false,
                },
            ],
          },
          _ => <String, dynamic>{'status': 'ok'},
        };
        try {
          socket.add(
            jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
          );
        } on StateError {
          // The test closed this socket while the request was in flight.
        }
      }
    });
  }

  static String _suffix(Object? stored) =>
      '$stored'.replaceFirst('stored-', '');

  final HttpServer server;
  final sockets = <WebSocket>[];
  final frames = <(WebSocket, Map<String, dynamic>)>[];
  final _frames = StreamController<Map<String, dynamic>>.broadcast();
  String? replayEpoch = 'epoch-1';
  final _sequences = <String, int>{};
  final _resumed = <String>{};
  final busy = <Object?>{};
  final silentGap = <Object?>{};

  static Future<_Gateway> start() async =>
      _Gateway._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Iterable<Map<String, dynamic>> rpcCalls(String method) =>
      frames.map((entry) => entry.$2).where((f) => f['method'] == method);

  int get liveSockets => sockets.where((s) => s.closeCode == null).length;

  /// A sequenced session event for [runtime] on the newest socket.
  void pushEvent(String runtime, String type, Map<String, dynamic> payload) {
    final seq = (_sequences[runtime] ?? 0) + 1;
    _sequences[runtime] = seq;
    sockets.last.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {
          'type': type,
          'session_id': runtime,
          if (replayEpoch != null) 'seq': seq,
          'payload': payload,
        },
      }),
    );
  }

  void pushClarify(String runtime, String id) => sockets.last.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'clarify',
      'params': {
        'session_id': runtime,
        'question': 'Seguimos?',
        'choices': ['si', 'no'],
      },
    }),
  );

  Future<Map<String, dynamic>> nextFrame(
    bool Function(Map<String, dynamic>) where,
  ) {
    for (final entry in frames) {
      if (where(entry.$2)) return Future.value(entry.$2);
    }
    return _frames.stream.firstWhere(where);
  }

  Future<void> close() async {
    await _frames.close();
    await server.close(force: true);
  }
}

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 'ticket');
}

SavedConnection _connectionFor(_Gateway gateway) => SavedConnection(
  id: 'conn-one-socket',
  label: 'One socket',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'key',
  dashboardUrl: 'http://127.0.0.1:${gateway.server.port}',
);

/// Real time plus a skew the watchdog test advances (backoff keeps ticking).
Duration _skew = Duration.zero;
DateTime _clock() => DateTime.now().add(_skew);

TuiGatewayClient _client(SavedConnection connection) => TuiGatewayClient(
  connection,
  dashboard: _TicketDashboardClient(),
  fanoutInactivityDeadline: const Duration(seconds: 10),
  now: _clock,
);

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: reason);
}

/// The shared chat socket the chats ride, peeked without holding a lease.
TuiGatewayClient _sharedClient(SharedGatewayPool pool, _Gateway gateway) {
  final lease = pool.acquireChat(
    _connectionFor(gateway),
    profile: 'default',
    chatLinger: Duration.zero,
  );
  lease.release();
  return lease.client;
}

void main() {
  late _Gateway gateway;
  late SharedGatewayPool pool;
  late ActiveChatService service;

  ActiveChatService newService({bool shared = true}) {
    final created = ActiveChatService(
      compressionRestoreStore: testCompressionRestoreStore(),
      chatGatewayPool: pool,
      sharedChatGatewayFactory: shared ? _client : null,
      // The pre-os1215 path: one client per chat.
      desktopGatewayFactory: shared ? null : _client,
    );
    addTearDown(created.dispose);
    return created;
  }

  Future<ActiveChat> open(String id, {String profile = 'default'}) async {
    final chat = service.attach(
      connection: _connectionFor(gateway),
      sessionId: 'stored-$id',
      sessionTitle: 'Chat $id',
      sessionProfile: profile,
      api: ApiClient(
        baseUrl: 'http://127.0.0.1:1',
        apiKey: 'key',
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      ),
      storedMessageLoader: (_, _) async => const [],
      attachDesktopRuntimeOnLoad: true,
      allowUnownedDesktopSnapshotForTesting: true,
      disableForegroundKeepAlive: true,
    );
    await chat.loadMessages();
    await _waitUntil(
      () => chat.desktopRuntimeSessionId == 'runtime-$id',
      reason: 'attach $id',
    );
    return chat;
  }

  setUp(() async {
    gateway = await _Gateway.start();
    pool = SharedGatewayPool.forTesting(linger: Duration.zero);
    service = newService();
  });

  tearDown(() async {
    service.dispose();
    await pool.closeAll();
    await gateway.close();
  });

  test(
    'opening five chats costs one socket and one handshake (was five)',
    () async {
      final chats = [for (final id in 'abcde'.split('')) await open(id)];

      expect(gateway.sockets, hasLength(1));
      expect(gateway.rpcCalls('client.capabilities'), hasLength(1));
      expect(gateway.rpcCalls('session.resume'), hasLength(5));
      expect(pool.chatClientCount, 1);
      expect(chats.map((c) => c.desktopRuntimeSessionId).toSet(), {
        for (final id in 'abcde'.split('')) 'runtime-$id',
      });

      // Measured baseline: the per-chat path dials once per chat.
      service.dispose();
      await pool.closeAll();
      final before = gateway.sockets.length;
      service = newService(shared: false);
      for (final id in 'fghij'.split('')) {
        await open(id);
      }
      expect(gateway.sockets.length - before, 5);
    },
  );

  test('a session event and a clarify reach only the chat that owns the '
      'runtime, and the answer leaves from that chat', () async {
    final a = await open('a');
    final b = await open('b');

    gateway.pushClarify('runtime-b', 'srq-onlyb0000001');
    await _waitUntil(() => b.pendingInteractivePrompt != null);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(a.pendingInteractivePrompt, isNull);
    expect(b.pendingInteractivePrompt!.key.runtimeSessionId, 'runtime-b');

    await b.respondToClarify(b.pendingInteractivePrompt!.key, 'si');
    final answer = await gateway
        .nextFrame((frame) => frame['id'] == 'srq-onlyb0000001')
        .timeout(const Duration(seconds: 2));
    expect(answer['result'], {'answer': 'si'});
    expect(gateway.sockets, hasLength(1));
    expect(a.pendingInteractivePrompt, isNull);
  });

  test('one drop is one reconnect: every chat re-attaches on the new socket '
      'and each runtime replays from its own watermark once', () async {
    final chats = [for (final id in 'abc'.split('')) await open(id)];
    final client = _sharedClient(pool, gateway);
    // Watermarks a=3, b=1, c=2.
    for (final (runtime, count) in [
      ('runtime-a', 3),
      ('runtime-b', 1),
      ('runtime-c', 2),
    ]) {
      for (var i = 0; i < count; i++) {
        gateway.pushEvent(runtime, 'status.update', const {'kind': 'noop'});
      }
    }
    await _waitUntil(
      () =>
          client.replayWatermarksForTesting['runtime-a'] == 3 &&
          client.replayWatermarksForTesting['runtime-b'] == 1 &&
          client.replayWatermarksForTesting['runtime-c'] == 2,
    );
    final resumesBefore = gateway.rpcCalls('session.resume').length;

    await gateway.sockets.single.close(1001);
    await _waitUntil(
      () =>
          gateway.rpcCalls('session.resume').length >= resumesBefore + 3 &&
          chats.every((c) => c.desktopRuntimeSessionId != null),
      timeout: const Duration(seconds: 30),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(gateway.sockets, hasLength(2), reason: 'one redial for 3 chats');
    expect(gateway.rpcCalls('client.capabilities'), hasLength(2));
    final replays = {
      for (final call in gateway.rpcCalls('session.events.since'))
        call['params']['session_id']: call['params']['last_seen'],
    };
    expect(replays, {'runtime-a': 3, 'runtime-b': 1, 'runtime-c': 2});
    expect(gateway.rpcCalls('session.events.since'), hasLength(3));
    final resumedAfter = gateway
        .rpcCalls('session.resume')
        .skip(resumesBefore)
        .map((f) => f['params']['session_id'])
        .toList();
    expect(resumedAfter.toSet(), {'stored-a', 'stored-b', 'stored-c'});
    expect(resumedAfter, hasLength(3), reason: 'no duplicate re-attach');
    final resumeSockets = {
      for (final entry in gateway.frames)
        if (entry.$2['method'] == 'session.resume') entry.$1,
    };
    expect(resumeSockets, {gateway.sockets.first, gateway.sockets.last});
  });

  test('releasing chat A detaches only its runtime; B keeps streaming on '
      'the same socket, which closes after the last chat', () async {
    await open('a');
    final b = await open('b');
    final client = _sharedClient(pool, gateway);
    gateway.pushEvent('runtime-a', 'status.update', const {'kind': 'noop'});
    await _waitUntil(
      () => client.replayWatermarksForTesting.containsKey('runtime-a'),
    );

    service.release('conn-one-socket', 'stored-a', profile: 'default');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(gateway.sockets.single.closeCode, isNull);
    expect(client.replayWatermarksForTesting.containsKey('runtime-a'), isFalse);

    // Frames for the released runtime are dropped; B still gets its own.
    gateway.pushEvent('runtime-a', 'status.update', const {'kind': 'noop'});
    gateway.pushClarify('runtime-b', 'srq-afterrel0001');
    await _waitUntil(
      () => b.pendingInteractivePrompt != null,
      reason: 'B clarify',
    );
    await b.respondToClarify(b.pendingInteractivePrompt!.key, 'no');
    expect(client.replayWatermarksForTesting.containsKey('runtime-a'), isFalse);

    // Reopening A re-attaches it on the same socket.
    final a2 = await open('a');
    expect(a2.desktopRuntimeSessionId, 'runtime-a');
    expect(gateway.sockets, hasLength(1));

    // B is still busy (its clarify turn): only A goes; the socket stays.
    service.release('conn-one-socket', 'stored-a', profile: 'default');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(gateway.liveSockets, 1);
    expect(pool.leaseCount, 1);

    // Disposing the last chat gives the socket back and it closes.
    service.dispose();
    await _waitUntil(() => gateway.liveSockets == 0, reason: 'closed');
    expect(pool.chatClientCount, 0);
  });

  test('profiles keep separate sockets', () async {
    await open('a', profile: 'default');
    await open('b', profile: 'work');
    expect(gateway.sockets, hasLength(2));
    expect(pool.chatClientCount, 2);
  });

  test(
    'a server without per-session replay keeps one socket per chat',
    () async {
      gateway.replayEpoch = null;
      await open('a');
      await open('b');
      await open('c');
      expect(gateway.sockets, hasLength(3));
    },
  );

  test('chats opened concurrently before the first gateway.ready of a '
      'server without per-session replay still get one socket each', () async {
    gateway.replayEpoch = null;
    final chats = await Future.wait([open('a'), open('b'), open('c')]);

    expect(gateway.sockets, hasLength(3));
    expect(pool.chatClientCount, 1);
    expect(chats.map((c) => c.desktopRuntimeSessionId).toSet(), {
      'runtime-a',
      'runtime-b',
      'runtime-c',
    });
    // A chat opened after that keeps its own socket too.
    await open('d');
    expect(gateway.sockets, hasLength(4));
  });

  test('chats opened concurrently on a replay-capable server each attach '
      'their runtime, and later chats share the proven socket', () async {
    final chats = await Future.wait([open('a'), open('b'), open('c')]);
    expect(chats.map((c) => c.desktopRuntimeSessionId).toSet(), {
      'runtime-a',
      'runtime-b',
      'runtime-c',
    });
    final before = gateway.sockets.length;
    expect(before, lessThanOrEqualTo(3));
    await open('d');
    await open('e');
    expect(gateway.sockets.length, before, reason: 'shared once proven');
    expect(pool.chatClientCount, 1);
  });

  test('a silent-fanout gap on runtime B rehydrates only chat B; A keeps '
      'its runtime on the healthy shared socket', () async {
    gateway.busy.addAll({'stored-a', 'stored-b'});
    final a = await open('a');
    await open('b');
    final client = _sharedClient(pool, gateway);
    expect(client.watchedRuntimesForTesting, {'runtime-a', 'runtime-b'});
    // Watermarks >= 1 (Hermes' `latest_seq` is a positive sequence).
    gateway.pushEvent('runtime-a', 'status.update', const {'kind': 'noop'});
    gateway.pushEvent('runtime-b', 'status.update', const {'kind': 'noop'});
    await _waitUntil(() => client.replayWatermarksForTesting.length == 2);
    gateway.silentGap.add('runtime-b');
    final resumesBefore = gateway.rpcCalls('session.resume').length;

    _skew += const Duration(seconds: 11);
    await client.debugProbeSilentFanout();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      gateway
          .rpcCalls('session.events.since')
          .map((f) => f['params']['session_id']),
      containsAll(['runtime-a', 'runtime-b']),
    );
    // B runs its own (unchanged) post-gap recovery; A is never touched.
    await _waitUntil(
      () => gateway.rpcCalls('session.resume').length > resumesBefore,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(a.desktopRuntimeSessionId, 'runtime-a');
    final resumedAfter = gateway
        .rpcCalls('session.resume')
        .skip(resumesBefore)
        .map((f) => f['params']['session_id'])
        .toList();
    expect(resumedAfter, ['stored-b'], reason: 'only B rehydrates');
    expect(gateway.sockets, hasLength(1));
  });

  test('network switch: one redial and one handshake for every open chat '
      '(per-chat sockets needed one each)', () async {
    Future<({int sockets, int handshakes})> measure() async {
      for (final id in 'abc'.split('')) {
        await open(id);
      }
      final socketsBefore = gateway.sockets.length;
      final handshakesBefore = gateway.rpcCalls('client.capabilities').length;
      for (final socket in gateway.sockets.toList()) {
        await socket.close(1001);
      }
      await _waitUntil(
        () => ['a', 'b', 'c'].every(
          (id) =>
              service
                  .of('conn-one-socket', 'stored-$id', profile: 'default')
                  ?.desktopRuntimeSessionId ==
              null,
        ),
        reason: 'every chat saw the drop',
      );
      service.requestImmediateTransportRecovery();
      await _waitUntil(
        () =>
            gateway.liveSockets >= 1 &&
            ['a', 'b', 'c'].every(
              (id) =>
                  service
                      .of('conn-one-socket', 'stored-$id', profile: 'default')
                      ?.desktopRuntimeSessionId ==
                  'runtime-$id',
            ),
        timeout: const Duration(seconds: 30),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return (
        sockets: gateway.sockets.length - socketsBefore,
        handshakes:
            gateway.rpcCalls('client.capabilities').length - handshakesBefore,
      );
    }

    final shared = await measure();
    expect(shared.sockets, 1);
    expect(shared.handshakes, 1);
    // ignore: avoid_print
    print('os1215 network switch shared: $shared');

    service.dispose();
    await pool.closeAll();
    service = newService(shared: false);
    final perChat = await measure();
    // ignore: avoid_print
    print('os1215 network switch per-chat: $perChat');
    expect(perChat.sockets, 3);
    expect(perChat.handshakes, 3);
  });
}
