// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// The welcome offers three ways in as cards: a Nous Portal account, a
// Dashboard address (including SSH), and a code or a server on the network.
// Each opens its existing flow; scan is recommended, a short
// explanation is one tap away, and changing one's mind loses nothing typed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/connect_method_cards.dart';
import 'package:hermes_android/core/screens/onboarding/manual_connect_page.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_scanner.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/services/dashboard_address.dart';

import 'support/onboarding_fakes.dart';

const _locales = ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh'];
const _ways = ['onboarding-way-nous', 'onboarding-manual', 'onboarding-scan'];

Future<HostProbeResult> _silent(DiscoveryTarget _) async =>
    const HostProbeResult(HostVerdict.silent);

Future<void> _open(
  WidgetTester tester, {
  String language = 'es',
  String theme = 'dark',
  double scale = 1,
  Size size = const Size(390, 844),
  bool pairing = false,
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
        diagnostics: OnboardingDiagnostics(),
        probe: _silent,
        cameraBuilder: (_, _) => const SizedBox(),
        scanCode: pairing ? (_) async => fakeFullPairing : null,
      ),
      language: language,
      theme: theme,
      scale: scale,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _popPage(WidgetTester tester) async {
  Navigator.of(tester.element(find.byType(ManualConnectPage))).pop();
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('scan or find is recommended with or without a known server', () {
    expect(recommendedConnectWay(pairingSeen: false), ConnectWay.scan);
    expect(recommendedConnectWay(pairingSeen: true), ConnectWay.scan);
    expect(
      recommendedConnectWay(pairingSeen: false, onTailnet: true),
      ConnectWay.scan,
    );
  });

  // Opened on the scan way from another screen (the connection editor),
  // back from the camera leaves at once: it used to ask the screen's own
  // PopScope, which refused off the welcome and called back again forever.
  testWidgets('back from the camera of an opened way leaves the flow', (
    tester,
  ) async {
    final manager = await onboardingManager();
    await tester.pumpWidget(
      onboardingHost(
        Builder(
          builder: (context) => TextButton(
            key: const ValueKey('open-scan-way'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => OnboardingScreen(
                  connManager: manager,
                  onDone: () {},
                  playOpening: false,
                  diagnostics: OnboardingDiagnostics(),
                  probe: _silent,
                  cameraBuilder: (_, _) => const SizedBox(),
                  initialWay: ConnectWay.scan,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-scan-way')));
    await tester.pumpAndSettle();
    expect(find.byType(QrScanView), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('onboarding-back')));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsNothing);
    expect(find.byKey(const ValueKey('open-scan-way')), findsOneWidget);
  });

  test('under flutter test the phone is never on a tailnet', () async {
    expect(await phoneOnTailnet(), isFalse);
  });

  testWidgets('a phone on a tailnet gets the find-my-server card marked', (
    tester,
  ) async {
    final manager = await onboardingManager();
    await tester.pumpWidget(
      onboardingHost(
        OnboardingScreen(
          connManager: manager,
          onDone: () {},
          playOpening: false,
          diagnostics: OnboardingDiagnostics(),
          probe: _silent,
          cameraBuilder: (_, _) => const SizedBox(),
          tailnetProbe: () async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final s = onboardingStrings(tester);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('onboarding-scan')),
        matching: find.text(s.nacWayRecommended),
      ),
      findsOneWidget,
    );
    expect(find.text(s.nacWayRecommended), findsOneWidget);
  });

  testWidgets('the three cards render, Nous first and scan recommended', (
    tester,
  ) async {
    await _open(tester);
    final s = onboardingStrings(tester);
    for (final k in _ways) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    // Account, address (including SSH), code: top to bottom.
    double top(String k) => tester.getRect(find.byKey(ValueKey(k))).top;
    expect(top(_ways[0]), lessThan(top(_ways[1])));
    expect(top(_ways[1]), lessThan(top(_ways[2])));
    expect(find.byKey(const ValueKey('onboarding-way-ssh')), findsNothing);
    // One sentence each, in the user's words.
    for (final text in [
      s.nacWayNousTitle,
      s.nacWayNousBody,
      s.nacWayManualTitle,
      s.nacWayManualBody,
      s.nacWayScanTitle,
      s.nacWayScanBody,
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    expect(find.text(s.nacWayRecommended), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('onboarding-scan')),
        matching: find.text(s.nacWayRecommended),
      ),
      findsOneWidget,
    );
    // Every card is a 48 dp+ touch target.
    for (final k in _ways) {
      expect(
        tester.getSize(find.byKey(ValueKey(k))).height,
        greaterThanOrEqualTo(48),
      );
    }
    // The setup command stays reachable for whoever has no Hermes yet.
    expect(find.byKey(const ValueKey('onboarding-help')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Nous card opens Connect turned towards Nous Cloud', (
    tester,
  ) async {
    await _open(tester, language: 'en');
    final s = onboardingStrings(tester);
    await tapOnboarding(tester, 'onboarding-way-nous');
    final page = find.byType(ManualConnectPage);
    expect(page, findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('cnx-title'))).data,
      s.nacWayNousTitle,
    );
    expect(find.byKey(const ValueKey('manual-nous-body')), findsOneWidget);
    // No SSH tab through this door; the page is the portal, one address and
    // the button: no name, no sign-in method (it is always the browser with
    // the Nous account), no Tailscale advice.
    expect(find.byKey(const ValueKey('cnx-tab-ssh')), findsNothing);
    expect(find.byKey(const ValueKey('manual-nous-portal')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual-nous-paste')), findsNothing);
    expect(find.byKey(const ValueKey('manual-address')), findsNothing);
    expect(find.byKey(const ValueKey('manual-nous-logo')), findsOneWidget);
    expect(find.byKey(const ValueKey('cnx-name')), findsNothing);
    expect(find.byKey(const ValueKey('cnx-method')), findsNothing);
    expect(find.byKey(const ValueKey('manual-user')), findsNothing);
    expect(find.text(s.cnxAddressNote), findsNothing);
    // Manual entry stays available as an explicit fallback.
    await tapOnboarding(tester, 'manual-nous-write-address');
    // A Nous Cloud address is named as such.
    await tester.enterText(
      find.byKey(const ValueKey('manual-address')),
      'mine.agents.nousresearch.com',
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('✓ ${s.nacWayNousHostOk}'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Dashboard card opens the usual Connect form', (
    tester,
  ) async {
    await _open(tester);
    final s = onboardingStrings(tester);
    await tapOnboarding(tester, 'onboarding-manual');
    expect(find.byType(ManualConnectPage), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('cnx-title'))).data,
      s.cnxTitle,
    );
    expect(find.byKey(const ValueKey('cnx-tab-direct')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual-address')), findsOneWidget);
    expect(find.byType(QrScanView), findsNothing);
  });

  testWidgets('Dashboard manual reaches the SSH route', (tester) async {
    await _open(tester);
    await tapOnboarding(tester, 'onboarding-manual');
    await tapOnboarding(tester, 'cnx-tab-ssh');
    expect(find.byType(ManualConnectPage), findsOneWidget);
    expect(find.byKey(const ValueKey('cnx-ssh-host')), findsOneWidget);
    expect(find.byKey(const ValueKey('cnx-ssh-user')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual-address')), findsNothing);
  });

  testWidgets('an entry opening SSH directly still selects its route', (
    tester,
  ) async {
    final manager = await onboardingManager();
    await tester.pumpWidget(
      onboardingHost(
        OnboardingScreen(
          connManager: manager,
          onDone: () {},
          playOpening: false,
          initialWay: ConnectWay.ssh,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ManualConnectPage), findsOneWidget);
    expect(find.byKey(const ValueKey('cnx-ssh-host')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual-address')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the code card opens the camera', (tester) async {
    await _open(tester);
    await tapOnboarding(tester, 'onboarding-scan');
    expect(find.byType(QrScanView), findsOneWidget);
    expect(find.byType(ManualConnectPage), findsNothing);
  });

  testWidgets('a pairing result moves the recommendation to the code card', (
    tester,
  ) async {
    await _open(tester, pairing: true);
    final s = onboardingStrings(tester);
    await tapOnboarding(tester, 'onboarding-scan');
    expect(find.text(s.o2ConfirmFull), findsOneWidget);
    await tapOnboarding(tester, 'onboarding-back');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('onboarding-scan')),
        matching: find.text(s.nacWayRecommended),
      ),
      findsOneWidget,
    );
    expect(find.text(s.nacWayRecommended), findsOneWidget);
  });

  testWidgets('«I don\'t know which to choose» opens the short explanation', (
    tester,
  ) async {
    await _open(tester, language: 'en');
    final s = onboardingStrings(tester);
    await tapOnboarding(tester, 'connect-way-which');
    expect(find.byKey(const ValueKey('connect-way-help')), findsOneWidget);
    expect(find.text(s.nacWayWhichTitle), findsOneWidget);
    expect(find.text(s.nacWayWhichBody), findsOneWidget);
    // One line per way.
    expect(s.nacWayWhichBody.split('\n'), hasLength(3));
    await tapOnboarding(tester, 'connect-way-help-close');
    expect(find.byKey(const ValueKey('connect-way-help')), findsNothing);
    expect(find.byKey(const ValueKey('onboarding-way-nous')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching ways keeps what was typed', (tester) async {
    await _open(tester);
    // An address through the Dashboard door.
    await tapOnboarding(tester, 'onboarding-manual');
    await tester.enterText(
      find.byKey(const ValueKey('manual-address')),
      'nas.local:9119',
    );
    await tester.enterText(find.byKey(const ValueKey('manual-user')), 'owner');
    await tester.pump(const Duration(seconds: 1));
    await _popPage(tester);
    expect(find.byKey(const ValueKey('onboarding-manual')), findsOneWidget);
    // An SSH host through the manual route selector.
    await tapOnboarding(tester, 'onboarding-manual');
    await tapOnboarding(tester, 'cnx-tab-ssh');
    await tester.enterText(
      find.byKey(const ValueKey('cnx-ssh-host')),
      'bastion.example',
    );
    await tester.pump();
    await _popPage(tester);
    // Back through the Dashboard door: the address and the user are there.
    await tapOnboarding(tester, 'onboarding-manual');
    expect(find.byKey(const ValueKey('manual-address')), findsOneWidget);
    expect(find.text('nas.local:9119'), findsOneWidget);
    expect(find.text('owner'), findsOneWidget);
    // The kept address is checked again on return.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('manual-status')), findsOneWidget);
    await _popPage(tester);
    // And the SSH host too.
    await tapOnboarding(tester, 'onboarding-manual');
    await tapOnboarding(tester, 'cnx-tab-ssh');
    expect(find.byKey(const ValueKey('cnx-ssh-host')), findsOneWidget);
    expect(find.text('bastion.example'), findsOneWidget);
    // The Nous door shares the same address field.
    await _popPage(tester);
    await tapOnboarding(tester, 'onboarding-way-nous');
    expect(find.byKey(const ValueKey('manual-nous-body')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual-address')), findsNothing);
    await tapOnboarding(tester, 'manual-nous-write-address');
    expect(find.text('nas.local:9119'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  group('layout', () {
    for (final language in _locales) {
      for (final width in [320.0, 390.0, 600.0, 840.0, 1248.0]) {
        testWidgets('$language at ${width.toInt()} dp, 2x text', (
          tester,
        ) async {
          await _open(
            tester,
            language: language,
            scale: 2,
            size: Size(width, width < 600 ? 844 : 900),
          );
          for (final k in [..._ways, 'connect-way-which', 'onboarding-help']) {
            expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
          }
          // The cards never run wider than the screen or the column cap.
          for (final k in _ways) {
            final rect = tester.getRect(find.byKey(ValueKey(k)));
            expect(rect.width, lessThanOrEqualTo(width));
            expect(rect.width, lessThanOrEqualTo(560));
            expect(rect.left, greaterThanOrEqualTo(0));
          }
          expect(tester.takeException(), isNull);
        });
      }
    }

    for (final theme in ['dark', 'light', 'midnight', 'midnight-light']) {
      for (final width in [320.0, 1248.0]) {
        testWidgets('$theme at ${width.toInt()} dp, 2x text', (tester) async {
          await _open(
            tester,
            theme: theme,
            scale: 2,
            size: Size(width, width < 600 ? 844 : 900),
          );
          for (final k in _ways) {
            expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
          }
          await tapOnboarding(tester, 'connect-way-which');
          expect(
            find.byKey(const ValueKey('connect-way-help')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}
