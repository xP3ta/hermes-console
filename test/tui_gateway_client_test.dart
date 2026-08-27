import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-qa',
      );
}

void main() {
  test(
    'habla el JSON-RPC oficial de Desktop y recibe eventos del mismo sid',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      final requests = <Map<String, dynamic>>[];
      var interruptedBusyReplies = 0;
      String? receivedTicket;
      final serverDone = Completer<void>();
      server.listen((request) async {
        receivedTicket = request.uri.queryParameters['ticket'];
        final socket = await WebSocketTransformer.upgrade(request);
        try {
          await for (final raw in socket) {
            final frame = jsonDecode(raw as String) as Map<String, dynamic>;
            requests.add(frame);
            final method = frame['method'] as String;
            final params = Map<String, dynamic>.from(frame['params'] as Map);
            if (method == 'prompt.submit' &&
                params['interrupted'] == true &&
                interruptedBusyReplies++ == 0) {
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': frame['id'],
                  'error': {'code': 4009, 'message': 'session busy'},
                }),
              );
              continue;
            }
            final result = switch (method) {
              'session.resume' => {'session_id': 'runtime-qa'},
              'session.steer' => {'status': 'queued'},
              'session.redirect' => {'status': 'redirected'},
              _ => <String, dynamic>{'status': 'ok'},
            };
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': result,
              }),
            );
            if (method == 'session.steer') {
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'method': 'event',
                  'params': {
                    'type': 'message.delta',
                    'payload': {'text': 'hecho'},
                  },
                }),
              );
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'method': 'event',
                  'params': {
                    'type': 'subagent.progress',
                    'payload': {'text': 'background'},
                  },
                }),
              );
            }
          }
        } finally {
          if (!serverDone.isCompleted) serverDone.complete();
        }
      });

      final connection = SavedConnection(
        id: 'conn-qa',
        label: 'QA',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      );
      final client = TuiGatewayClient(
        connection,
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);

      await client.connect();
      final binding = await client.resumeSession('stored-qa');
      await client.submitPrompt(binding.runtimeSessionId, 'pregunta');
      await client.submitInterruptedPrompt(
        binding.runtimeSessionId,
        'y también las de ayer',
      );
      final eventFuture = client.events.firstWhere(
        (event) => event.type == 'message.delta',
      );
      final subagentFuture = client.events.firstWhere(
        (event) => event.type == 'subagent.progress',
      );
      await client.steer(binding.runtimeSessionId, 'complemento');
      final redirect = await client.redirect(
        binding.runtimeSessionId,
        'corrige el cierre',
      );
      final event = await eventFuture.timeout(const Duration(seconds: 2));
      final subagent = await subagentFuture.timeout(const Duration(seconds: 2));

      expect(receivedTicket, 'ticket-qa');
      expect(binding.runtimeSessionId, 'runtime-qa');
      expect(binding.storedSessionId, 'stored-qa');
      expect(binding.created, isFalse);
      expect(redirect, DesktopRedirectDisposition.redirected);
      expect(requests.map((request) => request['method']), [
        'session.resume',
        'prompt.submit',
        'prompt.submit',
        'prompt.submit',
        'session.steer',
        'session.redirect',
      ]);
      expect(requests[0]['params'], {
        'session_id': 'stored-qa',
        'source': 'mobile',
      });
      expect(requests[1]['params'], {
        'session_id': 'runtime-qa',
        'text': 'pregunta',
      });
      expect(requests[2]['params'], {
        'session_id': 'runtime-qa',
        'text': 'y también las de ayer',
        'interrupted': true,
      });
      expect(requests[3]['params'], {
        'session_id': 'runtime-qa',
        'text': 'y también las de ayer',
        'interrupted': true,
      });
      expect(requests[4]['params'], {
        'session_id': 'runtime-qa',
        'text': 'complemento',
      });
      expect(requests[5]['params'], {
        'session_id': 'runtime-qa',
        'text': 'corrige el cierre',
      });
      expect(event.sessionId, 'runtime-qa');
      expect(event.payload['text'], 'hecho');
      expect(subagent.sessionId, isEmpty);

      await client.close();
      await serverDone.future.timeout(const Duration(seconds: 2));
    },
  );

  test(
    'idempotencia opcional usa params exactos y valida ACK/status',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final requests = <Map<String, dynamic>>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          requests.add(frame);
          final method = frame['method'] as String;
          final result = switch (method) {
            'session.resume' => {'session_id': 'runtime-modern'},
            'prompt.submit' => {
              'accepted': true,
              'client_turn_id': 'client-opaque',
              'server_turn_id': 'server-opaque',
              'state': 'accepted',
              'duplicate': false,
            },
            'turn.status' => {
              'known': true,
              'client_turn_id': 'client-opaque',
              'server_turn_id': 'server-opaque',
              'state': 'running',
            },
            _ => <String, dynamic>{},
          };
          socket.add(
            jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
          );
        }
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-modern-rpc',
          label: 'Modern RPC',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'gateway-key',
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);

      final binding = await client.resumeSession('stored-modern');
      final ack = await client.submitPromptIdempotent(
        binding.runtimeSessionId,
        'pregunta moderna',
        'client-opaque',
      );
      final status = await client.getTurnStatus(
        binding.runtimeSessionId,
        'client-opaque',
      );

      expect(requests.map((request) => request['method']), [
        'session.resume',
        'prompt.submit',
        'turn.status',
      ]);
      expect(requests[1]['params'], {
        'session_id': 'runtime-modern',
        'text': 'pregunta moderna',
        'client_turn_id': 'client-opaque',
      });
      expect(requests[2]['params'], {
        'session_id': 'runtime-modern',
        'client_turn_id': 'client-opaque',
      });
      expect(ack.serverTurnId, 'server-opaque');
      expect(ack.duplicate, isFalse);
      expect(status.known, isTrue);
      expect(status.state, DesktopTurnState.running);
    },
  );

  test(
    'no ancla eventos legacy tras ligar dos runtimes en el mismo socket',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      var resumeCalls = 0;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          final method = frame['method'] as String;
          final result = method == 'session.resume'
              ? {'session_id': 'runtime-${++resumeCalls}'}
              : <String, dynamic>{'status': 'queued'};
          socket.add(
            jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
          );
          if (method == 'session.steer') {
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'method': 'event',
                'params': {
                  'type': 'message.delta',
                  'payload': {'text': 'ambiguo'},
                },
              }),
            );
          }
        }
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-ambiguous-legacy',
          label: 'Ambiguous legacy',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'gateway-key',
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);

      final first = await client.resumeExisting('stored-1');
      final second = await client.resumeExisting('stored-2');
      final eventFuture = client.events.firstWhere(
        (event) => event.type == 'message.delta',
      );
      await client.steer(second.runtimeSessionId, 'continúa');
      final event = await eventFuture.timeout(const Duration(seconds: 2));

      expect(first.runtimeSessionId, 'runtime-1');
      expect(second.runtimeSessionId, 'runtime-2');
      expect(event.sessionId, isEmpty);
    },
  );

  test(
    'parsea el snapshot completo de session.resume de Hermes 0.19',
    () async {
      // Forma emitida por `_live_session_payload` + `_session_info` en el tag
      // v0.19.0 (commit 3ef6bbd201263d354fd83ec55b3c306ded2eb72a).
      final fixture = Map<String, dynamic>.from(
        jsonDecode(
              File(
                'test/fixtures/hermes_agent_019_session_resume.json',
              ).readAsStringSync(),
            )
            as Map,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final requests = <Map<String, dynamic>>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          requests.add(frame);
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': fixture,
            }),
          );
        }
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-snapshot-019',
          label: 'Snapshot 0.19',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'gateway-key',
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);

      expect(client, isA<HermesDesktopSessionLifecycleGateway>());
      final snapshot = await client.resumeExisting(
        '20260720_101500_fixture',
        profile: 'default',
        omitMessages: true,
      );

      expect(snapshot.runtimeSessionId, 'runtime019');
      expect(snapshot.storedSessionId, '20260720_101500_fixture');
      expect(snapshot.created, isFalse);
      expect(snapshot.messageCount, 3);
      expect(snapshot.messages, hasLength(3));
      expect(snapshot.messagesProvided, isTrue);
      expect(snapshot.messages.first.role, DesktopSessionMessageRole.user);
      expect(snapshot.messages.first.text, 'hola desde el móvil');
      expect(snapshot.messages[1].reasoning, 'resumen del razonamiento');
      expect(snapshot.messages[2].toolName, 'web_search');
      expect(snapshot.messages[2].toolCallId, isNull);
      expect(snapshot.inflight?.assistant, 'respuesta parcial');
      expect(snapshot.inflight?.streaming, isTrue);
      expect(snapshot.queued?.user, 'y añade las fuentes');
      expect(snapshot.running, isTrue);
      expect(snapshot.status, 'working');
      expect(snapshot.startedAt?.millisecondsSinceEpoch, 1784542500250);
      expect(snapshot.info.model, 'gpt-5.5-codex');
      expect(snapshot.info.provider, 'openai-codex');
      expect(snapshot.info.reasoningEffort, 'high');
      expect(snapshot.info.fast, isTrue);
      expect(snapshot.info.desktopContract, 4);
      expect(snapshot.info.approvalMode, 'manual');
      expect(snapshot.info.toolCount, 1);
      expect(snapshot.info.skillCount, 1);
      expect(snapshot.info.mcpServerCount, 0);
      expect(snapshot.info.project?['slug'], 'hermes-mobile');
      expect(snapshot.info.usage?.total, 1500);
      expect(snapshot.info.usage?.contextPercent, 1.25);
      expect(snapshot.info.raw, isNot(contains('system_prompt')));
      expect(snapshot.raw, isNot(contains('messages')));
      expect(snapshot.raw, isNot(contains('info')));
      expect(requests.map((request) => request['method']), ['session.resume']);
      expect(requests.single['params'], {
        'session_id': '20260720_101500_fixture',
        'source': 'mobile',
        'profile': 'default',
        'omit_messages': true,
      });
    },
  );

  test(
    'resumeExisting nunca crea si el servidor no encuentra la sesión',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final requests = <Map<String, dynamic>>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          requests.add(frame);
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              if (frame['method'] == 'session.resume')
                'error': {'code': 4007, 'message': 'session not found'}
              else
                'result': {
                  'session_id': 'must-not-exist',
                  'stored_session_id': 'must-not-exist',
                },
            }),
          );
        }
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-resume-only',
          label: 'Resume only',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'gateway-key',
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);

      await expectLater(
        client.resumeExisting('missing-session'),
        throwsA(
          isA<TuiGatewayRpcError>()
              .having((error) => error.method, 'method', 'session.resume')
              .having((error) => error.code, 'code', 4007),
        ),
      );

      expect(requests.map((request) => request['method']), ['session.resume']);
    },
  );

  test('resumed booleano nunca se convierte en identidad persistida', () {
    final snapshot = DesktopSessionSnapshot.fromJson(
      {
        'session_id': 'runtime-safe',
        'stored_session_id': 42,
        'session_key': false,
        'resumed': true,
      },
      requestedStoredSessionId: 'stored-safe',
      created: false,
      method: 'session.resume',
    );

    expect(snapshot.runtimeSessionId, 'runtime-safe');
    expect(snapshot.storedSessionId, 'stored-safe');
    expect(snapshot.storedSessionId, isNot('true'));
  });

  test('parser rechaza identidades runtime o stored que no sean strings', () {
    expect(
      () => DesktopSessionSnapshot.fromJson(
        {'session_id': true, 'session_key': 'stored-safe'},
        requestedStoredSessionId: 'stored-safe',
        created: false,
        method: 'session.resume',
      ),
      throwsFormatException,
    );
    expect(
      () => DesktopSessionSnapshot.fromJson(
        {'session_id': 'runtime-safe', 'stored_session_id': 42},
        requestedStoredSessionId: '',
        created: true,
        method: 'session.create',
      ),
      throwsFormatException,
    );
  });

  test('parser de snapshot degrada campos malformados sin inventar estado', () {
    final snapshot = DesktopSessionSnapshot.fromJson(
      {
        'session_id': 'runtime-defensive',
        'session_key': 'stored-defensive',
        'message_count': -3,
        'messages': 'not-a-list',
        'inflight': ['not-a-map'],
        'queued': true,
        'running': 'yes',
        'started_at': 'yesterday',
        'status': 200,
        'info': {
          'fast': 'yes',
          'desktop_contract': -1,
          'tools': ['not-a-map'],
          'usage': {'input': -10, 'total': 'many', 'cost_usd': -2},
        },
      },
      requestedStoredSessionId: 'stored-defensive',
      created: false,
      method: 'session.resume',
    );

    expect(snapshot.messageCount, isNull);
    expect(snapshot.messages, isEmpty);
    expect(snapshot.messagesProvided, isFalse);
    expect(snapshot.inflight, isNull);
    expect(snapshot.queued, isNull);
    expect(snapshot.running, isFalse);
    expect(snapshot.startedAt, isNull);
    expect(snapshot.status, isNull);
    expect(snapshot.info.fast, isNull);
    expect(snapshot.info.desktopContract, isNull);
    expect(snapshot.info.toolCount, isNull);
    expect(snapshot.info.usage?.input, isNull);
    expect(snapshot.info.usage?.total, isNull);
    expect(snapshot.info.usage?.costUsd, isNull);
  });

  test('createForFirstSubmit crea directamente y marca el snapshot', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final requests = <Map<String, dynamic>>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        requests.add(frame);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': {
              'session_id': 'runtime-created-directly',
              'stored_session_id': 'stored-created-directly',
              'message_count': 1,
              'messages': [
                {'role': 'user', 'text': 'semilla'},
              ],
              'info': {'model': 'provider/model'},
            },
          }),
        );
      }
    });

    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-create-direct',
        label: 'Create direct',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);

    final snapshot = await client.createForFirstSubmit(
      profile: 'coding',
      model: 'provider/model',
      seedMessages: const [
        {'role': 'user', 'content': 'semilla'},
      ],
    );

    expect(snapshot.created, isTrue);
    expect(snapshot.storedSessionId, 'stored-created-directly');
    expect(requests.map((request) => request['method']), ['session.create']);
    expect(requests.single['params'], {
      'source': 'mobile',
      'profile': 'coding',
      'model': 'provider/model',
      'messages': const [
        {'role': 'user', 'content': 'semilla'},
      ],
    });
  });

  test('crea una sesión viva cuando el borrador aún no existe', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final requests = <Map<String, dynamic>>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        requests.add(frame);
        final method = frame['method'] as String;
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            if (method == 'session.resume')
              'error': {'code': 4007, 'message': 'session not found'}
            else
              'result': {
                'session_id': 'runtime-created',
                'stored_session_id': 'stored-created',
              },
          }),
        );
      }
    });

    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-create',
        label: 'Create',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);

    final binding = await client.resumeSession(
      'mobile-draft',
      // Alias del API: no debe persistirse como modelo real de la sesión.
      model: 'hermes-agent',
      seedMessages: const [
        {'role': 'user', 'content': 'anterior'},
        {'role': 'assistant', 'content': 'respuesta'},
      ],
    );

    expect(binding.runtimeSessionId, 'runtime-created');
    expect(binding.storedSessionId, 'stored-created');
    expect(binding.created, isTrue);
    expect(requests.map((request) => request['method']), [
      'session.resume',
      'session.create',
    ]);
    expect(requests[1]['params'], {
      'source': 'mobile',
      'messages': const [
        {'role': 'user', 'content': 'anterior'},
        {'role': 'assistant', 'content': 'respuesta'},
      ],
    });
  });

  test('notifica inmediatamente si un socket ya conectado se corta', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final serverSocket = Completer<WebSocket>();
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      if (!serverSocket.isCompleted) serverSocket.complete(socket);
    });

    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-drop',
        label: 'Drop',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);

    final transportError = client.events.first;
    await client.connect();
    final socket = await serverSocket.future.timeout(
      const Duration(seconds: 2),
    );
    expect(client.isConnected, isTrue);

    await socket.close();

    await expectLater(transportError, throwsA(isA<StateError>()));
    expect(client.isConnected, isFalse);
  });

  test(
    'heartbeat anunciado invalida un socket abierto pero sin respuestas',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'heartbeat': true},
            },
          }),
        );
        // Consume gateway.ping without contestar: simula una radio en agujero
        // negro que deja el TCP aparentemente abierto.
        await for (final _ in socket) {}
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-heartbeat-blackhole',
          label: 'Heartbeat blackhole',
          host: '127.0.0.1',
          port: 8642,
          apiKey: String.fromCharCodes(const [113, 97]),
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
        heartbeatInterval: const Duration(milliseconds: 10),
        heartbeatDeadline: const Duration(milliseconds: 35),
      );
      addTearDown(client.close);

      final transportError = client.events.firstWhere(
        (event) => event.type == 'never-emitted-after-heartbeat',
      );
      await client.connect();

      await expectLater(
        transportError,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('heartbeat'),
          ),
        ),
      );
      expect(client.isConnected, isFalse);
    },
  );

  test(
    'un gateway antiguo sin heartbeat anunciado permanece compatible',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final received = <Map<String, dynamic>>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
          }),
        );
        await for (final raw in socket) {
          received.add(jsonDecode(raw as String) as Map<String, dynamic>);
        }
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-no-heartbeat',
          label: 'No heartbeat',
          host: '127.0.0.1',
          port: 8642,
          apiKey: String.fromCharCodes(const [113, 97]),
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
        heartbeatInterval: const Duration(milliseconds: 10),
        heartbeatDeadline: const Duration(milliseconds: 35),
      );
      addTearDown(client.close);

      await client.connect();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(client.isConnected, isTrue);
      expect(received, isEmpty);
    },
  );

  test(
    'reintentos de loginRequired conservan el error sin reparación',
    () async {
      final gatewaySource = File(
        'lib/core/services/tui_gateway_client.dart',
      ).readAsStringSync();
      expect(gatewaySource, isNot(contains('.setDashboardCredentials(')));

      final dashboard = DashboardClient(
        host: '127.0.0.1',
        port: 1,
        httpClientOverride: MockClient((request) async {
          if (request.url.path == '/') {
            return http.Response('<form id="provider-form"></form>', 200);
          }
          return http.Response('not found', 404);
        }),
      );
      addTearDown(dashboard.close);
      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-no-repair',
          label: 'No repair',
          host: '127.0.0.1',
          port: 8642,
          apiKey: '',
          dashboardUrl: 'http://127.0.0.1:1',
        ),
        dashboard: dashboard,
      );
      addTearDown(client.close);

      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          client.connect(),
          throwsA(
            isA<DashboardAuthException>().having(
              (error) => error.code,
              'code',
              DashboardAuthFailureCode.loginRequired,
            ),
          ),
        );
      }
    },
  );

  test('envía rewind y adjuntos por los RPC nativos de Desktop', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final requests = <Map<String, dynamic>>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        requests.add(frame);
        final method = frame['method'] as String;
        final result = switch (method) {
          'session.resume' => {'session_id': 'runtime-native'},
          'image.attach_bytes' => {
            'attached': true,
            'path': '/hermes/images/test.png',
          },
          'file.attach' => {
            'attached': true,
            'path': '/workspace/.hermes/test.txt',
            'ref_text': '@file:.hermes/test.txt',
          },
          'prompt.submit' => {
            'status': 'ok',
            'survivor_user_row_ids': [11, null, 'malformed'],
          },
          _ => <String, dynamic>{'status': 'ok'},
        };
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
        );
      }
    });

    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-native',
        label: 'Native',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);

    final binding = await client.resumeSession('stored-native');
    final image = await client.attachImageBytes(
      binding.runtimeSessionId,
      filename: 'test.png',
      contentBase64: 'aW1hZ2U=',
    );
    final file = await client.attachFileBytes(
      binding.runtimeSessionId,
      filename: 'test.txt',
      mimeType: 'text/plain',
      contentBase64: 'aG9sYQ==',
    );
    await client.detachImage(binding.runtimeSessionId, image.path!);
    final rewind = await client.submitDurableRewindPrompt(
      binding.runtimeSessionId,
      'corregido',
      2,
      truncateBeforeRowId: 73,
    );
    await client.submitRewindPrompt(
      binding.runtimeSessionId,
      'primer turno',
      0,
    );

    expect(requests.map((request) => request['method']), [
      'session.resume',
      'image.attach_bytes',
      'file.attach',
      'image.detach',
      'prompt.submit',
      'prompt.submit',
    ]);
    expect(requests[1]['params'], {
      'session_id': 'runtime-native',
      'filename': 'test.png',
      'content_base64': 'aW1hZ2U=',
    });
    expect(
      requests[2]['params']['data_url'],
      'data:text/plain;base64,aG9sYQ==',
    );
    expect(file.refText, '@file:.hermes/test.txt');
    expect(rewind.survivorUserRowIds, [11, null, null]);
    expect(requests[4]['params'], {
      'session_id': 'runtime-native',
      'text': 'corregido',
      'truncate_before_row_id': 73,
      'confirm_truncate': true,
    });
    expect(requests[5]['params'], {
      'session_id': 'runtime-native',
      'text': 'primer turno',
      'truncate_before_user_ordinal': 0,
      'confirm_truncate': true,
      'confirm_empty_truncate': true,
    });
  });

  test('resuelve row_id durable con el filtro exacto de Desktop', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final requests = <Map<String, dynamic>>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        requests.add(frame);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': frame['id'],
            'result': {
              'messages': [
                {'role': 'user', 'row_id': 0, 'text': 'cero'},
                {
                  'role': 'user',
                  'row_id': 72,
                  'text': 'pregunta original',
                  'display_kind': '   ',
                },
                {'role': 'user', 'row_id': 73, 'text': ' pregunta original '},
                {'role': 'user', 'row_id': 75, 'text': 'duplicada'},
                {'role': 'user', 'row_id': 76, 'text': ' duplicada '},
                {'role': 'assistant', 'row_id': 74, 'text': 'respuesta'},
              ],
            },
          }),
        );
      }
    });

    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-history-row-id',
        label: 'History row id',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'test-key',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);

    expect(
      await client.resolveDurableUserRowId(
        'runtime-history',
        sourceText: 'pregunta original',
        expectedOrdinal: 1,
      ),
      73,
    );
    expect(
      await client.resolveDurableUserRowId(
        'runtime-history',
        sourceText: 'cero',
        expectedOrdinal: 0,
      ),
      0,
    );
    expect(
      await client.resolveDurableUserRowId(
        'runtime-history',
        sourceText: 'pregunta original',
        expectedOrdinal: 0,
      ),
      isNull,
    );
    expect(
      await client.resolveDurableUserRowId(
        'runtime-history',
        sourceText: 'duplicada',
        expectedOrdinal: 3,
      ),
      isNull,
    );
    expect(requests.map((request) => request['method']), [
      'session.history',
      'session.history',
      'session.history',
      'session.history',
    ]);
  });

  test(
    'session.compress envía el JSON-RPC exacto y parsea el resultado',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final requests = <Map<String, dynamic>>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          requests.add(frame);
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'result': {
                'status': 'compressed',
                'removed': 2,
                'before_messages': 4,
                'after_messages': 2,
                'before_tokens': 179492,
                'after_tokens': 4100,
                'summary': {'noop': false},
                'usage': {'context_used': 4100, 'context_max': 200000},
                'info': {'stored_session_id': 'stored-compressed'},
                'messages': [
                  {'role': 'user', 'content': 'Resumen'},
                  {'role': 'assistant', 'content': 'Continuación'},
                ],
              },
            }),
          );
        }
      });

      final client = TuiGatewayClient(
        SavedConnection(
          id: 'conn-compress-rpc',
          label: 'Compress RPC',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'gateway-key',
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _TicketDashboardClient(),
      );
      addTearDown(client.close);

      final focused = await client.compressSession(
        'runtime-compress',
        focusTopic: '  decisiones de release  ',
      );
      await client.compressSession('runtime-compress', focusTopic: '   ');

      expect(requests.map((request) => request['method']), [
        'session.compress',
        'session.compress',
      ]);
      expect(requests.first['params'], {
        'session_id': 'runtime-compress',
        'focus_topic': 'decisiones de release',
      });
      expect(requests.last['params'], {'session_id': 'runtime-compress'});
      expect(focused.afterMessages, 2);
      expect(focused.info.storedSessionId, 'stored-compressed');
      expect(focused.messages.last.text, 'Continuación');
    },
  );

  test('cierra un socket idle limpiamente y permite reconectar', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final sockets = <WebSocket>[];
    final firstAccepted = Completer<void>();
    final acceptedTwice = Completer<void>();
    final firstClosed = Completer<void>();
    int? firstCloseCode;
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      if (sockets.length == 1 && !firstAccepted.isCompleted) {
        firstAccepted.complete();
      }
      if (sockets.length == 2 && !acceptedTwice.isCompleted) {
        acceptedTwice.complete();
      }
      // Escuchar el stream hace que dart:io procese también el close frame.
      await for (final _ in socket) {}
      if (sockets.length == 1) {
        firstCloseCode = socket.closeCode;
        if (!firstClosed.isCompleted) firstClosed.complete();
      }
    });

    final client = TuiGatewayClient(
      SavedConnection(
        id: 'conn-idle-reconnect',
        label: 'Idle reconnect',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'gateway-key',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(client.close);

    await client.connect();
    await firstAccepted.future.timeout(const Duration(seconds: 2));
    await client.disconnectIdle();
    await firstClosed.future.timeout(const Duration(seconds: 2));
    expect(firstCloseCode, 1000);

    await client.connect();
    await acceptedTwice.future.timeout(const Duration(seconds: 2));
    expect(sockets, hasLength(2));
  });
}
