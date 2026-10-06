import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/splash_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/animated_hermes_logo.dart';

void main() {
  testWidgets('orbit advances while platform animations are enabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('crimson'),
        home: const Scaffold(
          body: AnimatedHermesLogo(animate: true, orbit: true, glow: false),
        ),
      ),
    );

    final orbitPaint = find.descendant(
      of: find.byType(AnimatedHermesLogo),
      matching: find.byType(CustomPaint),
    );
    final before = tester.widget<CustomPaint>(orbitPaint).painter;
    await tester.pump(const Duration(milliseconds: 240));
    final after = tester.widget<CustomPaint>(orbitPaint).painter;
    expect(after, isNot(same(before)));
  });

  String assetName(Image image) {
    final provider = image.image;
    // cacheWidth wraps the asset in a ResizeImage; assert on the source asset.
    final asset = provider is ResizeImage ? provider.imageProvider : provider;
    return (asset as AssetImage).assetName;
  }

  for (final themeId in ['crimson', 'claude-light']) {
    testWidgets('brand logo shows the untinted Console mark on $themeId', (
      tester,
    ) async {
      final theme = AppTheme.fromId(themeId);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: AnimatedHermesLogo(
              animate: false,
              glow: false,
              color: theme.hermes.accent,
            ),
          ),
        ),
      );

      final mark = find.byKey(const Key('animated_hermes_logo_mark'));
      expect(mark, findsOneWidget);
      expect(assetName(tester.widget<Image>(mark)), kConsoleMarkAsset);
      expect(kConsoleMarkAsset, 'assets/branding/console_mark.png');
      // One logo everywhere: the mark is never re-tinted per theme.
      expect(
        find.ancestor(of: mark, matching: find.byType(ColorFiltered)),
        findsNothing,
      );
      expect(
        tester.widgetList<Image>(find.byType(Image)).map(assetName),
        everyElement(kConsoleMarkAsset),
      );
      final emblem = tester.widget<Container>(
        find.byKey(const Key('animated_hermes_logo_emblem')),
      );
      final decoration = emblem.decoration! as BoxDecoration;
      expect(decoration.color, isNull);
      expect(decoration.gradient, isNull);
    });
  }

  test('Console brand assets ship in the bundle', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final asset in [kConsoleMarkAsset, kConsoleIconAsset]) {
      expect(File(asset).existsSync(), isTrue, reason: asset);
      expect(pubspec, contains('- $asset'), reason: asset);
    }
  });

  testWidgets('splash keeps the Console mark and themes orbit and progress', (
    tester,
  ) async {
    final theme = AppTheme.fromId('crimson');
    final colors = theme.hermes;
    final expected =
        ThemeContrast.meets(colors.accent, colors.background, minimum: 3)
        ? colors.accent
        : colors.accentText;
    var completed = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: SplashScreen(onDone: () => completed = true),
      ),
    );
    await tester.pump();

    final logo = tester.widget<AnimatedHermesLogo>(
      find.byType(AnimatedHermesLogo),
    );
    expect(logo.color, expected);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byKey(const ValueKey('splash-progress-bar')), findsOneWidget);
    final fill = tester.widget<Container>(
      find.byKey(const ValueKey('splash-progress-fill')),
    );
    expect(fill.color, expected);
    expect(find.byKey(const Key('animated_hermes_logo_mark')), findsOneWidget);

    final beforePercent = tester
        .widget<Text>(find.byKey(const ValueKey('splash-progress-percent')))
        .data;
    await tester.pump(const Duration(milliseconds: 450));
    final midwayPercent = tester
        .widget<Text>(find.byKey(const ValueKey('splash-progress-percent')))
        .data;
    expect(midwayPercent, isNot(beforePercent));

    await tester.pump(const Duration(milliseconds: 2550));
    expect(completed, isFalse);
    final leaving = tester.widget<AnimatedOpacity>(
      find.byKey(const Key('splash-content-opacity')),
    );
    expect(leaving.opacity, 0);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, colors.background);
    await tester.pump(const Duration(milliseconds: 460));
    expect(completed, isTrue);
  });

  testWidgets('splash projects real startup milestones as a percentage', (
    tester,
  ) async {
    final progress = ValueNotifier<double>(0.34);
    addTearDown(progress.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SplashScreen(ready: false, progress: progress, onDone: () {}),
      ),
    );
    await tester.pump();

    expect(find.text('34%'), findsOneWidget);
    progress.value = 0.92;
    await tester.pump();
    expect(find.text('92%'), findsOneWidget);
  });

  testWidgets(
    'splash keeps 1 2 and 3 digit percentages aligned in a stable slot',
    (tester) async {
      final progress = ValueNotifier<double>(0.01);
      addTearDown(progress.dispose);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.10)),
          child: MaterialApp(
            home: SplashScreen(ready: false, progress: progress, onDone: () {}),
          ),
        ),
      );
      await tester.pump();

      final barFinder = find.byKey(const ValueKey('splash-progress-bar'));
      final trackFinder = find.byKey(const ValueKey('splash-progress-track'));
      final slotFinder = find.byKey(
        const ValueKey('splash-progress-percent-slot'),
      );
      final percentFinder = find.byKey(
        const ValueKey('splash-progress-percent'),
      );

      final initialBar = tester.getRect(barFinder);
      final initialTrack = tester.getRect(trackFinder);
      final initialSlot = tester.getRect(slotFinder);
      final initialPercent = tester.getRect(percentFinder);
      expect(initialBar.width, 168);
      expect(initialTrack.width, 120);
      expect(initialSlot.width, 40);
      expect(initialSlot.left - initialTrack.right, 8);
      expect(initialPercent.left, closeTo(initialSlot.left, 0.01));
      expect(initialPercent.center.dy, closeTo(initialTrack.center.dy, 0.5));

      for (final milestone in <double>[0.10, 1.0]) {
        progress.value = milestone;
        await tester.pump();

        final bar = tester.getRect(barFinder);
        final track = tester.getRect(trackFinder);
        final slot = tester.getRect(slotFinder);
        final percent = tester.getRect(percentFinder);
        expect(bar, initialBar);
        expect(track, initialTrack);
        expect(slot, initialSlot);
        expect(percent.left, closeTo(initialPercent.left, 0.01));
        expect(percent.right, lessThanOrEqualTo(slot.right));
        expect(percent.center.dy, closeTo(track.center.dy, 0.5));
      }

      expect(find.text('100%'), findsOneWidget);
    },
  );

  testWidgets('splash waits for Home readiness after its minimum duration', (
    tester,
  ) async {
    var completed = false;
    var ready = false;

    Widget app() => MaterialApp(
      home: SplashScreen(ready: ready, onDone: () => completed = true),
    );

    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 3360));

    expect(completed, isFalse);
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const Key('splash-content-opacity')),
          )
          .opacity,
      1,
    );

    ready = true;
    await tester.pumpWidget(app());
    await tester.pump();
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const Key('splash-content-opacity')),
          )
          .opacity,
      0,
    );
    await tester.pump(const Duration(milliseconds: 460));
    expect(completed, isTrue);
  });
}
