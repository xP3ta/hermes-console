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
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

/// lt1215: a real network cut mid-answer. After the reconnect the runtime is
/// quarantined (its live frames are held, never projected: current Hermes
/// cannot prove a snapshot/replay cut), so the chat only learns that the
/// answer is final through a REST/roster rehydration. Physical QA (build
/// 9485) measured the reconnect at once, the server finishing 11 s later,
/// and the answer shown only 30 s after the reconnect: the fanout watchdog's
/// second 15 s heartbeat tick. Here heartbeats never tick, so only the held
/// terminal frame itself can trigger the rehydration.
///
/// v7 fake: one stored session `stored-1` → runtime `runtime-1`, sequenced
/// events, the real wire shapes for resume/active_list/events.since.
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
              'heartbeat': true,
              'change_events': true,
              'replay_epoch': 'epoch-1',
            },
          },
        }),
      );
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        frames.add(frame);
        if (socket.closeCode != null) continue;
        final method = frame['method'];
        if (method is! String) continue;
        final params = (frame['params'] as Map?) ?? const {};
        final result = switch (method) {
          'client.capabilities' => {
            'server_requests': ['approval', 'clarify', 'sudo', 'secret'],
          },
          'gateway.capabilities' => {'per_session_exclusive_submit': true},
          'session.resume' => {
            'session_id': 'runtime-1',
            'stored_session_id': 'stored-1',
            'running': running,
            'status': running ? 'working' : 'idle',
            'inflight': running
                ? {'user': 'hola', 'assistant': 'respuesta '}
                : null,
          },
          'session.events.since' => {
            'epoch': 'epoch-1',
            'events': <Object>[],
            'latest_seq': params['last_seen'],
            'truncated': false,
            'count': 0,
          },
          'session.active_list' => {
            'sessions': [
              {
                'id': 'runtime-1',
                'session_key': 'stored-1',
                'stored_session_id': 'stored-1',
                'status': running ? 'working' : 'idle',
              },
            ],
          },
          'prompt.submit' => <String, dynamic>{'status': 'streaming'},
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

  final HttpServer server;
  final sockets = <WebSocket>[];
  final frames = <Map<String, dynamic>>[];
  bool running = false;
  int _seq = 0;

  static Future<_Gateway> start() async =>
      _Gateway._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  void event(String type, Map<String, dynamic> payload) => sockets.last.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {
        'type': type,
        'session_id': 'runtime-1',
        'seq': ++_seq,
        'payload': payload,
      },
    }),
  );

  int rpcCount(String method) =>
      frames.where((frame) => frame['method'] == method).length;
}

class _Dashboard extends DashboardClient {
  _Dashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 't');
}

Future<void> _until(
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

/// Durable transcript phases: before the turn, prompt stored, answer stored.
enum _Durable { empty, prompt, answer }

class _Harness {
  _Harness(this.gateway, this.connection);

  final _Gateway gateway;
  final SavedConnection connection;
  late final ActiveChat chat;
  var durable = _Durable.empty;

  /// Sends a prompt, streams a first delta, then drops the socket (the
  /// phone's ping timed out: dart:io closes with 1001) and waits for the
  /// reconnect recovery to bind the still-running turn again.
  Future<void> cutMidAnswerAndReconnect() async {
    await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []);
    await _until(() => gateway.rpcCount('prompt.submit') == 1);
    durable = _Durable.prompt;
    gateway.running = true;
    gateway.event('message.start', const {});
    gateway.event('message.delta', const {'text': 'respuesta '});
    await _until(() => chat.assistantContent.contains('respuesta'));

    final resumes = gateway.rpcCount('session.resume');
    await gateway.sockets.last.close(1001);
    await _until(
      () =>
          gateway.sockets.length == 2 &&
          gateway.rpcCount('session.resume') > resumes &&
          chat.desktopRuntimeSessionId == 'runtime-1' &&
          chat.state == ChatPipelineState.streaming,
      reason: 'reconnect recovery rebinds the running turn',
    );
  }

  /// Hermes ends the turn: the answer is durable, then the frame goes out.
  void finishTurn() {
    durable = _Durable.answer;
    gateway.running = false;
    gateway.event('message.complete', const {'text': 'respuesta final'});
  }

  int get rehydrationRpcs =>
      gateway.rpcCount('session.resume') +
      gateway.rpcCount('session.active_list') +
      gateway.rpcCount('session.events.since');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The real client stays on real sockets: undo the test HttpClient override.
  HttpOverrides.global = null;
  late _Gateway gateway;
  late SharedGatewayPool pool;
  late ActiveChatService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    gateway = await _Gateway.start();
    pool = SharedGatewayPool.forTesting(linger: Duration.zero);
    service = ActiveChatService(
      compressionRestoreStore: testCompressionRestoreStore(),
      connectionCredentialsRevision: ValueNotifier<int>(0),
      chatGatewayPool: pool,
      sharedChatGatewayFactory: (connection) => TuiGatewayClient(
        connection,
        dashboard: _Dashboard(),
        // No heartbeat tick (and so no fanout watchdog probe) can happen
        // during a test: only the event-driven path may rehydrate.
        heartbeatInterval: const Duration(hours: 1),
        heartbeatDeadline: const Duration(hours: 2),
      ),
    );
  });

  tearDown(() async {
    service.dispose();
    await pool.closeAll();
    await gateway.server.close(force: true);
  });

  Future<_Harness> open() async {
    final connection = SavedConnection(
      id: 'conn-late-cut',
      label: 'Late cut',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'k',
      dashboardUrl: 'http://127.0.0.1:${gateway.server.port}',
    );
    final harness = _Harness(gateway, connection);
    harness.chat = service.attach(
      connection: connection,
      sessionId: 'stored-1',
      sessionTitle: 'Late cut',
      sessionProfile: 'default',
      api: ApiClient(
        baseUrl: 'http://127.0.0.1:1',
        apiKey: 'k',
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      ),
      storedMessageLoader: (_, _) async => [
        if (harness.durable != _Durable.empty)
          {'id': 11, 'role': 'user', 'content': 'hola', 'timestamp': 100.0},
        if (harness.durable == _Durable.answer)
          {
            'id': 12,
            'role': 'assistant',
            'content': 'respuesta final',
            'timestamp': 101.0,
          },
      ],
      attachDesktopRuntimeOnLoad: true,
      allowUnownedDesktopSnapshotForTesting: true,
      disableForegroundKeepAlive: true,
    );
    await harness.chat.loadMessages();
    await _until(() => harness.chat.desktopRuntimeSessionId == 'runtime-1');
    return harness;
  }

  test('the answer Hermes finishes after a reconnect shows within 3 s '
      '(was 30 s: the fanout watchdog second tick)', () async {
    final h = await open();
    await h.cutMidAnswerAndReconnect();

    final clock = Stopwatch()..start();
    h.finishTurn();
    await _until(
      () =>
          h.chat.state == ChatPipelineState.completed &&
          h.chat.messages.any((m) => m['content'] == 'respuesta final'),
      timeout: const Duration(seconds: 6),
      reason: 'final answer shown',
    );
    // Desktop parity: a few seconds at most. The path is one resume plus
    // one transcript read; on loopback it takes a few ms.
    expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
    expect(
      h.chat.messages.where((m) => m['content'] == 'hola'),
      hasLength(1),
      reason: 'the prompt is not duplicated',
    );
  });

  test('a held frame that does not end the turn sends nothing: no extra '
      'traffic while Hermes keeps working', () async {
    final h = await open();
    await h.cutMidAnswerAndReconnect();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final before = h.rehydrationRpcs;

    h.gateway.event('message.delta', const {'text': 'mas '});
    h.gateway.event('tool.start', const {'tool_id': 't1', 'name': 'x'});
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(h.rehydrationRpcs, before);
    expect(h.chat.state, ChatPipelineState.streaming);

    // Positive control on the same socket: the terminal frame still lands.
    h.finishTurn();
    await _until(
      () => h.chat.state == ChatPipelineState.completed,
      timeout: const Duration(seconds: 6),
    );
  });

  test('repeated terminal frames rehydrate once', () async {
    final h = await open();
    await h.cutMidAnswerAndReconnect();
    final lease = pool.acquireChat(
      h.connection,
      profile: 'default',
      chatLinger: Duration.zero,
    );
    lease.release();
    var rehydrations = 0;
    final subscription = lease.client.events.listen(
      (_) {},
      onError: (Object error) {
        if (error is TuiGatewayRpcError &&
            error.message.contains('requires rehydration')) {
          rehydrations += 1;
        }
      },
    );
    addTearDown(subscription.cancel);

    h.finishTurn();
    h.gateway.event('message.complete', const {'text': 'respuesta final'});
    h.gateway.event('session.info', const {'running': false});
    await _until(
      () => h.chat.state == ChatPipelineState.completed,
      timeout: const Duration(seconds: 6),
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(rehydrations, 1);
  });
}
