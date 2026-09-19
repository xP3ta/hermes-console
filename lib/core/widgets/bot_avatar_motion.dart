import 'package:flutter/material.dart';

/// Motion for existing raster avatars (including selected pet thumbnails).
/// Procedural faces keep their own scan/blink animation in HermesBotFace.
class BotAvatarMotion extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final bool pet;
  const BotAvatarMotion({
    super.key,
    required this.child,
    required this.enabled,
    this.pet = false,
  });

  @override
  State<BotAvatarMotion> createState() => _BotAvatarMotionState();
}

class _BotAvatarMotionState extends State<BotAvatarMotion>
    with SingleTickerProviderStateMixin {
  late final _clock = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  bool get _enabled =>
      widget.enabled &&
      !MediaQuery.disableAnimationsOf(context) &&
      TickerMode.valuesOf(context).enabled;
  void _sync() {
    if (_enabled) {
      if (!_clock.isAnimating) _clock.repeat(reverse: true);
    } else {
      _clock.stop();
      _clock.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant BotAvatarMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _clock,
    child: widget.child,
    builder: (context, child) {
      final t = Curves.easeInOut.transform(_clock.value);
      return Transform.translate(
        offset: Offset(0, widget.pet ? -2 * t : 0),
        child: Transform.scale(scale: 1 - .035 * t, child: child),
      );
    },
  );
}
