// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// ONB6: WCAG 1.4.11. The resting boundary of HermesField and OnbSecondary
// reads at 3:1 on every light theme; dark themes are untouched.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_widgets.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/box_fill.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
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

  // The legibility pass: a dark palette's field and pill wear the same
  // control border, derived from the divider (same hue, smallest step) to
  // 3:1 on the page, the surfaces and the bodies of the boxes. Before, a
  // dark field had no resting outline and its fill sat near 1.0:1 on the
  // body of a group.
  for (final p in dark) {
    testWidgets('${p.id} (dark): the field and the pill wear the derived '
        'control border', (tester) async {
      await _host(tester, p.id);
      final theme = AppTheme.fromId(p.id);
      final c = theme.hermes;
      expect(c.divider, p.colors.divider);
      final boxes = HermesBoxFill.of(c);
      for (final back in [
        c.background,
        c.surface,
        c.surfaceVariant,
        boxes.group,
        boxes.card,
      ]) {
        expect(
          ThemeContrast.ratio(c.controlBorder, back),
          greaterThanOrEqualTo(3.0),
          reason: '${p.id} control border on $back',
        );
      }
      final from = HSLColor.fromColor(c.divider);
      final to = HSLColor.fromColor(c.controlBorder);
      if (from.saturation > 0.08) {
        final dh = (from.hue - to.hue).abs();
        expect(dh < 8 || 360 - dh < 8, isTrue, reason: '${p.id} keeps hue');
      }
      expect(_fieldSide(tester).color, c.controlBorder);
      expect(_pillBorder(tester), c.controlBorder);
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
