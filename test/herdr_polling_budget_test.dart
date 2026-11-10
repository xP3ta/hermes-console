// How often the app asks the server, counted against the fake server on a
// virtual clock. The numbers printed (BUDGET …) are what the manual quotes.
import 'package:fake_async/fake_async.dart'; // ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/herdr_agents.dart';
import 'package:hermes_android/core/services/herdr_status.dart';

import 'support/fake_herdr_server.dart';

class _Store implements HerdrAgentsStore {
  @override
  bool get hintDismissed => false;
  @override
  Future<void> dismissHint() async {}
  @override
  List<String> get folders => const [];
  @override
  Future<void> rememberFolder(String folder) async {}
  @override
  List<String> get favorites => const [];
  @override
  Future<void> toggleFavorite(String folder) async {}
  @override
  String? get lastKind => null;
  @override
  Future<void> setLastKind(String kind) async {}
}

FakeHerdrServer _server(HerdrAgentStatus status) => FakeHerdrServer(
  agents: [FakeAgent('w1:p1', 'claude', status, workspace: 'main')],
);

/// Snapshots and screen reads in [seconds] of virtual time.
({int snapshots, int reads}) _count(
  FakeHerdrServer server, {
  required int seconds,
  bool detail = false,
  bool changing = false,
}) {
  var snapshots = 0;
  var reads = 0;
  fakeAsync((async) {
    final c = HerdrAgentsController(
      run: server.call,
      store: _Store(),
      now: () => DateTime(2026, 11, 2).add(async.elapsed),
    )..setActive(true);
    async.flushMicrotasks();
    if (detail) {
      c.openDetail('w1:p1');
      async.flushMicrotasks();
    }
    for (var s = 0; s < seconds; s++) {
      if (changing) server.screens['w1:p1'] = 'line $s';
      async.elapse(const Duration(seconds: 1));
    }
    snapshots = server.snapshotCalls;
    reads = server.readCalls;
    c.dispose();
  });
  return (snapshots: snapshots, reads: reads);
}

void main() {
  test('the list: 10 s at rest, 3 s with an agent working', () {
    final idle = _count(_server(HerdrAgentStatus.idle), seconds: 60);
    final busy = _count(_server(HerdrAgentStatus.working), seconds: 60);
    // ignore: avoid_print
    print(
      'BUDGET list 60 s: idle ${idle.snapshots}, working ${busy.snapshots}',
    );
    expect(idle.snapshots, inInclusiveRange(6, 7));
    expect(busy.snapshots, inInclusiveRange(20, 21));
    expect(idle.reads + busy.reads, 0);
  });

  test('the open agent: a second apart while it changes, then it relaxes', () {
    final moving = _count(
      _server(HerdrAgentStatus.working),
      seconds: 30,
      detail: true,
      changing: true,
    );
    final still = _count(
      _server(HerdrAgentStatus.working),
      seconds: 30,
      detail: true,
    );
    final resting = _count(
      _server(HerdrAgentStatus.idle),
      seconds: 30,
      detail: true,
    );
    // ignore: avoid_print
    print(
      'BUDGET detail 30 s: changing ${moving.reads} reads, '
      'working-but-still ${still.reads}, idle ${resting.reads}',
    );
    expect(moving.reads, inInclusiveRange(29, 31));
    expect(still.reads, lessThan(moving.reads));
    expect(resting.reads, lessThan(still.reads));
  });

  test(
    'a start in progress is looked at every second, no longer than needed',
    () {
      final server = _server(HerdrAgentStatus.idle)
        ..agentAppearsAfter = const Duration(seconds: 12)
        ..startCommandAfter = const Duration(seconds: 8)
        ..startError = 'agent_start_timeout_0_9_5.json';
      var snapshotsDuring = 0;
      var snapshotsAfter = 0;
      fakeAsync((async) {
        final c = HerdrAgentsController(
          run: server.call,
          store: _Store(),
          now: () => DateTime(2026, 11, 2).add(async.elapsed),
        )..setActive(true);
        async.flushMicrotasks();
        c.createAgent(folder: '/srv/web', kind: 'claude');
        async.flushMicrotasks();
        final before = server.snapshotCalls;
        async.elapse(const Duration(seconds: 13));
        snapshotsDuring = server.snapshotCalls - before;
        expect(c.startJobs, isEmpty);
        final settled = server.snapshotCalls;
        async.elapse(const Duration(seconds: 30));
        snapshotsAfter = server.snapshotCalls - settled;
        c.dispose();
      });
      // ignore: avoid_print
      print(
        'BUDGET start: $snapshotsDuring looks in the first 13 s, '
        '$snapshotsAfter in the next 30 s',
      );
      expect(snapshotsDuring, inInclusiveRange(12, 14));
      expect(snapshotsAfter, lessThanOrEqualTo(10));
    },
  );

  test('hidden or in the background: nothing at all', () {
    final server = _server(HerdrAgentStatus.working);
    fakeAsync((async) {
      final c = HerdrAgentsController(run: server.call, store: _Store())
        ..setActive(true);
      async.flushMicrotasks();
      c.openDetail('w1:p1');
      async.flushMicrotasks();
      c.setActive(false);
      final calls = server.commands.length;
      async.elapse(const Duration(minutes: 30));
      expect(server.commands.length, calls);
      c.dispose();
    });
  });
}
