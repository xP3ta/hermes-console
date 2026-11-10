// REVIEW-Q9-VENT P2: the text of the chat's windows (Vistas, Ajustes)
// reads at 4.5:1 wherever the window blurs: on its veil (0.80 dark, 0.84
// light, ventanas-final-png) over the worst the blur can show behind it,
// white or black under the lightest barrier (a menu's), with the glow of
// its top third; and on its opaque fill. In every preset theme; the same
// hue, lighter or darker.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';

List<Color> _worst(HermesChrome chrome, {Color? tint}) {
  final veil = chrome.opaque.withValues(alpha: chrome.dark ? 0.80 : 0.84);
  final glow = Colors.white.withValues(alpha: chrome.dark ? 0.04 : 0.18);
  final barrier = Colors.black.withValues(alpha: HermesChrome.scrimMenu);
  final all = <Color>[chrome.opaque];
  for (final behind in [Colors.white, Colors.black]) {
    final through = ThemeContrast.composite(
      veil,
      ThemeContrast.composite(barrier, behind),
    );
    all
      ..add(through)
      ..add(ThemeContrast.composite(glow, through));
  }
  return [
    for (final b in all) tint == null ? b : ThemeContrast.composite(tint, b),
  ];
}

void main() {
  test('every window ink reads at 4.5:1 on its worst background, in every '
      'preset, its hue kept', () {
    for (final preset in AppTheme.presets) {
      final colors = AppTheme.fromId(preset.id).hermes;
      final chrome = HermesChrome.of(colors);
      final tint = colors.accent.withValues(alpha: 0.16);
      for (final (name, token, onTint) in [
        ('ink', chrome.ink, null),
        ('textPrimary', colors.textPrimary, null),
        ('mutedInk', chrome.mutedInk, null),
        ('textSecondary', colors.textSecondary, null),
        ('error', colors.error, null),
        ('accentText', colors.accentText, null),
        ('accentText on its tint', colors.accentText, tint),
      ]) {
        final ink = HermesFloatingSurface.windowInk(
          colors,
          token,
          tint: onTint,
        );
        for (final background in _worst(chrome, tint: onTint)) {
          expect(
            ThemeContrast.ratio(ink, background),
            greaterThanOrEqualTo(4.5 - 0.01),
            reason: '${preset.id} $name on $background',
          );
        }
        // A grey has no hue to keep.
        final hsl = HSLColor.fromColor(token);
        if (hsl.saturation > 0) {
          final hue = (HSLColor.fromColor(ink).hue - hsl.hue).abs();
          expect(
            hue > 180 ? 360 - hue : hue,
            lessThan(2),
            reason: '${preset.id} $name keeps its hue',
          );
        }
      }
    }
  });
}
