// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// «Connect an agent»: Nous, Dashboard, then scan; setup help follows. Synthetic
// fixtures only.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/manual_connect_page.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_scanner.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';

import '../support/onboarding_fakes.dart';

const _keys = [
  'onbFlowTitle',
  'onbFlowBody',
  'nacWayNousTitle',
  'nacWayNousBody',
  'nacWayManualTitle',
  'nacWayManualBody',
  'nacWayScanTitle',
  'nacWayScanBody',
  'nacNousWriteAddress',
  'nacNousWaitingAddress',
  'onbFlowGuidedBody',
];

Future<void> _open(
  WidgetTester tester,
  String language, {
  bool guided = false,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final manager = await onboardingManager();
  await tester.pumpWidget(
    onboardingHost(
      OnboardingScreen(
        connManager: manager,
        onDone: () {},
        playOpening: false,
        guided: guided,
        cameraBuilder: (_, _) => const SizedBox(),
      ),
      language: language,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('the flow copy exists in the nine languages', () {
    for (final l in ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh']) {
      final arb =
          jsonDecode(File('lib/l10n/app_$l.arb').readAsStringSync())
              as Map<String, dynamic>;
      for (final k in _keys) {
        expect((arb[k] as String?)?.trim(), isNotEmpty, reason: '$l/$k');
      }
      expect(arb['nacWayManualBody'], contains('SSH'), reason: l);
      expect((arb['nacWayWhichBody'] as String).split('\n'), hasLength(3));
      expect(arb.containsKey('nacWaySshTitle'), isFalse, reason: l);
      expect(arb.containsKey('nacWaySshBody'), isFalse, reason: l);
    }
  });

  for (final language in ['es', 'en', 'ja']) {
    testWidgets('$language: Nous, Dashboard, then scan', (tester) async {
      await _open(tester, language);
      expectOnboardingWays(tester, onboardingStrings(tester));
    });
  }

  testWidgets('the main way opens the address form, no camera', (tester) async {
    await _open(tester, 'en');
    await tapOnboarding(tester, 'onboarding-manual');
    expect(find.byType(ManualConnectPage), findsOneWidget);
    expect(find.byType(QrScanView), findsNothing);
  });

  testWidgets('the QR stays one tap away', (tester) async {
    await _open(tester, 'es');
    await tapOnboarding(tester, 'onboarding-scan');
    expect(find.byType(QrScanView), findsOneWidget);
  });

  testWidgets('large text and the open Fold keep all three ways reachable', (
    tester,
  ) async {
    for (final size in [const Size(320, 640), const Size(840, 700)]) {
      await _open(tester, 'en', size: size);
      for (final k in [
        'onboarding-manual',
        'onboarding-way-nous',
        'onboarding-scan',
      ]) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: '$size $k');
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('the guided setup shows the aligned body', (tester) async {
    await _open(tester, 'en', guided: true);
    final s = onboardingStrings(tester);
    expect(find.text(s.onbFlowGuidedBody), findsOneWidget);
  });
}
