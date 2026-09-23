import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/recovery_proof.dart';
import 'package:hermes_android/core/services/replay_coordinator.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _OwnershipStopGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopTypedRecoveryGateway {
  final _events = StreamController<TuiGatewayEvent>.broadcast();
  final _recovery = ReplayCoordinator();
  final _recoveryChannel = Object();
  var rejectNextSubmit = true;
  var interruptCalls = 0;
  var resumeExistingCalls = 0;
  var recoveryProofCalls = 0;
  var recoveryCommitCalls = 0;

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
    runtimeSessionId: 'runtime-owned-elsewhere',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    resumeExistingCalls++;
    return DesktopSessionSnapshot(
      runtimeSessionId: 'runtime-owned-elsewhere',
      storedSessionId: storedSessionId,
      created: false,
    );
  }

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-owned-elsewhere',
    storedSessionId: 'session-ownership-stop',
    created: true,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    if (!rejectNextSubmit) return;
    rejectNextSubmit = false;
    throw const TuiGatewayRpcError(
      'prompt.submit',
      'private ownership detail',
      code: 4090,
      data: {'reason': 'SESSION_NOT_OWNED'},
    );
  }

  @override
  Future<void> interrupt(String runtimeSessionId) async {
    interruptCalls++;
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
  }) {
    recoveryProofCalls++;
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
  bool validateRecovery(RecoveryProof proof) => _recovery.canCommitRecovery(
    proof,
    socketGeneration: 1,
    channel: _recoveryChannel,
    replayEpoch: null,
  );

  @override
  bool commitRecovery(RecoveryProof proof) {
    recoveryCommitCalls++;
    return _recovery.commitRecovery(
      proof,
      socketGeneration: 1,
      channel: _recoveryChannel,
      replayEpoch: null,
    );
  }

  @override
  bool recoveryAuthorityStillCurrent(RecoveryProof proof) =>
      _recovery.isRecoveryAuthorityCurrent(
        proof,
        socketGeneration: 1,
        channel: _recoveryChannel,
        replayEpoch: null,
      );

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> close() => _events.close();
}

class _NoopOutbox implements TurnOutboxPersistence {
  @override
  Future<void> delete(PreparedTurn turn) async {}

  @override
  Future<void> save(PreparedTurn turn) async {}
}

ActiveTurnDelivery _delivery() => ActiveTurnDelivery(
  prepared: PreparedTurn(
    connectionId: 'conn-stop-ownership',
    sessionId: 'session-ownership-stop',
    clientTurnId: 'turn-stop-ownership',
    createdAtMs: 1,
    updatedAtMs: 1,
    text: 'turno rechazado',
    attachments: [],
    model: 'hermes-agent',
    profile: '',
  ),
  store: _NoopOutbox(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('SESSION_NOT_OWNED keeps prompt fenced but explicit Stop reaches wire', () async {
    final gateway = _OwnershipStopGateway();
    final api = ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'test-only',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    );
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'conn-stop-ownership',
        label: 'Test',
        host: 'example.invalid',
        port: 443,
        apiKey: 'test-only',
        useHttps: true,
      ),
      sessionId: 'session-ownership-stop',
      sessionTitle: 'Test',
      notifications: null,
      onTerminal: () {},
      api: api,
      desktopGateway: gateway,
      desktopRecoveryAttemptTimeout: const Duration(milliseconds: 50),
      desktopRecoveryBackoff: const [Duration.zero],
    );
    addTearDown(chat.dispose);

    expect(
      await chat.send(
        fullText: 'turno rechazado',
        model: 'hermes-agent',
        history: const [],
        delivery: _delivery(),
      ),
      isFalse,
    );
    expect(chat.conflictReadOnly, isTrue);

    await chat.cancel();

    expect(gateway.resumeExistingCalls, 2);
    expect(gateway.recoveryProofCalls, 1);
    expect(gateway.recoveryCommitCalls, 1);
    expect(gateway.interruptCalls, 1);
    expect(chat.stopConfirmationState, StopConfirmationState.confirmed);
    expect(chat.conflictReadOnly, isTrue);
  });
}
