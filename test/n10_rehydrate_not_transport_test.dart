import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_keepalive_controller.dart';
import 'package:hermes_android/core/services/turn_keepalive_hold.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';
import 'support/test_api_client.dart';

/// N10b: with the socket stable, a withheld turn end or a silent-fanout gap
/// asks the chat to re-read authoritative state. That is not a lost transport:
/// no `offline`/`connecting`, no retired runtime, no `session.resume`, one
/// coalesced transcript read per turn. A cut socket keeps the loss path.
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
          'session.activate' => {
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
            'events': [
              for (final e in ring)
                if ((e['seq'] as int) > (params['last_seen'] as int)) e,
            ],
            'latest_seq': ring.isEmpty ? params['last_seen'] : ring.last['seq'],
            'truncated': false,
            'count': ring
                .where((e) => (e['seq'] as int) > (params['last_seen'] as int))
                .length,
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
          'session.redirect' => <String, dynamic>{'status': 'redirected'},
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

  /// What Hermes' replay ring holds: every frame sent, delivered or not.
  final ring = <Map<String, dynamic>>[];

  static Future<_Gateway> start() async =>
      _Gateway._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  void event(String type, int seq, Map<String, dynamic> payload) {
    final params = {
      'type': type,
      'session_id': 'runtime-1',
      'seq': seq,
      'payload': payload,
    };
    ring.add(params);
    sockets.last.add(
      jsonEncode({'jsonrpc': '2.0', 'method': 'event', 'params': params}),
    );
  }

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

enum _Durable { empty, prompt, answer, correctedAnswer }

class _ReleaseHoldOnResume with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) TurnKeepAliveHold.held = false;
  }
}

class _HoldPlatform implements TurnKeepAlivePlatform {
  int starts = 0;
  int stops = 0;

  @override
  set onEnded(void Function(String reason)? callback) {}

  @override
  Future<bool> start({
    required String title,
    required String text,
    required Duration cap,
  }) async {
    starts += 1;
    return true;
  }

  @override
  Future<void> stop() async {
    stops += 1;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late _Gateway gateway;
  late SharedGatewayPool pool;
  late ActiveChatService service;
  late ActiveChat chat;
  late TuiGatewayClient client;
  var durable = _Durable.empty;
  var transcriptReads = 0;
  var clock = DateTime.now();
  final transport = <ChatTransportState>[];
  final logs = <String>[];
  late DebugPrintCallback originalDebugPrint;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    durable = _Durable.empty;
    transcriptReads = 0;
    clock = DateTime.now();
    transport.clear();
    logs.clear();
    originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) logs.add(message);
    };
    gateway = await _Gateway.start();
    pool = SharedGatewayPool.forTesting(linger: Duration.zero);
    service = ActiveChatService(
      compressionRestoreStore: testCompressionRestoreStore(),
      connectionCredentialsRevision: ValueNotifier<int>(0),
      chatGatewayPool: pool,
      sharedChatGatewayFactory: (connection) => client = TuiGatewayClient(
        connection,
        dashboard: _Dashboard(),
        heartbeatInterval: const Duration(hours: 1),
        heartbeatDeadline: const Duration(hours: 2),
        fanoutInactivityDeadline: const Duration(seconds: 15),
        now: () => clock,
      ),
    );
  });

  tearDown(() async {
    debugPrint = originalDebugPrint;
    service.dispose();
    await pool.closeAll();
    await gateway.server.close(force: true);
  });

  Future<void> open() async {
    final connection = SavedConnection(
      id: 'conn-n10b',
      kind: InstanceKind.homelab,
      label: 'N10b',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'unused',
      dashboardUrl: 'http://127.0.0.1:${gateway.server.port}',
    );
    chat = service.attach(
      connection: connection,
      sessionId: 'stored-1',
      sessionTitle: 'N10b',
      sessionProfile: 'default',
      api: testApiClient(
        baseUrl: 'http://127.0.0.1:1',
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      ),
      storedMessageLoader: (_, _) async {
        transcriptReads += 1;
        return [
          if (durable != _Durable.empty)
            {'id': 11, 'role': 'user', 'content': 'hola', 'timestamp': 100.0},
          if (durable == _Durable.correctedAnswer)
            {
              'id': 12,
              'role': 'assistant',
              'content': 'respuesta ',
              'timestamp': 100.4,
            },
          if (durable == _Durable.correctedAnswer)
            {
              'id': 13,
              'role': 'user',
              'content': 'mejor hazlo corto',
              'display_kind': 'steer',
              'timestamp': 100.5,
            },
          if (durable == _Durable.answer || durable == _Durable.correctedAnswer)
            {
              'id': durable == _Durable.correctedAnswer ? 14 : 12,
              'role': 'assistant',
              'content': 'respuesta final',
              'timestamp': 101.0,
            },
        ];
      },
      attachDesktopRuntimeOnLoad: true,
      allowUnownedDesktopSnapshotForTesting: true,
      disableForegroundKeepAlive: true,
      wallClockMsForTesting: () => clock.millisecondsSinceEpoch,
    );
    await chat.loadMessages();
    await _until(() => chat.desktopRuntimeSessionId == 'runtime-1');
    chat.transportStatusListenable.addListener(
      () => transport.add(chat.transportStatus.state),
    );
  }

  /// A turn in flight whose live stream then loses one frame: the replay
  /// coordinator quarantines the runtime, exactly as on the 9605 trace.
  Future<void> streamThenLoseAFrame() async {
    await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []);
    await _until(() => gateway.rpcCount('prompt.submit') == 1);
    durable = _Durable.prompt;
    gateway.running = true;
    gateway.event('message.start', 1, const {});
    gateway.event('message.delta', 2, const {'text': 'respuesta '});
    await _until(() => chat.assistantContent.contains('respuesta'));
    gateway.event('message.delta', 4, const {'text': 'perdido '});
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  test('a withheld turn end on a stable socket settles the turn without '
      'offline, resume or a second read', () async {
    await open();
    await streamThenLoseAFrame();
    final resumes = gateway.rpcCount('session.resume');
    final reads = transcriptReads;

    durable = _Durable.answer;
    gateway.running = false;
    gateway.event('message.complete', 5, const {'text': 'respuesta final'});
    await _until(
      () =>
          chat.state == ChatPipelineState.completed &&
          chat.messages.any((m) => m['content'] == 'respuesta final'),
      reason: 'final answer shown',
    );

    expect(
      transport.where((state) => state != ChatTransportState.connected),
      isEmpty,
      reason: 'the socket never dropped: no offline, no reconnecting',
    );
    expect(gateway.rpcCount('session.resume'), resumes);
    expect(transcriptReads - reads, lessThanOrEqualTo(1));
    expect(logs.where((l) => l.contains('recovery scheduled')), isEmpty);
    expect(chat.messages.where((m) => m['content'] == 'hola'), hasLength(1));
    expect(
      chat.messages.where((m) => m['content'] == 'respuesta final'),
      hasLength(1),
    );
  });

  test('an answer not yet durable keeps the turn open: no gave-up, no '
      'resume, one read; the next window (x2) settles it', () async {
    await open();
    await streamThenLoseAFrame();
    final resumes = gateway.rpcCount('session.resume');
    final reads = transcriptReads;

    gateway.running = false;
    gateway.event('message.complete', 5, const {'text': 'respuesta final'});
    await _until(
      () => transcriptReads - reads == 1,
      reason: 'one coalesced read',
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(chat.state, isNot(ChatPipelineState.completed));
    expect(chat.state, isNot(ChatPipelineState.failed));
    expect(
      transport.where((state) => state != ChatTransportState.connected),
      isEmpty,
    );
    expect(gateway.rpcCount('session.resume'), resumes);
    expect(transcriptReads - reads, 1, reason: 'at most one read per turn');
    expect(logs.where((l) => l.contains('gave up')), isEmpty);
    expect(logs.where((l) => l.contains('recovery scheduled')), isEmpty);

    // Within one deadline (15 s) nothing is due; the first window after the
    // read is doubled (30 s), so 20 s later still nothing.
    durable = _Durable.answer;
    final probes = gateway.rpcCount('session.events.since');
    clock = clock.add(const Duration(seconds: 20));
    await client.debugProbeSilentFanout();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      gateway.rpcCount('session.events.since'),
      probes,
      reason: 'window not elapsed: no probe',
    );
    expect(transcriptReads - reads, 1);

    clock = clock.add(const Duration(seconds: 20));
    await client.debugProbeSilentFanout();
    await _until(
      () =>
          chat.state == ChatPipelineState.completed &&
          chat.messages.any((m) => m['content'] == 'respuesta final'),
      reason: 'next silence window settles the turn',
    );
    expect(gateway.rpcCount('session.resume'), resumes);
    expect(
      transport.where((state) => state != ChatTransportState.connected),
      isEmpty,
    );
  });

  test('a live correction whose old turn end is withheld does not degrade '
      'the new turn (was: gave up idle_unproven)', () async {
    await open();
    await streamThenLoseAFrame();
    final resumes = gateway.rpcCount('session.resume');

    await chat.steer('mejor hazlo corto');
    expect(gateway.rpcCount('session.redirect'), 1);
    // Hermes has one end per run: this is the end of the same, corrected turn
    // (redirect starts no new turn). It is withheld: no cut proof yet.
    gateway.event('message.complete', 5, const {'text': 'cortado'});
    await _until(
      () => logs.any((l) => l.contains('rehydrate in place')),
      reason: 'the withheld end asks for a rehydration',
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(chat.state, isNot(ChatPipelineState.failed));
    expect(chat.state, isNot(ChatPipelineState.completed));
    expect(logs.where((l) => l.contains('gave up')), isEmpty);
    expect(logs.where((l) => l.contains('recovery scheduled')), isEmpty);
    expect(gateway.rpcCount('session.resume'), resumes);
    expect(
      transport.where((state) => state != ChatTransportState.connected),
      isEmpty,
    );
  });

  test('the redirected turn ends with its own answer once: completed, one '
      'row, no resume, no offline', () async {
    await open();
    await streamThenLoseAFrame();
    final resumes = gateway.rpcCount('session.resume');
    await chat.steer('mejor hazlo corto');
    expect(gateway.rpcCount('session.redirect'), 1);

    durable = _Durable.correctedAnswer;
    gateway.running = false;
    gateway.event('message.complete', 5, const {'text': 'respuesta final'});
    await _until(
      () =>
          chat.state == ChatPipelineState.completed &&
          chat.messages.any((m) => m['content'] == 'respuesta final'),
      reason: 'the new turn ends with its answer',
    );

    expect(
      chat.messages.where((m) => m['content'] == 'respuesta final'),
      hasLength(1),
    );
    expect(
      chat.messages.where((m) => m['content'] == 'mejor hazlo corto'),
      hasLength(1),
    );
    expect(gateway.rpcCount('session.resume'), resumes);
    expect(
      transport.where((state) => state != ChatTransportState.connected),
      isEmpty,
    );
    expect(logs.where((l) => l.contains('gave up')), isEmpty);
  });

  test(
    'a failed turn whose end is withheld reaches a terminal state: '
    'idle_unproven after three unproven windows, no offline, no resume',
    () async {
      await open();
      await streamThenLoseAFrame();
      final resumes = gateway.rpcCount('session.resume');
      final reads = transcriptReads;

      // Hermes failed the turn: the server is idle and no assistant row exists.
      gateway.running = false;
      gateway.event('error', 5, const {'message': 'provider failed'});
      await Future<void>.delayed(const Duration(milliseconds: 500));
      for (var i = 0; i < 8 && chat.isStreaming; i++) {
        clock = clock.add(const Duration(seconds: 130));
        await client.debugProbeSilentFanout();
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      // dp-A (Desktop session-states.ts settleEndedLiveTurn): Hermes said the
      // turn is over, so it settles without «No se pudo recuperar el turno».
      await _until(
        () => !chat.isStreaming,
        reason: 'state=${chat.state} reads=${transcriptReads - reads}',
      );
      expect(chat.state, isNot(ChatPipelineState.failed));
      expect(
        chat.messages.where(
          (m) =>
              m['content'] ==
              'No se pudo recuperar el turno. Inténtalo de nuevo.',
        ),
        isEmpty,
      );

      expect(logs.where((l) => l.contains('kind=idle_unproven')), hasLength(1));
      expect(
        transcriptReads - reads,
        // dp-A: +1, the single transcript re-read after settling.
        lessThanOrEqualTo(4),
        reason: 'one read per window, three windows at most',
      );
      expect(gateway.rpcCount('session.resume'), resumes);
      expect(
        transport.where((state) => state != ChatTransportState.connected),
        isEmpty,
      );
      expect(logs.where((l) => l.contains('recovery scheduled')), isEmpty);
      expect(chat.messages.where((m) => m['content'] == 'hola'), hasLength(1));
    },
  );

  test('dispose clears in-place recovery observations and end candidate', () async {
    await open();
    await streamThenLoseAFrame();
    gateway.running = false;
    gateway.event('error', 5, const {'message': 'provider failed'});
    await _until(() => chat.hasInPlaceRecoveryProofForTesting);
    chat.dispose();
    expect(chat.hasInPlaceRecoveryProofForTesting, isFalse);
    expect(chat.desktopRecoveryUnconfirmed, isFalse);
  });

  // conn-registry (REVISION-3 #3): with the app away and the turn keep-alive
  // holding, a cut socket redials (Desktop reconnects during a turn:
  // apps/desktop/src/store/gateway.ts:1103); without the hold it stays down
  // until the app returns, as before.
  // conn-registry (REVISION-3 #3, REVISION-4 B): the REAL keep-alive
  // controller holds before the cut, keeps holding through it while the
  // socket redials, and the session is re-attached to the new socket in the
  // background (a recovery session.resume re-binds the live transport, and
  // the recovery proof lets the turn's frames through). Desktop reconnects during a
  // turn (apps/desktop/src/store/gateway.ts:1103).
  test('a socket cut during the hold redials, re-attaches and keeps the hold',
      () async {
    addTearDown(TurnKeepAliveHold.resetForTesting);
    await open();
    await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []);
    await _until(() => gateway.rpcCount('prompt.submit') == 1);
    durable = _Durable.prompt;
    gateway.running = true;
    gateway.event('message.start', 1, const {});
    await _until(() => chat.isStreaming);

    final platform = _HoldPlatform();
    final controller = TurnKeepAliveController(
      platform: platform,
      working: () => anyChatTurnWorking(service),
      transportUp: () => workingChatsConnected(service),
      enabled: () => true,
      appLocked: () => false,
      notificationsAllowed: () async => true,
      copy: () => (title: 't', text: 'x'),
      startDelay: const Duration(milliseconds: 10),
    );
    addTearDown(controller.dispose);
    // REVISION-4 C: a chat at rest on the SAME socket, attached after the
    // working one, must not re-suspend what the working chat unparks.
    final idle = service.attach(
      connection: SavedConnection(
        id: 'conn-n10b',
        kind: InstanceKind.homelab,
        label: 'N10b',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'unused',
        dashboardUrl: 'http://127.0.0.1:${gateway.server.port}',
      ),
      sessionId: 'stored-idle',
      sessionTitle: 'idle',
      sessionProfile: 'default',
      api: testApiClient(
        baseUrl: 'http://127.0.0.1:1',
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      ),
      storedMessageLoader: (_, _) async => const [],
      attachDesktopRuntimeOnLoad: false,
      allowUnownedDesktopSnapshotForTesting: true,
      disableForegroundKeepAlive: true,
    );
    expect(idle.isStreaming, isFalse);
    chat.didChangeAppLifecycleState(AppLifecycleState.hidden);
    idle.didChangeAppLifecycleState(AppLifecycleState.hidden);
    controller.lifecycleChanged(AppLifecycleState.hidden);
    await _until(() => TurnKeepAliveHold.held, reason: 'held before the cut');

    final sockets = gateway.sockets.length;
    final activations = gateway.rpcCount('session.resume');
    await gateway.sockets.last.close(1001);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    controller.reevaluate(); // main.dart wires the registry change to this
    expect(TurnKeepAliveHold.held, isTrue, reason: 'held during the cut');
    await _until(
      () => gateway.sockets.length > sockets,
      reason: 'the hold redials the cut socket',
    );
    await _until(
      () => gateway.rpcCount('session.resume') > activations,
      reason: 'the session is re-attached to the new socket',
    );
    controller.reevaluate();
    expect(TurnKeepAliveHold.held, isTrue, reason: 'held after the cut');
    expect(platform.stops, 0);
    expect(chat.isStreaming, isTrue);

    // The turn ends while the app is still away: its frames reach the
    // re-attached chat on the new socket.
    durable = _Durable.answer;
    gateway.running = false;
    gateway.event('message.complete', 2, const {'text': 'respuesta final'});
    await _until(
      () => !chat.isStreaming,
      reason: 'the turn closes in the background on the new socket',
    );
    controller.reevaluate();
    await _until(() => !TurnKeepAliveHold.held, reason: 'released after it');
    controller.lifecycleChanged(AppLifecycleState.resumed);
    chat.didChangeAppLifecycleState(AppLifecycleState.resumed);
    idle.didChangeAppLifecycleState(AppLifecycleState.resumed);
  });

  // REVISION-4 D: main.dart's keep-alive controller sees `resumed` before
  // the chat does (it observes the binding first) and ends the hold; the
  // chat, still backgrounded for a moment, must not suspend the socket's
  // redial then: a redial in flight would fail with a spurious
  // connectionLost right as the app comes back.
  test('the hold ending on resume before the chat sees it does not fail the '
      'redial', () async {
    addTearDown(TurnKeepAliveHold.resetForTesting);
    final binding = WidgetsBinding.instance;
    final releaser = _ReleaseHoldOnResume();
    binding.addObserver(releaser);
    addTearDown(() => binding.removeObserver(releaser));
    // The releaser must run before the chat: re-register the chat after it.
    await open();
    binding.removeObserver(chat);
    binding.addObserver(chat);
    await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []);
    await _until(() => gateway.rpcCount('prompt.submit') == 1);
    gateway.running = true;
    gateway.event('message.start', 1, const {});
    await _until(() => chat.isStreaming);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    TurnKeepAliveHold.held = true;
    await gateway.sockets.last.close(1001);
    await _until(() => !client.isConnected, reason: 'socket noticed');
    Object? redialError;
    final redial = client.connect().then<void>(
      (_) {},
      onError: (Object error) => redialError = error,
    );
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await redial.timeout(const Duration(seconds: 10), onTimeout: () {});
    expect(
      redialError,
      isNull,
      reason: 'no spurious connectionLost from a suspend on the way back',
    );
  });

  test('a real socket drop still schedules the recovery (loss path)', () async {
    await open();
    await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []);
    await _until(() => gateway.rpcCount('prompt.submit') == 1);
    durable = _Durable.prompt;
    gateway.running = true;
    gateway.event('message.start', 1, const {});
    gateway.event('message.delta', 2, const {'text': 'respuesta '});
    await _until(() => chat.assistantContent.contains('respuesta'));
    final resumes = gateway.rpcCount('session.resume');

    await gateway.sockets.last.close(1001);
    await _until(
      () =>
          logs.any((l) => l.contains('recovery scheduled reason=transport')) &&
          gateway.rpcCount('session.resume') > resumes,
      reason: 'a real cut recovers through session.resume as before',
    );
    // conn-registry E1: a real cut is a redial, never a red «offline» before
    // the first attempt (Desktop: use-statusbar-items.tsx:376-407).
    expect(transport, contains(ChatTransportState.reconnecting));
    expect(transport, isNot(contains(ChatTransportState.offline)));
  });
}
