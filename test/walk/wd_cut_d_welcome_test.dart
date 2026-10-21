// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// WD (CUT-D, D9), revised by ONB4: the welcome carries one plain line and no
// Dashboard jargon, the same with the simple connect on or off.
// Synthetic fixtures only.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/onboarding_fakes.dart';

Future<Strings> _welcome(
  WidgetTester tester, {
  required bool simpleConnect,
  required String language,
}) async {
  final manager = await onboardingManager();
  await tester.pumpWidget(
    onboardingHost(
      OnboardingScreen(
        connManager: manager,
        onDone: () {},
        simpleConnectEnabled: simpleConnect,
        playOpening: false,
      ),
      language: language,
    ),
  );
  await tester.pumpAndSettle();
  return onboardingStrings(tester);
}

void main() {
  const expected = {
    'es':
        'Console es el mando de tu Hermes, el que tienes en tu ordenador o en un servidor.',
    'en':
        'Console is the remote for your Hermes, the one on your computer or on a server.',
  };
  for (final language in ['es', 'en']) {
    for (final simpleConnect in [true, false]) {
      testWidgets('$language: welcome body, simple connect $simpleConnect', (
        tester,
      ) async {
        final s = await _welcome(
          tester,
          simpleConnect: simpleConnect,
          language: language,
        );
        expect(find.text(expected[language]!), findsOneWidget);
        expect(find.text(s.onb4WelcomeBody), findsOneWidget);
        expect(
          find.byKey(const ValueKey('onboarding-dashboard-explain')),
          findsNothing,
        );
      });
    }
  }
}
