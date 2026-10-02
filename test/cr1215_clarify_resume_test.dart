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

/// Fake Hermes gateway speaking the v7 contract: it answers client RPCs and
/// can push server→client request frames (`tui_gateway/server_requests.py`).
class _Gateway {
  final HttpServer server;
  final sockets = <WebSocket>[];
  final frames = <Map<String, dynamic>>[];
  final _frames = StreamController<Map<String, dynamic>>.broadcast();
  bool sendReadyImmediately = true;
  bool answerClientCapabilities = true;
  bool rejectClientCapabilities = false;
  Map<String, dynamic> Function(Map<String, dynamic> frame) resumeResult =
      (_) => {'session_id': 'runtime-1', 'stored_session_id': 'stored-1'};
  Map<String, dynamic> Function(Map<String, dynamic> frame) activeListResult =
      (_) => {'sessions': <Object>[]};
  Map<String, dynamic> Function(Map<String, dynamic> frame) eventsSinceResult =
      (_) => {
        'events': <Object>[],
        'latest_seq': 0,
        'truncated': false,
        'count': 0,
      };

  _Gateway._(this.server) {
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      if (sendReadyImmediately) sendReady(socket);
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        frames.add(frame);
        if (!_frames.isClosed) _frames.add(frame);
        final method = frame['method'];
        if (method is! String) continue; // a server-request response
        if (method == 'client.capabilities' && !answerClientCapabilities) {
          continue;
        }
        if (method == 'client.capabilities' && rejectClientCapabilities) {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'error': {'code': -32601, 'message': 'Method not found'},
            }),
          );
          continue;
        }
        final result = switch (method) {
          'client.capabilities' => {
            'server_requests': ['approval', 'clarify', 'sudo', 'secret'],
          },
          'gateway.capabilities' => {'per_session_exclusive_submit': true},
          'session.resume' => resumeResult(frame),
          'session.events.since' => eventsSinceResult(frame),
          'session.active_list' => activeListResult(frame),
          'clarify.lock' => {'status': 'ok', 'remaining': <String>[]},
          _ => <String, dynamic>{'status': 'ok'},
        };
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
        );
      }
    });
  }

  Map<String, dynamic> readyPayload = <String, dynamic>{};

  void sendReady([WebSocket? socket]) => (socket ?? sockets.last).add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {'type': 'gateway.ready', 'payload': readyPayload},
    }),
  );

  static Future<_Gateway> start() async =>
      _Gateway._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  void push(Map<String, dynamic> frame) => sockets.last.add(jsonEncode(frame));

  void pushServerRequest(
    String id,
    String method,
    Map<String, dynamic> params,
  ) => push({
    'jsonrpc': '2.0',
    'id': id,
    'method': method,
    'params': {'session_id': 'runtime-1', ...params},
  });

  void pushSessionEvent(String type, Map<String, dynamic> payload) => push({
    'jsonrpc': '2.0',
    'method': 'event',
    'params': {'type': type, 'session_id': 'runtime-1', 'payload': payload},
  });

  Future<Map<String, dynamic>> nextFrame(
    bool Function(Map<String, dynamic>) where,
  ) {
    for (final frame in frames) {
      if (where(frame)) return Future.value(frame);
    }
    return _frames.stream.firstWhere(where);
  }

  Iterable<Map<String, dynamic>> rpcCalls(String method) =>
      frames.where((frame) => frame['method'] == method);

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
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-server-requests',
      );
}

SavedConnection _connectionFor(_Gateway gateway) => SavedConnection(
  id: 'conn-server-requests',
  label: 'Server requests',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'gateway-key',
  dashboardUrl: 'http://127.0.0.1:${gateway.server.port}',
);

TuiGatewayClient _clientFor(_Gateway gateway) {
  final client = TuiGatewayClient(
    _connectionFor(gateway),
    dashboard: _TicketDashboardClient(),
  );
  addTearDown(client.close);
  return client;
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

Map<String, dynamic> _openClarify(String id, {String question = 'Seguimos?'}) =>
    {
      'id': id,
      'method': 'clarify',
      'params': {
        'session_id': 'runtime-1',
        'question': question,
        'choices': ['si', 'no'],
      },
    };

ActiveChat _chatFor(
  _Gateway gateway,
  TuiGatewayClient client, {
  bool attach = false,
}) {
  final connection = _connectionFor(gateway);
  final chat = ActiveChat(
    compressionRestoreStore: testCompressionRestoreStore(),
    connection: connection,
    sessionId: 'stored-1',
    sessionTitle: 'Clarify resume',
    notifications: null,
    onTerminal: () {},
    api: ApiClient(
      baseUrl: connection.baseUrl,
      apiKey: connection.apiKey,
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    ),
    desktopGateway: client,
    attachDesktopRuntimeOnLoad: attach,
    desktopRecoveryBackoff: const [Duration.zero],
    allowUnownedDesktopSnapshotForTesting: true,
  );
  addTearDown(chat.dispose);
  return chat;
}

void main() {
  late _Gateway gateway;

  setUp(() async => gateway = await _Gateway.start());
  tearDown(() => gateway.close());

  test('a clarify still open when the chat opens renders from the resume '
      'snapshot open_requests', () async {
    gateway.resumeResult = (_) => {
      'session_id': 'runtime-1',
      'stored_session_id': 'stored-1',
      'running': true,
      'status': 'waiting',
      'open_requests': [_openClarify('srq-cold000001')],
    };
    final client = _clientFor(gateway);
    final chat = _chatFor(gateway, client);

    await chat.loadMessages();
    await _waitUntil(() => chat.pendingInteractivePrompt != null);
    expect(chat.pendingInteractivePrompt!.key.requestId, 'srq-cold000001');

    await chat.respondToClarify(chat.pendingInteractivePrompt!.key, 'si');
    final answer = await gateway
        .nextFrame((frame) => frame['id'] == 'srq-cold000001')
        .timeout(const Duration(seconds: 2));
    expect(answer['result'], {'answer': 'si'});
  });

  test('a clarify pending across an abrupt socket drop comes back on the '
      'reconnected socket and is answered there', () async {
    gateway.resumeResult = (_) => {
      'session_id': 'runtime-1',
      'stored_session_id': 'stored-1',
      'running': true,
      'status': 'working',
    };
    final client = _clientFor(gateway);
    final chat = _chatFor(gateway, client, attach: true);
    await chat.loadMessages();
    await _waitUntil(() => gateway.rpcCalls('session.resume').isNotEmpty);
    gateway.pushServerRequest('srq-drop0000001', 'clarify', {
      'question': 'Seguimos?',
      'choices': ['si', 'no'],
    });
    await _waitUntil(() => chat.pendingInteractivePrompt != null);

    // The server still waits on the question and replays it on resume.
    gateway.resumeResult = (_) => {
      'session_id': 'runtime-1',
      'stored_session_id': 'stored-1',
      'running': true,
      'status': 'waiting',
      'open_requests': [_openClarify('srq-drop0000001')],
    };
    final resumesBefore = gateway.rpcCalls('session.resume').length;
    await gateway.sockets.single.close(1001);
    await _waitUntil(
      () => gateway.rpcCalls('session.resume').length > resumesBefore,
      timeout: const Duration(seconds: 20),
    );
    await _waitUntil(() => chat.pendingInteractivePrompt != null);
    expect(chat.pendingInteractivePrompt!.key.requestId, 'srq-drop0000001');
    expect(gateway.sockets, hasLength(2));
    expect(gateway.rpcCalls('client.capabilities'), hasLength(2));

    await chat.respondToClarify(chat.pendingInteractivePrompt!.key, 'no');
    final answer = await gateway
        .nextFrame((frame) => frame['id'] == 'srq-drop0000001')
        .timeout(const Duration(seconds: 2));
    expect(answer['result'], {'answer': 'no'});
  });

  test('a clarify written while the phone was offline shows after the '
      'reconnect resume', () async {
    gateway.resumeResult = (_) => {
      'session_id': 'runtime-1',
      'stored_session_id': 'stored-1',
      'running': true,
      'status': 'working',
    };
    final client = _clientFor(gateway);
    final chat = _chatFor(gateway, client, attach: true);
    await chat.loadMessages();
    await _waitUntil(() => chat.desktopRuntimeSessionId == 'runtime-1');

    // The socket dies first; the agent asks while nobody is attached, so the
    // frame goes nowhere and only the resume snapshot carries it.
    gateway.resumeResult = (_) => {
      'session_id': 'runtime-1',
      'stored_session_id': 'stored-1',
      'running': true,
      'status': 'waiting',
      'open_requests': [_openClarify('srq-offline00001')],
    };
    await gateway.sockets.single.close(1001);
    await _waitUntil(
      () => chat.pendingInteractivePrompt != null,
      timeout: const Duration(seconds: 20),
    );
    expect(chat.pendingInteractivePrompt!.key.requestId, 'srq-offline00001');
    expect(gateway.rpcCalls('client.capabilities'), hasLength(2));

    await chat.respondToClarify(chat.pendingInteractivePrompt!.key, 'si');
    final answer = await gateway
        .nextFrame((frame) => frame['id'] == 'srq-offline00001')
        .timeout(const Duration(seconds: 2));
    expect(answer['result'], {'answer': 'si'});
    expect(gateway.sockets.last.closeCode, isNull);
  });

  test('an idle viewer that loses its socket picks up a question asked '
      'meanwhile when it rejoins the runtime', () async {
    gateway.resumeResult = (_) => {
      'session_id': 'runtime-1',
      'stored_session_id': 'stored-1',
      'running': false,
      'status': 'idle',
    };
    gateway.activeListResult = (_) => {
      'sessions': [
        {
          'id': 'runtime-1',
          'session_key': 'stored-1',
          'stored_session_id': 'stored-1',
          'status': 'waiting',
          'current': false,
        },
      ],
    };
    final client = _clientFor(gateway);
    final chat = _chatFor(gateway, client, attach: true);
    await chat.loadMessages();
    await _waitUntil(() => chat.desktopRuntimeSessionId == 'runtime-1');
    expect(chat.isStreaming, isFalse);

    gateway.resumeResult = (_) => {
      'session_id': 'runtime-1',
      'stored_session_id': 'stored-1',
      'running': true,
      'status': 'waiting',
      'open_requests': [_openClarify('srq-idleview0001')],
    };
    await gateway.sockets.single.close(1001);
    await _waitUntil(
      () => chat.pendingInteractivePrompt != null,
      timeout: const Duration(seconds: 20),
    );
    expect(chat.pendingInteractivePrompt!.key.requestId, 'srq-idleview0001');
  });

  test(
    'an answered clarify never reopens from a stale replay after a drop',
    () async {
      gateway.resumeResult = (_) => {
        'session_id': 'runtime-1',
        'stored_session_id': 'stored-1',
        'running': true,
        'status': 'working',
      };
      final client = _clientFor(gateway);
      final chat = _chatFor(gateway, client, attach: true);
      await chat.loadMessages();
      await _waitUntil(() => chat.desktopRuntimeSessionId == 'runtime-1');
      gateway.pushServerRequest('srq-answered0001', 'clarify', {
        'question': 'Seguimos?',
        'choices': ['si', 'no'],
      });
      await _waitUntil(() => chat.pendingInteractivePrompt != null);
      await chat.respondToClarify(chat.pendingInteractivePrompt!.key, 'si');
      expect(chat.pendingInteractivePrompt, isNull);

      // A replay that still lists the answered id (race with the server
      // settling it) must not resurrect the card.
      gateway.resumeResult = (_) => {
        'session_id': 'runtime-1',
        'stored_session_id': 'stored-1',
        'running': true,
        'status': 'waiting',
        'open_requests': [_openClarify('srq-answered0001')],
      };
      final resumesBefore = gateway.rpcCalls('session.resume').length;
      await gateway.sockets.single.close(1001);
      await _waitUntil(
        () => gateway.rpcCalls('session.resume').length > resumesBefore,
        timeout: const Duration(seconds: 20),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(chat.pendingInteractivePrompt, isNull);
    },
  );

  test('a clarify registered on another socket is answered through the '
      'request.answer proxy, never the removed clarify.respond', () async {
    final client = _clientFor(gateway);
    await client.connect();
    final response = await client.respondToClarify('srq-elsewhere001', 'si');
    expect(response.status, DesktopPromptResponseStatus.ok);
    final proxy = gateway.rpcCalls('request.answer').single;
    expect(proxy['params'], {
      'id': 'srq-elsewhere001',
      'result': {'answer': 'si'},
    });
    expect(gateway.rpcCalls('clarify.respond'), isEmpty);
  });

  test('waiting with no visible card says so, and Show question asks the '
      'server for the open request', () async {
    // The resume races the request: status already says waiting but the
    // snapshot was cut before the request registered.
    gateway.resumeResult = (_) => {
      'session_id': 'runtime-1',
      'stored_session_id': 'stored-1',
      'running': true,
      'status': 'waiting',
    };
    gateway.eventsSinceResult = (frame) => {
      'events': <Object>[],
      'latest_seq': 0,
      'truncated': false,
      'count': 0,
      'open_requests': [_openClarify('srq-unseen000001')],
    };
    final client = _clientFor(gateway);
    final chat = _chatFor(gateway, client, attach: true);
    await chat.loadMessages();
    await _waitUntil(() => chat.desktopRuntimeSessionId == 'runtime-1');
    expect(chat.pendingInteractivePrompt, isNull);
    expect(chat.awaitsUnseenInput, isTrue);

    await chat.rehydrateOpenRequests();
    expect(chat.pendingInteractivePrompt!.key.requestId, 'srq-unseen000001');
    expect(chat.awaitsUnseenInput, isFalse);
    final probe = gateway.rpcCalls('session.events.since').last;
    expect(probe['params']['session_id'], 'runtime-1');
    expect(probe['params']['last_seen'], greaterThan(1 << 40));

    await chat.respondToClarify(chat.pendingInteractivePrompt!.key, 'no');
    final answer = await gateway
        .nextFrame((frame) => frame['id'] == 'srq-unseen000001')
        .timeout(const Duration(seconds: 2));
    expect(answer['result'], {'answer': 'no'});
  });

  test('a working turn never shows the waiting notice', () async {
    gateway.resumeResult = (_) => {
      'session_id': 'runtime-1',
      'stored_session_id': 'stored-1',
      'running': true,
      'status': 'working',
    };
    final client = _clientFor(gateway);
    final chat = _chatFor(gateway, client, attach: true);
    await chat.loadMessages();
    await _waitUntil(() => chat.desktopRuntimeSessionId == 'runtime-1');
    expect(chat.awaitsUnseenInput, isFalse);
  });

  test('connectivity flips every 200 ms with clarify traffic raise no '
      'uncaught error and the question survives', () async {
    gateway.resumeResult = (_) => {
      'session_id': 'runtime-1',
      'stored_session_id': 'stored-1',
      'running': true,
      'status': 'waiting',
      'open_requests': [_openClarify('srq-flip00000001')],
    };
    final proxy = await _FlakyProxy.start(gateway.server.port);
    addTearDown(proxy.close);
    final uncaught = <Object>[];
    await runZonedGuarded(() async {
      final connection = _connectionFor(
        gateway,
      ).copyWith(dashboardUrl: 'http://127.0.0.1:${proxy.port}');
      final client = TuiGatewayClient(
        connection,
        dashboard: _TicketDashboardClient(),
        heartbeatInterval: const Duration(milliseconds: 50),
        heartbeatDeadline: const Duration(milliseconds: 150),
      );
      addTearDown(client.close);
      final pool = SharedGatewayPool.forTesting(
        factory: (c) =>
            TuiGatewayClient(c, dashboard: _TicketDashboardClient()),
        linger: Duration.zero,
      );
      addTearDown(pool.closeAll);
      final lease = pool.acquire(connection);
      final chat = _chatFor(gateway, client, attach: true);
      await chat.loadMessages();
      await _waitUntil(() => chat.pendingInteractivePrompt != null);

      for (var flip = 0; flip < 15; flip++) {
        proxy.severAll();
        unawaited(client.probeNow().then((_) {}, onError: (Object _) {}));
        unawaited(pool.probeAll());
        unawaited(lease.client.connect().then((_) {}, onError: (Object _) {}));
        chat.probeTransportNow();
        chat.requestImmediateTransportRecovery();
        final pending = chat.pendingInteractivePrompt;
        if (pending != null && flip.isOdd) {
          unawaited(
            chat
                .respondToClarify(pending.key, 'si')
                .then((_) {}, onError: (Object _) {}),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      lease.release();
      // The network settles; the open question must be back on screen.
      await _waitUntil(
        () => client.isConnected && chat.desktopRuntimeSessionId != null,
        timeout: const Duration(seconds: 30),
      );
    }, (error, stack) => uncaught.add(error));
    expect(uncaught, isEmpty);
    // The flips really cut sockets: many reconnects reached the gateway.
    expect(gateway.sockets.length, greaterThan(8));
  });
}

/// TCP forwarder whose connections can be killed at once, the way a
/// wifi↔cellular or Tailscale path change kills every socket of the phone.
class _FlakyProxy {
  _FlakyProxy._(this._server, this._target) {
    _server.listen((client) async {
      try {
        final upstream = await Socket.connect(
          InternetAddress.loopbackIPv4,
          _target,
        );
        _pairs.add((client, upstream));
        client.listen(
          upstream.add,
          onError: (Object _) => upstream.destroy(),
          onDone: upstream.destroy,
          cancelOnError: true,
        );
        upstream.listen(
          client.add,
          onError: (Object _) => client.destroy(),
          onDone: client.destroy,
          cancelOnError: true,
        );
      } catch (_) {
        client.destroy();
      }
    });
  }

  final ServerSocket _server;
  final int _target;
  final _pairs = <(Socket, Socket)>[];

  int get port => _server.port;

  static Future<_FlakyProxy> start(int target) async => _FlakyProxy._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    target,
  );

  void severAll() {
    for (final (a, b) in _pairs) {
      a.destroy();
      b.destroy();
    }
    _pairs.clear();
  }

  Future<void> close() async {
    severAll();
    await _server.close();
  }
}
