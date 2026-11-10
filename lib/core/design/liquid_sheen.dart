import 'package:flutter/material.dart';

import '../widgets/frosted_backdrop.dart';
import 'liquid_glass.dart';

/// Filter-free, edge-only material for opaque groups and collection frames.
/// Rows keep their existing fills and inks. There is no glow over content.
class HermesSheen extends StatefulWidget {
  const HermesSheen({
    required this.child,
    required this.shape,
    this.enabled = true,
    this.liquid = HermesLiquid.overlay,
    super.key,
  });

  final Widget child;
  final OutlinedBorder shape;
  final bool enabled;
  final HermesLiquid liquid;

  @override
  State<HermesSheen> createState() => _HermesSheenState();
}

class _HermesSheenState extends State<HermesSheen> {
  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    FrostedBackdropPolicy.changes.addListener(_changed);
  }

  @override
  void dispose() {
    FrostedBackdropPolicy.changes.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final paints =
        widget.enabled &&
        FrostedBackdropPolicy.effectCeiling.value == HermesGlassTier.liquid &&
        FrostedBackdropPolicy.knownHighEnd.value &&
        FrostedBackdropPolicy.blursIn(context);
    return CustomPaint(
      foregroundPainter: paints
          ? _Rim(widget.shape, widget.liquid, Directionality.maybeOf(context))
          : null,
      child: widget.child,
    );
  }
}

class _Rim extends CustomPainter {
  const _Rim(this.shape, this.liquid, this.direction);

  final OutlinedBorder shape;
  final HermesLiquid liquid;
  final TextDirection? direction;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (rect.isEmpty) return;
    liquid.paintRim(
      canvas,
      shape.getOuterPath(rect, textDirection: direction),
      rect,
    );
  }

  @override
  bool shouldRepaint(_Rim oldDelegate) =>
      shape != oldDelegate.shape ||
      liquid != oldDelegate.liquid ||
      direction != oldDelegate.direction;
}
