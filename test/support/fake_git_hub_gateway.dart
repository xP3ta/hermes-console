import 'dart:async';

import 'package:hermes_android/core/models/desktop_control_center.dart'
    show ProjectGitBaseBranch, ProjectGitBranch, ProjectWorktreeResult;
import 'package:hermes_android/core/models/git_hub.dart';
import 'package:hermes_android/core/models/git_review.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/git_hub_gateway.dart';
import 'package:hermes_android/core/services/session_pull_requests.dart'
    show PullRequestInfo, PullRequestList;

import 'fake_git_review_gateway.dart';

/// Deterministic in-memory [HermesGitHubGateway]: the review fake plus the
/// hub routes. Every call is recorded in [calls]; writes refuse on a
/// read-only fake and throw [writeFailure] when set.
class FakeGitHubGateway extends FakeGitReviewGateway
    implements HermesGitHubGateway {
  FakeGitHubGateway({
    super.status,
    super.files,
    super.writes,
    this.ghAuth = const GitGhAuth(available: true, authenticated: true),
    this.shipInfo = const GitShipInfo(ghReady: true),
    List<ProjectGitBranch> branches = const [],
    List<ProjectGitBaseBranch> baseBranches = const [],
    List<GitWorktree> worktrees = const [],
  }) : branches = List.of(branches),
       baseBranches = List.of(baseBranches),
       worktrees = List.of(worktrees);

  GitGhAuth ghAuth;
  GitShipInfo shipInfo;
  List<ProjectGitBranch> branches;
  List<ProjectGitBaseBranch> baseBranches;
  List<GitWorktree> worktrees;
  GitCommitContext commitContext = const GitCommitContext();
  PullRequestList pullRequests = const PullRequestList(ghReady: true, prs: []);
  String createdPrUrl = 'https://github.com/o/r/pull/7';

  /// Thrown by gh-auth / ship-info while set (gh reads fail on their own).
  Object? shipFailure;

  /// Holds the next push open until completed.
  Completer<void>? pushGate;

  final List<String> pushed = [];
  final List<String?> reverted = [];
  final List<String> switched = [];
  final List<(String?, bool)> removedWorktrees = [];

  void _write() {
    if (!writes) {
      throw const DesktopControlFailure(DesktopControlFailureKind.forbidden);
    }
    final failure = writeFailure;
    if (failure != null) throw failure;
  }

  void _ship() {
    final failure = shipFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<GitGhAuth> gitGhAuth({bool refresh = false}) async {
    calls.add(refresh ? 'gh-auth:refresh' : 'gh-auth');
    _ship();
    return ghAuth;
  }

  @override
  Future<GitShipInfo> gitShipInfo(String repoPath) async {
    calls.add('ship-info');
    _ship();
    return shipInfo;
  }

  @override
  Future<List<GitWorktree>> gitWorktrees(String repoPath) async {
    calls.add('worktrees');
    final failure = readFailure;
    if (failure != null) throw failure;
    return List.unmodifiable(worktrees);
  }

  @override
  Future<List<ProjectGitBranch>> gitBranches(String repoPath) async {
    calls.add('branches');
    final failure = readFailure;
    if (failure != null) throw failure;
    return List.unmodifiable(branches);
  }

  @override
  Future<List<ProjectGitBaseBranch>> gitBaseBranches(String repoPath) async {
    calls.add('base-branches');
    final failure = readFailure;
    if (failure != null) throw failure;
    return List.unmodifiable(baseBranches);
  }

  @override
  Future<GitCommitContext> gitCommitContext(String repoPath) async {
    calls.add('commit-context');
    final failure = readFailure;
    if (failure != null) throw failure;
    return commitContext;
  }

  @override
  Future<PullRequestList> gitPullRequests(
    String repoPath, {
    required List<String> branches,
  }) async {
    calls.add('pr-list:${branches.join(',')}');
    final failure = readFailure;
    if (failure != null) throw failure;
    return pullRequests;
  }

  GitReviewFile _staged(GitReviewFile f, bool staged) => GitReviewFile(
    path: f.path,
    added: f.added,
    removed: f.removed,
    status: f.status,
    staged: staged,
  );

  @override
  Future<void> gitStageAll(String repoPath) async {
    calls.add('stage-all');
    _write();
    files = [for (final f in files) _staged(f, true)];
  }

  @override
  Future<void> gitUnstageAll(String repoPath) async {
    calls.add('unstage-all');
    _write();
    files = [for (final f in files) _staged(f, false)];
  }

  @override
  Future<void> gitRevert(String repoPath, {String? file}) async {
    calls.add(file == null ? 'revert-all' : 'revert:$file');
    _write();
    reverted.add(file);
    files = file == null ? [] : files.where((f) => f.path != file).toList();
    final current = status;
    if (current != null) {
      status = GitRepoStatus(
        branch: current.branch,
        ahead: current.ahead,
        behind: current.behind,
        changed: files.length,
      );
    }
  }

  @override
  Future<void> gitCommitAndPush(String repoPath, String message) async {
    calls.add('commit+push');
    await gitCommit(repoPath, message);
    pushed.add(message);
    final current = status;
    if (current != null) {
      status = GitRepoStatus(branch: current.branch, ahead: 0);
    }
  }

  @override
  Future<void> gitPush(String repoPath) async {
    calls.add('push');
    final gate = pushGate;
    if (gate != null) {
      pushGate = null;
      await gate.future;
    }
    _write();
    pushed.add('');
    final current = status;
    if (current != null) {
      status = GitRepoStatus(
        branch: current.branch,
        ahead: 0,
        changed: current.changed,
      );
    }
  }

  @override
  Future<GitCreatedPullRequest> gitCreatePullRequest(String repoPath) async {
    calls.add('create-pr');
    _write();
    shipInfo = GitShipInfo(
      ghReady: true,
      pullRequest: GitShipPullRequest(
        url: createdPrUrl,
        state: 'open',
        number: 7,
      ),
    );
    return GitCreatedPullRequest(url: createdPrUrl);
  }

  @override
  Future<ProjectWorktreeResult> gitWorktreeAdd(
    String repoPath, {
    String? branch,
    String? base,
    String? existingBranch,
  }) async {
    calls.add(
      'worktree-add:${branch ?? ''}:${base ?? ''}:${existingBranch ?? ''}',
    );
    _write();
    final name = branch ?? existingBranch ?? 'work';
    final path = '$repoPath/.worktrees/${name.replaceAll('/', '-')}';
    worktrees = [...worktrees, GitWorktree(path: path, branch: name)];
    return ProjectWorktreeResult(path: path, branch: name);
  }

  @override
  Future<void> gitWorktreeRemove(
    String repoPath,
    String worktreePath, {
    bool force = false,
  }) async {
    calls.add('worktree-remove:$worktreePath:$force');
    _write();
    removedWorktrees.add((worktreePath, force));
    worktrees = worktrees.where((w) => w.path != worktreePath).toList();
  }

  @override
  Future<void> gitBranchSwitch(String repoPath, String branch) async {
    calls.add('switch:$branch');
    _write();
    switched.add(branch);
    final current = status;
    status = GitRepoStatus(
      branch: branch,
      changed: current?.changed ?? 0,
      added: current?.added ?? 0,
      removed: current?.removed ?? 0,
    );
  }
}

/// A PR row for the fake's list.
PullRequestInfo fakePullRequest({
  required String branch,
  required int number,
  String state = 'open',
  bool draft = false,
  String title = 'Title',
  String url = 'https://github.com/o/r/pull/1',
}) => PullRequestInfo(
  branch: branch,
  number: number,
  state: state,
  draft: draft,
  title: title,
  url: url,
);
