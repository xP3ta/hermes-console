import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/animation.dart' show Cubic;

/// Numbers and pure geometry of the floating mascot, from the owner's
/// implementation guide (section 3). Kept free of widgets so every rule is
/// unit-tested on its own.
abstract final class MascotFloatPhysics {
  /// A press becomes a drag after this many logical pixels.
  static const double dragThreshold = 7;

  /// Dropped closer than this to a side edge, the mascot snaps to it...
  static const double edgeSnapDistance = 46;

  /// ...and rests this far from it.
  static const double edgeMargin = 6;

  /// Fall onto the dock: gravity (px/s²), bounce restitution, bounces.
  static const double gravity = 2600;
  static const double bounce = 0.34;
  static const int maxBounces = 3;

  /// A drop counts as "on the dock" when the mascot's bottom is within this
  /// many px above the dock's top (or lower) over its span; it then falls.
  static const double dropZone = 160;

  /// The mascot stands this far into the dock's top edge (`dockTop + 2`).
  static const double dockOverlap = 2;

  /// Without a dock it stands this far above the system inset.
  static const double noDockLift = 12;

  /// Wander: a decision every 2.6-6.4 s, walks up to ±180 px at 56 px/s
  /// (30 px/s while Hermes works), sleeps after 16 s without interaction.
  static const Duration minDecision = Duration(milliseconds: 2600);
  static const Duration maxDecision = Duration(milliseconds: 6400);
  static const double maxWander = 180;
  static const double idleSpeed = 56;
  static const double busySpeed = 30;
  static const Duration sleepAfter = Duration(seconds: 16);

  /// While a list scrolls: 28 % opacity and no hits for 700 ms.
  static const double scrollOpacity = 0.28;
  static const Duration scrollQuiet = Duration(milliseconds: 700);

  /// Stepping out of the dock's way when it reappears.
  static const Duration avoidDuration = Duration(milliseconds: 450);
  static const Cubic avoidCurve = Cubic(.3, 1.3, .5, 1);

  /// Motion frames (walk, fall, avoid, hop): one every 34 ms, ≤ 30 fps.
  static const Duration frame = Duration(milliseconds: 34);

  /// Size of the floating sprite box (guide: 56 x 60; the engine draws in a
  /// square box, so 56 dp).
  static const double spriteSize = 56;

  /// Bottom edge (global y) the mascot stands on in dock mode.
  static double baseline({
    required Rect? dock,
    required Size screen,
    required double bottomInset,
  }) => dock != null
      ? dock.top + dockOverlap
      : screen.height - bottomInset - noDockLift;

  /// Horizontal snap after a drop: within [edgeSnapDistance] of a side the
  /// mascot moves to [edgeMargin] from it; otherwise it stays, clamped on
  /// screen.
  static double snapLeft(double left, double width, double screenWidth) {
    final maxLeft = screenWidth - width - edgeMargin;
    if (left < edgeSnapDistance) return edgeMargin;
    if (screenWidth - (left + width) < edgeSnapDistance) return maxLeft;
    return left.clamp(edgeMargin, math.max(edgeMargin, maxLeft)).toDouble();
  }

  /// Vertical clamp of a floating mascot: on screen, below the status bar.
  static double clampTop(
    double top,
    double height,
    Size screen,
    double topInset,
  ) => top
      .clamp(topInset, math.max(topInset, screen.height - height))
      .toDouble();

  /// True when a mascot box dropped at [box] lands on the dock (or on the
  /// line while the dock is hidden): its centre is within the dock's
  /// horizontal span and its bottom is within [dropZone] above the dock's
  /// top, or lower.
  static bool landsOnDock(Rect box, Rect? dock) {
    if (dock == null) return false;
    final cx = box.center.dx;
    return cx >= dock.left &&
        cx <= dock.right &&
        box.bottom >= dock.top - dropZone;
  }

  /// When the dock (re)appears under a floating mascot, the top it should
  /// move to so it no longer overlaps; null when it is clear already.
  static double? avoidTop(Rect box, Rect? dock) {
    if (dock == null || !box.overlaps(dock)) return null;
    return dock.top + dockOverlap - box.height - 8;
  }

  /// Clamps a wander target to the strip above the dock (or the screen).
  static double wanderLeft({
    required double from,
    required double offset,
    required double width,
    required double minLeft,
    required double maxLeft,
  }) => (from + offset).clamp(minLeft, math.max(minLeft, maxLeft)).toDouble();

  /// Seconds a walk of [distance] px takes.
  static double walkSeconds(double distance, {required bool busy}) =>
      distance.abs() / (busy ? busySpeed : idleSpeed);
}

/// A fall onto a floor with gravity and up to [MascotFloatPhysics.maxBounces]
/// damped bounces, in closed form (no per-frame state): [topAt] gives the
/// box top at any time, [duration] when it rests.
final class MascotFall {
  MascotFall({required this.startTop, required this.floorTop})
    : assert(floorTop >= startTop) {
    const g = MascotFloatPhysics.gravity;
    final h = floorTop - startTop;
    var t = math.sqrt(2 * h / g);
    _impacts.add(t);
    var v = g * t;
    for (var i = 0; i < MascotFloatPhysics.maxBounces; i++) {
      v *= MascotFloatPhysics.bounce;
      if (v < 30) break; // Too small to see.
      _launch.add(v);
      t += 2 * v / g;
      _impacts.add(t);
    }
  }

  final double startTop;
  final double floorTop;
  final List<double> _impacts = <double>[];
  final List<double> _launch = <double>[];

  /// Number of bounces after the first impact.
  int get bounces => _launch.length;

  /// Seconds until the mascot rests on the floor.
  double get duration => _impacts.last;

  double topAt(double seconds) {
    const g = MascotFloatPhysics.gravity;
    if (seconds <= 0) return startTop;
    if (seconds < _impacts.first) {
      return startTop + 0.5 * g * seconds * seconds;
    }
    for (var i = 0; i < _launch.length; i++) {
      final from = _impacts[i];
      final to = _impacts[i + 1];
      if (seconds < to) {
        final s = seconds - from;
        final height = _launch[i] * s - 0.5 * g * s * s;
        return floorTop - height;
      }
    }
    return floorTop;
  }

  /// Highest point of each bounce (px above the floor).
  List<double> get bounceHeights => [
    for (final v in _launch) v * v / (2 * MascotFloatPhysics.gravity),
  ];
}

/// Small helper for tests and the overlay: the box of a mascot whose
/// bottom-left is at ([left], [bottom]).
Rect mascotBox(
  double left,
  double bottom, [
  double size = MascotFloatPhysics.spriteSize,
]) => Rect.fromLTWH(left, bottom - size, size, size);

/// Distance a pointer moved since it went down.
bool pastDragThreshold(Offset delta) =>
    delta.distance > MascotFloatPhysics.dragThreshold;
