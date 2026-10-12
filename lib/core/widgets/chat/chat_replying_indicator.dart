import 'package:flutter/material.dart';

/// rp1215: the accent edge on the left of the user bubble being answered
/// while other messages wait behind it. Painted over the bubble (clipped to
/// its rounded shape), so marking or unmarking never changes the layout.
class UserBubbleAccentEdgePainter extends CustomPainter {
  const UserBubbleAccentEdgePainter(this.color, {this.radius = 20});

  final Color color;
  final double radius;

  static const double width = 3;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final shape = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    canvas
      ..save()
      ..clipRRect(shape)
      ..drawRect(
        Rect.fromLTWH(0, 0, width, size.height),
        Paint()..color = color,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(UserBubbleAccentEdgePainter old) =>
      old.color != color || old.radius != radius;
}
