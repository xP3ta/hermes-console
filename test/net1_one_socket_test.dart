import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';

/// net1/N5 (harness from os1215): every open chat of a (connection, profile) rides ONE gateway
/// WebSocket, like Desktop's single JsonRpcGatewayClient. This fake speaks
/// the v7 replay contract (`replay_epoch`, sequenced session events) and
/// maps each stored session `stored-X` to the runtime `runtime-X`.
class _Gateway {
  _Gateway._(this.server) {
    server.listen((request) async {
      attempts++;
      if (refuse) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }
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
                  'current':
                      reportCurrent && runtime == params['current_session_id'],
                },
            ],
          },
          'session.close' => {'closed': true},
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

  /// Upgrade requests seen, refused ones included.
  int attempts = 0;

  /// While true every upgrade is answered 503 (a cut that does not reach the
  /// server's socket table).
  bool refuse = false;

  void dropAll() {
    for (final s in sockets) {
      if (s.closeCode == null) unawaited(s.close(WebSocketStatus.goingAway));
    }
  }

  final sockets = <WebSocket>[];
  final frames = <(WebSocket, Map<String, dynamic>)>[];
  final _frames = StreamController<Map<String, dynamic>>.broadcast();
  String? replayEpoch = 'epoch-1';
  final _sequences = <String, int>{};
  final _resumed = <String>{};
  final busy = <Object?>{};
  final silentGap = <Object?>{};

  /// `session.active_list` marks the asking runtime `current` (Hermes does
  /// for the caller's own session); off by default, as before.
  bool reportCurrent = false;

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
  late ValueNotifier<int> credentials;

  Future<ActiveChat> open(String id) async {
    final chat = service.attach(
      connection: _connectionFor(gateway),
      sessionId: 'stored-$id',
      sessionTitle: 'Chat $id',
      sessionProfile: 'default',
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
      timeout: const Duration(seconds: 25),
      reason: 'attach $id',
    );
    return chat;
  }

  setUp(() async {
    gateway = await _Gateway.start();
    pool = SharedGatewayPool.forTesting(linger: Duration.zero);
    credentials = ValueNotifier<int>(0);
    service = ActiveChatService(
      compressionRestoreStore: testCompressionRestoreStore(),
      connectionCredentialsRevision: credentials,
      chatGatewayPool: pool,
      sharedChatGatewayFactory: _client,
    );
  });

  tearDown(() async {
    service.dispose();
    await pool.closeAll();
    await gateway.close();
  });

  test('a chat opened during a cut waits for the shared socket instead of '
      'dialling its own: one socket after the cut', () async {
    await open('a');
    await open('b');
    await open('c');
    final client = _sharedClient(pool, gateway);
    expect(gateway.sockets, hasLength(1));
    expect(client.knownPerSessionReplayTransport, isTrue);

    gateway.refuse = true;
    gateway.dropAll();
    await _waitUntil(
      () => !client.isConnected,
      reason: 'the shared socket noticed the cut',
    );
    // Proven replay is remembered across the cut (was forgotten at the dial).
    expect(client.knownPerSessionReplayTransport, isTrue);
    final attemptsBefore = gateway.attempts;

    // The cut is the client's backoff gap: it ends with ONE redial.
    gateway.refuse = false;
    final d = open('d');
    await d;
    await _waitUntil(
      () => gateway.rpcCalls('session.resume').length >= 7,
      timeout: const Duration(seconds: 25),
      reason: 'a, b, c re-attach and d attaches',
    );

    expect(pool.chatClientCount, 1);
    expect(gateway.liveSockets, 1, reason: 'one socket, not one per chat');
    expect(
      gateway.sockets.length,
      2,
      reason: 'the first socket plus ONE reopen for the whole cut',
    );
    expect(identical(_sharedClient(pool, gateway), client), isTrue);
    // Every dial of the cut came from the shared client's own redial ladder.
    expect(gateway.attempts - attemptsBefore, lessThanOrEqualTo(4));
  });

  test('a server that comes back without replay_epoch is forgotten (legacy): '
      'chats go back to one socket each', () async {
    await open('a');
    final client = _sharedClient(pool, gateway);
    expect(client.knownPerSessionReplayTransport, isTrue);

    // The server came back as a legacy build.
    gateway.replayEpoch = null;
    gateway.dropAll();
    await _waitUntil(() => !client.isConnected, reason: 'cut noticed');
    await client.connectForeground();
    expect(client.knownPerSessionReplayTransport, isFalse);
  });

  test('a released chat leaves no socket redialling through the cut', () async {
    await open('a');
    final client = _sharedClient(pool, gateway);
    gateway.refuse = true;
    gateway.dropAll();
    await _waitUntil(() => !client.isConnected, reason: 'cut noticed');
    service.release('conn-one-socket', 'stored-a', profile: 'default');
    await _waitUntil(() => client.isClosed, reason: 'released socket closed');
    final attempts = gateway.attempts;
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(gateway.attempts, attempts);
    expect(gateway.liveSockets, 0);
  });

  test('a first contact with no gateway.ready yet stays unknown', () async {
    final lease = pool.acquireChat(
      _connectionFor(gateway),
      profile: 'default',
      chatLinger: Duration.zero,
      factory: _client,
    );
    addTearDown(lease.release);
    expect(lease.client.knownPerSessionReplayTransport, isFalse);
    expect(
      pool.chatSocketRefusesAnotherChat(_connectionFor(gateway), 'default'),
      isTrue,
      reason: 'a chat rides it and nothing proved replay',
    );
  });
}
