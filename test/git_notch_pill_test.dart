// GITPILL: on the Pixel (1.4.0, c09d1f28), in a chat whose folder is not a
// repository, the notch sheet showed the Git pill on its first opening
// (Terminal, Git and Navegador stacked) and never again (Terminal |
// Navegador in a row): the pill was drawn while the folder's read was
// still pending. The sheet must not change shape between openings.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/git_review.dart';
import 'package:hermes_android/core/services/git_review_controller.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_control_sheet.dart';

import 'support/fake_git_review_gateway.dart';

const _labels = ChatControlLabels(
  title: 'This conversation',
  refresh: 'Refresh',
  details: 'Details',
  cron: 'Schedule',
  delete: 'Delete conversation',
  readOnly: 'Read only',
  recovery: 'Recovery',
  extensions: 'Extensions',
  content: 'Artifacts',
  prompts: 'Prompts',
  showPinnedPrompt: 'Show pinned prompt',
  branch: 'Branch chat',
  findInChat: 'Search this chat',
);

const _repo = '/home/hermes/voz';

/// One opening of the notch sheet, as the chat builds it: Terminal, Git
/// (from [gitNotchEntry]) and Navegador.
Future<void> _open(WidgetTester tester, FakeGitReviewGateway gateway) async {
  final git = gitNotchEntry(
    gateway: gateway,
    repoPath: _repo,
    connectionId: 'c',
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.hermesRedDark,
      home: Scaffold(
        body: ChatControlSheet(
          labels: _labels,
          conversationTitle: 'Añadir voz a hermes',
          onRefresh: () {},
          onContent: () {},
          workspace: [
            ChatWorkspaceEntry(
              kind: ChatWorkspaceKind.terminal,
              label: 'Terminal',
              onTap: () {},
            ),
            ChatWorkspaceEntry(
              kind: ChatWorkspaceKind.git,
              label: 'Git',
              available: git.available,
              badgeCount: git.badge,
              onTap: () {},
            ),
            ChatWorkspaceEntry(
              kind: ChatWorkspaceKind.browser,
              label: 'Navegador',
              onTap: () {},
            ),
          ],
        ),
      ),
    ),
  );
}

final _gitPill = find.byKey(const ValueKey('chat-control-workspace-git'));
final _terminalPill = find.byKey(
  const ValueKey('chat-control-workspace-terminal'),
);

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(412, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(GitStatusCache.instance.clear);

  testWidgets('not a repository: no pill on the first opening, read still '
      'pending, nor after; the sheet keeps its shape', (tester) async {
    _phone(tester);
    final gateway = FakeGitReviewGateway(status: null);
    final pending = Completer<void>();
    gateway.statusGate = pending;
    // The chat starts reading the folder; the user opens the sheet first.
    final read = GitStatusCache.instance.prefetch(gateway, 'c', _repo);
    await _open(tester, gateway);
    expect(_gitPill, findsNothing);
    final first = tester.getRect(_terminalPill);
    pending.complete();
    await read;
    for (var opening = 2; opening <= 9; opening++) {
      await _open(tester, gateway);
      expect(_gitPill, findsNothing, reason: 'opening $opening');
      expect(tester.getRect(_terminalPill), first, reason: 'opening $opening');
    }
  });

  testWidgets('a repository read before the first opening: the pill is '
      'there from the first opening, with its badge, every time', (
    tester,
  ) async {
    _phone(tester);
    final gateway = FakeGitReviewGateway(
      status: const GitRepoStatus(branch: 'main', changed: 3),
    );
    // The chat's first frame reads the folder before any opening.
    await GitStatusCache.instance.prefetch(gateway, 'c', _repo);
    await _open(tester, gateway);
    expect(_gitPill, findsOneWidget);
    expect(
      find.descendant(of: _gitPill, matching: find.text('3')),
      findsOneWidget,
    );
    final first = tester.getRect(_terminalPill);
    for (var opening = 2; opening <= 5; opening++) {
      await GitStatusCache.instance.prefetch(gateway, 'c', _repo);
      await _open(tester, gateway);
      expect(_gitPill, findsOneWidget, reason: 'opening $opening');
      expect(tester.getRect(_terminalPill), first, reason: 'opening $opening');
    }
  });

  testWidgets('a Hermes without the git routes never shows the pill', (
    tester,
  ) async {
    _phone(tester);
    final gateway = FakeGitReviewGateway()..unsupported = true;
    await GitStatusCache.instance.prefetch(gateway, 'c', _repo);
    await _open(tester, gateway);
    expect(_gitPill, findsNothing);
    expect(gateway.calls, isEmpty);
  });
}
