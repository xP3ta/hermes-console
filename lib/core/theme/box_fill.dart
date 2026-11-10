// The body of the content boxes: cards, groups, panels, the rows of a list,
// the search field, the notices.
//
// It is SOLID and it comes from the page colour alone: a dark page's body is
// the page mixed with white, the least that sets it clearly apart from the
// page (and from the glow under it); a light page's body is the page lifted a
// little towards white. Nothing here depends on a transparency, a blur or the
// ink drawn on it, so the same body holds wherever the glass does not reach
// (the theme wears none, high contrast, an older level): the glass material
// and every fallback read it from here.
//
// The inks are derived AFTER the body ([HermesThemeColors.withReadableInk]):
// the body never moves to suit a text colour.
//
// A TINTED dark page (one with a hue you can see: a night blue) keeps that
// hue in everything lifted from it ([HermesPageTint]): mixing such a page
// with white keeps its hue but drains its saturation, so the boxes, the
// chrome and the glass pieces came out grey on a blue page. A neutral page
// (black, charcoal, a grey with a cast) is mixed with white exactly as
// before.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'glass_look.dart' show GlassMaterial;
import 'theme_contrast.dart';

/// The tint of a dark page, carried into every surface lifted from it.
///
/// A lift towards white on a dark page is the base's hue and saturation at
/// the lightness the mix reaches ([lift], [keepHue]); the translucent white
/// of the glass pieces and hairlines becomes a veil of the page's own light
/// ([veil]), as opaque as it needs to be to lift the page the same. On a
/// neutral page ([isTinted] false) every call answers the plain white mix,
/// bit for bit, so black and grey pages keep the surfaces they had.
abstract final class HermesPageTint {
  /// HSL saturation from which a dark page is tinted. A charcoal with a
  /// cast (0.05) and a grey-blue stay neutral; a night blue (0.5) is tinted.
  static const double tintedSaturation = 0.25;

  /// How much more opaque a tinted veil is than the white one it stands in
  /// for: its light is darker than white, so it needs more body to lift the
  /// page as much.
  static const double veilOpacity = 1.8;

  static const Color _white = Color(0xFFFFFFFF);
  static const Color _black = Color(0xFF000000);

  static final Expando<bool> _tinted = Expando<bool>('HermesPageTint');

  /// Whether [page] is a dark page with a visible hue.
  static bool isTinted(Color page) => _tinted[page] ??= _isTinted(page);

  static bool _isTinted(Color page) {
    final opaque = ThemeContrast.composite(page, _black);
    if (ThemeData.estimateBrightnessForColor(opaque) != Brightness.dark) {
      return false;
    }
    return HSLColor.fromColor(opaque).saturation >= tintedSaturation;
  }

  /// [lifted], a colour mixed towards white from [of]: unchanged on a
  /// neutral [page]; on a tinted one, [of]'s hue and saturation at the
  /// lightness [lifted] reached, so the step up never greys.
  static Color keepHue(Color lifted, {required Color of, required Color page}) {
    if (!isTinted(page)) return lifted;
    final base = HSLColor.fromColor(of);
    if (base.saturation == 0) return lifted;
    final lightness = HSLColor.fromColor(lifted).lightness;
    return Color(
      base.withLightness(lightness.clamp(0.0, 1.0)).toColor().toARGB32(),
    ).withValues(alpha: lifted.a);
  }

  /// [base] lifted towards white by [amount] on [page]: the plain mix on a
  /// neutral page, the same lightness in [base]'s own hue on a tinted one.
  static Color lift(Color base, double amount, {required Color page}) =>
      keepHue(ThemeContrast.blend(base, _white, amount), of: base, page: page);

  /// The translucent light of the glass on [page]: white at [alpha] on a
  /// neutral page; on a tinted one, the colour that, laid over the page at
  /// [veilOpacity] times [alpha], lifts it to exactly what white at [alpha]
  /// would, in the page's own hue and saturation.
  static Color veil(Color page, double alpha) {
    if (!isTinted(page)) return _white.withValues(alpha: alpha);
    final opaque = ThemeContrast.composite(page, _black);
    final target = lift(opaque, alpha, page: opaque);
    final a = (alpha * veilOpacity).clamp(0.0, 1.0);
    double channel(double to, double from) =>
        (from + (to - from) / a).clamp(0.0, 1.0);
    return Color.from(
      alpha: a,
      red: channel(target.r, opaque.r),
      green: channel(target.g, opaque.g),
      blue: channel(target.b, opaque.b),
    );
  }
}

@immutable
final class HermesBoxFill {
  const HermesBoxFill._({
    required this.dark,
    required this.page,
    required this.glow,
    required this.group,
    required this.card,
  });

  /// The page is dark.
  final bool dark;

  /// The page, opaque.
  final Color page;

  /// The page's glow at its strongest (the one the glass paints behind the
  /// surfaces).
  final Color glow;

  /// Body of a group, a panel, a list section, a field.
  final Color group;

  /// Body of a card or a row: a step apart from [group].
  final Color card;

  /// The least contrast a dark body keeps against the page.
  static const double darkStep = 1.26;

  /// ... and against the glow, which is a little lighter than the page.
  static const double darkGlowStep = 1.15;

  /// The range of the white mixed into a dark page (a dark page needs more
  /// the darker it is: the ratio is what binds, not the percentage).
  static const double darkLeast = 0.06;
  static const double darkMost = 0.15;

  /// How much more white a dark card takes than a dark group.
  static const double darkCardMore = 0.012;

  static final Expando<HermesBoxFill> _cache = Expando('HermesBoxFill');

  static HermesBoxFill of(HermesThemeColors colors) =>
      _cache[colors] ??= _derive(colors);

  static HermesBoxFill _derive(HermesThemeColors colors) {
    const white = Color(0xFFFFFFFF);
    final page = ThemeContrast.composite(
      colors.background,
      const Color(0xFF000000),
    );
    final dark =
        ThemeData.estimateBrightnessForColor(colors.background) ==
        Brightness.dark;
    final glow = GlassMaterial.glowOf(page, dark: dark, full: true);
    if (!dark) {
      final lift = GlassMaterial.lightLift(full: true);
      return HermesBoxFill._(
        dark: false,
        page: page,
        glow: glow,
        group: ThemeContrast.blend(page, white, lift.$1),
        card: ThemeContrast.blend(page, white, lift.$2),
      );
    }
    // On a tinted page the lift keeps the page's hue and saturation
    // ([HermesPageTint.lift]); the ratios are what bind, so the search is
    // the same.
    var amount = darkMost;
    for (var a = darkLeast; a <= darkMost + 1e-9; a += 0.005) {
      final body = HermesPageTint.lift(page, a, page: page);
      if (ThemeContrast.ratio(body, page) >= darkStep &&
          ThemeContrast.ratio(body, glow) >= darkGlowStep) {
        amount = a;
        break;
      }
    }
    return HermesBoxFill._(
      dark: true,
      page: page,
      glow: glow,
      group: HermesPageTint.lift(page, amount, page: page),
      card: HermesPageTint.lift(
        page,
        math.min(1.0, amount + darkCardMore),
        page: page,
      ),
    );
  }

  /// A notice's body: a card with the accent's faint tint.
  static Color banner(HermesThemeColors colors, Color card) =>
      Color.alphaBlend(colors.accent.withValues(alpha: 0.06), card);

  /// Every surface text is read on, opaque: the page and its glow, the
  /// bodies of the boxes, a notice, the theme's own surfaces and the user's
  /// bubble. An ink that reads on all of them reads wherever the app puts it.
  List<Color> readingBacks(HermesThemeColors colors) {
    final surface = ThemeContrast.composite(colors.surface, page);
    final variant = ThemeContrast.composite(colors.surfaceVariant, page);
    final bubble = colors.surfaceVariant.withValues(
      alpha: GlassMaterial.bubbleOpacity,
    );
    return [
      page,
      glow,
      group,
      card,
      banner(colors, card),
      surface,
      variant,
      ThemeContrast.composite(bubble, page),
      ThemeContrast.composite(bubble, glow),
    ];
  }
}
