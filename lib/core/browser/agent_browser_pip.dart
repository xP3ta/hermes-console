import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import '../widgets/workspace/chat_workspace_host.dart'
    show ChatWorkspacePaneScope;
import 'agent_browser_bridge.dart';
import 'in_app_browser_screen.dart';

/// Where the agent's browser of a chat is, over that chat (mock 138 v2).
enum AgentBrowserPipMode {
  /// Nothing over the chat.
  hidden,

  /// Only «Ver `<host>`» under the header: the window was closed while the
  /// agent works with its page.
  pill,

  /// The floating window, over the chat.
  open,

  /// The window anchored at the top as a 64 dp pill.
  docked,
}

/// The agent's browser of one chat, floating over it (mock 138 v2): the
/// agent's `preview.open` shows its page in a window instead of a screen
/// that covers the chat, so the chat, the keyboard and the queue stay in
/// reach while the agent works.
///
/// One browser per chat: closing the window lets its page go (the WebView
/// is unloaded as it is today); «Ver» opens the last page again.
class AgentBrowserPipController extends ChangeNotifier {
  AgentBrowserPipMode _mode = AgentBrowserPipMode.hidden;
  Uri? _url;
  String _label = '';
  bool _byAgent = true;
  int _generation = 0;
  double? _top;

  AgentBrowserPipMode get mode => _mode;

  /// The page the window opens on (the agent's, or the last one shown).
  Uri? get url => _url;
  String get label => _label;

  /// [url] is the agent's page.
  bool get byAgent => _byAgent;

  /// Which browser this is: a new one each time the window opens.
  int get generation => _generation;

  /// Where the user left the window; null at the top.
  double? get top => _top;

  /// The agent opened [url] with its chat on screen (mock 138 v2):
  /// «Ver `<host>`» appears under the header and one tap opens the window.
  /// A window the user already has open shows the page at once.
  void offer(Uri url, String label, {bool byAgent = true}) {
    if (_mode == AgentBrowserPipMode.open ||
        _mode == AgentBrowserPipMode.docked) {
      show(url, label, byAgent: byAgent);
      return;
    }
    _url = url;
    _label = label;
    _byAgent = byAgent;
    _top = null;
    _mode = AgentBrowserPipMode.pill;
    notifyListeners();
  }

  /// The window opens on [url] now (the user asked for it).
  void show(Uri url, String label, {bool byAgent = true}) {
    _url = url;
    _label = label;
    _byAgent = byAgent;
    _generation++;
    _top = null;
    _mode = AgentBrowserPipMode.open;
    notifyListeners();
  }

  /// «Ver»: the window again, on the last page.
  void open() {
    if (_url == null || _mode == AgentBrowserPipMode.open) return;
    if (_mode != AgentBrowserPipMode.docked) _generation++;
    _mode = AgentBrowserPipMode.open;
    notifyListeners();
  }

  void dock() {
    if (_mode != AgentBrowserPipMode.open) return;
    _mode = AgentBrowserPipMode.docked;
    _top = null;
    notifyListeners();
  }

  void undock() {
    if (_mode != AgentBrowserPipMode.docked) return;
    _mode = AgentBrowserPipMode.open;
    notifyListeners();
  }

  /// The window goes. While the agent works «Ver» stays ([keepPill]);
  /// [at] is the page it had, opened again by «Ver».
  void close({required bool keepPill, Uri? at}) {
    if (at != null) _url = at;
    final next = keepPill && _url != null
        ? AgentBrowserPipMode.pill
        : AgentBrowserPipMode.hidden;
    if (next == _mode) return;
    _mode = next;
    notifyListeners();
  }

  /// The window was dragged to [top] (layer coordinates).
  void moveTo(double top) {
    _top = top;
    notifyListeners();
  }
}

/// Sizes of the floating browser (mock 138 v2).
abstract final class AgentBrowserPipMetrics {
  /// The open window, when there is room for it.
  static const double windowHeight = 280;

  /// The anchored pill.
  static const double dockedHeight = 64;

  /// Chat left visible under the window: with less room (the keyboard is
  /// up) the window anchors itself.
  static const double minChatBelow = 120;

  /// The target the window is dropped on to close it.
  static const double closeTarget = 56;
}

/// The agent's browser over its chat: «Ver `<host>`», the floating window,
/// the anchored pill and the target that closes it. Placed over the whole
/// chat; it takes touches only where it draws.
///
/// The window stays between the header's band ([topInset]) and what the
/// chat keeps clear above its bottom bars ([bottomBars] +
/// [bottomClearance]): it never covers the header, the island or the
/// composer, and the chat under it never moves.
class AgentBrowserPipLayer extends StatefulWidget {
  const AgentBrowserPipLayer({
    required this.controller,
    required this.topInset,
    required this.bottomBars,
    required this.agentConnectionId,
    required this.agentSessionId,
    required this.changes,
    required this.working,
    required this.connected,
    required this.onExpand,
    this.bottomClearance = 0,
    this.onRetryConnection,
    this.bridge,
    super.key,
  });

  final AgentBrowserPipController controller;
  final double topInset;
  final ValueListenable<double> bottomBars;
  final double bottomClearance;

  /// The chat's connection and its runtime session, read live: the page is
  /// that agent's and no other's.
  final String agentConnectionId;
  final String? Function() agentSessionId;

  /// When [working] or [connected] may have changed.
  final Listenable changes;

  /// The agent's turn is running.
  final bool Function() working;

  /// The chat reaches Hermes.
  final bool Function() connected;

  /// «Ampliar»: the full browser on [url] ([byAgent]: the agent's page).
  final void Function(Uri url, String label, bool byAgent) onExpand;

  /// The chat's own reconnect, for «Reintentar» while it is offline.
  final VoidCallback? onRetryConnection;

  /// [AgentBrowserBridge.instance] when null (tests inject their own).
  final AgentBrowserBridge? bridge;

  @override
  State<AgentBrowserPipLayer> createState() => _AgentBrowserPipLayerState();
}

class _AgentBrowserPipLayerState extends State<AgentBrowserPipLayer> {
  final Map<int, GlobalKey<NavigatorState>> _navigators = {};
  final Map<int, _PipRootObserver> _observers = {};
  double? _dragTop;
  bool _overClose = false;

  /// The user is typing in the window (its address bar, a field of the
  /// page): it does not anchor itself away from the field when the keyboard
  /// comes up.
  bool _browserFocused = false;

  /// Wraps the window's browser: what has the focus under it is in the
  /// window.
  final FocusNode _windowFocus = FocusNode(
    debugLabel: 'agent-browser-pip',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// The bottom bars' extent this layer was last built with.
  double _bars = 0;

  /// A rebuild asked for while the frame was being built waits for its end.
  bool _rebuildScheduled = false;

  AgentBrowserBridge get _bridge =>
      widget.bridge ?? AgentBrowserBridge.instance;

  AgentBrowserPipController get _controller => widget.controller;

  AgentBrowserPage? get _page {
    final session = widget.agentSessionId();
    if (session == null) return null;
    return _bridge.pageOf(widget.agentConnectionId, session);
  }

  /// The page as the user left it, for «Ver» and «Ampliar».
  Uri? get _pageNow {
    final current = _page?.currentUrl ?? '';
    return current.isEmpty ? _controller.url : Uri.tryParse(current);
  }

  void _close() {
    _controller.close(keepPill: widget.working(), at: _pageNow);
  }

  void _expand() {
    final url = _pageNow;
    if (url == null) return;
    final byAgent = _page?.openedByAgent ?? _controller.byAgent;
    final label = _controller.label;
    // One browser: the window lets its page go, the full one opens on it.
    _controller.close(keepPill: widget.working(), at: url);
    widget.onExpand(url, label, byAgent);
  }

  @override
  void initState() {
    super.initState();
    _bars = widget.bottomBars.value;
    _controller.addListener(_rebuild);
    widget.changes.addListener(_rebuild);
    widget.bottomBars.addListener(_onBottomBars);
    FocusManager.instance.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(AgentBrowserPipLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_rebuild);
      widget.controller.addListener(_rebuild);
    }
    if (oldWidget.changes != widget.changes) {
      oldWidget.changes.removeListener(_rebuild);
      widget.changes.addListener(_rebuild);
    }
    if (oldWidget.bottomBars != widget.bottomBars) {
      oldWidget.bottomBars.removeListener(_onBottomBars);
      widget.bottomBars.addListener(_onBottomBars);
      _bars = widget.bottomBars.value;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_rebuild);
    widget.changes.removeListener(_rebuild);
    widget.bottomBars.removeListener(_onBottomBars);
    FocusManager.instance.removeListener(_onFocus);
    _windowFocus.dispose();
    super.dispose();
  }

  /// The chat writes its bottom bars' extent while it lays itself out
  /// (gint46): only a real change rebuilds, and never in the middle of
  /// that build.
  void _onBottomBars() {
    if (widget.bottomBars.value != _bars) _rebuild();
  }

  void _rebuild() {
    if (!mounted) return;
    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase != SchedulerPhase.persistentCallbacks) {
      setState(_syncBars);
      return;
    }
    if (_rebuildScheduled) return;
    _rebuildScheduled = true;
    binding.addPostFrameCallback((_) {
      _rebuildScheduled = false;
      if (mounted) setState(_syncBars);
    });
  }

  void _syncBars() => _bars = widget.bottomBars.value;

  void _onFocus() {
    final focused = _typingInWindow();
    if (focused == _browserFocused) return;
    _browserFocused = focused;
    _rebuild();
  }

  /// Something the user can type in, inside the window, has the focus. Not
  /// the window's Navigator: it focuses itself (`autofocus`) whenever
  /// nothing else in the app has the focus (gint48), which is no typing.
  bool _typingInWindow() {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || primary is FocusScopeNode) return false;
    if (!primary.ancestors.contains(_windowFocus)) return false;
    final navigator = _navigators[_controller.generation]?.currentState;
    return primary != navigator?.focusNode;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => _build(context, constraints),
    );
  }

  Widget _build(BuildContext context, BoxConstraints constraints) {
    final mode = _controller.mode;
    final url = _controller.url;
    if (mode == AgentBrowserPipMode.hidden || url == null) {
      return const SizedBox.shrink();
    }
    final top = widget.topInset + HermesSpace.x2;
    final bottom =
        constraints.maxHeight -
        _bars -
        widget.bottomClearance -
        HermesSpace.x2;
    final room = math.max(0.0, bottom - top);
    // With the keyboard up there is no room for the window and the chat:
    // it anchors itself until there is.
    final docked =
        mode == AgentBrowserPipMode.docked ||
        (!_browserFocused &&
            room <
                AgentBrowserPipMetrics.windowHeight +
                    AgentBrowserPipMetrics.minChatBelow);
    final windowShown = mode != AgentBrowserPipMode.pill;
    final height = docked
        ? AgentBrowserPipMetrics.dockedHeight
        : math.min(AgentBrowserPipMetrics.windowHeight, room);
    final maxTop = math.max(top, bottom - height);
    // Dragged, it follows the finger down onto the close target (mock 138
    // v2); let go short of it, it parks at its lowest place.
    final windowTop = docked
        ? top
        : _dragTop != null
        ? _dragTop!
              .clamp(top, maxTop + AgentBrowserPipMetrics.closeTarget)
              .toDouble()
        : (_controller.top ?? top).clamp(top, maxTop).toDouble();
    final reduce = HermesMotion.reduced(context);
    return PopScope(
      // System Back puts the window away; the chat stays.
      canPop: !windowShown,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && windowShown) _close();
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (mode == AgentBrowserPipMode.pill)
            Positioned(
              top: top,
              left: HermesSpace.x3,
              right: HermesSpace.x3,
              child: Center(
                child: _Enter(
                  key: ValueKey('agent-browser-pip-pill-$url'),
                  reduce: reduce,
                  child: _WatchPill(
                    host: url.host,
                    live: widget.working(),
                    onTap: _controller.open,
                  ),
                ),
              ),
            ),
          if (windowShown && _dragTop != null)
            Positioned(
              top: bottom - AgentBrowserPipMetrics.closeTarget,
              left: 0,
              right: 0,
              child: Center(child: _CloseTarget(hot: _overClose)),
            ),
          if (windowShown)
            Positioned(
              key: const ValueKey('agent-browser-pip'),
              top: windowTop,
              left: HermesSpace.x3,
              right: HermesSpace.x3,
              height: height,
              child: _Enter(
                key: ValueKey('agent-browser-pip-${_controller.generation}'),
                reduce: reduce,
                child: _window(
                  context,
                  url: url,
                  docked: docked,
                  dragging: _dragTop != null,
                  reduce: reduce,
                  onDrag: docked
                      ? null
                      : (dy) => _drag(dy, windowTop, top, bottom, height),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _drag(double dy, double from, double top, double bottom, double h) {
    setState(() {
      // Down past the bottom edge onto the close target, never over the
      // header.
      final next = ((_dragTop ?? from) + dy).clamp(
        top,
        math.max(top, bottom - h) + AgentBrowserPipMetrics.closeTarget,
      );
      _dragTop = next.toDouble();
      // Parked right above the composer it stays; only past that, over the
      // target, does it close.
      _overClose =
          _dragTop! >
          math.max(top, bottom - h) + AgentBrowserPipMetrics.closeTarget / 2;
    });
  }

  /// Another gesture took the touch: the window goes back to where it was,
  /// nothing is closed or anchored.
  void _dragCancel() {
    if (_dragTop == null && !_overClose) return;
    setState(() {
      _dragTop = null;
      _overClose = false;
    });
  }

  void _dragEnd(double top) {
    final at = _dragTop;
    final close = _overClose;
    setState(() {
      _dragTop = null;
      _overClose = false;
    });
    if (at == null) return;
    if (close) {
      _close();
    } else if (at <= top + HermesSpace.x8) {
      _controller.dock();
    } else {
      _controller.moveTo(at);
    }
  }

  Widget _window(
    BuildContext context, {
    required Uri url,
    required bool docked,
    required bool dragging,
    required bool reduce,
    required ValueChanged<double>? onDrag,
  }) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    final working = widget.working();
    final connected = widget.connected();
    final agentDrives = working && (_page?.openedByAgent ?? _controller.byAgent);
    final state = !connected
        ? strings.brwPipOffline
        : working
        ? strings.brwPipLive
        : strings.brwPipDone;
    final who = agentDrives
        ? strings.brwPipAgentControls
        : strings.brwPipYouControl;
    final radius = docked ? HermesRadius.tag : HermesRadius.pane;
    final top = widget.topInset + HermesSpace.x2;
    // Anchored by the user it can be opened again; anchored for want of
    // room (the keyboard is up) there is nowhere to open it.
    final userDocked = _controller.mode == AgentBrowserPipMode.docked;
    final bar = _PipBar(
      key: const ValueKey('agent-browser-pip-bar'),
      docked: docked,
      host: url.host,
      state: state,
      stateColor: !connected
          ? colors.error
          : working
          ? colors.error
          : colors.textSecondary,
      live: connected && working && !reduce,
      who: who,
      onRetry: connected ? null : widget.onRetryConnection,
      onDock: userDocked
          ? _controller.undock
          : docked
          ? null
          : _controller.dock,
      onExpand: _expand,
      onClose: _close,
      onDrag: onDrag,
      onDragEnd: () => _dragEnd(top),
      onDragCancel: _dragCancel,
    );
    final region = [strings.brwPipRegion, state, who].join(', ');
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: region,
      child: AnimatedScale(
        scale: dragging && !reduce ? 1.02 : 1,
        duration: HermesMotion.duration(context, HermesMotion.fast),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: chrome.opaque,
            shadows: chrome.shadow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius),
              side: BorderSide(
                color: connected ? chrome.line : colors.error,
              ),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                bar,
                Expanded(
                  key: const ValueKey('agent-browser-pip-page'),
                  // Anchored, the page is out of sight: the agent neither
                  // reads nor drives it until it is shown again (the bridge
                  // asks the page whether it is on screen).
                  child: Offstage(
                    offstage: docked,
                    child: TickerMode(
                      enabled: !docked,
                      // Out of sight the page keeps the size it had open,
                      // never the sliver the anchored pill leaves it.
                      child: OverflowBox(
                        alignment: Alignment.topCenter,
                        minHeight: docked ? _pageHeight : null,
                        maxHeight: docked ? _pageHeight : null,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            HermesSpace.x2,
                            0,
                            HermesSpace.x2,
                            HermesSpace.x2,
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(
                              HermesRadius.card,
                            ),
                            child: _browser(context, url),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The chat's in-app browser, as the workspace pane has it (no «Volver al
  /// chat», no background of its own), in a Navigator of its own: when the
  /// agent or the page closes it, the window goes, never the chat.
  Widget _browser(BuildContext context, Uri url) {
    final generation = _controller.generation;
    // One Navigator (and its observer: an observer serves one Navigator)
    // per browser; a new window is a new browser.
    _navigators.removeWhere((key, _) => key != generation);
    _observers.removeWhere((key, _) => key != generation);
    final navigator = _navigators.putIfAbsent(
      generation,
      () => GlobalKey<NavigatorState>(debugLabel: 'agent-browser-pip'),
    );
    final observer = _observers.putIfAbsent(
      generation,
      () => _PipRootObserver(onRootGone: _onRootGone),
    );
    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      removeBottom: true,
      removeLeft: true,
      removeRight: true,
      child: MediaQuery.removeViewInsets(
        context: context,
        removeBottom: true,
        child: Focus(
          focusNode: _windowFocus,
          child: ChatWorkspacePaneScope(
            child: Navigator(
              key: navigator,
              // Opening the window takes no focus: the composer keeps its
              // keyboard (gint47). The window counts as focused only while
              // the user types in it ([_typingInWindow]).
              requestFocus: false,
              observers: [observer],
              onGenerateRoute: (settings) => MaterialPageRoute<void>(
                settings: settings,
                builder: (_) => InAppBrowserScreen(
                  key: const ValueKey('agent-browser-pip-browser'),
                  initialUrl: url,
                  agentLabel: _controller.label,
                  openedByAgent: _controller.byAgent,
                  agentConnectionId: widget.agentConnectionId,
                  agentSessionId: widget.agentSessionId,
                  bridge: widget.bridge,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The page's height in the open window (under its bar).
  static const double _pageHeight =
      AgentBrowserPipMetrics.windowHeight - HermesSpace.tap;

  /// The agent closed its page (`preview.close`).
  void _onRootGone() {
    // After the frame: the Navigator is still finishing the pop.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.close(keepPill: false);
    });
  }
}

/// Fades and rises in once (`HermesMotion.base`, emphasized); with reduced
/// motion it is simply there.
class _Enter extends StatelessWidget {
  const _Enter({required this.reduce, required this.child, super.key});

  final bool reduce;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (reduce) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: HermesMotion.base,
      curve: HermesMotion.emphasized,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        // Tappable from its first frame, so TalkBack hears it from then too.
        alwaysIncludeSemantics: true,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * HermesSpace.x2),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// «Ver `<host>`»: the window was put away while the agent uses its page.
class _WatchPill extends StatelessWidget {
  const _WatchPill({
    required this.host,
    required this.live,
    required this.onTap,
  });

  final String host;
  final bool live;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    return Semantics(
      button: true,
      // The red dot, said: «en vivo» while Hermes works (mock 138 v2).
      label: live
          ? strings.brwPipWatchLabelLive(host)
          : strings.brwPipWatchLabel(host),
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        key: const ValueKey('agent-browser-pip-watch'),
        color: chrome.opaque,
        shape: StadiumBorder(side: BorderSide(color: chrome.line)),
        elevation: 0,
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: HermesSpace.tap),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Dot(color: live ? colors.error : colors.textSecondary),
                  const SizedBox(width: HermesSpace.x2),
                  Icon(
                    Icons.language_rounded,
                    size: HermesIcon.md,
                    color: chrome.ink,
                  ),
                  const SizedBox(width: HermesSpace.x2),
                  Flexible(
                    child: Text(
                      strings.brwPipWatch(host),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HermesType.style(HermesType.value, chrome.ink),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The window's bar: state, who drives the page and its three actions. It
/// is the handle the window is dragged by; anchored it is the whole pill.
class _PipBar extends StatelessWidget {
  const _PipBar({
    required this.docked,
    required this.host,
    required this.state,
    required this.stateColor,
    required this.live,
    required this.who,
    required this.onDock,
    required this.onExpand,
    required this.onClose,
    required this.onDrag,
    required this.onDragEnd,
    required this.onDragCancel,
    this.onRetry,
    super.key,
  });

  final bool docked;
  final String host;
  final String state;
  final Color stateColor;
  final bool live;
  final String who;
  final VoidCallback? onDock;
  final VoidCallback onExpand;
  final VoidCallback onClose;
  final ValueChanged<double>? onDrag;
  final VoidCallback onDragEnd;
  final VoidCallback onDragCancel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    final drag = onDrag;
    Widget action(String key, IconData icon, String tip, VoidCallback onTap) =>
        IconButton(
          key: ValueKey('agent-browser-pip-$key'),
          tooltip: tip,
          onPressed: onTap,
          color: chrome.ink,
          iconSize: HermesIcon.lg,
          icon: Icon(icon),
        );
    final row = SizedBox(
      height: docked
          ? AgentBrowserPipMetrics.dockedHeight - 2
          : HermesSpace.tap,
      child: Row(
        children: [
          SizedBox(width: docked ? HermesSpace.x2 : HermesSpace.x3),
          if (docked) ...[
            // No picture of the page: the WebView gives none, so the
            // anchored pill shows where it is, not what it shows.
            Container(
              width: HermesSpace.x8 + HermesSpace.x4,
              height: HermesSpace.x8 + HermesSpace.x4,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.surfaceVariant,
              ),
              child: Icon(
                Icons.language_rounded,
                size: HermesIcon.xl,
                color: chrome.mutedInk,
              ),
            ),
            const SizedBox(width: HermesSpace.x2),
          ],
          _Dot(color: stateColor, breathing: live),
          const SizedBox(width: HermesSpace.x2),
          Flexible(
            child: Text(
              state,
              key: const ValueKey('agent-browser-pip-state'),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: HermesType.style(HermesType.caption, chrome.ink),
            ),
          ),
          const SizedBox(width: HermesSpace.x2),
          Expanded(
            child: Text(
              docked ? host : who,
              key: const ValueKey('agent-browser-pip-who'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HermesType.style(HermesType.support, chrome.mutedInk),
            ),
          ),
          if (onRetry case final retry?)
            action('retry', Icons.refresh_rounded, strings.commonRetry, retry),
          if (onDock case final dock?)
            action(
              'dock',
              docked ? Icons.open_in_full_rounded : Icons.vertical_align_top,
              docked ? strings.brwPipUndock : strings.brwPipDock,
              dock,
            ),
          action(
            'expand',
            Icons.fullscreen_rounded,
            strings.brwPipExpand,
            onExpand,
          ),
          action('close', Icons.close_rounded, strings.brwPipClose, onClose),
        ],
      ),
    );
    if (drag == null) return row;
    // A pointer the system cancels mid-drag reaches the recognizer as an
    // end; this listener hears the cancel first and drops the drag, so the
    // end that follows does nothing.
    return Listener(
      onPointerCancel: (_) => onDragCancel(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (details) => drag(details.delta.dy),
        onVerticalDragEnd: (_) => onDragEnd(),
        onVerticalDragCancel: onDragCancel,
        child: row,
      ),
    );
  }
}

/// Where the window is dropped to close it, while it is dragged.
class _CloseTarget extends StatelessWidget {
  const _CloseTarget({required this.hot});

  final bool hot;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return ExcludeSemantics(
      child: Container(
        key: const ValueKey('agent-browser-pip-close-target'),
        width: AgentBrowserPipMetrics.closeTarget,
        height: AgentBrowserPipMetrics.closeTarget,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: hot ? colors.error : colors.surfaceVariant,
          border: Border.all(color: colors.error),
        ),
        child: Icon(
          Icons.close_rounded,
          size: HermesIcon.xl,
          color: hot ? colors.background : colors.error,
        ),
      ),
    );
  }
}

/// The state dot; [breathing] while the agent works (never with reduced
/// motion).
class _Dot extends StatefulWidget {
  const _Dot({required this.color, this.breathing = false});

  final Color color;
  final bool breathing;

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: HermesMotion.breath,
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_Dot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.breathing) {
      if (!_breath.isAnimating) _breath.repeat(reverse: true);
    } else {
      _breath
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween<double>(begin: 1, end: 0.45).animate(_breath),
    child: Container(
      width: HermesSpace.x2,
      height: HermesSpace.x2,
      decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
    ),
  );
}

class _PipRootObserver extends NavigatorObserver {
  _PipRootObserver({required this.onRootGone});

  final VoidCallback onRootGone;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute == null) onRootGone();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute == null) onRootGone();
  }
}
