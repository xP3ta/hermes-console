import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Tells the floating mascot when a dialog, sheet or menu (a [PopupRoute])
/// is on top of the root navigator: the mascot lives above the navigator,
/// so it hides itself instead of covering them.
///
/// Updates are published after the frame, because the navigator reports
/// routes while it builds and the overlay must not be dirtied mid-build.
class MascotRouteWatch extends NavigatorObserver {
  MascotRouteWatch();

  static final MascotRouteWatch instance = MascotRouteWatch();

  final List<Route<dynamic>> _stack = <Route<dynamic>>[];
  final ValueNotifier<bool> _modalOnTop = ValueNotifier<bool>(false);
  bool _pending = false;

  ValueListenable<bool> get modalOnTop => _modalOnTop;

  void _publish() {
    if (_pending) return;
    _pending = true;
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        _pending = false;
        final top = _stack.isEmpty ? null : _stack.last;
        _modalOnTop.value = top is PopupRoute;
      })
      ..scheduleFrame();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
    _publish();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _publish();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _publish();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (index >= 0 && newRoute != null) {
      _stack[index] = newRoute;
    } else {
      if (oldRoute != null) _stack.remove(oldRoute);
      if (newRoute != null) _stack.add(newRoute);
    }
    _publish();
  }
}
