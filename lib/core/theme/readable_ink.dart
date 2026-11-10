import 'package:flutter/widgets.dart';

import '../design/tokens.dart' show HermesChrome;
import 'app_theme.dart';
import 'theme_contrast.dart';

final Expando<Map<(int, int, double), Color>> _inks = Expando(
  'readableInkOnTint',
);

/// [ink] made readable on [tint] laid over any surface of [colors]
/// (background, surface, surfaceVariant, or the floating chrome the header,
/// the voice capsule and the PiP share): a label on a tinted pill does not
/// know which surface it sits on. The hue stays; the ink moves toward
/// black or white only as far as [minimum] needs. Cached per theme.
Color readableInkOnTint(
  Color ink,
  Color tint,
  HermesThemeColors colors, {
  double minimum = 4.5,
}) {
  final inks = _inks[colors] ??= <(int, int, double), Color>{};
  final key = (ink.toARGB32(), tint.toARGB32(), minimum);
  final cached = inks[key];
  if (cached != null) return cached;
  final behind = [
    ThemeContrast.composite(tint, colors.background),
    ThemeContrast.composite(tint, colors.surface),
    ThemeContrast.composite(tint, colors.surfaceVariant),
    ThemeContrast.composite(tint, HermesChrome.of(colors).opaque),
  ];
  return inks[key] = ThemeContrast.adjustForContrast(
    ink,
    behind,
    minimum: minimum,
  );
}
