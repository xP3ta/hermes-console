// Owner direction (1.2.15): every theme should feel like Claude's — soft
// graphite pages, gently layered surfaces, a calm accent, quiet status
// colours and subtle hairlines. The bands below are measured on the Claude
// presets at run time (plus a small margin), so "Claude-like" is a checked
// property of every preset, not a matter of taste.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';

/// OKLCH lightness and chroma of an opaque colour.
({double l, double c, double h}) oklch(Color color) {
  double lin(double v) =>
      v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  final r = lin(color.r), g = lin(color.g), b = lin(color.b);
  final l = math.pow(
    0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b,
    1 / 3,
  );
  final m = math.pow(
    0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b,
    1 / 3,
  );
  final s = math.pow(
    0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b,
    1 / 3,
  );
  final lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s;
  final a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
  final bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
  final hue = (math.atan2(bb, a) * 180 / math.pi) % 360;
  return (l: lightness, c: math.sqrt(a * a + bb * bb), h: hue);
}

class _Bands {
  _Bands(HermesThemePreset dark, HermesThemePreset light) {
    final cd = dark.colors, cl = light.colors;
    double maxC(Iterable<Color> colors) =>
        colors.map((c) => oklch(c).c).reduce(math.max);
    accentChroma =
        maxC([cd.accent, cd.accentHover, cl.accent, cl.accentHover]) + 0.005;
    statusChroma =
        maxC([
          cd.error,
          cd.success,
          cd.warning,
          cl.error,
          cl.success,
          cl.warning,
        ]) +
        0.005;
    darkPage = (oklch(cd.background).l - 0.03, oklch(cd.background).l + 0.03);
    lightPage = (oklch(cl.background).l - 0.04, oklch(cl.background).l + 0.005);
    textCeiling = ThemeContrast.ratio(cd.textPrimary, cd.background) + 1.0;
  }

  late final double accentChroma;
  late final double statusChroma;
  late final (double, double) darkPage;
  late final (double, double) lightPage;
  late final double textCeiling;

  /// Neutral pages: Claude's pages are near-grey; families keep only a tint.
  static const surfaceChroma = 0.03;

  /// Surface layering (OKLCH lightness spread of page/surface/variant):
  /// Claude dark 0.080, light 0.052.
  static const layering = (0.03, 0.10);
  static const secondaryChroma = 0.10;
  static const textFloor = 7.0;
  static const hairline = (1.15, 1.6);
}

void main() {
  final bands = _Bands(
    AppTheme.presetById('claude'),
    AppTheme.presetById('claude-light'),
  );

  test('the bands are Claude\'s own (sanity)', () {
    expect(bands.accentChroma, closeTo(0.143, 0.01));
    expect(bands.statusChroma, lessThan(0.17));
    expect(bands.darkPage.$1, closeTo(0.238, 0.01));
  });

  for (final preset in AppTheme.presets) {
    test('${preset.id} sits in the Claude bands', () {
      final c = preset.colors;
      final fails = <String>[];
      void within(String what, double v, (double, double) range) {
        if (v < range.$1 - 1e-9 || v > range.$2 + 1e-9) {
          fails.add('$what ${v.toStringAsFixed(3)} not in $range');
        }
      }

      void atMost(String what, double v, double max) {
        if (v > max + 1e-9) {
          fails.add(
            '$what ${v.toStringAsFixed(3)} > ${max.toStringAsFixed(3)}',
          );
        }
      }

      expect(c.background, isNot(const Color(0xFF000000)));
      expect(c.background, isNot(const Color(0xFFFFFFFF)));
      final page = oklch(c.background).l;
      within('page L', page, preset.isDark ? bands.darkPage : bands.lightPage);
      final ls = [
        c.background,
        c.surface,
        c.surfaceVariant,
      ].map((x) => oklch(x).l).toList();
      within(
        'layering',
        ls.reduce(math.max) - ls.reduce(math.min),
        _Bands.layering,
      );
      for (final (name, tone) in [
        ('background', c.background),
        ('surface', c.surface),
        ('surfaceVariant', c.surfaceVariant),
      ]) {
        atMost('$name chroma', oklch(tone).c, _Bands.surfaceChroma);
      }
      for (final (name, tone) in [
        ('accent', c.accent),
        ('accentHover', c.accentHover),
        ('accentText', c.accentText),
      ]) {
        atMost('$name chroma', oklch(tone).c, bands.accentChroma);
      }
      for (final (name, tone) in [
        ('error', c.error),
        ('success', c.success),
        ('warning', c.warning),
      ]) {
        atMost('$name chroma', oklch(tone).c, bands.statusChroma);
      }
      atMost(
        'secondary chroma',
        oklch(preset.secondary!).c,
        _Bands.secondaryChroma,
      );
      within(
        'body text ratio',
        ThemeContrast.ratio(c.textPrimary, c.background),
        (_Bands.textFloor, bands.textCeiling),
      );
      within(
        'hairline',
        ThemeContrast.ratio(c.divider, c.surface),
        _Bands.hairline,
      );
      expect(fails, isEmpty, reason: fails.join('\n'));
    });
  }
}
