// The colours of a launcher widget: the active theme's own, nothing added.
//
// The card is the theme's glass as far as a bitmap allows it: a translucent
// body of the page's colour (the wallpaper is the owner's and shows through
// a little) under the glass veil, a hairline, no shadow. The accent appears
// only where the theme puts it: the primary button, the ring of a face that
// waits for you, a dot of something new.
import 'dart:ui';

import 'package:flutter/material.dart' show ThemeData, Brightness;

import '../../theme/app_theme.dart' show HermesThemeColors;
import '../../theme/box_fill.dart' show HermesPageTint;
import '../../theme/theme_contrast.dart' show ThemeContrast;

class LauncherWidgetPalette {
  const LauncherWidgetPalette({
    required this.id,
    required this.dark,
    required this.page,
    required this.card,
    required this.veil,
    required this.hair,
    required this.variant,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.accent,
    required this.onAccent,
    required this.accentText,
    required this.ok,
    required this.warn,
    required this.error,
    required this.fontFamily,
  });

  /// A short name that tells two palettes apart (a file name, a test).
  final String id;
  final bool dark;

  /// The theme's page, opaque.
  final Color page;

  /// The body of the card: the page, translucent.
  final Color card;

  /// The glass veil laid over the body (the theme's own, the page's light).
  final Color veil;

  /// The hairline round the card and between rows.
  final Color hair;

  /// The body of a secondary button or a chip.
  final Color variant;

  /// Primary, secondary and tertiary ink.
  final Color ink;
  final Color ink2;
  final Color ink3;

  final Color accent;
  final Color onAccent;
  final Color accentText;
  final Color ok;
  final Color warn;
  final Color error;

  /// The family the app is set to; the bitmap is typeset in it.
  final String fontFamily;

  /// Opacity of the card's body over the wallpaper. High enough for the ink
  /// to read over any picture, low enough to tell it is glass.
  static const double darkBodyOpacity = 0.84;
  static const double lightBodyOpacity = 0.88;

  /// The glass veil of a dark theme ([GlassMaterial]'s full level).
  static const double darkVeil = 0.075;

  /// Something that is no longer current is drawn at this opacity.
  static const double dimOpacity = 0.55;

  static LauncherWidgetPalette of(
    HermesThemeColors colors, {
    required String fontFamily,
    String id = 'theme',
  }) {
    final page = ThemeContrast.composite(
      colors.background,
      const Color(0xFF000000),
    );
    final dark = ThemeData.estimateBrightnessForColor(page) == Brightness.dark;
    final veil = dark
        ? HermesPageTint.veil(page, darkVeil)
        : const Color(0xFFFFFFFF).withValues(alpha: 0.5);
    final hair = dark
        ? const Color(0xFFFFFFFF).withValues(alpha: 0.11)
        : ThemeContrast.composite(colors.divider, page).withValues(alpha: 0.9);
    return LauncherWidgetPalette(
      id: id,
      dark: dark,
      page: page,
      card: (dark ? page : ThemeContrast.composite(colors.surface, page))
          .withValues(alpha: dark ? darkBodyOpacity : lightBodyOpacity),
      veil: veil,
      hair: hair,
      variant: ThemeContrast.composite(colors.surfaceVariant, page),
      ink: ThemeContrast.composite(colors.textPrimary, page),
      ink2: ThemeContrast.composite(colors.textSecondary, page),
      ink3: ThemeContrast.composite(colors.textTertiary, page),
      accent: colors.accent,
      onAccent: colors.onAccent,
      accentText: ThemeContrast.composite(colors.accentText, page),
      ok: colors.success,
      warn: colors.warning,
      error: colors.error,
      fontFamily: fontFamily,
    );
  }

  /// [color] faded for something that is no longer current.
  Color dim(Color color) => color.withValues(alpha: color.a * dimOpacity);
}
