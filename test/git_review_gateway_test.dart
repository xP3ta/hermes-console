// Wire contract of the Git screen: the exact Dashboard `/api/git/*` routes,
// query strings and bodies Hermes Desktop sends on a remote gateway
// (`apps/desktop/src/lib/desktop-git.ts`), errors without server text, and
// no write from a read-only connection.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/git_review.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

final class _RecordingDashboard extends DashboardClient {
  _RecordingDashboard()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  final List<(String, String, Map<String, dynamic>?)> calls = [];
  final List<Duration> postTimeouts = [];
  final List<int> boundedBudgets = [];
  int? failStatus;
  String failBody = 'fatal: secret stderr';
  bool tooLarge = false;
  Map<String, dynamic> Function(String endpoint)? respond;

  Map<String, dynamic> _answer(String endpoint) {
    final status = failStatus;
    if (status != null) {
      throw DashboardHttpException(status, body: failBody);
    }
    return respond?.call(endpoint) ?? <String, dynamic>{};
  }

  /// Deadline of every GET, in call order (apiGet delegates here).
  final List<Duration> getTimeouts = [];

  @override
  Future<Map<String, dynamic>> apiGetWithin(
    String endpoint, {
    required Duration timeout,
    bool retried = false,
  }) async {
    calls.add(('GET', endpoint, null));
    getTimeouts.add(timeout);
    return _answer(endpoint);
  }

  @override
  Future<Map<String, dynamic>> apiGetBoundedWithin(
    String endpoint, {
    required int maxBytes,
    required Duration timeout,
    bool retried = false,
  }) async {
    calls.add(('GET', endpoint, null));
    boundedBudgets.add(maxBytes);
    getTimeouts.add(timeout);
    if (tooLarge) throw const SessionTranscriptTooLargeException();
    return _answer(endpoint);
  }

  @override
  Future<Map<String, dynamic>> apiPost(
    String endpoint, {
    Map<String, dynamic>? body,
    bool retried = false,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add(('POST', endpoint, body));
    postTimeouts.add(timeout);
    return _answer(endpoint);
  }
}

({TuiGatewayClient client, _RecordingDashboard dashboard}) _client({
  bool readOnly = false,
}) {
  final dashboard = _RecordingDashboard();
  final client = TuiGatewayClient(
    SavedConnection(
      id: 'git-wire',
      label: 'wire',
      host: 'hermes.local',
      port: 8642,
      apiKey: 'k',
      readOnly: readOnly,
    ),
    dashboard: dashboard,
    channelFactory: (_, _) => throw StateError('no socket expected'),
  );
  addTearDown(client.close);
  return (client: client, dashboard: dashboard);
}

Matcher _failure(DesktopControlFailureKind kind) => throwsA(
  isA<DesktopControlFailure>().having((f) => f.kind, 'kind', kind),
);

const _repo = '/srv/hermes console';

void main() {
  test('status reads git/status with the folder as a query value', () async {
    final h = _client();
    h.dashboard.respond = (_) => {
      'branch': 'release/1.3.1',
      'changed': 4,
      'added': 82,
      'removed': 1,
    };
    final status = await h.client.gitRepoStatus(_repo);
    expect(h.dashboard.calls.single, (
      'GET',
      'git/status?path=%2Fsrv%2Fhermes+console',
      null,
    ));
    expect(status!.branch, 'release/1.3.1');
    expect(status.changed, 4);
  });

  test('a non-repository folder answers null', () async {
    final h = _client();
    h.dashboard.respond = (_) => {'data': null};
    expect(await h.client.gitRepoStatus(_repo), isNull);
  });

  test('review list asks the uncommitted scope', () async {
    final h = _client();
    h.dashboard.respond = (_) => {
      'files': [
        {'path': 'a.dart', 'added': 1, 'removed': 0, 'status': 'M'},
      ],
      'base': null,
    };
    final list = await h.client.gitReviewList(_repo);
    expect(
      h.dashboard.calls.single.$2,
      'git/review/list?path=%2Fsrv%2Fhermes+console&scope=uncommitted',
    );
    expect(list.files.single.path, 'a.dart');
  });

  test('diff names the file, the scope and its staged side', () async {
    final h = _client();
    h.dashboard.respond = (_) => {
      'diff': '@@ -1 +1 @@\n-a\n+b\n',
    };
    final diff = await h.client.gitReviewDiff(
      _repo,
      const GitReviewFile(path: 'lib/a b.dart', staged: true),
    );
    expect(
      h.dashboard.calls.single.$2,
      'git/review/diff?path=%2Fsrv%2Fhermes+console'
      '&file=lib%2Fa+b.dart&scope=uncommitted&staged=true',
    );
    expect(h.dashboard.boundedBudgets.single, 512 * 1024);
    expect(diff.lines.map((l) => l.kind), [
      GitDiffLineKind.hunk,
      GitDiffLineKind.removed,
      GitDiffLineKind.added,
    ]);
  });

  test('a diff past the read budget comes back too large', () async {
    final h = _client();
    h.dashboard.tooLarge = true;
    final diff = await h.client.gitReviewDiff(
      _repo,
      const GitReviewFile(path: 'big.json'),
    );
    expect(diff.tooLarge, isTrue);
    expect(diff.lines, isEmpty);
  });

  test('stage / unstage post the one file', () async {
    final h = _client();
    await h.client.gitStage(_repo, 'a.dart');
    await h.client.gitUnstage(_repo, 'a.dart');
    // Lists, not records: a record compares its Map field by identity.
    final calls = [for (final c in h.dashboard.calls) [c.$2, c.$3]];
    expect(calls, [
      ['git/review/stage', {'path': _repo, 'file': 'a.dart'}],
      ['git/review/unstage', {'path': _repo, 'file': 'a.dart'}],
    ]);
  });

  test('commit posts the message as data', () async {
    final h = _client();
    const message = r"fix: it's $(touch x) `id`; rm -rf ~" '\nbody';
    await h.client.gitCommit(_repo, message);
    final call = h.dashboard.calls.single;
    expect(call.$2, 'git/review/commit');
    expect(call.$3, {'path': _repo, 'message': message});
    expect(h.dashboard.postTimeouts.single, const Duration(minutes: 2));
  });

  test('reads, diffs and staging get Desktop\'s 30 s deadline', () async {
    final h = _client();
    h.dashboard.respond = (endpoint) => endpoint.startsWith('git/status')
        ? const {'branch': 'main', 'changed': 1}
        : const {'files': <Object>[], 'diff': ''};
    await h.client.gitRepoStatus(_repo);
    await h.client.gitReviewList(_repo);
    await h.client.gitReviewDiff(_repo, const GitReviewFile(path: 'a.dart'));
    await h.client.gitStage(_repo, 'a.dart');
    await h.client.gitUnstage(_repo, 'a.dart');
    const deadline = Duration(seconds: 30);
    expect(TuiGatewayClient.gitRouteTimeout, deadline);
    expect(h.dashboard.getTimeouts, [deadline, deadline, deadline]);
    expect(h.dashboard.postTimeouts, [deadline, deadline]);
  });

  test('a refused mutation is rejected, without the server text', () async {
    final h = _client();
    h.dashboard.failStatus = 400;
    await expectLater(
      h.client.gitCommit(_repo, 'msg'),
      _failure(DesktopControlFailureKind.rejected),
    );
  });

  test('404 turns the capability off without asking again', () async {
    final h = _client();
    h.dashboard.failStatus = 404;
    await expectLater(
      h.client.gitRepoStatus(_repo),
      _failure(DesktopControlFailureKind.unsupported),
    );
    expect(h.client.gitReviewKnownUnsupported, isTrue);
    await expectLater(
      h.client.gitReviewList(_repo),
      _failure(DesktopControlFailureKind.unsupported),
    );
    expect(h.dashboard.calls.length, 1);
  });

  test('a read-only connection writes nothing', () async {
    final h = _client(readOnly: true);
    expect(h.client.gitWritesAllowed, isFalse);
    expect(
      () => h.client.gitCommit(_repo, 'msg'),
      _failure(DesktopControlFailureKind.forbidden),
    );
    expect(
      () => h.client.gitStage(_repo, 'a'),
      _failure(DesktopControlFailureKind.forbidden),
    );
    expect(h.dashboard.calls, isEmpty);
  });

  test('control characters in a path are refused before any call', () async {
    final h = _client();
    expect(
      () => h.client.gitRepoStatus('/srv/a\u0000b'),
      _failure(DesktopControlFailureKind.rejected),
    );
    expect(h.dashboard.calls, isEmpty);
  });

  test('a refused action keeps only its classified reason (F2b)', () async {
    final h = _client();
    h.dashboard.failStatus = 400;
    h.dashboard.failBody = jsonEncode({
      'detail': 'error: Committing is not possible because you have '
          'unmerged files.',
    });
    await expectLater(
      h.client.gitCommit(_repo, 'msg'),
      throwsA(
        isA<GitActionFailure>().having(
          (f) => f.problem,
          'problem',
          GitActionProblem.conflict,
        ),
      ),
    );
    // A refused action does not turn the routes off.
    expect(h.client.gitReviewKnownUnsupported, isFalse);
  });
}
