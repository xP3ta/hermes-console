import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/modal.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/dock_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/mascot/float/mascot_float_physics.dart';
import 'package:hermes_android/core/widgets/mascot/float/mascot_overlay.dart';
import 'package:hermes_android/core/widgets/mascot/float/mascot_prefs.dart';
import 'package:hermes_android/core/widgets/mascot/float/mascot_route_watch.dart';
import 'package:hermes_android/core/widgets/mascot/float/mascot_sources.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_identity.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_sprite.dart';
import 'package:hermes_android/core/widgets/mascot/mascot_state.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _theme = AppTheme.hermesRedDark;
const _screen = Size(390, 844);
const _size = MascotFloatPhysics.baseSize;

/// The dock's bar at rest on a 390 x 844 screen without insets, and the
/// handle it leaves when hidden by hand.
final _dock = Rect.fromLTWH(14, 770, 362, 60);
final _handle = Rect.fromLTWH(151, 790, 88, 48);
final _owner = Object();

/// Home on the dock: the right end of its top edge.
final _home = Offset(
  _dock.right - MascotFloatPhysics.dockEndInset - _size,
  _dock.top + MascotFloatPhysics.dockOverlap - _size,
);

const _sprite = ValueKey('mascot-overlay-sprite');
const _bubble = ValueKey('mascot-overlay-bubble');
const _barrier = ValueKey('mascot-overlay-barrier');
const _badge = ValueKey('mascot-overlay-badge');

/// A pet that records what it was asked to draw.
class _Pet extends ChangeNotifier implements MascotPet {
  bool _shown = true;
  double _scale = 1;
  int hides = 0;
  MascotState? state;
  bool? asleep;
  int? look;
  bool? airborne;

  @override
  bool get shown => _shown;
  set shown(bool value) {
    _shown = value;
    notifyListeners();
  }

  @override
  double get scale => _scale;
  set scale(double value) {
    _scale = value;
    notifyListeners();
  }

  @override
  String get name => 'Zoro';

  @override
  Widget build(
    BuildContext context, {
    required MascotState state,
    required double size,
    required bool asleep,
    required int look,
    bool airborne = false,
  }) {
    this.state = state;
    this.asleep = asleep;
    this.look = look;
    this.airborne = airborne;
    return MascotSprite(
      state: state,
      still: asleep,
      identity: MascotIdentity.hermes,
      size: size,
      excludeSemantics: true,
    );
  }

  @override
  Future<void> hide() async {
    hides++;
    shown = false;
  }
}

/// Stands for a chat: the app marks such pages as ones the mascot keeps
/// out of.
class _ChatPage extends StatelessWidget {
  const _ChatPage();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('chat')));
}

class _Insets {
  const _Insets({
    this.padding = EdgeInsets.zero,
    this.gestures = EdgeInsets.zero,
    this.keyboard = 0,
  });

  final EdgeInsets padding;
  final EdgeInsets gestures;
  final double keyboard;
}

class _Harness {
  final prefs = MascotPrefs();
  final geometry = DockGeometry();
  late final watch = MascotRouteWatch(
    quietPage: (page) => page is _ChatPage,
    geometry: geometry,
  );
  final pet = _Pet();
  final locked = ValueNotifier<bool>(false);
  final reduce = ValueNotifier<bool>(false);
  final suspended = ValueNotifier<bool>(false);
  final insets = ValueNotifier<_Insets>(const _Insets());
  final activity = ValueNotifier<MascotState>(MascotState.idle);
  final permissions = ValueNotifier<List<MascotPermission>>(const []);
  final notices = ValueNotifier<List<MascotNotice>>(const []);
  final cardVisible = ValueNotifier<bool>(false);
  final navigator = GlobalKey<NavigatorState>();
  int talks = 0;
  int changes = 0;

  late final sources = MascotSources(
    permissions: permissions,
    needsCardVisible: cardVisible,
    activity: activity,
    notices: notices,
  );

  Widget app({Widget? home}) => MaterialApp(
    navigatorKey: navigator,
    theme: _theme,
    locale: const Locale('es'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    navigatorObservers: [watch],
    builder: (context, nav) => ListenableBuilder(
      listenable: Listenable.merge([reduce, insets, suspended]),
      builder: (context, _) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduce.value,
          padding: insets.value.padding,
          viewPadding: insets.value.padding,
          systemGestureInsets: insets.value.gestures,
          viewInsets: EdgeInsets.only(bottom: insets.value.keyboard),
        ),
        child: MascotOverlayHost(
          pet: pet,
          prefs: prefs,
          sources: sources,
          geometry: geometry,
          routeWatch: watch,
          locked: locked,
          suspended: suspended.value,
          actions: MascotOverlayActions(
            onTalk: () => talks++,
            onChange: () => changes++,
          ),
          child: nav!,
        ),
      ),
    ),
    // The first screen is one the dock belongs to (Inicio).
    home: dockScreen(home ?? const _ListPage()),
  );

  /// What the app does wherever it mounts the dock: the route carries it.
  Widget dockScreen(Widget page, {bool pet = true}) =>
      DockScreen(geometry: geometry, carriesPet: pet, child: page);

  /// Pushes [page]; a screen the dock belongs to unless [dock] is false (a
  /// settings sub-page, a form, a detail page...).
  Future<void> push(
    WidgetTester tester,
    Widget page, {
    bool dock = true,
    bool pet = true,
  }) async {
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => dock ? dockScreen(page, pet: pet) : page,
        ),
      ),
    );
    await _settle(tester, 700);
  }

  Future<void> pop(WidgetTester tester) async {
    navigator.currentState!.pop();
    await _settle(tester, 700);
  }
}

/// A list screen: rows that scroll, each one tappable.
class _ListPage extends StatelessWidget {
  const _ListPage();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView(
      key: const ValueKey('list'),
      children: [
        for (var i = 0; i < 60; i++)
          InkWell(
            onTap: () {},
            child: SizedBox(height: 60, child: Text('row $i')),
          ),
      ],
    ),
  );
}

Future<_Harness> _pump(
  WidgetTester tester, {
  _Harness? harness,
  bool dock = true,
  Widget? home,
}) async {
  tester.view.physicalSize = _screen;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = harness ?? _Harness();
  if (dock) h.geometry.publish(_owner, _dock, hidden: false);
  await tester.pumpWidget(h.app(home: home));
  await _settle(tester, 400);
  return h;
}

Rect _box(WidgetTester tester) => tester.getRect(find.byKey(_sprite));

Future<void> _settle(WidgetTester tester, [int ms = 400]) async {
  for (var t = 0; t < ms; t += 16) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Picks the mascot up and lets it go with its box at [topLeft].
Future<void> _dragTo(WidgetTester tester, Offset topLeft) async {
  final box = _box(tester);
  final gesture = await tester.startGesture(box.center);
  await gesture.moveBy(const Offset(-6, -6)); // past the 7 px threshold
  await tester.pump();
  await gesture.moveTo(topLeft + box.size.center(Offset.zero));
  await tester.pump();
  await gesture.up();
  await _settle(tester);
}

MascotPermission _permission(
  ValueNotifier<List<MascotPermission>> list,
  List<bool> answers, {
  VoidCallback? openChat,
}) {
  late final MascotPermission p;
  p = MascotPermission(
    key: 'p1',
    title: 'Login tests',
    command: 'git push origin fix/login-tests',
    openChat: openChat,
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

MascotNotice _notice(
  String key, {
  MascotNoticeKind kind = MascotNoticeKind.profile,
  String text = 'Forja: Hermes respondió en Login',
  String action = 'Ver',
  bool waiting = false,
  VoidCallback? onAction,
  VoidCallback? onSeen,
}) => MascotNotice(
  key: key,
  kind: kind,
  waiting: waiting,
  text: (_) => text,
  action: (_) => action,
  onAction: onAction ?? () {},
  onSeen: onSeen,
);

/// Always the middle of the look interval.
class _Half implements math.Random {
  @override
  double nextDouble() => 0.5;

  @override
  int nextInt(int max) => max ~/ 2;

  @override
  bool nextBool() => true;
}

void main() {
  setUp(() {
    debugMascotOverlayRandom = _Half.new;
    SharedPreferences.setMockInitialValues({});
    debugMascotSpritesStill = true;
  });

  group('geometry', () {
    test('home is the right end of the dock\'s top edge', () {
      final home = MascotFloatPhysics.home(
        screen: _screen,
        size: _size,
        dock: _dock,
      );
      expect(home, _home);
      // Feet two pixels into the edge, box clear of the bar's items.
      expect(home.dy + _size, _dock.top + MascotFloatPhysics.dockOverlap);
      expect(home.dx + _size, lessThanOrEqualTo(_dock.right));
    });

    test('dropped along the dock it keeps that place on the edge', () {
      final left = MascotFloatPhysics.home(
        screen: _screen,
        size: _size,
        dock: _dock,
        dockAlong: 0,
      );
      expect(left.dx, _dock.left + MascotFloatPhysics.dockEndInset);
      expect(MascotFloatPhysics.dockAlongOf(left.dx, _dock, _size), 0);
      expect(MascotFloatPhysics.dockAlongOf(_home.dx, _dock, _size), 1);
      final mid = MascotFloatPhysics.home(
        screen: _screen,
        size: _size,
        dock: _dock,
        dockAlong: 0.25,
      );
      expect(
        MascotFloatPhysics.dockAlongOf(mid.dx, _dock, _size),
        closeTo(0.25, 1e-9),
      );
    });

    test('without a dock: the same corner, above the system inset', () {
      final plain = MascotFloatPhysics.home(screen: _screen, size: _size);
      expect(plain.dx, _home.dx, reason: 'the same column as on the dock');
      expect(plain.dy + _size, _screen.height - MascotFloatPhysics.cornerLift);
      final inset = MascotFloatPhysics.home(
        screen: _screen,
        size: _size,
        padding: const EdgeInsets.only(bottom: 24),
        gestures: const EdgeInsets.only(bottom: 32, right: 20),
      );
      expect(inset.dy + _size, _screen.height - 32 - 12);
      expect(inset.dx + _size, _screen.width - 28);
    });

    test('lands on the dock only when dropped on it', () {
      bool lands(double left, double bottom) =>
          MascotFloatPhysics.landsOnDock(mascotBox(left, bottom), _dock);
      expect(lands(100, _dock.top + 10), isTrue);
      expect(lands(100, _dock.top - 18), isTrue);
      expect(lands(100, _dock.top - 19), isFalse);
      expect(lands(100, 400), isFalse, reason: 'no fall from mid screen');
      expect(lands(-40, _dock.top), isFalse);
      expect(
        MascotFloatPhysics.landsOnDock(mascotBox(100, _dock.top), null),
        isFalse,
      );
    });

    test('free bounds keep out of insets, gesture zones, keyboard, dock', () {
      final bounds = MascotFloatPhysics.floatBounds(
        screen: _screen,
        size: _size,
        padding: const EdgeInsets.only(top: 30, bottom: 24),
        gestures: const EdgeInsets.only(left: 20, right: 20, bottom: 32),
        keepOut: _dock,
      );
      expect(bounds.left, 20);
      expect(bounds.right, _screen.width - 20 - _size);
      expect(bounds.top, 30);
      expect(bounds.bottom, _dock.top - 8 - _size);
      final typing = MascotFloatPhysics.floatBounds(
        screen: _screen,
        size: _size,
        keyboard: 300,
      );
      expect(typing.bottom, _screen.height - 300 - _size);
      expect(
        MascotFloatPhysics.clampInto(const Offset(-50, 9000), bounds),
        Offset(bounds.left, bounds.bottom),
      );
    });
  });

  group('presence gate', () {
    testWidgets('not shown: no overlay, no timers, nothing read or stored', (
      tester,
    ) async {
      final h = _Harness()..pet.shown = false;
      await _pump(tester, harness: h);
      expect(find.byType(MascotOverlay), findsNothing);
      expect(find.byType(MascotSprite), findsNothing);
      expect(h.prefs.loaded, isFalse);
      expect(debugMascotOverlayTimers, 0);
      // The page works as ever, and a scroll wakes nothing up.
      await tester.drag(
        find.byKey(const ValueKey('list')),
        const Offset(0, -200),
      );
      await _settle(tester, 60000);
      expect(debugMascotOverlayTimers, 0);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    });

    testWidgets('suspended (onboarding, locked start): no overlay', (
      tester,
    ) async {
      final h = _Harness()..suspended.value = true;
      await _pump(tester, harness: h);
      expect(find.byType(MascotOverlay), findsNothing);
      expect(h.prefs.loaded, isFalse);
      h.suspended.value = false;
      await _settle(tester);
      expect(find.byKey(_sprite), findsOneWidget);
    });

    testWidgets('turned on later it appears; one pet, the one it is given', (
      tester,
    ) async {
      final h = _Harness()..pet.shown = false;
      await _pump(tester, harness: h);
      h.pet.shown = true;
      await _settle(tester);
      expect(find.byKey(_sprite), findsOneWidget);
      expect(find.byType(MascotSprite), findsOneWidget);
      expect(_box(tester).topLeft, _home);
    });

    testWidgets('Ocultar in its own menu turns it off', (tester) async {
      final h = await _pump(tester);
      await tester.tap(find.byKey(_sprite));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('mascot-menu-hide')));
      await _settle(tester);
      expect(h.pet.hides, 1);
      expect(find.byType(MascotOverlay), findsNothing);
      expect(debugMascotOverlayTimers, 0);
    });
  });

  group('home', () {
    testWidgets('stands on the dock\'s right end, over none of its items', (
      tester,
    ) async {
      await _pump(tester);
      final box = _box(tester);
      expect(box.topLeft, _home);
      expect(box.size, const Size.square(_size));
      expect(box.bottom, _dock.top + MascotFloatPhysics.dockOverlap);
      expect(box.right, lessThanOrEqualTo(_dock.right));
      // The bar's items live below its top edge.
      expect(box.intersect(_dock.deflate(4)).height, lessThanOrEqualTo(0));
    });

    testWidgets('dock hidden by hand: its corner, off the handle', (
      tester,
    ) async {
      final h = await _pump(tester);
      h.geometry.publish(_owner, _handle, hidden: true);
      await _settle(tester);
      final box = _box(tester);
      expect(box.left, _home.dx, reason: 'the same corner');
      expect(box.bottom, _screen.height - MascotFloatPhysics.cornerLift);
      expect(box.overlaps(_handle), isFalse);
      // Shown again: back on its edge.
      h.geometry.publish(_owner, _dock, hidden: false);
      await _settle(tester);
      expect(_box(tester).topLeft, _home);
    });

    testWidgets('nothing is drawn under it: on the dock, off it, or where '
        'it was dropped', (tester) async {
      // The sprite and, when something waits, its badge: no base, no ring,
      // no shadow of its own.
      final h = await _pump(tester);
      // What the mascot's box holds: the pet, and nothing else.
      List<Widget> layers() => tester
          .widget<Stack>(
            find
                .descendant(
                  of: find.byKey(_sprite),
                  matching: find.byType(Stack),
                )
                .first,
          )
          .children;
      expect(find.byKey(const ValueKey('mascot-overlay-base')), findsNothing);
      expect(layers(), hasLength(1));
      h.geometry.publish(_owner, _handle, hidden: true);
      await _settle(tester);
      expect(layers(), hasLength(1));
      h.geometry.publish(_owner, _dock, hidden: false);
      await _settle(tester);
      await _dragTo(tester, const Offset(126, 324));
      expect(h.prefs.placement, MascotPlacement.free);
      expect(layers(), hasLength(1));
    });

    testWidgets('dock switched off: the corner, above the system inset', (
      tester,
    ) async {
      final h = _Harness()
        ..insets.value = const _Insets(
          padding: EdgeInsets.only(top: 30, bottom: 24),
          gestures: EdgeInsets.only(bottom: 32),
        );
      await _pump(tester, harness: h, dock: false);
      final box = _box(tester);
      expect(box.left, _home.dx);
      expect(box.bottom, _screen.height - 32 - MascotFloatPhysics.cornerLift);
    });

    testWidgets('a dock that reports while its route arrives is asked again '
        'once the navigator rests', (tester) async {
      final h = await _pump(tester);
      var asked = 0;
      h.geometry.watch(_owner, () => asked++);
      unawaited(
        h.navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => h.dockScreen(const _ListPage()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(h.watch.inTransition, isTrue);
      // Mid-transition the incoming dock says where it is passing through.
      h.geometry.publish(_owner, _dock.translate(0, 120), hidden: false);
      await tester.pump(const Duration(milliseconds: 16));
      expect(_box(tester).topLeft, _home, reason: 'it does not chase it');
      final before = asked;
      h.geometry.publish(_owner, _dock, hidden: false);
      await _settle(tester, 700);
      expect(h.watch.inTransition, isFalse);
      expect(asked, greaterThan(before));
      expect(_box(tester).topLeft, _home);
    });

    testWidgets('a side rail (wide windows) is not something to stand on', (
      tester,
    ) async {
      final h = await _pump(tester, dock: false);
      h.geometry.publish(
        _owner,
        const Rect.fromLTWH(0, 0, 72, 844),
        hidden: false,
      );
      await _settle(tester);
      expect(_box(tester).left, _home.dx);
      expect(
        _box(tester).bottom,
        _screen.height - MascotFloatPhysics.cornerLift,
      );
    });

    testWidgets('the pet\'s own size setting scales it on the spot', (
      tester,
    ) async {
      final h = await _pump(tester);
      h.pet.scale = 1.25;
      await _settle(tester);
      final box = _box(tester);
      expect(box.size, const Size.square(60));
      expect(box.bottom, _dock.top + MascotFloatPhysics.dockOverlap);
      expect(box.right, _dock.right - MascotFloatPhysics.dockEndInset);
    });
  });

  group('put it where you want', () {
    testWidgets('under 7 px is a tap (its menu), not a drag', (tester) async {
      final h = await _pump(tester);
      final g = await tester.startGesture(_box(tester).center);
      await g.moveBy(const Offset(4, 4));
      await g.up();
      await tester.pump();
      expect(find.byKey(const ValueKey('mascot-menu-hide')), findsOneWidget);
      expect(_box(tester).topLeft, _home);
      expect(h.prefs.placement, MascotPlacement.dock);
    });

    testWidgets('it stays exactly where it is dropped, near an edge too', (
      tester,
    ) async {
      final h = await _pump(tester);
      await _dragTo(tester, const Offset(126, 324));
      expect(_box(tester).left, closeTo(126, 0.01));
      expect(_box(tester).top, closeTo(324, 0.01));
      expect(h.prefs.placement, MascotPlacement.free);
      // 20 px from the side: it used to snap to the edge. It stays.
      await _dragTo(tester, const Offset(20, 500));
      expect(_box(tester).left, closeTo(20, 0.01));
      expect(_box(tester).top, closeTo(500, 0.01));
      // And it does not go anywhere by itself afterwards.
      final frames = debugMascotOverlayFrames;
      await _settle(tester, 90000);
      expect(debugMascotOverlayFrames, frames);
      expect(_box(tester).left, closeTo(20, 0.01));
    });

    testWidgets('low over the screen it no longer falls onto the dock', (
      tester,
    ) async {
      await _pump(tester);
      // 100 px above the dock used to be inside the 160 px "fall" zone.
      await _dragTo(tester, Offset(150, _dock.top - 100 - _size));
      expect(_box(tester).left, closeTo(150, 0.01));
      expect(_box(tester).bottom, closeTo(_dock.top - 100, 0.01));
    });

    testWidgets('a flick does not throw it', (tester) async {
      await _pump(tester);
      final box = _box(tester);
      final g = await tester.startGesture(box.center);
      // 300 px in 48 ms: far faster than the old 350 px/s throw.
      for (var i = 1; i <= 3; i++) {
        await g.moveBy(
          const Offset(-100, -100),
          timeStamp: Duration(milliseconds: 16 * i),
        );
      }
      await g.up(timeStamp: const Duration(milliseconds: 50));
      await _settle(tester, 2000);
      expect(_box(tester).center.dx, closeTo(box.center.dx - 300, 0.01));
      expect(_box(tester).center.dy, closeTo(box.center.dy - 300, 0.01));
    });

    testWidgets('the spot is remembered across screens and restarts', (
      tester,
    ) async {
      final h = await _pump(tester);
      await _dragTo(tester, const Offset(126, 324));
      await h.push(tester, const Scaffold(body: Text('other')));
      expect(_box(tester).left, closeTo(126, 0.01));
      expect(_box(tester).top, closeTo(324, 0.01));
      final stored = await SharedPreferences.getInstance();
      expect(stored.getString(MascotPrefs.placementKey), 'free');
      expect(stored.getStringList(MascotPrefs.positionKey), hasLength(2));
      // A new process: new objects, the same device storage.
      await tester.pumpWidget(const SizedBox());
      await _pump(tester);
      expect(_box(tester).left, closeTo(126, 0.5));
      expect(_box(tester).top, closeTo(324, 0.5));
    });

    testWidgets('clamped into the safe area, away from the gesture edges', (
      tester,
    ) async {
      final h = _Harness()
        ..insets.value = const _Insets(
          padding: EdgeInsets.only(top: 30, bottom: 24),
          gestures: EdgeInsets.only(left: 20, right: 20, bottom: 32),
        );
      await _pump(tester, harness: h, dock: false);
      await _dragTo(tester, const Offset(-30, -40));
      expect(_box(tester).left, 20);
      expect(_box(tester).top, 30);
      await _dragTo(tester, const Offset(380, 830));
      expect(_box(tester).right, _screen.width - 20);
      expect(_box(tester).bottom, _screen.height - 32);
    });

    testWidgets('dropped on the dock it stands on the dock, right there', (
      tester,
    ) async {
      final h = await _pump(tester);
      await _dragTo(tester, const Offset(126, 324));
      await _dragTo(tester, Offset(100, _dock.top - _size - 6));
      expect(h.prefs.placement, MascotPlacement.dock);
      expect(_box(tester).left, closeTo(100, 0.5));
      expect(_box(tester).bottom, _dock.top + MascotFloatPhysics.dockOverlap);
      final stored = await SharedPreferences.getInstance();
      expect(stored.containsKey(MascotPrefs.placementKey), isFalse);
      expect(stored.getDouble(MascotPrefs.dockAlongKey), isNotNull);
    });

    testWidgets('"Volver al dock" (menu, only once moved) takes it home', (
      tester,
    ) async {
      final h = await _pump(tester);
      await tester.tap(find.byKey(_sprite));
      await tester.pump();
      expect(find.byKey(const ValueKey('mascot-menu-dock')), findsNothing);
      await tester.tap(find.byKey(_sprite));
      await tester.pump();
      await _dragTo(tester, const Offset(126, 324));
      await tester.tap(find.byKey(_sprite));
      await tester.pump();
      expect(find.text('Volver al dock'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mascot-menu-dock')));
      await _settle(tester, 1000);
      expect(_box(tester).topLeft, _home);
      expect(h.prefs.moved, isFalse);
      // Home is the default: nothing stays stored.
      final stored = await SharedPreferences.getInstance();
      expect(stored.getKeys(), isEmpty);
    });

    testWidgets('a long press opens the menu', (tester) async {
      await _pump(tester);
      final g = await tester.startGesture(_box(tester).center);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(_bubble), findsNothing);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const ValueKey('mascot-menu-hide')), findsOneWidget);
      await g.up();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('mascot-menu-hide')),
        findsOneWidget,
        reason: 'lifting the finger is not a second tap',
      );
    });

    testWidgets('reduced motion: placed at once, no glide', (tester) async {
      final h = _Harness()..reduce.value = true;
      await _pump(tester, harness: h);
      final box = _box(tester);
      final g = await tester.startGesture(box.center);
      await g.moveBy(const Offset(-10, -10));
      await g.moveTo(Offset(124, _dock.top - 30));
      await g.up();
      await tester.pump();
      expect(_box(tester).bottom, _dock.top + MascotFloatPhysics.dockOverlap);
      expect(debugMascotOverlayTimers, 0);
    });

    testWidgets('a stored spot off this screen is pulled in, not lost', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        MascotPrefs.placementKey: 'float', // the flagged build's name
        MascotPrefs.positionKey: ['0.9900', '0.9900'],
        'mascot_float_enabled_v1': false,
        'mascot_float_sprite_v1': 'nimbus',
      });
      final h = await _pump(tester);
      expect(h.prefs.placement, MascotPlacement.free);
      final box = _box(tester);
      expect(box.right, lessThanOrEqualTo(_screen.width - 8));
      expect(box.bottom, lessThanOrEqualTo(_dock.top - 8));
      // The switches of the flagged build are gone with their keys.
      final stored = await SharedPreferences.getInstance();
      expect(stored.containsKey('mascot_float_enabled_v1'), isFalse);
      expect(stored.containsKey('mascot_float_sprite_v1'), isFalse);
      expect(h.prefs.position, const Offset(0.99, 0.99));
    });

    test('corrupt stored values fall back to home', () async {
      SharedPreferences.setMockInitialValues({
        MascotPrefs.placementKey: 'free',
        MascotPrefs.positionKey: ['x', 'NaN'],
        MascotPrefs.dockAlongKey: double.nan,
      });
      final prefs = MascotPrefs();
      await prefs.ensureLoaded();
      expect(prefs.placement, MascotPlacement.dock);
      expect(prefs.position, isNull);
      expect(prefs.dockAlong, isNull);
      expect(prefs.moved, isFalse);
    });
  });

  group('never on a control', () {
    testWidgets('a sticky Save at the bottom: it stands above it', (
      tester,
    ) async {
      await _pump(
        tester,
        dock: false,
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    key: const ValueKey('save'),
                    onPressed: () {},
                    child: const Text('Guardar'),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      final save = tester.getRect(find.byKey(const ValueKey('save')));
      final box = _box(tester);
      expect(box.overlaps(save), isFalse);
      expect(box.left, _home.dx, reason: 'still its corner');
      expect(box.bottom, lessThanOrEqualTo(save.top));
    });

    testWidgets('a top-bar "+": a pet parked on it steps off, on that screen '
        'only', (tester) async {
      Widget page({required bool plus}) => Scaffold(
        body: Stack(
          children: [
            const SizedBox.expand(),
            if (plus)
              Positioned(
                top: 40,
                right: 12,
                child: IconButton.filled(
                  key: const ValueKey('plus'),
                  onPressed: () {},
                  icon: const Icon(Icons.add),
                ),
              ),
          ],
        ),
      );
      final h = await _pump(tester, home: page(plus: false));
      await _dragTo(tester, const Offset(330, 40));
      expect(_box(tester).topLeft, const Offset(330, 40));
      await h.push(tester, page(plus: true));
      final plus = tester.getRect(find.byKey(const ValueKey('plus')));
      expect(_box(tester).overlaps(plus), isFalse);
      expect(_box(tester).left, 330, reason: 'straight down, no further');
      // Where he put it is untouched: back on the first screen it is there.
      await h.pop(tester);
      expect(_box(tester).left, closeTo(330, 0.01));
      expect(_box(tester).top, closeTo(40, 0.01));
    });

    testWidgets('rows that scroll and big cards are not controls', (
      tester,
    ) async {
      final h = await _pump(tester);
      await _dragTo(tester, const Offset(200, 300));
      expect(_box(tester).left, closeTo(200, 0.01));
      expect(_box(tester).top, closeTo(300, 0.01));
      await h.push(
        tester,
        Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 300,
              child: InkWell(onTap: () {}, child: const Text('card')),
            ),
          ),
        ),
      );
      expect(_box(tester).left, closeTo(200, 0.01));
      expect(_box(tester).top, closeTo(300, 0.01));
    });

    testWidgets('on the dock it is home whatever the page shows above', (
      tester,
    ) async {
      await _pump(
        tester,
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: _home.dx,
                top: _home.dy,
                child: IconButton(
                  onPressed: () {},
                  icon: const Icon(Icons.add),
                ),
              ),
            ],
          ),
        ),
      );
      expect(_box(tester).topLeft, _home);
    });
  });

  group('where it shows', () {
    testWidgets('a chat hides it, and it returns only when the chat is gone', (
      tester,
    ) async {
      final h = await _pump(tester);
      unawaited(
        h.navigator.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const _ChatPage()),
        ),
      );
      await _settle(tester, 200);
      expect(find.byKey(_sprite), findsNothing);
      await _settle(tester, 600);
      expect(find.byKey(_sprite), findsNothing);
      expect(debugMascotOverlayTimers, 0);
      h.navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        find.byKey(_sprite),
        findsNothing,
        reason: 'not over a chat that is still sliding out',
      );
      await _settle(tester, 700);
      expect(find.byKey(_sprite), findsOneWidget);
    });

    testWidgets('a screen the dock belongs to shows it, where it was', (
      tester,
    ) async {
      final h = await _pump(tester);
      await h.push(tester, const Scaffold(body: Text('herramientas')));
      expect(find.byKey(_sprite), findsOneWidget);
      expect(_box(tester).topLeft, _home);
    });

    testWidgets('a configuration screen has the dock but not the pet: dock '
        'shown, hidden by hand, or off', (tester) async {
      for (final state in ['shown', 'hidden', 'off']) {
        final h = await _pump(tester, dock: state != 'off');
        if (state == 'hidden') {
          h.geometry.publish(_owner, _dock.translate(0, 40), hidden: true);
          await _settle(tester, 300);
        }
        expect(find.byKey(_sprite), findsOneWidget, reason: state);
        await h.push(tester, const Scaffold(body: Text('ajustes')), pet: false);
        // A bubble that is pending waits for a pet screen.
        h.notices.value = [_notice('profile:c1:forja#$state')];
        await _settle(tester, 300);
        expect(find.byKey(_sprite), findsNothing, reason: state);
        expect(find.byKey(_bubble), findsNothing, reason: state);
        expect(debugMascotOverlayTimers, 0, reason: state);
        final route = ModalRoute.of(tester.element(find.text('ajustes')))!;
        expect(h.geometry.carriesDock(route), isTrue, reason: 'still the dock');
        expect(h.geometry.carriesPet(route), isFalse, reason: state);
        // Going on to another configuration page and back: still not there.
        await h.push(tester, const Scaffold(body: Text('hija')), dock: false);
        expect(find.byKey(_sprite), findsNothing, reason: state);
        await h.pop(tester);
        expect(find.byKey(_sprite), findsNothing, reason: state);
        await h.pop(tester);
        expect(find.byKey(_sprite), findsOneWidget, reason: state);
        expect(
          find.byKey(_bubble),
          findsOneWidget,
          reason: 'told on a pet one',
        );
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('moving from a pet screen to a configuration one swaps it '
        'out at once, and back', (tester) async {
      final h = await _pump(tester);
      await h.push(tester, const Scaffold(body: Text('chats')));
      expect(find.byKey(_sprite), findsOneWidget);
      await h.push(tester, const Scaffold(body: Text('ajustes')), pet: false);
      expect(find.byKey(_sprite), findsNothing);
      await h.pop(tester);
      expect(find.byKey(_sprite), findsOneWidget);
    });

    testWidgets('with the dock hidden by hand or switched off it is on the '
        'same screens, in its corner', (tester) async {
      final h = await _pump(tester, dock: false);
      // No bar published (switched off): the route still carries the dock,
      // so it is shown, in the corner.
      expect(find.byKey(_sprite), findsOneWidget);
      expect(_box(tester).left, _home.dx);
      // Hidden by hand: the handle is published, the screen is the same.
      h.geometry.publish(_owner, _dock.translate(0, 40), hidden: true);
      await _settle(tester, 300);
      expect(find.byKey(_sprite), findsOneWidget);
      await h.push(tester, const Scaffold(body: Text('ajustes')), dock: false);
      expect(find.byKey(_sprite), findsNothing);
      expect(debugMascotOverlayTimers, 0);
      await h.pop(tester);
      expect(find.byKey(_sprite), findsOneWidget);
    });

    testWidgets('a page the dock does not belong to hides it: a settings '
        'page, a form, a detail page', (tester) async {
      final h = await _pump(tester);
      for (final page in const ['ajustes', 'formulario', 'detalle']) {
        await h.push(tester, Scaffold(body: Text(page)), dock: false);
        expect(find.text(page), findsOneWidget);
        expect(find.byKey(_sprite), findsNothing, reason: page);
        expect(find.byKey(_bubble), findsNothing, reason: page);
        expect(debugMascotOverlayTimers, 0, reason: page);
        // Pages stack: still not there on top of another one.
        await h.push(tester, const Scaffold(body: Text('mas')), dock: false);
        expect(find.byKey(_sprite), findsNothing, reason: page);
        await h.pop(tester);
        await h.pop(tester);
        expect(find.byKey(_sprite), findsOneWidget, reason: page);
        expect(_box(tester).topLeft, _home);
      }
    });

    testWidgets('it leaves at the start of the push and returns when the pop '
        'has finished', (tester) async {
      final h = await _pump(tester);
      unawaited(
        h.navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('ajustes')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(h.watch.inTransition, isTrue);
      // It starts leaving with the push (a 140 ms fade): by the time the
      // page is a third of the way in it is gone, not riding over it.
      await _settle(tester, 160);
      expect(h.watch.inTransition, isTrue, reason: 'the page is still coming');
      expect(
        find.byKey(_sprite),
        findsNothing,
        reason: 'not riding over the incoming page',
      );
      await _settle(tester, 700);
      expect(find.byKey(_sprite), findsNothing);
      h.navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(h.watch.inTransition, isTrue);
      expect(
        find.byKey(_sprite),
        findsNothing,
        reason: 'not while the page is still sliding out',
      );
      await _settle(tester, 700);
      expect(find.byKey(_sprite), findsOneWidget);
    });

    testWidgets('a free-placed pet comes back to its spot on a dock screen', (
      tester,
    ) async {
      final h = await _pump(tester);
      await _dragTo(tester, const Offset(40, 300));
      final spot = _box(tester).topLeft;
      await h.push(tester, const Scaffold(body: Text('ajustes')), dock: false);
      expect(find.byKey(_sprite), findsNothing);
      await h.pop(tester);
      expect(_box(tester).topLeft, spot);
      await h.push(tester, const Scaffold(body: Text('otra')));
      expect(_box(tester).topLeft, spot, reason: 'a second dock screen');
    });

    testWidgets('a screen is a dock screen only while it mounts the dock', (
      tester,
    ) async {
      final h = await _pump(tester);
      await h.push(tester, const Scaffold(body: Text('con dock')));
      final route = ModalRoute.of(tester.element(find.text('con dock')))!;
      expect(h.geometry.carriesDock(route), isTrue);
      await h.pop(tester);
      expect(h.geometry.carriesDock(route), isFalse);
    });

    testWidgets('floating surfaces and viewers (non-opaque routes) hide it', (
      tester,
    ) async {
      final h = await _pump(tester);
      unawaited(
        h.navigator.currentState!.push(
          PageRouteBuilder<void>(
            opaque: false,
            barrierColor: Colors.black54,
            pageBuilder: (_, _, _) => const Center(child: Text('surface')),
          ),
        ),
      );
      await _settle(tester, 700);
      expect(find.byKey(_sprite), findsNothing);
      await h.pop(tester);
      expect(find.byKey(_sprite), findsOneWidget);
    });

    testWidgets('the app\'s own floating surface, menu and dialog hide it', (
      tester,
    ) async {
      // They are what every sheet, picker, menu and confirmation of the app
      // is shown with, and none of them is a PopupRoute.
      final h = await _pump(tester);
      final context = h.navigator.currentContext!;
      for (final (label, open) in <(String, void Function())>[
        (
          'surface',
          () => unawaited(
            showHermesSurface<void>(
              context: context,
              builder: (_) =>
                  const SizedBox(height: 120, child: Text('surface')),
            ),
          ),
        ),
        (
          'Borrar',
          () => unawaited(
            showHermesMenu<int>(
              context: context,
              actions: const [
                HermesAction(value: 1, label: 'Borrar', icon: Icons.delete),
              ],
            ),
          ),
        ),
        (
          'dialog',
          () => unawaited(
            showHermesDialogRoute<void>(
              context: context,
              builder: (_) => const AlertDialog(content: Text('dialog')),
            ),
          ),
        ),
      ]) {
        open();
        await _settle(tester, 700);
        expect(find.text(label), findsOneWidget);
        expect(find.byKey(_sprite), findsNothing, reason: label);
        expect(debugMascotOverlayTimers, 0);
        await h.pop(tester);
        expect(find.byKey(_sprite), findsOneWidget, reason: label);
      }
    });

    testWidgets('dialogs, sheets and menus hide it', (tester) async {
      final h = await _pump(tester);
      final context = h.navigator.currentContext!;
      for (final open in <void Function()>[
        () => unawaited(
          showDialog<void>(
            context: context,
            builder: (_) => const AlertDialog(content: Text('x')),
          ),
        ),
        () => unawaited(
          showModalBottomSheet<void>(
            context: context,
            builder: (_) => const SizedBox(height: 200, child: Text('x')),
          ),
        ),
        () => unawaited(
          showMenu<void>(
            context: context,
            position: const RelativeRect.fromLTRB(100, 100, 100, 100),
            items: const [PopupMenuItem<void>(child: Text('x'))],
          ),
        ),
      ]) {
        open();
        await _settle(tester, 700);
        expect(find.byKey(_sprite), findsNothing);
        expect(debugMascotOverlayTimers, 0);
        await h.pop(tester);
        expect(find.byKey(_sprite), findsOneWidget);
      }
    });

    testWidgets('a dock item\'s long-press menu hides it', (tester) async {
      // The menu opens above the bar, where the mascot stands.
      final h = await _pump(tester);
      h.geometry.setMenuOpen(_owner, true);
      await _settle(tester, 300);
      expect(find.byKey(_sprite), findsNothing);
      expect(debugMascotOverlayTimers, 0);
      // Another dock closing a menu it never opened changes nothing.
      h.geometry.setMenuOpen(Object(), false);
      await _settle(tester, 300);
      expect(find.byKey(_sprite), findsNothing);
      h.geometry.setMenuOpen(_owner, false);
      await _settle(tester, 300);
      expect(find.byKey(_sprite), findsOneWidget);
    });

    testWidgets('told something while a frame is being built, it takes it '
        'after the frame', (tester) async {
      // A dock closes or opens its menu from its own build when its route
      // is covered: the mascot must not mark itself in the middle of it.
      final h = await _pump(tester);
      await h.push(
        tester,
        Builder(
          builder: (context) {
            h.geometry.setMenuOpen(_owner, true);
            h.activity.value = MascotState.tool;
            return const Scaffold(body: Text('built'));
          },
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('built'), findsOneWidget);
      expect(find.byKey(_sprite), findsNothing);
      h.geometry.setMenuOpen(_owner, false);
      await _settle(tester, 300);
      expect(h.pet.state, MascotState.tool);
    });

    testWidgets('the lock screen hides it: no timers', (tester) async {
      final h = await _pump(tester);
      h.locked.value = true;
      await _settle(tester, 300);
      expect(find.byKey(_sprite), findsNothing);
      await _settle(tester, 60000);
      expect(debugMascotOverlayTimers, 0);
      h.locked.value = false;
      await _settle(tester, 300);
      expect(find.byKey(_sprite), findsOneWidget);
    });

    testWidgets('the keyboard hides it', (tester) async {
      final h = await _pump(tester);
      h.insets.value = const _Insets(keyboard: 300);
      await _settle(tester, 300);
      expect(find.byKey(_sprite), findsNothing);
      expect(debugMascotOverlayTimers, 0);
      h.insets.value = const _Insets();
      await _settle(tester, 300);
      expect(find.byKey(_sprite), findsOneWidget);
      expect(_box(tester).topLeft, _home);
    });

    testWidgets('a mascot on a chat\'s island hides it: never two', (
      tester,
    ) async {
      final h = await _pump(tester);
      await h.push(
        tester,
        const Scaffold(
          body: MascotSprite(state: MascotState.idle, header: true),
        ),
      );
      expect(find.byKey(_sprite), findsNothing);
      await h.pop(tester);
      expect(find.byKey(_sprite), findsOneWidget);
    });

    testWidgets('while a list scrolls it fades and takes no touch', (
      tester,
    ) async {
      await _pump(tester);
      final g = await tester.startGesture(const Offset(180, 300));
      await g.moveBy(const Offset(0, -40));
      await tester.pump();
      await g.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 200));
      final opacity = tester.widget<AnimatedOpacity>(
        find.byKey(const ValueKey('mascot-overlay-opacity')),
      );
      expect(opacity.opacity, MascotFloatPhysics.scrollOpacity);
      expect(
        tester
            .widget<IgnorePointer>(find.byKey(const ValueKey('mascot-here')))
            .ignoring,
        isTrue,
      );
      await g.up();
      await _settle(tester, 900);
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('mascot-overlay-opacity')),
            )
            .opacity,
        1,
      );
    });
  });

  group('alive, not noisy', () {
    testWidgets('resting: a look now and then, then asleep with no timer', (
      tester,
    ) async {
      final h = await _pump(tester);
      expect(h.pet.state, MascotState.idle);
      expect(h.pet.asleep, isFalse);
      expect(h.pet.look, 0);
      expect(debugMascotOverlayTimers, 2, reason: 'one look, one sleep');
      await _settle(tester, 19000); // the look comes at 18 s
      expect(h.pet.look, 1);
      await _settle(tester, 27000); // asleep at 45 s
      expect(h.pet.asleep, isTrue);
      expect(debugMascotOverlayTimers, 0);
      final frames = debugMascotOverlayFrames;
      await _settle(tester, 120000);
      expect(debugMascotOverlayFrames, frames);
      expect(debugMascotOverlayTimers, 0);
      // A touch wakes it.
      await tester.tap(find.byKey(_sprite));
      await tester.pump();
      expect(h.pet.asleep, isFalse);
    });

    testWidgets('it shows what Hermes is doing, and does not doze off busy', (
      tester,
    ) async {
      final h = await _pump(tester);
      for (final state in [
        MascotState.thinking,
        MascotState.tool,
        MascotState.done,
        MascotState.error,
        MascotState.offline,
      ]) {
        h.activity.value = state;
        await tester.pump();
        expect(h.pet.state, state);
      }
      h.activity.value = MascotState.tool;
      await tester.pump();
      expect(debugMascotOverlayTimers, 0, reason: 'its drawing moves it');
      await _settle(tester, 90000);
      expect(h.pet.asleep, isFalse);
      // Back to rest: awake, and the idle clock starts again.
      h.activity.value = MascotState.idle;
      await tester.pump();
      expect(h.pet.asleep, isFalse);
      expect(debugMascotOverlayTimers, 2);
    });

    testWidgets('something waiting wakes it and shows "te necesita"', (
      tester,
    ) async {
      final h = await _pump(tester);
      await _settle(tester, 46000);
      expect(h.pet.asleep, isTrue);
      h.notices.value = [_notice('q', waiting: true)];
      await tester.pump();
      expect(h.pet.asleep, isFalse);
      expect(h.pet.state, MascotState.needsYou);
      h.notices.value = [_notice('f', kind: MascotNoticeKind.failed)];
      await tester.pump();
      expect(h.pet.state, MascotState.error);
    });

    testWidgets('reduced motion: still, no timers', (tester) async {
      final h = _Harness()..reduce.value = true;
      await _pump(tester, harness: h);
      expect(h.pet.asleep, isTrue, reason: 'its resting drawing');
      expect(debugMascotOverlayTimers, 0);
      h.activity.value = MascotState.tool;
      await _settle(tester, 30000);
      expect(h.pet.asleep, isTrue);
      expect(debugMascotOverlayTimers, 0);
    });

    testWidgets('in the background: no timers; back in front it wakes', (
      tester,
    ) async {
      final h = await _pump(tester);
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
      expect(debugMascotOverlayTimers, 0);
      expect(h.pet.asleep, isTrue);
      await _settle(tester, 60000);
      expect(debugMascotOverlayTimers, 0);
      for (final s in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
      await tester.pump();
      expect(h.pet.asleep, isFalse);
      expect(debugMascotOverlayTimers, 2);
    });

    testWidgets('a settle is short and ≤ 30 frames a second', (tester) async {
      final h = await _pump(tester);
      final before = debugMascotOverlayFrames;
      // The dock is hidden under it: it settles down to its corner.
      h.geometry.publish(_owner, _handle, hidden: true);
      await tester.pump();
      var frames = 0;
      var last = debugMascotOverlayFrames;
      for (var t = 0; t < 1000; t += 8) {
        await tester.pump(const Duration(milliseconds: 8));
        if (debugMascotOverlayFrames != last) {
          frames++;
          last = debugMascotOverlayFrames;
        }
        if (t == 240) {
          expect(
            _box(tester).bottom,
            _screen.height - MascotFloatPhysics.cornerLift,
            reason: '180 ms',
          );
        }
      }
      expect(frames, inInclusiveRange(3, 6));
      expect(debugMascotOverlayFrames - before, lessThanOrEqualTo(6));
    });

    testWidgets('moving it never rebuilds the page under it', (tester) async {
      var builds = 0;
      await _pump(
        tester,
        home: Builder(
          builder: (context) {
            builds++;
            return const Scaffold(body: Text('page'));
          },
        ),
      );
      final before = builds;
      await _dragTo(tester, const Offset(60, 200));
      await _dragTo(tester, const Offset(200, 500));
      expect(builds, before);
      expect(
        find.ancestor(
          of: find.byType(MascotOverlay),
          matching: find.byType(RepaintBoundary),
        ),
        findsWidgets,
      );
    });
  });

  group('"Volver al dock" is a free fall, as Hermes Desktop\'s pet drops', () {
    // Dropped at (126, 324): 400 px above its place on the dock's edge.
    const from = Offset(126, 324);
    final drop = _home.dy - from.dy;

    Future<_Harness> lifted(WidgetTester tester, {_Harness? harness}) async {
      final h = await _pump(tester, harness: harness);
      await _dragTo(tester, from);
      expect(_box(tester).topLeft, from);
      return h;
    }

    /// Top-left of the mascot every 8 ms for [ms] after it is sent home.
    Future<List<Offset>> sendHome(
      WidgetTester tester,
      _Harness h, {
      int ms = 1200,
    }) async {
      unawaited(h.prefs.placeOnDock());
      await tester.pump();
      final path = <Offset>[];
      for (var t = 0; t < ms; t += 8) {
        await tester.pump(const Duration(milliseconds: 8));
        path.add(_box(tester).topLeft);
      }
      return path;
    }

    test('Desktop\'s numbers: 5200 px/s², steps of 50 ms at most', () {
      expect(MascotFloatPhysics.fallGravity, 5200);
      expect(MascotFloatPhysics.fallMaxStep, 0.05);
      expect(MascotFloatPhysics.rise, const Duration(milliseconds: 460));
      // 400 px take 0.39 s.
      expect(MascotFloatPhysics.fallSeconds(400), closeTo(0.392, 0.001));
      expect(MascotFloatPhysics.fallSeconds(0), 0);
      expect(MascotFloatPhysics.slideSeconds(10), 0.18);
      expect(MascotFloatPhysics.slideSeconds(300), 0.25);
      expect(MascotFloatPhysics.slideSeconds(3000), 0.36);
    });

    testWidgets('straight down, faster and faster, flush on the edge, then '
        'along it to its place', (tester) async {
      final h = await lifted(tester);
      final path = await sendHome(tester, h);
      final landed = path.indexWhere((p) => p.dy == _home.dy);
      expect(landed, greaterThan(0));
      // It lands when a body falling 400 px from rest does.
      expect(
        (landed + 1) * 0.008,
        closeTo(MascotFloatPhysics.fallSeconds(drop), 0.03),
      );
      final falling = path.sublist(0, landed);
      // Straight down: its column does not change while it falls...
      expect(falling.every((p) => p.dx == from.dx), isTrue);
      // ...and every step is longer than the one before (gravity, from
      // rest: no ease, no constant speed).
      final steps = [
        for (var i = 1; i < falling.length; i++)
          falling[i].dy - falling[i - 1].dy,
      ];
      expect(steps.first, lessThan(1));
      for (var i = 1; i < steps.length; i++) {
        expect(steps[i], greaterThan(steps[i - 1]));
      }
      // A flush landing: never below the edge, no bounce back up.
      expect(path.every((p) => p.dy <= _home.dy), isTrue);
      expect(path.sublist(landed).every((p) => p.dy == _home.dy), isTrue);
      // Then along the edge to the dock's right end, and there it stays.
      final after = path.sublist(landed);
      for (var i = 1; i < after.length; i++) {
        expect(after[i].dx, greaterThanOrEqualTo(after[i - 1].dx));
      }
      final home = path.indexWhere((p) => p == _home);
      expect(
        (home - landed) * 0.008,
        closeTo(MascotFloatPhysics.slideSeconds(_home.dx - from.dx), 0.03),
      );
      expect(path.last, _home);
      expect(h.prefs.moved, isFalse);
      expect(h.prefs.placement, MascotPlacement.dock);
    });

    testWidgets('in the air while it falls, at rest once landed; nothing '
        'keeps running', (tester) async {
      final h = await lifted(tester);
      expect(h.pet.airborne, isFalse);
      unawaited(h.prefs.placeOnDock());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.pet.airborne, isTrue);
      expect(tester.binding.transientCallbackCount, 1, reason: 'its ticker');
      await _settle(tester, 1000);
      expect(h.pet.airborne, isFalse);
      expect(h.pet.state, MascotState.idle);
      expect(_box(tester).topLeft, _home);
      // The ticker is stopped; only the two idle timers it always had.
      expect(tester.binding.transientCallbackCount, 0);
      expect(debugMascotOverlayTimers, 2);
      final frames = debugMascotOverlayFrames;
      await _settle(tester, 5000);
      expect(debugMascotOverlayFrames, frames);
    });

    testWidgets('from its menu, and from a long press', (tester) async {
      await lifted(tester);
      await tester.tap(find.byKey(_sprite));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('mascot-menu-dock')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 150));
      final mid = _box(tester).topLeft;
      expect(mid.dx, from.dx);
      expect(mid.dy, inExclusiveRange(from.dy, _home.dy));
      await _settle(tester, 1000);
      expect(_box(tester).topLeft, _home);

      await _dragTo(tester, from);
      final press = await tester.startGesture(_box(tester).center);
      await tester.pump(const Duration(milliseconds: 500));
      await press.up();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('mascot-menu-dock')));
      await _settle(tester, 1000);
      expect(_box(tester).topLeft, _home);
    });

    testWidgets('a drop by finger still stays exactly where it is left', (
      tester,
    ) async {
      final h = await lifted(tester);
      final frames = debugMascotOverlayFrames;
      await _settle(tester, 3000);
      expect(_box(tester).topLeft, from);
      expect(debugMascotOverlayFrames, frames);
      expect(h.pet.airborne, isFalse);
      // On the dock too: it stands where it was let go, it does not travel
      // to the end.
      await _dragTo(tester, Offset(100, _dock.top - _size - 6));
      await _settle(tester, 1000);
      expect(_box(tester).left, closeTo(100, 0.5));
    });

    testWidgets('caught in mid-fall it is in the hand, and stays where it is '
        'put', (tester) async {
      final h = await lifted(tester);
      unawaited(h.prefs.placeOnDock());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 120));
      final g = await tester.startGesture(_box(tester).center);
      await g.moveBy(const Offset(-10, -10));
      await tester.pump();
      await g.moveTo(const Offset(200, 300));
      await g.up();
      await _settle(tester, 1000);
      expect(_box(tester).center.dx, closeTo(200, 0.5));
      expect(_box(tester).center.dy, closeTo(300, 0.5));
      expect(h.prefs.placement, MascotPlacement.free);
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('dock hidden or absent: it falls to the corner it has there', (
      tester,
    ) async {
      final h = await lifted(tester);
      h.geometry.publish(_owner, _handle, hidden: true);
      await _settle(tester);
      expect(_box(tester).topLeft, from);
      final path = await sendHome(tester, h);
      final corner = Offset(
        _home.dx,
        _screen.height - MascotFloatPhysics.cornerLift - _size,
      );
      final landed = path.indexWhere((p) => p.dy == corner.dy);
      expect(path.sublist(0, landed).every((p) => p.dx == from.dx), isTrue);
      expect(path.every((p) => p.dy <= corner.dy), isTrue);
      expect(path.last, corner);
    });

    testWidgets('its place above it: it springs up, 460 ms, easing out', (
      tester,
    ) async {
      // No dock: free at the very bottom, below where the corner is.
      final h = await _pump(tester, dock: false);
      await _dragTo(tester, const Offset(100, 796));
      expect(_box(tester).top, 796);
      final corner = Offset(
        _home.dx,
        _screen.height - MascotFloatPhysics.cornerLift - _size,
      );
      final path = await sendHome(tester, h);
      final home = path.indexWhere((p) => p == corner);
      expect(home * 0.008, closeTo(0.46, 0.04));
      expect(path.every((p) => p.dy <= 796 && p.dy >= corner.dy), isTrue);
      expect(path.last, corner);
    });

    testWidgets('a chat opening in mid-fall: it is gone, and at its place '
        'when it is back', (tester) async {
      final h = await lifted(tester);
      unawaited(h.prefs.placeOnDock());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 120));
      unawaited(
        h.navigator.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const _ChatPage()),
        ),
      );
      await _settle(tester, 200);
      expect(find.byKey(_sprite), findsNothing);
      expect(tester.takeException(), isNull);
      await _settle(tester, 600);
      // Nothing of the fall is left running behind the chat.
      final frames = debugMascotOverlayFrames;
      await _settle(tester, 2000);
      expect(debugMascotOverlayFrames, frames);
      expect(debugMascotOverlayTimers, 0);
      await h.pop(tester);
      expect(_box(tester).topLeft, _home);
      expect(debugMascotOverlayFrames, frames, reason: 'no late animation');
      expect(h.pet.airborne, isFalse);
    });

    testWidgets('the keyboard coming up in mid-fall ends it at its place', (
      tester,
    ) async {
      final h = await lifted(tester);
      unawaited(h.prefs.placeOnDock());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 120));
      h.insets.value = const _Insets(keyboard: 300);
      await _settle(tester, 300);
      expect(find.byKey(_sprite), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      h.insets.value = const _Insets();
      await _settle(tester, 300);
      expect(_box(tester).topLeft, _home);
    });

    testWidgets('reduced motion: it is there at once, no fall', (tester) async {
      final h = await lifted(tester, harness: _Harness()..reduce.value = true);
      unawaited(h.prefs.placeOnDock());
      await tester.pump();
      await tester.pump();
      expect(_box(tester).topLeft, _home);
      expect(h.pet.airborne, isFalse);
      expect(tester.binding.transientCallbackCount, 0);
      expect(debugMascotOverlayTimers, 0);
    });

    testWidgets('the app going to the background in mid-fall: it ends at its '
        'place, stored on the dock', (tester) async {
      final h = await lifted(tester);
      unawaited(h.prefs.placeOnDock());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 120));
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
      expect(_box(tester).topLeft, _home);
      expect(tester.binding.transientCallbackCount, 0);
      expect(debugMascotOverlayTimers, 0);
      expect(h.prefs.placement, MascotPlacement.dock);
      final stored = await SharedPreferences.getInstance();
      expect(stored.getKeys(), isEmpty, reason: 'home is the default');
      for (final s in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
      expect(_box(tester).topLeft, _home);
    });

    testWidgets('the screen turning in mid-fall: it is put at its place on '
        'the new one', (tester) async {
      final h = await lifted(tester);
      unawaited(h.prefs.placeOnDock());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 120));
      // Landscape: the dock is elsewhere now.
      tester.view.physicalSize = const Size(844, 390);
      final turned = Rect.fromLTWH(14, 316, 816, 60);
      h.geometry.publish(_owner, turned, hidden: false);
      await _settle(tester, 300);
      expect(tester.takeException(), isNull);
      expect(
        _box(tester).topLeft,
        Offset(
          turned.right - MascotFloatPhysics.dockEndInset - _size,
          turned.top + MascotFloatPhysics.dockOverlap - _size,
        ),
      );
      expect(tester.binding.transientCallbackCount, 0);
      expect(h.pet.airborne, isFalse);
    });
  });

  group('what it tells', () {
    testWidgets('a permission: the command and Permitir / Rechazar / Ver el '
        'chat', (tester) async {
      final answers = <bool>[];
      var opened = 0;
      final h = await _pump(tester);
      h.permissions.value = [
        _permission(h.permissions, answers, openChat: () => opened++),
      ];
      await _settle(tester);
      // It arrived while he was looking: the badge and "te necesita", no
      // bubble by itself.
      expect(find.byKey(_bubble), findsNothing);
      expect(find.byKey(_badge), findsOneWidget);
      expect(h.pet.state, MascotState.needsYou);
      await tester.tap(find.byKey(_sprite));
      await tester.pump();
      expect(find.text('Login tests'), findsOneWidget);
      expect(find.text('git push origin fix/login-tests'), findsOneWidget);
      expect(find.text('Permitir'), findsOneWidget);
      expect(find.text('Rechazar'), findsOneWidget);
      await tester.tap(find.text('Ver el chat'));
      await tester.pump();
      expect(opened, 1);
      expect(find.byKey(_bubble), findsNothing);
      await tester.tap(find.byKey(_sprite));
      await tester.pump();
      await tester.tap(find.text('Permitir'));
      await tester.pump();
      expect(answers, [true]);
      expect(find.byKey(_bubble), findsNothing);
      expect(find.byKey(_badge), findsNothing);
      expect(h.pet.state, MascotState.idle);
    });

    testWidgets('Rechazar answers no; answered elsewhere closes the bubble', (
      tester,
    ) async {
      final answers = <bool>[];
      final h = await _pump(tester);
      h.permissions.value = [_permission(h.permissions, answers)];
      await tester.pump();
      await tester.tap(find.byKey(_sprite));
      await tester.pump();
      await tester.tap(find.text('Rechazar'));
      await tester.pump();
      expect(answers, [false]);
      h.permissions.value = [_permission(h.permissions, answers)];
      await tester.pump();
      await tester.tap(find.byKey(_sprite));
      await tester.pump();
      expect(find.byKey(_bubble), findsOneWidget);
      h.permissions.value = const []; // answered in the chat
      await tester.pump();
      expect(find.byKey(_bubble), findsNothing);
    });

    testWidgets('with the Inicio card on screen a tap only hops', (
      tester,
    ) async {
      final h = _Harness()..cardVisible.value = true;
      await _pump(tester, harness: h);
      h.permissions.value = [_permission(h.permissions, [])];
      await _settle(tester);
      await tester.tap(find.byKey(_sprite));
      await tester.pump();
      expect(find.byKey(_bubble), findsNothing);
      expect(find.byKey(_badge), findsOneWidget);
    });

    testWidgets('told while off the dock screens, it waits for the next one '
        'and says it once', (tester) async {
      var seen = 0;
      final h = await _pump(tester);
      await h.push(tester, const Scaffold(body: Text('ajustes')), dock: false);
      h.notices.value = [_notice('profile:c1:forja#0', onSeen: () => seen++)];
      await _settle(tester, 300);
      expect(find.byKey(_sprite), findsNothing);
      expect(find.byKey(_bubble), findsNothing);
      expect(debugMascotOverlayTimers, 0);
      await h.pop(tester);
      expect(find.byKey(_bubble), findsOneWidget);
      await _settle(tester, 9500);
      expect(find.byKey(_bubble), findsNothing);
      await h.push(tester, const Scaffold(body: Text('ajustes')), dock: false);
      await h.pop(tester);
      expect(find.byKey(_bubble), findsNothing, reason: 'once');
      expect(seen, 0);
    });

    testWidgets('another profile: one line, one action that goes there', (
      tester,
    ) async {
      var went = 0;
      var seen = 0;
      final h = await _pump(tester);
      h.notices.value = [
        _notice(
          'profile:c1:forja#0',
          onAction: () => went++,
          onSeen: () => seen++,
        ),
      ];
      await _settle(tester);
      expect(find.byKey(_bubble), findsNothing);
      expect(find.text('1'), findsOneWidget, reason: 'the badge');
      await tester.tap(find.byKey(_sprite));
      await tester.pump();
      expect(find.text('Forja: Hermes respondió en Login'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('mascot-bubble-action')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('mascot-bubble-never')), findsNothing);
      await tester.tap(find.text('Ver'));
      await tester.pump();
      expect(went, 1);
      expect(seen, 1);
      expect(find.byKey(_bubble), findsNothing);
      expect(find.byKey(_badge), findsNothing, reason: 'seen: not counted');
      // Seen, it does not come up again on a tap: the menu does.
      await tester.tap(find.byKey(_sprite));
      await tester.pump();
      expect(find.byKey(const ValueKey('mascot-menu-hide')), findsOneWidget);
    });

    testWidgets('another instance: "Ir"; closing it counts as seen', (
      tester,
    ) async {
      var went = 0;
      var seen = 0;
      final h = await _pump(tester);
      h.notices.value = [
        _notice(
          'instance:c2#0',
          kind: MascotNoticeKind.instance,
          text: 'Casa tiene 3 novedades',
          action: 'Ir',
          onAction: () => went++,
          onSeen: () => seen++,
        ),
      ];
      await tester.pump();
      await tester.tap(find.byKey(_sprite));
      await tester.pump();
      expect(find.text('Casa tiene 3 novedades'), findsOneWidget);
      expect(find.text('Ir'), findsOneWidget);
      // A tap anywhere else closes it, and still reaches the page.
      await tester.tapAt(const Offset(60, 200));
      await tester.pump();
      expect(find.byKey(_bubble), findsNothing);
      expect(seen, 1);
      expect(went, 0);
    });

    testWidgets('it speaks up by itself once, when it comes back on screen', (
      tester,
    ) async {
      var seen = 0;
      final h = await _pump(tester);
      await h.push(tester, const _ChatPage());
      h.notices.value = [_notice('profile:c1:forja#0', onSeen: () => seen++)];
      await tester.pump();
      expect(find.byKey(_bubble), findsNothing, reason: 'hidden in a chat');
      await h.pop(tester);
      expect(find.byKey(_bubble), findsOneWidget);
      expect(
        find.byKey(_barrier),
        findsNothing,
        reason: 'it came by itself: it takes no touch from the page',
      );
      // Left alone it goes back behind the badge.
      await _settle(tester, 9500);
      expect(find.byKey(_bubble), findsNothing);
      expect(find.byKey(_badge), findsOneWidget);
      expect(seen, 0);
      // And it does not repeat itself.
      await h.push(tester, const _ChatPage());
      await h.pop(tester);
      expect(find.byKey(_bubble), findsNothing);
      expect(debugMascotOverlayTimers, 2);
    });

    testWidgets('a permission waiting when the app opens is said at once', (
      tester,
    ) async {
      final h = _Harness();
      h.permissions.value = [_permission(h.permissions, [])];
      await _pump(tester, harness: h);
      expect(find.text('git push origin fix/login-tests'), findsOneWidget);
      expect(find.byKey(_barrier), findsNothing);
      // A tap on the mascot keeps it open to be answered.
      await tester.tap(find.byKey(_sprite));
      await tester.pump();
      expect(find.text('Permitir'), findsOneWidget);
      expect(find.byKey(_barrier), findsOneWidget);
      await _settle(tester, 20000);
      expect(find.text('Permitir'), findsOneWidget);
    });

    testWidgets('a suggestion: once, never while busy, and "No sugerirme '
        'esto" is for good', (tester) async {
      var turnedOn = 0;
      MascotNotice suggestion() => MascotNotice(
        key: 'notifications-off',
        kind: MascotNoticeKind.suggestion,
        text: (s) => s.mascotSuggestNotifications,
        action: (s) => s.mascotSuggestTurnOn,
        onAction: () => turnedOn++,
      );
      final h = _Harness();
      h.notices.value = [suggestion()];
      await _pump(tester, harness: h);
      expect(find.text('Tienes las notificaciones apagadas'), findsOneWidget);
      expect(find.text('Activar'), findsOneWidget);
      expect(find.byKey(_badge), findsNothing, reason: 'not something waiting');
      await tester.tap(find.text('No sugerirme esto'));
      await _settle(tester);
      expect(find.byKey(_bubble), findsNothing);
      expect(turnedOn, 0);
      expect(h.prefs.mutedSuggestions, {'notifications-off'});
      final stored = await SharedPreferences.getInstance();
      expect(stored.getStringList(MascotPrefs.mutedKey), ['notifications-off']);
      // A new start: it is not suggested again.
      await tester.pumpWidget(const SizedBox());
      final again = _Harness();
      again.notices.value = [suggestion()];
      await _pump(tester, harness: again);
      expect(find.byKey(_bubble), findsNothing);
    });

    testWidgets('a suggestion only closed waits a week before coming back', (
      tester,
    ) async {
      final prefs = MascotPrefs();
      await prefs.ensureLoaded();
      final now = DateTime.utc(2026, 10, 12, 10);
      expect(prefs.maySuggest('x', now), isTrue);
      await prefs.markSuggested('x', now);
      expect(prefs.maySuggest('x', now.add(const Duration(days: 6))), isFalse);
      expect(prefs.maySuggest('x', now.add(const Duration(days: 7))), isTrue);
      final fresh = MascotPrefs();
      await fresh.ensureLoaded();
      expect(fresh.maySuggest('x', now.add(const Duration(days: 1))), isFalse);
      await fresh.muteSuggestion('x');
      expect(
        fresh.maySuggest('x', now.add(const Duration(days: 400))),
        isFalse,
      );
    });

    testWidgets('its menu: Hablar, Cambiar mascota, Ocultar', (tester) async {
      final h = await _pump(tester);
      await tester.tap(find.byKey(_sprite));
      await tester.pump();
      expect(find.text('Hablar'), findsOneWidget);
      expect(find.text('Cambiar mascota'), findsOneWidget);
      expect(find.text('Ocultar'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mascot-menu-talk')));
      await tester.pump();
      expect(h.talks, 1);
      expect(find.byKey(_bubble), findsNothing);
      await tester.tap(find.byKey(_sprite));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('mascot-menu-change')));
      await tester.pump();
      expect(h.changes, 1);
    });
  });

  group('accessibility', () {
    testWidgets('a button whose label says who it is, its state and what '
        'waits', (tester) async {
      final handle = tester.ensureSemantics();
      final h = await _pump(tester);
      SemanticsNode node() => tester.getSemantics(find.byKey(_sprite));
      expect(node().label, 'Mascota de Zoro. Zoro está en reposo');
      final data = node().getSemanticsData();
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      expect(data.hasAction(SemanticsAction.longPress), isTrue);
      expect(
        data.customSemanticsActionIds,
        isNotEmpty,
        reason: '"Ocultar" without opening the menu',
      );
      h.activity.value = MascotState.tool;
      await tester.pump();
      expect(node().label, contains('Zoro está usando una herramienta'));
      h.notices.value = [_notice('n', waiting: true)];
      await tester.pump();
      expect(node().label, contains('Zoro te necesita'));
      expect(node().label, contains('1 aviso pendiente'));
      handle.dispose();
    });

    testWidgets('a notice is a polite live region; nothing traps focus', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final h = await _pump(tester);
      h.notices.value = [_notice('n')];
      await tester.pump();
      await tester.tap(find.byKey(_sprite));
      await tester.pump();
      final bubble = tester.getSemantics(find.byKey(_bubble));
      expect(bubble.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
      // The page under it is still there for the reader, and no focus
      // scope was put around the bubble.
      expect(find.text('row 0'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(MascotOverlay),
          matching: find.byType(FocusScope),
        ),
        findsNothing,
      );
      handle.dispose();
    });

    testWidgets('an approval is announced assertively', (tester) async {
      final announced = <Map<dynamic, dynamic>>[];
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (
            message,
          ) async {
            if (message is Map && message['type'] == 'announce') {
              announced.add(message['data'] as Map<dynamic, dynamic>);
            }
            return null;
          });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler<dynamic>(
              SystemChannels.accessibility,
              null,
            ),
      );
      final handle = tester.ensureSemantics();
      final h = await _pump(tester);
      h.permissions.value = [_permission(h.permissions, [])];
      await tester.pump();
      await tester.tap(find.byKey(_sprite));
      await tester.pump();
      expect(announced, hasLength(1));
      expect(
        announced.single['message'],
        'Login tests te necesita. git push origin fix/login-tests',
      );
      expect(announced.single['assertiveness'], Assertiveness.assertive.index);
      handle.dispose();
    });
  });
}
