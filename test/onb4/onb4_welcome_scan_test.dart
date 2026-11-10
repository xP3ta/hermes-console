// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// The welcome has four connection cards and a separate setup-help link.
// The camera carries the setup command under the
// viewfinder. Synthetic fixtures only.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/manual_connect_page.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_scanner.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_widgets.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/screens/qr_scan_screen.dart';
import 'package:hermes_android/core/services/hermes_setup_commands.dart';
import 'package:hermes_android/core/services/official_dashboard_command.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/onboarding_fakes.dart';

const _unix =
    'curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/'
    'hermes-dashboard-setup.sh | sh';
const _windows =
    '& ([scriptblock]::Create((irm '
    'https://raw.githubusercontent.com/xP3ta/hermes-setup/main/'
    'hermes-dashboard-setup.ps1)))';

ValueChanged<bool>? _permission;
Widget _camera(ValueChanged<String> _, ValueChanged<bool> permission) {
  _permission = permission;
  return const SizedBox();
}

Future<Strings> _welcome(
  WidgetTester tester,
  String language, {
  bool? flag,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final manager = await onboardingManager();
  await tester.pumpWidget(
    onboardingHost(
      flag == null
          ? OnboardingScreen(
              connManager: manager,
              onDone: () {},
              playOpening: false,
              cameraBuilder: _camera,
            )
          : OnboardingScreen(
              connManager: manager,
              onDone: () {},
              playOpening: false,
              cameraBuilder: _camera,
              simpleConnectEnabled: flag,
            ),
      language: language,
    ),
  );
  await tester.pumpAndSettle();
  return onboardingStrings(tester);
}

void main() {
  for (final language in ['es', 'en']) {
    // Default (no flag passed), flag on, flag off: the same welcome.
    for (final flag in <bool?>[null, true, false]) {
      testWidgets(
        '$language/$flag: four ordered cards, scan last, no automatic search',
        (tester) async {
          final s = await _welcome(tester, language, flag: flag);
          expectOnboardingWays(tester, s);
          expect(find.text('Buscar mi Hermes'), findsNothing);
          expect(find.text('Find my Hermes'), findsNothing);
        },
      );
    }

    testWidgets('$language: the QR way opens the camera', (tester) async {
      final s = await _welcome(tester, language);
      await tapOnboarding(tester, 'onboarding-scan');
      expect(find.byType(QrScanView), findsOneWidget);
      expect(find.text(s.onb4ScanHint), findsOneWidget);
    });

    testWidgets('$language: the pairing way opens the install help', (
      tester,
    ) async {
      final s = await _welcome(tester, language);
      await tapOnboarding(tester, 'onboarding-help');
      expect(find.text(s.onb4HelpTitle), findsOneWidget);
      expect(find.byType(QrScanView), findsNothing);
    });

    testWidgets('$language: the main way opens the manual page', (
      tester,
    ) async {
      await _welcome(tester, language);
      await tapOnboarding(tester, 'onboarding-manual');
      expect(find.byType(ManualConnectPage), findsOneWidget);
    });

    testWidgets('$language: the camera shows the command and copies it', (
      tester,
    ) async {
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
      final s = await _welcome(tester, language);
      await tapOnboarding(tester, 'onboarding-scan');
      expect(find.text(s.onb4NoCodeTitle), findsOneWidget);
      expect(find.text(s.onb4NoCodeBody), findsOneWidget);
      String shown() =>
          tester.widget<OnbCodeBlock>(find.byType(OnbCodeBlock)).command;
      expect(shown(), _unix);
      expect(shown(), dashboardSetupCommand(SetupHostSystem.unix));
      await tapOnboarding(tester, 'pairing-helper-copy');
      await tapOnboarding(tester, 'pairing-helper-send');
      await tapOnboarding(tester, 'pairing-helper-windows');
      expect(shown(), _windows);
      await tapOnboarding(tester, 'pairing-helper-copy');
      await tapOnboarding(tester, 'pairing-helper-send');
      expect(copied, [_unix, _windows]);
      expect(shared, [_unix, _windows]);
      // The torch stays; no pasted link; the old search command is nowhere.
      expect(find.byKey(const ValueKey('qr-torch')), findsOneWidget);
      expect(find.text(s.qrPasteLink), findsNothing);
      expect(find.byKey(const ValueKey('qr-paste')), findsNothing);
      expect(find.textContaining('0.0.0.0'), findsNothing);
      // The way to type the address is under the command.
      await tapOnboarding(tester, 'qr-panel-manual');
      expect(find.byType(ManualConnectPage), findsOneWidget);
    });

    testWidgets('$language: camera denied: Connect by hand, no pasted link', (
      tester,
    ) async {
      final s = await _welcome(tester, language);
      await tapOnboarding(tester, 'onboarding-scan');
      _permission!(false);
      await tester.pumpAndSettle();
      expect(find.text(s.qrCameraError), findsOneWidget);
      expect(find.byKey(const ValueKey('qr-denied-paste')), findsNothing);
      expect(find.text(s.qrPasteLink), findsNothing);
      await tapOnboarding(tester, 'qr-manual');
      expect(find.byType(ManualConnectPage), findsOneWidget);
    });

    testWidgets('$language: the camera of Settings keeps no panel', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        onboardingHost(
          const QrScanScreen(cameraBuilder: _camera),
          language: language,
        ),
      );
      await tester.pumpAndSettle();
      final s = Strings.of(tester.element(find.byType(QrScanView)));
      expect(find.byKey(const ValueKey('qr-help-panel')), findsNothing);
      expect(find.text(s.onb4NoCodeTitle), findsNothing);
      expect(find.byType(OnbCodeBlock), findsNothing);
      expect(find.text(s.qrAimHint), findsOneWidget);
      expect(find.byKey(const ValueKey('qr-paste')), findsOneWidget);
    });
  }

  testWidgets('the welcome holds at 320 dp and 2x text', (tester) async {
    await _welcome(tester, 'es', size: const Size(320, 640));
    await tester.pumpWidget(
      onboardingHost(
        OnboardingScreen(
          connManager: await onboardingManager(),
          onDone: () {},
          playOpening: false,
        ),
        scale: 2,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tapOnboarding(tester, 'onboarding-help');
    expect(tester.takeException(), isNull);
  });
}
