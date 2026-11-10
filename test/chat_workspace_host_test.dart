import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show BackdropFilterLayer;
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart'
    show HermesChrome, HermesScrim;
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/motion.dart' show HermesMotion;
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _chatField = ValueKey('fake-chat-field');
const _divider = ValueKey('chat-workspace-divider');
const _bar = ValueKey('chat-workspace-actions');
const _rail = ValueKey('chat-workspace-rail');

/// Stands in for the chat: a text field whose draft must survive every
/// layout change (it would be lost if the chat were rebuilt from scratch).
class _FakeChat extends StatelessWidget {
  const _FakeChat();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(child: TextField(key: _chatField)),
  );
}

/// A tab with its own state: a counter that must survive tab switches and
/// layout changes.
class _FakeTab extends StatefulWidget {
  const _FakeTab(this.tab);

  final ChatWorkspaceTab tab;

  @override
  State<_FakeTab> createState() => _FakeTabState();
}

class _FakeTabState extends State<_FakeTab> {
  int taps = 0;

  @override
  Widget build(BuildContext context) {
    final name = widget.tab.name;
    // It scrolls in a pane lower than its controls (a low pane with the
    // keyboard up), as a real panel's content does.
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                key: ValueKey('tab-$name'),
                onPressed: () => setState(() => taps++),
                child: Text('$name $taps'),
              ),
              // Opens a second screen inside the tab, like the SSH hub
              // opening the terminal.
              TextButton(
                key: ValueKey('tab-push-$name'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(body: Text('inner $name')),
                  ),
                ),
                child: const Text('push'),
              ),
              // Leaves the tab's first screen, like a cancelled App Lock.
              TextButton(
                key: ValueKey('tab-leave-$name'),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('leave'),
              ),
              Text(
                ChatWorkspacePaneScope.isInPane(context) ? 'in pane' : 'alone',
                key: ValueKey('tab-scope-$name'),
              ),
              // A field of the tab's own (the Browser's address, a search in
              // Files, the terminal's input).
              SizedBox(
                width: 200,
                child: TextField(key: ValueKey('tab-field-$name')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tab that puts its own controls on the floating bar, like the terminal
/// (keys, Herdr, an entry of «⋯»).
class _ToolbarTab extends StatefulWidget {
  const _ToolbarTab({this.needsYou = 0});

  final int needsYou;

  @override
  State<_ToolbarTab> createState() => _ToolbarTabState();
}

class _ToolbarTabState extends State<_ToolbarTab> {
  bool keys = true;
  int herdr = 0;
  int menu = 0;

  void _toggleKeys() => setState(() => keys = !keys);
  void _openHerdr() => setState(() => herdr++);
  void _menuEntry() => setState(() => menu++);
  int _needsYou() => widget.needsYou;

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ChatWorkspacePaneScope.publish(
        context,
        ChatWorkspaceToolbar(
          keysShown: keys,
          onToggleKeys: _toggleKeys,
          onHerdr: _openHerdr,
          herdrNeedsYou: _needsYou,
          menu: [
            ChatWorkspaceMenuEntry(
              key: const ValueKey('tab-menu-entry'),
              label: 'Tab action',
              icon: Icons.build_outlined,
              onSelected: _menuEntry,
            ),
          ],
        ),
      );
    });
    return Scaffold(body: Text('keys $keys herdr $herdr menu $menu'));
  }
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<ChatWorkspaceController> _pump(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
  ChatWorkspaceController? controller,
  ThemeData? theme,
  double textScale = 1,
  SharedPreferences? prefs,
  List<ChatWorkspaceTab> availableTabs = ChatWorkspaceTab.values,
  Widget? navigation,
  int? Function(ChatWorkspaceTab tab)? tabBadge,
  ChatWorkspaceTabBuilder? tabBuilder,
  bool reduceMotion = false,
  bool outerScaffold = false,
  Widget Function(ChatWorkspaceController controller)? chat,
  TextDirection? textDirection,
}) async {
  _size(tester, size);
  final c = controller ?? ChatWorkspaceController(prefs: prefs);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: const [
        Strings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: Strings.supportedLocales,
      theme: theme ?? AppTheme.hermesRedDark,
      builder: (context, home) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reduceMotion,
        ),
        child: textDirection == null
            ? home!
            : Directionality(textDirection: textDirection, child: home!),
      ),
      home: Builder(
        builder: (context) {
          final host = ChatWorkspaceHost(
            controller: c,
            chat: chat?.call(c) ?? const _FakeChat(),
            tabBuilder: tabBuilder ?? (_, tab) => _FakeTab(tab),
            availableTabs: availableTabs,
            navigation: navigation,
            tabBadge: tabBadge,
          );
          // The Chats screen around the chat on the open Fold: a Scaffold
          // that makes room for the keyboard and takes it out of the
          // MediaQuery it gives its body (the owner's capture 1659).
          return outerScaffold ? Scaffold(body: host) : host;
        },
      ),
    ),
  );
  return c;
}

/// The haptic ticks asked of the platform while the test runs.
List<Object?> _recordHaptics(WidgetTester tester) {
  final ticks = <Object?>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') ticks.add(call.arguments);
    return null;
  });
  addTearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });
  return ticks;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  // A motion started once a frame is laid out (the keyboard fold, gint56)
  // ticks from the next frame: settled is after it too.
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('no tab open: the chat alone, exactly as before', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.byKey(_divider), findsNothing);
    expect(find.byKey(_bar), findsNothing);
    expect(
      tester.getRect(find.byType(_FakeChat)),
      const Rect.fromLTWH(0, 0, 1280, 800),
    );
  });

  // Review R5A P2-B1-3: on a phone (no tab, too narrow to split) the chat
  // is not built inside the host's LayoutBuilder; widening moves it there
  // and back with its state.
  testWidgets('a phone builds the chat outside any LayoutBuilder of the host', (
    tester,
  ) async {
    await _pump(tester, size: const Size(412, 915));
    await tester.enterText(find.byKey(_chatField), 'draft in progress');
    int layoutBuilders() => find
        .ancestor(
          of: find.byKey(_chatField),
          matching: find.byType(LayoutBuilder),
        )
        .evaluate()
        .length;
    final phone = layoutBuilders();

    tester.view.physicalSize = const Size(1280, 800);
    await _settle(tester);
    expect(layoutBuilders(), phone + 1);
    expect(find.text('draft in progress'), findsOneWidget);

    tester.view.physicalSize = const Size(412, 915);
    await _settle(tester);
    expect(layoutBuilders(), phone);
    expect(find.text('draft in progress'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // the owner (APK 9708): the Terminal gets the room, the chat keeps 480 dp.
  testWidgets('tablet 1280 x 800: chat 480 | divider | Terminal', (
    tester,
  ) async {
    final c = await _pump(tester);
    await tester.enterText(find.byKey(_chatField), 'draft in progress');
    c.open(ChatWorkspaceTab.terminal);
    await _settle(tester);

    expect(find.byKey(_divider), findsOneWidget);
    expect(find.byKey(_bar), findsOneWidget);
    expect(find.byKey(const ValueKey('tab-terminal')), findsOneWidget);
    final chat = tester.getRect(find.byType(_FakeChat));
    expect(chat.left, 10);
    expect(chat.width, 480);
    expect(tester.getRect(find.byKey(_divider)).width, 14);
    // The chat kept its draft through the move into the pane.
    expect(find.text('draft in progress'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // the owner (APK 9708): at 0.44 the chat had 396 dp (~25 characters a line)
  // and Files two rows in the rest. Files now opens at 58/42, the Terminal
  // with the chat at its 480 dp floor; each kind keeps its own split.
  testWidgets('open Fold 933 x 704: Files 58/42, Terminal 480 dp', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = await _pump(tester, size: const Size(933, 704), prefs: prefs);
    c.open(ChatWorkspaceTab.files);
    await _settle(tester);
    expect(tester.getRect(find.byType(_FakeChat)).width, 521);
    expect(find.byKey(const ValueKey('tab-files')), findsOneWidget);

    c.open(ChatWorkspaceTab.terminal);
    await _settle(tester);
    expect(tester.getRect(find.byType(_FakeChat)).width, 480);

    // Widen the chat beside the Terminal: Files keeps its own split.
    await tester.drag(find.byKey(_divider), const Offset(60, 0));
    await _settle(tester);
    expect(tester.getRect(find.byType(_FakeChat)).width, closeTo(540, 1));
    c.activate(ChatWorkspaceTab.files);
    await _settle(tester);
    expect(tester.getRect(find.byType(_FakeChat)).width, 521);
    c.activate(ChatWorkspaceTab.terminal);
    await _settle(tester);
    expect(tester.getRect(find.byType(_FakeChat)).width, closeTo(540, 1));
    expect(
      prefs.getDouble(
        ChatWorkspaceController.ratioKeyFor(ChatWorkspaceTab.terminal),
      ),
      closeTo(540 / 899, 0.002),
    );
    expect(tester.takeException(), isNull);
  });

  for (final size in const [Size(412, 915), Size(800, 1280)]) {
    testWidgets('${size.width.toInt()} dp: opening directly uses the pane', (
      tester,
    ) async {
      final c = await _pump(tester, size: size);
      c.open(ChatWorkspaceTab.terminal);
      await _settle(tester);
      expect(c.canSplit, isFalse);
      expect(find.byKey(_divider), findsNothing);
      expect(
        tester.getRect(find.byType(_FakeChat, skipOffstage: false)),
        Rect.fromLTWH(0, 0, size.width, size.height),
      );
      // QA9716: one owner, now the same pane as Split→upright rather than
      // a second full-screen route above a hidden Terminal.
      expect(
        find.byKey(const ValueKey('tab-terminal'), skipOffstage: false),
        findsOneWidget,
      );
      expect(c.tabs, [ChatWorkspaceTab.terminal]);
      expect(find.byKey(_bar), findsOneWidget);
      // The rail only from 600 dp; on a phone the panel is the whole screen.
      expect(
        find.byKey(_rail),
        size.width < 600 ? findsNothing : findsOneWidget,
      );
      expect(c.mode, ChatWorkspaceMode.split);
    });
  }

  // Review R5A P2-B1-1: folding the workspace, or a window too narrow for
  // it, keeps every tab but the Terminal as it was (the Browser's page, the
  // Files folder, the Git diff); only the Terminal is built again.
  testWidgets('folding keeps the tabs but the Terminal as they were', (
    tester,
  ) async {
    final c = await _pump(tester);
    c
      ..open(ChatWorkspaceTab.terminal)
      ..open(ChatWorkspaceTab.files);
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('tab-files')));
    await tester.pump();
    expect(find.text('files 1'), findsOneWidget);
    final files = find.ancestor(
      of: find.byKey(const ValueKey('tab-files'), skipOffstage: false),
      matching: find.byType(_FakeTab, skipOffstage: false),
    );
    final state = tester.state(files);

    c.setMode(ChatWorkspaceMode.chat);
    await _settle(tester);
    expect(tester.getRect(find.byType(_FakeChat)).width, 1280);
    expect(find.text('files 1'), findsNothing);
    expect(find.text('files 1', skipOffstage: false), findsOneWidget);
    expect(
      find.byKey(const ValueKey('tab-terminal'), skipOffstage: false),
      findsNothing,
    );

    c.setMode(ChatWorkspaceMode.split);
    await _settle(tester);
    expect(find.text('files 1'), findsOneWidget);
    expect(tester.state(files), same(state));

    // Too narrow and back (a tablet turned upright).
    tester.view.physicalSize = const Size(800, 1280);
    await _settle(tester);
    expect(find.byKey(_divider), findsNothing);
    expect(find.text('files 1', skipOffstage: false), findsOneWidget);
    tester.view.physicalSize = const Size(1280, 800);
    await _settle(tester);
    expect(find.text('files 1'), findsOneWidget);
    expect(tester.state(files), same(state));
    expect(tester.takeException(), isNull);
  });

  testWidgets('drag the divider, saved on release; double tap resets', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = await _pump(tester, prefs: prefs);
    c.open(ChatWorkspaceTab.terminal);
    await _settle(tester);

    await tester.drag(find.byKey(_divider), const Offset(100, 0));
    await _settle(tester);
    expect(tester.getRect(find.byType(_FakeChat)).width, closeTo(580, 1));
    expect(
      prefs.getDouble(
        ChatWorkspaceController.ratioKeyFor(ChatWorkspaceTab.terminal),
      ),
      closeTo(580 / 1246, 0.002),
    );

    // Past the limits: the chat's 480 dp floor and 0.70 of 1246 dp.
    await tester.drag(find.byKey(_divider), const Offset(-2000, 0));
    await _settle(tester);
    expect(tester.getRect(find.byType(_FakeChat)).width, 480);
    await tester.drag(find.byKey(_divider), const Offset(3000, 0));
    await _settle(tester);
    expect(tester.getRect(find.byType(_FakeChat)).width, 872);

    final divider = find.byKey(_divider);
    await tester.tap(divider);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(divider);
    await _settle(tester);
    expect(tester.getRect(find.byType(_FakeChat)).width, 480);
    expect(
      prefs.getDouble(
        ChatWorkspaceController.ratioKeyFor(ChatWorkspaceTab.terminal),
      ),
      isNull,
    );
  });

  testWidgets('the divider is a slider for screen readers', (tester) async {
    final semantics = tester.ensureSemantics();
    final c = await _pump(tester);
    c.open(ChatWorkspaceTab.terminal);
    await _settle(tester);
    expect(
      tester.getSemantics(find.byKey(_divider)),
      isSemantics(
        label: 'Divider between chat and workspace',
        value: 'Chat at 39%', // 480 of 1246 dp
        hasIncreaseAction: true,
        // At its floor: a step down would move nothing.
        hasDecreaseAction: false,
      ),
    );
    semantics.dispose();
  });

  // Review R5A P3-B1-4: the divider says the share as laid out (the panes'
  // floor can keep it from the stored ratio) and offers no step that would
  // move nothing.
  testWidgets('the divider announces the real share and its limits', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final c = await _pump(tester, size: const Size(933, 704));
    c
      ..open(ChatWorkspaceTab.terminal)
      ..setRatio(ChatWorkspaceController.minRatio);
    await _settle(tester);
    // Stored 25 %, but the chat keeps its 480 dp floor: 480 of 899.
    expect(tester.getRect(find.byType(_FakeChat)).width, 480);
    expect(
      tester.getSemantics(find.byKey(_divider)),
      isSemantics(
        label: 'Divider between chat and workspace',
        value: 'Chat at 53%',
        hasIncreaseAction: true,
        hasDecreaseAction: false,
      ),
    );
    c.setRatio(ChatWorkspaceController.maxRatio);
    await _settle(tester);
    expect(
      tester.getSemantics(find.byKey(_divider)),
      isSemantics(
        label: 'Divider between chat and workspace',
        value: 'Chat at 69%',
        hasIncreaseAction: false,
        hasDecreaseAction: true,
      ),
    );
    semantics.dispose();
  });

  // Review R5A P3-B1-6: dragging past the limit and back moves the divider
  // at once, not after undoing the excess.
  testWidgets('the divider follows the finger back from its limit', (
    tester,
  ) async {
    final c = await _pump(tester, size: const Size(933, 704));
    c.open(ChatWorkspaceTab.terminal);
    await _settle(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(_divider)),
    );
    await gesture.moveBy(const Offset(-400, 0));
    await tester.pump();
    expect(tester.getRect(find.byType(_FakeChat)).width, 480);
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    expect(tester.getRect(find.byType(_FakeChat)).width, 500);
    await gesture.up();
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  // Review R5A P3-B1-5, Fold 2: with the keyboard up the bar folds behind
  // «Mostrar herramientas», which stays whole at the top of a low pane.
  testWidgets('the tools handle stays inside a low pane', (tester) async {
    final c = await _pump(tester, size: const Size(1280, 330));
    c.open(ChatWorkspaceTab.terminal);
    await _settle(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 100);
    addTearDown(tester.view.resetViewInsets);
    await _settle(tester);
    expect(find.byKey(_bar), findsNothing);
    final handle = tester.getRect(
      find.byKey(const ValueKey('chat-workspace-show-tools')),
    );
    // Ola 1 (audit 2.6): in from the pane's corner by its inset, where the
    // corner's radius no longer cuts it.
    final pane = tester.getRect(
      find.byKey(const ValueKey('chat-workspace-body-terminal')),
    );
    expect(
      handle.right,
      lessThanOrEqualTo(pane.right - ChatWorkspaceTokens.inset + 0.5),
    );
    expect(
      handle.top,
      greaterThanOrEqualTo(pane.top + ChatWorkspaceTokens.inset - 0.5),
    );
    expect(handle.top, greaterThanOrEqualTo(0));
    expect(handle.bottom, lessThanOrEqualTo(330 - 10));
    expect(handle.width, greaterThanOrEqualTo(48));
    expect(handle.height, greaterThanOrEqualTo(48));
    await tester.tap(find.byKey(const ValueKey('chat-workspace-show-tools')));
    await _settle(tester);
    expect(find.byKey(_bar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pane bar: «Chat» folds, expand to workspace only, rail, menu', (
    tester,
  ) async {
    final c = await _pump(tester);
    await tester.enterText(find.byKey(_chatField), 'keep me');
    c.open(ChatWorkspaceTab.terminal);
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('tab-terminal')));
    await _settle(tester);
    expect(find.text('terminal 1'), findsOneWidget);

    // Expand: workspace only, the chat folds into the rail.
    await tester.tap(find.byKey(const ValueKey('chat-workspace-expand')));
    await _settle(tester);
    expect(c.mode, ChatWorkspaceMode.workspace);
    expect(find.byKey(_rail), findsOneWidget);
    expect(find.byKey(_chatField), findsNothing);
    expect(tester.getRect(find.byKey(_rail)).width, 56);
    expect(find.text('terminal 1'), findsOneWidget);

    // The rail brings the chat back, draft intact.
    await tester.tap(find.byKey(const ValueKey('chat-workspace-show-chat')));
    await _settle(tester);
    expect(c.mode, ChatWorkspaceMode.split);
    expect(find.text('keep me'), findsOneWidget);

    // Fold the panel: chat only. The workspace is unmounted (review
    // P1-F4-1); the tab stays listed and comes back fresh.
    await tester.tap(find.byKey(const ValueKey('chat-workspace-collapse')));
    await _settle(tester);
    expect(c.mode, ChatWorkspaceMode.chat);
    expect(find.byKey(_divider), findsNothing);
    expect(tester.getRect(find.byType(_FakeChat)).width, 1280);
    expect(
      find.byKey(const ValueKey('tab-terminal'), skipOffstage: false),
      findsNothing,
    );

    c.open(ChatWorkspaceTab.terminal);
    await _settle(tester);
    expect(find.text('terminal 0'), findsOneWidget);

    // Layout menu.
    await tester.tap(find.byKey(const ValueKey('chat-workspace-layout-menu')));
    await _settle(tester);
    expect(find.text('Chat only'), findsOneWidget);
    expect(find.text('Split'), findsOneWidget);
    await tester.tap(find.text('Workspace only'));
    await _settle(tester);
    expect(c.mode, ChatWorkspaceMode.workspace);
    expect(tester.takeException(), isNull);
  });

  // Mock 136 v2-A: one selector, every panel the chat offers, always there.
  testWidgets('selector: a panel opens with a tap, keeps its state, closes '
      'from «⋯»', (tester) async {
    final c = await _pump(
      tester,
      availableTabs: const [ChatWorkspaceTab.terminal, ChatWorkspaceTab.files],
    );
    c.open(ChatWorkspaceTab.terminal);
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('tab-terminal')));
    await _settle(tester);
    // Only what the chat offers: no Git or Browser segment, no «+».
    expect(find.byKey(const ValueKey('chat-workspace-tab-git')), findsNothing);
    expect(find.byKey(const ValueKey('chat-workspace-add-tab')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('chat-workspace-tab-files')));
    await _settle(tester);
    expect(c.active, ChatWorkspaceTab.files);
    expect(c.tabs, [ChatWorkspaceTab.terminal, ChatWorkspaceTab.files]);
    expect(find.text('files 0'), findsOneWidget);
    expect(find.text('terminal 1'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('chat-workspace-tab-terminal')),
    );
    await _settle(tester);
    expect(find.text('terminal 1'), findsOneWidget);

    Future<void> closeActive() async {
      await tester.tap(
        find.byKey(const ValueKey('chat-workspace-layout-menu')),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('chat-workspace-close-tab')));
      await _settle(tester);
    }

    await closeActive();
    expect(c.tabs, [ChatWorkspaceTab.files]);
    expect(find.text('files 0'), findsOneWidget);
    await closeActive();
    expect(c.hasWorkspace, isFalse);
    expect(find.byKey(_divider), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // Mock 136 v2-A: a swipe across the selector moves to the panel beside;
  // past the first panel it is «Chat», which folds the pane.
  testWidgets('selector: a swipe moves to the panel beside', (tester) async {
    final c = await _pump(tester);
    c.open(ChatWorkspaceTab.files);
    await _settle(tester);
    final selector = find.byKey(const ValueKey('chat-workspace-tabs'));
    await tester.fling(selector, const Offset(-120, 0), 800);
    await _settle(tester);
    expect(c.active, ChatWorkspaceTab.git);
    await tester.fling(selector, const Offset(120, 0), 800);
    await _settle(tester);
    expect(c.active, ChatWorkspaceTab.files);
    await tester.fling(selector, const Offset(120, 0), 800);
    await _settle(tester);
    expect(c.active, ChatWorkspaceTab.terminal);
    await tester.fling(selector, const Offset(120, 0), 800);
    await _settle(tester);
    expect(c.mode, ChatWorkspaceMode.chat);
    expect(find.byKey(_divider), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // Ola 7 (AUDITORIA-PULIDO §4.2): a tick when the pane changes panel,
  // none on the segment already shown; one when its tab is closed.
  testWidgets('selector and closing a tab tick under the finger', (
    tester,
  ) async {
    const tick = 'HapticFeedbackType.selectionClick';
    final ticks = _recordHaptics(tester);
    final c = await _pump(tester);
    c.open(ChatWorkspaceTab.terminal);
    await _settle(tester);
    expect(ticks, isEmpty, reason: 'opened by the app, not a tap');

    await tester.tap(find.byKey(const ValueKey('chat-workspace-tab-files')));
    await _settle(tester);
    expect(ticks, [tick]);
    await tester.tap(find.byKey(const ValueKey('chat-workspace-tab-files')));
    await _settle(tester);
    expect(ticks, [tick], reason: 'already on Files');
    await tester.fling(
      find.byKey(const ValueKey('chat-workspace-tabs')),
      const Offset(-120, 0),
      800,
    );
    await _settle(tester);
    expect(c.active, ChatWorkspaceTab.git);
    expect(ticks, [tick, tick]);

    await tester.tap(find.byKey(const ValueKey('chat-workspace-layout-menu')));
    await _settle(tester);
    final beforeClose = ticks.length;
    await tester.tap(find.byKey(const ValueKey('chat-workspace-close-tab')));
    await _settle(tester);
    expect(c.tabs, isNot(contains(ChatWorkspaceTab.git)));
    expect(ticks.length, beforeClose + 1);
    expect(ticks.last, tick);
    expect(tester.takeException(), isNull);
  });

  // Ola 7 (AUDITORIA-PULIDO §4.2, v25 `.sheet`): the pane comes in from
  // the right edge and goes out the same way; with «reduce motion» it is
  // there, or gone, in the first frame.
  group('motion', () {
    Rect body(WidgetTester tester, ChatWorkspaceTab tab) => tester.getRect(
      find.byKey(ValueKey('chat-workspace-body-${tab.name}')),
    );

    testWidgets('the pane slides in and out beside the chat', (tester) async {
      final c = await _pump(tester);
      c.open(ChatWorkspaceTab.files);
      await tester.pump();
      final first = body(tester, ChatWorkspaceTab.files);
      await tester.pump(HermesMotion.sheetOpen);
      final rest = body(tester, ChatWorkspaceTab.files);
      expect(first.left, greaterThan(rest.left + 300), reason: 'from the edge');
      expect(first.size, rest.size, reason: 'it moves, it is not resized');
      await tester.pump(HermesMotion.sheetOpen);
      expect(body(tester, ChatWorkspaceTab.files), rest);

      // Folded: it leaves the way it came, then the chat has the screen.
      await tester.tap(find.byKey(const ValueKey('chat-workspace-collapse')));
      await tester.pump();
      await tester.pump(HermesMotion.sheetClose ~/ 2);
      expect(find.byKey(_divider), findsOneWidget);
      expect(body(tester, ChatWorkspaceTab.files).left, greaterThan(rest.left));
      await tester.pump(HermesMotion.sheetClose);
      expect(find.byKey(_divider), findsNothing);
      expect(tester.getRect(find.byType(_FakeChat)).width, 1280);
      expect(c.mode, ChatWorkspaceMode.chat);

      // Opened again once gone: in from the edge once more.
      c.setMode(ChatWorkspaceMode.split);
      await tester.pump();
      expect(
        body(tester, ChatWorkspaceTab.files).left,
        greaterThan(rest.left + 300),
      );
      await tester.pump(HermesMotion.sheetOpen);
      expect(body(tester, ChatWorkspaceTab.files), rest);

      // Opened again half way out: back from where it is, no jump to the
      // edge (review T3-A).
      await tester.tap(find.byKey(const ValueKey('chat-workspace-collapse')));
      await tester.pump();
      await tester.pump(HermesMotion.sheetClose ~/ 2);
      final halfOut = body(tester, ChatWorkspaceTab.files).left;
      expect(halfOut, greaterThan(rest.left));
      c.setMode(ChatWorkspaceMode.split);
      await tester.pump();
      expect(
        body(tester, ChatWorkspaceTab.files).left,
        lessThanOrEqualTo(halfOut),
      );
      await tester.pump(HermesMotion.sheetOpen);
      expect(body(tester, ChatWorkspaceTab.files), rest);
      expect(tester.takeException(), isNull);
    });

    testWidgets('reduce motion: the pane is in place, or gone, at once', (
      tester,
    ) async {
      final c = await _pump(tester, reduceMotion: true);
      c.open(ChatWorkspaceTab.files);
      await tester.pump();
      final first = body(tester, ChatWorkspaceTab.files);
      await _settle(tester);
      expect(body(tester, ChatWorkspaceTab.files), first);

      await tester.tap(find.byKey(const ValueKey('chat-workspace-collapse')));
      await tester.pump();
      expect(find.byKey(_divider), findsNothing);
      expect(tester.getRect(find.byType(_FakeChat)).width, 1280);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a pane already open when the chat is built does not slide', (
      tester,
    ) async {
      final c = ChatWorkspaceController()..open(ChatWorkspaceTab.files);
      await _pump(tester, controller: c);
      final first = body(tester, ChatWorkspaceTab.files);
      await _settle(tester);
      expect(body(tester, ChatWorkspaceTab.files), first);
    });

    // v25 `transition: all .2s`: another tab fades in; the tint of the
    // segment slides to it and, at rest, is the segment's own.
    testWidgets('changing tab: the screen fades in, the tint slides', (
      tester,
    ) async {
      // Files and Git share their split, so the pane keeps its size.
      final c = await _pump(
        tester,
        availableTabs: const [ChatWorkspaceTab.files, ChatWorkspaceTab.git],
      );
      c
        ..open(ChatWorkspaceTab.files)
        ..open(ChatWorkspaceTab.git);
      await _settle(tester);
      const fadeKey = ValueKey('chat-workspace-tab-fade');
      double opacity() =>
          tester.widget<FadeTransition>(find.byKey(fadeKey)).opacity.value;
      const slide = ValueKey('chat-workspace-segment-slide');
      const tint = ValueKey('chat-workspace-segment-active');
      const files = ValueKey('chat-workspace-tab-files');
      final gitTint = tester.getRect(find.byKey(tint));

      await tester.tap(find.byKey(files));
      await tester.pump();
      expect(c.active, ChatWorkspaceTab.files);
      // The screen fades in.
      expect(opacity(), lessThan(0.5));
      await tester.pump(HermesMotion.base ~/ 2);
      // Half way: the tint between the two segments, the segment unpainted.
      final moving = tester.getRect(find.byKey(slide));
      expect(moving.left, lessThan(gitTint.left));
      expect(moving.left, greaterThan(tester.getRect(find.byKey(files)).left));
      final unpainted = tester.widget<DecoratedBox>(find.byKey(tint));
      expect(
        (unpainted.decoration as ShapeDecoration).color,
        Colors.transparent,
      );
      await tester.pump(HermesMotion.base);
      expect(opacity(), 1);
      expect(find.byKey(slide), findsNothing);
      expect(
        find.descendant(of: find.byKey(files), matching: find.byKey(tint)),
        findsOneWidget,
      );
      expect(tester.getRect(find.byKey(tint)).left, lessThan(gitTint.left));
      expect(tester.takeException(), isNull);
    });

    testWidgets('reduce motion: another tab and its tint at once', (
      tester,
    ) async {
      final c = await _pump(tester, reduceMotion: true);
      c
        ..open(ChatWorkspaceTab.terminal)
        ..open(ChatWorkspaceTab.files);
      await _settle(tester);
      await tester.tap(
        find.byKey(const ValueKey('chat-workspace-tab-terminal')),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('chat-workspace-segment-slide')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('chat-workspace-tab-terminal')),
          matching: find.byKey(const ValueKey('chat-workspace-segment-active')),
        ),
        findsOneWidget,
      );
      final fade = tester.widget<FadeTransition>(
        find.byKey(const ValueKey('chat-workspace-tab-fade')),
      );
      expect(fade.opacity.value, 1);
    });

    // AUDITORIA §4.2: the pane's bar folded away in one frame when the
    // keyboard came up.
    for (final reduce in [false, true]) {
      final how = reduce ? 'at once' : 'in HermesMotion.base';
      testWidgets('keyboard: the bar folds $how', (tester) async {
        final c = await _pump(
          tester,
          size: const Size(933, 704),
          reduceMotion: reduce,
        );
        c.open(ChatWorkspaceTab.files);
        await _settle(tester);
        await tester.tap(find.byKey(const ValueKey('tab-field-files')));
        await _settle(tester);
        final open = tester.getRect(find.byKey(const ValueKey('tab-files')));
        tester.view.viewInsets = const FakeViewPadding(bottom: 305);
        addTearDown(tester.view.resetViewInsets);
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(const ValueKey('chat-workspace-tabs-folded')),
          findsOneWidget,
        );
        final first = tester.getRect(find.byKey(const ValueKey('tab-files')));
        await tester.pump(HermesMotion.base);
        final folded = tester.getRect(find.byKey(const ValueKey('tab-files')));
        if (reduce) {
          expect(first, folded);
        } else {
          // The bar's room closes over the frames, not in the first one.
          expect(first.top, greaterThan(folded.top));
        }
        expect(folded.top, lessThan(open.top));
        expect(tester.takeException(), isNull);
      });
    }
  });

  // the owner, capture 1659 (open Fold, landscape, a chat beside the Chats
  // list): the Chats screen's Scaffold makes room for the keyboard and
  // tells its body of none. The panes were squeezed under it instead of
  // the one being typed in taking the width (APK 9708).
  testWidgets('inside a screen that makes room for the keyboard, the pane '
      'typed in still takes the width and its bar folds', (tester) async {
    final c = await _pump(
      tester,
      size: const Size(933, 704),
      outerScaffold: true,
    );
    c.open(ChatWorkspaceTab.terminal);
    await _settle(tester);
    final split = tester.getRect(find.byKey(const ValueKey('tab-terminal')));
    await tester.tap(find.byKey(const ValueKey('tab-field-terminal')));
    await _settle(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 305);
    addTearDown(tester.view.resetViewInsets);
    await _settle(tester);
    // The chat folded to its rail; the pane is the width, the bar folded.
    expect(find.byKey(const ValueKey('chat-workspace-rail')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('chat-workspace-tabs-folded')),
      findsOneWidget,
    );
    final wide = tester.getRect(
      find.byKey(const ValueKey('chat-workspace-body-terminal')),
    );
    expect(wide.width, greaterThan(933 * 0.8));
    // The layout the user chose is untouched.
    expect(c.mode, ChatWorkspaceMode.split);
    // The keyboard goes: the split comes back.
    tester.view.resetViewInsets();
    await _settle(tester);
    expect(find.byKey(const ValueKey('chat-workspace-rail')), findsNothing);
    expect(
      tester.getRect(find.byKey(const ValueKey('tab-terminal'))).left,
      closeTo(split.left, 0.5),
    );
    expect(tester.takeException(), isNull);
  });

  // the owner (9714, ORDEN-Q9-ORIENTACION, his clarification of point 1): with
  // the keyboard up the pane typed in grows to the width; when the keyboard
  // goes it is back where it was, both smoothly (a clean cut with reduced
  // motion), the layout and the focus kept, and TalkBack hears it once
  // each way.
  for (final reduce in [false, true]) {
    testWidgets('keyboard in Terminal: it grows and comes back, layout and '
        'focus kept (reduced motion: $reduce)', (tester) async {
      final c = await _pump(
        tester,
        size: const Size(933, 704),
        reduceMotion: reduce,
      );
      c.open(ChatWorkspaceTab.terminal);
      await _settle(tester);
      Rect body() => tester.getRect(
        find.byKey(const ValueKey('chat-workspace-body-terminal')),
      );
      Key? focused() => FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<TextField>()
          ?.key;
      final split = body();
      await tester.tap(find.byKey(const ValueKey('tab-field-terminal')));
      await _settle(tester);
      tester.takeAnnouncements();

      tester.view.viewInsets = const FakeViewPadding(bottom: 305);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      if (!reduce) {
        // No jump: the first frame draws it where it was, then it moves
        // (the motion ticks from the next frame).
        expect(body().left, closeTo(split.left, 1));
        await tester.pump();
        await tester.pump(HermesMotion.base ~/ 2);
        expect(body().left, lessThan(split.left - 1));
      }
      await tester.pump(HermesMotion.base);
      await tester.pump(HermesMotion.base);
      final grown = body();
      expect(grown.left, lessThan(split.left - 100));
      expect(grown.width, greaterThan(split.width));
      expect(c.mode, ChatWorkspaceMode.split, reason: 'the layout chosen');
      expect(focused(), const ValueKey('tab-field-terminal'));
      expect(
        [for (final a in tester.takeAnnouncements()) a.message],
        ['Terminal expanded'],
      );

      // Turning the device with the keyboard up: still the width, and no
      // second announcement.
      tester.view.physicalSize = const Size(1280, 800);
      await tester.pump();
      await tester.pump(HermesMotion.base);
      await tester.pump(HermesMotion.base);
      expect(find.byKey(const ValueKey('chat-workspace-rail')), findsOneWidget);
      expect(tester.takeAnnouncements(), isEmpty);
      tester.view.physicalSize = const Size(933, 704);
      await tester.pump();
      await tester.pump(HermesMotion.base);
      await tester.pump(HermesMotion.base);

      tester.view.resetViewInsets();
      await tester.pump();
      if (!reduce) {
        expect(body().left, closeTo(grown.left, 1), reason: 'no jump back');
        await tester.pump();
        await tester.pump(HermesMotion.base ~/ 2);
        expect(body().left, greaterThan(grown.left + 1));
      }
      await tester.pump(HermesMotion.base);
      await tester.pump(HermesMotion.base);
      expect(body(), split);
      expect(c.mode, ChatWorkspaceMode.split);
      expect(focused(), const ValueKey('tab-field-terminal'));
      expect(
        [for (final a in tester.takeAnnouncements()) a.message],
        ['Terminal restored'],
      );
      expect(tester.takeException(), isNull);
    });
  }

  // the owner (9714, ORDEN-Q9-ORIENTACION 2 and 3): turning or folding the
  // device with a panel showing closed it and left the chat. Now the
  // panel adapts: where nothing fits beside the chat it takes the screen
  // («Trabajo»), the same one, its state alive; where it fits again the
  // layout chosen comes back. Sizes change while the app runs.
  group('turned and folded, the panel stays', () {
    const wide = Size(933, 704); // the open Fold, landscape
    const upright = Size(673, 841); // the open Fold, upright
    const cover = Size(360, 780); // folded: the cover screen
    final terminal = find.byKey(const ValueKey('chat-workspace-body-terminal'));
    _FakeTabState tabState(WidgetTester tester) => tester.state<_FakeTabState>(
      find.byType(_FakeTab, skipOffstage: false).first,
    );

    Future<void> resize(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      await _settle(tester);
    }

    for (final (layout, narrow) in const [
      (ChatWorkspaceMode.split, upright),
      (ChatWorkspaceMode.split, cover),
      (ChatWorkspaceMode.workspace, upright),
      (ChatWorkspaceMode.workspace, cover),
    ]) {
      testWidgets('${layout.name} → ${narrow.width.toInt()} dp and back: '
          'Trabajo with the same panel, then ${layout.name} again', (
        tester,
      ) async {
        final c = await _pump(tester, size: wide);
        c.open(ChatWorkspaceTab.terminal);
        c.setMode(layout);
        await _settle(tester);
        await tester.tap(find.byKey(const ValueKey('tab-terminal')));
        await tester.tap(find.byKey(const ValueKey('tab-terminal')));
        await tester.pump();
        expect(find.text('terminal 2'), findsOneWidget);
        final state = tabState(tester);

        await resize(tester, narrow);
        // Not the chat alone: the panel, on the screen, the same state.
        expect(terminal, findsOneWidget);
        expect(find.text('terminal 2'), findsOneWidget);
        expect(identical(tabState(tester), state), isTrue);
        expect(find.byType(_FakeChat), findsNothing, reason: 'Trabajo');
        expect(
          tester.getRect(terminal).width,
          greaterThan(narrow.width * 0.7),
        );
        // The layout chosen is untouched.
        expect(c.mode, layout);

        await resize(tester, wide);
        expect(c.mode, layout);
        expect(find.text('terminal 2'), findsOneWidget);
        expect(identical(tabState(tester), state), isTrue);
        expect(
          find.byType(_FakeChat),
          layout == ChatWorkspaceMode.split ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('«Chat» stays the chat alone when narrow', (tester) async {
      final c = await _pump(tester, size: wide);
      c
        ..open(ChatWorkspaceTab.terminal)
        ..setMode(ChatWorkspaceMode.chat);
      await _settle(tester);
      await resize(tester, upright);
      expect(find.byType(_FakeChat), findsOneWidget);
      expect(terminal, findsNothing);
    });

    testWidgets('narrow, the rail goes to the chat, and that choice stays', (
      tester,
    ) async {
      final c = await _pump(tester, size: wide);
      c.open(ChatWorkspaceTab.files);
      await _settle(tester);
      await resize(tester, upright);
      await tester.tap(find.byKey(const ValueKey('chat-workspace-show-chat')));
      await _settle(tester);
      expect(find.byType(_FakeChat), findsOneWidget);
      expect(c.mode, ChatWorkspaceMode.chat);
      await resize(tester, wide);
      expect(c.workspaceVisible, isFalse, reason: 'the chat was chosen');
      expect(find.byType(_FakeChat), findsOneWidget);
    });

    for (final reduce in [false, true]) {
      testWidgets('turned and folded with the keyboard up: panel, focus and '
          'announcements stay (reduced motion: $reduce)', (tester) async {
        final c = await _pump(tester, size: wide, reduceMotion: reduce);
        c.open(ChatWorkspaceTab.terminal);
        await _settle(tester);
        final state = tabState(tester);
        final split = tester.getRect(terminal);
        await tester.tap(find.byKey(const ValueKey('tab-field-terminal')));
        await _settle(tester);
        tester.takeAnnouncements();
        tester.view.viewInsets = const FakeViewPadding(bottom: 305);
        addTearDown(tester.view.resetViewInsets);
        await _settle(tester);
        Key? focused() => FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<TextField>()
            ?.key;
        expect(focused(), const ValueKey('tab-field-terminal'));
        expect(
          [for (final a in tester.takeAnnouncements()) a.message],
          ['Terminal expanded'],
        );

        // REVIEW-Q9ORIENT P2-1: 933 → 673 → 360 → 933, without closing
        // the keyboard or moving focus. Width alone never restores or
        // expands the pane again, and the chosen split stays untouched.
        for (final size in [upright, cover, wide]) {
          await resize(tester, size);
          expect(terminal, findsOneWidget);
          expect(focused(), const ValueKey('tab-field-terminal'));
          expect(identical(tabState(tester), state), isTrue);
          expect(c.mode, ChatWorkspaceMode.split);
          expect(tester.view.viewInsets.bottom, 305);
          expect(find.byType(_FakeChat), findsNothing, reason: 'Trabajo');
          expect(
            tester.getRect(terminal).width,
            greaterThan(size.width * 0.7),
          );
          expect(tester.takeAnnouncements(), isEmpty);
          expect(tester.takeException(), isNull);
        }

        tester.view.resetViewInsets();
        await _settle(tester);
        expect(terminal, findsOneWidget);
        expect(focused(), const ValueKey('tab-field-terminal'));
        expect(identical(tabState(tester), state), isTrue);
        expect(c.mode, ChatWorkspaceMode.split);
        expect(tester.getRect(terminal), split);
        expect(find.byType(_FakeChat), findsOneWidget);
        expect(
          [for (final a in tester.takeAnnouncements()) a.message],
          ['Terminal restored'],
        );
        await _settle(tester);
        expect(tester.takeAnnouncements(), isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  });

  for (final reduce in [false, true]) {
    testWidgets('keyboard episode ends when narrow rail chooses Chat '
        '(reduced motion: $reduce)', (tester) async {
      const wide = Size(933, 704);
      final c = await _pump(tester, size: wide, reduceMotion: reduce);
      c.open(ChatWorkspaceTab.terminal);
      await _settle(tester);
      final chat = find.byType(_FakeChat);
      final terminal = find.byKey(
        const ValueKey('chat-workspace-body-terminal'),
      );
      final splitChat = tester.getRect(chat);
      final splitTerminal = tester.getRect(terminal);
      Key? focused() => FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<TextField>()
          ?.key;
      await tester.tap(find.byKey(const ValueKey('tab-field-terminal')));
      await _settle(tester);
      tester.takeAnnouncements();
      tester.view.viewInsets = const FakeViewPadding(bottom: 305);
      addTearDown(tester.view.resetViewInsets);
      await _settle(tester);
      expect(focused(), const ValueKey('tab-field-terminal'));
      expect(
        [for (final a in tester.takeAnnouncements()) a.message],
        ['Terminal expanded'],
      );

      tester.view.physicalSize = const Size(673, 841);
      await _settle(tester);
      expect(terminal, findsOneWidget);
      expect(focused(), const ValueKey('tab-field-terminal'));
      expect(c.mode, ChatWorkspaceMode.split);
      expect(tester.view.viewInsets.bottom, 305);
      expect(tester.takeAnnouncements(), isEmpty);

      await tester.tap(find.byKey(const ValueKey('chat-workspace-show-chat')));
      await _settle(tester);
      expect(c.mode, ChatWorkspaceMode.chat);
      expect(chat, findsOneWidget);
      expect(terminal, findsNothing);
      expect(focused(), isNot(const ValueKey('tab-field-terminal')));
      expect(tester.view.viewInsets.bottom, 305);
      expect(tester.takeAnnouncements(), isEmpty);

      tester.view.resetViewInsets();
      await _settle(tester);
      expect(tester.takeAnnouncements(), isEmpty);
      tester.view.physicalSize = wide;
      await _settle(tester);
      expect(c.mode, ChatWorkspaceMode.chat);
      expect(tester.takeAnnouncements(), isEmpty);

      c.setMode(ChatWorkspaceMode.split);
      await tester.pump();
      // Even the first frame has no old keyboard opacity on the chat.
      final opacity = find.ancestor(of: chat, matching: find.byType(Opacity));
      expect(tester.widget<Opacity>(opacity.first).opacity, 1);
      expect(tester.getRect(chat), splitChat);
      expect(tester.takeAnnouncements(), isEmpty);
      await _settle(tester);
      expect(c.mode, ChatWorkspaceMode.split);
      expect(tester.getRect(chat), splitChat);
      expect(tester.getRect(terminal), splitTerminal);
      expect(tester.takeAnnouncements(), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a narrow workspace shows inactive tabs as icons', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    // The four panels this scenario was written for: with a fifth segment
    // the active one is an icon here too (still named for screen readers).
    final c = await _pump(
      tester,
      size: const Size(933, 704),
      availableTabs: const [
        ChatWorkspaceTab.terminal,
        ChatWorkspaceTab.files,
        ChatWorkspaceTab.git,
        ChatWorkspaceTab.browser,
      ],
    );
    c
      ..open(ChatWorkspaceTab.terminal)
      ..open(ChatWorkspaceTab.files);
    await _settle(tester);
    // 378 dp of workspace (Files at 58/42) < 720: Terminal is an icon with
    // its label for screen readers; the active Files keeps its text.
    expect(find.text('Terminal'), findsNothing);
    expect(find.text('Files'), findsOneWidget);
    expect(find.bySemanticsLabel('Terminal'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a hinge fixes the split; the divider cannot be dragged', (
    tester,
  ) async {
    tester.view.displayFeatures = const [
      DisplayFeature(
        bounds: Rect.fromLTWH(630, 0, 20, 800),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.unknown,
      ),
    ];
    addTearDown(tester.view.resetDisplayFeatures);
    final c = await _pump(tester);
    c.open(ChatWorkspaceTab.terminal);
    await _settle(tester);
    expect(tester.getRect(find.byType(_FakeChat)).right, 630);
    await tester.drag(find.byKey(_divider), const Offset(150, 0));
    await _settle(tester);
    expect(tester.getRect(find.byType(_FakeChat)).right, 630);
    expect(c.storedRatio, isNull);
  });

  testWidgets('a flat fold does not fix the split', (tester) async {
    tester.view.displayFeatures = const [
      DisplayFeature(
        bounds: Rect.fromLTWH(466, 0, 0, 704),
        type: DisplayFeatureType.fold,
        state: DisplayFeatureState.postureFlat,
      ),
    ];
    addTearDown(tester.view.resetDisplayFeatures);
    final c = await _pump(tester, size: const Size(933, 704));
    c.open(ChatWorkspaceTab.terminal);
    await _settle(tester);
    expect(tester.getRect(find.byType(_FakeChat)).width, 480);
  });

  final themes = <String, ThemeData>{
    'dark': AppTheme.hermesRedDark,
    'light': AppTheme.hermesRedLight,
  };
  for (final entry in themes.entries) {
    testWidgets('${entry.key} theme: the bar\'s pills and the panes use the '
        'tokens', (tester) async {
      final colors = entry.value.hermes;
      final c = await _pump(tester, theme: entry.value);
      c.open(ChatWorkspaceTab.terminal);
      await _settle(tester);
      // Mock 136 v2-A: the selector and the actions are pills on the
      // sunken tone, not a bar in the page's inverse.
      Color? fillOf(Finder finder) {
        final box = tester.widget<DecoratedBox>(finder);
        return (box.decoration as ShapeDecoration).color;
      }

      expect(fillOf(find.byKey(_bar)), colors.surfaceVariant);
      expect(
        fillOf(
          find
              .descendant(
                of: find.byKey(const ValueKey('chat-workspace-tabs')),
                matching: find.byType(DecoratedBox),
              )
              .first,
        ),
        colors.surfaceVariant,
      );
      final panes = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((b) => b.decoration)
          .whereType<BoxDecoration>()
          .where(
            (d) =>
                d.borderRadius ==
                BorderRadius.circular(chatWorkspacePaneRadius),
          )
          .map((d) => d.color)
          .toSet();
      expect(panes, {colors.surface});
      // Ola 1 (mock 136 v2-A `.pane`): a hairline edge on every pane, which
      // shows where the shadow alone does not (a dark page).
      final edges = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((b) => b.decoration)
          .whereType<BoxDecoration>()
          .where(
            (d) =>
                d.borderRadius ==
                BorderRadius.circular(chatWorkspacePaneRadius),
          )
          .map((d) => (d.border as Border?)?.top.color)
          .toSet();
      expect(edges, {HermesChrome.of(colors).line});
    });

    testWidgets('${entry.key} theme, Fold at 2x text: no overflow', (
      tester,
    ) async {
      final c = await _pump(
        tester,
        size: const Size(933, 704),
        theme: entry.value,
        textScale: 2,
      );
      c
        ..open(ChatWorkspaceTab.terminal)
        ..open(ChatWorkspaceTab.files);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      c.setMode(ChatWorkspaceMode.workspace);
      await _settle(tester);
      expect(tester.takeException(), isNull);
    });
  }

  // Review P1-F4-2: system Back goes to the active tab first.
  testWidgets('Back pops inside the tab before leaving the chat', (
    tester,
  ) async {
    final c = await _pump(tester);
    c.open(ChatWorkspaceTab.terminal);
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('tab-push-terminal')));
    await _settle(tester);
    expect(find.text('inner terminal'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.text('inner terminal'), findsNothing);
    expect(find.byKey(const ValueKey('tab-terminal')), findsOneWidget);
    expect(find.byKey(_divider), findsOneWidget);
    expect(c.tabs, [ChatWorkspaceTab.terminal]);
  });

  // Review P1-F4-2: a tab whose first screen leaves closes, no empty pane.
  testWidgets('a tab whose first screen leaves is closed', (tester) async {
    final c = await _pump(tester);
    c
      ..open(ChatWorkspaceTab.terminal)
      ..open(ChatWorkspaceTab.files);
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('tab-leave-files')));
    await _settle(tester);
    expect(c.tabs, [ChatWorkspaceTab.terminal]);
    expect(c.active, ChatWorkspaceTab.terminal);
    expect(find.byKey(const ValueKey('tab-terminal')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tab-leave-terminal')));
    await _settle(tester);
    expect(c.hasWorkspace, isFalse);
    expect(find.byKey(_divider), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // Review P2-F4-5: screens can tell they are in the pane.
  testWidgets('tab content knows it is inside the pane', (tester) async {
    final c = await _pump(tester);
    c.open(ChatWorkspaceTab.files);
    await _settle(tester);
    expect(find.text('in pane'), findsOneWidget);
  });

  // the owner, Fold horizontal (APK 9708): with the keyboard up the pane that
  // does not have the focus folds to a thin rail and the one that has it
  // takes the whole width (Fold 2 did it by hand for the Terminal only).
  group('keyboard: the pane without the focus folds', () {
    Future<void> keyboard(WidgetTester tester, double dp) async {
      tester.view.viewInsets = FakeViewPadding(bottom: dp);
      addTearDown(tester.view.resetViewInsets);
      await _settle(tester);
    }

    for (final tab in ChatWorkspaceTab.values) {
      testWidgets('${tab.name}: typing in the panel folds the chat', (
        tester,
      ) async {
        final c = await _pump(tester, size: const Size(933, 704));
        await tester.enterText(find.byKey(_chatField), 'keep me');
        c.open(tab);
        await _settle(tester);
        await tester.tap(find.byKey(ValueKey('tab-field-${tab.name}')));
        await _settle(tester);
        await keyboard(tester, 305);
        expect(find.byKey(_rail), findsOneWidget);
        expect(find.byKey(_divider), findsNothing);
        // 933 - 2 * 10 - 56 - 14 dp.
        expect(
          tester
              .getRect(find.byKey(ValueKey('chat-workspace-body-${tab.name}')))
              .width,
          closeTo(843, 1),
        );
        // Only the layout: the views the user chose are as they were.
        expect(c.mode, ChatWorkspaceMode.split);
        expect(tester.takeException(), isNull);

        tester.view.resetViewInsets();
        await _settle(tester);
        expect(find.byKey(_divider), findsOneWidget);
        expect(find.byKey(_rail), findsNothing);
        expect(find.text('keep me'), findsOneWidget);
      });
    }

    testWidgets('typing in the chat folds the panel; both keep their state', (
      tester,
    ) async {
      final c = await _pump(tester, size: const Size(933, 704));
      c.open(ChatWorkspaceTab.terminal);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('tab-terminal')));
      await _settle(tester);
      await tester.enterText(find.byKey(_chatField), 'draft');
      await _settle(tester);
      await keyboard(tester, 305);
      const paneRail = ValueKey('chat-workspace-pane-rail');
      expect(find.byKey(paneRail), findsOneWidget);
      expect(find.byKey(_divider), findsNothing);
      expect(tester.getRect(find.byKey(paneRail)).width, 56);
      expect(tester.getRect(find.byType(_FakeChat)).width, closeTo(843, 1));
      // The panel is folded, not dropped: its state waits off screen.
      expect(find.text('terminal 1', skipOffstage: false), findsOneWidget);

      tester.view.resetViewInsets();
      await _settle(tester);
      expect(find.byKey(paneRail), findsNothing);
      expect(find.text('terminal 1'), findsOneWidget);
      expect(find.text('draft'), findsOneWidget);
      expect(tester.getRect(find.byType(_FakeChat)).width, 480);
    });

    testWidgets('the rail closes the keyboard and the split comes back', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final c = await _pump(tester, size: const Size(933, 704));
      c.open(ChatWorkspaceTab.files);
      await _settle(tester);
      await tester.tap(find.byKey(_chatField));
      await _settle(tester);
      await keyboard(tester, 305);
      const show = ValueKey('chat-workspace-show-pane');
      expect(find.bySemanticsLabel('Open the workspace'), findsOneWidget);
      expect(tester.getSize(find.byKey(show)).height, greaterThanOrEqualTo(48));
      await tester.tap(find.byKey(show));
      await _settle(tester);
      // The keyboard went with the focus.
      expect(tester.testTextInput.isVisible, isFalse);
      expect(find.byKey(_divider), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a keyboard with the focus elsewhere changes nothing', (
      tester,
    ) async {
      final c = await _pump(tester, size: const Size(933, 704));
      c.open(ChatWorkspaceTab.files);
      await _settle(tester);
      await keyboard(tester, 305);
      expect(find.byKey(_divider), findsOneWidget);
      expect(find.byKey(_rail), findsNothing);
      expect(
        find.byKey(const ValueKey('chat-workspace-pane-rail')),
        findsNothing,
      );
    });
  });

  // Mock 136 v2-A on a narrow screen: a panel is a bottom sheet over the
  // dimmed chat, with the same rounded frame as Dividido (QA 9715).
  testWidgets('a narrow screen opens a panel as a bottom sheet', (
    tester,
  ) async {
    Color? sheetBackground;
    _size(tester, const Size(412, 915));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open-sheet'),
              onPressed: () => showChatWorkspaceSheet<void>(
                context,
                builder: (sheetContext) {
                  sheetBackground = ChatWorkspacePaneScope.backgroundOf(
                    sheetContext,
                    Colors.red,
                  );
                  return const Scaffold(body: Text('panel body'));
                },
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-sheet')));
    await _settle(tester);
    expect(find.text('panel body'), findsOneWidget);
    // Ola 1 (T1): the screen in the sheet shows the sheet's surface, not a
    // page grey of its own; the veil is the design system's sheet scrim.
    expect(sheetBackground, Colors.transparent);
    expect(
      tester.widgetList<ModalBarrier>(find.byType(ModalBarrier)).last.color,
      HermesScrim.sheet.color,
    );
    final sheet = find.byKey(const ValueKey('chat-workspace-sheet'));
    final rect = tester.getRect(sheet);
    expect(rect.bottom, 915 - ChatWorkspaceGeometry.padding);
    expect(rect.width, 412 - 2 * ChatWorkspaceGeometry.padding);
    // Most of the height, the chat still showing above it.
    expect(rect.top, greaterThan(915 * 0.05));
    expect(rect.height, greaterThan(915 * 0.85));
    expect(
      tester.widget<ClipRRect>(sheet).borderRadius,
      BorderRadius.circular(chatWorkspacePaneRadius),
    );
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.text('panel body'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  group('v25 fidelity (ORDEN-WS-FIDELIDAD)', () {
    // Point 1: the four tabs that exist as screens, from the selector (mock
    // 136 v2-A), Git with its count of changed files, read by TalkBack.
    testWidgets('tabs: Terminal, Files, Git and Browser; Git counts', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final c = await _pump(
        tester,
        size: const Size(933, 704),
        tabBadge: (tab) => tab == ChatWorkspaceTab.git ? 4 : null,
      );
      c.open(ChatWorkspaceTab.terminal);
      await _settle(tester);
      for (final tab in const [
        ChatWorkspaceTab.files,
        ChatWorkspaceTab.git,
        ChatWorkspaceTab.browser,
        ChatWorkspaceTab.agents,
      ]) {
        await tester.tap(
          find.byKey(ValueKey('chat-workspace-tab-${tab.name}')),
        );
        await _settle(tester);
        expect(c.active, tab);
        expect(find.text('${tab.name} 0'), findsOneWidget);
      }
      expect(c.tabs, ChatWorkspaceTab.values);
      // «Chat» first, then v25's order, left to right.
      expect(
        tester
            .getRect(find.byKey(const ValueKey('chat-workspace-collapse')))
            .left,
        lessThan(
          tester
              .getRect(
                find.byKey(const ValueKey('chat-workspace-tab-terminal')),
              )
              .left,
        ),
      );
      final lefts = [
        for (final tab in ChatWorkspaceTab.values)
          tester
              .getRect(find.byKey(ValueKey('chat-workspace-tab-${tab.name}')))
              .left,
      ];
      expect(lefts, [...lefts]..sort());
      final badge = find.byKey(const ValueKey('chat-workspace-tab-badge-git'));
      expect(
        find.descendant(of: badge, matching: find.text('4')),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(
          find.byKey(const ValueKey('chat-workspace-tab-git')),
        ),
        isSemantics(
          // The tab is «Cambios» / «Changes» (the Git hub).
          label: 'Changes',
          value: '4 changed',
          isButton: true,
          isSelected: false,
          hasSelectedState: true,
        ),
      );
      semantics.dispose();
    });

    // Point 3, mock 136 v2-A: one bar, the selector then the pill of
    // actions, with what the active tab adds.
    testWidgets('pane bar: order, keys, Herdr dot and the tab menu', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final c = await _pump(
        tester,
        tabBuilder: (_, tab) => tab == ChatWorkspaceTab.terminal
            ? const _ToolbarTab(needsYou: 2)
            : _FakeTab(tab),
      );
      c.open(ChatWorkspaceTab.terminal);
      await _settle(tester);
      await _settle(tester);

      const order = [
        'chat-workspace-collapse',
        'chat-workspace-tab-terminal',
        'chat-workspace-keys',
        'chat-workspace-herdr',
        'chat-workspace-expand',
        'chat-workspace-layout-menu',
      ];
      final rects = [
        for (final key in order) tester.getRect(find.byKey(ValueKey(key))),
      ];
      for (var i = 1; i < rects.length; i++) {
        expect(
          rects[i].left,
          greaterThan(rects[i - 1].left),
          reason: order[i],
        );
        // One row.
        expect(
          (rects[i].center.dy - rects[0].center.dy).abs(),
          lessThan(1),
          reason: order[i],
        );
      }
      for (final rect in rects) {
        expect(rect.height, greaterThanOrEqualTo(48));
      }
      expect(
        find.byKey(const ValueKey('chat-workspace-herdr-attention')),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey('chat-workspace-keys'))),
        isSemantics(
          tooltip: 'Keyboard',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey('chat-workspace-herdr'))),
        isSemantics(tooltip: 'Agents that need you: 2', isButton: true),
      );

      await tester.tap(find.byKey(const ValueKey('chat-workspace-keys')));
      await _settle(tester);
      expect(find.text('keys false herdr 0 menu 0'), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('chat-workspace-keys'))),
        isSemantics(
          tooltip: 'Keyboard',
          isSelected: false,
          hasSelectedState: true,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('chat-workspace-herdr')));
      await _settle(tester);
      expect(find.text('keys false herdr 1 menu 0'), findsOneWidget);

      // «⋯»: the three layouts, then what the tab adds.
      await tester.tap(
        find.byKey(const ValueKey('chat-workspace-layout-menu')),
      );
      await _settle(tester);
      expect(find.text('Split'), findsOneWidget);
      // Closing the tab is in «⋯» now (no × on the tabs, no bar).
      expect(find.text('Close tab'), findsOneWidget);
      expect(
        tester.getRect(find.text('Tab action')).top,
        greaterThan(tester.getRect(find.text('Workspace only')).top),
      );
      await tester.tap(find.text('Tab action'));
      await _settle(tester);
      expect(find.text('keys false herdr 1 menu 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });

    testWidgets('a tab without tools gets no keys or Herdr button', (
      tester,
    ) async {
      final c = await _pump(tester);
      c.open(ChatWorkspaceTab.files);
      await _settle(tester);
      expect(find.byKey(const ValueKey('chat-workspace-keys')), findsNothing);
      expect(find.byKey(const ValueKey('chat-workspace-herdr')), findsNothing);
      expect(
        find.byKey(const ValueKey('chat-workspace-layout-menu')),
        findsOneWidget,
      );
    });

    // Point 8: the frame stays inside the safe area (the bar no longer
    // covers the status bar's battery).
    testWidgets('the panes and the bar stay below the status bar', (
      tester,
    ) async {
      tester.view.padding = const FakeViewPadding(top: 40, bottom: 24);
      addTearDown(tester.view.resetPadding);
      final c = await _pump(tester, size: const Size(933, 704));
      c.open(ChatWorkspaceTab.files);
      await _settle(tester);
      const pad = ChatWorkspaceGeometry.padding;
      final chat = tester.getRect(find.byType(_FakeChat));
      expect(chat.top, 40 + pad);
      expect(chat.bottom, 704 - 24 - pad);
      expect(
        tester
            .getRect(find.byKey(const ValueKey('chat-workspace-collapse')))
            .top,
        greaterThanOrEqualTo(40 + pad),
      );
      // Inside the pane the system insets are already accounted for.
      expect(
        MediaQuery.paddingOf(tester.element(find.text('files 0'))),
        EdgeInsets.zero,
      );
    });

    // Point 4 (the owner: tablet only): the app's side navigation left of the
    // chat from 1100 dp, never on the open Fold.
    testWidgets('side navigation on a tablet, not on the open Fold', (
      tester,
    ) async {
      expect(kChatWorkspaceNavigationMinWidth, 1100);
      const nav = ValueKey('fake-navigation');
      final c = await _pump(
        tester,
        navigation: const ColoredBox(key: nav, color: Colors.red),
      );
      c.open(ChatWorkspaceTab.terminal);
      await _settle(tester);
      expect(
        tester.getRect(find.byKey(nav)),
        const Rect.fromLTWH(0, 0, 84, 800),
      );
      final chat = tester.getRect(find.byType(_FakeChat));
      expect(chat.left, 84 + ChatWorkspaceGeometry.padding);
      // The chat itself is not touched: only where it starts.
      expect(find.byKey(_chatField), findsOneWidget);

      _size(tester, const Size(933, 704));
      await _settle(tester);
      expect(find.byKey(nav), findsNothing);
      expect(
        tester.getRect(find.byType(_FakeChat)).left,
        ChatWorkspaceGeometry.padding,
      );
    });

    testWidgets('no navigation while the chat has the screen to itself', (
      tester,
    ) async {
      const nav = ValueKey('fake-navigation');
      final c = await _pump(
        tester,
        navigation: const ColoredBox(key: nav, color: Colors.red),
      );
      expect(find.byKey(nav), findsNothing);
      c.open(ChatWorkspaceTab.terminal);
      await _settle(tester);
      expect(find.byKey(nav), findsOneWidget);
      c.setMode(ChatWorkspaceMode.chat);
      await _settle(tester);
      expect(find.byKey(nav), findsNothing);
    });

    for (final entry in {
      'dark': AppTheme.hermesRedDark,
      'light': AppTheme.hermesRedLight,
    }.entries) {
      // Mock 136 v2-A: the pills on the sunken tone; the panel in use in
      // the accent's tint and named.
      testWidgets('${entry.key}: the active panel reads on its pill', (
        tester,
      ) async {
        final colors = entry.value.hermes;
        final c = await _pump(tester, theme: entry.value);
        c.open(ChatWorkspaceTab.files);
        await _settle(tester);
        final active = tester.widget<DecoratedBox>(
          find.byKey(const ValueKey('chat-workspace-segment-active')),
        );
        final fill = (active.decoration as ShapeDecoration).color!;
        expect(fill, colors.accent.withValues(alpha: 0.18));
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('chat-workspace-tab-files')),
            matching: find.byKey(
              const ValueKey('chat-workspace-segment-active'),
            ),
          ),
          findsOneWidget,
        );
        final icon = tester.widget<IconButton>(
          find.byKey(const ValueKey('chat-workspace-expand')),
        );
        expect(icon.color, colors.textSecondary);
        // The icons read on the pill: at least 3:1, as for non-text.
        double luminance(Color c) => c.computeLuminance();
        final pill = colors.surfaceVariant;
        final hi = math.max(luminance(pill), luminance(colors.textSecondary));
        final lo = math.min(luminance(pill), luminance(colors.textSecondary));
        expect((hi + 0.05) / (lo + 0.05), greaterThanOrEqualTo(3));
      });
    }
  });

  // the owner's final windows (ventanas-final-png): no handles at the screen's
  // edges; the chat's round «Vistas» opens a vertical menu of circles with
  // their names, «Chat · Dividido · Trabajo», the one in use in the accent.
  // ONLY the layout: the panels are in Ajustes.
  group('views (final windows)', () {
    const views = ValueKey('test-views');
    const listHandle = ValueKey('chat-workspace-handle-list');
    const workHandle = ValueKey('chat-workspace-handle-workspace');
    const menu = ValueKey('chat-workspace-views');
    Finder row(ChatWorkspaceMode mode) =>
        find.byKey(ValueKey('chat-views-layout-${mode.name}'));

    /// The fake chat with the chat's «Vistas» at its top end.
    Widget Function(ChatWorkspaceController) chatWithViews(
      List<ChatWorkspaceTab> tabs,
    ) => (c) => Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          const Positioned.fill(child: _FakeChat()),
          PositionedDirectional(
            top: 8,
            end: 8,
            child: ChatViewsButton(
              key: views,
              controller: c,
              availableTabs: tabs,
            ),
          ),
        ],
      ),
    );

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byKey(views));
      await _settle(tester);
      expect(find.byKey(menu), findsOneWidget);
    }

    for (final size in const [Size(933, 704), Size(1280, 800)]) {
      for (final theme in {
        'dark': AppTheme.hermesRedDark,
        'light': AppTheme.hermesRedLight,
      }.entries) {
        final name = '${size.width.toInt()} ${theme.key}';
        testWidgets('$name: no handle at the edges; «Vistas» is the layout '
            'menu: Chat · Dividido · Trabajo, the one in use marked', (
          tester,
        ) async {
          final semantics = tester.ensureSemantics();
          final c = ChatWorkspaceController(screen: ChatWorkspaceScreen.chats)
            ..windowWidth = size.width;
          const tabs = [ChatWorkspaceTab.terminal, ChatWorkspaceTab.files];
          await _pump(
            tester,
            size: size,
            controller: c,
            theme: theme.value,
            availableTabs: tabs,
            chat: chatWithViews(tabs),
          );
          expect(find.byKey(listHandle), findsNothing);
          expect(find.byKey(workHandle), findsNothing);
          final button = tester.getRect(find.byKey(views));
          expect(button.width, greaterThanOrEqualTo(48));
          expect(button.height, greaterThanOrEqualTo(48));
          expect(
            tester.getSemantics(
              find.descendant(
                of: find.byKey(views),
                matching: find.byType(IconButton),
              ),
            ),
            isSemantics(isButton: true, hasTapAction: true),
          );

          await openMenu(tester);
          // Only the layout: no panels, no list, no switch.
          expect(
            find.byKey(const ValueKey('chat-workspace-view-tab-terminal')),
            findsNothing,
          );
          expect(find.byType(Switch), findsNothing);
          final names = {
            ChatWorkspaceMode.chat: 'Chat',
            ChatWorkspaceMode.split: 'Split',
            ChatWorkspaceMode.workspace: 'Work',
          };
          double? top;
          for (final MapEntry(key: mode, value: label) in names.entries) {
            final rect = tester.getRect(row(mode));
            expect(rect.height, greaterThanOrEqualTo(48), reason: label);
            if (top != null) {
              expect(rect.top, greaterThan(top), reason: 'vertical');
            }
            top = rect.top;
            expect(
              tester.getSemantics(row(mode)),
              isSemantics(
                label: label,
                isButton: true,
                hasTapAction: true,
                isSelected: mode == ChatWorkspaceMode.chat,
              ),
            );
            final circle = tester.getRect(
              find.descendant(
                of: row(mode),
                matching: find.byKey(
                  const ValueKey('chat-views-layout-circle'),
                ),
              ),
            );
            expect(circle.size, const Size.square(40), reason: label);
          }

          // «Dividido» opens the last panel used (Terminal the first time)
          // beside the chat, and the menu goes.
          tester.semantics.tap(find.semantics.byLabel(RegExp(r'^Split$')));
          await _settle(tester);
          expect(find.byKey(menu), findsNothing);
          expect(c.workspaceVisible, isTrue);
          expect(c.mode, ChatWorkspaceMode.split);
          expect(c.active, ChatWorkspaceTab.terminal);
          // The button says a panel is beside the chat.
          expect(
            find.descendant(
              of: find.byKey(views),
              matching: find.byIcon(Icons.view_sidebar),
            ),
            findsOneWidget,
          );
          await openMenu(tester);
          expect(
            tester.getSemantics(row(ChatWorkspaceMode.split)),
            isSemantics(isSelected: true),
          );
          // «Chat» closes the panel.
          await tester.tap(row(ChatWorkspaceMode.chat));
          await _settle(tester);
          expect(c.workspaceVisible, isFalse);
          expect(c.chatVisible, isTrue);
          expect(tester.takeException(), isNull);
          semantics.dispose();
        });
      }
    }

    testWidgets('a phone: only «Chat»; «Dividido» and «Trabajo» are '
        'dimmed, with the line that says why', (tester) async {
      final semantics = tester.ensureSemantics();
      final c = ChatWorkspaceController(screen: ChatWorkspaceScreen.chats)
        ..windowWidth = 412;
      const tabs = [ChatWorkspaceTab.terminal, ChatWorkspaceTab.files];
      await _pump(
        tester,
        size: const Size(412, 915),
        controller: c,
        availableTabs: tabs,
        chat: chatWithViews(tabs),
      );
      expect(find.byKey(listHandle), findsNothing);
      expect(find.byKey(workHandle), findsNothing);
      await openMenu(tester);
      expect(find.textContaining('Upright, the chat takes'), findsOneWidget);
      for (final mode in [
        ChatWorkspaceMode.split,
        ChatWorkspaceMode.workspace,
      ]) {
        expect(
          tester.getSemantics(row(mode)),
          isSemantics(hasEnabledState: true, isEnabled: false),
          reason: mode.name,
        );
      }
      await tester.tap(row(ChatWorkspaceMode.split));
      await _settle(tester);
      expect(c.workspaceVisible, isFalse);
      expect(
        tester.getSemantics(row(ChatWorkspaceMode.chat)),
        isSemantics(isSelected: true, isEnabled: true),
      );
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });

    testWidgets('no panel this chat can open: «Dividido» and «Trabajo» are '
        'dimmed, with one line', (tester) async {
      final c = await _pump(
        tester,
        size: const Size(933, 704),
        availableTabs: const [],
        chat: chatWithViews(const []),
      );
      await openMenu(tester);
      expect(find.text('Open a panel to split the screen.'), findsOneWidget);
      await tester.tap(row(ChatWorkspaceMode.workspace));
      await _settle(tester);
      expect(c.workspaceVisible, isFalse);
    });

    Future<void> openViews(WidgetTester tester) async {
      await tester.tap(
        find.byKey(const ValueKey('chat-workspace-views-button')),
      );
      await _settle(tester);
      expect(find.byKey(menu), findsOneWidget);
    }

    testWidgets('«Workspace only»: «Vistas» on the bar; «Trabajo» is '
        'marked and «Dividido» brings the chat back', (tester) async {
      final semantics = tester.ensureSemantics();
      final c = await _pump(
        tester,
        size: const Size(933, 704),
        availableTabs: const [ChatWorkspaceTab.files, ChatWorkspaceTab.browser],
      );
      c.open(ChatWorkspaceTab.files);
      await _settle(tester);
      // Split: the chat's own header has «Vistas»; not the bar.
      expect(
        find.byKey(const ValueKey('chat-workspace-views-button')),
        findsNothing,
      );
      c.setMode(ChatWorkspaceMode.workspace);
      await _settle(tester);
      expect(
        tester.getSemantics(
          find.byKey(const ValueKey('chat-workspace-views-button')),
        ),
        isSemantics(tooltip: 'Views: Workspace', isButton: true),
      );
      await openViews(tester);
      expect(
        tester.getSemantics(row(ChatWorkspaceMode.workspace)),
        isSemantics(isSelected: true),
      );
      await tester.tap(row(ChatWorkspaceMode.split));
      await _settle(tester);
      expect(c.chatVisible, isTrue);
      expect(c.mode, ChatWorkspaceMode.split);
      expect(c.active, ChatWorkspaceTab.files, reason: 'the same panel');
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });

    testWidgets('the Chats screen: the two-views rule is said; «Chat» '
        'brings the chat back', (tester) async {
      final c = ChatWorkspaceController(screen: ChatWorkspaceScreen.chats)
        ..windowWidth = 933;
      await _pump(tester, size: const Size(933, 704), controller: c);
      c
        ..open(ChatWorkspaceTab.terminal)
        ..setMode(ChatWorkspaceMode.workspace);
      await _settle(tester);
      await openViews(tester);
      expect(
        find.textContaining('This screen fits two views at a time'),
        findsOneWidget,
      );
      await tester.tap(row(ChatWorkspaceMode.chat));
      await _settle(tester);
      expect(c.workspaceVisible, isFalse);
      expect(c.chatVisible, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the menu at 200 % text fits the open Fold', (tester) async {
      final c = await _pump(tester, size: const Size(933, 704), textScale: 2);
      c
        ..open(ChatWorkspaceTab.terminal)
        ..setMode(ChatWorkspaceMode.workspace);
      await _settle(tester);
      await openViews(tester);
      expect(tester.takeException(), isNull);
      final popover = tester.getRect(find.byKey(menu));
      expect(popover.bottom, lessThanOrEqualTo(704));
      expect(popover.right, lessThanOrEqualTo(933));
    });

    // Modal surfaces (menus included) are opaque since glass-tune: the
    // window has depth from its shadow, and nothing blurs what is under it,
    // with or without reduced motion.
    for (final reduce in [false, true]) {
      testWidgets('the menu is one opaque window, no blur (reduced motion: '
          '$reduce)', (tester) async {
        const tabs = [ChatWorkspaceTab.terminal];
        await _pump(
          tester,
          size: const Size(933, 704),
          availableTabs: tabs,
          reduceMotion: reduce,
          chat: chatWithViews(tabs),
        );
        expect(tester.layers.whereType<BackdropFilterLayer>(), isEmpty);
        await openMenu(tester);
        expect(find.byKey(menu), findsOneWidget);
        expect(tester.layers.whereType<BackdropFilterLayer>(), isEmpty);
      });
    }

    for (final scale in const [1.0, 1.3, 2.0]) {
      testWidgets('right to left, text ${scale}x: the menu mirrors and '
          'fits', (tester) async {
        const tabs = ChatWorkspaceTab.values;
        await _pump(
          tester,
          size: const Size(773, 900),
          textScale: scale,
          availableTabs: tabs,
          textDirection: TextDirection.rtl,
          chat: chatWithViews(tabs),
        );
        // At the chat's top end: the left in right-to-left.
        expect(tester.getRect(find.byKey(views)).left, lessThan(100));
        await openMenu(tester);
        expect(tester.takeException(), isNull);
        for (final mode in ChatWorkspaceMode.values) {
          final circle = tester.getRect(
            find.descendant(
              of: row(mode),
              matching: find.byKey(const ValueKey('chat-views-layout-circle')),
            ),
          );
          // The circle leads: on the right in right-to-left.
          expect(
            circle.center.dx,
            greaterThan(tester.getRect(row(mode)).center.dx),
          );
          expect(tester.getRect(row(mode)).height, greaterThanOrEqualTo(48));
        }
        final popover = tester.getRect(find.byKey(menu));
        expect(popover.bottom, lessThanOrEqualTo(900));
        expect(popover.left, greaterThanOrEqualTo(0));
      });
    }

    // Ola 8 (T2-E): the count pill was a fixed 18 dp around 11 dp text, so
    // at 200 % the figure was cut. 18 is now its least height.
    testWidgets('the Git count grows with 200 % text', (tester) async {
      final c = await _pump(
        tester,
        size: const Size(933, 704),
        textScale: 2,
        tabBadge: (tab) => tab == ChatWorkspaceTab.git ? 4 : null,
      );
      c.open(ChatWorkspaceTab.terminal);
      await _settle(tester);
      final badge = find.byKey(const ValueKey('chat-workspace-tab-badge-git'));
      final figure = find.descendant(of: badge, matching: find.text('4'));
      // 11 dp at 2× is at least 22 tall, which the fixed 18 cut.
      expect(tester.getSize(badge).height, greaterThanOrEqualTo(22));
      // gint55: the figure keeps the theme's line height too (31 dp at 2×);
      // the pill is as tall as its figure, not a bar the row's height.
      expect(
        tester.getSize(badge).height,
        closeTo(tester.getSize(figure).height, 0.5),
      );
      expect(tester.takeException(), isNull);
    });
  });

  // The owner (7 Nov): on a phone or the folded cover screen the panel is the
  // whole screen, with no side rail (it looked like a stray bar); the rail is
  // for landscape, an open Fold and a tablet, where the chat can fold beside
  // the panel. The layout follows the size at every change, and nothing is
  // lost across it: tab, its state, the chat's draft.
  group('the rail only where there is room, and live', () {
    const compact = [
      Size(360, 780), // the folded cover screen
      Size(390, 844),
      Size(412, 915),
      Size(454, 717), // the cover screen, wider
      Size(599, 800), // the edge
    ];
    const roomy = [
      Size(600, 800), // the edge
      Size(657, 870), // the open Fold, upright
      Size(720, 780),
      Size(844, 390), // a phone in landscape
      Size(933, 704), // the open Fold
      Size(1280, 800), // a tablet
    ];

    for (final size in compact) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()}: the panel is '
          'the whole screen, no rail', (tester) async {
        final c = await _pump(tester, size: size);
        c
          ..open(ChatWorkspaceTab.terminal)
          ..setMode(ChatWorkspaceMode.workspace);
        await _settle(tester);
        expect(find.byKey(_rail), findsNothing);
        final body = tester.getRect(
          find.byKey(const ValueKey('chat-workspace-body-terminal')),
        );
        expect(body.width, greaterThan(size.width * .8));
        // The way back is the bar's own chat segment.
        expect(
          find.byKey(const ValueKey('chat-workspace-collapse')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }

    for (final size in roomy) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()}: the chat '
          'folds into the rail beside the panel', (tester) async {
        final c = await _pump(tester, size: size);
        c
          ..open(ChatWorkspaceTab.terminal)
          ..setMode(ChatWorkspaceMode.workspace);
        await _settle(tester);
        expect(find.byKey(_rail), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('390x844 → 844x390 → 390x844: the rail comes and goes, '
        'the panel and the draft stay', (tester) async {
      final c = await _pump(tester, size: const Size(390, 844));
      await tester.enterText(find.byKey(_chatField), 'keep me');
      c
        ..open(ChatWorkspaceTab.terminal)
        ..setMode(ChatWorkspaceMode.workspace);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('tab-terminal')));
      await tester.tap(find.byKey(const ValueKey('tab-terminal')));
      await tester.pump();
      expect(find.text('terminal 2'), findsOneWidget);
      final state = tester.state<_FakeTabState>(
        find.byType(_FakeTab, skipOffstage: false).first,
      );
      expect(find.byKey(_rail), findsNothing);

      tester.view.physicalSize = const Size(844, 390);
      await _settle(tester);
      expect(find.byKey(_rail), findsOneWidget, reason: 'landscape has room');
      expect(find.text('terminal 2'), findsOneWidget);
      expect(
        identical(
          tester.state<_FakeTabState>(
            find.byType(_FakeTab, skipOffstage: false).first,
          ),
          state,
        ),
        isTrue,
      );

      tester.view.physicalSize = const Size(390, 844);
      await _settle(tester);
      expect(find.byKey(_rail), findsNothing);
      expect(find.text('terminal 2'), findsOneWidget);
      expect(c.active, ChatWorkspaceTab.terminal);
      expect(
        identical(
          tester.state<_FakeTabState>(
            find.byType(_FakeTab, skipOffstage: false).first,
          ),
          state,
        ),
        isTrue,
      );

      // Back to the chat from the bar: the draft is still there.
      await tester.tap(find.byKey(const ValueKey('chat-workspace-collapse')));
      await _settle(tester);
      expect(find.text('keep me'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('360x780 → 720x780 → 360x780: unfolding brings the rail, '
        'folding takes it away, the state stays', (tester) async {
      final c = await _pump(tester, size: const Size(360, 780));
      await tester.enterText(find.byKey(_chatField), 'borrador');
      c
        ..open(ChatWorkspaceTab.files)
        ..setMode(ChatWorkspaceMode.workspace);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('tab-files')));
      await tester.pump();
      expect(find.text('files 1'), findsOneWidget);
      expect(find.byKey(_rail), findsNothing);

      tester.view.physicalSize = const Size(720, 780);
      await _settle(tester);
      expect(find.byKey(_rail), findsOneWidget);
      expect(find.text('files 1'), findsOneWidget);
      expect(c.active, ChatWorkspaceTab.files);

      tester.view.physicalSize = const Size(360, 780);
      await _settle(tester);
      expect(find.byKey(_rail), findsNothing);
      expect(find.text('files 1'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('chat-workspace-collapse')));
      await _settle(tester);
      expect(find.text('borrador'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
