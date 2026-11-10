import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart'
    show HermesChrome;
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/design_shots.dart' show loadDesignFonts;

const _sheet = ValueKey('chat-workspace-sheet');
const _frame = ValueKey('chat-workspace-sheet-frame');
const _open = ValueKey('qa9715-open');
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
  int taps = 0;

  @override
  void dispose() {
    input.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    key: ValueKey('qa9715-panel-${widget.tab.name}'),
    backgroundColor: ChatWorkspacePaneScope.backgroundOf(context, Colors.red),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextButton(
            key: ValueKey('qa9715-count-${widget.tab.name}'),
            onPressed: () => setState(() => taps++),
            child: Text('${widget.tab.name}: $taps'),
          ),
          TextField(
            key: ValueKey('qa9715-input-${widget.tab.name}'),
            controller: input,
            focusNode: focus,
          ),
          TextButton(
            key: ValueKey('qa9715-pop-${widget.tab.name}'),
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Back'),
          ),
        ],
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _app(
  WidgetTester tester, {
  required Size size,
  required Widget home,
  required ThemeData theme,
  double scale = 1,
  bool reduce = false,
  bool safeArea = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  if (safeArea) {
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
  }
  addTearDown(tester.view.reset);
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
      home: home,
    ),
  );
}

Future<void> _compact(
  WidgetTester tester, {
  required Size size,
  required ThemeData theme,
  ChatWorkspaceTab tab = ChatWorkspaceTab.terminal,
  double scale = 1,
  bool safeArea = false,
}) async {
  await _app(
    tester,
    size: size,
    theme: theme,
    scale: scale,
    safeArea: safeArea,
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            key: _open,
            onPressed: () => showChatWorkspaceSheet<void>(
              context,
              builder: (_) => _Panel(tab),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(_open));
  await _settle(tester);
}

Finder _panel(ChatWorkspaceTab tab) =>
    find.byKey(ValueKey('qa9715-panel-${tab.name}'));

_PanelState _stateFor(WidgetTester tester, ChatWorkspaceTab tab) =>
    tester.state<_PanelState>(
      find.byWidgetPredicate(
        (widget) => widget is _Panel && widget.tab == tab,
        skipOffstage: false,
      ),
    );

Finder _clipFor(ChatWorkspaceTab tab) => find
    .ancestor(
      of: _panel(tab),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is ClipRRect &&
            widget.borderRadius ==
                BorderRadius.circular(chatWorkspacePaneRadius),
      ),
    )
    .first;

class _ClipPaintRecorder extends PaintingContext {
  _ClipPaintRecorder() : super(ContainerLayer(), Rect.zero);

  RRect? paintedClip;
  Clip? behavior;

  @override
  ClipRRectLayer? pushClipRRect(
    bool needsCompositing,
    Offset offset,
    Rect bounds,
    RRect clipRRect,
    PaintingContextCallback painter, {
    Clip clipBehavior = Clip.antiAlias,
    ClipRRectLayer? oldLayer,
  }) {
    paintedClip = clipRRect.shift(offset);
    behavior = clipBehavior;
    return oldLayer;
  }
}

void _roundedPaintRegion(WidgetTester tester, Finder finder) {
  final clip = tester.renderObject<RenderClipRRect>(finder);
  expect(clip.clipBehavior, Clip.antiAlias);
  final size = clip.size;
  final context = _ClipPaintRecorder();
  clip.paint(context, Offset.zero);
  expect(context.paintedClip, isNotNull);
  expect(context.behavior, Clip.antiAlias);
  final painted = context.paintedClip!;
  expect(painted.outerRect, Offset.zero & size);
  // Check the clip actually sent to painting, including both lower corners.
  // Flutter's default RenderClipRRect hitTest uses its rectangular bounds;
  // that input region is not evidence of the rounded paint.
  for (final point in [
    const Offset(1, 1),
    Offset(size.width - 1, 1),
    Offset(1, size.height - 1),
    Offset(size.width - 1, size.height - 1),
  ]) {
    expect(painted.contains(point), isFalse);
  }
  expect(
    painted.contains(size.center(Offset.zero)),
    isTrue,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadDesignFonts);
  const sizes = [
    Size(360, 800),
    Size(412, 915),
    Size(773, 1000),
    Size(884, 1000),
    _wide,
  ];
  final themes = [
    ('dark', AppTheme.hermesRedDark),
    ('light', AppTheme.hermesRedLight),
  ];

  for (final (name, theme) in themes) {
    for (final scale in [1.0, 2.0]) {
      for (final size in sizes) {
        testWidgets(
          'QA9715 compact frame $name $scale ${size.width}x${size.height}',
          (tester) async {
            await _compact(
              tester,
              size: size,
              theme: theme,
              scale: scale,
              safeArea: true,
            );
            final sheet = find.byKey(_sheet);
            final rect = tester.getRect(sheet);
            expect(rect.left, ChatWorkspaceGeometry.padding);
            expect(rect.right, size.width - ChatWorkspaceGeometry.padding);
            expect(
              rect.bottom,
              size.height - 24,
              reason: 'system area outside the frame',
            );
            expect(
              rect.top,
              greaterThan(24),
              reason: 'the chat still shows above',
            );
            expect(rect.height, greaterThan((size.height - 48) * 0.85));
            expect(
              tester.widget<ClipRRect>(sheet).borderRadius,
              BorderRadius.circular(chatWorkspacePaneRadius),
            );
            final decoration =
                tester.widget<DecoratedBox>(find.byKey(_frame)).decoration
                    as BoxDecoration;
            expect(decoration.color, theme.hermes.surface);
            expect(
              decoration.border,
              Border.all(color: HermesChrome.of(theme.hermes).line),
            );
            expect(
              decoration.borderRadius,
              BorderRadius.circular(chatWorkspacePaneRadius),
            );
            expect(decoration.boxShadow, hasLength(1));
            _roundedPaintRegion(tester, sheet);
            final context = tester.element(_panel(ChatWorkspaceTab.terminal));
            expect(ChatWorkspacePaneScope.isInPane(context), isFalse);
            expect(
              ChatWorkspacePaneScope.backgroundOf(context, Colors.red),
              Colors.transparent,
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  for (final tab in ChatWorkspaceTab.values) {
    for (final keyboard in [false, true]) {
      for (final reduce in [false, true]) {
        testWidgets(
          'QA9715 split vertical folded wide ${tab.name} keyboard=$keyboard reduce=$reduce',
          (tester) async {
            final controller = ChatWorkspaceController();
            addTearDown(controller.dispose);
            for (final tab in ChatWorkspaceTab.values) {
              controller.open(tab);
            }
            controller.activate(tab);
            await _app(
              tester,
              size: _wide,
              theme: keyboard
                  ? AppTheme.hermesRedLight
                  : AppTheme.hermesRedDark,
              scale: 2,
              reduce: reduce,
              home: ChatWorkspaceHost(
                controller: controller,
                chat: const Scaffold(body: Text('Chat')),
                tabBuilder: (_, tab) => _Panel(tab),
              ),
            );
            await _settle(tester);
            final state = _stateFor(tester, tab);
            final split = tester.getRect(_clipFor(tab));
            await tester.tap(find.byKey(ValueKey('qa9715-count-${tab.name}')));
            await tester.enterText(
              find.byKey(ValueKey('qa9715-input-${tab.name}')),
              'draft ${tab.name}',
            );
            await _settle(tester);
            expect(state.taps, 1);
            tester.takeAnnouncements();
            if (keyboard) {
              tester.view.viewInsets = const FakeViewPadding(bottom: 305);
              await _settle(tester);
              expect(tester.takeAnnouncements(), hasLength(1));
            }
            for (final size in [
              const Size(773, 1000),
              const Size(360, 800),
              const Size(884, 1000),
              _wide,
            ]) {
              tester.view.physicalSize = size;
              await _settle(tester);
              final current = _stateFor(tester, tab);
              expect(identical(current, state), isTrue);
              expect(current.input.text, 'draft ${tab.name}');
              expect(current.taps, 1);
              expect(FocusManager.instance.primaryFocus, same(state.focus));
              expect(controller.active, tab);
              expect(controller.tabs, ChatWorkspaceTab.values);
              expect(controller.mode, ChatWorkspaceMode.split);
              expect(tester.view.viewInsets.bottom, keyboard ? 305 : 0);
              expect(tester.takeAnnouncements(), isEmpty);
                _roundedPaintRegion(tester, _clipFor(tab));
              expect(tester.takeException(), isNull);
            }
            if (keyboard) {
              tester.view.resetViewInsets();
              await _settle(tester);
              expect(tester.takeAnnouncements(), hasLength(1));
            }
            expect(
              tester.getRect(_clipFor(tab)),
              split,
              reason: 'approved split restored exactly',
            );
            expect(FocusManager.instance.primaryFocus, same(state.focus));
            expect(tester.takeException(), isNull);
          },
        );
      }

      testWidgets(
        'QA9715 compact ${tab.name} survives rotation and keyboard=$keyboard',
        (tester) async {
          await _compact(
            tester,
            size: const Size(412, 915),
            theme: AppTheme.hermesRedDark,
            tab: tab,
            scale: 2,
          );
          final state = tester.state<_PanelState>(find.byType(_Panel));
          await tester.enterText(
            find.byKey(ValueKey('qa9715-input-${tab.name}')),
            'compact ${tab.name}',
          );
          if (keyboard) {
            tester.view.viewInsets = const FakeViewPadding(bottom: 305);
          }
          for (final size in [
            const Size(773, 1000),
            const Size(360, 800),
            _wide,
          ]) {
            tester.view.physicalSize = size;
            await _settle(tester);
            expect(tester.state<_PanelState>(find.byType(_Panel)), same(state));
            expect(state.input.text, 'compact ${tab.name}');
            expect(FocusManager.instance.primaryFocus, same(state.focus));
            expect(
              MediaQuery.viewInsetsOf(tester.element(_panel(tab))).bottom,
              keyboard ? 305 : 0,
            );
            expect(tester.getRect(find.byKey(_sheet)).width, size.width - 20);
            _roundedPaintRegion(tester, find.byKey(_sheet));
            expect(tester.takeException(), isNull);
          }
          tester.view.resetViewInsets();
          await tester.binding.handlePopRoute();
          await _settle(tester);
          expect(_panel(tab), findsNothing);
          expect(find.byKey(_open), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
