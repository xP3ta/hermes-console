import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/provider_logo.dart';

/// The colour a [ProviderLogo] actually paints with: its glyph painter's
/// tint, or the monogram's letter and frame (which must agree).
Color providerLogoTint(WidgetTester tester, Finder logo) {
  for (final paint in tester.widgetList<CustomPaint>(
    find.descendant(of: logo, matching: find.byType(CustomPaint)),
  )) {
    final painter = paint.painter;
    if (painter is ProviderGlyphPainter) return painter.color;
  }
  final letter = tester.widget<Text>(
    find.descendant(of: logo, matching: find.byType(Text)),
  );
  final frame = tester.widget<Container>(
    find.descendant(
      of: logo,
      matching: find.byKey(const ValueKey('provider-logo-monogram')),
    ),
  );
  final border = (frame.decoration! as BoxDecoration).border! as Border;
  expect(border.top.color, letter.style!.color, reason: 'one tint only');
  return letter.style!.color!;
}

/// The brand id a [ProviderLogo] resolved to.
String providerLogoId(WidgetTester tester, Finder logo) =>
    tester.widget<ProviderLogo>(logo).spec.id;
