/// Git review data, read from the Dashboard `/api/git/*` routes Hermes
/// Desktop uses on a remote gateway (`apps/desktop/src/lib/desktop-git.ts`).
/// Shapes mirror Desktop's `HermesRepoStatus`, `HermesReviewFile` and
/// `HermesReviewList` (`src/global.d.ts`).
library;

import 'dart:convert';

int _int(Object? value) => value is int ? value : 0;

String? _text(Object? value, int max) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return String.fromCharCodes(trimmed.runes.take(max));
}

/// `GET /api/git/status?path=`: the compact working-tree status behind
/// Desktop's composer coding row. Null on the wire for a non-repo.
final class GitRepoStatus {
  /// Branch name; null when detached or unknown.
  final String? branch;

  /// The repo's trunk (`main` / `master` / …), when one is detected.
  final String? defaultBranch;
  final bool detached;
  final int ahead;
  final int behind;
  final int staged;
  final int unstaged;
  final int untracked;
  final int conflicted;

  /// Distinct changed paths (tracked modified + conflicts + untracked).
  final int changed;

  /// +/- of tracked changes vs HEAD; untracked insertions folded into
  /// [added] (Desktop's coding row reads the same numbers).
  final int added;
  final int removed;

  const GitRepoStatus({
    this.branch,
    this.defaultBranch,
    this.detached = false,
    this.ahead = 0,
    this.behind = 0,
    this.staged = 0,
    this.unstaged = 0,
    this.untracked = 0,
    this.conflicted = 0,
    this.changed = 0,
    this.added = 0,
    this.removed = 0,
  });

  /// Parses the route's JSON. A `null` body (not a repository) arrives as
  /// `{data: null}` from the Dashboard client and yields null.
  static GitRepoStatus? tryParse(Map<String, dynamic> json) {
    if (!json.containsKey('changed') && !json.containsKey('branch')) {
      return null;
    }
    return GitRepoStatus(
      branch: _text(json['branch'], 512),
      defaultBranch: _text(json['defaultBranch'], 512),
      detached: json['detached'] == true,
      ahead: _int(json['ahead']),
      behind: _int(json['behind']),
      staged: _int(json['staged']),
      unstaged: _int(json['unstaged']),
      untracked: _int(json['untracked']),
      conflicted: _int(json['conflicted']),
      changed: _int(json['changed']),
      added: _int(json['added']),
      removed: _int(json['removed']),
    );
  }

  /// Desktop's coding row shows `+A −R` when there is a line delta, else
  /// «N cambios» when only untracked files changed.
  bool get hasLineDelta => added > 0 || removed > 0;
  bool get untrackedOnly => !hasLineDelta && untracked > 0;
}

/// The review scope sent to the server: the working tree against HEAD
/// (`uncommitted`) or the branch against its merge base with the trunk
/// (`branch`, Desktop's «all branch changes»). Desktop's last-turn scope
/// has no screen here.
enum GitReviewScope {
  uncommitted('uncommitted'),
  branch('branch');

  const GitReviewScope(this.wire);

  final String wire;
}

/// One changed file of the review list (Desktop's `HermesReviewFile`).
final class GitReviewFile {
  /// Repo-relative path.
  final String path;
  final int added;
  final int removed;

  /// M(odified) A(dded) D(eleted) R(enamed) C(opied) U(nmerged) ?(untracked).
  final String status;
  final bool staged;

  const GitReviewFile({
    required this.path,
    this.added = 0,
    this.removed = 0,
    this.status = 'M',
    this.staged = false,
  });

  static GitReviewFile? tryParse(Object? value) {
    if (value is! Map) return null;
    final path = _text(value['path'], 4096);
    if (path == null) return null;
    final status = _text(value['status'], 4);
    return GitReviewFile(
      path: path,
      added: _int(value['added']),
      removed: _int(value['removed']),
      status: status == null ? 'M' : status.substring(0, 1).toUpperCase(),
      staged: value['staged'] == true,
    );
  }

  /// The path without a trailing `/`: an untracked folder arrives as
  /// `nueva/` (`git status --porcelain=v2`, default untracked mode), and
  /// Desktop drops the empty last segment (`tree-data.ts`).
  String get _trimmed => path.replaceFirst(RegExp(r'/+$'), '');

  String get name {
    final trimmed = _trimmed;
    final slash = trimmed.lastIndexOf('/');
    return slash < 0 ? trimmed : trimmed.substring(slash + 1);
  }

  /// Folder inside the repo; empty at the root.
  String get directory {
    final trimmed = _trimmed;
    final slash = trimmed.lastIndexOf('/');
    return slash < 0 ? '' : trimmed.substring(0, slash);
  }
}

/// `GET /api/git/review/list` (Desktop's `HermesReviewList`).
final class GitReviewList {
  final List<GitReviewFile> files;

  /// The resolved base ref of a branch / last-turn scope; null otherwise.
  final String? base;

  const GitReviewList({this.files = const [], this.base});

  /// Rows sorted by path (the server sorts too) without the paths Desktop
  /// always hides from review ([isExcludedReviewPath]).
  factory GitReviewList.fromJson(Map<String, dynamic> json) {
    final rows = json['files'];
    final files = <GitReviewFile>[
      if (rows is List)
        for (final row in rows) ?GitReviewFile.tryParse(row),
    ]..removeWhere((file) => isExcludedReviewPath(file.path));
    files.sort((a, b) => a.path.compareTo(b.path));
    return GitReviewList(
      files: List.unmodifiable(files),
      base: _text(json['base'], 512),
    );
  }
}

/// Always hidden from review, regardless of `.gitignore`: VCS internals,
/// dependency / build / cache folders and OS noise (Desktop's
/// `ALWAYS_EXCLUDED`, `src/lib/excluded-paths.ts`).
const Set<String> kGitReviewAlwaysExcluded = {
  '.git',
  '.hg',
  '.svn',
  'node_modules',
  'bower_components',
  '.venv',
  'venv',
  'env',
  '__pycache__',
  '.mypy_cache',
  '.pytest_cache',
  '.ruff_cache',
  '.tox',
  '.gradle',
  '.idea',
  'dist',
  'build',
  'out',
  'target',
  'vendor',
  'Pods',
  '.next',
  '.nuxt',
  '.svelte-kit',
  '.output',
  '.turbo',
  '.parcel-cache',
  '.cache',
  '.terraform',
  '.expo',
  '.angular',
  'coverage',
  '.DS_Store',
  'Thumbs.db',
};

/// True when any segment of a repo-relative path is always excluded.
bool isExcludedReviewPath(String path) =>
    path.split(RegExp(r'[/\\]')).any(kGitReviewAlwaysExcluded.contains);

/// What a line of a unified diff is.
enum GitDiffLineKind { context, added, removed, hunk, note }

final class GitDiffLine {
  final GitDiffLineKind kind;

  /// The line without its `+`/`-`/space prefix; the whole header of a hunk.
  final String text;

  /// Line number in the new file (old file for a removal); null for hunk
  /// headers and notes.
  final int? number;

  const GitDiffLine(this.kind, this.text, {this.number});
}

/// One file's diff as `GET /api/git/review/diff` returns it.
final class GitReviewDiff {
  final List<GitDiffLine> lines;
  final bool binary;

  /// The diff passed the app's read budget and was not loaded.
  final bool tooLarge;

  const GitReviewDiff({
    this.lines = const [],
    this.binary = false,
    this.tooLarge = false,
  });

  /// Desktop's «No hay diferencias que mostrar».
  bool get isEmpty => !binary && !tooLarge && lines.isEmpty;
}

/// Lines of a diff the screen draws at most.
const int kGitDiffMaxLines = 4000;

/// Parses unified diff text into numbered lines. File headers (`diff --git`,
/// `index`, `---`, `+++`, modes) are dropped; hunks keep their `@@` header.
///
/// A file with unresolved conflicts comes back as git's combined diff
/// (`diff --cc`, hunks `@@@ -a,b -c,d +e,f @@@`): every line carries one
/// marker column per parent. Those lines are kept as they are, coloured by
/// their markers (any `-` removed, any `+` added) and numbered in the
/// working-tree file.
GitReviewDiff parseGitDiff(String raw, {int maxLines = kGitDiffMaxLines}) {
  final lines = <GitDiffLine>[];
  var binary = false;
  var inHunk = false;
  var oldLine = 0;
  var newLine = 0;
  // 0 in a unified hunk; the number of parents in a combined one.
  var markers = 0;
  final header = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');
  final combinedHeader = RegExp(
    r'^(@{3,})(?: -\d+(?:,\d+)?)+ \+(\d+)(?:,\d+)? @{3,}',
  );
  for (final rawLine in raw.split('\n')) {
    // A CRLF file keeps its \r on each line: drop it so it is not drawn.
    final line = rawLine.endsWith('\r')
        ? rawLine.substring(0, rawLine.length - 1)
        : rawLine;
    if (lines.length >= maxLines) {
      return GitReviewDiff(lines: List.unmodifiable(lines), tooLarge: true);
    }
    if (line.startsWith('diff --git ') || line.startsWith('diff --cc ')) {
      inHunk = false;
      continue;
    }
    if (line.startsWith('Binary files ') || line == 'GIT binary patch') {
      binary = true;
      inHunk = false;
      continue;
    }
    final combined = combinedHeader.firstMatch(line);
    if (combined != null) {
      inHunk = true;
      markers = combined.group(1)!.length - 1;
      newLine = int.parse(combined.group(2)!);
      lines.add(GitDiffLine(GitDiffLineKind.hunk, line));
      continue;
    }
    final hunk = header.firstMatch(line);
    if (hunk != null) {
      inHunk = true;
      markers = 0;
      oldLine = int.parse(hunk.group(1)!);
      newLine = int.parse(hunk.group(2)!);
      lines.add(GitDiffLine(GitDiffLineKind.hunk, line));
      continue;
    }
    if (!inHunk) continue;
    if (markers > 0) {
      if (line.startsWith(r'\')) {
        lines.add(GitDiffLine(GitDiffLineKind.note, line));
        continue;
      }
      final columns = line.length < markers ? line : line.substring(0, markers);
      if (line.isEmpty || columns.contains(RegExp(r'[^ +\-]'))) {
        inHunk = false;
        continue;
      }
      final text = line.substring(columns.length);
      if (columns.contains('-')) {
        lines.add(GitDiffLine(GitDiffLineKind.removed, text));
      } else if (columns.contains('+')) {
        lines.add(GitDiffLine(GitDiffLineKind.added, text, number: newLine));
        newLine++;
      } else {
        lines.add(GitDiffLine(GitDiffLineKind.context, text, number: newLine));
        newLine++;
      }
      continue;
    }
    if (line.startsWith('+')) {
      lines.add(
        GitDiffLine(GitDiffLineKind.added, line.substring(1), number: newLine),
      );
      newLine++;
    } else if (line.startsWith('-')) {
      lines.add(
        GitDiffLine(
          GitDiffLineKind.removed,
          line.substring(1),
          number: oldLine,
        ),
      );
      oldLine++;
    } else if (line.startsWith(' ')) {
      lines.add(
        GitDiffLine(
          GitDiffLineKind.context,
          line.substring(1),
          number: newLine,
        ),
      );
      oldLine++;
      newLine++;
    } else if (line.startsWith(r'\')) {
      lines.add(GitDiffLine(GitDiffLineKind.note, line));
    } else if (line.isNotEmpty) {
      inHunk = false;
    }
  }
  return GitReviewDiff(lines: List.unmodifiable(lines), binary: binary);
}

/// Why a git action failed on the server, read from the 400 the Dashboard
/// answers with git's stderr (`hermes_cli/web_git.py`). Only the
/// kind is kept: the text itself never reaches the screen.
enum GitActionProblem {
  /// Unmerged paths: the commit cannot go through.
  conflict,

  /// Git has no author name / email on the server.
  noIdentity,

  /// Nothing to commit.
  nothingToCommit,

  /// The remote refused the push (non-fast-forward): fetch first.
  pushRejected,

  /// The remote asked for credentials the server does not have.
  remoteAuth,

  /// The remote could not be reached (DNS, connection, timeout).
  remoteUnreachable,

  /// The branch has no remote to push to.
  noRemote,

  /// `gh` is missing or not logged in on the server.
  ghNotReady,

  /// A pull request already exists for the branch.
  prExists,

  /// No commits between the base branch and this one.
  prNoCommits,

  /// Local changes would be overwritten (branch switch, worktree remove).
  localChanges,

  /// The branch or ref does not exist.
  branchNotFound,
}

/// A git action the server ran and refused, with its classified reason.
final class GitActionFailure implements Exception {
  final GitActionProblem problem;

  const GitActionFailure(this.problem);

  @override
  String toString() => 'GitActionFailure(${problem.name})';
}

/// Classifies the `detail` of a refused git route. Git prints English
/// unless the server's locale says otherwise; an unknown text is null (the
/// screen then says the action was refused).
GitActionProblem? classifyGitFailureDetail(String body) {
  var text = body;
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['detail'] is String) {
      text = decoded['detail'] as String;
    }
  } on FormatException {
    // Not JSON: classify the raw body.
  }
  final t = text.toLowerCase();
  bool has(String needle) => t.contains(needle);
  if (has('unmerged') ||
      has('fix conflicts') ||
      has('unresolved conflict') ||
      has('merge conflict')) {
    return GitActionProblem.conflict;
  }
  if (has('please tell me who you are') ||
      has('author identity unknown') ||
      has('committer identity unknown') ||
      has('empty ident') ||
      has('identity lookup failed') ||
      has('invalid commit identity')) {
    return GitActionProblem.noIdentity;
  }
  if (has('nothing to commit') ||
      has('nothing added to commit') ||
      has('no changes added to commit')) {
    return GitActionProblem.nothingToCommit;
  }
  // Ship flow (push / gh): the order matters, a gh refusal names the PR
  // before any remote wording.
  if (has('already exists') && has('pull request')) {
    return GitActionProblem.prExists;
  }
  if (has('no commits between')) return GitActionProblem.prNoCommits;
  if (has('is gh installed') ||
      has('not logged in') ||
      has('gh auth login') ||
      has('gh: command not found') ||
      has('gh: not found')) {
    return GitActionProblem.ghNotReady;
  }
  if (has('non-fast-forward') ||
      has('fetch first') ||
      has('[rejected]') ||
      has('failed to push some refs')) {
    return GitActionProblem.pushRejected;
  }
  if (has('authentication failed') ||
      has('permission denied') ||
      has('could not read username') ||
      has('could not read password') ||
      has('terminal prompts disabled') ||
      (has('403') && has('push'))) {
    return GitActionProblem.remoteAuth;
  }
  if (has('could not resolve host') ||
      has('could not read from remote') ||
      has('connection refused') ||
      has('connection timed out') ||
      has('network is unreachable')) {
    return GitActionProblem.remoteUnreachable;
  }
  if (has('no configured push destination') ||
      has("'origin' does not appear to be a git repository") ||
      has('no remote')) {
    return GitActionProblem.noRemote;
  }
  // Branch switch and worktree remove.
  if (has('would be overwritten') ||
      has('local changes') ||
      has('contains modified or untracked files') ||
      has('use --force')) {
    return GitActionProblem.localChanges;
  }
  if (has('invalid reference') ||
      has('did not match any') ||
      has('not a valid branch') ||
      has('branch name is required') ||
      has('is not a working tree')) {
    return GitActionProblem.branchNotFound;
  }
  return null;
}
