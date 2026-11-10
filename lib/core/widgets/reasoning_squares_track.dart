import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../design/tokens.dart' show HermesType;
import '../theme/app_theme.dart';
import 'sheet_outline.dart';

/// Height of the squares track.
const double kReasoningSquaresHeight = 48;

/// Diameter of the round thumb.
const double kReasoningThumbDiameter = 34;

/// Frames of the blinking are throttled to about 30 per second.
const int _kFrameIntervalMs = 33;

/// The grid never has more cells than this, however wide the track is.
const int kReasoningSquaresMaxCells = 350;

/// Seconds a level change flashes the thumb.
const double _kFlashSeconds = 0.35;

/// Deterministic geometry of the squares grid and of which cells are on.
/// Pure: the painter and the tests share it.
@immutable
class ReasoningSquaresGrid {
  const ReasoningSquaresGrid._({
    required this.cols,
    required this.rows,
    required this.cellWidth,
    required this.cellHeight,
  });

  /// Cell side is `max(7, height / 6)`; a very wide track grows the cell so
  /// the grid stays within [kReasoningSquaresMaxCells].
  factory ReasoningSquaresGrid.fit(Size size) {
    var cell = math.max(7.0, size.height / 6);
    var cols = math.max(1, (size.width / cell).floor());
    var rows = math.max(1, (size.height / cell).floor());
    while (cols * rows > kReasoningSquaresMaxCells) {
      cell *= 1.1;
      cols = math.max(1, (size.width / cell).floor());
      rows = math.max(1, (size.height / cell).floor());
    }
    return ReasoningSquaresGrid._(
      cols: cols,
      rows: rows,
      cellWidth: size.width / cols,
      cellHeight: size.height / rows,
    );
  }

  final int cols;
  final int rows;
  final double cellWidth;
  final double cellHeight;

  int get cells => cols * rows;

  static int _mix(int seed) {
    var x = (seed * 2654435761) & 0xFFFFFFFF;
    x = ((x ^ (x >> 16)) * 0x45d9f3b) & 0xFFFFFFFF;
    x = ((x ^ (x >> 16)) * 0x45d9f3b) & 0xFFFFFFFF;
    return x ^ (x >> 16);
  }

  /// A stable number in [0, 1) for [cell] and [salt].
  static double unit(int cell, int salt) =>
      (_mix(cell * 8 + salt) & 0xFFFFFF) / 0x1000000;

  /// Density of lit cells at the level fraction [p].
  static double density(double p) => 0.10 + 0.80 * p;

  /// Share of dim cells left in the unlit part of the track.
  static const double dimDensity = 0.07;

  /// Whether [cell], centred at [x], is a lit square for [p] and a thumb at
  /// [thumbX]: denser near the start, sparser towards the thumb.
  bool isLit(int cell, double x, double p, double thumbX) {
    if (x > thumbX) return false;
    final t = thumbX <= 0 ? 0.0 : (x / thumbX).clamp(0.0, 1.0);
    final local = (density(p) * (1.25 - 0.5 * t)).clamp(0.0, 1.0);
    return unit(cell, 0) < local;
  }

  /// Whether [cell] is one of the few dim squares past the thumb.
  bool isDim(int cell) => unit(cell, 0) < dimDensity;

  /// Number of lit squares for level [p] and a thumb at [thumbX].
  int litCount(double p, double thumbX) {
    var n = 0;
    for (var i = 0; i < cells; i++) {
      final x = ((i % cols) + 0.5) * cellWidth;
      if (isLit(i, x, p, thumbX)) n++;
    }
    return n;
  }
}

/// Where the thumb sits for [fraction] in a track of [width] with [inset].
double reasoningThumbX(double width, double inset, double fraction) =>
    inset + (width - 2 * inset) * fraction;

/// Pulls a continuous [position] (in steps) towards the nearest step: flat
/// around each step, quick between two of them.
double reasoningMagnet(double position) {
  final nearest = position.roundToDouble();
  final d = position - nearest;
  return nearest + d.sign * 0.5 * math.pow(2 * d.abs(), 2);
}

/// Colour of the squares at level fraction [p]: the theme accent drifting in
/// hue towards its secondary colour and gaining lightness as [p] grows (on a
/// light palette it deepens instead, so it keeps reading on the pale track).
Color reasoningSquaresColor(HermesThemeColors colors, double p) {
  final from = HSLColor.fromColor(colors.accent);
  final to = HSLColor.fromColor(colors.secondary);
  var delta = to.hue - from.hue;
  if (delta > 180) delta -= 360;
  if (delta < -180) delta += 360;
  final hue = (from.hue + delta * 0.6 * p) % 360;
  final hover = HSLColor.fromColor(colors.accentHover).lightness;
  final lift = math.max(0.0, hover - from.lightness);
  final lightness = colors.isLightPalette
      ? from.lightness - 0.10 * p
      : from.lightness + (0.08 + lift * 0.5) * p;
  return from
      .withHue(hue < 0 ? hue + 360 : hue)
      .withLightness(lightness.clamp(0.0, 0.92))
      .toColor();
}

/// The track background: one tone darker than the sheet surface, or a paler,
/// more neutral one on a light palette.
Color reasoningSquaresBackground(HermesThemeColors colors) {
  final s = HSLColor.fromColor(colors.surface);
  if (colors.isLightPalette) {
    return s
        .withSaturation(s.saturation * 0.3)
        .withLightness(s.lightness + (1 - s.lightness) * 0.6)
        .toColor();
  }
  return s.withLightness(s.lightness * 0.4).toColor();
}

/// The track of the reasoning slider: a grid of small squares that light up
/// from the start to the thumb. One painter, one ticker (only while [animate]
/// and the route is visible), its own repaint boundary.
class ReasoningSquaresTrack extends StatefulWidget {
  const ReasoningSquaresTrack({
    required this.width,
    required this.level,
    required this.levels,
    required this.fraction,
    required this.inset,
    required this.hasThumb,
    required this.off,
    required this.enabled,
    required this.focused,
    required this.animate,
    super.key,
  });

  final double width;

  /// Shown level, or null when there is none.
  final int? level;
  final int levels;

  /// Thumb position along the usable track, 0..1.
  final double fraction;
  final double inset;
  final bool hasThumb;

  /// The level that means «no reasoning»: nothing is lit.
  final bool off;
  final bool enabled;
  final bool focused;

  /// False under reduce motion: a still picture, no ticker.
  final bool animate;

  @override
  State<ReasoningSquaresTrack> createState() => _ReasoningSquaresTrackState();
}

class _ReasoningSquaresTrackState extends State<ReasoningSquaresTrack>
    with SingleTickerProviderStateMixin {
  final _clock = ValueNotifier<double>(0);
  Ticker? _ticker;
  Duration _lastFrame = const Duration(milliseconds: -_kFrameIntervalMs);
  double _flashAt = -10;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(ReasoningSquaresTrack old) {
    super.didUpdateWidget(old);
    if (widget.animate && old.level != widget.level) {
      _flashAt = _clock.value;
    }
    _syncTicker();
  }

  void _syncTicker() {
    if (widget.animate) {
      _ticker ??= createTicker(_onTick);
      if (!_ticker!.isActive) _ticker!.start();
    } else if (_ticker != null) {
      _ticker!.stop();
      _lastFrame = const Duration(milliseconds: -_kFrameIntervalMs);
      _clock.value = 0;
      _flashAt = -10;
    }
  }

  void _onTick(Duration elapsed) {
    if ((elapsed - _lastFrame).inMilliseconds < _kFrameIntervalMs) return;
    _lastFrame = elapsed;
    _clock.value = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final level = widget.level;
    final p = level == null || widget.levels < 2
        ? 0.0
        : level / (widget.levels - 1);
    return RepaintBoundary(
      key: const ValueKey('model-picker-reasoning-squares'),
      child: CustomPaint(
        size: Size(widget.width, kReasoningSquaresHeight),
        painter: _SquaresPainter(
          clock: _clock,
          flashAt: _flashAt,
          animate: widget.animate,
          p: p,
          fraction: widget.fraction,
          inset: widget.inset,
          hasThumb: widget.hasThumb,
          lit: widget.hasThumb && !widget.off,
          enabled: widget.enabled,
          focused: widget.focused,
          background: reasoningSquaresBackground(colors),
          border: hermesSheetOutline(colors),
          squares: widget.enabled
              ? reasoningSquaresColor(colors, p)
              : colors.textTertiary,
          accent: colors.accent,
          thumb: colors.textPrimary,
        ),
      ),
    );
  }
}

class _SquaresPainter extends CustomPainter {
  _SquaresPainter({
    required this.clock,
    required this.flashAt,
    required this.animate,
    required this.p,
    required this.fraction,
    required this.inset,
    required this.hasThumb,
    required this.lit,
    required this.enabled,
    required this.focused,
    required this.background,
    required this.border,
    required this.squares,
    required this.accent,
    required this.thumb,
  }) : super(repaint: clock);

  final ValueNotifier<double> clock;
  final double flashAt;
  final bool animate;
  final double p;
  final double fraction;
  final double inset;
  final bool hasThumb;
  final bool lit;
  final bool enabled;
  final bool focused;
  final Color background;
  final Color border;
  final Color squares;
  final Color accent;
  final Color thumb;

  @override
  void paint(Canvas canvas, Size size) {
    final time = animate ? clock.value : 0.0;
    final box = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.height / 2),
    );
    canvas.drawRRect(box, Paint()..color = background);

    final grid = ReasoningSquaresGrid.fit(size);
    final thumbX = reasoningThumbX(size.width, inset, fraction);
    final speed = 0.4 + 2.4 * p;
    final floor = 0.18 + 0.32 * p;
    final strength = 0.15 + 0.50 * p;
    final fade = enabled ? 1.0 : 0.5;
    final paint = Paint();
    canvas.save();
    canvas.clipRRect(box);
    if (lit && thumbX > 0) {
      final fill = Rect.fromLTWH(0, 0, thumbX, size.height);
      canvas.drawRect(
        fill,
        Paint()
          ..shader = LinearGradient(
            colors: [
              squares.withValues(alpha: 0.04 * fade),
              squares.withValues(alpha: (0.10 + 0.18 * p) * fade),
            ],
          ).createShader(fill),
      );
    }
    for (var i = 0; i < grid.cells; i++) {
      final cx = ((i % grid.cols) + 0.5) * grid.cellWidth;
      final cy = ((i ~/ grid.cols) + 0.5) * grid.cellHeight;
      final isOn = lit && grid.isLit(i, cx, p, thumbX);
      if (!isOn && !grid.isDim(i)) continue;
      final phase = ReasoningSquaresGrid.unit(i, 1) * 2 * math.pi;
      final wave = 0.5 + 0.5 * math.sin(2 * math.pi * speed * time + phase);
      final alpha = isOn
          ? (floor + strength * wave).clamp(0.0, 1.0)
          : 0.08 + 0.07 * wave;
      final side =
          math.min(grid.cellWidth, grid.cellHeight) *
          (0.42 + 0.40 * ReasoningSquaresGrid.unit(i, 2));
      paint.color = squares.withValues(alpha: alpha * fade);
      canvas.drawRect(
        Rect.fromCenter(center: Offset(cx, cy), width: side, height: side),
        paint,
      );
    }
    canvas.restore();

    if (hasThumb) {
      final radius = kReasoningThumbDiameter / 2;
      final x = thumbX.clamp(radius, size.width - radius);
      final center = Offset(x, size.height / 2);
      final flash = animate
          ? (1 - (time - flashAt) / _kFlashSeconds).clamp(0.0, 1.0)
          : 0.0;
      if (lit) {
        final ball = enabled ? accent : squares;
        if (enabled) {
          canvas.drawCircle(
            center,
            radius + 3 + 3 * flash,
            Paint()
              ..color = accent.withValues(alpha: 0.35 + 0.35 * flash)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
          );
        }
        canvas.drawCircle(
          center,
          radius,
          Paint()
            ..shader = RadialGradient(
              center: const Alignment(-0.3, -0.4),
              colors: [Color.lerp(ball, thumb, 0.45)!, ball],
            ).createShader(Rect.fromCircle(center: center, radius: radius)),
        );
      } else {
        // Off or not adjustable: a hollow ball, no glow.
        canvas.drawCircle(center, radius, Paint()..color = background);
        canvas.drawCircle(
          center,
          radius - 1,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = thumb.withValues(alpha: enabled ? 0.55 : 0.3),
        );
      }
    }

    canvas.drawRRect(
      box,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = focused ? 2 : 1
        ..color = focused ? accent : border,
    );
  }

  @override
  bool shouldRepaint(_SquaresPainter old) =>
      old.flashAt != flashAt ||
      old.animate != animate ||
      old.p != p ||
      old.fraction != fraction ||
      old.inset != inset ||
      old.hasThumb != hasThumb ||
      old.lit != lit ||
      old.enabled != enabled ||
      old.focused != focused ||
      old.background != background ||
      old.border != border ||
      old.squares != squares ||
      old.accent != accent ||
      old.thumb != thumb;
}

/// Names of the real levels under the track, with a small mark above each
/// step; the active one in the accent colour and bold, with a longer mark.
///
/// When every name fits next to its neighbours (a wide sheet, short words)
/// all of them are written, each centred on its step. When they do not, the
/// marks stay and only three names are written: the first and the last level
/// at the ends and the active one under its step; an end name the active one
/// would touch gives way (the live level is also in the header). Names are
/// fitted down instead of overflowing, and never overlap.
class ReasoningLevelLabels extends StatelessWidget {
  const ReasoningLevelLabels({
    required this.labels,
    required this.active,
    required this.inset,
    required this.enabled,
    super.key,
  });

  final List<String> labels;
  final int? active;
  final double inset;
  final bool enabled;

  static const double _markHeight = 6;
  static const double _markGap = 3;

  /// Least room between two written names.
  static const double _gap = 6;

  double _centre(int i, int steps, double usable) =>
      inset + usable * i / math.max(1, steps - 1);

  /// The names to write and where: index -> (left, width). All of them when
  /// they fit; else the compact set.
  Map<int, (double, double)> _plan(
    double width,
    double Function(int, bool) measure,
  ) {
    final steps = labels.length;
    if (steps == 0) return const {};
    final usable = width - 2 * inset;
    (double, double) place(int i, double w) {
      final fitted = math.min(w, width);
      final left = (_centre(i, steps, usable) - fitted / 2)
          .clamp(0.0, math.max(0.0, width - fitted))
          .toDouble();
      return (left, fitted);
    }

    final all = <int, (double, double)>{
      for (var i = 0; i < steps; i++) i: place(i, measure(i, i == active)),
    };
    var fits = true;
    for (var i = 1; i < steps; i++) {
      final a = all[i - 1]!;
      final b = all[i]!;
      if (a.$1 + a.$2 + _gap > b.$1) fits = false;
    }
    if (fits) return all;

    final endMax = math.max(0.0, (width - _gap) / 2);
    final last = steps - 1;
    final plan = <int, (double, double)>{};
    final first = math.min(measure(0, active == 0), endMax);
    plan[0] = (0.0, first);
    if (last > 0) {
      final w = math.min(measure(last, active == last), endMax);
      plan[last] = (width - w, w);
    }
    final a = active;
    if (a != null && a > 0 && a < last) {
      final mine = place(a, measure(a, true));
      plan[a] = mine;
      plan.removeWhere((i, r) {
        if (i == a) return false;
        return mine.$1 < r.$1 + r.$2 + _gap && r.$1 < mine.$1 + mine.$2 + _gap;
      });
    }
    return plan;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final line = scaler.scale(HermesType.captionSize) * 1.4;
    final height = _markHeight + 2 + _markGap + line;
    TextStyle styleOf(bool on) => TextStyle(
      fontSize: HermesType.captionSize,
      fontWeight: on ? FontWeight.w700 : FontWeight.w400,
      color: on && enabled ? colors.accentText : colors.textSecondary,
    );
    double measure(int i, bool on) {
      final painter = TextPainter(
        text: TextSpan(text: labels[i], style: styleOf(on)),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final w = painter.width;
      painter.dispose();
      return w;
    }

    return ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final steps = labels.length;
          final usable = width - 2 * inset;
          final plan = _plan(width, measure);
          return SizedBox(
            height: height,
            width: width,
            child: Stack(
              children: [
                for (var i = 0; i < steps; i++)
                  Positioned(
                    left: _centre(i, steps, usable) - (i == active ? 1.0 : 0.5),
                    top: 0,
                    width: i == active ? 2 : 1,
                    height: i == active ? _markHeight + 2 : _markHeight,
                    child: Container(
                      key: i == active
                          ? const ValueKey('model-picker-reasoning-mark')
                          : null,
                      color: i == active && enabled
                          ? colors.accent
                          : hermesSheetOutline(colors),
                    ),
                  ),
                for (final entry in plan.entries)
                  Positioned(
                    left: entry.value.$1,
                    width: entry.value.$2,
                    top: _markHeight + 2 + _markGap,
                    bottom: 0,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        labels[entry.key],
                        maxLines: 1,
                        style: styleOf(entry.key == active),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
