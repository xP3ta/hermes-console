// OPUS-CRISTAL: the readable glass of the chat's foot (composer and the
// context pill), our own design. Prepared, not wired: no consumer uses it.
//
// Why a plain veil cannot do it: one veil must protect every ink over any
// page, black and white included. On classic-dark the composer's hint sits
// at 4.56:1 on the opaque chrome; over white behind, any veil under 1.0
// drops it below 4.5 (lanes/REPORT-OPUS-CRISTAL.md). So the composer stayed
// opaque, and an edge finish on an opaque body reads as no glass at all.
//
// What this does instead, in the strip's ONE backdrop layer and without a
// shader: blur, then a colour matrix that pivots the page's luminance on
// black (dark themes) or white (light themes) and compresses it, keeping
// part of its colour, then the chrome's veil. What scrolls behind shows as
// moving, coloured, smoked shapes; the luminance under the inks stays in a
// band where each ink reads at least as well as it does on the opaque
// chrome today, or at AA. [readsFor] checks that per palette and the
// consumer keeps the opaque chrome where it does not hold.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Colors;
import 'package:flutter/painting.dart';

import '../theme/app_theme.dart';
import '../theme/theme_contrast.dart';
import 'tokens.dart';

@immutable
class HermesSmokedGlass {
  const HermesSmokedGlass({
    required this.pivot,
    required this.luminance,
    required this.chroma,
    required this.veil,
  }) : assert(pivot == 0 || pivot == 1),
       assert(luminance >= 0 && luminance <= 1),
       assert(chroma >= 0 && chroma <= 1),
       assert(veil >= 0 && veil <= 1);

  /// 0: the page's luminance is pulled towards black; 1: towards white.
  final double pivot;

  /// How much of the page's luminance, around [pivot], reaches the veil.
  final double luminance;

  /// How much of the page's colour (away from its grey) is kept.
  final double chroma;

  /// The chrome's opaque colour laid over the toned page, at this opacity.
  final double veil;

  /// Desk-checked on classic-dark: every composer and pill ink at or above
  /// its ratio on the opaque chrome (gates/navegador-opus-cristal-20261030).
  static const dark = HermesSmokedGlass(
    pivot: 0,
    luminance: 0.20,
    chroma: 0.50,
    veil: 0.30,
  );

  /// Desk-checked on classic-light: every ink at AA 4.5 or better.
  static const light = HermesSmokedGlass(
    pivot: 1,
    luminance: 0.15,
    chroma: 0.35,
    veil: 0.60,
  );

  /// The chat foot's dark tone. It keeps [dark]'s chroma and lets 0.16 of the
  /// page's luminance through, under a veil of 0.40 of the chrome's grey
  /// (it was 0.15 under 0.30, which toned the page to ~#161618: a black
  /// slab). Swept over all 20 dark presets with the same AA
  /// certification as before ([readsFor]) and the real-transcript captures:
  /// 0.16 / 0.5 / 0.40 passes 20/20 with the page-coloured body at ~#1C
  /// instead of ~#16 and still lets the image through the slim pill (0.45
  /// fails it, 10-11 < 12). Lighter is not reachable by tuning: the muted
  /// ink sits at 4.5 on [HermesChrome.opaque], so nothing under it may be
  /// lighter than that grey, and over a white page the body is lighter than
  /// the page-coloured typical case by the share the image needs. Chroma
  /// 0.55 passes 7/20, luminance 0.17 17/20, a grey pivot 12/20 or fewer.
  /// The veil and the fallback stay [HermesChrome.opaque] (the theme's medium
  /// grey): [HermesChrome.raised] is lighter and would drop the muted ink to
  /// ~3.7. The strip's blur stays at its default. The dock keeps [dark]
  /// ([dockOf]); the drawer keeps [panelDark].
  static const chatDark = HermesSmokedGlass(
    pivot: 0,
    luminance: 0.16,
    chroma: 0.50,
    veil: 0.40,
  );

  /// The chat foot's light tone. [light] keeps every foot ink at AA as it is
  /// and so lets almost nothing through the slim context pill (real A/B
  /// f241a8c7: 6 < 12 with an image behind). Here the pill's status inks
  /// (accent, accentText, warning, error) are adjusted instead, just enough
  /// and keeping their hue ([adaptedInks]), as the dock's selected icon:
  /// AA never lowered. Desk simulation calibrated on real device frames:
  /// pill ROI ≈18 (≈16 real), composer ≈43, ghost ≤1.036 pill / ≤1.045
  /// composer; on classic, warning darkens 9 %, error 8 %, accentText 2 %,
  /// hue shift ≤0.4°; primary and secondary inks unchanged.
  static const chatLight = HermesSmokedGlass(
    pivot: 1,
    luminance: 0.25,
    chroma: 0.70,
    veil: 0.50,
  );

  /// The chat foot's tone for [chrome]: [chatDark] on a dark page,
  /// [chatLight] on a light one.
  static HermesSmokedGlass of(HermesChrome chrome) =>
      chrome.dark ? chatDark : chatLight;

  /// [ink] as a piece paints it on this glass: itself if it already reads
  /// (AA, or its ratio on the opaque chrome when that is lower, over the
  /// whole range under the glass, inside included), else moved just enough
  /// towards black on a light glass (white on a dark one), which keeps its
  /// hue. Null when no step reaches it: then the piece stays opaque.
  Color? inkOnGlass(Color ink, HermesChrome chrome) {
    final now = ThemeContrast.ratio(ink, chrome.opaque);
    final floor = now < target ? now : target;
    if (worstRatio(ink, chrome) >= floor) return ink;
    final towards = pivot == 1 ? Colors.black : Colors.white;
    for (var step = 1; step <= 100; step++) {
      final moved = Color.lerp(ink, towards, step / 100)!;
      if (worstRatio(moved, chrome) >= floor) return moved;
    }
    return null;
  }

  /// [colors] with the context pill's status inks as painted on this glass
  /// ([inkOnGlass]); an ink no step reaches is left as it is, so the strip's
  /// check ([readsFor]) keeps the opaque chrome.
  HermesThemeColors adaptedInks(HermesThemeColors colors) {
    final chrome = HermesChrome.of(colors);
    Color on(Color ink) => inkOnGlass(ink, chrome) ?? ink;
    return colors.copyWith(
      accent: on(colors.accent),
      accentText: on(colors.accentText),
      warning: on(colors.warning),
      error: on(colors.error),
    );
  }

  /// Every ink the composer and the context pill paint as text, the
  /// permissions segment (ChatScreen._modeColor) included. A toned
  /// strip checks these; a caller that paints another ink adds it.
  static List<Color> footInks(HermesThemeColors colors) {
    // The status inks as the pill paints them on the foot's tone.
    final pill = of(HermesChrome.of(colors)).adaptedInks(colors);
    return [
      colors.toneInkPrimary,
      colors.toneInkSecondary,
      HermesChrome.of(colors).toneMutedInk,
      pill.accent,
      pill.accentText,
      pill.warning,
      pill.error,
    ];
  }

  /// The glass of a panel that carries a lot of text (the side drawer):
  /// [chatDark]'s tone and chroma under a heavier veil. A heavier veil only
  /// narrows what can sit under the inks, so whatever reads on the foot
  /// reads here with more margin; where an ink still does not
  /// ([readsFor], [readsOver]) the panel keeps its opaque chrome.
  static const panelDark = HermesSmokedGlass(
    pivot: 0,
    luminance: 0.15,
    chroma: 0.50,
    veil: 0.62,
  );

  /// [light]'s tone under a heavier veil, for the same panels.
  ///
  /// Swept over the 20 light presets (every panel ink, the selected
  /// row's included): only the accent falls short. At veil 0.72 on 6 presets,
  /// at 0.80 on 5 (amber, midnight, ember, mono, slate), at 0.88 on 3 (ember,
  /// mono, slate). 0.80 keeps 15/20 on glass with a page that still shows
  /// through; those 5 light themes keep the opaque surface.
  static const panelLight = HermesSmokedGlass(
    pivot: 1,
    luminance: 0.15,
    chroma: 0.35,
    veil: 0.80,
  );

  /// The tone of a text-heavy panel for [chrome].
  static HermesSmokedGlass panelOf(HermesChrome chrome) =>
      chrome.dark ? panelDark : panelLight;

  /// Every ink a text-heavy panel (the drawer) paints as text or as an
  /// icon that must read. The selected row's inks sit on a tint: check
  /// them with [readsOver]. `textDisabled` is left out: a disabled label is
  /// exempt from the contrast minimum (WCAG 1.4.3), and it can never match
  /// its ratio on the opaque chrome, which is what [readsFor] asks.
  static List<Color> panelInks(HermesThemeColors colors) => [
    colors.toneInkPrimary,
    colors.toneInkSecondary,
    colors.toneInkTertiary,
    HermesChrome.of(colors).toneMutedInk,
    colors.accent,
    colors.warning,
  ];

  /// Whether [ink], painted on [tint] (a selected row), reads on this glass
  /// at least as well as it does on the same tint over the opaque chrome,
  /// or at [target] when that is already higher.
  bool readsOver(Color ink, Color tint, HermesChrome chrome) {
    final now = ThemeContrast.ratio(
      ink,
      ThemeContrast.composite(tint, chrome.opaque),
    );
    final floor = now < target ? now : target;
    return worstRatio(ink, chrome, over: tint) >= floor;
  }

  /// The dock's light glass. The chat's light tone holds warning and
  /// accent text at AA and so lets little colour through; the dock bar
  /// paints only primary icons and its selection (checked with `over`), so
  /// it can show more of the page: on console-light, with the user's
  /// default transparency floor (0.592), a red page reads +47.9 redness
  /// against the opaque dock, over the +30 of q9_dock_glass_test, and the
  /// bar's inks read on all 20 light palettes (desk check,
  /// gates/navegador-opus-cristal-20261030/dock-bar-light.json). Dark docks
  /// keep the chat's [dark] tone (+37.6 on classic-dark).
  static const dockLight = HermesSmokedGlass(
    pivot: 1,
    luminance: 0.5,
    chroma: 1.0,
    veil: 0.60,
  );

  /// The dock's tone for [chrome]: [dark] on a dark page, [dockLight] on a
  /// light one. Apply the user's transparency with [withVeilFloor].
  static HermesSmokedGlass dockOf(HermesChrome chrome) =>
      chrome.dark ? dark : dockLight;

  /// The inks of the dock bar (GestureDock): its icons. The selected item's
  /// ink is checked on its own with [worstRatio] and `over`.
  static List<Color> barInks(HermesThemeColors colors) => [
    colors.toneInkPrimary,
  ];

  /// Every ink the dock paints as text or as an icon that must read: the
  /// bar's and the rail's (DockItemTile). The selected item's ink sits on
  /// the selection tint: check it with [worstRatio] and `over`.
  static List<Color> dockInks(HermesThemeColors colors) => [
    colors.toneInkPrimary,
    colors.toneInkSecondary,
    HermesChrome.of(colors).toneMutedInk,
    colors.accentText,
  ];

  /// The user's explicit fill (Ajustes › Dock › Transparencia) is a floor:
  /// the tone never makes a surface more transparent than they chose. The
  /// same rule as `HermesLiquid.withVeilFloor`.
  HermesSmokedGlass withVeilFloor(double floor) => floor <= veil
      ? this
      : HermesSmokedGlass(
          pivot: pivot,
          luminance: luminance,
          chroma: chroma,
          veil: floor.clamp(0.0, 1.0),
        );

  /// The contrast the inks keep (WCAG AA), unless the opaque chrome of
  /// before already gives them less: then they keep at least that.
  static const double target = 4.5;

  /// Rec. 709 luma weights, the ones the matrix pivots on.
  static const double _wr = 0.2126;
  static const double _wg = 0.7152;
  static const double _wb = 0.0722;

  /// out = s·c + (k − s)·y + (1 − k)·pivot, with y the pixel's luma.
  /// Offsets are in 0..255, as [ui.ColorFilter.matrix] takes them.
  List<double> get matrix {
    final k = luminance;
    final s = chroma;
    final d = k - s;
    final offset = (1 - k) * pivot * 255;
    return <double>[
      s + d * _wr, d * _wg, d * _wb, 0, offset, //
      d * _wr, s + d * _wg, d * _wb, 0, offset, //
      d * _wr, d * _wg, s + d * _wb, 0, offset, //
      0, 0, 0, 1, 0, //
    ];
  }

  /// The tone applied after the blur, in the same layer.
  ui.ColorFilter get tone => ui.ColorFilter.matrix(matrix);

  /// Blur then tone: one [ui.ImageFilter] for one BackdropFilterLayer.
  ui.ImageFilter filter(double sigma) => ui.ImageFilter.compose(
    outer: tone,
    inner: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
  );

  /// The fill a piece paints over the toned backdrop.
  Color veilOf(HermesChrome chrome) => chrome.opaque.withValues(alpha: veil);

  /// The luminance range a piece's content can sit on: the veil over the
  /// toned page for every colour a blur can average to (any point of the
  /// sRGB cube), and the opaque chrome of the fallback. [over]: a
  /// translucent layer the piece paints on its fill (the dock's
  /// selection), composited on every one of them.
  ///
  /// Certified, not sampled (Navegador, 31 Oct): a colour between grid
  /// samples can sit darker than every sample (light chatLight: 0.7182
  /// sampled, 0.6993 certified). The ends come from a coarse grid refined
  /// around its 8 lowest and 8 highest points, widened by a Lipschitz bound
  /// of the output luminance (per-channel slope of the sRGB curve at the
  /// channel's largest reachable value, the matrix and the veil) and by
  /// the pipeline's rounding: a sample is rounded once (half a step); the
  /// real page passes the filter's output and the veil, each rounded (up to
  /// a step between them: 1.5 steps in all), and [over], when given, is one
  /// more rounded layer: 1 + (1 − its alpha)·(1 − veil/2) steps (Git), at
  /// most 2, taken as 2. No colour of the cube falls outside.
  (double, double) underRange(HermesChrome chrome, {Color? over}) {
    final survey = _survey(chrome, over);
    return (survey.lo, survey.hi);
  }

  /// Colours at, or next to, both ends of [underRange]: what an ink is
  /// adjusted against. Check the result with [worstRatio], which uses the
  /// certified range and counts the inside.
  (Color, Color) underExtremes(HermesChrome chrome, {Color? over}) {
    final survey = _survey(chrome, over);
    return (survey.dark, survey.light);
  }

  static final Map<(Color, HermesSmokedGlass, Color?), _Survey> _surveys = {};

  static double _slope(double u) => u <= 0.04045
      ? 1 / 12.92
      : 2.4 / 1.055 * math.pow((u + 0.055) / 1.055, 1.4).toDouble();

  _Survey _survey(HermesChrome chrome, Color? over) {
    final key = (chrome.opaque, this, over);
    final cached = _surveys[key];
    if (cached != null) return cached;
    const weights = [_wr, _wg, _wb];
    final d = luminance - chroma;
    final m = [
      for (var i = 0; i < 3; i++)
        [for (var j = 0; j < 3; j++) (i == j ? chroma : 0.0) + d * weights[j]],
    ];
    final offset = (1 - luminance) * pivot;
    final op = chrome.opaque;
    final opc = [op.r, op.g, op.b];
    final oa = over?.a ?? 0.0;
    final oc = over == null ? const [0.0, 0.0, 0.0] : [over.r, over.g, over.b];
    double laid(int i, double u) => oa * oc[i] + (1 - oa) * u;
    Color at(double x0, double x1, double x2) {
      final x = [x0, x1, x2];
      final ch = [
        for (var i = 0; i < 3; i++)
          laid(
            i,
            veil * opc[i] +
                (1 - veil) *
                    (offset + m[i][0] * x[0] + m[i][1] * x[1] + m[i][2] * x[2])
                        .clamp(0.0, 1.0),
          ),
      ];
      return Color.from(alpha: 1, red: ch[0], green: ch[1], blue: ch[2]);
    }

    // How fast the output luminance can change with the input colour.
    var lipschitz = 0.0;
    var rounding = 0.0;
    // 8-bit steps of rounding between a sample and the real page.
    final rounded = over == null ? 1.5 : 2.0;
    for (var i = 0; i < 3; i++) {
      var top = offset;
      var total = 0.0;
      for (var j = 0; j < 3; j++) {
        if (m[i][j] > 0) top += m[i][j];
        total += m[i][j].abs();
      }
      final reach = laid(i, veil * opc[i] + (1 - veil) * top.clamp(0.0, 1.0));
      final slope = _slope((reach + rounded / 255).clamp(0.0, 1.0));
      lipschitz += weights[i] * slope * (1 - veil) * (1 - oa) * total;
      rounding += weights[i] * slope * rounded / 255;
    }
    const steps = 16;
    const coarse = 0.5 / steps;
    const fine = coarse / 8;
    final grid = <(double, double, double, double)>[];
    for (var ri = 0; ri <= steps; ri++) {
      for (var gi = 0; gi <= steps; gi++) {
        for (var bi = 0; bi <= steps; bi++) {
          final r = ri / steps, g = gi / steps, b = bi / steps;
          grid.add((ThemeContrast.luminance(at(r, g, b)), r, g, b));
        }
      }
    }
    grid.sort((a, b) => a.$1.compareTo(b.$1));
    // Around a point, every colour within the coarse cell, at a fine step.
    (double, Color, double, Color) around((double, double, double, double) p) {
      var lo = double.infinity, hi = double.negativeInfinity;
      var dark = op, light = op;
      for (var a = 0; a <= 8; a++) {
        for (var b = 0; b <= 8; b++) {
          for (var c = 0; c <= 8; c++) {
            double near(double v, int k) =>
                (v - coarse + k * coarse / 4).clamp(0.0, 1.0);
            final colour = at(near(p.$2, a), near(p.$3, b), near(p.$4, c));
            final l = ThemeContrast.luminance(colour);
            if (l < lo) (lo, dark) = (l, colour);
            if (l > hi) (hi, light) = (l, colour);
          }
        }
      }
      return (lo, dark, hi, light);
    }

    var lowest = double.infinity, highest = double.negativeInfinity;
    var dark = op, light = op;
    for (final p in grid.take(8)) {
      final (lo, colour, _, _) = around(p);
      if (lo < lowest) (lowest, dark) = (lo, colour);
    }
    for (final p in grid.skip(grid.length - 8)) {
      final (_, _, hi, colour) = around(p);
      if (hi > highest) (highest, light) = (hi, colour);
    }
    final fallback = ThemeContrast.luminance(
      Color.from(
        alpha: 1,
        red: laid(0, opc[0]),
        green: laid(1, opc[1]),
        blue: laid(2, opc[2]),
      ),
    );
    final lo = [
      lowest - lipschitz * fine - rounding,
      grid[8].$1 - lipschitz * coarse - rounding,
      fallback,
    ].reduce(math.min);
    final hi = [
      highest + lipschitz * fine + rounding,
      grid[grid.length - 9].$1 + lipschitz * coarse + rounding,
      fallback,
    ].reduce(math.max);
    return _surveys[key] = _Survey(
      dark: dark,
      light: light,
      lo: lo.clamp(0.0, 1.0),
      hi: hi.clamp(0.0, 1.0),
    );
  }

  /// The worst ratio [ink] gets anywhere on this glass ([over] as in
  /// [underRange]). A blur only averages, so every luminance between the
  /// range's ends can sit under the ink: one inside the range meets its
  /// own luminance, 1:1 (Git R1, OPUS-WIRING-CONTRAST-RANGE-1). Outside
  /// it, the nearer end decides.
  double worstRatio(Color ink, HermesChrome chrome, {Color? over}) {
    final (lo, hi) = underRange(chrome, over: over);
    final l = ThemeContrast.luminance(ink);
    if (l >= lo && l <= hi) return 1;
    final near = l < lo ? lo : hi;
    final light = l > near ? l : near;
    final dark = l > near ? near : l;
    return (light + 0.05) / (dark + 0.05);
  }

  /// Whether every ink in [inks] reads on this glass at least as well as
  /// [target], or as well as on the opaque chrome when that is already
  /// lower. False: the consumer paints the opaque chrome of before.
  bool readsFor(HermesThemeColors colors, Iterable<Color> inks) {
    final chrome = HermesChrome.of(colors);
    for (final ink in inks) {
      final now = ThemeContrast.ratio(ink, chrome.opaque);
      final floor = now < target ? now : target;
      if (worstRatio(ink, chrome) < floor) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is HermesSmokedGlass &&
      other.pivot == pivot &&
      other.luminance == luminance &&
      other.chroma == chroma &&
      other.veil == veil;

  @override
  int get hashCode => Object.hash(pivot, luminance, chroma, veil);
}

/// What can sit under a piece of a [HermesSmokedGlass].
class _Survey {
  const _Survey({
    required this.dark,
    required this.light,
    required this.lo,
    required this.hi,
  });

  final Color dark;
  final Color light;
  final double lo;
  final double hi;
}
