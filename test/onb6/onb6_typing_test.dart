// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// ONB6: the setup command types itself in at most 600 ms. Synthetic fixtures.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_widgets.dart';
import 'package:hermes_android/core/services/hermes_setup_commands.dart';
import 'package:hermes_android/core/services/official_dashboard_command.dart';

final String _windows = dashboardSetupCommand(SetupHostSystem.windows);

// The finished block is a SelectionArea; while typing the full text is only an
// invisible spacer and the visible text is the typed prefix.
final _done = find.descendant(
  of: find.byType(OnbCodeBlock),
  matching: find.byType(SelectionArea),
);

Future<void> _host(WidgetTester tester, {bool reduced = false}) =>
    tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: child!,
        ),
        home: Scaffold(body: OnbCodeBlock(command: _windows)),
      ),
    );

void main() {
  testWidgets('the longest command is complete at +600 ms, not before +300', (
    tester,
  ) async {
    expect(_windows.length * 18, greaterThan(1200), reason: 'longest command');
    await _host(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(_done, findsNothing, reason: '+300 ms: still typing');
    await tester.pump(const Duration(milliseconds: 299));
    expect(_done, findsNothing, reason: '+599 ms: last frame');
    await tester.pump(const Duration(milliseconds: 2));
    expect(_done, findsOneWidget, reason: '+601 ms: complete');
  });

  testWidgets('a tap completes it at once', (tester) async {
    await _host(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_done, findsNothing);
    await tester.tap(find.byType(OnbCodeBlock));
    await tester.pump();
    expect(_done, findsOneWidget);
  });

  testWidgets('reduced motion: complete in the first frame', (tester) async {
    await _host(tester, reduced: true);
    expect(_done, findsOneWidget);
  });
}
