/// Soft design tokens (Inicio v4 widgets first; the rest of the app can
/// adopt them): continuous «squircle» corners, capsule bars, a
/// critically-damped spring, and a calm palette DERIVED from the active
/// theme: a neutral widget surface and low-chroma pastel tints whose hue
/// comes from the theme's own accent, so Dracula reads lavender, Gruvbox
/// warm sand and Amber peach, never neon. Every ink is computed for
/// contrast against the surface it sits on (text 4.5:1, icons 3:1).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'theme_contrast.dart';

abstract final class SoftRadii {
  /// Widget cards.
  static const double card = 24;

  /// Bottom sheets (top corners).
  static const double sheet = 28;

  /// Inner blocks (icon chips, preview frames, list groups).
  static const double inner = 14;

  /// Icon chip.
  static const double chip = 10;
}

abstract final class SoftShapes {
  /// Continuous-corner card.
  static OutlinedBorder card({
    double radius = SoftRadii.card,
    BorderSide? side,
  }) => RoundedSuperellipseBorder(
    borderRadius: BorderRadius.circular(radius),
    side: side ?? BorderSide.none,
  );

  static OutlinedBorder sheet() => const RoundedSuperellipseBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(SoftRadii.sheet)),
  );

  /// Buttons and bars: fully rounded ends.
  static OutlinedBorder capsule({BorderSide? side}) =>
      StadiumBorder(side: side ?? BorderSide.none);
}

/// Critically damped spring as a [Curve]: x(t) = 1 − (1 + ωt)·e^(−ωt),
/// normalised to end exactly at 1. No overshoot at all.
class SoftSpringCurve extends Curve {
  const SoftSpringCurve({this.omega = 8});

  final double omega;

  double _x(double t) => 1 - (1 + omega * t) * math.exp(-omega * t);

  @override
  double transformInternal(double t) => _x(t) / _x(1);
}

abstract final class SoftMotion {
  static const Curve spring = SoftSpringCurve();

  /// Reflow, lift and settle of widgets.
  static const Duration move = Duration(milliseconds: 280);

  /// Small state changes (counters, fades).
  static const Duration quick = Duration(milliseconds: 220);

  /// Check marks and counters drawing in.
  static const Duration draw = Duration(milliseconds: 320);

  static Duration of(BuildContext context, Duration nominal) =>
      (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
      ? Duration.zero
      : nominal;
}

/// Identity hues of the widgets. They are ROLES, not colours: each is a
/// rotation of the theme accent's hue, so the set follows the theme.
enum SoftHue {
  /// The accent's own hue.
  ember(0),

  /// Slightly warmer.
  sand(38),

  /// Fresh, green-ward.
  sage(110),

  /// Cool.
  sky(180),

  /// Violet-ward.
  lavender(250),

  /// No tint at all.
  neutral(null);

  const SoftHue(this.rotation);
  final double? rotation;
}

/// A tint: [wash] is the soft background of an icon chip or a thin band,
/// [ink] the icon/text colour readable on both the wash and the surface.
@immutable
final class SoftTint {
  final Color wash;
  final Color ink;
  const SoftTint(this.wash, this.ink);
}

@immutable
final class SoftPalette {
  /// Pastel washes stay this calm (HSV chroma, 0..1).
  static const double maxWashChroma = 0.10;

  /// Coloured inks stay below this (no neon).
  static const double maxInkChroma = 0.62;

  final Brightness brightness;

  /// Neutral widget surface, lifted from the background.
  final Color surface;

  /// Hairline border of cards.
  final Color hairline;

  /// Inner block (preview frame, list group) on [surface].
  final Color inset;
  final Color track;
  final Color text;
  final Color textMuted;

  /// Desaturated status inks (≥ 4.5:1 on [surface]).
  final Color attention;
  final Color failure;
  final Color ok;

  /// Filled capsule button and its label.
  final Color primary;
  final Color onPrimary;

  /// The theme accent the tints take their hue from.
  final Color accent;
  final Map<SoftHue, SoftTint> _tints = {};

  SoftPalette._({
    required this.brightness,
    required this.surface,
    required this.hairline,
    required this.inset,
    required this.track,
    required this.text,
    required this.textMuted,
    required this.attention,
    required this.failure,
    required this.ok,
    required this.primary,
    required this.onPrimary,
    required this.accent,
  });

  static final Expando<SoftPalette> _cache = Expando('softPalette');

  static SoftPalette ofContext(BuildContext context) {
    final theme = Theme.of(context);
    return of(theme.hermes, theme.brightness);
  }

  static SoftPalette of(HermesThemeColors colors, Brightness brightness) =>
      _cache[colors] ??= _build(colors, brightness);

  static SoftPalette _build(HermesThemeColors c, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final bgL = lightness(c.background);
    // Theme surface when it is a calm step from the background; else a
    // neutral lift (dark) or a slightly greyer sheet (light).
    final themeStep = (lightness(c.surface) - bgL).abs();
    var surface = themeStep >= 0.02 && themeStep <= 0.12
        ? c.surface
        : ThemeContrast.blend(
            c.background,
            dark ? const Color(0xFFFFFFFF) : const Color(0xFF000000),
            dark ? 0.055 : 0.035,
          );
    surface = _capChroma(surface, 0.06);
    final text = ThemeContrast.adjustForContrast(c.textPrimary, [
      surface,
    ], minimum: 7);
    final muted = ThemeContrast.adjustForContrast(c.textSecondary, [
      surface,
    ], minimum: 4.6);
    Color status(Color raw) => ThemeContrast.adjustForContrast(
      _capChroma(ThemeContrast.blend(raw, muted, 0.22), maxInkChroma),
      [surface],
      minimum: 4.6,
    );
    final accentSoft = _capChroma(c.accent, 0.72);
    final onPrimary = ThemeContrast.bestBlackOrWhite(accentSoft);
    return SoftPalette._(
      brightness: brightness,
      surface: surface,
      hairline: ThemeContrast.blend(surface, text, dark ? 0.09 : 0.08),
      inset: ThemeContrast.blend(surface, text, dark ? 0.045 : 0.035),
      track: ThemeContrast.blend(surface, text, dark ? 0.10 : 0.08),
      text: text,
      textMuted: muted,
      attention: status(c.warning),
      failure: status(c.error),
      ok: status(c.success),
      primary: accentSoft,
      onPrimary: onPrimary,
      accent: c.accent,
    );
  }

  SoftTint tint(SoftHue hue) => _tints[hue] ??= _tint(hue);

  SoftTint _tint(SoftHue hue) {
    final rotation = hue.rotation;
    if (rotation == null) {
      final wash = _capChroma(
        ThemeContrast.blend(surface, text, 0.07),
        chroma(surface) + 0.02,
      );
      return SoftTint(
        wash,
        ThemeContrast.adjustForContrast(textMuted, [
          wash,
          surface,
        ], minimum: 4.5),
      );
    }
    final base = HSLColor.fromColor(accent);
    final h = (base.hue + rotation) % 360;
    final dark = brightness == Brightness.dark;
    final pure = HSLColor.fromAHSL(1, h, 0.55, dark ? 0.62 : 0.52).toColor();
    var amount = dark ? 0.16 : 0.18;
    var wash = ThemeContrast.blend(surface, pure, amount);
    while (chroma(wash) > maxWashChroma && amount > 0.01) {
      amount -= 0.01;
      wash = ThemeContrast.blend(surface, pure, amount);
    }
    final inkSeed = HSLColor.fromAHSL(1, h, 0.42, dark ? 0.74 : 0.36).toColor();
    final ink = ThemeContrast.adjustForContrast(
      _capChroma(inkSeed, maxInkChroma),
      [wash, surface],
      minimum: 4.5,
    );
    return SoftTint(wash, ink);
  }

  /// HSL lightness (0..1).
  static double lightness(Color c) {
    final r = c.r, g = c.g, b = c.b;
    return (math.max(r, math.max(g, b)) + math.min(r, math.min(g, b))) / 2;
  }

  /// HSV chroma (0..1): max − min of the channels.
  static double chroma(Color c) {
    final r = c.r, g = c.g, b = c.b;
    return math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
  }

  /// Pulls [c] towards its own grey until its chroma is at most [cap].
  static Color _capChroma(Color c, double cap) {
    final current = chroma(c);
    if (current <= cap) return c;
    final grey = c.r * 0.299 + c.g * 0.587 + c.b * 0.114;
    final k = cap / current;
    int ch(double v) => ((grey + (v - grey) * k) * 255).round().clamp(0, 255);
    return Color.fromARGB(255, ch(c.r), ch(c.g), ch(c.b));
  }
}

/// Capsule progress bar: soft track, fully rounded fill. The fill is
/// never narrower than it is tall, so a small value is a round dot and
/// both ends stay round at every value.
class SoftCapsuleBar extends StatelessWidget {
  const SoftCapsuleBar({
    super.key,
    required this.value,
    required this.color,
    required this.track,
    this.height = 6,
  });

  /// 0..1.
  final double value;
  final Color color;
  final Color track;
  final double height;

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: v),
      duration: SoftMotion.of(context, SoftMotion.draw),
      curve: SoftMotion.spring,
      builder: (context, value, _) => SizedBox(
        height: height,
        child: CustomPaint(
          painter: _CapsulePainter(value, color, track),
          size: Size.fromHeight(height),
        ),
      ),
    );
  }
}

class _CapsulePainter extends CustomPainter {
  _CapsulePainter(this.value, this.color, this.track);
  final double value;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, r),
      Paint()..color = track,
    );
    if (value <= 0) return;
    final w = math.min(size.width, math.max(size.height, size.width * value));
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & Size(w, size.height), r),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_CapsulePainter old) =>
      old.value != value || old.color != color || old.track != track;
}

/// Ring progress with round caps.
class SoftRing extends StatelessWidget {
  const SoftRing({
    super.key,
    required this.value,
    required this.color,
    required this.track,
    this.size = 40,
    this.stroke = 4,
    this.child,
  });

  final double value;
  final Color color;
  final Color track;
  final double size;
  final double stroke;
  final Widget? child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: value.clamp(0.0, 1.0)),
    duration: SoftMotion.of(context, SoftMotion.draw),
    curve: SoftMotion.spring,
    builder: (context, v, child) => CustomPaint(
      size: Size.square(size),
      painter: _RingPainter(v, color, track, stroke),
      child: SizedBox.square(
        dimension: size,
        child: Center(child: child),
      ),
    ),
    child: child,
  );
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value, this.color, this.track, this.stroke);
  final double value;
  final Color color;
  final Color track;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = rect.deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(r, 0, math.pi * 2, false, paint..color = track);
    if (value > 0) {
      canvas.drawArc(
        r,
        -math.pi / 2,
        math.pi * 2 * value,
        false,
        paint..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value ||
      old.color != color ||
      old.track != track ||
      old.stroke != stroke;
}

/// A number that rolls smoothly to its new value.
class SoftCounter extends StatelessWidget {
  const SoftCounter(this.value, {super.key, this.style});
  final int value;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: value.toDouble()),
    duration: SoftMotion.of(context, SoftMotion.draw),
    curve: SoftMotion.spring,
    builder: (context, v, _) =>
        Text('${v.round()}', style: style, semanticsLabel: '$value'),
  );
}
