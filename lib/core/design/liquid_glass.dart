// QA9715: the shared «liquid»
// touch of a header strip's glass (HermesGlassStrip), our own design.
// shaders/liquid_glass.frag runs on the strip's ONE backdrop layer, after
// its blur: the page bends at the pieces' rims (refraction); the veil is
// the thinnest with which the pieces' ink, and their weakest ink (a title
// badge's, over its tint), read at AA over the page right behind (adaptive
// veil: low where the page allows it, up to the chrome of before where it
// does not); a thin highlight runs along the rims facing the light; and
// pieces that come close join (fusion).
//
// Impeller only (ImageFilter.shader). Without it, or where the device
// policy, reduced motion or high contrast say no blur, the strip is the
// glass, or the chrome, of before.
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Colors;
import 'package:flutter/painting.dart';

import '../theme/app_theme.dart';
import '../theme/theme_contrast.dart';
import 'glass_strip.dart';
import 'tokens.dart';

/// How liquid a strip is: one of [variants].
@immutable
class HermesLiquid {
  const HermesLiquid({
    required this.refraction,
    required this.rimWidth,
    required this.rim,
    required this.fusion,
    required this.veilLeast,
    this.badgeOpacity = badgeTint,
  });

  /// How far the rim bends the page behind (dp).
  final double refraction;

  /// Width of the highlight along the rim (dp).
  final double rimWidth;

  /// Strength of the highlight (0..1).
  final double rim;

  /// Pieces closer than this join (dp; 0: never).
  final double fusion;

  /// The thinnest the veil gets, over a page that lets the inks read: the
  /// «low veil». Where the page does not, it thickens up to opaque.
  final double veilLeast;

  /// Background tint under the weakest ink. Icon bands have no title badge.
  final double badgeOpacity;

  static const soft = HermesLiquid(
    refraction: 6,
    rimWidth: 1.5,
    rim: 0.22,
    fusion: 0,
    veilLeast: 0.72,
  );

  static const medium = HermesLiquid(
    refraction: 10,
    rimWidth: 2,
    rim: 0.38,
    fusion: 10,
    veilLeast: 0.60,
  );

  static const strong = HermesLiquid(
    refraction: 16,
    rimWidth: 2.5,
    rim: 0.55,
    fusion: 18,
    veilLeast: 0.48,
  );

  static const List<HermesLiquid> variants = [soft, medium, strong];

  // Consumers name a role; they never invent shader/blur recipes.
  static const header = medium;
  static const dock = HermesLiquid(
    refraction: 10,
    rimWidth: 2,
    rim: 0.38,
    fusion: 10,
    veilLeast: 0.60,
    badgeOpacity: 0,
  );
  static const pill = soft;
  static const overlay = HermesLiquid(
    refraction: 0,
    rimWidth: 1.5,
    rim: 0.22,
    fusion: 0,
    veilLeast: 0.80,
  );
  static const notice = overlay;

  /// An overlay larger than this has opaque backing and a painted rim.
  /// The limit applies to the real laid-out frame, including text scaling.
  static const double overlayFilterArea = 120000;

  /// An explicit fill (for example the user's dock opacity) is a floor,
  /// never permission for the shader to make it more transparent.
  HermesLiquid withVeilFloor(double opacity) => opacity <= veilLeast
      ? this
      : HermesLiquid(
          refraction: refraction,
          rimWidth: rimWidth,
          rim: rim,
          fusion: fusion,
          veilLeast: opacity.clamp(0.0, 1.0),
          badgeOpacity: badgeOpacity,
        );

  /// More pieces make the WHOLE strip fall back to glass, with its veil.
  static const int maxPieces = 5;

  /// Towards the light: up and to the left (y down).
  static const Offset light = Offset(-0.6, -0.8);

  /// The contrast the inks keep over the veil (WCAG AA).
  static const double target = 4.5;

  /// The steps the veil is searched in, from [veilLeast] to opaque.
  static const int steps = 12;

  /// The tint a title badge lays under its word (HermesTitleBadge).
  static const double badgeTint = 0.08;

  /// Edge-only highlight. It does not wash out text or fill list rows.
  /// Used by glass bands and the filter-free collection decoration.
  void paintRim(Canvas canvas, Path outline, Rect bounds) {
    if (bounds.isEmpty) return;
    canvas.save();
    canvas.clipPath(outline);
    canvas.drawPath(
      outline,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = rimWidth * 2
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: rim),
            Colors.white.withValues(alpha: rim * 0.15),
          ],
        ).createShader(bounds),
    );
    canvas.restore();
  }

  /// The weakest ink a piece shows: a title badge's, the chrome's muted
  /// ink moved just as far as AA needs over its tint on the glass and on
  /// the chrome of before (HermesTitleBadge.inkFor; a test keeps them the
  /// same). Worked out once per theme.
  static Color weakestInk(HermesThemeColors colors) =>
      _weakest[colors] ??= _resolveWeakest(colors);

  static final Expando<Color> _weakest = Expando<Color>('HermesLiquid');

  static Color _resolveWeakest(HermesThemeColors colors) {
    final chrome = HermesChrome.of(colors);
    final tint = chrome.ink.withValues(alpha: badgeTint);
    Color on(Color under) => ThemeContrast.composite(tint, under);
    final under = [
      on(chrome.opaque),
      on(HermesGlassStrip.worstUnder(colors)),
      on(HermesGlassStrip.ownUnder(colors)),
    ];
    return ThemeContrast.adjustForContrast(
      chrome.mutedInk,
      under,
      minimum: target,
    );
  }

  static Color _mix(Color from, Color to, double amount) =>
      Color.lerp(from.withValues(alpha: 1), to.withValues(alpha: 1), amount)!;

  /// Without the adaptive shader a single veil must protect both extreme
  /// backdrops. Keep the caller's opacity as a floor, then increase only
  /// as far as primary and badge ink need. No filter or shader is created.
  Color fallbackVeil(
    Color tint, {
    required Color ink,
    required Color weakInk,
    Color? backdropTint,
  }) {
    final from = withVeilFloor(tint.a);
    Color behind(Color extreme) => backdropTint == null
        ? extreme
        : ThemeContrast.composite(backdropTint, extreme);
    for (var i = 0; i <= steps; i++) {
      final alpha = from.veilLeast + (1 - from.veilLeast) * i / steps;
      final candidate = tint.withValues(alpha: alpha);
      var readable = true;
      for (final extreme in const [Colors.white, Colors.black]) {
        final under = ThemeContrast.composite(candidate, behind(extreme));
        final tinted = ThemeContrast.composite(
          ink.withValues(alpha: badgeOpacity),
          under,
        );
        readable =
            readable &&
            ThemeContrast.ratio(ink, under) >= target &&
            ThemeContrast.ratio(weakInk, tinted) >= target;
      }
      if (readable) return candidate;
    }
    return tint.withValues(alpha: 1);
  }

  /// The veil's opacity over a page of colour [behind]: the shader's rule.
  double veilOver(
    Color behind, {
    required Color veil,
    required Color ink,
    required Color weakInk,
  }) {
    for (var i = 0; i <= steps; i++) {
      final amount = veilLeast + (1 - veilLeast) * i / steps;
      final under = _mix(behind, veil, amount);
      final tinted = _mix(under, ink, badgeOpacity);
      if (ThemeContrast.ratio(ink, under) >= target &&
          ThemeContrast.ratio(weakInk, tinted) >= target) {
        return amount;
      }
    }
    return 1;
  }

  /// What a piece's content sits on over a page of colour [behind] (the
  /// shader's colour, without the rim's highlight).
  Color under(
    Color behind, {
    required Color veil,
    required Color ink,
    required Color weakInk,
  }) {
    final amount = veilOver(behind, veil: veil, ink: ink, weakInk: weakInk);
    return _mix(behind, veil, amount);
  }

  /// The shader's uniforms after the engine's two (the texture's size), for
  /// pieces at [rects] in physical pixels.
  List<double> uniforms(
    List<RRect> shapes, {
    required double devicePixelRatio,
    required Color veil,
    required Color ink,
    required Color weakInk,
  }) {
    assert(shapes.length <= maxPieces);
    final shown = shapes.take(maxPieces).toList();
    return [
      for (var k = 0; k < maxPieces; k++) ...[
        k < shown.length ? shown[k].left : 0,
        k < shown.length ? shown[k].top : 0,
        k < shown.length ? shown[k].width : 0,
        k < shown.length ? shown[k].height : 0,
      ],
      for (var k = 0; k < maxPieces; k++)
        k < shown.length ? shown[k].tlRadiusX : 0,
      shown.length.toDouble(),
      refraction * devicePixelRatio,
      rimWidth * devicePixelRatio,
      rim,
      fusion * devicePixelRatio,
      veil.r,
      veil.g,
      veil.b,
      veilLeast,
      ink.r,
      ink.g,
      ink.b,
      weakInk.r,
      weakInk.g,
      weakInk.b,
      badgeOpacity,
      target,
      light.dx,
      light.dy,
    ];
  }

  /// Writes [uniforms] into [shader].
  void configure(
    ui.FragmentShader shader,
    List<RRect> shapes, {
    required double devicePixelRatio,
    required Color veil,
    required Color ink,
    required Color weakInk,
  }) {
    final values = uniforms(
      shapes,
      devicePixelRatio: devicePixelRatio,
      veil: veil,
      ink: ink,
      weakInk: weakInk,
    );
    for (var i = 0; i < values.length; i++) {
      shader.setFloat(i + 2, values[i]);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is HermesLiquid &&
      other.refraction == refraction &&
      other.rimWidth == rimWidth &&
      other.rim == rim &&
      other.fusion == fusion &&
      other.veilLeast == veilLeast &&
      other.badgeOpacity == badgeOpacity;

  @override
  int get hashCode =>
      Object.hash(refraction, rimWidth, rim, fusion, veilLeast, badgeOpacity);
}

/// The liquid shader, loaded once.
abstract final class HermesLiquidShader {
  static const String asset = 'shaders/liquid_glass.frag';

  static ui.FragmentProgram? _program;
  static Future<ui.FragmentProgram?>? _loading;

  @visibleForTesting
  static int loadAttempts = 0;

  /// Whether the engine can run a shader on a backdrop (Impeller).
  static bool get supported => ui.ImageFilter.isShaderFilterSupported;

  /// The program once [load] has finished; null before, or when it cannot
  /// run here.
  static ui.FragmentProgram? get program => _program;

  /// Loads the program once; null where it cannot run.
  static Future<ui.FragmentProgram?> load() {
    if (!supported) return Future.value(null);
    return _loading ??= _load();
  }

  static Future<ui.FragmentProgram?> _load() async {
    loadAttempts++;
    try {
      return _program = await ui.FragmentProgram.fromAsset(asset);
    } catch (error) {
      debugPrint('[glass] liquid unavailable: $error');
      return null;
    }
  }
}
