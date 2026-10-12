import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../theme/motion.dart';

/// The light that passes behind the dock's icons when the selected place
/// changes: as if a lamp slid behind the glass from the item the user was
/// at to the one just picked, settled under it and went out.
///
/// It is one light for the whole app. Every screen mounts its own dock, so
/// the dock where the tap happened and the dock of the screen that opens
/// both paint this same light: the glide that starts under the finger goes
/// on, uninterrupted, on the next screen.
///
/// At rest it is dark. The selected item is its filled icon and nothing
/// else (matte); the light only shows the change.
///
/// Cheap by construction: a position and a strength driven by one ticker
/// that runs for the length of a transition (under a second) and is
/// stopped the rest of the time. The docks repaint one gradient from it;
/// nothing rebuilds and no blur is involved.
class DockLight extends ChangeNotifier {
  DockLight();

  /// The glide from one item to another.
  static const Duration travel = Motion.page;

  /// From dark to lit, at the start of a glide.
  static const Duration rise = Motion.fast;

  /// How long it stays lit under the item it reached.
  static const Duration hold = Motion.fast;

  /// From lit to dark, once it arrived.
  static const Duration fade = Duration(milliseconds: 400);

  static const Curve curve = Motion.enter;

  double _position = 0;
  double _strength = 0;
  int? _target;

  double _from = 0;
  double _fromStrength = 0;
  bool _leaving = false;
  Ticker? _ticker;

  /// Where the light is, in slots of the bar: 0 is the first item, 1 the
  /// second, and anything in between while it glides.
  double get position => _position;

  /// 0 (dark) to 1 (lit).
  double get strength => _strength;

  /// The slot of the selected place, or null when the screen in view is no
  /// item of the dock.
  int? get target => _target;

  /// A transition is running.
  bool get moving => _ticker?.isActive ?? false;

  /// The user picked the place at [slot]: the light glides there from
  /// wherever it is now. Picking the place it is already heading to
  /// changes nothing, and a new target mid-flight starts from the point it
  /// reached, so it never jumps back.
  ///
  /// Without [animate] (reduced motion) there is no light at all: the
  /// selection just changes.
  void moveTo(int slot, {required bool animate}) {
    if (_target == slot) return;
    final hadPlace = _target != null;
    _target = slot;
    if (!animate) {
      _snap(slot.toDouble());
      return;
    }
    // Nowhere to come from: it lights up where it is going.
    _from = hadPlace ? _position : slot.toDouble();
    _position = _from;
    _fromStrength = _strength;
    _leaving = false;
    _start();
  }

  /// A dock reports the place its screen is ([slot] null: none of its
  /// items). The same place the light already has changes nothing, so a
  /// screen that opens does not restart a glide in flight. Another place
  /// (the user came back) is a glide to it; none is the light going out;
  /// and the first place after none is taken without any light.
  void settle(int? slot, {required bool animate}) {
    if (slot == _target) return;
    if (slot == null) {
      _target = null;
      if (!animate || _strength == 0) {
        _snap(_position);
        return;
      }
      _from = _position;
      _fromStrength = _strength;
      _leaving = true;
      _start();
      return;
    }
    if (_target == null) {
      _target = slot;
      _snap(slot.toDouble());
      return;
    }
    moveTo(slot, animate: animate);
  }

  /// The dock's layout changed, so slots are other items now: the light is
  /// put under [slot] (or out) without a glide.
  void place(int? slot) {
    _target = slot;
    _snap(slot?.toDouble() ?? _position);
  }

  /// No dock is on screen: whatever was running ends where it was going.
  void rest() {
    if (!moving && _strength == 0) return;
    _snap(_target?.toDouble() ?? _position);
  }

  void _snap(double position) {
    _ticker?.stop();
    final changed = _position != position || _strength != 0;
    _position = position;
    _strength = 0;
    if (changed) notifyListeners();
  }

  void _start() {
    final ticker = _ticker ??= Ticker(_tick, debugLabel: 'DockLight');
    if (ticker.isActive) ticker.stop();
    ticker.start();
    notifyListeners();
  }

  static double _ratio(Duration elapsed, Duration total) =>
      (elapsed.inMicroseconds / total.inMicroseconds).clamp(0.0, 1.0);

  void _tick(Duration elapsed) {
    if (_leaving) {
      final t = _ratio(elapsed, Motion.base);
      _strength = _fromStrength * (1 - t);
      if (t >= 1) _ticker!.stop();
      notifyListeners();
      return;
    }
    final to = _target!.toDouble();
    _position = ui.lerpDouble(
      _from,
      to,
      curve.transform(_ratio(elapsed, travel)),
    )!;
    final lit = elapsed - travel - hold;
    if (lit <= Duration.zero) {
      _strength = math.max(_fromStrength, _ratio(elapsed, rise));
    } else {
      final t = _ratio(lit, fade);
      _strength = 1 - t;
      if (t >= 1) {
        _position = to;
        _ticker!.stop();
      }
    }
    notifyListeners();
  }

  /// Back to how it is before any dock was on screen.
  void reset() {
    _ticker?.stop();
    _position = 0;
    _strength = 0;
    _target = null;
    _leaving = false;
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }
}

/// Where the light falls on a bar of [size] with [slots] items laid out
/// inside [inset] of side padding: centred on the slot at [position], never
/// wider than the room that slot has to the bar's edge, so it is inside the
/// bar at every point of a glide.
Rect dockLightRect(
  Size size, {
  required int slots,
  required double position,
  required bool rtl,
  double inset = 0,
}) {
  final slotWidth = (size.width - inset * 2) / slots;
  final onScreen = rtl ? slots - 1 - position : position;
  final center = inset + slotWidth * (onScreen + .5);
  final width = math.min(slotWidth + inset, DockLightPainter.maxWidth);
  return Rect.fromCenter(
    center: Offset(center, size.height / 2),
    width: width,
    height: size.height,
  );
}

/// Paints the [DockLight] behind a row of [slots] items: one soft ellipse
/// of the accent colour, brightest in the middle and gone at its edge. The
/// bar's own clip keeps it inside the pill.
class DockLightPainter extends CustomPainter {
  DockLightPainter({
    required this.light,
    required this.slots,
    required this.color,
    required this.rtl,
    this.inset = 0,
  }) : super(repaint: light);

  final DockLight light;
  final int slots;
  final Color color;
  final bool rtl;
  final double inset;

  /// Widest the light gets, however few items the bar has.
  static const double maxWidth = 96;

  /// Opacity of the middle of the light at full strength.
  static const double peak = .26;

  /// The light's box on a bar of [size], now.
  Rect rectFor(Size size) => dockLightRect(
    size,
    slots: slots,
    position: light.position,
    rtl: rtl,
    inset: inset,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final strength = light.strength;
    if (strength <= 0 || slots <= 0) return;
    final rect = rectFor(size);
    final radius = rect.height / 2;
    final paint = Paint()
      ..shader = ui.Gradient.radial(
        Offset.zero,
        radius,
        [
          color.withValues(alpha: peak * strength),
          color.withValues(alpha: peak * .4 * strength),
          color.withValues(alpha: 0),
        ],
        const [0, .55, 1],
      );
    canvas
      ..save()
      ..translate(rect.center.dx, rect.center.dy)
      ..scale(rect.width / rect.height, 1)
      ..drawCircle(Offset.zero, radius, paint)
      ..restore();
  }

  @override
  bool shouldRepaint(DockLightPainter oldDelegate) =>
      oldDelegate.light != light ||
      oldDelegate.slots != slots ||
      oldDelegate.color != color ||
      oldDelegate.rtl != rtl ||
      oldDelegate.inset != inset;
}
