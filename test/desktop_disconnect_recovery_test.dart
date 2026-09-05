import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/utils/chat_turn.dart';

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

  /// Android congela el isolate al minimizar: el socket muere pero su cierre
  /// nunca se entrega y el heartbeat tampoco corre, así que el chat no recibe
  /// ninguna señal de error.
  void dropSilently() {
    _connected = false;
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
    String? requestId,
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
  DesktopSessionSnapshot? initialSnapshot;
  DesktopSessionSnapshot? recoverySnapshot;
  final List<({String runtimeId, String text})> steers = [];

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
    return initialSnapshot ??
        DesktopSessionBinding(
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
          recoverySnapshot ??
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

  @override
  Future<void> steer(String runtimeSessionId, String text) async {
    steers.add((runtimeId: runtimeSessionId, text: text));
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
  Future<SessionMessagesPage> getMessagesPage(
    String sessionId, {
    int limit = 120,
    int offset = 0,
  }) async => SessionMessagesPage(
    messages: await getMessages(sessionId),
    pagination: null,
  );

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

class _ToolThenFinalTranscriptApi extends ApiClient {
  _ToolThenFinalTranscriptApi()
    : super(baseUrl: 'http://127.0.0.1:8642', apiKey: 'test-key');

  final firstRead = Completer<void>();
  final finalReady = Completer<void>();
  int calls = 0;

  @override
  Future<List<Map<String, dynamic>>> getMessages(String sessionId) async {
    calls++;
    if (calls == 1) {
      if (!firstRead.isCompleted) firstRead.complete();
      return const [
        {'message_id': 'tool-user', 'role': 'user', 'content': 'usa tool'},
        {
          'message_id': 'tool-call',
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {'id': 'call-1', 'name': 'lookup'},
          ],
        },
        {
          'message_id': 'tool-result',
          'role': 'tool',
          'content': 'resultado intermedio',
        },
      ];
    }
    await finalReady.future;
    return const [
      {'message_id': 'tool-user', 'role': 'user', 'content': 'usa tool'},
      {
        'message_id': 'tool-call',
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {'id': 'call-1', 'name': 'lookup'},
        ],
      },
      {
        'message_id': 'tool-result',
        'role': 'tool',
        'content': 'resultado intermedio',
      },
      {
        'message_id': 'tool-final',
        'role': 'assistant',
        'content': 'respuesta final durable',
      },
    ];
  }

  @override
  void close() {}
}

class _PartialTailApi extends ApiClient {
  _PartialTailApi(this.rows)
    : super(baseUrl: 'http://127.0.0.1:8642', apiKey: 'test-key');

  final List<Map<String, dynamic>> rows;
  final List<int> requestedOffsets = [];

  @override
  Future<SessionMessagesPage> getMessagesPage(
    String sessionId, {
    int limit = 120,
    int offset = 0,
  }) async {
    requestedOffsets.add(offset);
    return SessionMessagesPage(
      messages: rows,
      pagination: {'limit': limit, 'offset': offset},
    );
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
    if (terminal) {
      final failure = chat.messages.firstWhere(
        (message) => message['role'] == 'assistant_error',
      );
      expect(
        failure['content'],
        'Could not recover the turn. Please try again.',
      );
      expect(failure['content'], isNot(contains(error.toString())));
    }
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

  test('turno reanudado sin outbox reconecta tras socket drop', () async {
    final recoveryGate = Completer<DesktopSessionSnapshot>();
    final gateway = _LifecycleRecoverableGateway()
      ..initialSnapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-desktop-1',
        storedSessionId: 'session-desktop-owned',
        created: false,
        messagesProvided: true,
        messages: [
          DesktopSessionMessage.tryParse(const {
            'role': 'user',
            'content': 'turno iniciado en Desktop',
          })!,
        ],
        inflight: DesktopInflightTurn(
          user: 'turno iniciado en Desktop',
          streaming: true,
        ),
        running: true,
      )
      ..recoveryExistingGate = recoveryGate;
    final chat = _recoverableChat('desktop-owned', gateway);
    addTearDown(chat.dispose);

    await chat.loadMessages();
    expect(chat.isStreaming, isTrue);
    expect(chat.desktopRuntimeSessionId, 'runtime-desktop-1');
    gateway.emit(
      'tool.start',
      sessionId: 'runtime-desktop-1',
      payload: const {'name': 'terminal'},
    );
    await _waitUntil(() => chat.trace.isNotEmpty);

    gateway.drop();
    await _waitUntil(() => gateway.resumeExistingCalls == 2);
    expect(chat.state, ChatPipelineState.connecting);

    final steer = chat.steer('ajuste durante recovery');
    await Future<void>.delayed(Duration.zero);
    expect(gateway.steers, isEmpty);
    recoveryGate.complete(
      DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-desktop-2',
        storedSessionId: 'session-desktop-owned',
        created: false,
        messagesProvided: true,
        messages: [
          DesktopSessionMessage.tryParse(const {
            'role': 'user',
            'content': 'turno iniciado en Desktop',
          })!,
        ],
        inflight: DesktopInflightTurn(
          user: 'turno iniciado en Desktop',
          streaming: true,
        ),
        running: true,
      ),
    );
    await steer.timeout(const Duration(seconds: 1));
    expect(gateway.connectCalls, 2);
    expect(gateway.committedRecoveryRuntimeIds, ['runtime-desktop-2']);
    expect(gateway.steers, [
      (runtimeId: 'runtime-desktop-2', text: 'ajuste durante recovery'),
    ]);

    gateway.emit(
      'tool.complete',
      sessionId: 'runtime-desktop-2',
      payload: const {'name': 'terminal', 'preview': 'ok'},
    );
    gateway.emit(
      'message.complete',
      sessionId: 'runtime-desktop-2',
      payload: const {'text': 'respuesta tras reconectar'},
    );
    await _waitUntil(() => chat.state == ChatPipelineState.completed);
    expect(chat.assistantContent, 'respuesta tras reconectar');
    expect(
      chat.messages.any(
        (message) => message['content'].toString().contains('StateError'),
      ),
      isFalse,
    );
  });

  test(
    'snapshot terminal de recovery backfillea y sella actividad viva',
    () async {
      final gateway = _LifecycleRecoverableGateway()
        ..initialSnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-terminal-1',
          storedSessionId: 'session-terminal-snapshot',
          created: false,
          messagesProvided: true,
          messages: [
            DesktopSessionMessage.tryParse(const {
              'role': 'user',
              'content': 'termina fuera del socket',
            })!,
          ],
          inflight: DesktopInflightTurn(
            user: 'termina fuera del socket',
            streaming: true,
          ),
          running: true,
        )
        ..recoverySnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-terminal-2',
          storedSessionId: 'session-terminal-snapshot',
          created: false,
          messagesProvided: true,
          messages: [
            DesktopSessionMessage.tryParse(const {
              'role': 'user',
              'content': 'termina fuera del socket',
            })!,
            DesktopSessionMessage.tryParse(const {
              'role': 'assistant',
              'content': 'respuesta durable final',
            })!,
          ],
          running: false,
          status: 'completed',
        );
      final chat = _recoverableChat('terminal-snapshot', gateway);
      addTearDown(chat.dispose);

      await chat.loadMessages();
      gateway.emit(
        'tool.start',
        sessionId: 'runtime-terminal-1',
        payload: const {'name': 'terminal'},
      );
      gateway.emit(
        'subagent.start',
        sessionId: 'runtime-terminal-1',
        payload: const {
          'subagent_id': 'child-terminal-snapshot',
          'status': 'running',
        },
      );
      await _waitUntil(
        () => chat.trace.isNotEmpty && chat.subagentActivities.isNotEmpty,
      );

      gateway.drop();
      await _waitUntil(() => chat.state == ChatPipelineState.completed);

      expect(chat.assistantContent, 'respuesta durable final');
      expect(chat.trace.single.status, 'completed');
      expect(
        chat.subagentActivities.single.phase,
        SubagentActivityPhase.completed,
      );
      expect(
        chat.messages.any(
          (message) => message['content'].toString().contains('StateError'),
        ),
        isFalse,
      );
    },
  );

  test(
    'snapshot terminal parcial espera el transcript durable y no sella el parcial',
    () async {
      var transcriptCalls = 0;
      final gateway = _LifecycleRecoverableGateway()
        ..initialSnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-terminal-partial-1',
          storedSessionId: 'session-terminal-partial',
          created: false,
          messagesProvided: true,
          messages: const [],
          inflight: DesktopInflightTurn(
            user: 'termina con snapshot parcial',
            assistant: 'respuesta local incompleta',
            streaming: true,
          ),
          running: true,
        )
        ..recoverySnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-terminal-partial-2',
          storedSessionId: 'session-terminal-partial',
          created: false,
          messagesProvided: true,
          messageCount: 300,
          messages: [
            DesktopSessionMessage.tryParse(const {
              'message_id': 'terminal-partial-user',
              'role': 'user',
              'content': 'termina con snapshot parcial',
            })!,
            DesktopSessionMessage.tryParse(const {
              'message_id': 'terminal-partial-answer',
              'role': 'assistant',
              'content': 'respuesta durable definitiva',
            })!,
          ],
          running: false,
          status: 'completed',
        );
      final chat = _recoverableChat(
        'terminal-partial',
        gateway,
        storedMessageLoader: (_, _) async {
          if (transcriptCalls++ == 0) return const [];
          return const [
            {
              'message_id': 'terminal-partial-user',
              'role': 'user',
              'content': 'termina con snapshot parcial',
            },
            {
              'message_id': 'terminal-partial-answer',
              'role': 'assistant',
              'content': 'respuesta durable definitiva',
            },
          ];
        },
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 300);
      expect(chat.assistantContent, 'respuesta local incompleta');

      gateway.drop();
      await _waitUntil(
        () => chat.state == ChatPipelineState.completed,
        timeout: const Duration(seconds: 6),
      );

      expect(chat.assistantContent, 'respuesta durable definitiva');
      expect(
        chat.messages.any(
          (message) => message['content'] == 'respuesta local incompleta',
        ),
        isFalse,
      );
      expect(chat.hasEarlierMessages, isFalse);
    },
  );

  test(
    'snapshot terminal parcial sin user conserva el prompt hasta REST completo',
    () async {
      final transcriptGate = Completer<List<Map<String, dynamic>>>();
      var transcriptCalls = 0;
      final gateway = _LifecycleRecoverableGateway()
        ..initialSnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-terminal-no-user-1',
          storedSessionId: 'session-terminal-no-user',
          created: false,
          messagesProvided: true,
          messages: const [],
          inflight: DesktopInflightTurn(
            user: 'prompt que no puede desaparecer',
            assistant: 'parcial todavía visible',
            streaming: true,
          ),
          running: true,
        )
        ..recoverySnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-terminal-no-user-2',
          storedSessionId: 'session-terminal-no-user',
          created: false,
          messagesProvided: true,
          messageCount: 300,
          messages: [
            DesktopSessionMessage.tryParse(const {
              'message_id': 'terminal-no-user-final',
              'role': 'assistant',
              'content': 'final cuya página omitió el user',
            })!,
          ],
          running: false,
          status: 'completed',
        );
      final chat = _recoverableChat(
        'terminal-no-user',
        gateway,
        storedMessageLoader: (_, _) {
          if (transcriptCalls++ == 0) {
            return Future.value(const []);
          }
          return transcriptGate.future;
        },
      );
      addTearDown(chat.dispose);

      await chat.loadMessages();
      gateway.drop();
      await _waitUntil(
        () => gateway.committedRecoveryRuntimeIds.contains(
          'runtime-terminal-no-user-2',
        ),
      );

      expect(chat.state, isNot(ChatPipelineState.completed));
      expect(
        chat.messages.any(
          (message) => message['content'] == 'prompt que no puede desaparecer',
        ),
        isTrue,
      );
      transcriptGate.complete(const [
        {
          'message_id': 'terminal-no-user-current',
          'role': 'user',
          'content': 'prompt que no puede desaparecer',
        },
        {
          'message_id': 'terminal-no-user-final',
          'role': 'assistant',
          'content': 'final cuya página omitió el user',
        },
      ]);
      await _waitUntil(() => chat.state == ChatPipelineState.completed);
      expect(chat.assistantContent, 'final cuya página omitió el user');
    },
  );

  test(
    'snapshot terminal parcial sin assistant final no sella un tool intermedio',
    () async {
      final transcriptGate = Completer<List<Map<String, dynamic>>>();
      var transcriptCalls = 0;
      final gateway = _LifecycleRecoverableGateway()
        ..initialSnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-terminal-tool-tail-1',
          storedSessionId: 'session-terminal-tool-tail',
          created: false,
          messagesProvided: true,
          messages: const [],
          inflight: DesktopInflightTurn(
            user: 'espera el assistant final',
            streaming: true,
          ),
          running: true,
        )
        ..recoverySnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-terminal-tool-tail-2',
          storedSessionId: 'session-terminal-tool-tail',
          created: false,
          messagesProvided: true,
          messageCount: 300,
          messages: [
            DesktopSessionMessage.tryParse(const {
              'message_id': 'terminal-tool-tail-user',
              'role': 'user',
              'content': 'espera el assistant final',
            })!,
            DesktopSessionMessage.tryParse(const {
              'message_id': 'terminal-tool-tail-call',
              'role': 'assistant',
              'content': '',
              'tool_calls': [
                {
                  'id': 'call-intermediate',
                  'function': {'name': 'search', 'arguments': '{}'},
                },
              ],
            })!,
            DesktopSessionMessage.tryParse(const {
              'message_id': 'terminal-tool-tail-result',
              'role': 'tool',
              'tool_call_id': 'call-intermediate',
              'content': 'resultado aún intermedio',
            })!,
          ],
          running: false,
          status: 'completed',
        );
      final chat = _recoverableChat(
        'terminal-tool-tail',
        gateway,
        storedMessageLoader: (_, _) {
          if (transcriptCalls++ == 0) {
            return Future.value(const []);
          }
          return transcriptGate.future;
        },
      );
      addTearDown(chat.dispose);

      await chat.loadMessages();
      gateway.drop();
      await _waitUntil(
        () => gateway.committedRecoveryRuntimeIds.contains(
          'runtime-terminal-tool-tail-2',
        ),
      );

      expect(chat.state, isNot(ChatPipelineState.completed));
      transcriptGate.complete(const [
        {
          'message_id': 'terminal-tool-tail-user',
          'role': 'user',
          'content': 'espera el assistant final',
        },
        {
          'message_id': 'terminal-tool-tail-final',
          'role': 'assistant',
          'content': 'assistant final ya durable',
        },
      ]);
      await _waitUntil(() => chat.state == ChatPipelineState.completed);
      expect(chat.assistantContent, 'assistant final ya durable');
    },
  );

  test('snapshot fallido de recovery no expone el error técnico', () async {
    const secret = '/home/private-user/session-token';
    final gateway = _LifecycleRecoverableGateway()
      ..initialSnapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-private-failure-1',
        storedSessionId: 'session-private-failure',
        created: false,
        messagesProvided: true,
        messages: [
          DesktopSessionMessage.tryParse(const {
            'message_id': 'private-failure-user',
            'role': 'user',
            'content': 'turno privado',
          })!,
        ],
        inflight: DesktopInflightTurn(user: 'turno privado', streaming: true),
        running: true,
      )
      ..recoverySnapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-private-failure-2',
        storedSessionId: 'session-private-failure',
        created: false,
        messagesProvided: false,
        inflight: DesktopInflightTurn(
          user: 'turno privado',
          error: 'StateError: $secret',
          status: 'error',
          recoverable: true,
        ),
        running: false,
        status: 'error',
      );
    final chat = _recoverableChat('private-recovery-failure', gateway);
    addTearDown(chat.dispose);

    await chat.loadMessages();
    gateway.drop();
    await _waitUntil(() => chat.state == ChatPipelineState.failed);

    final error = chat.messages.firstWhere(
      (message) => message['role'] == 'assistant_error',
    );
    expect(
      error['content'],
      'Could not recover the turn. Please try again.',
    );
    expect(
      chat.messages.expand((message) => message.values).join(' '),
      isNot(contains(secret)),
    );
  });

  test(
    'recovery sin mensajes no trata una cola parcial como transcript completo',
    () async {
      final partialTail = <Map<String, dynamic>>[
        const {
          'id': 'partial-oldest-user',
          'role': 'user',
          'content': 'prompt repetido en una cola parcial',
        },
        const {
          'id': 'legitimate-tail-answer',
          'role': 'assistant',
          'content': 'respuesta legítima visible',
        },
        for (var index = 0; index < 118; index++)
          {
            'id': 'partial-system-$index',
            'role': 'system',
            'content': 'contexto parcial $index',
          },
      ];
      final gateway = _LifecycleRecoverableGateway()
        ..initialSnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-partial-1',
          storedSessionId: 'session-recovery-partial',
          created: false,
          messagesProvided: false,
          messageCount: 300,
          inflight: DesktopInflightTurn(
            user: 'turno activo posterior',
            streaming: true,
          ),
          running: true,
        )
        ..recoverySnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-partial-2',
          storedSessionId: 'session-recovery-partial',
          created: false,
          messagesProvided: false,
          messageCount: 300,
          inflight: DesktopInflightTurn(
            user: 'turno activo posterior',
            streaming: true,
          ),
          running: true,
        );
      final chat = _recoverableChat(
        'recovery-partial',
        gateway,
        api: _PartialTailApi(partialTail),
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(
            content: 'prompt repetido en una cola parcial',
            firstUser: true,
          ),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 300);
      expect(chat.hasEarlierMessages, isTrue);
      expect(
        chat.messages.any(
          (message) => message['id'] == 'legitimate-tail-answer',
        ),
        isTrue,
      );

      gateway.drop();
      await _waitUntil(
        () => gateway.committedRecoveryRuntimeIds.contains('runtime-partial-2'),
      );

      expect(chat.hasEarlierMessages, isTrue);
      expect(
        chat.messages.any(
          (message) => message['id'] == 'legitimate-tail-answer',
        ),
        isTrue,
      );
      expect(
        chat.messages
            .singleWhere((message) => message['id'] == 'partial-oldest-user')
            .containsKey('_cancelledUser'),
        isFalse,
      );
    },
  );

  test(
    'snapshot con fila descartada no aplica firstUser al prompt repetido visible',
    () async {
      final snapshot = DesktopSessionSnapshot.fromJson(
        const {
          'session_id': 'runtime-malformed-transcript',
          'session_key': 'session-malformed-transcript',
          'messages': [
            {
              'message_id': 'cancelled-user-malformed',
              'content': 'prompt repetido',
            },
            {
              'message_id': 'old-answer',
              'role': 'assistant',
              'content': 'respuesta del turno anterior',
            },
            {
              'message_id': 'legitimate-user',
              'role': 'user',
              'content': 'prompt repetido',
            },
            {
              'message_id': 'legitimate-answer',
              'role': 'assistant',
              'content': 'respuesta legítima que debe seguir visible',
            },
          ],
        },
        requestedStoredSessionId: 'session-malformed-transcript',
        created: false,
        method: 'session.resume',
      );
      final gateway = _LifecycleRecoverableGateway()
        ..initialSnapshot = snapshot;
      final chat = _recoverableChat(
        'malformed-transcript',
        gateway,
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(content: 'prompt repetido', firstUser: true),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages();

      expect(
        chat.messages.any(
          (message) =>
              message['_desktopMessageId'] == 'legitimate-answer' &&
              message['content'] ==
                  'respuesta legítima que debe seguir visible',
        ),
        isTrue,
      );
      final repeatedUser = chat.messages.singleWhere(
        (message) => message['_desktopMessageId'] == 'legitimate-user',
      );
      expect(repeatedUser.containsKey('_cancelledUser'), isFalse);
    },
  );

  test(
    'recovery hydrating conserva la cola parcial hasta tener historial completo',
    () async {
      final partialTail = <Map<String, dynamic>>[
        const {
          'id': 'hydrating-oldest-user',
          'role': 'user',
          'content': 'prompt visible durante hydration',
        },
        const {
          'id': 'hydrating-legitimate-answer',
          'role': 'assistant',
          'content': 'respuesta legítima durante hydration',
        },
        for (var index = 0; index < 118; index++)
          {
            'id': 'hydrating-system-$index',
            'role': 'system',
            'content': 'contexto hydrating $index',
          },
      ];
      final gateway = _LifecycleRecoverableGateway()
        ..initialSnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-hydrating-1',
          storedSessionId: 'session-recovery-hydrating',
          created: false,
          messagesProvided: false,
          messageCount: 300,
          inflight: DesktopInflightTurn(
            user: 'turno activo durante hydration',
            streaming: true,
          ),
          running: true,
        )
        ..recoverySnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-hydrating-2',
          storedSessionId: 'session-recovery-hydrating',
          created: false,
          messagesProvided: true,
          messageCount: 300,
          hydrating: true,
          inflight: DesktopInflightTurn(
            user: 'turno activo durante hydration',
            streaming: true,
          ),
          running: true,
        );
      final chat = _recoverableChat(
        'recovery-hydrating',
        gateway,
        api: _PartialTailApi(partialTail),
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(
            content: 'prompt visible durante hydration',
            firstUser: true,
          ),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 300);
      gateway.drop();
      await _waitUntil(
        () =>
            gateway.committedRecoveryRuntimeIds.contains('runtime-hydrating-2'),
      );

      expect(chat.isHydratingDesktopHistory, isTrue);
      expect(chat.hasEarlierMessages, isTrue);
      expect(
        chat.messages.any(
          (message) => message['id'] == 'hydrating-legitimate-answer',
        ),
        isTrue,
      );
      expect(
        chat.messages
            .singleWhere((message) => message['id'] == 'hydrating-oldest-user')
            .containsKey('_cancelledUser'),
        isFalse,
      );

      partialTail.add(const {
        'id': 'hydrated-final-tail-answer',
        'role': 'assistant',
        'content': 'cola final adoptada tras recovery',
      });
      gateway.emit(
        'session.resume_progress',
        sessionId: 'runtime-hydrating-2',
        payload: const {'status': 'complete', 'message_count': 301},
      );
      await _waitUntil(
        () => chat.messages.any(
          (message) => message['id'] == 'hydrated-final-tail-answer',
        ),
      );

      expect(chat.isHydratingDesktopHistory, isFalse);
      expect(
        chat.messages.firstWhere(
          (message) => message['id'] == 'hydrated-final-tail-answer',
        )['content'],
        'cola final adoptada tras recovery',
      );
    },
  );

  test(
    'recovery hydrating degrada un fallback antes completo sin borrarlo',
    () async {
      final initialRows = <DesktopSessionMessage>[
        DesktopSessionMessage.tryParse(const {
          'message_id': 'recovery-complete-user',
          'role': 'user',
          'content': 'pregunta durable anterior',
        })!,
        DesktopSessionMessage.tryParse(const {
          'message_id': 'recovery-complete-answer',
          'role': 'assistant',
          'content': 'respuesta durable anterior',
        })!,
      ];
      final gateway = _LifecycleRecoverableGateway()
        ..initialSnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-complete-before-hydrating',
          storedSessionId: 'session-complete-before-hydrating',
          created: false,
          messagesProvided: true,
          messages: initialRows,
          messageCount: 2,
          inflight: DesktopInflightTurn(
            user: 'turno activo posterior',
            streaming: true,
          ),
          running: true,
        )
        ..recoverySnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-recovery-now-hydrating',
          storedSessionId: 'session-complete-before-hydrating',
          created: false,
          messagesProvided: true,
          messages: [
            DesktopSessionMessage.tryParse(const {
              'message_id': 'partial-during-recovery',
              'role': 'user',
              'content': 'ventana parcial durante recovery',
            })!,
          ],
          messageCount: 300,
          hydrating: true,
          inflight: DesktopInflightTurn(
            user: 'turno activo posterior',
            streaming: true,
          ),
          running: true,
        );
      final chat = _recoverableChat('complete-to-hydrating', gateway);
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      expect(chat.hasEarlierMessages, isFalse);
      gateway.drop();
      await _waitUntil(
        () => gateway.committedRecoveryRuntimeIds.contains(
          'runtime-recovery-now-hydrating',
        ),
      );

      expect(chat.hasEarlierMessages, isTrue);
      expect(
        chat.messages.any(
          (message) =>
              message['_desktopMessageId'] == 'recovery-complete-answer',
        ),
        isTrue,
      );
    },
  );

  test(
    'recovery omitido con count menor degrada el fallback completo',
    () async {
      final initialRows = <DesktopSessionMessage>[
        DesktopSessionMessage.tryParse(const {
          'message_id': 'recovery-compacted-user',
          'role': 'user',
          'content': 'prompt original',
        })!,
        DesktopSessionMessage.tryParse(const {
          'message_id': 'recovery-compacted-answer',
          'role': 'assistant',
          'content': 'respuesta legítima tras recovery',
        })!,
      ];
      final gateway = _LifecycleRecoverableGateway()
        ..initialSnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-before-recovery-compaction',
          storedSessionId: 'session-recovery-smaller-count',
          created: false,
          messagesProvided: true,
          messages: initialRows,
          messageCount: 2,
          inflight: DesktopInflightTurn(
            user: 'turno activo posterior',
            streaming: true,
          ),
          running: true,
        )
        ..recoverySnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-after-recovery-compaction',
          storedSessionId: 'session-recovery-smaller-count',
          created: false,
          messagesProvided: false,
          messageCount: 1,
          inflight: DesktopInflightTurn(
            user: 'turno activo posterior',
            streaming: true,
          ),
          running: true,
        );
      final chat = _recoverableChat(
        'recovery-smaller-count',
        gateway,
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(
            content: 'prompt repetido tras compactación',
            firstUser: true,
          ),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      expect(chat.hasEarlierMessages, isFalse);
      final userIndex = chat.messages.indexWhere(
        (message) => message['_desktopMessageId'] == 'recovery-compacted-user',
      );
      chat.messages[userIndex] = {
        ...chat.messages[userIndex],
        'content': 'prompt repetido tras compactación',
      };

      gateway.drop();
      await _waitUntil(
        () => gateway.committedRecoveryRuntimeIds.contains(
          'runtime-after-recovery-compaction',
        ),
      );

      expect(
        chat.messages.any(
          (message) =>
              message['_desktopMessageId'] == 'recovery-compacted-answer' &&
              message['content'] == 'respuesta legítima tras recovery',
        ),
        isTrue,
      );
      expect(
        chat.messages
            .singleWhere(
              (message) =>
                  message['_desktopMessageId'] == 'recovery-compacted-user',
            )
            .containsKey('_cancelledUser'),
        isFalse,
      );
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test(
    'recovery omitido no acredita count contra una fila durable sin id',
    () async {
      final initialRows = <DesktopSessionMessage>[
        DesktopSessionMessage.tryParse(const {
          'message_id': 'recovery-idless-coverage-user',
          'role': 'user',
          'content': 'prompt original',
        })!,
        DesktopSessionMessage.tryParse(const {
          'role': 'assistant',
          'content': 'respuesta legítima idless tras recovery',
        })!,
      ];
      final gateway = _LifecycleRecoverableGateway()
        ..initialSnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-before-idless-recovery',
          storedSessionId: 'session-idless-recovery',
          created: false,
          messagesProvided: true,
          messages: initialRows,
          messageCount: 2,
          inflight: DesktopInflightTurn(
            user: 'turno activo posterior',
            streaming: true,
          ),
          running: true,
        )
        ..recoverySnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-after-idless-recovery',
          storedSessionId: 'session-idless-recovery',
          created: false,
          messagesProvided: false,
          messageCount: 1,
          inflight: DesktopInflightTurn(
            user: 'turno activo posterior',
            streaming: true,
          ),
          running: true,
        );
      final chat = _recoverableChat(
        'recovery-idless-coverage',
        gateway,
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(
            content: 'prompt repetido tras recovery idless',
            firstUser: true,
          ),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      expect(chat.hasEarlierMessages, isFalse);
      final userIndex = chat.messages.indexWhere(
        (message) =>
            message['_desktopMessageId'] == 'recovery-idless-coverage-user',
      );
      chat.messages[userIndex] = {
        ...chat.messages[userIndex],
        'content': 'prompt repetido tras recovery idless',
      };

      gateway.drop();
      await _waitUntil(
        () => gateway.committedRecoveryRuntimeIds.contains(
          'runtime-after-idless-recovery',
        ),
      );

      expect(
        chat.messages.any(
          (message) =>
              message['content'] == 'respuesta legítima idless tras recovery',
        ),
        isTrue,
      );
      expect(
        chat.messages
            .singleWhere(
              (message) =>
                  message['_desktopMessageId'] ==
                  'recovery-idless-coverage-user',
            )
            .containsKey('_cancelledUser'),
        isFalse,
      );
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test(
    'recovery provisto con count distinto no acredita transcript completo',
    () async {
      final initialRows = <DesktopSessionMessage>[
        DesktopSessionMessage.tryParse(const {
          'message_id': 'recovery-provided-mismatch-user',
          'role': 'user',
          'content': 'prompt original',
        })!,
        DesktopSessionMessage.tryParse(const {
          'message_id': 'recovery-provided-mismatch-answer',
          'role': 'assistant',
          'content': 'respuesta legítima con mismatch en recovery',
        })!,
      ];
      final mismatchedRows = <DesktopSessionMessage>[
        DesktopSessionMessage.tryParse(const {
          'message_id': 'recovery-provided-mismatch-user',
          'role': 'user',
          'content': 'prompt repetido con mismatch en recovery',
        })!,
        DesktopSessionMessage.tryParse(const {
          'message_id': 'recovery-provided-mismatch-answer',
          'role': 'assistant',
          'content': 'respuesta legítima con mismatch en recovery',
        })!,
      ];
      final gateway = _LifecycleRecoverableGateway()
        ..initialSnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-before-provided-mismatch',
          storedSessionId: 'session-provided-mismatch',
          created: false,
          messagesProvided: true,
          messages: initialRows,
          messageCount: 2,
          inflight: DesktopInflightTurn(
            user: 'turno activo posterior',
            streaming: true,
          ),
          running: true,
        )
        ..recoverySnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-after-provided-mismatch',
          storedSessionId: 'session-provided-mismatch',
          created: false,
          messagesProvided: true,
          messages: mismatchedRows,
          messageCount: 1,
          inflight: DesktopInflightTurn(
            user: 'turno activo posterior',
            streaming: true,
          ),
          running: true,
        );
      final chat = _recoverableChat(
        'recovery-provided-mismatch',
        gateway,
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(
            content: 'prompt repetido con mismatch en recovery',
            firstUser: true,
          ),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      gateway.drop();
      await _waitUntil(
        () => gateway.committedRecoveryRuntimeIds.contains(
          'runtime-after-provided-mismatch',
        ),
      );

      expect(
        chat.messages.any(
          (message) =>
              message['_desktopMessageId'] ==
                  'recovery-provided-mismatch-answer' &&
              message['content'] ==
                  'respuesta legítima con mismatch en recovery',
        ),
        isTrue,
      );
      expect(
        chat.messages
            .singleWhere(
              (message) =>
                  message['_desktopMessageId'] ==
                  'recovery-provided-mismatch-user',
            )
            .containsKey('_cancelledUser'),
        isFalse,
      );
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test(
    'recovery provisto vacío degrada el fallback visible que conserva',
    () async {
      final initialRows = <DesktopSessionMessage>[
        DesktopSessionMessage.tryParse(const {
          'message_id': 'recovery-provided-empty-user',
          'role': 'user',
          'content': 'prompt original',
        })!,
        DesktopSessionMessage.tryParse(const {
          'message_id': 'recovery-provided-empty-answer',
          'role': 'assistant',
          'content': 'respuesta legítima antes del recovery vacío',
        })!,
      ];
      final gateway = _LifecycleRecoverableGateway()
        ..initialSnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-before-recovery-provided-empty',
          storedSessionId: 'session-recovery-provided-empty',
          created: false,
          messagesProvided: true,
          messages: initialRows,
          messageCount: 2,
          inflight: DesktopInflightTurn(
            user: 'turno activo anterior',
            streaming: true,
          ),
          running: true,
        )
        ..recoverySnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-recovery-provided-empty',
          storedSessionId: 'session-recovery-provided-empty',
          created: false,
          messagesProvided: true,
          messages: [],
          messageCount: 0,
          inflight: DesktopInflightTurn(
            user: 'turno activo posterior',
            streaming: true,
          ),
          running: true,
        );
      final chat = _recoverableChat(
        'recovery-provided-empty',
        gateway,
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(
            content: 'prompt repetido antes del recovery vacío',
            firstUser: true,
          ),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      final userIndex = chat.messages.indexWhere(
        (message) =>
            message['_desktopMessageId'] == 'recovery-provided-empty-user',
      );
      chat.messages[userIndex] = {
        ...chat.messages[userIndex],
        'content': 'prompt repetido antes del recovery vacío',
      };

      gateway.drop();
      await _waitUntil(
        () => gateway.committedRecoveryRuntimeIds.contains(
          'runtime-recovery-provided-empty',
        ),
      );

      expect(
        chat.messages.any(
          (message) =>
              message['_desktopMessageId'] ==
                  'recovery-provided-empty-answer' &&
              message['content'] ==
                  'respuesta legítima antes del recovery vacío',
        ),
        isTrue,
      );
      expect(
        chat.messages
            .singleWhere(
              (message) =>
                  message['_desktopMessageId'] ==
                  'recovery-provided-empty-user',
            )
            .containsKey('_cancelledUser'),
        isFalse,
      );
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test(
    'recovery hydrating omitido no aplica firstUser sobre fallback viejo',
    () async {
      final durableRows = <Map<String, dynamic>>[
        {
          'message_id': 'recovery-stale-user',
          'role': 'user',
          'content': 'prompt aún no cancelado',
        },
        {
          'message_id': 'recovery-stale-answer',
          'role': 'assistant',
          'content': 'respuesta legítima mientras recovery hidrata',
        },
      ];
      final initialMessages = durableRows
          .map((row) => DesktopSessionMessage.tryParse(row)!)
          .toList(growable: false);
      final gateway = _LifecycleRecoverableGateway()
        ..initialSnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-stale-recovery-1',
          storedSessionId: 'session-stale-recovery',
          created: false,
          messagesProvided: true,
          messages: initialMessages,
          messageCount: 2,
          inflight: DesktopInflightTurn(
            user: 'turno activo posterior',
            streaming: true,
          ),
          running: true,
        )
        ..recoverySnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-stale-recovery-2',
          storedSessionId: 'session-stale-recovery',
          created: false,
          messagesProvided: false,
          messageCount: 2,
          hydrating: true,
          inflight: DesktopInflightTurn(
            user: 'turno activo posterior',
            streaming: true,
          ),
          running: true,
        );
      final api = _PartialTailApi(durableRows);
      final chat = _recoverableChat(
        'stale-recovery-hydrating',
        gateway,
        api: api,
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(content: 'prompt repetido', firstUser: true),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      final userIndex = chat.messages.indexWhere(
        (message) => message['message_id'] == 'recovery-stale-user',
      );
      chat.messages[userIndex] = {
        ...chat.messages[userIndex],
        'content': 'prompt repetido',
      };
      durableRows[0] = {...durableRows[0], 'content': 'prompt repetido'};

      gateway.drop();
      await _waitUntil(
        () => gateway.committedRecoveryRuntimeIds.contains(
          'runtime-stale-recovery-2',
        ),
      );

      expect(chat.isHydratingDesktopHistory, isTrue);
      expect(
        chat.messages.any(
          (message) => message['message_id'] == 'recovery-stale-answer',
        ),
        isTrue,
      );
      expect(chat.messages[userIndex].containsKey('_cancelledUser'), isFalse);

      gateway.emit(
        'session.resume_progress',
        sessionId: 'runtime-stale-recovery-2',
        payload: const {'status': 'complete', 'message_count': 2},
      );
      await _waitUntil(
        () => !chat.messages.any(
          (message) => message['message_id'] == 'recovery-stale-answer',
        ),
      );

      expect(chat.isHydratingDesktopHistory, isFalse);
      expect(
        chat.messages.singleWhere(
          (message) => message['message_id'] == 'recovery-stale-user',
        )['_cancelledUser'],
        isTrue,
      );
    },
  );

  test(
    'recovery con snapshot parcial conserva la cola visible como fallback',
    () async {
      final partialTail = <Map<String, dynamic>>[
        const {
          'id': 'partial-snapshot-oldest-user',
          'role': 'user',
          'content': 'usuario visible antes del snapshot parcial',
        },
        const {
          'id': 'partial-snapshot-legitimate-answer',
          'role': 'assistant',
          'content': 'respuesta visible antes del snapshot parcial',
        },
        for (var index = 0; index < 118; index++)
          {
            'id': 'partial-snapshot-system-$index',
            'role': 'system',
            'content': 'contexto parcial de snapshot $index',
          },
      ];
      final gateway = _LifecycleRecoverableGateway()
        ..initialSnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-partial-snapshot-1',
          storedSessionId: 'session-recovery-partial-snapshot',
          created: false,
          messagesProvided: false,
          messageCount: 300,
          inflight: DesktopInflightTurn(
            user: 'turno activo sobre cola visible',
            streaming: true,
          ),
          running: true,
        )
        ..recoverySnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-partial-snapshot-2',
          storedSessionId: 'session-recovery-partial-snapshot',
          created: false,
          messagesProvided: true,
          messages: [
            DesktopSessionMessage.tryParse(const {
              'message_id': 'only-partial-desktop-row',
              'role': 'user',
              'content': 'fila parcial no autoritativa',
            })!,
          ],
          messageCount: 300,
          inflight: DesktopInflightTurn(
            user: 'turno activo sobre cola visible',
            streaming: true,
          ),
          running: true,
        );
      final api = _PartialTailApi(partialTail);
      final chat = _recoverableChat(
        'recovery-partial-snapshot',
        gateway,
        api: api,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 300);
      gateway.drop();
      await _waitUntil(
        () => gateway.committedRecoveryRuntimeIds.contains(
          'runtime-partial-snapshot-2',
        ),
      );

      expect(chat.hasEarlierMessages, isTrue);
      expect(
        chat.messages.any(
          (message) => message['id'] == 'partial-snapshot-legitimate-answer',
        ),
        isTrue,
      );

      partialTail.add(const {
        'id': 'only-partial-desktop-row',
        'role': 'user',
        'content': 'fila parcial no autoritativa',
      });
      expect(await chat.loadEarlierMessages(), isTrue);

      expect(api.requestedOffsets.last, 0);
      expect(
        chat.messages.any(
          (message) => message['id'] == 'only-partial-desktop-row',
        ),
        isTrue,
      );
    },
  );

  test('recovery con snapshot vacío no borra el historial visible', () async {
    final partialTail = <Map<String, dynamic>>[
      const {
        'id': 'visible-user-before-empty-recovery',
        'role': 'user',
        'content': 'pregunta visible antes de reconectar',
      },
      const {
        'id': 'visible-answer-before-empty-recovery',
        'role': 'assistant',
        'content': 'respuesta visible antes de reconectar',
      },
      for (var index = 0; index < 118; index++)
        {
          'id': 'visible-context-$index',
          'role': 'system',
          'content': 'contexto visible $index',
        },
    ];
    final gateway = _LifecycleRecoverableGateway()
      ..initialSnapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-empty-recovery-1',
        storedSessionId: 'session-empty-recovery',
        created: false,
        messagesProvided: false,
        messageCount: 300,
        inflight: DesktopInflightTurn(
          user: 'turno activo antes de reconectar',
          streaming: true,
        ),
        running: true,
      )
      ..recoverySnapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-empty-recovery-2',
        storedSessionId: 'session-empty-recovery',
        created: false,
        messagesProvided: true,
        messages: const [],
        messageCount: 0,
        inflight: DesktopInflightTurn(
          user: 'turno activo antes de reconectar',
          streaming: true,
        ),
        running: true,
      );
    final chat = _recoverableChat(
      'empty-recovery',
      gateway,
      api: _PartialTailApi(partialTail),
    );
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: 300);
    gateway.drop();
    await _waitUntil(
      () => gateway.committedRecoveryRuntimeIds.contains(
        'runtime-empty-recovery-2',
      ),
    );

    expect(chat.hasEarlierMessages, isTrue);
    expect(
      chat.messages.any(
        (message) => message['id'] == 'visible-answer-before-empty-recovery',
      ),
      isTrue,
    );
  });

  test(
    'snapshot terminal vacío conserva parcial el fallback durante recovery',
    () async {
      final partialTail = <Map<String, dynamic>>[
        const {
          'id': 'terminal-empty-partial-user',
          'role': 'user',
          'content': 'prompt repetido en cola parcial',
        },
        const {
          'id': 'terminal-empty-partial-answer',
          'role': 'assistant',
          'content': 'respuesta legítima visible',
        },
        for (var index = 0; index < 118; index++)
          {
            'id': 'terminal-empty-context-$index',
            'role': 'system',
            'content': 'contexto parcial $index',
          },
      ];
      final gateway = _LifecycleRecoverableGateway()
        ..initialSnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-terminal-empty-1',
          storedSessionId: 'session-terminal-empty',
          created: false,
          messagesProvided: false,
          messageCount: 300,
          inflight: DesktopInflightTurn(
            user: 'turno activo antes del terminal vacío',
            streaming: true,
          ),
          running: true,
        )
        ..recoverySnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-terminal-empty-2',
          storedSessionId: 'session-terminal-empty',
          created: false,
          messagesProvided: true,
          messages: [],
          messageCount: 0,
        );
      final chat = _recoverableChat(
        'terminal-empty-partial-fallback',
        gateway,
        api: _PartialTailApi(partialTail),
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(
            content: 'prompt repetido en cola parcial',
            firstUser: true,
          ),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 300);
      expect(chat.hasEarlierMessages, isTrue);
      gateway.drop();
      await _waitUntil(
        () => gateway.committedRecoveryRuntimeIds.contains(
          'runtime-terminal-empty-2',
        ),
      );

      expect(chat.hasEarlierMessages, isTrue);
      expect(
        chat.messages.any(
          (message) => message['id'] == 'terminal-empty-partial-answer',
        ),
        isTrue,
      );
      expect(
        chat.messages
            .singleWhere(
              (message) => message['id'] == 'terminal-empty-partial-user',
            )
            .containsKey('_cancelledUser'),
        isFalse,
      );
    },
  );

  test('recovery completo retira el backfill de una cola anterior', () async {
    final partialTail = <Map<String, dynamic>>[
      for (var index = 0; index < 120; index++)
        {
          'id': 'old-partial-$index',
          'role': index.isEven ? 'user' : 'assistant',
          'content': 'fila parcial anterior $index',
        },
    ];
    final gateway = _LifecycleRecoverableGateway()
      ..initialSnapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-complete-bookkeeping-1',
        storedSessionId: 'session-complete-bookkeeping',
        created: false,
        messagesProvided: false,
        messageCount: 300,
        inflight: DesktopInflightTurn(
          user: 'turno que completará el snapshot',
          streaming: true,
        ),
        running: true,
      )
      ..recoverySnapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-complete-bookkeeping-2',
        storedSessionId: 'session-complete-bookkeeping',
        created: false,
        messagesProvided: true,
        messages: [
          DesktopSessionMessage.tryParse(const {
            'message_id': 'complete-user',
            'role': 'user',
            'content': 'historial completo',
          })!,
          DesktopSessionMessage.tryParse(const {
            'message_id': 'complete-answer',
            'role': 'assistant',
            'content': 'respuesta completa',
          })!,
        ],
        messageCount: 2,
        running: true,
      );
    final chat = _recoverableChat(
      'complete-bookkeeping',
      gateway,
      api: _PartialTailApi(partialTail),
    );
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: 300);
    expect(chat.hasEarlierMessages, isTrue);

    gateway.drop();
    await _waitUntil(
      () => gateway.committedRecoveryRuntimeIds.contains(
        'runtime-complete-bookkeeping-2',
      ),
    );

    expect(chat.hasEarlierMessages, isFalse);
    expect(
      chat.messages
          .map((message) => message['_desktopMessageId'])
          .whereType<String>(),
      ['complete-answer', 'complete-user'],
    );
  });

  test('Stop no inventa firstUser desde un snapshot parcial', () async {
    final recorded = <CancelledTurnTombstone>[];
    final gateway = _LifecycleRecoverableGateway()
      ..initialSnapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-partial-stop',
        storedSessionId: 'session-partial-stop',
        created: false,
        messagesProvided: true,
        messages: [
          DesktopSessionMessage.tryParse(const {
            'role': 'user',
            'content': 'turno sin ancla en snapshot parcial',
          })!,
        ],
        messageCount: 300,
        inflight: DesktopInflightTurn(
          user: 'turno sin ancla en snapshot parcial',
          streaming: true,
        ),
        running: true,
      );
    final chat = _recoverableChat(
      'partial-stop',
      gateway,
      onCancelledTurn: (tombstone) async => recorded.add(tombstone),
    );
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: 300);
    expect(chat.isStreaming, isTrue);

    await expectLater(chat.cancel(), throwsStateError);
    expect(recorded, isEmpty);
    expect(chat.isStreaming, isTrue);
  });

  test(
    'Stop no enlaza por texto un inflight nuevo al user canónico anterior',
    () async {
      final recorded = <CancelledTurnTombstone>[];
      final gateway = _LifecycleRecoverableGateway()
        ..initialSnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-homonymous-inflight-stop',
          storedSessionId: 'session-homonymous-inflight-stop',
          created: false,
          messagesProvided: true,
          messages: [
            DesktopSessionMessage.tryParse(const {
              'message_id': 'historical-user-a',
              'role': 'user',
              'content': 'prompt repetido sin identidad compartida',
              'timestamp': 90,
            })!,
          ],
          messageCount: 1,
          inflight: DesktopInflightTurn(
            user: 'prompt repetido sin identidad compartida',
            assistant: 'respuesta parcial del turno nuevo B',
            streaming: true,
            startedAt: DateTime.fromMillisecondsSinceEpoch(100000, isUtc: true),
          ),
          running: true,
        );
      final chat = _recoverableChat(
        'homonymous-inflight-stop',
        gateway,
        onCancelledTurn: (tombstone) async => recorded.add(tombstone),
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'historical-user-a',
            'role': 'user',
            'content': 'prompt repetido sin identidad compartida',
            'timestamp': 90,
          },
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 1);

      final repeatedUsers = chat.messages
          .where(
            (message) =>
                isRealUserTurn(message) &&
                message['content'] ==
                    'prompt repetido sin identidad compartida',
          )
          .toList(growable: false);
      expect(repeatedUsers, hasLength(2));
      expect(
        repeatedUsers.any(
          (message) =>
              canonicalTranscriptMessageId(message) == 'historical-user-a',
        ),
        isTrue,
      );
      expect(
        repeatedUsers.any(
          (message) => message['_desktopSnapshotKind'] == 'inflight',
        ),
        isTrue,
      );

      await expectLater(chat.cancel(), throwsStateError);
      expect(recorded, isEmpty);
      expect(chat.isStreaming, isTrue);
      expect(
        chat.messages.singleWhere(
          (message) =>
              canonicalTranscriptMessageId(message) == 'historical-user-a',
        )['_cancelledUser'],
        isNot(true),
      );
      expect(
        chat.messages.singleWhere(
          (message) =>
              isRealUserTurn(message) &&
              message['_desktopSnapshotKind'] == 'inflight',
        )['_cancelledUser'],
        isNot(true),
      );
    },
  );

  test(
    'Stop liga el user actual por sus aliases aunque haya un user id-less anterior',
    () async {
      for (final alias in const ['_desktopMessageId', 'message_id', 'id']) {
        final recorded = <CancelledTurnTombstone>[];
        final gateway = _LifecycleRecoverableGateway()
          ..initialSnapshot = DesktopSessionSnapshot(
            runtimeSessionId: 'runtime-target-id-$alias',
            storedSessionId: 'session-target-id-$alias',
            created: false,
            messagesProvided: true,
            messages: [
              DesktopSessionMessage.tryParse(const {
                'role': 'user',
                'content': 'turno histórico sin identidad',
              })!,
              DesktopSessionMessage.tryParse({
                'message_id': 'source-current-$alias',
                'role': 'user',
                'content': 'turno actual identificado por $alias',
              })!,
            ],
            messageCount: 300,
            inflight: DesktopInflightTurn(
              user: 'turno actual identificado por $alias',
              assistant: 'respuesta parcial $alias',
              streaming: true,
            ),
            running: true,
          );
        final chat = _recoverableChat(
          'target-id-$alias',
          gateway,
          onCancelledTurn: (tombstone) async => recorded.add(tombstone),
        );
        addTearDown(chat.dispose);

        await chat.loadMessages(expectedMessageCount: 300);
        final userIndex = chat.messages.indexWhere(
          (message) =>
              message['content'] == 'turno actual identificado por $alias',
        );
        expect(userIndex, greaterThanOrEqualTo(0), reason: alias);
        final exactId = '  current-target-$alias  ';
        chat.messages[userIndex] =
            Map<String, dynamic>.of(chat.messages[userIndex])
              ..remove('_desktopMessageId')
              ..remove('message_id')
              ..remove('id')
              ..[alias] = exactId;

        await chat.cancel();

        expect(recorded, hasLength(1), reason: alias);
        expect(recorded.single.cancelledMessageId, exactId, reason: alias);
        expect(recorded.single.anchorMessageId, isNull, reason: alias);
        expect(recorded.single.firstUser, isFalse, reason: alias);
        expect(
          CancelledTurnTombstone.fromJson(
            recorded.single.stamped(123).toJson(),
          )?.cancelledMessageId,
          exactId,
          reason: alias,
        );
      }
    },
  );

  test('reconciliar transcript oculta la respuesta del turno detenido', () {
    final projected = projectCancelledTurnTombstones(
      existingNewestFirst: const [],
      incomingTranscriptComplete: true,
      durableTombstones: const [
        CancelledTurnTombstone(
          content: 'QA4931_OFFLINE_CANCEL_OLD',
          firstUser: true,
        ),
      ],
      incomingNewestFirst: const [
        {
          'id': 'cancelled-answer',
          'role': 'assistant',
          'content': 'QA4931_OFFLINE_CANCEL_OLD',
        },
        {
          'id': 'cancelled-user',
          'role': 'user',
          'content': 'QA4931_OFFLINE_CANCEL_OLD',
        },
      ],
    );

    expect(projected, hasLength(1));
    expect(projected.single['id'], 'cancelled-user');
    expect(projected.single['_cancelledUser'], isTrue);
  });

  test('tombstone distingue prompts repetidos por ancla durable', () {
    final projected = projectCancelledTurnTombstones(
      existingNewestFirst: const [],
      incomingTranscriptComplete: true,
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

  test('tombstone reaplica el ancla al cruzar aliases de identidad', () {
    for (final anchorKey in const ['_desktopMessageId', 'message_id', 'id']) {
      final projected = projectCancelledTurnTombstones(
        existingNewestFirst: const [],
        incomingTranscriptComplete: true,
        durableTombstones: const [
          CancelledTurnTombstone(
            content: 'turno detenido por alias',
            anchorMessageId: 'anchor-cross-alias',
          ),
        ],
        incomingNewestFirst: [
          const {
            'id': 'cancelled-answer',
            'role': 'assistant',
            'content': 'respuesta cancelada',
          },
          const {
            'message_id': 'cancelled-user',
            'role': 'user',
            'content': 'turno detenido por alias',
          },
          {
            anchorKey: 'anchor-cross-alias',
            'role': 'assistant',
            'content': 'respuesta anterior',
          },
        ],
      );

      expect(projected.map((message) => message['content']), [
        'turno detenido por alias',
        'respuesta anterior',
      ], reason: 'alias $anchorKey');
      expect(projected.first['_cancelledUser'], isTrue);
    }
  });

  test('tombstone reaplica un ancla de fila entre REST y Desktop', () {
    for (final anchorAlias in const ['_desktopRowId', 'row_id', 'id']) {
      final projected = projectCancelledTurnTombstones(
        existingNewestFirst: const [],
        incomingTranscriptComplete: false,
        durableTombstones: const [
          CancelledTurnTombstone(
            content: 'turno detenido por ancla de fila',
            anchorRowId: 73,
          ),
        ],
        incomingNewestFirst: [
          const {
            'id': 75,
            'role': 'assistant',
            'content': 'respuesta cancelada',
          },
          const {
            'id': 74,
            'role': 'user',
            'content': 'turno detenido por ancla de fila',
          },
          {
            anchorAlias: 73,
            'role': 'assistant',
            'content': 'respuesta anterior',
          },
        ],
      );

      expect(projected.map((message) => message['content']), [
        'turno detenido por ancla de fila',
        'respuesta anterior',
      ], reason: anchorAlias);
      expect(projected.first['_cancelledUser'], isTrue, reason: anchorAlias);
    }
  });

  test('tombstone ligado reaplica el target cruzando aliases exactos', () {
    for (final userAlias in const ['_desktopMessageId', 'message_id', 'id']) {
      const targetId = '  cancelled-target-opaque  ';
      final projected = projectCancelledTurnTombstones(
        existingNewestFirst: const [],
        incomingTranscriptComplete: false,
        durableTombstones: const [
          CancelledTurnTombstone(
            content: 'prompt repetido',
            cancelledMessageId: targetId,
          ),
        ],
        incomingNewestFirst: [
          const {
            'id': 'new-answer',
            'role': 'assistant',
            'content': 'respuesta legítima nueva',
          },
          const {
            'id': 'new-user',
            'role': 'user',
            'content': 'prompt repetido',
          },
          const {
            'id': 'cancelled-answer',
            'role': 'assistant',
            'content': 'respuesta cancelada',
          },
          {userAlias: targetId, 'role': 'user', 'content': 'prompt repetido'},
          const {
            'id': 'older-answer',
            'role': 'assistant',
            'content': 'respuesta anterior intacta',
          },
        ],
      );

      expect(projected.map((message) => message['content']), [
        'respuesta legítima nueva',
        'prompt repetido',
        'prompt repetido',
        'respuesta anterior intacta',
      ], reason: userAlias);
      expect(projected[2]['_cancelledUser'], isTrue, reason: userAlias);
    }
  });

  test('tombstone no equipara un id numérico con el string homónimo', () {
    final projected = projectCancelledTurnTombstones(
      existingNewestFirst: const [],
      incomingTranscriptComplete: false,
      durableTombstones: const [
        CancelledTurnTombstone(
          content: 'prompt legítimo',
          cancelledMessageId: '42',
        ),
      ],
      incomingNewestFirst: const [
        {
          'id': 'answer-42',
          'role': 'assistant',
          'content': 'respuesta legítima',
        },
        {'id': 42, 'role': 'user', 'content': 'prompt legítimo'},
      ],
    );

    expect(canonicalTranscriptMessageId(projected.last), isNull);
    expect(projected.map((message) => message['content']), [
      'respuesta legítima',
      'prompt legítimo',
    ]);
    expect(projected.last.containsKey('_cancelledUser'), isFalse);
  });

  test('tombstone ignora filas steer al contar turnos de usuario', () {
    final projected = projectCancelledTurnTombstones(
      existingNewestFirst: const [],
      incomingTranscriptComplete: true,
      durableTombstones: const [
        CancelledTurnTombstone(content: 'turno detenido', firstUser: true),
      ],
      incomingNewestFirst: const [
        {'id': 'answer-new', 'role': 'assistant', 'content': 'respuesta nueva'},
        {'id': 'user-new', 'role': 'user', 'content': 'turno nuevo'},
        {
          'id': 'answer-cancelled',
          'role': 'assistant',
          'content': 'respuesta que debe ocultarse',
        },
        {'id': 'user-cancelled', 'role': 'user', 'content': 'turno detenido'},
      ],
    );

    expect(projected.map((message) => message['content']), [
      'respuesta nueva',
      'turno nuevo',
      'turno detenido',
    ]);
    expect(projected.last['_cancelledUser'], isTrue);
  });

  test('firstUser no se proyecta sobre una ventana parcial', () {
    final projected = projectCancelledTurnTombstones(
      existingNewestFirst: const [],
      incomingTranscriptComplete: false,
      durableTombstones: const [
        CancelledTurnTombstone(content: 'prompt repetido', firstUser: true),
      ],
      incomingNewestFirst: const [
        {
          'id': 'answer-tail',
          'role': 'assistant',
          'content': 'respuesta válida',
        },
        {'id': 'user-tail', 'role': 'user', 'content': 'prompt repetido'},
      ],
    );

    expect(projected.map((message) => message['id']), [
      'answer-tail',
      'user-tail',
    ]);
    expect(projected.last.containsKey('_cancelledUser'), isFalse);
  });

  test('firstUser nunca cae sobre un inflight sintético del mismo texto', () {
    final incoming = <Map<String, dynamic>>[
      {
        '_desktopMessageId': 'synthetic-inflight',
        '_desktopSnapshotKind': 'inflight',
        'role': 'user',
        'content': 'prompt repetido',
      },
    ];

    final projected = projectCancelledTurnTombstones(
      existingNewestFirst: const [],
      incomingNewestFirst: incoming,
      incomingTranscriptComplete: true,
      durableTombstones: const [
        CancelledTurnTombstone(content: 'prompt repetido', firstUser: true),
      ],
    );

    expect(projected, incoming);
    expect(projected.single.containsKey('_cancelledUser'), isFalse);
  });

  test('tombstone anclado no salta a inflight si falta el user durable', () {
    final incoming = <Map<String, dynamic>>[
      {
        '_desktopMessageId': 'synthetic-inflight',
        '_desktopSnapshotKind': 'inflight',
        'role': 'user',
        'content': 'prompt repetido',
      },
      {
        'message_id': 'cancel-anchor',
        'role': 'assistant',
        'content': 'respuesta anterior',
      },
    ];

    final projected = projectCancelledTurnTombstones(
      existingNewestFirst: const [],
      incomingNewestFirst: incoming,
      incomingTranscriptComplete: true,
      durableTombstones: const [
        CancelledTurnTombstone(
          content: 'prompt repetido',
          anchorMessageId: 'cancel-anchor',
        ),
      ],
    );

    expect(projected, incoming);
    expect(projected.first.containsKey('_cancelledUser'), isFalse);
  });

  test('tombstone conserva metadatos user del turno cancelado', () {
    final projected = projectCancelledTurnTombstones(
      existingNewestFirst: const [],
      incomingTranscriptComplete: true,
      durableTombstones: const [
        CancelledTurnTombstone(content: 'turno detenido', firstUser: true),
      ],
      incomingNewestFirst: const [
        {
          'id': 'cancelled-answer',
          'role': 'assistant',
          'content': 'respuesta que debe ocultarse',
        },
        {
          'id': 'metadata-user',
          'role': 'user',
          'content': 'cambio de modelo',
          'display_kind': 'model_switch',
        },
        {'id': 'cancelled-user', 'role': 'user', 'content': 'turno detenido'},
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
      incomingTranscriptComplete: true,
      durableTombstones: const [
        CancelledTurnTombstone(content: 'turno detenido', firstUser: true),
      ],
      incomingNewestFirst: const [
        {
          'id': 'cancelled-answer',
          'role': 'assistant',
          'content': 'respuesta que debe ocultarse',
        },
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
        {'id': 'cancelled-user', 'role': 'user', 'content': 'turno detenido'},
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
      incomingTranscriptComplete: true,
      durableTombstones: const [
        CancelledTurnTombstone(content: 'turno detenido', firstUser: true),
      ],
      incomingNewestFirst: const [
        {
          'id': 'cancelled-answer',
          'role': 'assistant',
          'content': 'respuesta que debe ocultarse',
        },
        {'id': 'cancelled-user', 'role': 'user', 'content': 'turno detenido'},
      ],
    );

    expect(projected.map((message) => message['content']), ['turno detenido']);
    expect(projected.single['_cancelledUser'], isTrue);
  });

  test('cold open conserva transcript si el tombstone perdió su ancla', () {
    final projected = projectCancelledTurnTombstones(
      existingNewestFirst: const [],
      incomingTranscriptComplete: true,
      durableTombstones: const [
        CancelledTurnTombstone(
          content: 'prompt compactado',
          anchorMessageId: 'anchor-eliminada',
        ),
      ],
      incomingNewestFirst: const [
        {'id': 'answer-new', 'role': 'assistant', 'content': 'respuesta nueva'},
        {'id': 'user-new', 'role': 'user', 'content': 'pregunta nueva'},
      ],
    );

    expect(projected.map((message) => message['content']), [
      'respuesta nueva',
      'pregunta nueva',
    ]);
  });

  test(
    'firstUser invalidado por compactación no oculta un prompt repetido nuevo',
    () {
      final projected = projectCancelledTurnTombstones(
        existingNewestFirst: const [],
        incomingTranscriptComplete: true,
        durableTombstones: const [
          CancelledTurnTombstone(
            content: 'mismo prompt',
            firstUser: true,
            invalidated: true,
          ),
        ],
        incomingNewestFirst: const [
          {
            'id': 'new-answer-after-compaction',
            'role': 'assistant',
            'content': 'respuesta legítima post-compaction',
          },
          {
            'id': 'new-user-after-compaction',
            'role': 'user',
            'content': 'mismo prompt',
          },
        ],
      );

      expect(projected.map((message) => message['content']), [
        'respuesta legítima post-compaction',
        'mismo prompt',
      ]);
      expect(projected.last.containsKey('_cancelledUser'), isFalse);
    },
  );

  test('refresh canónico reemplaza el snapshot viejo pese al tombstone', () {
    final projected = projectCancelledTurnTombstones(
      existingNewestFirst: const [
        {'id': 'old-answer', 'role': 'assistant', 'content': 'respuesta vieja'},
        {'id': 'old-user', 'role': 'user', 'content': 'pregunta vieja'},
      ],
      incomingTranscriptComplete: true,
      durableTombstones: const [
        CancelledTurnTombstone(
          content: 'turno ya compactado',
          anchorMessageId: 'anchor-eliminada',
        ),
      ],
      incomingNewestFirst: const [
        {
          'id': 'canonical-answer',
          'role': 'assistant',
          'content': 'respuesta canónica',
        },
        {
          'id': 'canonical-user',
          'role': 'user',
          'content': 'pregunta canónica',
        },
      ],
    );

    expect(projected.map((message) => message['id']), [
      'canonical-answer',
      'canonical-user',
    ]);
  });

  test('tombstone no cae por texto sobre una ventana parcial', () {
    final projected = projectCancelledTurnTombstones(
      existingNewestFirst: const [],
      incomingTranscriptComplete: false,
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

    expect(projected.map((message) => message['content']), [
      'respuesta legítima reciente',
      'prompt repetido',
    ]);
    expect(projected.last.containsKey('_cancelledUser'), isFalse);
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

  test(
    'close/reopen tras compactación conserva el transcript canónico',
    () async {
      final gateway = _LifecycleRecoverableGateway();
      final chat = _recoverableChat(
        'restore-compacted',
        gateway,
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(
            content: 'turno compactado',
            anchorMessageId: 'anchor-eliminada',
          ),
        ],
        storedMessageLoader: (_, _) async => const [
          {
            'id': 'compacted-user',
            'role': 'user',
            'content': 'resumen tras compactar',
          },
          {
            'id': 'compacted-answer',
            'role': 'assistant',
            'content': 'historial canónico preservado',
          },
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);

      expect(chat.messages.map((message) => message['content']), [
        'historial canónico preservado',
        'resumen tras compactar',
      ]);
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
    chat.markStoredSessionMissing();

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

  test(
    'dos Stop consecutivos rehidratan el ancla durable entre turnos',
    () async {
      final recorded = <CancelledTurnTombstone>[];
      final durable = <Map<String, dynamic>>[];
      final gateway = _LifecycleRecoverableGateway();
      final chat = _recoverableChat(
        'two-durable-stops',
        gateway,
        desktopRecoveryAttemptTimeout: const Duration(milliseconds: 30),
        storedMessageLoader: (_, _) async => List.of(durable),
        onCancelledTurn: (tombstone) async => recorded.add(tombstone),
      );
      addTearDown(chat.dispose);
      chat.markStoredSessionMissing();

      await chat.send(
        fullText: 'primer turno detenido',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('two-durable-stops-1', _NoopOutbox()),
      );
      await chat.cancel();
      durable.add(const {
        'message_id': 'first-cancelled-user',
        'role': 'user',
        'content': 'primer turno detenido',
        'timestamp': 50,
      });

      final accepted = await chat.send(
        fullText: 'segundo turno detenido',
        model: 'hermes-agent',
        history: chat.buildHistory(),
        delivery: _delivery('two-durable-stops-2', _NoopOutbox()),
      );
      expect(accepted, isTrue);
      gateway.initialSnapshot = DesktopSessionSnapshot(
        runtimeSessionId: chat.desktopRuntimeSessionId!,
        storedSessionId: chat.serverSessionId,
        created: false,
        messagesProvided: false,
        messageCount: durable.length,
        running: true,
        inflight: DesktopInflightTurn(
          user: 'segundo turno detenido',
          streaming: true,
          startedAt: DateTime.fromMillisecondsSinceEpoch(100000, isUtc: true),
        ),
      );
      await chat.cancel();

      final created = recorded
          .where((tombstone) => tombstone.cancelledMessageId == null)
          .toList(growable: false);
      expect(created, hasLength(2));
      expect(created.first.firstUser, isTrue);
      expect(created.last.firstUser, isFalse);
      expect(created.last.anchorMessageId, 'first-cancelled-user');
      expect(recorded[1].cancelledMessageId, 'first-cancelled-user');
    },
  );

  test(
    'resume 4007 más REST vacío autoriza firstUser del primer Stop',
    () async {
      final recorded = <CancelledTurnTombstone>[];
      final gateway = _LifecycleRecoverableGateway()
        ..resumeExistingError = const TuiGatewayRpcError(
          'session.resume',
          'session not found',
          code: 4007,
        );
      final chat = _recoverableChat(
        'missing-before-first-stop',
        gateway,
        storedMessageLoader: (_, _) async => const [],
        onCancelledTurn: (tombstone) async => recorded.add(tombstone),
      );
      addTearDown(chat.dispose);

      await chat.loadMessages();
      expect(chat.storedSessionKnownMissing, isTrue);

      gateway.resumeExistingError = null;
      await chat.send(
        fullText: 'primer turno tras confirmar que no existe',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('missing-before-first-stop-1', _NoopOutbox()),
      );
      await chat.cancel();

      expect(recorded, hasLength(1));
      expect(recorded.single.firstUser, isTrue);
      expect(recorded.single.anchorMessageId, isNull);
    },
  );

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

  test('Stop usa una fila SQLite numérica como ancla exacta', () async {
    final recorded = <CancelledTurnTombstone>[];
    final gateway = _LifecycleRecoverableGateway();
    final chat = _recoverableChat(
      'persist-numeric-row-anchor',
      gateway,
      onCancelledTurn: (tombstone) async => recorded.add(tombstone),
    );
    addTearDown(chat.dispose);
    // `/api/sessions/:id/messages` entrega el `messages.id` de SQLite como
    // número. No debe convertirse al string "73", pero sí es una identidad
    // durable exacta que Desktop también proyecta como `_desktopRowId`.
    chat.messages.add(const {
      'id': 73,
      'role': 'assistant',
      'content': 'respuesta anterior con row id',
    });

    await chat.send(
      fullText: 'turno anclado por fila',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('persist-numeric-row-anchor-1', _NoopOutbox()),
    );

    await chat.cancel();

    expect(recorded, hasLength(1));
    expect(recorded.single.anchorMessageId, isNull);
    expect(recorded.single.anchorRowId, 73);
    expect(recorded.single.cancelledMessageId, isNull);
    expect(recorded.single.cancelledRowId, isNull);
    expect(
      CancelledTurnTombstone.fromJson(
        recorded.single.stamped(123).toJson(),
      )?.anchorRowId,
      73,
    );
    expect(chat.isStreaming, isFalse);
  });

  test(
    'Stop tolera que el ancla se ligue a un target mientras se guarda',
    () async {
      final firstWriteStarted = Completer<void>();
      final firstWriteGate = Completer<void>();
      final recorded = <CancelledTurnTombstone>[];
      final gateway = _LifecycleRecoverableGateway();
      final chat = _recoverableChat(
        'persist-identity-upgrade-race',
        gateway,
        onCancelledTurn: (tombstone) {
          recorded.add(tombstone);
          if (!firstWriteStarted.isCompleted) {
            firstWriteStarted.complete();
            return firstWriteGate.future;
          }
          return Future<void>.value();
        },
      );
      addTearDown(chat.dispose);
      chat.messages.add(const {
        'message_id': 'durable-before-upgrade',
        'role': 'assistant',
        'content': 'respuesta anterior',
      });

      await chat.send(
        fullText: 'turno cuya identidad se hidrata',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('persist-identity-upgrade-race-1', _NoopOutbox()),
      );
      final cancellation = chat.cancel();
      await firstWriteStarted.future;

      final userIndex = chat.messages.indexWhere(isRealUserTurn);
      expect(userIndex, greaterThanOrEqualTo(0));
      // Simula la sustitución autoritativa que puede publicar REST/snapshot
      // mientras FlutterSecureStorage confirma el tombstone anclado.
      chat.messages[userIndex] = const {
        'message_id': 'durable-current-after-upgrade',
        'role': 'user',
        'content': 'turno cuya identidad se hidrata',
      };
      firstWriteGate.complete();

      await cancellation;

      expect(chat.isStreaming, isFalse);
      expect(
        chat.messages.singleWhere(isRealUserTurn)['_cancelledUser'],
        isTrue,
      );
    },
  );

  test(
    'Stop no cruza un usuario histórico sin id para buscar un ancla',
    () async {
      final recorded = <CancelledTurnTombstone>[];
      final gateway = _LifecycleRecoverableGateway();
      final chat = _recoverableChat(
        'persist-anchor-across-idless-user',
        gateway,
        onCancelledTurn: (tombstone) async => recorded.add(tombstone),
      );
      addTearDown(chat.dispose);
      chat.messages.addAll(const [
        {
          'role': 'assistant',
          'content': 'respuesta legítima del turno repetido anterior',
        },
        {'role': 'user', 'content': 'mismo prompt'},
        {
          'id': 'too-old-to-anchor-current-turn',
          'role': 'assistant',
          'content': 'respuesta todavía más antigua',
        },
      ]);

      await chat.send(
        fullText: 'mismo prompt',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery(
          'persist-anchor-across-idless-user-1',
          _NoopOutbox(),
        ),
      );

      await expectLater(chat.cancel(), throwsStateError);
      expect(recorded, isEmpty);
      expect(chat.isStreaming, isTrue);
      expect(
        chat.messages.any(
          (message) =>
              message['content'] ==
                  'respuesta legítima del turno repetido anterior' &&
              message['_cancelled'] != true,
        ),
        isTrue,
      );
    },
  );

  test('Stop crea el tombstone desde todos los aliases exactos', () async {
    for (final alias in const ['_desktopMessageId', 'message_id', 'id']) {
      final recorded = <CancelledTurnTombstone>[];
      final gateway = _LifecycleRecoverableGateway();
      final chat = _recoverableChat(
        'persist-anchor-$alias',
        gateway,
        onCancelledTurn: (tombstone) async => recorded.add(tombstone),
      );
      addTearDown(chat.dispose);
      final durableId = '  durable-$alias  ';
      chat.messages.add({
        alias: durableId,
        'role': 'assistant',
        'content': 'respuesta anterior por $alias',
      });

      await chat.send(
        fullText: 'turno anclado por $alias',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('persist-anchor-$alias-1', _NoopOutbox()),
      );
      await chat.cancel();

      expect(recorded, hasLength(1), reason: alias);
      expect(recorded.single.anchorMessageId, durableId, reason: alias);
      expect(recorded.single.firstUser, isFalse, reason: alias);
    }
  });

  test('Stop no crea un ancla desde un row id decimal malformado', () async {
    final recorded = <CancelledTurnTombstone>[];
    final gateway = _LifecycleRecoverableGateway();
    final chat = _recoverableChat(
      'numeric-anchor',
      gateway,
      onCancelledTurn: (tombstone) async => recorded.add(tombstone),
    );
    addTearDown(chat.dispose);
    chat.messages.add(const {
      'id': 42.0,
      'role': 'assistant',
      'content': 'respuesta anterior sin identidad válida',
    });

    await chat.send(
      fullText: 'turno sin ancla durable',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('numeric-anchor-1', _NoopOutbox()),
    );

    await expectLater(chat.cancel(), throwsStateError);
    expect(recorded, isEmpty);
    expect(chat.isStreaming, isTrue);
  });

  test('tombstone por row id cruza los aliases numéricos sin normalizar', () {
    for (final rowAlias in const ['_desktopRowId', 'row_id', 'id']) {
      final projected = projectCancelledTurnTombstones(
        existingNewestFirst: const [],
        incomingTranscriptComplete: false,
        durableTombstones: const [
          CancelledTurnTombstone(
            content: 'turno detenido por row id',
            cancelledRowId: 74,
          ),
        ],
        incomingNewestFirst: [
          const {
            'id': 75,
            'role': 'assistant',
            'content': 'respuesta cancelada',
          },
          {
            rowAlias: 74,
            'role': 'user',
            'content': 'turno detenido por row id',
          },
        ],
      );

      expect(projected, hasLength(1), reason: rowAlias);
      expect(projected.single['_cancelledUser'], isTrue, reason: rowAlias);
      expect(
        canonicalTranscriptMessageId(projected.single),
        isNull,
        reason: rowAlias,
      );
      expect(canonicalTranscriptRowId(projected.single), 74, reason: rowAlias);
    }
  });

  test('tombstone row id nunca coincide con message id string homónimo', () {
    final projected = projectCancelledTurnTombstones(
      existingNewestFirst: const [],
      incomingTranscriptComplete: false,
      durableTombstones: const [
        CancelledTurnTombstone(content: 'prompt legítimo', cancelledRowId: 42),
      ],
      incomingNewestFirst: const [
        {
          'message_id': 'answer-42',
          'role': 'assistant',
          'content': 'respuesta legítima',
        },
        {'id': '42', 'role': 'user', 'content': 'prompt legítimo'},
      ],
    );

    expect(projected, hasLength(2));
    expect(projected.last.containsKey('_cancelledUser'), isFalse);
    expect(canonicalTranscriptMessageId(projected.last), '42');
    expect(canonicalTranscriptRowId(projected.last), isNull);
  });

  test(
    'tombstone enriquecido no cae al ancla ante una coordenada conflictiva',
    () {
      for (final conflictingUser in const [
        {
          'message_id': 'cancelled-message',
          'row_id': 43,
          'role': 'user',
          'content': 'prompt repetido',
        },
        {
          'message_id': 'otro-message',
          'row_id': 42,
          'role': 'user',
          'content': 'prompt repetido',
        },
      ]) {
        final projected = projectCancelledTurnTombstones(
          existingNewestFirst: const [],
          incomingTranscriptComplete: true,
          durableTombstones: const [
            CancelledTurnTombstone(
              content: 'prompt repetido',
              anchorMessageId: 'older-anchor',
              cancelledMessageId: 'cancelled-message',
              cancelledRowId: 42,
            ),
          ],
          incomingNewestFirst: [
            const {
              'message_id': 'answer-current',
              'role': 'assistant',
              'content': 'respuesta legítima',
            },
            conflictingUser,
            const {
              'message_id': 'older-anchor',
              'role': 'assistant',
              'content': 'respuesta anterior',
            },
          ],
        );

        expect(projected, hasLength(3));
        expect(projected[1].containsKey('_cancelledUser'), isFalse);
      }
    },
  );

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
    chat.markStoredSessionMissing();

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

  test('Stop no infiere firstUser si la sesión aún no se hidrató', () async {
    final recorded = <CancelledTurnTombstone>[];
    final gateway = _LifecycleRecoverableGateway();
    final chat = _recoverableChat(
      'unknown-empty-session',
      gateway,
      onCancelledTurn: (tombstone) async => recorded.add(tombstone),
    );
    addTearDown(chat.dispose);

    await chat.send(
      fullText: 'turno antes de cargar historial',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('unknown-empty-session-1', _NoopOutbox()),
    );

    await expectLater(chat.cancel(), throwsStateError);
    expect(recorded, isEmpty);
    expect(chat.isStreaming, isTrue);
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

  test('reinicio frío migra un scope legacy con tombstone singleton', () async {
    final scope = jsonEncode(const [
      'conn',
      'generation',
      'default',
      'session',
    ]);
    final payload = jsonEncode({
      scope: const {
        'content': 'turno detenido',
        'anchor_message_id': 'anchor-legacy',
        'first_user': false,
        'created_at_ms': 1000,
      },
    });
    final store = CancelledTurnTombstoneStore(
      read: () async => payload,
      write: (_) async {},
    );

    await store.initialize();

    final restored = store.load(
      connectionId: 'conn',
      generation: 'generation',
      profile: 'default',
      sessionId: 'session',
    );
    expect(restored, hasLength(1));
    expect(restored.single.anchorMessageId, 'anchor-legacy');
  });

  test(
    'reinicio frío descarta solo el scope ilegible y conserva los válidos',
    () async {
      final invalidScope = jsonEncode(const [
        'conn',
        'generation',
        'default',
        'invalid-session',
      ]);
      final validScope = jsonEncode(const [
        'conn',
        'generation',
        'default',
        'valid-session',
      ]);
      final payload = jsonEncode({
        invalidScope: const {'unexpected': true},
        validScope: const [
          {
            'content': 'otro turno detenido',
            'anchor_message_id': 'valid-anchor',
            'first_user': false,
            'created_at_ms': 1001,
          },
        ],
      });
      var writes = 0;
      final store = CancelledTurnTombstoneStore(
        read: () async => payload,
        write: (_) async => writes++,
      );

      await store.initialize();

      expect(
        store.load(
          connectionId: 'conn',
          generation: 'generation',
          profile: 'default',
          sessionId: 'invalid-session',
        ),
        isEmpty,
      );
      expect(
        store
            .load(
              connectionId: 'conn',
              generation: 'generation',
              profile: 'default',
              sessionId: 'valid-session',
            )
            .single
            .anchorMessageId,
        'valid-anchor',
      );
      expect(writes, 0);
    },
  );

  test(
    'reinicio frío descarta un scope mixto sin reaplicar su tombstone',
    () async {
      final mixedScope = jsonEncode(const [
        'conn',
        'generation',
        'default',
        'mixed-session',
      ]);
      final validScope = jsonEncode(const [
        'conn',
        'generation',
        'default',
        'valid-session',
      ]);
      final payload = jsonEncode({
        mixedScope: const [
          {
            'content': 'turno que pudo invalidarse',
            'anchor_message_id': 'mixed-anchor',
            'first_user': false,
            'created_at_ms': 1000,
          },
          {'invalidated': 'corrupt'},
        ],
        validScope: const [
          {
            'content': 'turno válido',
            'anchor_message_id': 'valid-anchor',
            'first_user': false,
            'created_at_ms': 1001,
          },
        ],
      });
      final store = CancelledTurnTombstoneStore(
        read: () async => payload,
        write: (_) async {},
      );

      await store.initialize();

      expect(
        store.load(
          connectionId: 'conn',
          generation: 'generation',
          profile: 'default',
          sessionId: 'mixed-session',
        ),
        isEmpty,
      );
      expect(
        store.load(
          connectionId: 'conn',
          generation: 'generation',
          profile: 'default',
          sessionId: 'valid-session',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'store persiste los aliases exactos de sesión en una sola escritura',
    () async {
      String? encryptedPayload;
      var writes = 0;
      final store = CancelledTurnTombstoneStore(
        read: () async => encryptedPayload,
        write: (value) async {
          writes++;
          encryptedPayload = value;
        },
        nowMs: () => 1000,
      );
      await store.initialize();

      await store.addAliases(
        connectionId: 'conn',
        profile: 'default',
        sessionIds: const [
          'mobile-route',
          'desktop-stored',
          'mobile-route',
          '',
        ],
        tombstone: const CancelledTurnTombstone(
          content: 'turno detenido',
          firstUser: true,
        ),
      );

      expect(writes, 1);
      for (final sessionId in const ['mobile-route', 'desktop-stored']) {
        final restored = store.load(
          connectionId: 'conn',
          profile: 'default',
          sessionId: sessionId,
        );
        expect(restored, hasLength(1), reason: sessionId);
        expect(restored.single.createdAtMs, 1000, reason: sessionId);
      }
      expect(encryptedPayload, isNotNull);
    },
  );

  test('tombstone persistido conserva el id opaco sin normalizarlo', () {
    final restored = CancelledTurnTombstone.fromJson(const {
      'content': 'turno detenido',
      'anchor_message_id': '  opaque-anchor  ',
      'first_user': false,
      'created_at_ms': 1000,
    });

    expect(restored, isNotNull);
    expect(restored!.anchorMessageId, '  opaque-anchor  ');
  });

  test('store conserva row ids tipados y separados de message ids', () async {
    String? encryptedPayload;
    final store = CancelledTurnTombstoneStore(
      read: () async => encryptedPayload,
      write: (value) async => encryptedPayload = value,
      nowMs: () => 1000,
    );
    await store.initialize();

    await store.add(
      connectionId: 'conn',
      profile: 'default',
      sessionId: 'session',
      tombstone: const CancelledTurnTombstone(
        content: 'mismo prompt',
        cancelledRowId: 42,
      ),
    );
    await store.add(
      connectionId: 'conn',
      profile: 'default',
      sessionId: 'session',
      tombstone: const CancelledTurnTombstone(
        content: 'mismo prompt',
        cancelledMessageId: '42',
      ),
    );

    final restored = store.load(
      connectionId: 'conn',
      profile: 'default',
      sessionId: 'session',
    );
    expect(restored, hasLength(2));
    expect(
      restored.any(
        (item) => item.cancelledRowId == 42 && item.cancelledMessageId == null,
      ),
      isTrue,
    );
    expect(
      restored.any(
        (item) =>
            item.cancelledMessageId == '42' && item.cancelledRowId == null,
      ),
      isTrue,
    );
  });

  test(
    'store distingue tombstones target-only con prompts repetidos',
    () async {
      String? encryptedPayload;
      var now = 1000;
      final store = CancelledTurnTombstoneStore(
        read: () async => encryptedPayload,
        write: (value) async => encryptedPayload = value,
        nowMs: () => now++,
      );
      await store.initialize();

      for (final id in const ['target-repeat-1', 'target-repeat-2']) {
        await store.add(
          connectionId: 'conn',
          profile: 'default',
          sessionId: 'session',
          tombstone: CancelledTurnTombstone(
            content: 'mismo prompt',
            cancelledMessageId: id,
          ),
        );
      }
      await store.add(
        connectionId: 'conn',
        profile: 'default',
        sessionId: 'session',
        tombstone: const CancelledTurnTombstone(
          content: 'mismo prompt',
          cancelledMessageId: 'target-repeat-1',
          invalidated: true,
        ),
      );

      final restored = store.load(
        connectionId: 'conn',
        profile: 'default',
        sessionId: 'session',
      );
      expect(restored, hasLength(2));
      expect(restored.map((item) => item.cancelledMessageId).toSet(), {
        'target-repeat-1',
        'target-repeat-2',
      });
      expect(
        restored
            .singleWhere((item) => item.cancelledMessageId == 'target-repeat-1')
            .invalidated,
        isTrue,
      );
    },
  );

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

      expect(chat.messages.first['role'], 'assistant_error');
      expect(
        chat.messages.first['content'],
        'Could not recover the turn. Please try again.',
      );
      expect(chat.messages.first['content'], isNot(contains('socket dropped')));

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

  test(
    'refresh nuevo vence a un GET terminal antiguo que termina después',
    () async {
      final gateway = _DroppingDesktopGateway();
      final api = _ControlledApiClient();
      final chat = ActiveChat(
        connection: _connection('terminal-refresh-epoch'),
        sessionId: 'session-terminal-refresh-epoch',
        sessionTitle: 'terminal-refresh-epoch',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
        terminalReconcileBudget: const Duration(seconds: 1),
      );
      addTearDown(chat.dispose);

      final initialLoad = chat.loadMessages(expectedMessageCount: 2);
      await _waitUntil(() => api.requests.length == 1);
      api.requests[0].complete(const [
        {
          'message_id': 'anchor-user',
          'role': 'user',
          'content': 'turno previo estable',
        },
        {
          'message_id': 'anchor-answer',
          'role': 'assistant',
          'content': 'respuesta previa estable',
        },
      ]);
      await initialLoad;

      await chat.send(
        fullText: 'turno original',
        model: 'hermes-agent',
        history: const [],
      );

      gateway.emit(
        'message.complete',
        payload: const {'text': 'respuesta visible del stream'},
      );
      await _waitUntil(() => api.requests.length == 2);

      final refresh = chat.loadMessages(expectedMessageCount: 4);
      await _waitUntil(() => api.requests.length == 3);
      api.requests[2].complete(const [
        {
          'message_id': 'anchor-user',
          'role': 'user',
          'content': 'turno previo estable',
        },
        {
          'message_id': 'anchor-answer',
          'role': 'assistant',
          'content': 'respuesta previa estable',
        },
        {
          'message_id': 'new-user',
          'role': 'user',
          'content': 'turno más nuevo',
        },
        {
          'message_id': 'new-answer',
          'role': 'assistant',
          'content': 'respuesta más nueva',
        },
      ]);
      await refresh;

      api.requests[1].complete(const [
        {
          'message_id': 'anchor-user',
          'role': 'user',
          'content': 'turno previo estable',
        },
        {
          'message_id': 'anchor-answer',
          'role': 'assistant',
          'content': 'respuesta previa estable',
        },
        {'message_id': 'old-user', 'role': 'user', 'content': 'turno original'},
        {
          'message_id': 'old-answer',
          'role': 'assistant',
          'content': 'respuesta terminal obsoleta',
        },
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(chat.messages.first['message_id'], 'new-answer');
      expect(chat.messages[1]['message_id'], 'new-user');
      expect(
        chat.messages.any(
          (message) => message['content'] == 'respuesta terminal obsoleta',
        ),
        isFalse,
      );
    },
  );

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

  test(
    'recovery legacy no sella un tool intermedio antes del assistant final',
    () async {
      final gateway = _DroppingDesktopGateway();
      final api = _ToolThenFinalTranscriptApi();
      final chat = ActiveChat(
        connection: _connection('drop-tool-then-final'),
        sessionId: 'session-drop-tool-then-final',
        sessionTitle: 'drop-tool-then-final',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
        terminalReconcileBudget: const Duration(seconds: 2),
      );
      addTearDown(chat.dispose);
      await chat.send(
        fullText: 'usa tool',
        model: 'hermes-agent',
        history: const [],
      );

      gateway.drop();
      await api.firstRead.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(api.calls, 1);
      expect(chat.state, isNot(ChatPipelineState.completed));
      expect(
        chat.messages.any(
          (message) => message['content'] == 'respuesta final durable',
        ),
        isFalse,
      );

      api.finalReady.complete();
      await _waitUntil(
        () => chat.state == ChatPipelineState.completed,
        timeout: const Duration(seconds: 2),
      );
      expect(api.calls, greaterThanOrEqualTo(2));
      expect(chat.messages.first['content'], 'respuesta final durable');
    },
  );

  group('transporte perdido mientras la app estaba minimizada', () {
    DesktopSessionSnapshot runningSnapshot(String runtimeId) =>
        DesktopSessionSnapshot(
          runtimeSessionId: runtimeId,
          storedSessionId: 'session-suspended',
          created: false,
          messagesProvided: true,
          messages: [
            DesktopSessionMessage.tryParse(const {
              'role': 'user',
              'content': 'turno en curso',
            })!,
          ],
          inflight: DesktopInflightTurn(
            user: 'turno en curso',
            streaming: true,
          ),
          running: true,
        );

    _LifecycleRecoverableGateway streamingGateway() =>
        _LifecycleRecoverableGateway()
          ..initialSnapshot = runningSnapshot('runtime-desktop-1')
          ..recoverySnapshot = runningSnapshot('runtime-desktop-2');

    test(
      'reconcileAfterResume reengancha un turno cuyo socket murió en silencio',
      () async {
        final gateway = streamingGateway()
          ..recoveredState = DesktopTurnState.running;
        final chat = _recoverableChat('suspended', gateway);
        addTearDown(chat.dispose);

        await chat.loadMessages();
        expect(chat.isStreaming, isTrue);

        // Minimizar: el socket muere sin entregar cierre ni error.
        gateway.dropSilently();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        // Sin la reconciliación, el chat se queda ejecutando para siempre.
        expect(chat.isStreaming, isTrue);
        expect(gateway.resumeExistingCalls, 1);

        await chat.reconcileAfterResume();
        await _waitUntil(() => gateway.resumeExistingCalls == 2);

        // El turno se reengancha sobre el socket nuevo y vuelve a recibir.
        expect(gateway.connectCalls, greaterThanOrEqualTo(2));
        expect(gateway.committedRecoveryRuntimeIds, isNotEmpty);
        final runtimeId = gateway.committedRecoveryRuntimeIds.last;
        gateway.emit(
          'message.complete',
          sessionId: runtimeId,
          payload: const {'text': 'respuesta recuperada'},
        );
        await _waitUntil(() => chat.state == ChatPipelineState.completed);
        expect(chat.messages.first['content'], 'respuesta recuperada');
      },
    );

    test('reabrir el chat también reengancha el turno colgado', () async {
      final gateway = streamingGateway()
        ..recoveredState = DesktopTurnState.running;
      final chat = _recoverableChat('reopened', gateway);
      addTearDown(chat.dispose);

      await chat.loadMessages();
      expect(chat.isStreaming, isTrue);
      gateway.dropSilently();

      // `warmDesktopGateway` es lo que ejecuta la pantalla al volver a abrir.
      await chat.warmDesktopGateway();
      await _waitUntil(() => gateway.resumeExistingCalls == 2);
      expect(gateway.committedRecoveryRuntimeIds, isNotEmpty);
    });

    test(
      'un turno que Hermes ya no conoce se cierra en vez de quedarse colgado',
      () async {
        final gateway = streamingGateway();
        final chat = _recoverableChat(
          'forgotten',
          gateway,
          desktopRecoveryBackoff: const [Duration.zero],
        );
        addTearDown(chat.dispose);

        await chat.loadMessages();
        expect(chat.isStreaming, isTrue);

        gateway.resumeExistingError = const TuiGatewayRpcError(
          'session.resume',
          'unknown session',
          code: 4007,
        );
        gateway.dropSilently();
        await chat.reconcileAfterResume();

        await _waitUntil(() => !chat.isStreaming);
        expect(chat.state, ChatPipelineState.failed);
      },
    );

    test('un transporte vivo no dispara ninguna recuperación', () async {
      final gateway = streamingGateway();
      final chat = _recoverableChat('healthy', gateway);
      addTearDown(chat.dispose);

      await chat.loadMessages();
      expect(chat.isStreaming, isTrue);
      final resumesBefore = gateway.resumeExistingCalls;

      await chat.reconcileAfterResume();
      await chat.warmDesktopGateway();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(gateway.resumeExistingCalls, resumesBefore);
      expect(chat.state, isNot(ChatPipelineState.failed));
    });
  });
}

class _NoopOutbox implements TurnOutboxPersistence {
  @override
  Future<void> delete(PreparedTurn turn) async {}

  @override
  Future<void> save(PreparedTurn turn) async {}
}
