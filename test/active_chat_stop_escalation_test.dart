import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/recovery_proof.dart';
import 'package:hermes_android/core/services/replay_coordinator.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _EscalationGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopTypedRecoveryGateway {
  _EscalationGateway({this.interruptErrors = const [], this.hangInterrupt = false});

  final List<Object?> interruptErrors;
  final bool hangInterrupt;
  final _events = StreamController<TuiGatewayEvent>.broadcast();
  final _recovery = ReplayCoordinator();
  final _recoveryChannel = Object();
  var interruptCalls = 0;
  var resumeExistingCalls = 0;

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
    runtimeSessionId: 'runtime-escalation',
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
      runtimeSessionId: 'runtime-escalation',
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
    runtimeSessionId: 'runtime-escalation',
    storedSessionId: 'session-stop-escalation',
    created: true,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {
    final index = interruptCalls++;
    if (hangInterrupt) return Completer<void>().future;
    if (index < interruptErrors.length) {
      final error = interruptErrors[index];
      if (error != null) throw error;
    }
    _events.add(
      const TuiGatewayEvent(
        type: 'message.complete',
        sessionId: 'runtime-escalation',
        payload: {'text': '', 'status': 'interrupted'},
      ),
    );
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

ActiveChat _chat(_EscalationGateway gateway) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
  connection: SavedConnection(
    id: 'conn-stop-escalation',
    label: 'Test',
    host: 'example.invalid',
    port: 443,
    apiKey: 'test-only',
    useHttps: true,
  ),
  sessionId: 'session-stop-escalation',
  sessionTitle: 'Test',
  notifications: null,
  onTerminal: () {},
  api: ApiClient(
    baseUrl: 'https://example.invalid',
    apiKey: 'test-only',
    httpClient: MockClient((_) async => http.Response('unused', 500)),
  ),
  desktopGateway: gateway,
  desktopRecoveryAttemptTimeout: const Duration(milliseconds: 30),
  desktopRecoveryBackoff: const [Duration.zero],
);

Future<void> _startTurn(ActiveChat chat) async {
  expect(
    await chat.send(
      fullText: 'turno vivo',
      model: 'hermes-agent',
      history: const [],
    ),
    isTrue,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('4001 resumes once and retries interrupt once', () async {
    final gateway = _EscalationGateway(
      interruptErrors: const [
        TuiGatewayRpcError('session.interrupt', 'session not found', code: 4001),
      ],
    );
    final chat = _chat(gateway);
    addTearDown(chat.dispose);
    await _startTurn(chat);

    final stop = chat.cancel();
    expect(chat.state, ChatPipelineState.cancelled);
    await stop;

    expect(gateway.resumeExistingCalls, 2);
    expect(gateway.interruptCalls, 2);
    expect(chat.stopConfirmationState, StopConfirmationState.confirmed);
  });

  test('5032 retries interrupt immediately without resuming', () async {
    final gateway = _EscalationGateway(
      interruptErrors: const [
        TuiGatewayRpcError('session.interrupt', 'agent still starting', code: 5032),
      ],
    );
    final chat = _chat(gateway);
    addTearDown(chat.dispose);
    await _startTurn(chat);

    await chat.cancel();

    expect(gateway.resumeExistingCalls, 1);
    expect(gateway.interruptCalls, 2);
    expect(chat.stopConfirmationState, StopConfirmationState.confirmed);
  });

  test('4009 waits for settling then resumes and retries', () async {
    final gateway = _EscalationGateway(
      interruptErrors: const [
        TuiGatewayRpcError('session.interrupt', 'disconnect settling', code: 4009),
      ],
    );
    final chat = _chat(gateway);
    addTearDown(chat.dispose);
    await _startTurn(chat);

    await chat.cancel();

    expect(gateway.resumeExistingCalls, 2);
    expect(gateway.interruptCalls, 2);
    expect(chat.stopConfirmationState, StopConfirmationState.confirmed);
  });

  test('hanging interrupt becomes unsettled after at most three attempts', () async {
    final gateway = _EscalationGateway(hangInterrupt: true);
    final chat = _chat(gateway);
    addTearDown(chat.dispose);
    await _startTurn(chat);

    var callerTimedOut = false;
    try {
      await chat.cancel().timeout(const Duration(milliseconds: 500));
    } on TimeoutException {
      callerTimedOut = true;
    }

    expect(callerTimedOut, isFalse);
    expect(gateway.interruptCalls, lessThanOrEqualTo(3));
    expect(chat.stopConfirmationState, StopConfirmationState.failed);
    expect(chat.state, ChatPipelineState.cancelled);
    expect(
      await chat.send(
        fullText: 'turno posterior',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
  });
}
