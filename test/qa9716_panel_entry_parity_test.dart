import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/design_shots.dart' show loadDesignFonts;

const _frame = ValueKey('chat-workspace-panel-frame');
const _clip = ValueKey('chat-workspace-panel-clip');
const _bar = ValueKey('chat-workspace-actions');
const _wide = Size(933, 704);

class _Panel extends StatefulWidget {
  const _Panel(this.tab);
  final ChatWorkspaceTab tab;

  @override
  State<_Panel> createState() => _PanelState();
}

class _PanelState extends State<_Panel> {
  final input = TextEditingController();
  final focus = FocusNode();
  final session = Object();
  bool keys = true;
  int herdr = 0;

  @override
  void dispose() {
    input.dispose();
    focus.dispose();
    super.dispose();
  }

  void _push() => Navigator.of(
    context,
  ).push<void>(MaterialPageRoute<void>(builder: (_) => const _Child()));

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ChatWorkspacePaneScope.publish(
        context,
        ChatWorkspaceToolbar(
          keysShown: keys,
          onToggleKeys: () => setState(() => keys = !keys),
          onHerdr: () => setState(() => herdr++),
          menu: [
            ChatWorkspaceMenuEntry(
              key: const ValueKey('qa9716-child-action'),
              label: 'Child route',
              icon: Icons.settings_outlined,
              onSelected: _push,
            ),
          ],
        ),
      );
    });
    return Scaffold(
      key: ValueKey('qa9716-panel-${widget.tab.name}'),
      body: SingleChildScrollView(
        child: Column(
          children: [
            Text('${widget.tab.name} keys=$keys herdr=$herdr'),
            TextField(
              key: ValueKey('qa9716-input-${widget.tab.name}'),
              controller: input,
              focusNode: focus,
            ),
            TextButton(
              key: ValueKey('qa9716-push-${widget.tab.name}'),
              onPressed: _push,
              child: const Text('Child route'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Child extends StatefulWidget {
  const _Child();
  @override
  State<_Child> createState() => _ChildState();
}

class _ChildState extends State<_Child> {
  bool blocked = true;
  int vetoes = 0;
  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: !blocked,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && blocked) setState(() => vetoes++);
    },
    child: Scaffold(
      body: TextButton(
        key: const ValueKey('qa9716-unblock'),
        onPressed: () => setState(() => blocked = false),
        child: Text('Unblock $vetoes'),
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<ChatWorkspaceController> _open(
  WidgetTester tester, {
  required Size size,
  required bool fromSplit,
  required ThemeData theme,
  required double scale,
  bool reduce = false,
}) async {
  tester.view.physicalSize = fromSplit ? _wide : size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
  final c = ChatWorkspaceController();
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: reduce,
        ),
        child: child!,
      ),
      home: ChatWorkspaceHost(
        controller: c,
        chat: const Scaffold(body: TextField(key: ValueKey('qa9716-chat'))),
        tabBuilder: (_, tab) => _Panel(tab),
      ),
    ),
  );
  c.open(ChatWorkspaceTab.terminal);
  await _settle(tester);
  if (fromSplit) {
    tester.view.physicalSize = size;
    await _settle(tester);
  }
  return c;
}

_PanelState _panel(WidgetTester tester, ChatWorkspaceTab tab) =>
    tester.state<_PanelState>(
      find.byWidgetPredicate(
        (w) => w is _Panel && w.tab == tab,
        skipOffstage: false,
      ),
    );

void main() {
  setUpAll(loadDesignFonts);
  for (final dark in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      for (final size in const [
        Size(360, 800),
        Size(412, 915),
        Size(673, 933),
        Size(773, 1000),
        Size(884, 1000),
      ]) {
        testWidgets('QA9716 both entries share frame, header and body '
            '$size dark=$dark text=$scale', (tester) async {
          addTearDown(tester.view.reset);
          final expected = <ChatWorkspaceTab, List<Object>>{};
          for (final fromSplit in [true, false]) {
            final c = await _open(
              tester,
              size: size,
              fromSplit: fromSplit,
              theme: dark ? AppTheme.hermesRedDark : AppTheme.hermesRedLight,
              scale: scale,
            );
            for (final tab in ChatWorkspaceTab.values) {
              c.open(tab);
              await _settle(tester);
              final state = _panel(tester, tab);
              final panel = find.byWidgetPredicate(
                (w) => w is _Panel && w.tab == tab,
              );
              final clip = tester.widget<ClipRRect>(find.byKey(_clip));
              final frame = tester.getRect(find.byKey(_frame));
              final header = tester.getRect(find.byKey(_bar));
              final body = tester.getRect(
                find.byKey(ValueKey('chat-workspace-body-${tab.name}')),
              );
              expect(
                ChatWorkspacePaneScope.isInPane(tester.element(panel)),
                isTrue,
              );
              expect(
                find
                    .byType(_Panel, skipOffstage: false)
                    .evaluate()
                    .where((e) => (e.widget as _Panel).tab == tab)
                    .length,
                1,
              );
              expect(
                clip.borderRadius,
                BorderRadius.circular(chatWorkspacePaneRadius),
              );
              expect(clip.clipBehavior, Clip.antiAlias);
              expect(frame.top, 24 + ChatWorkspaceGeometry.padding);
              expect(
                frame.bottom,
                size.height - 24 - ChatWorkspaceGeometry.padding,
              );
              expect(frame.width, greaterThan(size.width * 0.4));
              expect(header.left, greaterThanOrEqualTo(frame.left));
              expect(header.right, lessThanOrEqualTo(frame.right));
              expect(header.bottom, lessThanOrEqualTo(body.top));
              expect(body.bottom, lessThanOrEqualTo(frame.bottom));
              expect(
                tester
                    .widget<IconButton>(
                      find.byKey(const ValueKey('chat-workspace-keys')),
                    )
                    .onPressed,
                isNotNull,
              );
              expect(
                tester
                    .widget<IconButton>(
                      find.byKey(const ValueKey('chat-workspace-herdr')),
                    )
                    .onPressed,
                isNotNull,
              );
              expect(state.keys, isTrue);
              final measured = <Object>[
                frame,
                header,
                body,
                tester.widget<DecoratedBox>(find.byKey(_frame)).decoration,
                clip.borderRadius,
              ];
              if (fromSplit) {
                expected[tab] = measured;
              } else {
                expect(
                  measured,
                  expected[tab],
                  reason: 'direct must use Split→vertical composition',
                );
              }
            }
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            c.dispose();
          }
        });
      }
    }
  }

  for (final fromSplit in [false, true]) {
    testWidgets('QA9716 compact Back leaves inactive navigation untouched '
        'split=$fromSplit', (tester) async {
      addTearDown(tester.view.reset);
      final c = await _open(
        tester,
        size: const Size(673, 933),
        fromSplit: fromSplit,
        theme: AppTheme.hermesRedDark,
        scale: 1,
      );
      addTearDown(c.dispose);
      final terminal = _panel(tester, ChatWorkspaceTab.terminal);
      c.open(ChatWorkspaceTab.files);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('qa9716-push-files')));
      await _settle(tester);
      final child = tester.state<_ChildState>(find.byType(_Child));
      c.open(ChatWorkspaceTab.git);
      await _settle(tester);
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(c.active, ChatWorkspaceTab.files);
      expect(tester.state(find.byType(_Child)), same(child));
      expect(
        child.vetoes,
        0,
        reason: 'inactive tabs must not receive this Back',
      );
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(child.vetoes, 1);
      expect(c.active, ChatWorkspaceTab.files);
      await tester.tap(find.byKey(const ValueKey('qa9716-unblock')));
      await _settle(tester);
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(find.byType(_Child), findsNothing);
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(c.active, ChatWorkspaceTab.terminal);
      expect(_panel(tester, ChatWorkspaceTab.terminal), same(terminal));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
    for (final reduce in [false, true]) {
      testWidgets('QA9716 actions, keyboard focus and route veto survive both '
          'entries split=$fromSplit reduced=$reduce', (tester) async {
        addTearDown(tester.view.reset);
        final c = await _open(
          tester,
          size: const Size(673, 933),
          fromSplit: fromSplit,
          theme: AppTheme.hermesRedDark,
          scale: 1,
          reduce: reduce,
        );
        addTearDown(c.dispose);
        final terminal = _panel(tester, ChatWorkspaceTab.terminal);
        final session = terminal.session;
        await tester.tap(find.byKey(const ValueKey('chat-workspace-keys')));
        await _settle(tester);
        expect(terminal.keys, isFalse);
        await tester.tap(find.byKey(const ValueKey('chat-workspace-herdr')));
        await _settle(tester);
        expect(terminal.herdr, 1);
        await tester.enterText(
          find.byKey(const ValueKey('qa9716-input-terminal')),
          'kept draft',
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await _settle(tester);
        tester.takeAnnouncements();
        for (final size in const [
          _wide,
          Size(673, 933),
          Size(360, 800),
          _wide,
        ]) {
          tester.view.physicalSize = size;
          await _settle(tester);
          expect(_panel(tester, ChatWorkspaceTab.terminal), same(terminal));
          expect(terminal.session, same(session));
          expect(terminal.input.text, 'kept draft');
          expect(terminal.focus.hasFocus, isTrue);
          expect(c.mode, ChatWorkspaceMode.split);
          expect(
            MediaQuery.of(
              tester.element(find.byType(_Panel)),
            ).viewInsets.bottom,
            280,
          );
          expect(tester.takeAnnouncements(), isEmpty);
        }
        tester.view.viewInsets = const FakeViewPadding();
        terminal.focus.unfocus();
        tester.view.physicalSize = const Size(673, 933);
        await _settle(tester);
        await tester.tap(
          find.byKey(const ValueKey('chat-workspace-layout-menu')),
        );
        await _settle(tester);
        await tester.tap(find.byKey(const ValueKey('qa9716-child-action')));
        await _settle(tester);
        final child = tester.state<_ChildState>(find.byType(_Child));
        await tester.binding.handlePopRoute();
        await _settle(tester);
        expect(tester.state(find.byType(_Child)), same(child));
        expect(child.vetoes, 1);
        expect(_panel(tester, ChatWorkspaceTab.terminal), same(terminal));
        await tester.tap(find.byKey(const ValueKey('qa9716-unblock')));
        await _settle(tester);
        await tester.binding.handlePopRoute();
        await _settle(tester);
        expect(find.byType(_Child), findsNothing);
        expect(_panel(tester, ChatWorkspaceTab.terminal), same(terminal));
        await tester.tap(find.byKey(const ValueKey('chat-workspace-expand')));
        await _settle(tester);
        expect(c.mode, ChatWorkspaceMode.workspace);
        await tester.binding.handlePopRoute();
        await _settle(tester);
        expect(c.mode, ChatWorkspaceMode.split);
        expect(_panel(tester, ChatWorkspaceTab.terminal), same(terminal));
        await tester.binding.handlePopRoute();
        await _settle(tester);
        expect(c.tabs, isEmpty);
        expect(find.byKey(const ValueKey('qa9716-chat')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
