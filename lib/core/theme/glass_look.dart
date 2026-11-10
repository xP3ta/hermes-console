// The "glass" layer over any theme.
//
// The theme keeps every colour it had. This layer only decides how the
// surfaces BEHAVE: a body a step lighter than the page, a hairline, a soft
// glint at the top, one faint glow of the page's own colour behind
// everything, a gradient on the primary button and small tracked section
// labels. It has three levels (off, soft, full) and a per-theme safety: the
// material only exists for a theme whose ink reads on it over the whole range
// of the backdrop, otherwise that theme drops to a lower level instead of the
// threshold dropping. Off leaves the page completely flat.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../design/tokens.dart' show HermesGel;
import 'app_theme.dart';
import 'box_fill.dart';
import 'lines.dart' show HermesLines;
import 'soft_tokens.dart';
import 'theme_contrast.dart';

/// How much glass a surface wears.
enum GlassLevel {
  off,
  soft,
  full;

  static GlassLevel fromName(String? name) {
    for (final level in values) {
      if (level.name == name) return level;
    }
    return GlassLevel.full;
  }
}

/// The device setting: one level for the whole app.
///
/// The level is FIXED at [GlassLevel.full] for everybody: the Glass selector
/// was taken out of the app (the product decision is Glass, Full, with no
/// choice), so a store read from disk ignores whatever an older install saved
/// (a 9800/9801 build could save Off or Soft) and [setLevel] does nothing on
/// it. The per-theme safety ([GlassMaterial.effective]) is NOT a user choice
/// and stays: a theme whose ink does not read on the glass still drops to a
/// lower level by itself.
///
/// The type and its tests stay so the value keeps flowing through
/// [GlassLookScope]; only [GlassLookPrefs.inMemory], a test seam, can hold
/// another level.
class GlassLookPrefs extends ChangeNotifier {
  GlassLookPrefs._(this._prefs, {required bool fixed})
    : _fixed = fixed,
      _level = fixed
          ? GlassLevel.full
          : GlassLevel.fromName(_prefs?.getString(levelKey));

  /// The key older builds saved the choice under. It is no longer read.
  static const String levelKey = 'glass_look_level';

  final SharedPreferences? _prefs;
  final bool _fixed;
  GlassLevel _level;

  static GlassLookPrefs? _shared;

  static GlassLookPrefs get shared =>
      _shared ??= GlassLookPrefs._(null, fixed: true);

  static Future<GlassLookPrefs> load([SharedPreferences? prefs]) async {
    final resolved = prefs ?? await SharedPreferences.getInstance();
    final store = GlassLookPrefs._(resolved, fixed: true);
    final previous = _shared;
    _shared = store;
    previous?.notifyListeners();
    return store;
  }

  @visibleForTesting
  static void debugUse(GlassLookPrefs? store) => _shared = store;

  /// A store that lives in memory, for a test. Unlike the real one it can
  /// hold and change to any level, so the levels stay testable.
  @visibleForTesting
  factory GlassLookPrefs.inMemory([GlassLevel level = GlassLevel.full]) =>
      GlassLookPrefs._(null, fixed: false).._level = level;

  GlassLevel get level => _level;

  /// No effect on the real store (the level is fixed, see the class doc).
  Future<void> setLevel(GlassLevel value) async {
    if (_fixed || _level == value) return;
    _level = value;
    notifyListeners();
    await _prefs?.setString(levelKey, value.name);
  }
}

/// Hands the level to the tree. Without one above (a test, a lone widget)
/// the shared store answers.
class GlassLookScope extends InheritedNotifier<GlassLookPrefs> {
  const GlassLookScope({
    required GlassLookPrefs prefs,
    required super.child,
    super.key,
  }) : super(notifier: prefs);

  /// The level the user asked for; it listens.
  static GlassLevel levelOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<GlassLookScope>();
    return (scope?.notifier ?? GlassLookPrefs.shared).level;
  }
}

/// The glass of one theme at one level: every value is derived from the
/// theme's own colours.
@immutable
class GlassMaterial {
  const GlassMaterial._({
    required this.level,
    required this.dark,
    required this.page,
    required this.shadow,
    required this.rim,
    required this.selected,
    required this.selectedLine,
    required this.groupFill,
    required this.cardFill,
    required this.pieceFill,
    required this.line,
    required this.lineTop,
    required this.lineBottom,
    required this.boxShadow,
    required this.rimShade,
    required this.sheen,
    required this.glow,
    required this.buttonEnd,
    required this.readingVeil,
  });

  /// The level this theme really gets (never [GlassLevel.off]).
  final GlassLevel level;
  final bool dark;

  /// The page the glass sits on: the theme's own background, opaque.
  final Color page;

  /// The shadow under a piece of glass: on a light page the accent turned to
  /// ochre and darkened, short and faint; null on a dark one, where a shadow
  /// would only be a hard edge.
  final Color? shadow;

  /// The 1 px light that runs along the top edge, inside the piece.
  final Color rim;

  /// The body of the selected piece of a segmented control or a tab: a soft
  /// fill of the accent over the glass (the main ink reads on it), with
  /// [selectedLine], the accent, as its border. Never just a paler white.
  final Color selected;
  final Color selectedLine;

  /// The least ratio the border of a piece of glass keeps against the page,
  /// light or dark: the contour of a box ([HermesLines.contourRatio]; it
  /// was 1.5, which read as no border at all on a charcoal page).
  static const double borderRatio = HermesLines.contourRatio;

  /// Body of a group, a panel, a list section, a field: SOLID, derived from
  /// the page alone ([HermesBoxFill]): the page mixed with white in a dark
  /// theme, by the least that sets it clearly apart; lightened a little
  /// towards white in a light one ([lightLift]). Opaque, so the text on it
  /// never depends on what is behind and the short shadow under the piece
  /// never shows through it.
  final Color groupFill;

  /// Body of a card or a row: a step apart from [groupFill], also solid.
  final Color cardFill;

  /// Body of the small pieces that stay glass (a ghost button, a chip, a
  /// segmented control): translucent white over what is behind in a dark
  /// theme (the page's own light on a tinted page, [HermesPageTint.veil]),
  /// the group's body in a light one.
  final Color pieceFill;

  /// Hairline around a glass piece, as a single colour (the weakest of the
  /// two edges below): what a widget that can only take one border colour
  /// (a chip, a segmented button, a dialog) wears.
  final Color line;

  /// The two tones of the contour of a box ([HermesBoxEdge]): the top edge
  /// and the bottom one, in the gel's grammar (the light comes from above:
  /// the top is the lighter, the bottom the darker). Both keep
  /// [borderRatio] against the page, on the page and on its glow.
  final Color lineTop;
  final Color lineBottom;

  /// The short shadow under a box, on a dark page too (where [shadow] is
  /// null so that menus and sheets keep their look). A box paints it
  /// outside its own outline only, so a translucent body never shows it.
  final Color boxShadow;

  /// The inner shade of the bottom edge of a box, one pixel in.
  final Color rimShade;

  /// The glint at the top of a piece, at its strongest.
  final Color sheen;

  /// The one glow of the page, at its centre: the page's own colour (same
  /// hue and saturation) a few per cent lighter on a dark page or darker on a
  /// light one. It fades out to the page colour; nothing else is painted
  /// behind the surfaces.
  final Color glow;

  /// The light end of the primary button's gradient; null keeps it flat.
  final Color? buttonEnd;

  /// How opaque the page colour is laid over the glow where long text is
  /// read (the "reading calm"), at full calm. The theme raises it until its
  /// main ink reaches 7:1 and the secondary 4.5:1 on the worst point there.
  final double readingVeil;

  /// The bubble of a user's message: opaque enough that its text does not
  /// depend on what is behind it.
  static const double bubbleOpacity = 0.88;

  /// The part of the page, top and bottom, where the calm fades out so the
  /// glow shows at the edges. Between the two edges it is one flat veil: no
  /// gradient behind a paragraph.
  static const double calmEdge = 0.07;

  /// The veil, from 0 to 1 of [readingVeil], at [fraction] (0 top, 1 bottom)
  /// of the page.
  static double calmAt(double fraction) {
    final t = fraction.clamp(0.0, 1.0);
    if (t < calmEdge) return t / calmEdge;
    if (t > 1 - calmEdge) return (1 - t) / calmEdge;
    return 1;
  }

  /// [page] with the reading veil of [calm] (0 to 1) laid over [back].
  Color readingBack(Color page, Color back, {double calm = 1}) =>
      ThemeContrast.composite(page.withValues(alpha: readingVeil * calm), back);

  bool get isFull => level == GlassLevel.full;

  static const Color _white = Color(0xFFFFFFFF);
  static const Color _black = Color(0xFF000000);

  /// Where the glow sits, as a fraction of the page: high and to the left.
  static const Offset glowAt = Offset(0.15, -0.05);

  /// Reach of the glow, as a fraction of the page's longest side.
  static const double glowReach = 0.95;

  /// How far the glow's lightness moves from the page's (HSL, 0 to 1), on a
  /// dark page (lighter) and on a light one (darker), at each level. Hue and
  /// saturation stay the page's.
  static double glowStep({required bool dark, required bool full}) =>
      dark ? (full ? 0.05 : 0.025) : (full ? 0.04 : 0.02);

  /// How far a light piece's body is lifted from the page towards white
  /// ([groupFill], [cardFill]); the group takes the first of each pair.
  static (double group, double card) lightLift({required bool full}) =>
      full ? (0.36, 0.46) : (0.36, 0.44);

  /// The glow of [page]: its own hue and saturation with the lightness moved
  /// by [glowStep] (lighter on a dark page, darker on a light one).
  static Color glowOf(Color page, {required bool dark, required bool full}) {
    final hsl = HSLColor.fromColor(page);
    final step = glowStep(dark: dark, full: full);
    final lightness = hsl.lightness + (dark ? step : -step);
    return hsl.withLightness(lightness.clamp(0.0, 1.0)).toColor();
  }

  static final Expando<Map<GlassLevel, GlassMaterial?>> _cache = Expando(
    'GlassMaterial',
  );

  /// The ratio every ink must reach on the glass.
  static const double minimumRatio = 4.5;

  /// The ratio the main ink must reach where long text is read (AAA).
  static const double readingPrimaryRatio = 7.0;

  /// The glass [colors] wears when [requested] is the user's level, or null
  /// when it wears none: the level is off the Outline style is on
  /// ([HermesThemeColors.outlined]) or no level reads on it.
  static GlassMaterial? resolve(
    HermesThemeColors colors,
    GlassLevel requested,
  ) {
    if (requested == GlassLevel.off || colors.outlined) return null;
    final byLevel = _cache[colors] ??= {};
    return byLevel.putIfAbsent(requested, () {
      for (final level in [GlassLevel.full, GlassLevel.soft]) {
        if (level.index > requested.index) continue;
        final material = _build(colors, level);
        if (material != null) return material;
      }
      return null;
    });
  }

  /// The level [colors] really gets for [requested].
  static GlassLevel effective(HermesThemeColors colors, GlassLevel requested) =>
      resolve(colors, requested)?.level ?? GlassLevel.off;

  /// The body of the small glass pieces of [colors] on the full level (a
  /// segmented control's track, a chip), over the body of a group, opaque:
  /// what an ink or a ring on the track is checked against before the
  /// material itself is built ([HermesThemeColors.withReadableInk]).
  static Color pieceOverGroup(HermesThemeColors colors) {
    final bodies = HermesBoxFill.of(colors);
    if (!bodies.dark) return bodies.group;
    return ThemeContrast.composite(
      HermesPageTint.veil(bodies.page, pieceAlphaFull),
      bodies.group,
    );
  }

  /// The translucent white of a dark piece's body, on the full level and on
  /// the soft one.
  static const double pieceAlphaFull = 0.075;
  static const double pieceAlphaSoft = 0.055;

  /// The inks that must read on the glass.
  static List<Color> inks(HermesThemeColors colors, bool dark) {
    final soft = SoftPalette.of(
      colors,
      dark ? Brightness.dark : Brightness.light,
    );
    return [
      colors.textPrimary,
      colors.textSecondary,
      soft.text,
      soft.textMuted,
    ];
  }

  /// Whether every ink reads on [back] bare and under each body of glass.
  static bool _reads(
    List<Color> inks,
    Color back,
    Color groupFill,
    Color cardFill,
    Color pieceFill,
  ) {
    for (final surface in [
      back,
      ThemeContrast.composite(groupFill, back),
      ThemeContrast.composite(cardFill, back),
      ThemeContrast.composite(pieceFill, back),
      ThemeContrast.composite(
        pieceFill,
        ThemeContrast.composite(cardFill, back),
      ),
    ]) {
      for (final ink in inks) {
        if (ThemeContrast.ratio(ink, surface) < minimumRatio) return false;
      }
    }
    return true;
  }

  /// The hue of ochre the light glass's shadow and border lean to.
  static const double _ochre = 36;

  static GlassMaterial? _build(HermesThemeColors colors, GlassLevel level) {
    final dark =
        ThemeData.estimateBrightnessForColor(colors.background) ==
        Brightness.dark;
    final full = level == GlassLevel.full;
    // The page is the theme's own, dark or light: a light theme's page is the
    // colour of its light preset.
    final page = ThemeContrast.composite(colors.background, _black);
    // The bodies of the boxes are solid and come from the page alone
    // ([HermesBoxFill]): a dark page mixed with white, a light one lifted a
    // little towards white, never near-white and never see-through. The small
    // pieces that stay glass keep a translucent body in a dark theme.
    // On a tinted page that translucent body is a veil of the page's own
    // light ([HermesPageTint.veil]), never a grey one.
    final bodies = HermesBoxFill.of(colors);
    final groupFill = bodies.group;
    final cardFill = bodies.card;
    final pieceFill = dark
        ? HermesPageTint.veil(page, full ? pieceAlphaFull : pieceAlphaSoft)
        : groupFill;
    final inks = GlassMaterial.inks(colors, dark);
    // The page itself, under the glass, must already read.
    if (!_reads(inks, page, groupFill, cardFill, pieceFill)) return null;

    // One glow, monochrome: the page's hue and saturation with its lightness
    // moved a few per cent (lighter on a dark page, darker on a light one).
    final glow = glowOf(page, dark: dark, full: full);
    // The page and the glow at its strongest: every ink must read on both,
    // bare and under each body of glass.
    final backs = [page, glow];
    for (final back in backs) {
      if (!_reads(inks, back, groupFill, cardFill, pieceFill)) return null;
    }

    // Where long text is read the page colour veils the glow. Start from a
    // calm of the level and raise it, for this theme, until the main ink
    // reaches 7:1 and the secondary 4.5:1 on the worst point (the glow at its
    // strongest, under every body of glass and a user's bubble).
    final bubble = colors.surfaceVariant.withValues(alpha: bubbleOpacity);
    double? veil;
    for (var a = full ? 0.7 : 0.55; a <= 1.0001; a += 0.02) {
      var good = true;
      for (final cloud in backs) {
        final back = ThemeContrast.composite(page.withValues(alpha: a), cloud);
        for (final surface in [
          back,
          ThemeContrast.composite(groupFill, back),
          ThemeContrast.composite(cardFill, back),
          ThemeContrast.composite(pieceFill, back),
          ThemeContrast.composite(bubble, back),
        ]) {
          if (ThemeContrast.ratio(colors.textPrimary, surface) <
                  readingPrimaryRatio ||
              ThemeContrast.ratio(colors.textSecondary, surface) <
                  minimumRatio) {
            good = false;
          }
        }
      }
      if (good) {
        veil = a.clamp(0.0, 1.0);
        break;
      }
    }
    if (veil == null) return null;

    // The glint is painted under the ink, as part of the body: take the
    // strongest one every ink still reads through, on the page and on the
    // glow (the veil only moves a back towards the page, so these bound it).
    // The glint is painted with the body: a faint one, a dark body is only a
    // few per cent of white.
    final sheenMax = dark ? (full ? 0.05 : 0.025) : (full ? 0.2 : 0.12);
    var sheenAlpha = 0.0;
    for (final factor in const [1.0, 0.66, 0.4, 0.2]) {
      final glint = _white.withValues(alpha: sheenMax * factor);
      var good = true;
      for (final back in backs) {
        for (final fill in [groupFill, cardFill, pieceFill]) {
          final surface = ThemeContrast.composite(
            glint,
            ThemeContrast.composite(fill, back),
          );
          for (final ink in inks) {
            if (ThemeContrast.ratio(ink, surface) < minimumRatio) good = false;
          }
        }
      }
      if (good) {
        sheenAlpha = sheenMax * factor;
        break;
      }
    }

    Color? end;
    if (full) {
      for (final amount in const [0.22, 0.14, 0.08]) {
        final candidate = ThemeContrast.blend(colors.accent, _white, amount);
        if (ThemeContrast.ratio(colors.onAccent, candidate) >= minimumRatio) {
          end = candidate;
          break;
        }
      }
    }
    // Light glass: a warm shadow (the accent turned to ochre, darkened) and a
    // hairline of the warm ink, since a white edge would vanish on a pale
    // page. Dark glass keeps its white hairline and no shadow.
    // Brown ochre with a touch of the accent: the shadow and the border.
    final warmInk = ThemeContrast.blend(
      HSLColor.fromAHSL(1, _ochre, 0.5, 0.22).toColor(),
      colors.accent,
      0.1,
    );
    // The contour of a box is two-toned (lighter on top, darker below, as
    // the gel's rims) and both tones keep [borderRatio] against the page and
    // its glow, over each body. Dark: white, the least alpha that gets there
    // (never below the level's own); light: the warm ink, as faint as it
    // can be.
    // The contour keeps its 1.5:1 against the page and its glow on its own
    // (over the bare page) AND over each solid body (a light body is lighter
    // than the page, so the contour is weakest there).
    final fills = [groupFill, cardFill];
    double worst(Color line) {
      var least = double.infinity;
      for (final back in backs) {
        least = math.min(
          least,
          ThemeContrast.ratio(ThemeContrast.composite(line, back), back),
        );
        for (final fill in fills) {
          final under = ThemeContrast.composite(fill, back);
          final pixel = ThemeContrast.composite(line, under);
          least = math.min(least, ThemeContrast.ratio(pixel, back));
        }
      }
      return least;
    }

    // Dark: the page's light (white, or the tinted veil of a tinted page).
    Color edge(double alpha) => dark
        ? HermesPageTint.veil(page, alpha)
        : warmInk.withValues(alpha: alpha);
    final floor = dark ? (full ? 0.14 : 0.10) : 0.2;
    var base = 0.9;
    for (var percent = (floor * 100).round(); percent <= 90; percent++) {
      final candidate = percent / 100;
      if (worst(edge(candidate)) >= borderRatio + 0.03) {
        base = candidate;
        break;
      }
    }
    final edgeStep = dark ? HermesGel.boxEdgeStep : HermesGel.boxEdgeStepLight;
    final far = math.min(0.9, base + edgeStep);
    final lineTop = edge(dark ? far : base);
    final lineBottom = edge(dark ? base : far);
    // The selected piece: the accent, as soft as the main ink allows.
    Color? selected;
    for (final a in const [0.22, 0.18, 0.14, 0.1]) {
      final candidate = colors.accent.withValues(alpha: a);
      var good = true;
      for (final back in backs) {
        final group = ThemeContrast.composite(groupFill, back);
        // On the body of a group, and on the track of a segmented control
        // (the small glass over the group), where the segment sits.
        for (final under in [
          group,
          ThemeContrast.composite(pieceFill, group),
        ]) {
          final surface = ThemeContrast.composite(candidate, under);
          if (ThemeContrast.ratio(colors.textPrimary, surface) < minimumRatio) {
            good = false;
          }
        }
      }
      if (good) {
        selected = candidate;
        break;
      }
    }
    if (selected == null) return null;
    return GlassMaterial._(
      level: level,
      dark: dark,
      page: page,
      shadow: dark ? null : warmInk.withValues(alpha: full ? 0.12 : 0.09),
      rim: dark
          ? _white.withValues(
              alpha: full ? HermesGel.rimTopAlpha : HermesGel.rimTopAlpha / 2,
            )
          : _white.withValues(alpha: full ? 0.6 : 0.45),
      selected: selected,
      selectedLine: colors.accent,
      groupFill: groupFill,
      cardFill: cardFill,
      pieceFill: pieceFill,
      line: dark ? lineBottom : lineTop,
      lineTop: lineTop,
      lineBottom: lineBottom,
      boxShadow: dark
          ? _black.withValues(
              alpha: HermesGel.boxShadowDarkAlpha * (full ? 1 : 0.7),
            )
          : warmInk.withValues(alpha: full ? 0.12 : 0.09),
      rimShade: _black.withValues(
        alpha: dark
            ? HermesGel.boxRimBottomDarkAlpha
            : HermesGel.rimBottomAlpha,
      ),
      sheen: _white.withValues(alpha: sheenAlpha),
      glow: glow,
      buttonEnd: end,
      readingVeil: veil,
    );
  }
}
