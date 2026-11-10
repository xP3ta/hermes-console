import 'dart:ui';

import '../theme/theme_contrast.dart';
import '../widgets/hermes_bot_face.dart';
import 'studio_catalog.dart';
import 'studio_motion.dart';

/// Where the pair of eyes sits on the 100 x 100 canvas.
abstract final class StudioEyeLayout {
  static const double spacing = 15;
  static const double y = 47;
}

/// Paints the pair of eyes of a studio character in the 100 x 100 canvas.
///
/// [size] scales the eyes; [face] carries the glance, blink and brows of the
/// motion engine; [mood] overrides the style for the poses that need
/// closed, smiling, heart or crossed eyes. Every shape is drawn here from
/// plain paths.
void paintStudioEyes(
  Canvas canvas, {
  required BotEyeStyle style,
  required Color color,
  required double size,
  HermesBotFaceMotionSnapshot face = HermesBotFaceMotionSnapshot.staticFrame,
  BotEyeMood mood = BotEyeMood.open,
  double spacing = StudioEyeLayout.spacing,
  double y = StudioEyeLayout.y,
}) {
  final fill = Paint()
    ..color = color
    ..style = PaintingStyle.fill;
  final line = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = 2.6;
  final accent = ThemeContrast.bestBlackOrWhite(color);
  final glint = Paint()
    ..color = accent
    ..style = PaintingStyle.fill;
  for (final side in const [-1, 1]) {
    canvas.save();
    canvas.translate(
      50 + side * spacing + face.eyeOffsetX,
      y + face.eyeOffsetY,
    );
    canvas.scale(size * face.eyeScaleX, size * face.eyeScaleY);
    if (face.brows != 0) _brow(canvas, side, face.brows, line);
    switch (mood) {
      case BotEyeMood.closed:
        _closed(canvas, line);
      case BotEyeMood.joy:
        _joy(canvas, line);
      case BotEyeMood.heart:
        _heart(canvas, fill);
      case BotEyeMood.cross:
        _cross(canvas, line);
      case BotEyeMood.open:
        canvas.scale(1, face.blinkScaleY.clamp(0.08, 1.0).toDouble());
        _style(canvas, style, side, fill, line, glint);
    }
    canvas.restore();
  }
}

void _closed(Canvas canvas, Paint line) {
  canvas.drawPath(
    Path()
      ..moveTo(-5.5, -0.5)
      ..quadraticBezierTo(0, 5.5, 5.5, -0.5),
    line,
  );
}

void _joy(Canvas canvas, Paint line) {
  canvas.drawPath(
    Path()
      ..moveTo(-5.5, 2.5)
      ..quadraticBezierTo(0, -6, 5.5, 2.5),
    line,
  );
}

void _cross(Canvas canvas, Paint line) {
  canvas
    ..drawLine(const Offset(-4.5, -4.5), const Offset(4.5, 4.5), line)
    ..drawLine(const Offset(4.5, -4.5), const Offset(-4.5, 4.5), line);
}

void _heart(Canvas canvas, Paint fill) {
  canvas.drawPath(
    Path()
      ..moveTo(0, 6.4)
      ..cubicTo(-11, 0, -6.5, -8, 0, -3.2)
      ..cubicTo(6.5, -8, 11, 0, 0, 6.4)
      ..close(),
    fill,
  );
}

void _brow(Canvas canvas, int side, double brows, Paint line) {
  // brows > 0 raised; brows < 0 worried, the inner end lifted.
  final lift = brows > 0 ? 11 + brows * 2.4 : 10.5;
  final innerLift = brows < 0 ? lift + 3.2 * -brows : lift;
  final innerX = -6.0 * side;
  canvas.drawLine(
    Offset(innerX, -innerLift),
    Offset(-innerX, -lift),
    Paint()
      ..color = line.color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.1,
  );
}

void _style(
  Canvas canvas,
  BotEyeStyle style,
  int side,
  Paint fill,
  Paint line,
  Paint glint,
) {
  switch (style) {
    case BotEyeStyle.dot:
      canvas.drawCircle(Offset.zero, 5, fill);
    case BotEyeStyle.oval:
      canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: 8.4, height: 12),
        fill,
      );
    case BotEyeStyle.joy:
      _joy(canvas, line);
    case BotEyeStyle.dreamy:
      canvas.save();
      canvas.clipRect(const Rect.fromLTRB(-9, -1.5, 9, 10));
      canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: 11.4, height: 12.4),
        fill,
      );
      canvas.restore();
      canvas.drawLine(const Offset(-6.4, -1.5), const Offset(6.4, -1.5), line);
      canvas
        ..drawCircle(const Offset(-1.8, 1.6), 1.5, glint)
        ..drawCircle(const Offset(2, 3.4), 0.8, glint);
    case BotEyeStyle.glint:
      canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: 9.8, height: 12.6),
        fill,
      );
      canvas
        ..drawCircle(const Offset(-1.7, -2.8), 2.5, glint)
        ..drawCircle(const Offset(2, 3), 1.2, glint);
    case BotEyeStyle.bold:
      canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: 8, height: 12.4),
        fill,
      );
      canvas.drawLine(
        const Offset(-6.5, -10),
        const Offset(6.5, -10),
        line..strokeWidth = 3.2,
      );
    case BotEyeStyle.lantern:
      final triangle = Path()
        ..moveTo(0, -6.6)
        ..lineTo(6.6, 5)
        ..lineTo(-6.6, 5)
        ..close();
      canvas
        ..drawPath(triangle, fill)
        ..drawPath(triangle, line..strokeWidth = 2);
    case BotEyeStyle.ring:
      canvas.drawCircle(Offset.zero, 5.2, line..strokeWidth = 2.4);
    case BotEyeStyle.wink:
      if (side < 0) {
        canvas.drawCircle(Offset.zero, 5, fill);
      } else {
        _joy(canvas, line);
      }
    case BotEyeStyle.amazed:
      canvas.drawCircle(Offset.zero, 6.6, line..strokeWidth = 2.2);
      canvas.drawCircle(const Offset(0.4, 0.4), 2.5, fill);
    case BotEyeStyle.narrow:
      canvas.drawLine(
        const Offset(-5.6, 0),
        const Offset(5.6, 0),
        line..strokeWidth = 3.4,
      );
    case BotEyeStyle.grumpy:
      final outer = side < 0 ? -4.5 : 0.0;
      final inner = side < 0 ? 0.0 : -4.5;
      canvas.save();
      canvas.clipPath(
        Path()
          ..moveTo(-9, outer)
          ..lineTo(9, inner)
          ..lineTo(9, 10)
          ..lineTo(-9, 10)
          ..close(),
      );
      canvas.drawCircle(Offset.zero, 5.4, fill);
      canvas.restore();
      canvas.drawLine(
        Offset(-7, outer - 0.3),
        Offset(7, inner - 0.3),
        line..strokeWidth = 2.2,
      );
    case BotEyeStyle.slit:
      canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: 11.6, height: 12.4),
        fill,
      );
      canvas.drawLine(
        const Offset(0, -5),
        const Offset(0, 5),
        Paint()
          ..color = glint.color
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 2.2,
      );
    case BotEyeStyle.undead:
      if (side < 0) {
        _cross(canvas, line);
      } else {
        canvas
          ..drawCircle(Offset.zero, 6.2, fill)
          ..drawCircle(const Offset(1, -1), 2.1, glint);
      }
    case BotEyeStyle.heart:
      _heart(canvas, fill);
  }
}

/// Small preview of one eye style (the editor's grid), drawn centred in a
/// square [size] with the pair of eyes.
void paintEyeStylePreview(
  Canvas canvas,
  Size size,
  BotEyeStyle style,
  Color color,
) {
  final scale = size.shortestSide / 52;
  canvas.save();
  canvas.translate(size.width / 2, size.height / 2);
  canvas.scale(scale, scale);
  canvas.translate(-50, -StudioEyeLayout.y);
  paintStudioEyes(canvas, style: style, color: color, size: 1);
  canvas.restore();
}
