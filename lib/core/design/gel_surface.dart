import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'tokens.dart';

/// The gel-glass of the buttons ("cristal plastilina"): the one primitive
/// that gives a round or capsule button its glossy look.
///
/// It paints, over what [child] draws:
///  * the 1 px inner light of the top edge and the inner shade of the
///    bottom one,
///  * the gel's sheen, a 160 degree gradient of white that fades out at
///    38 % of the piece (it never reaches a centred icon), and
///  * with [HermesGelTone.accent], under the child, the accent gradient
///    (accent to a turned, lifted accent at 135 degrees) with its glow.
///
/// It never blurs: inside a `HermesGlassStrip` the pieces already share the
/// strip's one blur, and a loose button takes the fill it is given (or its
/// own translucent [paintFill] when none is) so the look is the same with
/// the blur off. Nothing animates at rest: a press compresses the gel by 4 %
/// and slides the sheen, without interpolation when the system reduces
/// motion. High contrast leaves the plain piece, without sheen or rims.
enum HermesGelTone { glass, accent }

class HermesGelSurface extends StatefulWidget {
  const HermesGelSurface({
    required this.child,
    this.shape = const CircleBorder(),
    this.tone = HermesGelTone.glass,
    this.accent,
    this.ink,
    this.paintFill = false,
    this.hairline = false,
    this.glow = true,
    this.enabled = true,
    this.pressable = true,
    this.inset = 0,
    this.pressed,
    this.sheenScale = 1,
    super.key,
  });

  final Widget child;

  /// Outline: a circle, a stadium or a rounded rectangle.
  final OutlinedBorder shape;

  final HermesGelTone tone;

  /// The accent of [HermesGelTone.accent]; the theme's by default.
  final Color? accent;

  /// The ink the accent gradient must stay readable under.
  final Color? ink;

  /// Paint the glass's own translucent fill (a piece that has no strip or
  /// veil behind it).
  final bool paintFill;

  /// Paint the 1 px border of the glass (a piece that has none of its own).
  final bool hairline;

  /// Accent only: the glow under the piece.
  final bool glow;

  /// A disabled piece neither compresses nor slides.
  final bool enabled;

  /// False for a piece inside a bigger one that already answers to the
  /// press.
  final bool pressable;

  /// The gel is painted this far inside the child's box: a button with a
  /// 48 dp target and a 44 dp look.
  final double inset;

  /// The press as the owner of the piece knows it (a button that already
  /// compresses itself); null: the piece listens to the pointer and
  /// compresses itself when [pressable].
  final bool? pressed;

  /// How much of the sheen the piece paints, 0 to 1. A piece whose text sits
  /// under the sheen (the composer, the status pill, the name pill) takes
  /// [HermesGel.textSheenScale], so that no ink loses its AA.
  final double sheenScale;

  @override
  State<HermesGelSurface> createState() => _HermesGelSurfaceState();
}

class _HermesGelSurfaceState extends State<HermesGelSurface> {
  bool _pressed = false;

  void _press(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final gel = HermesGel.of(colors);
    // Only these two aspects: a gel on the chat foot must not rebuild on
    // every keyboard frame (the view insets).
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final flat = MediaQuery.maybeHighContrastOf(context) ?? false;
    final own = widget.pressed == null && widget.pressable;
    final pressed = (widget.pressed ?? _pressed) && widget.enabled;
    final accent = widget.tone == HermesGelTone.accent
        ? widget.accent ?? colors.accent
        : null;
    final far = accent == null
        ? null
        : HermesGel.accent2(accent, ink: widget.ink ?? colors.onAccent);
    Widget body = CustomPaint(
      painter: _GelPainter(
        shape: widget.shape,
        gel: gel,
        inset: widget.inset,
        foreground: false,
        accent: accent,
        far: far,
        fill: widget.paintFill ? gel.glassFill : null,
      ),
      foregroundPainter: _GelPainter(
        shape: widget.shape,
        gel: gel,
        inset: widget.inset,
        foreground: true,
        flat: flat,
        hairline: widget.hairline,
        pressed: pressed,
        sheenScale: widget.sheenScale,
      ),
      child: widget.child,
    );
    if (accent != null && widget.glow && !flat) {
      body = DecoratedBox(
        decoration: ShapeDecoration(
          shape: widget.shape,
          shadows: [
            BoxShadow(
              color: accent.withValues(
                alpha: HermesGel.glowAlpha * (pressed ? 0.5 : 1),
              ),
              blurRadius: pressed ? HermesGel.glowBlur / 2 : HermesGel.glowBlur,
              offset: Offset(0, pressed ? 1 : HermesGel.glowDrop),
            ),
          ],
        ),
        child: body,
      );
    }
    if (!own) return body;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _press(true),
      onPointerUp: (_) => _press(false),
      onPointerCancel: (_) => _press(false),
      child: AnimatedScale(
        scale: pressed ? HermesGel.pressScale : 1,
        duration: reduceMotion ? Duration.zero : HermesGel.pressDuration,
        curve: Curves.easeOutCubic,
        child: body,
      ),
    );
  }
}

class _GelPainter extends CustomPainter {
  const _GelPainter({
    required this.shape,
    required this.gel,
    required this.foreground,
    this.inset = 0,
    this.accent,
    this.far,
    this.fill,
    this.flat = false,
    this.hairline = false,
    this.pressed = false,
    this.sheenScale = 1,
  });

  final OutlinedBorder shape;
  final HermesGel gel;

  /// Foreground: rims, sheen and hairline. Background: fill or gradient.
  final bool foreground;
  final double inset;
  final Color? accent;
  final Color? far;
  final Color? fill;
  final bool flat;
  final bool hairline;
  final bool pressed;
  final double sheenScale;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = (Offset.zero & size).deflate(inset);
    if (rect.isEmpty) return;
    final box = rect.size;
    final outline = shape.getOuterPath(rect);
    if (!foreground) {
      if (accent != null && far != null) {
        final (from, to) = HermesGel.line(box, 135);
        final shift = rect.topLeft;
        canvas.drawPath(
          outline,
          Paint()
            ..shader = ui.Gradient.linear(from + shift, to + shift, [
              accent!,
              far!,
            ]),
        );
      } else if (fill != null) {
        canvas.drawPath(outline, Paint()..color = fill!);
      }
      return;
    }
    if (hairline) {
      shape
          .copyWith(
            side: BorderSide(color: gel.hairline, width: HermesGel.rimWidth),
          )
          .paint(canvas, rect);
    }
    if (flat) return;
    canvas.save();
    canvas.clipPath(outline);
    final outer = Path()..addRect(rect.inflate(HermesGel.rimWidth * 2));
    void rim(Offset shift, Color color) => canvas.drawPath(
      Path.combine(PathOperation.difference, outer, outline.shift(shift)),
      Paint()..color = color,
    );
    rim(const Offset(0, HermesGel.rimWidth), gel.rimTop);
    rim(const Offset(0, -HermesGel.rimWidth), gel.rimBottom);
    if (sheenScale <= 0) {
      canvas.restore();
      return;
    }
    final (from, to) = HermesGel.line(box, HermesGel.sheenAngle);
    final slide =
        rect.topLeft +
        (pressed
            ? Offset(
                box.width * HermesGel.sheenSlide,
                -box.height * HermesGel.sheenSlide,
              )
            : Offset.zero);
    final sheen = gel.sheen.withValues(alpha: gel.sheen.a * sheenScale);
    final clear = gel.sheen.withValues(alpha: 0);
    canvas.drawPath(
      outline,
      Paint()
        ..shader = ui.Gradient.linear(
          from + slide,
          to + slide,
          [sheen, clear, clear],
          [0, HermesGel.sheenStop, 1],
        ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GelPainter old) =>
      old.shape != shape ||
      old.gel != gel ||
      old.foreground != foreground ||
      old.inset != inset ||
      old.accent != accent ||
      old.far != far ||
      old.fill != fill ||
      old.flat != flat ||
      old.hairline != hairline ||
      old.pressed != pressed ||
      old.sheenScale != sheenScale;
}
