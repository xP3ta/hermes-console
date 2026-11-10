import 'package:flutter/material.dart';

import '../design/tokens.dart' show HermesChrome;
import '../theme/app_theme.dart';
import '../theme/theme_contrast.dart';

/// Least contrast (WCAG ratio) the resting outline of a pill keeps against
/// the surface of a floating sheet and against the pill's own fill.
const double kSheetOutlineContrast = 1.45;

/// Least contrast of a selection ring (the round selector of a model row)
/// against the same surfaces; a control's boundary asks for 3:1.
const double kSheetRingContrast = 3.05;

final Expando<Color> _outline = Expando<Color>('sheetOutline');
final Expando<Color> _ring = Expando<Color>('sheetRing');

Color _lifted(HermesThemeColors colors, double minimum) {
  final chrome = HermesChrome.of(colors);
  return ThemeContrast.adjustForContrast(colors.controlBorder, [
    chrome.opaque,
    chrome.raised,
  ], minimum: minimum);
}

/// Resting outline of a pill that sits on a floating sheet (model rows,
/// provider pills, setting pills, the reasoning track): the control border
/// of the theme, lifted by the smallest step until it reads at
/// [kSheetOutlineContrast] on the sheet surface and on [HermesChrome.raised].
Color hermesSheetOutline(HermesThemeColors colors) =>
    _outline[colors] ??= _lifted(colors, kSheetOutlineContrast);

/// Ring of an empty round selector on a floating sheet, at
/// [kSheetRingContrast].
Color hermesSheetRing(HermesThemeColors colors) =>
    _ring[colors] ??= _lifted(colors, kSheetRingContrast);
