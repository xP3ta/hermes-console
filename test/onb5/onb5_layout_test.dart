// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// ONB5: no RenderFlex overflow on any screen at 320 dp and 2x text, in dark
// and light, and the keyboard never hides Connect or the focused field.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/manual_connect_page.dart';

import '../support/design_shots.dart' show loadDesignFonts;
import '../support/onboarding_fakes.dart';
import 'onb5_support.dart';

Future<void> _manualWithConsent(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('onboarding-manual')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('manual-address')),
    'http://192.168.1.20:9119',
  );
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('manual-consent')), findsOneWidget);
}

void main() {
  for (final theme in ['console', 'console-light']) {
    for (final (name, scale) in [('320', 1.0), ('320 at 2x', 2.0)]) {
      const small = Size(320, 640);
      final screens = <String, Future<void> Function(WidgetTester)>{
        'welcome': (t) =>
            openOnboarding(t, size: small, scale: scale, theme: theme),
        'help': (t) async {
          await openOnboarding(t, size: small, scale: scale, theme: theme);
          await tapOnboarding(t, 'onboarding-help');
          expect(find.byKey(const ValueKey('onboarding-help-scan')), findsOne);
        },
        'camera': (t) async {
          await openOnboarding(t, size: small, scale: scale, theme: theme);
          await t.ensureVisible(find.byKey(const ValueKey('onboarding-scan')));
          await t.tap(find.byKey(const ValueKey('onboarding-scan')));
          await t.pump();
          await t.pump(const Duration(seconds: 2));
          expect(find.byKey(const ValueKey('qr-help-panel')), findsOne);
        },
        'confirm with password and consent': (t) async {
          await openOnboarding(t, size: small, scale: scale, theme: theme);
          await scan(t, lanNoPassword);
          expect(find.byKey(const ValueKey('onb3-password')), findsOne);
          expect(find.byKey(const ValueKey('pairing-http-consent')), findsOne);
        },
        'connect by hand with consent': (t) async {
          await openOnboarding(t, size: small, scale: scale, theme: theme);
          await t.ensureVisible(
            find.byKey(const ValueKey('onboarding-manual')),
          );
          await _manualWithConsent(t);
        },
        'connected': (t) async {
          await openLink(
            t,
            fakeFullPairing,
            size: small,
            scale: scale,
            theme: theme,
          );
          await tapOnboarding(t, 'onboarding-confirm');
          await t.pumpAndSettle();
          expect(find.byKey(const ValueKey('onboarding-done')), findsOne);
        },
      };
      for (final entry in screens.entries) {
        testWidgets('${entry.key} · $theme · $name: no overflow', (
          tester,
        ) async {
          await entry.value(tester);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  group('with the keyboard (320 dp of inset on 390x844)', () {
    void keyboard(WidgetTester tester) {
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    }

    void expectAbove(WidgetTester tester, String key, {double top = 0}) {
      final r = rectOf(tester, key);
      expect(r.bottom, lessThanOrEqualTo(844 - 320), reason: '$key $r');
      expect(r.top, greaterThanOrEqualTo(top), reason: '$key $r');
      expect(find.byKey(ValueKey(key)).hitTestable(), findsOneWidget);
    }

    testWidgets('Connect by hand: password and Connect stay visible', (
      tester,
    ) async {
      await loadDesignFonts();
      await openOnboarding(tester);
      await tester.tap(find.byKey(const ValueKey('onboarding-manual')));
      await tester.pumpAndSettle();
      keyboard(tester);
      await tester.tap(find.byKey(const ValueKey('manual-password')));
      await tester.pumpAndSettle();
      expect(find.byType(ManualConnectPage), findsOneWidget);
      expectAbove(tester, 'manual-password');
      expectAbove(tester, 'manual-connect');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Connect by hand on a short phone: the focused field is above '
        'the keyboard', (tester) async {
      await loadDesignFonts();
      await openOnboarding(tester, size: const Size(390, 640));
      await tester.tap(find.byKey(const ValueKey('onboarding-manual')));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('manual-password')));
      await tester.tap(find.byKey(const ValueKey('manual-password')));
      await tester.pumpAndSettle();
      final field = rectOf(tester, 'manual-password');
      expect(field.bottom, lessThanOrEqualTo(640 - 320), reason: '$field');
      expect(field.top, greaterThanOrEqualTo(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Connect with…: the password field and Connect stay visible', (
      tester,
    ) async {
      await loadDesignFonts();
      await openOnboarding(tester);
      await scan(tester, lanNoPassword);
      keyboard(tester);
      await tester.tap(find.byKey(const ValueKey('onb3-password')));
      await tester.pumpAndSettle();
      expectAbove(tester, 'onb3-password');
      expectAbove(tester, 'onboarding-confirm');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Connect with…: same at 320x640 and 2x text', (tester) async {
      await loadDesignFonts();
      await openOnboarding(tester, size: const Size(320, 640), scale: 2);
      await scan(tester, lanNoPassword);
      tester.view.viewInsets = const FakeViewPadding(bottom: 250);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('onb3-password')));
      await tester.tap(find.byKey(const ValueKey('onb3-password')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final field = rectOf(tester, 'onb3-password');
      expect(field.bottom, lessThanOrEqualTo(640 - 250));
      expect(field.top, greaterThanOrEqualTo(0));
      expect(
        rectOf(tester, 'onboarding-confirm').bottom,
        lessThanOrEqualTo(640 - 250),
      );
    });
  });
}
