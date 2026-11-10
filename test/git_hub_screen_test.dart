// «Cambios»: the Git tab of the workspace. The folder over its branch, the
// path search, the scope, the file count, the files by state with their
// actions, the commit bar, the ship page, the branch picker, the empty
// states, destructive confirmations, masked links, both themes, large
// text, nine languages, phone and tablet.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/models/git_hub.dart';
import 'package:hermes_android/core/models/git_review.dart';
import 'package:hermes_android/core/screens/git_hub_screen.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/git_review_controller.dart';
import 'package:hermes_android/core/services/session_pull_requests.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/fake_git_hub_gateway.dart';

final Strings _s = lookupStrings(const Locale('es'));

const _files = [
  GitReviewFile(path: 'lib/core/models/session.dart', added: 16, status: 'M'),
  GitReviewFile(
    path: 'lib/core/services/ssh_commands.dart',
    added: 4,
    removed: 1,
    status: 'M',
    staged: true,
  ),
  GitReviewFile(path: 'test/session_model_test.dart', added: 43, status: '?'),
];

const _status = GitRepoStatus(
  branch: 'release/1.3.1',
  defaultBranch: 'main',
  changed: 3,
  ahead: 2,
  added: 63,
  removed: 1,
);

FakeGitHubGateway _gateway({
  GitRepoStatus? status = _status,
  List<GitReviewFile> files = _files,
  bool writes = true,
}) => FakeGitHubGateway(
  status: status,
  files: files,
  writes: writes,
  branches: const [
    ProjectGitBranch(name: 'release/1.3.1', checkedOut: true),
    ProjectGitBranch(name: 'main', isDefault: true),
    ProjectGitBranch(name: 'origin/feat', isRemote: true),
  ],
  baseBranches: const [
    ProjectGitBaseBranch(name: 'origin/main', isRemote: true, isDefault: true),
  ],
  shipInfo: const GitShipInfo(
    ghReady: true,
    pullRequest: GitShipPullRequest(
      url: 'https://github.com/o/r/pull/12',
      state: 'open',
      number: 12,
    ),
  ),
);

void _view(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _pump(
  WidgetTester tester,
  FakeGitHubGateway gateway, {
  ThemeData? theme,
  double textScale = 1,
  Locale locale = const Locale('es'),
  // 412 dp (the mock's phone); the shared confirm dialog's action row needs
  // it. The hierarchy and the large-text checks also run at 360 dp.
  Size size = const Size(412, 892),
  bool inPane = false,
  bool sessionReadOnly = false,
  VoidCallback? onOpenTerminal,
}) async {
  _view(tester, size);
  final screen = GitHubScreen(
    gateway: gateway,
    connectionId: 'c1',
    repoPath: '/home/ana/studio',
    sessionReadOnly: sessionReadOnly,
    onOpenTerminal: onOpenTerminal,
  );
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      locale: locale,
      theme: theme ?? AppTheme.hermesRedDark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: inPane
          ? ChatWorkspacePaneScope(tab: ChatWorkspaceTab.git, child: screen)
          : screen,
    ),
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump();
  }
}

Future<void> _confirm(WidgetTester tester, String label) async {
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.byKey(const ValueKey('hermes-confirm-dialog')), findsOneWidget);
  await _open(
    tester,
    find.descendant(
      of: find.byKey(const ValueKey('hermes-confirm-dialog')),
      matching: find.text(label),
    ),
  );
  await _settle(tester);
}

/// Taps what opens a surface or a route: a frame for the push, then its
/// transition.
Future<void> _open(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _openMenu(WidgetTester tester, Key button, Key action) async {
  await _open(tester, find.byKey(button));
  await _open(tester, find.byKey(action));
  await _settle(tester);
}

bool _enabled(WidgetTester tester, String key) {
  final button = tester.widget<ButtonStyleButton>(
    find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
    ),
  );
  return button.onPressed != null;
}

void main() {
  setUp(GitStatusCache.instance.clear);

  group('hierarchy', () {
    testWidgets('folder over branch, search, scope, count, groups', (
      tester,
    ) async {
      await _pump(tester, _gateway(), size: const Size(360, 800));
      expect(find.text('studio'), findsOneWidget);
      expect(find.byKey(const ValueKey('git-branch')), findsOneWidget);
      expect(find.text('release/1.3.1'), findsOneWidget);
      expect(find.text('↑2'), findsOneWidget);
      expect(find.byKey(const ValueKey('ght-search')), findsOneWidget);
      expect(find.byKey(const ValueKey('ght-scope')), findsOneWidget);
      expect(find.text(_s.ghtScopeUncommitted), findsOneWidget);
      expect(find.text(_s.ghtScopeBranch), findsOneWidget);
      expect(find.text(_s.ghtFileCount(3)), findsOneWidget);
      expect(find.byKey(const ValueKey('ght-group-staged')), findsOneWidget);
      expect(find.byKey(const ValueKey('ght-group-unstaged')), findsOneWidget);
      expect(find.byKey(const ValueKey('ght-group-untracked')), findsOneWidget);
      expect(find.text('session.dart'), findsOneWidget);
      expect(find.byKey(const ValueKey('git-commit-bar')), findsOneWidget);
      // The ship row says what is left to push and the branch's PR.
      final ship = find.byKey(const ValueKey('ght-ship-row'));
      expect(ship, findsOneWidget);
      expect(
        find.descendant(of: ship, matching: find.textContaining('#12')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the search filters by path; no match says so', (tester) async {
      await _pump(tester, _gateway());
      await tester.enterText(find.byKey(const ValueKey('ght-search')), 'ssh_');
      await tester.pump();
      expect(find.text('ssh_commands.dart'), findsOneWidget);
      expect(find.text('session.dart'), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('ght-search')), 'zzz');
      await tester.pump();
      expect(find.byKey(const ValueKey('ght-no-matches')), findsOneWidget);
      expect(find.text(_s.ghtNoMatches), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ght-search-clear')));
      await tester.pump();
      expect(find.text('session.dart'), findsOneWidget);
    });

    testWidgets('the branch scope lists the branch, without write actions', (
      tester,
    ) async {
      final gateway = _gateway()
        ..branchFiles = const [
          GitReviewFile(path: 'docs/plan.md', added: 9, status: 'M'),
        ];
      await _pump(tester, gateway);
      await tester.tap(find.byKey(const ValueKey('ght-scope-branch')));
      await _settle(tester);
      expect(gateway.calls, contains('list:branch'));
      expect(find.text('plan.md'), findsOneWidget);
      expect(find.text(_s.ghtFileCount(1)), findsOneWidget);
      expect(find.byKey(const ValueKey('git-commit-bar')), findsNothing);
      expect(
        find.byKey(const ValueKey('ght-file-menu-docs/plan.md')),
        findsNothing,
      );
      // Back to the working tree.
      await tester.tap(find.byKey(const ValueKey('ght-scope-uncommitted')));
      await _settle(tester);
      expect(find.text('session.dart'), findsOneWidget);
    });

    testWidgets('a clean tree says so; the branch scope has its own words', (
      tester,
    ) async {
      final gateway = _gateway(files: const []);
      await _pump(tester, gateway);
      expect(find.byKey(const ValueKey('ght-clean')), findsOneWidget);
      expect(find.text(_s.ghtCleanTitle), findsOneWidget);
      expect(find.text(_s.ghtCleanBody), findsOneWidget);
      expect(find.text(_s.ghtFileCount(0)), findsOneWidget);
      expect(find.byKey(const ValueKey('git-commit-bar')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('ght-scope-branch')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('ght-branch-clean')), findsOneWidget);
      expect(find.text(_s.ghtBranchCleanTitle), findsOneWidget);
    });

    testWidgets('not a repository: the glyph, the title and the body', (
      tester,
    ) async {
      await _pump(tester, _gateway(status: null));
      expect(find.byKey(const ValueKey('git-state-not-repo')), findsOneWidget);
      expect(find.text(_s.gitNotRepo), findsOneWidget);
      expect(find.text(_s.ghtNotRepoBody), findsOneWidget);
      expect(find.text('studio'), findsOneWidget);
      expect(find.byKey(const ValueKey('ght-search')), findsNothing);
      expect(find.byKey(const ValueKey('ght-scope')), findsNothing);
    });

    testWidgets('an older Hermes: unsupported, no retry', (tester) async {
      final gateway = _gateway()
        ..readFailure = const DesktopControlFailure(
          DesktopControlFailureKind.unsupported,
          code: 404,
        );
      await _pump(tester, gateway);
      expect(
        find.byKey(const ValueKey('git-state-unsupported')),
        findsOneWidget,
      );
      expect(find.text(_s.ghtUnsupportedBody), findsOneWidget);
      expect(find.byKey(const ValueKey('git-retry')), findsNothing);
    });

    testWidgets('in the pane the page shows through', (tester) async {
      await _pump(tester, _gateway(), inPane: true);
      expect(
        tester
            .widget<Scaffold>(find.byKey(const ValueKey('ght-screen')))
            .backgroundColor,
        Colors.transparent,
      );
      expect(find.byKey(const ValueKey('git-back')), findsNothing);
    });

    testWidgets('a tablet shows the ship page beside the list', (tester) async {
      await _pump(tester, _gateway(), size: const Size(840, 900));
      expect(find.byKey(const ValueKey('ght-wide')), findsOneWidget);
      expect(find.byKey(const ValueKey('ght-ship-page')), findsOneWidget);
      expect(find.byKey(const ValueKey('ght-ship-row')), findsNothing);
      expect(find.text('session.dart'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('changes', () {
    testWidgets('stage all and unstage all from the group headers', (
      tester,
    ) async {
      final gateway = _gateway();
      await _pump(tester, gateway);
      await tester.tap(find.byKey(const ValueKey('ght-stage-all')));
      await _settle(tester);
      expect(gateway.calls, contains('stage-all'));
      expect(find.byKey(const ValueKey('ght-group-unstaged')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('ght-unstage-all')));
      await _settle(tester);
      expect(gateway.calls, contains('unstage-all'));
      expect(find.byKey(const ValueKey('ght-group-staged')), findsNothing);
    });

    testWidgets('a file menu stages the file', (tester) async {
      final gateway = _gateway();
      await _pump(tester, gateway);
      const path = 'lib/core/models/session.dart';
      await _openMenu(
        tester,
        const ValueKey('ght-file-menu-$path'),
        const ValueKey('ght-file-stage-$path'),
      );
      expect(gateway.calls, contains('stage:$path'));
      expect(find.byKey(const ValueKey('git-staged-$path')), findsOneWidget);
    });

    testWidgets('discard asks, says it cannot be undone, then reverts', (
      tester,
    ) async {
      final gateway = _gateway();
      await _pump(tester, gateway);
      const path = 'lib/core/models/session.dart';
      await _openMenu(
        tester,
        const ValueKey('ght-file-menu-$path'),
        const ValueKey('ght-file-discard-$path'),
      );
      expect(find.text(_s.ghtDiscardTitle('session.dart')), findsOneWidget);
      expect(find.text(_s.ghtDiscardBody), findsOneWidget);
      await _confirm(tester, _s.ghtDiscardAction);
      expect(gateway.reverted, [path]);
      expect(find.text('session.dart'), findsNothing);
    });

    testWidgets('cancelling the discard sends nothing', (tester) async {
      final gateway = _gateway();
      await _pump(tester, gateway);
      const path = 'lib/core/models/session.dart';
      await _openMenu(
        tester,
        const ValueKey('ght-file-menu-$path'),
        const ValueKey('ght-file-discard-$path'),
      );
      await _confirm(tester, _s.commonCancel);
      expect(gateway.reverted, isEmpty);
      expect(find.text('session.dart'), findsOneWidget);
    });

    testWidgets('discard all from the menu names the count', (tester) async {
      final gateway = _gateway();
      await _pump(tester, gateway);
      await _openMenu(
        tester,
        const ValueKey('ght-menu'),
        const ValueKey('ght-discard-all'),
      );
      expect(find.text(_s.ghtDiscardAllBody(3)), findsOneWidget);
      await _confirm(tester, _s.ghtDiscardAction);
      expect(gateway.reverted, [null]);
      expect(find.byKey(const ValueKey('ght-clean')), findsOneWidget);
    });

    testWidgets('read-only: no actions, no commit bar, the chip says so', (
      tester,
    ) async {
      await _pump(tester, _gateway(writes: false));
      expect(find.text('session.dart'), findsOneWidget);
      expect(find.byKey(const ValueKey('git-commit-bar')), findsNothing);
      expect(find.byKey(const ValueKey('ght-stage-all')), findsNothing);
      expect(
        find.byKey(
          const ValueKey('ght-file-menu-lib/core/models/session.dart'),
        ),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('ght-read-only')), findsOneWidget);
    });

    testWidgets('the session policy alone makes it read-only', (tester) async {
      await _pump(tester, _gateway(), sessionReadOnly: true);
      expect(find.byKey(const ValueKey('git-commit-bar')), findsNothing);
      expect(find.byKey(const ValueKey('ght-read-only')), findsOneWidget);
    });
  });

  group('commit', () {
    testWidgets('commit sends the message; the tree is clean after', (
      tester,
    ) async {
      final gateway = _gateway();
      await _pump(tester, gateway);
      expect(_enabled(tester, 'git-commit'), isFalse);
      await tester.enterText(
        find.byKey(const ValueKey('git-commit-message')),
        'feat: hub',
      );
      await tester.pump();
      expect(_enabled(tester, 'git-commit'), isTrue);
      await tester.tap(find.byKey(const ValueKey('git-commit')));
      await _settle(tester);
      expect(gateway.commits, ['feat: hub']);
      expect(gateway.pushed, isEmpty);
      expect(find.byKey(const ValueKey('ght-clean')), findsOneWidget);
    });

    testWidgets('the options show the server context and push after', (
      tester,
    ) async {
      final gateway = _gateway()
        ..commitContext = const GitCommitContext(
          diffLines: ['+token = ••••'],
          recentSubjects: ['feat: before'],
        );
      await _pump(tester, gateway);
      await tester.tap(find.byKey(const ValueKey('ght-commit-options-toggle')));
      await _settle(tester);
      expect(gateway.calls, contains('commit-context'));
      expect(find.byKey(const ValueKey('ght-context')), findsOneWidget);
      expect(find.text('· feat: before'), findsOneWidget);
      expect(find.text(_s.ghtCommitStagesAllHint), findsNothing);
      await tester.tap(find.byKey(const ValueKey('ght-push-switch')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('git-commit-message')),
        'feat: ship',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('git-commit')));
      await _settle(tester);
      expect(gateway.calls, contains('commit+push'));
      expect(gateway.pushed, ['feat: ship']);
    });

    testWidgets('a refused commit says why, without server text', (
      tester,
    ) async {
      final gateway = _gateway()
        ..writeFailure = const GitActionFailure(GitActionProblem.noIdentity);
      await _pump(tester, gateway);
      await tester.enterText(
        find.byKey(const ValueKey('git-commit-message')),
        'x',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('git-commit')));
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(_s.gitProblemNoIdentity), findsOneWidget);
      expect(find.byKey(const ValueKey('ght-identity')), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('a conflict turns commit off and offers Terminal', (
      tester,
    ) async {
      var opened = 0;
      await _pump(
        tester,
        _gateway(
          files: const [GitReviewFile(path: 'lib/x.dart', status: 'U')],
          status: const GitRepoStatus(
            branch: 'main',
            changed: 1,
            conflicted: 1,
          ),
        ),
        onOpenTerminal: () => opened++,
      );
      expect(find.byKey(const ValueKey('git-conflicts')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('git-commit-message')),
        'x',
      );
      await tester.pump();
      expect(_enabled(tester, 'git-commit'), isFalse);
      await tester.tap(find.byKey(const ValueKey('git-open-terminal')));
      expect(opened, 1);
    });
  });

  group('ship', () {
    testWidgets('the ship page pushes and names the result', (tester) async {
      final gateway = _gateway();
      await _pump(tester, gateway);
      await _open(tester, find.byKey(const ValueKey('ght-ship-row')));
      expect(find.byKey(const ValueKey('ght-ship-screen')), findsOneWidget);
      expect(find.text(_s.ghtPushAhead(2)), findsOneWidget);
      expect(find.text(_s.ghtPushUpstreamHint), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ght-push')));
      await _settle(tester);
      expect(gateway.pushed, ['']);
      expect(find.text(_s.ghtPushNothing), findsOneWidget);
      expect(_enabled(tester, 'ght-push'), isFalse);
    });

    testWidgets('a rejected push says why', (tester) async {
      final gateway = _gateway()
        ..writeFailure = const GitActionFailure(GitActionProblem.pushRejected);
      await _pump(tester, gateway);
      await _open(tester, find.byKey(const ValueKey('ght-ship-row')));
      await tester.tap(find.byKey(const ValueKey('ght-push')));
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(_s.ghtProblemPushRejected), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('the current PR, its state and a safe link only', (
      tester,
    ) async {
      final gateway = _gateway()
        ..shipInfo = const GitShipInfo(
          ghReady: true,
          pullRequest: GitShipPullRequest(
            url: 'https://u:tok@github.com/o/r/pull/12',
            state: 'merged',
            number: 12,
          ),
        );
      await _pump(tester, gateway);
      await _open(tester, find.byKey(const ValueKey('ght-ship-row')));
      expect(find.byKey(const ValueKey('ght-pr-current')), findsOneWidget);
      expect(find.textContaining(_s.ghtPrStateMerged), findsOneWidget);
      expect(find.textContaining('tok@'), findsNothing);
      final open = tester.widget<IconButton>(
        find.byKey(const ValueKey('ght-pr-open')),
      );
      expect(open.onPressed, isNull);
      // A PR exists: no second one.
      expect(_enabled(tester, 'ght-pr-create'), isFalse);
    });

    testWidgets('create-pr confirms with the base, then names the link', (
      tester,
    ) async {
      final gateway = _gateway()..shipInfo = const GitShipInfo(ghReady: true);
      await _pump(tester, gateway);
      await _open(tester, find.byKey(const ValueKey('ght-ship-row')));
      expect(find.text(_s.ghtPrNone), findsOneWidget);
      expect(find.text(_s.ghtPrCreateHint), findsOneWidget);
      await _open(tester, find.byKey(const ValueKey('ght-pr-create')));
      expect(
        find.text(_s.ghtPrCreateConfirmBody('release/1.3.1', 'origin/main')),
        findsOneWidget,
      );
      await _confirm(tester, _s.ghtBranchNewCreate);
      expect(gateway.calls, contains('create-pr'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(_s.ghtPrCreated), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('gh not ready: no create, the words say so', (tester) async {
      final gateway = _gateway()
        ..ghAuth = const GitGhAuth(available: true, authenticated: false)
        ..shipInfo = const GitShipInfo(ghReady: false);
      await _pump(tester, gateway);
      expect(find.byKey(const ValueKey('ght-github-state')), findsOneWidget);
      expect(find.text(_s.ghtGitHubSignedOut), findsOneWidget);
      await _open(tester, find.byKey(const ValueKey('ght-ship-row')));
      expect(find.byKey(const ValueKey('ght-gh-not-ready')), findsOneWidget);
      expect(_enabled(tester, 'ght-pr-create'), isFalse);
    });

    testWidgets('the PR list loads on demand and masks titles', (tester) async {
      final gateway = _gateway()
        ..pullRequests = PullRequestList(
          ghReady: true,
          prs: [
            fakePullRequest(
              branch: 'main',
              number: 3,
              state: 'open',
              draft: true,
              title: 'Rotate token=abcdefghijklmnop',
            ),
          ],
        );
      await _pump(tester, gateway);
      await _open(tester, find.byKey(const ValueKey('ght-ship-row')));
      await tester.tap(find.byKey(const ValueKey('ght-pr-load')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('ght-pr-3')), findsOneWidget);
      expect(find.textContaining(_s.ghtPrStateDraft), findsOneWidget);
      expect(find.textContaining('abcdefghijklmnop'), findsNothing);
    });
  });

  group('branches', () {
    testWidgets('the branch opens the picker; a switch with changes asks', (
      tester,
    ) async {
      final gateway = _gateway();
      await _pump(tester, gateway);
      await _open(tester, find.byKey(const ValueKey('ght-branch-button')));
      expect(find.byKey(const ValueKey('ght-branch-sheet')), findsOneWidget);
      expect(find.byKey(const ValueKey('ght-branch-new')), findsOneWidget);
      await _open(tester, find.byKey(const ValueKey('ght-branch-main')));
      expect(find.text(_s.ghtBranchSwitchConfirmTitle('main')), findsOneWidget);
      expect(find.text(_s.ghtBranchSwitchConfirmBody(3)), findsOneWidget);
      await _confirm(tester, _s.ghtSwitchAction);
      expect(gateway.switched, ['main']);
      expect(find.text('main'), findsOneWidget);
    });

    testWidgets('a remote branch switches by its short name', (tester) async {
      final gateway = _gateway(
        files: const [],
        status: const GitRepoStatus(branch: 'release/1.3.1'),
      );
      await _pump(tester, gateway);
      await _open(tester, find.byKey(const ValueKey('ght-branch-button')));
      await _open(tester, find.byKey(const ValueKey('ght-branch-origin/feat')));
      await _settle(tester);
      // A clean tree: no confirmation.
      expect(find.byKey(const ValueKey('hermes-confirm-dialog')), findsNothing);
      expect(gateway.switched, ['feat']);
    });

    testWidgets('the worktrees page lists, opens and removes', (tester) async {
      final gateway = _gateway()
        ..worktrees = const [
          GitWorktree(path: '/home/ana/studio', branch: 'main', isMain: true),
          GitWorktree(path: '/home/ana/studio/.worktrees/x', branch: 'x'),
        ];
      await _pump(tester, gateway);
      await _openMenu(
        tester,
        const ValueKey('ght-menu'),
        const ValueKey('ght-menu-worktrees'),
      );
      expect(
        find.byKey(const ValueKey('ght-worktrees-screen')),
        findsOneWidget,
      );
      expect(find.textContaining(_s.ghtWorktreeMain), findsWidgets);
      const other = '/home/ana/studio/.worktrees/x';
      await _openMenu(
        tester,
        const ValueKey('ght-worktree-menu-$other'),
        const ValueKey('ght-worktree-remove-$other'),
      );
      expect(find.text(_s.ghtWorktreeRemoveTitle), findsOneWidget);
      await _confirm(tester, _s.ghtRemoveAction);
      expect(gateway.removedWorktrees, [(other, false)]);
      expect(find.byKey(const ValueKey('ght-worktree-$other')), findsNothing);
    });
  });

  group('looks', () {
    for (final (name, theme) in [
      ('dark', AppTheme.hermesRedDark),
      ('light', AppTheme.hermesRedLight),
    ]) {
      testWidgets('$name theme at 2x on a phone does not overflow', (
        tester,
      ) async {
        await _pump(
          tester,
          _gateway(),
          theme: theme,
          textScale: 2,
          size: const Size(360, 800),
        );
        expect(find.text('studio'), findsOneWidget);
        expect(find.byKey(const ValueKey('git-commit-bar')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    for (final locale in Strings.supportedLocales) {
      testWidgets('${locale.languageCode}: every text has words', (
        tester,
      ) async {
        await _pump(tester, _gateway(files: const []), locale: locale);
        final strings = lookupStrings(locale);
        expect(find.text(strings.ghtCleanTitle), findsOneWidget);
        expect(find.text(strings.ghtScopeUncommitted), findsOneWidget);
        expect(find.text(strings.ghtScopeBranch), findsOneWidget);
        expect(find.text(strings.ghtFileCount(0)), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('semantics: the branch is a button, the groups headers', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, _gateway());
      expect(
        tester.getSemantics(find.byKey(const ValueKey('ght-branch-button'))),
        matchesSemantics(
          isButton: true,
          label: _s.ghtBranchPick,
          value: 'release/1.3.1',
        ),
      );
      handle.dispose();
    });
  });
}
