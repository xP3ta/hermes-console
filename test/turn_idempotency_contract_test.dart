import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/command_descriptor.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_compression_result.dart';
import 'package:hermes_android/core/models/desktop_session_config.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/connection_diagnostics.dart';
import 'package:hermes_android/core/services/compression_restore_store.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/recovery_proof.dart';
import 'package:hermes_android/core/services/replay_coordinator.dart';
import 'package:hermes_android/core/services/session_config_reducer.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _MemoryOutbox implements TurnOutboxPersistence {
  _MemoryOutbox({this.beforeSave});

  final Future<void> Function(PreparedTurn turn, int attempt)? beforeSave;
  final List<PreparedTurn> writes = [];
  final List<PreparedTurn> deletes = [];

  @override
  Future<void> save(PreparedTurn turn) async {
    await beforeSave?.call(turn, writes.length + 1);
    writes.add(turn);
  }

  @override
  Future<void> delete(PreparedTurn turn) async => deletes.add(turn);
}

class _GatedCompressionFenceStorage implements CompressionRestoreStorage {
  Completer<void>? readEntered;
  Completer<void>? releaseRead;
  String? value;

  void gateNextRead() {
    readEntered = Completer<void>();
    releaseRead = Completer<void>();
  }

  @override
  Future<String?> read() async {
    final entered = readEntered;
    final release = releaseRead;
    if (entered != null && release != null) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
      if (identical(releaseRead, release)) {
        readEntered = null;
        releaseRead = null;
      }
    }
    return value;
  }

  @override
  Future<void> write(String next) async {
    value = next;
  }
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

  void emit(
    String type, {
    String sessionId = 'runtime-legacy',
    Map<String, dynamic> payload = const {},
    int? sequence,
    int? transportGeneration,
    Object? producerChannel,
  }) {
    _events.add(
      TuiGatewayEvent(
        type: type,
        sessionId: sessionId,
        sequence: sequence,
        transportGeneration: transportGeneration,
        producerChannel: producerChannel,
        payload: payload,
      ),
    );
  }

  void emitError(Object error) => _events.addError(error);

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
    implements
        HermesDesktopIdempotentGateway,
        HermesDesktopTypedRecoveryGateway {
  final ReplayCoordinator _recovery = ReplayCoordinator();
  final Object _recoveryChannel = Object();
  final List<(String, String, String)> idempotentSubmissions = [];
  int statusCalls = 0;
  Object? submissionError;
  bool duplicate = false;
  DesktopTurnState ackState = DesktopTurnState.accepted;
  DesktopTurnStatus? nextStatus;

  @override
  RecoveryProof recoveryProofForSnapshot(
    DesktopSessionSnapshot snapshot, {
    required String connectionId,
    required String profile,
    required int bindGeneration,
    required int sessionGeneration,
    required int turnGeneration,
    required Set<RecoveryDomain> coverage,
    int? postSnapshotSequence,
  }) {
    _recovery.quarantine(snapshot.runtimeSessionId);
    return _recovery.mintRecoveryProof(
      connectionId: connectionId,
      durableSessionId: snapshot.storedSessionId,
      runtimeSessionId: snapshot.runtimeSessionId,
      profile: profile,
      socketGeneration: 1,
      channel: _recoveryChannel,
      bindGeneration: bindGeneration,
      sessionGeneration: sessionGeneration,
      turnGeneration: turnGeneration,
      replayEpoch: null,
      created: snapshot.created,
      durableIdentityExplicit: snapshot.storedSessionIdentityExplicit,
      identityAliasesConsistent: snapshot.identityAliasesConsistent,
      // This fixture models an authority-bearing replay coordinator, not the
      // current upstream response. Production's empty/null control is covered
      // by tui_gateway_authority_boundary_test.
      coverage: RecoveryDomain.values.toSet(),
      postSnapshotSequence: 1,
    );
  }

  @override
  bool validateRecovery(RecoveryProof proof) => _recovery.canCommitRecovery(
    proof,
    socketGeneration: 1,
    channel: _recoveryChannel,
    replayEpoch: null,
  );

  @override
  bool commitRecovery(RecoveryProof proof) => _recovery.commitRecovery(
    proof,
    socketGeneration: 1,
    channel: _recoveryChannel,
    replayEpoch: null,
  );

  @override
  bool recoveryAuthorityStillCurrent(RecoveryProof proof) =>
      _recovery.isRecoveryAuthorityCurrent(
        proof,
        socketGeneration: 1,
        channel: _recoveryChannel,
        replayEpoch: null,
      );

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

class _OwnershipGateway extends _ModernGateway
    implements
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopAttachmentGateway {
  _OwnershipGateway({
    required this.resumeRuntimeIds,
    this.idempotentSubmissionErrors = const [],
    this.normalSubmissionErrors = const [],
    this.onResumeExisting,
    this.onIdempotentSubmit,
  });

  final List<String> resumeRuntimeIds;
  final List<Object?> idempotentSubmissionErrors;
  final List<Object?> normalSubmissionErrors;
  final Future<void> Function(int call)? onResumeExisting;
  final Future<void> Function(int call)? onIdempotentSubmit;
  final List<(String, String)> resumes = [];
  final List<(String, String)> imageAttachments = [];
  final List<(String, String)> fileAttachments = [];
  int _resumeIndex = 0;

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    resumes.add((storedSessionId, profile));
    final resumeIndex = _resumeIndex;
    _resumeIndex += 1;
    await onResumeExisting?.call(resumes.length);
    final runtimeId =
        resumeRuntimeIds[resumeIndex.clamp(0, resumeRuntimeIds.length - 1)];
    return DesktopSessionSnapshot(
      runtimeSessionId: runtimeId,
      storedSessionId: storedSessionId,
      created: false,
    );
  }

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) => throw StateError('ownership recovery must never create a session');

  @override
  Future<DesktopAttachmentResult> attachImageBytes(
    String runtimeSessionId, {
    required String filename,
    required String contentBase64,
  }) async {
    imageAttachments.add((runtimeSessionId, filename));
    return DesktopAttachmentResult(path: '/remote/$filename');
  }

  @override
  Future<DesktopAttachmentResult> attachFileBytes(
    String runtimeSessionId, {
    required String filename,
    required String mimeType,
    required String contentBase64,
  }) async {
    fileAttachments.add((runtimeSessionId, filename));
    return DesktopAttachmentResult(
      path: '/remote/$filename',
      refText: '@file:.hermes/$filename',
    );
  }

  @override
  Future<void> detachImage(String runtimeSessionId, String path) async {}

  @override
  Future<DesktopTurnAck> submitPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  ) async {
    idempotentSubmissions.add((runtimeSessionId, text, clientTurnId));
    await onIdempotentSubmit?.call(idempotentSubmissions.length);
    final attempt = idempotentSubmissions.length - 1;
    if (attempt < idempotentSubmissionErrors.length) {
      final error = idempotentSubmissionErrors[attempt];
      if (error != null) throw error;
    }
    return DesktopTurnAck(
      accepted: true,
      clientTurnId: clientTurnId,
      serverTurnId: 'server-turn-1',
      state: DesktopTurnState.accepted,
      duplicate: false,
    );
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submissions.add((runtimeSessionId, text));
    final attempt = submissions.length - 1;
    if (attempt < normalSubmissionErrors.length) {
      final error = normalSubmissionErrors[attempt];
      if (error != null) throw error;
    }
  }
}

class _RecheckOwnershipGateway extends _OwnershipGateway
    implements HermesDesktopSessionActivityGateway {
  _RecheckOwnershipGateway({
    required super.resumeRuntimeIds,
    super.idempotentSubmissionErrors,
    this.activeLists = const [],
  });

  final List<DesktopActiveSessionList> activeLists;
  final List<String> activations = [];
  final List<(String, String)> steerCalls = [];
  DesktopSessionSnapshot? activationSnapshotOverride;
  Completer<DesktopActiveSessionList>? activeListGate;
  final Completer<void> activeListEntered = Completer<void>();
  final List<String> activeListRequests = [];
  int _activeListIndex = 0;

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => DesktopGatewayCapabilityState.supported;

  @override
  Future<DesktopActiveSessionList> listActiveSessions({
    String currentRuntimeSessionId = '',
  }) async {
    activeListRequests.add(currentRuntimeSessionId);
    if (!activeListEntered.isCompleted) activeListEntered.complete();
    final gate = activeListGate;
    if (gate != null) return gate.future;
    if (activeLists.isEmpty) return const DesktopActiveSessionList();
    final index = _activeListIndex.clamp(0, activeLists.length - 1);
    _activeListIndex += 1;
    return activeLists[index];
  }

  @override
  Future<DesktopSessionSnapshot> activateSession(
    String runtimeSessionId, {
    required String storedSessionId,
  }) async {
    activations.add(runtimeSessionId);
    return activationSnapshotOverride ??
        DesktopSessionSnapshot(
          runtimeSessionId: runtimeSessionId,
          storedSessionId: storedSessionId,
          created: false,
        );
  }

  @override
  Future<void> steer(String runtimeSessionId, String text) async {
    steerCalls.add((runtimeSessionId, text));
  }
}

class _RuntimeReleaseGateway extends _RecheckOwnershipGateway
    implements HermesDesktopSessionCloseGateway {
  _RuntimeReleaseGateway({required super.activeLists})
    : super(resumeRuntimeIds: const ['runtime-owned']);

  final List<String> closeRequests = [];
  final List<String> createProfiles = [];
  bool closeResult = true;
  Completer<bool>? closeGate;
  Completer<void>? submitGate;
  final Completer<void> closeEntered = Completer<void>();
  final Completer<void> submitEntered = Completer<void>();

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    createProfiles.add(profile);
    return const DesktopSessionSnapshot(
      runtimeSessionId: 'runtime-owned',
      storedSessionId: 'session-modern',
      created: true,
    );
  }

  @override
  Future<DesktopTurnAck> submitPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  ) async {
    idempotentSubmissions.add((runtimeSessionId, text, clientTurnId));
    if (!submitEntered.isCompleted) submitEntered.complete();
    await submitGate?.future;
    return DesktopTurnAck(
      accepted: true,
      clientTurnId: clientTurnId,
      serverTurnId: 'server-turn-1',
      state: DesktopTurnState.accepted,
      duplicate: false,
    );
  }

  @override
  Future<bool> closeSession(String runtimeSessionId) async {
    closeRequests.add(runtimeSessionId);
    if (!closeEntered.isCompleted) closeEntered.complete();
    return closeGate?.future ?? closeResult;
  }
}

/// Gateway de liberación que además publica el terminal de interrupción, que
/// es lo que permite a un Stop asentarse sin retirar el runtime.
class _StopThenReleaseGateway extends _RuntimeReleaseGateway {
  _StopThenReleaseGateway({required super.activeLists});

  final List<String> interruptRequests = [];

  @override
  Future<void> interrupt(String runtimeSessionId) async {
    interruptRequests.add(runtimeSessionId);
    emit(
      'message.complete',
      sessionId: runtimeSessionId,
      payload: const {'text': 'Operation interrupted'},
    );
  }
}

class _ReleaseApprovalGateway extends _RuntimeReleaseGateway
    implements HermesDesktopApprovalResultGateway {
  _ReleaseApprovalGateway({required super.activeLists});

  final List<({String runtimeId, String choice, String requestId})>
  approvalCalls = [];

  @override
  Future<DesktopApprovalResult> resolveApprovalChecked(
    String runtimeSessionId,
    String choice, {
    required String requestId,
  }) async {
    approvalCalls.add((
      runtimeId: runtimeSessionId,
      choice: choice,
      requestId: requestId,
    ));
    return const DesktopApprovalResult(resolved: 1);
  }
}

class _ReleaseConfigGateway extends _RuntimeReleaseGateway
    implements HermesDesktopSessionConfigGateway {
  _ReleaseConfigGateway({required super.activeLists});

  final Completer<void> configEntered = Completer<void>();
  final Completer<DesktopConfigSetResult> configGate =
      Completer<DesktopConfigSetResult>();

  Future<DesktopConfigSetResult> _config() {
    if (!configEntered.isCompleted) configEntered.complete();
    return configGate.future;
  }

  @override
  Future<DesktopConfigSetResult> setSessionModel(
    String runtimeSessionId,
    DesktopModelSelection selection, {
    bool confirmExpensiveModel = false,
  }) => _config();

  @override
  Future<DesktopConfigSetResult> setSessionReasoning(
    String runtimeSessionId,
    DesktopReasoningEffort effort,
  ) => _config();

  @override
  Future<DesktopConfigSetResult> setSessionFastMode(
    String runtimeSessionId,
    DesktopFastMode mode,
  ) => _config();
}

class _SequencedReleaseConfigGateway extends _RuntimeReleaseGateway
    implements HermesDesktopSessionConfigGateway {
  _SequencedReleaseConfigGateway({required super.activeLists});

  final List<Completer<DesktopConfigSetResult>> configGates = [];

  Future<DesktopConfigSetResult> _config() {
    final gate = Completer<DesktopConfigSetResult>();
    configGates.add(gate);
    return gate.future;
  }

  @override
  Future<DesktopConfigSetResult> setSessionModel(
    String runtimeSessionId,
    DesktopModelSelection selection, {
    bool confirmExpensiveModel = false,
  }) => _config();

  @override
  Future<DesktopConfigSetResult> setSessionReasoning(
    String runtimeSessionId,
    DesktopReasoningEffort effort,
  ) => _config();

  @override
  Future<DesktopConfigSetResult> setSessionFastMode(
    String runtimeSessionId,
    DesktopFastMode mode,
  ) => _config();
}

class _ReleaseMutationGateway extends _ReleaseConfigGateway
    implements HermesDesktopCommandGateway, HermesDesktopCompressionGateway {
  _ReleaseMutationGateway({required super.activeLists});

  final Completer<void> slashEntered = Completer<void>();
  final Completer<DesktopCommandRpcResult> slashGate =
      Completer<DesktopCommandRpcResult>();
  final Completer<void> compressionEntered = Completer<void>();
  final Completer<DesktopCompressionResult> compressionGate =
      Completer<DesktopCompressionResult>();

  @override
  Future<DesktopCommandCatalog> commandsCatalog() async =>
      DesktopCommandCatalog.fromJson(const {'pairs': <Object>[]});

  @override
  Future<SlashCompletionBatch> completeSlash(String text) async =>
      SlashCompletionBatch.fromJson(const {'items': <Object>[]}, input: text);

  @override
  Future<DesktopCommandRpcResult> slashExec(
    String runtimeSessionId,
    String command,
  ) {
    if (!slashEntered.isCompleted) slashEntered.complete();
    return slashGate.future;
  }

  @override
  Future<DesktopCommandRpcResult> commandDispatch(
    String runtimeSessionId, {
    required String name,
    String arg = '',
  }) => slashExec(runtimeSessionId, name);

  @override
  Future<DesktopCompressionResult> compressSession(
    String runtimeSessionId, {
    String focusTopic = '',
  }) {
    if (!compressionEntered.isCompleted) compressionEntered.complete();
    return compressionGate.future;
  }
}

class _ConflictMutationGateway extends _RecheckOwnershipGateway
    implements HermesDesktopCompressionGateway {
  _ConflictMutationGateway({
    required super.resumeRuntimeIds,
    super.idempotentSubmissionErrors,
  });

  int compressionCalls = 0;

  @override
  Future<DesktopCompressionResult> compressSession(
    String runtimeSessionId, {
    String focusTopic = '',
  }) {
    compressionCalls += 1;
    return Future<DesktopCompressionResult>.error(
      StateError('compression must remain blocked'),
    );
  }
}

({ActiveChat chat, ActiveTurnDelivery delivery, _MemoryOutbox store}) _fixture(
  HermesDesktopGateway gateway, {
  Future<bool> Function()? capability,
  String profile = '',
  List<AttachmentDraft> attachments = const [],
  _MemoryOutbox? outbox,
  int Function()? wallClockMs,
  Duration desktopRecoveryAttemptTimeout = const Duration(seconds: 15),
  CompressionRestoreStore? compressionRestoreStore,
  ApprovalPolicyService? policy,
}) {
  final api = ApiClient(
    baseUrl: 'https://example.invalid',
    apiKey: 'test-only',
    httpClient: MockClient((_) async => http.Response('unused', 500)),
  );
  final chat = ActiveChat(
    compressionRestoreStore: compressionRestoreStore ?? testCompressionRestoreStore(),
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
    policy: policy,
    onTerminal: () {},
    api: api,
    desktopGateway: gateway,
    storedMessageLoader: gateway is _RuntimeReleaseGateway
        ? (_, _) async => const [
            {
              'message_id': 'release-user',
              'role': 'user',
              'content': 'prime release ownership',
            },
            {
              'message_id': 'release-assistant',
              'role': 'assistant',
              'content': 'ownership terminal',
            },
          ]
        : null,
    allowUnownedDesktopSnapshotForTesting: true,
    turnIdempotencyCapability: capability,
    wallClockMs: wallClockMs,
    desktopRecoveryAttemptTimeout: desktopRecoveryAttemptTimeout,
  );
  final now = DateTime.now().millisecondsSinceEpoch;
  final store = outbox ?? _MemoryOutbox();
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
        attachments: attachments,
        model: 'hermes-agent',
        profile: profile,
      ),
      store: store,
    ),
    store: store,
  );
}

Future<ApprovalPolicyService> _approvalPolicy(ApprovalMode mode) async {
  SharedPreferences.setMockInitialValues({
    'approval_global_mode': mode.storageKey,
  });
  return ApprovalPolicyService(await SharedPreferences.getInstance());
}

Future<void> _primeProductionReleaseOwnership(
  ({ActiveChat chat, ActiveTurnDelivery delivery, _MemoryOutbox store}) fixture,
  _RuntimeReleaseGateway gateway,
) async {
  fixture.chat.markStoredSessionMissing();
  expect(
    await fixture.chat.send(
      fullText: 'prime release ownership',
      model: 'hermes-agent',
      history: const [],
    ),
    isTrue,
  );
  final done = fixture.chat.changes.firstWhere(
    (event) => event == ActiveChatEvent.done,
  );
  gateway.emit(
    'message.complete',
    sessionId: 'runtime-owned',
    payload: const {'text': 'ownership terminal'},
  );
  await done;
  gateway.activeListRequests.clear();
  gateway.idempotentSubmissions.clear();
  gateway.submissions.clear();
}

Future<({ActiveChat chat, _RuntimeReleaseGateway gateway})> _releaseFixture(
  DesktopActiveSessionList releaseRoster, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final gateway = _RuntimeReleaseGateway(activeLists: [releaseRoster]);
  final fixture = _fixture(
    gateway,
    capability: () async => true,
    desktopRecoveryAttemptTimeout: timeout,
  );
  await _primeProductionReleaseOwnership(fixture, gateway);
  return (chat: fixture.chat, gateway: gateway);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'draft create accepted submit mints exact production release provenance',
    () async {
      const idle = DesktopActiveSessionList(
        sessions: [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-owned',
            storedSessionId: 'session-modern',
            current: true,
            status: 'idle',
          ),
        ],
      );
      final gateway = _RuntimeReleaseGateway(activeLists: const [idle])
        ..submitGate = Completer<void>();
      final fixture = _fixture(gateway, capability: () async => true);
      addTearDown(fixture.chat.dispose);
      fixture.chat.markStoredSessionMissing();

      final send = fixture.chat.send(
        fullText: 'primer turno real',
        model: 'hermes-agent',
        history: const [],
        delivery: fixture.delivery,
      );
      await gateway.submitEntered.future;

      expect(gateway.createProfiles, ['default']);
      expect(gateway.idempotentSubmissions, [
        ('runtime-owned', 'primer turno real', 'client-turn-1'),
      ]);
      expect(fixture.chat.showReleaseToDesktopControl, isFalse);
      expect(fixture.chat.canReleaseToDesktop, isFalse);
      expect(await fixture.chat.releaseRuntimeForDesktop(), isFalse);
      expect(gateway.activeListRequests, isEmpty);
      expect(gateway.closeRequests, isEmpty);

      gateway.submitGate!.complete();
      expect(await send, isTrue);
      expect(fixture.chat.showReleaseToDesktopControl, isTrue);
      expect(fixture.chat.canReleaseToDesktop, isFalse);

      final done = fixture.chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.done,
      );
      gateway.emit(
        'message.complete',
        sessionId: 'runtime-owned',
        payload: const {'text': 'terminal'},
        sequence: 1,
        transportGeneration: 1,
        producerChannel: Object(),
      );
      await done;

      expect(fixture.chat.canReleaseToDesktop, isTrue);
      expect(await fixture.chat.releaseRuntimeForDesktop(), isTrue);
      expect(gateway.activeListRequests, ['runtime-owned']);
      expect(gateway.closeRequests, ['runtime-owned']);
      expect(fixture.chat.showReleaseToDesktopControl, isFalse);
    },
  );

  test(
    'same service retains accepted owner for canonical reopen but fresh service cannot infer it',
    () async {
      const idle = DesktopActiveSessionList(
        sessions: [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-owned',
            storedSessionId: 'session-modern',
            current: true,
            status: 'idle',
          ),
        ],
      );
      final gateway = _RuntimeReleaseGateway(activeLists: const [idle]);
      final service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      addTearDown(service.dispose);
      final connection = SavedConnection(
        id: 'conn-modern',
        label: 'Modern',
        host: 'example.invalid',
        port: 443,
        apiKey: 'test-key',
        useHttps: true,
      );
      final api = ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      );
      final chat = service.attach(
        connection: connection,
        sessionId: 'draft-route',
        sessionTitle: 'Draft',
        api: api,
        desktopGateway: gateway,
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'user-1',
            'role': 'user',
            'content': 'crear y conservar',
          },
          {
            'message_id': 'assistant-1',
            'role': 'assistant',
            'content': 'terminal',
          },
        ],
        turnIdempotencyCapability: () async => true,
        disableForegroundKeepAlive: true,
      );
      chat.markStoredSessionMissing();
      final screenSubscription = chat.changes.listen((_) {});
      final now = DateTime.now().millisecondsSinceEpoch;
      final delivery = ActiveTurnDelivery(
        prepared: PreparedTurn(
          connectionId: connection.id,
          sessionId: 'draft-route',
          clientTurnId: 'same-process-turn',
          createdAtMs: now,
          updatedAtMs: now,
          text: 'crear y conservar',
          attachments: const [],
          model: 'hermes-agent',
          profile: '',
        ),
        store: _MemoryOutbox(),
      );

      expect(
        await chat.send(
          fullText: 'crear y conservar',
          model: 'hermes-agent',
          history: const [],
          delivery: delivery,
        ),
        isTrue,
      );
      final done = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.done,
      );
      gateway.emit(
        'message.complete',
        sessionId: 'runtime-owned',
        payload: const {'text': 'terminal'},
        sequence: 1,
        transportGeneration: 1,
        producerChannel: Object(),
      );
      await done;
      await screenSubscription.cancel();
      service.release(connection.id, 'draft-route', profile: 'default');
      await Future<void>.delayed(Duration.zero);

      final reopened = service.attach(
        connection: connection,
        sessionId: 'session-modern',
        sessionTitle: 'Canonical',
        initialStoredSessionId: 'session-modern',
        authoritativeStoredSessionBinding: true,
        desktopGateway: gateway,
      );
      expect(reopened, same(chat));
      expect(reopened.showReleaseToDesktopControl, isTrue);
      expect(gateway.activations, isEmpty);
      expect(gateway.resumes, isEmpty);
      expect(await reopened.releaseRuntimeForDesktop(), isTrue);
      expect(gateway.activeListRequests, ['runtime-owned']);
      expect(gateway.closeRequests, ['runtime-owned']);

      final freshGateway = _RuntimeReleaseGateway(activeLists: const [idle]);
      final freshService = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      addTearDown(freshService.dispose);
      freshGateway.activationSnapshotOverride = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-owned',
        storedSessionId: 'session-modern',
        created: false,
        messagesProvided: true,
      );
      final fresh = freshService.attach(
        connection: connection,
        sessionId: 'session-modern',
        sessionTitle: 'Canonical',
        initialStoredSessionId: 'session-modern',
        authoritativeStoredSessionBinding: true,
        api: ApiClient(
          baseUrl: 'https://example.invalid',
          apiKey: 'test-key',
          httpClient: MockClient((_) async => http.Response('unused', 500)),
        ),
        desktopGateway: freshGateway,
        storedMessageLoader: (_, _) async => const [
          {'message_id': 'user-1', 'role': 'user', 'content': 'historial'},
          {
            'message_id': 'assistant-1',
            'role': 'assistant',
            'content': 'terminal',
          },
        ],
      );
      await fresh.loadMessages();

      expect(fresh.desktopRuntimeSessionId, 'runtime-owned');
      expect(freshGateway.activeListRequests, isNotEmpty);
      expect(freshGateway.activations, ['runtime-owned']);
      expect(fresh.showReleaseToDesktopControl, isFalse);
      expect(fresh.canReleaseToDesktop, isFalse);
      expect(await fresh.releaseRuntimeForDesktop(), isFalse);
      expect(freshGateway.closeRequests, isEmpty);
    },
  );

  test('un Stop confirmado devuelve la liberación a Desktop', () async {
    const idle = DesktopActiveSessionList(
      sessions: [
        DesktopActiveSession(
          runtimeSessionId: 'runtime-owned',
          storedSessionId: 'session-modern',
          current: true,
          status: 'idle',
        ),
      ],
    );
    final gateway = _StopThenReleaseGateway(activeLists: const [idle]);
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);
    await _primeProductionReleaseOwnership(fixture, gateway);
    expect(fixture.chat.canReleaseToDesktop, isTrue);

    await fixture.chat.cancel();

    expect(fixture.chat.stopConfirmationState, StopConfirmationState.confirmed);
    expect(gateway.interruptRequests, ['runtime-owned']);
    // Un coordinador de Stop terminal no es trabajo en vuelo: deja de bloquear
    // la liberación del runtime durante el resto de la vida del ActiveChat.
    expect(fixture.chat.canReleaseToDesktop, isTrue);
  });

  test('gateway disconnect retires accepted release provenance', () async {
    final gateway = _RuntimeReleaseGateway(activeLists: const []);
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);
    fixture.chat.markStoredSessionMissing();
    expect(
      await fixture.chat.send(
        fullText: 'bind disconnect authority',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    expect(fixture.chat.showReleaseToDesktopControl, isTrue);

    gateway.emitError(const SocketException('disconnected'));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(fixture.chat.showReleaseToDesktopControl, isFalse);
    expect(fixture.chat.canReleaseToDesktop, isFalse);
    expect(await fixture.chat.releaseRuntimeForDesktop(), isFalse);
    expect(gateway.closeRequests, isEmpty);
  });

  test(
    'transport generation rotation revokes accepted release provenance',
    () async {
      const idle = DesktopActiveSessionList(
        sessions: [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-owned',
            storedSessionId: 'session-modern',
            current: true,
            status: 'idle',
          ),
        ],
      );
      final gateway = _RuntimeReleaseGateway(activeLists: const [idle]);
      final fixture = _fixture(gateway, capability: () async => true);
      addTearDown(fixture.chat.dispose);
      fixture.chat.markStoredSessionMissing();
      expect(
        await fixture.chat.send(
          fullText: 'bind transport authority',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      final channel = Object();
      final done = fixture.chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.done,
      );
      gateway.emit(
        'message.complete',
        sessionId: 'runtime-owned',
        payload: const {'text': 'terminal'},
        sequence: 1,
        transportGeneration: 1,
        producerChannel: channel,
      );
      await done;
      expect(fixture.chat.showReleaseToDesktopControl, isTrue);

      gateway.emit(
        'session.info',
        sessionId: 'runtime-owned',
        sequence: 1,
        transportGeneration: 2,
        producerChannel: Object(),
      );
      await Future<void>.delayed(Duration.zero);

      expect(fixture.chat.showReleaseToDesktopControl, isFalse);
      expect(fixture.chat.canReleaseToDesktop, isFalse);
      expect(await fixture.chat.releaseRuntimeForDesktop(), isFalse);
      expect(gateway.closeRequests, isEmpty);
    },
  );

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
        compressionRestoreStore: testCompressionRestoreStore(),
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

  test('el fence no permite limpiar un runtime que ya fue reemplazado', () {
    expect(
      activeChatRejectedRuntimeStillCurrent(
        expectedSessionEpoch: 4,
        currentSessionEpoch: 4,
        expectedBindEpoch: 8,
        currentBindEpoch: 9,
        rejectedRuntimeId: 'runtime-old',
        currentRuntimeId: 'runtime-new',
      ),
      isFalse,
    );
    expect(
      activeChatRejectedRuntimeStillCurrent(
        expectedSessionEpoch: 4,
        currentSessionEpoch: 4,
        expectedBindEpoch: 8,
        currentBindEpoch: 8,
        rejectedRuntimeId: 'runtime-old',
        currentRuntimeId: 'runtime-old',
      ),
      isTrue,
    );
  });

  test('el rechazo no resucita tombstones de adjuntos', () async {
    final fixture = _fixture(
      _ModernGateway(),
      attachments: const [
        AttachmentDraft(
          localId: 'removed-image',
          type: AttachmentType.image,
          name: 'removed.png',
          mimeType: 'image/png',
          sizeBytes: 3,
          localPath: '/tmp/removed.png',
          uploadState: AttachmentUploadState.removed,
          remoteRef: '/remote/removed.png',
          remoteSessionId: 'runtime-old',
          remoteTransport: AttachmentRemoteTransport.desktop,
        ),
      ],
    );
    addTearDown(fixture.chat.dispose);

    await fixture.delivery.markRejectedBeforeAcceptance(
      invalidateRemoteSessionId: 'runtime-old',
      invalidateTransport: AttachmentRemoteTransport.desktop,
    );

    expect(
      fixture.delivery.current.attachments.single.uploadState,
      AttachmentUploadState.removed,
    );
    expect(
      fixture.delivery.current.state,
      PreparedTurnState.failedBeforeAcceptance,
    );
  });

  test('SESSION_NOT_OWNED falla cerrado sin reanudar ni reenviar', () async {
    const rejection = TuiGatewayRpcError(
      'prompt.submit',
      'private ownership detail',
      code: 4090,
      data: {'reason': 'SESSION_NOT_OWNED'},
    );
    final gateway = _OwnershipGateway(
      resumeRuntimeIds: ['runtime-old', 'runtime-owner'],
      idempotentSubmissionErrors: [rejection, null],
    );
    final fixture = _fixture(
      gateway,
      capability: () async => true,
      profile: 'owner-profile',
    );
    addTearDown(fixture.chat.dispose);

    await fixture.chat.loadMessages(profile: 'owner-profile');
    expect(fixture.chat.desktopRuntimeSessionId, 'runtime-old');

    final accepted = await fixture.chat.send(
      fullText: 'mensaje moderno',
      model: 'hermes-agent',
      history: const [],
      profile: 'owner-profile',
      delivery: fixture.delivery,
    );

    expect(accepted, isFalse);
    expect(gateway.resumes, [('session-modern', 'owner-profile')]);
    expect(gateway.idempotentSubmissions, [
      ('runtime-old', 'mensaje moderno', 'client-turn-1'),
    ]);
    expect(fixture.chat.desktopRuntimeSessionId, isNull);
    expect(fixture.chat.state, ChatPipelineState.failed);
    expect(fixture.chat.turnIdempotencyInvalid, isFalse);
    expect(
      fixture.delivery.current.state,
      PreparedTurnState.failedBeforeAcceptance,
    );
    expect(
      fixture.store.writes.map((turn) => turn.state),
      containsAllInOrder(const [
        PreparedTurnState.submitting,
        PreparedTurnState.failedBeforeAcceptance,
      ]),
    );
    expect(
      fixture.chat.messages.where((message) => message['role'] == 'user'),
      hasLength(1),
    );
    expect(
      fixture.chat.messages.where(
        (message) =>
            message['role'] == 'assistant' && message['_pipeline'] == true,
      ),
      isEmpty,
    );
    final errors = fixture.chat.messages
        .where((message) => message['role'] == 'assistant_error')
        .toList(growable: false);
    expect(errors, hasLength(1));
    expect(
      errors.single['content'],
      isNot(contains('private ownership detail')),
    );
    expect(errors.single['content'], isNot(contains('runtime-owner')));
  });

  test('4090 bloquea taps y recheck nunca reenvía el PreparedTurn', () async {
    const rejection = TuiGatewayRpcError(
      'prompt.submit',
      'private ownership detail',
      code: 4090,
      data: {'reason': 'SESSION_NOT_OWNED'},
    );
    final gateway = _RecheckOwnershipGateway(
      resumeRuntimeIds: const ['runtime-old', 'runtime-rechecked'],
      idempotentSubmissionErrors: const [rejection, null],
      activeLists: const [DesktopActiveSessionList()],
    );
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);

    await fixture.chat.loadMessages();
    final first = await fixture.chat.send(
      fullText: 'mensaje moderno',
      model: 'hermes-agent',
      history: const [],
      delivery: fixture.delivery,
    );

    expect(first, isFalse);
    expect(fixture.chat.conflictReadOnly, isTrue);
    expect(gateway.idempotentSubmissions, hasLength(1));
    expect(fixture.delivery.current.clientTurnId, 'client-turn-1');
    expect(
      fixture.delivery.current.state,
      PreparedTurnState.failedBeforeAcceptance,
    );

    final blockedTap = await fixture.chat.send(
      fullText: 'mensaje moderno',
      model: 'hermes-agent',
      history: const [],
      delivery: fixture.delivery,
    );
    expect(blockedTap, isFalse);
    expect(gateway.idempotentSubmissions, hasLength(1));

    final available = await fixture.chat.recheckRuntimeOwnership();
    expect(available, isTrue);
    expect(fixture.chat.conflictReadOnly, isTrue);
    expect(gateway.idempotentSubmissions, hasLength(1));
    expect(fixture.delivery.current.clientTurnId, 'client-turn-1');
    expect(
      fixture.delivery.current.state,
      PreparedTurnState.failedBeforeAcceptance,
    );

    final manual = await fixture.chat.send(
      fullText: 'mensaje moderno',
      model: 'hermes-agent',
      history: const [],
      delivery: fixture.delivery,
    );
    expect(manual, isTrue);
    expect(fixture.chat.conflictReadOnly, isFalse);
    expect(gateway.idempotentSubmissions, hasLength(2));
    expect(gateway.idempotentSubmissions.last.$3, 'client-turn-1');
  });

  test('probe manual rechazado o ambiguo conserva el fence', () async {
    const rejection = TuiGatewayRpcError(
      'prompt.submit',
      'private ownership detail',
      code: 4090,
      data: {'reason': 'SESSION_NOT_OWNED'},
    );
    for (final probeFailure in <Object>[
      rejection,
      const SocketException('ambiguous manual probe'),
    ]) {
      final gateway = _RecheckOwnershipGateway(
        resumeRuntimeIds: const ['runtime-old', 'runtime-rechecked'],
        idempotentSubmissionErrors: [rejection, probeFailure],
      );
      final fixture = _fixture(gateway, capability: () async => true);
      addTearDown(fixture.chat.dispose);
      await fixture.chat.loadMessages();
      expect(
        await fixture.chat.send(
          fullText: 'mensaje moderno',
          model: 'hermes-agent',
          history: const [],
          delivery: fixture.delivery,
        ),
        isFalse,
      );
      expect(await fixture.chat.recheckRuntimeOwnership(), isTrue);

      expect(
        await fixture.chat.send(
          fullText: 'mensaje moderno',
          model: 'hermes-agent',
          history: const [],
          delivery: fixture.delivery,
        ),
        isFalse,
      );
      expect(fixture.chat.conflictReadOnly, isTrue);
      expect(gateway.idempotentSubmissions, hasLength(2));
      expect(gateway.idempotentSubmissions.last.$3, 'client-turn-1');
    }
  });

  test('recheck de ownership sigue disponible después del plazo temporal', () {
    final fixture = _fixture(
      _RecheckOwnershipGateway(resumeRuntimeIds: const ['runtime-old']),
      wallClockMs: () => DateTime.utc(2026, 9, 27).millisecondsSinceEpoch,
    );
    addTearDown(fixture.chat.dispose);

    expect(fixture.chat.ownershipRecheckAvailable, isTrue);
  });

  test(
    '4090 bloquea redirect aunque el runtime ajeno aparezca running',
    () async {
      const rejection = TuiGatewayRpcError(
        'prompt.submit',
        'private ownership detail',
        code: 4090,
        data: {'reason': 'SESSION_NOT_OWNED'},
      );
      final gateway = _RecheckOwnershipGateway(
        resumeRuntimeIds: const ['runtime-old'],
        idempotentSubmissionErrors: const [rejection],
      );
      final fixture = _fixture(gateway, capability: () async => true);
      addTearDown(fixture.chat.dispose);
      await fixture.chat.loadMessages();
      await fixture.chat.send(
        fullText: 'turno rechazado',
        model: 'hermes-agent',
        history: const [],
        delivery: fixture.delivery,
      );
      expect(fixture.chat.conflictReadOnly, isTrue);

      // Reader observation may discover that the foreign owner is running.
      fixture.chat.state = ChatPipelineState.waiting;
      await expectLater(
        fixture.chat.steer('NO DEBE MUTAR'),
        throwsA(
          isA<TuiGatewayRpcError>()
              .having((error) => error.code, 'code', 4090)
              .having((error) => error.reason, 'reason', 'SESSION_NOT_OWNED'),
        ),
      );
      expect(gateway.steerCalls, isEmpty);
    },
  );

  test(
    'release runtime propio idle cierra exacto y conserva estado durable',
    () async {
      final gateway = _RuntimeReleaseGateway(
        activeLists: const [
          DesktopActiveSessionList(
            sessions: [
              DesktopActiveSession(
                runtimeSessionId: 'runtime-owned',
                storedSessionId: 'session-modern',
                current: true,
                status: 'idle',
              ),
            ],
          ),
        ],
      );
      final fixture = _fixture(gateway, capability: () async => true);
      addTearDown(fixture.chat.dispose);
      gateway.activationSnapshotOverride = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-owned',
        storedSessionId: 'session-modern',
        created: false,
        messagesProvided: true,
        messages: [
          DesktopSessionMessage.tryParse(const {
            'message_id': 'durable-user',
            'role': 'user',
            'content': 'historial conservado',
          })!,
        ],
      );
      await _primeProductionReleaseOwnership(fixture, gateway);
      final messagesBefore = fixture.chat.messages;
      final deliveryBefore = fixture.delivery.current;
      final writesBefore = List<PreparedTurn>.of(fixture.store.writes);
      final deletesBefore = List<PreparedTurn>.of(fixture.store.deletes);

      expect(fixture.chat.showReleaseToDesktopControl, isTrue);
      expect(fixture.chat.canReleaseToDesktop, isTrue);
      expect(await fixture.chat.releaseRuntimeForDesktop(), isTrue);

      expect(gateway.activeListRequests, ['runtime-owned']);
      expect(gateway.closeRequests, ['runtime-owned']);
      expect(fixture.chat.desktopRuntimeSessionId, isNull);
      expect(fixture.chat.messages, messagesBefore);
      expect(fixture.delivery.current, deliveryBefore);
      expect(fixture.store.writes, writesBefore);
      expect(fixture.store.deletes, deletesBefore);
    },
  );

  test(
    'release rechaza roster malformed duplicate mismatch noncurrent y busy',
    () async {
      final rosters = <DesktopActiveSessionList>[
        const DesktopActiveSessionList(hasMalformedRows: true),
        const DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-owned',
              storedSessionId: 'session-modern',
              current: true,
              status: 'idle',
            ),
            DesktopActiveSession(
              runtimeSessionId: 'runtime-owned',
              storedSessionId: 'session-modern',
              current: true,
              status: 'idle',
            ),
          ],
        ),
        const DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-other',
              storedSessionId: 'session-modern',
              current: true,
              status: 'idle',
            ),
          ],
        ),
        const DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-owned',
              storedSessionId: 'session-modern',
              current: false,
              status: 'idle',
            ),
          ],
        ),
        const DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-owned',
              storedSessionId: 'session-modern',
              current: true,
              status: 'running',
            ),
          ],
        ),
      ];

      for (final roster in rosters) {
        final fixture = await _releaseFixture(roster);
        addTearDown(fixture.chat.dispose);

        expect(await fixture.chat.releaseRuntimeForDesktop(), isFalse);
        expect(fixture.chat.desktopRuntimeSessionId, 'runtime-owned');
        expect(fixture.gateway.activeListRequests, ['runtime-owned']);
        expect(fixture.gateway.closeRequests, isEmpty);
      }
    },
  );

  test('release bloquea submit que compite con session.close', () async {
    const idle = DesktopActiveSessionList(
      sessions: [
        DesktopActiveSession(
          runtimeSessionId: 'runtime-owned',
          storedSessionId: 'session-modern',
          current: true,
          status: 'idle',
        ),
      ],
    );
    final gateway = _StopThenReleaseGateway(activeLists: const [idle]);
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);
    await _primeProductionReleaseOwnership(fixture, gateway);
    gateway.closeGate = Completer<bool>();

    final release = fixture.chat.releaseRuntimeForDesktop();
    await gateway.closeEntered.future;
    final submitted = await fixture.chat.send(
      fullText: 'NO DEBE COMPETIR',
      model: 'hermes-agent',
      history: const [],
      delivery: fixture.delivery,
    );
    expect(submitted, isFalse);
    expect(gateway.idempotentSubmissions, isEmpty);
    expect(fixture.chat.canCompressDesktopSession, isFalse);
    await expectLater(
      fixture.chat.setSessionFastMode(DesktopFastMode.fast),
      throwsA(
        isA<TuiGatewayRpcError>()
            .having((error) => error.method, 'method', 'config.set')
            .having((error) => error.code, 'code', 4090),
      ),
    );
    await expectLater(
      fixture.chat.executeDesktopSlash('help'),
      throwsA(
        isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4090),
      ),
    );
    await fixture.chat.cancel();
    expect(gateway.interruptRequests, ['runtime-owned']);
    await expectLater(
      fixture.chat.steer('NO DEBE REDIRIGIR'),
      throwsA(
        isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4090),
      ),
    );
    gateway.closeGate!.complete(true);
    expect(await release, isFalse);
  });

  for (final approvalCase
      in <({String name, ApprovalMode mode, String choice})>[
        (
          name: 'auto approval',
          mode: ApprovalMode.yolo,
          choice: ApprovalScope.once.wire,
        ),
        (
          name: 'automatic deny',
          mode: ApprovalMode.readOnly,
          choice: ApprovalScope.deny.wire,
        ),
      ]) {
    test(
      '${approvalCase.name} arriving while session.close is held does not emit approval.resolve',
      () async {
        const idle = DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-owned',
              storedSessionId: 'session-modern',
              current: true,
              status: 'idle',
            ),
          ],
        );
        final gateway = _ReleaseApprovalGateway(activeLists: const [idle])
          ..closeGate = Completer<bool>();
        final fixture = _fixture(
          gateway,
          capability: () async => true,
          policy: await _approvalPolicy(approvalCase.mode),
        );
        addTearDown(fixture.chat.dispose);
        fixture.chat.markStoredSessionMissing();
        gateway.activeListRequests.clear();
        expect(
          await fixture.chat.send(
            fullText: 'prime desktop event ownership',
            model: 'hermes-agent',
            history: const [],
            delivery: fixture.delivery,
          ),
          isTrue,
        );
        final desktopProducer = Object();
        final firstRunDone = fixture.chat.changes.firstWhere(
          (event) => event == ActiveChatEvent.done,
        );
        gateway.emit(
          'message.complete',
          sessionId: 'runtime-owned',
          payload: const {'text': 'done'},
          sequence: 1,
          transportGeneration: 1,
          producerChannel: desktopProducer,
        );
        await firstRunDone;

        final release = fixture.chat.releaseRuntimeForDesktop();
        await gateway.closeEntered.future;
        final successorStarted = fixture.chat.changes.firstWhere(
          (event) => event == ActiveChatEvent.waiting,
        );
        gateway.emit(
          'message.start',
          sessionId: 'runtime-owned',
          sequence: 2,
          transportGeneration: 1,
          producerChannel: desktopProducer,
        );
        await successorStarted;
        final approvalHandled = fixture.chat.changes.firstWhere(
          (event) => event == ActiveChatEvent.toolProgress,
        );
        gateway.emit(
          'approval.request',
          sessionId: 'runtime-owned',
          payload: const {
            'request_id': 'approval-during-close',
            'command': 'touch protected',
            'pattern_key': 'touch',
          },
        );
        await approvalHandled;

        expect(gateway.approvalCalls, isEmpty);
        expect(
          fixture.chat.pendingApproval?['request_id'],
          'approval-during-close',
        );
        gateway.closeGate!.complete(false);
        expect(await release, isFalse);
        expect(
          fixture.chat.pendingApproval?['request_id'],
          'approval-during-close',
        );

        await fixture.chat.resolveApproval(approvalCase.choice);
        expect(gateway.approvalCalls, [
          (
            runtimeId: 'runtime-owned',
            choice: approvalCase.choice,
            requestId: 'approval-during-close',
          ),
        ]);
      },
    );
  }

  test(
    'release bloquea admisión de cola que compite con session.close',
    () async {
      const idle = DesktopActiveSessionList(
        sessions: [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-owned',
            storedSessionId: 'session-modern',
            current: true,
            status: 'idle',
          ),
        ],
      );

      final confirmed = await _releaseFixture(idle);
      addTearDown(confirmed.chat.dispose);
      confirmed.gateway.closeGate = Completer<bool>();

      final confirmedRelease = confirmed.chat.releaseRuntimeForDesktop();
      await confirmed.gateway.closeEntered.future;
      final prepared = _fixture(
        confirmed.gateway,
        capability: () async => true,
      );
      addTearDown(prepared.chat.dispose);

      expect(confirmed.chat.enqueue('texto durante close'), isFalse);
      expect(
        await confirmed.chat.enqueuePreparedTurn(prepared.delivery),
        isFalse,
      );
      expect(confirmed.chat.queuedMessages, isEmpty);
      expect(prepared.store.writes, isEmpty);
      expect(prepared.store.deletes, isEmpty);
      // A late local projection change cannot keep a binding after the exact
      // remote runtime has confirmed closure.
      confirmed.chat.state = ChatPipelineState.waiting;
      confirmed.gateway.closeGate!.complete(true);

      expect(await confirmedRelease, isTrue);
      expect(confirmed.chat.desktopRuntimeSessionId, isNull);

      final rejected = await _releaseFixture(idle);
      addTearDown(rejected.chat.dispose);
      rejected.gateway.closeGate = Completer<bool>();

      final rejectedRelease = rejected.chat.releaseRuntimeForDesktop();
      await rejected.gateway.closeEntered.future;
      expect(rejected.chat.enqueue('bloqueado durante close fallido'), isFalse);
      rejected.gateway.closeGate!.complete(false);

      expect(await rejectedRelease, isFalse);
      expect(rejected.chat.desktopRuntimeSessionId, 'runtime-owned');
      expect(rejected.chat.mutationsBlockedByOwnershipConflict, isFalse);
      expect(rejected.chat.enqueue('aceptado después del fallo'), isTrue);
      expect(rejected.chat.queuedMessages, ['aceptado después del fallo']);
    },
  );

  test('release must not race an already admitted config mutation', () async {
    const idle = DesktopActiveSessionList(
      sessions: [
        DesktopActiveSession(
          runtimeSessionId: 'runtime-owned',
          storedSessionId: 'session-modern',
          current: true,
          status: 'idle',
        ),
      ],
    );
    final gateway = _ReleaseConfigGateway(activeLists: const [idle]);
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);
    await _primeProductionReleaseOwnership(fixture, gateway);

    final config = fixture.chat.setSessionFastMode(DesktopFastMode.fast);
    await gateway.configEntered.future;
    try {
      final advertisedRelease = fixture.chat.canReleaseToDesktop;
      final released = await fixture.chat.releaseRuntimeForDesktop();
      expect(
        [advertisedRelease, released, gateway.closeRequests],
        [false, false, isEmpty],
        reason: 'an admitted config.set must reserve mutation authority',
      );
    } finally {
      if (!gateway.configGate.isCompleted) {
        gateway.configGate.complete(
          const DesktopConfigSetResult(
            key: DesktopSessionConfigKey.fast,
            value: 'fast',
          ),
        );
      }
      await config;
    }
  });

  test(
    'stale config completion cannot release across a newer request',
    () async {
      const idle = DesktopActiveSessionList(
        sessions: [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-owned',
            storedSessionId: 'session-modern',
            current: true,
            status: 'idle',
          ),
        ],
      );
      final gateway = _SequencedReleaseConfigGateway(activeLists: const [idle]);
      final fixture = _fixture(gateway, capability: () async => true);
      addTearDown(fixture.chat.dispose);
      await _primeProductionReleaseOwnership(fixture, gateway);

      final stale = fixture.chat.setSessionFastMode(DesktopFastMode.fast);
      final current = fixture.chat.setSessionFastMode(DesktopFastMode.normal);
      expect(gateway.configGates, hasLength(2));

      gateway.configGates.first.complete(
        const DesktopConfigSetResult(
          key: DesktopSessionConfigKey.fast,
          value: 'fast',
        ),
      );
      await expectLater(stale, throwsStateError);
      expect(fixture.chat.canReleaseToDesktop, isFalse);
      expect(await fixture.chat.releaseRuntimeForDesktop(), isFalse);
      expect(gateway.closeRequests, isEmpty);

      gateway.configGates.last.complete(
        const DesktopConfigSetResult(
          key: DesktopSessionConfigKey.fast,
          value: 'normal',
        ),
      );
      await current;
      expect(fixture.chat.canReleaseToDesktop, isFalse);
      gateway.emit(
        'session.info',
        sessionId: 'runtime-owned',
        payload: const {
          'info': {'stored_session_id': 'session-modern', 'fast': false},
        },
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        fixture.chat
            .pendingSessionConfigChange(DesktopSessionConfigKey.fast)
            ?.status,
        SessionConfigChangeStatus.confirmed,
      );
      expect(fixture.chat.canReleaseToDesktop, isTrue);
      expect(await fixture.chat.releaseRuntimeForDesktop(), isTrue);
      expect(gateway.closeRequests, ['runtime-owned']);
    },
  );

  test(
    'config confirmation dismissal supersedes only the exact current request',
    () async {
      const idle = DesktopActiveSessionList(
        sessions: [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-owned',
            storedSessionId: 'session-modern',
            current: true,
            status: 'idle',
          ),
        ],
      );
      final gateway = _SequencedReleaseConfigGateway(activeLists: const [idle]);
      final fixture = _fixture(gateway, capability: () async => true);
      addTearDown(fixture.chat.dispose);
      await _primeProductionReleaseOwnership(fixture, gateway);
      gateway.emit(
        'session.info',
        sessionId: 'runtime-owned',
        payload: const {
          'info': {'model': 'old-model', 'provider': 'provider-a'},
        },
      );
      await Future<void>.delayed(Duration.zero);

      final stale = fixture.chat.setSessionModel(
        DesktopModelSelection(modelId: 'model-a', providerSlug: 'provider-a'),
      );
      gateway.configGates.first.complete(
        const DesktopConfigSetResult(
          key: DesktopSessionConfigKey.model,
          value: 'model-a',
          confirmRequired: true,
          confirmMessage: 'Confirm A',
        ),
      );
      final staleConfirmation = await stale;

      final current = fixture.chat.setSessionModel(
        DesktopModelSelection(modelId: 'model-b', providerSlug: 'provider-a'),
      );
      gateway.configGates.last.complete(
        const DesktopConfigSetResult(
          key: DesktopSessionConfigKey.model,
          value: 'model-b',
          confirmRequired: true,
          confirmMessage: 'Confirm B',
        ),
      );
      final currentConfirmation = await current;

      expect(
        fixture.chat.dismissSessionConfigConfirmation(staleConfirmation),
        isFalse,
      );
      expect(
        fixture.chat
            .pendingSessionConfigChange(DesktopSessionConfigKey.model)
            ?.requestEpoch,
        currentConfirmation.requestEpoch,
      );
      expect(fixture.chat.canReleaseToDesktop, isFalse);

      expect(
        fixture.chat.dismissSessionConfigConfirmation(currentConfirmation),
        isTrue,
      );
      expect(
        fixture.chat
            .pendingSessionConfigChange(DesktopSessionConfigKey.model)
            ?.status,
        SessionConfigChangeStatus.superseded,
      );
      expect(fixture.chat.effectiveSessionConfig.model, 'old-model');
      expect(fixture.chat.canReleaseToDesktop, isTrue);
      expect(gateway.configGates, hasLength(2));
    },
  );

  test('release waits for an admitted slash mutation to settle', () async {
    const idle = DesktopActiveSessionList(
      sessions: [
        DesktopActiveSession(
          runtimeSessionId: 'runtime-owned',
          storedSessionId: 'session-modern',
          current: true,
          status: 'idle',
        ),
      ],
    );
    final gateway = _ReleaseMutationGateway(activeLists: const [idle]);
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);
    await _primeProductionReleaseOwnership(fixture, gateway);

    final slash = fixture.chat.executeDesktopSlash('help');
    await gateway.slashEntered.future;
    expect(fixture.chat.canReleaseToDesktop, isFalse);
    expect(await fixture.chat.releaseRuntimeForDesktop(), isFalse);
    expect(gateway.closeRequests, isEmpty);

    gateway.slashGate.complete(
      const DesktopCommandRpcResult(
        kind: DesktopCommandDispatchKind.none,
        accepted: DesktopCommandAcceptance.accepted,
      ),
    );
    await slash;
    expect(fixture.chat.canReleaseToDesktop, isTrue);
    expect(await fixture.chat.releaseRuntimeForDesktop(), isTrue);
    expect(gateway.closeRequests, ['runtime-owned']);
  });

  test('release waits for admitted compression preparation and RPC', () async {
    const idle = DesktopActiveSessionList(
      sessions: [
        DesktopActiveSession(
          runtimeSessionId: 'runtime-owned',
          storedSessionId: 'session-modern',
          current: true,
          status: 'idle',
        ),
      ],
    );
    final gateway = _ReleaseMutationGateway(activeLists: const [idle]);
    final fenceStorage = _GatedCompressionFenceStorage();
    final fixture = _fixture(
      gateway,
      capability: () async => true,
      compressionRestoreStore: CompressionRestoreStore(
        storage: fenceStorage,
      ),
    );
    addTearDown(fixture.chat.dispose);
    await _primeProductionReleaseOwnership(fixture, gateway);
    fenceStorage.gateNextRead();
    final readEntered = fenceStorage.readEntered!;
    final releaseRead = fenceStorage.releaseRead!;

    final compression = fixture.chat.compressDesktopSession();
    await readEntered.future;
    try {
      expect(fixture.chat.canReleaseToDesktop, isFalse);
      expect(await fixture.chat.releaseRuntimeForDesktop(), isFalse);
      expect(gateway.closeRequests, isEmpty);
    } finally {
      if (!releaseRead.isCompleted) {
        releaseRead.complete();
      }
    }
    await gateway.compressionEntered.future;
    expect(fixture.chat.canReleaseToDesktop, isFalse);

    gateway.compressionGate.complete(
      DesktopCompressionResult.fromJson(const {
        'status': 'compressed',
        'removed': 0,
        'summary': {'noop': true, 'aborted': false},
      }),
    );
    await compression;
    expect(fixture.chat.canReleaseToDesktop, isTrue);
    expect(await fixture.chat.releaseRuntimeForDesktop(), isTrue);
    expect(gateway.closeRequests, ['runtime-owned']);
  });

  test('release conserva binding ante closed false timeout y stale', () async {
    const idle = DesktopActiveSessionList(
      sessions: [
        DesktopActiveSession(
          runtimeSessionId: 'runtime-owned',
          storedSessionId: 'session-modern',
          current: true,
          status: 'idle',
        ),
      ],
    );

    final rejected = await _releaseFixture(idle);
    addTearDown(rejected.chat.dispose);
    rejected.gateway.closeResult = false;
    expect(await rejected.chat.releaseRuntimeForDesktop(), isFalse);
    expect(rejected.chat.desktopRuntimeSessionId, 'runtime-owned');
    expect(rejected.gateway.closeRequests, ['runtime-owned']);

    final timedOut = await _releaseFixture(
      idle,
      timeout: const Duration(milliseconds: 10),
    );
    addTearDown(timedOut.chat.dispose);
    timedOut.gateway.activeListGate = Completer<DesktopActiveSessionList>();
    expect(await timedOut.chat.releaseRuntimeForDesktop(), isFalse);
    expect(timedOut.chat.desktopRuntimeSessionId, 'runtime-owned');
    expect(timedOut.gateway.closeRequests, isEmpty);

    final closeTimedOut = await _releaseFixture(
      idle,
      timeout: const Duration(milliseconds: 10),
    );
    addTearDown(closeTimedOut.chat.dispose);
    closeTimedOut.gateway.closeGate = Completer<bool>();
    expect(await closeTimedOut.chat.releaseRuntimeForDesktop(), isFalse);
    expect(closeTimedOut.chat.desktopRuntimeSessionId, 'runtime-owned');
    expect(closeTimedOut.gateway.closeRequests, ['runtime-owned']);

    final staleList = await _releaseFixture(idle);
    addTearDown(staleList.chat.dispose);
    final listGate = Completer<DesktopActiveSessionList>();
    staleList.gateway.activeListGate = listGate;
    final staleListRelease = staleList.chat.releaseRuntimeForDesktop();
    staleList.chat.adoptDesktopRuntimeForTesting('runtime-new');
    listGate.complete(idle);
    expect(await staleListRelease, isFalse);
    expect(staleList.chat.desktopRuntimeSessionId, 'runtime-new');
    expect(staleList.gateway.closeRequests, isEmpty);

    final staleClose = await _releaseFixture(idle);
    addTearDown(staleClose.chat.dispose);
    final closeGate = Completer<bool>();
    staleClose.gateway.closeGate = closeGate;
    final staleCloseRelease = staleClose.chat.releaseRuntimeForDesktop();
    await staleClose.gateway.closeEntered.future;
    expect(staleClose.chat.runtimeReleaseInFlight, isTrue);
    expect(staleClose.chat.canReleaseToDesktop, isFalse);
    staleClose.chat.adoptDesktopRuntimeForTesting('runtime-new');
    closeGate.complete(true);
    expect(await staleCloseRelease, isFalse);
    expect(staleClose.chat.runtimeReleaseInFlight, isFalse);
    expect(staleClose.chat.desktopRuntimeSessionId, 'runtime-new');
    expect(staleClose.gateway.closeRequests, ['runtime-owned']);
  });

  test(
    'blockers locales cortan release antes de active_list y close',
    () async {
      const idle = DesktopActiveSessionList(
        sessions: [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-owned',
            storedSessionId: 'session-modern',
            current: true,
            status: 'idle',
          ),
        ],
      );

      final streaming = await _releaseFixture(idle);
      addTearDown(streaming.chat.dispose);
      streaming.chat.state = ChatPipelineState.waiting;
      expect(await streaming.chat.releaseRuntimeForDesktop(), isFalse);
      expect(streaming.gateway.activeListRequests, isEmpty);
      expect(streaming.gateway.closeRequests, isEmpty);

      final approval = await _releaseFixture(idle);
      addTearDown(approval.chat.dispose);
      approval.chat.pendingApproval = const {'request_id': 'approval-local'};
      expect(await approval.chat.releaseRuntimeForDesktop(), isFalse);
      expect(approval.gateway.activeListRequests, isEmpty);
      expect(approval.gateway.closeRequests, isEmpty);

      final tool = await _releaseFixture(idle);
      addTearDown(tool.chat.dispose);
      tool.chat.traceActive = true;
      expect(await tool.chat.releaseRuntimeForDesktop(), isFalse);
      expect(tool.gateway.activeListRequests, isEmpty);
      expect(tool.gateway.closeRequests, isEmpty);
    },
  );

  test('recheck ambiguo malformed mismatch y stale falla cerrado', () async {
    const rejection = TuiGatewayRpcError(
      'prompt.submit',
      'private ownership detail',
      code: 4090,
      data: {'reason': 'SESSION_NOT_OWNED'},
    );

    Future<({ActiveChat chat, _RecheckOwnershipGateway gateway})> conflicted(
      DesktopActiveSessionList active,
    ) async {
      final gateway = _RecheckOwnershipGateway(
        resumeRuntimeIds: const ['runtime-old', 'runtime-unused'],
        idempotentSubmissionErrors: const [rejection],
        activeLists: [active],
      );
      final fixture = _fixture(gateway, capability: () async => true);
      addTearDown(fixture.chat.dispose);
      await fixture.chat.loadMessages();
      await fixture.chat.send(
        fullText: 'mensaje moderno',
        model: 'hermes-agent',
        history: const [],
        delivery: fixture.delivery,
      );
      expect(fixture.chat.conflictReadOnly, isTrue);
      return (chat: fixture.chat, gateway: gateway);
    }

    final malformed = await conflicted(
      const DesktopActiveSessionList(hasMalformedRows: true),
    );
    expect(await malformed.chat.recheckRuntimeOwnership(), isFalse);
    expect(malformed.chat.conflictReadOnly, isTrue);

    final ambiguous = await conflicted(
      const DesktopActiveSessionList(
        sessions: [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-a',
            storedSessionId: 'session-modern',
            status: 'idle',
          ),
          DesktopActiveSession(
            runtimeSessionId: 'runtime-b',
            storedSessionId: 'session-modern',
            status: 'idle',
          ),
        ],
      ),
    );
    expect(await ambiguous.chat.recheckRuntimeOwnership(), isFalse);
    expect(ambiguous.gateway.activations, isEmpty);

    final runtimeCollision = await conflicted(
      const DesktopActiveSessionList(
        sessions: [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-shared',
            storedSessionId: 'session-modern',
            status: 'idle',
          ),
          DesktopActiveSession(
            runtimeSessionId: 'runtime-shared',
            storedSessionId: 'session-foreign',
            status: 'idle',
          ),
        ],
      ),
    );
    expect(await runtimeCollision.chat.recheckRuntimeOwnership(), isFalse);
    expect(runtimeCollision.chat.conflictReadOnly, isTrue);
    expect(runtimeCollision.gateway.activations, isEmpty);

    final mismatch = await conflicted(
      const DesktopActiveSessionList(
        sessions: [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-a',
            storedSessionId: 'session-modern',
            status: 'idle',
          ),
        ],
      ),
    );
    mismatch.gateway.activationSnapshotOverride = const DesktopSessionSnapshot(
      runtimeSessionId: 'runtime-foreign',
      storedSessionId: 'session-modern',
      created: false,
    );
    expect(await mismatch.chat.recheckRuntimeOwnership(), isFalse);
    expect(mismatch.chat.conflictReadOnly, isTrue);

    final stale = await conflicted(const DesktopActiveSessionList());
    final gate = Completer<DesktopActiveSessionList>();
    stale.gateway.activeListGate = gate;
    final recheck = stale.chat.recheckRuntimeOwnership();
    await stale.gateway.activeListEntered.future;
    stale.chat.adoptDesktopRuntimeForTesting('runtime-raced');
    gate.complete(const DesktopActiveSessionList());
    expect(await recheck, isFalse);
    expect(stale.chat.conflictReadOnly, isTrue);
  });

  test(
    'conflictReadOnly bloquea compresión antes de adquirir runtime',
    () async {
      const rejection = TuiGatewayRpcError(
        'prompt.submit',
        'private ownership detail',
        code: 4090,
        data: {'reason': 'SESSION_NOT_OWNED'},
      );
      final gateway = _ConflictMutationGateway(
        resumeRuntimeIds: const ['runtime-old', 'runtime-forbidden'],
        idempotentSubmissionErrors: const [rejection],
      );
      final fixture = _fixture(gateway, capability: () async => true);
      addTearDown(fixture.chat.dispose);
      await fixture.chat.loadMessages();
      await fixture.chat.send(
        fullText: 'mensaje moderno',
        model: 'hermes-agent',
        history: const [],
        delivery: fixture.delivery,
      );

      await expectLater(
        fixture.chat.compressDesktopSession(),
        throwsA(
          isA<TuiGatewayRpcError>()
              .having((error) => error.code, 'code', 4090)
              .having((error) => error.reason, 'reason', 'SESSION_NOT_OWNED'),
        ),
      );
      expect(gateway.compressionCalls, 0);
      expect(gateway.resumes, hasLength(1));

      expect(await fixture.chat.recheckRuntimeOwnership(), isTrue);
      await expectLater(
        fixture.chat.setSessionFastMode(DesktopFastMode.fast),
        throwsA(
          isA<TuiGatewayRpcError>()
              .having((error) => error.method, 'method', 'config.set')
              .having((error) => error.code, 'code', 4090),
        ),
      );
      await expectLater(
        fixture.chat.compressDesktopSession(),
        throwsA(
          isA<TuiGatewayRpcError>()
              .having((error) => error.code, 'code', 4090)
              .having((error) => error.reason, 'reason', 'SESSION_NOT_OWNED'),
        ),
      );
      expect(gateway.compressionCalls, 0);
    },
  );

  test(
    '4001 session not found reanuda el durable y reintenta una vez',
    () async {
      const rejection = TuiGatewayRpcError(
        'prompt.submit',
        'session not found',
        code: 4001,
      );
      final gateway = _OwnershipGateway(
        resumeRuntimeIds: ['runtime-stale', 'runtime-resumed'],
        idempotentSubmissionErrors: [rejection, null],
      );
      final fixture = _fixture(
        gateway,
        capability: () async => true,
        profile: 'owner-profile',
      );
      addTearDown(fixture.chat.dispose);

      await fixture.chat.loadMessages(profile: 'owner-profile');
      final accepted = await fixture.chat.send(
        fullText: 'mensaje moderno',
        model: 'hermes-agent',
        history: const [],
        profile: 'owner-profile',
        delivery: fixture.delivery,
      );

      expect(accepted, isTrue);
      expect(gateway.resumes, [
        ('session-modern', 'owner-profile'),
        ('session-modern', 'owner-profile'),
      ]);
      expect(gateway.idempotentSubmissions, [
        ('runtime-stale', 'mensaje moderno', 'client-turn-1'),
        ('runtime-resumed', 'mensaje moderno', 'client-turn-1'),
      ]);
      expect(fixture.chat.desktopRuntimeSessionId, 'runtime-resumed');
      expect(fixture.delivery.current.state, PreparedTurnState.running);
    },
  );

  test('4001 reintenta tras confirmar incluso el mismo runtime', () async {
    const rejection = TuiGatewayRpcError(
      'prompt.submit',
      'session not found',
      code: 4001,
    );
    final gateway = _OwnershipGateway(
      resumeRuntimeIds: ['runtime-stale', 'runtime-stale'],
      idempotentSubmissionErrors: [rejection],
    );
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);

    await fixture.chat.loadMessages();
    final accepted = await fixture.chat.send(
      fullText: 'mensaje moderno',
      model: 'hermes-agent',
      history: const [],
      delivery: fixture.delivery,
    );

    expect(accepted, isTrue);
    expect(gateway.resumes, hasLength(2));
    expect(gateway.idempotentSubmissions, [
      ('runtime-stale', 'mensaje moderno', 'client-turn-1'),
      ('runtime-stale', 'mensaje moderno', 'client-turn-1'),
    ]);
    expect(fixture.chat.turnIdempotencyInvalid, isFalse);
    expect(fixture.delivery.current.state, PreparedTurnState.running);
  });

  test('un segundo 4001 termina sin bucle', () async {
    const rejection = TuiGatewayRpcError(
      'prompt.submit',
      'session not found',
      code: 4001,
    );
    final gateway = _OwnershipGateway(
      resumeRuntimeIds: ['runtime-stale', 'runtime-resumed'],
      idempotentSubmissionErrors: [rejection, rejection],
    );
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);

    await fixture.chat.loadMessages();
    final accepted = await fixture.chat.send(
      fullText: 'mensaje moderno',
      model: 'hermes-agent',
      history: const [],
      delivery: fixture.delivery,
    );

    expect(accepted, isFalse);
    expect(gateway.resumes, hasLength(2));
    expect(gateway.idempotentSubmissions, [
      ('runtime-stale', 'mensaje moderno', 'client-turn-1'),
      ('runtime-resumed', 'mensaje moderno', 'client-turn-1'),
    ]);
    expect(
      fixture.delivery.current.state,
      PreparedTurnState.failedBeforeAcceptance,
    );
  });

  test('4001 de otro método y otros códigos no recuperan runtime', () async {
    const cases = [
      (
        label: 'otro método',
        error: TuiGatewayRpcError(
          'session.resume',
          'session not found',
          code: 4001,
        ),
      ),
      (
        label: 'otro código',
        error: TuiGatewayRpcError(
          'prompt.submit',
          'session not found',
          code: 4007,
        ),
      ),
    ];
    for (final testCase in cases) {
      final gateway = _OwnershipGateway(
        resumeRuntimeIds: ['runtime-stale', 'runtime-resumed'],
        idempotentSubmissionErrors: [testCase.error],
      );
      final fixture = _fixture(gateway, capability: () async => true);
      addTearDown(fixture.chat.dispose);

      await fixture.chat.loadMessages();
      final accepted = await fixture.chat.send(
        fullText: 'mensaje moderno',
        model: 'hermes-agent',
        history: const [],
        delivery: fixture.delivery,
      );

      expect(accepted, isFalse, reason: testCase.label);
      expect(gateway.resumes, hasLength(1), reason: testCase.label);
      expect(
        gateway.idempotentSubmissions,
        hasLength(1),
        reason: testCase.label,
      );
    }
  });

  test(
    'persiste 4001 antes de esperar la reanudación y luego reintenta',
    () async {
      const rejection = TuiGatewayRpcError(
        'prompt.submit',
        'session not found',
        code: 4001,
      );
      final recoveryStarted = Completer<void>();
      final allowRecovery = Completer<void>();
      final gateway = _OwnershipGateway(
        resumeRuntimeIds: const ['runtime-stale', 'runtime-owner'],
        idempotentSubmissionErrors: const [rejection, null],
        onResumeExisting: (call) async {
          if (call == 2) {
            recoveryStarted.complete();
            await allowRecovery.future;
          }
        },
      );
      final fixture = _fixture(
        gateway,
        capability: () async => true,
        profile: 'owner-profile',
      );
      addTearDown(() async {
        if (!allowRecovery.isCompleted) allowRecovery.complete();
        fixture.chat.dispose();
      });

      await fixture.chat.loadMessages(profile: 'owner-profile');
      expect(fixture.chat.desktopRuntimeSessionId, 'runtime-stale');

      final sendFuture = fixture.chat.send(
        fullText: 'mensaje moderno',
        model: 'hermes-agent',
        history: const [],
        profile: 'owner-profile',
        delivery: fixture.delivery,
      );
      await recoveryStarted.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError(
          'recovery did not start: resumes=${gateway.resumes.length}, '
          'submits=${gateway.idempotentSubmissions.length}',
        ),
      );

      final stateWhileRecoveryWasBlocked = fixture.delivery.current.state;

      allowRecovery.complete();
      final accepted = await sendFuture.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError(
          'send did not finish: resumes=${gateway.resumes.length}, '
          'submits=${gateway.idempotentSubmissions.length}',
        ),
      );

      expect(
        stateWhileRecoveryWasBlocked,
        PreparedTurnState.failedBeforeAcceptance,
      );
      expect(accepted, isTrue);
      expect(gateway.idempotentSubmissions, hasLength(2));
      expect(fixture.delivery.current.state, PreparedTurnState.running);
    },
  );

  test('el retry 4001 no cruza un rebind durante la persistencia', () async {
    const rejection = TuiGatewayRpcError(
      'prompt.submit',
      'session not found',
      code: 4001,
    );
    final retryPersistenceStarted = Completer<void>();
    final allowRetryPersistence = Completer<void>();
    var submittingSaves = 0;
    final outbox = _MemoryOutbox(
      beforeSave: (turn, _) async {
        if (turn.state != PreparedTurnState.submitting) return;
        submittingSaves += 1;
        if (submittingSaves == 2) {
          retryPersistenceStarted.complete();
          await allowRetryPersistence.future;
        }
      },
    );
    final gateway = _OwnershipGateway(
      resumeRuntimeIds: const [
        'runtime-stale',
        'runtime-owner',
        'runtime-rebound-again',
      ],
      idempotentSubmissionErrors: const [rejection, null],
    );
    final fixture = _fixture(
      gateway,
      capability: () async => true,
      profile: 'owner-profile',
      outbox: outbox,
    );
    addTearDown(() async {
      if (!allowRetryPersistence.isCompleted) {
        allowRetryPersistence.complete();
      }
      fixture.chat.dispose();
    });

    await fixture.chat.loadMessages(profile: 'owner-profile');
    final sendFuture = fixture.chat.send(
      fullText: 'mensaje moderno',
      model: 'hermes-agent',
      history: const [],
      profile: 'owner-profile',
      delivery: fixture.delivery,
    );
    await retryPersistenceStarted.future.timeout(const Duration(seconds: 5));
    await fixture.chat.loadMessages(profile: 'owner-profile');
    expect(fixture.chat.desktopRuntimeSessionId, 'runtime-rebound-again');

    allowRetryPersistence.complete();
    final accepted = await sendFuture.timeout(const Duration(seconds: 5));

    expect(accepted, isFalse);
    expect(gateway.idempotentSubmissions, [
      ('runtime-stale', 'mensaje moderno', 'client-turn-1'),
    ]);
    expect(fixture.chat.desktopRuntimeSessionId, 'runtime-rebound-again');
    expect(
      fixture.delivery.current.state,
      PreparedTurnState.failedBeforeAcceptance,
    );
  });

  test(
    'un fallo no retira el runtime adoptado mientras persiste el rechazo',
    () async {
      const rejection = TuiGatewayRpcError(
        'prompt.submit',
        'capacity detail',
        code: 4090,
        data: {'reason': 'MAX_CONCURRENT_SESSIONS'},
      );
      final rejectionPersistenceStarted = Completer<void>();
      final allowRejectionPersistence = Completer<void>();
      final outbox = _MemoryOutbox(
        beforeSave: (turn, _) async {
          if (turn.state != PreparedTurnState.failedBeforeAcceptance ||
              rejectionPersistenceStarted.isCompleted) {
            return;
          }
          rejectionPersistenceStarted.complete();
          await allowRejectionPersistence.future;
        },
      );
      final gateway = _OwnershipGateway(
        resumeRuntimeIds: const ['runtime-stale', 'runtime-rebound'],
        idempotentSubmissionErrors: const [rejection],
      );
      final fixture = _fixture(
        gateway,
        capability: () async => true,
        profile: 'owner-profile',
        outbox: outbox,
      );
      addTearDown(() async {
        if (!allowRejectionPersistence.isCompleted) {
          allowRejectionPersistence.complete();
        }
        fixture.chat.dispose();
      });

      await fixture.chat.loadMessages(profile: 'owner-profile');
      final sendFuture = fixture.chat.send(
        fullText: 'mensaje moderno',
        model: 'hermes-agent',
        history: const [],
        profile: 'owner-profile',
        delivery: fixture.delivery,
      );
      await rejectionPersistenceStarted.future.timeout(
        const Duration(seconds: 5),
      );
      await fixture.chat.loadMessages(profile: 'owner-profile');
      expect(fixture.chat.desktopRuntimeSessionId, 'runtime-rebound');

      allowRejectionPersistence.complete();
      final accepted = await sendFuture.timeout(const Duration(seconds: 5));

      expect(accepted, isFalse);
      expect(fixture.chat.desktopRuntimeSessionId, 'runtime-rebound');
      expect(gateway.idempotentSubmissions, [
        ('runtime-stale', 'mensaje moderno', 'client-turn-1'),
      ]);
    },
  );

  test(
    'un fallo tardío no retira un rebind que reutiliza el mismo runtime',
    () async {
      const rejection = TuiGatewayRpcError(
        'prompt.submit',
        'private capacity detail',
        code: 4090,
        data: {'reason': 'MAX_CONCURRENT_SESSIONS'},
      );
      final submitStarted = Completer<void>();
      final allowSubmitFailure = Completer<void>();
      final gateway = _OwnershipGateway(
        resumeRuntimeIds: ['runtime-same', 'runtime-same'],
        idempotentSubmissionErrors: const [rejection],
        onIdempotentSubmit: (call) async {
          if (call != 1) return;
          submitStarted.complete();
          await allowSubmitFailure.future;
        },
      );
      final fixture = _fixture(
        gateway,
        capability: () async => true,
        profile: 'owner-profile',
      );
      addTearDown(() {
        if (!allowSubmitFailure.isCompleted) allowSubmitFailure.complete();
        fixture.chat.dispose();
      });

      await fixture.chat.loadMessages(profile: 'owner-profile');
      final send = fixture.chat.send(
        fullText: 'hola',
        model: 'model',
        history: const [],
        profile: 'owner-profile',
        delivery: fixture.delivery,
      );
      await submitStarted.future.timeout(const Duration(seconds: 5));

      gateway.emitError(StateError('simulated disconnect'));
      await Future<void>.delayed(Duration.zero);
      expect(fixture.chat.desktopRuntimeSessionId, isNull);
      await fixture.chat.loadMessages(profile: 'owner-profile');
      expect(fixture.chat.desktopRuntimeSessionId, 'runtime-same');

      allowSubmitFailure.complete();
      expect(await send.timeout(const Duration(seconds: 5)), isFalse);
      expect(fixture.chat.desktopRuntimeSessionId, 'runtime-same');
      expect(gateway.idempotentSubmissions, hasLength(1));
    },
  );

  test(
    'rechazo recuperable no cruza un rebind que reutiliza el runtime',
    () async {
      const rejection = TuiGatewayRpcError(
        'prompt.submit',
        'private ownership detail',
        code: 4090,
        data: {'reason': 'SESSION_NOT_OWNED'},
      );
      final rejectionPersistenceStarted = Completer<void>();
      final allowRejectionPersistence = Completer<void>();
      final outbox = _MemoryOutbox(
        beforeSave: (turn, _) async {
          if (turn.state != PreparedTurnState.failedBeforeAcceptance ||
              rejectionPersistenceStarted.isCompleted) {
            return;
          }
          rejectionPersistenceStarted.complete();
          await allowRejectionPersistence.future;
        },
      );
      final gateway = _OwnershipGateway(
        resumeRuntimeIds: const [
          'runtime-same',
          'runtime-same',
          'runtime-same',
        ],
        idempotentSubmissionErrors: const [rejection, null],
      );
      final fixture = _fixture(
        gateway,
        capability: () async => true,
        profile: 'owner-profile',
        outbox: outbox,
      );
      addTearDown(() {
        if (!allowRejectionPersistence.isCompleted) {
          allowRejectionPersistence.complete();
        }
        fixture.chat.dispose();
      });

      await fixture.chat.loadMessages(profile: 'owner-profile');
      final send = fixture.chat.send(
        fullText: 'hola',
        model: 'model',
        history: const [],
        profile: 'owner-profile',
        delivery: fixture.delivery,
      );
      await rejectionPersistenceStarted.future.timeout(
        const Duration(seconds: 5),
      );

      gateway.emitError(StateError('simulated disconnect'));
      await Future<void>.delayed(Duration.zero);
      await fixture.chat.loadMessages(profile: 'owner-profile');
      expect(fixture.chat.desktopRuntimeSessionId, 'runtime-same');
      final resumesBeforeAllowingRejectedTurn = gateway.resumes.length;

      allowRejectionPersistence.complete();
      expect(await send.timeout(const Duration(seconds: 5)), isFalse);
      expect(gateway.idempotentSubmissions, [
        ('runtime-same', 'hola', 'client-turn-1'),
      ]);
      expect(gateway.resumes, hasLength(resumesBeforeAllowingRejectedTurn));
    },
  );

  test(
    '4001 tras image.attach_bytes invalida la asociación remota sin reenviar',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hermes-turn-ownership-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final image = File('${directory.path}/evidence.png');
      await image.writeAsBytes(const [1, 2, 3]);
      const rejection = TuiGatewayRpcError(
        'prompt.submit',
        'session not found',
        code: 4001,
      );
      final gateway = _OwnershipGateway(
        resumeRuntimeIds: ['runtime-stale', 'runtime-resumed'],
        idempotentSubmissionErrors: [rejection, null],
      );
      final fixture = _fixture(
        gateway,
        capability: () async => true,
        attachments: [
          AttachmentDraft(
            localId: 'image-evidence',
            type: AttachmentType.image,
            name: 'evidence.png',
            mimeType: 'image/png',
            sizeBytes: 3,
            localPath: image.path,
          ),
        ],
      );
      addTearDown(fixture.chat.dispose);

      await fixture.chat.loadMessages();
      final accepted = await fixture.chat.send(
        fullText: 'mensaje moderno',
        model: 'hermes-agent',
        history: const [],
        delivery: fixture.delivery,
      );

      expect(accepted, isFalse);
      expect(gateway.imageAttachments, [('runtime-stale', 'evidence.png')]);
      expect(gateway.resumes, [('session-modern', 'default')]);
      expect(gateway.idempotentSubmissions, [
        ('runtime-stale', 'mensaje moderno', 'client-turn-1'),
      ]);
      expect(
        fixture.delivery.current.state,
        PreparedTurnState.failedBeforeAcceptance,
      );
      expect(
        fixture.delivery.current.attachments.single.uploadState,
        AttachmentUploadState.pending,
      );
      expect(
        fixture.delivery.current.attachments.single.remoteSessionId,
        isNull,
      );
      expect(fixture.delivery.current.attachments.single.remoteRef, isNull);
      final attachedWriteIndex = fixture.store.writes.indexWhere(
        (turn) =>
            turn.attachments.single.uploadState ==
            AttachmentUploadState.attached,
      );
      expect(attachedWriteIndex, isNonNegative);
      expect(
        fixture.store.writes
            .skip(attachedWriteIndex + 1)
            .where(
              (turn) =>
                  turn.state == PreparedTurnState.submitting &&
                  turn.attachments.single.uploadState ==
                      AttachmentUploadState.pending,
            ),
        isEmpty,
        reason: 'el rechazo y la invalidación deben persistirse atómicamente',
      );
    },
  );

  test('SESSION_NOT_OWNED falla cerrado también en submit normal', () async {
    const rejection = TuiGatewayRpcError(
      'prompt.submit',
      'private ownership detail',
      code: 4090,
      data: {'reason': 'SESSION_NOT_OWNED'},
    );
    final gateway = _OwnershipGateway(
      resumeRuntimeIds: ['runtime-old', 'runtime-owner'],
      normalSubmissionErrors: [rejection, null],
    );
    final fixture = _fixture(gateway, capability: () async => false);
    addTearDown(fixture.chat.dispose);

    await fixture.chat.loadMessages();
    final accepted = await fixture.chat.send(
      fullText: 'mensaje moderno',
      model: 'hermes-agent',
      history: const [],
      delivery: fixture.delivery,
    );

    expect(accepted, isFalse);
    expect(gateway.resumes, [('session-modern', 'default')]);
    expect(gateway.submissions, [('runtime-old', 'mensaje moderno')]);
    expect(gateway.idempotentSubmissions, isEmpty);
    expect(fixture.chat.desktopRuntimeSessionId, isNull);
    expect(
      fixture.delivery.current.state,
      PreparedTurnState.failedBeforeAcceptance,
    );
  });

  test('SESSION_NOT_OWNED no reintenta contra el mismo runtime', () async {
    const rejection = TuiGatewayRpcError(
      'prompt.submit',
      'private ownership detail',
      code: 4090,
      data: {'reason': 'SESSION_NOT_OWNED'},
    );
    final gateway = _OwnershipGateway(
      resumeRuntimeIds: ['runtime-old', 'runtime-old'],
      idempotentSubmissionErrors: [rejection],
    );
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);

    await fixture.chat.loadMessages();
    final accepted = await fixture.chat.send(
      fullText: 'mensaje moderno',
      model: 'hermes-agent',
      history: const [],
      delivery: fixture.delivery,
    );

    expect(accepted, isFalse);
    expect(gateway.resumes, hasLength(1));
    expect(gateway.idempotentSubmissions, [
      ('runtime-old', 'mensaje moderno', 'client-turn-1'),
    ]);
    expect(fixture.chat.state, ChatPipelineState.failed);
    expect(
      fixture.delivery.current.state,
      PreparedTurnState.failedBeforeAcceptance,
    );
  });

  test('SESSION_NOT_OWNED no consume un segundo rechazo en retry', () async {
    const rejection = TuiGatewayRpcError(
      'prompt.submit',
      'private ownership detail',
      code: 4090,
      data: {'reason': 'SESSION_NOT_OWNED'},
    );
    final gateway = _OwnershipGateway(
      resumeRuntimeIds: ['runtime-old', 'runtime-owner'],
      idempotentSubmissionErrors: [rejection, rejection],
    );
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);

    await fixture.chat.loadMessages();
    final accepted = await fixture.chat.send(
      fullText: 'mensaje moderno',
      model: 'hermes-agent',
      history: const [],
      delivery: fixture.delivery,
    );

    expect(accepted, isFalse);
    expect(gateway.resumes, hasLength(1));
    expect(gateway.idempotentSubmissions, [
      ('runtime-old', 'mensaje moderno', 'client-turn-1'),
    ]);
    expect(fixture.chat.state, ChatPipelineState.failed);
    expect(
      fixture.delivery.current.state,
      PreparedTurnState.failedBeforeAcceptance,
    );
    expect(
      fixture.chat.messages.where((message) => message['role'] == 'user'),
      hasLength(1),
    );
    expect(
      fixture.chat.messages.singleWhere(
        (message) => message['role'] == 'assistant_error',
      )['content'],
      'No se puede continuar en directo porque esta conversación pertenece '
      'a otro gateway o proceso. El historial se conserva y puedes iniciar '
      'un chat nuevo.',
    );
  });

  test('otros reasons 4090 no recuperan ownership', () async {
    for (final reason in const [
      'MAX_CONCURRENT_SESSIONS',
      'SESSION_COORDINATION_UNAVAILABLE',
      'UNKNOWN_COORDINATION_REASON',
    ]) {
      final gateway = _OwnershipGateway(
        resumeRuntimeIds: ['runtime-old', 'runtime-owner'],
        idempotentSubmissionErrors: [
          TuiGatewayRpcError(
            'prompt.submit',
            'private coordination detail',
            code: 4090,
            data: {'reason': reason},
          ),
        ],
      );
      final fixture = _fixture(gateway, capability: () async => true);
      addTearDown(fixture.chat.dispose);

      await fixture.chat.loadMessages();
      final accepted = await fixture.chat.send(
        fullText: 'mensaje moderno',
        model: 'hermes-agent',
        history: const [],
        delivery: fixture.delivery,
      );

      expect(accepted, isFalse, reason: reason);
      expect(gateway.resumes, hasLength(1), reason: reason);
      expect(gateway.idempotentSubmissions, hasLength(1), reason: reason);
      expect(
        fixture.delivery.current.state,
        reason == 'UNKNOWN_COORDINATION_REASON'
            ? PreparedTurnState.ambiguous
            : PreparedTurnState.failedBeforeAcceptance,
        reason: reason,
      );
    }
  });

  test('un error ambiguo de prompt.submit no recupera ownership', () async {
    const ambiguous = TuiGatewayRpcError(
      'prompt.submit',
      'Timeout waiting for JSON-RPC response',
      data: {'reason': 'SESSION_NOT_OWNED'},
    );
    final gateway = _OwnershipGateway(
      resumeRuntimeIds: ['runtime-old', 'runtime-owner'],
      idempotentSubmissionErrors: [ambiguous],
    );
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);

    await fixture.chat.loadMessages();
    final accepted = await fixture.chat.send(
      fullText: 'mensaje moderno',
      model: 'hermes-agent',
      history: const [],
      delivery: fixture.delivery,
    );

    expect(accepted, isFalse);
    expect(gateway.resumes, hasLength(1));
    expect(gateway.idempotentSubmissions, hasLength(1));
    expect(fixture.delivery.current.state, PreparedTurnState.ambiguous);
  });

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
