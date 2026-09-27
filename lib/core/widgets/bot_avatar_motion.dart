import 'package:flutter/material.dart';

/// Motion for existing raster avatars (including selected pet thumbnails).
/// Procedural faces keep their own scan/blink animation in HermesBotFace.
class BotAvatarMotion extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final bool pet;

  /// Optional shared clock (any period); its value drives one breath phase
  /// per [externalPeriod]. With a clock this widget owns no ticker.
  final Animation<double>? clock;
  final Duration externalPeriod;
  final Duration externalClockDuration;

  /// Breath depth (scale dip at the bottom of a breath).
  final double depth;

  /// Upward lift in logical pixels at the top of a breath; `null` keeps
  /// the legacy behaviour (2 px for pets, none otherwise).
  final double? lift;

  const BotAvatarMotion({
    super.key,
    required this.child,
    required this.enabled,
    this.pet = false,
    this.clock,
    this.externalPeriod = const Duration(milliseconds: 3200),
    this.externalClockDuration = const Duration(days: 1),
    this.depth = .035,
    this.lift,
  });

  @override
  State<BotAvatarMotion> createState() => _BotAvatarMotionState();
}

class _BotAvatarMotionState extends State<BotAvatarMotion>
    with SingleTickerProviderStateMixin {
  AnimationController? _ownClock;
  AnimationController get _clock => _ownClock ??= AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  bool get _enabled =>
      widget.enabled &&
      !MediaQuery.disableAnimationsOf(context) &&
      TickerMode.valuesOf(context).enabled;
  void _sync() {
    if (widget.clock != null) {
      _ownClock?.stop();
      return;
    }
    if (_enabled) {
      if (!_clock.isAnimating) _clock.repeat(reverse: true);
    } else {
      _ownClock?.stop();
      if (_ownClock != null && _ownClock!.value != 0) _ownClock!.value = 0;
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
    _ownClock?.dispose();
    super.dispose();
  }

  double get _phase {
    final external = widget.clock;
    if (external == null) return _ownClock?.value ?? 0;
    if (!_enabled) return 0;
    final elapsedUs =
        external.value * widget.externalClockDuration.inMicroseconds;
    final period = widget.externalPeriod.inMicroseconds;
    final cycle = (elapsedUs % period) / period;
    // Triangle wave 0→1→0, same shape as repeat(reverse: true).
    return cycle < .5 ? cycle * 2 : 2 - cycle * 2;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.clock ?? _ownClock ?? kAlwaysDismissedAnimation,
    child: widget.child,
    builder: (context, child) {
      final t = Curves.easeInOut.transform(_phase);
      final lift = widget.lift;
      if (lift == null) {
        return Transform.translate(
          offset: Offset(0, widget.pet ? -2 * t : 0),
          child: Transform.scale(scale: 1 - widget.depth * t, child: child),
        );
      }
      // Living avatars: inhale (t→0) grows and rises, exhale settles.
      // Scaling from the bottom keeps the avatar planted instead of
      // pulsing in place.
      return Transform.translate(
        offset: Offset(0, -lift * (1 - t)),
        child: Transform.scale(
          scale: 1 - widget.depth * t,
          alignment: Alignment.bottomCenter,
          child: child,
        ),
      );
    },
  );
}
