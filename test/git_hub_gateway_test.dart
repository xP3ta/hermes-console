// Wire contract of the Git hub: the exact Dashboard `/api/git/*` routes
// of `hermes_cli/web_routers/git.py`, their query strings and bodies,
// errors without the server's text, 404/405 as unsupported, and no POST
// from a read-only connection.
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
  int? failStatus;
  String failBody = 'fatal: https://user:tok3n@github.com/o/r secret stderr';
  bool tooLarge = false;
  Map<String, dynamic> Function(String endpoint)? respond;

  Map<String, dynamic> _answer(String endpoint) {
    final status = failStatus;
    if (status != null) throw DashboardHttpException(status, body: failBody);
    return respond?.call(endpoint) ?? <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> apiGetWithin(
    String endpoint, {
    required Duration timeout,
    bool retried = false,
  }) async {
    calls.add(('GET', endpoint, null));
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
      id: 'git-hub-wire',
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

Matcher _failure(DesktopControlFailureKind kind) =>
    throwsA(isA<DesktopControlFailure>().having((f) => f.kind, 'kind', kind));

Matcher _problem(GitActionProblem problem) => throwsA(
  isA<GitActionFailure>().having((f) => f.problem, 'problem', problem),
);

const _repo = '/srv/hermes console';
const _q = 'path=%2Fsrv%2Fhermes+console';

void main() {
  group('reads', () {
    test('gh-auth, plain and with refresh', () async {
      final h = _client();
      h.dashboard.respond = (_) => {'available': true, 'authenticated': false};
      final auth = await h.client.gitGhAuth();
      await h.client.gitGhAuth(refresh: true);
      expect(h.dashboard.calls.map((c) => c.$2), [
        'git/gh-auth',
        'git/gh-auth?refresh=true',
      ]);
      expect(auth.available, isTrue);
      expect(auth.authenticated, isFalse);
    });

    test('worktrees names the folder and parses the rows', () async {
      final h = _client();
      h.dashboard.respond = (_) => {
        'worktrees': [
          {'path': '/srv/r', 'branch': 'main', 'isMain': true},
          {'path': '/srv/r/.worktrees/x', 'branch': 'feat/x', 'locked': true},
          {'branch': 'no-path'},
        ],
      };
      final trees = await h.client.gitWorktrees(_repo);
      expect(h.dashboard.calls.single.$2, 'git/worktrees?$_q');
      expect(trees.map((t) => t.path), ['/srv/r', '/srv/r/.worktrees/x']);
      expect(trees.first.isMain, isTrue);
      expect(trees.last.locked, isTrue);
      expect(trees.last.name, 'x');
    });

    test('branches and base-branches', () async {
      final h = _client();
      h.dashboard.respond = (endpoint) => endpoint.startsWith('git/branches')
          ? {
              'branches': [
                {'name': 'main', 'checkedOut': true, 'isDefault': true},
                {'name': 'origin/feat', 'isRemote': true},
              ],
            }
          : {
              'branches': [
                {'name': 'origin/main', 'isRemote': true, 'isDefault': true},
              ],
            };
      final branches = await h.client.gitBranches(_repo);
      final bases = await h.client.gitBaseBranches(_repo);
      expect(h.dashboard.calls.map((c) => c.$2), [
        'git/branches?$_q',
        'git/base-branches?$_q',
      ]);
      expect(branches.map((b) => b.name), ['main', 'origin/feat']);
      expect(branches.last.isRemote, isTrue);
      expect(bases.single.isDefault, isTrue);
    });

    test('commit-context is read bounded and masked', () async {
      final h = _client();
      h.dashboard.respond = (_) => {
        'diff': '+url = https://u:p4ssw0rd@host/x\n+token=abcdef123456\n\n',
        'recent': 'feat: a\nfix: b\n',
      };
      final context = await h.client.gitCommitContext(_repo);
      expect(h.dashboard.calls.single.$2, 'git/review/commit-context?$_q');
      expect(context.recentSubjects, ['feat: a', 'fix: b']);
      expect(context.diffLines.length, 2);
      expect(context.diffLines.join('\n'), isNot(contains('p4ssw0rd')));
      expect(context.diffLines.join('\n'), isNot(contains('abcdef123456')));
    });

    test('commit-context past the budget is simply empty', () async {
      final h = _client();
      h.dashboard.tooLarge = true;
      final context = await h.client.gitCommitContext(_repo);
      expect(context.isEmpty, isTrue);
    });

    test('ship-info with and without a PR', () async {
      final h = _client();
      h.dashboard.respond = (_) => {
        'ghReady': true,
        'pr': {
          'url': 'https://github.com/o/r/pull/3',
          'state': 'OPEN',
          'number': 3,
        },
      };
      final ship = await h.client.gitShipInfo(_repo);
      expect(h.dashboard.calls.single.$2, 'git/review/ship-info?$_q');
      expect(ship.ghReady, isTrue);
      expect(ship.pullRequest!.number, 3);
      expect(ship.pullRequest!.state, 'open');
      h.dashboard.respond = (_) => {'ghReady': false, 'pr': null};
      final none = await h.client.gitShipInfo(_repo);
      expect(none.ghReady, isFalse);
      expect(none.pullRequest, isNull);
    });

    test('pr-list posts the branches as data', () async {
      final h = _client();
      h.dashboard.respond = (_) => {
        'ghReady': true,
        'prs': [
          {'branch': 'feat/x', 'number': 9, 'state': 'open', 'url': 'u'},
        ],
      };
      final list = await h.client.gitPullRequests(
        _repo,
        branches: ['feat/x', 'main'],
      );
      final call = h.dashboard.calls.single;
      expect(call.$1, 'POST');
      expect(call.$2, 'git/review/pr-list');
      expect(call.$3, {
        'path': _repo,
        'branches': ['feat/x', 'main'],
        'numbers': <int>[],
      });
      expect(list.prs.single.number, 9);
    });
  });

  group('writes', () {
    test(
      'stage / unstage / revert on the whole tree carry only the folder',
      () async {
        final h = _client();
        await h.client.gitStageAll(_repo);
        await h.client.gitUnstageAll(_repo);
        await h.client.gitRevert(_repo);
        final calls = [
          for (final c in h.dashboard.calls) [c.$2, c.$3],
        ];
        expect(calls, [
          [
            'git/review/stage',
            {'path': _repo},
          ],
          [
            'git/review/unstage',
            {'path': _repo},
          ],
          [
            'git/review/revert',
            {'path': _repo},
          ],
        ]);
      },
    );

    test('revert of one file names it', () async {
      final h = _client();
      await h.client.gitRevert(_repo, file: 'lib/a.dart');
      expect(h.dashboard.calls.single.$3, {
        'path': _repo,
        'file': 'lib/a.dart',
      });
    });

    test(
      'commit with push sets the flag; push alone posts the folder',
      () async {
        final h = _client();
        await h.client.gitCommitAndPush(_repo, 'feat: x');
        await h.client.gitPush(_repo);
        final calls = [
          for (final c in h.dashboard.calls) [c.$2, c.$3],
        ];
        expect(calls, [
          [
            'git/review/commit',
            {'path': _repo, 'message': 'feat: x', 'push': true},
          ],
          [
            'git/review/push',
            {'path': _repo},
          ],
        ]);
        // Both may run a push on the server: the commit's generous deadline.
        expect(
          h.dashboard.postTimeouts,
          everyElement(const Duration(minutes: 2)),
        );
      },
    );

    test('create-pr sends the folder only and reads the link', () async {
      final h = _client();
      h.dashboard.respond = (_) => {'url': 'https://github.com/o/r/pull/12'};
      final created = await h.client.gitCreatePullRequest(_repo);
      expect(h.dashboard.calls.single.$2, 'git/review/create-pr');
      expect(h.dashboard.calls.single.$3, {'path': _repo});
      expect(created.url, 'https://github.com/o/r/pull/12');
    });

    test(
      'worktree add: a new branch, a branch off a base, an existing one',
      () async {
        final h = _client();
        h.dashboard.respond = (_) => {
          'path': '/srv/r/.worktrees/x',
          'branch': 'x',
        };
        await h.client.gitWorktreeAdd(
          _repo,
          branch: 'feat/x',
          base: 'origin/main',
        );
        await h.client.gitWorktreeAdd(_repo, existingBranch: 'origin/feat');
        final calls = [for (final c in h.dashboard.calls) c.$3];
        expect(calls, [
          {
            'path': _repo,
            'name': 'feat/x',
            'branch': 'feat/x',
            'base': 'origin/main',
          },
          {'path': _repo, 'existingBranch': 'origin/feat'},
        ]);
        expect(
          () => h.client.gitWorktreeAdd(_repo),
          _failure(DesktopControlFailureKind.rejected),
        );
      },
    );

    test('worktree remove carries force explicitly', () async {
      final h = _client();
      await h.client.gitWorktreeRemove(_repo, '/srv/r/.worktrees/x');
      await h.client.gitWorktreeRemove(
        _repo,
        '/srv/r/.worktrees/x',
        force: true,
      );
      final calls = [for (final c in h.dashboard.calls) c.$3];
      expect(calls, [
        {'path': _repo, 'worktreePath': '/srv/r/.worktrees/x', 'force': false},
        {'path': _repo, 'worktreePath': '/srv/r/.worktrees/x', 'force': true},
      ]);
    });

    test('branch switch posts the name as data', () async {
      final h = _client();
      await h.client.gitBranchSwitch(_repo, 'feat/x; rm -rf ~');
      expect(h.dashboard.calls.single.$2, 'git/branch/switch');
      expect(h.dashboard.calls.single.$3, {
        'path': _repo,
        'branch': 'feat/x; rm -rf ~',
      });
    });
  });

  group('errors', () {
    test('404 and 405 turn the routes off as unsupported', () async {
      for (final status in [404, 405]) {
        final h = _client();
        h.dashboard.failStatus = status;
        await expectLater(
          h.client.gitShipInfo(_repo),
          _failure(DesktopControlFailureKind.unsupported),
        );
        expect(h.client.gitReviewKnownUnsupported, isTrue, reason: '$status');
        await expectLater(
          h.client.gitPush(_repo),
          _failure(DesktopControlFailureKind.unsupported),
        );
        expect(h.dashboard.calls.length, 1, reason: '$status: no retry');
      }
    });

    test('a refused push keeps only its classified reason', () async {
      final h = _client();
      h.dashboard.failStatus = 400;
      h.dashboard.failBody = jsonEncode({
        'detail':
            ' ! [rejected] main -> main (fetch first)\n'
            'error: failed to push some refs to https://x:tok@github.com/o/r',
      });
      await expectLater(
        h.client.gitPush(_repo),
        _problem(GitActionProblem.pushRejected),
      );
      h.dashboard.failBody = jsonEncode({
        'detail':
            'gh pr create failed: a pull request for branch "x" into '
            'branch "main" already exists:',
      });
      await expectLater(
        h.client.gitCreatePullRequest(_repo),
        _problem(GitActionProblem.prExists),
      );
      h.dashboard.failBody = jsonEncode({
        'detail':
            'fatal: /srv/r/.worktrees/x contains modified or untracked '
            'files, use --force to delete it',
      });
      await expectLater(
        h.client.gitWorktreeRemove(_repo, '/srv/r/.worktrees/x'),
        _problem(GitActionProblem.localChanges),
      );
      expect(h.client.gitReviewKnownUnsupported, isFalse);
    });

    test('an unknown refusal is rejected, without the server text', () async {
      final h = _client();
      h.dashboard.failStatus = 400;
      h.dashboard.failBody = 'something with https://u:p@host/x in it';
      Object? caught;
      try {
        await h.client.gitBranchSwitch(_repo, 'x');
      } catch (error) {
        caught = error;
      }
      expect(caught, isA<DesktopControlFailure>());
      expect(
        (caught! as DesktopControlFailure).kind,
        DesktopControlFailureKind.rejected,
      );
      expect(caught.toString(), isNot(contains('u:p@host')));
    });

    test('a read-only connection sends no POST at all', () async {
      final h = _client(readOnly: true);
      expect(h.client.gitWritesAllowed, isFalse);
      final writes = <Future<Object?> Function()>[
        () => h.client.gitStageAll(_repo),
        () => h.client.gitUnstageAll(_repo),
        () => h.client.gitRevert(_repo),
        () => h.client.gitRevert(_repo, file: 'a'),
        () => h.client.gitCommitAndPush(_repo, 'm'),
        () => h.client.gitPush(_repo),
        () => h.client.gitCreatePullRequest(_repo),
        () => h.client.gitWorktreeAdd(_repo, branch: 'b'),
        () => h.client.gitWorktreeRemove(_repo, '/w'),
        () => h.client.gitBranchSwitch(_repo, 'b'),
      ];
      for (final write in writes) {
        await expectLater(write, _failure(DesktopControlFailureKind.forbidden));
      }
      expect(h.dashboard.calls, isEmpty);
      // Reads still work read-only.
      h.dashboard.respond = (_) => {'ghReady': false, 'pr': null};
      await h.client.gitShipInfo(_repo);
      expect(h.dashboard.calls.single.$1, 'GET');
    });

    test('control characters are refused before any request', () async {
      final h = _client();
      expect(
        () => h.client.gitBranchSwitch(_repo, 'a\u0000b'),
        _failure(DesktopControlFailureKind.rejected),
      );
      expect(
        () => h.client.gitWorktreeRemove(_repo, '/w\u0007'),
        _failure(DesktopControlFailureKind.rejected),
      );
      expect(h.dashboard.calls, isEmpty);
    });
  });
}
