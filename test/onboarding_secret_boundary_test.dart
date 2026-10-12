import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';

import 'support/onboarding_fakes.dart';

void main() {
  test(
    'setup help never sends a command or pairing credential to an agent',
    () {
      for (final path in [
        'lib/core/screens/onboarding/onboarding_scanner.dart',
        'lib/core/screens/onboarding_screen.dart',
      ]) {
        final source = File(path).readAsStringSync();
        for (final forbidden in [
          'agentPromptFor(',
          'sendMessage(',
          'chatCompletions(',
          'apiPost(',
          'hermes-mobile-setup',
          'curl ',
        ]) {
          expect(source, isNot(contains(forbidden)), reason: path);
        }
      }
    },
  );

  testWidgets('help explains the computer and provides an honest manual exit', (
    tester,
  ) async {
    final manager = await onboardingManager();
    var done = false;
    await tester.pumpWidget(
      onboardingHost(
        OnboardingScreen(connManager: manager, onDone: () => done = true),
      ),
    );
    await tapOnboarding(tester, 'onboarding-help');
    expect(find.textContaining('Terminal'), findsOneWidget);
    expect(find.textContaining('Pídeselo'), findsNothing);
    await tapOnboarding(tester, 'onboarding-back');
    await tapOnboarding(tester, 'onboarding-manual');
    expect(find.byType(InstanceEditScreen), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(done, isFalse);
    expect(manager.getConnections(), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
