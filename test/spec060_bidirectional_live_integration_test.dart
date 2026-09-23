import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/compression_restore_store.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _FixtureDashboard extends DashboardClient {
  _FixtureDashboard()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'isolated-fixture',
      );
}

class _SharedGatewayFixture {
  _SharedGatewayFixture({
    this.rejectResume = false,
    this.emitSubmitLifecycle = true,
    this.advertiseLive = true,
  });

  final bool rejectResume;
  final bool emitSubmitLifecycle;
  final bool advertiseLive;
  late final HttpServer server;
  final sockets = <WebSocket>{};
  final methods = <String>[];
  final resumedDurables = <String>[];
  final activatedRuntimes = <String>[];
  var sequence = 0;
  var submitCount = 0;
  Completer<void>? recoveryResumeGate;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.done.whenComplete(() => sockets.remove(socket));
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'replay_epoch': 'fixture-epoch', 'heartbeat': false},
          },
        }),
      );
      socket.listen((raw) => unawaited(_handle(socket, raw as String)));
    });
  }

  Future<void> _handle(WebSocket socket, String raw) async {
    final frame = jsonDecode(raw) as Map<String, dynamic>;
    final method = frame['method'] as String;
    methods.add(method);
    final params =
        (frame['params'] as Map?)?.cast<String, dynamic>() ?? const {};
    late final Map<String, dynamic> result;
    switch (method) {
      case 'gateway.capabilities':
        result = {'per_session_exclusive_submit': true};
      case 'session.active_list':
        result = {
          'sessions': advertiseLive
              ? [
                  {
                    'id': 'runtime-shared',
                    'session_key': 'durable-shared',
                    'current': true,
                    'status': 'running',
                  },
                ]
              : <Object>[],
        };
      case 'session.activate':
        activatedRuntimes.add(params['session_id'] as String);
        result = {
          'session_id': 'runtime-shared',
          'stored_session_id': 'durable-shared',
          'session_key': 'durable-shared',
          'created': false,
          'messages': [
            {
              'message_id': 'desktop-user-1',
              'role': 'user',
              'content': 'turno iniciado en Desktop',
            },
          ],
          'inflight': {
            'user': 'turno iniciado en Desktop',
            'assistant': 'parcial Desktop',
            'streaming': true,
          },
          'running': true,
          'status': 'running',
        };
      case 'session.resume':
        resumedDurables.add(params['session_id'] as String);
        if (resumedDurables.length > 1) await recoveryResumeGate?.future;
        if (rejectResume) {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': frame['id'],
              'error': {
                'code': 4009,
                'message': 'runtime is attached to another gateway',
              },
            }),
          );
          return;
        }
        result = {
          'session_id': 'runtime-shared',
          'stored_session_id': 'durable-shared',
          'session_key': 'durable-shared',
          'created': false,
          'messages': [
            {
              'message_id': 'desktop-user-1',
              'role': 'user',
              'content': 'turno iniciado en Desktop',
            },
          ],
          'inflight': {
            'user': 'turno iniciado en Desktop',
            'assistant': 'parcial Desktop',
            'streaming': true,
          },
          'running': true,
          'status': 'running',
        };
      case 'prompt.submit':
        submitCount += 1;
        final clientTurnId = params['client_turn_id'];
        result = clientTurnId is String
            ? {
                'accepted': true,
                'client_turn_id': clientTurnId,
                'server_turn_id': 'server-turn-$submitCount',
                'state': 'running',
                'duplicate': false,
              }
            : <String, dynamic>{};
        if (emitSubmitLifecycle) {
          scheduleMicrotask(() {
            broadcast('status.update', const {'status': 'running'});
            broadcast('message.start', const {});
            broadcast('message.delta', const {
              'text': 'respuesta Console viva',
            });
          });
        }
      case 'turn.status':
        result = {
          'known': true,
          'client_turn_id': params['client_turn_id'],
          'server_turn_id': 'server-turn-$submitCount',
          'state': 'running',
        };
      default:
        result = <String, dynamic>{};
    }
    if (socket.readyState != WebSocket.open) return;
    try {
      socket.add(
        jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
      );
    } on StateError {
      // The test may rotate this exact channel while an RPC handler is gated.
    }
  }

  void broadcast(String type, Map<String, dynamic> payload) {
    sequence += 1;
    final raw = jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {
        'type': type,
        'session_id': 'runtime-shared',
        'seq': sequence,
        'payload': payload,
      },
    });
    for (final socket in sockets.toList(growable: false)) {
      socket.add(raw);
    }
  }

  Future<void> dropViewers() async {
    for (final socket in sockets.toList(growable: false)) {
      await socket.close(WebSocketStatus.goingAway, 'fixture transport cut');
    }
  }

  Future<void> close() async {
    for (final socket in sockets.toList(growable: false)) {
      await socket.close();
    }
    await server.close(force: true);
  }
}

class _NoopOutbox implements TurnOutboxPersistence {
  @override
  Future<void> delete(PreparedTurn turn) async {}

  @override
  Future<void> save(PreparedTurn turn) async {}
}

class _CountingDelivery extends ActiveTurnDelivery {
  _CountingDelivery({required super.prepared, required super.store});

  int markRunningCalls = 0;

  @override
  Future<void> markRunning() {
    markRunningCalls += 1;
    return super.markRunning();
  }
}

SavedConnection _connection(int port) => SavedConnection(
  id: 'fixture-shared-gateway',
  label: 'Isolated shared gateway',
  host: '127.0.0.1',
  port: 8642,
  apiKey: String.fromCharCodes(const [113, 97]),
  dashboardUrl: 'http://127.0.0.1:$port',
);

ApiClient _emptyRestClient(SavedConnection connection) => ApiClient(
  baseUrl: connection.baseUrl,
  apiKey: connection.apiKey,
  httpClient: MockClient(
    (_) async => http.Response(
      jsonEncode({
        'data': <Object>[],
        'pagination': {'total': 0},
      }),
      200,
      headers: {'content-type': 'application/json'},
    ),
  ),
);

ActiveChat _chat(
  SavedConnection connection,
  TuiGatewayClient gateway,
  String namespace, {
  StoredSessionMessageLoader? storedMessageLoader,
  Future<bool> Function()? turnIdempotencyCapability,
}) {
  final service = ActiveChatService(
    compressionRestoreStore: CompressionRestoreStore(
      storage: InMemoryCompressionRestoreStorage(),
      mutationNamespaceForTesting: namespace,
    ),
    attachDesktopRuntimeOnLoad: true,
  );
  addTearDown(service.dispose);
  final chat = service.attach(
    connection: connection,
    sessionId: 'durable-shared',
    initialStoredSessionId: 'durable-shared',
    sessionTitle: 'Shared durable session',
    desktopGateway: gateway,
    storedMessageLoader: storedMessageLoader,
    api: _emptyRestClient(connection),
    attachDesktopRuntimeOnLoad: true,
    disableForegroundKeepAlive: true,
    turnIdempotencyCapability: turnIdempotencyCapability,
  );
  chat.smoothStreaming = false;
  return chat;
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not reached before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test(
    'shared gateway carries Desktop live state and Console turn to two viewers',
    () async {
      final fixture = _SharedGatewayFixture();
      await fixture.start();
      addTearDown(fixture.close);
      final connection = _connection(fixture.server.port);
      final firstGateway = TuiGatewayClient(
        connection,
        dashboard: _FixtureDashboard(),
        heartbeatInterval: const Duration(hours: 1),
        heartbeatDeadline: const Duration(hours: 2),
      );
      final secondGateway = TuiGatewayClient(
        connection,
        dashboard: _FixtureDashboard(),
        heartbeatInterval: const Duration(hours: 1),
        heartbeatDeadline: const Duration(hours: 2),
      );
      addTearDown(firstGateway.close);
      addTearDown(secondGateway.close);
      final first = _chat(connection, firstGateway, 'spec060-first');
      final second = _chat(connection, secondGateway, 'spec060-second');
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      await Future.wait([first.loadMessages(), second.loadMessages()]);
      expect(fixture.activatedRuntimes, ['runtime-shared', 'runtime-shared']);
      expect(fixture.resumedDurables, isEmpty);
      expect(first.desktopRuntimeSessionId, 'runtime-shared');
      expect(second.desktopRuntimeSessionId, 'runtime-shared');
      expect(first.assistantContent, contains('parcial Desktop'));
      expect(second.assistantContent, contains('parcial Desktop'));

      fixture.broadcast('tool.start', const {
        'tool_id': 'tool-1',
        'name': 'terminal',
        'preview': 'public progress',
      });
      fixture.broadcast('subagent.start', const {
        'subagent_id': 'child-1',
        'child_session_id': 'child-durable-1',
        'status': 'running',
      });
      fixture.broadcast('clarify.request', const {
        'request_id': 'clarify-1',
        'questions': [
          {'qid': 'q1', 'question': '¿Continuar?'},
        ],
      });
      await _waitUntil(
        () =>
            second.trace.isNotEmpty &&
            second.subagentAggregate.activeCount == 1 &&
            second.pendingInteractivePrompt != null,
      );
      expect(second.subagentActivities, isEmpty);
      expect(second.state, ChatPipelineState.executing);

      fixture.broadcast('message.complete', const {
        'text': 'respuesta Desktop final',
      });
      await _waitUntil(
        () =>
            first.state == ChatPipelineState.completed &&
            second.state == ChatPipelineState.completed,
      );

      final accepted = await first.send(
        fullText: 'continuación desde Console',
        model: 'hermes-agent',
        history: first.buildHistory(),
      );
      expect(accepted, isTrue);
      await _waitUntil(
        () => second.assistantContent.contains('respuesta Console viva'),
      );

      first.dispose();
      fixture.broadcast('message.delta', const {'text': ' tras cerrar viewer'});
      await _waitUntil(
        () => second.assistantContent.contains('tras cerrar viewer'),
      );
      expect(fixture.submitCount, 1);
      expect(
        fixture.methods,
        isNot(contains(anyOf('session.create', 'interrupt'))),
      );
    },
  );

  test(
    'live-before-REST reconciliation keeps one durable message identity',
    () async {
      final fixture = _SharedGatewayFixture();
      await fixture.start();
      addTearDown(fixture.close);
      final connection = _connection(fixture.server.port);
      final gateway = TuiGatewayClient(
        connection,
        dashboard: _FixtureDashboard(),
        heartbeatInterval: const Duration(hours: 1),
        heartbeatDeadline: const Duration(hours: 2),
      );
      addTearDown(gateway.close);
      final rest = Completer<List<Map<String, dynamic>>>();
      final chat = _chat(
        connection,
        gateway,
        'spec060-reversed',
        storedMessageLoader: (_, _) => rest.future,
      );
      addTearDown(chat.dispose);

      final loading = chat.loadMessages();
      await _waitUntil(() => fixture.activatedRuntimes.isNotEmpty);
      fixture.broadcast('message.interim', const {
        'message_id': 'assistant-shared-1',
        'text': 'respuesta compartida única',
      });
      await _waitUntil(
        () => chat.messages.any(
          (message) => message['content'] == 'respuesta compartida única',
        ),
      );
      rest.complete(const [
        {
          'message_id': 'desktop-user-1',
          'role': 'user',
          'content': 'turno iniciado en Desktop',
        },
        {
          'message_id': 'assistant-shared-1',
          'role': 'assistant',
          'content': 'respuesta compartida única',
        },
      ]);
      await loading;

      expect(
        chat.messages.where(
          (message) => message['content'] == 'respuesta compartida única',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'isolated gateway refusal preserves durable history without mutations',
    () async {
      final fixture = _SharedGatewayFixture(
        rejectResume: true,
        advertiseLive: false,
      );
      await fixture.start();
      addTearDown(fixture.close);
      final connection = _connection(fixture.server.port);
      final gateway = TuiGatewayClient(
        connection,
        dashboard: _FixtureDashboard(),
        heartbeatInterval: const Duration(hours: 1),
        heartbeatDeadline: const Duration(hours: 2),
      );
      addTearDown(gateway.close);
      final chat = _chat(
        connection,
        gateway,
        'spec060-isolated',
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'durable-history-1',
            'role': 'assistant',
            'content': 'historial durable conservado',
          },
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages();

      expect(chat.desktopRuntimeSessionId, isNull);
      expect(
        chat.messages,
        contains(containsPair('content', 'historial durable conservado')),
      );
      expect(fixture.resumedDurables, ['durable-shared']);
      expect(
        fixture.methods,
        isNot(
          contains(
            anyOf(
              'session.create',
              'session.activate',
              'prompt.submit',
              'interrupt',
            ),
          ),
        ),
      );
    },
  );

  test(
    'production empty recovery proof keeps retrying across channel rotation',
    () async {
      final fixture = _SharedGatewayFixture(emitSubmitLifecycle: false)
        ..recoveryResumeGate = Completer<void>();
      await fixture.start();
      addTearDown(fixture.close);
      final connection = _connection(fixture.server.port);
      final gateway = TuiGatewayClient(
        connection,
        dashboard: _FixtureDashboard(),
        heartbeatInterval: const Duration(hours: 1),
        heartbeatDeadline: const Duration(hours: 2),
      );
      addTearDown(gateway.close);
      final chat = _chat(
        connection,
        gateway,
        'spec060-production-empty-proof',
        turnIdempotencyCapability: () async => true,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages();
      fixture.broadcast('message.complete', const {
        'text': 'historial canónico previo',
      });
      await _waitUntil(() => chat.state == ChatPipelineState.completed);

      final delivery = _CountingDelivery(
        prepared: PreparedTurn(
          connectionId: connection.id,
          sessionId: 'durable-shared',
          clientTurnId: 'production-empty-proof-turn',
          createdAtMs: 1,
          updatedAtMs: 1,
          text: 'turno pendiente tras corte',
          attachments: const [],
          model: 'hermes-agent',
          profile: '',
        ),
        store: _NoopOutbox(),
      );
      final accepted = await chat.send(
        fullText: 'turno pendiente tras corte',
        model: 'hermes-agent',
        history: chat.buildHistory(),
        delivery: delivery,
      );
      expect(accepted, isTrue);
      expect(delivery.markRunningCalls, 1);

      await fixture.dropViewers();
      await _waitUntil(() => fixture.methods.contains('turn.status'));
      expect(delivery.markRunningCalls, 1);
      expect(chat.desktopRuntimeSessionId, isNull);
      await _waitUntil(() => fixture.resumedDurables.isNotEmpty);
      // The first production recovery observed running status but its proof had
      // the product client's empty coverage/null cut, so it neither adopted nor
      // marked running. Rotate again while the next resume awaits its response.
      await fixture.dropViewers();
      fixture.recoveryResumeGate!.complete();
      await _waitUntil(() => fixture.resumedDurables.length >= 2);

      expect(delivery.markRunningCalls, 1);
      expect(chat.state, ChatPipelineState.connecting);
      expect(chat.desktopRuntimeSessionId, isNull);
      expect(
        chat.messages,
        contains(containsPair('content', 'turno pendiente tras corte')),
      );
      expect(fixture.submitCount, 1);
      expect(fixture.resumedDurables, everyElement('durable-shared'));
    },
  );

  test(
    'unproven reconnect cut preserves transcript and never mutates',
    () async {
      final fixture = _SharedGatewayFixture();
      await fixture.start();
      addTearDown(fixture.close);
      final connection = _connection(fixture.server.port);
      final gateway = TuiGatewayClient(
        connection,
        dashboard: _FixtureDashboard(),
        heartbeatInterval: const Duration(hours: 1),
        heartbeatDeadline: const Duration(hours: 2),
      );
      addTearDown(gateway.close);
      final chat = _chat(connection, gateway, 'spec060-unproven-cut');
      addTearDown(chat.dispose);

      await chat.loadMessages();
      expect(chat.assistantContent, contains('parcial Desktop'));
      await fixture.dropViewers();
      await _waitUntil(() => fixture.resumedDurables.isNotEmpty);
      await _waitUntil(() => chat.desktopRuntimeSessionId == null);

      expect(
        chat.messages,
        contains(containsPair('content', 'turno iniciado en Desktop')),
      );
      expect(fixture.resumedDurables, everyElement('durable-shared'));
      expect(
        fixture.methods,
        isNot(contains(anyOf('session.create', 'prompt.submit', 'interrupt'))),
      );
    },
  );
}
