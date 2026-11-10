import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/motion.dart' show HermesMotion;

/// "Trabajando": a thin ring with a short arc running round it, in the
/// colour of the state. It stands in for the dot that used to go before the
/// title of a live row: the state is told once, next to its own text.
///
/// With animations off (system setting) the arc stays still at the top.
class HermesWorkingRing extends StatefulWidget {
  const HermesWorkingRing({required this.color, this.size = 12, super.key});

  final Color color;
  final double size;

  @override
  State<HermesWorkingRing> createState() => _HermesWorkingRingState();
}

class _HermesWorkingRingState extends State<HermesWorkingRing>
    with SingleTickerProviderStateMixin {
  AnimationController? _turn;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion) {
      _turn?.dispose();
      _turn = null;
      return;
    }
    _turn ??= AnimationController(vsync: this, duration: HermesMotion.spin)
      ..repeat();
  }

  @override
  void dispose() {
    _turn?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // It repaints every frame while the row is live: its own layer, so the
    // title and the preview of the row are not repainted with it.
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: CustomPaint(painter: _RingPainter(widget.color, _turn)),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.color, this.turn) : super(repaint: turn);

  final Color color;
  final Animation<double>? turn;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide / 6;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.shortestSide / 2 - stroke / 2,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.22);
    canvas.drawArc(rect, 0, 2 * math.pi, false, paint);
    paint.color = color;
    final start = -math.pi / 2 + (turn?.value ?? 0) * 2 * math.pi;
    canvas.drawArc(rect, start, math.pi * 0.62, false, paint);
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.turn != turn;
}
