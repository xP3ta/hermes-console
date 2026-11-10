import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../theme/motion.dart';

/// What the sprite's halo follows (voz inline: the halo is the orb).
enum VoiceHaloMode {
  /// No voice, or the voice paused: no halo.
  off,

  /// The microphone's level, in the listening tone.
  listening,

  /// A slow breath while Hermes thinks or uses a tool.
  thinking,

  /// Hermes's voice level, in the warm tone.
  speaking,
}

/// A soft radial halo behind the header's sprite that follows the voice.
///
/// It is its own layer: the level is read by a ticker that eases toward it
/// frame by frame and only the painter repaints, so a level tick rebuilds
/// no widget (not the halo's, not the chat's). It never takes layout room
/// either: the host draws it around the sprite, in a [Positioned] that the
/// sprite's box does not grow for. With reduce motion it is a still, soft
/// halo while the voice is live and nothing while it is off.
class VoiceHalo extends StatefulWidget {
  const VoiceHalo({
    required this.mode,
    required this.color,
    this.level,
    this.reduceMotion = false,
    super.key,
  });

  final VoiceHaloMode mode;
  final Color color;

  /// The level (0–1) the halo follows while listening or speaking.
  final ValueListenable<double>? level;
  final bool reduceMotion;

  /// The halo's amplitude with reduce motion: one soft, still glow.
  static const double stillAmplitude = 0.35;

  /// Period of the thinking breath.
  static const Duration breath = HermesMotion.voiceBreath;

  @override
  State<VoiceHalo> createState() => _VoiceHaloState();
}

class _VoiceHaloState extends State<VoiceHalo>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final ValueNotifier<double> _amplitude = ValueNotifier(0);
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(VoiceHalo old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// Starts the ticker when the halo has something to follow, stops it
  /// once an off halo has faded out.
  void _sync() {
    if (widget.reduceMotion) {
      if (_ticker.isActive) _ticker.stop();
      _amplitude.value = widget.mode == VoiceHaloMode.off
          ? 0
          : VoiceHalo.stillAmplitude;
      return;
    }
    if (!_ticker.isActive &&
        (widget.mode != VoiceHaloMode.off || _amplitude.value > 0)) {
      _ticker.start();
    }
  }

  double get _target => switch (widget.mode) {
    VoiceHaloMode.off => 0,
    VoiceHaloMode.thinking =>
      0.25 +
          0.15 *
              math.sin(
                2 *
                    math.pi *
                    _elapsed.inMicroseconds /
                    VoiceHalo.breath.inMicroseconds,
              ),
    VoiceHaloMode.listening || VoiceHaloMode.speaking =>
      0.15 + 0.85 * (widget.level?.value ?? 0).clamp(0.0, 1.0),
  };

  void _tick(Duration elapsed) {
    _elapsed = elapsed;
    final current = _amplitude.value;
    // Eased: a fifth of the way to the target per frame.
    var next = current + (_target - current) * 0.2;
    if ((next - _target).abs() < 0.002) next = _target;
    _amplitude.value = next;
    if (widget.mode == VoiceHaloMode.off && next == 0) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _amplitude.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      key: const ValueKey('voice-halo-paint'),
      painter: VoiceHaloPainter(amplitude: _amplitude, color: widget.color),
      size: Size.infinite,
    ),
  );
}

/// Paints the halo for the [amplitude] it listens to (0 = nothing).
class VoiceHaloPainter extends CustomPainter {
  VoiceHaloPainter({required this.amplitude, required this.color})
    : super(repaint: amplitude);

  final ValueListenable<double> amplitude;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final a = amplitude.value;
    if (a <= 0) return;
    final center = size.center(Offset.zero);
    final full = size.shortestSide / 2;
    final radius = full * (0.7 + 0.3 * a);
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          color.withValues(alpha: 0.10 + 0.32 * a),
          color.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(VoiceHaloPainter old) =>
      old.amplitude != amplitude || old.color != color;
}
