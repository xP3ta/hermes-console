import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../../shell/dock_geometry.dart';

/// Tells the floating mascot what the root navigator shows. The mascot
/// lives above the navigator, so it has to step out by itself:
///
/// * [covered] is true while the top route is one the mascot stays out of.
///   The mascot stands only on the screens the dock belongs to
///   ([DockGeometry.carriesPet], declared by `DockScreen` wherever the dock
///   is mounted, except on the pure configuration screens); every other route covers it, from the moment it is pushed.
///   On top of that: a dialog, sheet or menu (a [PopupRoute]), any route
///   that lets the page behind show through (the app's own floating
///   surfaces and the media viewers are non-opaque page routes), or a dock
///   screen the app marked as quiet with [quietPage]. It stays true while
///   such a route is still animating away, so the mascot never shows over a
///   page that is sliding out.
/// * [settled] counts the moments the navigator came to rest on a route:
///   the mascot then looks again at where it may stand.
///
/// Updates are published after the frame, because the navigator reports
/// routes while it builds and the overlay must not be dirtied mid-build.
/// Nothing is scheduled while no route is moving.
class MascotRouteWatch extends NavigatorObserver {
  MascotRouteWatch({this.quietPage, DockGeometry? geometry})
    : _geometry = geometry ?? DockGeometry.instance {
    // A screen that declares (or stops declaring) the dock is news.
    _geometry.screensRevision.addListener(_onScreens);
  }

  static final MascotRouteWatch instance = MascotRouteWatch();

  final DockGeometry _geometry;

  void _onScreens() => _changed();

  /// Pages the mascot stays out of. Asked once per page route with the
  /// widgets at the top of its subtree, until it says yes.
  bool Function(Widget page)? quietPage;

  /// How many widgets of a page route are looked at to find its page.
  static const int probeBudget = 96;

  final List<Route<dynamic>> _stack = <Route<dynamic>>[];
  final Set<Route<dynamic>> _moving = <Route<dynamic>>{};
  final Set<Route<dynamic>> _leaving = <Route<dynamic>>{};
  final Expando<bool> _quiet = Expando<bool>('mascot-quiet-route');
  final Expando<bool> _probed = Expando<bool>('mascot-quiet-page');
  final ValueNotifier<bool> _covered = ValueNotifier<bool>(false);
  final ValueNotifier<int> _settled = ValueNotifier<int>(0);
  bool _pending = false;
  bool _dirty = false;
  int _retries = 0;

  ValueListenable<bool> get covered => _covered;
  ValueListenable<int> get settled => _settled;

  /// True while a route is animating in or out.
  bool get inTransition => _moving.isNotEmpty;

  bool _animating(Route<dynamic> route) {
    if (route is! TransitionRoute) return false;
    // For its first frame a pushed route is laid out offstage (the hero
    // flight measures it), and its animation reads as complete meanwhile.
    if (route is ModalRoute && route.isActive && route.offstage) return true;
    final status = route.animation?.status;
    return status == AnimationStatus.forward ||
        status == AnimationStatus.reverse;
  }

  /// Whether [route] is one the mascot stays out of. Null while a route
  /// that carries the dock has not built its page yet. The verdict is kept
  /// in [_quiet] so a route that is leaving can still be asked about.
  bool? _quietOf(Route<dynamic> route) {
    if (route is PopupRoute) return _quiet[route] = true;
    if (route is! ModalRoute) return _quiet[route] = false;
    if (!route.opaque) return _quiet[route] = true;
    // The whitelist: only the screens the dock belongs to. A page that has
    // not declared it (yet) is not one, which keeps the mascot out of an
    // incoming page from the first frame of its push.
    if (!_geometry.carriesPet(route)) return _quiet[route] = true;
    final probed = _probed[route];
    if (probed != null) return _quiet[route] = probed;
    final test = quietPage;
    if (test == null) return _quiet[route] = false;
    final root = route.subtreeContext;
    if (root is! Element) return null;
    var budget = probeBudget;
    var found = false;
    void visit(Element element) {
      if (found || budget-- <= 0) return;
      if (test(element.widget)) {
        found = true;
        return;
      }
      element.visitChildren(visit);
    }

    root.visitChildren(visit);
    _probed[route] = found;
    return _quiet[route] = found;
  }

  void _changed([Route<dynamic>? moved]) {
    _dirty = true;
    if (moved != null && _animating(moved)) _moving.add(moved);
    _publish(frame: true);
  }

  void _publish({bool frame = false}) {
    if (_pending) return;
    _pending = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      _moving.removeWhere((route) => !_animating(route));
      _leaving.removeWhere((route) => !_moving.contains(route));
      final top = _stack.isEmpty ? null : _stack.last;
      final quiet = top == null ? false : _quietOf(top);
      var covered = quiet ?? _covered.value;
      for (final route in _leaving) {
        if (_quiet[route] ?? false) covered = true;
      }
      _covered.value = covered;
      if (quiet == null && _retries < 3) {
        // The page is not built yet: look again after its first frame.
        _retries++;
        _publish(frame: true);
        return;
      }
      _retries = 0;
      if (_moving.isNotEmpty) {
        // A transition is running and producing frames: look again after
        // the next one. No frame is asked for.
        _publish();
        return;
      }
      if (_dirty) {
        _dirty = false;
        _settled.value++;
      }
    });
    if (frame) SchedulerBinding.instance.scheduleFrame();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // The first route of a navigator: whatever an earlier one left behind
    // (a rebuilt app) is not on screen any more.
    if (previousRoute == null) {
      _stack.clear();
      _moving.clear();
      _leaving.clear();
    }
    _stack.add(route);
    _changed(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    if (_animating(route)) _leaving.add(route);
    _changed(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _changed();
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
    _changed(newRoute);
  }
}
