// The Git screen (Hermes Console 1.4.0, F2): Desktop's review pane content
// in the narrow full-screen shape of the approved mock — header, file list,
// full-screen diff and the commit bar — plus every state the mock leaves
// out, both themes and large text.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/git_review.dart';
import 'package:hermes_android/core/screens/git_review_screen.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/git_review_controller.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/hermes_tokens.dart';
import 'package:hermes_android/core/theme/readable_ink.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/fake_git_review_gateway.dart';

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
  changed: 3,
  added: 63,
  removed: 1,
);

FakeGitReviewGateway _gateway({
  GitRepoStatus? status = _status,
  List<GitReviewFile> files = _files,
  bool writes = true,
}) => FakeGitReviewGateway(status: status, files: files, writes: writes);

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(412, 892);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _pump(
  WidgetTester tester,
  FakeGitReviewGateway gateway, {
  ThemeData? theme,
  double textScale = 1,
  VoidCallback? onOpenTerminal,
  bool inPane = false,
}) async {
  _phone(tester);
  final screen = GitReviewScreen(
    gateway: gateway,
    connectionId: 'c1',
    repoPath: '/srv/repo',
    onOpenTerminal: onOpenTerminal,
  );
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      locale: const Locale('es'),
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
  await _settleReads(tester);
}

/// The fake answers in microtasks; a few frames let every read land.
Future<void> _settleReads(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(
    find.byKey(const ValueKey('git-commit-message')),
    text,
  );
  await tester.pump();
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

String _message(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('git-commit-message')))
    .controller!
    .text;

void main() {
  setUp(GitStatusCache.instance.clear);

  testWidgets('header, files and the commit bar (mock 3-git)', (tester) async {
    await _pump(tester, _gateway());
    expect(find.byKey(const ValueKey('git-branch')), findsOneWidget);
    expect(find.text('release/1.3.1'), findsOneWidget);
    // Desktop's coding row: +A −R of the working tree.
    expect(find.text('+63'), findsOneWidget);
    expect(find.text('−1'), findsWidgets);
    expect(find.text('session.dart'), findsOneWidget);
    expect(find.text('lib/core/models'), findsOneWidget);
    expect(find.text('session_model_test.dart'), findsOneWidget);
    expect(find.text('+16'), findsOneWidget);
    // A zero side is left out, like Desktop's DiffCount.
    expect(find.text('−0'), findsNothing);
    // Staged files carry the green dot.
    expect(
      find.byKey(
        const ValueKey('git-staged-lib/core/services/ssh_commands.dart'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('git-staged-lib/core/models/session.dart')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('git-commit-bar')), findsOneWidget);
    expect(find.text(_s.gitCommit), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // Audit T1 (Ola 1): in the workspace pane the page grey of the screen and
  // of its commit bar sat on the pane's grey. There the pane shows through;
  // full screen the page is the screen's own.
  for (final inPane in [true, false]) {
    testWidgets('${inPane ? 'in the pane' : 'full screen'}: the page and '
        'the commit bar', (tester) async {
      await _pump(tester, _gateway(), inPane: inPane);
      final page = AppTheme.hermesRedDark.hermes.background;
      final expected = inPane ? Colors.transparent : page;
      expect(
        tester
            .widget<Scaffold>(find.byKey(const ValueKey('git-review-screen')))
            .backgroundColor,
        expected,
      );
      final bar = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('git-commit-bar')),
      );
      expect((bar.decoration as BoxDecoration).color, expected);
    });
  }

  // Ola 6 (audit §2.10, mock 136 v2-A, Cadu): the files in a card of rows
  // with their status in a box; the commit bar a pill, no band, no rule.
  testWidgets('the files are a card of rows; the commit bar is a pill', (
    tester,
  ) async {
    await _pump(tester, _gateway(), inPane: true);
    final colors = AppTheme.hermesRedDark.hermes;
    final chrome = HermesChrome.of(colors);

    final card = find.byKey(const ValueKey('git-files-card'));
    final cardBox =
        tester.widget<DecoratedBox>(card).decoration as BoxDecoration;
    expect(cardBox.borderRadius, BorderRadius.circular(HermesRadius.card));
    expect(
      find.descendant(
        of: card,
        matching: find.byKey(const ValueKey('git-file-list')),
      ),
      findsOneWidget,
    );
    const path = 'lib/core/models/session.dart';
    final row = find.byKey(const ValueKey('git-file-$path'));
    expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
    expect(
      tester.widget<InkWell>(row).borderRadius,
      BorderRadius.circular(HermesRadius.row),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('git-file-icon-$path'))),
      const Size(32, 32),
    );
    final name = tester.widget<Text>(
      find.descendant(of: row, matching: find.text('session.dart')),
    );
    expect(name.style!.fontSize, HermesType.value.fontSize);
    expect(name.style!.fontWeight, FontWeight.w600);
    // The counts in the bundled mono (audit T5).
    final plus = tester.widget<Text>(
      find.descendant(of: row, matching: find.text('+16')),
    );
    expect(plus.style!.fontFamily, HermesType.monoFamily);

    final bar = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('git-commit-bar')),
    );
    expect((bar.decoration as BoxDecoration).border, isNull);
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('git-commit-message')),
    );
    final border = field.decoration!.enabledBorder! as OutlineInputBorder;
    // Half its 48 dp: the same pill at one line, a card with 24 dp corners
    // when the message grows (REVIEW-T2-D P3-3; a 999 radius made a tall
    // capsule of four lines).
    expect(border.borderRadius, BorderRadius.circular(HermesSize.tap / 2));
    expect(border.borderSide.color, chrome.line);
    expect(field.decoration!.fillColor, chrome.opaque);
    // The button sits beside the message, in the same pill row.
    final fieldRect = tester.getRect(
      find.byKey(const ValueKey('git-commit-message')),
    );
    final buttonRect = tester.getRect(find.byKey(const ValueKey('git-commit')));
    expect(buttonRect.left, greaterThan(fieldRect.right));
    expect(buttonRect.bottom, closeTo(fieldRect.bottom, 1));
    expect(buttonRect.height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });

  testWidgets('commit stays off until there is a message', (tester) async {
    final gateway = _gateway();
    await _pump(tester, gateway);
    expect(_enabled(tester, 'git-commit'), isFalse);
    await _type(tester, '   ');
    expect(_enabled(tester, 'git-commit'), isFalse);
    await _type(tester, 'fix: title');
    expect(_enabled(tester, 'git-commit'), isTrue);
  });

  testWidgets('Hacer commit sends the message; the tree empties', (
    tester,
  ) async {
    final gateway = _gateway();
    await _pump(tester, gateway);
    await _type(tester, 'fix: title');
    await tester.tap(find.byKey(const ValueKey('git-commit')));
    await _settleReads(tester);
    expect(gateway.commits.single, 'fix: title');
    expect(find.byKey(const ValueKey('git-state-no-diffs')), findsOneWidget);
    expect(find.text(_s.gitNoDiffs), findsOneWidget);
    // Like Desktop, the bar only exists while there are changes.
    expect(find.byKey(const ValueKey('git-commit-bar')), findsNothing);
  });

  testWidgets('a refused commit says so and keeps the message', (
    tester,
  ) async {
    final gateway = _gateway()
      ..writeFailure = const DesktopControlFailure(
        DesktopControlFailureKind.rejected,
        code: 400,
      );
    await _pump(tester, gateway);
    await _type(tester, 'feat: x');
    await tester.tap(find.byKey(const ValueKey('git-commit')));
    await _settleReads(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(_s.gitFailureRejected), findsOneWidget);
    expect(_message(tester), 'feat: x');
    expect(_enabled(tester, 'git-commit'), isTrue);
    await tester.pump(const Duration(seconds: 10));
  });

  group('states the mock does not draw', () {
    testWidgets('not a repository', (tester) async {
      await _pump(tester, _gateway(status: null));
      expect(find.byKey(const ValueKey('git-state-not-repo')), findsOneWidget);
      expect(find.text(_s.gitNotRepo), findsOneWidget);
      expect(find.byKey(const ValueKey('git-commit-bar')), findsNothing);
    });

    testWidgets('no changes', (tester) async {
      await _pump(tester, _gateway(files: const []));
      expect(find.text(_s.gitNoDiffs), findsOneWidget);
      expect(find.byKey(const ValueKey('git-commit-bar')), findsNothing);
    });

    testWidgets('an older Hermes without the git routes', (tester) async {
      final gateway = _gateway()
        ..readFailure = const DesktopControlFailure(
          DesktopControlFailureKind.unsupported,
          code: 404,
        );
      await _pump(tester, gateway);
      expect(find.text(_s.gitFailureUnsupported), findsOneWidget);
      expect(find.byKey(const ValueKey('git-retry')), findsNothing);
    });

    testWidgets('no connection, then a retry', (tester) async {
      final gateway = _gateway()
        ..readFailure = const DesktopControlFailure(
          DesktopControlFailureKind.unavailable,
        );
      await _pump(tester, gateway);
      expect(find.text(_s.projectsCenterFailureUnavailable), findsOneWidget);
      gateway.readFailure = null;
      await tester.tap(find.byKey(const ValueKey('git-retry')));
      await _settleReads(tester);
      expect(find.text('session.dart'), findsOneWidget);
    });

    testWidgets('a read-only connection shows no write action', (
      tester,
    ) async {
      await _pump(tester, _gateway(writes: false));
      expect(find.text('session.dart'), findsOneWidget);
      expect(find.byKey(const ValueKey('git-commit-bar')), findsNothing);
      await tester.tap(find.text('session.dart'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _settleReads(tester);
      expect(find.byKey(const ValueKey('git-diff-stage')), findsNothing);
    });
  });

  group('diff (mock 3b)', () {
    Future<void> openFirst(WidgetTester tester) async {
      await tester.tap(find.text('session.dart'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _settleReads(tester);
    }

    testWidgets('numbered lines, back returns to the list', (tester) async {
      final gateway = _gateway();
      gateway.diffs['lib/core/models/session.dart'] = parseGitDiff(
        '@@ -210,3 +210,4 @@\n'
        ' String titleWith(String? raw) {\n'
        '+  if (mixed) return x;\n'
        '   return t;\n'
        ' }\n',
      );
      await _pump(tester, gateway);
      await openFirst(tester);
      expect(find.byKey(const ValueKey('git-diff-screen')), findsOneWidget);
      expect(find.byKey(const ValueKey('git-diff-lines')), findsOneWidget);
      expect(find.text('  if (mixed) return x;'), findsOneWidget);
      expect(find.text('211'), findsOneWidget);
      expect(
        gateway.calls,
        contains('diff:lib/core/models/session.dart:false'),
      );
      await tester.tap(find.byKey(const ValueKey('git-diff-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('git-diff-screen')), findsNothing);
      expect(find.text('session.dart'), findsOneWidget);
    });

    testWidgets('binary', (tester) async {
      final gateway = _gateway();
      gateway.diffs['lib/core/models/session.dart'] = const GitReviewDiff(
        binary: true,
      );
      await _pump(tester, gateway);
      await openFirst(tester);
      expect(find.text(_s.gitDiffBinary), findsOneWidget);
    });

    testWidgets('too large', (tester) async {
      final gateway = _gateway();
      gateway.diffs['lib/core/models/session.dart'] = const GitReviewDiff(
        tooLarge: true,
      );
      await _pump(tester, gateway);
      await openFirst(tester);
      expect(find.text(_s.gitDiffTooLarge), findsOneWidget);
    });

    testWidgets('empty', (tester) async {
      await _pump(tester, _gateway());
      await openFirst(tester);
      expect(find.text(_s.gitNoDiff), findsOneWidget);
    });

    testWidgets('stage flips the file and re-reads its staged side', (
      tester,
    ) async {
      final gateway = _gateway();
      await _pump(tester, gateway);
      await openFirst(tester);
      final stage = find.byKey(const ValueKey('git-diff-stage'));
      expect(tester.widget<IconButton>(stage).tooltip, _s.gitStage);
      await tester.tap(stage);
      await _settleReads(tester);
      expect(gateway.calls, contains('stage:lib/core/models/session.dart'));
      expect(gateway.calls, contains('diff:lib/core/models/session.dart:true'));
      expect(tester.widget<IconButton>(stage).tooltip, _s.gitUnstage);
    });
  });

  for (final (name, theme) in [
    ('dark', AppTheme.hermesRedDark),
    ('light', AppTheme.hermesRedLight),
  ]) {
    testWidgets('$name theme paints with its tokens', (tester) async {
      await _pump(tester, _gateway(), theme: theme);
      final colors = theme.hermes;
      final scaffold = tester.widget<Scaffold>(
        find.byKey(const ValueKey('git-review-screen')),
      );
      expect(scaffold.backgroundColor, colors.background);
      final added = tester.widget<Text>(find.text('+16'));
      expect(added.style!.color, colors.success);
      final branch = tester.widget<Text>(find.text('release/1.3.1'));
      // Ola 8 (T2-E): the branch pill's ink is accentText made readable on
      // the pill's 16 % accent tint, the same call the pill paints with.
      final tint = colors.accent.withValues(alpha: 0.16);
      expect(
        branch.style!.color,
        readableInkOnTint(colors.accentText, tint, colors),
      );
      expect(
        ThemeContrast.ratio(
          branch.style!.color!,
          ThemeContrast.composite(tint, colors.background),
        ),
        greaterThanOrEqualTo(4.5),
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final scale in [1.3, 2.0]) {
    testWidgets('text at ${scale}x does not overflow', (tester) async {
      await _pump(
        tester,
        _gateway(
          status: const GitRepoStatus(
            branch: 'feature/a-very-long-branch-name-for-large-text',
            ahead: 12,
            behind: 3,
            changed: 3,
            added: 1234,
            removed: 567,
          ),
        ),
        textScale: scale,
      );
      expect(tester.takeException(), isNull);
      await _type(tester, 'fix: title');
      expect(tester.takeException(), isNull);
      expect(find.text(_s.gitCommit), findsOneWidget);
    });
  }

  group('F2b states', () {
    const conflicted = GitRepoStatus(
      branch: 'main',
      changed: 2,
      conflicted: 1,
      added: 3,
    );
    const conflictFiles = [
      GitReviewFile(path: 'f.txt', status: 'U'),
      GitReviewFile(path: 'g.txt', added: 3, status: 'M'),
    ];

    testWidgets('a conflict turns commit off and offers Terminal', (
      tester,
    ) async {
      var terminal = 0;
      await _pump(
        tester,
        _gateway(status: conflicted, files: conflictFiles),
        onOpenTerminal: () => terminal++,
      );
      expect(find.byKey(const ValueKey('git-conflicts')), findsOneWidget);
      expect(find.text(_s.gitConflicts(1)), findsOneWidget);
      await _type(tester, 'merge');
      expect(_enabled(tester, 'git-commit'), isFalse);
      await tester.tap(find.byKey(const ValueKey('git-open-terminal')));
      expect(terminal, 1);
    });

    testWidgets('without a terminal the conflict line has no action', (
      tester,
    ) async {
      await _pump(tester, _gateway(status: conflicted, files: conflictFiles));
      expect(find.byKey(const ValueKey('git-conflicts')), findsOneWidget);
      expect(find.byKey(const ValueKey('git-open-terminal')), findsNothing);
    });

    for (final (problem, text, terminal) in [
      (GitActionProblem.conflict, _s.gitProblemConflict, true),
      (GitActionProblem.noIdentity, _s.gitProblemNoIdentity, true),
      (GitActionProblem.nothingToCommit, _s.gitNoDiffs, false),
    ]) {
      testWidgets('a refused commit: ${problem.name}', (tester) async {
        var opened = 0;
        final gateway = _gateway()..writeFailure = GitActionFailure(problem);
        await _pump(tester, gateway, onOpenTerminal: () => opened++);
        await _type(tester, 'feat: x');
        await tester.tap(find.byKey(const ValueKey('git-commit')));
        await _settleReads(tester);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text(text), findsOneWidget);
        final action = find.text(_s.chaControlTerminal);
        if (terminal) {
          expect(action, findsOneWidget);
          await tester.tap(action);
          expect(opened, 1);
        } else {
          expect(action, findsNothing);
        }
        await tester.pump(const Duration(seconds: 10));
      });
    }

    testWidgets('the diff at 2x: long name, counts and stage fit', (
      tester,
    ) async {
      const long = GitReviewFile(
        path: 'lib/core/a_really_long_file_name_for_large_text_checks.dart',
        added: 1234,
        removed: 567,
        status: 'M',
      );
      final gateway = _gateway(files: const [long]);
      gateway.diffs[long.path] = parseGitDiff(
        '@@ -1,2 +1,2 @@\n-old line\n+${'x' * 300}\n',
      );
      await _pump(
        tester,
        gateway,
        textScale: 2,
        theme: AppTheme.hermesRedLight,
      );
      await tester.tap(find.text(long.name));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _settleReads(tester);
      expect(find.byKey(const ValueKey('git-diff-lines')), findsOneWidget);
      expect(find.byKey(const ValueKey('git-diff-stage')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final (name, theme) in [
      ('dark', AppTheme.hermesRedDark),
      ('light', AppTheme.hermesRedLight),
    ]) {
      testWidgets('conflict line at 2x in the $name theme', (tester) async {
        await _pump(
          tester,
          _gateway(status: conflicted, files: conflictFiles),
          theme: theme,
          textScale: 2,
          onOpenTerminal: () {},
        );
        expect(tester.takeException(), isNull);
        final icon = tester.widget<Icon>(
          find.descendant(
            of: find.byKey(const ValueKey('git-conflicts')),
            matching: find.byType(Icon),
          ),
        );
        expect(icon.color, theme.hermes.warning);
      });
    }
  });

  group('REVIEW-F2', () {
    // P2-1: Desktop's refresh button, usable from a screen reader.
    testWidgets('the refresh button re-reads status and list', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final gateway = _gateway();
      await _pump(tester, gateway);
      final refresh = find.byKey(const ValueKey('git-refresh'));
      expect(tester.widget<IconButton>(refresh).tooltip, _s.gitRefresh);
      expect(
        tester.getSemantics(refresh),
        isSemantics(isButton: true, hasTapAction: true),
      );
      gateway.calls.clear();
      await tester.tap(refresh);
      await _settleReads(tester);
      expect(gateway.calls, containsAll(['status', 'list']));
      semantics.dispose();
    });

    testWidgets('the refresh button is off while a read runs', (
      tester,
    ) async {
      final gateway = _gateway();
      await _pump(tester, gateway);
      final gate = Completer<void>();
      gateway.statusGate = gate;
      await tester.tap(find.byKey(const ValueKey('git-refresh')));
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('git-refresh')))
            .onPressed,
        isNull,
      );
      gate.complete();
      await _settleReads(tester);
    });

    // P2-2: a deletion is not told by colour alone.
    testWidgets('each row names its status for a screen reader', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _pump(
        tester,
        _gateway(
          files: const [
            GitReviewFile(path: 'old.dart', removed: 3, status: 'D'),
            GitReviewFile(path: 'new.dart', added: 2, status: '?'),
          ],
        ),
      );
      expect(
        find.bySemanticsLabel(RegExp(_s.gitStatusDeleted)),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(_s.gitStatusUntracked)),
        findsOneWidget,
      );
      semantics.dispose();
    });

    // P2-3: a commit that fails after the user left still says so.
    testWidgets('a failure after leaving the screen is still shown', (
      tester,
    ) async {
      _phone(tester);
      final gateway = _gateway()
        ..writeFailure = const GitActionFailure(GitActionProblem.noIdentity);
      final gate = Completer<void>();
      gateway.commitGate = gate;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          locale: const Locale('es'),
          theme: AppTheme.hermesRedDark,
          home: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => GitReviewScreen(
                    gateway: gateway,
                    connectionId: 'c1',
                    repoPath: '/srv/repo',
                  ),
                ),
              ),
              child: const SizedBox(width: 40, height: 40),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _settleReads(tester);
      await _type(tester, 'feat: x');
      await tester.tap(find.byKey(const ValueKey('git-commit')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('git-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(GitReviewScreen), findsNothing);
      gate.complete();
      await _settleReads(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(_s.gitProblemNoIdentity), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });
  });

  group('REVIEW-R5-C', () {
    testWidgets('C-G3: as its tab\'s first page Git shows no dead back', (
      tester,
    ) async {
      // The workspace pane mounts Git as the first route of the tab's own
      // Navigator, like this home route: there is nothing to pop.
      await _pump(tester, _gateway());
      expect(find.byKey(const ValueKey('git-review-screen')), findsOneWidget);
      expect(find.byKey(const ValueKey('git-back')), findsNothing);
    });

    testWidgets('C-G3: pushed over the chat, back is there and leaves', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          locale: const Locale('es'),
          theme: AppTheme.hermesRedDark,
          home: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => GitReviewScreen(
                    gateway: _gateway(),
                    connectionId: 'c1',
                    repoPath: '/srv/repo',
                  ),
                ),
              ),
              child: const SizedBox(width: 40, height: 40),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _settleReads(tester);
      expect(find.byKey(const ValueKey('git-back')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('git-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(GitReviewScreen), findsNothing);
    });

    testWidgets('C-G8: a stage refused after leaving the diff is still said', (
      tester,
    ) async {
      final gateway = _gateway();
      await _pump(tester, gateway);
      await tester.tap(find.text('session.dart'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _settleReads(tester);
      final gate = Completer<void>();
      gateway
        ..stageGate = gate
        ..writeFailure = const DesktopControlFailure(
          DesktopControlFailureKind.rejected,
          code: 400,
        );
      await tester.tap(find.byKey(const ValueKey('git-diff-stage')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('git-diff-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('git-diff-screen')), findsNothing);
      gate.complete();
      await _settleReads(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(_s.gitFailureRejected), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });
  });
}
