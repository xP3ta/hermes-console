import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/guide/guide_layer.dart';
import 'package:hermes_android/core/guide/guided_tour.dart';
import 'package:hermes_android/core/screens/guided_tours_screen.dart';
import 'package:hermes_android/core/screens/lock_screen.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

GuideController get _g => GuideController.instance;
GestureDockController get _dock => GestureDockController.instance;

const _spotlight = ValueKey('guide-spotlight');
const _card = ValueKey('guide-card');

Widget _app({
  required Widget home,
  ValueListenable<bool>? locked,
  ThemeData? theme,
  double textScale = 1,
  bool reduceMotion = false,
  GlobalKey<NavigatorState>? navigatorKey,
  TransitionBuilder? outer,
}) => MaterialApp(
  navigatorKey: navigatorKey,
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: theme ?? AppTheme.fromId('dark'),
  builder: (context, child) {
    Widget layer = MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: reduceMotion,
      ),
      child: GuideLayer(locked: locked, child: child!),
    );
    if (outer != null) layer = outer(context, layer);
    return layer;
  },
  home: home,
);

/// A Home-like screen with the General tour's targets except the profile
/// switcher, which a step must then skip.
class _FakeHome extends StatelessWidget {
  final VoidCallback? onUnder;
  final ValueListenable<double>? boardTop;

  const _FakeHome({this.onUnder, this.boardTop});

  @override
  Widget build(BuildContext context) => Scaffold(
    // Like the real dock, which stays put under the keyboard.
    resizeToAvoidBottomInset: false,
    body: Stack(
      children: [
        Positioned(
          top: 40,
          left: 16,
          child: Text('Servidor', key: const ValueKey('home-header-title')),
        ),
        ValueListenableBuilder<double>(
          valueListenable: boardTop ?? ValueNotifier(120),
          builder: (context, top, _) => Positioned(
            top: top,
            left: 16,
            right: 16,
            height: 120,
            child: const ColoredBox(
              key: ValueKey('home-widget-glance'),
              color: Colors.teal,
            ),
          ),
        ),
        Positioned(
          top: 300,
          left: 16,
          child: ElevatedButton(
            key: const ValueKey('under'),
            onPressed: onUnder,
            child: const Text('Debajo'),
          ),
        ),
        Positioned(
          left: 14,
          right: 14,
          bottom: 20,
          height: 60,
          child: Semantics(
            key: const ValueKey('gesture-dock'),
            container: true,
            child: const ColoredBox(color: Colors.indigo),
          ),
        ),
      ],
    ),
  );
}

void _phone(WidgetTester tester, {Size size = const Size(390, 844)}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

Rect? _hole(WidgetTester tester) {
  final paint = find.byKey(_spotlight);
  if (paint.evaluate().isEmpty) return null;
  return (tester.widget<CustomPaint>(paint).painter! as GuideSpotlightPainter)
      .hole;
}

/// The spotlight is the target's own rect (plus its padding), not a guess.
void _expectSpotlightOn(WidgetTester tester, Finder target) {
  expect(target, findsOneWidget);
  final rect = tester.getRect(target);
  final screen =
      Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
  final want = rect.inflate(guideSpotlightPadding).intersect(screen);
  final hole = _hole(tester);
  expect(hole, isNotNull, reason: 'no spotlight');
  expect(hole!.overlaps(rect), isTrue, reason: '$hole vs $rect');
  for (final (a, b) in [
    (hole.left, want.left),
    (hole.top, want.top),
    (hole.right, want.right),
    (hole.bottom, want.bottom),
  ]) {
    expect(a, closeTo(b, .5), reason: 'spotlight $hole, target $rect');
  }
}

String _title(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(_card),
        matching: find.byKey(const ValueKey('guide-card-title')),
      ),
    )
    .data!;

Strings _es(WidgetTester tester) =>
    Strings.of(tester.element(find.byType(Scaffold).first));

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Every label in the semantics tree.
List<String> _labels(WidgetTester tester) {
  final out = <String>[];
  void visit(SemanticsNode node) {
    if (node.label.isNotEmpty) out.add(node.label);
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  final root =
      tester.binding.renderViews.first.owner?.semanticsOwner?.rootSemanticsNode;
  if (root != null) visit(root);
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    _g.resetForTesting();
    _dock.resetForTesting(settings: const GestureDockSettings());
    DockGeometry.instance.resetForTesting();
    FeatureFlags.instance.resetForTesting(gestureDock: true);
  });

  tearDown(() {
    _g.resetForTesting();
    GuidedToursScreen.debugChatScreen = null;
    GuidedToursScreen.debugBotsScreen = null;
  });

  group('engine', () {
    testWidgets('skips a step whose target is not on screen; the spotlight '
        'sits on each real target; finishing persists', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(home: const _FakeHome()));
      _g.start(GuideTourId.general);
      await _settle(tester);
      final s = _es(tester);

      expect(_title(tester), s.gt1215HomeBoardTitle);
      expect(find.text('Paso 1 de 4'), findsOneWidget);
      _expectSpotlightOn(
        tester,
        find.byKey(const ValueKey('home-widget-glance')),
      );
      expect(find.byKey(const ValueKey('guide-back')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('guide-next')));
      await _settle(tester);
      expect(_title(tester), s.gt1215HomeServerTitle);
      _expectSpotlightOn(
        tester,
        find.byKey(const ValueKey('home-header-title')),
      );

      // No profile switcher on this screen: its step is skipped, never
      // pointed at nothing.
      await tester.tap(find.byKey(const ValueKey('guide-next')));
      await _settle(tester);
      expect(_title(tester), s.gt1215HomeDockTitle);
      expect(find.text('Paso 4 de 4'), findsOneWidget);
      _expectSpotlightOn(tester, find.byKey(const ValueKey('gesture-dock')));
      expect(find.text(s.gdTourDone), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('guide-next')));
      await _settle(tester);
      expect(_g.active, isFalse);
      expect(find.byKey(const ValueKey('guide-layer')), findsNothing);
      expect(_g.isDone(GuideTourId.general), isTrue);
      final prefs = await SharedPreferences.getInstance();
      final stored = jsonDecode(prefs.getString(GuideController.storageKey)!);
      expect(stored['done'], ['general']);
      // A fresh engine reads it back.
      _g.resetForTesting();
      await _g.ensureLoaded();
      expect(_g.isDone(GuideTourId.general), isTrue);
    });

    testWidgets('Atrás goes back, Saltar ends without marking it done and '
        'leaves nothing that blocks taps', (tester) async {
      _phone(tester);
      var under = 0;
      await tester.pumpWidget(_app(home: _FakeHome(onUnder: () => under++)));
      _g.start(GuideTourId.general);
      await _settle(tester);
      final s = _es(tester);
      // While the tour runs the screen under it takes no taps.
      await tester.tap(
        find.byKey(const ValueKey('under')),
        warnIfMissed: false,
      );
      expect(under, 0);

      await tester.tap(find.byKey(const ValueKey('guide-next')));
      await _settle(tester);
      expect(_title(tester), s.gt1215HomeServerTitle);
      await tester.tap(find.byKey(const ValueKey('guide-back')));
      await _settle(tester);
      expect(_title(tester), s.gt1215HomeBoardTitle);

      await tester.tap(find.byKey(const ValueKey('guide-skip')));
      await _settle(tester);
      expect(_g.active, isFalse);
      expect(_g.isDone(GuideTourId.general), isFalse);
      expect(find.byKey(const ValueKey('guide-layer')), findsNothing);
      expect(find.byKey(const ValueKey('guide-scrim')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('under')));
      expect(under, 1);
      // Nothing comes back later either.
      await tester.pump(const Duration(seconds: 10));
      expect(find.byKey(const ValueKey('guide-layer')), findsNothing);
    });

    testWidgets('the spotlight follows its widget when it moves', (
      tester,
    ) async {
      _phone(tester);
      final top = ValueNotifier<double>(120);
      await tester.pumpWidget(_app(home: _FakeHome(boardTop: top)));
      _g.start(GuideTourId.general);
      await _settle(tester);
      final board = find.byKey(const ValueKey('home-widget-glance'));
      _expectSpotlightOn(tester, board);
      top.value = 200;
      await _settle(tester);
      expect(tester.getRect(board).top, 200);
      _expectSpotlightOn(tester, board);
      _g.skip();
      await _settle(tester);
    });

    testWidgets('a tour asked for a screen that is not there draws nothing '
        'and gives up', (tester) async {
      _phone(tester);
      var under = 0;
      await tester.pumpWidget(_app(home: _FakeHome(onUnder: () => under++)));
      _g.start(GuideTourId.chat);
      await _settle(tester);
      expect(find.byKey(const ValueKey('guide-layer')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('under')));
      expect(under, 1);
      await tester.pump(GuideController.startWindow);
      await tester.pump();
      expect(_g.active, isFalse);
    });

    testWidgets('a route over the screen hides the step at once; the screen '
        'going away ends the tour with no barrier left', (tester) async {
      _phone(tester);
      final nav = GlobalKey<NavigatorState>();
      var under = 0;
      await tester.pumpWidget(
        _app(
          navigatorKey: nav,
          home: _FakeHome(onUnder: () => under++),
        ),
      );
      _g.start(GuideTourId.general);
      await _settle(tester);
      expect(find.byKey(_card), findsOneWidget);
      // Something the app opens by itself (a permission sheet, a route).
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey('other'),
                onPressed: () => under += 10,
                child: const Text('Otra'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _settle(tester);
      expect(find.byKey(_card), findsNothing, reason: 'target covered');
      await tester.tap(find.byKey(const ValueKey('other')));
      expect(under, 10, reason: 'no barrier over the new route');
      await tester.pump(GuideController.lostGrace);
      await _settle(tester);
      expect(_g.active, isFalse, reason: 'its screen is gone');
      expect(_g.isDone(GuideTourId.general), isFalse);
      nav.currentState!.pop();
      await tester.pump(const Duration(milliseconds: 400));
      await _settle(tester);
      expect(find.byKey(const ValueKey('guide-layer')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('under')));
      expect(under, 11);
    });

    testWidgets('never over App Lock: it waits behind the lock screen and '
        'comes back on the same step after unlock', (tester) async {
      _phone(tester);
      SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
      final prefs = await SharedPreferences.getInstance();
      final lock = AppLockService(prefs);
      lock.unlock();
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        _app(
          navigatorKey: nav,
          locked: lock.locked,
          home: const _FakeHome(),
          outer: (context, child) =>
              AppLockGate(lock: lock, navigatorKey: nav, child: child!),
        ),
      );
      _g.start(GuideTourId.general);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('guide-next')));
      await _settle(tester);
      final s = _es(tester);
      expect(_title(tester), s.gt1215HomeServerTitle);

      lock.lockNow();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(LockScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('guide-layer')), findsNothing);
      expect(find.byKey(_card), findsNothing);
      // Long past every timer: still waiting, not ended.
      await tester.pump(const Duration(seconds: 20));
      expect(find.byKey(_card), findsNothing);
      expect(_g.active, isTrue);

      lock.unlock();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await _settle(tester);
      expect(find.byType(LockScreen), findsNothing);
      expect(_title(tester), s.gt1215HomeServerTitle);
      _expectSpotlightOn(
        tester,
        find.byKey(const ValueKey('home-header-title')),
      );
      _g.skip();
      await _settle(tester);
    });

    testWidgets('320 dp, text at 2x and a light theme: the card fits and '
        'never covers its target', (tester) async {
      _phone(tester, size: const Size(320, 640));
      await tester.pumpWidget(
        _app(
          home: const _FakeHome(),
          textScale: 2,
          theme: AppTheme.fromId('github'),
        ),
      );
      expect(
        Theme.of(tester.element(find.byType(Scaffold))).brightness,
        Brightness.light,
      );
      _g.start(GuideTourId.general);
      await _settle(tester);
      final screen = Offset.zero & const Size(320, 640);
      for (final target in [
        'home-widget-glance',
        'home-header-title',
        'gesture-dock',
      ]) {
        expect(tester.takeException(), isNull);
        final card = tester.getRect(
          find.byKey(const ValueKey('guide-card-box')),
        );
        final rect = tester.getRect(find.byKey(ValueKey(target)));
        expect(
          screen.inflate(.5).contains(card.topLeft),
          isTrue,
          reason: '$target $card',
        );
        expect(
          screen.inflate(.5).contains(card.bottomRight),
          isTrue,
          reason: '$target $card',
        );
        expect(
          card.overlaps(rect),
          isFalse,
          reason: '$target: $card over $rect',
        );
        _expectSpotlightOn(tester, find.byKey(ValueKey(target)));
        await tester.tap(find.byKey(const ValueKey('guide-next')));
        await _settle(tester);
      }
      expect(_g.active, isFalse);
    });

    testWidgets('TalkBack: the step is read and what is behind is blocked '
        'until the tour ends', (tester) async {
      _phone(tester);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(home: const _FakeHome()));
      expect(_labels(tester).any((l) => l.contains('Debajo')), isTrue);
      _g.start(GuideTourId.general);
      await _settle(tester);
      final s = _es(tester);
      final labels = _labels(tester);
      bool says(String text) => labels.any((l) => l.contains(text));
      expect(says(s.gt1215HomeBoardTitle), isTrue, reason: '$labels');
      expect(says(s.gt1215HomeBoardBody), isTrue, reason: '$labels');
      expect(says(s.gdTourSkip), isTrue, reason: '$labels');
      expect(says('Debajo'), isFalse, reason: '$labels');
      _g.skip();
      await _settle(tester);
      expect(_labels(tester).any((l) => l.contains('Debajo')), isTrue);
      handle.dispose();
    });

    testWidgets('reduced motion: a step on screen asks for no frames', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(
        _app(home: const _FakeHome(), reduceMotion: true),
      );
      _g.start(GuideTourId.general);
      await _settle(tester);
      expect(find.byKey(_card), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isFalse);
      _g.skip();
      await _settle(tester);
    });

    testWidgets('keyboard: starting closes it, and a target under it is '
        'skipped', (tester) async {
      _phone(tester);
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        _app(
          home: Scaffold(
            resizeToAvoidBottomInset: false,
            body: Stack(
              children: [
                const _FakeHome(),
                Positioned(
                  top: 360,
                  left: 16,
                  width: 200,
                  child: TextField(focusNode: focus),
                ),
              ],
            ),
          ),
        ),
      );
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      _g.start(GuideTourId.general);
      await _settle(tester);
      expect(focus.hasFocus, isFalse);
      // The keyboard is still on its way down: the dock under it is not a
      // step.
      await tester.tap(find.byKey(const ValueKey('guide-next')));
      await _settle(tester);
      expect(find.text(_es(tester).gdTourDone), findsOneWidget);
      expect(_title(tester), _es(tester).gt1215HomeServerTitle);
      _g.skip();
      await _settle(tester);
    });
  });

  group('Recorrido guiado in Ajustes', () {
    Widget stack(GlobalKey<NavigatorState> nav) =>
        _app(navigatorKey: nav, home: const _FakeHome());

    Future<void> openList(
      WidgetTester tester,
      GlobalKey<NavigatorState> nav,
    ) async {
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Ajustes')),
        ),
      );
      nav.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const GuidedToursScreen()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('lists General, Chat, Bots and Dock; General goes back to '
        'Home and runs there', (tester) async {
      _phone(tester);
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(stack(nav));
      GuidedToursScreen.debugChatScreen = (_) =>
          const Scaffold(body: Text('chat'));
      GuidedToursScreen.debugBotsScreen = (_) =>
          const Scaffold(body: Text('bots'));
      await openList(tester, nav);
      for (final tour in GuideTourId.values) {
        expect(
          find.byKey(ValueKey('guided-tour-${tour.name}')),
          findsOneWidget,
          reason: tour.name,
        );
      }
      await tester.tap(find.byKey(const ValueKey('guided-tour-general')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await _settle(tester);
      expect(find.byType(GuidedToursScreen), findsNothing);
      expect(_g.tour, GuideTourId.general);
      expect(_title(tester), _es(tester).gt1215HomeBoardTitle);
      await tester.tap(find.byKey(const ValueKey('guide-skip')));
      await _settle(tester);
    });

    testWidgets('finished tours say so; there is no tour of the dock', (
      tester,
    ) async {
      _phone(tester);
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(stack(nav));
      await openList(tester, nav);
      expect(find.textContaining('· Visto'), findsNothing);
      expect(find.byKey(const ValueKey('guided-tour-dock')), findsNothing);
      _g.start(GuideTourId.general);
      await _settle(tester);
      _g.finish();
      await _settle(tester);
      await openList(tester, nav);
      expect(find.text('General · Visto'), findsOneWidget);
    });
  });
}
