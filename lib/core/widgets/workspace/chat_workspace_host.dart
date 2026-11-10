// Chat + espacio de trabajo en dos paneles (1.4.0, F4), según la maqueta v25
// (`?dev=tablet`, `?dev=fold`): chat a la izquierda, panel de trabajo con
// pestañas a la derecha, divisor arrastrable y barra flotante sólida. Con
// menos de 840 dp el mismo panel ocupa Trabajo; sin pestañas, solo el chat.
//
// El chat y el panel viven bajo GlobalKeys: al cambiar de modo (solo chat,
// dividido, solo trabajo) se reubican sin perder estado (borrador, scroll,
// la pantalla abierta en cada pestaña).
//
// Fidelidad a la v25 (1.4.0): marco dentro de la zona segura (el panel ya no
// sube bajo la barra de estado) y en tablet la navegación lateral de la app a
// la izquierda del chat.
//
// Maqueta 136 v2-A (the owner, Fold horizontal, APK 9708): el panel tiene UNA
// barra. Un selector en pastilla (Chat · Terminal · Archivos · Git ·
// Navegador, con su contador; deslizar sobre él pasa al vecino; «Chat»
// pliega el panel) y una pastilla de acciones (teclas, Herdr, ampliar, ⋯).
// Ya no hay pestañas con «+» y «×» ni barra flotante sobre el contenido.
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable, listEquals, visibleForTesting;
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerPhase;
import 'package:flutter/semantics.dart' show SemanticsService;

import '../../../l10n/app_localizations.dart';
import '../../design/hermes_design.dart'
    show
        HermesAction,
        HermesChrome,
        HermesMenuButton,
        HermesScrim;
import '../../feedback/haptics.dart';
import '../../theme/app_theme.dart';
import '../../theme/motion.dart' show HermesMotion;
import '../../utils/responsive.dart';
import 'chat_views.dart';
import 'chat_workspace.dart';

export 'chat_views.dart';

typedef ChatWorkspaceTabBuilder =
    Widget Function(BuildContext context, ChatWorkspaceTab tab);

class ChatWorkspaceHost extends StatefulWidget {
  const ChatWorkspaceHost({
    required this.controller,
    required this.chat,
    required this.tabBuilder,
    this.availableTabs = ChatWorkspaceTab.values,
    this.navigation,
    this.navigationWidth = 84,
    this.tabBadge,
    super.key,
  });

  final ChatWorkspaceController controller;
  final Widget chat;
  final ChatWorkspaceTabBuilder tabBuilder;

  /// Tabs the «+» button can open.
  final List<ChatWorkspaceTab> availableTabs;

  /// The app's side navigation (v25's dock), shown to the left of the chat
  /// while the two panes are on screen, on windows of at least
  /// [kChatWorkspaceNavigationMinWidth] that this host spans. Null: none.
  final Widget? navigation;

  /// Room [navigation] takes at the left edge, its margin included.
  final double navigationWidth;

  /// A count on a tab (v25: Git's changed files); null shows none.
  final int? Function(ChatWorkspaceTab tab)? tabBadge;

  @override
  State<ChatWorkspaceHost> createState() => _ChatWorkspaceHostState();
}

class _ChatWorkspaceHostState extends State<ChatWorkspaceHost>
    with TickerProviderStateMixin {
  final GlobalKey _chatKey = GlobalKey(debugLabel: 'chat-workspace-chat');
  final GlobalKey _workspaceKey = GlobalKey(debugLabel: 'chat-workspace-pane');
  final Map<ChatWorkspaceTab, GlobalKey<NavigatorState>> _navigators = {};
  final Map<ChatWorkspaceTab, _TabRootObserver> _observers = {};
  final Map<ChatWorkspaceTab, ValueNotifier<ChatWorkspaceToolbar>> _toolbars =
      {};
  double? _dragChatWidth;

  ChatWorkspaceController get _controller => widget.controller;

  GlobalKey<NavigatorState> _navigatorFor(ChatWorkspaceTab tab) =>
      _navigators.putIfAbsent(
        tab,
        () => GlobalKey<NavigatorState>(debugLabel: 'workspace-${tab.name}'),
      );

  /// Closes [tab] when its first screen leaves (e.g. App Lock cancelled),
  /// instead of leaving an empty pane (review P1-F4-2).
  _TabRootObserver _observerFor(ChatWorkspaceTab tab) => _observers.putIfAbsent(
    tab,
    () => _TabRootObserver(
      onRootGone: () => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _controller.close(tab);
      }),
    ),
  );

  /// What [tab]'s screen adds to the pane's bar.
  ValueNotifier<ChatWorkspaceToolbar> _toolbarFor(ChatWorkspaceTab tab) =>
      _toolbars.putIfAbsent(
        tab,
        () => ValueNotifier(ChatWorkspaceToolbar.none),
      );

  /// the owner (Fold horizontal, APK 9708): with the keyboard up the pane that
  /// does not have the focus folds to a thin rail and the one that has it
  /// takes the whole width. Which pane holds the focus, followed as it
  /// moves; the keyboard itself is read when the panes are laid out.
  _FocusSide _focusSide = _FocusSide.none;

  /// One focus node around each pane, never focused itself: which pane
  /// holds the focus is read from the focus tree, never by walking the
  /// elements, which may be on their way out (gate gint37: a drawer closing
  /// left the primary focus on a deactivated element).
  final FocusNode _chatFocus = FocusNode(
    debugLabel: 'chat-workspace-chat',
    canRequestFocus: false,
    skipTraversal: true,
  );
  final FocusNode _workspaceFocus = FocusNode(
    debugLabel: 'chat-workspace-pane',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// Ola 7 (v25 `.sheet`): the pane comes in from the right edge beside
  /// the chat, and goes out the same way when it folds. 1 is in place.
  late final AnimationController _paneMotion = AnimationController(
    vsync: this,
    value: 1,
    duration: HermesMotion.sheetOpen,
    reverseDuration: HermesMotion.sheetClose,
  )..addStatusListener(_onPaneMotion);
  late final CurvedAnimation _paneCurve = CurvedAnimation(
    parent: _paneMotion,
    curve: HermesMotion.emphasized,
    reverseCurve: HermesMotion.exit.flipped,
  );

  /// the owner (APK 9708; 9714, ORDEN-Q9-ORIENTACION): with the keyboard up the
  /// pane typed in takes the width, and when the keyboard goes it is back
  /// where it was, both in [HermesMotion.base] (a clean cut with «reduce
  /// motion»). The panes are laid out at once at their new size, so a
  /// terminal is never resized frame by frame; only where they are drawn
  /// moves. 1 is folded.
  late final AnimationController _keyboardMotion = AnimationController(
    vsync: this,
    duration: HermesMotion.base,
  );
  late final CurvedAnimation _keyboardCurve = CurvedAnimation(
    parent: _keyboardMotion,
    curve: HermesMotion.standard,
  );

  /// The keyboard fold of the chosen layout, and the side the motion moves
  /// (the one folding, or the one coming back). A narrow window drawing
  /// Trabajo temporarily does not close the keyboard fold.
  _FocusSide _folded = _FocusSide.none;
  _FocusSide _motionSide = _FocusSide.none;
  int _keyboardFoldRevision = 0;

  /// Choosing Chat or closing the last panel abandons the keyboard
  /// episode, including callbacks queued before this build. It is not a
  /// keyboard restoration: the panel has left. Clear the paint state now
  /// and reset the controller after the frame, before a later reopening.
  void _resetKeyboardFold() {
    if (_folded == _FocusSide.none &&
        _motionSide == _FocusSide.none &&
        !_keyboardMotion.isAnimating &&
        _keyboardMotion.value == 0) {
      return;
    }
    _folded = _FocusSide.none;
    _motionSide = _FocusSide.none;
    final revision = ++_keyboardFoldRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _keyboardFoldRevision) return;
      _keyboardMotion
        ..stop()
        ..value = 0;
    });
  }

  /// Started once the frame that changed the fold is laid out, never
  /// during it (gint56). TalkBack hears it once: the panel typed in grew,
  /// or is back.
  void _keyboardFoldChanged(_FocusSide from, _FocusSide to) {
    final folding = to != _FocusSide.none;
    if (_reduce) {
      _keyboardMotion.value = folding ? 1 : 0;
    } else if (folding) {
      _keyboardMotion.forward(from: 0);
    } else {
      _keyboardMotion.reverse(from: 1);
    }
    final tab = _controller.active;
    if (tab == null) return;
    final strings = Strings.of(context);
    final name = chatWorkspaceTabLabel(strings, tab);
    final said = to == _FocusSide.workspace
        ? strings.cwsPanelExpanded(name)
        : from == _FocusSide.workspace && to == _FocusSide.none
        ? strings.cwsPanelRestored(name)
        : null;
    if (said == null) return;
    SemanticsService.sendAnnouncement(
      View.of(context),
      said,
      Directionality.of(context),
    );
  }

  /// [child] drawn [shift] dp along the row from where it is laid out, as
  /// much as [away] says (1 all of it, 0 none), and as opaque as [opacity].
  Widget _inKeyboardMotion(
    Widget child, {
    double Function() shift = _none,
    double Function() opacity = _whole,
  }) => AnimatedBuilder(
    animation: _keyboardCurve,
    builder: (context, child) => Opacity(
      opacity: opacity(),
      child: Transform.translate(offset: Offset(shift(), 0), child: child),
    ),
    child: child,
  );

  static double _none() => 0;
  static double _whole() => 1;

  /// The layout last drawn: whether the pane was on screen. Null before the
  /// first one: a pane already open when the chat is built is just there.
  ChatWorkspaceMode? _drawn;

  /// While the pane goes out (the mode is already «Solo chat»), the layout
  /// it leaves from.
  ChatWorkspaceMode? _leaving;

  /// «Reduce motion», as the last build read it.
  bool _reduce = false;

  void _onPaneMotion(AnimationStatus status) {
    if (status != AnimationStatus.dismissed || _leaving == null) return;
    // Out at the end of a frame's animations: drawn in that same frame.
    // Out while a frame is built (never expected): after it.
    final binding = WidgetsBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      binding.addPostFrameCallback((_) => _paneGone());
    } else {
      _paneGone();
    }
  }

  void _paneGone() {
    if (!mounted || _leaving == null) return;
    setState(() {
      _leaving = null;
      _drawn = ChatWorkspaceMode.chat;
    });
  }

  /// The views changed (gint56: decided here, when they change, never
  /// while the panes are laid out): the pane starts its way in when it
  /// appears and its way out when it folds. Only beside the chat on a
  /// wide window; a narrow one, or reduced motion, change at once.
  void _onViews() {
    final binding = WidgetsBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      // Changed while a frame is built: decided once it is done.
      binding.addPostFrameCallback((_) {
        if (mounted) _startPaneMotion();
      });
      return;
    }
    _startPaneMotion();
  }

  void _startPaneMotion() {
    final previous = _drawn;
    final width = _controller.layoutWidth;
    final fits = width != null && chatWorkspaceSplitFits(width);
    final shown =
        _controller.hasWorkspace && _controller.mode != ChatWorkspaceMode.chat;
    if (!fits || previous == null || _reduce) {
      _leaving = null;
      if (_paneMotion.isAnimating || _paneMotion.value != 1) {
        _paneMotion.value = 1;
      }
    } else if (shown) {
      if (_leaving != null || previous == ChatWorkspaceMode.chat) {
        // In, or back in from half way out.
        final from = _leaving != null ? _paneMotion.value : 0.0;
        _leaving = null;
        _paneMotion.forward(from: from);
      }
    } else if (_controller.hasWorkspace &&
        _leaving == null &&
        previous != ChatWorkspaceMode.chat &&
        _paneMotion.value > 0) {
      _leaving = previous;
      _paneMotion.reverse(from: _paneMotion.value);
    }
  }

  /// Which layout the panes draw: the one the pane leaves from while it
  /// goes out. Only reads; the motion is started in [_onViews].
  ChatWorkspaceMode _layoutMode(ChatWorkspaceMode mode, {required bool fits}) {
    final leaving = fits ? _leaving : null;
    return _drawn = mode == ChatWorkspaceMode.chat ? leaving ?? mode : mode;
  }

  /// The pane on its way in or out: from beyond the right edge, fading in.
  Widget _paneInMotion(Widget pane) => FadeTransition(
    opacity: _paneCurve,
    child: SlideTransition(
      position: _paneCurve.drive(
        Tween(begin: const Offset(1, 0), end: Offset.zero),
      ),
      child: pane,
    ),
  );

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocusMoved);
    _controller.addListener(_onViews);
  }

  @override
  void didUpdateWidget(ChatWorkspaceHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    oldWidget.controller.removeListener(_onViews);
    widget.controller.addListener(_onViews);
  }

  @override
  void dispose() {
    _controller.removeListener(_onViews);
    _paneCurve.dispose();
    _paneMotion.dispose();
    _keyboardCurve.dispose();
    _keyboardMotion.dispose();
    FocusManager.instance.removeListener(_onFocusMoved);
    _chatFocus.dispose();
    _workspaceFocus.dispose();
    for (final toolbar in _toolbars.values) {
      toolbar.dispose();
    }
    super.dispose();
  }

  /// Focus may move while a frame is built (autofocus): the side is
  /// re-read and applied after it.
  void _onFocusMoved() {
    if (_sideOfFocus() == _focusSide) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final side = _sideOfFocus();
      if (side != _focusSide) setState(() => _focusSide = side);
    });
  }

  _FocusSide _sideOfFocus() {
    // A scope holding the focus is a screen, not something being typed in:
    // a panel's first screen takes it when the panel opens (gate gint37,
    // the split folded on a keyboard brought up by something else).
    if (FocusManager.instance.primaryFocus is FocusScopeNode) {
      return _FocusSide.none;
    }
    if (_workspaceFocus.hasFocus) return _FocusSide.workspace;
    if (_chatFocus.hasFocus) return _FocusSide.chat;
    return _FocusSide.none;
  }

  /// A pane inside its focus node ([_sideOfFocus]).
  Widget _focusRegion(FocusNode node, Widget child) => Focus(
    focusNode: node,
    canRequestFocus: false,
    skipTraversal: true,
    includeSemantics: false,
    child: child,
  );

  Widget get _chatPane => KeyedSubtree(
    key: _chatKey,
    child: _focusRegion(_chatFocus, widget.chat),
  );

  /// The rail of a folded pane: the keyboard goes, and with it the fold.
  void _leaveKeyboardFold() => FocusManager.instance.primaryFocus?.unfocus();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      // No tab and a window too narrow to split (every phone): the chat is
      // built in the build phase, as it always was, not during a
      // LayoutBuilder's layout (review R5A P2-B1-3). The same GlobalKey
      // moves it when the workspace is needed. Rebuilt when the window
      // size changes.
      MediaQuery.sizeOf(context);
      _reduce = HermesMotion.reduced(context);
      if (!_controller.workspaceVisible) _resetKeyboardFold();
      final window = chatWorkspaceWindowWidth(context);
      if (!_controller.hasWorkspace && !chatWorkspaceSplitFits(window)) {
        _controller.layoutWidth = window;
        _drawn = ChatWorkspaceMode.chat;
        _leaving = null;
        return _chatPane;
      }
      return LayoutBuilder(builder: _layout);
    },
  );

  Widget _layout(BuildContext context, BoxConstraints constraints) {
    _controller.layoutWidth = constraints.maxWidth;
    final chat = _chatPane;
    // Never opened: the chat as it always was. QA 9709 (v3, the owner): no
    // handle at the screen's edges; the list and the workspace come back
    // from the chat's header (its list button and «Vistas»).
    if (!_controller.hasWorkspace) {
      _drawn = ChatWorkspaceMode.chat;
      _leaving = null;
      return chat;
    }
    _navigators.removeWhere((tab, _) => !_controller.tabs.contains(tab));
    _observers.removeWhere((tab, _) => !_controller.tabs.contains(tab));
    // A closed tab's controls go with its screen (after this frame: the bar
    // may be listening). The notifier stays for when the tab comes back.
    for (final MapEntry(key: tab, value: toolbar) in _toolbars.entries) {
      if (_controller.tabs.contains(tab) ||
          identical(toolbar.value, ChatWorkspaceToolbar.none)) {
        continue;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_controller.tabs.contains(tab)) {
          toolbar.value = ChatWorkspaceToolbar.none;
        }
      });
    }

    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    final fits = width.isFinite && chatWorkspaceSplitFits(width);
    // the owner (9714, ORDEN-Q9-ORIENTACION 2): turned upright or folded with a
    // panel showing, the panel used to go and leave the chat. Where nothing
    // fits beside the chat, a panel that was showing takes the screen
    // («Trabajo»), the same one with its session; where it fits again the
    // layout chosen comes back (the controller's mode never changed).
    // QA9716: opening directly while upright uses this same pane, bar and
    // navigator as a split turned upright. There is no second modal panel
    // on top of a hidden Terminal (P1-F4-1).
    final mode = _layoutMode(
      fits
          ? _controller.mode
          : _controller.workspaceVisible
          ? ChatWorkspaceMode.workspace
          : ChatWorkspaceMode.chat,
      fits: fits,
    );

    Widget workspacePane({required bool hidden}) => KeyedSubtree(
      key: _workspaceKey,
      child: _focusRegion(
        _workspaceFocus,
        _WorkspacePane(
          controller: _controller,
          tabBuilder: widget.tabBuilder,
          availableTabs: widget.availableTabs,
          tabBadge: widget.tabBadge,
          navigatorFor: _navigatorFor,
          observerFor: _observerFor,
          toolbarFor: _toolbarFor,
          hidden: hidden,
          compact: !fits,
        ),
      ),
    );

    if (mode == ChatWorkspaceMode.chat) {
      // Chat only (folded, or too narrow): the chat alone. The workspace
      // stays mounted out of sight, so the Browser's page, the Files folder
      // and the Git diff are still there when it comes back (review R5A
      // P2-B1-1). All but the Terminal: kept alive off screen it became a
      // second screen on the same session once Terminal opened full screen,
      // fighting the visible one over the pty size and the reconnection
      // (review P1-F4-1). Its tab stays listed and is built again when
      // shown; the SSH session lives in the service, so nothing is lost.
      return Stack(
        fit: StackFit.expand,
        children: [
          chat,
          Offstage(
            child: TickerMode(
              enabled: false,
              child: ExcludeFocus(child: workspacePane(hidden: true)),
            ),
          ),
        ],
      );
    }

    final colors = Theme.of(context).hermes;
    final window = MediaQuery.sizeOf(context);
    final spansWindow = width >= window.width - 0.5;
    // v25's frame sits inside the safe area: the panes no longer run under
    // the status bar, where the floating bar covered the battery.
    final safe = MediaQuery.paddingOf(context);
    final showNavigation =
        widget.navigation != null &&
        spansWindow &&
        width >= kChatWorkspaceNavigationMinWidth;
    final lead = safe.left + (showNavigation ? widget.navigationWidth : 0);
    final usableWidth = math.max(0.0, width - lead - safe.right);
    final usableHeight = math.max(0.0, height - safe.top - safe.bottom);

    final workspace = workspacePane(hidden: false);

    // The hinge is in window coordinates: only usable when this host spans
    // the window (a chat inside a list-detail pane ignores it). Shifted to
    // where the panes start.
    final hinge = spansWindow
        ? chatWorkspaceHinge(
            MediaQuery.displayFeaturesOf(context),
            window,
          )?.translate(-lead, 0)
        : null;
    final ratio = _controller.ratioFor();
    final geometry = ChatWorkspaceGeometry.compute(
      width: usableWidth,
      ratio: ratio,
      hinge: hinge,
    );
    const pad = ChatWorkspaceGeometry.padding;
    final paneHeight = math.max(0.0, usableHeight - 2 * pad);
    final framePadding = EdgeInsets.fromLTRB(
      lead + pad,
      safe.top + pad,
      safe.right + pad,
      safe.bottom + pad,
    );

    Widget frame(Widget panes) => ColoredBox(
      color: colors.background,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Padding(padding: framePadding, child: panes),
          if (showNavigation)
            Positioned(
              key: const ValueKey('chat-workspace-navigation'),
              left: 0,
              top: 0,
              bottom: 0,
              width: lead,
              child: widget.navigation!,
            ),
        ],
      ),
    );

    // the owner (APK 9708): with the keyboard up the pane without the focus
    // folds to a rail and the one with it takes the width; when the
    // keyboard closes the split comes back by itself. A hinge keeps its
    // split.
    final keyboardFocus =
        _controller.mode == ChatWorkspaceMode.split &&
            chatWorkspaceKeyboardUp(context) &&
            !geometry.lockedToHinge
        ? _focusSide
        : _FocusSide.none;
    if (keyboardFocus != _folded) {
      final from = _folded;
      _folded = keyboardFocus;
      _motionSide = keyboardFocus == _FocusSide.none ? from : keyboardFocus;
      final revision = ++_keyboardFoldRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && revision == _keyboardFoldRevision) {
          _keyboardFoldChanged(from, keyboardFocus);
        }
      });
    }
    // Width can temporarily draw Trabajo while the chosen split, keyboard
    // and focus stay the same. Only the real keyboard/focus transition
    // starts the motion and announcement; the drawn mode selects the rail
    // and geometry, including its explicit Chat action when narrow.
    final keyboardFold = mode == ChatWorkspaceMode.split
        ? keyboardFocus
        : _FocusSide.none;
    // How far the pane typed in moves: from beside the chat to beside its
    // rail. Along the row: to the left, or to the right right to left.
    final along = Directionality.of(context) == TextDirection.rtl ? -1.0 : 1.0;
    final travel =
        along *
        math.max(0.0, geometry.chatWidth - ChatWorkspaceGeometry.rail);
    double v() => _keyboardCurve.value;

    if (mode == ChatWorkspaceMode.workspace ||
        keyboardFold == _FocusSide.workspace) {
      // The chat folds into a rail only where there is room for it beside the
      // panel: 600 dp and up (landscape, an open Fold, a tablet). On a compact
      // width (a phone upright, the folded cover screen) the panel is the whole
      // screen, like a link opened in the in-app browser: no rail, and the
      // chat segment of the pane's own bar (or Back) returns to it.
      // Decided from this build's constraints, so a turn of the phone or a
      // fold/unfold draws the other layout at once; the chat, the panel and
      // every tab keep their state across it.
      final railed = width.isFinite && width >= Responsive.tabletBreakpoint;
      final chrome = railed
          ? ChatWorkspaceGeometry.rail + ChatWorkspaceGeometry.divider
          : 0.0;
      final workspaceWidth = math.max(0.0, usableWidth - 2 * pad - chrome);
      return Stack(
        fit: StackFit.expand,
        children: [
          // The chat keeps its state while folded into the rail.
          Offstage(
            child: TickerMode(
              enabled: false,
              child: SizedBox(width: width, height: height, child: chat),
            ),
          ),
          frame(
            Row(
              children: [
                if (railed) ...[
                  _inKeyboardMotion(
                    _ChatRail(
                      onShowChat: keyboardFold == _FocusSide.workspace
                          ? _leaveKeyboardFold
                          // Where the split does not fit, the chat alone.
                          : () => _controller.setMode(
                              fits
                                  ? ChatWorkspaceMode.split
                                  : ChatWorkspaceMode.chat,
                            ),
                    ),
                    opacity: keyboardFold == _FocusSide.workspace ? v : _whole,
                  ),
                  const SizedBox(width: ChatWorkspaceGeometry.divider),
                ],
                _inKeyboardMotion(
                  _paneInMotion(
                    _paneBox(
                      context,
                      width: workspaceWidth,
                      height: paneHeight,
                      child: workspace,
                      workspace: true,
                    ),
                  ),
                  // From where it was beside the chat to the full width.
                  shift: keyboardFold == _FocusSide.workspace
                      ? () => travel * (1 - v())
                      : _none,
                ),
              ],
            ),
          ),
        ],
      );
    }

    if (keyboardFold == _FocusSide.chat) {
      const chrome = ChatWorkspaceGeometry.rail + ChatWorkspaceGeometry.divider;
      final chatWidth = math.max(0.0, usableWidth - 2 * pad - chrome);
      return Stack(
        fit: StackFit.expand,
        children: [
          // The pane keeps its state and its size (the terminal's rows and
          // columns do not change) while folded into the rail.
          Offstage(
            child: TickerMode(
              enabled: false,
              child: SizedBox(
                width: geometry.workspaceWidth,
                height: paneHeight,
                child: workspace,
              ),
            ),
          ),
          frame(
            Row(
              children: [
                _paneBox(
                  context,
                  width: chatWidth,
                  height: paneHeight,
                  child: chat,
                ),
                const SizedBox(width: ChatWorkspaceGeometry.divider),
                _inKeyboardMotion(
                  _PaneRail(
                    tab: _controller.active,
                    onShowPane: _leaveKeyboardFold,
                  ),
                  opacity: v,
                ),
              ],
            ),
          ),
        ],
      );
    }

    final chatWidth = geometry.chatWidth;
    // The chat's share as laid out, not as stored: the panes' floor can
    // keep it from the stored ratio (review R5A P3-B1-4).
    final available = math.max(1.0, chatWidth + geometry.workspaceWidth);
    final share = chatWidth / available;
    double shareAt(double ratio) {
      final at = ChatWorkspaceGeometry.compute(
        width: usableWidth,
        ratio: ratio,
        hinge: hinge,
      );
      return at.chatWidth / available;
    }

    return frame(
      Row(
        children: [
          // On the way back from a keyboard fold: the chat comes back in
          // where the pane typed in was, and that pane slides back.
          _inKeyboardMotion(
            _paneBox(
              context,
              width: chatWidth,
              height: paneHeight,
              child: chat,
            ),
            opacity: () =>
                _motionSide == _FocusSide.workspace ? 1 - v() : 1,
          ),
          _Divider(
            width: geometry.dividerWidth,
            locked: geometry.lockedToHinge,
            dragging: _dragChatWidth != null,
            chatShare: share,
            shareAfterStep: (step) => shareAt(share + step),
            onDragStart: () => setState(() => _dragChatWidth = chatWidth),
            onDragUpdate: (dx) {
              // Within what the panes allow: dragging back past the limit
              // moves the divider at once (review R5A P3-B1-6).
              final (low, high) = ChatWorkspaceGeometry.chatWidthRange(
                usableWidth,
              );
              final moved = (_dragChatWidth ?? chatWidth) + dx;
              final next = moved.clamp(low, high).toDouble();
              _dragChatWidth = next;
              _controller.setRatio(
                ChatWorkspaceGeometry.ratioForChatWidth(next, usableWidth),
              );
            },
            onDragEnd: () {
              setState(() => _dragChatWidth = null);
              _controller.commitRatio();
            },
            onReset: _controller.resetRatio,
            onStep: (step) {
              _controller.setRatio(share + step);
              _controller.commitRatio();
            },
          ),
          _inKeyboardMotion(
            _paneInMotion(
              _paneBox(
                context,
                width: geometry.workspaceWidth,
                height: paneHeight,
                child: workspace,
                workspace: true,
              ),
            ),
            shift: () =>
                _motionSide == _FocusSide.workspace ? -travel * v() : 0,
            opacity: () => _motionSide == _FocusSide.chat ? 1 - v() : 1,
          ),
        ],
      ),
    );
  }

  /// A rounded pane whose content sees its own size as the screen size, so
  /// width-based layouts inside it (chat bubbles, `Responsive`) fit the pane.
  /// The frame already keeps the panes inside the safe area, so their
  /// content gets no system padding of its own (the keyboard inset stays).
  Widget _paneBox(
    BuildContext context, {
    required double width,
    required double height,
    required Widget child,
    bool workspace = false,
  }) {
    final media = MediaQuery.of(context);
    return SizedBox(
      width: width,
      height: height,
      child: _WorkspacePaneSurface(
        frameKey: workspace
            ? const ValueKey('chat-workspace-panel-frame')
            : null,
        clipKey: workspace ? const ValueKey('chat-workspace-panel-clip') : null,
        child: MediaQuery(
          data: media.copyWith(
            size: Size(width, height),
            padding: EdgeInsets.zero,
            viewPadding: EdgeInsets.zero,
          ),
          // The host sits above the chat's Scaffold, so nothing above a
          // pane is Material: the tab strip's + menu and other ink buttons
          // threw 'No Material widget found' (gate gint5). A transparent
          // Material gives them one without changing how the pane looks.
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

/// The approved split's frame, also used when a panel opens over the chat.
/// Keep its paint and clip together so a compact panel cannot lose its
/// bottom corners or acquire another palette (QA 9715).
class _WorkspacePaneSurface extends StatelessWidget {
  const _WorkspacePaneSurface({
    required this.child,
    this.frameKey,
    this.clipKey,
  });

  final Widget child;
  final Key? frameKey;
  final Key? clipKey;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final radius = BorderRadius.circular(chatWorkspacePaneRadius);
    return DecoratedBox(
      key: frameKey,
      decoration: BoxDecoration(
        color: colors.surface,
        // Mock 136 v2-A `.pane`: a hairline edge. The shadow alone does not
        // show on a dark page.
        border: Border.all(color: HermesChrome.of(colors).line),
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      // The hairline is painted again above the content: a pane whose body is
      // opaque (the browser page, the terminal) covers the border that lies
      // under the clip, and the frame looked cut where the body began.
      child: Stack(
        children: [
          ClipRRect(key: clipKey, borderRadius: radius, child: child),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                key: const ValueKey('chat-workspace-pane-edge'),
                decoration: ShapeDecoration(
                  shape: RoundedRectangleBorder(
                    borderRadius: radius,
                    side: BorderSide(color: HermesChrome.of(colors).line),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The pane frame on its own, for tests.
@visibleForTesting
Widget debugWorkspacePaneSurface({required Widget child}) =>
    _WorkspacePaneSurface(child: child);

/// The panes' corners (mock 136 v2-A's token).
const double chatWorkspacePaneRadius = ChatWorkspaceTokens.paneRadius;

/// Whether the keyboard is up over this window. A screen around the chat
/// may already have taken it out of the MediaQuery: an outer Scaffold that
/// makes room for it (the Chats screen beside the chat on the open Fold,
/// the owner's capture 1659) leaves the panes lower but tells them of no
/// keyboard, so nothing folded and both panes were squeezed under it. The
/// window still has it.
bool chatWorkspaceKeyboardUp(BuildContext context) {
  if (MediaQuery.viewInsetsOf(context).bottom > 0) return true;
  final view = View.maybeOf(context);
  return view != null && view.viewInsets.bottom > 0;
}

/// Width of the window this [context] is in. A pane's content sees its own
/// size as the screen's ([MediaQuery.sizeOf]); what fits side by side is
/// decided on the real window.
double chatWorkspaceWindowWidth(BuildContext context) {
  final view = View.of(context);
  return view.physicalSize.width / view.devicePixelRatio;
}

/// The tab the workspace opens on from a handle or «Vistas»: the one in
/// use or last chosen when [available] offers it, else the first offered.
ChatWorkspaceTab? chatWorkspaceTabFor(
  ChatWorkspaceController controller,
  List<ChatWorkspaceTab> available,
) {
  final preferred = controller.preferredTab;
  if (preferred != null && available.contains(preferred)) return preferred;
  return available.firstOrNull;
}

/// Shares the screen's views controller with what it holds: the Chats
/// screen's list host and the chat open beside it use the same one (one
/// model of views, mock 134).
class ChatWorkspaceScope extends InheritedNotifier<ChatWorkspaceController> {
  const ChatWorkspaceScope({
    required ChatWorkspaceController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  /// The screen's controller, if this [context] is inside one. Does not
  /// rebuild [context] on changes: listen to the controller for that.
  static ChatWorkspaceController? maybeOf(BuildContext context) =>
      (context
                  .getElementForInheritedWidgetOfExactType<ChatWorkspaceScope>()
                  ?.widget
              as ChatWorkspaceScope?)
          ?.notifier;
}

/// Mock 136 v2-A on a narrow screen (a phone, the open Fold held upright):
/// a panel opens as a bottom sheet over the dimmed chat, with the same
/// rounded frame as the split and 92 % of the height, instead of a page
/// on top of it. Back, a tap on the dimmed chat or the
/// screen's own way back closes it. Not draggable: the terminal and the
/// lists inside use the vertical drags. The screen in it keeps the
/// keyboard's inset (its Scaffold sizes itself above the keyboard).
Future<T?> showChatWorkspaceSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  enableDrag: false,
  // Material 3 otherwise caps a sheet at 640 dp even on the upright Fold.
  // The panel uses the available width, with only the frame's small inset.
  constraints: const BoxConstraints(maxWidth: double.infinity),
  backgroundColor: Colors.transparent,
  elevation: 0,
  barrierColor: HermesScrim.sheet.color,
  builder: (sheetContext) {
    final colors = Theme.of(sheetContext).hermes;
    const pad = ChatWorkspaceGeometry.padding;
    final bottom = math.max(pad, MediaQuery.paddingOf(sheetContext).bottom);
    return FractionallySizedBox(
      heightFactor: 0.92,
      child: Padding(
        padding: EdgeInsets.fromLTRB(pad, 0, pad, bottom),
        child: Column(
          children: [
            // A grabber that says «sheet»; the sheet itself stays put.
            ExcludeSemantics(
              child: Container(
                width: 40,
                height: 5,
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: colors.textDisabled,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            Expanded(
              child: _WorkspacePaneSurface(
                frameKey: const ValueKey('chat-workspace-sheet-frame'),
                clipKey: const ValueKey('chat-workspace-sheet'),
                child: MediaQuery.removePadding(
                  context: sheetContext,
                  removeTop: true,
                  // The frame has already made room for the system area.
                  // Keep viewInsets: the screen still handles its keyboard.
                  removeBottom: true,
                  child: Material(
                    type: MaterialType.transparency,
                    child: _ChatWorkspaceSheetScope(
                      child: Builder(builder: builder),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  },
);

class _Divider extends StatelessWidget {
  const _Divider({
    required this.width,
    required this.locked,
    required this.dragging,
    required this.chatShare,
    required this.shareAfterStep,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onReset,
    required this.onStep,
  });

  final double width;
  final bool locked;
  final bool dragging;
  /// The chat's share as laid out.
  final double chatShare;

  /// The share one step (±[step]) would really give: the same at a limit.
  final double Function(double step) shareAfterStep;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onReset;
  final ValueChanged<double> onStep;

  static const double step = 0.05;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    int percent(double share) =>
        (ChatWorkspaceController.clampRatio(share) * 100).round();
    final grip = Container(
      width: 4,
      height: dragging ? 64 : 44,
      decoration: BoxDecoration(
        color: dragging ? colors.accent : colors.textDisabled,
        borderRadius: BorderRadius.circular(4),
      ),
    );
    final increased = shareAfterStep(step);
    final decreased = shareAfterStep(-step);
    final canIncrease = percent(increased) > percent(chatShare);
    final canDecrease = percent(decreased) < percent(chatShare);
    if (locked) {
      // The hinge splits the screen: nothing to drag.
      return SizedBox(
        key: const ValueKey('chat-workspace-divider'),
        width: width,
      );
    }
    return Semantics(
      container: true,
      slider: true,
      label: strings.cwsDivider,
      value: strings.cwsChatShare(percent(chatShare)),
      // A step that moves nothing (at a limit) is not offered.
      increasedValue: canIncrease
          ? strings.cwsChatShare(percent(increased))
          : null,
      decreasedValue: canDecrease
          ? strings.cwsChatShare(percent(decreased))
          : null,
      onIncrease: canIncrease ? () => onStep(step) : null,
      onDecrease: canDecrease ? () => onStep(-step) : null,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          key: const ValueKey('chat-workspace-divider'),
          behavior: HitTestBehavior.opaque,
          // The divider follows the finger from the first touch (the slop
          // is not lost).
          dragStartBehavior: DragStartBehavior.down,
          onHorizontalDragStart: (_) => onDragStart(),
          onHorizontalDragUpdate: (d) => onDragUpdate(d.delta.dx),
          onHorizontalDragEnd: (_) => onDragEnd(),
          onHorizontalDragCancel: onDragEnd,
          onDoubleTap: onReset,
          child: SizedBox(width: width, child: Center(child: grip)),
        ),
      ),
    );
  }
}

/// v25 «Solo trabajo»: the chat folded into a rail; a tap brings it back.
class _ChatRail extends StatelessWidget {
  const _ChatRail({required this.onShowChat});

  final VoidCallback onShowChat;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      key: const ValueKey('chat-workspace-rail'),
      width: ChatWorkspaceGeometry.rail,
      decoration: BoxDecoration(
        color: colors.surface,
        // v25: the folded chat is a pill like the panes.
        borderRadius: BorderRadius.circular(28),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      alignment: Alignment.topCenter,
      // Same as the panes: the rail is outside any Scaffold.
      child: Material(
        type: MaterialType.transparency,
        child: IconButton(
          key: const ValueKey('chat-workspace-show-chat'),
          tooltip: Strings.of(context).cwsShowChat,
          icon: Icon(Icons.chat_bubble_outline, color: colors.textSecondary),
          onPressed: onShowChat,
        ),
      ),
    );
  }
}

/// Which pane holds the keyboard's focus.
enum _FocusSide { none, chat, workspace }

/// The pane folded beside the chat while the chat has the keyboard (the owner,
/// APK 9708): a rail like the chat's own, with the panel's icon; a tap
/// closes the keyboard and the split comes back.
class _PaneRail extends StatelessWidget {
  const _PaneRail({required this.tab, required this.onShowPane});

  final ChatWorkspaceTab? tab;
  final VoidCallback onShowPane;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final tab = this.tab;
    final label = Strings.of(context).cwsOpenWorkspace;
    return Container(
      key: const ValueKey('chat-workspace-pane-rail'),
      width: ChatWorkspaceGeometry.rail,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(ChatWorkspaceTokens.paneRadius),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      alignment: Alignment.topCenter,
      // Named for screen readers like the edge handles ([_EdgeHandle]).
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        onTap: onShowPane,
        child: Material(
          type: MaterialType.transparency,
          child: IconButton(
            key: const ValueKey('chat-workspace-show-pane'),
            tooltip: label,
            icon: Icon(
              tab == null
                  ? Icons.vertical_split_outlined
                  : chatWorkspaceTabIcon(tab),
              color: colors.textSecondary,
            ),
            onPressed: onShowPane,
          ),
        ),
      ),
    );
  }
}

class _WorkspacePane extends StatelessWidget {
  const _WorkspacePane({
    required this.controller,
    required this.tabBuilder,
    required this.availableTabs,
    required this.tabBadge,
    required this.navigatorFor,
    required this.observerFor,
    required this.toolbarFor,
    required this.hidden,
    required this.compact,
  });

  final ChatWorkspaceController controller;
  final ChatWorkspaceTabBuilder tabBuilder;
  final List<ChatWorkspaceTab> availableTabs;
  final int? Function(ChatWorkspaceTab tab)? tabBadge;
  final GlobalKey<NavigatorState> Function(ChatWorkspaceTab) navigatorFor;
  final _TabRootObserver Function(ChatWorkspaceTab) observerFor;
  final ValueNotifier<ChatWorkspaceToolbar> Function(ChatWorkspaceTab)
  toolbarFor;

  /// Mounted out of sight (chat only): no tab takes Back, and the Terminal
  /// is not built at all (see [ChatWorkspaceHost]).
  final bool hidden;

  /// At a compact root, Back restores an expanded panel or closes its tab
  /// before returning to the chat. Child routes and their vetoes go first.
  final bool compact;

  void _backFromRoot(ChatWorkspaceTab tab) {
    if (controller.mode == ChatWorkspaceMode.workspace) {
      controller.setMode(ChatWorkspaceMode.split);
    } else {
      controller.close(tab);
    }
  }

  @override
  Widget build(BuildContext context) => _KeyboardFold(
    controller: controller,
    builder: (context, typing, barShown, showBar) =>
        _pane(context, typing: typing, barShown: barShown, showBar: showBar),
  );

  Widget _pane(
    BuildContext context, {
    required bool typing,
    required bool barShown,
    required VoidCallback showBar,
  }) {
    final tabs = [
      for (final tab in controller.tabs)
        if (!hidden || tab != ChatWorkspaceTab.terminal) tab,
    ];
    final active = hidden ? null : controller.active;
    // the owner (ronda Fold 2): with the keyboard up the terminal had one line
    // left. The pane's bar steps aside behind one handle (until asked
    // for), so the tab gets every line.
    final barFolded = typing && !barShown;
    return Semantics(
      container: true,
      label: Strings.of(context).cwsWorkspace,
      explicitChildNodes: true,
      child: Stack(
        children: [
          Column(
            children: [
              _KeyboardFoldBar(
                folded: barFolded,
                bar: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    ChatWorkspaceTokens.inset,
                    ChatWorkspaceTokens.inset,
                    ChatWorkspaceTokens.inset,
                    8,
                  ),
                  child: _PaneBar(
                    controller: controller,
                    availableTabs: availableTabs,
                    tabBadge: tabBadge,
                    toolbar: active == null ? null : toolbarFor(active),
                  ),
                ),
              ),
              Expanded(
                child: _TabBodies(
                  active: active,
                  child: Stack(
                    children: [
                      for (final tab in tabs)
                        Offstage(
                          key: ValueKey('chat-workspace-body-${tab.name}'),
                          offstage: tab != active,
                          child: TickerMode(
                            enabled: tab == active,
                            // System Back goes to this tab's routes/vetoes
                            // first. At a compact root it returns through
                            // the tabs to Chat, not out of the conversation.
                            child: _WorkspaceTabBack(
                              enabled: tab == active,
                              navigator: navigatorFor(tab),
                              onRootBack: compact
                                  ? () => _backFromRoot(tab)
                                  : null,
                              child: ChatWorkspacePaneScope(
                                tab: tab,
                                controller: controller,
                                toolbar: toolbarFor(tab),
                                child: Navigator(
                                  key: navigatorFor(tab),
                                  observers: [observerFor(tab)],
                                  onGenerateRoute: (settings) =>
                                      MaterialPageRoute<void>(
                                        settings: settings,
                                        builder: (context) =>
                                            tabBuilder(context, tab),
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
            ],
          ),
          // With the keyboard up, the only part of the pane left in view is
          // its top: the handle that brings the bar back sits there.
          if (barFolded)
            // In from the corner by the pane's inset: at the very edge its
            // radius cut the handle (audit 2.6).
            // TODO(token): HermesSpace.inset once Ola 2 publishes it.
            Positioned(
              top: ChatWorkspaceTokens.inset,
              right: ChatWorkspaceTokens.inset,
              child: _ToolsHandle(onTap: showBar),
            ),
        ],
      ),
    );
  }
}

/// Like NavigatorPopHandler, with a compact root action. Only the active
/// tab may handle a rejected pop: every PopScope on the parent route hears
/// that notification, including disabled/offstage tabs. NavigationNotification
/// includes PopScope vetoes as well as child routes (browser grid/history,
/// expanded terminal, unsaved edits), so those always precede the root action.
class _WorkspaceTabBack extends StatefulWidget {
  const _WorkspaceTabBack({
    required this.enabled,
    required this.navigator,
    required this.onRootBack,
    required this.child,
  });

  final bool enabled;
  final GlobalKey<NavigatorState> navigator;
  final VoidCallback? onRootBack;
  final Widget child;

  @override
  State<_WorkspaceTabBack> createState() => _WorkspaceTabBackState();
}

class _WorkspaceTabBackState extends State<_WorkspaceTabBack> {
  bool _canHandlePop = false;

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: !widget.enabled || (!_canHandlePop && widget.onRootBack == null),
    onPopInvokedWithResult: (didPop, _) {
      if (didPop || !widget.enabled) return;
      if (_canHandlePop) {
        widget.navigator.currentState?.maybePop();
      } else {
        widget.onRootBack?.call();
      }
    },
    child: NotificationListener<NavigationNotification>(
      onNotification: (notification) {
        if (notification.canHandlePop != _canHandlePop) {
          setState(() => _canHandlePop = notification.canHandlePop);
        }
        return false;
      },
      child: widget.child,
    ),
  );
}

IconData chatWorkspaceTabIcon(ChatWorkspaceTab tab) => switch (tab) {
  ChatWorkspaceTab.terminal => Icons.terminal_rounded,
  ChatWorkspaceTab.files => Icons.folder_open_outlined,
  // Same glyphs as the notch sheet's Git and Navegador.
  ChatWorkspaceTab.git => Icons.call_split_rounded,
  ChatWorkspaceTab.browser => Icons.language_rounded,
  // The agents of Herdr on the server.
  ChatWorkspaceTab.agents => Icons.smart_toy_outlined,
};

String chatWorkspaceTabLabel(Strings strings, ChatWorkspaceTab tab) =>
    switch (tab) {
      ChatWorkspaceTab.terminal => strings.chaControlTerminal,
      ChatWorkspaceTab.files => strings.cwsFiles,
      ChatWorkspaceTab.git => strings.ghtPanelTitle,
      ChatWorkspaceTab.browser => strings.chaControlBrowser,
      ChatWorkspaceTab.agents => strings.hdaTitle,
    };

/// The tabs' screens, in a semantics node of
/// their own. Each tab's Navigator puts a modal barrier under its route,
/// and a barrier's BlockSemantics drops every node painted before it up to
/// the nearest semantics boundary: without this one, the tab strip above
/// was gone for screen readers (gate gint6, 'a narrow workspace shows
/// inactive tabs as icons').
/// the owner (ronda Fold 2): whether the keyboard is up over the workspace pane
/// (its own MediaQuery keeps the keyboard inset), and what the pane does
/// about it. The pane's bar stays folded until [showBar]; a pane expanded
/// to the whole width while typing (the bar's «Ampliar») goes back to the
/// split when the keyboard closes. The session is never touched: only the
/// layout changes.
class _KeyboardFold extends StatefulWidget {
  const _KeyboardFold({required this.controller, required this.builder});

  final ChatWorkspaceController controller;
  final Widget Function(
    BuildContext context,
    bool typing,
    bool barShown,
    VoidCallback showBar,
  )
  builder;

  @override
  State<_KeyboardFold> createState() => _KeyboardFoldState();
}

class _KeyboardFoldState extends State<_KeyboardFold> {
  bool _typing = false;
  bool _barShown = false;

  /// The pane went workspace-only while the keyboard was up.
  bool _expandedForKeyboard = false;
  /// The mode last seen. Read when the pane mounts, not lazily: a `late`
  /// initializer would first run inside [_onViews], after «Ampliar» had
  /// already changed the mode, and the change would never be seen (gate
  /// gint32: the pane stayed full width after the keyboard closed).
  late ChatWorkspaceMode _mode;

  @override
  void initState() {
    super.initState();
    _mode = widget.controller.mode;
    widget.controller.addListener(_onViews);
  }

  @override
  void didUpdateWidget(_KeyboardFold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    oldWidget.controller.removeListener(_onViews);
    widget.controller.addListener(_onViews);
    _mode = widget.controller.mode;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onViews);
    super.dispose();
  }

  void _onViews() {
    final mode = widget.controller.mode;
    if (mode == _mode) return;
    _expandedForKeyboard = _typing && mode == ChatWorkspaceMode.workspace;
    _mode = mode;
  }

  void _showBar() => setState(() => _barShown = true);

  @override
  Widget build(BuildContext context) {
    // The pane gets lower when a screen around it makes room for the
    // keyboard: rebuilt then, and the keyboard read from the window.
    MediaQuery.sizeOf(context);
    final typing = chatWorkspaceKeyboardUp(context);
    if (typing != _typing) {
      _typing = typing;
      if (!typing) {
        _barShown = false;
        if (_expandedForKeyboard) {
          _expandedForKeyboard = false;
          final controller = widget.controller;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && controller.mode == ChatWorkspaceMode.workspace) {
              controller.setMode(ChatWorkspaceMode.split);
            }
          });
        }
      }
    }
    return widget.builder(context, typing, _barShown, _showBar);
  }
}

/// Ola 7: the pane's bar folds away with the keyboard and comes back with
/// it in [HermesMotion.base], rather than in one frame. Only its height
/// moves: a width that changes (another panel's split, the divider) is
/// followed at once. With «reduce motion» there is no [AnimatedSize] at
/// all (gint56: one of no duration ends inside its own layout).
class _KeyboardFoldBar extends StatelessWidget {
  const _KeyboardFoldBar({required this.folded, required this.bar});

  final bool folded;
  final Widget bar;

  @override
  Widget build(BuildContext context) {
    final child = folded
        ? const SizedBox(
            key: ValueKey('chat-workspace-tabs-folded'),
            width: double.infinity,
          )
        : bar;
    return SizedBox(
      width: double.infinity,
      child: HermesMotion.reduced(context)
          ? child
          : AnimatedSize(
              duration: HermesMotion.base,
              curve: HermesMotion.size,
              alignment: Alignment.topCenter,
              child: child,
            ),
    );
  }
}

class _TabBodies extends StatefulWidget {
  const _TabBodies({required this.active, required this.child});

  /// The tab on screen.
  final ChatWorkspaceTab? active;
  final Widget child;

  @override
  State<_TabBodies> createState() => _TabBodiesState();
}

class _TabBodiesState extends State<_TabBodies>
    with SingleTickerProviderStateMixin {
  /// Ola 7 (v25 `transition: all .2s`): another tab's screen fades in
  /// rather than replacing the last one in a frame.
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: HermesMotion.fast,
    value: 1,
  );
  late final CurvedAnimation _opacity = CurvedAnimation(
    parent: _fade,
    curve: HermesMotion.standard,
  );

  @override
  void didUpdateWidget(_TabBodies oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed =
        oldWidget.active != null &&
        widget.active != null &&
        oldWidget.active != widget.active;
    if (!changed) return;
    if (HermesMotion.reduced(context)) {
      _fade.value = 1;
    } else {
      _fade.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _opacity.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    child: FadeTransition(
      key: const ValueKey('chat-workspace-tab-fade'),
      opacity: _opacity,
      child: widget.child,
    ),
  );
}

/// Radii and spacing of mock 136 v2-A (its table of tokens), for the pane
/// and what it holds.
abstract final class ChatWorkspaceTokens {
  /// The pane and the chat beside it.
  static const double paneRadius = 28;

  /// A card inside the pane (the terminal, a list of files).
  static const double cardRadius = 22;

  /// A row inside a card.
  static const double rowRadius = 16;

  /// The bottom sheet of a narrow screen.
  static const double sheetRadius = 32;

  /// Between surfaces.
  static const double gap = 10;

  /// Inside the pane and the sheet; a card's margin in the pane.
  static const double inset = 12;

  /// A pill's touch target: segments, actions, keys.
  static const double target = 48;
}

/// Mock 136 v2-A: the pane's one bar. The selector of panels in a pill and,
/// beside it, the pill of actions.
class _PaneBar extends StatelessWidget {
  const _PaneBar({
    required this.controller,
    required this.availableTabs,
    required this.tabBadge,
    required this.toolbar,
  });

  final ChatWorkspaceController controller;
  final List<ChatWorkspaceTab> availableTabs;
  final int? Function(ChatWorkspaceTab tab)? tabBadge;
  final ValueListenable<ChatWorkspaceToolbar>? toolbar;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: _PanelSelector(
          controller: controller,
          availableTabs: availableTabs,
          tabBadge: tabBadge,
        ),
      ),
      const SizedBox(width: 8),
      _PaneActions(
        controller: controller,
        toolbar: toolbar,
        availableTabs: availableTabs,
      ),
    ],
  );
}

/// The one selector of panels (mock 136 v2-A): «Chat» and every panel this
/// chat offers, always in the same order, with their counts. Tapping a
/// panel shows it (opening it if needed); «Chat» folds the pane and leaves
/// the chat alone. A swipe across the selector moves to the panel beside
/// it; the panels' own content keeps its gestures.
///
/// Like the mock's `.seg`, the segments share the pill and it never
/// scrolls: every panel is named when all the names fit; otherwise only the
/// active one is (its name cut short if it must), the others are their
/// icon. A scrolling strip hid panels off its edge and took the swipe for
/// itself (gate gint37).
class _PanelSelector extends StatefulWidget {
  const _PanelSelector({
    required this.controller,
    required this.availableTabs,
    required this.tabBadge,
  });

  final ChatWorkspaceController controller;
  final List<ChatWorkspaceTab> availableTabs;
  final int? Function(ChatWorkspaceTab tab)? tabBadge;

  @override
  State<_PanelSelector> createState() => _PanelSelectorState();
}

class _PanelSelectorState extends State<_PanelSelector>
    with SingleTickerProviderStateMixin {
  /// Ola 7 (v25 `transition: all .2s`): the tint of the panel in use slides
  /// to the one chosen. At rest the active segment paints its own tint, the
  /// same pill in the same place.
  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: HermesMotion.base,
    value: 1,
  );
  late final CurvedAnimation _slideCurve = CurvedAnimation(
    parent: _slide,
    curve: HermesMotion.standard,
  );

  /// The segments' tints at the last layout, and the one the slide leaves.
  List<Rect> _tints = const [];
  Rect? _from;
  late ChatWorkspaceTab? _shown = _current;

  ChatWorkspaceController get controller => widget.controller;

  /// What the pane shows: null is «Chat» (the pane folded).
  ChatWorkspaceTab? get _current =>
      controller.mode == ChatWorkspaceMode.chat ? null : controller.active;

  List<ChatWorkspaceTab?> get _entries => [null, ...widget.availableTabs];

  @override
  void dispose() {
    _slideCurve.dispose();
    _slide.dispose();
    super.dispose();
  }

  void _select(ChatWorkspaceTab? tab) {
    // Ola 7: a tick when the pane changes, none for the segment it is on.
    if (tab != _current) HermesHaptics.selection();
    if (tab == null) {
      controller.setMode(ChatWorkspaceMode.chat);
    } else if (controller.tabs.contains(tab)) {
      controller.activate(tab);
    } else {
      controller.open(tab);
    }
  }

  void _step(int delta) {
    final entries = _entries;
    final index = entries.indexOf(_current);
    final next = (index + delta).clamp(0, entries.length - 1);
    if (next != index) _select(entries[next]);
  }

  /// The panel in use changed: the tint leaves from where it was.
  void _follow(ChatWorkspaceTab? current) {
    if (current == _shown) return;
    final from = _entries.indexOf(_shown);
    _shown = current;
    if (HermesMotion.reduced(context) || from < 0 || from >= _tints.length) {
      _from = null;
      _slide.value = 1;
      return;
    }
    _from = _tints[from];
    _slide.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final current = _current;
    _follow(current);
    final entries = _entries;
    final tabBadge = widget.tabBadge;
    final widths = [
      for (final tab in entries)
        _Segment.namedWidth(
          context,
          _Segment.labelOf(strings, tab),
          tab == null ? null : tabBadge?.call(tab),
        ),
    ];
    final namedWidth = widths.fold(0.0, (sum, width) => sum + width);
    return GestureDetector(
      key: const ValueKey('chat-workspace-tabs'),
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity.abs() < 200) return;
        _step(velocity < 0 ? 1 : -1);
      },
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: colors.surfaceVariant,
          shape: const StadiumBorder(),
        ),
        child: SizedBox(
          height: ChatWorkspaceTokens.target,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final named = namedWidth <= constraints.maxWidth;
                final flexes = [
                  for (final (index, tab) in entries.indexed)
                    // Named: each its own width and a share of the rest.
                    // Otherwise the mock's flex: 2 for the active one, 1
                    // for each icon.
                    named ? widths[index].ceil() : (tab == current ? 2 : 1),
                ];
                // Where each segment's tint sits: the Row shares the width
                // by flex, and the tint is the segment less its inset.
                final total = flexes.fold(0, (sum, flex) => sum + flex);
                const height = ChatWorkspaceTokens.target;
                final tints = <Rect>[];
                var left = 0.0;
                for (final flex in flexes) {
                  final width = constraints.maxWidth * flex / total;
                  final segment = Offset(left, 0) & Size(width, height);
                  tints.add(segment.deflate(_Segment._inset));
                  left += width;
                }
                _tints = tints;
                final to = entries.indexOf(current);
                return AnimatedBuilder(
                  animation: _slideCurve,
                  builder: (context, _) {
                    final from = _from;
                    final sliding =
                        _slide.status == AnimationStatus.forward &&
                        from != null &&
                        to >= 0;
                    return Stack(
                      children: [
                        if (sliding)
                          Positioned.fromRect(
                            rect: Rect.lerp(
                              from,
                              _tints[to],
                              _slideCurve.value,
                            )!,
                            child: DecoratedBox(
                              key: const ValueKey(
                                'chat-workspace-segment-slide',
                              ),
                              decoration: ShapeDecoration(
                                color: _Segment.tintOf(colors),
                                shape: const StadiumBorder(),
                              ),
                            ),
                          ),
                        Row(
                          children: [
                            for (final (index, tab) in entries.indexed)
                              Expanded(
                                flex: flexes[index],
                                child: _Segment(
                                  tab: tab,
                                  active: tab == current,
                                  tinted: !sliding,
                                  iconOnly: !named && tab != current,
                                  badge: tab == null
                                      ? null
                                      : tabBadge?.call(tab),
                                  onTap: () => _select(tab),
                                ),
                              ),
                          ],
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// One segment of the selector: a 48 dp target, the active one filled with
/// the accent's tint and named, the others their icon when the names do
/// not all fit. Git carries its count of changed files, on the icon when
/// the segment is only its icon.
class _Segment extends StatelessWidget {
  const _Segment({
    required this.tab,
    required this.active,
    required this.iconOnly,
    required this.badge,
    required this.onTap,
    this.tinted = true,
  });

  /// Null: «Chat».
  final ChatWorkspaceTab? tab;
  final bool active;

  /// The active segment paints its tint; not while the tint slides to it.
  final bool tinted;

  /// The tint of the panel in use.
  static Color tintOf(HermesThemeColors colors) =>
      colors.accent.withValues(alpha: 0.18);
  final bool iconOnly;
  final int? badge;
  final VoidCallback onTap;

  static const double _inset = 4;
  static const double _padding = 12;
  static const double _iconSize = 18;
  static const double _iconGap = 8;
  static const double _countGap = 6;

  /// Room a name needs before it is shown at all, even cut short.
  static const double _minLabel = 12;

  static const TextStyle _labelStyle = TextStyle(fontWeight: FontWeight.w600);
  static const TextStyle _countStyle = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w700,
  );

  static String labelOf(Strings strings, ChatWorkspaceTab? tab) =>
      tab == null ? strings.cwsViewChat : chatWorkspaceTabLabel(strings, tab);

  static double _textWidth(
    BuildContext context,
    String text,
    TextStyle style,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: DefaultTextStyle.of(context).style.merge(style),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  /// Width of the count's pill, or 0 without a count.
  static double _countWidth(BuildContext context, int? count) {
    if (count == null || count <= 0) return 0;
    return math.max(18.0, 12 + _textWidth(context, '$count', _countStyle));
  }

  /// Width of a segment that shows its name and count in full.
  static double namedWidth(BuildContext context, String label, int? count) {
    final countWidth = _countWidth(context, count);
    return 2 * _inset +
        2 * _padding +
        _iconSize +
        _iconGap +
        _textWidth(context, label, _labelStyle) +
        (countWidth > 0 ? _countGap + countWidth : 0);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final tab = this.tab;
    final label = labelOf(strings, tab);
    final icon = tab == null
        ? Icons.chat_bubble_outline
        : chatWorkspaceTabIcon(tab);
    final foreground = active ? colors.accent : colors.textSecondary;
    final count = badge;
    final showCount = count != null && count > 0;
    final countPill = showCount
        ? Container(
            key: ValueKey('chat-workspace-tab-badge-${tab?.name}'),
            // 18 at least, and taller with large text (Ola 8): the centre
            // takes the figure's own size, so the pill never fills the row.
            constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: colors.accent,
              borderRadius: BorderRadius.circular(99),
            ),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: Text(
                '$count',
                style: _countStyle.copyWith(color: colors.onAccent),
              ),
            ),
          )
        : null;
    final glyph = Icon(icon, size: _iconSize, color: foreground);
    return Semantics(
      // Each segment is its own node, read one by one, named whether or
      // not its name fits on screen.
      container: true,
      selected: active,
      button: true,
      label: label,
      value: showCount ? strings.gitChanged(count) : null,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        key: ValueKey(
          tab == null
              ? 'chat-workspace-collapse'
              : 'chat-workspace-tab-${tab.name}',
        ),
        type: MaterialType.transparency,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: ChatWorkspaceTokens.target,
            child: Padding(
              padding: const EdgeInsets.all(_inset),
              child: DecoratedBox(
                key: active
                    ? const ValueKey('chat-workspace-segment-active')
                    : null,
                decoration: ShapeDecoration(
                  color: active && tinted ? tintOf(colors) : Colors.transparent,
                  shape: const StadiumBorder(),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final countRoom = showCount
                        ? _countGap + _countWidth(context, count)
                        : 0.0;
                    final labelRoom =
                        constraints.maxWidth -
                        2 * _padding -
                        _iconSize -
                        _iconGap -
                        countRoom;
                    if (iconOnly || labelRoom < _minLabel) {
                      // Its icon, and the count on it.
                      return Center(
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            glyph,
                            if (countPill != null)
                              Positioned(
                                right: -10,
                                top: -8,
                                child: countPill,
                              ),
                          ],
                        ),
                      );
                    }
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: _padding,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          glyph,
                          const SizedBox(width: _iconGap),
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: _labelStyle.copyWith(color: foreground),
                            ),
                          ),
                          if (countPill != null) ...[
                            const SizedBox(width: _countGap),
                            countPill,
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Mock 136 v2-A: the pill of actions beside the selector. The terminal's
/// keys and Herdr (what the active tab publishes), expand or restore and
/// «⋯»: the layouts, closing the panel's tab and what the tab adds. In
/// «Solo trabajo» «Vistas» is here too, since the chat's header is folded.
class _PaneActions extends StatelessWidget {
  const _PaneActions({
    required this.controller,
    required this.toolbar,
    required this.availableTabs,
  });

  final ChatWorkspaceController controller;
  final ValueListenable<ChatWorkspaceToolbar>? toolbar;
  final List<ChatWorkspaceTab> availableTabs;

  @override
  Widget build(BuildContext context) {
    final source = toolbar;
    if (source == null) return _pill(context, ChatWorkspaceToolbar.none);
    return ValueListenableBuilder<ChatWorkspaceToolbar>(
      valueListenable: source,
      builder: (context, tools, _) => _pill(context, tools),
    );
  }

  Widget _pill(BuildContext context, ChatWorkspaceToolbar tools) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final ink = colors.textSecondary;
    final on = colors.accent;
    final expanded = controller.mode == ChatWorkspaceMode.workspace;
    final active = controller.active;
    Widget button({
      required Key key,
      required IconData icon,
      required String tooltip,
      required VoidCallback? onPressed,
      bool? selected,
      Widget? badge,
    }) {
      final glyph = Icon(icon, size: 20);
      return IconButton(
        key: key,
        tooltip: tooltip,
        onPressed: onPressed,
        // A toggle (the keys): read as selected or not.
        isSelected: selected,
        color: selected == true ? on : ink,
        constraints: const BoxConstraints.tightFor(
          width: 44,
          height: ChatWorkspaceTokens.target,
        ),
        padding: EdgeInsets.zero,
        icon: badge == null
            ? glyph
            : Stack(
                clipBehavior: Clip.none,
                children: [
                  glyph,
                  Positioned(right: -6, top: -5, child: badge),
                ],
              ),
      );
    }

    final herdrAttention = tools.herdrNeedsYou?.call() ?? 0;
    return DecoratedBox(
      key: const ValueKey('chat-workspace-actions'),
      decoration: ShapeDecoration(
        color: colors.surfaceVariant,
        shape: const StadiumBorder(),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (tools.onToggleKeys case final toggle?)
              button(
                key: const ValueKey('chat-workspace-keys'),
                icon: Icons.keyboard_outlined,
                tooltip: strings.cwsTerminalKeys,
                selected: tools.keysShown,
                onPressed: toggle,
              ),
            if (tools.onHerdr case final openHerdr?)
              button(
                key: const ValueKey('chat-workspace-herdr'),
                icon: Icons.tag,
                tooltip: herdrAttention > 0
                    ? strings.herdrNeedsYouCount(herdrAttention)
                    : strings.herdrPanelTooltip,
                onPressed: openHerdr,
                badge: herdrAttention > 0
                    ? Container(
                        key: const ValueKey('chat-workspace-herdr-attention'),
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: colors.warning,
                          shape: BoxShape.circle,
                        ),
                      )
                    : null,
              ),
            button(
              key: const ValueKey('chat-workspace-expand'),
              icon: expanded ? Icons.close_fullscreen : Icons.open_in_full,
              tooltip: expanded
                  ? strings.cwsRestoreSplit
                  : strings.cwsExpandWorkspace,
              onPressed: controller.toggleExpanded,
            ),
            // «Vistas» lives here while the chat is hidden (its own header
            // has it otherwise): always one tap away.
            if (expanded)
              Builder(
                builder: (buttonContext) => button(
                  key: const ValueKey('chat-workspace-views-button'),
                  icon: Icons.view_column_outlined,
                  tooltip: chatWorkspaceViewsLabel(strings, controller),
                  onPressed: () => showChatWorkspaceViews(
                    buttonContext,
                    controller: controller,
                    availableTabs: availableTabs,
                  ),
                ),
              ),
            HermesMenuButton<Object>(
              key: const ValueKey('chat-workspace-layout-menu'),
              tooltip: strings.cwsMore,
              icon: Icon(Icons.more_horiz, size: 20, color: ink),
              onSelected: (choice) {
                if (choice is ChatWorkspaceMode) {
                  controller.setMode(choice);
                } else if (choice is ChatWorkspaceTab) {
                  HermesHaptics.selection();
                  controller.close(choice);
                } else if (choice is ChatWorkspaceMenuEntry) {
                  choice.onSelected();
                }
              },
              actions: (_) => [
                for (final (mode, icon, label) in [
                  (
                    ChatWorkspaceMode.chat,
                    Icons.view_sidebar_outlined,
                    strings.cwsLayoutChat,
                  ),
                  (
                    ChatWorkspaceMode.split,
                    Icons.vertical_split_outlined,
                    strings.cwsLayoutSplit,
                  ),
                  (
                    ChatWorkspaceMode.workspace,
                    Icons.web_asset_outlined,
                    strings.cwsLayoutWorkspace,
                  ),
                ])
                  HermesAction<Object>(
                    key: ValueKey('chat-workspace-mode-${mode.name}'),
                    value: mode,
                    label: label,
                    icon: icon,
                    selected: controller.mode == mode,
                  ),
                // The panel's tab ends (its screen closes; the session of a
                // terminal lives on in the service).
                if (active != null)
                  HermesAction<Object>(
                    key: const ValueKey('chat-workspace-close-tab'),
                    value: active,
                    label: strings.cwsCloseTab,
                    icon: Icons.close,
                    divided: true,
                  ),
                for (final (i, entry) in tools.menu.indexed)
                  HermesAction<Object>(
                    key: entry.key,
                    value: entry,
                    label: entry.label,
                    icon: entry.icon,
                    destructive: entry.destructive,
                    divided: i == 0,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// With the keyboard up the pane's bar steps aside behind this handle at
/// the pane's top edge («Mostrar herramientas»); a tap brings the bar back.
class _ToolsHandle extends StatelessWidget {
  const _ToolsHandle({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      label: Strings.of(context).cwsShowTools,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        key: const ValueKey('chat-workspace-show-tools'),
        color: colors.surfaceVariant,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox.square(
            dimension: ChatWorkspaceTokens.target,
            child: Icon(
              Icons.more_horiz,
              size: 18,
              color: colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// One entry a tab adds to the pane's «⋯» menu.
@immutable
class ChatWorkspaceMenuEntry {
  const ChatWorkspaceMenuEntry({
    required this.label,
    required this.icon,
    required this.onSelected,
    this.destructive = false,
    this.key,
  });

  final String label;
  final IconData icon;
  final VoidCallback onSelected;
  final bool destructive;
  final Key? key;

  @override
  bool operator ==(Object other) =>
      other is ChatWorkspaceMenuEntry &&
      other.label == label &&
      other.icon == icon &&
      other.destructive == destructive &&
      other.key == key;

  @override
  int get hashCode => Object.hash(label, icon, destructive, key);
}

/// What a tab's screen puts on the pane's bar: the terminal's key
/// row toggle, its Herdr panel and entries for «⋯». Published by the
/// screen through [ChatWorkspacePaneScope.publish]; nothing by default.
@immutable
class ChatWorkspaceToolbar {
  const ChatWorkspaceToolbar({
    this.keysShown,
    this.onToggleKeys,
    this.onHerdr,
    this.herdrNeedsYou,
    this.menu = const [],
  });

  static const ChatWorkspaceToolbar none = ChatWorkspaceToolbar();

  /// The key row is on screen; null without [onToggleKeys].
  final bool? keysShown;
  final VoidCallback? onToggleKeys;

  /// Opens the Herdr panel; null when the tab has no Herdr session.
  final VoidCallback? onHerdr;

  /// Agents waiting for the user, read when the bar builds.
  final int Function()? herdrNeedsYou;
  final List<ChatWorkspaceMenuEntry> menu;

  /// Equal when the bar would look the same: the callbacks are the
  /// screen's own methods, so a new toolbar with the same state does not
  /// rebuild the bar.
  @override
  bool operator ==(Object other) =>
      other is ChatWorkspaceToolbar &&
      other.keysShown == keysShown &&
      (other.onToggleKeys == null) == (onToggleKeys == null) &&
      (other.onHerdr == null) == (onHerdr == null) &&
      (other.herdrNeedsYou?.call() ?? 0) == (herdrNeedsYou?.call() ?? 0) &&
      listEquals(other.menu, menu);

  @override
  int get hashCode => Object.hash(
    keysShown,
    onToggleKeys == null,
    onHerdr == null,
    herdrNeedsYou?.call() ?? 0,
    Object.hashAll(menu),
  );
}

/// Marks a subtree as living inside the workspace pane next to the chat,
/// so a screen built for full screen can behave as a pane (e.g. the
/// terminal does not take the keyboard focus from the chat's composer:
/// review P2-F4-5), open another tab and put its controls on the floating
/// bar.
class ChatWorkspacePaneScope extends InheritedWidget {
  const ChatWorkspacePaneScope({
    required super.child,
    this.tab,
    this.controller,
    this.toolbar,
    super.key,
  });

  final ChatWorkspaceTab? tab;
  final ChatWorkspaceController? controller;
  final ValueNotifier<ChatWorkspaceToolbar>? toolbar;

  static ChatWorkspacePaneScope? _of(BuildContext context) =>
      context
              .getElementForInheritedWidgetOfExactType<
                ChatWorkspacePaneScope
              >()
              ?.widget
          as ChatWorkspacePaneScope?;

  static bool isInPane(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatWorkspacePaneScope>() !=
      null;

  /// The background of a tab's screen: none inside the pane or the sheet
  /// of a narrow screen, so their own surface shows and they read as one
  /// piece (audit T1: the screen's page grey sat on the pane's grey);
  /// [outside] full screen.
  static Color backgroundOf(BuildContext context, Color outside) =>
      isInPane(context) || _ChatWorkspaceSheetScope.contains(context)
      ? Colors.transparent
      : outside;

  /// The workspace this pane belongs to (to open a sibling tab).
  static ChatWorkspaceController? controllerOf(BuildContext context) =>
      _of(context)?.controller;

  /// Puts [toolbar] on the pane's bar while this tab is the active one.
  /// Call it outside build (a post-frame callback): it may rebuild the bar.
  static void publish(BuildContext context, ChatWorkspaceToolbar toolbar) {
    final target = _of(context)?.toolbar;
    if (target != null) target.value = toolbar;
  }

  @override
  bool updateShouldNotify(ChatWorkspacePaneScope oldWidget) => false;
}

/// Marks a screen shown in [showChatWorkspaceSheet]: it is full screen in
/// every other way (its own header, its own way back), only its background
/// is the sheet's ([ChatWorkspacePaneScope.backgroundOf]).
class _ChatWorkspaceSheetScope extends InheritedWidget {
  const _ChatWorkspaceSheetScope({required super.child});

  static bool contains(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ChatWorkspaceSheetScope>() !=
      null;

  @override
  bool updateShouldNotify(_ChatWorkspaceSheetScope oldWidget) => false;
}

/// Reports when a tab's navigator loses its first route.
class _TabRootObserver extends NavigatorObserver {
  _TabRootObserver({required this.onRootGone});

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

/// Widest a chat's transcript and composer get. Mock 134 state B: the chat
/// alone on an expanded window reads at [Responsive.chatReadingWidth],
/// centred by its parent. Beside the list (state A) or the workspace (state
/// C), and below an expanded window (a phone, the upright Fold: the chat
/// takes the screen), it takes all its room. Placed inside the chat's body,
/// so a pane's own size counts; it follows [views] as they change.
class ChatReadingWidth extends StatelessWidget {
  const ChatReadingWidth({required this.views, required this.child, super.key});

  final ChatWorkspaceController views;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: views,
    builder: (context, child) {
      final alone = !views.listVisible && !views.workspaceVisible;
      final expanded =
          MediaQuery.sizeOf(context).width >= Responsive.expandedBreakpoint;
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: alone && expanded
              ? Responsive.chatReadingWidth
              : double.infinity,
        ),
        child: child,
      );
    },
    child: child,
  );
}
