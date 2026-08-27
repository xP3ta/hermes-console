import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  int interruptCalls = 0;
  int hangingInterruptsRemaining = 0;
  int interruptErrorsRemaining = 0;
  Object? interruptError;
  Object? resumeSessionError;
  final List<String> interruptedRuntimeIds = [];
  final List<String> submittedRuntimeIds = [];
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
    if (resumeSessionError case final error?) throw error;
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
    submittedRuntimeIds.add(runtimeSessionId);
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
  Future<void> interrupt(String runtimeSessionId) async {
    interruptCalls++;
    interruptedRuntimeIds.add(runtimeSessionId);
    if (hangingInterruptsRemaining > 0) {
      hangingInterruptsRemaining--;
      await Completer<void>().future;
    }
    if (interruptErrorsRemaining > 0) {
      interruptErrorsRemaining--;
      throw interruptError ?? StateError('interrupt failed');
    }
  }

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
    submittedRuntimeIds.add(runtimeSessionId);
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
  Object? createForFirstSubmitError;
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
    if (createForFirstSubmitError case final error?) throw error;
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

class _RestFallbackApiClient extends ApiClient {
  _RestFallbackApiClient()
    : super(baseUrl: 'http://127.0.0.1:8642', apiKey: 'key');

  int startCalls = 0;
  int stopCalls = 0;
  Completer<String>? startGate;

  @override
  Future<String> startRun({
    required String input,
    String? sessionId,
    String? model,
    List<Map<String, dynamic>>? history,
    String? profile,
  }) async {
    startCalls++;
    return startGate == null ? 'rest-run' : await startGate!.future;
  }

  @override
  Future<Map<String, dynamic>> stopRun(String runId) async {
    stopCalls++;
    return <String, dynamic>{};
  }

  @override
  Future<void> streamRunEvents(
    String runId, {
    required void Function(Map<String, dynamic> event) onEvent,
    required void Function() onDone,
    required void Function(String error) onError,
    Duration idleTimeout = const Duration(seconds: 90),
  }) => Completer<void>().future;
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
  List<CancelledTurnTombstone> initialCancelledTurnTombstones = const [],
  Future<void> Function(CancelledTurnTombstone)? onCancelledTurn,
  void Function(ActiveChatEvent)? onEvent,
  StoredSessionMessageLoader? storedMessageLoader,
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
  initialCancelledTurnTombstones: initialCancelledTurnTombstones,
  onCancelledTurn: onCancelledTurn,
  onEvent: onEvent,
  storedMessageLoader: storedMessageLoader,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reconciliar transcript oculta la respuesta del turno detenido', () {
    final projected = projectCancelledTurnTombstones(
      existingNewestFirst: const [],
      durableTombstones: const [
        CancelledTurnTombstone(
          content: 'QA4931_OFFLINE_CANCEL_OLD',
          firstUser: true,
        ),
      ],
      incomingNewestFirst: const [
        {'role': 'assistant', 'content': 'QA4931_OFFLINE_CANCEL_OLD'},
        {'role': 'user', 'content': 'QA4931_OFFLINE_CANCEL_OLD'},
      ],
    );

    expect(projected, [
      {
        'role': 'user',
        'content': 'QA4931_OFFLINE_CANCEL_OLD',
        '_cancelledUser': true,
      },
    ]);
  });

  test('tombstone distingue prompts repetidos por ancla durable', () {
    final projected = projectCancelledTurnTombstones(
      existingNewestFirst: const [],
      durableTombstones: const [
        CancelledTurnTombstone(
          content: 'mismo prompt',
          anchorMessageId: 'anchor-old',
        ),
      ],
      incomingNewestFirst: const [
        {'id': 'answer-new', 'role': 'assistant', 'content': 'respuesta nueva'},
        {'id': 'user-new', 'role': 'user', 'content': 'mismo prompt'},
        {'id': 'answer-old', 'role': 'assistant', 'content': 'respuesta vieja'},
        {'id': 'user-old', 'role': 'user', 'content': 'mismo prompt'},
        {
          'id': 'anchor-old',
          'role': 'assistant',
          'content': 'respuesta previa',
        },
      ],
    );

    expect(projected.map((message) => message['content']), [
      'respuesta nueva',
      'mismo prompt',
      'mismo prompt',
      'respuesta previa',
    ]);
    expect(projected[2]['_cancelledUser'], isTrue);
  });

  test('tombstone ignora filas steer al contar turnos de usuario', () {
    final projected = projectCancelledTurnTombstones(
      existingNewestFirst: const [],
      durableTombstones: const [
        CancelledTurnTombstone(content: 'turno detenido', firstUser: true),
      ],
      incomingNewestFirst: const [
        {'role': 'assistant', 'content': 'respuesta nueva'},
        {'role': 'user', 'content': 'turno nuevo'},
        {'role': 'assistant', 'content': 'respuesta que debe ocultarse'},
        {'role': 'user', 'content': 'turno detenido'},
      ],
    );

    expect(projected.map((message) => message['content']), [
      'respuesta nueva',
      'turno nuevo',
      'turno detenido',
    ]);
    expect(projected.last['_cancelledUser'], isTrue);
  });

  test('tombstone conserva metadatos user del turno cancelado', () {
    final projected = projectCancelledTurnTombstones(
      existingNewestFirst: const [],
      durableTombstones: const [
        CancelledTurnTombstone(content: 'turno detenido', firstUser: true),
      ],
      incomingNewestFirst: const [
        {'role': 'assistant', 'content': 'respuesta que debe ocultarse'},
        {
          'role': 'user',
          'content': 'cambio de modelo',
          'display_kind': 'model_switch',
        },
        {'role': 'user', 'content': 'turno detenido'},
      ],
    );

    expect(projected.map((message) => message['content']), [
      'cambio de modelo',
      'turno detenido',
    ]);
    expect(projected.last['_cancelledUser'], isTrue);
  });

  test('tombstone conserva tool y artefactos del turno cancelado', () {
    final projected = projectCancelledTurnTombstones(
      existingNewestFirst: const [],
      durableTombstones: const [
        CancelledTurnTombstone(content: 'turno detenido', firstUser: true),
      ],
      incomingNewestFirst: const [
        {'role': 'assistant', 'content': 'respuesta que debe ocultarse'},
        {
          'role': 'tool',
          'content': 'resultado estructurado',
          'call_id': 'call-1',
        },
        {
          'role': 'artifact',
          'content': 'informe.pdf',
          'artifact_id': 'artifact-1',
        },
        {'role': 'user', 'content': 'turno detenido'},
      ],
    );

    expect(projected.map((message) => message['role']), [
      'tool',
      'artifact',
      'user',
    ]);
    expect(projected.last['_cancelledUser'], isTrue);
  });

  test('tombstone durable sobrevive sin mensajes locales', () {
    final projected = projectCancelledTurnTombstones(
      existingNewestFirst: const [],
      durableTombstones: const [
        CancelledTurnTombstone(content: 'turno detenido', firstUser: true),
      ],
      incomingNewestFirst: const [
        {'role': 'assistant', 'content': 'respuesta que debe ocultarse'},
        {'role': 'user', 'content': 'turno detenido'},
      ],
    );

    expect(projected.map((message) => message['content']), ['turno detenido']);
    expect(projected.single['_cancelledUser'], isTrue);
  });

  test('tombstone no cae por texto sobre una ventana parcial', () {
    final projected = projectCancelledTurnTombstones(
      existingNewestFirst: const [],
      durableTombstones: const [
        CancelledTurnTombstone(
          content: 'prompt repetido',
          anchorMessageId: 'missing-anchor',
        ),
      ],
      incomingNewestFirst: const [
        {'role': 'assistant', 'content': 'respuesta legítima reciente'},
        {'role': 'user', 'content': 'prompt repetido'},
      ],
    );

    expect(projected, isEmpty);
  });

  test(
    'loadMessages reaplica tombstone restaurado tras recrear proceso',
    () async {
      final gateway = _LifecycleRecoverableGateway();
      final chat = _recoverableChat(
        'restore-load',
        gateway,
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(
            content: 'turno detenido',
            anchorMessageId: 'anchor-before',
          ),
        ],
        storedMessageLoader: (_, _) async => const [
          {
            'id': 'anchor-before',
            'role': 'assistant',
            'content': 'respuesta anterior',
          },
          {'id': 'cancelled-user', 'role': 'user', 'content': 'turno detenido'},
          {
            'id': 'cancelled-answer',
            'role': 'assistant',
            'content': 'respuesta que no debe reaparecer',
          },
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 3);

      expect(chat.messages.map((message) => message['content']), [
        'turno detenido',
        'respuesta anterior',
      ]);
      expect(chat.messages.first['_cancelledUser'], isTrue);
    },
  );

  test('Stop publica un tombstone durable anclado', () async {
    final recorded = <CancelledTurnTombstone>[];
    final gateway = _LifecycleRecoverableGateway();
    final chat = _recoverableChat(
      'persist-cancel',
      gateway,
      onCancelledTurn: (tombstone) async => recorded.add(tombstone),
    );
    addTearDown(chat.dispose);

    await chat.send(
      fullText: 'turno que se detiene',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('persist-cancel-1', _NoopOutbox()),
    );
    chat.cancel();
    await _waitUntil(() => recorded.isNotEmpty);

    expect(recorded.single.content, 'turno que se detiene');
    expect(recorded.single.firstUser, isTrue);
    expect(recorded.single.anchorMessageId, isNull);
  });

  test('Stop usa el id durable anterior como ancla', () async {
    final recorded = <CancelledTurnTombstone>[];
    final gateway = _LifecycleRecoverableGateway();
    final chat = _recoverableChat(
      'persist-anchor',
      gateway,
      onCancelledTurn: (tombstone) async => recorded.add(tombstone),
    );
    addTearDown(chat.dispose);
    chat.messages.add({
      'id': 'durable-before-turn',
      'role': 'assistant',
      'content': 'respuesta anterior',
    });

    await chat.send(
      fullText: 'turno anclado',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('persist-anchor-1', _NoopOutbox()),
    );
    await chat.cancel();

    expect(recorded, hasLength(1));
    expect(recorded.single.anchorMessageId, 'durable-before-turn');
    expect(recorded.single.firstUser, isFalse);
  });

  test('Stop espera confirmación del almacenamiento durable', () async {
    final gate = Completer<void>();
    final events = <ActiveChatEvent>[];
    final gateway = _LifecycleRecoverableGateway();
    final chat = _recoverableChat(
      'persist-ack',
      gateway,
      onCancelledTurn: (_) => gate.future,
      onEvent: events.add,
    );
    addTearDown(chat.dispose);

    await chat.send(
      fullText: 'turno durable',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('persist-ack-1', _NoopOutbox()),
    );
    var completed = false;
    final cancel = chat.cancel().then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    expect(chat.isStreaming, isTrue);
    expect(chat.hasPendingDurableCancellation, isTrue);
    expect(events, isNot(contains(ActiveChatEvent.cancelled)));
    gate.complete();
    await cancel;
    expect(completed, isTrue);
    expect(events, contains(ActiveChatEvent.cancelled));
  });

  test('Stop sin ancla durable falla cerrado y no confirma', () async {
    var persisted = 0;
    final events = <ActiveChatEvent>[];
    final gateway = _LifecycleRecoverableGateway();
    final chat = _recoverableChat(
      'missing-anchor',
      gateway,
      onCancelledTurn: (_) async => persisted++,
      onEvent: events.add,
    );
    addTearDown(chat.dispose);
    chat.messages.add({'role': 'user', 'content': 'turno histórico sin id'});

    await chat.send(
      fullText: 'turno sin ancla',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('missing-anchor-1', _NoopOutbox()),
    );

    await expectLater(chat.cancel(), throwsStateError);
    expect(persisted, 0);
    expect(chat.isStreaming, isTrue);
    expect(events, isNot(contains(ActiveChatEvent.cancelled)));
  });

  test('fallo durable bloquea envío pero permite reintentar Stop', () async {
    var persistenceAttempts = 0;
    final gateway = _LifecycleRecoverableGateway();
    final chat = _recoverableChat(
      'persist-failure',
      gateway,
      onCancelledTurn: (_) async {
        persistenceAttempts++;
        if (persistenceAttempts == 1) {
          throw StateError('keystore failed');
        }
      },
    );
    addTearDown(chat.dispose);
    chat.messages.add({
      'role': 'assistant',
      'content': 'respuesta anterior',
      'id': 'anchor-before-failure',
    });

    await chat.send(
      fullText: 'turno detenido',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('persist-failure-1', _NoopOutbox()),
    );
    await expectLater(chat.cancel(), throwsStateError);

    await expectLater(
      chat.send(
        fullText: 'turno posterior prohibido',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('persist-failure-2', _NoopOutbox()),
      ),
      throwsStateError,
    );
    expect(gateway.submitCalls, 1);
    expect(chat.isStreaming, isTrue);
    await chat.cancel();
    expect(persistenceAttempts, 2);
    expect(chat.isStreaming, isFalse);
  });

  test(
    'terminal durante write fallido mantiene Stop y permite retry',
    () async {
      final gate = Completer<void>();
      var attempts = 0;
      final gateway = _LifecycleRecoverableGateway();
      final chat = _recoverableChat(
        'terminal-during-write',
        gateway,
        onCancelledTurn: (_) {
          attempts++;
          return attempts == 1 ? gate.future : Future<void>.value();
        },
      );
      addTearDown(chat.dispose);
      chat.messages.add({
        'role': 'assistant',
        'content': 'ancla',
        'id': 'anchor-terminal',
      });
      await chat.send(
        fullText: 'turno',
        model: 'hermes-agent',
        history: const [],
      );

      final firstCancel = chat.cancel();
      gateway.emit('message.complete');
      await Future<void>.delayed(Duration.zero);
      expect(chat.isStreaming, isTrue);
      gate.completeError(StateError('keystore unavailable'));
      await expectLater(firstCancel, throwsA(isA<StateError>()));
      expect(chat.isStreaming, isTrue);

      await chat.cancel();
      expect(attempts, 2);
      expect(chat.isStreaming, isFalse);
    },
  );

  test('store cifrado restaura tombstones tras recrear el proceso', () async {
    String? encryptedPayload;
    Future<String?> read() async => encryptedPayload;
    Future<void> write(String value) async => encryptedPayload = value;

    final first = CancelledTurnTombstoneStore(
      read: read,
      write: write,
      nowMs: () => 1000,
    );
    await first.initialize();
    await first.add(
      connectionId: 'conn',
      profile: 'default',
      sessionId: 'session',
      tombstone: const CancelledTurnTombstone(
        content: 'turno detenido',
        anchorMessageId: 'anchor-3',
      ),
    );

    final restoredStore = CancelledTurnTombstoneStore(
      read: read,
      write: write,
      nowMs: () => 1001,
    );
    await restoredStore.initialize();
    final restored = restoredStore.load(
      connectionId: 'conn',
      profile: 'default',
      sessionId: 'session',
    );

    expect(restored, hasLength(1));
    expect(restored.single.content, 'turno detenido');
    expect(restored.single.matchesContent('turno detenido'), isTrue);
    expect(restored.single.anchorMessageId, 'anchor-3');
  });

  test(
    'store falla cerrado y puede reintentar tras error de lectura',
    () async {
      var failRead = true;
      var writes = 0;
      final store = CancelledTurnTombstoneStore(
        read: () async {
          if (failRead) throw StateError('keystore unavailable');
          return null;
        },
        write: (_) async => writes++,
        nowMs: () => 1000,
      );

      await expectLater(store.initialize(), throwsStateError);
      expect(
        () => store.load(
          connectionId: 'conn',
          profile: 'default',
          sessionId: 'session',
        ),
        throwsStateError,
      );
      expect(writes, 0);

      failRead = false;
      await store.initialize();
      await store.add(
        connectionId: 'conn',
        profile: 'default',
        sessionId: 'session',
        tombstone: const CancelledTurnTombstone(
          content: 'turno detenido',
          firstUser: true,
        ),
      );
      expect(writes, 1);
    },
  );

  test('store no sobrescribe JSON cifrado corrupto', () async {
    var writes = 0;
    final store = CancelledTurnTombstoneStore(
      read: () async => '{corrupt',
      write: (_) async => writes++,
      nowMs: () => 1000,
    );

    await expectLater(store.initialize(), throwsFormatException);
    expect(writes, 0);
    await expectLater(
      store.add(
        connectionId: 'conn',
        profile: 'default',
        sessionId: 'session',
        tombstone: const CancelledTurnTombstone(
          content: 'turno detenido',
          firstUser: true,
        ),
      ),
      throwsFormatException,
    );
    expect(writes, 0);
  });

  test(
    'store no publica en caché antes de confirmar escritura cifrada',
    () async {
      final writeGate = Completer<void>();
      final store = CancelledTurnTombstoneStore(
        read: () async => null,
        write: (_) => writeGate.future,
        nowMs: () => 1000,
      );
      await store.initialize();

      final pending = store.add(
        connectionId: 'conn',
        profile: 'default',
        sessionId: 'session',
        tombstone: const CancelledTurnTombstone(
          content: 'turno detenido',
          firstUser: true,
        ),
      );

      expect(
        store.load(
          connectionId: 'conn',
          profile: 'default',
          sessionId: 'session',
        ),
        isEmpty,
      );
      writeGate.complete();
      await pending;
      expect(
        store.load(
          connectionId: 'conn',
          profile: 'default',
          sessionId: 'session',
        ),
        hasLength(1),
      );
    },
  );

  test('store aísla generaciones distintas del mismo backend lógico', () async {
    final store = CancelledTurnTombstoneStore(
      read: () async => null,
      write: (_) async {},
    );
    await store.initialize();
    await store.add(
      connectionId: 'conn',
      profile: 'default',
      sessionId: 'session',
      generation: 'host-a:443',
      tombstone: const CancelledTurnTombstone(
        content: 'privado',
        firstUser: true,
      ),
    );

    expect(
      store.load(
        connectionId: 'conn',
        profile: 'default',
        sessionId: 'session',
        generation: 'host-b:443',
      ),
      isEmpty,
    );
  });

  test('store borra una sesión sin afectar otra conexión', () async {
    String? payload;
    final store = CancelledTurnTombstoneStore(
      read: () async => payload,
      write: (value) async => payload = value,
    );
    await store.initialize();
    for (final connection in ['conn-a', 'conn-b']) {
      await store.add(
        connectionId: connection,
        profile: 'default',
        sessionId: 'session',
        tombstone: const CancelledTurnTombstone(
          content: 'privado',
          firstUser: true,
        ),
      );
    }

    expect(
      await store.removeSession(
        connectionId: 'conn-a',
        profile: 'default',
        sessionId: 'session',
      ),
      1,
    );
    expect(
      store.load(
        connectionId: 'conn-a',
        profile: 'default',
        sessionId: 'session',
      ),
      isEmpty,
    );
    expect(
      store.load(
        connectionId: 'conn-b',
        profile: 'default',
        sessionId: 'session',
      ),
      hasLength(1),
    );
  });

  test('store borra todos los scopes de una conexión', () async {
    String? payload;
    final store = CancelledTurnTombstoneStore(
      read: () async => payload,
      write: (value) async => payload = value,
    );
    await store.initialize();
    for (final session in ['one', 'two']) {
      await store.add(
        connectionId: 'conn-a',
        profile: 'default',
        sessionId: session,
        tombstone: const CancelledTurnTombstone(
          content: 'privado',
          firstUser: true,
        ),
      );
    }

    expect(await store.removeConnection('conn-a'), 2);
    expect(payload, isNot(contains('privado')));
  });

  test(
    'cleanup fallido queda en cola durable y se reintenta al iniciar',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      String? payload;
      var failWrites = false;
      final store = CancelledTurnTombstoneStore(
        read: () async => payload,
        write: (value) async {
          if (failWrites) throw StateError('keystore unavailable');
          payload = value;
        },
      );
      await store.initialize();
      await store.add(
        connectionId: 'conn',
        profile: 'default',
        sessionId: 'session',
        tombstone: const CancelledTurnTombstone(
          content: 'privado',
          firstUser: true,
        ),
      );
      failWrites = true;
      final first = ActiveChatService(prefs: prefs, cancelledTurnStore: store);
      await expectLater(
        first.clearCancelledTurnsForSession(
          connectionId: 'conn',
          profile: 'default',
          sessionId: 'session',
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        prefs.getStringList('cancelled_turn_cleanup_pending_v1'),
        isNotEmpty,
      );

      failWrites = false;
      ActiveChatService(prefs: prefs, cancelledTurnStore: store);
      await _waitUntil(
        () => store
            .load(
              connectionId: 'conn',
              profile: 'default',
              sessionId: 'session',
            )
            .isEmpty,
      );
      expect(prefs.getStringList('cancelled_turn_cleanup_pending_v1'), isEmpty);
    },
  );

  test(
    'store conserva tombstones antiguos mientras el servidor pueda retenerlos',
    () async {
      String? encryptedPayload;
      Future<String?> read() async => encryptedPayload;
      Future<void> write(String value) async => encryptedPayload = value;
      final first = CancelledTurnTombstoneStore(
        read: read,
        write: write,
        nowMs: () => 1000,
      );
      await first.initialize();
      await first.add(
        connectionId: 'conn',
        profile: 'default',
        sessionId: 'session',
        tombstone: const CancelledTurnTombstone(
          content: 'turno detenido',
          anchorMessageId: 'anchor-3',
        ),
      );

      final expired = CancelledTurnTombstoneStore(
        read: read,
        write: write,
        nowMs: () => 1000 + Duration.millisecondsPerDay * 31,
      );
      await expired.initialize();

      expect(
        expired.load(
          connectionId: 'conn',
          profile: 'default',
          sessionId: 'session',
        ),
        hasLength(1),
      );
    },
  );

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

  test('auth rateLimited 429 sigue en backoff sin reenviar ni crear', () async {
    final gateway = _LifecycleRecoverableGateway()
      ..recoveryConnectError = const DashboardAuthException(
        DashboardAuthFailureCode.rateLimited,
        statusCode: 429,
      );
    final chat = _recoverableChat(
      'coverage-auth-rate-limited',
      gateway,
      desktopRecoveryBackoff: const [
        Duration.zero,
        Duration(milliseconds: 10),
        Duration(hours: 1),
      ],
    );
    addTearDown(chat.dispose);

    await chat.send(
      fullText: 'no reenviar durante rate limit',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('coverage-auth-rate-limited', _NoopOutbox()),
    );
    gateway.drop();
    await _waitUntil(() => gateway.connectCalls >= 3);

    expect(chat.state, ChatPipelineState.connecting);
    expect(gateway.submitCalls, 1);
    expect(gateway.createForFirstSubmitCalls, 0);
  });

  test('auth loginFailed 503 sigue en backoff sin reenviar ni crear', () async {
    final gateway = _LifecycleRecoverableGateway()
      ..recoveryConnectError = const DashboardAuthException(
        DashboardAuthFailureCode.loginFailed,
        statusCode: 503,
      );
    final chat = _recoverableChat(
      'coverage-auth-login-failed',
      gateway,
      desktopRecoveryBackoff: const [
        Duration.zero,
        Duration(milliseconds: 10),
        Duration(hours: 1),
      ],
    );
    addTearDown(chat.dispose);

    await chat.send(
      fullText: 'no reenviar durante fallo transitorio de login',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('coverage-auth-login-failed', _NoopOutbox()),
    );
    gateway.drop();
    await _waitUntil(() => gateway.connectCalls >= 3);

    expect(chat.state, ChatPipelineState.connecting);
    expect(gateway.submitCalls, 1);
    expect(gateway.createForFirstSubmitCalls, 0);
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
    'una operación recovery legacy colgada vence y cancel no reanuda',
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
      expect(gateway.submitCalls, 1);
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

  test(
    'markRunning colgado vence y cancel dispose libera recovery sin mutar',
    () async {
      final gateway = _LifecycleRecoverableGateway();
      final outbox = _GatedOutbox();
      final chat = _recoverableChat(
        'hung-mark-running',
        gateway,
        desktopRecoveryAttemptTimeout: const Duration(milliseconds: 25),
        desktopRecoveryBackoff: const [
          Duration.zero,
          Duration(milliseconds: 10),
          Duration(hours: 1),
        ],
      );

      final send = chat.send(
        fullText: 'persistir running una sola vez',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('hung-mark-running', outbox),
      );
      await outbox.acceptedStarted.future;
      gateway.drop();
      await _waitUntil(() => gateway.statusCalls == 1);
      outbox.acceptedGate.complete();
      await outbox.runningStarted.future;

      await _waitUntil(() => gateway.connectCalls >= 3);
      chat.cancel();
      chat.dispose();
      outbox.runningGate.complete();
      await send;
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(chat.state, ChatPipelineState.cancelled);
      expect(gateway.committedRecoveryRuntimeIds, isEmpty);
      expect(gateway.submitCalls, 1);
      expect(gateway.createForFirstSubmitCalls, 0);
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

  test('Stop de fallback REST usa stopRun y no reanuda Desktop', () async {
    final gateway = _LifecycleRecoverableGateway()
      ..resumeSessionError = StateError('desktop unavailable')
      ..resumeExistingError = StateError('desktop unavailable')
      ..createForFirstSubmitError = StateError('desktop unavailable');
    final api = _RestFallbackApiClient();
    final chat = _recoverableChat('rest-fallback-cancel', gateway, api: api);
    addTearDown(chat.dispose);
    final delivery = _delivery('rest-fallback-cancel', _NoopOutbox());

    final accepted = await chat.send(
      fullText: 'turno REST',
      model: 'hermes-agent',
      history: const [],
      delivery: delivery,
    );
    expect(accepted, isTrue);
    expect(api.startCalls, 1);
    expect(chat.currentRunId, 'rest-run');
    final resumesBeforeCancel = gateway.resumeExistingCalls;

    chat.cancel();
    await Future<void>.delayed(Duration.zero);

    expect(api.stopCalls, 1);
    expect(gateway.resumeExistingCalls, resumesBeforeCancel);
    expect(gateway.interruptCalls, 0);
  });

  test('Stop durante startRun REST espera el id y no toca Desktop', () async {
    final gateway = _LifecycleRecoverableGateway()
      ..resumeSessionError = StateError('desktop unavailable')
      ..resumeExistingError = StateError('desktop unavailable')
      ..createForFirstSubmitError = StateError('desktop unavailable');
    final api = _RestFallbackApiClient()..startGate = Completer<String>();
    final chat = _recoverableChat('rest-start-cancel', gateway, api: api);
    addTearDown(chat.dispose);
    final delivery = _delivery('rest-start-cancel', _NoopOutbox());

    final send = chat.send(
      fullText: 'turno REST lento',
      model: 'hermes-agent',
      history: const [],
      delivery: delivery,
    );
    await _waitUntil(() => api.startCalls == 1);
    expect(delivery.current.transport, PreparedTurnTransport.rest);
    expect(chat.currentRunId, isNull);
    final resumesBeforeCancel = gateway.resumeExistingCalls;

    chat.cancel();
    api.startGate!.complete('rest-run-late');
    expect(await send, isFalse);
    await Future<void>.delayed(Duration.zero);

    expect(api.stopCalls, 1);
    expect(gateway.resumeExistingCalls, resumesBeforeCancel);
    expect(gateway.interruptCalls, 0);
  });

  test('cancel offline legacy no usa resumeSession que puede crear', () async {
    final gateway = _RecoverableDesktopGateway()
      ..hangingInterruptsRemaining = 1;
    final chat = _recoverableChat(
      'legacy-cancel-no-create',
      gateway,
      desktopRecoveryAttemptTimeout: const Duration(milliseconds: 20),
      desktopRecoveryBackoff: const [Duration.zero, Duration(milliseconds: 1)],
    );
    addTearDown(chat.dispose);

    await chat.send(
      fullText: 'turno legacy',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('legacy-cancel-no-create', _NoopOutbox()),
    );
    final resumesBeforeCancel = gateway.resumeCalls;

    chat.cancel();
    await _waitUntil(() => gateway.interruptCalls == 1);
    await Future<void>.delayed(const Duration(milliseconds: 70));

    expect(gateway.resumeCalls, resumesBeforeCancel);
    expect(gateway.interruptCalls, 1);
  });

  test('cancel tras perder el runtime reanuda el stored id sin crear', () async {
    final gateway = _LifecycleRecoverableGateway()
      ..recoveryExistingGate = Completer<DesktopSessionSnapshot>();
    final chat = _recoverableChat(
      'cancel-runtime-retired',
      gateway,
      desktopRecoveryAttemptTimeout: const Duration(milliseconds: 60),
      desktopRecoveryBackoff: const [Duration.zero, Duration(milliseconds: 1)],
    );
    addTearDown(chat.dispose);

    await chat.send(
      fullText: 'turno viejo',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('cancel-runtime-retired', _NoopOutbox()),
    );
    final createsBeforeCancel = gateway.createForFirstSubmitCalls;
    gateway.drop();
    await _waitUntil(() => chat.desktopRuntimeSessionId == null);

    chat.cancel();
    gateway.recoveryExistingGate!.complete(
      const DesktopSessionBinding(
        runtimeSessionId: 'runtime-recovered-after-cancel',
        storedSessionId: 'cancel-runtime-retired',
        created: false,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(
      gateway.interruptedRuntimeIds,
      contains('runtime-recovered-after-cancel'),
      reason:
          'resumeCalls=${gateway.resumeExistingCalls} state=${chat.state} runtime=${chat.desktopRuntimeSessionId}',
    );

    expect(gateway.createForFirstSubmitCalls, createsBeforeCancel);
    expect(
      gateway.resumeExistingStoredIds,
      contains('session-cancel-runtime-retired'),
    );
    expect(chat.state, ChatPipelineState.cancelled);
  });

  test(
    'cancel offline reata la sesión e interrumpe el runtime recuperado',
    () async {
      final gateway = _LifecycleRecoverableGateway()
        ..hangingInterruptsRemaining = 1;
      final chat = _recoverableChat(
        'cancel-offline',
        gateway,
        desktopRecoveryAttemptTimeout: const Duration(milliseconds: 20),
        desktopRecoveryBackoff: const [
          Duration.zero,
          Duration(milliseconds: 10),
        ],
      );
      addTearDown(chat.dispose);

      await chat.send(
        fullText: 'trabajo largo',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('cancel-offline', _NoopOutbox()),
      );
      expect(chat.isStreaming, isTrue);
      final createsBeforeCancel = gateway.createForFirstSubmitCalls;

      chat.cancel();

      await _waitUntil(
        () => gateway.resumeExistingCalls >= 1 && gateway.interruptCalls >= 2,
        timeout: const Duration(milliseconds: 500),
      );
      expect(chat.state, ChatPipelineState.cancelled);
      expect(gateway.connectCalls, greaterThanOrEqualTo(2));
      expect(gateway.resumeExistingCalls, greaterThanOrEqualTo(1));
      expect(gateway.interruptedRuntimeIds, hasLength(2));
      expect(
        gateway.interruptedRuntimeIds.last,
        startsWith('runtime-recovery-'),
      );
      expect(gateway.committedRecoveryRuntimeIds, [
        gateway.interruptedRuntimeIds.last,
      ]);
      expect(gateway.createForFirstSubmitCalls, createsBeforeCancel);
      expect(gateway.submitCalls, 1);
    },
  );

  test(
    'un turno nuevo espera a que el cancel offline quede entregado',
    () async {
      final gateway = _LifecycleRecoverableGateway()
        ..hangingInterruptsRemaining = 1;
      final chat = _recoverableChat(
        'cancel-before-next',
        gateway,
        desktopRecoveryAttemptTimeout: const Duration(milliseconds: 30),
        desktopRecoveryBackoff: const [
          Duration.zero,
          Duration(milliseconds: 10),
        ],
      );
      addTearDown(chat.dispose);

      await chat.send(
        fullText: 'turno viejo',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('cancel-before-next', _NoopOutbox()),
      );
      chat.cancel();
      final next = chat.send(
        fullText: 'turno nuevo',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('cancel-before-next-2', _NoopOutbox()),
      );

      await _waitUntil(() => gateway.interruptCalls == 2);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(gateway.submitCalls, 1);
      final recoveredRuntimeId = gateway.interruptedRuntimeIds.last;
      gateway.emit(
        'message.complete',
        sessionId: recoveredRuntimeId,
        payload: const {'text': 'Operation interrupted.'},
      );
      await next.timeout(const Duration(milliseconds: 500));
      expect(gateway.interruptCalls, 2);
      expect(gateway.submitCalls, 2);
    },
  );

  test('error terminal al cancelar retira el runtime muerto', () async {
    final gateway = _LifecycleRecoverableGateway()
      ..interruptErrorsRemaining = 1
      ..interruptError = const TuiGatewayRpcError(
        'session.interrupt',
        'session not found',
        code: 4007,
      );
    final chat = _recoverableChat(
      'cancel-terminal-error',
      gateway,
      desktopRecoveryAttemptTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(chat.dispose);

    await chat.send(
      fullText: 'turno perdido',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('cancel-terminal-error', _NoopOutbox()),
    );
    expect(chat.desktopRuntimeSessionId, isNotNull);

    chat.cancel();
    await _waitUntil(() => gateway.interruptCalls == 1);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(chat.desktopRuntimeSessionId, isNull);
  });

  test(
    'terminal ausente retira el runtime antes del turno siguiente',
    () async {
      final gateway = _LifecycleRecoverableGateway();
      final chat = _recoverableChat(
        'cancel-terminal-timeout',
        gateway,
        desktopRecoveryAttemptTimeout: const Duration(milliseconds: 30),
        desktopRecoveryBackoff: const [Duration.zero],
      );
      addTearDown(chat.dispose);

      await chat.send(
        fullText: 'turno viejo',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('cancel-terminal-timeout', _NoopOutbox()),
      );
      final oldRuntimeId = gateway.submittedRuntimeIds.single;
      chat.cancel();

      await chat
          .send(
            fullText: 'turno nuevo',
            model: 'hermes-agent',
            history: const [],
            delivery: _delivery('cancel-terminal-timeout-2', _NoopOutbox()),
          )
          .timeout(const Duration(milliseconds: 300));

      expect(gateway.submittedRuntimeIds, hasLength(2));
      expect(gateway.submittedRuntimeIds.last, isNot(oldRuntimeId));
      gateway.emit(
        'message.complete',
        sessionId: oldRuntimeId,
        payload: const {'text': 'STALE_OLD_TURN'},
      );
      await Future<void>.delayed(Duration.zero);
      expect(chat.isStreaming, isTrue);
      expect(
        chat.messages.any((message) => message['content'] == 'STALE_OLD_TURN'),
        isFalse,
      );
    },
  );

  test('dispose detiene el reintento de cancel offline', () async {
    final gateway = _LifecycleRecoverableGateway()
      ..hangingInterruptsRemaining = 10;
    final chat = _recoverableChat(
      'cancel-dispose',
      gateway,
      desktopRecoveryAttemptTimeout: const Duration(milliseconds: 30),
      desktopRecoveryBackoff: const [Duration.zero, Duration(milliseconds: 10)],
    );

    await chat.send(
      fullText: 'turno desechado',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('cancel-dispose', _NoopOutbox()),
    );
    chat.cancel();
    await _waitUntil(() => gateway.interruptCalls == 1);
    final next = chat.send(
      fullText: 'no debe salir',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('cancel-dispose-2', _NoopOutbox()),
    );

    chat.dispose();
    expect(await next.timeout(const Duration(milliseconds: 200)), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(gateway.interruptCalls, 1);
    expect(gateway.resumeExistingCalls, 0);
    expect(gateway.submitCalls, 1);
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
