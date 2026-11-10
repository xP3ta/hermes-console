import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/glass_look.dart';
import 'tokens.dart' show HermesGel;

/// The finish of a box (a card, a group, a panel, a row of a list, a tab bar,
/// a field, a notice): the same grammar as the gel of the buttons
/// (`HermesGelSurface`), at the scale of a box.
///
///  * the contour, 1 px, in two tones: the top edge lighter, the bottom one
///    darker (both keep [GlassMaterial.borderRatio] against the page);
///  * inside it, 1 px in, the gel's inner light along the top edge and its
///    inner shade along the bottom one, following the corners;
///  * a short shadow under the box, painted OUTSIDE its outline only (so a
///    translucent body never shows it).
///
/// It is painted, never blurred over the content: no `BackdropFilter`, no
/// layer; a long list pays a gradient stroke, two crescents and one small
/// blur per row.
@immutable
class HermesBoxEdge extends CustomPainter {
  const HermesBoxEdge({
    required this.radius,
    required this.top,
    required this.bottom,
    required this.light,
    required this.shade,
  });

  /// The edge of [glass]; [line] (a selected row's accent, say) replaces
  /// both tones of the contour.
  factory HermesBoxEdge.of(
    GlassMaterial glass,
    BorderRadius radius, {
    Color? line,
  }) => HermesBoxEdge(
    radius: radius,
    top: line ?? glass.lineTop,
    bottom: line ?? glass.lineBottom,
    light: glass.rim,
    shade: glass.rimShade,
  );

  final BorderRadius radius;

  /// The contour at the top edge and at the bottom one.
  final Color top;
  final Color bottom;

  /// The inner light of the top edge and the inner shade of the bottom one.
  final Color light;
  final Color shade;

  @override
  void paint(Canvas canvas, Size size) {
    const width = HermesGel.rimWidth;
    if (size.width < width * 4 || size.height < width * 4) return;
    final rect = Offset.zero & size;
    final outer = radius.toRRect(rect);
    final contour = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    if (top == bottom) {
      contour.color = top;
    } else {
      contour.shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
        top,
        bottom,
      ]);
    }
    canvas.drawRRect(outer.deflate(width / 2), contour);
    // The rims sit just inside the contour, so they never wash it out.
    final inner = outer.deflate(width);
    canvas.save();
    canvas.clipRRect(inner);
    void crescent(double drop, Color color) => canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRRect(inner)
        ..addRRect(inner.shift(Offset(0, drop))),
      Paint()..color = color,
    );
    crescent(width, light);
    crescent(-width, shade);
    canvas.restore();
  }

  @override
  bool shouldRepaint(HermesBoxEdge old) =>
      old.radius != radius ||
      old.top != top ||
      old.bottom != bottom ||
      old.light != light ||
      old.shade != shade;
}

/// The short shadow of a box, [drop] down and [blur] soft, clipped away
/// inside the outline: only what falls outside the box is painted.
@immutable
class HermesBoxShadow extends CustomPainter {
  const HermesBoxShadow({
    required this.radius,
    required this.color,
    required this.blur,
    required this.drop,
  });

  final BorderRadius radius;
  final Color color;
  final double blur;
  final double drop;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || color.a == 0) return;
    final rect = Offset.zero & size;
    final box = radius.toRRect(rect);
    final reach = blur * 2 + drop.abs() + 2;
    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(rect.inflate(reach))
        ..addRRect(box),
    );
    canvas.drawRRect(
      box.shift(Offset(0, drop)),
      Paint()
        ..color = color
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          Shadow.convertRadiusToSigma(blur),
        ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(HermesBoxShadow old) =>
      old.radius != radius ||
      old.color != color ||
      old.blur != blur ||
      old.drop != drop;
}

/// [child] with the finish of a box: the contour and rims over it
/// ([HermesBoxEdge]) and, when [lifted], the short shadow under it
/// ([HermesBoxShadow]). The box's own body is the child's: it must leave the
/// outer [HermesGel.rimWidth] to the contour (a padding of that width).
class HermesBoxEdges extends StatelessWidget {
  const HermesBoxEdges({
    required this.glass,
    required this.radius,
    required this.child,
    this.lifted = false,
    this.compact = false,
    this.line,
    super.key,
  });

  final GlassMaterial glass;
  final BorderRadius radius;
  final Widget child;

  /// Paint the short shadow (a few boxes per screen, or a list's rows with
  /// [compact]).
  final bool lifted;

  /// The shorter shadow of a card or a row of a list.
  final bool compact;

  /// A single colour for the whole contour (a selected row's accent).
  final Color? line;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: lifted
        ? HermesBoxShadow(
            radius: radius,
            color: glass.boxShadow,
            blur: compact
                ? HermesGel.boxShadowCompactBlur
                : HermesGel.boxShadowBlur,
            drop: compact
                ? HermesGel.boxShadowCompactDrop
                : HermesGel.boxShadowDrop,
          )
        : null,
    foregroundPainter: HermesBoxEdge.of(glass, radius, line: line),
    child: child,
  );
}
