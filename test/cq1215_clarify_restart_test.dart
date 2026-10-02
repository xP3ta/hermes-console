import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';

/// Fake Hermes gateway (v7 contract) for a chat reopened after the app
/// process restarted while the agent waits on a `clarify`.
///
/// Mirrors the real server: the request is keyed by the live UI session id
/// (`server_requests.ServerRequest.sid`), `session.resume` of a still-live
/// stored session reuses that same sid (`_resume_reuse_live`), and every
/// resume/activate/events.since result carries `open_requests` built from
/// `ServerRequest.snapshot()`. The batch wire of `_clarify_block` sends
/// `"choices": null` for an open-ended question.
class _Gateway {
  final HttpServer server;
  final sockets = <WebSocket>[];
  final frames = <Map<String, dynamic>>[];
  final _frames = StreamController<Map<String, dynamic>>.broadcast();
  Map<String, dynamic> Function(Map<String, dynamic> frame) resumeResult =
      (_) => {'session_id': 'live-s', 'stored_session_id': 'stored-1'};
  Map<String, dynamic> Function(Map<String, dynamic> frame) activeListResult =
      (_) => {'sessions': <Object>[]};
  Map<String, dynamic> Function(Map<String, dynamic> frame) eventsSinceResult =
      (_) => {
        'events': <Object>[],
        'latest_seq': 0,
        'truncated': false,
        'count': 0,
      };
  final lockedAnswers = <String, String>{};

  _Gateway._(this.server) {
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      sendReady(socket);
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        frames.add(frame);
        if (!_frames.isClosed) _frames.add(frame);
        final method = frame['method'];
        if (method is! String) continue;
        if (method == 'clarify.lock') {
          final params = frame['params'] as Map<String, dynamic>;
          lockedAnswers[params['question_id'] as String] =
              params['answer'] as String;
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

  void sendReady(WebSocket socket) => socket.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
    }),
  );

  static Future<_Gateway> start() async =>
      _Gateway._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

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
        credential: 'ticket-clarify-restart',
      );
}

SavedConnection _connectionFor(_Gateway gateway) => SavedConnection(
  id: 'conn-clarify-restart',
  label: 'Clarify restart',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'unused',
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

/// A cold-started chat: a brand new client and chat with persisted state
/// only (no runtime, no cards), like the app after an update restarted it.
ActiveChat _coldChat(_Gateway gateway, TuiGatewayClient client) {
  final connection = _connectionFor(gateway);
  final chat = ActiveChat(
    compressionRestoreStore: testCompressionRestoreStore(),
    connection: connection,
    sessionId: 'stored-1',
    sessionTitle: 'Clarify restart',
    notifications: null,
    onTerminal: () {},
    api: ApiClient(
      baseUrl: connection.baseUrl,
      apiKey: connection.apiKey,
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    ),
    desktopGateway: client,
    attachDesktopRuntimeOnLoad: true,
    desktopRecoveryBackoff: const [Duration.zero],
    allowUnownedDesktopSnapshotForTesting: true,
  );
  addTearDown(chat.dispose);
  return chat;
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

/// The open request exactly as `ServerRequest.snapshot()` renders the batch
/// `clarify` of `server._clarify_block`: one open-ended question (no
/// choices → `null` on the wire) and one with choices.
Map<String, dynamic> _batchClarify(String id) => {
  'id': id,
  'method': 'clarify',
  'params': {
    'session_id': 'live-s',
    'questions': [
      {
        'qid': 'q0',
        'question': 'Que par quieres?',
        'choices': null,
        'multi_select': false,
      },
      {
        'qid': 'q1',
        'question': 'Intervalo?',
        'choices': ['1h (Recommended)', '4h'],
        'multi_select': false,
      },
    ],
  },
};

Map<String, dynamic> _waitingSnapshot({List<Object>? open}) => {
  'session_id': 'live-s',
  'stored_session_id': 'stored-1',
  'session_key': 'stored-1',
  'resumed': 'stored-1',
  'running': true,
  'status': 'waiting',
  'turn_started_at':
      DateTime.now()
          .subtract(const Duration(minutes: 33))
          .millisecondsSinceEpoch /
      1000,
  'open_requests': ?open,
};

void main() {
  late _Gateway gateway;

  setUp(() async => gateway = await _Gateway.start());
  tearDown(() => gateway.close());

  test(
    'after a cold restart the batch clarify of the reused live session '
    'renders from the resume snapshot and is answered by clarify.lock',
    () async {
      gateway.resumeResult = (_) =>
          _waitingSnapshot(open: [_batchClarify('srq-restart00001')]);
      final client = _clientFor(gateway);
      final chat = _coldChat(gateway, client);

      await chat.loadMessages();
      await _waitUntil(() => chat.desktopRuntimeSessionId == 'live-s');
      await _waitUntil(() => chat.pendingInteractivePrompt != null);
      final request =
          chat.pendingInteractivePrompt!.request! as ClarifyPromptRequest;
      expect(request.key.requestId, 'srq-restart00001');
      expect(request.questions.map((q) => q.qid), ['q0', 'q1']);
      expect(request.questions.first.choices, isEmpty);
      expect(chat.awaitsUnseenInput, isFalse);

      await chat.respondToClarifyBatch(request.key, {
        'q0': 'XBT/EUR',
        'q1': '4h',
      });
      expect(gateway.lockedAnswers, {'q0': 'XBT/EUR', 'q1': '4h'});
      final locks = gateway.rpcCalls('clarify.lock').toList();
      expect(locks.map((f) => f['params']['request_id']).toSet(), {
        'srq-restart00001',
      });
    },
  );

  test('Show question brings back the batch clarify through '
      'session.events.since on the live sid', () async {
    // The resume raced the request: waiting, no open request listed yet.
    gateway.resumeResult = (_) => _waitingSnapshot();
    gateway.eventsSinceResult = (_) => {
      'events': <Object>[],
      'latest_seq': 0,
      'truncated': false,
      'count': 0,
      'open_requests': [_batchClarify('srq-restart00002')],
    };
    final client = _clientFor(gateway);
    final chat = _coldChat(gateway, client);
    await chat.loadMessages();
    await _waitUntil(() => chat.desktopRuntimeSessionId == 'live-s');
    expect(chat.awaitsUnseenInput, isTrue);

    await chat.rehydrateOpenRequests();
    final probe = gateway.rpcCalls('session.events.since').last;
    expect(probe['params']['session_id'], 'live-s');
    expect(chat.pendingInteractivePrompt?.key.requestId, 'srq-restart00002');
    expect(chat.awaitsUnseenInput, isFalse);
    expect(chat.openRequestRecoveryFailed, isFalse);
  });

  test('Show question with nothing recoverable says so instead of a dead '
      'button, and Retry recovers once the server lists it', () async {
    gateway.resumeResult = (_) => _waitingSnapshot();
    final client = _clientFor(gateway);
    final chat = _coldChat(gateway, client);
    await chat.loadMessages();
    await _waitUntil(() => chat.desktopRuntimeSessionId == 'live-s');
    expect(chat.awaitsUnseenInput, isTrue);

    // A malformed entry is not a question either.
    gateway.eventsSinceResult = (_) => {
      'events': <Object>[],
      'open_requests': [
        {'id': 'srq-broken000001', 'method': 'clarify', 'params': 'bad'},
      ],
    };
    await chat.rehydrateOpenRequests();
    expect(chat.pendingInteractivePrompt, isNull);
    expect(chat.openRequestRecoveryFailed, isTrue);
    // The notice stays (Hermes still waits) but now in its failed form.
    expect(chat.awaitsUnseenInput, isTrue);

    gateway.eventsSinceResult = (_) => {
      'events': <Object>[],
      'open_requests': [_batchClarify('srq-restart00003')],
    };
    await chat.rehydrateOpenRequests();
    expect(chat.pendingInteractivePrompt?.key.requestId, 'srq-restart00003');
    expect(chat.openRequestRecoveryFailed, isFalse);
  });
}
