import '../models/git_review.dart';

/// The Dashboard `/api/git/*` review routes, exactly as Hermes Desktop calls
/// them on a remote gateway (`apps/desktop/src/lib/desktop-git.ts`). The
/// server runs git itself (`hermes_cli/web_git.py`): the app sends a
/// folder and a message, never a command line.
///
/// Implementations map a missing route (404/405) to an unsupported
/// [DesktopControlFailure], a refused mutation (400: git failed) to a
/// [GitActionFailure] when its reason is recognised (else `rejected`), and a
/// write on a read-only connection to `forbidden`. None carries the
/// server's text.
abstract interface class HermesGitReviewGateway {
  /// False on a read-only connection: the screen shows no write action.
  bool get gitWritesAllowed;

  /// True once a git route answered 404/405 on this connection.
  bool get gitReviewKnownUnsupported;

  /// `GET /api/git/status?path=`; null when [repoPath] is not a repository.
  Future<GitRepoStatus?> gitRepoStatus(String repoPath);

  /// `GET /api/git/review/list?path=&scope=`.
  Future<GitReviewList> gitReviewList(
    String repoPath, {
    GitReviewScope scope = GitReviewScope.uncommitted,
  });

  /// `GET /api/git/review/diff?path=&file=&scope=&staged=`. A body past the
  /// app's read budget comes back as [GitReviewDiff.tooLarge].
  Future<GitReviewDiff> gitReviewDiff(
    String repoPath,
    GitReviewFile file, {
    GitReviewScope scope = GitReviewScope.uncommitted,
  });

  /// `POST /api/git/review/stage {path, file}`: one file, as Desktop's
  /// per-file toggle.
  Future<void> gitStage(String repoPath, String file);

  /// `POST /api/git/review/unstage {path, file}`.
  Future<void> gitUnstage(String repoPath, String file);

  /// `POST /api/git/review/commit {path, message}`: the server stages
  /// everything first when nothing is staged, then commits. Local only.
  Future<void> gitCommit(String repoPath, String message);
}
