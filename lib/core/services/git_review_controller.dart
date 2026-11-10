import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/git_review.dart';
import 'desktop_control_gateway.dart';
import 'git_review_gateway.dart';

/// Last repository status read per connection and folder: the notch's Git
/// pill shows it (number of changed files) without asking the server again.
/// Memory only; a new read replaces it.
final class GitStatusCache {
  GitStatusCache._();

  static final GitStatusCache instance = GitStatusCache._();

  final Map<String, GitRepoStatus?> _byRepo = {};

  /// Latest read started per folder. A read that answers after a newer one
  /// started is dropped, so an old count never overwrites a fresh one.
  final Map<String, int> _readSeq = {};

  static String _key(String connectionId, String repoPath) =>
      '$connectionId\n${repoPath.trim()}';

  /// Starts a read of [repoPath]'s status; pass the ticket to
  /// [recordRead] with its answer.
  int beginRead(String connectionId, String repoPath) {
    final key = _key(connectionId, repoPath);
    return _readSeq[key] = (_readSeq[key] ?? 0) + 1;
  }

  /// Records the answer of the read [ticket] started, unless a newer read
  /// of the same folder started since. Returns whether it was recorded.
  bool recordRead(
    int ticket,
    String connectionId,
    String repoPath,
    GitRepoStatus? status,
  ) {
    final key = _key(connectionId, repoPath);
    if (_readSeq[key] != ticket) return false;
    _byRepo[key] = status;
    return true;
  }

  /// True once a read answered for this folder (null = not a repository).
  bool knows(String connectionId, String repoPath) =>
      _byRepo.containsKey(_key(connectionId, repoPath));

  GitRepoStatus? statusOf(String connectionId, String repoPath) =>
      _byRepo[_key(connectionId, repoPath)];

  /// Records [status] now, as the newest answer for the folder (reads in
  /// flight from before are then dropped).
  void record(String connectionId, String repoPath, GitRepoStatus? status) {
    recordRead(
      beginRead(connectionId, repoPath),
      connectionId,
      repoPath,
      status,
    );
  }

  /// Reads the status into the cache; errors leave what was known.
  Future<void> prefetch(
    HermesGitReviewGateway gateway,
    String connectionId,
    String repoPath,
  ) async {
    if (gateway.gitReviewKnownUnsupported) return;
    final ticket = beginRead(connectionId, repoPath);
    try {
      final status = await gateway.gitRepoStatus(repoPath);
      recordRead(ticket, connectionId, repoPath, status);
    } catch (error) {
      debugPrint('[git] status prefetch failed (${error.runtimeType})');
    }
  }

  @visibleForTesting
  void clear() {
    _byRepo.clear();
    _readSeq.clear();
  }
}

/// The notch's Git pill for a conversation: shown only once a read has
/// confirmed that the conversation's folder is a repository the gateway can
/// serve. A folder not read yet (the read in flight), not a repository, or
/// on a Hermes without the git routes has no pill, so the sheet never shows
/// it and then loses it. Its badge is the last known number of changed
/// files.
({bool available, int? badge}) gitNotchEntry({
  required HermesGitReviewGateway? gateway,
  required String? repoPath,
  required String connectionId,
  GitStatusCache? cache,
}) {
  const none = (available: false, badge: null);
  if (gateway == null ||
      repoPath == null ||
      gateway.gitReviewKnownUnsupported) {
    return none;
  }
  final known = cache ?? GitStatusCache.instance;
  final status = known.statusOf(connectionId, repoPath);
  if (status == null) return none;
  return (available: true, badge: status.changed);
}

/// What the screen shows instead of the file list.
enum GitReviewPhase {
  /// First read in flight.
  loading,

  /// The folder is a repository; [GitReviewController.files] may be empty
  /// («Sin diferencias»).
  ready,

  /// Desktop's «No es un repositorio Git».
  notRepo,

  /// This Hermes has no `/api/git/*` routes.
  unsupported,

  /// The read failed (no connection, refused…); the screen offers a retry.
  failed,
}

/// The state of Hermes Desktop's review pane (`src/store/review.ts`) for one
/// folder, uncommitted scope: the changed files, the repository status of
/// the coding row, stage / unstage, and the local commit behind a busy flag.
///
/// Reads that resolve after a newer one started are dropped (sequence
/// guards, like Desktop's). After [dispose] nothing is notified.
class GitReviewController extends ChangeNotifier {
  GitReviewController({
    required this.gateway,
    required this.connectionId,
    required this.repoPath,
    GitStatusCache? cache,
  }) : _cache = cache ?? GitStatusCache.instance;

  final HermesGitReviewGateway gateway;
  final String connectionId;
  final String repoPath;
  final GitStatusCache _cache;

  GitReviewPhase _phase = GitReviewPhase.loading;
  GitReviewPhase get phase => _phase;

  GitRepoStatus? _status;
  GitRepoStatus? get status => _status;

  List<GitReviewFile> _files = const [];
  List<GitReviewFile> get files => _files;
  bool get hasFiles => _files.isNotEmpty;

  /// Unmerged paths (status `conflicted`, or a `U` row). Git refuses to
  /// commit them, so the commit actions are off until they are resolved.
  int get conflicts {
    final counted = _status?.conflicted ?? 0;
    final rows = _files.where((file) => file.status == 'U').length;
    return counted > rows ? counted : rows;
  }

  bool get hasConflicts => conflicts > 0;

  /// The failure behind [GitReviewPhase.failed].
  Object? _failure;
  Object? get failure => _failure;

  bool _loading = false;

  /// A read is in flight (also while files are already shown).
  bool get loading => _loading;

  bool _commitBusy = false;

  /// A commit is running: the commit button and field are off.
  bool get commitBusy => _commitBusy;

  bool get writesAllowed => gateway.gitWritesAllowed;

  GitReviewScope _scope = GitReviewScope.uncommitted;

  /// What the list shows: the working tree, or the branch against its
  /// base. Stage / unstage / discard / commit act on the working tree
  /// only, so they are off in the branch scope.
  GitReviewScope get scope => _scope;
  bool get isUncommittedScope => _scope == GitReviewScope.uncommitted;

  /// Changes the scope and re-reads the list.
  Future<void> setScope(GitReviewScope scope) async {
    if (scope == _scope) return;
    _scope = scope;
    _files = const [];
    _notify();
    await refresh();
  }

  int _refreshSeq = 0;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Status + uncommitted list, read together.
  Future<void> refresh() async {
    final seq = ++_refreshSeq;
    final ticket = _cache.beginRead(connectionId, repoPath);
    _loading = true;
    _notify();
    try {
      final statusRead = gateway.gitRepoStatus(repoPath);
      final listRead = gateway.gitReviewList(repoPath, scope: _scope);
      // Both reads run at once. When the status read fails (or says "not a
      // repository") the list read is never awaited, and its own failure
      // would escape as an unhandled error: give it a listener now. Awaiting
      // it below still delivers its result or its error.
      unawaited(listRead.then<void>((_) {}, onError: (_) {}));
      final status = await statusRead;
      if (status == null) {
        // Not a repository: the list read is moot.
        if (seq != _refreshSeq || _disposed) return;
        _cache.recordRead(ticket, connectionId, repoPath, null);
        _status = null;
        _files = const [];
        _phase = GitReviewPhase.notRepo;
        return;
      }
      final list = await listRead;
      if (seq != _refreshSeq || _disposed) return;
      _cache.recordRead(ticket, connectionId, repoPath, status);
      _status = status;
      _files = list.files;
      _failure = null;
      _phase = GitReviewPhase.ready;
    } on DesktopControlFailure catch (failure) {
      if (seq != _refreshSeq || _disposed) return;
      _failure = failure;
      _phase = failure.kind == DesktopControlFailureKind.unsupported
          ? GitReviewPhase.unsupported
          : GitReviewPhase.failed;
    } catch (error) {
      if (seq != _refreshSeq || _disposed) return;
      _failure = error;
      _phase = GitReviewPhase.failed;
    } finally {
      if (seq == _refreshSeq) {
        _loading = false;
        _notify();
      }
    }
  }

  /// One file's diff; the file's [GitReviewFile.staged] picks the staged or
  /// the working-tree side, as in Desktop.
  Future<GitReviewDiff> diffOf(GitReviewFile file) async =>
      gateway.gitReviewDiff(repoPath, file, scope: _scope);

  /// Desktop's per-file stage / unstage toggle, then a re-read.
  Future<void> toggleStaged(GitReviewFile file) async {
    if (file.staged) {
      await gateway.gitUnstage(repoPath, file.path);
    } else {
      await gateway.gitStage(repoPath, file.path);
    }
    await refresh();
  }

  /// «Hacer commit», Desktop's local commit: the server stages everything
  /// when nothing is staged, then commits. Throws (the screen tells why);
  /// nothing runs while a commit is busy or the message is empty.
  Future<bool> commit(String message) async {
    final text = message.trim();
    if (text.isEmpty ||
        !hasFiles ||
        hasConflicts ||
        _commitBusy ||
        !writesAllowed ||
        !isUncommittedScope) {
      return false;
    }
    _commitBusy = true;
    _notify();
    try {
      await gateway.gitCommit(repoPath, text);
    } catch (_) {
      // With nothing staged the server runs `git add -A` before the commit:
      // a refused commit (a hook, the identity) can leave everything staged
      // there. Show the tree as it is now, then say why it failed.
      _commitBusy = false;
      unawaited(refresh());
      rethrow;
    } finally {
      _commitBusy = false;
      _notify();
    }
    await refresh();
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    _refreshSeq++;
    super.dispose();
  }
}
