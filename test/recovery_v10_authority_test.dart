import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/json_rpc_wire.dart';
import 'package:hermes_android/core/services/recovery_proof.dart';
import 'package:hermes_android/core/services/replay_coordinator.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

final Object _recoveryChannel = Object();

class _LeakingAuthDashboard extends DashboardClient {
  _LeakingAuthDashboard(this.marker)
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  final String marker;

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async {
    throw StateError('auth failed with $marker');
  }
}

TuiGatewayClient _authFailingClient(String marker) => TuiGatewayClient(
  SavedConnection(
    id: 'conn-sensitive-auth',
    label: 'Sensitive auth',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'unused',
    dashboardUrl: 'http://127.0.0.1:1',
  ),
  dashboard: _LeakingAuthDashboard(marker),
);

void main() {
  test(
    'minted recovery without an exact snapshot cursor remains quarantined',
    () {
      final coordinator = ReplayCoordinator();
      coordinator.quarantine('runtime-a');
      final proof = coordinator.mintRecoveryProof(
        connectionId: 'conn-a',
        durableSessionId: 'stored-a',
        runtimeSessionId: 'runtime-a',
        profile: 'profile-a',
        socketGeneration: 7,
        channel: _recoveryChannel,
        bindGeneration: 8,
        sessionGeneration: 9,
        turnGeneration: 10,
        replayEpoch: 'epoch-a',
        created: false,
        durableIdentityExplicit: true,
        identityAliasesConsistent: true,
        coverage: RecoveryDomain.values.toSet(),
        postSnapshotSequence: null,
      );

      expect(
        coordinator.commitRecovery(
          proof,
          socketGeneration: 7,
          channel: _recoveryChannel,
          replayEpoch: 'epoch-a',
        ),
        isFalse,
      );
      expect(coordinator.isQuarantined('runtime-a'), isTrue);
    },
  );

  test(
    'quarantined snapshot window retains frames without projecting them',
    () {
      final coordinator = ReplayCoordinator();
      coordinator.quarantine('runtime-a');

      expect(
        coordinator.acceptLive(
          const SessionGatewayEvent('message.delta', 'runtime-a', 2, {
            'text': 'between',
          }),
        ),
        ReplayLiveDisposition.held,
      );
      final proof = coordinator.mintRecoveryProof(
        connectionId: 'conn-a',
        durableSessionId: 'stored-a',
        runtimeSessionId: 'runtime-a',
        profile: 'profile-a',
        socketGeneration: 7,
        channel: _recoveryChannel,
        bindGeneration: 8,
        sessionGeneration: 9,
        turnGeneration: 10,
        replayEpoch: 'epoch-a',
        created: false,
        durableIdentityExplicit: true,
        identityAliasesConsistent: true,
        coverage: RecoveryDomain.values.toSet(),
        postSnapshotSequence: null,
      );
      expect(
        coordinator.commitRecovery(
          proof,
          socketGeneration: 7,
          channel: _recoveryChannel,
          replayEpoch: 'epoch-a',
        ),
        isFalse,
      );
      expect(
        coordinator.acceptLive(
          const SessionGatewayEvent('message.delta', 'runtime-a', 3, {
            'text': 'after',
          }),
        ),
        ReplayLiveDisposition.held,
      );
      expect(coordinator.watermarks, isEmpty);
      expect(coordinator.isQuarantined('runtime-a'), isTrue);
    },
  );

  test('exact snapshot cut releases only a contiguous held tail once', () {
    final coordinator = ReplayCoordinator();
    coordinator.quarantine('runtime-a');
    expect(
      coordinator.acceptLive(
        const SessionGatewayEvent('message.delta', 'runtime-a', 13, {
          'text': 'between',
        }),
      ),
      ReplayLiveDisposition.held,
    );
    expect(
      coordinator.acceptLive(
        const SessionGatewayEvent('message.delta', 'runtime-a', 14, {
          'text': 'after',
        }),
      ),
      ReplayLiveDisposition.held,
    );
    final proof = coordinator.mintRecoveryProof(
      connectionId: 'conn-a',
      durableSessionId: 'stored-a',
      runtimeSessionId: 'runtime-a',
      profile: 'profile-a',
      socketGeneration: 7,
      channel: _recoveryChannel,
      bindGeneration: 8,
      sessionGeneration: 9,
      turnGeneration: 10,
      replayEpoch: 'epoch-a',
      created: false,
      durableIdentityExplicit: true,
      identityAliasesConsistent: true,
      coverage: RecoveryDomain.values.toSet(),
      postSnapshotSequence: 12,
    );

    expect(
      coordinator.commitRecovery(
        proof,
        socketGeneration: 7,
        channel: _recoveryChannel,
        replayEpoch: 'epoch-a',
      ),
      isTrue,
    );
    expect(coordinator.watermarks['runtime-a'], 14);
    expect(
      coordinator.commitRecovery(
        proof,
        socketGeneration: 7,
        channel: _recoveryChannel,
        replayEpoch: 'epoch-a',
      ),
      isFalse,
    );
  });

  test('exact snapshot cut rejects a non-contiguous held tail', () {
    final coordinator = ReplayCoordinator();
    coordinator.quarantine('runtime-a');
    coordinator.acceptLive(
      const SessionGatewayEvent('message.delta', 'runtime-a', 14, {
        'text': 'gap',
      }),
    );
    final proof = coordinator.mintRecoveryProof(
      connectionId: 'conn-a',
      durableSessionId: 'stored-a',
      runtimeSessionId: 'runtime-a',
      profile: 'profile-a',
      socketGeneration: 7,
      channel: _recoveryChannel,
      bindGeneration: 8,
      sessionGeneration: 9,
      turnGeneration: 10,
      replayEpoch: 'epoch-a',
      created: false,
      durableIdentityExplicit: true,
      identityAliasesConsistent: true,
      coverage: RecoveryDomain.values.toSet(),
      postSnapshotSequence: 12,
    );

    expect(
      coordinator.commitRecovery(
        proof,
        socketGeneration: 7,
        channel: _recoveryChannel,
        replayEpoch: 'epoch-a',
      ),
      isFalse,
    );
    expect(coordinator.isQuarantined('runtime-a'), isTrue);
  });

  test('snapshot producer boundary rejects whitespace runtime identity', () {
    expect(
      () => DesktopSessionSnapshot.fromJson(
        const {'session_id': ' runtime-a ', 'stored_session_id': 'stored-a'},
        requestedStoredSessionId: 'stored-a',
        created: false,
        method: 'session.resume',
      ),
      throwsFormatException,
    );
  });

  test('snapshot producer boundary rejects whitespace durable identity', () {
    expect(
      () => DesktopSessionSnapshot.fromJson(
        const {'session_id': 'runtime-a', 'stored_session_id': ' stored-a '},
        requestedStoredSessionId: 'stored-a',
        created: false,
        method: 'session.resume',
      ),
      throwsFormatException,
    );
  });

  test(
    'held frames from an older socket generation cannot be released by a newer proof',
    () {
      final coordinator = ReplayCoordinator();
      coordinator.quarantine('runtime-a');
      expect(
        coordinator.acceptLive(
          const SessionGatewayEvent('message.delta', 'runtime-a', 13, {
            'text': 'old-generation',
          }),
        ),
        ReplayLiveDisposition.held,
      );
      coordinator.mintRecoveryProof(
        connectionId: 'conn-a',
        durableSessionId: 'stored-a',
        runtimeSessionId: 'runtime-a',
        profile: 'profile-a',
        socketGeneration: 7,
        channel: _recoveryChannel,
        bindGeneration: 8,
        sessionGeneration: 9,
        turnGeneration: 10,
        replayEpoch: 'epoch-a',
        created: false,
        durableIdentityExplicit: true,
        identityAliasesConsistent: true,
        coverage: RecoveryDomain.values.toSet(),
        postSnapshotSequence: 12,
      );
      final newer = coordinator.mintRecoveryProof(
        connectionId: 'conn-a',
        durableSessionId: 'stored-a',
        runtimeSessionId: 'runtime-a',
        profile: 'profile-a',
        socketGeneration: 8,
        channel: _recoveryChannel,
        bindGeneration: 8,
        sessionGeneration: 9,
        turnGeneration: 10,
        replayEpoch: 'epoch-a',
        created: false,
        durableIdentityExplicit: true,
        identityAliasesConsistent: true,
        coverage: RecoveryDomain.values.toSet(),
        postSnapshotSequence: 12,
      );

      expect(
        coordinator.commitRecovery(
          newer,
          socketGeneration: 8,
          channel: _recoveryChannel,
          replayEpoch: 'epoch-a',
        ),
        isFalse,
      );
      expect(coordinator.takeCommittedRecoveryEvents('runtime-a'), isEmpty);
      expect(coordinator.isQuarantined('runtime-a'), isTrue);
    },
  );

  test('held overflow poisons the exact attempt and blocks later commit', () {
    final coordinator = ReplayCoordinator();
    coordinator.quarantine('runtime-a');
    for (var sequence = 2; sequence <= 65; sequence++) {
      expect(
        coordinator.acceptLive(
          SessionGatewayEvent('message.delta', 'runtime-a', sequence, const {}),
        ),
        ReplayLiveDisposition.held,
      );
    }
    expect(
      coordinator.acceptLive(
        const SessionGatewayEvent('message.delta', 'runtime-a', 66, {}),
      ),
      ReplayLiveDisposition.quarantined,
    );
    final proof = coordinator.mintRecoveryProof(
      connectionId: 'conn-a',
      durableSessionId: 'stored-a',
      runtimeSessionId: 'runtime-a',
      profile: 'profile-a',
      socketGeneration: 7,
      channel: _recoveryChannel,
      bindGeneration: 8,
      sessionGeneration: 9,
      turnGeneration: 10,
      replayEpoch: 'epoch-a',
      created: false,
      durableIdentityExplicit: true,
      identityAliasesConsistent: true,
      coverage: RecoveryDomain.values.toSet(),
      postSnapshotSequence: 1,
    );

    expect(
      coordinator.commitRecovery(
        proof,
        socketGeneration: 7,
        channel: _recoveryChannel,
        replayEpoch: 'epoch-a',
      ),
      isFalse,
    );
    expect(coordinator.takeCommittedRecoveryEvents('runtime-a'), isEmpty);
  });

  test(
    'global recovery runtime cap fails closed before the thirty-third hold',
    () {
      final coordinator = ReplayCoordinator();
      for (var index = 0; index < 32; index++) {
        final runtime = 'runtime-$index';
        coordinator.quarantine(runtime);
        expect(
          coordinator.acceptLive(
            SessionGatewayEvent('message.delta', runtime, 1, const {}),
          ),
          ReplayLiveDisposition.held,
        );
      }
      coordinator.quarantine('runtime-overflow');
      expect(
        coordinator.acceptLive(
          const SessionGatewayEvent('message.delta', 'runtime-overflow', 1, {}),
        ),
        ReplayLiveDisposition.quarantined,
      );
    },
  );

  test('legitimately minted proof becomes stale after epoch rotation', () {
    final coordinator = ReplayCoordinator();
    coordinator.quarantine('runtime-a');
    final proof = coordinator.mintRecoveryProof(
      connectionId: 'conn-a',
      durableSessionId: 'stored-a',
      runtimeSessionId: 'runtime-a',
      profile: 'profile-a',
      socketGeneration: 7,
      channel: _recoveryChannel,
      bindGeneration: 8,
      sessionGeneration: 9,
      turnGeneration: 10,
      replayEpoch: 'epoch-a',
      created: false,
      durableIdentityExplicit: true,
      identityAliasesConsistent: true,
      coverage: RecoveryDomain.values.toSet(),
      postSnapshotSequence: 12,
    );
    coordinator.rotateEpoch();

    expect(
      coordinator.commitRecovery(
        proof,
        socketGeneration: 7,
        channel: _recoveryChannel,
        replayEpoch: 'epoch-a',
      ),
      isFalse,
    );
  });

  test('snapshot copy preserves every identity and evidence field', () {
    const snapshot = DesktopSessionSnapshot(
      runtimeSessionId: 'runtime-copy',
      storedSessionId: 'stored-copy',
      storedSessionIdProvenance:
          DesktopStoredSessionIdProvenance.storedSessionId,
      created: false,
      lineageRootId: 'lineage-copy',
      identityAliasesConsistent: false,
      storedSessionIdentityExplicit: true,
      messagesProvided: true,
      messagesFullyParsed: false,
      messageCount: 7,
      hydrating: true,
      running: true,
      status: 'running',
      pendingClarifyProvided: true,
      raw: {'evidence': 'kept'},
    );

    final copy = snapshot.withoutPersistedMessages();

    expect(copy.runtimeSessionId, snapshot.runtimeSessionId);
    expect(copy.storedSessionId, snapshot.storedSessionId);
    expect(copy.storedSessionIdProvenance, snapshot.storedSessionIdProvenance);
    expect(copy.created, snapshot.created);
    expect(copy.lineageRootId, snapshot.lineageRootId);
    expect(copy.identityAliasesConsistent, snapshot.identityAliasesConsistent);
    expect(
      copy.storedSessionIdentityExplicit,
      snapshot.storedSessionIdentityExplicit,
    );
    expect(copy.messagesProvided, isFalse);
    expect(copy.messagesFullyParsed, snapshot.messagesFullyParsed);
    expect(copy.messageCount, snapshot.messageCount);
    expect(copy.hydrating, snapshot.hydrating);
    expect(copy.running, snapshot.running);
    expect(copy.status, snapshot.status);
    expect(copy.pendingClarifyProvided, snapshot.pendingClarifyProvided);
    expect(copy.raw, same(snapshot.raw));
  });

  for (final operation
      in <
            String,
            Future<DesktopPromptResponse> Function(
              TuiGatewayClient,
              EphemeralSensitiveValue,
            )
          >{
            'sudo.respond': (client, value) =>
                client.respondToSudo('sudo-a', value),
            'secret.respond': (client, value) =>
                client.respondToSecret('secret-a', value),
          }
          .entries) {
    test(
      '${operation.key} sanitizes connect/auth failures end to end',
      () async {
        const marker = 'PRIVATE_CONNECT_AUTH_MARKER';
        final client = _authFailingClient(marker);
        addTearDown(client.close);
        final value = EphemeralSensitiveValue('PRIVATE_VALUE_MARKER');

        Object? failure;
        StackTrace? failureStack;
        try {
          await operation.value(client, value);
        } catch (error, stackTrace) {
          failure = error;
          failureStack = stackTrace;
        }

        expect(
          failure,
          isA<TuiGatewayRpcError>()
              .having((error) => error.method, 'method', operation.key)
              .having(
                (error) => error.message,
                'message',
                'Sensitive response transport failed',
              )
              .having((error) => error.data, 'data', isEmpty),
        );
        expect(failure.toString(), isNot(contains(marker)));
        expect(failure.toString(), isNot(contains('PRIVATE_VALUE_MARKER')));
        expect(failureStack.toString(), isNot(contains(marker)));
        expect(
          failureStack.toString(),
          isNot(contains('PRIVATE_VALUE_MARKER')),
        );
        expect(value.isDisposed, isTrue);
        expect(value.hasValue, isFalse);
        expect(value.disposeAttempts, 1);
      },
    );
  }
}
