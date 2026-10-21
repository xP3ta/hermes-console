import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../widgets/frosted_backdrop.dart' show FrostedBackdropPolicy;
import '../../theme/motion.dart' show CoveredRouteMediaQueryFreeze;
import 'halloween.dart';

/// Motion for the first-run flow: the logo that draws itself, the light
/// behind it, the scanner frame, the verifying ring and the check. Every
/// piece is a [CustomPainter] or a transform over a single controller, so a
/// frame costs a few paths and no off-screen layer.
abstract final class OnboardingMotion {
  /// The opening plays once per process; coming back to the welcome shows
  /// its end state.
  static bool openingPlayed = false;

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// Battery saver and low-RAM devices: no motes, a shorter opening.
  static bool get lowPower => FrostedBackdropPolicy.reducedPerformance.value;

  /// How long the ambient light and motes run while a screen sits.
  static const Duration ambientSpan = Duration(minutes: 2);
}

double ivl(double t, double begin, double end, [Curve curve = Curves.linear]) {
  if (t <= begin) return 0;
  if (t >= end) return 1;
  return curve.transform((t - begin) / (end - begin));
}

// ── The mark ─────────────────────────────────────────────────────────────
//
// Geometry of assets/branding/console_mark.svg, read from its own path data:
//   <path d="M664.4,316.0 A275,275 0 1,0 664.4,684.0" stroke-width="134"/>
//   <rect x="694" y="398" width="104" height="204"/>
// test/onboarding_motion_test.dart pins these numbers to the asset's text.
const Rect kMarkViewBox = Rect.fromLTWH(118, 158, 680, 684);
const Offset kMarkArcStart = Offset(664.4, 316.0);
const Offset kMarkArcEnd = Offset(664.4, 684.0);
const double kMarkArcRadius = 275;
const double kMarkStroke = 134;
const Rect kMarkBar = Rect.fromLTWH(694, 398, 104, 204);

/// The brand colour of the mark: the same on every theme, never re-tinted.
const Color kMarkColor = Color(0xFFD97757);

final Path _arcPath = Path()
  ..moveTo(kMarkArcStart.dx, kMarkArcStart.dy)
  ..arcToPoint(
    kMarkArcEnd,
    radius: const Radius.circular(kMarkArcRadius),
    largeArc: true,
    clockwise: false,
  );
final ui.PathMetric _arcMetric = _arcPath.computeMetrics().first;

/// Paints the Console mark. [arc] and [bar] reveal it (1 is complete);
/// [glint] sweeps a narrow highlight across it (null or outside 0..1: none).
class ConsoleMarkPainter extends CustomPainter {
  ConsoleMarkPainter({
    this.arc = 1,
    this.bar = 1,
    this.glint,
    this.season = Season.none,
    this.ambient,
  }) : super(repaint: ambient);
  final double arc;
  final double bar;
  final double? glint;
  final Season season;

  /// Drives the flicker / nose pulse of a seasonal mark; still when idle.
  final Animation<double>? ambient;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(
      size.width / kMarkViewBox.width,
      size.height / kMarkViewBox.height,
    );
    canvas
      ..translate(
        (size.width - kMarkViewBox.width * scale) / 2,
        (size.height - kMarkViewBox.height * scale) / 2,
      )
      ..scale(scale)
      ..translate(-kMarkViewBox.left, -kMarkViewBox.top);
    final shown = _arcMetric.extractPath(0, _arcMetric.length * arc);
    if (season != Season.none) {
      paintSeasonMark(canvas, season, shown, arc, bar, ambientSeconds(ambient));
      return;
    }
    final fill = Paint()
      ..color = kMarkColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = kMarkStroke;
    if (arc > 0) canvas.drawPath(shown, fill);
    final barRect = Rect.fromCenter(
      center: kMarkBar.center,
      width: kMarkBar.width,
      height: kMarkBar.height * bar,
    );
    if (bar > 0) {
      canvas.drawRect(
        barRect,
        Paint()..color = kMarkColor.withValues(alpha: bar.clamp(0.0, 1.0)),
      );
    }
    final g = glint;
    if (g != null && g > -0.3 && g < 1.3) {
      final shader = ui.Gradient.linear(
        Offset(kMarkViewBox.left + kMarkViewBox.width * (g - 0.16), 0),
        Offset(
          kMarkViewBox.left + kMarkViewBox.width * (g + 0.16),
          kMarkViewBox.height * 0.3,
        ),
        const [
          Color(0x00FFFFFF),
          Color(0x00FFFFFF),
          Color(0x8CFFFFFF),
          Color(0x00FFFFFF),
          Color(0x00FFFFFF),
        ],
        const [0, 0.3, 0.5, 0.7, 1],
      );
      final shine = Paint()..shader = shader;
      canvas.drawPath(
        shown,
        shine
          ..style = PaintingStyle.stroke
          ..strokeWidth = kMarkStroke,
      );
      if (bar > 0) canvas.drawRect(barRect, shine..style = PaintingStyle.fill);
    }
  }

  @override
  bool shouldRepaint(ConsoleMarkPainter old) =>
      old.arc != arc ||
      old.bar != bar ||
      old.glint != glint ||
      old.season != season;
}

/// The mark at rest, or part-way through its drawing.
class ConsoleMark extends StatelessWidget {
  const ConsoleMark({
    required this.size,
    this.arc = 1,
    this.bar = 1,
    this.glint,
    this.season = Season.none,
    this.ambient,
    super.key,
  });
  final double size;
  final double arc;
  final double bar;
  final double? glint;
  final Season season;
  final Animation<double>? ambient;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      key: const ValueKey('console-mark'),
      size: Size.square(size),
      painter: ConsoleMarkPainter(
        arc: arc,
        bar: bar,
        glint: glint,
        season: season,
        ambient: ambient,
      ),
    ),
  );
}

// ── Light and motes ──────────────────────────────────────────────────────

/// The soft radial light behind the hero.
class GlowPainter extends CustomPainter {
  GlowPainter({
    required this.center,
    required this.radius,
    required this.color,
    required this.strength,
    this.peak = 0.22,
    super.repaint,
  });
  final double peak;
  final Offset Function() center;
  final double Function() radius;
  final Color color;
  final double Function() strength;

  @override
  void paint(Canvas canvas, Size size) {
    final a = strength();
    final r = radius();
    if (a <= 0 || r <= 0) return;
    final c = center();
    final shader = ui.Gradient.radial(
      c,
      r,
      [
        color.withValues(alpha: peak * a),
        color.withValues(alpha: 0.05 * a),
        color.withValues(alpha: 0),
      ],
      const [0, 0.62, 1],
    );
    canvas.drawCircle(c, r, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(GlowPainter old) =>
      old.color != color || old.center != center || old.peak != peak;
}

/// A dozen faint motes drifting upward at their own speeds.
class MotesPainter extends CustomPainter {
  MotesPainter({
    required this.t,
    required this.color,
    required this.strength,
    this.count = 14,
    super.repaint,
  });
  final double Function() t;
  final Color color;
  final double Function() strength;
  final int count;

  @override
  void paint(Canvas canvas, Size size) {
    final s = strength();
    if (s <= 0) return;
    final time = t();
    final paint = Paint();
    for (var i = 0; i < count; i++) {
      final rnd = math.Random(i * 7919 + 13);
      final speed = 1 + rnd.nextInt(3);
      final phase = rnd.nextDouble();
      final x0 = rnd.nextDouble();
      final radius = 1.2 + rnd.nextDouble() * 2.2;
      final alpha = 0.18 + rnd.nextDouble() * 0.3;
      final life = (time * speed + phase) % 1;
      final y = size.height * (1.02 - life * 1.04);
      final x = size.width * x0 + math.sin((life + phase) * math.pi * 2) * 14;
      final fade = math.sin(life * math.pi);
      paint.color = color.withValues(alpha: alpha * fade * s);
      canvas.drawCircle(Offset(x, y), radius, paint);
    }
  }

  @override
  bool shouldRepaint(MotesPainter old) => old.color != color;
}

/// A burst of motes spraying out of a point, once.
class BurstPainter extends CustomPainter {
  BurstPainter({
    required this.t,
    required this.center,
    required this.color,
    required this.radius,
    super.repaint,
  });
  final double Function() t;
  final Offset Function() center;
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final time = t();
    if (time <= 0 || time >= 1) return;
    final c = center();
    final eased = Curves.easeOutCubic.transform(time);
    final paint = Paint();
    for (var i = 0; i < 26; i++) {
      final rnd = math.Random(i * 104729 + 5);
      final angle = rnd.nextDouble() * math.pi * 2;
      final reach = radius * (0.9 + rnd.nextDouble() * 1.7);
      final dot = 1.4 + rnd.nextDouble() * 2.4;
      paint.color = color.withValues(alpha: (1 - time) * 0.85);
      canvas.drawCircle(
        c + Offset(math.cos(angle), math.sin(angle)) * (reach * eased),
        dot * (1 - time * 0.5),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(BurstPainter old) => old.color != color;
}

/// A ring of light that expands from a point and fades.
class PulseRingPainter extends CustomPainter {
  PulseRingPainter({
    required this.t,
    required this.center,
    required this.color,
    required this.from,
    required this.to,
    super.repaint,
  });
  final double Function() t;
  final Offset Function() center;
  final Color color;
  final double from;
  final double to;

  @override
  void paint(Canvas canvas, Size size) {
    final time = t();
    if (time <= 0 || time >= 1) return;
    final e = Curves.easeOutCubic.transform(time);
    canvas.drawCircle(
      center(),
      ui.lerpDouble(from, to, e)!,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3 * (1 - time) + 0.5
        ..color = color.withValues(alpha: 0.7 * (1 - time)),
    );
  }

  @override
  bool shouldRepaint(PulseRingPainter old) => old.color != color;
}

// ── Scanner frame ────────────────────────────────────────────────────────

/// Four corner brackets and a scan line. [fly] brings the corners in from the
/// screen's corners (0 is far, 1 is locked); [lock] closes them onto the code;
/// [line] is the phase of the travelling scan line.
class ScanFramePainter extends CustomPainter {
  ScanFramePainter({
    required this.color,
    required this.fly,
    required this.lock,
    required this.line,
    required this.screen,
    required this.pulse,
    super.repaint,
  });
  final Color color;
  final double Function() fly;
  final double Function() lock;
  final double Function() line;
  final Size screen;
  final double Function() pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final f = Curves.easeOutBack.transform(fly().clamp(0.0, 1.0));
    final l = Curves.easeInCubic.transform(lock().clamp(0.0, 1.0));
    final inset = ui.lerpDouble(0, size.width * 0.06, l)!;
    final frame = Rect.fromLTWH(0, 0, size.width, size.height).deflate(inset);
    final arm = size.width * 0.21;
    final radius = size.width * 0.12;
    final breath = 1 + 0.015 * math.sin(pulse() * math.pi * 2);
    final paint = Paint()
      ..color = color.withValues(alpha: fly().clamp(0.0, 1.0))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    // Each corner's far position is the matching corner of the screen.
    final centre = size.center(Offset.zero);
    Offset far(Offset corner) {
      final sx = corner.dx < centre.dx ? -1.0 : 1.0;
      final sy = corner.dy < centre.dy ? -1.0 : 1.0;
      return Offset(
        centre.dx + sx * screen.width * 0.62,
        centre.dy + sy * screen.height * 0.6,
      );
    }

    void bracket(Offset corner, double dx, double dy) {
      final target = centre + (corner - centre) * breath;
      final at = Offset.lerp(far(corner), target, f)!;
      final p = Path()
        ..moveTo(at.dx, at.dy + dy * arm)
        ..lineTo(at.dx, at.dy + dy * radius)
        ..quadraticBezierTo(at.dx, at.dy, at.dx + dx * radius, at.dy)
        ..lineTo(at.dx + dx * arm, at.dy);
      canvas.drawPath(p, paint);
    }

    bracket(frame.topLeft, 1, 1);
    bracket(frame.topRight, -1, 1);
    bracket(frame.bottomLeft, 1, -1);
    bracket(frame.bottomRight, -1, -1);
    // The scan line travels down and up inside the frame.
    final phase = line();
    final travel = phase < 0.5 ? phase * 2 : (1 - phase) * 2;
    final y = frame.top + frame.height * (0.12 + 0.76 * travel);
    final lineAlpha = fly() >= 1 && l == 0 ? 0.55 : 0.0;
    if (lineAlpha > 0) {
      canvas.drawLine(
        Offset(frame.left + arm * 0.5, y),
        Offset(frame.right - arm * 0.5, y),
        Paint()
          ..color = color.withValues(alpha: lineAlpha)
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(ScanFramePainter old) => old.color != color;
}

// ── Verifying ring and check ─────────────────────────────────────────────

class ProgressRingPainter extends CustomPainter {
  const ProgressRingPainter({
    required this.progress,
    required this.color,
    required this.track,
    this.width = 6,
  });
  final double progress;
  final Color color;
  final Color track;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(width / 2);
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = track,
    );
    if (progress <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * progress.clamp(0.0, 1.0),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(ProgressRingPainter old) =>
      old.progress != progress || old.color != color || old.track != track;
}

/// A check mark whose stroke is drawn up to [progress].
class CheckPainter extends CustomPainter {
  const CheckPainter({
    required this.progress,
    required this.color,
    this.width = 3,
  });
  final double progress;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final path = Path()
      ..moveTo(size.width * 0.22, size.height * 0.53)
      ..lineTo(size.width * 0.43, size.height * 0.72)
      ..lineTo(size.width * 0.78, size.height * 0.31);
    final metric = path.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * progress.clamp(0.0, 1.0)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(CheckPainter old) =>
      old.progress != progress || old.color != color;
}

/// A check that draws itself when it first appears.
class DrawnCheck extends StatefulWidget {
  const DrawnCheck({
    required this.size,
    required this.color,
    this.width = 3,
    this.duration = const Duration(milliseconds: 420),
    super.key,
  });
  final double size;
  final Color color;
  final double width;
  final Duration duration;

  @override
  State<DrawnCheck> createState() => _DrawnCheckState();
}

class _DrawnCheckState extends State<DrawnCheck>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (OnboardingMotion.reduced(context)) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.size,
    child: AnimatedBuilder(
      animation: _c,
      builder: (_, _) => CustomPaint(
        painter: CheckPainter(
          progress: Curves.easeOutCubic.transform(_c.value),
          color: widget.color,
          width: widget.width,
        ),
      ),
    ),
  );
}

// ── Entrances ────────────────────────────────────────────────────────────

/// Rises 12 dp and fades in after [delay]; plays once, when first built. No
/// timer: the delay is the head of the controller's own span.
class RiseIn extends StatefulWidget {
  const RiseIn({
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 420),
    super.key,
  });
  final Widget child;
  final Duration delay;
  final Duration duration;

  @override
  State<RiseIn> createState() => _RiseInState();
}

class _RiseInState extends State<RiseIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.delay + widget.duration,
  );
  late final Animation<double> _a = CurvedAnimation(
    parent: _c,
    curve: Interval(
      widget.delay.inMicroseconds /
          (widget.delay + widget.duration).inMicroseconds,
      1,
      curve: Curves.easeOutCubic,
    ),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (OnboardingMotion.reduced(context)) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _a,
    child: widget.child,
    builder: (_, child) => Opacity(
      opacity: _a.value,
      child: Transform.translate(
        offset: Offset(0, 12 * (1 - _a.value)),
        child: child,
      ),
    ),
  );
}

/// Scales in from 0.6 with a soft overshoot after [delay].
class PopIn extends StatefulWidget {
  const PopIn({required this.child, this.delay = Duration.zero, super.key});
  final Widget child;
  final Duration delay;

  @override
  State<PopIn> createState() => _PopInState();
}

class _PopInState extends State<PopIn> with SingleTickerProviderStateMixin {
  static const _span = Duration(milliseconds: 380);
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.delay + _span,
  );
  late final Animation<double> _a = CurvedAnimation(
    parent: _c,
    curve: Interval(
      widget.delay.inMicroseconds / (widget.delay + _span).inMicroseconds,
      1,
      curve: Curves.easeOutBack,
    ),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (OnboardingMotion.reduced(context)) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _a,
    child: widget.child,
    builder: (_, child) => Opacity(
      opacity: _a.value.clamp(0.0, 1.0),
      child: Transform.scale(scale: 0.6 + 0.4 * _a.value, child: child),
    ),
  );
}

/// The route to «Connect by hand»: the same fade and 1.04 -> 1 scale as the
/// onboarding's own steps, and the page below stays still.
class OnbRoute<T> extends PageRouteBuilder<T> {
  OnbRoute({required WidgetBuilder builder})
    : super(
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (context, _, _) =>
            CoveredRouteMediaQueryFreeze(child: builder(context)),
        transitionsBuilder: (context, animation, _, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          final fade = FadeTransition(opacity: curved, child: child);
          if (OnboardingMotion.reduced(context)) return fade;
          return ScaleTransition(
            scale: Tween<double>(begin: 1.04, end: 1).animate(curved),
            child: fade,
          );
        },
      );

  @override
  bool canTransitionFrom(TransitionRoute<dynamic> _) => false;
}
