// GITPILL: on the Pixel (1.4.0, c09d1f28), in a chat whose folder is not a
// repository, the notch sheet showed the Git pill on its first opening
// (Terminal, Git and Navegador stacked) and never again (Terminal |
// Navegador in a row): the pill was drawn while the folder's read was
// still pending. The sheet must not change shape between openings.
//
// 1.4.3: Git is offered as Desktop offers its review pane, whenever the
// conversation has a folder and the gateway the git routes; a folder that
// is not a repository says so inside the panel. The cache tells the chat
// when a read settles, so the offer and its badge follow without
// reopening anything.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/git_review.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
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

  // Rewritten in 1.4.3: a folder that is not a repository keeps its Git
  // row (Desktop shows the review pane for any folder and says «not a
  // repository» inside); what GITPILL guarded, a sheet that never changes
  // shape between openings, still holds.
  testWidgets('not a repository: the Git row is there on the first opening, '
      'read still pending, and after; the sheet keeps its shape', (
    tester,
  ) async {
    _phone(tester);
    final gateway = FakeGitReviewGateway(status: null);
    final pending = Completer<void>();
    gateway.statusGate = pending;
    // The chat starts reading the folder; the user opens the sheet first.
    final read = GitStatusCache.instance.prefetch(gateway, 'c', _repo);
    await _open(tester, gateway);
    expect(_gitPill, findsOneWidget);
    final first = tester.getRect(_terminalPill);
    final git = tester.getRect(_gitPill);
    pending.complete();
    await read;
    for (var opening = 2; opening <= 9; opening++) {
      await _open(tester, gateway);
      expect(_gitPill, findsOneWidget, reason: 'opening $opening');
      expect(tester.getRect(_gitPill), git, reason: 'opening $opening');
      expect(tester.getRect(_terminalPill), first, reason: 'opening $opening');
    }
  });

  test('a folder with no answer yet is offered without a badge', () {
    final entry = gitNotchEntry(
      gateway: FakeGitReviewGateway(),
      repoPath: _repo,
      connectionId: 'c',
    );
    expect(entry.available, isTrue);
    expect(entry.badge, isNull);
    for (final folder in [null, '', '  ']) {
      expect(
        gitNotchEntry(
          gateway: FakeGitReviewGateway(),
          repoPath: folder,
          connectionId: 'c',
        ).available,
        isFalse,
        reason: 'no folder: «$folder»',
      );
    }
  });

  test('the cache tells its listeners when a read settles with something '
      'new, and when the gateway learns it has no git routes', () async {
    final cache = GitStatusCache.instance;
    var told = 0;
    void listener() => told++;
    cache.addListener(listener);
    addTearDown(() => cache.removeListener(listener));
    final gateway = FakeGitReviewGateway(
      status: const GitRepoStatus(branch: 'main', changed: 2),
    );

    await cache.prefetch(gateway, 'c', _repo);
    expect(told, 1, reason: 'the first answer for the folder');
    expect(
      gitNotchEntry(gateway: gateway, repoPath: _repo, connectionId: 'c').badge,
      2,
    );
    await cache.prefetch(gateway, 'c', _repo);
    expect(told, 1, reason: 'the same answer again changes nothing');
    gateway.status = const GitRepoStatus(branch: 'main', changed: 5);
    await cache.prefetch(gateway, 'c', _repo);
    expect(told, 2, reason: 'the count changed');
    gateway.status = null;
    await cache.prefetch(gateway, 'c', _repo);
    expect(told, 3, reason: 'no longer a repository');
    expect(
      gitNotchEntry(gateway: gateway, repoPath: _repo, connectionId: 'c'),
      (available: true, badge: null),
    );

    // An older Hermes answers 404 to the read: the gateway learns it has
    // no git routes during the read, and the offer goes.
    final gate = Completer<void>();
    gateway
      ..status = const GitRepoStatus(branch: 'main')
      ..statusGate = gate;
    final read = cache.prefetch(gateway, 'c', '/srv/other');
    gateway
      ..unsupported = true
      ..readFailure = const DesktopControlFailure(
        DesktopControlFailureKind.unsupported,
        code: 404,
      );
    gate.complete();
    await read;
    expect(told, 4, reason: 'the routes are gone');
    expect(
      gitNotchEntry(gateway: gateway, repoPath: _repo, connectionId: 'c')
          .available,
      isFalse,
    );
    // A failure that teaches nothing (the network) tells nobody.
    final flaky = FakeGitReviewGateway()
      ..readFailure = StateError('offline');
    await cache.prefetch(flaky, 'c', '/srv/flaky');
    expect(told, 4);
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
