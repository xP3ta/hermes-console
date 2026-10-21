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
      api: ApiClient(
        baseUrl: 'http://127.0.0.1:1',
        apiKey: 'unused',
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
      for (var i = 0; i < 8 && chat.state != ChatPipelineState.failed; i++) {
        clock = clock.add(const Duration(seconds: 130));
        await client.debugProbeSilentFanout();
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      await _until(
        () => chat.state == ChatPipelineState.failed,
        reason: 'state=${chat.state} reads=${transcriptReads - reads}',
      );

      expect(logs.where((l) => l.contains('kind=idle_unproven')), hasLength(1));
      expect(
        transcriptReads - reads,
        lessThanOrEqualTo(3),
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
    expect(transport, contains(ChatTransportState.offline));
  });
}
