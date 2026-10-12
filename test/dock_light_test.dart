// The light that passes behind the dock's icons when the selected place
// changes.
//
// Owner (2026-10-11): "estaría guapo un efecto dentro del dock como si la
// luz pasara por detrás y seleccionara dónde va", next to his earlier "sin
// el aura de luz, rollo mate, que se rellene de color el icono".
//
// So: the icon stays matte; when the selection changes a soft light glides
// INSIDE the bar, behind the icons, from the item the user was at to the
// one just picked, settles under it and goes out. At rest there is no
// light at all.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/dock_light.dart';
import 'package:hermes_android/core/shell/gesture_dock.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

GestureDockController get _c => GestureDockController.instance;
DockLight get _light => _c.light;

const _tabs = [
  GestureDockTab.home,
  GestureDockTab.create,
  GestureDockTab.search,
  GestureDockTab.bots,
  GestureDockTab.tools,
];

const _lightKey = ValueKey('gesture-dock-light');

Finder _item(GestureDockTab tab) =>
    find.byKey(ValueKey('gesture-dock-tab-${tab.name}')).hitTestable();

Widget _screen(
  GestureDockTab? current, {
  void Function(GestureDockTab tab)? onTab,
  bool reduceMotion = false,
  TextDirection direction = TextDirection.ltr,
}) => Builder(
  builder: (context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
    child: Directionality(
      textDirection: direction,
      child: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            Center(child: Text(current?.name ?? 'other')),
            GestureDock(
              current: current,
              onTab: {
                for (final tab in GestureDockTab.values)
                  if (tab != current) tab: () => onTab?.call(tab),
              },
              // A long press has somewhere to go, as in the app.
              onEdit: () {},
            ),
          ],
        ),
      ),
    ),
  ),
);

Widget _app(Widget home, {String theme = 'classic-dark'}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId(theme),
  home: home,
);

void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.viewPadding = const FakeViewPadding(bottom: 72);
  tester.view.padding = const FakeViewPadding(bottom: 72);
  addTearDown(tester.view.reset);
}

/// The bar, and the light's box in the bar's own coordinates, now.
({Rect bar, Rect light}) _measure(WidgetTester tester) {
  final paint = find.byKey(_lightKey).last;
  final box = tester.renderObject<RenderBox>(paint);
  final painter =
      tester.widget<CustomPaint>(paint).painter! as DockLightPainter;
  return (bar: Offset.zero & box.size, light: painter.rectFor(box.size));
}

/// Centre of [tab]'s slot in the bar's coordinates.
double _slotCenter(WidgetTester tester, GestureDockTab tab) {
  final bar = tester.renderObject<RenderBox>(find.byKey(_lightKey).last);
  final item = tester.getCenter(
    find.byKey(ValueKey('gesture-dock-tab-${tab.name}')).last,
  );
  return bar.globalToLocal(item).dx;
}

bool _inside(Rect outer, Rect inner) =>
    inner.left >= outer.left &&
    inner.right <= outer.right &&
    inner.top >= outer.top &&
    inner.bottom <= outer.bottom;

/// Pumps one frame at a time until the light is still, checking it on
/// every frame. Returns each frame's (position, strength).
Future<List<(double, double)>> _watch(
  WidgetTester tester, {
  int maxFrames = 120,
}) async {
  final frames = <(double, double)>[];
  for (var i = 0; i < maxFrames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    final m = _measure(tester);
    expect(
      _inside(m.bar, m.light),
      isTrue,
      reason: 'frame $i: ${m.light} is outside the bar ${m.bar}',
    );
    expect(_light.strength, inInclusiveRange(0, 1));
    frames.add((_light.position, _light.strength));
    if (!_light.moving) break;
  }
  expect(_light.moving, isFalse, reason: 'the light came to rest');
  return frames;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FeatureFlags.instance.resetForTesting(gestureDock: true);
    _c.resetForTesting(settings: const GestureDockSettings(tabs: _tabs));
    DockGeometry.instance.resetForTesting();
  });

  tearDown(FeatureFlags.instance.resetForTesting);

  group('a glide', () {
    testWidgets('from the item you were at to the one you tap: inside the '
        'bar on every frame, centred on the item at the end, then dark', (
      tester,
    ) async {
      _phone(tester);
      GestureDockTab current = GestureDockTab.home;
      late StateSetter rebuild;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return _screen(current, onTab: (tab) => current = tab);
            },
          ),
        ),
      );
      await tester.pump();
      // At rest: no light, under the selected item.
      expect(_light.strength, 0);
      expect(_light.moving, isFalse);
      expect(_light.target, 0);
      expect(
        _measure(tester).light.center.dx,
        moreOrLessEquals(_slotCenter(tester, GestureDockTab.home)),
      );

      await tester.tap(_item(GestureDockTab.tools));
      // The light left on the tap, before the next screen is there.
      expect(_light.moving, isTrue);
      expect(_light.target, 4);
      rebuild(() {});
      final frames = await _watch(tester);

      // One glide, forwards only, in the app's page duration.
      final positions = [for (final f in frames) f.$1];
      for (var i = 1; i < positions.length; i++) {
        expect(positions[i], greaterThanOrEqualTo(positions[i - 1]));
      }
      expect(positions.first, lessThan(1), reason: 'it starts where it was');
      final arrived = positions.indexWhere((p) => p > 3.999);
      expect((arrived + 1) * 16, inInclusiveRange(240, 320));
      // Lit while it travels.
      expect(frames[arrived ~/ 2].$2, greaterThan(.9));
      // It ends centred on the item, and dark.
      expect(_light.position, 4);
      expect(_light.strength, 0);
      expect(
        _measure(tester).light.center.dx,
        moreOrLessEquals(_slotCenter(tester, GestureDockTab.tools)),
      );
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a second tap mid-flight starts from where the light is: no '
        'jump, no way back, no bounce', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(_screen(GestureDockTab.home)));
      await tester.pump();
      await tester.tap(_item(GestureDockTab.tools));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final reached = _light.position;
      final lit = _light.strength;
      expect(reached, inExclusiveRange(1, 4));

      await tester.tap(_item(GestureDockTab.search));
      expect(_light.position, reached, reason: 'no restart from the origin');
      expect(_light.strength, lit, reason: 'it does not blink');
      expect(_light.target, 2);
      final frames = await _watch(tester);
      final positions = [reached, for (final f in frames) f.$1];
      for (var i = 1; i < positions.length; i++) {
        expect(
          positions[i],
          lessThanOrEqualTo(positions[i - 1]),
          reason: 'straight to the new item, never past it and back',
        );
        expect(positions[i], greaterThanOrEqualTo(2));
      }
      expect(_light.position, 2);
      expect(_light.strength, 0);
    });

    testWidgets('tapping the same item again restarts nothing', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(_screen(GestureDockTab.home)));
      await tester.pump();
      await tester.tap(_item(GestureDockTab.bots));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final reached = _light.position;
      await tester.tap(_item(GestureDockTab.bots));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_light.position, greaterThan(reached));
      await _watch(tester);
      expect(_light.position, 3);
    });

    testWidgets('right-to-left: the light is under the item as drawn', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(
        _app(_screen(GestureDockTab.home, direction: TextDirection.rtl)),
      );
      await tester.pump();
      expect(
        _measure(tester).light.center.dx,
        moreOrLessEquals(_slotCenter(tester, GestureDockTab.home)),
      );
      await tester.tap(_item(GestureDockTab.tools));
      await _watch(tester);
      expect(
        _measure(tester).light.center.dx,
        moreOrLessEquals(_slotCenter(tester, GestureDockTab.tools)),
      );
    });
  });

  group('what does not move it', () {
    testWidgets('an action ("Nuevo") leaves the light where it is', (
      tester,
    ) async {
      _phone(tester);
      final taps = <GestureDockTab>[];
      await tester.pumpWidget(
        _app(_screen(GestureDockTab.search, onTab: taps.add)),
      );
      await tester.pump();
      await tester.tap(_item(GestureDockTab.create));
      await tester.pump(const Duration(milliseconds: 16));
      expect(taps, [GestureDockTab.create]);
      expect(_light.moving, isFalse);
      expect(_light.strength, 0);
      expect(_light.position, 2);
      expect(_light.target, 2);
    });

    testWidgets('a long press and a slide over the bar leave it too', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(_screen(GestureDockTab.search)));
      await tester.pump();
      final hold = await tester.startGesture(
        tester.getCenter(_item(GestureDockTab.tools)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await hold.up();
      await tester.pump();
      final slide = await tester.startGesture(
        tester.getCenter(_item(GestureDockTab.home)),
      );
      await slide.moveBy(const Offset(120, 0));
      await slide.up();
      await tester.pump();
      expect(_light.moving, isFalse);
      expect(_light.position, 2);
      expect(_light.strength, 0);
    });

    testWidgets('reduced motion: the selection just changes, with no frame in '
        'between and no light', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _app(_screen(GestureDockTab.home, reduceMotion: true)),
      );
      await tester.pump();
      final seen = <double>{_light.position};
      void record() {
        seen.add(_light.position);
        expect(_light.strength, 0);
      }

      _light.addListener(record);
      addTearDown(() => _light.removeListener(record));
      await tester.tap(_item(GestureDockTab.tools));
      expect(_light.position, 4);
      expect(_light.moving, isFalse);
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(seen, {0.0, 4.0});
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });

  group('across screens', () {
    Widget screens(GlobalKey<NavigatorState> navigator) => MaterialApp(
      navigatorKey: navigator,
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('classic-dark'),
      home: _screen(
        GestureDockTab.home,
        onTab: (tab) => navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) =>
                _screen(tab == GestureDockTab.projects ? null : tab),
          ),
        ),
      ),
    );

    testWidgets('the glide that starts under the finger goes on in the dock '
        'of the screen that opens, and comes back with Back', (tester) async {
      _phone(tester);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(screens(navigator));
      await tester.pump();

      await tester.tap(_item(GestureDockTab.bots));
      final positions = <double>[_light.position];
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        positions.add(_light.position);
        final m = _measure(tester);
        expect(_inside(m.bar, m.light), isTrue);
      }
      // The new screen's dock mounted mid-glide and restarted nothing.
      expect(find.text('bots'), findsOneWidget);
      for (var i = 1; i < positions.length; i++) {
        expect(positions[i], greaterThanOrEqualTo(positions[i - 1]));
      }
      expect(_light.position, 3);
      expect(_light.strength, 0);

      // Back: Home's dock is in view again and the light returns to Inicio.
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(_light.target, 0);
      expect(_light.moving, isTrue);
      await tester.pumpAndSettle();
      expect(_light.position, 0);
      expect(_light.strength, 0);
    });

    testWidgets('a screen that is no item of the dock: no item is selected '
        'and there is no light; the next place lights up where it is, '
        'without a glide', (tester) async {
      _phone(tester);
      _c.resetForTesting(
        settings: const GestureDockSettings(
          tabs: [
            GestureDockTab.home,
            GestureDockTab.projects,
            GestureDockTab.search,
            GestureDockTab.bots,
            GestureDockTab.tools,
          ],
        ),
      );
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(screens(navigator));
      await tester.pump();
      // Proyectos opens a screen that is no item here (see `screens`).
      await tester.tap(_item(GestureDockTab.projects));
      await tester.pumpAndSettle();
      expect(find.text('other'), findsOneWidget);
      expect(_light.target, isNull, reason: 'no item is selected');
      expect(_light.strength, 0);
      expect(_light.moving, isFalse);

      // From there, Bots: nothing to come from, so no travel.
      await tester.tap(_item(GestureDockTab.bots));
      expect(_light.position, 3);
      expect(_light.target, 3);
      final positions = <double>{};
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        positions.add(_light.position);
      }
      expect(positions, {3.0});
      expect(_light.strength, 0);
    });
  });

  group('drawn inside the bar, cheaply', () {
    testWidgets('behind the icons, inside the bar\'s clip, with no blur of '
        'its own; the same on the solid surface', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(_screen(GestureDockTab.home)));
      await tester.pump();
      final light = find.byKey(_lightKey);
      expect(light, findsOneWidget);
      final bar = tester.getRect(
        find.byKey(const ValueKey('gesture-dock-glass')),
      );
      expect(tester.getRect(light), bar);
      expect(
        tester.getRect(
          find.ancestor(of: light, matching: find.byType(ClipRRect)).first,
        ),
        bar,
        reason: 'the nearest clip is the bar\'s own pill',
      );
      // Painted before the icons of the same bar.
      const home = ValueKey('gesture-dock-tab-home');
      final order = [
        for (final element
            in find
                .descendant(
                  of: find.byKey(const ValueKey('gesture-dock-glass')),
                  matching: find.byWidgetPredicate(
                    (w) => w.key == _lightKey || w.key == home,
                  ),
                )
                .evaluate())
          element.widget.key,
      ];
      expect(order, [_lightKey, home]);
      // Its own layer, nothing that filters.
      expect(
        find.ancestor(of: light, matching: find.byType(RepaintBoundary)),
        findsWidgets,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('gesture-dock-glass')),
          matching: find.byWidgetPredicate(
            (w) => w is BackdropFilter || w is ImageFiltered,
          ),
        ),
        findsNothing,
      );
      // The bar itself no longer blurs what is behind it either.
      expect(find.byType(BackdropFilter), findsNothing);

      await _c.setOpaque(true);
      await tester.pump();
      expect(find.byType(BackdropFilter), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('gesture-dock-opaque')),
          matching: find.byKey(_lightKey),
        ),
        findsOneWidget,
      );
      await tester.tap(_item(GestureDockTab.tools));
      await _watch(tester);
      expect(_light.position, 4);
    });

    testWidgets('a glide repaints the light and rebuilds nothing', (
      tester,
    ) async {
      _phone(tester);
      var builds = 0;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              builds++;
              return _screen(GestureDockTab.home);
            },
          ),
        ),
      );
      await tester.pump();
      final before = builds;
      final dock = tester.element(find.byType(GestureDock));
      var dockBuilds = 0;
      void count(Element element) {
        if (element.dirty) dockBuilds++;
        element.visitChildren(count);
      }

      await tester.tap(_item(GestureDockTab.tools));
      // The pressed item springs back for 120 ms (its own small rebuild).
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(_light.moving, isTrue);
      var frames = 0;
      while (_light.moving) {
        // Nothing under the dock is dirty when a frame is about to draw.
        count(dock);
        await tester.pump(const Duration(milliseconds: 16));
        frames++;
      }
      expect(frames, greaterThan(20));
      expect(builds, before);
      expect(dockBuilds, 0);
    });

    testWidgets('with no dock on screen nothing ticks', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(_screen(GestureDockTab.home)));
      await tester.pump();
      await tester.tap(_item(GestureDockTab.tools));
      await tester.pump(const Duration(milliseconds: 32));
      expect(_light.moving, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(_light.moving, isFalse);
      expect(_light.strength, 0);
      expect(_light.position, 4, reason: 'it ends where it was going');
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    test('the light\'s box fits the bar for any number of items, at both '
        'ends and in between', () {
      for (final width in [240.0, 332.0, 362.0, 600.0]) {
        for (var slots = 2; slots <= 5; slots++) {
          for (var p = 0.0; p <= slots - 1; p += .125) {
            for (final rtl in [false, true]) {
              final size = Size(width, 60);
              final rect = dockLightRect(
                size,
                slots: slots,
                position: p,
                rtl: rtl,
                inset: 6,
              );
              expect(
                _inside(Offset.zero & size, rect),
                isTrue,
                reason: '$width dp, $slots items, at $p',
              );
              expect(
                rect.width,
                lessThanOrEqualTo(DockLightPainter.maxWidth + 1e-9),
              );
            }
          }
        }
      }
    });
  });

  group('the model', () {
    test('timing comes from the app\'s motion catalogue', () {
      expect(DockLight.travel, const Duration(milliseconds: 260));
      expect(DockLight.curve, Curves.easeOutCubic);
    });

    testWidgets('the first place after a cold start is taken without light', (
      tester,
    ) async {
      final light = DockLight();
      expect(light.target, isNull);
      light.settle(2, animate: true);
      expect(light.target, 2);
      expect(light.position, 2);
      expect(light.strength, 0);
      expect(light.moving, isFalse);
      light.dispose();
    });

    testWidgets('going out mid-glide: it fades where it is, in the base '
        'duration', (tester) async {
      final light = DockLight();
      light.settle(0, animate: true);
      light.moveTo(4, animate: true);
      for (var i = 0; i < 9; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final at = light.position;
      final lit = light.strength;
      expect(at, inExclusiveRange(0, 4));
      expect(lit, greaterThan(.5));
      light.settle(null, animate: true);
      expect(light.target, isNull);
      var previous = lit;
      var frames = 0;
      while (light.moving) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(light.position, at, reason: 'it does not travel on');
        expect(light.strength, lessThanOrEqualTo(previous));
        previous = light.strength;
        frames++;
      }
      expect(light.strength, 0);
      expect(frames * 16, inInclusiveRange(180, 240));
      light.dispose();
    });

    testWidgets('a new layout puts it under the item without a glide', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(_screen(GestureDockTab.tools)));
      await tester.pump();
      expect(_light.position, 4);
      await _c.setTabs([
        GestureDockTab.home,
        GestureDockTab.tools,
        GestureDockTab.search,
      ]);
      await tester.pump();
      expect(_light.position, 1);
      expect(_light.target, 1);
      expect(_light.moving, isFalse);
      expect(_light.strength, 0);
    });
  });
}
