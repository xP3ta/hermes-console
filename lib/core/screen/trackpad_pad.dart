import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../feedback/haptics.dart';
import '../theme/app_theme.dart';
import 'screen_chrome.dart';

/// What the trackpad drives: the bot desktop's virtual pointer.
abstract interface class PadSink {
  /// Moves the pointer by a finger delta in logical pixels.
  void move(double dx, double dy);

  /// Clicks: [mask] 1 left, 2 middle (wheel), 4 right.
  void click(int mask);

  /// Holds a button down (drag).
  void down(int mask);

  /// Lets a held button go.
  void up(int mask);

  /// Turns the wheel [steps] notches; positive scrolls the content down.
  void wheel(int steps);
}

/// Gesture timings are not animations, so they are not motion tokens.
Duration _ms(int value) => Duration(microseconds: value * 1000);

/// Finger travel (dp) under which a touch is still a tap.
const double padTapSlop = 8;

/// Longest a touch can last and still be a tap.
final Duration padTapMax = _ms(300);

/// Holding still this long starts a drag.
final Duration padHoldToDrag = _ms(380);

/// A second tap this soon after the first (and near it) is a double click,
/// and drags if it moves.
final Duration padDoubleTapWindow = _ms(400);

/// Finger travel (dp) per wheel notch.
const double padWheelStep = 24;

/// Usual height of the pad surface.
const double padSurfaceHeight = 210;

/// Smallest surface worth drawing; below it only the buttons stay.
const double padSurfaceMin = 96;

/// Width of the scroll rail on the right edge of the surface.
const double padRailWidth = 44;

enum _Gesture { idle, move, drag, scroll, two }

/// A laptop-style trackpad: a large rounded surface with a scroll rail on
/// the right and three buttons under it (Clic, Rueda, Clic derecho).
///
/// Drag moves the pointer, a short tap clicks, a second tap clicks again
/// (a double click), holding and then dragging drags, a drag on the rail or
/// with two fingers scrolls, and a two-finger tap right-clicks.
class ScreenTrackpad extends StatefulWidget {
  /// Creates a trackpad that drives [sink].
  const ScreenTrackpad({
    required this.sink,
    this.surfaceHeight = padSurfaceHeight,
    super.key,
  });

  /// Height of the surface; zero or less leaves only the three buttons (a
  /// short window, or the keyboard up).
  final double surfaceHeight;

  /// Receiver of the gestures.
  final PadSink sink;

  @override
  State<ScreenTrackpad> createState() => _ScreenTrackpadState();
}

class _ScreenTrackpadState extends State<ScreenTrackpad> {
  final _fingers = <int, Offset>{};
  var _gesture = _Gesture.idle;
  var _maxFingers = 0;
  var _moved = false;
  var _armedDouble = false;
  var _heldDown = false;
  Offset _start = Offset.zero;
  Duration _startTime = Duration.zero;
  Duration? _lastTapEnd;
  Offset _lastTapAt = Offset.zero;
  double _carry = 0;
  Timer? _hold;
  var _width = 0.0;

  PadSink get _sink => widget.sink;

  @override
  void dispose() {
    _hold?.cancel();
    if (_heldDown) _sink.up(1);
    super.dispose();
  }

  void _onDown(PointerDownEvent event) {
    _fingers[event.pointer] = event.localPosition;
    _maxFingers = _fingers.length > _maxFingers ? _fingers.length : _maxFingers;
    if (_fingers.length == 1) {
      _start = event.localPosition;
      _startTime = event.timeStamp;
      _moved = false;
      _carry = 0;
      final lastTap = _lastTapEnd;
      _armedDouble =
          lastTap != null &&
          event.timeStamp - lastTap <= padDoubleTapWindow &&
          (event.localPosition - _lastTapAt).distance <= padTapSlop * 2;
      _gesture = _start.dx >= _width - padRailWidth
          ? _Gesture.scroll
          : _Gesture.idle;
      _hold?.cancel();
      if (_gesture == _Gesture.idle) {
        _hold = Timer(padHoldToDrag, _onHold);
      }
      return;
    }
    _hold?.cancel();
    if (_heldDown) return; // a drag owns the gesture until it ends
    _gesture = _Gesture.two;
    _carry = 0;
  }

  void _onHold() {
    if (_fingers.length != 1 || _moved || _gesture != _Gesture.idle) return;
    _gesture = _Gesture.drag;
    _heldDown = true;
    _sink.down(1);
    HermesHaptics.selection();
  }

  void _onMove(PointerMoveEvent event) {
    final previous = _fingers[event.pointer];
    if (previous == null) return;
    _fingers[event.pointer] = event.localPosition;
    final delta = event.localPosition - previous;
    if (_gesture == _Gesture.two) {
      // The pair moves together: the mean vertical travel scrolls.
      _scrollBy(delta.dy / _fingers.length);
      return;
    }
    if (_fingers.length != 1) return;
    if (_gesture == _Gesture.scroll) {
      _scrollBy(delta.dy);
      return;
    }
    if (_gesture == _Gesture.idle) {
      if ((event.localPosition - _start).distance <= padTapSlop) return;
      _moved = true;
      _hold?.cancel();
      if (_armedDouble) {
        _gesture = _Gesture.drag;
        _heldDown = true;
        _sink.down(1);
      } else {
        _gesture = _Gesture.move;
      }
    }
    _sink.move(delta.dx, delta.dy);
  }

  /// Content follows the fingers: dragging up scrolls down.
  void _scrollBy(double dy) {
    _moved = true;
    _carry -= dy;
    var steps = 0;
    while (_carry >= padWheelStep) {
      steps++;
      _carry -= padWheelStep;
    }
    while (_carry <= -padWheelStep) {
      steps--;
      _carry += padWheelStep;
    }
    if (steps != 0) _sink.wheel(steps);
  }

  void _onUp(PointerUpEvent event) {
    _fingers.remove(event.pointer);
    if (_fingers.isEmpty) _finish(event, cancelled: false);
  }

  void _onCancel(PointerCancelEvent event) {
    _fingers.remove(event.pointer);
    if (_fingers.isEmpty) _finish(event, cancelled: true);
  }

  void _finish(PointerEvent event, {required bool cancelled}) {
    _hold?.cancel();
    if (_heldDown) {
      _heldDown = false;
      _sink.up(1);
    } else if (!cancelled &&
        !_moved &&
        _gesture != _Gesture.scroll &&
        event.timeStamp - _startTime <= padTapMax) {
      final right = _maxFingers == 2;
      _sink.click(right ? 4 : 1);
      HermesHaptics.selection();
      if (!right) {
        _lastTapEnd = event.timeStamp;
        _lastTapAt = _start;
      }
    }
    _gesture = _Gesture.idle;
    _maxFingers = 0;
    _moved = false;
    _carry = 0;
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.surfaceHeight > 0)
          LayoutBuilder(
            builder: (context, constraints) {
              _width = constraints.maxWidth;
              return Listener(
                key: const ValueKey('screen-trackpad'),
                behavior: HitTestBehavior.opaque,
                onPointerDown: _onDown,
                onPointerMove: _onMove,
                onPointerUp: _onUp,
                onPointerCancel: _onCancel,
                child: Semantics(
                  label: strings.bsaTrackpad,
                  hint: strings.bsaPadHint,
                  container: true,
                  child: Container(
                    height: widget.surfaceHeight,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(color: colors.divider),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [colors.surface, colors.surfaceVariant],
                      ),
                    ),
                    child: Stack(
                      children: [
                        PositionedDirectional(
                          end: 10,
                          top: 16,
                          bottom: 16,
                          width: 22,
                          child: Container(
                            key: const ValueKey('screen-trackpad-rail'),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(11),
                              color: colors.surface,
                              border: Border.all(color: colors.divider),
                            ),
                            child: Icon(
                              Icons.unfold_more_rounded,
                              size: 16,
                              semanticLabel: strings.bsaPadScroll,
                              color: colors.textSecondary,
                            ),
                          ),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 12,
                          child: ExcludeSemantics(
                            child: Text(
                              strings.bsaPadHint,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.textSecondary,
                                fontSize: 10.5,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        if (widget.surfaceHeight > 0) const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              flex: 100,
              child: ScreenPill(
                key: const ValueKey('screen-pad-left'),
                label: strings.bsaClick,
                minHeight: 52,
                onTap: () => _button(1),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 60,
              child: ScreenPill(
                key: const ValueKey('screen-pad-wheel'),
                label: strings.bsaWheel,
                minHeight: 52,
                onTap: () => _button(2),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 100,
              child: ScreenPill(
                key: const ValueKey('screen-pad-right'),
                label: strings.bsaRightClick,
                minHeight: 52,
                onTap: () => _button(4),
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _button(int mask) {
    _sink.click(mask);
    HermesHaptics.selection();
  }
}
