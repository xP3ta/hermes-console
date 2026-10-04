import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/session.dart';
import 'desktop_control_gateway.dart';

/// Branches that never get a PR lookup: a stranger's fork branch of the same
/// name would otherwise be badged onto the session.
const Set<String> _trunkBranches = {
  'dev',
  'develop',
  'main',
  'master',
  'trunk',
};

const Duration pullRequestStale = Duration(seconds: 60);
const int _maxScannedIds = 500;
const int _maxRequestKeys = 50;

enum PullRequestBucket { merged, closed, draft, open, none }

/// One row of `POST /api/git/review/pr-list`.
final class PullRequestInfo {
  final String branch;
  final int number;
  final String state;
  final bool draft;
  final String title;
  final String url;

  const PullRequestInfo({
    required this.branch,
    required this.number,
    required this.state,
    required this.draft,
    required this.title,
    required this.url,
  });

  PullRequestBucket get bucket {
    switch (state) {
      case 'merged':
        return PullRequestBucket.merged;
      case 'closed':
        return PullRequestBucket.closed;
      case 'open':
        return draft ? PullRequestBucket.draft : PullRequestBucket.open;
    }
    return PullRequestBucket.none;
  }

  static PullRequestInfo? tryParse(Object? value) {
    if (value is! Map) return null;
    final number = value['number'];
    final state = value['state'];
    if (number is! int || number <= 0 || state is! String) return null;
    String text(Object? v, int max) =>
        v is String ? String.fromCharCodes(v.runes.take(max)) : '';
    return PullRequestInfo(
      branch: text(value['branch'], 512),
      number: number,
      state: state,
      draft: value['draft'] == true,
      title: text(value['title'], 512),
      url: text(value['url'], 2048),
    );
  }
}

final class PullRequestList {
  final bool ghReady;
  final List<PullRequestInfo> prs;

  const PullRequestList({required this.ghReady, required this.prs});

  factory PullRequestList.fromJson(Map<String, dynamic> json) {
    final rows = json['prs'];
    return PullRequestList(
      ghReady: json['ghReady'] == true,
      prs: rows is List
          ? rows
                .map(PullRequestInfo.tryParse)
                .whereType<PullRequestInfo>()
                .toList(growable: false)
          : const [],
    );
  }
}

/// `POST /api/profiles/sessions/pull-requests`: PR numbers recovered from
/// transcripts, plus the ids the server actually scanned.
final class PullRequestScan {
  final Map<String, int> pullRequests;
  final List<String> scanned;

  const PullRequestScan({required this.pullRequests, required this.scanned});

  factory PullRequestScan.fromJson(Map<String, dynamic> json) {
    final found = <String, int>{};
    final raw = json['pull_requests'];
    if (raw is Map) {
      for (final entry in raw.entries) {
        final value = entry.value;
        final number = value is Map ? value['number'] : null;
        if (entry.key is String && number is int && number > 0) {
          found[entry.key as String] = number;
        }
      }
    }
    final scanned = json['scanned'];
    return PullRequestScan(
      pullRequests: found,
      scanned: scanned is List
          ? scanned.whereType<String>().toList(growable: false)
          : const [],
    );
  }
}

/// Dashboard git routes behind the session PR tag. Implementations map a
/// missing route (404/405) to an unsupported [DesktopControlFailure].
abstract interface class HermesPullRequestGateway {
  Future<PullRequestList> prList(
    String repoPath, {
    List<String> branches = const [],
    List<int> numbers = const [],
  });

  Future<PullRequestScan> scanSessionPullRequests(List<String> ids);
}

/// Only https links leave the app.
Uri? safePullRequestUri(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  return uri;
}

class _RepoEntry {
  DateTime at;
  final Set<String> branches;
  final Set<int> numbers;
  final Map<String, PullRequestInfo> byBranch;
  final Map<int, PullRequestInfo> byNumber;

  _RepoEntry({
    required this.at,
    Set<String>? branches,
    Set<int>? numbers,
    Map<String, PullRequestInfo>? byBranch,
    Map<int, PullRequestInfo>? byNumber,
  }) : branches = branches ?? {},
       numbers = numbers ?? {},
       byBranch = byBranch ?? {},
       byNumber = byNumber ?? {};
}

/// Reads a session's pull request on demand (menu or detail opening), never
/// on list build or scroll: one `pr-list` per repo per [pullRequestStale]
/// window, one request in flight per repo, trunk branches never asked for.
class PullRequestTagService {
  final HermesPullRequestGateway gateway;
  final DateTime Function() _now;
  final SharedPreferences? _prefs;
  final String _scanKey;

  final Map<String, _RepoEntry> _repos = {};
  final Map<String, Future<void>> _inFlight = {};
  final Map<String, int?> _scanned = {};
  bool _supported = true;
  bool _scanSupported = true;

  PullRequestTagService({
    required this.gateway,
    required String connectionId,
    SharedPreferences? prefs,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _prefs = prefs,
       _scanKey = 'pr_scanned_ids_$connectionId' {
    for (final item in prefs?.getStringList(_scanKey) ?? const <String>[]) {
      final split = item.lastIndexOf('=');
      if (split <= 0) {
        _scanned[item] = null;
      } else {
        _scanned[item.substring(0, split)] = int.tryParse(
          item.substring(split + 1),
        );
      }
    }
  }

  /// False once the server answered 404/405: nothing is shown or asked.
  bool get supported => _supported;

  Future<PullRequestInfo?> tagFor(Session session) async {
    if (!_supported) return null;
    final repo = session.gitRepoRoot?.trim() ?? '';
    if (repo.isEmpty) return null;
    final branch = session.gitBranch?.trim() ?? '';
    if (branch.isNotEmpty && !_trunkBranches.contains(branch.toLowerCase())) {
      return _lookup(repo, branch: branch);
    }
    final number = await _recoveredNumber(session.id);
    if (number == null) return null;
    return _lookup(repo, number: number);
  }

  Future<int?> _recoveredNumber(String sessionId) async {
    if (_scanned.containsKey(sessionId)) return _scanned[sessionId];
    if (!_scanSupported) return null;
    try {
      final scan = await gateway.scanSessionPullRequests([sessionId]);
      final number = scan.pullRequests[sessionId];
      if (scan.scanned.contains(sessionId)) {
        _remember(sessionId, number);
      }
      return number;
    } on DesktopControlFailure catch (failure) {
      if (failure.kind == DesktopControlFailureKind.unsupported) {
        _scanSupported = false;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  void _remember(String id, int? number) {
    _scanned.remove(id);
    _scanned[id] = number;
    while (_scanned.length > _maxScannedIds) {
      _scanned.remove(_scanned.keys.first);
    }
    final prefs = _prefs;
    if (prefs == null) return;
    unawaited(
      prefs.setStringList(_scanKey, [
        for (final e in _scanned.entries)
          e.value == null ? e.key : '${e.key}=${e.value}',
      ]),
    );
  }

  PullRequestInfo? _read(_RepoEntry? entry, String? branch, int? number) {
    if (entry == null) return null;
    if (branch != null) return entry.byBranch[branch];
    return entry.byNumber[number];
  }

  bool _asked(_RepoEntry? entry, String? branch, int? number) =>
      entry != null &&
      (branch != null
          ? entry.branches.contains(branch)
          : entry.numbers.contains(number));

  Future<PullRequestInfo?> _lookup(
    String repo, {
    String? branch,
    int? number,
  }) async {
    // One request per repo at a time, but a waiter whose key the finished
    // request did not carry asks again instead of being answered "none".
    var waited = false;
    for (var turn = 0; turn < 4; turn++) {
      final pending = _inFlight[repo];
      if (pending != null) {
        await pending;
        waited = true;
        continue;
      }
      final entry = _repos[repo];
      final fresh =
          entry != null && _now().difference(entry.at) < pullRequestStale;
      if (fresh && (waited ? _asked(entry, branch, number) : true)) {
        return _asked(entry, branch, number)
            ? _read(entry, branch, number)
            : null;
      }
      final flight = _refresh(repo, entry, branch: branch, number: number);
      _inFlight[repo] = flight;
      try {
        await flight;
      } finally {
        if (identical(_inFlight[repo], flight)) _inFlight.remove(repo);
      }
      return _read(_repos[repo], branch, number);
    }
    return null;
  }

  Future<void> _refresh(
    String repo,
    _RepoEntry? stale, {
    String? branch,
    int? number,
  }) async {
    final branches = <String>{...?stale?.branches, ?branch};
    final numbers = <int>{...?stale?.numbers, ?number};
    while (branches.length + numbers.length > _maxRequestKeys) {
      if (branches.length > 1 && branch != null) {
        branches.remove(branches.firstWhere((b) => b != branch));
      } else if (numbers.isNotEmpty) {
        numbers.remove(numbers.firstWhere((n) => n != number));
      } else {
        break;
      }
    }
    try {
      final result = await gateway.prList(
        repo,
        branches: branches.toList(growable: false),
        numbers: numbers.toList(growable: false),
      );
      final entry = _RepoEntry(
        at: _now(),
        branches: branches,
        numbers: numbers,
      );
      if (result.ghReady) {
        for (final pr in result.prs) {
          if (pr.branch.isNotEmpty) entry.byBranch[pr.branch] = pr;
          entry.byNumber[pr.number] = pr;
        }
      }
      _repos[repo] = entry;
    } on DesktopControlFailure catch (failure) {
      if (failure.kind == DesktopControlFailureKind.unsupported) {
        _supported = false;
        return;
      }
      _keepWhatWeHad(repo, stale, branches, numbers);
    } catch (_) {
      _keepWhatWeHad(repo, stale, branches, numbers);
    }
  }

  /// A failed read keeps the older answer and waits out the window instead of
  /// retrying on every open.
  void _keepWhatWeHad(
    String repo,
    _RepoEntry? stale,
    Set<String> branches,
    Set<int> numbers,
  ) {
    final entry = stale ?? _RepoEntry(at: _now());
    entry.at = _now();
    entry.branches.addAll(branches);
    entry.numbers.addAll(numbers);
    _repos[repo] = entry;
  }
}
