// The Git hub's state: the review pane's reads plus GitHub's auth, the
// branch's ship info, branches, worktrees, the commit context, the pull
// requests, and every write behind one busy flag.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/models/git_hub.dart';
import 'package:hermes_android/core/models/git_review.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/git_hub_controller.dart';
import 'package:hermes_android/core/services/git_review_controller.dart';
import 'package:hermes_android/core/services/session_pull_requests.dart';

import 'support/fake_git_hub_gateway.dart';

const _files = [
  GitReviewFile(path: 'lib/a.dart', added: 16, status: 'M', staged: true),
  GitReviewFile(path: 'lib/b.dart', added: 2, removed: 1, status: 'M'),
  GitReviewFile(path: 'test/c_test.dart', added: 19, status: '?'),
];

const _status = GitRepoStatus(
  branch: 'feat/x',
  defaultBranch: 'main',
  changed: 3,
  ahead: 2,
  behind: 1,
  added: 37,
  removed: 1,
);

({GitHubController controller, FakeGitHubGateway gateway}) _make({
  GitRepoStatus? status = _status,
  List<GitReviewFile> files = _files,
  bool writes = true,
}) {
  final gateway = FakeGitHubGateway(
    status: status,
    files: files,
    writes: writes,
    branches: const [
      ProjectGitBranch(name: 'feat/x', checkedOut: true),
      ProjectGitBranch(name: 'main', isDefault: true),
      ProjectGitBranch(name: 'origin/other', isRemote: true),
    ],
    baseBranches: const [
      ProjectGitBaseBranch(
        name: 'origin/main',
        isRemote: true,
        isDefault: true,
      ),
      ProjectGitBaseBranch(name: 'main'),
    ],
    worktrees: const [
      GitWorktree(path: '/srv/repo', branch: 'feat/x', isMain: true),
    ],
  );
  final controller = GitHubController(
    gateway: gateway,
    connectionId: 'c1',
    repoPath: '/srv/repo',
  );
  addTearDown(controller.dispose);
  return (controller: controller, gateway: gateway);
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  setUp(GitStatusCache.instance.clear);

  group('reads', () {
    test('refresh reads status, list, then gh-auth and ship-info', () async {
      final h = _make();
      await h.controller.refresh();
      await _settle();
      expect(h.controller.phase, GitReviewPhase.ready);
      expect(h.gateway.calls, ['status', 'list', 'gh-auth', 'ship-info']);
      expect(h.controller.ghAuth!.authenticated, isTrue);
      expect(h.controller.shipInfo!.ghReady, isTrue);
    });

    test('files are grouped by state', () async {
      final h = _make();
      await h.controller.refresh();
      expect(h.controller.stagedFiles.map((f) => f.path), ['lib/a.dart']);
      expect(h.controller.unstagedFiles.map((f) => f.path), ['lib/b.dart']);
      expect(h.controller.untrackedFiles.map((f) => f.path), [
        'test/c_test.dart',
      ]);
      expect(h.controller.stagedCount, 1);
      expect(h.controller.unstagedCount, 1);
      expect(h.controller.untrackedCount, 1);
    });

    test('a gh failure leaves the header unknown, the tree ready', () async {
      final h = _make();
      h.gateway.shipFailure = const DesktopControlFailure(
        DesktopControlFailureKind.unavailable,
      );
      await h.controller.refresh();
      await _settle();
      expect(h.controller.phase, GitReviewPhase.ready);
      expect(h.controller.ghAuth, isNull);
      expect(h.controller.shipInfo, isNull);
    });

    test('not a repository reads nothing of gh', () async {
      final h = _make(status: null);
      await h.controller.refresh();
      await _settle();
      expect(h.controller.phase, GitReviewPhase.notRepo);
      expect(h.gateway.calls, ['status', 'list']);
    });

    test('an older Hermes is unsupported and asks gh nothing', () async {
      final h = _make();
      h.gateway.readFailure = const DesktopControlFailure(
        DesktopControlFailureKind.unsupported,
        code: 404,
      );
      await h.controller.refresh();
      await _settle();
      expect(h.controller.phase, GitReviewPhase.unsupported);
      expect(h.gateway.calls, ['status', 'list']);
    });

    test('a stale ship read is dropped', () async {
      final h = _make();
      await h.controller.refresh();
      await _settle();
      h.gateway.ghAuth = const GitGhAuth(available: true, authenticated: false);
      final first = h.controller.refreshShip();
      final second = h.controller.refreshShip(refreshAuth: true);
      await Future.wait([first, second]);
      expect(h.gateway.calls.last, 'ship-info');
      expect(h.gateway.calls, contains('gh-auth:refresh'));
      expect(h.controller.ghAuth!.authenticated, isFalse);
    });

    test('branches, base branches, worktrees and the default base', () async {
      final h = _make();
      await h.controller.refresh();
      await h.controller.loadBranches();
      await h.controller.loadBaseBranches();
      await h.controller.loadWorktrees();
      expect(h.controller.branches.length, 3);
      expect(h.controller.defaultBase, 'origin/main');
      expect(h.controller.worktrees.single.isMain, isTrue);
      expect(h.controller.localBranchNames, ['feat/x', 'main']);
    });

    test('the default base falls back to the status trunk', () async {
      final h = _make();
      await h.controller.refresh();
      expect(h.controller.defaultBase, 'main');
    });

    test('commit context loads on demand; a failure reads as empty', () async {
      final h = _make();
      h.gateway.commitContext = const GitCommitContext(
        diffLines: ['+a'],
        recentSubjects: ['feat: x'],
      );
      await h.controller.loadCommitContext();
      expect(h.controller.commitContext!.recentSubjects, ['feat: x']);
      h.gateway.readFailure = const DesktopControlFailure(
        DesktopControlFailureKind.unavailable,
      );
      await h.controller.loadCommitContext();
      expect(h.controller.commitContext!.isEmpty, isTrue);
      expect(h.controller.commitContextLoading, isFalse);
    });

    test('pull requests ask for the local branches, current first', () async {
      final h = _make();
      h.gateway.pullRequests = PullRequestList(
        ghReady: true,
        prs: [fakePullRequest(branch: 'feat/x', number: 4)],
      );
      await h.controller.refresh();
      await h.controller.loadPullRequests();
      expect(h.gateway.calls, contains('branches'));
      expect(h.gateway.calls.last, 'pr-list:feat/x,main');
      expect(h.controller.pullRequests!.prs.single.number, 4);
      expect(h.controller.isBusy, isFalse);
    });

    test('a failed PR read rethrows and frees the busy flag', () async {
      final h = _make();
      await h.controller.refresh();
      h.gateway.readFailure = const DesktopControlFailure(
        DesktopControlFailureKind.unavailable,
      );
      await expectLater(
        h.controller.loadPullRequests(),
        throwsA(isA<DesktopControlFailure>()),
      );
      expect(h.controller.isBusy, isFalse);
      expect(h.controller.pullRequests, isNull);
    });
  });

  group('changes', () {
    test('stage all and unstage all re-read the tree', () async {
      final h = _make();
      await h.controller.refresh();
      await h.controller.stageAll();
      expect(h.controller.stagedCount, 3);
      await h.controller.unstageAll();
      expect(h.controller.stagedCount, 0);
      expect(h.gateway.calls, containsAllInOrder(['stage-all', 'unstage-all']));
      expect(h.controller.isBusy, isFalse);
    });

    test('revert of one file, and of everything', () async {
      final h = _make();
      await h.controller.refresh();
      await h.controller.revert(file: _files[1]);
      expect(h.gateway.reverted, ['lib/b.dart']);
      expect(h.controller.files.length, 2);
      await h.controller.revert();
      expect(h.gateway.reverted.last, isNull);
      expect(h.controller.hasFiles, isFalse);
    });

    test('a refused revert rethrows and frees the busy flag', () async {
      final h = _make();
      await h.controller.refresh();
      h.gateway.writeFailure = const GitActionFailure(
        GitActionProblem.localChanges,
      );
      await expectLater(
        h.controller.revert(),
        throwsA(isA<GitActionFailure>()),
      );
      expect(h.controller.busy, GitHubBusy.none);
      expect(h.controller.files.length, 3);
    });

    test(
      'a second action while one runs is refused, nothing is sent',
      () async {
        final h = _make();
        await h.controller.refresh();
        final gate = Completer<void>();
        h.gateway.pushGate = gate;
        final push = h.controller.push();
        await _settle();
        expect(h.controller.busy, GitHubBusy.push);
        await expectLater(h.controller.stageAll(), throwsStateError);
        expect(h.gateway.calls, isNot(contains('stage-all')));
        gate.complete();
        await push;
        expect(h.controller.isBusy, isFalse);
        expect(h.gateway.pushed, ['']);
      },
    );

    test('read-only: no write goes out', () async {
      final h = _make(writes: false);
      await h.controller.refresh();
      expect(h.controller.writesAllowed, isFalse);
      expect(await h.controller.commitChanges('m'), isFalse);
      await expectLater(
        h.controller.stageAll(),
        throwsA(isA<DesktopControlFailure>()),
      );
      expect(h.gateway.pushed, isEmpty);
      expect(h.gateway.commits, isEmpty);
    });
  });

  group('commit and push', () {
    test('commit alone', () async {
      final h = _make();
      await h.controller.refresh();
      expect(await h.controller.commitChanges('feat: x'), isTrue);
      expect(h.gateway.commits, ['feat: x']);
      expect(h.gateway.pushed, isEmpty);
      expect(h.controller.identity, GitIdentityState.ok);
      expect(h.controller.hasFiles, isFalse);
      expect(h.controller.commitContext, isNull);
    });

    test('commit with push uses the one route with the flag', () async {
      final h = _make();
      await h.controller.refresh();
      expect(await h.controller.commitChanges('feat: x', push: true), isTrue);
      expect(h.gateway.calls, contains('commit+push'));
      expect(h.gateway.pushed, ['feat: x']);
      expect(h.controller.status!.ahead, 0);
    });

    test('a commit refused for identity marks it missing', () async {
      final h = _make();
      await h.controller.refresh();
      h.gateway.writeFailure = const GitActionFailure(
        GitActionProblem.noIdentity,
      );
      await expectLater(
        h.controller.commitChanges('m'),
        throwsA(isA<GitActionFailure>()),
      );
      await _settle();
      expect(h.controller.identity, GitIdentityState.missing);
      expect(h.controller.commitBusy, isFalse);
      expect(h.controller.files.length, 3);
    });

    test(
      'nothing commits without a message, files or with conflicts',
      () async {
        final h = _make();
        await h.controller.refresh();
        expect(await h.controller.commitChanges('  '), isFalse);
        final empty = _make(files: const []);
        await empty.controller.refresh();
        expect(await empty.controller.commitChanges('m'), isFalse);
        final conflicted = _make(
          files: const [GitReviewFile(path: 'x', status: 'U')],
        );
        await conflicted.controller.refresh();
        expect(await conflicted.controller.commitChanges('m'), isFalse);
        expect(h.gateway.commits, isEmpty);
      },
    );

    test('push re-reads the status', () async {
      final h = _make();
      await h.controller.refresh();
      await h.controller.push();
      expect(h.gateway.pushed, ['']);
      expect(h.controller.status!.ahead, 0);
      expect(h.controller.isBusy, isFalse);
    });

    test('a rejected push rethrows its reason', () async {
      final h = _make();
      await h.controller.refresh();
      h.gateway.writeFailure = const GitActionFailure(
        GitActionProblem.pushRejected,
      );
      await expectLater(
        h.controller.push(),
        throwsA(
          isA<GitActionFailure>().having(
            (f) => f.problem,
            'problem',
            GitActionProblem.pushRejected,
          ),
        ),
      );
      expect(h.controller.isBusy, isFalse);
    });
  });

  group('pull request', () {
    test('create-pr returns the link and refreshes ship info', () async {
      final h = _make();
      await h.controller.refresh();
      final created = await h.controller.createPullRequest();
      await _settle();
      await _settle();
      expect(created.url, 'https://github.com/o/r/pull/7');
      expect(h.controller.shipInfo!.pullRequest!.number, 7);
      expect(h.controller.isBusy, isFalse);
    });

    test('a gh refusal rethrows classified', () async {
      final h = _make();
      await h.controller.refresh();
      h.gateway.writeFailure = const GitActionFailure(
        GitActionProblem.ghNotReady,
      );
      await expectLater(
        h.controller.createPullRequest(),
        throwsA(isA<GitActionFailure>()),
      );
      expect(h.controller.isBusy, isFalse);
    });
  });

  group('branches and worktrees', () {
    test('switch re-reads and forgets branch-bound caches', () async {
      final h = _make();
      await h.controller.refresh();
      await h.controller.loadBranches();
      await h.controller.loadPullRequests();
      await h.controller.switchBranch('main');
      expect(h.gateway.switched, ['main']);
      expect(h.controller.status!.branch, 'main');
      expect(h.controller.branches, isEmpty);
      expect(h.controller.pullRequests, isNull);
      expect(h.controller.isBusy, isFalse);
    });

    test('a refused switch keeps the branch', () async {
      final h = _make();
      await h.controller.refresh();
      h.gateway.writeFailure = const GitActionFailure(
        GitActionProblem.localChanges,
      );
      await expectLater(
        h.controller.switchBranch('main'),
        throwsA(isA<GitActionFailure>()),
      );
      expect(h.controller.status!.branch, 'feat/x');
      expect(h.controller.isBusy, isFalse);
    });

    test('add worktree returns the path and re-reads the list', () async {
      final h = _make();
      await h.controller.refresh();
      final result = await h.controller.addWorktree(
        branch: 'feat/y',
        base: 'origin/main',
      );
      expect(result.path, '/srv/repo/.worktrees/feat-y');
      expect(h.controller.worktrees.map((w) => w.branch), ['feat/x', 'feat/y']);
      expect(h.gateway.calls, contains('worktree-add:feat/y:origin/main:'));
    });

    test('remove worktree, then forced', () async {
      final h = _make();
      await h.controller.refresh();
      await h.controller.addWorktree(branch: 'feat/y');
      await h.controller.removeWorktree('/srv/repo/.worktrees/feat-y');
      expect(h.gateway.removedWorktrees, [
        ('/srv/repo/.worktrees/feat-y', false),
      ]);
      expect(h.controller.worktrees.length, 1);
      h.gateway.writeFailure = const GitActionFailure(
        GitActionProblem.localChanges,
      );
      await expectLater(
        h.controller.removeWorktree('/srv/repo', force: false),
        throwsA(isA<GitActionFailure>()),
      );
      h.gateway.writeFailure = null;
      await h.controller.removeWorktree('/srv/repo', force: true);
      expect(h.gateway.removedWorktrees.last, ('/srv/repo', true));
    });
  });

  test('after dispose nothing notifies', () async {
    final gateway = FakeGitHubGateway(status: _status, files: _files);
    final controller = GitHubController(
      gateway: gateway,
      connectionId: 'c1',
      repoPath: '/srv/repo',
    );
    var notified = 0;
    controller.addListener(() => notified++);
    final read = controller.refresh();
    controller.dispose();
    await read;
    await _settle();
    final after = notified;
    await _settle();
    expect(notified, after);
  });
}
