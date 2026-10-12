import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart' show Material, MaterialType;
import 'package:flutter/widgets.dart';

/// pm1215: one shared motion for every transient surface that grows out of
/// a pill (the header activity pill, the bottom status pill, the composer
/// grabber). The surface opens as a container transform from the pill's
/// rect, follows the finger while it is dragged toward its edge, springs
/// back when released short of the threshold and, when it closes, shrinks
/// back INTO the pill it came from. No ✕: a swipe, a tap outside, system
/// Back or the screen reader's dismiss action close it.

/// Open/close duration of a pill morph (critically damped, no overshoot).
const Duration kPillMorphOpen = Duration(milliseconds: 300);
const Duration kPillMorphClose = Duration(milliseconds: 260);

/// Reduced motion: the same surface, only faded.
const Duration kPillMorphFade = Duration(milliseconds: 120);

/// Releasing a drag past this distance (logical px) toward the surface's
/// edge closes it.
const double kPillMorphDismissDistance = 80;

/// Or faster than this (px/s) toward the edge.
const double kPillMorphDismissVelocity = 550;

/// A critically damped spring (ζ = 1) as a curve: x(t) = 1 − (1 + ωt)e^(−ωt),
/// normalised so it ends exactly at 1. Fast start, no overshoot, no linger.
class CriticallyDampedCurve extends Curve {
  const CriticallyDampedCurve({this.omega = 8});

  /// Natural frequency in units of the animation's duration.
  final double omega;

  double _x(double t) => 1 - (1 + omega * t) * math.exp(-omega * t);

  @override
  double transformInternal(double t) => _x(t) / _x(1);
}

/// The curve every pill morph uses to open. Closing uses its flipped
/// version so the shrink starts at full speed (no "stuck" first frames).
const Curve kPillMorphCurve = CriticallyDampedCurve();

/// The edge a pill-morph surface sits against, which is also the direction
/// that dismisses it: a header panel ([top]) is swiped up, a bottom sheet
/// ([bottom]) down.
enum PillMorphEdge { top, bottom }

/// Where the open surface goes, given the pill's rect and the screen.
typedef PillMorphTarget = Rect Function(Rect origin, Size screen, Size surface);

/// Default placement: centred horizontally; under the pill for [top],
/// above [bottomInset] for [bottom].
Rect pillMorphDefaultTarget(
  PillMorphEdge edge,
  Rect origin,
  Size screen,
  Size surface, {
  double gap = 8,
  double bottomInset = 0,
}) {
  final left = (screen.width - surface.width) / 2;
  final top = switch (edge) {
    PillMorphEdge.top => origin.bottom + gap,
    PillMorphEdge.bottom => screen.height - bottomInset - surface.height,
  };
  return Rect.fromLTWH(left, top, surface.width, surface.height);
}

/// Owns the drag of one pill-morph surface: the offset toward its edge, the
/// spring back, and the decision to close.
class PillMorphDrag extends ChangeNotifier {
  PillMorphDrag({required TickerProvider vsync, required this.onDismiss})
    : _spring = AnimationController.unbounded(vsync: vsync) {
    _spring.addListener(() {
      _offset = math.max(0, _spring.value);
      notifyListeners();
    });
  }

  final VoidCallback onDismiss;
  final AnimationController _spring;
  double _offset = 0;
  bool _closing = false;

  /// How far (px) the surface was pulled toward its edge. Never negative.
  double get offset => _offset;
  bool get closing => _closing;

  /// Critically damped: the surface settles back without bouncing.
  static final SpringDescription spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 520,
    ratio: 1,
  );

  /// [delta] is positive toward the edge (the dismiss direction).
  void dragBy(double delta) {
    if (_closing) return;
    if (_spring.isAnimating) _spring.stop();
    final next = math.max(0.0, _offset + delta);
    if (next == _offset) return;
    _offset = next;
    notifyListeners();
  }

  /// [velocity] is px/s toward the edge.
  void release(double velocity, {bool reduceMotion = false}) {
    if (_closing) return;
    if (_offset > kPillMorphDismissDistance ||
        (_offset > 0 && velocity > kPillMorphDismissVelocity) ||
        velocity > kPillMorphDismissVelocity * 2) {
      dismiss();
      return;
    }
    if (_offset == 0) return;
    if (reduceMotion) {
      _offset = 0;
      notifyListeners();
      return;
    }
    _spring.animateWith(
      SpringSimulation(spring, _offset, 0, -velocity, tolerance: _tolerance),
    );
  }

  static const Tolerance _tolerance = Tolerance(distance: 0.5, velocity: 5);

  void dismiss() {
    if (_closing) return;
    _closing = true;
    if (_spring.isAnimating) _spring.stop();
    onDismiss();
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }
}

/// A popup route whose page is a [PillMorphSurface]: transparent barrier
/// (the surface paints its own scrim, which lightens while dragging), tap
/// outside and Back close it.
class PillMorphRoute<T> extends PopupRoute<T> {
  PillMorphRoute({
    required this.builder,
    required this.reduceMotion,
    required this.dismissLabel,
    super.settings,
  });

  final Widget Function(BuildContext context, Animation<double> animation)
  builder;
  final bool reduceMotion;
  final String dismissLabel;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => dismissLabel;

  @override
  Duration get transitionDuration =>
      reduceMotion ? kPillMorphFade : kPillMorphOpen;

  @override
  Duration get reverseTransitionDuration =>
      reduceMotion ? kPillMorphFade : kPillMorphClose;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => builder(context, animation);
}

/// Reads the global rect of the widget under [key] (the pill), or null.
///
/// Reads [Element.renderObject] rather than `findRenderObject()`: the pill's
/// screen can be removed while the morph is still on screen (its route torn
/// down under a dialog), and `findRenderObject()` throws on that inactive
/// element. A detached box then yields null and the morph keeps its last rect.
Rect? pillMorphRectOf(GlobalKey key) {
  final element = key.currentContext;
  final box = element is Element ? element.renderObject : null;
  if (box is! RenderBox || !box.hasSize || !box.attached) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// The surface of a pill morph: content-sized, it grows out of [origin]
/// (the pill's global rect) into the rect [target] picks, with the radius
/// going from the pill's stadium to [radius]. The drag follows the finger
/// toward [edge]: a bottom sheet moves whole, a header panel rolls up under
/// its top edge (it never covers the pill it hangs from).
class PillMorphSurface extends StatefulWidget {
  const PillMorphSurface({
    required this.animation,
    required this.origin,
    required this.edge,
    required this.color,
    required this.onDismiss,
    required this.dismissLabel,
    required this.child,
    this.target,
    this.maxWidth = 560,
    this.maxHeight,
    this.radius = 24,
    this.scrimOpacity = 0.32,
    this.scrimTop,
    this.surfaceKey,
    this.reduceMotion = false,
    this.borderColor,
    super.key,
  });

  final Animation<double> animation;

  /// The pill's rect in global coordinates; read on every layout so a
  /// pill that moves (keyboard, rotation) keeps being the origin. Null:
  /// a small stadium at the surface's edge centre.
  final Rect? Function() origin;
  final PillMorphEdge edge;
  final PillMorphTarget? target;
  final Color color;
  final Color? borderColor;
  final VoidCallback onDismiss;

  /// Screen-reader label of the dismiss action (e.g. «Cerrar»).
  final String dismissLabel;
  final Widget child;
  final double maxWidth;
  final double? maxHeight;
  final double radius;
  final double scrimOpacity;

  /// The scrim starts here (global y); null: the whole screen. A header
  /// panel keeps the header (pill and face) out of the scrim.
  final double? scrimTop;
  final Key? surfaceKey;
  final bool reduceMotion;

  @override
  State<PillMorphSurface> createState() => PillMorphSurfaceState();
}

class PillMorphSurfaceState extends State<PillMorphSurface>
    with SingleTickerProviderStateMixin {
  late final PillMorphDrag drag = PillMorphDrag(
    vsync: this,
    onDismiss: widget.onDismiss,
  );
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: widget.animation,
    curve: kPillMorphCurve,
    reverseCurve: kPillMorphCurve.flipped,
  );

  /// How open (0…1) the surface was when its route started to close.
  double _closedFrom = 1;

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_onRouteStatus);
  }

  void _onRouteStatus(AnimationStatus status) {
    if (status == AnimationStatus.reverse) _closedFrom = _curved.value;
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onRouteStatus);
    _curved.dispose();
    drag.dispose();
    super.dispose();
  }

  /// The share (1 → 0) of the finger's pull the surface still carries with
  /// its morph at [open].
  ///
  /// A close is ONE motion from where the sheet is into its pill: the pull
  /// shrinks in step with the size, so every edge travels straight to the
  /// pill. Driven apart (the size on the morph curve, the pull on the
  /// route's linear value) the sheet was already a blob by mid-close, still
  /// hanging below its pill, and crawled back up into it.
  double _pullLeft(double open) {
    if (widget.animation.status != AnimationStatus.reverse) return 1;
    return _closedFrom <= 0 ? 0 : (open / _closedFrom).clamp(0.0, 1.0);
  }

  /// +1 when a positive dy moves toward the edge.
  double get _sign => widget.edge == PillMorphEdge.bottom ? 1 : -1;

  void _dragUpdate(DragUpdateDetails d) => drag.dragBy(d.delta.dy * _sign);

  void _dragEnd(DragEndDetails d) => drag.release(
    (d.primaryVelocity ?? 0) * _sign,
    reduceMotion: widget.reduceMotion,
  );

  /// Content that scrolls takes the drag; once it is at the end that faces
  /// the edge, the pull moves the surface instead.
  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    _fingerScrolls = switch (n) {
      ScrollStartNotification(:final dragDetails) => dragDetails != null,
      ScrollUpdateNotification(:final dragDetails) => dragDetails != null,
      OverscrollNotification(:final dragDetails) => dragDetails != null,
      ScrollEndNotification() => false,
      _ => _fingerScrolls,
    };
    if (n is OverscrollNotification && n.dragDetails != null) {
      // bottom: pulling down at the top (overscroll < 0); top: pulling up
      // at the bottom (overscroll > 0).
      final toward = widget.edge == PillMorphEdge.bottom
          ? -n.overscroll
          : n.overscroll;
      if (toward > 0) drag.dragBy(toward);
    } else if (n is ScrollUpdateNotification &&
        n.dragDetails != null &&
        drag.offset > 0) {
      final delta = n.scrollDelta ?? 0;
      final back = widget.edge == PillMorphEdge.bottom ? delta : -delta;
      if (back > 0) drag.dragBy(-back);
    } else if (n is ScrollEndNotification) {
      final v = n.dragDetails?.primaryVelocity ?? 0;
      drag.release(v * _sign, reduceMotion: widget.reduceMotion);
    }
    return false;
  }

  /// A finger (not a fling) is moving the content's own scrollable.
  bool _fingerScrolls = false;

  /// The finger's pull at the end of the list that faces the edge (the top
  /// of a bottom sheet's list, the bottom of a header panel's) moves the
  /// surface, so the list must not also answer it with Android's overscroll
  /// stretch: the rows deformed under the finger while the surface
  /// travelled with it. A fling that runs into that end keeps the platform
  /// effect.
  bool _onOverscrollIndicator(OverscrollIndicatorNotification n) {
    final towardEdge = widget.edge == PillMorphEdge.bottom
        ? n.leading
        : !n.leading;
    if (n.depth == 0 && towardEdge && _fingerScrolls) {
      n.disallowIndicator();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final insets = MediaQuery.viewInsetsOf(context);
    final bottomInset = math.max(padding.bottom, insets.bottom) + 10;
    final width = math.min(widget.maxWidth, screen.width - 20);
    final maxHeight =
        widget.maxHeight ??
        math.max(0.0, (screen.height - padding.top - bottomInset - 24) * 0.85);
    final reduce = widget.reduceMotion;
    final Animation<double> curved = reduce ? widget.animation : _curved;
    final content = NotificationListener<OverscrollIndicatorNotification>(
      onNotification: _onOverscrollIndicator,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: GestureDetector(
          onVerticalDragUpdate: _dragUpdate,
          onVerticalDragEnd: _dragEnd,
          onVerticalDragCancel: () => drag.release(0),
          child: Semantics(
            container: true,
            scopesRoute: false,
            onDismiss: drag.dismiss,
            customSemanticsActions: {
              CustomSemanticsAction(label: widget.dismissLabel): drag.dismiss,
            },
            child: ConstrainedBox(
              key: widget.surfaceKey,
              constraints: BoxConstraints(
                minWidth: width,
                maxWidth: width,
                maxHeight: maxHeight,
              ),
              // Ink (rows, buttons) paints on the morph's own surface.
              child: Material(
                type: MaterialType.transparency,
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
    return AnimatedBuilder(
      animation: Listenable.merge([curved, drag]),
      builder: (context, child) {
        final raw = widget.animation.value.clamp(0.0, 1.0);
        final pull = drag.offset;
        // The surface never leans back toward its pill while pulled: that
        // cropped its rows from the sides under the finger, and the lean was
        // dropped at once on release (a frame at full size before the
        // shrink). It follows the finger and closes from there in ONE
        // motion: the pull it still carries shrinks in step with its size.
        // Reduced motion: no morph, it fades where the finger left it.
        final t = reduce ? 1.0 : curved.value;
        final carried = pull * (reduce ? 1 : _pullLeft(t));
        // A bottom sheet lies over the pill it came from and moves whole.
        // A header panel hangs UNDER its pill, which must stay in view (the
        // name, the face on it): it rolls up under its own top edge
        // instead, its rows moving with the finger.
        final bottom = widget.edge == PillMorphEdge.bottom;
        final offset = bottom ? carried : 0.0;
        final retract = bottom ? 0.0 : carried;
        final scrim =
            widget.scrimOpacity * raw * (1 - (pull / 300).clamp(0.0, 1.0));
        return Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: widget.scrimTop ?? 0,
              bottom: 0,
              child: IgnorePointer(
                child: ColoredBox(
                  key: const ValueKey('pill-morph-scrim'),
                  color: Color.fromRGBO(0, 0, 0, scrim),
                ),
              ),
            ),
            Positioned.fill(
              child: Opacity(
                opacity: reduce ? raw : 1,
                child: _PillMorphLayout(
                  origin: widget.origin(),
                  edge: widget.edge,
                  target: widget.target,
                  bottomInset: bottomInset,
                  t: t,
                  contentOpacity: reduce
                      ? 1
                      : Curves.easeOut.transform(
                          ((raw - 0.15) / 0.6).clamp(0.0, 1.0),
                        ),
                  offset: offset,
                  retract: retract,
                  radius: widget.radius,
                  color: widget.color,
                  borderColor: widget.borderColor,
                  child: child,
                ),
              ),
            ),
          ],
        );
      },
      child: content,
    );
  }
}

class _PillMorphLayout extends SingleChildRenderObjectWidget {
  const _PillMorphLayout({
    required this.origin,
    required this.edge,
    required this.target,
    required this.bottomInset,
    required this.t,
    required this.contentOpacity,
    required this.offset,
    required this.retract,
    required this.radius,
    required this.color,
    required this.borderColor,
    super.child,
  });

  final Rect? origin;
  final PillMorphEdge edge;
  final PillMorphTarget? target;
  final double bottomInset;
  final double t;
  final double contentOpacity;
  final double offset;
  final double retract;
  final double radius;
  final Color color;
  final Color? borderColor;

  @override
  RenderPillMorph createRenderObject(BuildContext context) => RenderPillMorph(
    origin: origin,
    edge: edge,
    target: target,
    bottomInset: bottomInset,
    t: t,
    contentOpacity: contentOpacity,
    offset: offset,
    retract: retract,
    radius: radius,
    color: color,
    borderColor: borderColor,
  );

  @override
  void updateRenderObject(BuildContext context, RenderPillMorph renderObject) {
    renderObject
      ..origin = origin
      ..edge = edge
      ..target = target
      ..bottomInset = bottomInset
      ..t = t
      ..contentOpacity = contentOpacity
      ..offset = offset
      ..retract = retract
      ..radius = radius
      ..color = color
      ..borderColor = borderColor;
  }
}

/// Lays the surface out at its open size once, then paints it clipped to
/// the rect between the pill and the open position (container transform).
/// The content is anchored to the edge the surface grows from, so it is
/// revealed rather than squashed.
class RenderPillMorph extends RenderProxyBox {
  RenderPillMorph({
    required this._origin,
    required this._edge,
    required this._target,
    required this._bottomInset,
    required this._t,
    required this._contentOpacity,
    required this._offset,
    required this._retract,
    required this._radius,
    required this._color,
    required this._borderColor,
  });

  Rect? _origin;
  set origin(Rect? v) {
    if (v == _origin) return;
    _origin = v;
    markNeedsLayout();
  }

  PillMorphEdge _edge;
  set edge(PillMorphEdge v) {
    if (v == _edge) return;
    _edge = v;
    markNeedsLayout();
  }

  PillMorphTarget? _target;
  set target(PillMorphTarget? v) {
    if (v == _target) return;
    _target = v;
    markNeedsLayout();
  }

  double _bottomInset;
  set bottomInset(double v) {
    if (v == _bottomInset) return;
    _bottomInset = v;
    markNeedsLayout();
  }

  double _t;
  set t(double v) {
    if (v == _t) return;
    _t = v;
    markNeedsPaint();
  }

  double _contentOpacity;
  set contentOpacity(double v) {
    if (v == _contentOpacity) return;
    _contentOpacity = v;
    markNeedsPaint();
  }

  double _offset;
  set offset(double v) {
    if (v == _offset) return;
    _offset = v;
    markNeedsPaint();
  }

  /// How far (px) a header panel is rolled up under its top edge.
  double _retract;
  set retract(double v) {
    if (v == _retract) return;
    _retract = v;
    markNeedsPaint();
  }

  double _radius;
  set radius(double v) {
    if (v == _radius) return;
    _radius = v;
    markNeedsPaint();
  }

  Color _color;
  set color(Color v) {
    if (v == _color) return;
    _color = v;
    markNeedsPaint();
  }

  Color? _borderColor;
  set borderColor(Color? v) {
    if (v == _borderColor) return;
    _borderColor = v;
    markNeedsPaint();
  }

  Rect _targetRect = Rect.zero;

  // The clip and the content fade are layers: always composite (a short-
  // lived surface, one layer).
  @override
  bool get alwaysNeedsCompositing => true;

  /// The open rect (before the morph and the drag), for tests.
  Rect get targetRect => _targetRect;

  /// Where the surface is painted this frame, for tests.
  Rect get currentRect => _current();

  Rect get _originRect {
    final o = _origin;
    if (o != null) return o;
    final w = 56.0, h = 24.0;
    final x = (size.width - w) / 2;
    return _edge == PillMorphEdge.top
        ? Rect.fromLTWH(x, 0, w, h)
        : Rect.fromLTWH(x, size.height - _bottomInset - h, w, h);
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    final child = this.child;
    if (child == null) return;
    child.layout(
      BoxConstraints(maxWidth: size.width, maxHeight: size.height),
      parentUsesSize: true,
    );
    final origin = _originRect;
    final pick = _target;
    _targetRect = pick != null
        ? pick(origin, size, child.size)
        : pillMorphDefaultTarget(
            _edge,
            origin,
            size,
            child.size,
            bottomInset: _bottomInset,
          );
  }

  /// The rect between the pill and the open position, before any pull.
  Rect get _morphed => Rect.lerp(_originRect, _targetRect, _t.clamp(0.0, 1.0))!;

  /// How much of [morphed] a pulled header panel hides under its top edge.
  /// It never gets shorter than its pill, so closing from there only ever
  /// shrinks.
  double _rolledUp(Rect morphed) {
    if (_edge != PillMorphEdge.top || _retract <= 0) return 0;
    final least = math.min(morphed.height, _originRect.height);
    return math.min(_retract, morphed.height - least);
  }

  Rect _current() {
    final r = _morphed;
    final cut = _rolledUp(r);
    if (cut > 0) return Rect.fromLTRB(r.left, r.top, r.right, r.bottom - cut);
    return r.shift(Offset(0, _offset));
  }

  double get _currentRadius {
    final o = _originRect;
    return lerpDouble(o.shortestSide / 2, _radius, _t.clamp(0.0, 1.0))!;
  }

  /// Where the content goes: anchored to the edge the surface grows from,
  /// and moved with the finger while a header panel is rolled up.
  Offset _childOffset(Rect r) {
    final child = this.child!;
    final dx = r.center.dx - child.size.width / 2;
    final dy = _edge == PillMorphEdge.top
        ? r.top - _rolledUp(_morphed)
        : r.bottom - child.size.height;
    return Offset(dx, dy);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    final r = _current();
    if (!r.contains(position)) return false;
    final o = _childOffset(r);
    return result.addWithPaintOffset(
      offset: o,
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  @override
  bool hitTestSelf(Offset position) => _current().contains(position);

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final o = _childOffset(_current());
    transform.multiply(Matrix4.translationValues(o.dx, o.dy, 0));
  }

  final LayerHandle<ClipRRectLayer> _clip = LayerHandle<ClipRRectLayer>();
  final LayerHandle<OpacityLayer> _opacity = LayerHandle<OpacityLayer>();

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final r = _current().shift(offset);
    final rrect = RRect.fromRectAndRadius(r, Radius.circular(_currentRadius));
    final canvas = context.canvas;
    final elevation = 12 * _t.clamp(0.0, 1.0) + 2;
    canvas.drawShadow(
      Path()..addRRect(rrect),
      const Color(0xFF000000).withValues(alpha: 0.45),
      elevation,
      false,
    );
    canvas.drawRRect(rrect, Paint()..color = _color);
    final childOffset = _childOffset(_current()) + offset;
    _clip.layer = context.pushClipRRect(
      needsCompositing,
      offset,
      r.shift(-offset),
      rrect.shift(-offset),
      (context, o) {
        final alpha = (_contentOpacity * 255).round();
        if (alpha >= 255) {
          context.paintChild(child, childOffset);
        } else if (alpha > 0) {
          _opacity.layer = context.pushOpacity(
            childOffset,
            alpha,
            (context, o) => context.paintChild(child, o),
            oldLayer: _opacity.layer,
          );
        }
      },
      oldLayer: _clip.layer,
    );
    final border = _borderColor;
    if (border != null) {
      context.canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = border,
      );
    }
  }

  @override
  void dispose() {
    _clip.layer = null;
    _opacity.layer = null;
    super.dispose();
  }
}
