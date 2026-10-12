import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/animation.dart' show Cubic, Curves;
import 'package:flutter/painting.dart' show EdgeInsets;

/// Numbers and pure geometry of the floating mascot. Kept free of widgets so
/// every rule is unit-tested on its own.
///
/// The mascot has two ways of living on a screen:
///
/// * **on the dock** (default): standing on the dock's top edge at its right
///   end, or wherever along the edge the user dropped it. With no dock on
///   the screen (hidden by hand, switched off, a page without one) it keeps
///   that corner, above the system inset, with nothing drawn under it;
/// * **free**: exactly where the user dropped it, kept inside the safe area.
///
/// Nothing here moves the mascot by itself: no wander, no edge snap, no
/// throw. A drop only settles (a short glide) when it has to be pulled into
/// the safe area or onto the dock's edge. The one journey it makes is the
/// one it is asked for, "Volver al dock": a free fall to its place.
abstract final class MascotFloatPhysics {
  /// A press becomes a drag after this many logical pixels.
  static const double dragThreshold = 7;

  /// A finger resting this long on the mascot opens its menu.
  static const Duration longPress = Duration(milliseconds: 480);

  /// Side of the sprite box at 100 % (the pet's own size setting scales it).
  static const double baseSize = 48;

  /// The mascot stands this far into the dock's top edge.
  static const double dockOverlap = 2;

  /// Gap between the mascot's box and the dock's right end: far enough in
  /// for a wide pet's feet to land where the bar's rounded corner is nearly
  /// flat, close enough to read as "the end of the dock".
  static const double dockEndInset = 8;

  /// Without a dock: the box keeps this far from the screen's right side,
  /// the same column it has on the dock (the bar's 14 px side margin plus
  /// [dockEndInset])...
  static const double cornerInset = 22;

  /// ...and its feet stand this far above the system inset.
  static const double cornerLift = 12;

  /// Free placement: at least this far from the screen sides.
  static const double edgeMargin = 8;

  /// A free mascot keeps this far above the dock.
  static const double floatGap = 8;

  /// A drop counts as "on the dock" when the mascot's feet are within this
  /// many px above the dock's top edge, or lower, over its span.
  static const double dropZone = 18;

  /// Settling after a drop, a screen change or "Volver al dock".
  static const Duration settle = Duration(milliseconds: 180);
  static const Cubic settleCurve = Curves.easeOutCubic;

  /// "Volver al dock" is a free fall, with the numbers of Hermes Desktop's
  /// pet (`apps/desktop/src/components/pet/use-pet-roam.ts`): it drops
  /// straight down from rest at [fallGravity] px/s², no step longer than
  /// [fallMaxStep] seconds, and lands flush: no bounce, no squash.
  static const double fallGravity = 5200;
  static const double fallMaxStep = 0.05;

  /// Up to a resting place above it (Desktop's spring onto a higher ledge):
  /// this long, easing out.
  static const Duration rise = Duration(milliseconds: 460);

  /// Landed beside its place, it slides along the edge to it at
  /// [slideSpeed] px/s, never for less than [slideMin] nor more than
  /// [slideMax].
  static const double slideSpeed = 1200;
  static const Duration slideMin = Duration(milliseconds: 180);
  static const Duration slideMax = Duration(milliseconds: 360);

  /// Seconds a free fall of [height] px takes.
  static double fallSeconds(double height) =>
      height <= 0 ? 0 : math.sqrt(2 * height / fallGravity);

  /// Seconds the slide over [distance] px takes.
  static double slideSeconds(double distance) => (distance.abs() / slideSpeed)
      .clamp(slideMin.inMicroseconds / 1e6, slideMax.inMicroseconds / 1e6)
      .toDouble();

  /// The small hop when something new needs the user.
  static const Duration hop = Duration(milliseconds: 300);
  static const double hopHeight = 10;

  /// Motion frames (settle, hop): one every 34 ms, ≤ 30 fps.
  static const Duration frame = Duration(milliseconds: 34);

  /// Asleep (still, no timers) after this long with nothing going on.
  static const Duration sleepAfter = Duration(seconds: 45);

  /// A look around while idle: one every [minLook]–[maxLook].
  static const Duration minLook = Duration(seconds: 12);
  static const Duration maxLook = Duration(seconds: 24);

  /// Asleep it dims a little.
  static const double asleepOpacity = 0.72;

  /// A suggestion the user only closed may come back after this long.
  static const int suggestAgainDays = 7;

  /// While a list scrolls: 28 % opacity and no hits for 700 ms.
  static const double scrollOpacity = 0.28;
  static const Duration scrollQuiet = Duration(milliseconds: 700);

  /// Lean and squash while held: up to [holdTilt] rad and [holdSquash] of
  /// its size, reached at [holdFullSpeed] px/s; relaxes [holdRelax] after
  /// the finger stops.
  static const double holdTilt = 0.2;
  static const double holdSquash = 0.1;
  static const double holdFullSpeed = 1500;
  static const Duration holdRelax = Duration(milliseconds: 90);

  /// How far a mascot that found a fixed control under it steps aside, and
  /// how many steps it tries.
  static const double avoidStep = 12;
  static const int avoidSteps = 6;

  /// Where the mascot stands when it lives on the dock: on [dock]'s top
  /// edge ([dockAlong] 0..1 along the bar, null for the right end), or the
  /// bottom right corner above the system inset when [dock] is null.
  static Offset home({
    required Size screen,
    required double size,
    EdgeInsets padding = EdgeInsets.zero,
    EdgeInsets gestures = EdgeInsets.zero,
    Rect? dock,
    double? dockAlong,
  }) {
    if (dock != null) {
      final minLeft = dock.left + dockEndInset;
      final maxLeft = math.max(minLeft, dock.right - dockEndInset - size);
      final left = dockAlong == null
          ? maxLeft
          : minLeft + (maxLeft - minLeft) * dockAlong.clamp(0.0, 1.0);
      return Offset(left, dock.top + dockOverlap - size);
    }
    final right = math.max(
      cornerInset,
      math.max(padding.right, gestures.right) + edgeMargin,
    );
    final bottom = math.max(padding.bottom, gestures.bottom) + cornerLift;
    return Offset(
      math.max(edgeMargin, screen.width - right - size),
      math.max(padding.top, screen.height - bottom - size),
    );
  }

  /// Where along the dock (0..1) a box whose left is [left] stands.
  static double dockAlongOf(double left, Rect dock, double size) {
    final minLeft = dock.left + dockEndInset;
    final maxLeft = math.max(minLeft, dock.right - dockEndInset - size);
    if (maxLeft <= minLeft) return 1;
    return ((left - minLeft) / (maxLeft - minLeft)).clamp(0.0, 1.0);
  }

  /// True when a mascot box dropped at [box] lands on the dock: its centre
  /// is within the bar's span and its feet are within [dropZone] above the
  /// bar's top edge, or lower.
  static bool landsOnDock(Rect box, Rect? dock) {
    if (dock == null) return false;
    final cx = box.center.dx;
    return cx >= dock.left &&
        cx <= dock.right &&
        box.bottom >= dock.top - dropZone;
  }

  /// Where the top-left of a free mascot may be: below the status bar, out
  /// of the system gesture zones and the keyboard, [edgeMargin] from the
  /// sides at least, and [floatGap] above [keepOut] (the dock, or the handle
  /// a hidden dock leaves) when there is one.
  static Rect floatBounds({
    required Size screen,
    required double size,
    EdgeInsets padding = EdgeInsets.zero,
    EdgeInsets gestures = EdgeInsets.zero,
    double keyboard = 0,
    Rect? keepOut,
  }) {
    final left = math.max(edgeMargin, math.max(padding.left, gestures.left));
    final right =
        screen.width -
        math.max(edgeMargin, math.max(padding.right, gestures.right)) -
        size;
    final top = math.max(padding.top, gestures.top);
    var floor =
        screen.height -
        math.max(keyboard, math.max(padding.bottom, gestures.bottom));
    if (keepOut != null) floor = math.min(floor, keepOut.top - floatGap);
    final bottom = floor - size;
    return Rect.fromLTRB(
      left,
      top,
      math.max(left, right),
      math.max(top, bottom),
    );
  }

  /// [p] moved into [bounds].
  static Offset clampInto(Offset p, Rect bounds) => Offset(
    p.dx.clamp(bounds.left, bounds.right).toDouble(),
    p.dy.clamp(bounds.top, bounds.bottom).toDouble(),
  );

  /// The spots a mascot resting at [rest] tries, in order, when a fixed
  /// control of the page is under it: itself first, then steps away from
  /// the nearest horizontal edge of the screen (up from the bottom half,
  /// down from the top half), then steps sideways towards the middle.
  static List<Offset> avoidCandidates({
    required Offset rest,
    required Size screen,
    required double size,
    required Rect bounds,
  }) {
    final up = rest.dy + size / 2 > screen.height / 2;
    final side = rest.dx + size / 2 > screen.width / 2 ? -1.0 : 1.0;
    final stride = size / 2 + avoidStep;
    return [
      rest,
      for (var i = 1; i <= avoidSteps; i++)
        clampInto(
          Offset(rest.dx, rest.dy + (up ? -1 : 1) * stride * i),
          bounds,
        ),
      for (var i = 1; i <= avoidSteps; i++)
        clampInto(Offset(rest.dx + side * stride * i, rest.dy), bounds),
    ];
  }
}

/// Small helper for tests and the overlay: the box of a mascot whose
/// bottom-left is at ([left], [bottom]).
Rect mascotBox(
  double left,
  double bottom, [
  double size = MascotFloatPhysics.baseSize,
]) => Rect.fromLTWH(left, bottom - size, size, size);

/// Distance a pointer moved since it went down.
bool pastDragThreshold(Offset delta) =>
    delta.distance > MascotFloatPhysics.dragThreshold;
