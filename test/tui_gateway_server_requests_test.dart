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

  _Gateway._(this.server) {
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      if (sendReadyImmediately) sendReady(socket);
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        frames.add(frame);
        _frames.add(frame);
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

Future<(TuiGatewayClient, List<TuiGatewayEvent>)> _connect(
  _Gateway gateway,
) async {
  final client = _clientFor(gateway);
  final events = <TuiGatewayEvent>[];
  client.events.listen(events.add);
  await client.resumeExisting('stored-1');
  return (client, events);
}

Future<TuiGatewayEvent> _eventOfType(
  List<TuiGatewayEvent> events,
  String type,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (DateTime.now().isBefore(deadline)) {
    for (final event in events) {
      if (event.type == type) return event;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('no $type event; got ${events.map((e) => e.type).toList()}');
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

void main() {
  late _Gateway gateway;

  setUp(() async => gateway = await _Gateway.start());
  tearDown(() => gateway.close());

  test('advertises server requests only after ready without blocking RPCs', () async {
    gateway.sendReadyImmediately = false;
    gateway.answerClientCapabilities = false;
    final client = _clientFor(gateway);

    final connecting = client.connect();
    await _waitUntil(() => gateway.sockets.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(gateway.frames, isEmpty);

    gateway.sendReady();
    await connecting.timeout(const Duration(seconds: 1));
    await _waitUntil(
      () => gateway.rpcCalls('client.capabilities').isNotEmpty,
    );
    expect(gateway.rpcCalls('client.capabilities').single['params'], {
      'server_requests': true,
    });

    final resumed = await client
        .resumeExisting('stored-1')
        .timeout(const Duration(seconds: 1));
    expect(resumed.runtimeSessionId, 'runtime-1');
  });

  test('change_events stays off when gateway.ready does not advertise it', () async {
    final client = _clientFor(gateway);
    await client.connect();
    expect(client.changeEventsAvailable, isFalse);
    await _waitUntil(
      () => gateway.rpcCalls('client.capabilities').isNotEmpty,
    );
  });

  test('records gateway.ready change_events for the connection', () async {
    gateway.readyPayload = {'change_events': true};
    final client = _clientFor(gateway);
    await client.connect();
    expect(client.changeEventsAvailable, isTrue);
    await _waitUntil(
      () => gateway.rpcCalls('client.capabilities').isNotEmpty,
    );
  });

  test('advertises again after reconnect', () async {
    final client = _clientFor(gateway);
    await client.connect();
    await _waitUntil(
      () => gateway.rpcCalls('client.capabilities').length == 1,
    );

    await gateway.sockets.single.close();
    await _waitUntil(() => !client.isConnected);
    await client.connect();
    await _waitUntil(
      () => gateway.rpcCalls('client.capabilities').length == 2,
    );

    expect(gateway.sockets, hasLength(2));
  });

  test('older backend rejection does not break the connection', () async {
    gateway.rejectClientCapabilities = true;
    final client = _clientFor(gateway);

    await client.connect();
    await _waitUntil(
      () => gateway.rpcCalls('client.capabilities').isNotEmpty,
    );
    final resumed = await client.resumeExisting('stored-1');

    expect(resumed.runtimeSessionId, 'runtime-1');
    expect(client.isConnected, isTrue);
    expect(gateway.sockets, hasLength(1));
  });

  test('fake gateway prompt reaches ActiveChat and answers on its request id', () async {
    final connection = _connectionFor(gateway);
    final client = _clientFor(gateway);
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: connection,
      sessionId: 'stored-1',
      sessionTitle: 'Server request integration',
      notifications: null,
      onTerminal: () {},
      api: ApiClient(
        baseUrl: connection.baseUrl,
        apiKey: connection.apiKey,
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      ),
      desktopGateway: client,
      allowUnownedDesktopSnapshotForTesting: true,
    );
    addTearDown(chat.dispose);

    await chat.loadMessages();
    gateway.pushServerRequest('srq-chat-clarify', 'clarify', {
      'question': 'Continue?',
      'choices': ['yes', 'no'],
    });
    await _waitUntil(() => chat.pendingInteractivePrompt != null);

    final prompt = chat.pendingInteractivePrompt!;
    expect(prompt.request, isA<ClarifyPromptRequest>());
    expect(prompt.key.requestId, 'srq-chat-clarify');
    await chat.respondToClarify(prompt.key, 'yes');
    final answer = await gateway.nextFrame(
      (frame) => frame['id'] == 'srq-chat-clarify',
    );
    expect(answer['result'], {'answer': 'yes'});
    expect(chat.pendingInteractivePrompt, isNull);

    await client.resumeExisting('stored-1');
    expect(client.isConnected, isTrue);
    expect(gateway.sockets, hasLength(1));
  });

  test(
    'clarify request surfaces as clarify.request and is answered on the frame',
    () async {
      final (client, events) = await _connect(gateway);
      gateway.pushServerRequest('srq-clarify0001', 'clarify', {
        'question': '¿Qué color?',
        'choices': ['rojo', 'azul'],
      });

      final event = await _eventOfType(events, 'clarify.request');
      expect(event.sessionId, 'runtime-1');
      expect(event.payload['request_id'], 'srq-clarify0001');
      expect(event.payload['question'], '¿Qué color?');
      expect(event.payload['choices'], ['rojo', 'azul']);
      expect(event.payload.containsKey('session_id'), isFalse);
      expect(
        InteractivePromptRequest.fromGatewayEvent(
          type: event.type,
          runtimeSessionId: event.sessionId,
          payload: event.payload,
        ),
        isA<ClarifyPromptRequest>(),
      );

      final response = await client.respondToClarify('srq-clarify0001', 'rojo');
      expect(response.status, DesktopPromptResponseStatus.ok);
      final answer = await gateway.nextFrame(
        (frame) => frame['id'] == 'srq-clarify0001',
      );
      expect(answer, {
        'jsonrpc': '2.0',
        'id': 'srq-clarify0001',
        'result': {'answer': 'rojo'},
      });
      expect(gateway.rpcCalls('clarify.respond'), isEmpty);

      // The transport survived: same socket, and RPCs still flow.
      await client.resumeExisting('stored-1');
      expect(gateway.sockets, hasLength(1));
    },
  );

  test(
    'approval request keeps the queue request_id and answers on the frame',
    () async {
      final (client, events) = await _connect(gateway);
      gateway.pushServerRequest('srq-approval001', 'approval', {
        'request_id': 'apr-1',
        'command': 'rm -rf build',
        'choices': ['once', 'session', 'always', 'deny'],
      });

      final event = await _eventOfType(events, 'approval.request');
      expect(event.payload['request_id'], 'apr-1');
      expect(event.payload['command'], 'rm -rf build');

      final result = await client.resolveApprovalChecked(
        'runtime-1',
        'once',
        requestId: 'apr-1',
      );
      expect(result.resolved, 1);
      final answer = await gateway.nextFrame(
        (frame) => frame['id'] == 'srq-approval001',
      );
      expect(answer['result'], {'choice': 'once'});
      expect(gateway.rpcCalls('approval.respond'), isEmpty);
    },
  );

  test('approve-all without a request id answers the open approval', () async {
    final (client, events) = await _connect(gateway);
    gateway.pushServerRequest('srq-approval002', 'approval', {
      'request_id': 'apr-2',
      'command': 'git push',
    });
    await _eventOfType(events, 'approval.request');

    await client.resolveApproval('runtime-1', 'session', resolveAll: true);
    final answer = await gateway.nextFrame(
      (frame) => frame['id'] == 'srq-approval002',
    );
    expect(answer['result'], {'choice': 'session', 'all': true});
    expect(gateway.rpcCalls('approval.respond'), isEmpty);
  });

  test('sudo, secret, and terminal.read answer under value', () async {
    final (client, events) = await _connect(gateway);
    gateway.pushServerRequest('srq-sudo00000001', 'sudo', {});
    gateway.pushServerRequest('srq-secret000001', 'secret', {
      'env_var': 'TEST_TOKEN',
      'prompt': 'Token',
    });
    gateway.pushServerRequest('srq-term00000001', 'terminal.read', {
      'start': 0,
      'count': 20,
    });
    await _eventOfType(events, 'sudo.request');
    await _eventOfType(events, 'secret.request');
    final read = await _eventOfType(events, 'terminal.read.request');
    expect(read.payload['request_id'], 'srq-term00000001');

    final sudo = await client.respondToSudo(
      'srq-sudo00000001',
      EphemeralSensitiveValue('sudo-test-value'),
    );
    expect(sudo.status, DesktopPromptResponseStatus.ok);
    final sudoAnswer = await gateway.nextFrame(
      (frame) => frame['id'] == 'srq-sudo00000001',
    );
    expect(sudoAnswer['result'], {'value': 'sudo-test-value'});
    expect(gateway.rpcCalls('sudo.respond'), isEmpty);

    final secret = await client.respondToSecret(
      'srq-secret000001',
      EphemeralSensitiveValue('secret-test-value'),
    );
    expect(secret.status, DesktopPromptResponseStatus.ok);
    final secretAnswer = await gateway.nextFrame(
      (frame) => frame['id'] == 'srq-secret000001',
    );
    expect(secretAnswer['result'], {'value': 'secret-test-value'});
    expect(gateway.rpcCalls('secret.respond'), isEmpty);

    await client.respondToTerminalRead('srq-term00000001');
    final readAnswer = await gateway.nextFrame(
      (frame) => frame['id'] == 'srq-term00000001',
    );
    expect(readAnswer['result'], {'value': ''});
    expect(gateway.rpcCalls('terminal.read.respond'), isEmpty);
  });

  test(
    'request.cancel becomes the legacy expiry and closes the request',
    () async {
      final (client, events) = await _connect(gateway);
      gateway.pushServerRequest('srq-clarify0002', 'clarify', {
        'question': '¿Seguimos?',
      });
      gateway.pushServerRequest('srq-approval003', 'approval', {
        'request_id': 'apr-3',
        'command': 'ls',
      });
      await _eventOfType(events, 'clarify.request');
      await _eventOfType(events, 'approval.request');

      gateway.pushSessionEvent('request.cancel', {
        'id': 'srq-clarify0002',
        'method': 'clarify',
        'reason': 'timeout',
      });
      gateway.pushSessionEvent('request.cancel', {
        'id': 'srq-approval003',
        'method': 'approval',
        'reason': 'interrupted',
      });

      final expire = await _eventOfType(events, 'clarify.expire');
      expect(expire.payload['request_id'], 'srq-clarify0002');
      final responded = await _eventOfType(events, 'approval.responded');
      expect(responded.payload['request_id'], 'apr-3');
      expect(events.where((e) => e.type == 'request.cancel'), isEmpty);

      // Nothing is open any more: a late answer takes the compat RPC path
      // instead of writing an orphan response frame.
      await client.respondToClarify('srq-clarify0002', 'sí');
      expect(gateway.rpcCalls('clarify.respond'), hasLength(1));
      expect(
        gateway.frames.where(
          (frame) =>
              frame['id'] == 'srq-clarify0002' && frame['method'] == null,
        ),
        isEmpty,
      );
    },
  );

  test(
    'open_requests on session.resume are re-delivered and batch answers lock',
    () async {
      gateway.resumeResult = (_) => {
        'session_id': 'runtime-1',
        'stored_session_id': 'stored-1',
        'open_requests': [
          {
            'id': 'srq-batch0000001',
            'method': 'clarify',
            'params': {
              'session_id': 'runtime-1',
              'questions': [
                {
                  'qid': 'q1',
                  'question': '¿Idioma?',
                  'choices': ['es', 'en'],
                },
                {'qid': 'q2', 'question': '¿Tema?', 'choices': <String>[]},
              ],
              'answers': {'q1': 'es'},
            },
          },
          {'id': 'not-a-request', 'params': <String, dynamic>{}},
        ],
      };
      final (client, events) = await _connect(gateway);

      final event = await _eventOfType(events, 'clarify.request');
      expect(event.payload['request_id'], 'srq-batch0000001');
      final request =
          InteractivePromptRequest.fromGatewayEvent(
                type: event.type,
                runtimeSessionId: event.sessionId,
                payload: event.payload,
              )
              as ClarifyPromptRequest;
      expect(request.isBatch, isTrue);
      expect(request.lockedAnswers, {'q1': 'es'});

      final locked = await client.respondToClarify(
        'srq-batch0000001',
        'oscuro',
        questionId: 'q2',
      );
      expect(locked.status, DesktopPromptResponseStatus.ok);
      final lock = gateway.rpcCalls('clarify.lock').single;
      expect(lock['params'], {
        'request_id': 'srq-batch0000001',
        'question_id': 'q2',
        'answer': 'oscuro',
      });
      expect(gateway.rpcCalls('clarify.respond'), isEmpty);
    },
  );

  test(
    'unsupported request kinds fail with -32601 without retiring the socket',
    () async {
      final (client, events) = await _connect(gateway);
      gateway.pushServerRequest('srq-tour00000001', 'tour', {'step': 1});
      gateway.push({
        'jsonrpc': '2.0',
        'id': 'srq-nosession001',
        'method': 'clarify',
        'params': {'question': 'sin sesión'},
      });

      final tour = await gateway.nextFrame(
        (frame) => frame['id'] == 'srq-tour00000001',
      );
      expect((tour['error'] as Map)['code'], -32601);
      final noSession = await gateway.nextFrame(
        (frame) => frame['id'] == 'srq-nosession001',
      );
      expect((noSession['error'] as Map)['code'], -32602);
      expect(events.where((e) => e.type.endsWith('.request')), isEmpty);

      await client.resumeExisting('stored-1');
      expect(gateway.sockets, hasLength(1));
    },
  );

  test(
    'vault prompts surface the continuation card and stay unanswered',
    () async {
      final (_, events) = await _connect(gateway);
      gateway.pushServerRequest('srq-vault0000001', 'vault.unlock_prompt', {
        'backend': 'bitwarden',
        'display_name': 'Bitwarden',
      });
      final event = await _eventOfType(events, 'vault.unlock.request');
      expect(event.payload['request_id'], 'srq-vault0000001');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        gateway.frames.where((frame) => frame['id'] == 'srq-vault0000001'),
        isEmpty,
      );
    },
  );
}
