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
        OnboardingScreen(
          simpleConnectEnabled: false,
          connManager: manager,
          onDone: () => done = true,
        ),
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

  test('the typed password lives only in memory during the sign-in', () {
    const path = 'lib/core/services/native_password_login.dart';
    final source = File(path).readAsStringSync();
    for (final forbidden in [
      'print(',
      'debugPrint',
      'log(',
      'SharedPreferences',
      'SecureStorage',
      'DashboardSecrets',
      'basicAuth',
      r'$password',
      r'$username',
    ]) {
      expect(source, isNot(contains(forbidden)), reason: forbidden);
    }
    // The password is an argument of run(), never a field of the service.
    expect(source, isNot(contains('final String password')));
    expect(source, isNot(contains('String? password')));
    expect(source, isNot(contains('_password')));
    final screen = File(
      'lib/core/screens/dashboard_setup_screen.dart',
    ).readAsStringSync();
    expect(screen, isNot(contains('NativePasswordLogin(password')));
    expect(
      RegExp(r"(SavedConnection|copyWith)\([^)]*_secret").hasMatch(screen),
      isFalse,
    );
  });

  test(
    'the v2 pairing password never reaches toString, hashCode or storage',
    () {
      final source = File(
        'lib/core/services/pairing_link.dart',
      ).readAsStringSync();
      final start = source.indexOf('class DashboardPairingLink');
      expect(start, greaterThan(0));
      final v2 = source.substring(start);
      expect(v2, isNot(contains('SharedPreferences')));
      expect(v2, isNot(contains('SecureStorage')));
      expect(v2, isNot(contains('print(')));
      expect(v2, isNot(contains('debugPrint')));
      expect(v2, isNot(contains(r'$_password')));
      expect(v2, isNot(contains(r'$password')));
      expect(v2, isNot(contains('Object.hash(url, user, label, _password')));
    },
  );

  test('the v2 link password only goes to the native sign-in', () {
    final source = File(
      'lib/core/screens/onboarding_screen.dart',
    ).readAsStringSync();
    final start = source.indexOf('void _receiveV2(');
    final end = source.indexOf('bool _needsConsent(');
    expect(start, greaterThan(0));
    expect(end, greaterThan(start));
    final v2 = source.substring(start, end);
    for (final forbidden in [
      'SharedPreferences',
      'print(',
      'debugPrint',
      'Navigator',
      'password: link.password',
      r'$secret',
    ]) {
      expect(v2, isNot(contains(forbidden)), reason: forbidden);
    }
    // The only sink of the secret is the native sign-in.
    expect(RegExp(r'password: secret').allMatches(v2), hasLength(1));
    expect(v2, contains('NativePasswordLogin().run('));
    final store = RegExp(r'setDashboardSecrets\([^;]*\);').firstMatch(v2)![0]!;
    expect(store, isNot(contains('password')));
    expect(store, isNot(contains('username')));
  });
}
