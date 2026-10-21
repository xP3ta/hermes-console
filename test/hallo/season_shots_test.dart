import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/halloween.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_motion.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';

import '../support/design_shots.dart';
import '../support/onboarding_fakes.dart';
import 'season_home_test.dart' show pumpHome;

const _root = ValueKey('season-shot-root');

Future<void> _shot(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull);
  final boundary =
      tester.renderObject(find.byKey(_root)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final dir = Directory('build/onboarding_shots')
      ..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<void> _frames(WidgetTester tester, int n) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  for (final (season, day) in [
    ('halloween', DateTime(2026, 10, 31)),
    ('christmas', DateTime(2026, 12, 25)),
  ]) {
    for (final theme in ['dark', 'light']) {
      for (final (size, scale, tag) in [
        (const Size(390, 844), 1.0, '390'),
        (const Size(320, 640), 2.0, '320_2x'),
      ]) {
        testWidgets('SEASON shots $season $theme $tag', (tester) async {
          await loadDesignFonts();
          addTearDown(() => seasonClock = DateTime.now);
          seasonClock = () => day;
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final name = 'season_${season}_%_${theme}_$tag';
          Widget host(Widget child, {bool motion = false}) => RepaintBoundary(
            key: _root,
            child: onboardingHost(
              child,
              theme: theme,
              scale: scale,
              motion: motion,
            ),
          );
          OnboardingMotion.openingPlayed = true;

          // Welcome with its motion on (bats / snow), then at rest, then help.
          final manager = await onboardingManager();
          await tester.pumpWidget(
            host(
              OnboardingScreen(
                connManager: manager,
                onDone: () {},
                playOpening: false,
              ),
              motion: true,
            ),
          );
          await _frames(tester, 14);
          await _shot(tester, name.replaceFirst('%', 'welcome_motion'));
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpWidget(
            host(OnboardingScreen(connManager: manager, onDone: () {})),
          );
          await tester.pumpAndSettle();
          await _shot(tester, name.replaceFirst('%', 'welcome'));
          await tapOnboarding(tester, 'onboarding-help');
          await _shot(tester, name.replaceFirst('%', 'help'));

          // «Conectar con…» and «Conectado».
          final gate = Completer<void>();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpWidget(
            host(
              OnboardingScreen(
                connManager: await onboardingManager(),
                onDone: () {},
                diagnostics: OnboardingDiagnostics()..gate = gate,
                initialLink: fakeFullPairing,
              ),
            ),
          );
          await tester.pumpAndSettle();
          await _shot(tester, name.replaceFirst('%', 'confirm'));
          await tapOnboarding(tester, 'onboarding-confirm');
          await tester.pump(const Duration(milliseconds: 100));
          await _shot(tester, name.replaceFirst('%', 'connecting'));
          gate.complete();
          await tester.pumpAndSettle();
          await _shot(tester, name.replaceFirst('%', 'success'));
          await tester.pumpWidget(const SizedBox.shrink());

          // «Conectado» with the motion on.
          await tester.pumpWidget(
            host(
              OnboardingScreen(
                connManager: await onboardingManager(),
                onDone: () {},
                diagnostics: OnboardingDiagnostics(),
                initialLink: fakeFullPairing,
              ),
              motion: true,
            ),
          );
          await _frames(tester, 4);
          await tester.tap(find.byKey(const ValueKey('onboarding-confirm')));
          await _frames(tester, 16);
          await _shot(tester, name.replaceFirst('%', 'success_motion'));
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 1));

          // Home.
          await pumpHome(
            tester,
            day,
            size: size,
            scale: scale,
            theme: theme,
            root: _root,
          );
          await _shot(tester, name.replaceFirst('%', 'home'));
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }
}
