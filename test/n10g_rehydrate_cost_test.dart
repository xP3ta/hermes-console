import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/transcript_rehydrate_cost.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

/// N10g: a recovery that changes nothing must not rebuild the transcript.
/// Unchanged rows keep their identity (so list entries, sticky index, anchors
/// and artifact fingerprints survive) and large REST bodies decode off the
/// main isolate.
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

List<Map<String, dynamic>> _transcript(int pairs) => [
  for (var i = 0; i < pairs; i++) ...[
    {
      'id': 1000 + i * 2,
      'role': 'user',
      'content': 'pregunta $i',
      'timestamp': 100.0 + i * 2,
    },
    {
      'id': 1001 + i * 2,
      'role': 'assistant',
      // A few replies are 40-60 KB like the ones on the 9605 trace.
      'content': i % 40 == 0 ? 'x' * (40 * 1024 + i) : 'respuesta $i',
      'timestamp': 101.0 + i * 2,
    },
  ],
];

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
      ),
    );
  });

  tearDown(() async {
    debugPrint = originalDebugPrint;
    service.dispose();
    await pool.closeAll();
    await gateway.server.close(force: true);
  });

  test('a recovery that changes nothing keeps the identity of all 250 rows '
      'and the same transcript', () async {
    final stored = _transcript(125);
    final connection = SavedConnection(
      id: 'conn-n10g',
      kind: InstanceKind.homelab,
      label: 'N10g',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'unused',
      dashboardUrl: 'http://127.0.0.1:${gateway.server.port}',
    );
    chat = service.attach(
      connection: connection,
      sessionId: 'stored-1',
      sessionTitle: 'N10g',
      sessionProfile: 'default',
      api: ApiClient(
        baseUrl: 'http://127.0.0.1:1',
        apiKey: 'unused',
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      ),
      storedMessageLoader: (_, _) async => [
        for (final m in stored) Map<String, dynamic>.from(m),
      ],
      attachDesktopRuntimeOnLoad: true,
      allowUnownedDesktopSnapshotForTesting: true,
      disableForegroundKeepAlive: true,
    );
    await chat.loadMessages();
    await _until(() => chat.desktopRuntimeSessionId == 'runtime-1');
    final before = chat.messages;
    expect(before.length, greaterThanOrEqualTo(250));
    final beforeJson = jsonEncode(before);

    // A turn in flight, then a real cut: the recovery re-reads and re-projects
    // the whole transcript although nothing in the 250 old rows changed.
    await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []);
    await _until(() => gateway.rpcCount('prompt.submit') == 1);
    gateway.running = true;
    gateway.event('message.start', 1, const {});
    gateway.event('message.delta', 2, const {'text': 'respuesta '});
    await _until(() => chat.assistantContent.contains('respuesta'));
    final resumes = gateway.rpcCount('session.resume');

    await gateway.sockets.last.close(1001);
    await _until(
      () =>
          logs.any((l) => l.contains('recovery scheduled')) &&
          gateway.rpcCount('session.resume') > resumes,
      reason: 'a cut socket recovers through session.resume',
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    final after = chat.messages;

    // chat.messages is newest-first: the live turn is added at the front and
    // the 250 old rows are the tail, in the same order.
    expect(after.length, greaterThan(before.length));
    final tail = after.sublist(after.length - before.length);
    expect(
      jsonEncode(tail).hashCode,
      beforeJson.hashCode,
      reason: 'same transcript, same order, no loss or duplicates',
    );
    var replaced = 0;
    for (var i = 0; i < before.length; i++) {
      if (!identical(before[i], tail[i])) replaced++;
    }
    expect(replaced, 0, reason: 'unchanged rows keep their identity');
  });

  test('a REST body above 64 KB decodes off the main isolate, a small one '
      'inline', () async {
    final big = jsonEncode({'data': _transcript(60)});
    final small = jsonEncode({'data': _transcript(2)});
    expect(big.length, greaterThan(kJsonDecodeOffMainBytes));
    final paths = <bool>[];
    final decodedBig = await decodeJsonOffMain(big, onPath: paths.add);
    final decodedSmall = await decodeJsonOffMain(small, onPath: paths.add);
    expect(paths, [true, false]);
    expect(decodedBig, jsonDecode(big));
    expect(decodedSmall, jsonDecode(small));
  });

  test('the Dashboard read of a transcript page above 64 KB decodes off the '
      'main isolate', () async {
    final big = jsonEncode({'messages': _transcript(60)});
    final paths = <bool>[];
    debugJsonDecodePathObserver = paths.add;
    addTearDown(() => debugJsonDecodePathObserver = null);
    final dashboard = DashboardClient(
      host: '127.0.0.1',
      manualToken: 'dashboard-token',
      httpClientOverride: MockClient(
        (request) async => http.Response(
          big,
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    final data = await dashboard.apiGet('sessions/stored-1/messages');
    expect((data['messages'] as List).length, 120);
    expect(paths, [
      true,
    ], reason: 'one large body, decoded off the main isolate');
  });
}
