// The small meter of a voice conversation, as Hermes Desktop draws it inside
// its "End" pill (`ConversationIndicator`, apps/desktop/src/app/chat/composer/
// controls.tsx): five thin rounded bars, the middle one the tallest, each
// `30 % + min(70 %, level x weight)` of the box while the app listens and a
// still row of dots otherwise. While Hermes speaks Desktop shows a turning
// mark there instead: the playback has no level to draw, and a meter that
// moved on its own would be a lie.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// What the meter shows.
enum VoiceMeterMode {
  /// Nothing is heard or said: five still dots.
  still,

  /// The bars follow [VoiceMeter.level], the microphone's.
  level,

  /// Hermes is speaking. Its playback reports no level, so this is Desktop's
  /// turning mark, not bars.
  speaking,
}

/// Five bars that follow a live level, in a box that never changes size.
///
/// A level tick repaints this widget's own layer and nothing else: no widget
/// is rebuilt, here or above. Its ticker runs only while a bar is still
/// moving or the speaking mark turns; at rest, and in [VoiceMeterMode.still],
/// nothing is scheduled at all. With animations disabled it is always the
/// still dots.
class VoiceMeter extends StatefulWidget {
  final VoiceMeterMode mode;

  /// The level to follow in [VoiceMeterMode.level]; without one the dots
  /// stay still.
  final ValueListenable<double>? level;
  final Color color;

  const VoiceMeter({
    required this.mode,
    required this.color,
    this.level,
    super.key,
  });

  static const double _barWidth = 2.5;
  static const double _barGap = 2.5;
  static const int _bars = 5;
  static const double width = _bars * _barWidth + (_bars - 1) * _barGap;
  static const double height = 13;

  /// Desktop's weights, and its rule for a bar's share of the box.
  static const List<double> _weights = [0.55, 0.85, 1, 0.85, 0.55];
  static const double _restShare = 0.3;

  /// Height of bar [index] when the meter shows [shown] (0..1).
  @visibleForTesting
  static double barHeight(int index, double shown) =>
      height *
      (_restShare +
          math.min(1 - _restShare, shown.clamp(0.0, 1.0) * _weights[index]));

  @override
  State<VoiceMeter> createState() => VoiceMeterState();
}

@visibleForTesting
class VoiceMeterState extends State<VoiceMeter>
    with SingleTickerProviderStateMixin {
  /// Recent levels: the quietest of them is the room.
  static const int _window = 45;

  /// What the bars show is how far the level rises out of the room's quiet,
  /// not the raw level: a phone records speech at a tenth of full scale,
  /// where bars drawn to scale barely move. A margin above the room still
  /// reads as silence; [_fullRise] above it fills the bars.
  static const double _silence = 0.015;
  static const double _fullRise = 0.2;

  /// The bars rise at once and fall a little slower, like the 100 ms ease of
  /// Desktop's dictation bars: the level arrives in chunks, not per frame.
  static const double _riseMs = 45;
  static const double _fallMs = 140;
  static const double _settled = 0.004;

  /// One turn of the speaking mark, as Desktop's `animate-spin`.
  static const double _turnMs = 1000;

  final List<double> _recent = <double>[];
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  late final Ticker _ticker = createTicker(_onTick);
  Duration _lastTick = Duration.zero;
  double _target = 0;
  double _shown = 0;
  double _turn = 0;
  bool _started = false;
  bool _reducedMotion = false;
  bool _listening = false;
  int _builds = 0;

  /// How much of the box the bars fill now, 0..1.
  double get shown => _shown;

  /// Whether a frame is being asked for.
  bool get ticking => _ticker.isActive;

  /// Times this widget has been built: a level tick never adds one.
  int get builds => _builds;

  VoiceMeterMode get _mode =>
      _reducedMotion ||
          (widget.mode == VoiceMeterMode.level && widget.level == null)
      ? VoiceMeterMode.still
      : widget.mode;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_started && reduced == _reducedMotion) return;
    _started = true;
    _unlisten(widget);
    _reducedMotion = reduced;
    _sync();
  }

  @override
  void didUpdateWidget(VoiceMeter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode == widget.mode &&
        identical(oldWidget.level, widget.level)) {
      return;
    }
    _unlisten(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _unlisten(widget);
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  void _unlisten(VoiceMeter from) {
    if (!_listening) return;
    from.level?.removeListener(_onLevel);
    _listening = false;
  }

  /// Puts the meter in its current mode: what it listens to, and whether
  /// anything moves.
  void _sync() {
    final mode = _mode;
    if (mode == VoiceMeterMode.level) {
      widget.level!.addListener(_onLevel);
      _listening = true;
    } else {
      _recent.clear();
      _target = 0;
      _shown = 0;
    }
    if (mode != VoiceMeterMode.speaking) _turn = 0;
    if (mode == VoiceMeterMode.speaking) {
      _run();
    } else if (mode == VoiceMeterMode.still) {
      _rest();
    }
    _frame.value++;
  }

  void _run() {
    if (_ticker.isActive) return;
    _lastTick = Duration.zero;
    _ticker.start();
  }

  void _rest() {
    if (_ticker.isActive) _ticker.stop();
  }

  void _onLevel() {
    final value = widget.level?.value ?? 0;
    final raw = value.isFinite ? value.clamp(0.0, 1.0) : 0.0;
    _recent.add(raw);
    if (_recent.length > _window) _recent.removeAt(0);
    final room = _recent.reduce(math.min);
    final rise = ((raw - room - _silence) / _fullRise).clamp(0.0, 1.0);
    // A perceptual curve: normal speech moves the bars, not only a shout.
    _target = math.pow(rise, 0.6).toDouble();
    if ((_target - _shown).abs() > _settled) _run();
  }

  void _onTick(Duration elapsed) {
    final ms = (elapsed - _lastTick).inMicroseconds / 1000;
    _lastTick = elapsed;
    if (_mode == VoiceMeterMode.speaking) {
      _turn = (_turn + ms / _turnMs) % 1;
      _frame.value++;
      return;
    }
    final gap = _target - _shown;
    if (gap.abs() <= _settled) {
      _shown = _target;
      _rest();
    } else {
      final time = gap > 0 ? _riseMs : _fallMs;
      _shown += gap * (1 - math.exp(-ms / time));
    }
    _frame.value++;
  }

  @override
  Widget build(BuildContext context) {
    _builds++;
    return RepaintBoundary(
      child: CustomPaint(
        size: const Size(VoiceMeter.width, VoiceMeter.height),
        painter: _MeterPainter(this, widget.color),
      ),
    );
  }
}

class _MeterPainter extends CustomPainter {
  _MeterPainter(this._meter, this._color) : super(repaint: _meter._frame);

  final VoiceMeterState _meter;
  final Color _color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = _color;
    if (_meter._mode == VoiceMeterMode.speaking) {
      // Three quarters of a ring, turning: Desktop's `Loader2`.
      final radius = size.height / 2 - 1.25;
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.75
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: size.center(Offset.zero), radius: radius),
        _meter._turn * 2 * math.pi,
        1.5 * math.pi,
        false,
        paint,
      );
      return;
    }
    const step = VoiceMeter._barWidth + VoiceMeter._barGap;
    const radius = Radius.circular(VoiceMeter._barWidth / 2);
    for (var index = 0; index < VoiceMeter._weights.length; index++) {
      final height = VoiceMeter.barHeight(index, _meter._shown);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            index * step,
            (size.height - height) / 2,
            VoiceMeter._barWidth,
            height,
          ),
          radius,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_MeterPainter oldDelegate) =>
      oldDelegate._color != _color || !identical(oldDelegate._meter, _meter);
}
