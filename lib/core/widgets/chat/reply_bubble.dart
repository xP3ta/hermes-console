import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../theme/hermes_tokens.dart' show HermesMotion;

/// One spring as a curve: a size change that lands the way the entrances do.
class _SpringCurve extends Curve {
  const _SpringCurve(this.stiffness, this.damping, this.seconds);

  final double stiffness;
  final double damping;
  final double seconds;

  @override
  double transformInternal(double t) => SpringSimulation(
    SpringDescription(mass: 1, stiffness: stiffness, damping: damping),
    0,
    1,
    0,
  ).x(t * seconds);
}

/// A piece that arrives on a spring: it rises a little, fades in and (for a
/// sent message) grows to its size. Only when [animate] is set at its first
/// frame; with reduced motion it is simply there.
class SpringIn extends StatefulWidget {
  const SpringIn({
    required this.child,
    required this.animate,
    this.scaleFrom = 1,
    this.rise = 14,
    this.alignment = Alignment.centerLeft,
    super.key,
  });

  final Widget child;
  final bool animate;
  final double scaleFrom;
  final double rise;
  final Alignment alignment;

  @override
  State<SpringIn> createState() => _SpringInState();
}

class _SpringInState extends State<SpringIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spring = AnimationController.unbounded(
    vsync: this,
    value: widget.animate ? 0 : 1,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!widget.animate) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _spring.value = 1;
      return;
    }
    _spring.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 300, damping: 22),
        0,
        1,
        0,
      ),
    );
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _spring,
    child: widget.child,
    builder: (context, child) {
      final x = _spring.value;
      if (x == 1) return child!;
      return Opacity(
        opacity: x.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, (1 - x) * widget.rise),
          child: Transform.scale(
            scale: widget.scaleFrom + (1 - widget.scaleFrom) * x,
            alignment: widget.alignment,
            child: child,
          ),
        ),
      );
    },
  );
}

/// The answer's soft bubble. A live one arrives on a spring and its size
/// follows the text on another, so it opens instead of jumping. A long answer
/// is cut in slices: only the first has the top corners and only the last
/// the bottom ones, and those slices keep the full width.
class ReplyBubble extends StatelessWidget {
  const ReplyBubble({
    required this.children,
    required this.fill,
    required this.live,
    this.first = true,
    this.last = true,
    super.key,
  });

  final List<Widget> children;
  final Color fill;
  final bool live;
  final bool first;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final whole = first && last;
    const corner = Radius.circular(20);
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final box = Container(
      width: whole ? null : double.infinity,
      padding: EdgeInsets.fromLTRB(14, first ? 9 : 0, 14, last ? 9 : 0),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.vertical(
          top: first ? corner : Radius.zero,
          bottom: last ? corner : Radius.zero,
        ),
      ),
      child: Column(
        crossAxisAlignment: whole
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
    return Padding(
      padding: EdgeInsets.only(top: first ? 4 : 0, bottom: last ? 2 : 0),
      child: SpringIn(
        animate: live && first,
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          // Only the live bubble follows its text on a spring. A settled one
          // is plain layout: an animated size would lag one frame behind a
          // width change (fold, rotation) and the reader's anchor would be
          // measured on the stale size.
          child: live
              ? AnimatedSize(
                  // Never zero: a zero-length AnimatedSize finishes inside
                  // its own layout and marks itself dirty there.
                  duration: reduced
                      ? HermesMotion.instant
                      : HermesMotion.bubble,
                  curve: const _SpringCurve(260, 26, 0.52),
                  alignment: AlignmentDirectional.topStart,
                  child: box,
                )
              : box,
        ),
      ),
    );
  }
}
