import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/halloween.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_motion.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';

import '../support/design_shots.dart';
import '../support/onboarding_fakes.dart';

const _root = ValueKey('season-root');
const _mark = ValueKey('console-mark');
const _fx = ValueKey('season-fx');

void main() {
  test('seasonOf: Halloween edges (isHalloweenSeason)', () {
    expect(isHalloweenSeason(DateTime(2026, 10, 24, 23, 59)), isFalse);
    expect(isHalloweenSeason(DateTime(2026, 10, 25)), isTrue);
    expect(isHalloweenSeason(DateTime(2026, 10, 31)), isTrue);
    expect(isHalloweenSeason(DateTime(2026, 11, 2, 23, 59)), isTrue);
    expect(isHalloweenSeason(DateTime(2026, 11, 3)), isFalse);
    expect(seasonOf(DateTime(2031, 10, 31)), Season.halloween);
  });

  test('seasonOf: Christmas edges, across the year', () {
    expect(seasonOf(DateTime(2026, 12, 19, 23, 59)), Season.none);
    expect(seasonOf(DateTime(2026, 12, 20)), Season.christmas);
    expect(seasonOf(DateTime(2026, 12, 31)), Season.christmas);
    expect(seasonOf(DateTime(2027, 1, 1)), Season.christmas);
    expect(seasonOf(DateTime(2027, 1, 6, 23, 59)), Season.christmas);
    expect(seasonOf(DateTime(2027, 1, 7)), Season.none);
    expect(seasonOf(DateTime(2026, 7, 1)), Season.none);
  });

  test('the clock is injectable and defaults to the real one', () {
    addTearDown(() => seasonClock = DateTime.now);
    seasonClock = () => DateTime(2026, 10, 31);
    expect(seasonOf(seasonClock()), Season.halloween);
  });

  Future<void> welcome(
    WidgetTester tester,
    DateTime day, {
    bool motion = false,
  }) async {
    addTearDown(() => seasonClock = DateTime.now);
    seasonClock = () => day;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    OnboardingMotion.openingPlayed = true;
    final manager = await onboardingManager();
    await tester.pumpWidget(
      RepaintBoundary(
        key: _root,
        child: onboardingHost(
          OnboardingScreen(
            connManager: manager,
            onDone: () {},
            playOpening: false,
          ),
          motion: motion,
        ),
      ),
    );
    if (motion) {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
    } else {
      await tester.pumpAndSettle();
    }
  }

  Future<List<int>> png(WidgetTester tester) async {
    final boundary =
        tester.renderObject(find.byKey(_root)) as RenderRepaintBoundary;
    return (await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return bytes!.buffer.asUint8List().toList();
    }))!;
  }

  ConsoleMarkPainter painter(WidgetTester tester) =>
      tester.widget<CustomPaint>(find.byKey(_mark)).painter!
          as ConsoleMarkPainter;

  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('out of season the welcome is the plain mark, byte for byte', (
    tester,
  ) async {
    await loadDesignFonts();
    await welcome(tester, DateTime(2026, 7, 1));
    expect(painter(tester).season, Season.none);
    expect(find.byKey(_fx), findsNothing);
    final july = await png(tester);
    await leave(tester);
    await welcome(tester, DateTime(2026, 8, 15));
    expect(await png(tester), july, reason: 'two plain days differ');
    await leave(tester);
    await welcome(tester, DateTime(2026, 10, 31));
    expect(painter(tester).season, Season.halloween);
    expect(await png(tester), isNot(july), reason: 'Halloween looks plain');
    await leave(tester);
  });

  testWidgets('Halloween: the pumpkin and 3 bats; none with reduced motion', (
    tester,
  ) async {
    await loadDesignFonts();
    await welcome(tester, DateTime(2026, 10, 31), motion: true);
    expect(painter(tester).season, Season.halloween);
    expect(ambientSeconds(painter(tester).ambient), isNotNull);
    final fx = tester.widget<CustomPaint>(find.byKey(_fx));
    expect((fx.painter! as SeasonFxPainter).count, 3);
    await leave(tester);
    await welcome(tester, DateTime(2026, 10, 31));
    expect(painter(tester).season, Season.halloween);
    expect(ambientSeconds(painter(tester).ambient), isNull, reason: 'flickers');
    expect(find.byKey(_fx), findsNothing);
    await leave(tester);
  });

  testWidgets('Christmas: Rudolph and 9 flakes; none with reduced motion', (
    tester,
  ) async {
    await loadDesignFonts();
    await welcome(tester, DateTime(2027, 1, 1), motion: true);
    expect(painter(tester).season, Season.christmas);
    expect(ambientSeconds(painter(tester).ambient), isNotNull);
    final fx = tester.widget<CustomPaint>(find.byKey(_fx));
    expect((fx.painter! as SeasonFxPainter).count, 9);
    await leave(tester);
    await welcome(tester, DateTime(2027, 1, 1));
    expect(painter(tester).season, Season.christmas);
    expect(ambientSeconds(painter(tester).ambient), isNull, reason: 'pulses');
    expect(find.byKey(_fx), findsNothing);
    await leave(tester);
  });

  test('the nose pulses 1 → .55 → 1 and rests at 1; the candle dips to .7', () {
    expect(pulseAt(null), 1);
    expect(pulseAt(0), closeTo(1, 1e-9));
    expect(pulseAt(.7), closeTo(.55, 1e-9));
    expect(flickerAt(null), 1);
    expect(flickerAt(0), 1);
    expect(flickerAt(1.7 * .45), closeTo(.7, 1e-9));
    expect(flickerAt(1.7 * .75), closeTo(.85, 1e-9));
  });
}
