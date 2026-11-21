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
import 'support/test_api_client.dart';

/// Review A1: the stamped-reply cursor across a REAL socket
/// cut + `session.resume` recovery with the turn still running (not the
/// synthetic messagesHydrated control). Hermes 0.23.1 `inflight.assistant`
/// is every delta of the turn appended (tui_gateway/session_history.py
/// _append_inflight_delta), so in segment 0 it is exactly that segment's
/// text. Whatever the server re-sends or replays after the recovery, each
/// chunk must be on screen exactly once.
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
                ? {'user': 'hola', 'assistant': inflightAssistant}
                : null,
          },
          'session.activate' => {
            'session_id': 'runtime-1',
            'stored_session_id': 'stored-1',
            'running': running,
            'status': running ? 'working' : 'idle',
            'inflight': running
                ? {'user': 'hola', 'assistant': inflightAssistant}
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
  String inflightAssistant = '';

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

  /// A frame the server sent while the client was cut: in the replay ring,
  /// never delivered on the old socket.
  void lost(String type, int seq, Map<String, dynamic> payload) => ring.add({
    'type': type,
    'session_id': 'runtime-1',
    'seq': seq,
    'payload': payload,
  });

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


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late _Gateway gateway;
  late SharedGatewayPool pool;
  late ActiveChatService service;
  late ActiveChat chat;
  final logs = <String>[];
  late DebugPrintCallback originalDebugPrint;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
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
      sharedChatGatewayFactory: (connection) => TuiGatewayClient(
        connection,
        dashboard: _Dashboard(),
        heartbeatInterval: const Duration(hours: 1),
        heartbeatDeadline: const Duration(hours: 2),
        fanoutInactivityDeadline: const Duration(seconds: 15),
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
      id: 'conn-a1',
      kind: InstanceKind.homelab,
      label: 'A1',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'unused',
      dashboardUrl: 'http://127.0.0.1:${gateway.server.port}',
    );
    chat = service.attach(
      connection: connection,
      sessionId: 'stored-1',
      sessionTitle: 'A1',
      sessionProfile: 'default',
      api: testApiClient(
        baseUrl: 'http://127.0.0.1:1',
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      ),
      storedMessageLoader: (_, _) async => [
        {'id': 11, 'role': 'user', 'content': 'hola', 'timestamp': 100.0},
      ],
      attachDesktopRuntimeOnLoad: true,
      allowUnownedDesktopSnapshotForTesting: true,
      disableForegroundKeepAlive: true,
    );
    await chat.loadMessages();
    await _until(() => chat.desktopRuntimeSessionId == 'runtime-1');
  }

  Map<String, dynamic> delta(String text, int offset) => {
    'text': text,
    'turn_id': 'turn-a1',
    'segment': 0,
    'offset': offset,
  };

  /// Every assistant row on screen, joined.
  String shown() => chat.messages
      .where((row) => row['role'] == 'assistant')
      .map((row) => '${row['content'] ?? ''}')
      .join('\n');

  int count(String token) => token.allMatches(shown()).length;

  /// A running turn that streamed [applied]; then a real cut, the server's
  /// inflight being [inflight], and the recovery through session.resume.
  Future<int> streamThenCut(
    List<String> applied,
    String inflight, {
    List<String> lostInCut = const [],
    List<(String, Map<String, dynamic>)> lostEvents = const [],
  }) async {
    await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []);
    await _until(() => gateway.rpcCount('prompt.submit') == 1);
    gateway.running = true;
    gateway.event('message.start', 1, const {'turn_id': 'turn-a1'});
    var offset = 0;
    var seq = 2;
    for (final text in applied) {
      gateway.event('message.delta', seq++, delta(text, offset));
      offset += text.length;
    }
    await _until(
      () => shown().contains(applied.last.trim()),
      reason: 'live text shown: ${shown()}',
    );
    for (final text in lostInCut) {
      gateway.lost('message.delta', seq++, delta(text, offset));
      offset += text.length;
    }
    for (final (type, payload) in lostEvents) {
      gateway.lost(type, seq++, payload);
    }
    gateway.inflightAssistant = inflight;
    final resumes = gateway.rpcCount('session.resume');
    final sockets = gateway.sockets.length;
    await gateway.sockets.last.close(1001);
    await _until(
      () =>
          gateway.rpcCount('session.resume') > resumes &&
          gateway.sockets.length > sockets &&
          logs.any((l) => l.contains('snapshot recovery converged')),
      reason: 'recovered through session.resume on a new socket',
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return seq;
  }

  // A1-1 of the review (a snapshot BEHIND what was painted) is not written as
  // a test: Hermes 0.23.1 appends every delta to `inflight` under the
  // history lock BEFORE it emits the frame (tui_gateway/prompt_turn.py
  // _emit_delta, 777-786), so a snapshot of the same turn always holds at
  // least what this client painted. Run r4red/r4green1 (2026-11-14) tried it
  // anyway: with that impossible input the recovery projection keeps the
  // live row next to the snapshot row with or without the cursor fix (sealed
  // lib: «ZQXa» + «ZQXa ZQXb»), so it measures the projection, not A.

  test('[CONTROL A1-2] snapshot with everything, the server re-sends it '
      'all: each chunk once', () async {
    await open();
    final seq = await streamThenCut(['ZQXa ', 'ZQXb '], 'ZQXa ZQXb ');
    gateway.event('message.delta', seq, delta('ZQXa ', 0));
    gateway.event('message.delta', seq + 1, delta('ZQXb ', 5));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(count('ZQXa'), 1, reason: shown());
    expect(count('ZQXb'), 1, reason: shown());
  });

  test('[RED A1-3] a chunk lost in the cut is in the snapshot and also '
      'replayed: shown once', () async {
    await open();
    // ZQXc was sent while the client was cut: the snapshot has it and the
    // replay ring has it too (seq 4, never delivered on the old socket).
    final seq = await streamThenCut(
      ['ZQXa ', 'ZQXb '],
      'ZQXa ZQXb ZQXc ',
      lostInCut: ['ZQXc '],
    );
    // The server re-sends it once more (superseded attempt) after the
    // recovery, contiguous with what it already sent.
    gateway.event('message.delta', seq, delta('ZQXc ', 10));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(count('ZQXc'), 1, reason: shown());
  });

  test('a mixture-of-agents reference sent during the cut is shown after '
      'the recovery: the snapshot carries no MoA block', () async {
    await open();
    await streamThenCut(
      ['ZQXa '],
      'ZQXa ',
      lostEvents: [
        (
          'moa.reference',
          {
            'turn_id': 'turn-a1',
            'label': 'Beta',
            'text': 'Beta says ZQXmoa',
            'index': 2,
            'count': 3,
          },
        ),
      ],
    );
    String reasoning() => chat.messages
        .map((row) => '${row['reasoning'] ?? ''}')
        .join('\n');
    await _until(
      () => reasoning().contains('Beta says ZQXmoa'),
      reason: 'reasoning shown: ${reasoning()}',
    );
    expect(reasoning(), contains('Reference 2/3 — Beta'));
  });

  test('[CONTROL A1-4] new text after the recovery is applied', () async {
    await open();
    final seq = await streamThenCut(['ZQXa '], 'ZQXa ');
    gateway.event('message.delta', seq, delta('ZQXd', 5));
    await _until(() => shown().contains('ZQXd'), reason: shown());
    expect(count('ZQXa'), 1, reason: shown());
    expect(count('ZQXd'), 1, reason: shown());
  });
}
