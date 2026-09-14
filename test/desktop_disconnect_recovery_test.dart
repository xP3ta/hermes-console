import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_compression_outcome.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/desktop_compression_fence_store.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';

import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/recovery_proof.dart';
import 'package:hermes_android/core/services/replay_coordinator.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/utils/chat_turn.dart';

import 'support/in_memory_compression_fence_storage.dart';

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

  void failWith(Object error) {
    _connected = false;
    _events.addError(error);
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

class _QueueAuthorizedDroppingGateway extends _DroppingDesktopGateway
    implements HermesDesktopSessionActivityGateway {
  int listActiveCalls = 0;

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => DesktopGatewayCapabilityState.supported;

  @override
  Future<DesktopSessionSnapshot> activateSession(
    String runtimeSessionId, {
    required String storedSessionId,
  }) async => throw StateError('legacy queue recovery must resume its runtime');

  @override
  Future<DesktopActiveSessionList> listActiveSessions({
    String currentRuntimeSessionId = '',
  }) async {
    listActiveCalls += 1;
    return const DesktopActiveSessionList();
  }
}

class _RecoverableDesktopGateway extends _DroppingDesktopGateway
    implements
        HermesDesktopIdempotentGateway,
        HermesDesktopTypedRecoveryGateway {
  final ReplayCoordinator _recovery = ReplayCoordinator();
  final Object _recoveryChannel = Object();
  bool invalidateRecoveryAfterValidation = false;
  Completer<void>? recoveryConnectGate;
  Completer<void>? recoveryResumeGate;
  Completer<void>? recoveryStatusGate;
  final recoveryResumeStarted = Completer<void>();
  DesktopTurnState recoveredState = DesktopTurnState.running;
  int recoveryConnectFailuresRemaining = 0;
  Object? recoveryConnectError;
  int statusCalls = 0;

  void invalidateRecoveryAuthority() => _recovery.rotateEpoch();

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
      coverage: RecoveryDomain.values.toSet(),
      postSnapshotSequence: 1,
    );
  }

  @override
  bool validateRecovery(RecoveryProof proof) {
    final valid = _recovery.canCommitRecovery(
      proof,
      socketGeneration: 1,
      channel: _recoveryChannel,
      replayEpoch: null,
    );
    if (valid && invalidateRecoveryAfterValidation) _recovery.rotateEpoch();
    return valid;
  }

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

/// Solo el resume DE RECUPERACIÓN falla (una vez) con el preflight local;
/// las llamadas del flujo normal del turno usan el comportamiento base.
class _PreflightDenialRecoveryGateway extends _LifecycleRecoverableGateway {
  int recoveryResumeCalls = 0;

  @override
  Future<DesktopSessionSnapshot> resumeExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) {
    recoveryResumeCalls++;
    if (recoveryResumeCalls == 1) {
      return Future.error(
        const TuiGatewayRpcError(
          'session.resume',
          'Hermes Agent cannot safely accept this message',
          origin: CompressionFailureOrigin.localPreflight,
        ),
      );
    }
    return super.resumeExistingForRecovery(storedSessionId, profile: profile);
  }
}

class _PermanentCapabilityDenialRecoveryGateway
    extends _LifecycleRecoverableGateway {
  int recoveryResumeCalls = 0;

  @override
  Future<DesktopSessionSnapshot> resumeExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) {
    recoveryResumeCalls++;
    return Future.error(
      const TuiGatewayRpcError(
        'session.resume',
        'Hermes Agent cannot safely accept this message',
        data: {'reason': 'EXCLUSIVE_SUBMIT_CAPABILITY_DENIED'},
        origin: CompressionFailureOrigin.localPreflight,
      ),
    );
  }
}

class _TypedTransientRecoveryGateway extends _LifecycleRecoverableGateway {
  int recoveryResumeCalls = 0;

  @override
  Future<DesktopSessionSnapshot> resumeExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) {
    recoveryResumeCalls++;
    if (recoveryResumeCalls == 1) {
      return Future.error(
        const TuiGatewayRpcError(
          'gateway.capabilities',
          'Hermes Desktop request timed out',
          origin: CompressionFailureOrigin.remoteRpc,
          failureKind: TuiGatewayRpcFailureKind.timeout,
        ),
      );
    }
    return super.resumeExistingForRecovery(storedSessionId, profile: profile);
  }
}

class _LifecycleRecoverableGateway extends _RecoverableDesktopGateway
    implements
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopRecoverySessionLifecycleGateway,
        HermesDesktopRosterBoundRecoveryGateway,
        HermesDesktopTypedRecoveryGateway {
  int resumeExistingCalls = 0;
  int createForFirstSubmitCalls = 0;
  final List<String> resumeExistingStoredIds = [];
  final List<String> committedRecoveryRuntimeIds = [];
  bool recoveryCommitSucceeds = true;
  Object? createForFirstSubmitError;
  Completer<DesktopSessionSnapshot>? recoveryExistingGate;
  Object? resumeExistingError;
  int? resumeExistingFailuresRemaining;
  final List<Future<DesktopSessionSnapshot>> scriptedResumeExisting = [];
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
    if (scriptedResumeExisting.isNotEmpty) {
      return scriptedResumeExisting.removeAt(0);
    }
    if (resumeExistingError case final error?) {
      final remaining = resumeExistingFailuresRemaining;
      if (remaining != null) {
        resumeExistingFailuresRemaining = remaining - 1;
        if (remaining <= 1) resumeExistingError = null;
      }
      throw error;
    }
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
    if (scriptedResumeExisting.isNotEmpty) {
      return scriptedResumeExisting.removeAt(0);
    }
    if (resumeExistingError case final error?) {
      final remaining = resumeExistingFailuresRemaining;
      if (remaining != null) {
        resumeExistingFailuresRemaining = remaining - 1;
        if (remaining <= 1) resumeExistingError = null;
      }
      return Future.error(error);
    }
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
  Future<DesktopRosterBoundRecovery> resumeAdvertisedExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) async {
    await connect();
    DesktopActiveSession? advertised;
    if (this is HermesDesktopSessionActivityGateway) {
      final activity = this as HermesDesktopSessionActivityGateway;
      final roster = await activity.listActiveSessions();
      final matches = roster.sessions
          .where((row) => row.storedSessionId == storedSessionId)
          .toList(growable: false);
      if (roster.hasMalformedRows || matches.length != 1) {
        throw const TuiGatewayRpcError(
          'session.active_list',
          'test roster did not prove one owner',
        );
      }
      advertised = matches.single;
    }
    final snapshot = await resumeExistingForRecovery(
      storedSessionId,
      profile: profile,
    );
    if (advertised != null &&
        advertised.runtimeSessionId != snapshot.runtimeSessionId) {
      throw const TuiGatewayRpcError(
        'session.resume',
        'test resume escaped the roster proof',
      );
    }
    return DesktopRosterBoundRecovery.forTesting(snapshot, this);
  }

  @override
  bool consumeRosterBoundRecovery(DesktopRosterBoundRecovery recovery) {
    if (!recoveryCommitSucceeds) return false;
    committedRecoveryRuntimeIds.add(recovery.snapshot.runtimeSessionId);
    return true;
  }

  @override
  bool consumeRosterBoundViewerAttachment(
    DesktopRosterBoundRecovery recovery,
  ) => consumeRosterBoundRecovery(recovery);

  @override
  void commitRecoveryRuntime(String runtimeSessionId) {}

  @override
  bool validateRecovery(RecoveryProof proof) {
    final valid = super.validateRecovery(proof);
    if (valid && !recoveryCommitSucceeds) {
      _recovery.rotateEpoch();
    }
    return valid;
  }

  @override
  bool commitRecovery(RecoveryProof proof) {
    final committed = super.commitRecovery(proof);
    if (committed) committedRecoveryRuntimeIds.add(proof.runtimeSessionId);
    return committed;
  }

  @override
  Future<void> steer(String runtimeSessionId, String text) async {
    steers.add((runtimeId: runtimeSessionId, text: text));
  }
}

class _ActivityLifecycleRecoverableGateway extends _LifecycleRecoverableGateway
    implements HermesDesktopSessionActivityGateway {
  int activateCalls = 0;
  int listActiveSessionsCalls = 0;
  String? initialAdvertisedStoredSessionId;
  String? initialAdvertisedRuntimeSessionId;
  String? recoveryAdvertisedStoredSessionId;
  String? recoveryAdvertisedRuntimeSessionId;

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => DesktopGatewayCapabilityState.supported;

  @override
  Future<DesktopSessionSnapshot> activateSession(
    String runtimeSessionId, {
    required String storedSessionId,
  }) async {
    activateCalls += 1;
    final snapshot = initialSnapshot;
    if (snapshot == null ||
        snapshot.runtimeSessionId != runtimeSessionId ||
        snapshot.storedSessionId != storedSessionId) {
      throw StateError(
        'activation must match the initially advertised runtime',
      );
    }
    return snapshot;
  }

  @override
  Future<DesktopRosterBoundRecovery> resumeAdvertisedExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) async {
    await connect();
    listActiveSessionsCalls += 1;
    final advertisedStoredId = recoveryAdvertisedStoredSessionId;
    final advertisedRuntimeId = recoveryAdvertisedRuntimeSessionId;
    if (advertisedStoredId != storedSessionId || advertisedRuntimeId == null) {
      throw const TuiGatewayRpcError(
        'session.active_list',
        'test recovery roster did not prove one owner',
      );
    }
    final snapshot = await resumeExistingForRecovery(
      storedSessionId,
      profile: profile,
    );
    if (snapshot.runtimeSessionId != advertisedRuntimeId) {
      throw const TuiGatewayRpcError(
        'session.resume',
        'test resume escaped the recovery roster proof',
      );
    }
    return DesktopRosterBoundRecovery.forTesting(snapshot, this);
  }

  @override
  Future<DesktopActiveSessionList> listActiveSessions({
    String currentRuntimeSessionId = '',
  }) async {
    listActiveSessionsCalls += 1;
    final storedId = initialAdvertisedStoredSessionId;
    if (storedId == null) return const DesktopActiveSessionList();
    final runtimeId = initialAdvertisedRuntimeSessionId;
    if (runtimeId == null) return const DesktopActiveSessionList();
    return DesktopActiveSessionList(
      sessions: [
        DesktopActiveSession(
          runtimeSessionId: runtimeId,
          storedSessionId: storedId,
        ),
      ],
    );
  }
}

class _StaticTicketDashboardClient extends DashboardClient {
  _StaticTicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-qa',
      );
}

class _CountingRealLifecycleGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopRecoverySessionLifecycleGateway,
        HermesDesktopRosterBoundRecoveryGateway,
        HermesDesktopTypedRecoveryGateway {
  _CountingRealLifecycleGateway(this.delegate);

  final TuiGatewayClient delegate;
  int connectCalls = 0;
  int resumeExistingCalls = 0;
  int createCalls = 0;
  int legacyResumeCalls = 0;
  int submitCalls = 0;
  int interruptCalls = 0;
  int steerCalls = 0;
  int approvalCalls = 0;
  final List<String> committedRuntimeIds = [];

  @override
  Stream<TuiGatewayEvent> get events => delegate.events;

  @override
  bool get isConnected => delegate.isConnected;

  @override
  Future<void> connect() {
    connectCalls += 1;
    return delegate.connect();
  }

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) {
    legacyResumeCalls += 1;
    return delegate.resumeSession(
      storedSessionId,
      profile: profile,
      seedMessages: seedMessages,
      model: model,
    );
  }

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) {
    resumeExistingCalls += 1;
    return delegate.resumeExisting(
      storedSessionId,
      profile: profile,
      omitMessages: omitMessages,
      deferHistory: deferHistory,
    );
  }

  @override
  Future<DesktopSessionSnapshot> resumeExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) {
    resumeExistingCalls += 1;
    return delegate.resumeExistingForRecovery(
      storedSessionId,
      profile: profile,
    );
  }

  @override
  Future<DesktopRosterBoundRecovery> resumeAdvertisedExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) async {
    await connect();
    resumeExistingCalls += 1;
    return delegate.resumeAdvertisedExistingForRecovery(
      storedSessionId,
      profile: profile,
    );
  }

  @override
  bool consumeRosterBoundRecovery(DesktopRosterBoundRecovery recovery) =>
      delegate.consumeRosterBoundRecovery(recovery);

  @override
  bool consumeRosterBoundViewerAttachment(
    DesktopRosterBoundRecovery recovery,
  ) => delegate.consumeRosterBoundViewerAttachment(recovery);

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) {
    createCalls += 1;
    return delegate.createForFirstSubmit(
      profile: profile,
      seedMessages: seedMessages,
      model: model,
    );
  }

  @override
  void commitRecoveryRuntime(String runtimeSessionId) {
    delegate.commitRecoveryRuntime(runtimeSessionId);
  }

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
  }) => delegate.recoveryProofForSnapshot(
    snapshot,
    connectionId: connectionId,
    profile: profile,
    bindGeneration: bindGeneration,
    sessionGeneration: sessionGeneration,
    turnGeneration: turnGeneration,
    coverage: coverage,
    postSnapshotSequence: postSnapshotSequence,
  );

  @override
  bool validateRecovery(RecoveryProof proof) =>
      delegate.validateRecovery(proof);

  @override
  bool commitRecovery(RecoveryProof proof) {
    final committed = delegate.commitRecovery(proof);
    if (committed) committedRuntimeIds.add(proof.runtimeSessionId);
    return committed;
  }

  @override
  bool recoveryAuthorityStillCurrent(RecoveryProof proof) =>
      delegate.recoveryAuthorityStillCurrent(proof);

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) {
    submitCalls += 1;
    return delegate.submitPrompt(runtimeSessionId, text);
  }

  @override
  Future<void> interrupt(String runtimeSessionId) {
    interruptCalls += 1;
    return delegate.interrupt(runtimeSessionId);
  }

  @override
  Future<void> steer(String runtimeSessionId, String text) {
    steerCalls += 1;
    return delegate.steer(runtimeSessionId, text);
  }

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) {
    approvalCalls += 1;
    return delegate.resolveApproval(
      runtimeSessionId,
      choice,
      resolveAll: resolveAll,
      requestId: requestId,
    );
  }

  @override
  Future<void> close() => delegate.close();
}

class _TicketTransportOnceGateway extends _ActivityLifecycleRecoverableGateway {
  _TicketTransportOnceGateway(this.dashboard);

  final DashboardClient dashboard;
  int ticketConnectAttempts = 0;

  @override
  Future<void> connect() async {
    ticketConnectAttempts += 1;
    if (ticketConnectAttempts == 1) {
      await dashboard.mintWsTicket();
    }
    await super.connect();
  }
}

class _RestFallbackApiClient extends ApiClient {
  _RestFallbackApiClient()
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('not found', 404)),
      );

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
  Future<Map<String, dynamic>> stopRun(String runId, {String? profile}) async {
    stopCalls++;
    return <String, dynamic>{};
  }

  @override
  Future<void> streamRunEvents(
    String runId, {
    String? profile,
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
  Future<List<Map<String, dynamic>>> getMessages(
    String sessionId, {
    String? profile,
  }) {
    final request = Completer<List<Map<String, dynamic>>>();
    requests.add(request);
    return request.future;
  }

  @override
  Future<SessionMessagesPage> getMessagesPage(
    String sessionId, {
    String? profile,
    int limit = 120,
    int offset = 0,
  }) async => SessionMessagesPage(
    messages: await getMessages(sessionId, profile: profile),
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
  Future<List<Map<String, dynamic>>> getMessages(
    String sessionId, {
    String? profile,
  }) async {
    calls++;
    return transcript;
  }

  @override
  void close() {}
}

class _SingleAuthorizedTranscriptApi extends ApiClient {
  _SingleAuthorizedTranscriptApi(this.transcript)
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: String.fromCharCodes(const [113, 97]),
      );

  final List<Map<String, dynamic>> transcript;
  final firstRead = Completer<void>();
  final redundantRead = Completer<void>();
  int calls = 0;

  @override
  Future<List<Map<String, dynamic>>> getMessages(
    String sessionId, {
    String? profile,
  }) async {
    calls += 1;
    if (calls == 1) {
      firstRead.complete();
      return transcript;
    }
    if (!redundantRead.isCompleted) redundantRead.complete();
    throw http.ClientException('redundant transcript read must not occur');
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
  Future<List<Map<String, dynamic>>> getMessages(
    String sessionId, {
    String? profile,
  }) async {
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
    String? profile,
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

class _CountingDelivery extends ActiveTurnDelivery {
  _CountingDelivery({required super.prepared, required super.store});

  int markRunningCalls = 0;

  @override
  Future<void> markRunning() {
    markRunningCalls += 1;
    return super.markRunning();
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
    // Keep this classification test independent of random retry timing.
    desktopRecoveryRandom: () => 1.0,
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
        'No se pudo recuperar el turno. Inténtalo de nuevo.',
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
  double Function()? desktopRecoveryRandom,
  List<CancelledTurnTombstone> initialCancelledTurnTombstones = const [],
  Future<void> Function(CancelledTurnTombstone)? onCancelledTurn,
  void Function(ActiveChatEvent)? onEvent,
  StoredSessionMessageLoader? storedMessageLoader,
  bool turnIdempotencySupported = true,
}) => ActiveChat(
  compressionFenceStore: testCompressionFenceStore(),
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
  allowUnownedDesktopSnapshotForTesting: true,
  turnIdempotencyCapability: () async => turnIdempotencySupported,
  terminalReconcileBudget: terminalReconcileBudget,
  desktopRecoveryAttemptTimeout: desktopRecoveryAttemptTimeout,
  desktopRecoveryBackoff: desktopRecoveryBackoff,
  desktopRecoveryRandom: desktopRecoveryRandom,
  initialCancelledTurnTombstones: initialCancelledTurnTombstones,
  onCancelledTurn: onCancelledTurn,
  onEvent: onEvent,
  storedMessageLoader: storedMessageLoader,
);

ActiveChat _productionAttachChat(
  String id,
  HermesDesktopGateway gateway, {
  ApiClient? api,
  StoredSessionMessageLoader? storedMessageLoader,
  List<Duration> desktopRecoveryBackoff = const [Duration.zero],
  double Function()? desktopRecoveryRandom,
  DesktopCompressionFenceStore? compressionFenceStore,
}) {
  if (gateway case final _ActivityLifecycleRecoverableGateway activity) {
    final initial = activity.initialSnapshot;
    if (initial != null) {
      activity.initialAdvertisedStoredSessionId ??= initial.storedSessionId;
      activity.initialAdvertisedRuntimeSessionId ??= initial.runtimeSessionId;
    }
    final recovery = activity.recoverySnapshot ?? initial;
    if (recovery != null) {
      activity.recoveryAdvertisedStoredSessionId ??= recovery.storedSessionId;
      activity.recoveryAdvertisedRuntimeSessionId ??= recovery.runtimeSessionId;
    }
  }
  return ActiveChat(
    compressionFenceStore: compressionFenceStore ?? testCompressionFenceStore(),
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
    attachDesktopRuntimeOnLoad: true,
    storedMessageLoader: storedMessageLoader,
    desktopRecoveryBackoff: desktopRecoveryBackoff,
    desktopRecoveryRandom: desktopRecoveryRandom,
  );
}

void _expectNoViewerAttachmentMutations(
  _ActivityLifecycleRecoverableGateway gateway,
  _RestFallbackApiClient api, {
  int expectedActivateCalls = 0,
}) {
  expect(gateway.createForFirstSubmitCalls, 0);
  expect(gateway.submitCalls, 0);
  expect(gateway.activateCalls, expectedActivateCalls);
  expect(gateway.interruptCalls, 0);
  expect(gateway.resumeCalls, 0);
  expect(api.startCalls, 0);
  expect(api.stopCalls, 0);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'idle attached socket drop automatically resumes exact durable id',
    () async {
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..initialSnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-idle-1',
          storedSessionId: 'session-idle-attach',
          created: false,
          messagesProvided: true,
          running: false,
          status: 'completed',
        )
        ..recoverySnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-idle-2',
          storedSessionId: 'session-idle-attach',
          created: false,
          messagesProvided: true,
          running: false,
          status: 'completed',
        );
      final chat = _productionAttachChat(
        'idle-attach',
        gateway,
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'idle-answer',
            'role': 'assistant',
            'content': 'durable transcript stays visible',
          },
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(profile: 'owner-profile');
      expect(chat.desktopRuntimeSessionId, 'runtime-idle-1');
      expect(
        chat.messages.single['content'],
        'durable transcript stays visible',
      );

      gateway.drop();
      await _waitUntil(() => chat.desktopRuntimeSessionId == 'runtime-idle-2');

      expect(gateway.resumeExistingStoredIds, ['session-idle-attach']);
      expect(gateway.committedRecoveryRuntimeIds, ['runtime-idle-2']);
      expect(
        chat.messages.single['content'],
        'durable transcript stays visible',
      );
      expect(gateway.submitCalls, 0);
      expect(gateway.createForFirstSubmitCalls, 0);
      expect(gateway.activateCalls, 1);
      expect(gateway.interruptCalls, 0);
      expect(gateway.resumeCalls, 0);
    },
  );

  test(
    'commit false keeps automatic reattach quarantined and unadopted',
    () async {
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..recoveryCommitSucceeds = false
        ..initialSnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-commit-false-1',
          storedSessionId: 'session-commit-false',
          created: false,
          messagesProvided: true,
          running: false,
          status: 'completed',
        )
        ..recoverySnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-commit-false-2',
          storedSessionId: 'session-commit-false',
          created: false,
          messagesProvided: true,
          running: true,
          status: 'running',
        );
      final chat = _productionAttachChat(
        'commit-false',
        gateway,
        storedMessageLoader: (_, _) async => const [
          {'message_id': 'kept', 'role': 'assistant', 'content': 'kept'},
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(profile: 'owner-profile');
      gateway.drop();
      await _waitUntil(() => gateway.resumeExistingCalls == 1);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(chat.desktopRuntimeSessionId, isNull);
      expect(chat.messages.single['content'], 'kept');
      expect(gateway.committedRecoveryRuntimeIds, isEmpty);
      expect(chat.state, isNot(ChatPipelineState.executing));
    },
  );

  test(
    'passive refresh does not cancel automatic exact-durable reattach',
    () async {
      final recoveryGate = Completer<DesktopSessionSnapshot>();
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..initialSnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-passive-race-1',
          storedSessionId: 'session-passive-race',
          created: false,
          messagesProvided: true,
          running: false,
          status: 'completed',
        )
        ..recoverySnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-passive-race-2',
          storedSessionId: 'session-passive-race',
          created: false,
          messagesProvided: true,
          running: false,
          status: 'completed',
        )
        ..recoveryExistingGate = recoveryGate;
      final chat = _productionAttachChat(
        'passive-race',
        gateway,
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'passive-race-answer',
            'role': 'assistant',
            'content': 'durable transcript survives passive refresh',
          },
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(profile: 'owner-profile');
      expect(chat.desktopRuntimeSessionId, 'runtime-passive-race-1');

      gateway.drop();
      await _waitUntil(() => gateway.resumeExistingCalls == 1);
      await chat.loadMessages(profile: 'owner-profile', passiveOnly: true);
      recoveryGate.complete(
        const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-passive-race-2',
          storedSessionId: 'session-passive-race',
          created: false,
          messagesProvided: true,
          running: false,
          status: 'completed',
        ),
      );

      await _waitUntil(
        () => chat.desktopRuntimeSessionId == 'runtime-passive-race-2',
      );
      expect(gateway.resumeExistingStoredIds, ['session-passive-race']);
      expect(gateway.committedRecoveryRuntimeIds, ['runtime-passive-race-2']);
      expect(chat.messages, [
        containsPair('content', 'durable transcript survives passive refresh'),
      ]);
      expect(gateway.submitCalls, 0);
      expect(gateway.createForFirstSubmitCalls, 0);
      expect(gateway.activateCalls, 1);
      expect(gateway.interruptCalls, 0);
      expect(gateway.resumeCalls, 0);
    },
  );

  test('disposed chat rejects held automatic reattach response', () async {
    final recoveryGate = Completer<DesktopSessionSnapshot>();
    final gateway = _ActivityLifecycleRecoverableGateway()
      ..initialSnapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-dispose-fence-1',
        storedSessionId: 'session-dispose-fence',
        created: false,
        messagesProvided: true,
        running: false,
      )
      ..recoveryExistingGate = recoveryGate;
    final chat = _productionAttachChat(
      'dispose-fence',
      gateway,
      storedMessageLoader: (_, _) async => const [
        {
          'message_id': 'dispose-fence-answer',
          'role': 'assistant',
          'content': 'durable before disposal',
        },
      ],
    );

    await chat.loadMessages(profile: 'owner-profile');
    gateway.drop();
    await _waitUntil(() => gateway.resumeExistingCalls == 1);

    chat.dispose();
    recoveryGate.complete(
      const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-disposed-must-not-bind',
        storedSessionId: 'session-dispose-fence',
        created: false,
        messagesProvided: true,
        running: false,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(chat.desktopRuntimeSessionId, isNull);
    expect(gateway.committedRecoveryRuntimeIds, isEmpty);
    expect(gateway.submitCalls, 0);
    expect(gateway.createForFirstSubmitCalls, 0);
    expect(gateway.activateCalls, 1);
    expect(gateway.interruptCalls, 0);
    expect(gateway.resumeCalls, 0);
  });

  test(
    'authoritative stored-session replacement rejects old held reattach response',
    () async {
      final recoveryGate = Completer<DesktopSessionSnapshot>();
      final oldGateway = _ActivityLifecycleRecoverableGateway()
        ..initialAdvertisedStoredSessionId = 'session-retarget-old'
        ..initialAdvertisedRuntimeSessionId = 'runtime-retarget-old-1'
        ..recoveryAdvertisedStoredSessionId = 'session-retarget-old'
        ..recoveryAdvertisedRuntimeSessionId = 'runtime-retarget-old-1'
        ..initialSnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-retarget-old-1',
          storedSessionId: 'session-retarget-old',
          created: false,
          messagesProvided: true,
          running: false,
        )
        ..recoveryExistingGate = recoveryGate;
      final service = ActiveChatService(
        compressionFenceStore: testCompressionFenceStore(),
      );
      addTearDown(service.dispose);
      final oldChat = service.attach(
        connection: _connection('retarget-fence'),
        sessionId: 'mobile-retarget-route',
        sessionTitle: 'old durable binding',
        sessionProfile: 'owner-profile',
        initialStoredSessionId: 'session-retarget-old',
        authoritativeStoredSessionBinding: true,
        api: ApiClient(
          baseUrl: 'http://127.0.0.1:1',
          apiKey: '',
          httpClient: MockClient((_) async => http.Response('not found', 404)),
        ),
        desktopGateway: oldGateway,
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'retarget-old-answer',
            'role': 'assistant',
            'content': 'old durable transcript',
          },
        ],
        attachDesktopRuntimeOnLoad: true,
        disableForegroundKeepAlive: true,
      );

      await oldChat.loadMessages(profile: 'owner-profile');
      oldGateway.drop();
      await _waitUntil(() => oldGateway.resumeExistingCalls == 1);

      final replacementGateway = _ActivityLifecycleRecoverableGateway();
      final replacement = service.attach(
        connection: _connection('retarget-fence'),
        sessionId: 'mobile-retarget-route',
        sessionTitle: 'new durable binding',
        sessionProfile: 'owner-profile',
        initialStoredSessionId: 'session-retarget-new',
        authoritativeStoredSessionBinding: true,
        api: ApiClient(
          baseUrl: 'http://127.0.0.1:1',
          apiKey: '',
          httpClient: MockClient((_) async => http.Response('not found', 404)),
        ),
        desktopGateway: replacementGateway,
        storedMessageLoader: (_, _) async => const [],
        attachDesktopRuntimeOnLoad: true,
        disableForegroundKeepAlive: true,
      );
      expect(replacement, isNot(same(oldChat)));
      expect(replacement.storedSessionId, 'session-retarget-new');

      recoveryGate.complete(
        const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-retarget-old-must-not-bind',
          storedSessionId: 'session-retarget-old',
          created: false,
          messagesProvided: true,
          running: false,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(oldChat.desktopRuntimeSessionId, isNull);
      expect(oldGateway.committedRecoveryRuntimeIds, isEmpty);
      expect(oldGateway.submitCalls, 0);
      expect(oldGateway.createForFirstSubmitCalls, 0);
      expect(oldGateway.activateCalls, 1);
      expect(oldGateway.interruptCalls, 0);
      expect(oldGateway.resumeCalls, 0);
      expect(replacementGateway.submitCalls, 0);
      expect(replacementGateway.createForFirstSubmitCalls, 0);
      expect(replacementGateway.activateCalls, 0);
      expect(replacementGateway.interruptCalls, 0);
      expect(replacementGateway.resumeCalls, 0);
    },
  );

  test(
    'transient cold-open resume failure automatically reattaches after REST success',
    () async {
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..resumeExistingError = const DashboardHttpException(503)
        ..resumeExistingFailuresRemaining = 1
        ..recoverySnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-cold-recovered',
          storedSessionId: 'session-cold-retry',
          created: false,
          messagesProvided: true,
          running: false,
          status: 'completed',
        );
      final chat = _productionAttachChat(
        'cold-retry',
        gateway,
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'cold-answer',
            'role': 'assistant',
            'content': 'REST loaded while gateway warmed',
          },
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(profile: 'owner-profile');
      expect(
        chat.messages.single['content'],
        'REST loaded while gateway warmed',
      );
      await _waitUntil(
        () => chat.desktopRuntimeSessionId == 'runtime-cold-recovered',
      );

      expect(gateway.resumeExistingStoredIds, [
        'session-cold-retry',
        'session-cold-retry',
      ]);
      expect(gateway.committedRecoveryRuntimeIds, ['runtime-cold-recovered']);
      expect(gateway.submitCalls, 0);
      expect(gateway.createForFirstSubmitCalls, 0);
      expect(gateway.activateCalls, 0);
      expect(gateway.interruptCalls, 0);
      expect(gateway.resumeCalls, 0);
    },
  );

  test(
    'transient automatic reattach rejects a runtime absent from fresh active '
    'proof',
    () async {
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..recoveryAdvertisedRuntimeSessionId =
            'runtime-advertised-before-transient'
        ..resumeExistingError = const DashboardHttpException(503)
        ..resumeExistingFailuresRemaining = 1
        ..recoverySnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-unproved-after-transient',
          storedSessionId: 'session-transient-proof',
          created: false,
          messagesProvided: true,
        );
      final chat = _productionAttachChat(
        'transient-proof',
        gateway,
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'transient-proof-history',
            'role': 'assistant',
            'content': 'durable history',
          },
        ],
        desktopRecoveryBackoff: const [Duration.zero],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(profile: 'owner-profile');
      await _waitUntil(() => gateway.resumeExistingCalls >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(gateway.listActiveSessionsCalls, greaterThanOrEqualTo(2));
      expect(chat.desktopRuntimeSessionId, isNull);
      expect(gateway.committedRecoveryRuntimeIds, isEmpty);
      expect(gateway.submitCalls, 0);
      expect(gateway.createForFirstSubmitCalls, 0);
    },
  );

  test(
    'WebSocketChannelException cold open retries exact durable viewer resume',
    () async {
      final api = _RestFallbackApiClient();
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..resumeExistingError = WebSocketChannelException.from(
          const SocketException('Connection refused'),
        )
        ..resumeExistingFailuresRemaining = 1
        ..recoverySnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-websocket-wrapper-recovered',
          storedSessionId: 'session-websocket-wrapper',
          created: false,
        );
      final chat = _productionAttachChat(
        'websocket-wrapper',
        gateway,
        api: api,
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'websocket-wrapper-history',
            'role': 'assistant',
            'content': 'durable history',
          },
        ],
        desktopRecoveryBackoff: const [Duration.zero],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(profile: 'owner-profile');
      await _waitUntil(
        () =>
            chat.desktopRuntimeSessionId ==
            'runtime-websocket-wrapper-recovered',
      );

      expect(gateway.resumeExistingStoredIds, [
        'session-websocket-wrapper',
        'session-websocket-wrapper',
      ]);
      _expectNoViewerAttachmentMutations(gateway, api);
    },
  );

  test(
    'real failed upgrades classify viewer-only retries without mutations',
    () async {
      for (final status in const [401, 403, 404, 429, 500, 503]) {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var upgradeRequests = 0;
        server.listen((request) async {
          upgradeRequests += 1;
          if (upgradeRequests == 1) {
            request.response.statusCode = status;
            request.response.write('PRIVATE_UPGRADE_BODY_$status');
            await request.response.close();
            return;
          }
          final socket = await WebSocketTransformer.upgrade(request);
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'gateway.ready',
                'payload': {'replay_epoch': 'epoch-a'},
              },
            }),
          );
          await for (final raw in socket) {
            final frame = jsonDecode(raw as String) as Map<String, dynamic>;
            final method = frame['method'];

            final result = method == 'gateway.capabilities'
                ? <String, dynamic>{'per_session_exclusive_submit': true}
                : <String, dynamic>{
                    'session_id': 'runtime-real-upgrade-$status',
                    'stored_session_id': 'session-real-upgrade-$status',
                    'created': false,
                  };
            socket.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': result,
              }),
            );
          }
        });
        final delegate = TuiGatewayClient(
          SavedConnection(
            id: 'real-upgrade-$status',
            label: 'Real upgrade $status',
            host: '127.0.0.1',
            port: 8642,
            apiKey: String.fromCharCodes(const [113, 97]),
            dashboardUrl: 'http://127.0.0.1:${server.port}',
          ),
          dashboard: _StaticTicketDashboardClient(),
        );
        final gateway = _CountingRealLifecycleGateway(delegate);
        final chat = _productionAttachChat(
          'real-upgrade-$status',
          gateway,
          storedMessageLoader: (_, _) async => [
            {
              'message_id': 'real-upgrade-history-$status',
              'role': 'assistant',
              'content': 'durable history',
            },
          ],
          desktopRecoveryBackoff: const [Duration.zero],
        );

        await chat.loadMessages(profile: 'owner-profile');
        final transient = status == 429 || status >= 500;
        if (transient) {
          await _waitUntil(() => upgradeRequests == 2);
          expect(gateway.connectCalls, 2, reason: 'HTTP $status');
          expect(upgradeRequests, 2, reason: 'HTTP $status');
          expect(gateway.resumeExistingCalls, 1, reason: 'HTTP $status');
          // The retry reaches current upstream, but no coverage/cut authority is
          // available, so the live overlay remains quarantined.
          expect(gateway.committedRuntimeIds, isEmpty, reason: 'HTTP $status');
          expect(chat.desktopRuntimeSessionId, isNull, reason: 'HTTP $status');
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 60));
          expect(gateway.connectCalls, 1, reason: 'HTTP $status');
          expect(upgradeRequests, 1, reason: 'HTTP $status');
          expect(gateway.resumeExistingCalls, 0, reason: 'HTTP $status');
          expect(gateway.committedRuntimeIds, isEmpty, reason: 'HTTP $status');
          expect(chat.desktopRuntimeSessionId, isNull, reason: 'HTTP $status');
        }
        expect(gateway.createCalls, 0, reason: 'HTTP $status');
        expect(gateway.legacyResumeCalls, 0, reason: 'HTTP $status');
        expect(gateway.submitCalls, 0, reason: 'HTTP $status');
        expect(gateway.interruptCalls, 0, reason: 'HTTP $status');
        expect(gateway.steerCalls, 0, reason: 'HTTP $status');
        expect(gateway.approvalCalls, 0, reason: 'HTTP $status');

        chat.dispose();
        await gateway.close();
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test('real socket-refused upgrade retries viewer only', () async {
    final reservation = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final refusedPort = reservation.port;
    await reservation.close();
    final delegate = TuiGatewayClient(
      SavedConnection(
        id: 'real-socket-refused',
        label: 'Real socket refused',
        host: '127.0.0.1',
        port: 8642,
        apiKey: String.fromCharCodes(const [113, 97]),
        dashboardUrl: 'http://127.0.0.1:$refusedPort',
      ),
      dashboard: _StaticTicketDashboardClient(),
    );
    final gateway = _CountingRealLifecycleGateway(delegate);
    final chat = _productionAttachChat(
      'real-socket-refused',
      gateway,
      storedMessageLoader: (_, _) async => const [
        {
          'message_id': 'real-refused-history',
          'role': 'assistant',
          'content': 'durable history',
        },
      ],
      desktopRecoveryBackoff: const [
        Duration.zero,
        Duration(milliseconds: 100),
      ],
    );

    await chat.loadMessages(profile: 'owner-profile');
    await _waitUntil(() => gateway.connectCalls == 2);
    expect(gateway.resumeExistingCalls, 0);
    expect(gateway.committedRuntimeIds, isEmpty);
    expect(gateway.createCalls, 0);
    expect(gateway.legacyResumeCalls, 0);
    expect(gateway.submitCalls, 0);
    expect(gateway.interruptCalls, 0);
    expect(gateway.steerCalls, 0);
    expect(gateway.approvalCalls, 0);

    chat.dispose();
    await gateway.close();
  });

  test(
    'typed connection loss retries exact durable viewer resume and binds once',
    () async {
      final api = _RestFallbackApiClient();
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..resumeExistingError = const TuiGatewayRpcError(
          'session.resume',
          'Connection lost before JSON-RPC response',
          failureKind: TuiGatewayRpcFailureKind.connectionLost,
        )
        ..resumeExistingFailuresRemaining = 1
        ..recoverySnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-typed-loss-recovered',
          storedSessionId: 'session-typed-loss',
          created: false,
          messagesProvided: true,
          running: false,
          status: 'completed',
        );
      final chat = _productionAttachChat(
        'typed-loss',
        gateway,
        api: api,
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'typed-loss-answer',
            'role': 'assistant',
            'content': 'durable survivor',
          },
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(profile: 'owner-profile');
      await _waitUntil(
        () => chat.desktopRuntimeSessionId == 'runtime-typed-loss-recovered',
      );

      expect(gateway.resumeExistingStoredIds, [
        'session-typed-loss',
        'session-typed-loss',
      ]);
      expect(gateway.committedRecoveryRuntimeIds, [
        'runtime-typed-loss-recovered',
      ]);
      expect(chat.messages.single['content'], 'durable survivor');
      _expectNoViewerAttachmentMutations(gateway, api);
    },
  );

  test(
    'passive cold open never resumes or creates a desktop runtime',
    () async {
      final gateway = _ActivityLifecycleRecoverableGateway();
      final chat = _productionAttachChat(
        'passive-open',
        gateway,
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'passive-answer',
            'role': 'assistant',
            'content': 'read only',
          },
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(profile: 'owner-profile', passiveOnly: true);
      gateway.drop();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(chat.messages.single['content'], 'read only');
      expect(chat.desktopRuntimeSessionId, isNull);
      expect(gateway.connectCalls, 0);
      expect(gateway.resumeExistingCalls, 0);
      expect(gateway.createForFirstSubmitCalls, 0);
      expect(gateway.submitCalls, 0);
      expect(gateway.activateCalls, 0);
      expect(gateway.interruptCalls, 0);
      expect(gateway.resumeCalls, 0);
    },
  );

  test(
    'transient cold-open failure with valid empty REST retries exact durable id',
    () async {
      final api = _RestFallbackApiClient();
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..resumeExistingError = const DashboardHttpException(503)
        ..resumeExistingFailuresRemaining = 1
        ..recoverySnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-empty-recovered',
          storedSessionId: 'session-empty-retry',
          created: false,
          messagesProvided: true,
          messageCount: 0,
        );
      final chat = _productionAttachChat(
        'empty-retry',
        gateway,
        api: api,
        storedMessageLoader: (_, _) async => const [],
        desktopRecoveryBackoff: const [Duration.zero],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(
        profile: 'owner-profile',
        expectedMessageCount: 0,
      );
      _expectNoViewerAttachmentMutations(gateway, api);
      await _waitUntil(
        () => chat.desktopRuntimeSessionId == 'runtime-empty-recovered',
      );

      expect(gateway.resumeExistingStoredIds, [
        'session-empty-retry',
        'session-empty-retry',
      ]);
      expect(gateway.committedRecoveryRuntimeIds, ['runtime-empty-recovered']);
      _expectNoViewerAttachmentMutations(gateway, api);
    },
  );

  test(
    'transient resume with expected-count violation still schedules attachment recovery',
    () async {
      final api = _RestFallbackApiClient();
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..resumeExistingError = const DashboardHttpException(503)
        ..resumeExistingFailuresRemaining = 1
        ..recoverySnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-count-recovered',
          storedSessionId: 'session-count-retry',
          created: false,
        );
      final chat = _productionAttachChat(
        'count-retry',
        gateway,
        api: api,
        storedMessageLoader: (_, _) async => const [],
        desktopRecoveryBackoff: const [Duration.zero],
      );
      addTearDown(chat.dispose);

      await expectLater(
        chat.loadMessages(profile: 'owner-profile', expectedMessageCount: 2),
        throwsStateError,
      );
      _expectNoViewerAttachmentMutations(gateway, api);
      await _waitUntil(
        () => chat.desktopRuntimeSessionId == 'runtime-count-recovered',
      );

      expect(gateway.resumeExistingCalls, 2);
      expect(
        gateway.resumeExistingStoredIds,
        everyElement('session-count-retry'),
      );
      _expectNoViewerAttachmentMutations(gateway, api);
    },
  );

  test(
    'transient resume with REST transport failure still schedules attachment recovery',
    () async {
      final api = _RestFallbackApiClient();
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..resumeExistingError = const DashboardHttpException(503)
        ..resumeExistingFailuresRemaining = 1
        ..recoverySnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-rest-error-recovered',
          storedSessionId: 'session-rest-error-retry',
          created: false,
        );
      final chat = _productionAttachChat(
        'rest-error-retry',
        gateway,
        api: api,
        storedMessageLoader: (_, _) =>
            Future.error(http.ClientException('typed REST transport failure')),
        desktopRecoveryBackoff: const [Duration.zero],
      );
      addTearDown(chat.dispose);

      await expectLater(
        chat.loadMessages(profile: 'owner-profile'),
        throwsA(anything),
      );
      _expectNoViewerAttachmentMutations(gateway, api);
      await _waitUntil(
        () => chat.desktopRuntimeSessionId == 'runtime-rest-error-recovered',
      );

      expect(gateway.resumeExistingCalls, 2);
      expect(
        gateway.resumeExistingStoredIds,
        everyElement('session-rest-error-retry'),
      );
      _expectNoViewerAttachmentMutations(gateway, api);
    },
  );

  test(
    'legacy code-null JSON-RPC timeout retries viewer attachment and exact resume succeeds',
    () async {
      final api = _RestFallbackApiClient();
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..resumeExistingError = const TuiGatewayRpcError(
          'session.resume',
          'Timeout waiting for JSON-RPC response',
        )
        ..resumeExistingFailuresRemaining = 2
        ..recoverySnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-timeout-recovered',
          storedSessionId: 'session-timeout-retry',
          created: false,
        );
      final chat = _productionAttachChat(
        'timeout-retry',
        gateway,
        api: api,
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'timeout-history',
            'role': 'assistant',
            'content': 'history remains readable during timeout recovery',
          },
        ],
        desktopRecoveryBackoff: const [Duration.zero, Duration.zero],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(profile: 'owner-profile');
      _expectNoViewerAttachmentMutations(gateway, api);
      await _waitUntil(
        () => chat.desktopRuntimeSessionId == 'runtime-timeout-recovered',
      );

      expect(gateway.resumeExistingCalls, 3);
      expect(
        gateway.resumeExistingStoredIds,
        everyElement('session-timeout-retry'),
      );
      expect(gateway.committedRecoveryRuntimeIds, [
        'runtime-timeout-recovered',
      ]);
      _expectNoViewerAttachmentMutations(gateway, api);
    },
  );

  test(
    'malformed code-null RPC stops viewer attachment without retry',
    () async {
      final api = _RestFallbackApiClient();
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..resumeExistingError = const TuiGatewayRpcError(
          'session.resume',
          'Invalid JSON-RPC response',
          origin: CompressionFailureOrigin.malformed,
        );
      final chat = _productionAttachChat(
        'malformed-stop',
        gateway,
        api: api,
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'malformed-history',
            'role': 'assistant',
            'content': 'durable history',
          },
        ],
        desktopRecoveryBackoff: const [Duration.zero, Duration(hours: 1)],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(profile: 'owner-profile');
      await Future<void>.delayed(const Duration(milliseconds: 40));

      _expectNoViewerAttachmentMutations(gateway, api);
      expect(gateway.resumeExistingCalls, 1);
      expect(chat.desktopRuntimeSessionId, isNull);
      _expectNoViewerAttachmentMutations(gateway, api);
    },
  );

  test(
    'unknown coded remote RPC stops viewer attachment as ambiguous',
    () async {
      final api = _RestFallbackApiClient();
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..resumeExistingError = const TuiGatewayRpcError(
          'session.resume',
          'future server rejection',
          code: 712345,
          data: {'reason': 'SESSION_NOT_OWNED'},
          origin: CompressionFailureOrigin.remoteRpc,
        );
      final chat = _productionAttachChat(
        'unknown-code-stop',
        gateway,
        api: api,
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'unknown-code-history',
            'role': 'assistant',
            'content': 'durable history',
          },
        ],
        desktopRecoveryBackoff: const [Duration.zero, Duration(hours: 1)],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(profile: 'owner-profile');
      await Future<void>.delayed(const Duration(milliseconds: 40));

      _expectNoViewerAttachmentMutations(gateway, api);
      expect(gateway.resumeExistingCalls, 1);
      expect(chat.desktopRuntimeSessionId, isNull);
      _expectNoViewerAttachmentMutations(gateway, api);
    },
  );

  test('unknown Object stops viewer attachment as ambiguous', () async {
    final api = _RestFallbackApiClient();
    final gateway = _ActivityLifecycleRecoverableGateway()
      ..resumeExistingError = StateError('programmer error');
    final chat = _productionAttachChat(
      'unknown-object-stop',
      gateway,
      api: api,
      storedMessageLoader: (_, _) async => const [
        {
          'message_id': 'unknown-object-history',
          'role': 'assistant',
          'content': 'durable history',
        },
      ],
      desktopRecoveryBackoff: const [Duration.zero, Duration(hours: 1)],
    );
    addTearDown(chat.dispose);

    await chat.loadMessages(profile: 'owner-profile');
    await Future<void>.delayed(const Duration(milliseconds: 40));

    _expectNoViewerAttachmentMutations(gateway, api);
    expect(gateway.resumeExistingCalls, 1);
    expect(chat.desktopRuntimeSessionId, isNull);
    _expectNoViewerAttachmentMutations(gateway, api);
  });

  test(
    'Dashboard ticket transport timeout retries exact durable viewer resume',
    () async {
      final dashboard = DashboardClient(
        host: 'hermes.local',
        manualToken: 'unused',
        httpClientOverride: MockClient(
          (_) async => throw TimeoutException('synthetic ticket timeout'),
        ),
      );
      addTearDown(dashboard.close);
      final api = _RestFallbackApiClient();
      const id = 'ws-ticket-transport-timeout';
      final gateway = _TicketTransportOnceGateway(dashboard)
        ..recoveryAdvertisedRuntimeSessionId =
            'runtime-ws-ticket-transport-timeout'
        ..recoverySnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-ws-ticket-transport-timeout',
          storedSessionId: 'session-ws-ticket-transport-timeout',
          created: false,
        );
      final chat = _productionAttachChat(
        id,
        gateway,
        api: api,
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'ws-ticket-timeout-history',
            'role': 'assistant',
            'content': 'durable history',
          },
        ],
        desktopRecoveryBackoff: const [Duration.zero, Duration.zero],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(profile: 'owner-profile');
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(gateway.ticketConnectAttempts, 2);
      expect(gateway.resumeExistingCalls, 1);
      expect(gateway.resumeExistingStoredIds, [
        'session-ws-ticket-transport-timeout',
      ]);
      expect(
        chat.desktopRuntimeSessionId,
        'runtime-ws-ticket-transport-timeout',
      );
      _expectNoViewerAttachmentMutations(gateway, api);
    },
  );

  test(
    'malformed status-less Dashboard ticket stops viewer attachment',
    () async {
      final dashboard = DashboardClient(
        host: 'hermes.local',
        manualToken: 'unused',
        httpClientOverride: MockClient((_) async => http.Response('{}', 200)),
      );
      addTearDown(dashboard.close);
      final api = _RestFallbackApiClient();
      const id = 'ws-ticket-malformed';
      final gateway = _TicketTransportOnceGateway(dashboard);
      final chat = _productionAttachChat(
        id,
        gateway,
        api: api,
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'ws-ticket-malformed-history',
            'role': 'assistant',
            'content': 'durable history',
          },
        ],
        desktopRecoveryBackoff: const [Duration.zero, Duration.zero],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(profile: 'owner-profile');
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(gateway.ticketConnectAttempts, 1);
      expect(gateway.resumeExistingCalls, 0);
      expect(chat.desktopRuntimeSessionId, isNull);
      _expectNoViewerAttachmentMutations(gateway, api);
    },
  );

  test('Dashboard WebSocket auth 401 and 403 stop without retry', () async {
    for (final status in const [401, 403]) {
      final api = _RestFallbackApiClient();
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..resumeExistingError = DashboardWebSocketAuthException(
          DashboardWebSocketAuthFailureCode.unavailable,
          statusCode: status,
        );
      final chat = _productionAttachChat(
        'ws-auth-$status',
        gateway,
        api: api,
        storedMessageLoader: (_, _) async => [
          {
            'message_id': 'ws-auth-history-$status',
            'role': 'assistant',
            'content': 'durable history',
          },
        ],
        desktopRecoveryBackoff: const [Duration.zero, Duration(hours: 1)],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(profile: 'owner-profile');
      await Future<void>.delayed(const Duration(milliseconds: 40));

      _expectNoViewerAttachmentMutations(gateway, api);
      expect(gateway.resumeExistingCalls, 1, reason: 'HTTP $status');
      expect(chat.desktopRuntimeSessionId, isNull, reason: 'HTTP $status');
      _expectNoViewerAttachmentMutations(gateway, api);
    }
  });

  test('Dashboard WebSocket auth 408 429 and 5xx retry exact resume', () async {
    for (final status in const [408, 429, 500, 503]) {
      final api = _RestFallbackApiClient();
      final id = 'ws-transient-$status';
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..resumeExistingError = DashboardWebSocketAuthException(
          DashboardWebSocketAuthFailureCode.unavailable,
          statusCode: status,
        )
        ..resumeExistingFailuresRemaining = 2
        ..recoverySnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-$id',
          storedSessionId: 'session-$id',
          created: false,
        );
      final chat = _productionAttachChat(
        id,
        gateway,
        api: api,
        storedMessageLoader: (_, _) async => [
          {
            'message_id': 'ws-transient-history-$status',
            'role': 'assistant',
            'content': 'durable history',
          },
        ],
        desktopRecoveryBackoff: const [Duration.zero, Duration.zero],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(profile: 'owner-profile');
      await _waitUntil(() => chat.desktopRuntimeSessionId == 'runtime-$id');

      expect(gateway.resumeExistingCalls, 3, reason: 'HTTP $status');
      expect(gateway.resumeExistingStoredIds, everyElement('session-$id'));
      _expectNoViewerAttachmentMutations(gateway, api);
    }
  });

  test(
    '4007 with nonempty REST preserves history marks missing and never retries',
    () async {
      final api = _RestFallbackApiClient();
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..resumeExistingError = const TuiGatewayRpcError(
          'session.resume',
          'session not found',
          code: 4007,
          origin: CompressionFailureOrigin.remoteRpc,
        );
      final chat = _productionAttachChat(
        'missing-with-history',
        gateway,
        api: api,
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'missing-history',
            'role': 'assistant',
            'content': 'preserve this durable history',
          },
        ],
        desktopRecoveryBackoff: const [Duration.zero],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(profile: 'owner-profile');
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(chat.messages.single['content'], 'preserve this durable history');
      _expectNoViewerAttachmentMutations(gateway, api);
      expect(chat.storedSessionKnownMissing, isTrue);
      expect(gateway.resumeExistingCalls, 1);
      expect(chat.desktopRuntimeSessionId, isNull);
      _expectNoViewerAttachmentMutations(gateway, api);
    },
  );

  test('4007 cold-open stop absorbs a later gateway stream error', () async {
    final api = _RestFallbackApiClient();
    final gateway = _ActivityLifecycleRecoverableGateway()
      ..resumeExistingError = const TuiGatewayRpcError(
        'session.resume',
        'session not found',
        code: 4007,
        origin: CompressionFailureOrigin.remoteRpc,
      );
    final chat = _productionAttachChat(
      'missing-absorbs-drop',
      gateway,
      api: api,
      storedMessageLoader: (_, _) async => const [
        {
          'message_id': 'missing-absorbs-history',
          'role': 'assistant',
          'content': 'durable history',
        },
      ],
      desktopRecoveryBackoff: const [Duration.zero],
    );
    addTearDown(chat.dispose);

    await chat.loadMessages(profile: 'owner-profile');
    gateway.drop();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(gateway.resumeExistingCalls, 1);
    expect(chat.desktopRuntimeSessionId, isNull);
    _expectNoViewerAttachmentMutations(gateway, api);
  });

  test(
    'attached malformed stream closure absorbs a later transient stream error',
    () async {
      final api = _RestFallbackApiClient();
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..initialSnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-malformed-stream',
          storedSessionId: 'session-malformed-stream',
          created: false,
          messagesProvided: true,
          running: false,
          status: 'completed',
        );
      final chat = _productionAttachChat(
        'malformed-stream',
        gateway,
        api: api,
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'malformed-stream-history',
            'role': 'assistant',
            'content': 'durable history',
          },
        ],
        desktopRecoveryBackoff: const [Duration(milliseconds: 10)],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(profile: 'owner-profile');
      expect(chat.desktopRuntimeSessionId, 'runtime-malformed-stream');

      gateway.failWith(
        const TuiGatewayRpcError(
          'events',
          'Invalid JSON-RPC response',
          origin: CompressionFailureOrigin.malformed,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(chat.desktopRuntimeSessionId, isNull);

      gateway.drop();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(gateway.resumeExistingCalls, 0);
      expect(chat.desktopRuntimeSessionId, isNull);
      _expectNoViewerAttachmentMutations(
        gateway,
        api,
        expectedActivateCalls: 1,
      );
    },
  );

  test(
    'malformed and unknown cold-open stops absorb later gateway stream errors',
    () async {
      final cases = <String, Object>{
        'malformed': const TuiGatewayRpcError(
          'session.resume',
          'Invalid JSON-RPC response',
          origin: CompressionFailureOrigin.malformed,
        ),
        'unknown': const TuiGatewayRpcError(
          'session.resume',
          'future server rejection',
          code: 712345,
          origin: CompressionFailureOrigin.remoteRpc,
        ),
      };
      for (final entry in cases.entries) {
        final api = _RestFallbackApiClient();
        final gateway = _ActivityLifecycleRecoverableGateway()
          ..resumeExistingError = entry.value;
        final chat = _productionAttachChat(
          '${entry.key}-absorbs-drop',
          gateway,
          api: api,
          storedMessageLoader: (_, _) async => const [
            {
              'message_id': 'absorbing-history',
              'role': 'assistant',
              'content': 'durable history',
            },
          ],
          desktopRecoveryBackoff: const [Duration.zero],
        );
        addTearDown(chat.dispose);

        await chat.loadMessages(profile: 'owner-profile');
        gateway.drop();
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(gateway.resumeExistingCalls, 1, reason: entry.key);
        expect(chat.desktopRuntimeSessionId, isNull, reason: entry.key);
        _expectNoViewerAttachmentMutations(gateway, api);
      }
    },
  );

  test(
    'later explicit visible load reassesses repaired 4007 configuration',
    () async {
      final api = _RestFallbackApiClient();
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..resumeExistingError = const TuiGatewayRpcError(
          'session.resume',
          'session not found',
          code: 4007,
          origin: CompressionFailureOrigin.remoteRpc,
        );
      final chat = _productionAttachChat(
        'explicit-reassess',
        gateway,
        api: api,
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'explicit-reassess-history',
            'role': 'assistant',
            'content': 'durable history',
          },
        ],
        desktopRecoveryBackoff: const [Duration.zero],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(profile: 'owner-profile');
      expect(gateway.resumeExistingCalls, 1);
      gateway
        ..resumeExistingError = null
        ..initialSnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-explicit-repaired',
          storedSessionId: 'session-explicit-reassess',
          created: false,
        );

      await chat.loadMessages(profile: 'owner-profile');

      expect(gateway.resumeExistingCalls, 2);
      expect(chat.desktopRuntimeSessionId, 'runtime-explicit-repaired');
      _expectNoViewerAttachmentMutations(gateway, api);
    },
  );

  test(
    'explicit visible reassessment supersedes an existing recovery backoff',
    () async {
      final api = _RestFallbackApiClient();
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..resumeExistingError = const DashboardHttpException(503)
        ..resumeExistingFailuresRemaining = 3
        ..recoverySnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-explicit-backoff-recovered',
          storedSessionId: 'session-explicit-backoff',
          created: false,
        );
      final chat = _productionAttachChat(
        'explicit-backoff',
        gateway,
        api: api,
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'explicit-backoff-history',
            'role': 'assistant',
            'content': 'durable history',
          },
        ],
        desktopRecoveryBackoff: const [Duration(milliseconds: 250)],
        desktopRecoveryRandom: () => 1,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(profile: 'owner-profile');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await chat.loadMessages(profile: 'owner-profile');
      await _waitUntil(
        () =>
            chat.desktopRuntimeSessionId ==
            'runtime-explicit-backoff-recovered',
      );
      expect(gateway.resumeExistingCalls, 4);
      expect(gateway.committedRecoveryRuntimeIds, [
        'runtime-explicit-backoff-recovered',
      ]);

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(gateway.resumeExistingCalls, 4);
      _expectNoViewerAttachmentMutations(gateway, api);
    },
  );

  test(
    'terminal cold-open result cancels an already-held automatic reattach',
    () async {
      final cases = <String, Object>{
        '4007': const TuiGatewayRpcError(
          'session.resume',
          'not found',
          code: 4007,
          origin: CompressionFailureOrigin.remoteRpc,
        ),
        'malformed': const TuiGatewayRpcError(
          'session.resume',
          'invalid envelope PRIVATE_TERMINAL_MARKER',
          origin: CompressionFailureOrigin.malformed,
        ),
        'auth': const DashboardWebSocketAuthException(
          DashboardWebSocketAuthFailureCode.unavailable,
          statusCode: 401,
        ),
        'unknown': const TuiGatewayRpcError(
          'session.resume',
          'future rejection PRIVATE_TERMINAL_MARKER',
          code: 712345,
          origin: CompressionFailureOrigin.remoteRpc,
        ),
      };
      for (final entry in cases.entries) {
        final heldRecovery = Completer<DesktopSessionSnapshot>();
        final terminalColdOpen = Completer<DesktopSessionSnapshot>();
        final api = _RestFallbackApiClient();
        final gateway = _ActivityLifecycleRecoverableGateway()
          ..recoveryAdvertisedRuntimeSessionId = 'runtime-${entry.key}-initial'
          ..initialSnapshot = DesktopSessionSnapshot(
            runtimeSessionId: 'runtime-${entry.key}-initial',
            storedSessionId: 'session-held-terminal-${entry.key}',
            created: false,
            messagesProvided: true,
          )
          ..scriptedResumeExisting.addAll([
            heldRecovery.future,
            terminalColdOpen.future,
          ]);
        final chat = _productionAttachChat(
          'held-terminal-${entry.key}',
          gateway,
          api: api,
          storedMessageLoader: (_, _) async => const [
            {
              'message_id': 'held-terminal-history',
              'role': 'assistant',
              'content': 'durable history',
            },
          ],
          desktopRecoveryBackoff: const [Duration.zero],
        );
        addTearDown(chat.dispose);

        await chat.loadMessages(profile: 'owner-profile');
        gateway.drop();
        await _waitUntil(() => gateway.resumeExistingCalls == 1);
        gateway
          ..initialAdvertisedStoredSessionId = null
          ..initialAdvertisedRuntimeSessionId = null;
        final terminalLoad = chat.loadMessages(profile: 'owner-profile');
        await _waitUntil(() => gateway.resumeExistingCalls == 2);
        terminalColdOpen.completeError(entry.value);
        await terminalLoad;
        final connectsAtTerminal = gateway.connectCalls;
        final resumesAtTerminal = gateway.resumeExistingCalls;

        heldRecovery.complete(
          DesktopSessionSnapshot(
            runtimeSessionId: 'runtime-${entry.key}-must-not-bind',
            storedSessionId: 'session-held-terminal-${entry.key}',
            created: false,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(gateway.connectCalls, connectsAtTerminal, reason: entry.key);
        expect(
          gateway.resumeExistingCalls,
          resumesAtTerminal,
          reason: entry.key,
        );
        expect(gateway.committedRecoveryRuntimeIds, isEmpty, reason: entry.key);
        expect(chat.desktopRuntimeSessionId, isNull, reason: entry.key);
        _expectNoViewerAttachmentMutations(
          gateway,
          api,
          expectedActivateCalls: 1,
        );
      }
    },
  );

  test(
    'compression-fenced visible load preserves terminal viewer recovery closure',
    () async {
      const id = 'fenced-terminal-reassessment';
      final storage = InMemoryDesktopCompressionFenceStorage();
      final fenceStore = DesktopCompressionFenceStore(
        storage: storage,
        mutationNamespaceForTesting: id,
        attemptId: () => 'fenced-terminal-attempt',
      );
      final api = _RestFallbackApiClient();
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..resumeExistingError = const TuiGatewayRpcError(
          'session.resume',
          'not found',
          code: 4007,
          origin: CompressionFailureOrigin.remoteRpc,
        );
      final chat = _productionAttachChat(
        id,
        gateway,
        api: api,
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'fenced-terminal-history',
            'role': 'assistant',
            'content': 'durable history',
          },
        ],
        desktopRecoveryBackoff: const [Duration.zero],
        compressionFenceStore: fenceStore,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(profile: 'owner-profile');
      expect(chat.storedSessionKnownMissing, isTrue);
      final armed = await fenceStore.arm(
        DesktopCompressionFenceScope(
          connectionId: id,
          profile: 'owner-profile',
          logicalSessionId: 'session-$id',
        ),
        tipAtStart: 'session-$id',
        compressionsAtStart: 0,
        createdAtMs: 1,
        reconcileUntilMs: 4102444800000,
      );
      expect(armed.claimed, isTrue);
      gateway.resumeExistingError = null;

      await chat.loadMessages(profile: 'owner-profile');
      gateway.drop();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(chat.storedSessionKnownMissing, isTrue);
      expect(gateway.resumeExistingCalls, 1);
      expect(gateway.committedRecoveryRuntimeIds, isEmpty);
      expect(chat.desktopRuntimeSessionId, isNull);
      _expectNoViewerAttachmentMutations(gateway, api);
    },
  );

  test('snapshot fallback copy preserves identity evidence', () async {
    final api = _RestFallbackApiClient();
    final gateway = _ActivityLifecycleRecoverableGateway()
      ..initialSnapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-copy-untrusted',
        storedSessionId: 'session-copy-evidence',
        created: false,
        identityAliasesConsistent: false,
        messagesProvided: true,
        messages: [
          DesktopSessionMessage(
            role: DesktopSessionMessageRole.assistant,
            rawRole: 'assistant',
            content: 'desktop fallback',
          ),
        ],
      );
    final chat = _productionAttachChat(
      'copy-evidence',
      gateway,
      api: api,
      storedMessageLoader: (_, _) async => const [
        {
          'message_id': 'rest-copy',
          'role': 'assistant',
          'content': 'REST authoritative fallback',
        },
      ],
      desktopRecoveryBackoff: const [Duration.zero],
    );
    addTearDown(chat.dispose);

    await chat.loadMessages(profile: 'owner-profile', expectedMessageCount: 1);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(chat.desktopRuntimeSessionId, isNull);
    expect(gateway.committedRecoveryRuntimeIds, isEmpty);
  });

  test('-32601 with valid empty REST stops without retry', () async {
    final api = _RestFallbackApiClient();
    final gateway = _ActivityLifecycleRecoverableGateway()
      ..resumeExistingError = const TuiGatewayRpcError(
        'session.resume',
        'method not found',
        code: -32601,
        origin: CompressionFailureOrigin.remoteRpc,
      );
    final chat = _productionAttachChat(
      'method-missing-empty',
      gateway,
      api: api,
      storedMessageLoader: (_, _) async => const [],
      desktopRecoveryBackoff: const [Duration.zero],
    );
    addTearDown(chat.dispose);

    await chat.loadMessages(profile: 'owner-profile', expectedMessageCount: 0);
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(gateway.resumeExistingCalls, 1);
    expect(chat.desktopRuntimeSessionId, isNull);
    _expectNoViewerAttachmentMutations(gateway, api);
  });

  test(
    'untrusted and created snapshots with valid empty REST do not retry',
    () async {
      final snapshots = <DesktopSessionSnapshot>[
        const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-created',
          storedSessionId: 'session-invalid-snapshot-created',
          created: true,
        ),
        const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-untrusted',
          storedSessionId: 'session-invalid-snapshot-untrusted',
          created: false,
          identityAliasesConsistent: false,
        ),
      ];
      for (var index = 0; index < snapshots.length; index++) {
        final api = _RestFallbackApiClient();
        final id = index == 0
            ? 'invalid-snapshot-created'
            : 'invalid-snapshot-untrusted';
        final gateway = _ActivityLifecycleRecoverableGateway()
          ..initialSnapshot = snapshots[index];
        final chat = _productionAttachChat(
          id,
          gateway,
          api: api,
          storedMessageLoader: (_, _) async => const [],
          desktopRecoveryBackoff: const [Duration.zero],
        );
        addTearDown(chat.dispose);

        await chat.loadMessages(
          profile: 'owner-profile',
          expectedMessageCount: 0,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(gateway.resumeExistingCalls, 0, reason: id);
        expect(chat.desktopRuntimeSessionId, isNull, reason: id);
        expect(gateway.committedRecoveryRuntimeIds, isEmpty, reason: id);
        _expectNoViewerAttachmentMutations(
          gateway,
          api,
          expectedActivateCalls: 1,
        );
      }
    },
  );

  test('passive valid-empty cold open issues zero lifecycle calls', () async {
    final api = _RestFallbackApiClient();
    final gateway = _ActivityLifecycleRecoverableGateway();
    final chat = _productionAttachChat(
      'passive-empty-open',
      gateway,
      api: api,
      storedMessageLoader: (_, _) async => const [],
      desktopRecoveryBackoff: const [Duration.zero],
    );
    addTearDown(chat.dispose);

    await chat.loadMessages(
      profile: 'owner-profile',
      expectedMessageCount: 0,
      passiveOnly: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(chat.messages, isEmpty);
    expect(gateway.connectCalls, 0);
    expect(gateway.resumeExistingCalls, 0);
    _expectNoViewerAttachmentMutations(gateway, api);
  });

  test(
    'older transient empty load cannot schedule after newer trusted successful load',
    () async {
      final oldResume = Completer<DesktopSessionSnapshot>();
      final oldRest = Completer<List<Map<String, dynamic>>>();
      var restCalls = 0;
      final api = _RestFallbackApiClient();
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..scriptedResumeExisting.addAll([
          oldResume.future,
          Future.value(
            const DesktopSessionSnapshot(
              runtimeSessionId: 'runtime-newer-trusted',
              storedSessionId: 'session-load-generation',
              created: false,
              messagesProvided: true,
              messageCount: 0,
            ),
          ),
        ]);
      final chat = _productionAttachChat(
        'load-generation',
        gateway,
        api: api,
        storedMessageLoader: (_, _) {
          restCalls += 1;
          return restCalls == 1 ? oldRest.future : Future.value(const []);
        },
        desktopRecoveryBackoff: const [Duration.zero],
      );
      addTearDown(chat.dispose);

      final older = chat.loadMessages(profile: 'owner-profile');
      await _waitUntil(
        () => gateway.resumeExistingCalls == 1 && restCalls == 1,
      );
      await chat.loadMessages(profile: 'owner-profile');
      expect(chat.desktopRuntimeSessionId, 'runtime-newer-trusted');

      oldRest.complete(const []);
      oldResume.completeError(const DashboardHttpException(503));
      await older;
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(gateway.resumeExistingCalls, 2);
      expect(gateway.resumeExistingStoredIds, [
        'session-load-generation',
        'session-load-generation',
      ]);
      expect(chat.desktopRuntimeSessionId, 'runtime-newer-trusted');
      _expectNoViewerAttachmentMutations(gateway, api);
    },
  );

  test(
    'invalidatePassiveRead cancels stale REST but does not cancel exact-durable reattach',
    () async {
      final recoveryGate = Completer<DesktopSessionSnapshot>();
      final staleReadGate = Completer<List<Map<String, dynamic>>>();
      var transcriptCalls = 0;
      final gateway = _ActivityLifecycleRecoverableGateway()
        ..initialSnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-passive-invalidate-1',
          storedSessionId: 'session-passive-invalidate',
          created: false,
          messagesProvided: true,
          running: false,
        )
        ..recoverySnapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-passive-invalidate-2',
          storedSessionId: 'session-passive-invalidate',
          created: false,
          messagesProvided: true,
          running: false,
        )
        ..recoveryExistingGate = recoveryGate;
      final chat = _productionAttachChat(
        'passive-invalidate',
        gateway,
        storedMessageLoader: (_, _) {
          transcriptCalls += 1;
          if (transcriptCalls == 1) {
            return Future.value(const [
              {
                'message_id': 'durable-answer',
                'role': 'assistant',
                'content': 'authoritative durable transcript',
              },
            ]);
          }
          return staleReadGate.future;
        },
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(profile: 'owner-profile');
      gateway.drop();
      await _waitUntil(() => gateway.resumeExistingCalls == 1);

      final staleRead = chat.loadMessages(
        profile: 'owner-profile',
        passiveOnly: true,
      );
      await _waitUntil(() => transcriptCalls == 2);
      chat.invalidatePassiveRead();
      staleReadGate.complete(const [
        {
          'message_id': 'stale-rest-answer',
          'role': 'assistant',
          'content': 'must not replace the durable transcript',
        },
      ]);
      await staleRead;
      recoveryGate.complete(
        const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-passive-invalidate-2',
          storedSessionId: 'session-passive-invalidate',
          created: false,
          messagesProvided: true,
          running: false,
        ),
      );

      await _waitUntil(
        () => chat.desktopRuntimeSessionId == 'runtime-passive-invalidate-2',
      );
      expect(
        chat.messages.single['content'],
        'authoritative durable transcript',
      );
      expect(gateway.committedRecoveryRuntimeIds, [
        'runtime-passive-invalidate-2',
      ]);
      expect(gateway.submitCalls, 0);
      expect(gateway.createForFirstSubmitCalls, 0);
      expect(gateway.activateCalls, 1);
      expect(gateway.interruptCalls, 0);
      expect(gateway.resumeCalls, 0);
    },
  );

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
    'recovery running usa el anchor previo para no duplicar el prompt',
    () async {
      const currentPrompt = 'turno activo durante recovery';
      final gateway = _LifecycleRecoverableGateway()
        ..initialSnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-anchor-1',
          storedSessionId: 'session-recovery-anchor',
          created: false,
          messagesProvided: true,
          messages: [
            DesktopSessionMessage.tryParse(const {
              'message_id': 'anchor-old-user',
              'role': 'user',
              'content': 'pregunta anterior',
            })!,
            DesktopSessionMessage.tryParse(const {
              'message_id': 'anchor-old-answer',
              'role': 'assistant',
              'content': 'respuesta anterior',
            })!,
          ],
          inflight: DesktopInflightTurn(
            user: currentPrompt,
            assistant: 'parcial previo',
            streaming: true,
          ),
          running: true,
        )
        ..recoverySnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-anchor-2',
          storedSessionId: 'session-recovery-anchor',
          created: false,
          messagesProvided: true,
          messages: [
            DesktopSessionMessage.tryParse(const {
              'message_id': 'anchor-old-user',
              'role': 'user',
              'content': 'pregunta anterior',
            })!,
            DesktopSessionMessage.tryParse(const {
              'message_id': 'anchor-old-answer',
              'role': 'assistant',
              'content': 'respuesta anterior',
            })!,
            DesktopSessionMessage.tryParse(const {
              'message_id': 'anchor-current-user',
              'role': 'user',
              'content': currentPrompt,
            })!,
          ],
          inflight: DesktopInflightTurn(
            user: currentPrompt,
            assistant: 'parcial recuperado',
            streaming: true,
          ),
          running: true,
        );
      final chat = _recoverableChat('recovery-anchor', gateway);
      addTearDown(chat.dispose);

      await chat.loadMessages();
      expect(
        chat.internalMessagesForTesting.where(
          (message) =>
              message['role'] == 'user' && message['content'] == currentPrompt,
        ),
        hasLength(1),
      );

      gateway.drop();
      await _waitUntil(
        () => gateway.committedRecoveryRuntimeIds.contains('runtime-anchor-2'),
      );

      expect(
        chat.internalMessagesForTesting.where(
          (message) =>
              message['role'] == 'user' && message['content'] == currentPrompt,
        ),
        hasLength(1),
      );
    },
  );

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
        () => chat.trace.isNotEmpty && chat.subagentAggregate.activeCount == 1,
      );
      expect(chat.subagentActivities, isEmpty);

      gateway.drop();
      await _waitUntil(() => chat.state == ChatPipelineState.completed);

      expect(chat.assistantContent, 'respuesta durable final');
      expect(chat.trace.single.status, 'completed');
      expect(chat.subagentAggregate.terminalCount, 1);
      expect(chat.subagentActivities, isEmpty);
      expect(
        chat.messages.any(
          (message) => message['content'].toString().contains('StateError'),
        ),
        isFalse,
      );
    },
  );

  test(
    'sin turn_idempotency_v1 el corte reanuda la sesión viva en vez de fallar',
    () async {
      // The official gateway never publishes `turn_idempotency_v1`. A socket
      // drop mid-turn must still resume the live session and adopt its
      // inflight turn instead of degrading straight to a failed turn.
      final gateway = _LifecycleRecoverableGateway()
        ..recoverySnapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-live-noidem',
          storedSessionId: 'session-live-noidem',
          created: false,
          messagesProvided: true,
          messages: const [],
          inflight: DesktopInflightTurn(
            user: 'sigue vivo sin idempotencia',
            assistant: 'respuesta parcial viva',
            streaming: true,
          ),
          running: true,
        );
      final chat = _recoverableChat(
        'live-noidem',
        gateway,
        turnIdempotencySupported: false,
      );
      addTearDown(chat.dispose);

      await chat.send(
        fullText: 'sigue vivo sin idempotencia',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('live-noidem', _NoopOutbox()),
      );
      final resumesBeforeDrop = gateway.resumeExistingCalls;
      gateway.drop();
      await _waitUntil(
        () =>
            chat.assistantContent == 'respuesta parcial viva' ||
            chat.state == ChatPipelineState.failed,
        timeout: const Duration(seconds: 10),
      );

      expect(chat.state, isNot(ChatPipelineState.failed));
      expect(chat.assistantContent, 'respuesta parcial viva');
      expect(chat.awaitingDurableTurnRecovery, isFalse);
      expect(chat.desktopRuntimeSessionId, 'runtime-live-noidem');
      expect(gateway.resumeExistingCalls, resumesBeforeDrop + 1);
      expect(gateway.statusCalls, 0);
    },
  );

  test(
    'sin turn_idempotency_v1 un resume sin snapshot sigue degradando honesto',
    () async {
      final gateway = _LifecycleRecoverableGateway();
      final chat = _recoverableChat(
        'binding-noidem',
        gateway,
        turnIdempotencySupported: false,
      );
      addTearDown(chat.dispose);

      await chat.send(
        fullText: 'sin evidencia del servidor',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('binding-noidem', _NoopOutbox()),
      );
      final resumesBeforeDrop = gateway.resumeExistingCalls;
      gateway.drop();
      await _waitUntil(
        () => chat.state == ChatPipelineState.failed,
        timeout: const Duration(seconds: 10),
      );

      expect(chat.awaitingDurableTurnRecovery, isTrue);
      expect(gateway.resumeExistingCalls, resumesBeforeDrop + 1);
      expect(gateway.statusCalls, 0);
    },
  );

  test(
    'snapshot terminal parcial sin cobertura degrada y conserva el parcial',
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
      await _waitUntil(() => chat.state == ChatPipelineState.failed);

      expect(chat.awaitingDurableTurnRecovery, isTrue);
      expect(transcriptCalls, 1);
      expect(
        chat.messages.any(
          (message) => message['content'] == 'respuesta local incompleta',
        ),
        isTrue,
      );
      expect(
        chat.messages.any(
          (message) => message['content'] == 'respuesta durable definitiva',
        ),
        isFalse,
      );
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test(
    'snapshot terminal parcial sin user queda history-pending sin GET tardío',
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
      await _waitUntil(() => chat.state == ChatPipelineState.failed);
      expect(chat.awaitingDurableTurnRecovery, isTrue);
      expect(transcriptCalls, 1);
      expect(transcriptGate.isCompleted, isFalse);
    },
  );

  test(
    'snapshot terminal parcial con tool queda pending sin promover transcript',
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
      await _waitUntil(() => chat.state == ChatPipelineState.failed);
      expect(chat.awaitingDurableTurnRecovery, isTrue);
      expect(transcriptCalls, 1);
      expect(transcriptGate.isCompleted, isFalse);
      expect(
        chat.messages.any(
          (message) => message['content'] == 'assistant final ya durable',
        ),
        isFalse,
      );
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
      'No se pudo recuperar el turno. Inténtalo de nuevo.',
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
        chat.internalMessagesForTesting.any(
          (message) =>
              message['_desktopMessageId'] == 'legitimate-answer' &&
              message['content'] ==
                  'respuesta legítima que debe seguir visible',
        ),
        isTrue,
      );
      final repeatedUser = chat.internalMessagesForTesting.singleWhere(
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
        chat.internalMessagesForTesting.any(
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
      final userIndex = chat.internalMessagesForTesting.indexWhere(
        (message) => message['_desktopMessageId'] == 'recovery-compacted-user',
      );
      chat.internalMessagesForTesting[userIndex] = {
        ...chat.internalMessagesForTesting[userIndex],
        'content': 'prompt repetido tras compactación',
      };

      gateway.drop();
      await _waitUntil(
        () => gateway.committedRecoveryRuntimeIds.contains(
          'runtime-after-recovery-compaction',
        ),
      );

      expect(
        chat.internalMessagesForTesting.any(
          (message) =>
              message['_desktopMessageId'] == 'recovery-compacted-answer' &&
              message['content'] == 'respuesta legítima tras recovery',
        ),
        isTrue,
      );
      expect(
        chat.internalMessagesForTesting
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
      final userIndex = chat.internalMessagesForTesting.indexWhere(
        (message) =>
            message['_desktopMessageId'] == 'recovery-idless-coverage-user',
      );
      chat.internalMessagesForTesting[userIndex] = {
        ...chat.internalMessagesForTesting[userIndex],
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
        chat.internalMessagesForTesting
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
        chat.internalMessagesForTesting.any(
          (message) =>
              message['_desktopMessageId'] ==
                  'recovery-provided-mismatch-answer' &&
              message['content'] ==
                  'respuesta legítima con mismatch en recovery',
        ),
        isTrue,
      );
      expect(
        chat.internalMessagesForTesting
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
      final userIndex = chat.internalMessagesForTesting.indexWhere(
        (message) =>
            message['_desktopMessageId'] == 'recovery-provided-empty-user',
      );
      chat.internalMessagesForTesting[userIndex] = {
        ...chat.internalMessagesForTesting[userIndex],
        'content': 'prompt repetido antes del recovery vacío',
      };

      gateway.drop();
      await _waitUntil(
        () => gateway.committedRecoveryRuntimeIds.contains(
          'runtime-recovery-provided-empty',
        ),
      );

      expect(
        chat.internalMessagesForTesting.any(
          (message) =>
              message['_desktopMessageId'] ==
                  'recovery-provided-empty-answer' &&
              message['content'] ==
                  'respuesta legítima antes del recovery vacío',
        ),
        isTrue,
      );
      expect(
        chat.internalMessagesForTesting
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
      chat.internalMessagesForTesting[userIndex] = {
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
      chat.internalMessagesForTesting
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

      final repeatedUsers = chat.internalMessagesForTesting
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
        chat.internalMessagesForTesting.singleWhere(
          (message) =>
              canonicalTranscriptMessageId(message) == 'historical-user-a',
        )['_cancelledUser'],
        isNot(true),
      );
      expect(
        chat.internalMessagesForTesting.singleWhere(
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
        chat.internalMessagesForTesting[userIndex] =
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
    chat.internalMessagesForTesting.add({
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
    chat.internalMessagesForTesting.add(const {
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
      chat.internalMessagesForTesting.add(const {
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
      chat.internalMessagesForTesting[userIndex] = const {
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
      chat.internalMessagesForTesting.addAll(const [
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
      chat.internalMessagesForTesting.add({
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
    chat.internalMessagesForTesting.add(const {
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
    chat.internalMessagesForTesting.add({
      'role': 'user',
      'content': 'turno histórico sin id',
    });

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
    chat.internalMessagesForTesting.add({
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
    Object? firstStopError;
    try {
      await chat.cancel();
    } catch (error) {
      firstStopError = error;
    }
    expect(firstStopError, isA<StateError>());

    expect(
      await chat.send(
        fullText: 'turno posterior prohibido',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('persist-failure-2', _NoopOutbox()),
      ),
      isFalse,
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
      chat.internalMessagesForTesting.add({
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
        compressionFenceStore: testCompressionFenceStore(),
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
        'No se pudo recuperar el turno. Inténtalo de nuevo.',
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
    'contract future-capability: cobertura completa reanuda corte idempotente',
    () async {
      final gateway = _RecoverableDesktopGateway();
      final api = ApiClient(
        baseUrl: 'http://127.0.0.1:1',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('not found', 404)),
      );
      final chat = ActiveChat(
        compressionFenceStore: testCompressionFenceStore(),
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

  test('commit false never calls markRunning during recovery', () async {
    final gateway = _RecoverableDesktopGateway()
      ..invalidateRecoveryAfterValidation = true;
    final chat = _recoverableChat(
      'commit-false-running',
      gateway,
      desktopRecoveryBackoff: const [Duration(milliseconds: 20)],
    );
    addTearDown(chat.dispose);
    final delivery = _CountingDelivery(
      prepared: PreparedTurn(
        connectionId: 'commit-false-running',
        sessionId: 'session-commit-false-running',
        clientTurnId: 'turn-commit-false-running',
        createdAtMs: 1,
        updatedAtMs: 1,
        text: 'no marcar running sin commit',
        attachments: const [],
        model: 'hermes-agent',
        profile: '',
      ),
      store: _NoopOutbox(),
    );

    await chat.send(
      fullText: 'no marcar running sin commit',
      model: 'hermes-agent',
      history: const [],
      delivery: delivery,
    );
    final beforeRecovery = delivery.markRunningCalls;
    gateway.drop();
    await _waitUntil(() => gateway.statusCalls > 0);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(delivery.markRunningCalls, beforeRecovery);
    expect(chat.state, isNot(ChatPipelineState.executing));
  });

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
    'first reconnect is immediate and cancellation fences its stale jitter timer',
    () async {
      final gateway = _RecoverableDesktopGateway()
        ..recoveryConnectFailuresRemaining = 100;
      final chat = _recoverableChat(
        'coverage-cancel',
        gateway,
        desktopRecoveryBackoff: const [Duration(milliseconds: 50)],
        desktopRecoveryRandom: () => 1,
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
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(gateway.connectCalls, 2);

      await chat.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(chat.state, ChatPipelineState.cancelled);
      expect(gateway.connectCalls, 2);
    },
  );

  test('reconnect full jitter is injectable and capped at thirty seconds', () {
    final samples = <double>[0.5, 1.0].iterator;
    final chat = _recoverableChat(
      'coverage-jitter-cap',
      _RecoverableDesktopGateway(),
      desktopRecoveryBackoff: const [
        Duration(milliseconds: 100),
        Duration(minutes: 5),
      ],
      desktopRecoveryRandom: () {
        samples.moveNext();
        return samples.current;
      },
    );
    addTearDown(chat.dispose);

    expect(chat.desktopRecoveryDelayForTesting(0), Duration.zero);
    expect(
      chat.desktopRecoveryDelayForTesting(1),
      const Duration(milliseconds: 50),
    );
    expect(chat.desktopRecoveryDelayForTesting(2), const Duration(seconds: 30));
  });

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
      const TuiGatewayRpcError(
        'session.resume',
        'unknown remote failure',
        code: 712345,
      ),
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
      final gateway = _LifecycleRecoverableGateway();
      final chat = _recoverableChat('recovery-missing-modern', gateway);
      addTearDown(chat.dispose);

      await chat.send(
        fullText: 'una sola vez',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('recovery-missing-modern', _NoopOutbox()),
      );
      expect(gateway.resumeCalls, 0);
      expect(gateway.resumeExistingCalls, 1);
      expect(gateway.createForFirstSubmitCalls, 0);

      gateway.resumeExistingError = const TuiGatewayRpcError(
        'session.resume',
        'session not found',
        code: 4007,
      );
      gateway.drop();
      await _waitUntil(() => chat.state == ChatPipelineState.failed);

      expect(gateway.resumeExistingCalls, 2);
      expect(gateway.resumeExistingStoredIds, [
        'session-recovery-missing-modern',
        'session-recovery-missing-modern',
      ]);
      expect(gateway.resumeCalls, 0);
      expect(gateway.createForFirstSubmitCalls, 0);
      expect(gateway.statusCalls, 0);
    },
  );

  test('un resume recovery obsoleto no adopta la identidad runtime', () async {
    final staleResume = Completer<DesktopSessionSnapshot>();
    final stopResume = Completer<DesktopSessionSnapshot>();
    final gateway = _LifecycleRecoverableGateway()
      ..initialSnapshot = const DesktopSessionBinding(
        runtimeSessionId: 'runtime-inicial',
        storedSessionId: 'session-stale-recovery-runtime',
        created: false,
      )
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

    gateway.recoveryExistingGate = stopResume;
    final stop = chat.cancel();
    await _waitUntil(() => gateway.resumeExistingCalls == 2);
    staleResume.complete(
      const DesktopSessionBinding(
        runtimeSessionId: 'runtime-obsoleto',
        storedSessionId: 'session-stale-recovery-runtime',
        created: false,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(chat.state, ChatPipelineState.cancelled);
    expect(
      gateway.committedRecoveryRuntimeIds,
      isNot(contains('runtime-obsoleto')),
    );

    stopResume.complete(
      const DesktopSessionBinding(
        runtimeSessionId: 'runtime-stop',
        storedSessionId: 'session-stale-recovery-runtime',
        created: false,
      ),
    );
    await stop;

    expect(gateway.committedRecoveryRuntimeIds, ['runtime-stop']);
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

        final stop = chat.cancel();
        gate.complete();
        await stop;
        expect(chat.state, ChatPipelineState.cancelled);
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

      final stop = chat.cancel();
      outbox.runningGate.complete();
      await stop;
      expect(chat.state, ChatPipelineState.cancelled);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(chat.state, ChatPipelineState.cancelled);

      await send;
    },
  );

  test(
    'rotar socket durante markRunning impide adoptar el runtime stale',
    () async {
      final statusGate = Completer<void>();
      final gateway = _RecoverableDesktopGateway()
        ..recoveryStatusGate = statusGate;
      final outbox = _GatedOutbox();
      final chat = _recoverableChat(
        'stale-channel-mark-running',
        gateway,
        // This test isolates the in-flight proof fence. A deterministic maximum
        // jitter keeps a later retry from becoming a second independent actor.
        desktopRecoveryRandom: () => 1.0,
      );
      addTearDown(chat.dispose);

      final send = chat.send(
        fullText: 'una sola vez',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('stale-channel-mark-running', outbox),
      );
      await outbox.acceptedStarted.future;
      gateway.drop();
      await _waitUntil(() => gateway.statusCalls == 1);
      statusGate.complete();
      await Future<void>.delayed(Duration.zero);
      outbox.acceptedGate.complete();
      await outbox.runningStarted.future;

      gateway.invalidateRecoveryAuthority();
      outbox.runningGate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(chat.desktopRuntimeSessionId, isNull);
      expect(chat.state, isNot(ChatPipelineState.executing));
      expect(gateway.submitCalls, 1);
      await chat.cancel();
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
      final stop = chat.cancel();
      chat.dispose();
      final commitsAtDispose = List<String>.of(
        gateway.committedRecoveryRuntimeIds,
      );
      expect(commitsAtDispose, isNot(contains('runtime-recovery-1')));
      expect(commitsAtDispose, isNot(contains('runtime-recovery-2')));
      outbox.runningGate.complete();
      await send;
      await stop;
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(gateway.committedRecoveryRuntimeIds, commitsAtDispose);
      expect(chat.desktopRuntimeSessionId, isNull);
      expect(gateway.submitCalls, 1);
      expect(gateway.createForFirstSubmitCalls, 0);
    },
  );

  test('una recuperación vieja no completa el turno nuevo', () async {
    final gateway = _LifecycleRecoverableGateway()
      ..recoveryStatusGate = Completer<void>()
      ..recoveredState = DesktopTurnState.terminal;
    final chat = _recoverableChat('recovery-new-turn', gateway);
    addTearDown(chat.dispose);

    expect(
      await chat.send(
        fullText: 'turno viejo',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('recovery-new-turn', _NoopOutbox()),
      ),
      isTrue,
    );
    gateway.drop();
    await _waitUntil(() => gateway.statusCalls == 1);

    await chat.cancel();
    expect(
      await chat.send(
        fullText: 'turno nuevo',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    expect(gateway.submitCalls, 2);
    expect(chat.state, ChatPipelineState.waiting);

    gateway.recoveryStatusGate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    gateway.emit(
      'tool.start',
      sessionId: gateway.submittedRuntimeIds.last,
      payload: const {'name': 'new-turn-tool'},
    );
    await _waitUntil(() => chat.state == ChatPipelineState.executing);

    expect(chat.trace.last.id, 'new-turn-tool');
  });

  test('un denial local de preflight durante la recuperación reintenta y no '
      'declara el turno perdido', () async {
    // Reproduce la tarjeta falsa "No se pudo recuperar el turno": el
    // servidor sí ejecuta el turno, pero el primer intento de recuperación
    // tropieza con el preflight local (code null) durante el flap del
    // socket y la clasificación terminal cortaba el backoff al instante.
    final gateway = _PreflightDenialRecoveryGateway()
      ..recoveredState = DesktopTurnState.terminal;
    final chat = _recoverableChat(
      'recovery-preflight-denial',
      gateway,
      desktopRecoveryBackoff: const [Duration.zero, Duration(milliseconds: 10)],
    );
    addTearDown(chat.dispose);

    final send = chat.send(
      fullText: 'turno que el servidor sí completó',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('recovery-preflight-denial', _NoopOutbox()),
    );
    await _waitUntil(() => gateway.submitCalls == 1);
    gateway.drop();

    await _waitUntil(() => gateway.statusCalls >= 1);
    await send;
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(gateway.recoveryResumeCalls, greaterThanOrEqualTo(2));
    expect(gateway.submitCalls, 1);
    expect(chat.state, ChatPipelineState.completed);
  });

  test('un capability denial permanente termina recovery sin reintentar ni '
      'duplicar submit', () async {
    final gateway = _PermanentCapabilityDenialRecoveryGateway();
    final chat = _recoverableChat(
      'recovery-permanent-capability-denial',
      gateway,
      desktopRecoveryBackoff: const [Duration.zero],
    );
    addTearDown(chat.dispose);

    final send = chat.send(
      fullText: 'turno aceptado antes del denial permanente',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery(
        'recovery-permanent-capability-denial',
        _NoopOutbox(),
      ),
    );
    await _waitUntil(() => gateway.submitCalls == 1);
    gateway.drop();

    await _waitUntil(() => chat.state == ChatPipelineState.failed);
    await send;

    expect(gateway.recoveryResumeCalls, 1);
    expect(gateway.submitCalls, 1);
  });

  test('un timeout tipado de capability durante recovery reintenta sin '
      'duplicar submit', () async {
    final gateway = _TypedTransientRecoveryGateway()
      ..recoveredState = DesktopTurnState.terminal;
    final chat = _recoverableChat(
      'recovery-typed-capability-timeout',
      gateway,
      desktopRecoveryBackoff: const [Duration.zero, Duration(milliseconds: 10)],
    );
    addTearDown(chat.dispose);

    final send = chat.send(
      fullText: 'turno aceptado antes del timeout tipado',
      model: 'hermes-agent',
      history: const [],
      delivery: _delivery('recovery-typed-capability-timeout', _NoopOutbox()),
    );
    await _waitUntil(() => gateway.submitCalls == 1);
    gateway.drop();

    await send;
    await _waitUntil(() => chat.state == ChatPipelineState.completed);

    expect(gateway.recoveryResumeCalls, greaterThanOrEqualTo(2));
    expect(gateway.submitCalls, 1);
  });

  test(
    'legacy GET A awaiting tombstone cannot close after refresh B',
    () async {
      SharedPreferences.setMockInitialValues({});
      final gateway = _DroppingDesktopGateway();
      final api = _ControlledApiClient();
      final tombstonePersistStarted = Completer<void>();
      final tombstonePersistGate = Completer<void>();
      final chat = ActiveChat(
        compressionFenceStore: testCompressionFenceStore(),
        connection: _connection('legacy-get-tombstone-refresh'),
        sessionId: 'session-legacy-get-tombstone-refresh',
        sessionTitle: 'legacy-get-tombstone-refresh',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
        terminalReconcileBudget: const Duration(milliseconds: 80),
        onCancelledTurn: (tombstone) {
          if (tombstone.cancelledMessageId != null) {
            if (!tombstonePersistStarted.isCompleted) {
              tombstonePersistStarted.complete();
            }
            return tombstonePersistGate.future;
          }
          return Future<void>.value();
        },
      );
      addTearDown(chat.dispose);

      final initialLoad = chat.loadMessages(expectedMessageCount: 2);
      await _waitUntil(() => api.requests.length == 1);
      api.requests[0].complete(const [
        {'message_id': 'prior-user', 'role': 'user', 'content': 'anterior'},
        {
          'message_id': 'prior-answer',
          'role': 'assistant',
          'content': 'respuesta anterior',
        },
      ]);
      await initialLoad.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('initial load stalled'),
      );

      await chat.send(
        fullText: 'turno detenido',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );

      final cancel = chat.cancel();
      await _waitUntil(() => gateway.interruptCalls == 1);
      gateway.emit(
        'message.complete',
        payload: const {'text': 'Operation interrupted.'},
      );
      await cancel.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('cancel stalled'),
      );

      final ambiguousSend = chat.send(
        fullText: 'turno ambiguo',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      await _waitUntil(() => api.requests.length == 2);
      api.requests[1].complete(const [
        {'message_id': 'prior-user', 'role': 'user', 'content': 'anterior'},
        {
          'message_id': 'prior-answer',
          'role': 'assistant',
          'content': 'respuesta anterior',
        },
        {
          'message_id': 'cancelled-user',
          'role': 'user',
          'content': 'turno detenido',
        },
      ]);
      await tombstonePersistStarted.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('tombstone metadata did not start'),
      );
      expect(
        await ambiguousSend.timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw StateError('ambiguous send stalled'),
        ),
        isTrue,
      );
      chat.enqueue('queued Desktop must remain fenced');
      gateway.emit(
        'message.delta',
        payload: const {'text': 'parcial preservado'},
      );
      await _waitUntil(() => chat.assistantContent == 'parcial preservado');
      final events = <ActiveChatEvent>[];
      final subscription = chat.changes.listen(events.add);
      addTearDown(subscription.cancel);

      gateway.drop();

      await _waitUntil(
        () =>
            api.requests.length == 3 || chat.state == ChatPipelineState.failed,
      );
      // R3 starts legacy GET A here. The retired route performs no such read.
      if (api.requests.length == 3) {
        api.requests[2].complete(const [
          {'message_id': 'prior-user', 'role': 'user', 'content': 'anterior'},
          {
            'message_id': 'prior-answer',
            'role': 'assistant',
            'content': 'respuesta anterior',
          },
          {
            'message_id': 'cancelled-user',
            'role': 'user',
            'content': 'turno detenido',
          },
          {
            'message_id': 'ambiguous-user',
            'role': 'user',
            'content': 'turno ambiguo',
          },
          {
            'message_id': 'stale-final-a',
            'role': 'assistant',
            'content': 'final obsoleto de A',
          },
        ]);
        await Future<void>.value();
      }

      final refreshB = chat.loadMessages(expectedMessageCount: 4);

      await _waitUntil(
        () =>
            api.requests.length == 4 ||
            (api.requests.length == 3 &&
                chat.state == ChatPipelineState.failed),
      );
      final refreshRequest = api.requests.last;
      if (!refreshRequest.isCompleted) {
        refreshRequest.complete(const [
          {'message_id': 'prior-user', 'role': 'user', 'content': 'anterior'},
          {
            'message_id': 'prior-answer',
            'role': 'assistant',
            'content': 'respuesta anterior',
          },
          {
            'message_id': 'cancelled-user',
            'role': 'user',
            'content': 'turno detenido',
          },
          {
            'message_id': 'ambiguous-user',
            'role': 'user',
            'content': 'turno ambiguo',
          },
        ]);
      }
      tombstonePersistGate.complete();
      await refreshB.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('refresh B stalled'),
      );
      await _waitUntil(
        () =>
            chat.state == ChatPipelineState.failed ||
            events.contains(ActiveChatEvent.done),
      );

      expect(chat.state, ChatPipelineState.failed);
      expect(chat.awaitingDurableTurnRecovery, isTrue);
      expect(events.where((event) => event == ActiveChatEvent.done), isEmpty);
      expect(gateway.submitCalls, 2);
      expect(chat.lastPrompt, 'turno ambiguo');
      expect(
        chat.messages.any(
          (message) => message['content'] == 'final obsoleto de A',
        ),
        isFalse,
      );
      expect(
        chat.messages.any(
          (message) => message['content'] == 'parcial preservado',
        ),
        isTrue,
        reason: chat.internalMessagesForTesting.toString(),
      );
    },
  );

  test(
    'refresh nuevo vence a un GET terminal antiguo que termina después',
    () async {
      final gateway = _DroppingDesktopGateway();
      final api = _ControlledApiClient();
      final chat = ActiveChat(
        compressionFenceStore: testCompressionFenceStore(),
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
      compressionFenceStore: testCompressionFenceStore(),
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

    final events = <ActiveChatEvent>[];
    final subscription = chat.changes.listen(events.add);
    addTearDown(subscription.cancel);
    gateway.emit('message.complete');
    await _waitUntil(() => api.requests.length == 1);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(events, isNot(contains(ActiveChatEvent.done)));
    expect(api.requests, hasLength(1));
    expect(chat.state, ChatPipelineState.completed);
    api.requests.single.complete(const []);
  });

  test(
    'terminal vacío adopta tarde user tool canónico y publica done una vez',
    () async {
      final gateway = _DroppingDesktopGateway();
      final api = _ControlledApiClient();
      final chat = ActiveChat(
        compressionFenceStore: testCompressionFenceStore(),
        connection: _connection('terminal-late-tool-only'),
        sessionId: 'session-terminal-late-tool-only',
        sessionTitle: 'terminal-late-tool-only',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
        terminalReconcileBudget: const Duration(milliseconds: 80),
      );
      addTearDown(chat.dispose);
      await chat.send(
        fullText: 'usa la herramienta tarde',
        model: 'hermes-agent',
        history: const [],
      );
      final events = <ActiveChatEvent>[];
      final subscription = chat.changes.listen(events.add);
      addTearDown(subscription.cancel);

      gateway.emit('message.start');
      gateway.emit('message.complete');
      await _waitUntil(() => api.requests.length == 1);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(events.where((event) => event == ActiveChatEvent.done), isEmpty);

      await _waitUntil(
        () => api.requests.length == 2,
        timeout: const Duration(seconds: 2),
      );
      api.requests[1].complete(const [
        {
          'message_id': 'late-user',
          'role': 'user',
          'content': 'usa la herramienta tarde',
        },
        {
          'message_id': 'late-tool',
          'role': 'tool',
          'name': 'search',
          'content': 'resultado canónico',
        },
      ]);
      await _waitUntil(
        () =>
            events.where((event) => event == ActiveChatEvent.done).length == 1,
      );
      await Future<void>.delayed(const Duration(milliseconds: 900));

      expect(
        events.where((event) => event == ActiveChatEvent.done),
        hasLength(1),
      );
      expect(chat.internalMessagesForTesting.first['message_id'], 'late-tool');
      api.requests.first.complete(const []);
    },
  );

  test(
    'assistant call y tool sin linkage siguen incompletos y no drenan',
    () async {
      final gateway = _DroppingDesktopGateway();
      final api = _ControlledApiClient();
      final chat = ActiveChat(
        compressionFenceStore: testCompressionFenceStore(),
        connection: _connection('terminal-open-call-unlinked-tool'),
        sessionId: 'session-terminal-open-call-unlinked-tool',
        sessionTitle: 'terminal-open-call-unlinked-tool',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
        terminalReconcileBudget: const Duration(milliseconds: 80),
      );
      addTearDown(chat.dispose);
      await chat.send(
        fullText: 'usa tool sin enlace',
        model: 'hermes-agent',
        history: const [],
      );
      chat.enqueue('no drenar todavía');
      final events = <ActiveChatEvent>[];
      final subscription = chat.changes.listen(events.add);
      addTearDown(subscription.cancel);

      gateway.emit('message.complete');
      await _waitUntil(() => api.requests.length == 1);
      final read = api.requests.single;
      read.complete(const [
        {
          'message_id': 'open-user',
          'role': 'user',
          'content': 'usa tool sin enlace',
        },
        {
          'message_id': 'open-assistant',
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'A',
              'function': {'name': 'search', 'arguments': '{}'},
            },
          ],
        },
        {
          'message_id': 'open-tool',
          'role': 'tool',
          'name': 'search',
          'content': 'resultado intermedio',
        },
      ]);
      await read.future;
      await Future<void>.value();

      expect(events.where((event) => event == ActiveChatEvent.done), isEmpty);
      expect(gateway.submitCalls, 1);
      expect(chat.assistantContent, '');
    },
  );

  test('terminal vacío tras delta parcial no autoriza done ni drain', () async {
    SharedPreferences.setMockInitialValues({});
    final gateway = _DroppingDesktopGateway();
    final api = _ControlledApiClient();
    final chat = ActiveChat(
      compressionFenceStore: testCompressionFenceStore(),
      connection: _connection('terminal-empty-after-partial-delta'),
      sessionId: 'session-terminal-empty-after-partial-delta',
      sessionTitle: 'terminal-empty-after-partial-delta',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
      terminalReconcileBudget: const Duration(milliseconds: 80),
    );
    addTearDown(chat.dispose);
    await chat.send(
      fullText: 'usa tool con respuesta parcial',
      model: 'hermes-agent',
      history: const [],
    );
    chat.enqueue('segundo turno no autorizado');
    final events = <ActiveChatEvent>[];
    final subscription = chat.changes.listen(events.add);
    addTearDown(subscription.cancel);

    gateway.emit(
      'message.delta',
      payload: const {'text': 'respuesta parcial visible'},
    );
    await _waitUntil(
      () => chat.assistantContent == 'respuesta parcial visible',
    );
    gateway.emit('message.complete');
    await _waitUntil(() => api.requests.length == 1);
    final causalRead = api.requests.single;
    causalRead.complete(const [
      {
        'message_id': 'partial-user',
        'role': 'user',
        'content': 'usa tool con respuesta parcial',
      },
      {
        'message_id': 'partial-assistant-tool-call',
        'role': 'assistant',
        'content': 'respuesta parcial visible',
        'tool_calls': [
          {
            'id': 'A',
            'function': {'name': 'search', 'arguments': '{}'},
          },
        ],
      },
      {
        'message_id': 'partial-tool-result',
        'role': 'tool',
        'tool_call_id': 'A',
        'name': 'search',
        'content': 'resultado intermedio',
      },
    ]);
    await causalRead.future;
    await Future<void>.value();

    expect(events.where((event) => event == ActiveChatEvent.done), isEmpty);
    expect(gateway.submitCalls, 1);
    expect(chat.assistantContent, 'respuesta parcial visible');
    expect(chat.isStreaming, isTrue);
  });

  test(
    'terminal duplicado publica y drena la cola exactamente una vez',
    () async {
      final gateway = _DroppingDesktopGateway();
      final api = _ControlledApiClient();
      final chat = ActiveChat(
        compressionFenceStore: testCompressionFenceStore(),
        connection: _connection('terminal-duplicate-exactly-once'),
        sessionId: 'session-terminal-duplicate-exactly-once',
        sessionTitle: 'terminal-duplicate-exactly-once',
        notifications: null,
        onTerminal: () {},
        api: api,
        desktopGateway: gateway,
        terminalReconcileBudget: const Duration(seconds: 1),
      );
      addTearDown(chat.dispose);
      await chat.send(
        fullText: 'primer turno',
        model: 'hermes-agent',
        history: const [],
      );
      chat.enqueue('segundo turno');
      final events = <ActiveChatEvent>[];
      final subscription = chat.changes.listen(events.add);
      addTearDown(subscription.cancel);

      gateway.emit('message.complete', payload: const {'text': 'final único'});
      gateway.emit(
        'message.complete',
        payload: const {'text': 'final duplicado'},
      );
      await _waitUntil(() => gateway.submitCalls == 2);
      await Future<void>.value();

      expect(
        events.where((event) => event == ActiveChatEvent.done),
        hasLength(1),
      );
      expect(gateway.submitCalls, 2);
      expect(chat.lastPrompt, 'segundo turno');
      for (final request in api.requests) {
        if (!request.isCompleted) request.complete(const []);
      }
    },
  );

  test('compacting mantiene REST viejo stale y no publica ni drena', () async {
    final gateway = _DroppingDesktopGateway();
    final api = _ControlledApiClient();
    final chat = ActiveChat(
      compressionFenceStore: testCompressionFenceStore(),
      connection: _connection('terminal-compacting-empty'),
      sessionId: 'session-terminal-compacting-empty',
      sessionTitle: 'terminal-compacting-empty',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
      terminalReconcileBudget: const Duration(milliseconds: 80),
    );
    addTearDown(chat.dispose);
    await chat.send(
      fullText: 'compacta y responde',
      model: 'hermes-agent',
      history: const [],
    );
    chat.enqueue('turno en cola');
    final events = <ActiveChatEvent>[];
    final subscription = chat.changes.listen(events.add);
    addTearDown(subscription.cancel);

    gateway.emit('status.update', payload: const {'kind': 'compacting'});
    gateway.emit('message.start');
    gateway.emit('message.complete');

    expect(events.where((event) => event == ActiveChatEvent.done), isEmpty);
    expect(gateway.submitCalls, 1);
    await _waitUntil(
      () => api.requests.isNotEmpty,
      timeout: const Duration(seconds: 2),
    );
    final staleRead = api.requests.single;
    staleRead.complete(const [
      {
        'message_id': 'compact-user',
        'role': 'user',
        'content': 'compacta y responde',
      },
      {
        'message_id': 'compact-answer',
        'role': 'assistant',
        'content': 'respuesta REST anterior al fence',
      },
    ]);
    await staleRead.future;
    await Future<void>.value();

    expect(events.where((event) => event == ActiveChatEvent.done), isEmpty);
    expect(chat.assistantContent, '');
    expect(gateway.submitCalls, 1);
  });

  test('dispose durante un GET terminal impide mutaciones tardías', () async {
    final gateway = _DroppingDesktopGateway();
    final api = _ControlledApiClient();
    final chat = ActiveChat(
      compressionFenceStore: testCompressionFenceStore(),
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
      compressionFenceStore: testCompressionFenceStore(),
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
        compressionFenceStore: testCompressionFenceStore(),
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
        {
          'message_id': 'terminal-tool-user',
          'role': 'user',
          'content': 'usa la herramienta',
        },
        {
          'message_id': 'terminal-tool-result',
          'role': 'tool',
          'name': 'search',
          'content': 'resultado',
        },
      ]);
      await done.timeout(const Duration(seconds: 1));

      expect(api.requests, hasLength(1));
      expect(chat.internalMessagesForTesting.first['role'], 'tool');
      expect(chat.state, ChatPipelineState.completed);
    },
  );

  test(
    'un transcript terminal parcial no reemplaza la respuesta completa visible',
    () async {
      final gateway = _DroppingDesktopGateway();
      final api = _ControlledApiClient();
      final chat = ActiveChat(
        compressionFenceStore: testCompressionFenceStore(),
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
        compressionFenceStore: testCompressionFenceStore(),
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
      compressionFenceStore: testCompressionFenceStore(),
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
    chat.internalMessagesForTesting = [
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

    final stop = chat.cancel();
    api.startGate!.complete('rest-run-late');
    await stop;
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
      final stop = chat.cancel();

      await _waitUntil(() => gateway.interruptCalls == 2);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(gateway.submitCalls, 1);
      final recoveredRuntimeId = gateway.interruptedRuntimeIds.last;
      gateway.emit(
        'message.complete',
        sessionId: recoveredRuntimeId,
        payload: const {'text': 'Operation interrupted.'},
      );
      await stop;
      final next = chat.send(
        fullText: 'turno nuevo',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery('cancel-before-next-2', _NoopOutbox()),
      );
      expect(await next.timeout(const Duration(milliseconds: 500)), isTrue);
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
      await chat.cancel();

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
    final resumesBeforeCancel = gateway.resumeExistingCalls;
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
    expect(gateway.resumeExistingCalls, resumesBeforeCancel);
    expect(gateway.submitCalls, 1);
  });

  test(
    'sin idempotencia, un corte no adopta assistant final por GET',
    () async {
      final gateway = _DroppingDesktopGateway();
      final api = _CompletedTranscriptApi(const [
        {'role': 'user', 'content': 'dame noticias'},
        {'role': 'assistant', 'content': 'Aquí están las noticias.'},
      ]);
      final chat = ActiveChat(
        compressionFenceStore: testCompressionFenceStore(),
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

      gateway.drop();

      await _waitUntil(() => chat.state == ChatPipelineState.failed);
      expect(chat.awaitingDurableTurnRecovery, isTrue);
      expect(api.calls, 0);
      expect(chat.messages.first['role'], 'assistant_error');
      expect(
        chat.messages.any(
          (message) => message['content'] == 'Aquí están las noticias.',
        ),
        isFalse,
      );
    },
  );

  test('recovery legacy no consume GET final ni drena la cola', () async {
    SharedPreferences.setMockInitialValues({});
    final gateway = _QueueAuthorizedDroppingGateway();
    final api = _SingleAuthorizedTranscriptApi(const [
      {
        'message_id': 'legacy-authority-user',
        'role': 'user',
        'content': 'dame noticias',
      },
      {
        'message_id': 'legacy-authority-final',
        'role': 'assistant',
        'content': 'Aquí están las noticias.',
      },
    ]);
    final terminalEvents = <ActiveChatEvent>[];
    final chat = ActiveChat(
      compressionFenceStore: testCompressionFenceStore(),
      connection: _connection('legacy-authority-once'),
      sessionId: 'session-legacy-authority-once',
      sessionTitle: 'legacy-authority-once',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
      terminalReconcileBudget: const Duration(milliseconds: 80),
    );
    addTearDown(chat.dispose);
    final subscription = chat.changes.listen(terminalEvents.add);
    addTearDown(subscription.cancel);

    await chat.send(
      fullText: 'dame noticias',
      model: 'hermes-agent',
      history: const [],
    );
    chat.enqueue('continúa con el siguiente turno');
    gateway.emit('message.delta', payload: const {'text': 'Aquí están'});
    await _waitUntil(() => chat.assistantContent == 'Aquí están');

    gateway.drop();
    await _waitUntil(() => chat.state == ChatPipelineState.failed);

    expect(chat.awaitingDurableTurnRecovery, isTrue);
    expect(api.calls, 0);
    expect(api.firstRead.isCompleted, isFalse);
    expect(api.redundantRead.isCompleted, isFalse);
    expect(
      terminalEvents.where((event) => event == ActiveChatEvent.done),
      isEmpty,
    );
    expect(gateway.submitCalls, 1);
    expect(gateway.listActiveCalls, 0);
    expect(chat.lastPrompt, 'dame noticias');
    expect(
      chat.messages.any((message) => message['content'] == 'Aquí están'),
      isTrue,
    );
  });

  test(
    'recovery legacy no lee tool ni assistant final tras socket drop',
    () async {
      final gateway = _DroppingDesktopGateway();
      final api = _ToolThenFinalTranscriptApi();
      final chat = ActiveChat(
        compressionFenceStore: testCompressionFenceStore(),
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
      await _waitUntil(() => chat.state == ChatPipelineState.failed);

      expect(chat.awaitingDurableTurnRecovery, isTrue);
      expect(api.calls, 0);
      expect(api.firstRead.isCompleted, isFalse);
      expect(
        chat.messages.any(
          (message) => message['content'] == 'respuesta final durable',
        ),
        isFalse,
      );
      expect(api.finalReady.isCompleted, isFalse);
    },
  );
}

class _NoopOutbox implements TurnOutboxPersistence {
  @override
  Future<void> delete(PreparedTurn turn) async {}

  @override
  Future<void> save(PreparedTurn turn) async {}
}
