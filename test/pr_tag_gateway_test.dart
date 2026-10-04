// Wire contract of the PR tag reads: exact Dashboard routes and bodies, and
// 404/405 turning the capability off without touching the socket.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

final class _RecordingDashboard extends DashboardClient {
  _RecordingDashboard()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  final List<(String, Map<String, dynamic>?)> posts = [];
  int? failStatus;
  Map<String, dynamic> Function(String endpoint)? respond;

  @override
  Future<Map<String, dynamic>> apiPost(
    String endpoint, {
    Map<String, dynamic>? body,
    bool retried = false,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    posts.add((endpoint, body));
    final status = failStatus;
    if (status != null) throw DashboardHttpException(status);
    return respond?.call(endpoint) ?? <String, dynamic>{};
  }
}

({TuiGatewayClient client, _RecordingDashboard dashboard}) _client() {
  final dashboard = _RecordingDashboard();
  final client = TuiGatewayClient(
    SavedConnection(
      id: 'pr-wire',
      label: 'wire',
      host: 'hermes.local',
      port: 8642,
      apiKey: 'k',
    ),
    dashboard: dashboard,
    channelFactory: (_, _) => throw StateError('no socket expected'),
  );
  addTearDown(client.close);
  return (client: client, dashboard: dashboard);
}

void main() {
  test('pr-list posts path, branches and numbers', () async {
    final h = _client();
    h.dashboard.respond = (_) => {
      'ghReady': true,
      'prs': [
        {
          'branch': 'feat/x',
          'draft': true,
          'number': 9,
          'state': 'open',
          'title': 'T',
          'url': 'https://github.example.test/o/r/pull/9',
        },
      ],
    };
    final result = await h.client.prList(
      '/srv/repo',
      branches: ['feat/x'],
      numbers: [4],
    );
    expect(h.dashboard.posts.single.$1, 'git/review/pr-list');
    expect(h.dashboard.posts.single.$2, {
      'path': '/srv/repo',
      'branches': ['feat/x'],
      'numbers': [4],
    });
    expect(result.ghReady, isTrue);
    expect(result.prs.single.number, 9);
    expect(result.prs.single.draft, isTrue);
  });

  test('a null or malformed list is an empty list', () async {
    final h = _client();
    h.dashboard.respond = (_) => {'ghReady': null, 'prs': null};
    final result = await h.client.prList('/srv/repo', branches: ['a']);
    expect(result.ghReady, isFalse);
    expect(result.prs, isEmpty);
  });

  test('404 on pr-list is unsupported and is not retried', () async {
    final h = _client();
    h.dashboard.failStatus = 404;
    await expectLater(
      h.client.prList('/srv/repo', branches: ['a']),
      throwsA(
        isA<DesktopControlFailure>().having(
          (f) => f.kind,
          'kind',
          DesktopControlFailureKind.unsupported,
        ),
      ),
    );
    await expectLater(
      h.client.prList('/srv/repo', branches: ['a']),
      throwsA(isA<DesktopControlFailure>()),
    );
    expect(h.dashboard.posts.length, 1);
  });

  test('scan posts ids and parses recovered numbers', () async {
    final h = _client();
    h.dashboard.respond = (_) => {
      'pull_requests': {
        's1': {'number': 12, 'url': 'https://github.example.test/o/r/pull/12'},
      },
      'scanned': ['s1', 's2'],
    };
    final scan = await h.client.scanSessionPullRequests(['s1', 's2']);
    expect(h.dashboard.posts.single.$1, 'profiles/sessions/pull-requests');
    expect(h.dashboard.posts.single.$2, {
      'ids': ['s1', 's2'],
    });
    expect(scan.pullRequests, {'s1': 12});
    expect(scan.scanned, ['s1', 's2']);
  });

  test('a missing scan route does not disable pr-list', () async {
    final h = _client();
    h.dashboard.failStatus = 405;
    await expectLater(
      h.client.scanSessionPullRequests(['s1']),
      throwsA(isA<DesktopControlFailure>()),
    );
    h.dashboard.failStatus = null;
    await h.client.prList('/srv/repo', branches: ['a']);
    expect(h.dashboard.posts.length, 2);
  });
}
