// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// ONB6: WCAG 1.4.11. The resting boundary of HermesField and OnbSecondary
// reads at 3:1 on every light theme; dark themes are untouched.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_widgets.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';

double _ratio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Future<void> _host(WidgetTester tester, String id) => tester.pumpWidget(
  MaterialApp(
    theme: AppTheme.fromId(id),
    home: Builder(
      builder: (context) => Scaffold(
        body: Column(
          children: [
            HermesField(label: 'Name', controller: TextEditingController()),
            OnbSecondary(label: 'Other', onTap: () {}),
          ],
        ),
      ),
    ),
  ),
);

BorderSide _fieldSide(WidgetTester tester) {
  final d = tester.widget<TextField>(find.byType(TextField)).decoration!;
  final b = d.enabledBorder!;
  return b.borderSide;
}

Color? _pillBorder(WidgetTester tester) {
  for (final w in tester.widgetList<Container>(
    find.descendant(
      of: find.byType(OnbSecondary),
      matching: find.byType(Container),
    ),
  )) {
    final deco = w.decoration;
    if (deco is BoxDecoration && deco.border is Border) {
      return (deco.border! as Border).top.color;
    }
  }
  return null;
}

void main() {
  final light = AppTheme.presets.where((p) => p.brightness == Brightness.light);
  final dark = AppTheme.presets.where((p) => p.brightness == Brightness.dark);

  test('the catalog has both kinds', () {
    expect(light, isNotEmpty);
    expect(dark, isNotEmpty);
  });

  for (final p in light) {
    testWidgets('${p.id} (light): field and pill boundary >= 3:1', (
      tester,
    ) async {
      await _host(tester, p.id);
      final theme = AppTheme.fromId(p.id);
      final c = theme.hermes;
      final side = _fieldSide(tester);
      expect(side.style, BorderStyle.solid);
      expect(side.width, greaterThanOrEqualTo(1.0));
      expect(_ratio(side.color, c.background), greaterThanOrEqualTo(3.0));
      expect(
        _ratio(side.color, theme.scaffoldBackgroundColor),
        greaterThanOrEqualTo(3.0),
      );
      final pill = _pillBorder(tester)!;
      expect(_ratio(pill, c.background), greaterThanOrEqualTo(3.0));
      expect(_ratio(pill, c.surfaceVariant), greaterThanOrEqualTo(3.0));
      expect(pill, c.controlBorder);
    });
  }

  for (final p in dark) {
    testWidgets('${p.id} (dark): borders are still the divider', (
      tester,
    ) async {
      await _host(tester, p.id);
      final theme = AppTheme.fromId(p.id);
      final c = theme.hermes;
      expect(c.controlBorder, c.divider);
      expect(c.divider, p.colors.divider);
      final outlined =
          theme.hermesComponents.profile.border.outlinesRestingControls;
      final side = _fieldSide(tester);
      if (outlined) {
        expect(side.color, c.divider);
      } else {
        expect(side, BorderSide.none, reason: 'same as the base');
      }
      expect(_pillBorder(tester), c.divider);
    });
  }

  testWidgets('focus keeps the accent border (alpha .6)', (tester) async {
    await _host(tester, 'console-light');
    final c = AppTheme.fromId('console-light').hermes;
    final d = tester.widget<TextField>(find.byType(TextField)).decoration!;
    expect(d.focusedBorder!.borderSide.color, c.accent.withValues(alpha: 0.6));
  });

  testWidgets('console-light lifts both from ~1.1:1 / ~1.2:1', (tester) async {
    final c = AppTheme.fromId('console-light').hermes;
    expect(_ratio(c.divider, c.background), lessThan(1.5));
    expect(_ratio(c.controlBorder, c.background), greaterThanOrEqualTo(3.0));
  });
}
