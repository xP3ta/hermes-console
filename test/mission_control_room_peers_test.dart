import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';

void main() {
  test('peer connections are probed at the same time', () async {
    final gates = {
      for (final c in ['a', 'b', 'c']) c: Completer<void>(),
    };
    var inFlight = 0;
    var maxInFlight = 0;

    final gathering = gatherRoomPeerCandidates<String, String>(
      connections: gates.keys,
      probeConnection: (connection) async {
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await gates[connection]!.future;
        inFlight--;
        return ['$connection-1', '$connection-2'];
      },
      keyOf: (candidate) => candidate,
    );
    await Future<void>.delayed(Duration.zero);
    // Before: one connection at a time (3 serial probe chains).
    expect(maxInFlight, 3);
    // Finish out of order: results still follow connection order.
    gates['c']!.complete();
    gates['a']!.complete();
    gates['b']!.complete();

    expect(await gathering, ['a-1', 'a-2', 'b-1', 'b-2', 'c-1', 'c-2']);
  });

  test('a failing connection contributes nothing; first key wins', () async {
    final result = await gatherRoomPeerCandidates<String, String>(
      connections: const ['a', 'down', 'b'],
      probeConnection: (connection) async {
        if (connection == 'down') throw StateError('offline');
        return ['shared', connection];
      },
      keyOf: (candidate) => candidate,
    );

    expect(result, ['shared', 'a', 'b']);
  });
}
