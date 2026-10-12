import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../utils/responsive.dart';

/// Material 3 list-detail layout for tablets (Chats, Projects, Settings).
///
///  * compact (< 600dp): only [list]. Opening an item is the phone flow: a
///    full-screen route on the app navigator ([pushInDetailPane] falls back
///    to `Navigator.push`).
///  * medium (600–839dp): one pane. An open item replaces the list; Back
///    closes it and the list comes back where it was.
///  * expanded (>= 840dp): the list at [Responsive.listPaneWidth] on the
///    left and the open item on the right, or [placeholder] when none is.
///
/// The detail pane is a nested [Navigator]: the item's page keeps working as
/// it does full screen (its own pushes, `pop(result)`, Back), and opening an
/// item never pushes a route on the app navigator. The list and the pane's
/// navigator are kept under [GlobalKey]s so a rotation between medium and expanded moves
/// them instead of rebuilding them: the open page, its scroll position and
/// any typed draft survive.
class AdaptiveListDetail extends StatefulWidget {
  final Widget list;
  final Widget placeholder;

  /// Called when the window becomes compact while an item is open. The pane
  /// cannot exist on a phone-sized window, so the owner may reopen the item
  /// with its phone flow. The pane content is discarded afterwards.
  final VoidCallback? onCollapsedWithDetail;

  /// The app's route observer. Pages that subscribe to it to know whether
  /// they are visible (a chat suppressing its own notifications) keep
  /// receiving `didPush`/`didPushNext`/`didPopNext` inside the pane: pushes
  /// in the pane are forwarded to it, and so is the host screen being
  /// covered or uncovered by another app route.
  final RouteObserver<PageRoute<dynamic>>? visibilityObserver;

  const AdaptiveListDetail({
    required this.list,
    required this.placeholder,
    this.onCollapsedWithDetail,
    this.visibilityObserver,
    super.key,
  });

  @override
  State<AdaptiveListDetail> createState() => AdaptiveListDetailState();
}

class AdaptiveListDetailState extends State<AdaptiveListDetail>
    with RouteAware {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>(
    debugLabel: 'adaptive-detail-navigator',
  );
  final GlobalKey _listKey = GlobalKey(debugLabel: 'adaptive-list');
  late final _DepthObserver _depthObserver = _DepthObserver(
    _onDepthChanged,
    () => widget.visibilityObserver,
  );
  PageRoute<dynamic>? _hostRoute;

  /// Stand-in for "some app route above the host screen" when forwarding
  /// cover/uncover to [AdaptiveListDetail.visibilityObserver]. It is never
  /// installed and nothing subscribes to it.
  late final PageRoute<void> _coverRoute = PageRouteBuilder<void>(
    pageBuilder: (_, _, _) => const SizedBox.shrink(),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final observer = widget.visibilityObserver;
    final route = ModalRoute.of(context);
    if (observer != null && route is PageRoute && route != _hostRoute) {
      if (_hostRoute != null) observer.unsubscribe(this);
      _hostRoute = route;
      observer.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    if (_hostRoute != null) widget.visibilityObserver?.unsubscribe(this);
    super.dispose();
  }

  PageRoute<dynamic>? get _paneTop {
    final top = _depthObserver.top;
    return top is PageRoute && hasDetail ? top : null;
  }

  @override
  void didPushNext() {
    final top = _paneTop;
    if (top != null) widget.visibilityObserver?.didPush(_coverRoute, top);
  }

  @override
  void didPopNext() {
    final top = _paneTop;
    if (top != null) widget.visibilityObserver?.didPop(_coverRoute, top);
  }

  /// Pages open above the pane's placeholder.
  int _depth = 0;
  WindowSizeClass? _lastClass;

  /// Whether an item is open in the pane.
  bool get hasDetail => _depth > 0;

  /// Whether this layout currently shows items in its own pane (medium and
  /// expanded). When false, callers use their phone flow.
  bool get active =>
      _lastClass != null && _lastClass != WindowSizeClass.compact;

  /// Opens [route] as the pane's only page, replacing what was open.
  Future<T?> show<T extends Object?>(Route<T> route) {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) {
      return Navigator.of(context).push<T>(route);
    }
    return navigator.pushAndRemoveUntil<T>(route, (r) => r.isFirst);
  }

  /// Closes whatever is open in the pane.
  void clear() => _navigatorKey.currentState?.popUntil((r) => r.isFirst);

  void _onDepthChanged(int depth) {
    if (_depth == depth) return;
    void apply() {
      if (mounted) setState(() => _depth = depth);
    }

    // Navigator callbacks can arrive while a frame is being built (a route
    // removed during a rebuild): apply after it.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      _depth = depth;
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  @override
  Widget build(BuildContext context) {
    final sizeClass = Responsive.sizeClassOf(context);
    final previous = _lastClass;
    _lastClass = sizeClass;
    if (sizeClass == WindowSizeClass.compact) {
      if (previous != null &&
          previous != WindowSizeClass.compact &&
          hasDetail) {
        _depth = 0;
        final callback = widget.onCollapsedWithDetail;
        if (callback != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => callback());
        }
      }
      return _DetailPaneScope(
        state: this,
        active: false,
        child: KeyedSubtree(key: _listKey, child: widget.list),
      );
    }

    final list = KeyedSubtree(key: _listKey, child: widget.list);
    // The navigator's own GlobalKey moves the open page between layouts.
    final pane = KeyedSubtree(
      child: HeroControllerScope.none(
        child: Navigator(
          key: _navigatorKey,
          observers: [_depthObserver],
          onGenerateInitialRoutes: (_, _) => [
            PageRouteBuilder<void>(
              settings: const RouteSettings(name: 'detail-placeholder'),
              pageBuilder: (_, _, _) =>
                  CoveredRouteMediaQueryFreeze(child: widget.placeholder),
              transitionDuration: Duration.zero,
              reverseTransitionDuration: Duration.zero,
            ),
          ],
        ),
      ),
    );

    final Widget layout;
    if (sizeClass == WindowSizeClass.expanded) {
      layout = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: Responsive.listPaneWidth, child: list),
          VerticalDivider(
            width: 1,
            thickness: 1,
            color: Theme.of(context).hermes.divider,
          ),
          Expanded(
            child: KeyedSubtree(
              key: const ValueKey('adaptive-detail-pane'),
              child: pane,
            ),
          ),
        ],
      );
    } else {
      // Medium: one pane. Both stay mounted so switching keeps their state;
      // the hidden one neither paints, ticks nor takes input.
      layout = Stack(
        fit: StackFit.expand,
        children: [
          _Hideable(hidden: hasDetail, child: list),
          _Hideable(
            hidden: !hasDetail,
            child: KeyedSubtree(
              key: const ValueKey('adaptive-detail-pane'),
              child: pane,
            ),
          ),
        ],
      );
    }

    return _DetailPaneScope(
      state: this,
      active: true,
      // Back closes the open item (or its inner pages) before leaving the
      // screen that hosts the panes.
      child: PopScope(
        canPop: !hasDetail,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          _navigatorKey.currentState?.maybePop();
        },
        child: layout,
      ),
    );
  }
}

class _Hideable extends StatelessWidget {
  final bool hidden;
  final Widget child;

  const _Hideable({required this.hidden, required this.child});

  @override
  Widget build(BuildContext context) => Offstage(
    offstage: hidden,
    child: TickerMode(enabled: !hidden, child: child),
  );
}

/// Counts the pages open above the placeholder and forwards the pane's own
/// pushes and pops to the app route observer.
class _DepthObserver extends NavigatorObserver {
  final ValueChanged<int> onDepth;
  final RouteObserver<PageRoute<dynamic>>? Function() visibility;
  _DepthObserver(this.onDepth, this.visibility);

  final List<Route<dynamic>> _stack = [];
  Route<dynamic>? get top => _stack.isEmpty ? null : _stack.last;

  void _report() => onDepth(_stack.isEmpty ? 0 : _stack.length - 1);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
    _report();
    visibility()?.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _report();
    visibility()?.didPop(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _report();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (index >= 0 && newRoute != null) _stack[index] = newRoute;
    _report();
  }
}

class _DetailPaneScope extends InheritedWidget {
  final AdaptiveListDetailState state;
  final bool active;

  const _DetailPaneScope({
    required this.state,
    required this.active,
    required super.child,
  });

  @override
  bool updateShouldNotify(_DetailPaneScope oldWidget) =>
      active != oldWidget.active || state != oldWidget.state;
}

/// The list-detail layout [context] belongs to, when it is showing items in
/// its own pane (medium/expanded). Null on phones or outside one.
AdaptiveListDetailState? activeDetailPaneOf(BuildContext context) {
  final scope = context.getInheritedWidgetOfExactType<_DetailPaneScope>();
  if (scope == null || !scope.active) return null;
  return scope.state;
}

/// Opens [route] from a list: in the detail pane when the list sits in an
/// active [AdaptiveListDetail], otherwise exactly like `Navigator.push`.
/// Only pages go to the pane; dialogs and sheets keep their usual navigator.
Future<T?> pushInDetailPane<T extends Object?>(
  BuildContext context,
  Route<T> route,
) {
  final pane = route is PageRoute ? activeDetailPaneOf(context) : null;
  if (pane != null) return pane.show<T>(route);
  return Navigator.of(context).push<T>(route);
}
