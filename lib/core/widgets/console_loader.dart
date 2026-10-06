import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

/// Sizes of [ConsoleLoader].
enum ConsoleLoaderSize {
  /// 16–20 dp, mark only: inline in rows and next to short text.
  small,

  /// 32 dp with an optional label: panels, sheets and list initial loads.
  medium,

  /// 64 dp with the label: full-screen loading states.
  large,
}

/// Colours a [ConsoleLoader] paints with, resolved from the active theme.
@immutable
class ConsoleLoaderColors {
  /// The "C" and its cursor.
  final Color mark;

  /// The "Cargando…" / "Loading…" label.
  final Color label;

  const ConsoleLoaderColors({required this.mark, required this.label});
}

/// The branded loading state: the Console "C" with a terminal cursor that
/// blinks while the app waits for content, plus a localized "Cargando…" /
/// "Loading…" label.
///
/// The mark is drawn with a [CustomPainter] from the logo's SVG geometry (no
/// image decode, crisp at any size). The cursor eases in and out on a
/// terminal-like rhythm ([blinkPhase] visible, [blinkPhase] hidden) and is the
/// only layer that repaints: the arc and the host sit behind their own repaint
/// boundaries. The timer runs at most at 30 fps and only notifies while the
/// opacity actually changes, so the plateaus of the blink produce no frames.
///
/// The loader is still (cursor visible) whenever animations should not run:
/// reduce motion, TickerMode off (a route covered by an opaque route, a muted
/// subtree) or the app not in the foreground. It announces itself as a loading
/// spinner with the localized label, even in the mark-only small size.
class ConsoleLoader extends StatefulWidget {
  /// Generic constructor; prefer [ConsoleLoader.small], [.medium], [.large].
  const ConsoleLoader({
    super.key,
    this.size = ConsoleLoaderSize.medium,
    this.showLabel,
    this.label,
    this.dimension,
    this.typing,
  });

  /// Mark only, 16–20 dp (default 18): for rows and inline states.
  const ConsoleLoader.small({super.key, this.label, this.dimension})
    : size = ConsoleLoaderSize.small,
      showLabel = false,
      typing = false;

  /// 32 dp mark with an optional label: for panels and sheets.
  const ConsoleLoader.medium({super.key, this.showLabel = false, this.label})
    : size = ConsoleLoaderSize.medium,
      dimension = null,
      typing = false;

  /// 64 dp mark with the label: for full-screen states. The C arc is typed in
  /// once when it appears (unless [typing] is false or motion is reduced).
  const ConsoleLoader.large({
    super.key,
    this.showLabel = true,
    this.label,
    this.typing = true,
  }) : size = ConsoleLoaderSize.large,
       dimension = null;

  final ConsoleLoaderSize size;

  /// Whether to show the text label under the mark. Defaults per size: no for
  /// small and medium, yes for large. The small size never shows it.
  final bool? showLabel;

  /// Text of the label and of the semantics announcement. Defaults to the
  /// localized "Cargando…" / "Loading…".
  final String? label;

  /// Small size only: the mark's side, clamped to 16–20 dp.
  final double? dimension;

  /// Large size only: type the C arc in once before the cursor blinks.
  final bool? typing;

  /// Key of the mark's repaint boundary (the square that holds the C).
  static const Key markKey = ValueKey('console-loader-mark');

  /// Each half of the blink: visible for this long, then hidden for as long.
  static const Duration blinkPhase = Duration(milliseconds: 530);

  /// Fade at each edge of the blink (eased, not a hard on/off).
  static const Duration blinkFade = Duration(milliseconds: 150);

  /// Timer step: 30 fps at most.
  static const Duration frameInterval = Duration(microseconds: 33334);

  /// Duration of the large size's one-shot typing of the arc.
  static const Duration typingDuration = Duration(milliseconds: 660);
  static const int _typingSteps = 12;

  static double markDimensionFor(ConsoleLoaderSize size, [double? asked]) =>
      switch (size) {
        ConsoleLoaderSize.small => (asked ?? 18).clamp(16, 20).toDouble(),
        ConsoleLoaderSize.medium => 32,
        ConsoleLoaderSize.large => 64,
      };

  /// Theme colours: the accent ink for the mark ([HermesThemeColors.accentText]
  /// is the accent itself in dark themes and the darkened, readable accent in
  /// light ones) and the muted secondary ink for the label.
  static ConsoleLoaderColors colorsFor(ThemeData theme) {
    final c = theme.hermes;
    return ConsoleLoaderColors(mark: c.accentText, label: c.textSecondary);
  }

  /// Cursor opacity at [elapsed] into the blink cycle.
  static double cursorOpacityAt(Duration elapsed) {
    final cycle = blinkPhase.inMicroseconds * 2;
    final t = elapsed.inMicroseconds % cycle;
    final phase = blinkPhase.inMicroseconds;
    final fade = blinkFade.inMicroseconds;
    if (t < phase - fade) return 1;
    if (t < phase) {
      return 1 - Curves.easeInOut.transform((t - (phase - fade)) / fade);
    }
    if (t < cycle - fade) return 0;
    return Curves.easeInOut.transform((t - (cycle - fade)) / fade);
  }

  // Debug hooks for tests (paint counters and the live state).
  static int _debugCursorPaints = 0;
  static int _debugArcPaints = 0;

  @visibleForTesting
  static int get debugCursorPaints => _debugCursorPaints;

  @visibleForTesting
  static int get debugArcPaints => _debugArcPaints;

  @visibleForTesting
  static void debugResetPaintCounters() {
    _debugCursorPaints = 0;
    _debugArcPaints = 0;
  }

  @visibleForTesting
  static double debugCursorOpacity(BuildContext loaderElement) =>
      ((loaderElement as StatefulElement).state as _ConsoleLoaderState)
          ._cursor
          .value;

  @visibleForTesting
  static double debugArcProgress(BuildContext loaderElement) =>
      ((loaderElement as StatefulElement).state as _ConsoleLoaderState)
          ._arc
          .value;

  @override
  State<ConsoleLoader> createState() => _ConsoleLoaderState();
}

class _ConsoleLoaderState extends State<ConsoleLoader>
    with WidgetsBindingObserver {
  final ValueNotifier<double> _cursor = ValueNotifier<double>(1);
  late final ValueNotifier<double> _arc = ValueNotifier<double>(
    _wantsTyping ? 1 / ConsoleLoader._typingSteps : 1,
  );
  Timer? _timer;
  Duration _elapsed = Duration.zero;
  Duration _typingElapsed = Duration.zero;
  bool _tickerEnabled = true;
  bool _reduceMotion = false;
  bool _appActive = true;

  bool get _wantsTyping =>
      widget.size == ConsoleLoaderSize.large && (widget.typing ?? true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _appActive = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(covariant ConsoleLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_wantsTyping) _arc.value = 1;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (active == _appActive) return;
    _appActive = active;
    _sync();
  }

  bool get _animating => !_reduceMotion && _tickerEnabled && _appActive;

  void _sync() {
    if (!_animating) {
      _timer?.cancel();
      _timer = null;
      // Still frame: the whole C and a solid cursor; the blink restarts from
      // "visible" when motion resumes.
      _arc.value = 1;
      _elapsed = Duration.zero;
      _cursor.value = 1;
      return;
    }
    _timer ??= Timer.periodic(ConsoleLoader.frameInterval, (_) => _tick());
  }

  void _tick() {
    if (!mounted) return;
    if (_arc.value < 1) {
      // Typing: the cursor stays solid while the C is written.
      _typingElapsed += ConsoleLoader.frameInterval;
      final step =
          (_typingElapsed.inMicroseconds *
                  ConsoleLoader._typingSteps /
                  ConsoleLoader.typingDuration.inMicroseconds)
              .floor() +
          1;
      _arc.value = math.min(1, step / ConsoleLoader._typingSteps);
      return;
    }
    _elapsed += ConsoleLoader.frameInterval;
    final next = ConsoleLoader.cursorOpacityAt(_elapsed);
    // Only notify on a visible change: the plateaus schedule no frames.
    if ((next - _cursor.value).abs() > 0.002) _cursor.value = next;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
    _cursor.dispose();
    _arc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = ConsoleLoader.colorsFor(theme);
    // Harnesses without the app's delegates still get a readable label.
    final label =
        widget.label ??
        Localizations.of<Strings>(context, Strings)?.commonLoading ??
        'Loading…';
    final dimension = ConsoleLoader.markDimensionFor(
      widget.size,
      widget.dimension,
    );
    final showLabel =
        widget.size != ConsoleLoaderSize.small &&
        (widget.showLabel ?? widget.size == ConsoleLoaderSize.large);

    Widget mark = RepaintBoundary(
      key: ConsoleLoader.markKey,
      child: SizedBox.square(
        dimension: dimension,
        child: CustomPaint(
          painter: _ArcPainter(progress: _arc, color: colors.mark),
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _CursorPainter(opacity: _cursor, color: colors.mark),
              size: Size.square(dimension),
            ),
          ),
        ),
      ),
    );

    Widget content = mark;
    if (showLabel) {
      final large = widget.size == ConsoleLoaderSize.large;
      final base = large
          ? theme.textTheme.bodyMedium
          : theme.textTheme.bodySmall;
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          mark,
          SizedBox(height: large ? 14 : 8),
          Text(
            label,
            textAlign: TextAlign.center,
            style: (base ?? const TextStyle()).copyWith(color: colors.label),
          ),
        ],
      );
    }

    return Semantics(
      container: true,
      role: SemanticsRole.loadingSpinner,
      label: label,
      child: ExcludeSemantics(child: content),
    );
  }
}

/// Logo geometry, in the units of the brand SVG's viewBox
/// (`118 158 680 684`): a 275-unit arc, 134 units thick, opening to the
/// right, plus the cursor bar.
abstract final class _MarkGeometry {
  static const double viewWidth = 680;
  static const double viewHeight = 684;
  static const Offset center = Offset(460 - 118, 500 - 158);
  static const double radius = 275;
  static const double stroke = 134;
  static const Rect cursor = Rect.fromLTWH(694 - 118, 398 - 158, 104, 204);

  /// Arc ends at (664.4, 316) and (664.4, 684): ±atan2(184, 204.4).
  static final double startAngle = -math.atan2(184, 204.4);
  static final double sweep = -(2 * math.pi + 2 * startAngle);

  /// Maps the viewBox into a square of side [side], centred.
  static void fit(Canvas canvas, Size size) {
    final scale = math.min(size.width / viewWidth, size.height / viewHeight);
    canvas.translate(
      (size.width - viewWidth * scale) / 2,
      (size.height - viewHeight * scale) / 2,
    );
    canvas.scale(scale);
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter({required this.progress, required this.color})
    : super(repaint: progress);

  final ValueListenable<double> progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    ConsoleLoader._debugArcPaints++;
    canvas.save();
    _MarkGeometry.fit(canvas, size);
    canvas.drawArc(
      Rect.fromCircle(
        center: _MarkGeometry.center,
        radius: _MarkGeometry.radius,
      ),
      _MarkGeometry.startAngle,
      _MarkGeometry.sweep * progress.value,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = _MarkGeometry.stroke
        ..strokeCap = StrokeCap.butt
        ..isAntiAlias = true,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ArcPainter old) =>
      old.color != color || old.progress != progress;
}

class _CursorPainter extends CustomPainter {
  _CursorPainter({required this.opacity, required this.color})
    : super(repaint: opacity);

  final ValueListenable<double> opacity;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    ConsoleLoader._debugCursorPaints++;
    final o = opacity.value.clamp(0.0, 1.0);
    if (o <= 0) return;
    canvas.save();
    _MarkGeometry.fit(canvas, size);
    canvas.drawRect(
      _MarkGeometry.cursor,
      Paint()..color = color.withValues(alpha: color.a * o),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CursorPainter old) =>
      old.color != color || old.opacity != opacity;
}
