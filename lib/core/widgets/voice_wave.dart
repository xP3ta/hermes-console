// The wave of a voice conversation (QA 9709, the owner: «como la de Grok»): thin
// bars across the whole width they are given, symmetric about the middle
// line, drawing the recent history of a live level. What is new comes in on
// the right and the rest slides left, smoothly, a sample at a time; it is
// not a block of bars rising and falling together.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// What the wave draws.
enum VoiceWaveMode {
  /// Nothing to follow (loading, paused, waiting, a failure): a still line
  /// of dots.
  rest,

  /// The microphone's level, while the user speaks.
  listening,

  /// Hermes is working: almost flat, with a slow pulse in the middle.
  thinking,

  /// The level of the reply that is playing. Where the app has no level of
  /// its own playback (the phone's voice) it stays a still line rather than
  /// faking one.
  speaking,
}

/// Thin bars across the whole width, following [level] in
/// [VoiceWaveMode.listening] and [VoiceWaveMode.speaking].
///
/// A sample repaints this widget's own layer and nothing else: no widget is
/// rebuilt. The ticker runs only while the wave moves: once the level is
/// quiet and every bar is down it stops, and the level's next change starts
/// it again. Only the thinking pulse runs on its own. At rest, and with
/// animations disabled (a still shape), nothing is scheduled.
class VoiceWave extends StatefulWidget {
  const VoiceWave({
    required this.mode,
    required this.color,
    this.level,
    this.height = defaultHeight,
    super.key,
  });

  final VoiceWaveMode mode;

  /// The live level (0..1) to draw while listening or speaking.
  final ValueListenable<double>? level;
  final Color color;
  final double height;

  static const double defaultHeight = 36;
  static const double barWidth = 2.5;
  static const double barGap = 3;

  /// A bar for every [barWidth] + [barGap] of [width].
  static int barsFor(double width) =>
      width <= 0 ? 0 : ((width + barGap) / (barWidth + barGap)).floor();

  @override
  State<VoiceWave> createState() => VoiceWaveState();
}

@visibleForTesting
class VoiceWaveState extends State<VoiceWave>
    with SingleTickerProviderStateMixin {
  /// One new sample this often; between two, the bars slide by a fraction.
  static const double _sampleMs = 60;

  /// What the bars show is how far the level rises out of the room's quiet
  /// (the quietest of the last samples), like the meter it replaces: speech
  /// arrives at a tenth of full scale, and drawn to scale it barely moves.
  static const int _window = 45;
  static const double _silence = 0.015;
  static const double _fullRise = 0.2;

  /// Rise at once, fall a little slower: the level arrives in chunks.
  static const double _fall = 0.55;
  static const double _settled = 0.004;

  /// One breath of the thinking pulse.
  static const double _pulseMs = 2400;

  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  late final Ticker _ticker = createTicker(_onTick);
  final List<double> _recent = <double>[];
  List<double> _samples = const [];
  /// The last tick's time; null until the ticker's first.
  Duration? _last;
  double _sinceSample = 0;
  double _pulse = 0;
  double _held = 0;
  bool _reduced = false;

  /// The bars' heights now, oldest first (0..1 of the height).
  List<double> get samples => List.unmodifiable(_samples);

  /// Whether a frame is being asked for.
  bool get ticking => _ticker.isActive;

  /// How far the bars have slid towards the next sample, 0..1.
  double get slide => (_sinceSample / _sampleMs).clamp(0.0, 1.0);

  /// The pulse's phase, 0..1, while thinking.
  double get pulse => _pulse;

  bool get _moves =>
      !_reduced &&
      switch (widget.mode) {
        VoiceWaveMode.rest => false,
        VoiceWaveMode.thinking => true,
        VoiceWaveMode.listening ||
        VoiceWaveMode.speaking => widget.level != null,
      };

  @override
  void initState() {
    super.initState();
    _listen(widget.level);
  }

  /// Follows [level]: every value it takes is part of the room's history,
  /// the one it has now included, so the quiet before speech counts even
  /// while the ticker sleeps.
  void _listen(ValueListenable<double>? level) {
    if (level == null) return;
    level.addListener(_onLevel);
    _remember(level.value);
  }

  void _remember(double raw) {
    _recent.add(raw);
    if (_recent.length > _window) _recent.removeAt(0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(VoiceWave oldWidget) {
    super.didUpdateWidget(oldWidget);
    final levelChanged = !identical(oldWidget.level, widget.level);
    if (levelChanged) oldWidget.level?.removeListener(_onLevel);
    if (levelChanged || oldWidget.mode != widget.mode) {
      _recent.clear();
      _held = 0;
      _samples = List<double>.filled(_samples.length, 0);
      if (levelChanged) {
        _listen(widget.level);
      } else if (widget.level case final level?) {
        _remember(level.value);
      }
    }
    _sync();
  }

  /// The level moved: it joins the room's history and, if the wave had
  /// stopped, the wave goes on.
  void _onLevel() {
    final level = widget.level;
    if (level == null) return;
    _remember(level.value);
    if (_moves && !_ticker.isActive) {
      _last = null;
      _ticker.start();
    }
  }

  void _sync() {
    if (_moves) {
      if (!_ticker.isActive) {
        _last = null;
        _ticker.start();
      }
    } else if (_ticker.isActive) {
      _ticker.stop();
    }
    _frame.value++;
  }

  /// The bars that fit [width]: the history keeps its newest samples.
  void _fit(int bars) {
    // One more than fits: it slides in from the right edge.
    final count = bars + 1;
    if (_samples.length == count) return;
    final kept = _samples.length > count
        ? _samples.sublist(_samples.length - count)
        : [...List<double>.filled(count - _samples.length, 0), ..._samples];
    _samples = kept;
  }

  double _shown(double raw) {
    final room = _recent.isEmpty ? raw : _recent.reduce(math.min);
    return ((raw - room - _silence) / _fullRise).clamp(0.0, 1.0);
  }

  void _onTick(Duration elapsed) {
    final last = _last;
    final dt = last == null ? 0.0 : (elapsed - last).inMicroseconds / 1000;
    _last = elapsed;
    if (widget.mode == VoiceWaveMode.thinking) {
      _pulse = (_pulse + dt / _pulseMs) % 1;
      _frame.value++;
      return;
    }
    _sinceSample += dt;
    var sampled = false;
    while (_sinceSample >= _sampleMs) {
      _sinceSample -= _sampleMs;
      sampled = true;
      final target = _shown(widget.level?.value ?? 0);
      _held = target >= _held ? target : _held + (target - _held) * _fall;
      // Below what a bar can show, it is down.
      if (_held < _settled) _held = 0;
      if (_samples.isNotEmpty) {
        _samples = [..._samples.skip(1), _held];
      }
    }
    _frame.value++;
    // Quiet, and every bar down after a sample: nothing moves until the
    // level does. (A tick that took no sample, the first after a start,
    // has not looked at the level yet.)
    if (sampled && _held == 0 && _samples.every((s) => s == 0)) {
      _ticker.stop();
      _sinceSample = 0;
    }
  }

  @override
  void dispose() {
    widget.level?.removeListener(_onLevel);
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 0.0;
      _fit(VoiceWave.barsFor(width));
      return SizedBox(
        width: width,
        height: widget.height,
        child: CustomPaint(
          painter: _WavePainter(
            state: this,
            mode: widget.mode,
            still: _reduced,
            color: widget.color,
            repaint: _frame,
          ),
        ),
      );
    },
  );
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.state,
    required this.mode,
    required this.still,
    required this.color,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final VoiceWaveState state;
  final VoiceWaveMode mode;
  final bool still;
  final Color color;

  /// The smallest bar is a dot.
  static const double _dot = VoiceWave.barWidth;

  /// Thinking: how high the pulse rises in the middle (of the height).
  static const double _thinkFloor = 0.06;
  static const double _thinkRise = 0.12;

  @override
  void paint(Canvas canvas, Size size) {
    final bars = VoiceWave.barsFor(size.width);
    if (bars == 0) return;
    const step = VoiceWave.barWidth + VoiceWave.barGap;
    final mid = size.height / 2;
    final paint = Paint()..color = color;
    final moving =
        !still &&
        (mode == VoiceWaveMode.listening || mode == VoiceWaveMode.speaking);
    final samples = state._samples;
    final slide = moving ? state.slide : 0.0;
    for (var i = 0; i <= bars; i++) {
      final x = (i - slide) * step;
      if (x < 0 || x + VoiceWave.barWidth > size.width + 0.01) continue;
      final p = bars == 1 ? 0.5 : i / bars;
      final amount = switch (mode) {
        VoiceWaveMode.rest => 0.0,
        VoiceWaveMode.thinking => _thinking(p),
        VoiceWaveMode.listening ||
        VoiceWaveMode.speaking => still
            ? 0.12 + 0.3 * _bell(p, 0.28)
            : (i < samples.length ? samples[i] : 0.0),
      };
      final h = math.max(_dot, amount * size.height);
      // Older bars fade a little to the left, as the voice moves on.
      final fade = moving ? 0.35 + 0.65 * p : 0.8;
      paint.color = color.withValues(alpha: color.a * fade);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, mid - h / 2, VoiceWave.barWidth, h),
          const Radius.circular(VoiceWave.barWidth / 2),
        ),
        paint,
      );
    }
  }

  /// Almost flat, breathing in the middle; still with animations off.
  double _thinking(double p) {
    final breath =
        still ? 0.5 : 0.5 + 0.5 * math.sin(2 * math.pi * state.pulse);
    return _thinkFloor + _thinkRise * _bell(p, 0.18) * breath;
  }

  static double _bell(double p, double width) =>
      math.exp(-math.pow((p - 0.5) / width, 2));

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.mode != mode ||
      old.still != still ||
      old.color != color ||
      !identical(old.state, state);
}
