// The Git screen's state, as Hermes Desktop's review store
// (`apps/desktop/src/store/review.ts`): reads, phases, stale-read guards,
// the local commit behind a busy flag, and the notch's status cache.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/git_review.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/git_review_controller.dart';

import 'support/fake_git_review_gateway.dart';

const _files = [
  GitReviewFile(path: 'lib/a.dart', added: 16, status: 'M'),
  GitReviewFile(path: 'test/b_test.dart', added: 19, status: '?'),
];

({GitReviewController controller, FakeGitReviewGateway gateway}) _make({
  GitRepoStatus? status = const GitRepoStatus(
    branch: 'feat/x',
    changed: 2,
    added: 35,
  ),
  List<GitReviewFile> files = _files,
  bool writes = true,
  GitStatusCache? cache,
}) {
  final gateway = FakeGitReviewGateway(
    status: status,
    files: files,
    writes: writes,
  );
  final controller = GitReviewController(
    gateway: gateway,
    connectionId: 'c1',
    repoPath: '/srv/repo',
    cache: cache ?? GitStatusCache.instance,
  );
  addTearDown(controller.dispose);
  return (controller: controller, gateway: gateway);
}

void main() {
  setUp(GitStatusCache.instance.clear);

  group('reads', () {
    test('a repository with changes is ready with its files', () async {
      final h = _make();
      expect(h.controller.phase, GitReviewPhase.loading);
      await h.controller.refresh();
      expect(h.controller.phase, GitReviewPhase.ready);
      expect(h.controller.status!.branch, 'feat/x');
      expect(h.controller.files.map((f) => f.path), [
        'lib/a.dart',
        'test/b_test.dart',
      ]);
      expect(h.controller.loading, isFalse);
      expect(h.gateway.calls, ['status', 'list']);
    });

    test('no changes: ready with an empty list', () async {
      final h = _make(files: const []);
      await h.controller.refresh();
      expect(h.controller.phase, GitReviewPhase.ready);
      expect(h.controller.hasFiles, isFalse);
    });

    test('not a repository', () async {
      final h = _make(status: null);
      await h.controller.refresh();
      expect(h.controller.phase, GitReviewPhase.notRepo);
      expect(h.controller.files, isEmpty);
      expect(GitStatusCache.instance.knows('c1', '/srv/repo'), isTrue);
      expect(GitStatusCache.instance.statusOf('c1', '/srv/repo'), isNull);
    });

    test('an older Hermes without git routes is unsupported', () async {
      final h = _make();
      h.gateway.readFailure = const DesktopControlFailure(
        DesktopControlFailureKind.unsupported,
        code: 404,
      );
      await h.controller.refresh();
      expect(h.controller.phase, GitReviewPhase.unsupported);
    });

    test('no network: failed, and a retry recovers', () async {
      final h = _make();
      h.gateway.readFailure = const DesktopControlFailure(
        DesktopControlFailureKind.unavailable,
      );
      await h.controller.refresh();
      expect(h.controller.phase, GitReviewPhase.failed);
      expect(h.controller.failure, isA<DesktopControlFailure>());
      h.gateway.readFailure = null;
      await h.controller.refresh();
      expect(h.controller.phase, GitReviewPhase.ready);
    });

    test('a read that resolves after a newer one is dropped', () async {
      final h = _make();
      final gate = Completer<void>();
      h.gateway.statusGate = gate;
      final older = h.controller.refresh();
      h.gateway.status = const GitRepoStatus(branch: 'newer', changed: 2);
      await h.controller.refresh();
      expect(h.controller.status!.branch, 'newer');
      h.gateway.status = const GitRepoStatus(branch: 'older');
      gate.complete();
      await older;
      expect(h.controller.status!.branch, 'newer');
    });

    test('nothing is notified after dispose', () async {
      final gateway = FakeGitReviewGateway(files: _files);
      final controller = GitReviewController(
        gateway: gateway,
        connectionId: 'c1',
        repoPath: '/srv/repo',
      );
      var notified = 0;
      controller.addListener(() => notified++);
      final gate = Completer<void>();
      gateway.statusGate = gate;
      final read = controller.refresh();
      final before = notified;
      controller.dispose();
      gate.complete();
      await read;
      expect(notified, before);
    });

    test('a diff reads the file on its staged side', () async {
      final h = _make();
      h.gateway.diffs['lib/a.dart'] = const GitReviewDiff(binary: true);
      final diff = await h.controller.diffOf(
        const GitReviewFile(path: 'lib/a.dart', staged: true),
      );
      expect(diff.binary, isTrue);
      expect(h.gateway.calls.last, 'diff:lib/a.dart:true');
    });
  });

  group('commit', () {
    test('commit sends the trimmed message and re-reads', () async {
      final h = _make();
      await h.controller.refresh();
      h.gateway.calls.clear();
      final done = await h.controller.commit('  fix: title  ');
      expect(done, isTrue);
      expect(h.gateway.commits.single, 'fix: title');
      expect(h.gateway.calls, containsAllInOrder(['commit', 'status']));
      expect(h.controller.hasFiles, isFalse);
      expect(h.controller.status!.ahead, 1);
      expect(h.controller.commitBusy, isFalse);
    });

    test('nothing to commit, an empty message or a read-only connection '
        'do nothing', () async {
      final empty = _make(files: const []);
      await empty.controller.refresh();
      expect(await empty.controller.commit('x'), isFalse);
      final blank = _make();
      await blank.controller.refresh();
      expect(await blank.controller.commit('   '), isFalse);
      final readOnly = _make(writes: false);
      await readOnly.controller.refresh();
      expect(await readOnly.controller.commit('x'), isFalse);
      for (final gateway in [empty.gateway, blank.gateway, readOnly.gateway]) {
        expect(gateway.commits, isEmpty);
      }
    });

    test('a refused commit throws and frees the busy flag', () async {
      final h = _make();
      await h.controller.refresh();
      h.gateway.writeFailure = const DesktopControlFailure(
        DesktopControlFailureKind.rejected,
        code: 400,
      );
      await expectLater(
        h.controller.commit('x'),
        throwsA(isA<DesktopControlFailure>()),
      );
      expect(h.controller.commitBusy, isFalse);
      expect(h.controller.hasFiles, isTrue);
    });

    test('C-G4: a refused commit re-reads the tree the server left', () async {
      final h = _make();
      await h.controller.refresh();
      expect(h.controller.files.every((f) => !f.staged), isTrue);
      h.gateway
        ..stagesAllBeforeCommit = true
        ..writeFailure = const DesktopControlFailure(
          DesktopControlFailureKind.rejected,
          code: 400,
        );
      h.gateway.calls.clear();
      await expectLater(
        h.controller.commit('x'),
        throwsA(isA<DesktopControlFailure>()),
      );
      await pumpEventQueue();
      // Re-read after the refusal: the rows say what the server staged, so
      // a diff now asks for the staged side.
      expect(h.gateway.calls, containsAllInOrder(['commit', 'status', 'list']));
      expect(h.controller.files, isNotEmpty);
      expect(h.controller.files.every((f) => f.staged), isTrue);
      expect(h.controller.commitBusy, isFalse);
    });

    test('the busy flag is on while a commit runs', () async {
      final h = _make();
      await h.controller.refresh();
      final seen = <bool>[];
      h.controller.addListener(() => seen.add(h.controller.commitBusy));
      await h.controller.commit('x');
      expect(seen.first, isTrue);
      expect(seen.last, isFalse);
    });

  });

  test('toggling a file stages or unstages it and re-reads', () async {
    final h = _make();
    await h.controller.refresh();
    await h.controller.toggleStaged(h.controller.files.first);
    expect(h.gateway.calls, contains('stage:lib/a.dart'));
    expect(h.controller.files.first.staged, isTrue);
    await h.controller.toggleStaged(h.controller.files.first);
    expect(h.gateway.calls, contains('unstage:lib/a.dart'));
    expect(h.controller.files.first.staged, isFalse);
  });

  group('GitStatusCache (notch pill)', () {
    test('reads are recorded; a later read replaces them', () async {
      final cache = GitStatusCache.instance;
      expect(cache.knows('c1', '/r'), isFalse);
      expect(cache.statusOf('c1', '/r'), isNull);
      final gateway = FakeGitReviewGateway(
        status: const GitRepoStatus(branch: 'main', changed: 4),
      );
      await cache.prefetch(gateway, 'c1', '/r ');
      expect(cache.statusOf('c1', '/r')!.changed, 4);
      gateway.status = null;
      await cache.prefetch(gateway, 'c1', '/r');
      expect(cache.knows('c1', '/r'), isTrue);
      expect(cache.statusOf('c1', '/r'), isNull);
    });

    test('C-G7: an old read that answers last does not win', () async {
      final cache = GitStatusCache.instance;
      final slow = FakeGitReviewGateway(
        status: const GitRepoStatus(branch: 'main', changed: 1),
      )..statusGate = Completer<void>();
      final fresh = FakeGitReviewGateway(
        status: const GitRepoStatus(branch: 'main', changed: 5),
      );
      final gate = slow.statusGate!;
      final old = cache.prefetch(slow, 'c1', '/r');
      await cache.prefetch(fresh, 'c1', '/r');
      expect(cache.statusOf('c1', '/r')!.changed, 5);
      gate.complete();
      await old;
      expect(cache.statusOf('c1', '/r')!.changed, 5);
    });

    test('C-G7: a screen read started after a prefetch wins over it', () async {
      final cache = GitStatusCache.instance;
      final slow = FakeGitReviewGateway(
        status: const GitRepoStatus(branch: 'main', changed: 9),
      )..statusGate = Completer<void>();
      final gate = slow.statusGate!;
      final old = cache.prefetch(slow, 'c1', '/srv/repo');
      final h = _make(
        status: const GitRepoStatus(branch: 'main', changed: 2),
      );
      await h.controller.refresh();
      gate.complete();
      await old;
      expect(cache.statusOf('c1', '/srv/repo')!.changed, 2);
    });

    test('a failed prefetch keeps what was known', () async {
      final cache = GitStatusCache.instance;
      cache.record('c1', '/r', const GitRepoStatus(changed: 3));
      final gateway = FakeGitReviewGateway()
        ..readFailure = const DesktopControlFailure(
          DesktopControlFailureKind.unavailable,
        );
      await cache.prefetch(gateway, 'c1', '/r');
      expect(cache.statusOf('c1', '/r')!.changed, 3);
    });

    test('an unsupported gateway is not asked', () async {
      final gateway = FakeGitReviewGateway()..unsupported = true;
      await GitStatusCache.instance.prefetch(gateway, 'c1', '/r');
      expect(gateway.calls, isEmpty);
    });

    test('notch entry: shown with the changed count as its badge', () {
      final gateway = FakeGitReviewGateway();
      GitStatusCache.instance.record(
        'c1',
        '/r',
        const GitRepoStatus(branch: 'main', changed: 4),
      );
      final entry = gitNotchEntry(
        gateway: gateway,
        repoPath: '/r',
        connectionId: 'c1',
      );
      expect(entry.available, isTrue);
      expect(entry.badge, 4);
    });

    // GITPILL (Pixel, 1.4.0 c09d1f28): an unread folder showed the pill on
    // the first opening and lost it once the read said "not a repository".
    test('notch entry: no pill while the folder is not read yet', () {
      final entry = gitNotchEntry(
        gateway: FakeGitReviewGateway(),
        repoPath: '/r',
        connectionId: 'c1',
      );
      expect(entry.available, isFalse);
      expect(entry.badge, isNull);
    });

    test('notch entry: hidden without gateway, folder, routes or repo', () {
      bool shown(FakeGitReviewGateway? gateway, String? repoPath) =>
          gitNotchEntry(
            gateway: gateway,
            repoPath: repoPath,
            connectionId: 'c1',
          ).available;
      final gateway = FakeGitReviewGateway();
      expect(shown(null, '/r'), isFalse);
      expect(shown(gateway, null), isFalse);
      // A confirmed repository on a Hermes that lost its git routes.
      GitStatusCache.instance.record('c1', '/r', const GitRepoStatus());
      expect(shown(FakeGitReviewGateway()..unsupported = true, '/r'), isFalse);
      GitStatusCache.instance.record('c1', '/r', null);
      expect(shown(gateway, '/r'), isFalse);
    });

    test('folders are kept per connection', () {
      final cache = GitStatusCache.instance;
      cache.record('c1', '/r', const GitRepoStatus(changed: 1));
      expect(cache.knows('c2', '/r'), isFalse);
    });
  });

  group('F2b', () {
    test('conflicts turn commit off', () async {
      final h = _make(
        status: const GitRepoStatus(branch: 'main', changed: 1, conflicted: 1),
        files: const [GitReviewFile(path: 'f.txt', status: 'U')],
      );
      await h.controller.refresh();
      expect(h.controller.hasConflicts, isTrue);
      expect(h.controller.conflicts, 1);
      expect(await h.controller.commit('merge'), isFalse);
      expect(h.gateway.commits, isEmpty);
    });

  });
}
