// SPDX-License-Identifier: GPL-3.0-only
// SWITCH: the simple connect is on in every variant without any dart-define.
// The welcome mounted with NO simpleConnectEnabled argument must offer
// the two doors; the constant itself must be true by default.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/flavor.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';

import '../support/onboarding_fakes.dart';

void main() {
  test('kSimpleConnectEnabled is true without any dart-define', () {
    expect(kSimpleConnectEnabled, isTrue);
  });

  for (final language in ['es', 'en']) {
    testWidgets('$language: default welcome offers the two doors', (
      tester,
    ) async {
      final manager = await onboardingManager();
      await tester.pumpWidget(
        onboardingHost(
          OnboardingScreen(
            connManager: manager,
            onDone: () {},
            playOpening: false,
          ),
          language: language,
        ),
      );
      await tester.pumpAndSettle();
      final s = onboardingStrings(tester);
      expect(find.text(s.onb4HaveHermes), findsOneWidget);
      expect(find.text(s.onb4NoHermes), findsOneWidget);
      expect(s.onb4HaveHermes, language == 'es' ? 'Ya tengo Hermes' : isNotEmpty);
    });

    testWidgets('$language: switch forced off keeps the same welcome', (
      tester,
    ) async {
      final manager = await onboardingManager();
      await tester.pumpWidget(
        onboardingHost(
          OnboardingScreen(
            connManager: manager,
            onDone: () {},
            simpleConnectEnabled: false,
            playOpening: false,
          ),
          language: language,
        ),
      );
      await tester.pumpAndSettle();
      final s = onboardingStrings(tester);
      expect(find.text(s.onb4HaveHermes), findsOneWidget);
      expect(find.text(s.onb4NoHermes), findsOneWidget);
    });
  }
}
