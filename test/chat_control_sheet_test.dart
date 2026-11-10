import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart'
    show
        HermesChrome,
        HermesFloatingSurface,
        HermesScrim,
        hermesOriginOf,
        showHermesSurface;
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_control_sheet.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/l10n/app_localizations_en.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';

// The chat's «Ajustes» window, the owner's final windows (ventanas-final-png): a
// LIST. On top, the conversation's name and the pill of two round buttons
// [🔍][+]; then PANELES (Terminal · Archivos · Git · Navegador, the one
// showing marked «en pantalla»); then the conversation's actions, one row each;
// «Borrar conversación» last, apart, in red. Model, permissions, «Ir a»,
// Memory and Skills live elsewhere (status pill, ≡ menu), and how the
// screen is shared in «Vistas»: none of them come back here.

ChatControlLabels _labels({String? panelOpen}) => ChatControlLabels(
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
  newChat: 'New chat',
  desktop: 'See the bot\'s desktop',
  panels: 'Panels',
  panelOpen: panelOpen ?? StringsEn().chaControlPanelOpen,
);

/// The actions in the mock's order, with every optional one.
const _actionOrder = <String>[
  'refresh',
  'content',
  'prompts',
  'show-pinned-prompt',
  'branch',
  'details',
  'cron',
  'recovery',
  'extensions',
];

const _panelOrder = <String>['terminal', 'files', 'git', 'browser'];

Finder _row(String id) => find.byKey(ValueKey('chat-control-$id'));
Finder _panel(String kind) =>
    find.byKey(ValueKey('chat-control-workspace-$kind'));

Widget _app({
  Map<String, int>? calls,
  bool readOnly = false,
  bool showDelete = true,
  bool showDetails = true,
  bool showCron = true,
  bool branch = true,
  bool recovery = true,
  bool pinned = true,
  bool extensions = true,
  List<ChatWorkspaceEntry>? workspace,
  ThemeData? theme,
  double textScale = 1,
  bool newChat = true,
  bool desktop = false,
  ChatWorkspaceKind? open,
  String title = 'Synthetic conversation',
  String? panelOpen,
}) {
  VoidCallback hit(String id) => () {
    final counts = calls;
    if (counts != null) counts[id] = (counts[id] ?? 0) + 1;
  };
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
        labels: _labels(panelOpen: panelOpen),
        conversationTitle: title,
        readOnly: readOnly,
        showDetails: showDetails,
        showCron: showCron,
        workspace:
            workspace ??
            [
              for (final (kind, label) in const [
                (ChatWorkspaceKind.terminal, 'Terminal'),
                (ChatWorkspaceKind.files, 'Files'),
                (ChatWorkspaceKind.git, 'Git'),
                (ChatWorkspaceKind.browser, 'Browser'),
              ])
                ChatWorkspaceEntry(
                  kind: kind,
                  label: label,
                  open: kind == open,
                  badgeCount: kind == ChatWorkspaceKind.git ? 4 : null,
                  badgeSemanticLabel: kind == ChatWorkspaceKind.git
                      ? '4 changes'
                      : null,
                  onTap: hit(kind.name),
                ),
            ],
        onFindInChat: hit('find'),
        onNewChat: newChat ? hit('new-chat') : null,
        onDesktop: desktop ? hit('desktop') : null,
        onRefresh: hit('refresh'),
        onContent: hit('content'),
        onPrompts: hit('prompts'),
        onShowPinnedPrompt: pinned ? hit('show-pinned-prompt') : null,
        onBranch: branch ? hit('branch') : null,
        onDetails: hit('details'),
        onCron: hit('cron'),
        onRecovery: recovery ? hit('recovery') : null,
        onExtensions: extensions ? hit('extensions') : null,
        onDelete: showDelete ? hit('delete') : null,
      ),
    ),
  );
}

void _tallPhone(WidgetTester tester, [Size size = const Size(390, 1400)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('TalkBack: the conversation\'s name is the heading, the '
      'window says what it is', (tester) async {
    final semantics = tester.ensureSemantics();
    _tallPhone(tester);
    await tester.pumpWidget(_app());
    expect(
      tester.getSemantics(find.byKey(const ValueKey('chat-control-header'))),
      isSemantics(label: 'Synthetic conversation', isHeader: true),
    );
    expect(find.bySemanticsLabel('This conversation'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('order: the name and the pill, PANELES, the actions, Delete', (
    tester,
  ) async {
    _tallPhone(tester);
    await tester.pumpWidget(_app());
    final header = tester.getRect(
      find.byKey(const ValueKey('chat-control-header')),
    );
    final quick = tester.getRect(
      find.byKey(const ValueKey('chat-control-quick')),
    );
    // The pill at the name's right, on its first line.
    expect(quick.left, greaterThanOrEqualTo(header.right));
    expect(quick.top, lessThan(header.bottom));
    final heading = tester.getRect(
      find.byKey(const ValueKey('chat-control-panels')),
    );
    expect(find.text('PANELS'), findsOneWidget);
    expect(heading.top, greaterThan(header.bottom));
    var previous = heading.bottom;
    for (final kind in _panelOrder) {
      final rect = tester.getRect(_panel(kind));
      expect(rect.top, greaterThanOrEqualTo(previous - 0.5), reason: kind);
      previous = rect.bottom;
    }
    for (final id in _actionOrder) {
      final rect = tester.getRect(_row(id));
      expect(rect.top, greaterThan(previous - 0.5), reason: id);
      previous = rect.bottom;
    }
    expect(tester.getRect(_row('delete')).top, greaterThan(previous));
    // Each one a row as wide as the list, at least 48 dp tall.
    final width = tester.getSize(_row('refresh')).width;
    for (final id in [..._actionOrder, 'delete']) {
      final size = tester.getSize(_row(id));
      expect(size.height, greaterThanOrEqualTo(48), reason: id);
      expect(size.width, width, reason: id);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('what lives elsewhere is not here: model, permissions, Ir a, '
      'Memory, Skills, the layout', (tester) async {
    _tallPhone(tester);
    await tester.pumpWidget(_app());
    for (final key in [
      // Desktop has one Artifacts view; the old second entry is gone.
      'chat-control-artifacts',
      'chat-control-model',
      'chat-control-permissions',
      'chat-control-memory',
      'chat-control-skills',
      'chat-control-previous-chat',
      'chat-control-next-chat',
      'chat-notch-go-to',
      'chat-views-layout',
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
    }
    expect(
      find.byWidgetPredicate((w) => w is HermesSegmentedControl),
      findsNothing,
    );
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
  });

  testWidgets('every row does what it says', (tester) async {
    _tallPhone(tester);
    final calls = <String, int>{};
    await tester.pumpWidget(_app(calls: calls));
    for (final id in [..._actionOrder, 'delete', 'find', 'new-chat']) {
      await tester.tap(_row(id));
    }
    for (final kind in _panelOrder) {
      await tester.tap(_panel(kind));
    }
    expect(calls, {
      for (final id in [
        ..._actionOrder,
        'delete',
        'find',
        'new-chat',
        ..._panelOrder,
      ])
        id: 1,
    });
  });

  group('the quick pill (ref-ventanas-2)', () {
    for (final scale in const [1.0, 1.3, 2.0]) {
      testWidgets('text ${scale}x: two round buttons, 48 dp targets, '
          'named for TalkBack', (tester) async {
        final semantics = tester.ensureSemantics();
        _tallPhone(tester);
        await tester.pumpWidget(_app(textScale: scale));
        expect(tester.takeException(), isNull);
        final quick = find.byKey(const ValueKey('chat-control-quick'));
        for (final (id, name) in const [
          ('find', 'Search this chat'),
          ('new-chat', 'New chat'),
        ]) {
          final button = find.descendant(of: quick, matching: _row(id));
          expect(button, findsOneWidget, reason: id);
          final rect = tester.getRect(button);
          expect(rect.width, greaterThanOrEqualTo(48), reason: id);
          expect(rect.height, greaterThanOrEqualTo(48), reason: id);
          expect(
            tester.getSemantics(button),
            isSemantics(tooltip: name, isButton: true, hasTapAction: true),
          );
          final circle = tester.widget<IconButton>(button);
          expect(
            circle.style!.shape!.resolve(const <WidgetState>{}),
            isA<CircleBorder>(),
          );
        }
        // No divider: two circles in a capsule.
        expect(
          find.descendant(of: quick, matching: find.byType(ColoredBox)),
          findsNothing,
        );
        semantics.dispose();
      });
    }

    testWidgets('a Bot Chat: «Buscar» and its desktop', (tester) async {
      _tallPhone(tester);
      await tester.pumpWidget(_app(newChat: false, desktop: true));
      final quick = find.byKey(const ValueKey('chat-control-quick'));
      expect(
        find.descendant(of: quick, matching: _row('desktop')),
        findsOneWidget,
      );
      expect(_row('new-chat'), findsNothing);
    });

    testWidgets('without a second action «Buscar» is a row of the list', (
      tester,
    ) async {
      _tallPhone(tester);
      await tester.pumpWidget(_app(newChat: false));
      expect(find.byKey(const ValueKey('chat-control-quick')), findsNothing);
      expect(find.text('Search this chat'), findsOneWidget);
      expect(
        tester.getRect(_row('find')).bottom,
        lessThanOrEqualTo(tester.getRect(_row('refresh')).top + 0.5),
      );
    });
  });

  group('PANELES', () {
    testWidgets('Terminal · Archivos · Git · Navegador; the one showing is '
        'marked «on screen» and read so', (tester) async {
      final semantics = tester.ensureSemantics();
      _tallPhone(tester);
      await tester.pumpWidget(_app(open: ChatWorkspaceKind.terminal));
      final colors = AppTheme.hermesRedDark.hermes;
      expect(
        find.descendant(
          of: _panel('terminal'),
          matching: find.byKey(const ValueKey('chat-control-panel-open')),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('chat-control-panel-open')),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(_panel('terminal')),
        isSemantics(
          label: 'Terminal, on screen',
          isButton: true,
          isSelected: true,
          hasTapAction: true,
        ),
      );
      expect(
        tester.getSemantics(_panel('files')),
        isSemantics(label: 'Files', isSelected: false, hasTapAction: true),
      );
      // Git reads its count as words.
      expect(
        tester.getSemantics(_panel('git')),
        isSemantics(label: 'Git, 4 changes'),
      );
      expect(
        find.descendant(of: _panel('git'), matching: find.text('4')),
        findsOneWidget,
      );
      final name = tester.widget<Text>(
        find.descendant(
          of: _panel('terminal'),
          matching: find.text('Terminal'),
        ),
      );
      // The accent's words, readable on its tint (REVIEW-Q9-VENT P2).
      expect(
        name.style!.color,
        HermesFloatingSurface.windowInk(
          colors,
          colors.accentText,
          tint: colors.accent.withValues(alpha: 0.16),
        ),
      );
      expect(name.style!.fontWeight, FontWeight.w700);
      for (final (kind, icon) in const [
        ('terminal', Icons.terminal_rounded),
        ('files', Icons.folder_open_outlined),
        ('git', Icons.call_split_rounded),
        ('browser', Icons.language_rounded),
      ]) {
        expect(
          find.descendant(of: _panel(kind), matching: find.byIcon(icon)),
          findsOneWidget,
          reason: kind,
        );
      }
      semantics.dispose();
    });

    testWidgets('a panel that does not exist leaves no trace; none, no '
        'heading', (tester) async {
      _tallPhone(tester);
      await tester.pumpWidget(
        _app(
          workspace: [
            ChatWorkspaceEntry(
              kind: ChatWorkspaceKind.terminal,
              label: 'Terminal',
              available: false,
              onTap: () {},
            ),
            ChatWorkspaceEntry(
              kind: ChatWorkspaceKind.browser,
              label: 'Browser',
              onTap: () {},
            ),
          ],
        ),
      );
      expect(_panel('terminal'), findsNothing);
      expect(_panel('browser'), findsOneWidget);
      await tester.pumpWidget(_app(workspace: const []));
      expect(find.byKey(const ValueKey('chat-control-panels')), findsNothing);
      expect(
        find.byKey(const ValueKey('chat-control-workspace')),
        findsNothing,
      );
    });
  });

  group('Delete', () {
    testWidgets('apart, last, in the error colour', (tester) async {
      _tallPhone(tester);
      await tester.pumpWidget(_app());
      final colors = AppTheme.hermesRedDark.hermes;
      final text = tester.widget<Text>(
        find.descendant(
          of: _row('delete'),
          matching: find.text('Delete conversation'),
        ),
      );
      // The error's red, readable on the window (REVIEW-Q9-VENT P2-1:
      // the raw token gave 2.93:1 in Console dark), its hue kept.
      final red = HermesFloatingSurface.windowInk(colors, colors.error);
      expect(text.style?.color, red);
      final hue = (HSLColor.fromColor(red).hue -
              HSLColor.fromColor(colors.error).hue)
          .abs();
      expect(hue > 180 ? 360 - hue : hue, lessThan(2));
      expect(
        ThemeContrast.ratio(red, HermesChrome.of(colors).opaque),
        greaterThanOrEqualTo(4.5 - 0.01),
      );
      expect(
        tester.widget<Icon>(
          find.descendant(of: _row('delete'), matching: find.byType(Icon)),
        ).color,
        red,
      );
      // A line keeps it apart from the actions.
      expect(find.byType(Divider), findsNWidgets(2));
    });

    testWidgets('read-only: shown, disabled, badge in the header', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      _tallPhone(tester);
      final calls = <String, int>{};
      await tester.pumpWidget(_app(calls: calls, readOnly: true));
      expect(find.byType(HermesBadge), findsOneWidget);
      expect(
        tester.getSemantics(_row('delete')),
        isSemantics(hasEnabledState: true, isEnabled: false),
      );
      await tester.tap(_row('delete'));
      expect(calls, isEmpty);
      final text = tester.widget<Text>(
        find.descendant(
          of: _row('delete'),
          matching: find.text('Delete conversation'),
        ),
      );
      expect(
        text.style?.color,
        AppTheme.hermesRedDark.hermes.textDisabled,
      );
      semantics.dispose();
    });

    testWidgets('absent when deletion does not apply', (tester) async {
      _tallPhone(tester);
      await tester.pumpWidget(_app(showDelete: false));
      expect(_row('delete'), findsNothing);
    });
  });

  testWidgets('conditional rows only when they exist', (tester) async {
    _tallPhone(tester);
    await tester.pumpWidget(
      _app(
        branch: false,
        recovery: false,
        pinned: false,
        showCron: false,
        showDetails: false,
        extensions: false,
      ),
    );
    for (final id in [
      'branch',
      'recovery',
      'show-pinned-prompt',
      'cron',
      'details',
      'extensions',
    ]) {
      expect(_row(id), findsNothing, reason: id);
    }
    for (final id in ['refresh', 'content', 'prompts']) {
      expect(_row(id), findsOneWidget, reason: id);
    }
  });

  group('themes', () {
    for (final (name, theme) in [
      ('dark', AppTheme.hermesRedDark),
      ('light', AppTheme.hermesRedLight),
    ]) {
      testWidgets('$name: theme tokens, nothing hard-coded', (tester) async {
        _tallPhone(tester);
        await tester.pumpWidget(_app(theme: theme));
        final colors = theme.hermes;
        final chrome = HermesChrome.of(colors);
        final artifacts = tester.widget<Text>(
          find.descendant(
            of: _row('content'),
            matching: find.text('Artifacts'),
          ),
        );
        expect(
          artifacts.style?.color,
          HermesFloatingSurface.windowInk(colors, colors.textPrimary),
        );
        expect(
          tester.widget<Icon>(
            find.descendant(of: _row('content'), matching: find.byType(Icon)),
          ).color,
          chrome.mutedInk,
        );
        final title = tester.widget<Text>(find.text('Synthetic conversation'));
        expect(
          title.style?.color,
          HermesFloatingSurface.windowInk(colors, colors.textPrimary),
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  // Geometry 320-884, text 1.0 / 1.3 / 2.0: nothing overflows, nothing is
  // cut; the name wraps to two lines and the rows' names wrap.
  // The Fold (773, 884) and a tablet (1280) too (ORDEN-LOOP, Terminal 3).
  for (final width in const [320.0, 390.0, 773.0, 884.0, 1280.0]) {
    for (final scale in const [1.0, 1.3, 2.0]) {
      testWidgets('${width.toInt()} dp, text ${scale}x: rows whole, '
          'nothing overflows', (tester) async {
        _tallPhone(tester, Size(width, 2400));
        final semantics = tester.ensureSemantics();
        try {
          await tester.pumpWidget(
            _app(
              textScale: scale,
              panelOpen: StringsEs().chaControlPanelOpen,
              open: ChatWorkspaceKind.git,
              title: 'Revisión del apk antes de publicarla en la tienda',
            ),
          );
          expect(tester.takeException(), isNull);
          final title = tester.widget<Text>(
            find.text('Revisión del apk antes de publicarla en la tienda'),
          );
          expect(title.maxLines, 2);
          for (final id in [..._actionOrder, 'delete']) {
            expect(
              tester.getSize(_row(id)).height,
              greaterThanOrEqualTo(48),
              reason: id,
            );
          }
          for (final kind in _panelOrder) {
            expect(
              tester.getSize(_panel(kind)).height,
              greaterThanOrEqualTo(48),
            );
          }
          final selected = _panel('git');
          expect(
            tester.getSemantics(selected),
            isSemantics(
              label: 'Git, 4 changes, en pantalla',
              isButton: true,
              isEnabled: true,
              isSelected: true,
              hasTapAction: true,
            ),
          );
          final bounds = tester.getRect(selected);
          for (final text in ['Git', '4', 'en pantalla']) {
            final content = find.descendant(
              of: selected,
              matching: find.text(text),
            );
            expect(content, findsOneWidget);
            expect(content.hitTestable(), findsOneWidget);
            final rect = tester.getRect(content);
            expect(rect.left, greaterThanOrEqualTo(bounds.left));
            expect(rect.right, lessThanOrEqualTo(bounds.right));
            expect(rect.top, greaterThanOrEqualTo(bounds.top));
            expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
            final widget = tester.widget<Text>(content);
            expect(widget.maxLines, isNull, reason: text);
            expect(widget.overflow, isNull, reason: text);
          }
        } finally {
          semantics.dispose();
        }
      });
    }
  }

  testWidgets('floating surface at 2x text stays bounded and scrolls to '
      'Delete', (tester) async {
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
                    labels: _labels(),
                    conversationTitle: 'Synthetic conversation',
                    showDetails: true,
                    showCron: true,
                    onRefresh: () {},
                    onContent: () {},
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
      _row('delete'),
      260,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('chat-control-sheet')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(_row('delete'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ORDEN-LOOP 1.4, Terminal 3: Ajustes as it opens, a lifted window
  // anchored to its button at the top right, on the Fold and a tablet:
  // whole on screen, no wider than its 360, Delete reachable.
  for (final size in const [Size(884, 1000), Size(1280, 800), Size(773, 900)]) {
    testWidgets('lifted at ${size.width.toInt()}x${size.height.toInt()}: '
        'anchored, whole, bounded', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.hermesRedDark,
          home: Builder(
            builder: (context) => Scaffold(
              body: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Builder(
                    builder: (anchor) => IconButton(
                      key: const ValueKey('test-settings'),
                      icon: const Icon(Icons.more_horiz_rounded),
                      onPressed: () => showHermesSurface<void>(
                        context: anchor,
                        surfaceKey: const ValueKey('test-ajustes'),
                        originRect: hermesOriginOf(anchor),
                        maxWidth: 360,
                        scrim: HermesScrim.menu,
                        coversPage: false,
                        lifted: true,
                        builder: (_) => ChatControlSheet(
                          labels: _labels(),
                          conversationTitle: 'Synthetic conversation',
                          workspace: [
                            ChatWorkspaceEntry(
                              kind: ChatWorkspaceKind.terminal,
                              label: 'Terminal',
                              open: true,
                              onTap: () {},
                            ),
                          ],
                          onFindInChat: () {},
                          onNewChat: () {},
                          onRefresh: () {},
                          onContent: () {},
                          onDelete: () {},
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('test-settings')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final window = tester.getRect(find.byKey(const ValueKey('test-ajustes')));
      expect(window.width, lessThanOrEqualTo(360));
      expect(window.left, greaterThanOrEqualTo(0));
      expect(window.right, lessThanOrEqualTo(size.width));
      expect(window.top, greaterThanOrEqualTo(0));
      expect(window.bottom, lessThanOrEqualTo(size.height));
      // At its button: in the right half of the screen.
      expect(window.center.dx, greaterThan(size.width / 2));
      expect(_row('delete').hitTestable(), findsOneWidget);
      expect(find.text('PANELS'), findsOneWidget);
    });
  }
}
