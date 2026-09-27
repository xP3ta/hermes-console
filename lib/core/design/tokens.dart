import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

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
