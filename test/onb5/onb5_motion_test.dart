// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// ONB5: the motion of the polish, frame by frame (tester.pump, not a
// recording), and the reduced-motion end states.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/manual_connect_page.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_motion.dart';

import '../support/onboarding_fakes.dart';
import 'onb5_support.dart';

const _mark = ValueKey('console-mark');

Future<void> _ms(WidgetTester tester, int ms) async {
  for (var i = 0; i < ms; i += 10) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void main() {
  setUp(() => OnboardingMotion.openingPlayed = true);

  testWidgets('scan -> confirm: the logo never crosses the title', (
    tester,
  ) async {
    await openOnboarding(tester, motion: true);
    await scan(tester, lanNoPassword, motion: true);
    // Until the confirmation exists, the logo fades; then it appears in its
    // own place and never goes through the title.
    final title = find.textContaining('192.168.1.20:9119');
    var crossings = 0;
    var seenTitle = 0;
    Rect? at900;
    for (var ms = 0; ms <= 4000; ms += 50) {
      await tester.pump(const Duration(milliseconds: 50));
      final marks = find.byKey(_mark);
      if (marks.evaluate().isEmpty || title.evaluate().isEmpty) continue;
      // A frame in which the logo is still invisible (the fade has just
      // begun and the rect is measured after it) cannot cross anything.
      if (opacityOf(tester, marks.first) < .05) continue;
      final big = biggestText(tester, '192.168.1.20:9119');
      seenTitle++;
      if (tester.getRect(marks.first).bottom > tester.getRect(big).top + 0.5) {
        crossings++;
      }
    }
    expect(seenTitle, greaterThan(10));
    expect(crossings, 0, reason: 'the logo overlapped the title');
    await tester.pump(const Duration(seconds: 3));
    final end = tester.getRect(find.byKey(_mark).first);
    expect(
      end.bottom,
      lessThanOrEqualTo(
        tester.getRect(biggestText(tester, '192.168.1.20:9119')).top,
      ),
    );
    at900 = end;
    expect(at900.center.dx, closeTo(195, 2));
  });

  testWidgets('scan -> confirm: from the first frame of the confirmation the '
      'logo is already in its place (±2 dp)', (tester) async {
    await openOnboarding(tester, motion: true);
    await scan(tester, lanNoPassword, motion: true);
    await pumpUntil(tester, find.byKey(const ValueKey('onboarding-confirm')));
    await _ms(tester, 900);
    final at900 = tester.getRect(find.byKey(_mark).first).center;
    await tester.pump(const Duration(seconds: 3));
    final end = tester.getRect(find.byKey(_mark).first).center;
    expect((at900 - end).distance, lessThan(2));
  });

  testWidgets('Connect by hand enters in place: fade and scale, no slide', (
    tester,
  ) async {
    await openOnboarding(tester, motion: true);
    await tester.tap(find.byKey(const ValueKey('onboarding-manual')));
    await tester.pump();
    await _ms(tester, 80);
    final button = find.byKey(const ValueKey('manual-connect'));
    // No horizontal travel (the old page route slid in from the right).
    expect(tester.getRect(button).left, closeTo(24, 3));
    expect(opacityOf(tester, button), lessThan(1));
    expect(
      find.ancestor(
        of: find.byType(ManualConnectPage),
        matching: find.byType(SlideTransition),
      ),
      findsNothing,
    );
    // The page below does not slide away either.
    await tester.pump(const Duration(seconds: 2));
    expect(opacityOf(tester, button), 1);
    expect(tester.getRect(button).left, closeTo(24, 0.5));
  });

  testWidgets('Connect by hand: the fields rise one after the other', (
    tester,
  ) async {
    await openOnboarding(tester, motion: true);
    await tester.tap(find.byKey(const ValueKey('onboarding-manual')));
    await tester.pump();
    await _ms(tester, 300);
    double r(String k) => riseOf(tester, find.byKey(ValueKey(k)));
    expect(r('manual-address'), greaterThan(r('manual-user')));
    expect(r('manual-user'), greaterThan(r('manual-password')));
    expect(r('manual-password'), greaterThan(r('manual-connect')));
    expect(r('manual-connect'), lessThan(1));
  });

  testWidgets(
    'welcome -> camera: the logo and the glow fade, the panel rises',
    (tester) async {
      await openOnboarding(tester, motion: true);
      expect(opacityOf(tester, find.byKey(_mark)), 1);
      await tester.tap(find.byKey(const ValueKey('onboarding-scan')));
      // Frame 0: still there (it was cut here before).
      await tester.pump();
      expect(find.byKey(_mark), findsWidgets);
      await _ms(tester, 40);
      final fading = opacityOf(tester, find.byKey(_mark).first);
      expect(fading, lessThan(1));
      expect(fading, greaterThan(0));
      await _ms(tester, 60);
      final panel = find.byKey(const ValueKey('qr-help-panel'));
      final early = tester.getRect(panel).top;
      await tester.pump(const Duration(milliseconds: 900));
      final done = tester.getRect(panel).top;
      expect(early, greaterThan(done + 20));
      await tester.pump(const Duration(seconds: 2));
      expect(tester.getRect(panel).top, closeTo(done, 0.5));
      expect(opacityOf(tester, panel), 1);
    },
  );

  testWidgets('confirmation: password and consent rise; success: the actions '
      'come after the content', (tester) async {
    await openOnboarding(tester, motion: true);
    await scan(tester, lanNoPassword, motion: true);
    await pumpUntil(tester, find.byKey(const ValueKey('onb3-password')));
    await _ms(tester, 400);
    final password = find.byKey(const ValueKey('onb3-password'));
    final consent = find.byKey(const ValueKey('pairing-http-consent'));
    expect(riseOf(tester, password), lessThan(1));
    expect(riseOf(tester, consent), lessThan(riseOf(tester, password)));
    await tester.pump(const Duration(seconds: 2));
    expect(riseOf(tester, password), 1);
    expect(riseOf(tester, consent), 1);
  });

  testWidgets('success: Open chat / Go home wait for the rows', (tester) async {
    await openLink(tester, fakeFullPairing, motion: true);
    await tester.tap(find.byKey(const ValueKey('onboarding-confirm')));
    final done = find.byKey(const ValueKey('onboarding-done'));
    await pumpUntil(tester, done);
    await _ms(tester, 300);
    expect(riseOf(tester, done), lessThan(1));
    await tester.pump(const Duration(seconds: 3));
    expect(riseOf(tester, done), 1);
  });

  group('reduced motion: the first frame is the end state', () {
    testWidgets('Connect by hand', (tester) async {
      await openOnboarding(tester);
      await tester.tap(find.byKey(const ValueKey('onboarding-manual')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      for (final k in [
        'manual-address',
        'manual-user',
        'manual-password',
        'manual-connect',
      ]) {
        expect(riseOf(tester, find.byKey(ValueKey(k))), 1, reason: k);
      }
      // A plain fade: no scale on the way in.
      expect(
        find.ancestor(
          of: find.byType(ManualConnectPage),
          matching: find.byType(ScaleTransition),
        ),
        findsNothing,
      );
    });

    testWidgets('confirmation', (tester) async {
      await openOnboarding(tester);
      await tester.tap(find.byKey(const ValueKey('onboarding-scan')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      detect!(lanNoPassword);
      await pumpUntil(tester, find.byKey(const ValueKey('onb3-password')));
      for (final k in ['onb3-password', 'pairing-http-consent']) {
        expect(riseOf(tester, find.byKey(ValueKey(k))), 1, reason: k);
      }
    });

    testWidgets('the camera panel', (tester) async {
      await openOnboarding(tester);
      await tester.tap(find.byKey(const ValueKey('onboarding-scan')));
      await tester.pump();
      final panel = find.byKey(const ValueKey('qr-help-panel'));
      await pumpUntil(tester, panel);
      await tester.pump(const Duration(milliseconds: 16));
      final first = tester.getRect(panel).top;
      expect(riseOf(tester, panel), 1);
      await tester.pump(const Duration(seconds: 2));
      expect(tester.getRect(panel).top, closeTo(first, 0.5));
    });

    testWidgets('the consent has no animation to wait for', (tester) async {
      await openOnboarding(tester);
      await scan(tester, lanNoPassword);
      await tapOnboarding(tester, 'pairing-http-consent');
      expect(find.byType(AnimatedContainer), findsWidgets);
      final box = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: find.byKey(const ValueKey('pairing-http-consent')),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      expect(box.duration, Duration.zero);
    });
  });
}
