import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/json_rpc_wire.dart';
import 'package:hermes_android/core/services/recovery_proof.dart';
import 'package:hermes_android/core/services/replay_coordinator.dart';

void main() {
  test('recovery authority rejects anything but the exact channel', () {
    final coordinator = ReplayCoordinator()..quarantine('runtime-a');
    final channel = Object();
    final proof = coordinator.mintRecoveryProof(
      connectionId: 'connection-a',
      durableSessionId: 'durable-a',
      runtimeSessionId: 'runtime-a',
      profile: 'profile-a',
      socketGeneration: 1,
      channel: channel,
      bindGeneration: 2,
      sessionGeneration: 3,
      turnGeneration: 4,
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
        socketGeneration: 1,
        channel: Object(),
        replayEpoch: 'epoch-a',
      ),
      isFalse,
    );
    expect(coordinator.isQuarantined('runtime-a'), isTrue);
  });

  test('epoch rotation permits a fresh exact-channel recovery attempt', () {
    final coordinator = ReplayCoordinator()..quarantine('runtime-a');
    final oldChannel = Object();
    coordinator.mintRecoveryProof(
      connectionId: 'connection-a',
      durableSessionId: 'durable-a',
      runtimeSessionId: 'runtime-a',
      profile: 'profile-a',
      socketGeneration: 1,
      channel: oldChannel,
      bindGeneration: 2,
      sessionGeneration: 3,
      turnGeneration: 4,
      replayEpoch: 'epoch-a',
      created: false,
      durableIdentityExplicit: true,
      identityAliasesConsistent: true,
      coverage: RecoveryDomain.values.toSet(),
      postSnapshotSequence: 1,
    );

    coordinator.rotateEpoch();
    final newChannel = Object();
    expect(
      coordinator.acceptLive(
        const SessionGatewayEvent('message.delta', 'runtime-a', 2, {}),
        socketGeneration: 2,
        channel: newChannel,
        replayEpoch: 'epoch-b',
      ),
      ReplayLiveDisposition.held,
    );
  });

  test(
    'transport retirement permits a fresh exact-channel recovery attempt',
    () {
      final coordinator = ReplayCoordinator()..quarantine('runtime-a');
      final oldChannel = Object();
      coordinator.mintRecoveryProof(
        connectionId: 'connection-a',
        durableSessionId: 'durable-a',
        runtimeSessionId: 'runtime-a',
        profile: 'profile-a',
        socketGeneration: 1,
        channel: oldChannel,
        bindGeneration: 2,
        sessionGeneration: 3,
        turnGeneration: 4,
        replayEpoch: 'epoch-a',
        created: false,
        durableIdentityExplicit: true,
        identityAliasesConsistent: true,
        coverage: RecoveryDomain.values.toSet(),
        postSnapshotSequence: 1,
      );

      coordinator.retireTransport(generation: 1, channel: oldChannel);
      final newChannel = Object();
      expect(
        coordinator.acceptLive(
          const SessionGatewayEvent('message.delta', 'runtime-a', 2, {}),
          socketGeneration: 2,
          channel: newChannel,
          replayEpoch: 'epoch-b',
        ),
        ReplayLiveDisposition.held,
      );
    },
  );

  test('replay overflow abandonment keeps the global held budget balanced', () {
    final coordinator = ReplayCoordinator();
    final replayChannel = Object();
    expect(
      coordinator.acceptLive(
        const SessionGatewayEvent('message.delta', 'stale-runtime', 1, {}),
      ),
      ReplayLiveDisposition.dispatch,
    );
    coordinator.beginReconnect(
      generation: 1,
      channel: replayChannel,
      epoch: 'epoch-a',
    );
    for (var sequence = 2; sequence <= 65; sequence++) {
      expect(
        coordinator.acceptLive(
          SessionGatewayEvent(
            'message.delta',
            'stale-runtime',
            sequence,
            const {},
          ),
          socketGeneration: 1,
          channel: replayChannel,
          replayEpoch: 'epoch-a',
        ),
        ReplayLiveDisposition.held,
      );
    }
    expect(
      coordinator.acceptLive(
        const SessionGatewayEvent('message.delta', 'stale-runtime', 66, {}),
        socketGeneration: 1,
        channel: replayChannel,
        replayEpoch: 'epoch-a',
      ),
      ReplayLiveDisposition.quarantined,
    );

    final recoveryChannel = Object();
    final proof = coordinator.mintRecoveryProof(
      connectionId: 'connection-a',
      durableSessionId: 'durable-a',
      runtimeSessionId: 'stale-runtime',
      profile: 'profile-a',
      socketGeneration: 2,
      channel: recoveryChannel,
      bindGeneration: 2,
      sessionGeneration: 3,
      turnGeneration: 4,
      replayEpoch: 'epoch-b',
      created: false,
      durableIdentityExplicit: true,
      identityAliasesConsistent: true,
      coverage: RecoveryDomain.values.toSet(),
      postSnapshotSequence: 1,
    );
    expect(
      coordinator.commitRecovery(
        proof,
        socketGeneration: 2,
        channel: recoveryChannel,
        replayEpoch: 'epoch-b',
      ),
      isTrue,
    );

    coordinator.quarantine('stale-runtime');
    for (var sequence = 1; sequence <= 64; sequence++) {
      expect(
        coordinator.acceptLive(
          SessionGatewayEvent(
            'message.delta',
            'stale-runtime',
            sequence,
            const {},
          ),
        ),
        ReplayLiveDisposition.held,
      );
    }
    for (var runtimeIndex = 0; runtimeIndex < 30; runtimeIndex++) {
      final runtime = 'held-runtime-$runtimeIndex';
      coordinator.quarantine(runtime);
      for (var sequence = 1; sequence <= 64; sequence++) {
        expect(
          coordinator.acceptLive(
            SessionGatewayEvent('message.delta', runtime, sequence, const {}),
          ),
          ReplayLiveDisposition.held,
        );
      }
    }
    coordinator.quarantine('last-runtime');
    expect(
      coordinator.acceptLive(
        const SessionGatewayEvent('message.delta', 'last-runtime', 1, {}),
      ),
      ReplayLiveDisposition.held,
    );
  });
}
