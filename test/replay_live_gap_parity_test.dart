import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/json_rpc_wire.dart';
import 'package:hermes_android/core/services/replay_coordinator.dart';

/// Desktop parity of hunk 1b (hermes-agent 3b421578,
/// apps/shared/src/json-rpc-gateway.ts:478-501 `handleEvent` -> `recordSeq`
/// -> `dispatchEvent`): a live frame newer than the session watermark
/// advances it and dispatches, with or without a gap (no quarantine). The
/// frames lost in the gap are the reconnect replay's job (`fetchReplay`,
/// :558-611).
/// The second test pins Console's base behaviour for a live frame at or below
/// the watermark (ignored); hunk 1b does not change it. It is NOT Desktop's
/// live path (handleEvent dispatches without that filter); Desktop's
/// `dispatchIfNewer` (:724-742) applies to replayed / parked frames only.
void main() {
  test('a live seq gap advances the watermark and dispatches (no quarantine)',
      () {
    final coordinator = ReplayCoordinator();
    expect(
      coordinator.acceptLive(
        const SessionGatewayEvent('message.start', 'runtime-a', 8, {}),
      ),
      ReplayLiveDisposition.dispatch,
    );
    // seq 9 and 10 never reached this socket (pruned viewer).
    expect(
      coordinator.acceptLive(
        const SessionGatewayEvent('message.start', 'runtime-a', 11, {}),
      ),
      ReplayLiveDisposition.dispatch,
    );
    expect(coordinator.isQuarantined('runtime-a'), isFalse);
    expect(coordinator.watermarks['runtime-a'], 11);
    expect(
      coordinator.acceptLive(
        const SessionGatewayEvent('message.delta', 'runtime-a', 12, {
          'text': 'live',
        }),
      ),
      ReplayLiveDisposition.dispatch,
    );
    expect(coordinator.watermarks['runtime-a'], 12);
  });

  test('a live frame at or below the watermark is dropped once dispatched', () {
    final coordinator = ReplayCoordinator();
    coordinator.acceptLive(
      const SessionGatewayEvent('message.delta', 'runtime-a', 5, {'text': 'a'}),
    );
    expect(
      coordinator.acceptLive(
        const SessionGatewayEvent('message.delta', 'runtime-a', 5, {
          'text': 'a',
        }),
      ),
      ReplayLiveDisposition.ignored,
    );
    expect(
      coordinator.acceptLive(
        const SessionGatewayEvent('message.delta', 'runtime-a', 4, {
          'text': 'old',
        }),
      ),
      ReplayLiveDisposition.ignored,
    );
    expect(coordinator.watermarks['runtime-a'], 5);
  });
}
