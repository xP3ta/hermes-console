// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// «Add instance» from Settings offers the same three ways as the welcome, at
// the top of the form, each to the same flow; leaving a way comes back to
// the editor, and editing an existing connection shows no cards.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/screens/onboarding/manual_connect_page.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/connection_editor_actions.dart';
import 'support/onboarding_fakes.dart';

const _ways = ['instance-way-nous', 'instance-way-manual', 'instance-way-scan'];

Future<ConnectionManager> _open(
  WidgetTester tester, {
  SavedConnection? initial,
  String language = 'es',
  double scale = 1,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final manager = await onboardingManager();
  await tester.pumpWidget(
    onboardingHost(
      InstanceEditScreen(
        connManager: manager,
        initial: initial,
        diagnostics: OnboardingDiagnostics(),
        scanCode: (_) async => fakeFullPairing,
      ),
      language: language,
      scale: scale,
    ),
  );
  await tester.pumpAndSettle();
  return manager;
}

Strings _strings(WidgetTester tester) =>
    Strings.of(tester.element(find.byType(InstanceEditScreen)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a new instance shows the three ways over the form', (
    tester,
  ) async {
    await _open(tester);
    final s = _strings(tester);
    for (final k in _ways) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    expect(find.byKey(const ValueKey('instance-way-ssh')), findsNothing);
    expect(find.text(s.nacWayPickTitle), findsOneWidget);
    await revealEditorControl(tester, find.text(s.nacWayEditorForm));
    expect(find.text(s.nacWayEditorForm), findsOneWidget);
    expect(find.byKey(const ValueKey('connect-way-which')), findsOneWidget);
    // The form is still there, below.
    final url = find.byKey(const ValueKey('instance-gateway-url'));
    await revealEditorControl(tester, url);
    expect(url, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing an existing connection shows no cards', (tester) async {
    await _open(
      tester,
      initial: fakeFullPairing.toDraftConnection().copyWith(id: 'conn-a'),
    );
    for (final k in _ways) {
      expect(find.byKey(ValueKey(k)), findsNothing, reason: k);
    }
  });

  testWidgets('Dashboard manual reaches SSH and back returns here', (
    tester,
  ) async {
    await _open(tester);
    await tapOnboarding(tester, 'instance-way-manual');
    await tapOnboarding(tester, 'cnx-tab-ssh');
    // The flow sits under the Connect page it opened.
    expect(find.byType(OnboardingScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(ManualConnectPage), findsOneWidget);
    expect(find.byKey(const ValueKey('cnx-ssh-host')), findsOneWidget);
    // Back out of the form: no second welcome, the editor again.
    await tapOnboarding(tester, 'onboarding-back');
    expect(find.byType(OnboardingScreen), findsNothing);
    expect(find.byType(InstanceEditScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('instance-way-ssh')), findsNothing);
    expect(find.byKey(const ValueKey('instance-way-manual')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Nous card opens Connect turned towards Nous Cloud', (
    tester,
  ) async {
    await _open(tester, language: 'en');
    final s = _strings(tester);
    await tapOnboarding(tester, 'instance-way-nous');
    expect(find.byType(ManualConnectPage), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('cnx-title'))).data,
      s.nacWayNousTitle,
    );
    expect(find.byKey(const ValueKey('cnx-tab-ssh')), findsNothing);
    await tapOnboarding(tester, 'onboarding-back');
    expect(find.byType(InstanceEditScreen), findsOneWidget);
  });

  testWidgets('going back and opening a way again keeps what was typed', (
    tester,
  ) async {
    await _open(tester);
    await tapOnboarding(tester, 'instance-way-manual');
    await tester.enterText(find.byKey(const ValueKey('manual-user')), 'owner');
    await tester.pump();
    await tapOnboarding(tester, 'onboarding-back');
    expect(find.byType(InstanceEditScreen), findsOneWidget);
    await tapOnboarding(tester, 'instance-way-manual');
    expect(find.byType(ManualConnectPage), findsOneWidget);
    expect(find.text('owner'), findsOneWidget);
    await tapOnboarding(tester, 'onboarding-back');
    expect(find.byType(InstanceEditScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Dashboard card opens the usual Connect form', (
    tester,
  ) async {
    await _open(tester);
    final s = _strings(tester);
    await tapOnboarding(tester, 'instance-way-manual');
    expect(find.byType(ManualConnectPage), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('cnx-title'))).data,
      s.cnxTitle,
    );
    expect(find.byKey(const ValueKey('cnx-tab-direct')), findsOneWidget);
    await tapOnboarding(tester, 'onboarding-back');
    expect(find.byType(InstanceEditScreen), findsOneWidget);
  });

  testWidgets('the code card scans, confirms, and back returns here', (
    tester,
  ) async {
    await _open(tester);
    final s = _strings(tester);
    await tapOnboarding(tester, 'instance-way-scan');
    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.text(s.o2ConfirmFull), findsOneWidget);
    await tapOnboarding(tester, 'onboarding-back');
    expect(find.byType(OnboardingScreen), findsNothing);
    expect(find.byType(InstanceEditScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the explanation opens over the editor', (tester) async {
    await _open(tester, language: 'en');
    final s = _strings(tester);
    await tapOnboarding(tester, 'connect-way-which');
    expect(find.text(s.nacWayWhichTitle), findsOneWidget);
    await tapOnboarding(tester, 'connect-way-help-close');
    expect(find.text(s.nacWayWhichTitle), findsNothing);
  });

  for (final width in [320.0, 600.0, 1248.0]) {
    testWidgets('the cards fit at ${width.toInt()} dp with 2x text', (
      tester,
    ) async {
      await _open(
        tester,
        language: 'de',
        scale: 2,
        size: Size(width, width < 600 ? 844 : 900),
      );
      for (final k in _ways) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
        expect(
          tester.getRect(find.byKey(ValueKey(k))).width,
          lessThanOrEqualTo(width),
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
