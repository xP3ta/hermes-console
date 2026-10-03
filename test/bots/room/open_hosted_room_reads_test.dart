import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/open_hosted_room_reads.dart';

import '../../support/spec070_fixtures.dart';

/// One read on the wire: its generation and the answer it is waiting for.
typedef _Flight = ({
  int generation,
  Completer<HostedGroupWorkspaceReadback> answer,
});

final class _Harness {
  int live = 1;
  final flights = <_Flight>[];
  final proven = <int>[];
  late final reads = OpenHostedRoomReads(
    capabilities: () async => spec070Capabilities(generation: live),
    readUnder: (room, generation) {
      final answer = Completer<HostedGroupWorkspaceReadback>();
      flights.add((generation: generation, answer: answer));
      return answer.future;
    },
    onProven: (capabilities) => proven.add(capabilities.generation),
  );

  void answer(int index, {int? generation}) {
    final flight = flights[index];
    flight.answer.complete(
      HostedGroupWorkspaceReadback(
        room: spec070Room(),
        log: null,
        capabilityGeneration: generation ?? flight.generation,
      ),
    );
  }
}

void main() {
  test('each read follows the generation live at that moment', () async {
    final h = _Harness();
    final first = h.reads.read(spec070Room());
    await pumpEventQueue();
    h.answer(0);
    expect((await first).capabilityGeneration, 1);

    h.live = 2; // the socket reconnected
    final second = h.reads.read(spec070Room());
    await pumpEventQueue();
    h.answer(1);
    expect((await second).capabilityGeneration, 2);
    expect(h.flights.map((f) => f.generation), [1, 2]);
    expect(h.proven, [1, 2]);
    expect(h.reads.newestGeneration, 2);
  });

  test('an old read landing after a newer one started is discarded', () async {
    final h = _Harness();
    final old = h.reads.read(spec070Room());
    await pumpEventQueue();
    h.live = 2;
    final fresh = h.reads.read(spec070Room());
    await pumpEventQueue();
    h.answer(1);
    expect((await fresh).capabilityGeneration, 2);

    h.answer(0); // the read sent on the closed socket lands last
    await expectLater(old, throwsStateError);
    expect(h.proven, [2], reason: 'generation 1 never becomes current again');
    expect(h.reads.newestGeneration, 2);
  });

  test('an old read is discarded even before the newer one lands', () async {
    final h = _Harness();
    final old = h.reads.read(spec070Room());
    await pumpEventQueue();
    h.live = 2;
    unawaited(h.reads.read(spec070Room()).then((_) {}, onError: (_) {}));
    await pumpEventQueue();
    h.answer(0);
    await expectLater(old, throwsStateError);
    expect(h.proven, isEmpty);
  });

  test('capabilities older than the newest generation read nothing', () async {
    final h = _Harness()..live = 2;
    final fresh = h.reads.read(spec070Room());
    await pumpEventQueue();
    h.answer(0);
    await fresh;
    h.live = 1; // a capability answer from the closed socket
    await expectLater(h.reads.read(spec070Room()), throwsStateError);
    expect(h.flights, hasLength(1), reason: 'nothing read under 1');
    expect(h.reads.supersedes(1), isTrue);
    expect(h.reads.supersedes(2), isFalse);
    expect(h.proven, [2]);
  });

  test('an answer bound to another generation is refused', () async {
    final h = _Harness();
    final read = h.reads.read(spec070Room());
    await pumpEventQueue();
    h.answer(0, generation: 7);
    await expectLater(read, throwsStateError);
    expect(h.proven, isEmpty);
  });

  test('a generation without groups.state reads nothing', () async {
    final reads = <int>[];
    final reader = OpenHostedRoomReads(
      capabilities: () async => GroupsCapabilities.tryParse(
        {
          'protocol_version': 2,
          'driver': true,
          'methods': ['groups.capabilities', 'groups.list'],
          'max_log_limit': 50,
        },
        connectionId: 'conn-home',
        generation: 1,
      )!,
      readUnder: (room, generation) {
        reads.add(generation);
        throw StateError('must not read');
      },
    );
    await expectLater(reader.read(spec070Room()), throwsStateError);
    expect(reads, isEmpty);
  });
}
