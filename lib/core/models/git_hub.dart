/// Data of the Git hub beyond the review pane: the rest of the Dashboard
/// `/api/git/*` routes (`hermes_cli/web_routers/git.py`): `gh-auth`,
/// `worktrees`, `review/commit-context`, `review/ship-info` and the answer
/// of `review/create-pr`. Nothing here talks to a server.
library;

import '../capabilities/spp_safety.dart' show sppMaskLogLine, sppSafeEndpoint;

int _int(Object? value) => value is int ? value : 0;

String _text(Object? value, int max) {
  if (value is! String) return '';
  final trimmed = value.trim();
  return String.fromCharCodes(trimmed.runes.take(max));
}

/// `GET /api/git/gh-auth`: whether the `gh` CLI exists on the server and
/// has a logged-in host. Cached five minutes there.
final class GitGhAuth {
  final bool available;
  final bool authenticated;

  const GitGhAuth({required this.available, required this.authenticated});

  factory GitGhAuth.fromJson(Map<String, dynamic> json) => GitGhAuth(
    available: json['available'] == true,
    authenticated: json['authenticated'] == true,
  );
}

/// One row of `GET /api/git/worktrees` (`git worktree list --porcelain`).
final class GitWorktree {
  final String path;

  /// Short branch name; empty when detached.
  final String branch;
  final bool isMain;
  final bool detached;
  final bool locked;

  const GitWorktree({
    required this.path,
    this.branch = '',
    this.isMain = false,
    this.detached = false,
    this.locked = false,
  });

  static GitWorktree? tryParse(Object? value) {
    if (value is! Map) return null;
    final path = _text(value['path'], 4096);
    if (path.isEmpty) return null;
    return GitWorktree(
      path: path,
      branch: _text(value['branch'], 512),
      isMain: value['isMain'] == true,
      detached: value['detached'] == true,
      locked: value['locked'] == true,
    );
  }

  /// The last folder of the path, for a row title.
  String get name {
    final trimmed = path.replaceFirst(RegExp(r'/+$'), '');
    final slash = trimmed.lastIndexOf('/');
    return slash < 0 ? trimmed : trimmed.substring(slash + 1);
  }
}

/// Lines of the server's commit-context diff the screen keeps at most.
const int kGitCommitContextMaxLines = 600;

/// `GET /api/git/review/commit-context`: what the server would commit
/// (the staged diff, or everything against HEAD when nothing is staged)
/// and the last ten commit subjects. The screen shows it as help for the
/// message; the app invents nothing on top.
final class GitCommitContext {
  /// The diff, one line per entry, every credential masked.
  final List<String> diffLines;

  /// True when the server's text had more lines than kept.
  final bool truncated;

  /// Recent subjects, newest first, masked.
  final List<String> recentSubjects;

  const GitCommitContext({
    this.diffLines = const [],
    this.truncated = false,
    this.recentSubjects = const [],
  });

  factory GitCommitContext.fromJson(Map<String, dynamic> json) {
    final diff = json['diff'];
    final recent = json['recent'];
    final raw = diff is String ? diff.split('\n') : const <String>[];
    while (raw.isNotEmpty && raw.last.trim().isEmpty) {
      raw.removeLast();
    }
    final kept = raw.take(kGitCommitContextMaxLines);
    return GitCommitContext(
      diffLines: List.unmodifiable(kept.map(gitSafeText)),
      truncated: raw.length > kGitCommitContextMaxLines,
      recentSubjects: List.unmodifiable([
        if (recent is String)
          for (final line in recent.split('\n'))
            if (line.trim().isNotEmpty) gitSafeText(line.trim()),
      ]),
    );
  }

  bool get isEmpty => diffLines.isEmpty && recentSubjects.isEmpty;
}

/// A pull request as `ship-info` names it (number, state and link).
final class GitShipPullRequest {
  final String url;

  /// `open`, `merged`, `closed`… lower-cased; empty when unknown.
  final String state;
  final int number;

  const GitShipPullRequest({
    required this.url,
    this.state = '',
    this.number = 0,
  });

  static GitShipPullRequest? tryParse(Object? value) {
    if (value is! Map) return null;
    final url = _text(value['url'], 2048);
    if (url.isEmpty) return null;
    return GitShipPullRequest(
      url: url,
      state: _text(value['state'], 32).toLowerCase(),
      number: _int(value['number']),
    );
  }
}

/// `GET /api/git/review/ship-info`: `gh` logged in, and the current
/// branch's pull request when there is one.
final class GitShipInfo {
  final bool ghReady;
  final GitShipPullRequest? pullRequest;

  const GitShipInfo({required this.ghReady, this.pullRequest});

  factory GitShipInfo.fromJson(Map<String, dynamic> json) => GitShipInfo(
    ghReady: json['ghReady'] == true,
    pullRequest: GitShipPullRequest.tryParse(json['pr']),
  );
}

/// Answer of `POST /api/git/review/create-pr`: the link `gh` printed.
final class GitCreatedPullRequest {
  final String url;

  const GitCreatedPullRequest({required this.url});

  factory GitCreatedPullRequest.fromJson(Map<String, dynamic> json) =>
      GitCreatedPullRequest(url: _text(json['url'], 2048));
}

/// Text from the server (a commit subject, a diff line, a PR title, a
/// path) with any credential hidden before it is drawn: URLs lose their
/// user info and query values, tokens become a mask.
String gitSafeText(String raw) => sppMaskLogLine(raw);

/// A link the app may hand to the system browser: `https` only, no user
/// info, no credential-shaped query. Null for anything else (the screen
/// then shows the masked text and no «Abrir»).
Uri? gitSafeHttpsUrl(String raw) {
  final text = raw.trim();
  if (text.isEmpty || text.length > 2048) return null;
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  // The masker leaves a clean link as it is; anything it would touch stays
  // on screen as masked text only.
  return sppSafeEndpoint(text) == text ? uri : null;
}
