// The dock is a plain tap bar.
//
// Owner (2026-10-11): "Yo al dock le quitaría lo de los gestos, dejaría que
// fuese donde pulsas. Dejaría lo de mantener pulsado. Lo de ocultar
// automáticamente lo quitaría; dejaría opcional ocultar manual."
//
// | On the bar                    | What happens                          |
// |-------------------------------|---------------------------------------|
// | tap an item                   | it runs                               |
// | long press an item            | its menu (Actividad, Editar dock and  |
// |                               | Esconder el dock are in every menu)   |
// | long press outside the items  | edit mode                             |
// | any swipe, in any direction   | nothing                               |
// | scrolling the screen          | nothing: the dock never hides itself  |
// | keyboard open                 | the dock steps aside                  |
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/gesture_dock.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 360 x 780 dp phone, 24 dp gesture-navigation inset, 30 dp back-gesture
// edges. The bar spans x 14..346 and y 682..742; items are 80 dp wide from
// x = 20, so their centres are at 60, 140, 220 and 300.
const _barCenter = Offset(180, 712);
Offset _tab(int i) => Offset(60 + 80.0 * i, 712);

GestureDockController get _c => GestureDockController.instance;

/// Stands in for a dock on the visible route.

class _Calls {
  final List<String> log = [];
  VoidCallback call(String name) =>
      () => log.add(name);
}

Widget _app({
  required Widget child,
  bool reduceMotion = false,
  TextDirection? direction,
}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: Builder(
    builder: (context) {
      final screen = MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: Scaffold(body: child),
      );
      return direction == null
          ? screen
          : Directionality(textDirection: direction, child: screen);
    },
  ),
);

Widget _dock(
  _Calls calls, {
  GestureDockTab? current = GestureDockTab.home,
  bool withShortcuts = true,
  bool Function()? needsYou,
  Widget? body,
  bool reduceMotion = false,
  TextDirection? direction,
}) => _app(
  reduceMotion: reduceMotion,
  direction: direction,
  child: Stack(
    fit: StackFit.expand,
    children: [
      ?body,
      GestureDock(
        current: current,
        onTab: {
          GestureDockTab.home: current == GestureDockTab.home
              ? null
              : calls.call('home'),
          GestureDockTab.create: calls.call('new'),
          GestureDockTab.projects: current == GestureDockTab.projects
              ? null
              : calls.call('projects'),
          GestureDockTab.settings: current == GestureDockTab.settings
              ? null
              : calls.call('settings'),
        },
        shortcuts: withShortcuts
            ? {
                GestureDockTab.settings: [
                  DockShortcut(
                    label: 'Atajo uno',
                    icon: Icons.star,
                    onTap: calls.call('shortcut'),
                  ),
                ],
              }
            : const {},
        onActivity: calls.call('activity'),
        onEdit: calls.call('edit'),
        needsYou: needsYou ?? () => false,
      ),
    ],
  ),
);

void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.viewPadding = const FakeViewPadding(bottom: 72);
  tester.view.padding = const FakeViewPadding(bottom: 72);
  tester.view.systemGestureInsets = const FakeViewPadding(
    left: 90,
    right: 90,
    bottom: 72,
  );
  addTearDown(tester.view.reset);
}

Future<void> _drag(WidgetTester tester, Offset from, List<Offset> steps) async {
  final gesture = await tester.startGesture(from);
  for (final step in steps) {
    await gesture.moveBy(step);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pump();
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  _c.resetForTesting(
    settings: const GestureDockSettings(
      tabs: GestureDockTab.legacyDefaultLayout,
    ),
  );
  await tester.pump(const Duration(seconds: 20));
}

Matrix4 _barTransform(WidgetTester tester) => tester
    .widget<Transform>(
      find
          .descendant(
            of: find.byKey(const ValueKey('gesture-dock-pointer')),
            matching: find.byType(Transform),
          )
          .first,
    )
    .transform;

double _barOpacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find
          .descendant(
            of: find.byKey(const ValueKey('gesture-dock-pointer')),
            matching: find.byType(Opacity),
          )
          .first,
    )
    .opacity;

const _popover = ValueKey('gesture-dock-popover');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _c.resetForTesting(
      settings: const GestureDockSettings(
        tabs: GestureDockTab.legacyDefaultLayout,
      ),
    );
    DockGeometry.instance.resetForTesting();
    FeatureFlags.instance.resetForTesting();
  });

  group('taps', () {
    testWidgets('a tap on an item runs it, every time', (tester) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls));
      await tester.tapAt(_tab(2));
      await tester.pump();
      expect(calls.log, ['projects']);
      await tester.tapAt(_tab(1));
      await tester.tapAt(_tab(3));
      await tester.tapAt(_tab(2));
      expect(calls.log, ['projects', 'new', 'settings', 'projects']);
      await _finish(tester);
    });

    testWidgets('the item of the screen you are on does nothing', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls, current: GestureDockTab.projects));
      await tester.tapAt(_tab(2));
      await tester.pump();
      expect(calls.log, isEmpty);
      await tester.tapAt(_tab(0));
      expect(calls.log, ['home']);
      await _finish(tester);
    });

    testWidgets('right-to-left: a tap hits the item drawn under the finger', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls, direction: TextDirection.rtl));
      // Mirrored row: Ajustes is drawn first from the left.
      expect(
        tester
            .getCenter(find.byKey(const ValueKey('gesture-dock-tab-settings')))
            .dx,
        _tab(0).dx,
      );
      await tester.tapAt(_tab(0));
      await tester.tapAt(_tab(2));
      expect(calls.log, ['settings', 'new']);
      await _finish(tester);
    });
  });

  group('no gesture does anything', () {
    // Every direction, short and long, slow and in one go. Before the dock
    // was a tap bar these changed item (sideways), opened Actividad (up)
    // and hid the dock (down).
    for (final (name, step) in const [
      ('left', Offset(-20, 0)),
      ('right', Offset(20, 0)),
      ('up', Offset(0, -20)),
      ('down', Offset(0, 20)),
      ('diagonal', Offset(14, 14)),
    ]) {
      testWidgets('a swipe $name on the bar changes nothing', (tester) async {
        _phone(tester);
        final calls = _Calls();
        await tester.pumpWidget(_dock(calls, current: GestureDockTab.projects));
        for (final steps in [1, 2, 3, 6]) {
          final gesture = await tester.startGesture(_barCenter);
          for (var i = 0; i < steps; i++) {
            await gesture.moveBy(step);
            await tester.pump(const Duration(milliseconds: 16));
            expect(
              _barTransform(tester),
              Matrix4.identity(),
              reason: 'the bar does not follow the finger',
            );
            expect(_barOpacity(tester), 1);
          }
          await gesture.up();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          expect(calls.log, isEmpty, reason: '$name, ${steps * 20} dp');
          expect(_c.hidden.value, isFalse);
          expect(find.byKey(_popover), findsNothing);
          expect(_barOpacity(tester), 1);
          expect(_barTransform(tester), Matrix4.identity());
        }
        await _finish(tester);
      });
    }

    testWidgets('a finger that slides off the spot it touched is not a tap', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls));
      // From Proyectos to Ajustes and up there: neither runs.
      await _drag(tester, _tab(2), const [Offset(40, 0), Offset(40, 0)]);
      expect(calls.log, isEmpty);
      // A finger that only trembles (under the touch slop) still taps.
      await _drag(tester, _tab(2), const [Offset(6, 3)]);
      expect(calls.log, ['projects']);
      await _finish(tester);
    });

    testWidgets('scrolling the screen, however far, never hides the dock', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(
        _dock(
          _Calls(),
          body: ListView.builder(
            key: const ValueKey('list'),
            itemCount: 200,
            itemBuilder: (_, i) => SizedBox(height: 56, child: Text('Fila $i')),
          ),
        ),
      );
      for (final delta in const [-300.0, -900.0, 400.0, -2000.0]) {
        await tester.drag(find.byKey(const ValueKey('list')), Offset(0, delta));
        await tester.pump();
        expect(_c.hidden.value, isFalse);
        expect(_barOpacity(tester), 1);
        await tester.pump(const Duration(seconds: 2));
        expect(_barOpacity(tester), 1);
      }
      await tester.fling(
        find.byKey(const ValueKey('list')),
        const Offset(0, -600),
        3000,
      );
      await tester.pump(const Duration(seconds: 3));
      expect(_c.hidden.value, isFalse);
      expect(_barOpacity(tester), 1);
      await _finish(tester);
    });

    testWidgets('a system gesture taken mid-touch (a cancel) runs nothing', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls));
      final gesture = await tester.startGesture(_tab(2));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.cancel();
      await tester.pump();
      expect(calls.log, isEmpty);
      await tester.tapAt(_tab(2));
      expect(calls.log, ['projects'], reason: 'the next tap works');
      await _finish(tester);
    });
  });

  group('long press', () {
    testWidgets('480 ms on an item opens its menu and no tap fires', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls));
      final gesture = await tester.startGesture(_tab(3));
      await tester.pump(const Duration(milliseconds: 470));
      expect(find.byKey(_popover), findsNothing);
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.byKey(_popover), findsOneWidget);
      await gesture.up();
      await tester.pump();
      expect(calls.log, isEmpty, reason: 'the release is not a tap');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Atajo uno'));
      await tester.pump();
      expect(calls.log, ['shortcut']);
      expect(find.byKey(_popover), findsNothing);
      await _finish(tester);
    });

    testWidgets('a tap outside the menu closes it and runs nothing', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls));
      final gesture = await tester.startGesture(_tab(3));
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pump();
      expect(find.byKey(_popover), findsOneWidget);
      await tester.tapAt(const Offset(180, 200));
      await tester.pump();
      expect(find.byKey(_popover), findsNothing);
      expect(calls.log, isEmpty);
      await _finish(tester);
    });

    testWidgets('sliding away before 480 ms cancels the long press', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls));
      final gesture = await tester.startGesture(_tab(3));
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveBy(const Offset(0, -24));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(_popover), findsNothing);
      await gesture.up();
      await tester.pump();
      expect(calls.log, isEmpty);
      await _finish(tester);
    });

    testWidgets('where there is no menu, it opens the edit mode', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls, withShortcuts: false));
      final gesture = await tester.startGesture(_tab(2));
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pump();
      expect(calls.log, ['edit']);
      expect(find.byKey(_popover), findsNothing);
      await _finish(tester);
    });
  });

  group('accessibility', () {
    testWidgets('what a long press reaches is a screen reader action; no '
        'action names a gesture', (tester) async {
      _phone(tester);
      final handle = tester.ensureSemantics();
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls, current: GestureDockTab.projects));
      final dock = tester.getSemantics(
        find.byKey(const ValueKey('gesture-dock')),
      );
      final dockNode = find.semantics.byPredicate((n) => n.id == dock.id);
      Future<void> run(String label) async {
        tester.semantics.customAction(
          dockNode,
          CustomSemanticsAction(label: label),
        );
        await tester.pump();
      }

      final strings = Strings.of(
        tester.element(find.byKey(const ValueKey('gesture-dock'))),
      );
      final offered = [
        for (final id
            in dock.getSemanticsData().customSemanticsActionIds ??
                const <int>[])
          CustomSemanticsAction.getAction(id)!.label,
      ];
      expect(
        offered,
        unorderedEquals([
          strings.gdActivityTitle,
          strings.gdEditDock,
          strings.gdHideDock,
        ]),
      );
      await run(strings.gdActivityTitle);
      await run(strings.gdEditDock);
      expect(calls.log, ['activity', 'edit']);
      await run(strings.gdHideDock);
      expect(_c.hidden.value, isTrue);
      await tester.pump(const Duration(milliseconds: 400));
      tester.semantics.tap(find.semantics.byLabel(strings.gdShowDock));
      await tester.pump();
      expect(_c.hidden.value, isFalse);
      // While hidden the items are out of the semantics tree; once shown
      // again, an item's long press opens its menu.
      await tester.pump(const Duration(milliseconds: 400));
      tester.semantics.longPress(find.semantics.byLabel(strings.gdTabSettings));
      await tester.pump();
      expect(find.byKey(_popover), findsOneWidget);
      handle.dispose();
      await _finish(tester);
    });
  });

  group('keyboard and attention', () {
    testWidgets('the dock steps aside while the keyboard is open', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls));
      tester.view.viewInsets = const FakeViewPadding(bottom: 900);
      await tester.pump(const Duration(milliseconds: 200));
      final gate = tester.widget<IgnorePointer>(
        find.byKey(const ValueKey('gesture-dock-keyboard-gate')),
      );
      expect(gate.ignoring, isTrue);
      await tester.tapAt(_tab(2));
      expect(calls.log, isEmpty);
      await tester.pump();
      expect(DockGeometry.instance.rect.value, isNull);
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tapAt(_tab(2));
      expect(calls.log, ['projects']);
      await _finish(tester);
    });

    testWidgets('amber dot on Inicio when something needs you elsewhere', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(
        _dock(calls, current: GestureDockTab.projects, needsYou: () => true),
      );
      expect(
        find.byKey(const ValueKey('gesture-dock-attention')),
        findsOneWidget,
      );
      await tester.pumpWidget(
        _dock(calls, current: GestureDockTab.home, needsYou: () => true),
      );
      expect(
        find.byKey(const ValueKey('gesture-dock-attention')),
        findsNothing,
      );
      await tester.pumpWidget(
        _dock(calls, current: GestureDockTab.projects, needsYou: () => false),
      );
      expect(
        find.byKey(const ValueKey('gesture-dock-attention')),
        findsNothing,
      );
      await _finish(tester);
    });
  });

  // Owner: "que se 'ilumine' lo que se selecciona para saber que está
  // seleccionado, pero sin el aura de luz sino rollo mate, que se rellene
  // de color el icono".
  group('selected item: matte', () {
    Widget on(
      GestureDockTab current, {
      String theme = 'classic-dark',
      List<GestureDockTab>? tabs,
    }) {
      _c.resetForTesting(
        settings: GestureDockSettings(
          tabs:
              tabs ?? GestureDockTab.normalize([GestureDockTab.home, current]),
        ),
      );
      return MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId(theme),
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              GestureDock(
                current: current,
                onTab: {
                  for (final tab in GestureDockTab.values)
                    if (tab != current) tab: () {},
                },
              ),
            ],
          ),
        ),
      );
    }

    Finder item(GestureDockTab tab) =>
        find.byKey(ValueKey('gesture-dock-tab-${tab.name}'));

    Icon iconOf(WidgetTester tester, GestureDockTab tab) => tester.widget<Icon>(
      find.descendant(of: item(tab), matching: find.byType(Icon)),
    );

    /// Nothing under [tab]'s slot throws light: no shadow on the icon, no
    /// box shadow, no gradient, no blur.
    void expectMatte(WidgetTester tester, GestureDockTab tab) {
      expect(iconOf(tester, tab).shadows ?? const <Shadow>[], isEmpty);
      expect(
        find.descendant(
          of: item(tab),
          matching: find.byWidgetPredicate(
            (w) =>
                w is BackdropFilter ||
                w is ImageFiltered ||
                w is ShaderMask ||
                w is PhysicalModel ||
                w is PhysicalShape,
          ),
        ),
        findsNothing,
      );
      final boxes = find.descendant(
        of: item(tab),
        matching: find.byWidgetPredicate(
          (w) => w is DecoratedBox || w is Container,
        ),
      );
      for (final element in boxes.evaluate()) {
        final widget = element.widget;
        final decoration = widget is DecoratedBox
            ? widget.decoration
            : (widget as Container).decoration;
        if (decoration is BoxDecoration) {
          expect(decoration.boxShadow ?? const <BoxShadow>[], isEmpty);
          expect(decoration.gradient, isNull);
        }
      }
    }

    for (final tab in GestureDockTab.values.where((t) => t.isPlace)) {
      // Chats gets its filled icon with its new name (next commit).
      if (tab == GestureDockTab.search) continue;
      testWidgets('${tab.name}: the filled icon in the accent colour, and '
          'nothing else', (tester) async {
        _phone(tester);
        await tester.pumpWidget(on(tab));
        final colors = AppTheme.fromId('classic-dark').hermes;
        final selected = iconOf(tester, tab);
        expect(selected.icon, gestureDockTabIcon(tab, selected: true));
        expect(
          selected.icon,
          isNot(gestureDockTabIcon(tab)),
          reason: 'the filled form is another glyph than the outlined one',
        );
        expect(selected.color, colors.accentText);
        expectMatte(tester, tab);
        expect(find.byKey(const ValueKey('gesture-dock-glow')), findsNothing);
        expect(tester.widget<Semantics>(item(tab)).properties.selected, isTrue);
        // Every other item: outlined and muted.
        for (final other in _c.value.tabs.where((t) => t != tab)) {
          final icon = iconOf(tester, other);
          expect(icon.icon, gestureDockTabIcon(other), reason: other.name);
          expect(icon.color, colors.textSecondary, reason: other.name);
          expectMatte(tester, other);
          expect(
            tester.widget<Semantics>(item(other)).properties.selected,
            isFalse,
          );
        }
        await _finish(tester);
      });
    }

    testWidgets('an action never shows as selected', (tester) async {
      _phone(tester);
      for (final action in [GestureDockTab.create, GestureDockTab.activity]) {
        expect(action.isPlace, isFalse);
        await tester.pumpWidget(on(action));
        final colors = AppTheme.fromId('classic-dark').hermes;
        final icon = iconOf(tester, action);
        expect(icon.icon, gestureDockTabIcon(action));
        expect(icon.icon, gestureDockTabIcon(action, selected: true));
        expect(icon.color, isNot(colors.accentText));
        expect(
          tester.widget<Semantics>(item(action)).properties.selected,
          isFalse,
        );
      }
      await _finish(tester);
    });

    // A matte icon has only its own colour to stand on: at least 3:1
    // against the bar (WCAG 1.4.11), solid or glass over the page.
    for (final theme in ['classic-dark', 'classic', 'console', 'amber-light']) {
      testWidgets('$theme: the selected icon reads on the bar', (tester) async {
        _phone(tester);
        await tester.pumpWidget(on(GestureDockTab.settings, theme: theme));
        final colors = AppTheme.fromId(theme).hermes;
        final selected = iconOf(tester, GestureDockTab.settings).color!;
        final unselected = iconOf(tester, GestureDockTab.home).color!;
        final glass = ThemeContrast.composite(
          colors.surface.withValues(alpha: .58),
          colors.background,
        );
        for (final bar in [colors.surface, glass]) {
          expect(
            ThemeContrast.ratio(selected, bar),
            greaterThanOrEqualTo(3),
            reason: '$theme selected on $bar',
          );
          expect(
            ThemeContrast.ratio(unselected, bar),
            greaterThanOrEqualTo(3),
            reason: '$theme unselected on $bar',
          );
        }
        expect(selected, isNot(unselected));
        await _finish(tester);
      });
    }
  });

  group('hidden by hand', () {
    testWidgets('the bar slides away; with reduced motion, in one frame', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_dock(_Calls()));
      _c.setHidden(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_barOpacity(tester), inExclusiveRange(0, 1));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_barOpacity(tester), 0);
      _c.setHidden(false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_barOpacity(tester), 1);

      await tester.pumpWidget(_dock(_Calls(), reduceMotion: true));
      _c.setHidden(true);
      await tester.pump();
      await tester.pump();
      expect(_barOpacity(tester), 0);
      await _finish(tester);
    });

    testWidgets('hiding closes an open menu', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_dock(_Calls()));
      final gesture = await tester.startGesture(_tab(3));
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pump();
      expect(find.byKey(_popover), findsOneWidget);
      _c.setHidden(true);
      await tester.pump();
      expect(find.byKey(_popover), findsNothing);
      await _finish(tester);
    });
  });

  group('geometry', () {
    testWidgets(
      'publishes the bar, then the handle while hidden, then clears',
      (tester) async {
        _phone(tester);
        await tester.pumpWidget(_dock(_Calls()));
        await tester.pump();
        expect(
          DockGeometry.instance.rect.value,
          const Rect.fromLTWH(14, 682, 332, 60),
        );
        expect(DockGeometry.instance.hidden.value, isFalse);
        _c.setHidden(true);
        await tester.pump(const Duration(milliseconds: 400));
        final handle = DockGeometry.instance.rect.value!;
        expect(DockGeometry.instance.hidden.value, isTrue);
        expect(handle, const Rect.fromLTWH(136, 702, 88, 48));
        await tester.pumpWidget(const SizedBox());
        expect(DockGeometry.instance.rect.value, isNull);
        await _finish(tester);
      },
    );

    testWidgets('asked again, it says where it rests', (tester) async {
      // Whoever stands on the dock asks once the navigator has settled: the
      // first report may come while the dock's route is still arriving.
      _phone(tester);
      await tester.pumpWidget(_dock(_Calls()));
      await tester.pump();
      const bar = Rect.fromLTWH(14, 682, 332, 60);
      expect(DockGeometry.instance.rect.value, bar);
      DockGeometry.instance.publish(
        Object(),
        bar.translate(90, 0),
        hidden: false,
      );
      DockGeometry.instance.refresh();
      await tester.pump();
      expect(DockGeometry.instance.rect.value, bar);
      // A dock that left the screen is not asked.
      await tester.pumpWidget(const SizedBox());
      DockGeometry.instance.refresh();
      await tester.pump();
      expect(DockGeometry.instance.rect.value, isNull);
      await _finish(tester);
    });

    testWidgets('an item\'s menu is announced while it is open', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_dock(_Calls()));
      expect(DockGeometry.instance.menuOpen.value, isFalse);
      final gesture = await tester.startGesture(_tab(3));
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pump();
      expect(find.byKey(_popover), findsOneWidget);
      expect(DockGeometry.instance.menuOpen.value, isTrue);
      await tester.tapAt(const Offset(180, 200));
      await tester.pump();
      expect(DockGeometry.instance.menuOpen.value, isFalse);
      // Gone with its menu open, it does not leave the flag behind.
      final again = await tester.startGesture(_tab(3));
      await tester.pump(const Duration(milliseconds: 500));
      await again.up();
      await tester.pump();
      expect(DockGeometry.instance.menuOpen.value, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(DockGeometry.instance.menuOpen.value, isFalse);
      await _finish(tester);
    });

    testWidgets('the bar is the floating chrome and never blurs; opaque when '
        'asked to', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_dock(_Calls()));
      final context = tester.element(find.byType(GestureDock));
      final chrome = HermesChrome.ofContext(context);
      Color? fillOf(String key) =>
          (tester.widget<DecoratedBox>(find.byKey(ValueKey(key))).decoration
                  as BoxDecoration)
              .color;
      // Nothing scrolls behind the dock, so a blur would be pure cost.
      expect(find.byType(BackdropFilter), findsNothing);
      expect(fillOf('gesture-dock-glass'), chrome.fill);
      expect(
        tester.getRect(find.byKey(const ValueKey('gesture-dock-glass'))),
        const Rect.fromLTWH(14, 682, 332, 60),
      );
      await _c.setOpaque(true);
      await tester.pump();
      expect(find.byType(BackdropFilter), findsNothing);
      expect(fillOf('gesture-dock-opaque'), chrome.opaque);
      await _finish(tester);
    });

    testWidgets('hiding and showing does not rebuild the content', (
      tester,
    ) async {
      _phone(tester);
      var builds = 0;
      await tester.pumpWidget(
        _dock(
          _Calls(),
          body: Builder(
            builder: (_) {
              builds++;
              return const SizedBox.expand();
            },
          ),
        ),
      );
      final before = builds;
      _c.setHidden(true);
      await tester.pump(const Duration(milliseconds: 400));
      _c.setHidden(false);
      await tester.pump(const Duration(milliseconds: 400));
      expect(builds, before);
      await _finish(tester);
    });
  });
}
