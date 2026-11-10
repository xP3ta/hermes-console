import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../theme/hermes_tokens.dart';

/// One keyed child, retained once even when an exit is interrupted by return.
typedef TurnMotionEntry = ({Object id, Widget child});

/// A small turn's rows, with layout, opacity and reordering on the same
/// display clock. Source updates in one frame are reconciled together;
/// there is no AnimatedSwitcher keeping a second thought subtree alive.
class TurnStepMotion extends StatefulWidget {
  const TurnStepMotion({
    required this.entries,
    this.animateInitial = false,
    super.key,
  });
  final List<TurnMotionEntry> entries;
  final bool animateInitial;

  @override
  State<TurnStepMotion> createState() => _TurnStepMotionState();
}

class _TurnStepMotionState extends State<TurnStepMotion> {
  final List<Object> _order = [];
  final Map<Object, Widget> _children = {};
  Set<Object> _wanted = {};
  final Set<Object> _initial = {};
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    if (!widget.animateInitial) {
      _initial.addAll(widget.entries.map((entry) => entry.id));
    }
    _reconcile();
  }

  @override
  void didUpdateWidget(TurnStepMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reconcile();
  }

  void _reconcile() {
    final wanted = widget.entries.map((entry) => entry.id).toList();
    assert(wanted.toSet().length == wanted.length, 'Duplicate turn step id');
    final next = <Object>[...wanted];
    // Exits occupy their old slot while shrinking; neighbours therefore move
    // continuously. Returning IDs reuse that same slot/state, never a clone.
    for (var index = 0; index < _order.length; index++) {
      final id = _order[index];
      if (!next.contains(id)) next.insert(math.min(index, next.length), id);
    }
    if (_order.length != next.length ||
        Iterable<int>.generate(
          next.length,
        ).any((index) => _order[index] != next[index])) {
      _revision++;
    }
    _order
      ..clear()
      ..addAll(next);
    _wanted = wanted.toSet();
    for (final entry in widget.entries) {
      _children[entry.id] = entry.child;
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduced = HermesMotion.reduced(context);
    final wantedOrder = widget.entries.map((entry) => entry.id).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final id in _order)
          _MotionSlot(
            key: ValueKey(id),
            present: _wanted.contains(id),
            initiallyVisible: _initial.contains(id),
            reduced: reduced,
            revision: _revision,
            delay:
                HermesMotion.stagger *
                math.max(0, math.min(2, wantedOrder.indexOf(id))),
            onGone: () {
              if (!mounted || _wanted.contains(id)) return;
              setState(() {
                _order.remove(id);
                _children.remove(id);
                _initial.remove(id);
              });
            },
            child: _children[id]!,
          ),
      ],
    );
  }
}

class _MotionSlot extends StatefulWidget {
  const _MotionSlot({
    required this.present,
    required this.initiallyVisible,
    required this.reduced,
    required this.revision,
    required this.delay,
    required this.onGone,
    required this.child,
    super.key,
  });
  final bool present;
  final bool initiallyVisible;
  final bool reduced;
  final int revision;
  final Duration delay;
  final VoidCallback onGone;
  final Widget child;

  @override
  State<_MotionSlot> createState() => _MotionSlotState();
}

class _MotionSlotState extends State<_MotionSlot>
    with TickerProviderStateMixin {
  @override
  Widget build(BuildContext context) => _SlotBox(
    vsync: this,
    present: widget.present,
    initiallyVisible: widget.initiallyVisible,
    reduced: widget.reduced || !TickerMode.valuesOf(context).enabled,
    revision: widget.revision,
    delay: widget.delay,
    onGone: widget.onGone,
    child: widget.child,
  );
}

class _SlotBox extends SingleChildRenderObjectWidget {
  const _SlotBox({
    required this.vsync,
    required this.present,
    required this.initiallyVisible,
    required this.reduced,
    required this.revision,
    required this.delay,
    required this.onGone,
    required super.child,
  });
  final TickerProvider vsync;
  final bool present;
  final bool initiallyVisible;
  final bool reduced;
  final int revision;
  final Duration delay;
  final VoidCallback onGone;

  @override
  _RenderSlot createRenderObject(BuildContext context) => _RenderSlot(
    vsync: vsync,
    present: present,
    reduced: reduced,
    initiallyVisible: initiallyVisible,
    revision: revision,
    delay: delay,
    onGone: onGone,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderSlot object) =>
      object.update(
        present: present,
        reduced: reduced,
        revision: revision,
        delay: delay,
        onGone: onGone,
      );
}

class _RenderSlot extends RenderProxyBox {
  _RenderSlot({
    required TickerProvider vsync,
    required bool present,
    required bool initiallyVisible,
    required bool reduced,
    required this._revision,
    required this._delay,
    required this._onGone,
  }) : _present = present,
       _reduced = reduced {
    _ticker = vsync.createTicker(_tick);
    _to = present ? 1 : 0;
    _factor = reduced || initiallyVisible ? _to : 0;
    _from = _factor;
    if (initiallyVisible) _age = HermesMotion.base;
  }

  late final Ticker _ticker;
  bool _present;
  bool _reduced;
  int _revision;
  Duration _delay;
  VoidCallback _onGone;
  Duration _last = Duration.zero;
  Duration _age = Duration.zero;
  Duration _moveAge = HermesMotion.base;
  double _factor = 0;
  double _from = 0;
  double _to = 1;
  Offset? _previousPosition;
  Offset _moveFrom = Offset.zero;
  bool _armed = false;
  bool _goneScheduled = false;

  Offset get _movement =>
      _moveFrom *
      (1 -
          HermesMotion.standard.transform(
            (_moveAge.inMicroseconds / HermesMotion.base.inMicroseconds).clamp(
              0.0,
              1.0,
            ),
          ));

  void update({
    required bool present,
    required bool reduced,
    required int revision,
    required Duration delay,
    required VoidCallback onGone,
  }) {
    _onGone = onGone;
    _armed |= revision != _revision;
    _revision = revision;
    if (present != _present) {
      _from = _factor;
      _to = present ? 1 : 0;
      _age = Duration.zero;
      _delay = Duration.zero;
      _goneScheduled = false;
    }
    _present = present;
    _reduced = reduced;
    if (reduced) {
      _factor = _from = _to;
      _moveFrom = Offset.zero;
      _moveAge = HermesMotion.base;
      _age = HermesMotion.base;
      _delay = Duration.zero;
      _stop();
    }
    markNeedsLayout();
  }

  void _start() {
    if (_ticker.isActive || _reduced || !attached) return;
    _last = Duration.zero;
    _ticker.start();
  }

  void _stop() => _ticker.stop();

  void _tick(Duration elapsed) {
    final delta = elapsed - _last;
    _last = elapsed;
    _age += delta;
    _moveAge += delta;
    // A block coming in takes its time and settles softly; one going out
    // leaves quickly.
    final entering = _to > _from;
    final span = entering ? HermesMotion.enter : HermesMotion.base;
    final t = ((_age - _delay).inMicroseconds / span.inMicroseconds).clamp(
      0.0,
      1.0,
    );
    _factor =
        _from +
        (_to - _from) *
            (entering ? HermesMotion.emphasized : HermesMotion.standard)
                .transform(t);
    markNeedsLayout();
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void performLayout() {
    child?.layout(constraints, parentUsesSize: true);
    // Close enough is arrived: the last sliver of a long, soft ease never
    // leaves the block a hair short of its height.
    if (_reduced || (_factor - _to).abs() <= 0.001) _factor = _to;
    size = constraints.constrain(
      Size(child?.size.width ?? 0, (child?.size.height ?? 0) * _factor),
    );
    if ((_factor - _to).abs() > 0.001 || _moveAge < HermesMotion.base) {
      _start();
    } else {
      _stop();
      if (!_present && !_goneScheduled) {
        _goneScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (attached && !_present) _onGone();
        });
      }
    }
  }

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    final data = parentData;
    final position = data is BoxParentData ? data.offset : Offset.zero;
    if (_armed && !_reduced && _previousPosition != null) {
      final delta = _previousPosition! + _movement - position;
      // A reflow can move a row by several slots (folding or returning from
      // a resized window). Keep its small settling motion inside its own
      // slot instead of flying across other completed actions.
      _moveFrom = Offset(
        delta.dx.clamp(-HermesSpace.x1, HermesSpace.x1).toDouble(),
        delta.dy.clamp(-HermesSpace.x1, HermesSpace.x1).toDouble(),
      );
      _moveAge = Duration.zero;
      if (_moveFrom.distanceSquared > 0.01) _start();
    }
    _armed = false;
    _previousPosition = position;
    if (_factor <= 0 || child == null) return;
    final translated = _movement + Offset(0, HermesSpace.x2 * (1 - _factor));
    void draw(PaintingContext context, Offset offset) {
      void moved(PaintingContext context, Offset offset) {
        context.pushTransform(
          needsCompositing,
          offset,
          Matrix4.translationValues(translated.dx, translated.dy, 0),
          (context, offset) => context.paintChild(child!, offset),
        );
      }

      if (_factor < 0.999) {
        context.pushOpacity(offset, (255 * _factor).round(), moved);
      } else {
        moved(context, offset);
      }
    }

    // Paint and hit testing share the allocated row at every phase, not
    // just while it grows/shrinks. No step can cover a sibling or composer.
    context.pushClipRect(needsCompositing, offset, Offset.zero & size, draw);
  }

  @override
  Rect? describeApproximatePaintClip(RenderObject child) => Offset.zero & size;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (_factor <= 0 || child == null || !size.contains(position)) {
      return false;
    }
    final translated = _movement + Offset(0, HermesSpace.x2 * (1 - _factor));
    final hit = result.addWithPaintOffset(
      offset: translated,
      position: position,
      hitTest: (result, position) => child!.hitTest(result, position: position),
    );
    if (hit) result.add(BoxHitTestEntry(this, position));
    return hit;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final translated = _movement + Offset(0, HermesSpace.x2 * (1 - _factor));
    transform.translateByDouble(translated.dx, translated.dy, 0, 1);
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    // Departing thoughts remain painted once, but cannot be announced again.
    if (_present && _factor > 0) super.visitChildrenForSemantics(visitor);
  }

  @override
  void detach() {
    _stop();
    super.detach();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}
