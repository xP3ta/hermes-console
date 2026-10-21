import 'dart:io';
import 'package:flutter/material.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_widgets.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/services/pairing_link.dart';
import 'support/onboarding_fakes.dart';

const _unixSetup =
    'curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/'
    'hermes-dashboard-setup.sh | sh';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('public guidance has no executable installer or Bridge prompt', () {
    for (final file in [
      'lib/core/screens/onboarding/manual_setup_page.dart',
      'lib/core/screens/onboarding/onboarding_scanner.dart',
      'lib/core/screens/onboarding/onboarding_widgets.dart',
      'lib/core/screens/onboarding/onboarding_motion.dart',
      'lib/core/screens/onboarding_screen.dart',
    ]) {
      final source = File(file).readAsStringSync();
      for (final forbidden in [
        'hermes-mobile-setup',
        'hermes-pair.sh',
        'hermes-pair.ps1',
        'hermes_bridge.py',
        'bridgePort',
        'curl -',
        '| iex',
      ]) {
        expect(source.contains(forbidden), isFalse, reason: file);
      }
    }
  });
  test(
    'legacy link preserves official destinations but discards retired secrets',
    () {
      final canary = ['retired', 'secret', 'canary'].join('-');
      final link = PairingLink.tryParse(
        'hermes://pair?host=127.0.0.1&port=9131&token=official-key&dashboard=http%3A%2F%2F127.0.0.1%3A8643&label=lab&bridge=invalid&bridge_token=$canary',
      )!;
      expect(link.host, '127.0.0.1');
      expect(link.port, 9131);
      expect(link.token, 'official-key');
      expect(link.dashboardUrl, 'http://127.0.0.1:8643');
      expect(link.label, 'lab');
      expect(link.toDraftConnection().apiKey, 'official-key');
      expect(link.build().contains(canary), isFalse);
      expect(
        Uri.parse(link.build()).queryParameters.containsKey('bridge'),
        isFalse,
      );
      expect(
        Uri.parse(link.build()).queryParameters.containsKey('bridge_token'),
        isFalse,
      );
    },
  );
  test(
    'malformed official query returns null without logging incoming secrets',
    () {
      final canary = ['private', 'query', 'canary'].join('-');
      final printed = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) printed.add(message);
      };
      try {
        final result = PairingLink.tryParse(
          'hermes://pair?host=lab&port=8642&token=%FF&bridge_token=$canary',
        );
        expect(result, isNull);
        expect(printed.join().contains(canary), isFalse);
      } finally {
        debugPrint = previous;
      }
    },
  );
  test('malformed retired query values are ignored', () {
    final result = PairingLink.tryParse(
      'hermes://pair?host=lab&port=8642&token=official-key&bridge_token=%FF&bridge=%FF',
    );
    expect(result?.token, 'official-key');
  });
  testWidgets('help uses the one official command and keeps manual entry', (
    tester,
  ) async {
    final manager = await onboardingManager();
    await tester.pumpWidget(
      onboardingHost(
        OnboardingScreen(
          simpleConnectEnabled: false,
          connManager: manager,
          onDone: () {},
        ),
        language: 'en',
      ),
    );
    await tester.pumpAndSettle();
    await tapOnboarding(tester, 'onboarding-help');
    expect(
      tester.widget<OnbCodeBlock>(find.byType(OnbCodeBlock)).command,
      _unixSetup,
    );
    // Whatever the help lets a person copy is that one line, taken from
    // its one place; and no word of the retired Mobile Bridge anywhere on
    // the screen.
    for (final block in tester.widgetList<OnbCodeBlock>(
      find.byType(OnbCodeBlock),
    )) {
      expect(block.command, _unixSetup);
    }
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      expect((text.data ?? '').toLowerCase(), isNot(contains('bridge')));
    }
    await tapOnboarding(tester, 'onboarding-help-manual');
    expect(find.byType(InstanceEditScreen), findsOneWidget);
    expect(manager.getConnections(), isEmpty);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(manager.prefs.getBool('onboarding_done'), isNull);
    expect(tester.takeException(), isNull);
  });
}
