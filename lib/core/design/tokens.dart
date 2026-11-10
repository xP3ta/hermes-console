import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/box_fill.dart';
import '../theme/lines.dart';
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

  /// Horizontal page padding (reference `ListView` padding). the owner's
  /// default for 1.4.0: change it here, nowhere else.
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

  /// Gap between floating pieces, and between the work pane and the chat
  /// (mock 136 v2-A `--gap`).
  static const double gap = 10;

  /// Inset inside the work pane and its cards (mock 136 v2-A `--inset`).
  static const double inset = 12;
}

/// The one radius scale (audit 1.4.0, §3.1), from mock 136 v2-A.
///
/// From the largest: [sheet], [pane], [card], [row], [control], [chip] and
/// [tag]. Bars and grabbers take half their own height instead.
abstract final class HermesRadius {
  /// Bottom sheets: the notch sheet, the viewer, the pane's menus
  /// (`--r-sheet`). the owner's default for 1.4.0.
  static const double sheet = 32;

  /// The work pane, its rail and a one-line composer (`--r-pane`).
  static const double pane = 28;

  /// Cards: terminal, web page, files, Clarify, approval, island events,
  /// voice (`--r-card`).
  static const double card = 22;

  /// Rows, list groups, the transfers pill, the viewer's data card
  /// (`--r-row`).
  static const double row = 16;

  /// Fields, rectangular buttons, small thumbnails.
  static const double control = 12;

  /// Inline code, small badges, swatches.
  static const double chip = 6;

  /// Pills, capsules, segments and round buttons (`--r-pill`).
  static const double tag = 999;

  /// Same as [row].
  static const double group = row;

  /// Same as [card].
  static const double floating = card;

  /// Same as [card].
  static const double dialog = card;
}

/// Six-step type scale. Colour is always explicit: pass it via [style].
abstract final class HermesType {
  /// The sizes of the scale, for a style that keeps its own weight and
  /// spacing (`TextStyle(fontSize: HermesType.supportSize, ...)`). Constant,
  /// so they also go inside a `const` style.
  static const double displaySize = 22;
  static const double titleSize = 17;
  static const double bodySize = 14.5;
  static const double textSize = 14;
  static const double supportSize = 12.5;
  static const double valueSize = 13;
  static const double captionSize = 11.5;
  static const double readingSize = 15;

  /// A short code the user reads out or types (a device sign-in code).
  static const double codeSize = 32;

  /// The content boxes (cards, groups, lists, fields), on their solid body:
  /// the label of a section (12, w600, a moderate tracking), the subtitle of
  /// a row or a notice (13) and the placeholder of a field (14). Nothing in
  /// a box is read smaller than these.
  static const double sectionSize = 12;
  static const double sectionTracking = 0.5;
  static const double subtitleSize = 13;
  static const double hintSize = 14;

  static const TextStyle display = TextStyle(
    fontSize: displaySize,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
  );
  static const TextStyle title = TextStyle(
    fontSize: titleSize,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
  );
  static const TextStyle body = TextStyle(
    fontSize: bodySize,
    fontWeight: FontWeight.w500,
  );
  static const TextStyle text = TextStyle(
    fontSize: textSize,
    fontWeight: FontWeight.w400,
    height: 1.45,
  );
  static const TextStyle support = TextStyle(
    fontSize: supportSize,
    fontWeight: FontWeight.w400,
  );

  /// Right-aligned row values (reference `_Line.value`).
  static const TextStyle value = TextStyle(
    fontSize: valueSize,
    fontWeight: FontWeight.w400,
  );
  static const TextStyle caption = TextStyle(
    fontSize: captionSize,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.6,
  );

  /// Reading text of the chat. the owner's default for 1.4.0: 15, line 1.5.
  static const TextStyle reading = TextStyle(
    fontSize: readingSize,
    fontWeight: FontWeight.w400,
    height: 1.5,
  );

  /// The bundled monospace family (`pubspec.yaml`), for code, hosts, paths,
  /// terminal keys and counts. Never the platform's `'monospace'`.
  static const String monoFamily = 'JetBrainsMono';

  /// [monoFamily] with nothing else: copy it with the size of the text it
  /// sits in.
  static const TextStyle mono = TextStyle(fontFamily: monoFamily);

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
  /// The body of a group: the solid one derived from the page
  /// ([HermesBoxFill]); only the Outline style stays a faint tint.
  static Color group(HermesThemeColors colors) => colors.outlined
      ? colors.surfaceVariant.withValues(alpha: .35)
      : HermesBoxFill.of(colors).group;

  /// The divider between two rows of a group: the least line that reaches
  /// [HermesLines.dividerRatio] on the group's body in this theme (a fixed
  /// 50 % of the palette's divider sat near 1.1:1 on most dark bodies).
  static Color divider(HermesThemeColors colors) =>
      HermesLines.of(colors).divider;
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
    required this.raised,
    required this.line,
    required this.ink,
    required this.mutedInk,
    required this.toneMutedInk,
    required this.shadow,
  });

  /// Whether the page behind is dark.
  final bool dark;

  /// Translucent fill of a floating piece.
  final Color fill;

  /// [fill] as it looks over the empty page. Modal surfaces use it, and so
  /// does every place where nothing may show through.
  final Color opaque;

  /// One step above [opaque]: a piece that sits ON a floating surface,
  /// such as the pills of the notch sheet (mock 133: pill #34343A on sheet
  /// #2A2A2F). On a dark page it is [opaque] lifted [raisedLift] towards
  /// white; on a light page, where the sheet is near white, it is the
  /// palette's `surfaceVariant` over the page.
  final Color raised;

  /// Hairline around a floating piece.
  final Color line;

  /// Primary ink on the chrome (the palette's `textPrimary`).
  final Color ink;

  /// Secondary ink on the chrome: `textSecondary`, lifted by the smallest
  /// step that reads at AA 4.5:1 on [opaque]. On the lifted fill the plain
  /// `textSecondary` of most dark palettes falls just under it.
  final Color mutedInk;

  /// [mutedInk] as it was derived from the palette's tone ink
  /// ([HermesThemeColors.toneInkSecondary]): what the glass tones certify.
  final Color toneMutedInk;

  /// Soft static shadow. Never animate it.
  final List<BoxShadow> shadow;

  /// How far a dark `surfaceVariant` is lifted towards white.
  static const double lift = 0.08;
  static const double darkOpacity = 0.86;
  static const double lightOpacity = 0.88;

  /// How far [raised] is lifted above [opaque] on a dark page.
  static const double raisedLift = 0.06;

  /// The least alpha of [line]: white on a dark page, the main ink on a
  /// light one. From here the line is raised, per theme, until the edge of
  /// a floating piece reaches [HermesLines.edgeRatio] against the page.
  static const double lineFloorDark = 0.15;
  static const double lineFloorLight = 0.11;

  /// How opaque [opaque] is laid over a frosted strip (the header's pills,
  /// the composer on the glass): the glass veil of `FrostedBackdrop`.
  static const double veilOpacity = 0.80;

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
    // On a tinted page every lift keeps the page's hue ([HermesPageTint]).
    final raised = ThemeContrast.composite(colors.surfaceVariant, page);
    final base = dark ? HermesPageTint.lift(raised, lift, page: page) : white;
    final fill = base.withValues(alpha: dark ? darkOpacity : lightOpacity);
    final opaque = ThemeContrast.composite(fill, page);
    final opaquePage = ThemeContrast.composite(page, black);
    // The hairline of a floating piece: raised from its floor until the
    // edge (the line over the piece's own fill) reads against the page at
    // the edge ratio, so a pill or a menu is cut out of any page.
    // ... whether the piece is opaque (a menu, a sheet) or wears the glass
    // veil ([veilOpacity], a header pill): the stronger of the two lines.
    Color lineOver(Color body) => HermesLineSearch.reach(
      ink: (alpha) => dark
          ? HermesPageTint.veil(page, alpha)
          : colors.textPrimary.withValues(alpha: alpha),
      body: body,
      against: [opaquePage],
      ratio: HermesLines.edgeRatio,
      floor: dark ? lineFloorDark : lineFloorLight,
    );
    final solid = lineOver(opaque);
    final veiled = lineOver(
      ThemeContrast.composite(
        opaque.withValues(alpha: veilOpacity),
        opaquePage,
      ),
    );
    final line = veiled.a > solid.a ? veiled : solid;
    return HermesChrome._(
      dark: dark,
      fill: fill,
      opaque: opaque,
      raised: dark
          ? HermesPageTint.lift(opaque, raisedLift, page: page)
          : ThemeContrast.composite(colors.surfaceVariant, page),
      line: line,
      ink: colors.textPrimary,
      mutedInk: ThemeContrast.adjustForContrast(colors.textSecondary, [
        opaque,
      ], minimum: 4.5),
      toneMutedInk: ThemeContrast.adjustForContrast(colors.toneInkSecondary, [
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

/// Which inks a piece draws over the gel's sheen ([HermesGel.inksOf]).
enum HermesGelInks { field, name, status, chip }

/// The recipe of the gel-glass ("cristal plastilina") of the buttons: the
/// translucent fill, the rims of light, the glossy sheen and the accent
/// gradient with its glow. One place for the numbers; the primitive that
/// paints them is `HermesGelSurface` (`gel_surface.dart`).
final class HermesGel {
  const HermesGel._({
    required this.dark,
    required this.glassFill,
    required this.hairline,
    required this.rimTop,
    required this.rimBottom,
  });

  /// Whether the page behind is dark.
  final bool dark;

  /// Fill of the glass when the piece has no frosted strip behind it:
  /// white at .075 on a dark page (the page's own light on a tinted page,
  /// [HermesPageTint.veil]), .62 on a light one.
  final Color glassFill;

  /// Hairline of 1 px around the piece: the page's light on a dark page
  /// (white, or the page's own tint), the main ink on a light one, each
  /// raised from [hairlineFloorDark] / [hairlineFloorLight] until the edge
  /// reaches [HermesLines.edgeRatio] against the page. (A white hairline
  /// at .95 on a light page was no hairline at all: 1.0:1 on white.)
  final Color hairline;

  /// The least alpha of [hairline] on a dark and on a light page.
  static const double hairlineFloorDark = 0.14;
  static const double hairlineFloorLight = 0.11;

  /// Inner light of the top edge.
  final Color rimTop;

  /// Inner shade of the bottom edge.
  final Color rimBottom;

  /// The sheen over the top-left of the piece: white at [sheenAlpha]
  /// fading to nothing at [sheenStop] of a 160 degree gradient.
  static const double sheenAlpha = 0.2;
  static const double sheenStop = 0.38;
  static const double sheenAngle = 160;

  /// How much a press compresses the gel.
  static const double pressScale = 0.96;

  /// How far, as a share of the piece, the sheen slides while pressed.
  static const double sheenSlide = 0.12;

  /// Time of the press: the gel compresses and the sheen slides.
  static const Duration pressDuration = Duration(milliseconds: 120);

  /// Width of the rims.
  static const double rimWidth = 1;

  /// The gel's inner light of the top edge and shade of the bottom one, as
  /// alphas of white and of black. The boxes (cards, groups, panels, rows,
  /// tabs, fields) wear the same two rims inside their contour, one pixel in
  /// (`HermesBoxEdge`); [rimBottomAlpha] is what a light box keeps.
  static const double rimTopAlpha = 0.24;
  static const double rimBottomAlpha = 0.07;

  /// Boxes on a dark page: the bottom rim is a little stronger than the
  /// gel's, because black at .07 is lost on a dark fill.
  static const double boxRimBottomDarkAlpha = 0.18;

  /// A dark box's contour is two-toned: the top edge carries this much more
  /// white than the bottom one (the light comes from above).
  static const double boxEdgeStep = 0.06;

  /// A light box's contour is two-toned too: the bottom edge carries this
  /// much more ink than the top one.
  static const double boxEdgeStepLight = 0.10;

  /// The short shadow of a box, drop and blur: the one of a group, a panel
  /// or a field, and the shorter one of a card or a row of a list (the blur
  /// of a long list is paid once per row). [boxShadowBlurMax] and
  /// [boxShadowDropMax] are the ranges no box leaves.
  static const double boxShadowBlur = 6;
  static const double boxShadowDrop = 2;
  static const double boxShadowCompactBlur = 4;
  static const double boxShadowCompactDrop = 1;
  static const double boxShadowBlurMax = 8;
  static const double boxShadowDropMax = 3;

  /// The shadow of a box on a dark page is black at this alpha; on a light
  /// one it is the glass's own warm one (`GlassMaterial.shadow`).
  static const double boxShadowDarkAlpha = 0.34;

  /// The accent button's glow: alpha, blur and drop.
  static const double glowAlpha = 0.45;
  static const double glowBlur = 14;
  static const double glowDrop = 4;

  /// The accent gradient's far end: turned this many degrees and lifted.
  static const double accent2Turn = 24;
  static const double accent2Lift = 0.08;

  /// The dock's active glow: accent at this alpha from the bottom edge.
  static const double dockGlowAlpha = 0.28;

  /// The ink of a dock item on its active glow is certified against this
  /// flat accent veil. The glow peaks at [dockGlowAlpha] on the bottom edge
  /// and fades within [dockGlowRadius] of the item, so under the icon it is
  /// never stronger than the veil.
  static double dockGlowCertified(bool dark) => dark ? 0.16 : 0.14;

  /// Reach of the glow, as a share of the item's shorter side: the whole
  /// height of the pill, so the light is a soft wash under the icon and not
  /// a small spot at the foot (which read as a smudge on the device).
  static const double dockGlowRadius = 1.0;

  /// The glow halfway up, under the centre of the icon: never above
  /// [dockGlowCertified] on either page.
  static const double dockGlowMidAlpha = 0.14;

  /// The active dock item's glow: [accent] radiating from the bottom edge
  /// and fading out, with no solid background.
  static BoxDecoration glow(Color accent, BorderRadius radius) => BoxDecoration(
    borderRadius: radius,
    gradient: RadialGradient(
      center: Alignment.bottomCenter,
      radius: dockGlowRadius,
      stops: const [0, 0.5, 1],
      colors: [
        accent.withValues(alpha: dockGlowAlpha),
        accent.withValues(alpha: dockGlowMidAlpha),
        accent.withValues(alpha: 0),
      ],
    ),
  );

  static final Expando<HermesGel> _derived = Expando<HermesGel>('HermesGel');

  static HermesGel of(HermesThemeColors colors) =>
      _derived[colors] ??= _derive(colors);

  static HermesGel ofContext(BuildContext context) =>
      of(Theme.of(context).hermes);

  static HermesGel _derive(HermesThemeColors colors) {
    const white = Color(0xFFFFFFFF);
    const black = Color(0xFF000000);
    final dark = HermesChrome.of(colors).dark;
    final page = colors.background;
    final opaquePage = ThemeContrast.composite(page, black);
    final glassFill = dark
        ? HermesPageTint.veil(page, 0.075)
        : white.withValues(alpha: 0.62);
    return HermesGel._(
      dark: dark,
      glassFill: glassFill,
      hairline: HermesLineSearch.reach(
        ink: (alpha) => dark
            ? HermesPageTint.veil(page, alpha)
            : colors.textPrimary.withValues(alpha: alpha),
        body: ThemeContrast.composite(glassFill, opaquePage),
        against: [opaquePage],
        ratio: HermesLines.edgeRatio,
        floor: dark ? hairlineFloorDark : hairlineFloorLight,
      ),
      rimTop: white.withValues(alpha: rimTopAlpha),
      rimBottom: black.withValues(alpha: rimBottomAlpha),
    );
  }

  /// The sheen's colour.
  Color get sheen => rimTop.withValues(alpha: sheenAlpha);

  /// The far end of the accent gradient: [accent] turned and lifted, then
  /// kept as readable under [ink] as [accent] itself was (never past AA).
  static Color accent2(Color accent, {Color? ink}) {
    final hsl = HSLColor.fromColor(accent);
    final turned = hsl
        .withHue((hsl.hue + accent2Turn) % 360)
        .withLightness((hsl.lightness + accent2Lift).clamp(0.0, 1.0))
        .toColor();
    if (ink == null) return turned;
    final minimum = math.min(4.5, ThemeContrast.ratio(ink, accent));
    return ThemeContrast.adjustForContrast(turned, [ink], minimum: minimum);
  }

  static final Expando<Map<HermesGelInks, double>> _textSheen =
      Expando<Map<HermesGelInks, double>>('HermesGel.textSheen');

  /// The inks a piece of [kind] draws over its sheen.
  static List<Color> inksOf(HermesThemeColors colors, HermesGelInks kind) {
    final chrome = HermesChrome.of(colors);
    return switch (kind) {
      // The composer: what is typed, the hint, the icons.
      HermesGelInks.field => [
        chrome.ink,
        colors.toneInkPrimary,
        colors.toneInkSecondary,
      ],
      // The name pill: the name, the state and the mark.
      HermesGelInks.name => [
        chrome.ink,
        chrome.toneMutedInk,
        colors.accentText,
        colors.toneInkPrimary,
        colors.toneInkSecondary,
      ],
      // The status pill: the figures, the model, the shield and their
      // warning colours.
      HermesGelInks.status => [
        colors.toneInkPrimary,
        colors.toneInkSecondary,
        colors.accentText,
        colors.warning,
        colors.error,
      ],
      // The pinned prompt: «Tú:», the prompt and the close.
      HermesGelInks.chip => [
        chrome.toneMutedInk,
        colors.toneInkPrimary,
        colors.toneInkSecondary,
      ],
    };
  }

  /// The share (0 to 1) of the sheen a piece may paint over TEXT: the
  /// largest one for which every ink of the piece ([inksOf]) keeps the
  /// contrast it has on the chrome's opaque grey (AA where it had AA),
  /// certified at the sheen's peak, which is stronger than anywhere the text
  /// sits.
  ///
  /// A light theme's sheen only lightens the ground of dark ink: it keeps
  /// all of it. A dark one gives up as much as its inks need.
  static double textSheenScale(
    HermesThemeColors colors, [
    HermesGelInks kind = HermesGelInks.field,
  ]) {
    final cache = _textSheen[colors] ??= <HermesGelInks, double>{};
    return cache[kind] ??= _deriveTextSheen(colors, kind);
  }

  static double _deriveTextSheen(HermesThemeColors colors, HermesGelInks kind) {
    final chrome = HermesChrome.of(colors);
    final peak = of(colors).sheen;
    final inks = inksOf(colors, kind);
    bool reads(double scale) {
      final lit = ThemeContrast.composite(
        peak.withValues(alpha: peak.a * scale),
        chrome.opaque,
      );
      for (final ink in inks) {
        final base = ThemeContrast.ratio(ink, chrome.opaque);
        final need = math.min(4.5, base);
        if (ThemeContrast.ratio(ink, lit) < need) return false;
      }
      return true;
    }

    if (reads(1)) return 1;
    var low = 0.0;
    var high = 1.0;
    for (var i = 0; i < 14; i++) {
      final middle = (low + high) / 2;
      if (reads(middle)) {
        low = middle;
      } else {
        high = middle;
      }
    }
    return low;
  }

  /// CSS-style gradient line of [angle] degrees across [size].
  static (Offset, Offset) line(Size size, double angle) {
    final radians = angle * math.pi / 180;
    final dx = math.sin(radians);
    final dy = -math.cos(radians);
    final length = size.width * dx.abs() + size.height * dy.abs();
    final center = size.center(Offset.zero);
    final half = Offset(dx, dy) * (length / 2);
    return (center - half, center + half);
  }
}
