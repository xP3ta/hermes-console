// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// C3d-1: with the flag off Connect by hand stays the full form; with it on
// it is the simple form and signs nothing in by itself; Edit never signs in.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/services/onboarding_arrival.dart';

import '../support/onboarding_fakes.dart';
import 'c3d_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(OnboardingArrival.reset);

  testWidgets('R1: flag off keeps the form, «Sign in» and «Save»', (
    tester,
  ) async {
    final dash = Dash();
    await withDash(dash, () async {
      final rig = await pumpWelcome(tester, flag: false);
      final s = onboardingStrings(tester);
      await tester.tap(find.byKey(const ValueKey('onboarding-manual')));
      await tester.pumpAndSettle();
      expect(find.byType(DashboardSetupScreen), findsNothing);
      expect(
        find.byKey(const ValueKey('instance-dashboard-sign-in')),
        findsOne,
      );
      expect(rig.manager.getConnections(), isEmpty);
      expect(s.o2SuccessTitle, isNotEmpty);
    });
  });

  testWidgets('R8: manual with the flag on does not sign in by itself', (
    tester,
  ) async {
    final dash = Dash();
    await withDash(dash, () async {
      final rig = await pumpWelcome(tester);
      final s = onboardingStrings(tester);
      final taps = Taps(tester);
      await taps.key('onboarding-manual');
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(DashboardSetupScreen), findsNothing);
      // The simple form (W4), not the editor: nothing signs in by itself.
      expect(find.byKey(const ValueKey('manual-address')), findsOneWidget);
      expect(find.byType(InstanceEditScreen), findsNothing);
      expect(find.text(s.ieGatewayUrlRequired), findsNothing);
      expect(rig.manager.getConnections(), isEmpty);
    });
  });

  testWidgets('R9: editing a saved connection never signs in by itself', (
    tester,
  ) async {
    final dash = Dash();
    await withDash(dash, () async {
      final manager = await onboardingManager();
      await manager.upsertConnection(
        fakeFullPairing.toDraftConnection().copyWith(id: 'conn-a'),
      );
      await tester.pumpWidget(
        onboardingHost(
          InstanceEditScreen(
            connManager: manager,
            initial: manager.getConnections().single,
            diagnostics: OnboardingDiagnostics(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DashboardSetupScreen), findsNothing);
      expect(find.byType(InstanceEditScreen), findsOneWidget);
    });
  });
}
