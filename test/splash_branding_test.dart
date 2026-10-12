import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/animated_hermes_logo.dart';

void main() {
  // ns1215: the Flutter splash screen is gone (owner decision: open straight
  // into the app); its tests moved to ns1215_startup_handoff_test. The brand
  // mark checks below still cover onboarding/About.
  testWidgets('orbit advances while platform animations are enabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('bordeaux'),
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

  for (final themeId in ['bordeaux', 'claude-light']) {
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
}
