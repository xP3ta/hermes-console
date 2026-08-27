import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

class _DroppingDesktopGateway implements HermesDesktopGateway {
  _DroppingDesktopGateway({this.canonicalStoredId});

  final _events = StreamController<TuiGatewayEvent>.broadcast();
  final String? canonicalStoredId;
  bool _connected = false;
  int connectCalls = 0;
  int resumeCalls = 0;
  int submitCalls = 0;
  final List<String> resumedStoredIds = [];

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async {
    connectCalls++;
    _connected = true;
  }

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    resumeCalls++;
    resumedStoredIds.add(storedSessionId);
    return DesktopSessionBinding(
      runtimeSessionId: 'runtime-$resumeCalls',
      storedSessionId: canonicalStoredId ?? storedSessionId,
      created: false,
    );
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submitCalls++;
  }

  void drop() {
    _connected = false;
    _events.addError(StateError('socket dropped'));
  }

  void emit(
    String type, {
    String? sessionId,
    Map<String, dynamic> payload = const {},
  }) {
    _events.add(
      TuiGatewayEvent(
        type: type,
        sessionId: sessionId ?? 'runtime-$resumeCalls',
        payload: payload,
      ),
    );
  }

  @override
  Future<void> close() async {
    _connected = false;
    await _events.close();
  }

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
  }) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}
}

class _RecoverableDesktopGateway extends _DroppingDesktopGateway
    implements HermesDesktopIdempotentGateway {
  Completer<void>? recoveryConnectGate;
  Completer<void>? recoveryResumeGate;
  Completer<void>? recoveryStatusGate;
  final recoveryResumeStarted = Completer<void>();
  DesktopTurnState recoveredState = DesktopTurnState.running;
  int recoveryConnectFailuresRemaining = 0;
  Object? recoveryConnectError;
  int statusCalls = 0;

  @override
  Future<void> connect() async {
    await super.connect();
    if (connectCalls > 1) {
      await recoveryConnectGate?.future;
      if (recoveryConnectError case final error?) throw error;
      if (recoveryConnectFailuresRemaining > 0) {
        recoveryConnectFailuresRemaining--;
        _connected = false;
        throw StateError('coverage unavailable');
      }
    }
  }

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    if (resumeCalls > 0) {
      if (!recoveryResumeStarted.isCompleted) {
        recoveryResumeStarted.complete();
      }
      await recoveryResumeGate?.future;
    }
    return super.resumeSession(
      storedSessionId,
      profile: profile,
      seedMessages: seedMessages,
      model: model,
    );
  }

  @override
  Future<DesktopTurnAck> submitPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  ) async {
    submitCalls++;
    return DesktopTurnAck(
      accepted: true,
      clientTurnId: clientTurnId,
      serverTurnId: 'server-turn',
      state: DesktopTurnState.running,
      duplicate: false,
    );
  }

  @override
  Future<DesktopTurnStatus> getTurnStatus(
    String sessionId,
    String clientTurnId,
  ) async {
    statusCalls++;
    await recoveryStatusGate?.future;
    return DesktopTurnStatus(
      known: true,
      clientTurnId: clientTurnId,
      serverTurnId: 'server-turn',
      state: recoveredState,
    );
  }
}

class _LifecycleRecoverableGateway extends _RecoverableDesktopGateway
    implements
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopRecoverySessionLifecycleGateway {
  int resumeExistingCalls = 0;
  int createForFirstSubmitCalls = 0;
  final List<String> resumeExistingStoredIds = [];
  final List<String> committedRecoveryRuntimeIds = [];
  Completer<DesktopSessionSnapshot>? recoveryExistingGate;
  Object? resumeExistingError;

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    resumeExistingCalls++;
    resumeExistingStoredIds.add(storedSessionId);
    if (resumeExistingError case final error?) throw error;
    return DesktopSessionBinding(
      runtimeSessionId: 'runtime-existing-$resumeExistingCalls',
      storedSessionId: storedSessionId,
      created: false,
    );
  }

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    createForFirstSubmitCalls++;
    return const DesktopSessionBinding(
      runtimeSessionId: 'runtime-created-unexpectedly',
      storedSessionId: 'stored-created-unexpectedly',
      created: true,
    );
  }

  @override
  Future<DesktopSessionSnapshot> resumeExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) {
    resumeExistingCalls++;
    resumeExistingStoredIds.add(storedSessionId);
    if (resumeExistingError case final error?) return Future.error(error);
    return recoveryExistingGate?.future ??
        Future.value(
          DesktopSessionBinding(
            runtimeSessionId: 'runtime-recovery-$resumeExistingCalls',
            storedSessionId: storedSessionId,
            created: false,
          ),
        );
  }

  @override
  void commitRecoveryRuntime(String runtimeSessionId) {
    committedRecoveryRuntimeIds.add(runtimeSessionId);
  }
}

class _ControlledApiClient extends ApiClient {
  _ControlledApiClient()
    : super(baseUrl: 'http://127.0.0.1:8642', apiKey: 'test-key');

  final List<Completer<List<Map<String, dynamic>>>> requests = [];
  bool closed = false;

  @override
  Future<List<Map<String, dynamic>>> getMessages(String sessionId) {
    final request = Completer<List<Map<String, dynamic>>>();
    requests.add(request);
    return request.future;
  }

  @override
  void close() {
    closed = true;
  }
}

/// API cuyo `getMessages` siempre devuelve un transcript ya completo, para
/// probar la reconciliación tras un corte cuando el servidor sí tiene la
/// respuesta del turno.
class _CompletedTranscriptApi extends ApiClient {
  _CompletedTranscriptApi(this.transcript)
    : super(baseUrl: 'http://127.0.0.1:8642', apiKey: 'test-key');

  final List<Map<String, dynamic>> transcript;
  int calls = 0;

  @override
  Future<List<Map<String, dynamic>>> getMessages(String sessionId) async {
    calls++;
    return transcript;
  }

  @override
  void close() {}
}

class _GatedOutbox implements TurnOutboxPersistence {
  final acceptedStarted = Completer<void>();
  final runningStarted = Completer<void>();
  final acceptedGate = Completer<void>();
  final runningGate = Completer<void>();

  @override
  Future<void> delete(PreparedTurn turn) async {}

  @override
  Future<void> save(PreparedTurn turn) async {
    if (turn.state == PreparedTurnState.accepted) {
      if (!acceptedStarted.isCompleted) acceptedStarted.complete();
      await acceptedGate.future;
    } else if (turn.state == PreparedTurnState.running) {
      if (!runningStarted.isCompleted) runningStarted.complete();
      await runningGate.future;
    }
  }
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not reached before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

SavedConnection _connection(String id) => SavedConnection(
  id: id,
  label: id,
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-key',
  kind: InstanceKind.vps,
);

ActiveTurnDelivery _delivery(
  String connectionId,
  TurnOutboxPersistence store,
) => ActiveTurnDelivery(
  prepared: PreparedTurn(
    connectionId: connectionId,
    sessionId: 'session-$connectionId',
    clientTurnId: 'turn-$connectionId',
    createdAtMs: 1,
    updatedAtMs: 1,
    text: 'mensaje',
    attachments: const [],
    model: 'hermes-agent',
    profile: '',
  ),
  store: store,
);

Future<void> _expectRecoveryErrorClassification(
  String id,
  Object error, {
  required bool terminal,
}) async {
  final gateway = _RecoverableDesktopGateway()..recoveryConnectError = error;
  final chat = _recoverableChat(
    id,
    gateway,
    desktopRecoveryBackoff: const [Duration.zero],
  );
  try {
    await chat.send(
      fullText: 'clasificar fallo recovery',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery(id, _NoopOutbox()),
    );
    gateway.drop();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      chat.state,
      terminal ? ChatPipelineState.failed : ChatPipelineState.connecting,
    );
    expect(gateway.connectCalls, 2);
  } finally {
    chat.dispose();
  }
}

ActiveChat _recoverableChat(
  String id,
  _RecoverableDesktopGateway gateway, {
  ApiClient? api,
  Duration terminalReconcileBudget = const Duration(seconds: 4),
  Duration desktopRecoveryAttemptTimeout = const Duration(seconds: 15),
  List<Duration> desktopRecoveryBackoff = const [
    Duration.zero,
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
  ],
}) => ActiveChat(
  connection: _connection(id),
  sessionId: 'session-$id',
  sessionTitle: id,
  notifications: null,
  onTerminal: () {},
  api:
      api ??
      ApiClient(
        baseUrl: 'http://127.0.0.1:1',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('not found', 404)),
      ),
  desktopGateway: gateway,
  turnIdempotencyCapability: () async => true,
  terminalReconcileBudget: terminalReconcileBudget,
  desktopRecoveryAttemptTimeout: desktopRecoveryAttemptTimeout,
  desktopRecoveryBackoff: desktopRecoveryBackoff,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'tras un corte Desktop el siguiente envío reanuda una sesión nueva',
    () async {
      final gateway = _DroppingDesktopGateway(
        canonicalStoredId: '20260716_canonical',
      );
      final api = ApiClient(
        baseUrl: 'http://127.0.0.1:1',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('not found', 404)),
      );
      final chat = ActiveChat(
        connection: SavedConnection(
          id: 'conn-drop',
          label: 'Drop',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'test-key',
          kind: InstanceKind.vps,
        ),
        sessionId: 'session-drop',
        sessionTitle: 'Drop',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
      );
      addTearDown(chat.dispose);

      chat.send(fullText: 'primero', model: 'hermes-agent', history: const []);
      await _waitUntil(() => gateway.submitCalls == 1);
      expect(gateway.resumeCalls, 1);

      gateway.drop();
      await _waitUntil(() => chat.state == ChatPipelineState.failed);

      chat.send(fullText: 'segundo', model: 'hermes-agent', history: const []);
      await _waitUntil(() => gateway.submitCalls == 2);

      expect(gateway.resumeCalls, 2);
      expect(gateway.resumedStoredIds, ['session-drop', '20260716_canonical']);
      expect(chat.state, ChatPipelineState.waiting);
    },
  );

  test(
    'un corte idempotente se reanuda sin reenviar ni pedir reconectar',
    () async {
      final gateway = _RecoverableDesktopGateway();
      final api = ApiClient(
        baseUrl: 'http://127.0.0.1:1',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('not found', 404)),
      );
      final chat = ActiveChat(
        connection: SavedConnection(
          id: 'conn-recover',
          label: 'Recover',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'test-key',
          kind: InstanceKind.vps,
        ),
        sessionId: 'session-recover',
        sessionTitle: 'Recover',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
        turnIdempotencyCapability: () async => true,
      );
      addTearDown(chat.dispose);

      await chat.send(
        fullText: 'una sola vez',
        model: 'hermes-agent',
        history: const [],
        delivery: ActiveTurnDelivery(
          prepared: PreparedTurn(
            connectionId: 'conn-recover',
            sessionId: 'session-recover',
            clientTurnId: 'client-turn',
            createdAtMs: 1,
            updatedAtMs: 1,
            text: 'una sola vez',
            attachments: const [],
            model: 'hermes-agent',
            profile: '',
          ),
          store: _NoopOutbox(),
        ),
      );
      expect(gateway.submitCalls, 1);

      gateway.drop();
      await _waitUntil(() => gateway.statusCalls == 1);

      expect(gateway.submitCalls, 1);
      expect(gateway.resumeCalls, 2);
      expect(chat.state, ChatPipelineState.executing);
    },
  );

  test(
    'una pérdida de cobertura prolongada espera la red y conserva el turno',
    () async {
      final gateway = _RecoverableDesktopGateway()
        // Supera los cuatro intentos 0s/1s/2s/4s del comportamiento anterior.
        ..recoveryConnectFailuresRemaining = 4;
      final chat = _recoverableChat(
        'coverage',
        gateway,
        desktopRecoveryBackoff: const [Duration.zero],
      );
      addTearDown(chat.dispose);

      await chat.send(
        fullText: 'no duplicar durante la pérdida de cobertura',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('coverage', _NoopOutbox()),
      );
      expect(gateway.submitCalls, 1);

      gateway.drop();
      await _waitUntil(
        () =>
            gateway.statusCalls == 1 || chat.state == ChatPipelineState.failed,
        timeout: const Duration(seconds: 10),
      );

      expect(chat.state, ChatPipelineState.executing);
      expect(gateway.statusCalls, 1);
      expect(gateway.submitCalls, 1);
    },
  );

  test(
    'un backoff vacío conserva un intento inmediato y luego cede al timer',
    () async {
      final gateway = _RecoverableDesktopGateway()
        ..recoveryConnectFailuresRemaining = 100;
      final chat = _recoverableChat(
        'coverage-empty-backoff',
        gateway,
        desktopRecoveryBackoff: const [],
      );
      addTearDown(chat.dispose);

      await chat.send(
        fullText: 'esperar sin monopolizar el event loop',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('coverage-empty-backoff', _NoopOutbox()),
      );
      gateway.drop();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(gateway.connectCalls, 2);
      expect(chat.state, ChatPipelineState.connecting);
    },
  );

  test(
    'backoff no positivo permite como máximo un intento inmediato',
    () async {
      final gateway = _RecoverableDesktopGateway()
        ..recoveryConnectFailuresRemaining = 100;
      final chat = _recoverableChat(
        'coverage-nonpositive-backoff',
        gateway,
        desktopRecoveryBackoff: const [
          Duration(seconds: -2),
          Duration.zero,
          Duration(seconds: -1),
        ],
      );
      addTearDown(chat.dispose);

      await chat.send(
        fullText: 'normalizar retrasos inválidos',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('coverage-nonpositive-backoff', _NoopOutbox()),
      );
      gateway.drop();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(gateway.connectCalls, 2);
      expect(chat.state, ChatPipelineState.connecting);
    },
  );

  test(
    'cancelar durante el backoff detiene la reconexión inmediatamente',
    () async {
      final gateway = _RecoverableDesktopGateway();
      final chat = _recoverableChat(
        'coverage-cancel',
        gateway,
        desktopRecoveryBackoff: const [Duration(hours: 1)],
      );
      addTearDown(chat.dispose);

      await chat.send(
        fullText: 'cancelar mientras no hay cobertura',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('coverage-cancel', _NoopOutbox()),
      );
      gateway.drop();
      await _waitUntil(() => chat.state == ChatPipelineState.connecting);

      chat.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(chat.state, ChatPipelineState.cancelled);
      expect(gateway.connectCalls, 1);
    },
  );

  test('HTTP 404 de sesión es terminal para recovery', () async {
    final gateway = _RecoverableDesktopGateway()
      ..recoveryConnectError = const DashboardHttpException(404);
    final chat = _recoverableChat(
      'coverage-http-404',
      gateway,
      desktopRecoveryBackoff: const [Duration.zero],
    );
    addTearDown(chat.dispose);

    await chat.send(
      fullText: 'no reintentar una sesión ausente',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('coverage-http-404', _NoopOutbox()),
    );
    gateway.drop();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(chat.state, ChatPipelineState.failed);
    expect(gateway.connectCalls, 2);
  });

  test('RPC malformado sin código es terminal para recovery', () async {
    final gateway = _RecoverableDesktopGateway()
      ..recoveryConnectError = const TuiGatewayRpcError(
        'session.resume',
        'malformed response',
      );
    final chat = _recoverableChat(
      'coverage-rpc-null',
      gateway,
      desktopRecoveryBackoff: const [Duration.zero],
    );
    addTearDown(chat.dispose);

    await chat.send(
      fullText: 'no reintentar una respuesta inválida',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('coverage-rpc-null', _NoopOutbox()),
    );
    gateway.drop();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(chat.state, ChatPipelineState.failed);
    expect(gateway.connectCalls, 2);
  });

  test('fallos estructurales HTTP y RPC son terminales', () async {
    final cases = <Object>[
      const DashboardHttpException(400),
      const DashboardHttpException(422),
      const TuiGatewayRpcError('session.resume', 'parse', code: -32700),
      const TuiGatewayRpcError(
        'session.resume',
        'invalid request',
        code: -32600,
      ),
      const TuiGatewayRpcError(
        'session.resume',
        'invalid params',
        code: -32602,
      ),
      const TuiGatewayRpcError('session.resume', 'auth', code: 4030),
    ];
    for (var index = 0; index < cases.length; index++) {
      await _expectRecoveryErrorClassification(
        'terminal-classification-$index',
        cases[index],
        terminal: true,
      );
    }
  });

  test(
    'timeout rate-limit transporte y 5xx siguen siendo transitorios',
    () async {
      final cases = <Object>[
        const DashboardHttpException(408),
        const DashboardHttpException(429),
        const DashboardHttpException(503),
        const TuiGatewayRpcError('session.resume', 'server busy', code: 5001),
        StateError('transport offline'),
      ];
      for (var index = 0; index < cases.length; index++) {
        await _expectRecoveryErrorClassification(
          'transient-classification-$index',
          cases[index],
          terminal: false,
        );
      }
    },
  );

  test('un rechazo de autenticación no entra en reconexión infinita', () async {
    final gateway = _RecoverableDesktopGateway()
      ..recoveryConnectError = const DashboardAuthException(
        DashboardAuthFailureCode.invalidCredentials,
        statusCode: 401,
      );
    final chat = _recoverableChat(
      'coverage-auth',
      gateway,
      desktopRecoveryBackoff: const [Duration.zero],
    );
    addTearDown(chat.dispose);

    await chat.send(
      fullText: 'no reintentar credenciales inválidas',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('coverage-auth', _NoopOutbox()),
    );
    gateway.drop();
    await _waitUntil(() => chat.state == ChatPipelineState.failed);

    expect(gateway.connectCalls, 2);
    expect(gateway.submitCalls, 1);
  });

  test(
    'recovery 4007 moderno no cae en resume legacy ni crea una sesión',
    () async {
      final gateway = _LifecycleRecoverableGateway()
        ..resumeExistingError = const TuiGatewayRpcError(
          'session.resume',
          'session not found',
          code: 4007,
        );
      final chat = _recoverableChat('recovery-missing-modern', gateway);
      addTearDown(chat.dispose);

      await chat.send(
        fullText: 'una sola vez',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('recovery-missing-modern', _NoopOutbox()),
      );
      expect(gateway.resumeCalls, 1);
      expect(gateway.resumeExistingCalls, 0);
      expect(gateway.createForFirstSubmitCalls, 0);

      gateway.drop();
      await _waitUntil(() => chat.state == ChatPipelineState.failed);

      expect(gateway.resumeExistingCalls, 1);
      expect(gateway.resumeExistingStoredIds, [
        'session-recovery-missing-modern',
      ]);
      expect(gateway.resumeCalls, 1);
      expect(gateway.createForFirstSubmitCalls, 0);
      expect(gateway.statusCalls, 0);
    },
  );

  test('un resume recovery obsoleto no adopta la identidad runtime', () async {
    final staleResume = Completer<DesktopSessionSnapshot>();
    final gateway = _LifecycleRecoverableGateway()
      ..recoveryExistingGate = staleResume;
    final chat = _recoverableChat('stale-recovery-runtime', gateway);
    addTearDown(chat.dispose);

    await chat.send(
      fullText: 'turno original',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('stale-recovery-runtime', _NoopOutbox()),
    );
    gateway.drop();
    await _waitUntil(() => gateway.resumeExistingCalls == 1);

    chat.cancel();
    staleResume.complete(
      const DesktopSessionBinding(
        runtimeSessionId: 'runtime-obsoleto',
        storedSessionId: 'session-stale-recovery-runtime',
        created: false,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(chat.state, ChatPipelineState.cancelled);
    expect(gateway.committedRecoveryRuntimeIds, isEmpty);
  });

  test(
    'reconciliar outbox 4007 moderno conserva ambiguo y nunca crea',
    () async {
      final gateway = _LifecycleRecoverableGateway()
        ..resumeExistingError = const TuiGatewayRpcError(
          'session.resume',
          'session not found',
          code: 4007,
        );
      final chat = _recoverableChat('outbox-missing-modern', gateway);
      addTearDown(chat.dispose);
      final store = _NoopOutbox();
      final ambiguous = _delivery('outbox-missing-modern', store).current
          .copyWith(
            updatedAtMs: DateTime.now().millisecondsSinceEpoch,
            state: PreparedTurnState.ambiguous,
          );

      final resolved = await chat.reconcileAmbiguousTurn(ambiguous, store);

      expect(resolved.state, PreparedTurnState.ambiguous);
      expect(gateway.resumeExistingCalls, 1);
      expect(gateway.resumeExistingStoredIds, [
        'session-outbox-missing-modern',
      ]);
      expect(gateway.resumeCalls, 0);
      expect(gateway.createForFirstSubmitCalls, 0);
      expect(gateway.statusCalls, 0);
    },
  );

  for (final boundary in const ['connect', 'resume', 'status']) {
    test(
      'cancelar durante $boundary impide que la recuperación resucite el turno',
      () async {
        final gateway = _RecoverableDesktopGateway();
        final gate = Completer<void>();
        switch (boundary) {
          case 'connect':
            gateway.recoveryConnectGate = gate;
          case 'resume':
            gateway.recoveryResumeGate = gate;
          case 'status':
            gateway.recoveryStatusGate = gate;
        }
        final chat = _recoverableChat('cancel-$boundary', gateway);
        addTearDown(chat.dispose);

        await chat.send(
          fullText: 'una sola vez',
          model: 'hermes-agent',
          history: const [],
          delivery: _delivery('cancel-$boundary', _NoopOutbox()),
        );
        gateway.drop();
        switch (boundary) {
          case 'connect':
            await _waitUntil(() => gateway.connectCalls == 2);
          case 'resume':
            await gateway.recoveryResumeStarted.future;
          case 'status':
            await _waitUntil(() => gateway.statusCalls == 1);
        }

        chat.cancel();
        expect(chat.state, ChatPipelineState.cancelled);
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(chat.state, ChatPipelineState.cancelled);
      },
    );
  }

  test(
    'una operación recovery colgada vence y cancel libera el chat',
    () async {
      final gateway = _RecoverableDesktopGateway()
        ..recoveryConnectGate = Completer<void>();
      final chat = _recoverableChat(
        'hung-recovery-operation',
        gateway,
        desktopRecoveryAttemptTimeout: const Duration(milliseconds: 25),
        desktopRecoveryBackoff: const [
          Duration.zero,
          Duration(milliseconds: 10),
        ],
      );
      addTearDown(chat.dispose);

      await chat.send(
        fullText: 'no retener el chat por una operación colgada',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('hung-recovery-operation', _NoopOutbox()),
      );
      gateway.drop();
      await _waitUntil(() => gateway.connectCalls >= 3);

      chat.cancel();
      final callsAfterCancel = gateway.connectCalls;
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(chat.state, ChatPipelineState.cancelled);
      expect(gateway.connectCalls, callsAfterCancel);
    },
  );

  test(
    'cancelar durante markRunning impide una transición tardía a executing',
    () async {
      final statusGate = Completer<void>();
      final gateway = _RecoverableDesktopGateway()
        ..recoveryStatusGate = statusGate;
      final outbox = _GatedOutbox();
      final chat = _recoverableChat('cancel-mark-running', gateway);
      addTearDown(chat.dispose);

      final send = chat.send(
        fullText: 'una sola vez',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('cancel-mark-running', outbox),
      );
      await outbox.acceptedStarted.future;
      gateway.drop();
      await _waitUntil(() => gateway.statusCalls == 1);
      statusGate.complete();
      await Future<void>.delayed(Duration.zero);
      outbox.acceptedGate.complete();
      await outbox.runningStarted.future;

      chat.cancel();
      expect(chat.state, ChatPipelineState.cancelled);
      outbox.runningGate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(chat.state, ChatPipelineState.cancelled);

      await send;
    },
  );

  test('una recuperación vieja no completa el turno nuevo', () async {
    final gateway = _RecoverableDesktopGateway()
      ..recoveryStatusGate = Completer<void>()
      ..recoveredState = DesktopTurnState.terminal;
    final chat = _recoverableChat('recovery-new-turn', gateway);
    addTearDown(chat.dispose);

    await chat.send(
      fullText: 'turno viejo',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('recovery-new-turn', _NoopOutbox()),
    );
    gateway.drop();
    await _waitUntil(() => gateway.statusCalls == 1);

    chat.cancel();
    await chat.send(
      fullText: 'turno nuevo',
      model: 'hermes-agent',
      history: const [],
    );
    expect(gateway.submitCalls, 2);
    expect(chat.state, ChatPipelineState.waiting);

    gateway.recoveryStatusGate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    gateway.emit('tool.start', payload: const {'name': 'new-turn-tool'});
    await _waitUntil(() => chat.state == ChatPipelineState.executing);

    expect(chat.trace.last.id, 'new-turn-tool');
  });

  test('un GET terminal colgado respeta el presupuesto total', () async {
    final gateway = _DroppingDesktopGateway();
    final api = _ControlledApiClient();
    final chat = ActiveChat(
      connection: _connection('terminal-budget'),
      sessionId: 'session-terminal-budget',
      sessionTitle: 'terminal-budget',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
      terminalReconcileBudget: const Duration(milliseconds: 80),
    );
    addTearDown(chat.dispose);
    await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []);

    final stopwatch = Stopwatch()..start();
    final done = chat.changes.firstWhere(
      (event) => event == ActiveChatEvent.done,
    );
    gateway.emit('message.complete');
    await _waitUntil(() => api.requests.length == 1);
    await done.timeout(const Duration(seconds: 1));
    stopwatch.stop();

    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
    expect(api.requests, hasLength(1));
    expect(chat.state, ChatPipelineState.completed);
    api.requests.single.complete(const []);
  });

  test('dispose durante un GET terminal impide mutaciones tardías', () async {
    final gateway = _DroppingDesktopGateway();
    final api = _ControlledApiClient();
    final chat = ActiveChat(
      connection: _connection('terminal-dispose-get'),
      sessionId: 'session-terminal-dispose-get',
      sessionTitle: 'terminal-dispose-get',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
      terminalReconcileBudget: const Duration(seconds: 1),
    );
    await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []);
    gateway.emit('message.complete');
    await _waitUntil(() => api.requests.length == 1);

    chat.dispose();
    api.requests.single.complete(const [
      {'role': 'user', 'content': 'hola'},
      {'role': 'assistant', 'content': 'respuesta tardía'},
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(api.closed, isTrue);
    expect(chat.assistantContent, isNot('respuesta tardía'));
    expect(api.requests, hasLength(1));
  });

  test('dispose durante el backoff terminal evita otro GET', () async {
    final gateway = _DroppingDesktopGateway();
    final api = _ControlledApiClient();
    final chat = ActiveChat(
      connection: _connection('terminal-dispose-delay'),
      sessionId: 'session-terminal-dispose-delay',
      sessionTitle: 'terminal-dispose-delay',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
      terminalReconcileBudget: const Duration(seconds: 1),
    );
    await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []);
    gateway.emit('message.complete');
    await _waitUntil(() => api.requests.length == 1);
    api.requests.single.complete(const []);
    await Future<void>.delayed(const Duration(milliseconds: 40));

    chat.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(api.requests, hasLength(1));
  });

  test(
    'un transcript terminal user+tool se adopta sin texto assistant',
    () async {
      final gateway = _DroppingDesktopGateway();
      final api = _ControlledApiClient();
      final chat = ActiveChat(
        connection: _connection('terminal-tool-only'),
        sessionId: 'session-terminal-tool-only',
        sessionTitle: 'terminal-tool-only',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
        terminalReconcileBudget: const Duration(seconds: 1),
      );
      addTearDown(chat.dispose);
      await chat.send(
        fullText: 'usa la herramienta',
        model: 'hermes-agent',
        history: const [],
      );
      final done = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.done,
      );
      gateway.emit('message.complete');
      await _waitUntil(() => api.requests.length == 1);
      api.requests.single.complete(const [
        {'role': 'user', 'content': 'usa la herramienta'},
        {'role': 'tool', 'name': 'search', 'content': 'resultado'},
      ]);
      await done.timeout(const Duration(seconds: 1));

      expect(api.requests, hasLength(1));
      expect(chat.messages.first['role'], 'tool');
      expect(chat.state, ChatPipelineState.completed);
    },
  );

  test(
    'un transcript terminal parcial no reemplaza la respuesta completa visible',
    () async {
      final gateway = _DroppingDesktopGateway();
      final api = _ControlledApiClient();
      final chat = ActiveChat(
        connection: _connection('terminal-stale-assistant'),
        sessionId: 'session-terminal-stale-assistant',
        sessionTitle: 'terminal-stale-assistant',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
        terminalReconcileBudget: const Duration(seconds: 1),
      );
      addTearDown(chat.dispose);
      await chat.send(
        fullText: 'explica el resultado',
        model: 'hermes-agent',
        history: const [],
      );
      final done = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.done,
      );
      gateway.emit(
        'message.complete',
        payload: const {
          'text': 'Respuesta completa que ya estaba visible en el chat.',
        },
      );
      await _waitUntil(() => api.requests.length == 1);
      api.requests.single.complete(const [
        {'role': 'user', 'content': 'explica el resultado'},
        {'role': 'assistant', 'content': 'Respuesta completa'},
      ]);
      await done.timeout(const Duration(seconds: 1));

      expect(
        chat.assistantContent,
        'Respuesta completa que ya estaba visible en el chat.',
      );
    },
  );

  test(
    'terminal vacío espera al transcript canónico sin perder la respuesta',
    () async {
      final gateway = _DroppingDesktopGateway(
        canonicalStoredId: '20260716_delayed',
      );
      var transcriptReads = 0;
      final requestedPaths = <String>[];
      final api = ApiClient(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          requestedPaths.add(request.url.path);
          if (request.url.path == '/api/sessions/20260716_delayed/messages') {
            transcriptReads++;
            if (transcriptReads < 3) {
              return http.Response('{"data":[]}', 200);
            }
            return http.Response(
              '{"data":['
              '{"role":"user","content":"hola"},'
              '{"role":"assistant","content":"respuesta persistida"}'
              ']}',
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      );
      final chat = ActiveChat(
        connection: SavedConnection(
          id: 'conn-delayed',
          label: 'Delayed',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'test-key',
          kind: InstanceKind.vps,
        ),
        sessionId: 'mob-provisional',
        sessionTitle: 'Delayed',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.send(
        fullText: 'hola',
        model: 'hermes-agent',
        history: const [],
      );
      final done = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.done,
      );
      gateway.emit('message.complete');
      await done.timeout(const Duration(seconds: 3));

      expect(chat.serverSessionId, '20260716_delayed');
      expect(chat.assistantContent, 'respuesta persistida');
      expect(transcriptReads, 3);
      expect(
        requestedPaths,
        isNot(contains('/api/sessions/mob-provisional/messages')),
      );
    },
  );

  test('un 404 al recargar conserva los mensajes visibles', () async {
    final api = ApiClient(
      baseUrl: 'http://127.0.0.1:8642',
      apiKey: 'test-key',
      httpClient: MockClient((_) async => http.Response('not found', 404)),
    );
    final chat = ActiveChat(
      connection: SavedConnection(
        id: 'conn-refresh',
        label: 'Refresh',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'test-key',
        kind: InstanceKind.vps,
      ),
      sessionId: 'mob-refresh',
      sessionTitle: 'Refresh',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: _DroppingDesktopGateway(),
    );
    addTearDown(chat.dispose);
    chat.messages = [
      {'role': 'assistant', 'content': 'no me borres'},
      {'role': 'user', 'content': 'mensaje'},
    ];

    await expectLater(chat.loadMessages(), throwsException);

    expect(chat.assistantContent, 'no me borres');
    expect(chat.messages, hasLength(2));
  });

  test('sin idempotencia, un corte a mitad de turno reconcilia el transcript '
      'en vez de fallar con el error crudo', () async {
    final gateway = _DroppingDesktopGateway();
    final api = _CompletedTranscriptApi(const [
      {'role': 'user', 'content': 'dame noticias'},
      {'role': 'assistant', 'content': 'Aquí están las noticias.'},
    ]);
    final chat = ActiveChat(
      connection: _connection('drop-reconcile'),
      sessionId: 'session-drop-reconcile',
      sessionTitle: 'drop-reconcile',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
      terminalReconcileBudget: const Duration(seconds: 1),
    );
    addTearDown(chat.dispose);
    await chat.send(
      fullText: 'dame noticias',
      model: 'hermes-agent',
      history: const [],
    );

    // El socket se cae a mitad de turno, sin evento terminal. El gateway no
    // soporta idempotencia de turno, así que la recuperación por
    // getTurnStatus no aplica: la app debe reconciliar el transcript y
    // mostrar la respuesta que el servidor sí produjo, en vez de quedar en
    // estado de error.
    gateway.drop();

    await _waitUntil(() => chat.state == ChatPipelineState.completed);
    expect(chat.messages.first['role'], 'assistant');
    expect(chat.messages.first['content'], 'Aquí están las noticias.');
  });
}

class _NoopOutbox implements TurnOutboxPersistence {
  @override
  Future<void> delete(PreparedTurn turn) async {}

  @override
  Future<void> save(PreparedTurn turn) async {}
}
