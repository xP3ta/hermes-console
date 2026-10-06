import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/mascot/float/mascot_float_physics.dart';
import 'package:hermes_android/core/widgets/mascot/float/mascot_overlay.dart';
import 'package:hermes_android/core/widgets/mascot/float/mascot_prefs.dart';
import 'package:hermes_android/core/widgets/mascot/float/mascot_route_watch.dart';
import 'package:hermes_android/core/widgets/mascot/float/mascot_settings_screen.dart';
import 'package:hermes_android/core/widgets/mascot/float/mascot_sources.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_sprite.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_state.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _theme = AppTheme.hermesRedDark;
const _screen = Size(360, 780);
const _size = MascotFloatPhysics.spriteSize;
final _dock = Rect.fromLTWH(14, 690, 332, 60);
final _line = Rect.fromLTWH(152, 756, 56, 5);
final _owner = Object();

class _Harness {
  _Harness({
    List<MascotPermission> permissions = const [],
    bool cardVisible = false,
    List<MascotSuggestion> suggestions = const [],
  }) : permissions = ValueNotifier(permissions),
       cardVisible = ValueNotifier(cardVisible),
       suggestions = ValueNotifier(suggestions);

  final prefs = MascotPrefs();
  final geometry = DockGeometry();
  final watch = MascotRouteWatch();
  final locked = ValueNotifier<bool>(false);
  final reduce = ValueNotifier<bool>(false);
  final activity = ValueNotifier<MascotState>(MascotState.idle);
  final ValueNotifier<List<MascotPermission>> permissions;
  final ValueNotifier<bool> cardVisible;
  final ValueNotifier<List<MascotSuggestion>> suggestions;
  final navigator = GlobalKey<NavigatorState>();
  int settingsOpened = 0;

  late final sources = MascotSources(
    permissions: permissions,
    needsCardVisible: cardVisible,
    suggestions: suggestions,
    activity: activity,
  );

  Widget app({Widget? body}) => MaterialApp(
    navigatorKey: navigator,
    theme: _theme,
    locale: const Locale('es'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    navigatorObservers: [watch],
    builder: (context, nav) => ValueListenableBuilder<bool>(
      valueListenable: reduce,
      builder: (context, reduced, _) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: MascotOverlayHost(
          prefs: prefs,
          sources: sources,
          geometry: geometry,
          routeWatch: watch,
          locked: locked,
          actions: MascotOverlayActions(onSettings: () => settingsOpened++),
          child: nav!,
        ),
      ),
    ),
    home: Scaffold(
      body:
          body ??
          ListView(
            key: const ValueKey('list'),
            children: [
              // The Inicio "Te necesita" card reads the same source.
              ValueListenableBuilder<List<MascotPermission>>(
                valueListenable: permissions,
                builder: (context, items, _) => Column(
                  children: [
                    for (final item in items)
                      Text('card:${item.title}', key: ValueKey(item.key)),
                  ],
                ),
              ),
              for (var i = 0; i < 60; i++)
                SizedBox(height: 60, child: Text('row $i')),
            ],
          ),
    ),
  );
}

Future<_Harness> _pump(
  WidgetTester tester, {
  _Harness? harness,
  bool dock = true,
}) async {
  tester.view.physicalSize = _screen * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final h = harness ?? _Harness();
  if (dock) h.geometry.publish(_owner, _dock, hidden: false);
  await tester.pumpWidget(h.app());
  await tester.pump();
  await tester.pump();
  return h;
}

Rect _box(WidgetTester tester) =>
    tester.getRect(find.byKey(const ValueKey('mascot-overlay-sprite')));

Future<void> _settle(WidgetTester tester, [int ms = 1200]) async {
  for (var t = 0; t < ms; t += 16) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

MascotPermission _permission(
  ValueNotifier<List<MascotPermission>> list,
  List<bool> answers,
) {
  late final MascotPermission p;
  p = MascotPermission(
    key: 'p1',
    title: 'Login tests',
    command: 'git push origin fix/login-tests',
    resolve: (allow) async {
      answers.add(allow);
      list.value = [
        for (final x in list.value)
          if (x.key != p.key) x,
      ];
    },
  );
  return p;
}

void main() {
  setUp(() {
    debugMascotOverlayRandom = () => math.Random(7);
    SharedPreferences.setMockInitialValues({});
    FeatureFlags.floatingMascot = true;
    debugMascotSpritesStill = true;
  });
  tearDown(() {
    FeatureFlags.floatingMascot = false;
  });

  group('physics', () {
    test('edge snap: closer than 46 px goes to 6 px', () {
      expect(MascotFloatPhysics.snapLeft(30, _size, 360), 6);
      expect(MascotFloatPhysics.snapLeft(45.9, _size, 360), 6);
      expect(MascotFloatPhysics.snapLeft(46, _size, 360), 46);
      expect(MascotFloatPhysics.snapLeft(150, _size, 360), 150);
      expect(
        MascotFloatPhysics.snapLeft(360 - _size - 40, _size, 360),
        360 - _size - 6,
      );
    });

    test('fall: gravity 2600 px/s², bounce x0.34, at most 3 bounces', () {
      final fall = MascotFall(startTop: 100, floorTop: 700);
      // Free fall: h = g t² / 2.
      expect(fall.topAt(0.1), closeTo(100 + 0.5 * 2600 * 0.01, 0.01));
      expect(fall.bounces, inInclusiveRange(1, 3));
      final heights = fall.bounceHeights;
      expect(heights.first, closeTo(600 * 0.34 * 0.34, 0.5));
      for (var i = 1; i < heights.length; i++) {
        expect(heights[i] / heights[i - 1], closeTo(0.34 * 0.34, 0.001));
      }
      expect(fall.topAt(fall.duration + 1), 700);
      final tall = MascotFall(startTop: 0, floorTop: 5000);
      expect(tall.bounces, 3);
    });

    test('lands on the dock only over it', () {
      expect(
        MascotFloatPhysics.landsOnDock(mascotBox(100, 700), _dock),
        isTrue,
      );
      expect(
        MascotFloatPhysics.landsOnDock(mascotBox(100, 600), _dock),
        isTrue,
      );
      expect(
        MascotFloatPhysics.landsOnDock(mascotBox(100, 500), _dock),
        isFalse,
      );
      expect(
        MascotFloatPhysics.landsOnDock(mascotBox(-40, 700), _dock),
        isFalse,
      );
      expect(
        MascotFloatPhysics.landsOnDock(mascotBox(100, 700), null),
        isFalse,
      );
    });
  });

  group('feature flag', () {
    testWidgets('off: nothing is mounted, read or scheduled', (tester) async {
      FeatureFlags.floatingMascot = false;
      final h = await _pump(tester);
      expect(find.byType(MascotOverlay), findsNothing);
      expect(find.byType(MascotSprite), findsNothing);
      // The host hands the navigator back untouched: no Stack, no
      // scroll listener between them.
      expect(
        find.ancestor(of: find.byType(Navigator), matching: find.byType(Stack)),
        findsNothing,
      );
      expect(h.prefs.loaded, isFalse);
      expect(debugMascotOverlayTimers, 0);
      expect(find.text('row 0'), findsOneWidget);
    });
  });

  group('dock placement', () {
    testWidgets('stands on the dock top edge, never inside it', (tester) async {
      await _pump(tester);
      final box = _box(tester);
      expect(box.bottom, _dock.top + MascotFloatPhysics.dockOverlap);
      expect(box.bottom - _dock.top, lessThanOrEqualTo(2));
    });

    testWidgets('drops onto the line when the dock hides', (tester) async {
      final h = await _pump(tester);
      h.geometry.publish(_owner, _line, hidden: true);
      await _settle(tester, 600);
      expect(_box(tester).bottom, _line.top + MascotFloatPhysics.dockOverlap);
    });

    testWidgets('without a dock it stands above the bottom inset', (
      tester,
    ) async {
      await _pump(tester, dock: false);
      expect(
        _box(tester).bottom,
        _screen.height - MascotFloatPhysics.noDockLift,
      );
    });
  });

  group('drag', () {
    testWidgets('under 7 px is a tap (menu), not a drag', (tester) async {
      await _pump(tester);
      final before = _box(tester);
      final g = await tester.startGesture(before.center);
      await g.moveBy(const Offset(5, -1));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(_box(tester), before);
      expect(find.byKey(const ValueKey('mascot-menu-hide')), findsOneWidget);
    });

    testWidgets('a drag moves it, snaps to an edge and floats there', (
      tester,
    ) async {
      final h = await _pump(tester);
      final start = _box(tester).center;
      final g = await tester.startGesture(start);
      await g.moveTo(const Offset(60, 300));
      await tester.pump();
      await g.moveTo(const Offset(50, 300));
      await tester.pump();
      await g.up();
      await _settle(tester, 600);
      expect(find.byKey(const ValueKey('mascot-menu-hide')), findsNothing);
      expect(_box(tester).left, MascotFloatPhysics.edgeMargin);
      expect(_box(tester).center.dy, closeTo(300, 1));
      expect(h.prefs.placement, MascotPlacement.float);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(MascotPrefs.placementKey), 'float');
      expect(prefs.getStringList(MascotPrefs.positionKey), isNotNull);
    });

    testWidgets('dropped over the dock it falls with gravity and sticks', (
      tester,
    ) async {
      final h = await _pump(tester);
      final g = await tester.startGesture(_box(tester).center);
      await g.moveTo(const Offset(180, 200));
      await tester.pump();
      await g.moveTo(Offset(180, _dock.top - 100));
      await tester.pump();
      await g.up();
      final floor = _dock.top + MascotFloatPhysics.dockOverlap - _size;
      // It accelerates downwards (gravity), never through the floor.
      final tops = <double>[_box(tester).top];
      for (var i = 0; i < 5; i++) {
        await tester.pump(MascotFloatPhysics.frame);
        tops.add(_box(tester).top);
      }
      for (var i = 2; i < tops.length; i++) {
        expect(tops[i] - tops[i - 1], greaterThan(tops[i - 1] - tops[i - 2]));
      }
      expect(tops.every((t) => t <= floor + 0.01), isTrue);
      await _settle(tester, 1500);
      expect(_box(tester).top, floor);
      expect(h.prefs.placement, MascotPlacement.dock);
    });

    testWidgets('a floating mascot under a reappearing dock steps aside', (
      tester,
    ) async {
      final h = _Harness();
      SharedPreferences.setMockInitialValues({
        MascotPrefs.placementKey: 'float',
        MascotPrefs.positionKey: ['0.4', '0.9'],
      });
      await _pump(tester, harness: h, dock: false);
      expect(_box(tester).overlaps(_dock), isTrue);
      h.geometry.publish(_owner, _dock, hidden: false);
      await tester.pump();
      await _settle(tester, 700);
      expect(_box(tester).overlaps(_dock), isFalse);
      expect(_box(tester).bottom, lessThanOrEqualTo(_dock.top));
    });
  });

  group('scroll', () {
    testWidgets('28 % opacity and no hits for 700 ms after a scroll', (
      tester,
    ) async {
      await _pump(tester);
      Opacity opacity() =>
          tester.widget(find.byKey(const ValueKey('mascot-overlay-opacity')));
      expect(opacity().opacity, 1);
      await tester.drag(
        find.byKey(const ValueKey('list')),
        const Offset(0, -200),
      );
      await tester.pump();
      expect(opacity().opacity, MascotFloatPhysics.scrollOpacity);
      final ignore = tester.widget<IgnorePointer>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('mascot-overlay-opacity')),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );
      expect(ignore.ignoring, isTrue);
      await tester.pump(const Duration(milliseconds: 650));
      expect(opacity().opacity, MascotFloatPhysics.scrollOpacity);
      await tester.pump(const Duration(milliseconds: 100));
      expect(opacity().opacity, 1);
    });
  });

  group('permissions', () {
    testWidgets('one event: answering in the bubble clears the card too', (
      tester,
    ) async {
      final answers = <bool>[];
      final h = _Harness();
      h.permissions.value = [_permission(h.permissions, answers)];
      await _pump(tester, harness: h);
      expect(find.text('card:Login tests'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('mascot-overlay-badge')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('mascot-overlay-sprite')));
      await tester.pump();
      expect(find.text('git push origin fix/login-tests'), findsOneWidget);
      await tester.tap(find.text('Permitir'));
      await tester.pump();
      expect(answers, [true]);
      expect(find.text('card:Login tests'), findsNothing);
      expect(find.byKey(const ValueKey('mascot-overlay-bubble')), findsNothing);
      expect(find.byKey(const ValueKey('mascot-overlay-badge')), findsNothing);
    });

    testWidgets('answering on the card closes the mascot bubble', (
      tester,
    ) async {
      final answers = <bool>[];
      final h = _Harness();
      final p = _permission(h.permissions, answers);
      h.permissions.value = [p];
      await _pump(tester, harness: h);
      await tester.tap(find.byKey(const ValueKey('mascot-overlay-sprite')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('mascot-overlay-bubble')),
        findsOneWidget,
      );
      await p.resolve(false); // the card's "Rechazar"
      await tester.pump();
      expect(find.byKey(const ValueKey('mascot-overlay-bubble')), findsNothing);
    });

    testWidgets('with the Inicio card on screen it only hops and counts', (
      tester,
    ) async {
      final h = _Harness(cardVisible: true);
      h.permissions.value = [_permission(h.permissions, [])];
      await _pump(tester, harness: h);
      final before = debugMascotOverlayFrames;
      await tester.tap(find.byKey(const ValueKey('mascot-overlay-sprite')));
      await tester.pump();
      await _settle(tester, 400);
      expect(find.byKey(const ValueKey('mascot-overlay-bubble')), findsNothing);
      expect(
        find.byKey(const ValueKey('mascot-overlay-badge')),
        findsOneWidget,
      );
      expect(debugMascotOverlayFrames, greaterThan(before)); // the hop
    });
  });

  group('menu and off', () {
    testWidgets('Ocultarme turns it off; permissions stay as cards', (
      tester,
    ) async {
      final h = _Harness();
      await _pump(tester, harness: h);
      await tester.tap(find.byKey(const ValueKey('mascot-overlay-sprite')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('mascot-menu-hide')));
      await tester.pump();
      expect(find.byType(MascotOverlay), findsNothing);
      expect(debugMascotOverlayTimers, 0);
      expect(h.prefs.enabled, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(MascotPrefs.enabledKey), isFalse);
      h.permissions.value = [_permission(h.permissions, [])];
      await tester.pump();
      expect(find.text('card:Login tests'), findsOneWidget);
    });

    testWidgets('menu items and the settings action', (tester) async {
      final h = await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('mascot-overlay-sprite')));
      await tester.pump();
      for (final label in [
        '¿Qué haces?',
        'Sugiéreme algo',
        'Dejarme flotar',
        'Ajustes de la mascota',
        'Ocultarme',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await tester.tap(find.text('Sugiéreme algo'));
      await tester.pump();
      // No server suggestions: it says so, it never invents one.
      expect(find.text('No tengo sugerencias ahora.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 7));
      expect(find.byKey(const ValueKey('mascot-overlay-bubble')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('mascot-overlay-sprite')));
      await tester.pump();
      await tester.tap(find.text('Ajustes de la mascota'));
      await tester.pump();
      expect(h.settingsOpened, 1);
    });

    testWidgets('a server suggestion opens on tap and closes after 9 s', (
      tester,
    ) async {
      var accepted = 0;
      final h = _Harness(
        suggestions: [
          MascotSuggestion(
            key: 's',
            text: 'Resumen de hoy listo',
            actionLabel: 'Ver',
            onAction: () => accepted++,
          ),
        ],
      );
      await _pump(tester, harness: h);
      await tester.tap(find.byKey(const ValueKey('mascot-overlay-sprite')));
      await tester.pump();
      expect(find.text('Resumen de hoy listo'), findsOneWidget);
      await tester.pump(const Duration(seconds: 9));
      expect(find.text('Resumen de hoy listo'), findsNothing);
      expect(accepted, 0);
    });
  });

  group('gesture welcome', () {
    testWidgets('the dock welcome speaks through the mascot bubble', (
      tester,
    ) async {
      final h = await _pump(tester);
      final presenter = GestureDockController.welcomePresenter;
      expect(presenter, isNotNull);
      final controller = GestureDockController();
      expect(presenter!(controller), isTrue);
      await tester.pump();
      expect(find.text('¿Te enseño a moverte por aquí?'), findsOneWidget);
      await tester.tap(find.text('Prefiero sin mascota'));
      await tester.pump();
      expect(controller.value.welcomeSeen, isTrue);
      expect(h.prefs.enabled, isFalse);
      expect(find.byType(MascotOverlay), findsNothing);
      // Unmounted: the dock shows its own card again.
      expect(GestureDockController.welcomePresenter, isNull);
    });

    testWidgets('hidden mascot declines, so the dock shows its card', (
      tester,
    ) async {
      final h = await _pump(tester);
      h.locked.value = true;
      await tester.pump();
      expect(
        GestureDockController.welcomePresenter!(GestureDockController()),
        isFalse,
      );
    });
  });

  group('hidden and paused', () {
    Future<void> expectStill(WidgetTester tester) async {
      final before = debugMascotOverlayFrames;
      await _settle(tester, 20000);
      expect(debugMascotOverlayFrames, before);
      expect(debugMascotOverlayTimers, 0);
    }

    testWidgets('locked: hidden, no timers', (tester) async {
      final h = await _pump(tester);
      h.locked.value = true;
      await tester.pump();
      expect(find.byKey(const ValueKey('mascot-overlay-sprite')), findsNothing);
      await expectStill(tester);
    });

    testWidgets('a dialog on top hides it', (tester) async {
      final h = await _pump(tester);
      unawaited(
        showDialog<void>(
          context: h.navigator.currentContext!,
          builder: (_) => const AlertDialog(content: Text('dialog')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mascot-overlay-sprite')), findsNothing);
      h.navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mascot-overlay-sprite')),
        findsOneWidget,
      );
    });

    testWidgets('a chat header mascot hides it (no second mascot)', (
      tester,
    ) async {
      final h = await _pump(tester);
      h.navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(
            body: MascotSprite(state: MascotState.idle, header: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mascot-overlay-sprite')), findsNothing);
      h.navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mascot-overlay-sprite')),
        findsOneWidget,
      );
    });

    testWidgets('background: no timers', (tester) async {
      await _pump(tester);
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
      await expectStill(tester);
      for (final s in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
    });

    testWidgets('reduced motion: still, and a drop lands without a fall', (
      tester,
    ) async {
      final h = _Harness();
      h.reduce.value = true;
      await _pump(tester, harness: h);
      await expectStill(tester);
      final g = await tester.startGesture(_box(tester).center);
      await g.moveTo(const Offset(180, 200));
      await tester.pump();
      await g.moveTo(Offset(180, _dock.top - 100));
      await tester.pump();
      await g.up();
      await tester.pump();
      // No fall animation: it is on the dock in the next frame.
      expect(_box(tester).bottom, _dock.top + MascotFloatPhysics.dockOverlap);
    });
  });

  group('frame budget', () {
    testWidgets('wanders at ≤ 30 fps, then sleeps: 0 frames, 0 timers', (
      tester,
    ) async {
      await _pump(tester);
      final frames = <int>[];
      var t = 0;
      while (t < 16000) {
        final before = debugMascotOverlayFrames;
        await tester.pump(const Duration(milliseconds: 10));
        t += 10;
        if (debugMascotOverlayFrames > before) frames.add(t);
      }
      var best = 0;
      for (var i = 0; i < frames.length; i++) {
        best = [
          best,
          frames.where((f) => f >= frames[i] && f < frames[i] + 1000).length,
        ].reduce((a, b) => a > b ? a : b);
      }
      expect(frames, isNotEmpty); // it did wander
      expect(best, lessThanOrEqualTo(30));
      // Asleep after 16 s without interaction while Hermes is idle.
      await _settle(tester, 4000);
      final before = debugMascotOverlayFrames;
      await _settle(tester, 15000);
      expect(debugMascotOverlayFrames, before);
      expect(debugMascotOverlayTimers, 0);
    });
  });

  group('settings', () {
    testWidgets('on/off, placement and sprite persist; defaults clear keys', (
      tester,
    ) async {
      final prefs = MascotPrefs();
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme,
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: MascotSettingsScreen(prefs: prefs),
        ),
      );
      await tester.pump();
      final store = await SharedPreferences.getInstance();
      await tester.tap(find.text('Flotando'));
      await tester.pump();
      expect(store.getString(MascotPrefs.placementKey), 'float');
      await tester.tap(find.text('Pegada al dock'));
      await tester.pump();
      expect(store.getString(MascotPrefs.placementKey), isNull);
      await tester.tap(
        find.byKey(const ValueKey('mascot-settings-sprite-nimbus')),
      );
      await tester.pump();
      expect(store.getString(MascotPrefs.spriteKey), 'nimbus');
      await tester.tap(
        find.byKey(const ValueKey('mascot-settings-sprite-auto')),
      );
      await tester.pump();
      expect(store.getString(MascotPrefs.spriteKey), isNull);
      await tester.tap(find.byKey(const ValueKey('mascot-settings-enabled')));
      await tester.pump();
      expect(store.getBool(MascotPrefs.enabledKey), isFalse);
    });

    test('corrupt stored values fall back to defaults', () async {
      SharedPreferences.setMockInitialValues({
        MascotPrefs.placementKey: 'sideways',
        MascotPrefs.spriteKey: 'dragon',
        MascotPrefs.positionKey: ['x', 'NaN'],
      });
      final prefs = MascotPrefs();
      await prefs.ensureLoaded();
      expect(prefs.placement, MascotPlacement.dock);
      expect(prefs.sprite, isNull);
      expect(prefs.position, isNull);
      expect(prefs.enabled, isTrue);
    });
  });
}
