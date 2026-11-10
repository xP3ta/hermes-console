import 'package:fake_async/fake_async.dart'; // ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/herdr_agents.dart';
import 'package:hermes_android/core/services/herdr_status.dart';

import 'support/fake_herdr_server.dart';

class _Store implements HerdrAgentsStore {
  final List<String> remembered = [];
  final List<String> pinned = [];
  String? kind;

  @override
  bool get hintDismissed => false;

  @override
  Future<void> dismissHint() async {}

  @override
  List<String> get folders => remembered;

  @override
  Future<void> rememberFolder(String folder) async {
    remembered
      ..remove(folder)
      ..insert(0, folder);
  }

  @override
  List<String> get favorites => pinned;

  @override
  Future<void> toggleFavorite(String folder) async {
    if (!pinned.remove(folder)) pinned.add(folder);
  }

  @override
  String? get lastKind => kind;

  @override
  Future<void> setLastKind(String value) async => kind = value;
}

void main() {
  late FakeHerdrServer server;
  late _Store store;
  var now = DateTime(2026, 11, 2, 10);

  HerdrAgentsController make(FakeAsync async) => HerdrAgentsController(
    run: server.call,
    store: store,
    now: () => now.add(async.elapsed),
    startRetry: const Duration(milliseconds: 10),
  );

  setUp(() {
    server = FakeHerdrServer(
      agents: [
        FakeAgent('w1:p1', 'claude', HerdrAgentStatus.idle, workspace: 'main'),
      ],
    );
    store = _Store();
    now = DateTime(2026, 11, 2, 10);
  });

  test('a quick start: the row says «starting» and then becomes the agent', () {
    fakeAsync((async) {
      final c = make(async)..setActive(true);
      async.flushMicrotasks();
      HerdrActionResult? result;
      c.createAgent(folder: '/srv/app', kind: 'codex').then((r) => result = r);
      async.flushMicrotasks();

      // Back as soon as the workspace exists, with the start under way.
      expect(result, HerdrActionResult.ok);
      expect(c.createdPaneId, 'w4:p1');
      expect(store.remembered, ['/srv/app']);
      expect(store.kind, 'codex');
      final start = server.herdrCalls
          .map(shellWords)
          .firstWhere((w) => w[2] == 'start');
      expect(start.sublist(1), [
        'agent',
        'start',
        'codex',
        '--kind',
        'codex',
        '--pane',
        'w4:p1',
        '--timeout',
        '8000',
      ]);
      async.elapse(const Duration(seconds: 2));
      expect(c.startJobs, isEmpty);
      expect(c.allRows.map((r) => r.paneId), contains('w4:p1'));
      expect(server.startCalls, 1);
      c.dispose();
    });
  });

  test(
    'a slow harness is no error: Herdr gives up at 8 s, it starts at 12 s',
    () {
      fakeAsync((async) {
        server
          ..startError = 'agent_start_timeout_0_9_5.json'
          ..startCommandAfter = const Duration(seconds: 8)
          ..agentAppearsAfter = const Duration(seconds: 12);
        final c = make(async)..setActive(true);
        async.flushMicrotasks();
        c.createAgent(folder: '/srv/app', kind: 'claude');
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 3));
        expect(c.startJobs.single.phase, HerdrStartPhase.starting);
        // The command has answered with Herdr's own timeout: still no alarm.
        async.elapse(const Duration(seconds: 7));
        expect(c.startJobs.single.phase, HerdrStartPhase.starting);
        expect(c.startJobs.single.failed, isFalse);

        async.elapse(const Duration(seconds: 4));
        expect(c.startJobs, isEmpty);
        expect(c.allRows.any((r) => r.paneId == 'w4:p1'), isTrue);
        // Nothing was started twice.
        expect(server.startCalls, 1);
        c.dispose();
      });
    },
  );

  test('an agent that stops at its first question is running, not failed', () {
    fakeAsync((async) {
      server.startError = 'agent_start_not_ready_0_9_5.json';
      final c = make(async)..setActive(true);
      async.flushMicrotasks();
      c.createAgent(folder: '/srv/app', kind: 'claude');
      async.elapse(const Duration(seconds: 3));

      expect(c.startJobs, isEmpty);
      final row = c.allRows.firstWhere((r) => r.paneId == 'w4:p1');
      expect(row.status, HerdrAgentStatus.blocked);
      expect(c.needsYou, 1);
      c.dispose();
    });
  });

  test('a real failure waits the deadline, then says what the pane said', () {
    fakeAsync((async) {
      server
        ..startError = 'agent_start_timeout_0_9_5.json'
        ..agentAppearsAfter = null;
      final c = make(async)..setActive(true);
      async.flushMicrotasks();
      c.createAgent(folder: '/srv/app', kind: 'pi');
      async.elapse(const Duration(seconds: 25));
      expect(c.startJobs.single.phase, HerdrStartPhase.starting);

      async.elapse(const Duration(seconds: 7));
      final job = c.startJobs.single;
      expect(job.failed, isTrue);
      expect(job.kind, 'pi');
      expect(job.reason, contains('pi: command not found'));
      expect(job.reason, isNot(contains('\x1b')));
      // The pane was read once, with the read-only command.
      final reads = server.herdrCalls
          .map(shellWords)
          .where((w) => w[1] == 'pane' && w[2] == 'read');
      expect(reads.length, 1);
      expect(reads.single[3], 'w4:p1');
      c.dispose();
    });
  });

  test('with an empty pane the reason is Herdr\'s own sentence, cleaned', () {
    fakeAsync((async) {
      server
        ..startError = 'agent_start_timeout_0_9_5.json'
        ..agentAppearsAfter = null
        ..paneScreens['w4:p1'] = '\x1b[31m\x1b[0m';
      final c = make(async)..setActive(true);
      async.flushMicrotasks();
      c.createAgent(folder: '/srv/app', kind: 'pi');
      async.elapse(const Duration(seconds: 32));
      expect(c.startJobs.single.reason, 'timed out waiting for agent startup');
      c.dispose();
    });
  });

  test(
    'an agent later than the deadline replaces the failure, not joins it',
    () {
      fakeAsync((async) {
        server
          ..startError = 'agent_start_timeout_0_9_5.json'
          ..agentAppearsAfter = const Duration(seconds: 40);
        final c = make(async)..setActive(true);
        async.flushMicrotasks();
        c.createAgent(folder: '/srv/app', kind: 'claude');
        async.elapse(const Duration(seconds: 32));
        expect(c.startJobs.single.failed, isTrue);
        expect(c.allRows.any((r) => r.paneId == 'w4:p1'), isFalse);

        // The slow harness comes up after all: one row, no leftover alarm.
        async.elapse(const Duration(seconds: 12));
        expect(c.startJobs, isEmpty);
        expect(c.allRows.any((r) => r.paneId == 'w4:p1'), isTrue);
        expect(server.startCalls, 1);
        c.dispose();
      });
    },
  );

  test('a start that is retried by hand reuses the workspace', () {
    fakeAsync((async) {
      server
        ..startError = 'agent_start_timeout_0_9_5.json'
        ..agentAppearsAfter = null;
      final c = make(async)..setActive(true);
      async.flushMicrotasks();
      c.createAgent(folder: '/srv/app', kind: 'pi');
      async.elapse(const Duration(seconds: 32));
      expect(c.startJobs.single.failed, isTrue);

      server
        ..startError = null
        ..agentAppearsAfter = const Duration(seconds: 3);
      c.retryStart('w4:p1');
      async.flushMicrotasks();
      expect(c.startJobs.single.failed, isFalse);
      async.elapse(const Duration(seconds: 5));
      expect(c.startJobs, isEmpty);
      expect(server.startCalls, 2);
      // One workspace only: no second `workspace create`.
      expect(server.created.length, 1);
      c.dispose();
    });
  });

  test('«pane busy» is retried once, and only when no agent is there', () {
    fakeAsync((async) {
      server.startFailures = 1;
      final c = make(async)..setActive(true);
      async.flushMicrotasks();
      c.createAgent(folder: '/srv/app', kind: 'codex');
      async.elapse(const Duration(seconds: 3));
      expect(server.startCalls, 2);
      expect(c.startJobs, isEmpty);

      // Always busy: one retry, not a loop, and the deadline decides.
      server
        ..startFailures = 99
        ..agentAppearsAfter = null;
      c.createAgent(folder: '/srv/app', kind: 'codex');
      async.elapse(const Duration(seconds: 3));
      expect(server.startCalls, 4);
      c.dispose();
    });
  });

  test('a workspace closed meanwhile drops its job without noise', () {
    fakeAsync((async) {
      server
        ..startError = 'agent_start_timeout_0_9_5.json'
        ..agentAppearsAfter = null;
      final c = make(async)..setActive(true);
      async.flushMicrotasks();
      c.createAgent(folder: '/srv/app', kind: 'codex');
      async.elapse(const Duration(seconds: 3));
      expect(c.startJobs, hasLength(1));
      server.created.clear();
      async.elapse(const Duration(seconds: 3));
      expect(c.startJobs, isEmpty);
      c.dispose();
    });
  });

  test('a failed start can be dismissed; the workspace stays', () {
    fakeAsync((async) {
      server
        ..startError = 'agent_start_timeout_0_9_5.json'
        ..agentAppearsAfter = null;
      final c = make(async)..setActive(true);
      async.flushMicrotasks();
      c.createAgent(folder: '/srv/app', kind: 'pi');
      async.elapse(const Duration(seconds: 32));
      c.dismissStart('w4:p1');
      expect(c.startJobs, isEmpty);
      expect(server.created.length, 1);
      c.dispose();
    });
  });

  test('a kind the app does not offer, or a bad folder, leaves nothing', () {
    fakeAsync((async) {
      final c = make(async)..setActive(true);
      async.flushMicrotasks();
      server.commands.clear();
      HerdrActionResult? kind;
      HerdrActionResult? folder;
      c.createAgent(folder: '/srv/app', kind: 'rm -rf').then((r) => kind = r);
      c.createAgent(folder: 'relative', kind: 'codex').then((r) => folder = r);
      async.flushMicrotasks();
      expect(kind, HerdrActionResult.invalid);
      expect(folder, HerdrActionResult.invalid);
      expect(server.herdrCalls, isEmpty);
      c.dispose();
    });
  });

  test('the workspace label is the one typed, cleaned, else the folder', () {
    fakeAsync((async) {
      final c = make(async)..setActive(true);
      async.flushMicrotasks();
      c.createAgent(
        folder: '/srv/app',
        kind: 'codex',
        label: '  -my \$(x) ws ',
      );
      async.flushMicrotasks();
      final create = server.herdrCalls
          .map(shellWords)
          .firstWhere((w) => w[1] == 'workspace');
      expect(create[create.indexOf('--label') + 1], 'my --x- ws');
      expect(herdrWorkspaceLabel('---'), isNull);
      expect(herdrWorkspaceLabel(null), isNull);
      expect(herdrWorkspaceLabel('x' * 80)!.length, 40);
      c.dispose();
    });
  });

  test('a prompt shows «working» at once and reads again soon', () {
    fakeAsync((async) {
      server.agents[0].status = HerdrAgentStatus.idle;
      final c = make(async)..setActive(true);
      async.flushMicrotasks();
      c.openDetail('w1:p1');
      async.flushMicrotasks();
      expect(c.detailRow!.status, HerdrAgentStatus.idle);
      final reads = server.readCalls;

      c.sendPrompt('w1:p1', 'hello');
      async.flushMicrotasks();
      expect(c.detailRow!.status, HerdrAgentStatus.working);
      // The fake still says idle: the app does not wait for it.
      async.elapse(const Duration(seconds: 1));
      expect(server.readCalls, greaterThan(reads));
      async.elapse(const Duration(seconds: 5));
      expect(c.detailRow!.status, HerdrAgentStatus.idle);
      c.dispose();
    });
  });

  test('workspaces keep their agents and put the ones waiting first', () {
    server.agents.addAll([
      FakeAgent(
        'w3:p1',
        'codex',
        HerdrAgentStatus.blocked,
        workspace: 'web',
        cwd: '/srv/web',
      ),
      FakeAgent(
        'w4:p1',
        'hermes',
        HerdrAgentStatus.working,
        workspace: 'web',
        cwd: '/srv/web',
      ),
    ]);
    server.focusedWorkspace = 'w1';
    final snapshot = HerdrSnapshot.fromJson(
      server.snapshotJson()['snapshot']! as Map<String, Object?>,
    );
    final groups = herdrWorkspaceGroups(snapshot);
    expect(groups.map((g) => g.workspace.label), ['web', 'main', 'shell']);
    expect(groups.first.rows.map((r) => r.paneId), ['w3:p1', 'w4:p1']);
    expect(groups.first.status, HerdrAgentStatus.blocked);
    expect(groups[1].workspace.focused, isTrue);
    expect(groups.last.hasAgents, isFalse);

    // Filter: shells disappear; search matches the folder or the workspace.
    final working = herdrWorkspaceGroups(
      snapshot,
      filter: HerdrStatusFilter.working,
    );
    expect(working.map((g) => g.workspace.label), ['web']);
    expect(working.single.rows.single.paneId, 'w4:p1');
    expect(
      herdrWorkspaceGroups(
        snapshot,
        query: 'PROYECTOS',
      ).map((g) => g.workspace.label),
      ['main'],
    );
    expect(
      herdrWorkspaceGroups(snapshot, query: 'web').single.rows,
      hasLength(2),
    );
    expect(herdrWorkspaceGroups(snapshot, query: 'nope'), isEmpty);
  });
}
