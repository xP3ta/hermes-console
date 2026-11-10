import 'dart:async';

import 'package:hermes_android/core/models/git_review.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/git_review_gateway.dart';

/// Deterministic in-memory [HermesGitReviewGateway]: no socket, no timer.
/// Each read answers from the fields; a [Completer] in [statusGate] holds
/// the next status read until the test completes it.
class FakeGitReviewGateway implements HermesGitReviewGateway {
  FakeGitReviewGateway({
    this.status = const GitRepoStatus(branch: 'main'),
    List<GitReviewFile> files = const [],
    this.writes = true,
  }) : files = List.of(files);

  GitRepoStatus? status;
  List<GitReviewFile> files;
  bool writes;

  /// Answers the branch scope (the branch against its base).
  List<GitReviewFile> branchFiles = const [];

  /// Thrown by every read while set.
  Object? readFailure;

  /// Thrown by commit / stage while set.
  Object? writeFailure;

  /// Answers [gitReviewDiff]; a missing path is an empty diff.
  final Map<String, GitReviewDiff> diffs = {};

  /// Holds the next status read open until completed.
  Completer<void>? statusGate;

  /// Holds the next commit open until completed (a slow commit).
  Completer<void>? commitGate;

  /// Holds the next stage / unstage open until completed.
  Completer<void>? stageGate;

  /// Like the server with nothing staged: `git add -A` runs before the
  /// commit, so a refused commit still leaves every file staged.
  bool stagesAllBeforeCommit = false;

  final List<String> calls = [];
  final List<String> commits = [];
  bool unsupported = false;

  @override
  bool get gitWritesAllowed => writes;

  @override
  bool get gitReviewKnownUnsupported => unsupported;

  void _read() {
    final failure = readFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<GitRepoStatus?> gitRepoStatus(String repoPath) async {
    calls.add('status');
    final gate = statusGate;
    if (gate != null) {
      statusGate = null;
      await gate.future;
    }
    _read();
    return status;
  }

  @override
  Future<GitReviewList> gitReviewList(
    String repoPath, {
    GitReviewScope scope = GitReviewScope.uncommitted,
  }) async {
    calls.add(scope == GitReviewScope.uncommitted ? 'list' : 'list:branch');
    _read();
    return GitReviewList(
      files: List.unmodifiable(
        scope == GitReviewScope.uncommitted ? files : branchFiles,
      ),
      base: scope == GitReviewScope.uncommitted ? null : 'abc123',
    );
  }

  @override
  Future<GitReviewDiff> gitReviewDiff(
    String repoPath,
    GitReviewFile file, {
    GitReviewScope scope = GitReviewScope.uncommitted,
  }) async {
    calls.add('diff:${file.path}:${file.staged}');
    _read();
    return diffs[file.path] ?? const GitReviewDiff();
  }

  void _write() {
    if (!writes) {
      throw const DesktopControlFailure(DesktopControlFailureKind.forbidden);
    }
    final failure = writeFailure;
    if (failure != null) throw failure;
  }

  Future<void> _holdStage() async {
    final gate = stageGate;
    if (gate != null) {
      stageGate = null;
      await gate.future;
    }
  }

  GitReviewFile _withStaged(GitReviewFile file, bool staged) => GitReviewFile(
    path: file.path,
    added: file.added,
    removed: file.removed,
    status: file.status,
    staged: staged,
  );

  @override
  Future<void> gitStage(String repoPath, String file) async {
    calls.add('stage:$file');
    await _holdStage();
    _write();
    files = [for (final f in files) f.path == file ? _withStaged(f, true) : f];
  }

  @override
  Future<void> gitUnstage(String repoPath, String file) async {
    calls.add('unstage:$file');
    await _holdStage();
    _write();
    files = [for (final f in files) f.path == file ? _withStaged(f, false) : f];
  }

  @override
  Future<void> gitCommit(String repoPath, String message) async {
    calls.add('commit');
    final gate = commitGate;
    if (gate != null) {
      commitGate = null;
      await gate.future;
    }
    if (stagesAllBeforeCommit && files.every((f) => !f.staged)) {
      files = [for (final f in files) _withStaged(f, true)];
    }
    _write();
    commits.add(message);
    files = [];
    final current = status;
    if (current != null) {
      status = GitRepoStatus(branch: current.branch, ahead: current.ahead + 1);
    }
  }
}
