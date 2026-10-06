import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_notch.dart';
import 'package:hermes_android/core/widgets/chat_control_sheet.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';

const _labels = ChatControlLabels(
  title: 'Chat settings',
  scope: 'Only this conversation',
  sessionSection: 'Session',
  toolsSection: 'Tools',
  dangerSection: 'Danger',
  permissions: 'Permissions',
  refresh: 'Refresh',
  artifacts: 'Artifacts',
  details: 'Details',
  cron: 'Schedule',
  delete: 'Delete conversation',
  readOnly: 'Read only',
  releaseDesktop: 'Release for Desktop',
  releaseUnavailable: 'Viewer cardinality unavailable',
);

Widget _app({
  bool readOnly = false,
  bool showDelete = true,
  VoidCallback? onDelete,
  VoidCallback? onArtifacts,
  bool showRelease = false,
  bool releaseEnabled = false,
  bool releaseInFlight = false,
  VoidCallback? onRelease,
  VoidCallback? onPrompts,
  String? promptsLabel,
}) => MaterialApp(
  theme: AppTheme.hermesRedDark,
  home: Scaffold(
    body: ChatControlSheet(
      labels: promptsLabel == null
          ? _labels
          : ChatControlLabels(
              title: _labels.title,
              scope: _labels.scope,
              sessionSection: _labels.sessionSection,
              toolsSection: _labels.toolsSection,
              dangerSection: _labels.dangerSection,
              permissions: _labels.permissions,
              refresh: _labels.refresh,
              artifacts: _labels.artifacts,
              details: _labels.details,
              cron: _labels.cron,
              delete: _labels.delete,
              readOnly: _labels.readOnly,
              releaseDesktop: _labels.releaseDesktop,
              releaseUnavailable: _labels.releaseUnavailable,
              prompts: promptsLabel,
            ),
      onPrompts: onPrompts,
      conversationTitle: 'Synthetic conversation',
      readOnly: readOnly,
      showDetails: true,
      showCron: true,
      onPermissions: () {},
      onRefresh: () {},
      onArtifacts: onArtifacts ?? () {},
      onDetails: () {},
      onCron: () {},
      onDelete: showDelete ? onDelete ?? () {} : null,
      showReleaseDesktop: showRelease,
      releaseDesktopEnabled: releaseEnabled,
      releaseInFlight: releaseInFlight,
      onReleaseDesktop: onRelease,
    ),
  ),
);

void main() {
  testWidgets('Prompts is an on-demand tool row, absent without a callback', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    expect(find.byKey(const ValueKey('chat-control-prompts')), findsNothing);

    var opened = false;
    await tester.pumpWidget(
      _app(promptsLabel: 'Prompts', onPrompts: () => opened = true),
    );
    await tester.ensureVisible(find.text('Prompts'));
    await tester.tap(find.text('Prompts'));
    await tester.pump();
    expect(opened, isTrue);
  });

  testWidgets('keeps only unique session actions and direct tools', (
    tester,
  ) async {
    var artifactsOpened = false;
    await tester.pumpWidget(_app(onArtifacts: () => artifactsOpened = true));

    expect(find.byKey(const ValueKey('chat-control-sheet')), findsOneWidget);
    expect(find.text('Synthetic conversation'), findsOneWidget);
    expect(find.text('Permissions'), findsOneWidget);
    expect(find.text('Model and reasoning'), findsNothing);
    expect(find.text('Preferences'), findsNothing);
    expect(find.text('Density'), findsNothing);
    expect(find.text('Agents and subagents'), findsNothing);
    expect(find.text('More tools'), findsNothing);
    expect(find.text('Refresh'), findsOneWidget);
    expect(find.text('Artifacts'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
    expect(find.text('Schedule'), findsOneWidget);

    await tester.ensureVisible(find.text('Artifacts'));
    await tester.tap(find.text('Artifacts'));
    await tester.pump();
    expect(artifactsOpened, isTrue);
  });

  testWidgets('read-only disables the destructive target', (tester) async {
    var deleted = false;
    await tester.pumpWidget(
      _app(readOnly: true, onDelete: () => deleted = true),
    );
    expect(find.text('READ ONLY'), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('chat-control-sheet')),
      const Offset(0, -1000),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete conversation'));
    await tester.pump();

    expect(deleted, isFalse);
  });

  testWidgets('omits the dangerous section when deletion is not applicable', (
    tester,
  ) async {
    await tester.pumpWidget(_app(showDelete: false));

    expect(find.text('Danger'), findsNothing);
    expect(find.text('Delete conversation'), findsNothing);
    expect(find.byKey(const ValueKey('chat-control-delete')), findsNothing);
  });

  testWidgets('release habilitado ejecuta callback y expone progreso estable', (
    tester,
  ) async {
    var released = false;
    await tester.pumpWidget(
      _app(
        showRelease: true,
        releaseEnabled: true,
        onRelease: () => released = true,
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey('chat-control-release-desktop')),
    );
    expect(released, isTrue);

    await tester.pumpWidget(
      _app(showRelease: true, releaseEnabled: false, releaseInFlight: true),
    );
    expect(
      find.byKey(const ValueKey('chat-runtime-release-progress')),
      findsOneWidget,
    );
  });

  testWidgets('floating menu stays bounded and scrollable at 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.hermesRedDark,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showHermesFloatingSurface<void>(
                  context: context,
                  surfaceKey: const ValueKey('compact-chat-control'),
                  maxWidth: 480,
                  builder: (_) => ChatControlSheet(
                    labels: _labels,
                    conversationTitle: 'Synthetic conversation',
                    showDetails: true,
                    showCron: true,
                    onPermissions: () {},
                    onRefresh: () {},
                    onArtifacts: () {},
                    onDetails: () {},
                    onCron: () {},
                    onDelete: () {},
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final surface = find.byKey(const ValueKey('compact-chat-control'));
    expect(surface, findsOneWidget);
    expect(tester.getSize(surface).width, lessThanOrEqualTo(328));
    expect(tester.getSize(surface).height, lessThan(540));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('chat-control-delete')),
      260,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('chat-control-sheet')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.byKey(const ValueKey('chat-control-delete')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('notch sheet layout', () {
    const full = ChatControlLabels(
      title: 'Chat settings',
      scope: 'Only this conversation',
      sessionSection: 'Session',
      toolsSection: 'Tools',
      dangerSection: 'Danger',
      permissions: 'Permissions',
      refresh: 'Refresh',
      artifacts: 'Artifacts',
      details: 'Details',
      cron: 'Schedule',
      delete: 'Delete conversation',
      readOnly: 'Read only',
      releaseDesktop: 'Release for Desktop',
      releaseUnavailable: 'Viewer cardinality unavailable',
      recovery: 'Recovery',
      extensions: 'Extensions',
      content: 'Files and links',
      prompts: 'Prompts',
      showPinnedPrompt: 'Show pinned prompt',
      branch: 'Branch chat',
      skills: 'Skills',
      memory: 'Memory',
      goTo: 'Go to',
      chats: 'Chats',
      home: 'Home',
      projects: 'Projects',
      settings: 'Settings',
      searchChats: 'Search chats',
      findInChat: 'Search this chat',
      model: 'Model',
      previousChat: 'Previous chat',
      nextChat: 'Next chat',
    );

    Widget sheet({
      required Map<String, int> calls,
      List<ChatNotchDestination>? went,
      double textScale = 1,
      ThemeData? theme,
    }) {
      VoidCallback hit(String id) =>
          () => calls[id] = (calls[id] ?? 0) + 1;
      return MaterialApp(
        theme: theme ?? AppTheme.hermesRedDark,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: ChatControlSheet(
            labels: full,
            conversationTitle: 'Synthetic conversation',
            showDetails: true,
            showCron: true,
            showReleaseDesktop: true,
            releaseDesktopEnabled: true,
            onNavigate: (d) => went?.add(d),
            onFindInChat: hit('find'),
            onModel: hit('model'),
            onPreviousChat: hit('previous-chat'),
            onNextChat: hit('next-chat'),
            onPermissions: hit('permissions'),
            onRefresh: hit('refresh'),
            onArtifacts: hit('artifacts'),
            onContent: hit('content'),
            onPrompts: hit('prompts'),
            onShowPinnedPrompt: hit('show-pinned-prompt'),
            onBranch: hit('branch'),
            onDetails: hit('details'),
            onCron: hit('cron'),
            onRecovery: hit('recovery'),
            onExtensions: hit('extensions'),
            onSkills: hit('skills'),
            onMemory: hit('memory'),
            onReleaseDesktop: hit('release-desktop'),
            onDelete: hit('delete'),
          ),
        ),
      );
    }

    // Every entry the old header ⋮ sheet, the header search icon and the Bot
    // Chat overflow offered, plus the two that had lost their button (Skills,
    // Memory), lives in exactly one group of the notch sheet.
    const groups = <String, List<String>>{
      'find': ['find'],
      'session': [
        'model',
        'previous-chat',
        'next-chat',
        'permissions',
        'refresh',
        'details',
        'prompts',
        'show-pinned-prompt',
        'branch',
      ],
      'tools': [
        'artifacts',
        'content',
        'cron',
        'extensions',
        'skills',
        'memory',
        'recovery',
      ],
      'danger': ['release-desktop', 'delete'],
    };

    testWidgets('every previous action is reachable in its group', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <String, int>{};
      await tester.pumpWidget(sheet(calls: calls));
      var previousGroupBottom = double.negativeInfinity;
      for (final entry in groups.entries) {
        final group = find.byKey(ValueKey('chat-control-group-${entry.key}'));
        expect(group, findsOneWidget, reason: entry.key);
        expect(tester.getRect(group).top, greaterThan(previousGroupBottom));
        previousGroupBottom = tester.getRect(group).bottom;
        var previousRowTop = double.negativeInfinity;
        for (final id in entry.value) {
          final row = find.descendant(
            of: group,
            matching: find.byKey(ValueKey('chat-control-$id')),
          );
          expect(row, findsOneWidget, reason: '$id in ${entry.key}');
          expect(tester.getRect(row).top, greaterThan(previousRowTop));
          previousRowTop = tester.getRect(row).top;
          expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
          await tester.tap(row);
          await tester.pump();
          expect(calls[id], 1, reason: id);
        }
      }
      expect(calls.length, groups.values.expand((ids) => ids).length);
    });

    testWidgets('Ir a: equal grey tiles with the dock icons, in order', (
      tester,
    ) async {
      final went = <ChatNotchDestination>[];
      await tester.pumpWidget(sheet(calls: {}, went: went));
      final colors = AppTheme.hermesRedDark.hermes;
      final row = find.byKey(const ValueKey('chat-notch-go-to'));
      expect(row, findsOneWidget);
      expect(find.text('Go to'), findsOneWidget);
      // Below "Search this chat", above the settings title.
      expect(
        tester.getRect(row).bottom,
        lessThan(tester.getRect(find.text('Chat settings')).top),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('chat-control-find'))).bottom,
        lessThan(tester.getRect(row).top),
      );
      const expected = <ChatNotchDestination, IconData>{
        ChatNotchDestination.chats: Icons.forum_outlined,
        ChatNotchDestination.home: Icons.home_outlined,
        ChatNotchDestination.projects: Icons.folder_copy_outlined,
        ChatNotchDestination.settings: Icons.settings_outlined,
        ChatNotchDestination.searchChats: Icons.manage_search_rounded,
      };
      Size? size;
      double? lastLeft;
      for (final MapEntry(key: destination, value: icon) in expected.entries) {
        final tile = find.byKey(ValueKey('chat-notch-go-${destination.name}'));
        expect(tile, findsOneWidget);
        final tileSize = tester.getSize(tile);
        size ??= tileSize;
        expect(tileSize.width, closeTo(size.width, 0.5));
        expect(tileSize.height, greaterThanOrEqualTo(48));
        final left = tester.getRect(tile).left;
        if (lastLeft != null) expect(left, greaterThan(lastLeft));
        lastLeft = left;
        final glyph = tester.widget<Icon>(
          find.descendant(of: tile, matching: find.byType(Icon)),
        );
        expect(glyph.icon, icon);
        expect(glyph.color, colors.textPrimary);
        final face = tester.widget<DecoratedBox>(
          find.descendant(
            of: tile,
            matching: find.byKey(const ValueKey('chat-notch-go-face')),
          ),
        );
        expect((face.decoration as BoxDecoration).color, colors.surfaceVariant);
        await tester.tap(tile);
        await tester.pump();
      }
      expect(went, expected.keys.toList());
    });

    testWidgets('2x text: tiles wrap to two columns and nothing overflows', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(sheet(calls: {}, textScale: 2));
      final chats = tester.getRect(
        find.byKey(const ValueKey('chat-notch-go-chats')),
      );
      final home = tester.getRect(
        find.byKey(const ValueKey('chat-notch-go-home')),
      );
      final projects = tester.getRect(
        find.byKey(const ValueKey('chat-notch-go-projects')),
      );
      expect(home.top, closeTo(chats.top, 0.5));
      expect(projects.top, greaterThan(chats.bottom - 0.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('light theme keeps the tiles neutral grey', (tester) async {
      await tester.pumpWidget(sheet(calls: {}, theme: AppTheme.hermesRedLight));
      final face = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byKey(const ValueKey('chat-notch-go-home')),
          matching: find.byKey(const ValueKey('chat-notch-go-face')),
        ),
      );
      expect(
        (face.decoration as BoxDecoration).color,
        AppTheme.hermesRedLight.hermes.surfaceVariant,
      );
    });

    testWidgets('without a navigator there is no Ir a row', (tester) async {
      await tester.pumpWidget(_app());
      expect(find.byKey(const ValueKey('chat-notch-go-to')), findsNothing);
    });
  });
}
