// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// C3d-1 latch: however often the form rebuilds, one sign-in opens. Own file
// because it needs the new constructor parameter (it cannot compile on base).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';

import '../support/onboarding_fakes.dart';
import 'c3d_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('R10: rebuilds and a second frame open one sign-in', (
    tester,
  ) async {
    final dash = Dash();
    await withDash(dash, () async {
      final manager = await onboardingManager();
      final pushes = _Count();
      late StateSetter rebuild;
      await tester.pumpWidget(
        onboardingHost(
          StatefulBuilder(
            builder: (context, set) {
              rebuild = set;
              return Navigator(
                observers: [pushes],
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => InstanceEditScreen(
                    connManager: manager,
                    prefill: fakeFullPairing.toDraftConnection(),
                    signInFirst: true,
                    verifyChatBeforeSave: true,
                    diagnostics: OnboardingDiagnostics(),
                  ),
                ),
              );
            },
          ),
        ),
      );
      rebuild(() {});
      await tester.pump();
      rebuild(() {});
      await tester.pumpAndSettle();
      expect(find.byType(DashboardSetupScreen), findsOneWidget);
      expect(pushes.pushed, 2, reason: 'the form and ONE sign-in');
    });
  });

  testWidgets('R9: Edit with the parameter set still never signs in', (
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
            signInFirst: true,
            diagnostics: OnboardingDiagnostics(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DashboardSetupScreen), findsNothing);
    });
  });
}

class _Count extends NavigatorObserver {
  int pushed = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushed++;
}
