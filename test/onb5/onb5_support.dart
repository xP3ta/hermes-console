// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// Shared harness of the ONB5 tests: the onboarding on a phone of any size,
// a camera that hands its detector back, and small finders.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/services/pairing_link.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/onboarding_fakes.dart';

String v2Link(String url, {String? pass}) =>
    'hermes://pair?v=2&url=${Uri.encodeQueryComponent(url)}&user=admin'
    '${pass == null ? '' : '&pass=${Uri.encodeQueryComponent(pass)}'}';

/// A v2 code of a Hermes on the LAN over http with no password: the screen
/// with the field AND the consent.
final lanNoPassword = v2Link('http://192.168.1.20:9119');

ValueChanged<String>? detect;
Widget camera(ValueChanged<String> d, ValueChanged<bool> _) {
  detect = d;
  return const SizedBox();
}

void phone(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  // A status bar of 24 and a gesture bar of 16, as on the QA phone.
  const bars = FakeViewPadding(top: 24, bottom: 16);
  tester.view.padding = bars;
  tester.view.viewPadding = bars;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);
}

Future<Strings> openOnboarding(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double scale = 1,
  bool motion = false,
  String theme = 'dark',
  String language = 'es',
}) async {
  phone(tester, size);
  // A fresh tree each time: a test may open the screen at several sizes.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    onboardingHost(
      OnboardingScreen(
        connManager: await onboardingManager(),
        onDone: () {},
        playOpening: false,
        cameraBuilder: camera,
        diagnostics: OnboardingDiagnostics(),
      ),
      language: language,
      theme: theme,
      scale: scale,
      motion: motion,
    ),
  );
  if (motion) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 3));
  } else {
    await tester.pumpAndSettle();
  }
  return onboardingStrings(tester);
}

/// Taps «Scan» and feeds the camera [link]; with [motion] it pumps in steps.
Future<void> scan(
  WidgetTester tester,
  String link, {
  bool motion = false,
}) async {
  final button = find.byKey(const ValueKey('onboarding-scan'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  detect!(link);
  if (!motion) {
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  }
}

Rect rectOf(WidgetTester tester, String key) =>
    tester.getRect(find.byKey(ValueKey(key)));

/// The product of every Opacity and FadeTransition above [f].
double opacityOf(WidgetTester tester, Finder f) {
  var v = 1.0;
  for (final o in tester.widgetList<Opacity>(
    find.ancestor(of: f, matching: find.byType(Opacity)),
  )) {
    v *= o.opacity;
  }
  for (final o in tester.widgetList<FadeTransition>(
    find.ancestor(of: f, matching: find.byType(FadeTransition)),
  )) {
    v *= o.opacity.value;
  }
  return v;
}

/// The product of the Opacity widgets only: what a RiseIn does, without the
/// fade of a route or of the step switcher above it.
double riseOf(WidgetTester tester, Finder f) {
  var v = 1.0;
  for (final o in tester.widgetList<Opacity>(
    find.ancestor(of: f, matching: find.byType(Opacity)),
  )) {
    v *= o.opacity;
  }
  return v;
}

/// Pumps frames until [f] is on the screen (at most [limit]).
Future<void> pumpUntil(
  WidgetTester tester,
  Finder f, {
  Duration limit = const Duration(seconds: 8),
}) async {
  var spent = Duration.zero;
  while (f.evaluate().isEmpty && spent < limit) {
    await tester.pump(const Duration(milliseconds: 16));
    spent += const Duration(milliseconds: 16);
  }
  expect(f, findsOneWidget, reason: 'never appeared');
}

/// The biggest text that holds [needle]: the title, not the small notes.
Finder biggestText(WidgetTester tester, String needle) {
  final all = find.textContaining(needle).evaluate().toList();
  all.sort(
    (a, b) => ((b.widget as Text).style?.fontSize ?? 0).compareTo(
      (a.widget as Text).style?.fontSize ?? 0,
    ),
  );
  return find.byWidget(all.first.widget);
}

/// The strings of whatever screen is on top (the onboarding sits offstage
/// under Connect by hand).
Strings stringsOf(WidgetTester tester, Type screen) =>
    Strings.of(tester.element(find.byType(screen)));

/// The onboarding opened on a saved code, with the fake Dashboard checks.
Future<void> openLink(
  WidgetTester tester,
  PairingLink link, {
  Size size = const Size(390, 844),
  double scale = 1,
  bool motion = false,
  String theme = 'dark',
}) async {
  phone(tester, size);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    onboardingHost(
      OnboardingScreen(
        connManager: await onboardingManager(),
        onDone: () {},
        playOpening: false,
        diagnostics: OnboardingDiagnostics(),
        initialLink: link,
      ),
      scale: scale,
      theme: theme,
      motion: motion,
    ),
  );
  if (motion) {
    await tester.pump(const Duration(seconds: 3));
  } else {
    await tester.pumpAndSettle();
  }
}
