import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/desktop_control_center.dart'
    show ProjectGitBaseBranch, ProjectGitBranch, ProjectWorktreeResult;
import '../models/git_hub.dart';
import '../models/git_review.dart';
import 'git_hub_gateway.dart';
import 'git_review_controller.dart';
import 'session_pull_requests.dart' show PullRequestList;

/// What the hub is doing beyond a read; one thing at a time.
enum GitHubBusy {
  none,
  stageAll,
  revert,
  push,
  createPr,
  switchBranch,
  worktree,
  pullRequests,
}

/// Git's author identity on the server as far as the app knows: the
/// server has no route for it, so it is learned from a commit.
enum GitIdentityState { unknown, ok, missing }

/// The Git hub's state for one folder: the review pane's status and files
/// ([GitReviewController]) plus GitHub's auth, the branch's ship info,
/// branches, worktrees, the commit context and the pull requests, each
/// read on demand. Every write goes through the Dashboard routes of
/// [HermesGitHubGateway]; nothing runs on the phone.
class GitHubController extends GitReviewController {
  GitHubController({
    required HermesGitHubGateway gateway,
    required super.connectionId,
    required super.repoPath,
    super.cache,
  }) : hub = gateway,
       super(gateway: gateway);

  final HermesGitHubGateway hub;

  GitGhAuth? _ghAuth;

  /// Null until `gh-auth` answered (or failed: the header then says «sin
  /// comprobar»).
  GitGhAuth? get ghAuth => _ghAuth;

  GitShipInfo? _ship;
  GitShipInfo? get shipInfo => _ship;

  GitIdentityState _identity = GitIdentityState.unknown;
  GitIdentityState get identity => _identity;

  List<ProjectGitBranch> _branches = const [];
  List<ProjectGitBranch> get branches => _branches;

  List<ProjectGitBaseBranch> _baseBranches = const [];
  List<ProjectGitBaseBranch> get baseBranches => _baseBranches;

  List<GitWorktree> _worktrees = const [];
  List<GitWorktree> get worktrees => _worktrees;

  GitCommitContext? _commitContext;
  GitCommitContext? get commitContext => _commitContext;
  bool _contextLoading = false;
  bool get commitContextLoading => _contextLoading;

  PullRequestList? _pullRequests;
  PullRequestList? get pullRequests => _pullRequests;

  GitHubBusy _busy = GitHubBusy.none;
  GitHubBusy get busy => _busy;
  bool get isBusy => _busy != GitHubBusy.none;

  bool _hubCommitBusy = false;
  @override
  bool get commitBusy => _hubCommitBusy || super.commitBusy;

  bool _disposed = false;
  int _shipSeq = 0;

  void _tell() {
    if (!_disposed) notifyListeners();
  }

  /// The base branch flagged default, else the status' trunk; empty when
  /// neither is known.
  String get defaultBase {
    for (final base in _baseBranches) {
      if (base.isDefault) return base.name;
    }
    return status?.defaultBranch ?? '';
  }

  /// Local branch names (for the PR list), the current one first.
  List<String> get localBranchNames {
    final names = <String>[
      ?status?.branch,
      for (final branch in _branches)
        if (!branch.isRemote) branch.name,
    ];
    return List.unmodifiable({...names}.take(50));
  }

  int get stagedCount => files.where((f) => f.staged).length;
  int get unstagedCount =>
      files.where((f) => !f.staged && f.status != '?').length;
  int get untrackedCount => files.where((f) => f.status == '?').length;

  List<GitReviewFile> get stagedFiles =>
      files.where((f) => f.staged).toList(growable: false);
  List<GitReviewFile> get unstagedFiles =>
      files.where((f) => !f.staged && f.status != '?').toList(growable: false);
  List<GitReviewFile> get untrackedFiles =>
      files.where((f) => f.status == '?').toList(growable: false);

  /// Status + files, then GitHub's auth and the branch's PR in the
  /// background (gh is optional on the server: a failure there leaves the
  /// header at «sin comprobar»).
  @override
  Future<void> refresh() async {
    await super.refresh();
    if (_disposed || phase != GitReviewPhase.ready) return;
    unawaited(refreshShip());
  }

  /// `gh-auth` and `ship-info`, read together; a stale answer is dropped.
  Future<void> refreshShip({bool refreshAuth = false}) async {
    final seq = ++_shipSeq;
    final authRead = hub.gitGhAuth(refresh: refreshAuth);
    final shipRead = hub.gitShipInfo(repoPath);
    unawaited(shipRead.then<void>((_) {}, onError: (_) {}));
    try {
      final auth = await authRead;
      if (seq != _shipSeq || _disposed) return;
      _ghAuth = auth;
    } catch (error) {
      debugPrint('[git] gh-auth read failed (${error.runtimeType})');
    }
    try {
      final ship = await shipRead;
      if (seq != _shipSeq || _disposed) return;
      _ship = ship;
    } catch (error) {
      debugPrint('[git] ship-info read failed (${error.runtimeType})');
    }
    _tell();
  }

  Future<void> loadBranches() async {
    final list = await hub.gitBranches(repoPath);
    if (_disposed) return;
    _branches = list;
    _tell();
  }

  Future<void> loadBaseBranches() async {
    final list = await hub.gitBaseBranches(repoPath);
    if (_disposed) return;
    _baseBranches = list;
    _tell();
  }

  Future<void> loadWorktrees() async {
    final list = await hub.gitWorktrees(repoPath);
    if (_disposed) return;
    _worktrees = list;
    _tell();
  }

  /// The server's help for the message. Errors leave it unset (the card
  /// then says there is no context); nothing else depends on it.
  Future<void> loadCommitContext() async {
    _contextLoading = true;
    _tell();
    try {
      final context = await hub.gitCommitContext(repoPath);
      if (_disposed) return;
      _commitContext = context;
    } catch (error) {
      if (_disposed) return;
      _commitContext = const GitCommitContext();
      debugPrint('[git] commit-context read failed (${error.runtimeType})');
    } finally {
      _contextLoading = false;
      _tell();
    }
  }

  /// PRs of the local branches (the branches list is read first when it
  /// is not known yet). Throws on failure.
  Future<void> loadPullRequests() async {
    if (isBusy) return;
    _busy = GitHubBusy.pullRequests;
    _tell();
    try {
      if (_branches.isEmpty) {
        try {
          await loadBranches();
        } catch (_) {
          // The current branch alone is still worth asking for.
        }
      }
      final names = localBranchNames;
      if (names.isEmpty) {
        _pullRequests = const PullRequestList(ghReady: false, prs: []);
        return;
      }
      final list = await hub.gitPullRequests(repoPath, branches: names);
      if (_disposed) return;
      _pullRequests = list;
    } finally {
      _busy = GitHubBusy.none;
      _tell();
    }
  }

  Future<T> _run<T>(GitHubBusy what, Future<T> Function() action) async {
    if (isBusy) throw StateError('git hub busy: ${_busy.name}');
    _busy = what;
    _tell();
    try {
      return await action();
    } finally {
      _busy = GitHubBusy.none;
      _tell();
    }
  }

  Future<void> stageAll() => _run(GitHubBusy.stageAll, () async {
    await hub.gitStageAll(repoPath);
    await refresh();
  });

  Future<void> unstageAll() => _run(GitHubBusy.stageAll, () async {
    await hub.gitUnstageAll(repoPath);
    await refresh();
  });

  /// Discards one file's changes, or every change when [file] is null.
  /// The screen confirms first; nothing undoes it.
  Future<void> revert({GitReviewFile? file}) =>
      _run(GitHubBusy.revert, () async {
        await hub.gitRevert(repoPath, file: file?.path);
        await refresh();
      });

  /// The commit (the server stages everything when nothing is staged),
  /// optionally followed by the push. A refusal re-reads the tree, then
  /// rethrows for the screen to say why.
  Future<bool> commitChanges(String message, {bool push = false}) async {
    final text = message.trim();
    if (text.isEmpty ||
        !hasFiles ||
        hasConflicts ||
        commitBusy ||
        isBusy ||
        !writesAllowed ||
        !isUncommittedScope) {
      return false;
    }
    _hubCommitBusy = true;
    _tell();
    try {
      if (push) {
        await hub.gitCommitAndPush(repoPath, text);
      } else {
        await hub.gitCommit(repoPath, text);
      }
      _identity = GitIdentityState.ok;
    } on GitActionFailure catch (failure) {
      if (failure.problem == GitActionProblem.noIdentity) {
        _identity = GitIdentityState.missing;
      }
      _hubCommitBusy = false;
      unawaited(refresh());
      rethrow;
    } catch (_) {
      _hubCommitBusy = false;
      unawaited(refresh());
      rethrow;
    } finally {
      _hubCommitBusy = false;
      _tell();
    }
    _commitContext = null;
    await refresh();
    return true;
  }

  Future<void> push() => _run(GitHubBusy.push, () async {
    await hub.gitPush(repoPath);
    await refresh();
  });

  /// `create-pr`; the server pushes first. Returns the link gh printed.
  Future<GitCreatedPullRequest> createPullRequest() =>
      _run(GitHubBusy.createPr, () async {
        final created = await hub.gitCreatePullRequest(repoPath);
        unawaited(refresh());
        return created;
      });

  Future<void> switchBranch(String branch) =>
      _run(GitHubBusy.switchBranch, () async {
        await hub.gitBranchSwitch(repoPath, branch);
        _branches = const [];
        _pullRequests = null;
        _commitContext = null;
        await refresh();
      });

  Future<ProjectWorktreeResult> addWorktree({
    String? branch,
    String? base,
    String? existingBranch,
  }) => _run(GitHubBusy.worktree, () async {
    final result = await hub.gitWorktreeAdd(
      repoPath,
      branch: branch,
      base: base,
      existingBranch: existingBranch,
    );
    try {
      await loadWorktrees();
    } catch (_) {
      // The list is re-read next time the sheet opens.
    }
    return result;
  });

  Future<void> removeWorktree(String worktreePath, {bool force = false}) =>
      _run(GitHubBusy.worktree, () async {
        await hub.gitWorktreeRemove(repoPath, worktreePath, force: force);
        try {
          await loadWorktrees();
        } catch (_) {}
      });

  @override
  void dispose() {
    _disposed = true;
    _shipSeq++;
    super.dispose();
  }
}
