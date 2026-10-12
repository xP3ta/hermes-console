import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../design/tokens.dart' show HermesChrome;
import '../theme/app_theme.dart';
import 'dock_geometry.dart';
import 'dock_light.dart';
import 'gesture_dock_state.dart';

/// Height of the floating bar.
const double gestureDockHeight = 60;

/// Gap between the bar and the screen sides.
const double gestureDockSideMargin = 14;

/// Gap between the bar and the system navigation area.
const double gestureDockBottomGap = 14;

/// Space kept free between the end of a list and the top of the bar.
const double gestureDockBreathing = 8;

/// How long a finger rests on an item before its menu opens.
const Duration dockLongPress = Duration(milliseconds: 480);

/// How long the bar takes to leave or come back when hidden by hand.
const Duration dockHideDuration = Duration(milliseconds: 350);

/// The handle a hidden dock leaves behind: a pill inside a touch target of
/// at least 48 dp, kept [dockHandleGap] above the system navigation area.
const Size dockHandleTarget = Size(88, 48);
const Size dockHandleSize = Size(64, 30);
const double dockHandleGap = 6;

/// Distance from the bottom edge to the handle's touch target: above the
/// navigation inset and above the zone where the system takes swipes
/// (gesture navigation), whichever is taller.
double dockHandleBottom(BuildContext context) =>
    math.max(
      MediaQuery.viewPaddingOf(context).bottom,
      MediaQuery.systemGestureInsetsOf(context).bottom,
    ) +
    dockHandleGap;

/// Bottom space content keeps free so the bar never covers its last row:
/// system inset, gap, bar and a breathing gap. It does not change while
/// the dock is hidden or shown, so content never relayouts for it.
double gestureDockFootprint(BuildContext context) =>
    MediaQuery.viewPaddingOf(context).bottom +
    gestureDockBottomGap +
    gestureDockHeight +
    gestureDockBreathing;

/// One entry in an item's long-press menu.
@immutable
class DockShortcut {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const DockShortcut({
    required this.label,
    required this.icon,
    required this.onTap,
  });
}

/// The floating glass dock: "Flotante · iconos".
///
/// A plain tap bar. A tap on an item runs it; a long press opens its menu.
/// No swipe on it does anything, and it never hides by itself: the only
/// way it leaves the screen is "Esconder el dock", and then it leaves a
/// handle that brings it back with one tap.
///
/// It fills its parent `Stack` and places itself; the screen keeps the
/// [gestureDockFootprint] free at the bottom. Navigation is the host's:
/// the dock only reports which item was chosen.
class GestureDock extends StatefulWidget {
  /// The item this screen is. Null on screens that are none of them.
  final GestureDockTab? current;

  /// What each item does here. A missing or null entry renders the item
  /// disabled.
  final Map<GestureDockTab, VoidCallback?> onTab;

  /// The long-press menu of each item.
  final Map<GestureDockTab, List<DockShortcut>> shortcuts;

  /// Opens the "Actividad" sheet (its menu entry, its optional item and
  /// the screen reader action).
  final VoidCallback? onActivity;

  /// Opens the dock's edit mode (long press where there is no menu, the
  /// "Editar dock" menu entry, Ajustes › Dock).
  final VoidCallback? onEdit;

  /// Whether something needs the user elsewhere (pending permission), and
  /// what notifies when that changes.
  final bool Function() needsYou;
  final Listenable? attention;

  final GestureDockController? controller;
  final DockGeometry? geometry;

  const GestureDock({
    required this.onTab,
    this.current,
    this.shortcuts = const {},
    this.onActivity,
    this.onEdit,
    this.needsYou = _never,
    this.attention,
    this.controller,
    this.geometry,
    super.key,
  });

  static bool _never() => false;

  @override
  State<GestureDock> createState() => _GestureDockState();
}

class _GestureDockState extends State<GestureDock>
    with SingleTickerProviderStateMixin {
  GestureDockController get _c =>
      widget.controller ?? GestureDockController.instance;
  DockGeometry get _geometry => widget.geometry ?? DockGeometry.instance;

  late final AnimationController _hide = AnimationController(
    vsync: this,
    duration: dockHideDuration,
  );
  final ValueNotifier<int?> _pressed = ValueNotifier<int?>(null);
  final GlobalKey _barSlot = GlobalKey(debugLabel: 'gesture-dock-bar');
  final GlobalKey _handleSlot = GlobalKey(debugLabel: 'gesture-dock-handle');

  int? _pointer;
  Offset _start = Offset.zero;
  int? _downTab;
  bool _moved = false;
  bool _longPressed = false;
  Timer? _longPressTimer;

  GestureDockTab? _popover;
  bool _attached = false;
  bool _geometryQueued = false;

  /// The items on the bar, in the user's order (edit mode).
  List<GestureDockTab> get _tabs => _c.value.tabs;
  List<GestureDockTab> _lightTabs = const [];

  /// Where the place this screen is sits on the bar, if it is on it.
  int? get _currentSlot {
    final current = widget.current;
    if (current == null || !current.isPlace) return null;
    final slot = _tabs.indexOf(current);
    return slot < 0 ? null : slot;
  }

  /// The edit mode changed the bar: its slots are other items now.
  void _onSettingsChanged() {
    if (listEquals(_lightTabs, _tabs)) return;
    _lightTabs = _tabs;
    if (_attached) _c.light.place(_currentSlot);
  }

  bool get _rtl => Directionality.of(context) == TextDirection.rtl;

  bool get _reduced => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void initState() {
    super.initState();
    _hide.value = _c.hidden.value ? 1 : 0;
    _c.hidden.addListener(_onHiddenChanged);
    _lightTabs = _tabs;
    _c.settings.addListener(_onSettingsChanged);
    unawaited(_c.ensureLoaded());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible && !_attached) {
      _attached = true;
      _c.attach(this, _queueGeometry);
      _geometry.watch(this, _queueGeometry);
      // This screen is in view: its place is the selected one. Coming back
      // to it (the system's back) the light glides back too.
      _c.light.settle(_currentSlot, animate: !_reduced);
    } else if (!visible && _attached) {
      _attached = false;
      _geometry.unwatch(this);
      _geometry.clear(this);
      _c.detach(this);
      _closePopover();
    }
    final duration = _reduced ? Duration.zero : dockHideDuration;
    _hide.duration = duration;
    _hide.reverseDuration = duration;
  }

  @override
  void didUpdateWidget(covariant GestureDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      final old = oldWidget.controller ?? GestureDockController.instance;
      old.hidden.removeListener(_onHiddenChanged);
      old.settings.removeListener(_onSettingsChanged);
      _c.hidden.addListener(_onHiddenChanged);
      _c.settings.addListener(_onSettingsChanged);
      _lightTabs = _tabs;
      _hide.value = _c.hidden.value ? 1 : 0;
    }
    if (_attached && oldWidget.current != widget.current) {
      _c.light.settle(_currentSlot, animate: !_reduced);
    }
  }

  @override
  void dispose() {
    _c.hidden.removeListener(_onHiddenChanged);
    _c.settings.removeListener(_onSettingsChanged);
    _geometry.unwatch(this);
    _geometry.setMenuOpen(this, false);
    _geometry.clear(this);
    if (_attached) _c.detach(this);
    _longPressTimer?.cancel();
    _hide.dispose();
    _pressed.dispose();
    super.dispose();
  }

  void _onHiddenChanged() {
    if (!mounted) return;
    if (_c.hidden.value) {
      _closePopover();
      unawaited(_hide.forward());
    } else {
      unawaited(_hide.reverse());
    }
    _queueGeometry();
    setState(() {});
  }

  // ---- geometry --------------------------------------------------------

  void _queueGeometry() {
    if (_geometryQueued) return;
    _geometryQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _geometryQueued = false;
      _publishGeometry();
    });
  }

  void _publishGeometry() {
    if (!mounted || !_attached) return;
    final keyboard = View.of(context).viewInsets.bottom > 0;
    if (keyboard) {
      _geometry.publish(this, null, hidden: _c.hidden.value);
      return;
    }
    final hidden = _c.hidden.value;
    final key = hidden ? _handleSlot : _barSlot;
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return;
    final origin = box.localToGlobal(Offset.zero);
    _geometry.publish(this, origin & box.size, hidden: hidden);
  }

  // ---- touches ---------------------------------------------------------

  /// The item under [local] (bar coordinates). The bar's row is mirrored
  /// in right-to-left languages, so the slot is too.
  int? _tabAt(Offset local, double width) {
    if (local.dx < 0 || local.dx > width) return null;
    final slot = (local.dx / (width / _tabs.length)).floor().clamp(
      0,
      _tabs.length - 1,
    );
    return _rtl ? _tabs.length - 1 - slot : slot;
  }

  void _onDown(PointerDownEvent event, double width, Offset inset) {
    if (_pointer != null) return;
    _closePopover();
    _pointer = event.pointer;
    _start = event.position;
    _moved = false;
    _longPressed = false;
    _downTab = _tabAt(event.localPosition - inset, width);
    _pressed.value = _downTab;
    final tab = _downTab == null ? null : _tabs[_downTab!];
    _longPressTimer?.cancel();
    // An item with a menu opens it; anywhere else on the bar the long
    // press opens the edit mode.
    final hasMenu = tab != null && (widget.shortcuts[tab]?.isNotEmpty ?? false);
    if (hasMenu || widget.onEdit != null) {
      _longPressTimer = Timer(dockLongPress, () {
        if (_moved || _pointer == null) return;
        _longPressed = true;
        _pressed.value = null;
        unawaited(HapticFeedback.selectionClick());
        if (hasMenu) {
          _openPopover(tab);
        } else {
          widget.onEdit?.call();
        }
      });
    }
  }

  /// A finger that leaves the spot it touched is neither a tap nor a long
  /// press, and the dock has no other gesture: nothing happens.
  void _onMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || _longPressed || _moved) return;
    if ((event.position - _start).distance <= kTouchSlop) return;
    _moved = true;
    _longPressTimer?.cancel();
    _pressed.value = null;
  }

  void _onUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    _finish(cancelled: false);
  }

  void _onCancel(PointerCancelEvent event) {
    if (event.pointer != _pointer) return;
    _finish(cancelled: true);
  }

  void _finish({required bool cancelled}) {
    _longPressTimer?.cancel();
    _pointer = null;
    _pressed.value = null;
    if (cancelled || _longPressed || _moved || _downTab == null) return;
    _run(_downTab!);
  }

  /// Runs the item at [slot]. For a place the light leaves for it at once,
  /// before the screen it opens is there, so it reads as the light picking
  /// the destination. An action ("Nuevo", "Actividad") moves no light.
  void _run(int slot) {
    final tab = _tabs[slot];
    final action = widget.onTab[tab];
    if (action == null) return;
    if (tab.isPlace) _c.light.moveTo(slot, animate: !_reduced);
    action();
  }

  void _openPopover(GestureDockTab tab) {
    _geometry.setMenuOpen(this, true);
    setState(() => _popover = tab);
  }

  void _closePopover() {
    if (_popover == null) return;
    _geometry.setMenuOpen(this, false);
    if (mounted) setState(() => _popover = null);
  }

  /// Side padding of the row of items inside the bar.
  static const double _rowInset = 6;

  void _hideByHand() => _c.setHidden(true);

  void _showFromHandle() => _c.setHidden(false);

  // ---- build -----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final padding = MediaQuery.viewPaddingOf(context);
    final dockBottom = padding.bottom + gestureDockBottomGap;
    final handleBottom = dockHandleBottom(context);
    _queueGeometry();
    return _KeyboardGate(
      onChanged: _queueGeometry,
      child: ValueListenableBuilder<GestureDockSettings>(
        valueListenable: _c.settings,
        builder: (context, settings, _) {
          final hidden = _c.hidden.value;
          return Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              if (_popover != null)
                Positioned.fill(
                  child: GestureDetector(
                    key: const ValueKey('gesture-dock-popover-barrier'),
                    behavior: HitTestBehavior.translucent,
                    onTap: _closePopover,
                  ),
                ),
              Positioned(
                key: _barSlot,
                left: gestureDockSideMargin,
                right: gestureDockSideMargin,
                bottom: dockBottom,
                height: gestureDockHeight,
                // Bar or handle: whichever is in view takes the touches.
                child: ExcludeSemantics(
                  excluding: hidden,
                  child: IgnorePointer(
                    ignoring: hidden,
                    child: LayoutBuilder(
                      builder: (context, constraints) =>
                          _buildBar(context, constraints.maxWidth, settings),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: handleBottom,
                child: Center(
                  child: KeyedSubtree(
                    key: _handleSlot,
                    child: _buildHandle(context, strings, hidden),
                  ),
                ),
              ),
              if (_popover != null)
                _ShortcutPopover(
                  key: const ValueKey('gesture-dock-popover'),
                  tab: _popover!,
                  slot: settings.tabs.indexOf(_popover!),
                  slots: settings.tabs.length,
                  bottom: dockBottom + gestureDockHeight + 10,
                  shortcuts: widget.shortcuts[_popover!] ?? const [],
                  onSelected: (shortcut) {
                    _closePopover();
                    shortcut.onTap();
                  },
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBar(
    BuildContext context,
    double width,
    GestureDockSettings settings,
  ) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final opaque = settings.opaque || MediaQuery.highContrastOf(context);
    final tabs = settings.tabs;
    // What a long press reaches, for a screen reader.
    final actions = <CustomSemanticsAction, VoidCallback>{
      if (widget.onActivity != null)
        CustomSemanticsAction(label: strings.gdActivityTitle):
            widget.onActivity!,
      if (widget.onEdit != null)
        CustomSemanticsAction(label: strings.gdEditDock): widget.onEdit!,
      CustomSemanticsAction(label: strings.gdHideDock): _hideByHand,
    };
    final surface = _GlassSurface(
      opaque: opaque,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Behind the icons and inside the bar's clip: it never spills
          // out of the pill. Its own layer, so a glide repaints one
          // gradient and neither the icons nor anything outside the bar.
          IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                key: const ValueKey('gesture-dock-light'),
                painter: DockLightPainter(
                  light: _c.light,
                  slots: tabs.length,
                  color: colors.accent,
                  rtl: _rtl,
                  inset: _rowInset,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: _rowInset),
            child: Row(
              children: [
                for (var i = 0; i < tabs.length; i++)
                  Expanded(child: _buildTab(context, tabs, i, strings, colors)),
              ],
            ),
          ),
        ],
      ),
    );
    return Semantics(
      key: const ValueKey('gesture-dock'),
      container: true,
      explicitChildNodes: true,
      customSemanticsActions: actions,
      child: Listener(
        key: const ValueKey('gesture-dock-pointer'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) =>
            _onDown(e, width - _rowInset * 2, const Offset(_rowInset, 0)),
        onPointerMove: _onMove,
        onPointerUp: _onUp,
        onPointerCancel: _onCancel,
        child: AnimatedBuilder(
          animation: _hide,
          builder: (context, child) => _transformed(child!),
          child: RepaintBoundary(child: surface),
        ),
      ),
    );
  }

  /// Leaving and coming back is a transform and an opacity on the bar
  /// alone: nothing above or beside it rebuilds.
  Widget _transformed(Widget child) {
    final t = const Cubic(.3, .8, .3, 1).transform(_hide.value);
    final sx = 1 - (1 - .16) * t;
    final sy = 1 - (1 - .22) * t;
    return Opacity(
      opacity: (1 - t).clamp(0.0, 1.0).toDouble(),
      child: Transform(
        alignment: Alignment.bottomCenter,
        transform: Matrix4.translationValues(0, gestureDockHeight / 2 * t, 0)
          ..scaleByDouble(sx, sy, 1, 1),
        child: child,
      ),
    );
  }

  Widget _buildTab(
    BuildContext context,
    List<GestureDockTab> tabs,
    int index,
    Strings strings,
    HermesThemeColors colors,
  ) {
    final tab = tabs[index];
    final action = widget.onTab[tab];
    // Matte: the selected place is its filled icon in the accent colour,
    // and nothing else. No glow, no shadow, no halo.
    final selected = tab.isPlace && widget.current == tab;
    final shortcuts = widget.shortcuts[tab] ?? const <DockShortcut>[];
    final label = gestureDockTabLabel(strings, tab);
    final enabled = action != null || selected;
    final glyph = Icon(
      gestureDockTabIcon(tab, selected: selected),
      size: tab == GestureDockTab.create ? 28 : 24,
      color: selected
          ? colors.accentText
          : (enabled ? colors.textSecondary : colors.textDisabled),
    );
    return Semantics(
      key: ValueKey('gesture-dock-tab-${tab.name}'),
      button: true,
      selected: selected,
      enabled: enabled,
      label: label,
      onTap: action == null ? null : () => _run(index),
      onLongPress: shortcuts.isNotEmpty
          ? () => _openPopover(tab)
          : widget.onEdit,
      excludeSemantics: true,
      child: ValueListenableBuilder<int?>(
        valueListenable: _pressed,
        builder: (context, pressed, child) => AnimatedScale(
          scale: pressed == index ? .9 : 1,
          duration: _reduced
              ? Duration.zero
              : const Duration(milliseconds: 120),
          child: child,
        ),
        child: SizedBox(
          height: 46,
          child: Stack(
            alignment: Alignment.center,
            children: [
              glyph,
              if (tab == GestureDockTab.home && !selected)
                _AttentionDot(
                  attention: widget.attention,
                  needsYou: widget.needsYou,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// What a hidden dock leaves on screen: one pill, one tap, the dock is
  /// back. It fades in as the bar goes ([_hide]), so one of the two is
  /// always there.
  Widget _buildHandle(BuildContext context, Strings strings, bool hidden) {
    final colors = Theme.of(context).hermes;
    return IgnorePointer(
      ignoring: !hidden,
      child: FadeTransition(
        opacity: _hide,
        child: Semantics(
          key: const ValueKey('gesture-dock-handle'),
          button: true,
          label: strings.gdShowDock,
          onTap: hidden ? _showFromHandle : null,
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _showFromHandle,
            child: SizedBox.fromSize(
              size: dockHandleTarget,
              child: Center(
                child: Container(
                  key: const ValueKey('gesture-dock-handle-pill'),
                  width: dockHandleSize.width,
                  height: dockHandleSize.height,
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(
                      dockHandleSize.height / 2,
                    ),
                    border: Border.all(color: colors.divider),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x40000000),
                        blurRadius: 12,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.keyboard_arrow_up_rounded,
                    size: 24,
                    color: colors.accentText,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The icon of each item: outlined, and filled when it is the selected
/// place. The bar and the tablet rail both read it, so the two forms of the
/// dock can never show different symbols.
IconData gestureDockTabIcon(
  GestureDockTab tab, {
  bool selected = false,
}) => switch (tab) {
  GestureDockTab.home => selected ? Icons.home_rounded : Icons.home_outlined,
  GestureDockTab.create => Icons.add_rounded,
  GestureDockTab.projects =>
    selected ? Icons.folder_rounded : Icons.folder_outlined,
  GestureDockTab.settings =>
    selected ? Icons.settings_rounded : Icons.settings_outlined,
  GestureDockTab.bots =>
    selected ? Icons.smart_toy_rounded : Icons.smart_toy_outlined,
  // The conversation list. Its stored name is still `search`.
  GestureDockTab.search =>
    selected ? Icons.chat_bubble_rounded : Icons.chat_bubble_outline_rounded,
  GestureDockTab.cron =>
    selected ? Icons.watch_later_rounded : Icons.schedule_outlined,
  // The board's own icon in the drawer, which has both forms.
  GestureDockTab.tasks =>
    selected ? Icons.view_kanban_rounded : Icons.view_kanban_outlined,
  GestureDockTab.tools =>
    selected ? Icons.handyman_rounded : Icons.handyman_outlined,
  GestureDockTab.activity => Icons.bolt_outlined,
};

String gestureDockTabLabel(Strings strings, GestureDockTab tab) =>
    switch (tab) {
      GestureDockTab.home => strings.gdTabHome,
      GestureDockTab.create => strings.gdGotoNewChat,
      GestureDockTab.projects => strings.gdTabProjects,
      GestureDockTab.settings => strings.gdTabSettings,
      GestureDockTab.bots => strings.missionBotsLabel,
      GestureDockTab.search => strings.dockSessionsLabel,
      GestureDockTab.cron => strings.gdShortCron,
      GestureDockTab.tasks => strings.gdShortTasks,
      GestureDockTab.tools => strings.drawerTools,
      GestureDockTab.activity => strings.gdActivityTitle,
    };

/// Steps the dock aside while the keyboard is open.
///
/// The Scaffold zeroes the bottom inset for its body, so the keyboard is
/// read from the view. The view does not notify its dependents, so this
/// listens to the metrics itself: a gate that only looked while building
/// stayed shut after the keyboard closed whenever nothing rebuilt it, and
/// the dock (bar and handle) was left invisible and untouchable.
class _KeyboardGate extends StatefulWidget {
  final Widget child;
  final VoidCallback onChanged;

  const _KeyboardGate({required this.child, required this.onChanged});

  @override
  State<_KeyboardGate> createState() => _KeyboardGateState();
}

class _KeyboardGateState extends State<_KeyboardGate>
    with WidgetsBindingObserver {
  bool _open = false;

  bool _read() => View.of(context).viewInsets.bottom > 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _open = _read();
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final open = _read();
    if (open == _open) return;
    setState(() => _open = open);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _open = _read();
    widget.onChanged();
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return IgnorePointer(
      key: const ValueKey('gesture-dock-keyboard-gate'),
      ignoring: _open,
      child: AnimatedOpacity(
        opacity: _open ? 0 : 1,
        duration: reduced ? Duration.zero : const Duration(milliseconds: 140),
        child: widget.child,
      ),
    );
  }
}

/// The bar's surface: the floating chrome of the theme, opaque when asked
/// to. It never blurs: nothing scrolls behind the dock (a page's list
/// dissolves before reaching it), so a backdrop blur would only cost a pass
/// on every frame.
class _GlassSurface extends StatelessWidget {
  final bool opaque;
  final Widget child;

  const _GlassSurface({required this.opaque, required this.child});

  @override
  Widget build(BuildContext context) {
    final chrome = HermesChrome.ofContext(context);
    final radius = BorderRadius.circular(gestureDockHeight / 2);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: const [
          BoxShadow(
            color: Color(0x59000000),
            blurRadius: 30,
            offset: Offset(0, 14),
            spreadRadius: -10,
          ),
        ],
      ),
      child: DecoratedBox(
        key: ValueKey(opaque ? 'gesture-dock-opaque' : 'gesture-dock-glass'),
        decoration: BoxDecoration(
          color: opaque ? chrome.opaque : chrome.fill,
          borderRadius: radius,
          border: Border.all(color: chrome.line),
        ),
        // The light that glides behind the icons is a plain rectangle: the
        // bar's own pill is what keeps it inside the rounded ends.
        child: ClipRRect(borderRadius: radius, child: child),
      ),
    );
  }
}

class _AttentionDot extends StatelessWidget {
  final Listenable? attention;
  final bool Function() needsYou;

  const _AttentionDot({required this.attention, required this.needsYou});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    Widget dot() => needsYou()
        ? Positioned(
            top: 7,
            left: 0,
            right: 0,
            child: Center(
              child: Transform.translate(
                offset: const Offset(12, 0),
                child: Container(
                  key: const ValueKey('gesture-dock-attention'),
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: colors.warning,
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.surface, width: 2),
                  ),
                ),
              ),
            ),
          )
        : const SizedBox.shrink();
    final source = attention;
    if (source == null) return dot();
    return ListenableBuilder(
      listenable: source,
      builder: (context, _) => dot(),
    );
  }
}

class _ShortcutPopover extends StatelessWidget {
  final GestureDockTab tab;

  /// Where [tab] sits on the bar (on screen, left to right in LTR).
  final int slot;
  final int slots;
  final double bottom;
  final List<DockShortcut> shortcuts;
  final ValueChanged<DockShortcut> onSelected;

  const _ShortcutPopover({
    required this.tab,
    required this.slot,
    required this.slots,
    required this.bottom,
    required this.shortcuts,
    required this.onSelected,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final width = MediaQuery.sizeOf(context).width;
    const popoverWidth = 236.0;
    final barWidth = width - gestureDockSideMargin * 2 - 12;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final onScreen = rtl ? slots - 1 - slot : slot;
    final center =
        gestureDockSideMargin + 6 + barWidth / slots * (onScreen + .5);
    final left = (center - popoverWidth / 2)
        .clamp(10.0, math.max(10.0, width - popoverWidth - 10))
        .toDouble();
    final strings = Strings.of(context);
    return Positioned(
      left: left,
      bottom: bottom,
      width: popoverWidth,
      child: Semantics(
        container: true,
        label: strings.gdShortcutsOf(gestureDockTabLabel(strings, tab)),
        child: Material(
          color: colors.surface,
          elevation: 8,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final shortcut in shortcuts)
                InkWell(
                  key: ValueKey('gesture-dock-shortcut-${shortcut.label}'),
                  onTap: () => onSelected(shortcut),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(
                        children: [
                          Icon(shortcut.icon, size: 20, color: colors.accent),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              shortcut.label,
                              style: TextStyle(color: colors.textPrimary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
