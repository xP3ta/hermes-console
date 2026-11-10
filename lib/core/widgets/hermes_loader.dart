import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

/// Three dots in a triangle that spin and "breathe": the loading indicator
/// for screens, sections and sheets.
///
/// Based on the "three-body" loader by Gabriel (GitHub: dovatgabriel,
/// "tidy-walrus-92"), published on Uiverse.io under the MIT licence. This is a
/// re-implementation of its geometry and timings with a [CustomPainter] and a
/// single [AnimationController]; no CSS is copied. See THIRD_PARTY_NOTICES.md.
///
/// Geometry, as a fraction of [size]: every dot has a diameter of 0.30. The
/// whole mark turns once every [spinPeriod] (2.0 s, linear) and each dot
/// moves towards the centre of the triangle and shrinks to 0.65 of its size
/// and 0.8 of its opacity once every [wobblePeriod] (0.8 s, ease in-out),
/// the two lower dots slightly out of phase.
///
/// The colour defaults to the accent ink of the active theme
/// ([HermesThemeColors.accentText]). With "reduce motion" the mark is drawn as
/// a still frame and no frames are scheduled. It announces itself as a loading
/// spinner; [semanticLabel] defaults to the localized "Loading…".
class HermesLoader extends StatefulWidget {
  const HermesLoader({
    super.key,
    this.size = defaultSize,
    this.color,
    this.semanticLabel,
  });

  /// Side of the square the mark is laid out in, in dp.
  final double size;

  /// Colour of the dots; the theme accent ink when null.
  final Color? color;

  /// Text announced to screen readers; the localized "Loading…" when null.
  final String? semanticLabel;

  static const double defaultSize = 36;

  /// One turn of the whole mark.
  static const Duration spinPeriod = Duration(seconds: 2);

  /// One breath of every dot.
  static const Duration wobblePeriod = Duration(milliseconds: 800);

  /// Both periods fit a whole number of times in this one: the controller
  /// loops over it without a jump (2 turns, 5 breaths).
  static const Duration loopPeriod = Duration(seconds: 4);

  /// Key of the repaint boundary that holds the mark.
  static const Key markKey = ValueKey('hermes-loader-mark');

  /// Geometry of the three dots [seconds] into the animation, in the
  /// coordinate space of a [size] square, before the turn of the whole mark.
  /// Order: lower left, lower right, top.
  @visibleForTesting
  static List<HermesLoaderDot> dotsAt(double size, double seconds) {
    final speed = wobblePeriod.inMicroseconds / Duration.microsecondsPerSecond;
    final d = size * 0.3;
    final r = d / 2;
    final origin = size * 0.8;

    // Wobble progress 0..1..0 with ease in-out on each half. A negative CSS
    // delay means the animation is already that far along.
    double breath(double delayFraction) {
      final phase = ((seconds / speed) + delayFraction) % 1.0;
      final half = phase < 0.5 ? phase * 2 : 2 - phase * 2;
      return Curves.easeInOut.transform(half);
    }

    HermesLoaderDot lower({
      required double columnX,
      required double angle,
      required double delayFraction,
    }) {
      final m = breath(delayFraction);
      // The dot sits at the pivot of its column, which turns +-60 degrees:
      // its own "up" is the direction towards the middle of the triangle.
      final pivot = Offset(columnX + size * 0.15, origin);
      final lift = Offset(0, -0.66 * d * m);
      final c = pivot + _rotate(lift, angle);
      return HermesLoaderDot(c, r * (1 - 0.35 * m), 1 - 0.2 * m);
    }

    final top = breath(0);
    return [
      lower(columnX: 0, angle: math.pi / 3, delayFraction: 0.3),
      lower(columnX: size * 0.7, angle: -math.pi / 3, delayFraction: 0.15),
      HermesLoaderDot(
        Offset(size * 0.5, size * 0.05 + r + 0.66 * d * top),
        r * (1 - 0.35 * top),
        1 - 0.2 * top,
      ),
    ];
  }

  static Offset _rotate(Offset v, double a) => Offset(
    v.dx * math.cos(a) - v.dy * math.sin(a),
    v.dx * math.sin(a) + v.dy * math.cos(a),
  );

  @override
  State<HermesLoader> createState() => _HermesLoaderState();
}

/// One dot of the [HermesLoader]: centre, radius and opacity.
@immutable
class HermesLoaderDot {
  const HermesLoaderDot(this.center, this.radius, this.opacity);

  final Offset center;
  final double radius;
  final double opacity;
}

class _HermesLoaderState extends State<HermesLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: HermesLoader.loopPeriod,
  );
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_reduceMotion) {
      _controller.stop();
      _controller.value = 0;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).hermes.accentText;
    final label =
        widget.semanticLabel ??
        Localizations.of<Strings>(context, Strings)?.commonLoading ??
        'Loading…';
    return Semantics(
      container: true,
      role: SemanticsRole.loadingSpinner,
      label: label,
      child: ExcludeSemantics(
        child: RepaintBoundary(
          key: HermesLoader.markKey,
          child: SizedBox.square(
            dimension: widget.size,
            child: CustomPaint(
              painter: _ThreeBodyPainter(animation: _controller, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

class _ThreeBodyPainter extends CustomPainter {
  _ThreeBodyPainter({required this.animation, required this.color})
    : super(repaint: animation);

  final Animation<double> animation;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    final seconds =
        animation.value *
        HermesLoader.loopPeriod.inMicroseconds /
        Duration.microsecondsPerSecond;
    final spinSeconds =
        HermesLoader.spinPeriod.inMicroseconds / Duration.microsecondsPerSecond;
    final spin = 2 * math.pi * ((seconds % spinSeconds) / spinSeconds);
    canvas.save();
    canvas.translate(
      (size.width - side) / 2 + side / 2,
      (size.height - side) / 2 + side / 2,
    );
    canvas.rotate(spin);
    canvas.translate(-side / 2, -side / 2);
    for (final dot in HermesLoader.dotsAt(side, seconds)) {
      canvas.drawCircle(
        dot.center,
        dot.radius,
        Paint()
          ..color = color.withValues(alpha: color.a * dot.opacity)
          ..isAntiAlias = true,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ThreeBodyPainter old) =>
      old.color != color || old.animation != animation;
}
