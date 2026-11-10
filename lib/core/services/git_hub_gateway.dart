import '../models/desktop_control_center.dart'
    show ProjectGitBaseBranch, ProjectGitBranch, ProjectWorktreeResult;
import '../models/git_hub.dart';
import 'git_review_gateway.dart';
import 'session_pull_requests.dart' show PullRequestList;

/// The whole Dashboard `/api/git/*` surface the Git hub uses, on top of
/// the review routes of [HermesGitReviewGateway]. Exactly the routes
/// `hermes_cli/web_routers/git.py` publishes; the server runs git and gh,
/// the app sends a folder and values, never a command line.
///
/// Not used on purpose: `review/rev-parse` (no screen needs a SHA) and
/// `file-diff` (the working-tree-vs-HEAD preview; `review/diff` already
/// serves every listed file on its staged side).
///
/// Implementations map a missing route (404/405) to an unsupported
/// [DesktopControlFailure], a refused mutation (400) to a
/// [GitActionFailure] when its reason is recognised (else `rejected`), and
/// any write on a read-only connection to `forbidden` before any request.
abstract interface class HermesGitHubGateway implements HermesGitReviewGateway {
  /// `GET /api/git/gh-auth[?refresh=true]`.
  Future<GitGhAuth> gitGhAuth({bool refresh = false});

  /// `GET /api/git/worktrees?path=`.
  Future<List<GitWorktree>> gitWorktrees(String repoPath);

  /// `GET /api/git/branches?path=`: local heads, then remote-only refs.
  Future<List<ProjectGitBranch>> gitBranches(String repoPath);

  /// `GET /api/git/base-branches?path=`: the default flagged.
  Future<List<ProjectGitBaseBranch>> gitBaseBranches(String repoPath);

  /// `GET /api/git/review/commit-context?path=`.
  Future<GitCommitContext> gitCommitContext(String repoPath);

  /// `GET /api/git/review/ship-info?path=`.
  Future<GitShipInfo> gitShipInfo(String repoPath);

  /// `POST /api/git/review/pr-list {path, branches, numbers}`.
  Future<PullRequestList> gitPullRequests(
    String repoPath, {
    required List<String> branches,
  });

  /// `POST /api/git/review/stage {path}`: everything (`git add -A`).
  Future<void> gitStageAll(String repoPath);

  /// `POST /api/git/review/unstage {path}`: everything.
  Future<void> gitUnstageAll(String repoPath);

  /// `POST /api/git/review/revert {path, file?}`: discards the file's
  /// changes back to HEAD (an untracked file is removed); the whole tree
  /// when [file] is null. Nothing undoes it.
  Future<void> gitRevert(String repoPath, {String? file});

  /// `POST /api/git/review/commit {path, message, push: true}`: the
  /// commit, then the server pushes (with `-u origin <branch>` when the
  /// branch has no upstream).
  Future<void> gitCommitAndPush(String repoPath, String message);

  /// `POST /api/git/review/push {path}`.
  Future<void> gitPush(String repoPath);

  /// `POST /api/git/review/create-pr {path}`: the server pushes, then
  /// `gh pr create --fill` (title and body from the commits, base = the
  /// repository's default). The route takes no title, body or base.
  Future<GitCreatedPullRequest> gitCreatePullRequest(String repoPath);

  /// `POST /api/git/worktree/add {path, name?, branch?, base?,
  /// existingBranch?}`.
  Future<ProjectWorktreeResult> gitWorktreeAdd(
    String repoPath, {
    String? branch,
    String? base,
    String? existingBranch,
  });

  /// `POST /api/git/worktree/remove {path, worktreePath, force}`.
  Future<void> gitWorktreeRemove(
    String repoPath,
    String worktreePath, {
    bool force = false,
  });

  /// `POST /api/git/branch/switch {path, branch}`.
  Future<void> gitBranchSwitch(String repoPath, String branch);
}
