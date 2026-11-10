import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/hermes_tokens.dart';
import 'chat_live_icon.dart';

// The marks of the live turn (the header capsule and the transcript's
// timeline): ONE clock of seconds drives every one of them, and each paints
// from it without rebuilding its row. With motion reduced the clock is null
// and every mark is a still state.

/// Seconds the clock covers before it repeats: the least common multiple of
/// the ring (0.8 s a turn), a 1.6 s beat and the sheen (2.2 s).
const double kLiveClockPeriod = 17.6;

const double _spinSeconds = 0.8;
const double _sheenSeconds = 2.2;

/// A mark of one step of the timeline.
enum LiveMarkState { queued, running, ok, failed }

/// The ring that says a step waits (faint) or runs (an accent arc turning
/// once every 0.8 s).
class LiveRing extends StatelessWidget {
  const LiveRing({
    required this.running,
    required this.seconds,
    this.size = HermesIcon.sm,
    this.color,
    super.key,
  });

  final bool running;
  final Animation<double>? seconds;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.square(size),
        painter: _RingPainter(
          track: HermesChrome.of(colors).line,
          arc: running ? (color ?? colors.accent) : null,
          seconds: running ? seconds : null,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.track, required this.arc, this.seconds})
    : super(repaint: seconds);

  final Color track;
  final Color? arc;
  final Animation<double>? seconds;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide * 0.14;
    final rect = (Offset.zero & size).deflate(stroke / 2 + 1);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = track;
    canvas.drawOval(rect, paint);
    final color = arc;
    if (color == null) return;
    final turns = seconds == null ? 0.0 : seconds!.value / _spinSeconds;
    paint.color = color;
    canvas.drawArc(
      rect,
      turns * 2 * math.pi - math.pi / 2,
      math.pi * 0.78,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.track != track || old.arc != arc || old.seconds != seconds;
}

/// A step that ended, in the chat's icon family: the outline check in the
/// quiet ink, or the outline error sign in the error ink. Never a filled
/// badge: the timeline's marks are all one outline family, one size and one
/// neutral ink; only a failure takes a colour.
class LiveResultMark extends StatelessWidget {
  const LiveResultMark({
    required this.ok,
    this.size = HermesIcon.sm,
    super.key,
  });

  final bool ok;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return ChatLiveIcon(
      ok ? ChatLiveGlyph.check : ChatLiveGlyph.error,
      size: size,
      color: ok ? colors.textSecondary : colors.error,
    );
  }
}

/// The mark of one timeline step by its state. A settled step shows what it
/// was ([glyph]: the terminal for a command, the wrench for another tool),
/// in the quiet ink; a failed one the outline error sign in the error ink; a
/// running one the thin ring, turning in the same quiet ink. Without a
/// [glyph] a settled step shows the outline check.
class LiveStepMark extends StatelessWidget {
  const LiveStepMark({
    required this.state,
    required this.seconds,
    this.glyph,
    this.size = HermesIcon.sm,
    super.key,
  });

  final LiveMarkState state;
  final Animation<double>? seconds;
  final ChatLiveGlyph? glyph;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final kind = glyph;
    return switch (state) {
      LiveMarkState.queued => LiveRing(
        running: false,
        seconds: seconds,
        size: size,
      ),
      LiveMarkState.running => LiveRing(
        running: true,
        seconds: seconds,
        size: size,
        color: colors.textSecondary,
      ),
      LiveMarkState.ok when kind != null => ChatLiveIcon(
        kind,
        size: size,
        color: colors.textSecondary,
      ),
      LiveMarkState.ok => LiveResultMark(ok: true, size: size),
      LiveMarkState.failed => LiveResultMark(ok: false, size: size),
    };
  }
}

/// The thought's mark: the chat's reasoning glyph in the quiet ink, playing
/// while it thinks ([seconds] set), still once it has thought ([quiet]).
class LiveBrain extends StatelessWidget {
  const LiveBrain({
    required this.seconds,
    this.quiet = false,
    this.size = HermesIcon.sm,
    super.key,
  });

  final Animation<double>? seconds;
  final bool quiet;
  final double size;

  @override
  Widget build(BuildContext context) => ChatLiveIcon(
    ChatLiveGlyph.reasoning,
    live: !quiet && seconds != null,
    size: size,
    color: Theme.of(context).hermes.textSecondary,
  );
}

/// A word with a sheen that runs over its letters; still without a clock.
class LiveSheen extends StatelessWidget {
  const LiveSheen({
    required this.seconds,
    required this.base,
    required this.peak,
    required this.child,
    super.key,
  });

  final Animation<double>? seconds;
  final Color base;
  final Color peak;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final clock = seconds;
    if (clock == null) return child;
    return AnimatedBuilder(
      animation: clock,
      child: child,
      builder: (context, child) {
        final slide = (clock.value / _sheenSeconds % 1) * 2 - 1;
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) => LinearGradient(
            colors: [base, peak, base],
            stops: const [0.35, 0.5, 0.65],
            transform: _Slide(slide),
          ).createShader(bounds),
          child: child,
        );
      },
    );
  }
}

/// Slides a gradient sideways by [fraction] of the box's width.
class _Slide extends GradientTransform {
  const _Slide(this.fraction);
  final double fraction;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * fraction, 0, 0);
}

/// Drives a [seconds] clock for a surface that may run it: repeating on its
/// own (the transcript), and only while [active] and motion is not reduced.
/// The controller is stopped otherwise, so a settled turn never ticks.
mixin LiveClockMixin<T extends StatefulWidget> on State<T>, TickerProvider {
  AnimationController? _clockController;
  Animation<double>? _seconds;

  /// The shared clock, or null when nothing should move.
  Animation<double>? get liveSeconds => _seconds;

  void syncLiveClock({required bool active}) {
    final run = active && !HermesMotion.reduced(context);
    if (run) {
      final controller = _clockController ??= AnimationController(
        vsync: this,
        duration: Duration(milliseconds: (kLiveClockPeriod * 1000).round()),
      );
      _seconds ??= controller.drive(
        Tween<double>(begin: 0, end: kLiveClockPeriod),
      );
      if (!controller.isAnimating) controller.repeat();
    } else {
      _clockController?.stop();
      _seconds = null;
    }
  }

  void disposeLiveClock() => _clockController?.dispose();
}
