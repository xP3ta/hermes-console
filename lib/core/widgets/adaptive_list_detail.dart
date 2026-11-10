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

  /// Expanded: width of the list beside the open item.
  final double listWidth;

  /// Expanded, with an item open: whether the list shows beside it. Hidden,
  /// it stays mounted (its scroll and search survive) and the item takes
  /// the whole width. Without an open item the list always shows.
  final bool listVisible;

  /// Expanded, the list hidden: shows it over the open item for a moment,
  /// without taking a column ([onDismissListOverlay] when the user taps
  /// beside it).
  final bool listOverlay;
  final VoidCallback? onDismissListOverlay;

  /// Label of the dismissable scrim behind [listOverlay].
  final String? listOverlayDismissLabel;

  /// Expanded, list beside the item: room left above and below the line
  /// between them, and how strong it is. By default a full-height divider;
  /// the Chats screen draws mock 134's short, faint line.
  final EdgeInsetsGeometry dividerMargin;
  final double dividerOpacity;

  /// Expanded, the list folded away with an item open: wraps the pane with
  /// what stands in for the list on its leading edge (the Chats screen's
  /// rail of agents). Null: the item takes the whole width.
  final Widget Function(Widget pane)? foldedListRail;

  const AdaptiveListDetail({
    required this.list,
    required this.placeholder,
    this.onCollapsedWithDetail,
    this.visibilityObserver,
    this.listWidth = Responsive.listPaneWidth,
    this.listVisible = true,
    this.listOverlay = false,
    this.onDismissListOverlay,
    this.listOverlayDismissLabel,
    this.dividerMargin = EdgeInsets.zero,
    this.dividerOpacity = 1,
    this.foldedListRail,
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
    if (previous != sizeClass) {
      // QA 9709 (Fold): what the window reports when it folds or unfolds,
      // in logcat as `[layout]`.
      debugPrint(
        '[layout] list-detail ${previous?.name ?? '-'} -> ${sizeClass.name} '
        'width=${MediaQuery.sizeOf(context).width.toStringAsFixed(0)} '
        'depth=$_depth',
      );
    }
    if (sizeClass == WindowSizeClass.compact) {
      if (previous != null && previous != WindowSizeClass.compact) {
        // The pane's navigator leaves the tree with this frame, and with
        // it every page it held: none is open any more. Its observer
        // forgets them too (a disposed navigator tells it nothing).
        final hadDetail = hasDetail;
        _depth = 0;
        _depthObserver.reset();
        final callback = widget.onCollapsedWithDetail;
        if (hadDetail && callback != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => callback());
        }
      }
      return _DetailPaneScope(
        state: this,
        active: false,
        child: KeyedSubtree(key: _listKey, child: widget.list),
      );
    }

    // The count answers to the navigator itself: one that cannot pop holds
    // only the placeholder, so nothing is open, whatever was counted. A
    // medium window must never show the placeholder in place of the list
    // (QA 9709, the owner's 2219 capture).
    final navigator = _navigatorKey.currentState;
    if (_depth > 0 && navigator != null && !navigator.canPop()) {
      _depth = 0;
      _depthObserver.keepTop();
    }

    final list = KeyedSubtree(key: _listKey, child: widget.list);
    // The navigator's own GlobalKey moves the open page between layouts.
    //
    // A semantics container of its own: every route of the pane (the
    // placeholder too) has a modal barrier, and a barrier blocks the
    // semantics of what was painted before it in the same container. Side
    // by side that was the whole list column (and, folded, the agent
    // rail): TalkBack and uiautomator saw only the placeholder (QA 9970
    // SC11, Pixel on its side: one node, «Elige una conversación…»).
    final pane = KeyedSubtree(
      child: Semantics(
        container: true,
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
      ),
    );

    final divider = Theme.of(context).hermes.divider;
    final Widget layout;
    if (sizeClass == WindowSizeClass.expanded &&
        (widget.listVisible || !hasDetail)) {
      layout = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: widget.listWidth, child: list),
          Padding(
            key: const ValueKey('adaptive-list-divider'),
            padding: widget.dividerMargin,
            child: VerticalDivider(
              width: 1,
              thickness: 1,
              color: divider.withValues(
                alpha: divider.a * widget.dividerOpacity,
              ),
            ),
          ),
          Expanded(
            child: KeyedSubtree(
              key: const ValueKey('adaptive-detail-pane'),
              child: pane,
            ),
          ),
        ],
      );
    } else if (sizeClass == WindowSizeClass.expanded) {
      // The list folded away: the open item takes the whole width. Shown
      // over it on request, it does not push it.
      final overlay = widget.listOverlay;
      final colors = Theme.of(context).hermes;
      final folded = KeyedSubtree(
        key: const ValueKey('adaptive-detail-pane'),
        child: pane,
      );
      layout = Stack(
        fit: StackFit.expand,
        children: [
          widget.foldedListRail?.call(folded) ?? folded,
          if (overlay)
            ModalBarrier(
              key: const ValueKey('adaptive-list-overlay-scrim'),
              color: Colors.black.withValues(alpha: 0.24),
              semanticsLabel: widget.listOverlayDismissLabel,
              onDismiss: widget.onDismissListOverlay,
            ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: widget.listWidth,
            child: _Hideable(
              hidden: !overlay,
              child: Material(
                key: const ValueKey('adaptive-list-overlay'),
                color: colors.background,
                elevation: 8,
                child: list,
              ),
            ),
          ),
        ],
      );
    } else {
      // Medium: one pane. Both stay mounted so switching keeps their state;
      // the hidden one neither paints, ticks nor takes input. With an item
      // open, [listOverlay] brings the list over it for a moment.
      final overlay = widget.listOverlay && hasDetail;
      layout = Stack(
        fit: StackFit.expand,
        children: [
          _Hideable(
            hidden: !hasDetail,
            child: KeyedSubtree(
              key: const ValueKey('adaptive-detail-pane'),
              child: pane,
            ),
          ),
          if (overlay)
            ModalBarrier(
              key: const ValueKey('adaptive-list-overlay-scrim'),
              color: Colors.black.withValues(alpha: 0.24),
              semanticsLabel: widget.listOverlayDismissLabel,
              onDismiss: widget.onDismissListOverlay,
            ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: overlay ? widget.listWidth : null,
            right: overlay ? null : 0,
            child: _Hideable(
              hidden: hasDetail && !overlay,
              child: overlay
                  ? Material(
                      key: const ValueKey('adaptive-list-overlay'),
                      color: Theme.of(context).hermes.background,
                      elevation: 8,
                      child: list,
                    )
                  : list,
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

  /// The pane's navigator went away (a compact window): no page is open.
  void reset() => _stack.clear();

  /// The navigator holds only its first route: that one is all there is.
  void keepTop() {
    if (_stack.length > 1) _stack.removeRange(0, _stack.length - 1);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // A push with nothing below is a navigator's first route: a new pane
    // navigator (the window widened again after a compact one). Whatever
    // the old one held is gone; counting it would leave an "open item"
    // that is only the placeholder, with the list hidden and Back eaten
    // (QA 9709, folding the Fold on Chats).
    if (previousRoute == null) _stack.clear();
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
