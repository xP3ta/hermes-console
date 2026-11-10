import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/git_review.dart';
import 'package:hermes_android/core/screens/git_review_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/fake_git_review_gateway.dart';

// Ola 1 (AUDITORIA-PULIDO §5): the workspace pane is one piece. The tab's
// screen shows the pane's surface (no page grey of its own), the pane has
// its hairline edge, and the selector and the actions sit on it. The open
// Fold (about 884 × 1104 dp), dark and light, with the Git tab: a real
// screen that needs no platform view or SSH stack.
//
// New goldens: until their PNGs are generated on the reference engine with
// `flutter test --update-goldens test/workspace_pane_golden_test.dart` (and
// looked at), these skip instead of failing for a missing file.

const _fold = Size(884, 1104);

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

/// A missing golden is an explicit, reasoned skip (never a silent pass): the
/// reason names the file so the run's skip count shows what to regenerate.
String? _pending(String golden) =>
    !autoUpdateGoldenFiles && !File('test/$golden').existsSync()
    ? 'golden test/$golden is missing; regenerate with '
          '`flutter test --update-goldens test/workspace_pane_golden_test.dart`'
    : null;

void main() {
  for (final (name, theme) in [
    ('dark', AppTheme.hermesRedDark),
    ('light', AppTheme.hermesRedLight),
  ]) {
    final golden = 'goldens/workspace_pane_git_$name.png';
    final missing = _pending(golden);
    if (missing != null) {
      // testWidgets only takes a bool; `test` carries the reason in the run.
      test(
        'the pane with Git is one piece ($name, open Fold)',
        () {},
        skip: missing,
      );
      continue;
    }
    testWidgets('the pane with Git is one piece ($name, open Fold)', (
      tester,
    ) async {
      tester.view.physicalSize = _fold;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = ChatWorkspaceController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: ChatWorkspaceHost(
            controller: controller,
            chat: const SizedBox.expand(),
            availableTabs: const [ChatWorkspaceTab.git],
            tabBuilder: (_, _) => GitReviewScreen(
              gateway: FakeGitReviewGateway(status: _status, files: _files),
              connectionId: 'c1',
              repoPath: '/srv/repo',
            ),
          ),
        ),
      );
      controller.open(ChatWorkspaceTab.git);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(ChatWorkspaceHost),
        matchesGoldenFile(golden),
      );
    });
  }
}
