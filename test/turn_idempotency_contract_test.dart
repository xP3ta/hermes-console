import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/connection_diagnostics.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

class _MemoryOutbox implements TurnOutboxPersistence {
  final List<PreparedTurn> writes = [];
  final List<PreparedTurn> deletes = [];

  @override
  Future<void> save(PreparedTurn turn) async => writes.add(turn);

  @override
  Future<void> delete(PreparedTurn turn) async => deletes.add(turn);
}

class _LegacyGateway implements HermesDesktopGateway {
  final _events = StreamController<TuiGatewayEvent>.broadcast();
  final List<(String, String)> submissions = [];

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-legacy',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submissions.add((runtimeSessionId, text));
  }

  void emit(String type, {Map<String, dynamic> payload = const {}}) {
    _events.add(
      TuiGatewayEvent(
        type: type,
        sessionId: 'runtime-legacy',
        payload: payload,
      ),
    );
  }

  @override
  Future<void> close() => _events.close();

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}
}

class _ModernGateway extends _LegacyGateway
    implements HermesDesktopIdempotentGateway {
  final List<(String, String, String)> idempotentSubmissions = [];
  int statusCalls = 0;
  Object? submissionError;
  bool duplicate = false;
  DesktopTurnState ackState = DesktopTurnState.accepted;
  DesktopTurnStatus? nextStatus;

  @override
  Future<DesktopTurnAck> submitPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  ) async {
    idempotentSubmissions.add((runtimeSessionId, text, clientTurnId));
    if (submissionError case final error?) throw error;
    return DesktopTurnAck(
      accepted: true,
      clientTurnId: clientTurnId,
      serverTurnId: 'server-turn-1',
      state: ackState,
      duplicate: duplicate,
    );
  }

  @override
  Future<DesktopTurnStatus> getTurnStatus(
    String sessionId,
    String clientTurnId,
  ) async {
    statusCalls++;
    return nextStatus ??
        DesktopTurnStatus(known: false, clientTurnId: clientTurnId);
  }
}

({ActiveChat chat, ActiveTurnDelivery delivery, _MemoryOutbox store}) _fixture(
  HermesDesktopGateway gateway, {
  Future<bool> Function()? capability,
}) {
  final api = ApiClient(
    baseUrl: 'https://example.invalid',
    apiKey: 'test-only',
    httpClient: MockClient((_) async => http.Response('unused', 500)),
  );
  final chat = ActiveChat(
    connection: SavedConnection(
      id: 'conn-modern',
      label: 'Modern',
      host: 'example.invalid',
      port: 443,
      apiKey: 'test-only',
      useHttps: true,
    ),
    sessionId: 'session-modern',
    sessionTitle: 'Modern',
    notifications: null,
    onTerminal: () {},
    api: api,
    desktopGateway: gateway,
    turnIdempotencyCapability: capability,
  );
  final now = DateTime.now().millisecondsSinceEpoch;
  final store = _MemoryOutbox();
  return (
    chat: chat,
    delivery: ActiveTurnDelivery(
      prepared: PreparedTurn(
        connectionId: 'conn-modern',
        sessionId: 'session-modern',
        clientTurnId: 'client-turn-1',
        createdAtMs: now,
        updatedAtMs: now,
        text: 'mensaje moderno',
        attachments: const [],
        model: 'hermes-agent',
        profile: '',
      ),
      store: store,
    ),
    store: store,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'sin capability usa prompt heredado exacto y no consulta status',
    () async {
      final gateway = _LegacyGateway();
      final api = ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: 'test-only',
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      );
      final chat = ActiveChat(
        connection: SavedConnection(
          id: 'conn-legacy',
          label: 'Legacy',
          host: 'example.invalid',
          port: 443,
          apiKey: 'test-only',
          useHttps: true,
        ),
        sessionId: 'session-legacy',
        sessionTitle: 'Legacy',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
      );
      addTearDown(chat.dispose);
      final now = DateTime.now().millisecondsSinceEpoch;
      final delivery = ActiveTurnDelivery(
        prepared: PreparedTurn(
          connectionId: 'conn-legacy',
          sessionId: 'session-legacy',
          clientTurnId: 'client-turn-must-stay-local',
          createdAtMs: now,
          updatedAtMs: now,
          text: 'mensaje heredado',
          attachments: const [],
          model: 'hermes-agent',
          profile: '',
        ),
        store: _MemoryOutbox(),
      );

      final accepted = await chat.send(
        fullText: 'mensaje heredado',
        model: 'hermes-agent',
        history: const [],
        delivery: delivery,
      );

      expect(accepted, isTrue);
      expect(gateway.submissions, [('runtime-legacy', 'mensaje heredado')]);
      expect(gateway.submissions.single.$2, isNot(contains('client-turn')));
      expect(delivery.current.state, PreparedTurnState.running);
    },
  );

  test('ACK idempotente valida eco, estado e identidad opaca', () {
    final ack = DesktopTurnAck.fromJson(const {
      'accepted': true,
      'client_turn_id': 'client-turn-1',
      'server_turn_id': 'server-opaque',
      'state': 'accepted',
      'duplicate': false,
    }, expectedClientTurnId: 'client-turn-1');

    expect(ack.accepted, isTrue);
    expect(ack.serverTurnId, 'server-opaque');
    expect(ack.state, DesktopTurnState.accepted);
    expect(ack.duplicate, isFalse);
  });

  test('ACK idempotente rechaza eco o estado que rompen contrato', () {
    expect(
      () => DesktopTurnAck.fromJson(const {
        'accepted': true,
        'client_turn_id': 'otro',
        'state': 'accepted',
      }, expectedClientTurnId: 'client-turn-1'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
    expect(
      () => DesktopTurnAck.fromJson(const {
        'accepted': true,
        'client_turn_id': 'client-turn-1',
        'state': 'inventado',
      }, expectedClientTurnId: 'client-turn-1'),
      throwsA(isA<TuiGatewayRpcError>()),
    );
  });

  test('status unknown es tipado y no equivale a permiso para reenviar', () {
    final status = DesktopTurnStatus.fromJson(const {
      'known': false,
      'client_turn_id': 'client-turn-1',
    }, expectedClientTurnId: 'client-turn-1');

    expect(status.known, isFalse);
    expect(status.state, isNull);
    expect(status.serverTurnId, isNull);
  });

  test(
    'capability autenticada se deriva y persiste sin probe mutante',
    () async {
      final caps = ServerCapabilities.tryParse(
        jsonEncode({
          'object': 'hermes.api_server.capabilities',
          'features': {'turn_idempotency_v1': true},
          'endpoints': <String, Object?>{},
        }),
      );
      final diagnostics = ConnectionDiagnostics(
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      );
      addTearDown(diagnostics.close);

      final matrix = diagnostics.buildMatrix(
        const [],
        const [],
        null,
        serverCaps: caps,
      );

      expect(matrix.turnIdempotency, CapState.yes);
      expect(matrix.isServerSourced('turnIdempotency'), isTrue);
      SharedPreferences.setMockInitialValues({
        'capabilities_conn-modern': jsonEncode(matrix.toJson()),
      });
      expect(
        await ConnectionManager.isTurnIdempotencySupported('conn-modern'),
        isTrue,
      );
    },
  );

  test('capability ausente o corrupta conserva contrato heredado', () async {
    SharedPreferences.setMockInitialValues({
      'capabilities_corrupt': '{no-json',
    });

    expect(
      await ConnectionManager.isTurnIdempotencySupported('missing'),
      isFalse,
    );
    expect(
      await ConnectionManager.isTurnIdempotencySupported('corrupt'),
      isFalse,
    );
  });

  test(
    'capability solo habilita idempotencia si es reciente y server-sourced',
    () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({
        'capabilities_legacy': jsonEncode({'turn_idempotency': 'yes'}),
        'capabilities_inferred': jsonEncode({
          'turn_idempotency': 'yes',
          'server_sourced': <String>[],
          'checked_at_ms': now,
        }),
        'capabilities_stale': jsonEncode({
          'turn_idempotency': 'yes',
          'server_sourced': ['turnIdempotency'],
          'checked_at_ms': now - const Duration(hours: 25).inMilliseconds,
        }),
        'capabilities_future': jsonEncode({
          'turn_idempotency': 'yes',
          'server_sourced': ['turnIdempotency'],
          'checked_at_ms': now + const Duration(minutes: 5).inMilliseconds,
        }),
        'capabilities_recent': jsonEncode({
          'turn_idempotency': 'yes',
          'server_sourced': ['turnIdempotency'],
          'checked_at_ms': now - const Duration(minutes: 5).inMilliseconds,
        }),
      });

      expect(
        await ConnectionManager.isTurnIdempotencySupported('legacy'),
        isFalse,
      );
      expect(
        await ConnectionManager.isTurnIdempotencySupported('inferred'),
        isFalse,
      );
      expect(
        await ConnectionManager.isTurnIdempotencySupported('stale'),
        isFalse,
      );
      expect(
        await ConnectionManager.isTurnIdempotencySupported('future'),
        isFalse,
      );
      expect(
        await ConnectionManager.isTurnIdempotencySupported('recent'),
        isTrue,
      );
    },
  );

  test(
    'capability positiva envía client_turn_id sin tocar camino base',
    () async {
      final gateway = _ModernGateway();
      final fixture = _fixture(gateway, capability: () async => true);
      addTearDown(fixture.chat.dispose);

      final accepted = await fixture.chat.send(
        fullText: 'mensaje moderno',
        model: 'hermes-agent',
        history: const [],
        delivery: fixture.delivery,
      );

      expect(accepted, isTrue);
      expect(gateway.submissions, isEmpty);
      expect(gateway.idempotentSubmissions, [
        ('runtime-legacy', 'mensaje moderno', 'client-turn-1'),
      ]);
      expect(gateway.statusCalls, 0);
    },
  );

  test('duplicate=true conserva una sola entrega aceptada', () async {
    final gateway = _ModernGateway()..duplicate = true;
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);

    final accepted = await fixture.chat.send(
      fullText: 'mensaje moderno',
      model: 'hermes-agent',
      history: const [],
      delivery: fixture.delivery,
    );

    expect(accepted, isTrue);
    expect(gateway.idempotentSubmissions, hasLength(1));
    expect(gateway.submissions, isEmpty);
    expect(fixture.delivery.current.state, PreparedTurnState.running);
  });

  test('duplicate terminal limpia evidencia sin esperar otro evento', () async {
    final gateway = _ModernGateway()
      ..duplicate = true
      ..ackState = DesktopTurnState.terminal;
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);

    final accepted = await fixture.chat.send(
      fullText: 'mensaje moderno',
      model: 'hermes-agent',
      history: const [],
      delivery: fixture.delivery,
    );

    expect(accepted, isTrue);
    expect(gateway.idempotentSubmissions, hasLength(1));
    expect(fixture.delivery.current.state, PreparedTurnState.terminal);
    expect(fixture.store.deletes, hasLength(1));
    expect(fixture.chat.activeTurnDelivery, isNull);
  });

  test('capability obsoleta con socket viejo conserva prompt base', () async {
    final gateway = _LegacyGateway();
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);

    final accepted = await fixture.chat.send(
      fullText: 'mensaje moderno',
      model: 'hermes-agent',
      history: const [],
      delivery: fixture.delivery,
    );

    expect(accepted, isTrue);
    expect(gateway.submissions, [('runtime-legacy', 'mensaje moderno')]);
    expect(fixture.delivery.current.state, PreparedTurnState.running);
  });

  test('method-not-found moderno invalida capability sin fallback', () async {
    final gateway = _ModernGateway()
      ..submissionError = const TuiGatewayRpcError(
        'prompt.submit',
        'method not found',
        code: -32601,
      );
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);

    final accepted = await fixture.chat.send(
      fullText: 'mensaje moderno',
      model: 'hermes-agent',
      history: const [],
      delivery: fixture.delivery,
    );

    expect(accepted, isFalse);
    expect(gateway.submissions, isEmpty);
    expect(gateway.idempotentSubmissions, hasLength(1));
    expect(fixture.chat.turnIdempotencyInvalid, isTrue);
    expect(fixture.delivery.current.state, PreparedTurnState.ambiguous);
  });

  test('turn.status recupera running sin volver a enviar', () async {
    final gateway = _ModernGateway()
      ..nextStatus = const DesktopTurnStatus(
        known: true,
        clientTurnId: 'client-turn-1',
        serverTurnId: 'server-turn-1',
        state: DesktopTurnState.running,
      );
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);
    final ambiguous = fixture.delivery.current.copyWith(
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      state: PreparedTurnState.ambiguous,
    );

    final resolved = await fixture.chat.reconcileAmbiguousTurn(
      ambiguous,
      fixture.store,
    );

    expect(resolved.state, PreparedTurnState.running);
    expect(gateway.statusCalls, 1);
    expect(gateway.submissions, isEmpty);
    expect(gateway.idempotentSubmissions, isEmpty);
    expect(fixture.chat.state, ChatPipelineState.waiting);
  });

  test('running restaurado se elimina al recibir el terminal real', () async {
    final gateway = _ModernGateway()
      ..nextStatus = const DesktopTurnStatus(
        known: true,
        clientTurnId: 'client-turn-1',
        serverTurnId: 'server-turn-1',
        state: DesktopTurnState.running,
      );
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);
    final ambiguous = fixture.delivery.current.copyWith(
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      state: PreparedTurnState.ambiguous,
    );

    final resolved = await fixture.chat.reconcileAmbiguousTurn(
      ambiguous,
      fixture.store,
    );
    expect(resolved.state, PreparedTurnState.running);

    gateway.emit('message.complete', payload: const {'text': 'hecho'});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(fixture.chat.activeTurnDelivery, isNull);
    expect(fixture.store.deletes, hasLength(1));
    expect(fixture.store.deletes.single.state, PreparedTurnState.terminal);
  });

  test('turn.status known=false permanece ambiguo', () async {
    final gateway = _ModernGateway();
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);
    final ambiguous = fixture.delivery.current.copyWith(
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      state: PreparedTurnState.ambiguous,
    );

    final resolved = await fixture.chat.reconcileAmbiguousTurn(
      ambiguous,
      fixture.store,
    );

    expect(resolved.state, PreparedTurnState.ambiguous);
    expect(gateway.statusCalls, 1);
    expect(fixture.store.deletes, isEmpty);
  });

  test('turn.status terminal limpia la outbox sin reenviar', () async {
    final gateway = _ModernGateway()
      ..nextStatus = const DesktopTurnStatus(
        known: true,
        clientTurnId: 'client-turn-1',
        serverTurnId: 'server-turn-1',
        state: DesktopTurnState.terminal,
      );
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);
    final accepted = fixture.delivery.current.copyWith(
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      state: PreparedTurnState.accepted,
    );

    final resolved = await fixture.chat.reconcileAmbiguousTurn(
      accepted,
      fixture.store,
    );

    expect(resolved.state, PreparedTurnState.terminal);
    expect(fixture.store.deletes, hasLength(1));
    expect(gateway.submissions, isEmpty);
    expect(gateway.idempotentSubmissions, isEmpty);
  });

  test('turn.status no se consulta sin capability positiva', () async {
    final gateway = _ModernGateway();
    final fixture = _fixture(gateway, capability: () async => false);
    addTearDown(fixture.chat.dispose);
    final ambiguous = fixture.delivery.current.copyWith(
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      state: PreparedTurnState.ambiguous,
    );

    final resolved = await fixture.chat.reconcileAmbiguousTurn(
      ambiguous,
      fixture.store,
    );

    expect(resolved.state, PreparedTurnState.ambiguous);
    expect(gateway.statusCalls, 0);
  });
}
