import 'package:flutter/widgets.dart';

/// Hands a screen its enclosing [ModalRoute] without making the screen depend
/// on the route's status.
///
/// `ModalRoute.of(context)` subscribes the caller to EVERY status change of its
/// route (`isCurrent`, `canPop`, ...), and the subscription lasts for the
/// element's lifetime, even when the call was made from a handler or a timer
/// guard. Those statuses flip exactly when another screen is pushed on top or
/// popped back, so a screen that called it anywhere was rebuilt in full in the
/// first frame of every page transition: Home rebuilt ~600 elements while the
/// dock destination it was opening built its own first frame.
///
/// Only this leaf depends on the route; its rebuild returns the same [child]
/// instance, so nothing below it rebuilds. Use [ModalRoute.isFirstOf] (an
/// aspect, notified only when that value changes) for values read in `build`.
class EnclosingRoute extends StatefulWidget {
  const EnclosingRoute({required this.onRoute, required this.child, super.key});

  /// Called with the enclosing route the first time it is known and whenever
  /// it changes (reparenting). Runs during the build phase: subscribe or
  /// store it, never `setState`.
  final ValueChanged<ModalRoute<Object?>?> onRoute;

  final Widget child;

  @override
  State<EnclosingRoute> createState() => _EnclosingRouteState();
}

class _EnclosingRouteState extends State<EnclosingRoute> {
  ModalRoute<Object?>? _route;
  bool _reported = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_reported && identical(route, _route)) return;
    _reported = true;
    _route = route;
    widget.onRoute(route);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Runs [action] once the screen above [route] has finished its pop
/// animation, in the frame after the transition's last one.
///
/// `RouteAware.didPopNext` and the future of a `Navigator.push` both fire
/// when the pop STARTS. A refresh started there rebuilds the screen being
/// uncovered inside the back transition (its loading flag at once, then the
/// answer ~100-200 ms later). Runs at once when nothing covers the route or
/// the platform asks to disable animations.
void runWhenUncovered(
  BuildContext context,
  ModalRoute<Object?>? route,
  VoidCallback action,
) {
  final cover = route?.secondaryAnimation;
  if (cover == null ||
      cover.status == AnimationStatus.dismissed ||
      (MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
    action();
    return;
  }
  void onStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    cover.removeStatusListener(onStatus);
    WidgetsBinding.instance.addPostFrameCallback((_) => action());
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  cover.addStatusListener(onStatus);
}
