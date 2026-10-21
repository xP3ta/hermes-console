// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// ONB2-F / ONB4: manual mode is coherent. «Connect by hand» on the welcome
// opens the one-screen simple form with the Dashboard semantics on, and the
// full editor with them off.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';

import 'c3d/c3d_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the welcome door opens the simple form, one screen (flag on)', (
    tester,
  ) async {
    await withDash(Dash(), () async {
      await pumpWelcome(tester);
      await Taps(tester).key('onboarding-manual');
      expect(find.byKey(const ValueKey('manual-address')), findsOneWidget);
      expect(find.byType(InstanceEditScreen), findsNothing);
    });
  });

  testWidgets('flag off keeps «Connect manually» opening the form', (
    tester,
  ) async {
    await withDash(Dash(), () async {
      await pumpWelcome(tester, flag: false);
      await Taps(tester).key('onboarding-manual');
      expect(find.byType(InstanceEditScreen), findsOneWidget);
    });
  });
}
