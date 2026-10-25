// SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';

import 'support/onboarding_fakes.dart';

/// POPLOOP (Play Console ANR on 1.3.0, «Input dispatching timed out»): on the
/// guided setup help (`ManualSetupPage`: first step, empty history) the
/// route's PopScope said «cannot pop», so back reached `_back`, which asked
/// `maybePop` again, which met the same PopScope and called `_back` again: a
/// microtask loop that never let the main thread read input.
///
/// An outer PopScope on the same route counts every refused pop and, past
/// [_loopLimit], closes the route itself: a loop fails this test on the
/// counter instead of hanging the runner.
const _loopLimit = 50;

class _Harness {
  int refusedPops = 0;
}

Future<_Harness> _open(WidgetTester tester, {required bool guided}) async {
  final manager = await onboardingManager();
  await tester.pumpWidget(onboardingHost(const Text('below')));
  final navigator = tester.state<NavigatorState>(find.byType(Navigator));
  final harness = _Harness();
  navigator.push(
    MaterialPageRoute<void>(
      builder: (_) => PopScope(
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          harness.refusedPops++;
          if (harness.refusedPops == _loopLimit) navigator.pop();
        },
        child: OnboardingScreen(
          connManager: manager,
          onDone: () {},
          guided: guided,
          playOpening: false,
          simpleConnectEnabled: false,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byType(OnboardingScreen), findsOneWidget);
  return harness;
}

void main() {
  group('guided setup help (first step, nothing behind it)', () {
    testWidgets('system back closes it once, with no pop loop', (
      tester,
    ) async {
      final harness = await _open(tester, guided: true);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(
        harness.refusedPops,
        0,
        reason: 'back on the guided help is a pop, never a refused one',
      );
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(find.text('below'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('its own back button closes it once, with no pop loop', (
      tester,
    ) async {
      final harness = await _open(tester, guided: true);

      await tapOnboarding(tester, 'onboarding-back');

      expect(harness.refusedPops, 0);
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(find.text('below'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('first launch (not guided), unchanged', () {
    testWidgets('back on the welcome leaves', (tester) async {
      final harness = await _open(tester, guided: false);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(harness.refusedPops, 0);
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(find.text('below'), findsOneWidget);
    });

    testWidgets('back on a later step goes one step back and stays', (
      tester,
    ) async {
      final harness = await _open(tester, guided: false);
      await tapOnboarding(tester, 'onboarding-help');
      expect(find.byKey(const ValueKey('onboarding-back')), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(harness.refusedPops, 1, reason: 'one refusal, one step back');
      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('onboarding-help')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
