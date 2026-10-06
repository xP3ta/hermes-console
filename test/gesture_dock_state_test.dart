import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GestureDockController c;
  late DateTime clock;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    c = GestureDockController()
      ..resetForTesting(settings: const GestureDockSettings(welcomeSeen: true));
    clock = DateTime(2026, 10, 6, 10);
    c.now = () => clock;
    c.attach(Object());
  });

  tearDown(() => c.resetForTesting());

  void taps(int n) {
    for (var i = 0; i < n; i++) {
      c.recordTap();
    }
  }

  group('tips', () {
    test('the swipe tip unlocks at 6 taps, not 5', () {
      taps(5);
      expect(c.tip.value, isNull);
      taps(1);
      expect(c.tip.value, DockGesture.swipe);
    });

    test('at most one tip per day', () {
      taps(6);
      expect(c.tip.value, DockGesture.swipe);
      c.tipNotNow();
      taps(10);
      expect(c.tip.value, isNull, reason: 'same day');
      clock = clock.add(const Duration(days: 1));
      taps(1);
      expect(c.tip.value, DockGesture.swipe);
    });

    test('"Ahora no" twice and that tip never comes back', () {
      taps(6);
      c.tipNotNow();
      clock = clock.add(const Duration(days: 1));
      taps(1);
      expect(c.tip.value, DockGesture.swipe);
      c.tipNotNow();
      clock = clock.add(const Duration(days: 1));
      // 7 taps: swipe is retired and the hide tip needs 9.
      c.maybeShowTip();
      expect(c.tip.value, isNull);
      taps(2);
      expect(c.value.taps, 9);
      expect(c.tip.value, DockGesture.hide);
    });

    test('"Ya lo sé" marks it learned', () {
      taps(6);
      c.tipKnown();
      expect(c.tip.value, isNull);
      expect(c.value.learned, contains(DockGesture.swipe));
    });

    test('unlock order: up needs swipe learned and 12 taps; hold needs up', () {
      c.resetForTesting(
        settings: const GestureDockSettings(
          welcomeSeen: true,
          taps: 14,
          learned: {DockGesture.swipe, DockGesture.hide},
        ),
      );
      c.now = () => clock;
      c.attach(Object());
      c.maybeShowTip();
      expect(c.tip.value, DockGesture.up);
      c.tipKnown();
      clock = clock.add(const Duration(days: 1));
      c.maybeShowTip();
      expect(c.tip.value, isNull, reason: 'hold needs 15 taps');
      taps(1);
      expect(c.tip.value, DockGesture.hold);
    });

    test('the hide tip never shows in fixed mode', () {
      c.resetForTesting(
        settings: const GestureDockSettings(
          welcomeSeen: true,
          taps: 20,
          mode: DockHideMode.fixed,
          learned: {DockGesture.swipe, DockGesture.up, DockGesture.hold},
        ),
      );
      c.now = () => clock;
      c.maybeShowTip();
      expect(c.tip.value, isNull);
    });

    test('never over a pending permission, an open sheet or a drag', () {
      taps(5);
      c.needsYou = () => true;
      taps(1);
      expect(c.tip.value, isNull);
      c.needsYou = () => false;
      c.sheetOpen = true;
      c.maybeShowTip();
      expect(c.tip.value, isNull);
      c.sheetOpen = false;
      c.dragging = true;
      c.maybeShowTip();
      expect(c.tip.value, isNull);
      c.dragging = false;
      c.maybeShowTip();
      expect(c.tip.value, DockGesture.swipe);
    });

    test(
      'no tips before the welcome, during the tour or when switched off',
      () {
        c.resetForTesting(settings: const GestureDockSettings(taps: 6));
        c.now = () => clock;
        c.maybeShowTip();
        expect(c.tip.value, isNull, reason: 'welcome not seen');
        c.resetForTesting(
          settings: const GestureDockSettings(welcomeSeen: true, taps: 6),
        );
        c.now = () => clock;
        c.startTour();
        c.maybeShowTip();
        expect(c.tip.value, isNull, reason: 'tour');
        c.skipTour();
        c.resetForTesting(
          settings: const GestureDockSettings(
            welcomeSeen: true,
            taps: 6,
            tips: false,
          ),
        );
        c.now = () => clock;
        c.maybeShowTip();
        expect(c.tip.value, isNull, reason: 'tips off');
      },
    );
  });

  group('auto mode', () {
    setUp(() async => c.setMode(DockHideMode.auto));

    test('hides past 28 dp of scroll down, shows past 14 dp up', () {
      c.handleScroll(delta: 20, pixels: 200, minExtent: 0);
      expect(c.hidden.value, isFalse);
      c.handleScroll(delta: 9, pixels: 209, minExtent: 0);
      expect(c.hidden.value, isTrue);
      c.handleScroll(delta: -10, pixels: 199, minExtent: 0);
      expect(c.hidden.value, isTrue);
      c.handleScroll(delta: -5, pixels: 194, minExtent: 0);
      expect(c.hidden.value, isFalse);
    });

    test('near the top (under 24 dp) it always shows', () {
      c.setHidden(true);
      c.handleScroll(delta: 5, pixels: 20, minExtent: 0);
      expect(c.hidden.value, isFalse);
    });

    test('a change of direction restarts the count', () {
      c.handleScroll(delta: 20, pixels: 200, minExtent: 0);
      c.handleScroll(delta: -2, pixels: 198, minExtent: 0);
      c.handleScroll(delta: 20, pixels: 218, minExtent: 0);
      expect(c.hidden.value, isFalse);
    });

    test('without a dock on screen scrolling does nothing', () {
      final other = GestureDockController()
        ..resetForTesting(
          settings: const GestureDockSettings(mode: DockHideMode.auto),
        );
      other.handleScroll(delta: 100, pixels: 400, minExtent: 0);
      expect(other.hidden.value, isFalse);
    });

    test('no inactivity auto-hide: time alone never hides the dock', () async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.hidden.value, isFalse);
    });
  });

  group('modes', () {
    test('fixed refuses to hide and shows a hidden dock', () async {
      c.setHidden(true);
      await c.setMode(DockHideMode.fixed);
      expect(c.hidden.value, isFalse);
      c.setHidden(true);
      expect(c.hidden.value, isFalse);
    });

    test('manual is the default', () {
      expect(const GestureDockSettings().mode, DockHideMode.manual);
    });
  });

  group('persistence', () {
    test('settings round-trip through SharedPreferences', () async {
      await c.setMode(DockHideMode.auto);
      await c.setGestures(false);
      c.learn(DockGesture.hold);
      await Future<void>.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(GestureDockController.storageKey)!;
      final loaded = GestureDockSettings.fromJson(jsonDecode(raw));
      expect(loaded.mode, DockHideMode.auto);
      expect(loaded.gestures, isFalse);
      expect(loaded.learned, contains(DockGesture.hold));
    });

    test('a fresh controller loads what was stored', () async {
      SharedPreferences.setMockInitialValues({
        GestureDockController.storageKey: jsonEncode(
          const GestureDockSettings(
            mode: DockHideMode.fixed,
            opaque: true,
          ).toJson(),
        ),
      });
      final fresh = GestureDockController();
      await fresh.ensureLoaded();
      expect(fresh.value.mode, DockHideMode.fixed);
      expect(fresh.value.opaque, isTrue);
    });

    test('corrupt or future payloads fall back to defaults', () {
      expect(GestureDockSettings.fromJson('x').mode, DockHideMode.manual);
      expect(
        GestureDockSettings.fromJson({
          'schema_version': 99,
          'mode': 'fixed',
        }).mode,
        DockHideMode.manual,
      );
      final odd = GestureDockSettings.fromJson({
        'schema_version': 1,
        'mode': 7,
        'gestures': 'yes',
        'learned': ['swipe', 'bogus', 3],
        'taps': -4,
        'skips': {'hide': 2, 'nope': 1, 'up': 'x'},
      });
      expect(odd.mode, DockHideMode.manual);
      expect(odd.gestures, isTrue);
      expect(odd.learned, {DockGesture.swipe});
      expect(odd.taps, 0);
      expect(odd.skips, {DockGesture.hide: 2});
    });
  });
}
