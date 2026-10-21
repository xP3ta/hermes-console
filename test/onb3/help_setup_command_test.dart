// SPDX-License-Identifier: GPL-3.0-only
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_widgets.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/services/pairing_link.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/onboarding_fakes.dart';

const _unix =
    'curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/'
    'hermes-dashboard-setup.sh | sh';
const _windows =
    '& ([scriptblock]::Create((irm '
    'https://raw.githubusercontent.com/xP3ta/hermes-setup/main/'
    'hermes-dashboard-setup.ps1)))';

Future<(Strings, List<String>, List<String>)> _open(
  WidgetTester tester,
  String language, {
  Future<PairingLink?> Function(BuildContext)? scan,
}) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final copied = <String>[];
  final shared = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('dev.fluttercommunity.plus/share'),
    (call) async {
      shared.add((call.arguments as Map)['text'] as String);
      return null;
    },
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/share'),
      null,
    );
  });
  final manager = await onboardingManager();
  await tester.pumpWidget(
    onboardingHost(
      OnboardingScreen(
        simpleConnectEnabled: false,
        connManager: manager,
        scanCode: scan,
        onDone: () {},
      ),
      language: language,
    ),
  );
  await tester.pumpAndSettle();
  await tapOnboarding(tester, 'onboarding-help');
  return (onboardingStrings(tester), copied, shared);
}

String _shown(WidgetTester tester) =>
    tester.widget<OnbCodeBlock>(find.byType(OnbCodeBlock)).command;

void main() {
  for (final language in ['es', 'en']) {
    testWidgets('$language: each tab shows, copies and sends its own line', (
      tester,
    ) async {
      final (s, copied, shared) = await _open(tester, language);
      expect(_shown(tester), _unix);
      await tapOnboarding(tester, 'pairing-helper-copy');
      await tapOnboarding(tester, 'pairing-helper-send');
      await tapOnboarding(tester, 'pairing-helper-windows');
      expect(_shown(tester), _windows);
      await tapOnboarding(tester, 'pairing-helper-copy');
      await tapOnboarding(tester, 'pairing-helper-send');
      expect(copied, [_unix, _windows]);
      expect(shared, [_unix, _windows]);
      for (final line in [_unix, _windows]) {
        expect(line, isNot(contains('sudo')));
        expect(line, isNot(contains('0.0.0.0')));
      }
      expect(find.text(s.onb4HelpSafe, skipOffstage: false), findsOneWidget);
      expect(find.text(s.onb3HelpStepScan, skipOffstage: false), findsOne);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$language: the main button scans, the others stay', (
      tester,
    ) async {
      var scans = 0;
      await _open(
        tester,
        language,
        scan: (_) async {
          scans++;
          return null;
        },
      );
      final primary = find.byKey(const ValueKey('onboarding-help-scan'));
      expect(find.byType(OnbPrimary), findsOneWidget);
      expect(tester.widget<OnbPrimary>(primary).onTap, isNotNull);
      expect(
        find.byKey(const ValueKey('onboarding-help-manual')),
        findsOneWidget,
      );
      expect(
        tester.widget(find.byKey(const ValueKey('onboarding-help-manual'))),
        isA<OnbTextButton>(),
      );
      expect(find.byKey(const ValueKey('onboarding-paste')), findsNothing);
      await tapOnboarding(tester, 'onboarding-help-scan');
      expect(scans, 1);
      expect(find.byType(InstanceEditScreen), findsNothing);
      await tapOnboarding(tester, 'onboarding-help-manual');
      expect(find.byType(InstanceEditScreen), findsOneWidget);
      expect(scans, 1);
    });
  }

  test('the setup label lives in one place and the old line is gone', () {
    final src = File(
      'lib/core/services/official_dashboard_command.dart',
    ).readAsStringSync();
    expect('raw.githubusercontent.com'.allMatches(src).length, 1);
    expect("kHermesSetupRef = 'main'".allMatches(src).length, 1);
    final screen = File(
      'lib/core/screens/onboarding_screen.dart',
    ).readAsStringSync();
    expect(screen, isNot(contains('kOfficialDashboardCommand')));
    expect(screen, isNot(contains('hermes-setup')));
    for (final l in ['es', 'en']) {
      expect(
        File('lib/l10n/app_$l.arb').readAsStringSync(),
        isNot(contains('o2StepCode')),
      );
    }
  });
}
