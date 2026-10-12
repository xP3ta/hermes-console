import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/theme_contrast.dart';

/// Design tokens of spec 080 ("one design system for all of Hermes Console").
///
/// The values are taken from the Bot profile screen, the design reference.
/// Everything visual in `lib/core/design` reads from here; screens should use
/// the components rather than these numbers directly.
abstract final class HermesSpace {
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x5 = 20;
  static const double x6 = 24;
  static const double x8 = 32;

  /// Horizontal page padding (reference `ListView` padding).
  static const double pageH = 18;
  static const double pageTop = 12;
  static const double pageBottom = 24;

  /// Section header spacing (reference `_Header`).
  static const double sectionTop = 22;
  static const double sectionBottom = 8;

  /// Row padding and height (reference `_Line`).
  static const double rowH = 14;
  static const double rowV = 10;
  static const double rowMin = 52;
  static const double rowIconGap = 16;
  static const double rowDividerIndent = 50;

  /// Minimum touch target.
  static const double tap = 48;
}

abstract final class HermesRadius {
  static const double control = 12;
  static const double group = 16;
  static const double floating = 22;
  static const double dialog = 22;
  static const double tag = 999;
}

/// Six-step type scale. Colour is always explicit: pass it via [style].
abstract final class HermesType {
  static const TextStyle display = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
  );
  static const TextStyle title = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
  );
  static const TextStyle body = TextStyle(
    fontSize: 14.5,
    fontWeight: FontWeight.w500,
  );
  static const TextStyle text = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.45,
  );
  static const TextStyle support = TextStyle(
    fontSize: 12.5,
    fontWeight: FontWeight.w400,
  );

  /// Right-aligned row values (reference `_Line.value`).
  static const TextStyle value = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
  );
  static const TextStyle caption = TextStyle(
    fontSize: 11.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.6,
  );

  static TextStyle style(TextStyle base, Color color) =>
      base.copyWith(color: color);
}

/// Human status tones. Colour is only spent when it changes the decision.
enum HermesStatusTone { neutral, active, ok, warn, error }

extension HermesStatusToneColor on HermesStatusTone {
  Color colorIn(HermesThemeColors colors) => switch (this) {
    HermesStatusTone.neutral => colors.textSecondary,
    HermesStatusTone.active => colors.accentText,
    HermesStatusTone.ok => colors.success,
    HermesStatusTone.warn => colors.warning,
    HermesStatusTone.error => colors.error,
  };
}

/// Group surface values of the reference `_Card`.
abstract final class HermesSurfaces {
  static Color group(HermesThemeColors colors) =>
      colors.surfaceVariant.withValues(alpha: .35);
  static Color divider(HermesThemeColors colors) =>
      colors.divider.withValues(alpha: .5);
}

/// Floating chrome ("un punto más claro"): what floats in front of the page
/// (header pieces, pills, the dock, notices, menus) reads one step lighter
/// than the page behind it.
///
/// Every value derives from the palette, so the presets and any custom Theme
/// Studio profile get it with no values of their own:
///  * dark page: `surfaceVariant` lifted 8 % towards white, at 86 %;
///  * light page: white at 88 %; there the hairline and the shadow carry the
///    edge, because white is only a step away from a light page.
///
/// Never blurred: a tint this dense keeps its own labels readable over text
/// passing behind it, and costs nothing per scrolled frame.
@immutable
final class HermesChrome {
  const HermesChrome._({
    required this.dark,
    required this.fill,
    required this.opaque,
    required this.line,
    required this.ink,
    required this.mutedInk,
    required this.shadow,
  });

  /// Whether the page behind is dark.
  final bool dark;

  /// Translucent fill of a floating piece.
  final Color fill;

  /// [fill] as it looks over the empty page. Modal surfaces use it, and so
  /// does every place where nothing may show through.
  final Color opaque;

  /// Hairline around a floating piece.
  final Color line;

  /// Primary ink on the chrome (the palette's `textPrimary`).
  final Color ink;

  /// Secondary ink on the chrome: `textSecondary`, lifted by the smallest
  /// step that reads at AA 4.5:1 on [opaque]. On the lifted fill the plain
  /// `textSecondary` of most dark palettes falls just under it.
  final Color mutedInk;

  /// Soft static shadow. Never animate it.
  final List<BoxShadow> shadow;

  /// How far a dark `surfaceVariant` is lifted towards white.
  static const double lift = 0.08;
  static const double darkOpacity = 0.86;
  static const double lightOpacity = 0.88;

  /// Scrim under a menu or popover: what is behind stays readable.
  static const double scrimMenu = 0.22;

  /// Scrim under a sheet or panel.
  static const double scrimSheet = 0.42;

  /// Scrim under a dialog that asks for an answer.
  static const double scrimDialog = 0.50;

  static final Expando<HermesChrome> _derived = Expando<HermesChrome>(
    'HermesChrome',
  );

  static HermesChrome of(HermesThemeColors colors) =>
      _derived[colors] ??= _derive(colors);

  static HermesChrome ofContext(BuildContext context) =>
      of(Theme.of(context).hermes);

  static HermesChrome _derive(HermesThemeColors colors) {
    const white = Color(0xFFFFFFFF);
    const black = Color(0xFF000000);
    final page = colors.background;
    final dark = ThemeData.estimateBrightnessForColor(page) == Brightness.dark;
    // A custom profile may declare a translucent token: read it over the page.
    final raised = ThemeContrast.composite(colors.surfaceVariant, page);
    final base = dark ? ThemeContrast.blend(raised, white, lift) : white;
    final fill = base.withValues(alpha: dark ? darkOpacity : lightOpacity);
    final opaque = ThemeContrast.composite(fill, page);
    return HermesChrome._(
      dark: dark,
      fill: fill,
      opaque: opaque,
      line: dark
          ? white.withValues(alpha: 0.15)
          : colors.textPrimary.withValues(alpha: 0.11),
      ink: colors.textPrimary,
      mutedInk: ThemeContrast.adjustForContrast(colors.textSecondary, [
        opaque,
      ], minimum: 4.5),
      shadow: dark
          ? [
              BoxShadow(
                color: black.withValues(alpha: 0.55),
                blurRadius: 26,
                spreadRadius: -8,
                offset: const Offset(0, 12),
              ),
              BoxShadow(
                color: black.withValues(alpha: 0.22),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ]
          : const [
              BoxShadow(
                color: Color(0x4D463C28),
                blurRadius: 26,
                spreadRadius: -10,
                offset: Offset(0, 12),
              ),
              BoxShadow(
                color: Color(0x1A463C28),
                blurRadius: 3,
                offset: Offset(0, 1),
              ),
            ],
    );
  }
}
