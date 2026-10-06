import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/gesture_dock.dart';
import 'package:hermes_android/core/shell/gesture_dock_scroll_relay.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 360 x 780 dp phone, 24 dp gesture-navigation inset, 30 dp back-gesture
// edges. The bar spans x 14..346 and y 682..742; tabs are 80 dp wide from
// x = 20, so their centres are at 60, 140, 220 and 300.
const _barCenter = Offset(180, 712);
Offset _tab(int i) => Offset(60 + 80.0 * i, 712);

GestureDockController get _c => GestureDockController.instance;

class _Calls {
  final List<String> log = [];
  VoidCallback call(String name) =>
      () => log.add(name);
}

Widget _app({required Widget child, bool reduceMotion = false}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: Scaffold(body: child),
    ),
  ),
);

Widget _dock(
  _Calls calls, {
  GestureDockTab? current = GestureDockTab.home,
  bool withShortcuts = true,
  bool Function()? needsYou,
  Widget? body,
  bool reduceMotion = false,
}) => _app(
  reduceMotion: reduceMotion,
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
        onGoto: calls.call('goto'),
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
  _c.resetForTesting(settings: const GestureDockSettings(welcomeSeen: true));
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // The welcome is its own group; everywhere else it is already seen.
    _c.resetForTesting(settings: const GestureDockSettings(welcomeSeen: true));
    DockGeometry.instance.resetForTesting();
    FeatureFlags.instance.resetForTesting();
  });

  group('taps', () {
    testWidgets('a tap on a tab runs it and counts towards tips', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls));
      await tester.tapAt(_tab(2));
      await tester.pump();
      expect(calls.log, ['projects']);
      expect(_c.value.taps, 1);
      await tester.tapAt(_tab(1));
      expect(calls.log, ['projects', 'new']);
      await _finish(tester);
    });

    testWidgets('a tap right after a gesture is swallowed, later ones work', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls, current: GestureDockTab.projects));
      // Swipe left from Proyectos: goes to Ajustes.
      await _drag(tester, _barCenter, [
        const Offset(-30, 0),
        const Offset(-30, 0),
      ]);
      expect(calls.log, ['settings']);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(_tab(1));
      expect(calls.log, ['settings'], reason: 'tap 60 ms after a swipe');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tapAt(_tab(1));
      expect(calls.log, ['settings', 'new']);
      await _finish(tester);
    });
  });

  group('lateral swipe', () {
    testWidgets('more than 40 dp steps to the next place, 38 dp does not', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls));
      await _drag(tester, _barCenter, [
        const Offset(-19, 0),
        const Offset(-19, 0),
      ]);
      expect(calls.log, isEmpty);
      await tester.pump(const Duration(milliseconds: 300));
      await _drag(tester, _barCenter, [
        const Offset(-21, 0),
        const Offset(-21, 0),
      ]);
      expect(calls.log, ['projects']);
      expect(_c.value.learned, contains(DockGesture.swipe));
      await _finish(tester);
    });

    testWidgets('swiping right goes to the previous place', (tester) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls, current: GestureDockTab.settings));
      await _drag(tester, _barCenter, [
        const Offset(25, 0),
        const Offset(25, 0),
      ]);
      expect(calls.log, ['projects']);
      await _finish(tester);
    });

    testWidgets('at the first place the dock bounces 12 dp in 240 ms', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls));
      await _drag(tester, _barCenter, [
        const Offset(25, 0),
        const Offset(25, 0),
      ]);
      expect(calls.log, isEmpty);
      // Let the finger's own 25 % follow settle first (200 ms), then read
      // the bounce at its peak (120 ms of 240).
      await tester.pump(const Duration(milliseconds: 120));
      final peak = _barTransform(tester).getTranslation().x;
      expect(peak, greaterThan(10));
      // The bounce (12) plus what is left of the finger's settle (<1).
      expect(peak, lessThanOrEqualTo(14));
      await tester.pump(const Duration(milliseconds: 140));
      expect(_barTransform(tester).getTranslation().x, closeTo(0, 0.01));
      await _finish(tester);
    });

    testWidgets(
      'the axis is locked after 9 dp: sideways then down never hides',
      (tester) async {
        _phone(tester);
        final calls = _Calls();
        await tester.pumpWidget(_dock(calls));
        await _drag(tester, _barCenter, [
          const Offset(-12, 0),
          const Offset(0, 60),
        ]);
        expect(_c.hidden.value, isFalse);
        expect(calls.log, isEmpty);
        // Below 9 dp nothing is decided yet: a later down move still hides.
        await tester.pump(const Duration(milliseconds: 300));
        await _drag(tester, _barCenter, [
          const Offset(-6, 0),
          const Offset(0, 60),
        ]);
        expect(_c.hidden.value, isTrue);
        await _finish(tester);
      },
    );

    testWidgets('a swipe starting in the system back-gesture edge is ignored', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls));
      // x = 22 is inside the 30 dp left system gesture inset.
      await _drag(tester, const Offset(22, 712), [
        const Offset(30, 0),
        const Offset(30, 0),
      ]);
      await _drag(tester, const Offset(338, 712), [
        const Offset(-30, 0),
        const Offset(-30, 0),
      ]);
      expect(calls.log, isEmpty);
      await tester.pump(const Duration(milliseconds: 300));
      await _drag(tester, const Offset(300, 712), [
        const Offset(-30, 0),
        const Offset(-30, 0),
      ]);
      expect(calls.log, ['projects']);
      await _finish(tester);
    });

    testWidgets('with Gestos off, swipes and swipe-up do nothing', (
      tester,
    ) async {
      _phone(tester);
      _c.resetForTesting(
        settings: const GestureDockSettings(welcomeSeen: true, gestures: false),
      );
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls));
      await _drag(tester, _barCenter, [
        const Offset(-30, 0),
        const Offset(-30, 0),
      ]);
      await tester.pump(const Duration(milliseconds: 300));
      await _drag(tester, _barCenter, [
        const Offset(0, -20),
        const Offset(0, -20),
      ]);
      expect(calls.log, isEmpty);
      await _finish(tester);
    });
  });

  group('swipe down hides', () {
    testWidgets('more than 32 dp hides and shows the accent line', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls));
      await _drag(tester, _barCenter, [
        const Offset(0, 15),
        const Offset(0, 15),
      ]);
      expect(_c.hidden.value, isFalse, reason: '30 dp');
      await tester.pump(const Duration(milliseconds: 300));
      await _drag(tester, _barCenter, [
        const Offset(0, 17),
        const Offset(0, 17),
      ]);
      expect(_c.hidden.value, isTrue);
      await tester.pump(const Duration(milliseconds: 400));
      expect(_barOpacity(tester), 0);
      final line = tester.widget<IgnorePointer>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('gesture-dock-line')),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );
      expect(line.ignoring, isFalse);
      await _finish(tester);
    });

    testWidgets('while dragging it follows the finger and fades to .25', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls));
      final gesture = await tester.startGesture(_barCenter);
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 25));
      await tester.pump();
      expect(_barTransform(tester).getTranslation().y, closeTo(45, .01));
      expect(_barOpacity(tester), closeTo(.5, .01));
      await gesture.moveBy(const Offset(0, 100));
      await tester.pump();
      expect(_barOpacity(tester), closeTo(.25, .01));
      await gesture.cancel();
      await _finish(tester);
    });

    testWidgets('fixed mode never hides', (tester) async {
      _phone(tester);
      _c.resetForTesting(
        settings: const GestureDockSettings(
          welcomeSeen: true,
          mode: DockHideMode.fixed,
        ),
      );
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls));
      // The bar does not even follow the finger down.
      final gesture = await tester.startGesture(_barCenter);
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
      expect(_barTransform(tester).getTranslation().y, 0);
      expect(_barOpacity(tester), 1);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_c.hidden.value, isFalse);
      expect(find.byKey(const ValueKey('gesture-dock-grab')), findsNothing);
      await _finish(tester);
    });

    testWidgets('the first hide shows the hint once; the grab handle leaves', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls));
      expect(find.byKey(const ValueKey('gesture-dock-grab')), findsOneWidget);
      _c.setHidden(true);
      _c.learn(DockGesture.hide);
      await tester.pump();
      expect(find.byKey(const ValueKey('gesture-dock-hint')), findsOneWidget);
      expect(_c.value.hideHintShown, isTrue);
      _c.setHidden(false);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('gesture-dock-hint')), findsNothing);
      expect(find.byKey(const ValueKey('gesture-dock-grab')), findsNothing);
      _c.setHidden(true);
      await tester.pump();
      expect(find.byKey(const ValueKey('gesture-dock-hint')), findsNothing);
      await _finish(tester);
    });

    testWidgets('with reduced motion the dock hides in one frame', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls, reduceMotion: true));
      _c.setHidden(true);
      await tester.pump();
      await tester.pump();
      expect(_barOpacity(tester), 0);
      await _finish(tester);
    });
  });

  group('hidden line', () {
    Future<void> hideFirst(WidgetTester tester, _Calls calls) async {
      await tester.pumpWidget(_dock(calls));
      _c.setHidden(true);
      await tester.pump(const Duration(milliseconds: 400));
    }

    // The line's touch area is centred at x 180, 24 dp + 17 above the
    // bottom edge.
    const line = Offset(180, 780 - 24 - 17);

    testWidgets('a tap (under 8 dp of movement) brings the dock back', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await hideFirst(tester, calls);
      await _drag(tester, line, [const Offset(5, 0)]);
      expect(_c.hidden.value, isFalse);
      expect(_c.value.learned, contains(DockGesture.show));
      expect(calls.log, isEmpty, reason: 'no tab under the line');
      await _finish(tester);
    });

    testWidgets('dragging it up more than 12 dp brings it back', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await hideFirst(tester, calls);
      await _drag(tester, line, [const Offset(9, 0)]);
      expect(_c.hidden.value, isTrue, reason: '9 dp sideways is no tap');
      await _drag(tester, line, [const Offset(0, -6), const Offset(0, -7)]);
      expect(_c.hidden.value, isFalse);
      await _finish(tester);
    });

    testWidgets('the hidden bar does not take taps', (tester) async {
      _phone(tester);
      final calls = _Calls();
      await hideFirst(tester, calls);
      await tester.tapAt(_tab(2));
      expect(calls.log, isEmpty);
      await _finish(tester);
    });
  });

  group('swipe up', () {
    testWidgets('more than 28 dp opens "Ir a"; 26 dp does not', (tester) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls));
      await _drag(tester, _barCenter, [
        const Offset(0, -13),
        const Offset(0, -13),
      ]);
      expect(calls.log, isEmpty);
      await tester.pump(const Duration(milliseconds: 300));
      await _drag(tester, _barCenter, [
        const Offset(0, -15),
        const Offset(0, -15),
      ]);
      expect(calls.log, ['goto']);
      expect(_c.value.learned, contains(DockGesture.up));
      await _finish(tester);
    });
  });

  group('long press', () {
    testWidgets('480 ms on a tab opens its shortcuts and no tap fires', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls));
      final gesture = await tester.startGesture(_tab(3));
      await tester.pump(const Duration(milliseconds: 470));
      expect(find.byKey(const ValueKey('gesture-dock-popover')), findsNothing);
      await tester.pump(const Duration(milliseconds: 20));
      expect(
        find.byKey(const ValueKey('gesture-dock-popover')),
        findsOneWidget,
      );
      await gesture.up();
      await tester.pump();
      expect(calls.log, isEmpty, reason: 'the release is not a tap');
      expect(_c.value.learned, contains(DockGesture.hold));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Atajo uno'));
      await tester.pump();
      expect(calls.log, ['shortcut']);
      expect(find.byKey(const ValueKey('gesture-dock-popover')), findsNothing);
      await _finish(tester);
    });

    testWidgets('moving past 9 dp before 480 ms cancels the long press', (
      tester,
    ) async {
      _phone(tester);
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls));
      final gesture = await tester.startGesture(_tab(3));
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveBy(const Offset(0, -12));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('gesture-dock-popover')), findsNothing);
      await gesture.up();
      await _finish(tester);
    });
  });

  group('accessibility', () {
    testWidgets('every gesture has a semantics action or a labelled button', (
      tester,
    ) async {
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

      await run('Pestaña siguiente');
      await run('Pestaña anterior');
      await run('Ir a…');
      expect(calls.log, ['settings', 'home', 'goto']);
      await run('Esconder el dock');
      expect(_c.hidden.value, isTrue);
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester.getSemantics(find.byKey(const ValueKey('gesture-dock-line'))),
        isSemantics(
          label: 'Mostrar el dock',
          isButton: true,
          hasTapAction: true,
        ),
      );
      tester.semantics.tap(find.semantics.byLabel('Mostrar el dock'));
      await tester.pump();
      expect(_c.hidden.value, isFalse);
      // While hidden the tabs are out of the semantics tree; once shown
      // again, a tab's long press is the shortcuts' equivalent.
      await tester.pump(const Duration(milliseconds: 400));
      tester.semantics.longPress(find.semantics.byLabel('Ajustes'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('gesture-dock-popover')),
        findsOneWidget,
      );
      handle.dispose();
      await _finish(tester);
    });

    testWidgets('the grab handle is a labelled button that hides the dock', (
      tester,
    ) async {
      _phone(tester);
      final handle = tester.ensureSemantics();
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls));
      expect(
        tester.getSemantics(find.byKey(const ValueKey('gesture-dock-grab'))),
        isSemantics(label: 'Esconder el dock', isButton: true),
      );
      tester.semantics.tap(find.semantics.byLabel('Esconder el dock'));
      await tester.pump();
      expect(_c.hidden.value, isTrue);
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

    testWidgets('the active tab glows in the theme accent', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _dock(_Calls(), current: GestureDockTab.projects),
      );
      final accent = AppTheme.fromId('dark').hermes.accent;
      final glow = find.descendant(
        of: find.byKey(const ValueKey('gesture-dock-tab-projects')),
        matching: find.byKey(const ValueKey('gesture-dock-glow')),
      );
      expect(glow, findsOneWidget);
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const ValueKey('gesture-dock-tab-projects')),
          matching: find.byType(Icon),
        ),
      );
      expect(icon.color, accent);
      expect(find.byKey(const ValueKey('gesture-dock-glow')), findsOneWidget);
      await _finish(tester);
    });
  });

  group('geometry', () {
    testWidgets('publishes the bar, then the line while hidden, then clears', (
      tester,
    ) async {
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
      final line = DockGeometry.instance.rect.value!;
      expect(DockGeometry.instance.hidden.value, isTrue);
      expect(line.bottom, 780 - 24);
      expect(line.center.dx, 180);
      await tester.pumpWidget(const SizedBox());
      expect(DockGeometry.instance.rect.value, isNull);
      await _finish(tester);
    });

    testWidgets('glass blur is clipped to the bar; opaque has no blur', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_dock(_Calls()));
      final blur = find.byType(BackdropFilter);
      expect(blur, findsOneWidget);
      expect(tester.getRect(blur), const Rect.fromLTWH(14, 682, 332, 60));
      expect(
        find.ancestor(of: blur, matching: find.byType(ClipRRect)),
        findsWidgets,
      );
      await _c.setOpaque(true);
      await tester.pump();
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byKey(const ValueKey('gesture-dock-opaque')), findsOneWidget);
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

  group('auto mode', () {
    Widget list() => GestureDockScrollRelay(
      child: _dock(
        _Calls(),
        body: ListView.builder(
          key: const ValueKey('list'),
          itemCount: 100,
          itemBuilder: (_, i) => SizedBox(height: 60, child: Text('row $i')),
        ),
      ),
    );

    testWidgets('scrolling down hides, scrolling up a little shows', (
      tester,
    ) async {
      _phone(tester);
      FeatureFlags.instance.resetForTesting(gestureDock: true);
      _c.resetForTesting(
        settings: const GestureDockSettings(
          welcomeSeen: true,
          mode: DockHideMode.auto,
        ),
      );
      await tester.pumpWidget(list());
      await tester.drag(
        find.byKey(const ValueKey('list')),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      expect(_c.hidden.value, isTrue);
      await tester.drag(
        find.byKey(const ValueKey('list')),
        const Offset(0, 40),
      );
      await tester.pumpAndSettle();
      expect(_c.hidden.value, isFalse);
      await _finish(tester);
    });

    testWidgets('manual mode and the flag off ignore scrolling', (
      tester,
    ) async {
      _phone(tester);
      FeatureFlags.instance.resetForTesting(gestureDock: true);
      await tester.pumpWidget(list());
      await tester.drag(
        find.byKey(const ValueKey('list')),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      expect(_c.hidden.value, isFalse, reason: 'manual is the default');
      FeatureFlags.instance.resetForTesting();
      await _c.setMode(DockHideMode.auto);
      await tester.drag(
        find.byKey(const ValueKey('list')),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      expect(_c.hidden.value, isFalse, reason: 'flag off');
      await _finish(tester);
    });
  });

  group('coach', () {
    testWidgets('welcome appears after 1.8 s on first run', (tester) async {
      _phone(tester);
      _c.resetForTesting();
      await tester.pumpWidget(_dock(_Calls()));
      await tester.pump(const Duration(milliseconds: 1700));
      expect(find.byKey(const ValueKey('gesture-dock-welcome')), findsNothing);
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        find.byKey(const ValueKey('gesture-dock-welcome')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('gesture-dock-welcome-later')),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('gesture-dock-welcome')), findsNothing);
      expect(_c.value.welcomeSeen, isTrue);
      await _finish(tester);
    });

    testWidgets('no welcome over a pending permission', (tester) async {
      _phone(tester);
      _c.resetForTesting();
      await tester.pumpWidget(_dock(_Calls(), needsYou: () => true));
      _c.needsYou = () => true;
      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(const ValueKey('gesture-dock-welcome')), findsNothing);
      await _finish(tester);
    });

    testWidgets('the welcome goes to the mascot when it takes it', (
      tester,
    ) async {
      _phone(tester);
      _c.resetForTesting();
      var asked = 0;
      GestureDockController.welcomePresenter = (_) {
        asked++;
        return true;
      };
      await tester.pumpWidget(_dock(_Calls()));
      await tester.pump(const Duration(seconds: 2));
      expect(asked, 1);
      expect(find.byKey(const ValueKey('gesture-dock-welcome')), findsNothing);
      await _finish(tester);
    });

    testWidgets('the tour advances only on the real gesture', (tester) async {
      _phone(tester);
      _c.resetForTesting();
      final calls = _Calls();
      await tester.pumpWidget(_dock(calls, current: GestureDockTab.projects));
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(
        find.byKey(const ValueKey('gesture-dock-welcome-teach')),
      );
      await tester.pump();
      expect(_c.tourStep.value, 0);
      expect(
        find.byKey(const ValueKey('gesture-dock-tour-scrim')),
        findsOneWidget,
      );
      expect(find.text('Paso 1 de 3'), findsOneWidget);
      // Tapping a tab is not the swipe the step asks for.
      await tester.tapAt(_tab(1));
      await tester.pump(const Duration(seconds: 1));
      expect(_c.tourStep.value, 0);
      await _drag(tester, _barCenter, [
        const Offset(-30, 0),
        const Offset(-30, 0),
      ]);
      expect(find.text('¡Muy bien!'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 800));
      expect(_c.tourStep.value, 1);
      // Wrong gesture for step 2 (hide): swipe up does not advance.
      await tester.pump(const Duration(milliseconds: 200));
      await _drag(tester, _barCenter, [
        const Offset(0, -20),
        const Offset(0, -20),
      ]);
      await tester.pump(const Duration(seconds: 1));
      expect(_c.tourStep.value, 1);
      await _drag(tester, _barCenter, [
        const Offset(0, 20),
        const Offset(0, 20),
      ]);
      await tester.pump(const Duration(milliseconds: 800));
      expect(_c.tourStep.value, 2);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tapAt(const Offset(180, 780 - 24 - 17));
      await tester.pump(const Duration(milliseconds: 800));
      expect(_c.tourStep.value, isNull);
      expect(_c.value.tourDone, isTrue);
      await _finish(tester);
    });

    testWidgets('Saltar ends the tour at any step', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_dock(_Calls()));
      _c.startTour();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('gesture-dock-tour-skip')));
      await tester.pump();
      expect(_c.tourStep.value, isNull);
      expect(_c.value.tourDone, isFalse);
      expect(_c.value.welcomeSeen, isTrue);
      await _finish(tester);
    });
  });
}
