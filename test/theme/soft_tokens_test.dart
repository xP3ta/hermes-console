import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/soft_tokens.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';

void main() {
  test('there are presets to check', () {
    expect(AppTheme.presets.length, greaterThanOrEqualTo(30));
  });

  for (final preset in AppTheme.presets) {
    test(
      '${preset.id}: neutral surface, capped pastel tints, readable ink',
      () {
        final theme = AppTheme.fromId(preset.id);
        final colors = theme.hermes;
        final palette = SoftPalette.of(colors, theme.brightness);

        // The widget surface is distinct from the background, calmly.
        final dL =
            (SoftPalette.lightness(palette.surface) -
                    SoftPalette.lightness(colors.background))
                .abs();
        expect(dL, inInclusiveRange(0.015, 0.16), reason: 'surface ΔL $dL');

        for (final hue in SoftHue.values.where((h) => h != SoftHue.neutral)) {
          final tint = palette.tint(hue);
          // Low chroma: pastel, never neon.
          expect(
            SoftPalette.chroma(tint.wash),
            lessThanOrEqualTo(SoftPalette.maxWashChroma + 1e-6),
            reason: '$hue wash chroma',
          );
          expect(
            ThemeContrast.ratio(tint.ink, tint.wash),
            greaterThanOrEqualTo(3.0),
            reason: '$hue icon on wash',
          );
          expect(
            ThemeContrast.ratio(tint.ink, palette.surface),
            greaterThanOrEqualTo(3.0),
            reason: '$hue icon on surface',
          );
          expect(
            SoftPalette.chroma(tint.ink),
            lessThanOrEqualTo(SoftPalette.maxInkChroma + 1e-6),
            reason: '$hue ink chroma',
          );
        }
        // Neutral option: no hue.
        final neutral = palette.tint(SoftHue.neutral);
        expect(
          SoftPalette.chroma(neutral.wash),
          lessThanOrEqualTo(SoftPalette.chroma(palette.surface) + 0.02 + 1e-6),
        );
        expect(
          ThemeContrast.ratio(neutral.ink, neutral.wash),
          greaterThanOrEqualTo(4.5),
        );

        for (final ink in [palette.text, palette.textMuted]) {
          expect(
            ThemeContrast.ratio(ink, palette.surface),
            greaterThanOrEqualTo(4.5),
          );
        }
        for (final status in [palette.attention, palette.failure, palette.ok]) {
          expect(
            ThemeContrast.ratio(status, palette.surface),
            greaterThanOrEqualTo(4.5),
            reason: 'status text',
          );
        }
        expect(
          ThemeContrast.ratio(palette.onPrimary, palette.primary),
          greaterThanOrEqualTo(4.5),
          reason: 'primary button label',
        );
      },
    );
  }

  test('squircle shapes and capsule bars', () {
    expect(SoftShapes.card(), isA<RoundedSuperellipseBorder>());
    expect(SoftShapes.capsule(), isA<StadiumBorder>());
    expect(SoftRadii.card, inInclusiveRange(22, 26));
  });

  test('the spring curve settles without visible overshoot', () {
    var max = 0.0;
    for (var i = 0; i <= 100; i++) {
      final v = SoftMotion.spring.transform(i / 100);
      if (v > max) max = v;
    }
    expect(SoftMotion.spring.transform(0), 0);
    expect(SoftMotion.spring.transform(1), 1);
    expect(max, lessThanOrEqualTo(1.02));
    expect(SoftMotion.spring.transform(0.5), greaterThan(0.6));
  });
}
