import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../../l10n/app_localizations.dart';
import '../design/gel_surface.dart';
import '../design/glass_strip.dart';
import '../design/liquid_glass.dart';
import '../design/smoked_glass.dart';
import '../design/tokens.dart'
    show HermesChrome, HermesGel, HermesRadius, HermesSpace;
import '../services/dock_preferences_store.dart';
import '../services/ssh_profile_presence.dart';
import '../theme/app_theme.dart';
import '../theme/theme_contrast.dart';
import '../theme/hermes_tokens.dart' show HermesIcon;
import '../widgets/dock_style.dart' show resolveDockVisual;
import '../widgets/frosted_backdrop.dart';
import 'dock_geometry.dart';
import 'dock_light.dart';
import 'gesture_dock_state.dart';
import '../feedback/haptics.dart';

/// Height of the floating bar, and the side of the round «+» beside it
/// (QA 9709, dock-final: one pill of places and «+» apart).
const double gestureDockHeight = 56;

/// Gap between the pill of places and the round «+».
const double gestureDockGap = HermesSpace.gap;

/// Width of an item in the pill: 64 dp, down to the 48 dp touch target on
/// narrow screens.
const double gestureDockSlotMax = 64;
const double gestureDockSlotMin = HermesSpace.tap;

/// Inner padding of the pill at each end.
const double gestureDockPillInset = 4;

/// Gap between the bar and the screen sides.
const double gestureDockSideMargin = 14;

/// Tighter spacing, used only when five places and «+» would not fit a narrow
/// window at the 48 dp target otherwise (a 320 dp phone with the cover of a
/// folding one): the destinations stay, the air between them gives.
const double gestureDockSideMarginTight = HermesSpace.x2;
const double gestureDockGapTight = HermesSpace.x1;
const double gestureDockPillInsetTight = HermesSpace.x1 / 2;

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

/// How the dock's items sit: the places in one pill, «Nuevo chat» apart
/// as a round piece of the same glass when the layout has it. Its order in
/// the layout does not move it: it is always the round piece at the end.
@immutable
class GestureDockLayout {
  const GestureDockLayout._({
    required this.places,
    required this.create,
    required this.slot,
    this.gap = gestureDockGap,
    this.inset = gestureDockPillInset,
    this.tight = false,
  });

  /// [tabs] (the user's layout) in [available] width (the window less the
  /// side margins).
  ///
  /// When the places at the 48 dp target and «+» do not fit, the spacing is
  /// compacted ([tight]): a narrower gap, inset and side margin, which makes
  /// the bar up to [gestureDockSideMargin] − [gestureDockSideMarginTight] per
  /// side wider than [available]. No destination is left out.
  factory GestureDockLayout.of(List<GestureDockTab> tabs, double available) {
    final places = [
      for (final tab in tabs)
        if (tab != GestureDockTab.create) tab,
    ];
    final create = tabs.contains(GestureDockTab.create);
    GestureDockLayout build(double room, double gap, double inset, bool tight) {
      final round = create ? gap + gestureDockHeight : 0.0;
      final free = room - round - inset * 2;
      final slot = places.isEmpty
          ? gestureDockSlotMax
          : (free / places.length)
                .clamp(gestureDockSlotMin, gestureDockSlotMax)
                .toDouble();
      return GestureDockLayout._(
        places: List.unmodifiable(places),
        create: create,
        slot: slot,
        gap: gap,
        inset: inset,
        tight: tight,
      );
    }

    final roomy = build(available, gestureDockGap, gestureDockPillInset, false);
    if (roomy.width <= available) return roomy;
    return build(
      available + (gestureDockSideMargin - gestureDockSideMarginTight) * 2,
      gestureDockGapTight,
      gestureDockPillInsetTight,
      true,
    );
  }

  /// Gap between the pill and «+», and the pill's inner padding.
  final double gap;
  final double inset;

  /// The compacted spacing of a narrow window (see [GestureDockLayout.of]).
  final bool tight;

  /// Every item but «Nuevo chat», in the user's order.
  final List<GestureDockTab> places;

  /// Whether the round «+» shows.
  final bool create;

  /// Width of each item of the pill.
  final double slot;

  double get pillWidth => slot * places.length + inset * 2;

  /// Both pieces and the gap between them.
  double get width => pillWidth + (create ? gap + gestureDockHeight : 0);

  /// The item under [dx] (from the left of both pieces), mirrored in
  /// right-to-left languages, where «+» is on the left.
  GestureDockTab? tabAt(double dx, {required bool rtl}) {
    if (dx < 0 || dx > width) return null;
    final x = rtl ? width - dx : dx;
    if (x > pillWidth) {
      return create && x >= pillWidth + gap ? GestureDockTab.create : null;
    }
    if (places.isEmpty) return null;
    final slotIndex = ((x - inset) / slot).floor().clamp(0, places.length - 1);
    return places[slotIndex];
  }

  /// Centre of [tab] from the left of both pieces, as drawn.
  double centerOf(GestureDockTab tab, {required bool rtl}) {
    final x = tab == GestureDockTab.create
        ? width - gestureDockHeight / 2
        : inset + slot * (places.indexOf(tab) + .5);
    return rtl ? width - x : x;
  }
}

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
  final ValueNotifier<GestureDockTab?> _pressed =
      ValueNotifier<GestureDockTab?>(null);
  final GlobalKey _barSlot = GlobalKey(debugLabel: 'gesture-dock-bar');
  final GlobalKey _handleSlot = GlobalKey(debugLabel: 'gesture-dock-handle');

  int? _pointer;
  Offset _start = Offset.zero;
  GestureDockTab? _downTab;
  bool _moved = false;
  bool _longPressed = false;
  Timer? _longPressTimer;

  GestureDockTab? _popover;
  bool _attached = false;
  bool _geometryQueued = false;

  /// The items on the bar, in the user's order (edit mode).
  List<GestureDockTab> get _tabs => gestureDockShownTabs(_c.value.tabs);
  List<GestureDockTab> _lightTabs = const [];

  /// The items of the pill: every item but «Nuevo chat», which is the
  /// round piece beside it.
  List<GestureDockTab> get _places => [
    for (final tab in _tabs)
      if (tab != GestureDockTab.create) tab,
  ];

  /// Where the place this screen is sits in the pill, if it is in it.
  int? get _currentSlot {
    final current = widget.current;
    if (current == null || !current.isPlace) return null;
    final slot = _places.indexOf(current);
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
    SshProfilePresence.instance.addListener(_onSettingsChanged);
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
    SshProfilePresence.instance.removeListener(_onSettingsChanged);
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

  void _onDown(PointerDownEvent event, GestureDockLayout layout) {
    if (_pointer != null) return;
    _closePopover();
    _pointer = event.pointer;
    _start = event.position;
    _moved = false;
    _longPressed = false;
    final tab = layout.tabAt(event.localPosition.dx, rtl: _rtl);
    _downTab = tab;
    _pressed.value = tab;
    _longPressTimer?.cancel();
    // An item with a menu opens it; anywhere else on the bar the long
    // press opens the edit mode.
    final hasMenu = tab != null && (widget.shortcuts[tab]?.isNotEmpty ?? false);
    if (hasMenu || widget.onEdit != null) {
      _longPressTimer = Timer(dockLongPress, () {
        if (_moved || _pointer == null) return;
        _longPressed = true;
        _pressed.value = null;
        HermesHaptics.selection();
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

  /// Runs [tab]. For a place the light leaves for it at once, before the
  /// screen it opens is there, so it reads as the light picking the
  /// destination. An action ("Nuevo", "Actividad") moves no light.
  void _run(GestureDockTab tab) {
    final action = widget.onTab[tab];
    if (action == null) return;
    final slot = _places.indexOf(tab);
    if (tab.isPlace && slot >= 0) _c.light.moveTo(slot, animate: !_reduced);
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

  /// Room above and below the selected item's pill inside its 48 dp.
  static const double _activeInset = HermesSpace.x1 / 2;

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
      child: ListenableBuilder(
        listenable: Listenable.merge([
          _c.settings,
          SshProfilePresence.instance,
        ]),
        builder: (context, _) => LayoutBuilder(
          builder: (context, constraints) {
            final hidden = _c.hidden.value;
            final layout = GestureDockLayout.of(
              gestureDockShownTabs(_c.value.tabs),
              constraints.maxWidth - gestureDockSideMargin * 2,
            );
            final left = (constraints.maxWidth - layout.width) / 2;
            final popover = _popover;
            return Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.none,
              children: [
                if (popover != null)
                  Positioned.fill(
                    child: GestureDetector(
                      key: const ValueKey('gesture-dock-popover-barrier'),
                      behavior: HitTestBehavior.translucent,
                      onTap: _closePopover,
                    ),
                  ),
                Positioned(
                  key: _barSlot,
                  left: left,
                  width: layout.width,
                  bottom: dockBottom,
                  height: gestureDockHeight,
                  // Bar or handle: whichever is in view takes the touches.
                  child: ExcludeSemantics(
                    excluding: hidden,
                    child: IgnorePointer(
                      ignoring: hidden,
                      child: _buildBar(context, layout, _c.value),
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
                if (popover != null)
                  _ShortcutPopover(
                    key: const ValueKey('gesture-dock-popover'),
                    tab: popover,
                    center: left + layout.centerOf(popover, rtl: _rtl),
                    bottom: dockBottom + gestureDockHeight + 10,
                    shortcuts: widget.shortcuts[popover] ?? const [],
                    onSelected: (shortcut) {
                      _closePopover();
                      shortcut.onTap();
                    },
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// The pill of places and, apart, the round «+»: two pieces of the same
  /// glass (QA 9709, dock-final). One listener takes the touches of both.
  Widget _buildBar(
    BuildContext context,
    GestureDockLayout layout,
    GestureDockSettings settings,
  ) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final opaque = settings.opaque || MediaQuery.highContrastOf(context);
    final dockVisual = resolveDockVisual(
      colors,
      DockPreferencesController.instance.value.general.style,
    );
    final tone = opaque ? null : _dockTone(colors, dockVisual.background);
    // What a long press reaches, for a screen reader.
    final actions = <CustomSemanticsAction, VoidCallback>{
      if (widget.onActivity != null)
        CustomSemanticsAction(label: strings.gdActivityTitle):
            widget.onActivity!,
      if (widget.onEdit != null)
        CustomSemanticsAction(label: strings.gdEditDock): widget.onEdit!,
      CustomSemanticsAction(label: strings.gdHideDock): _hideByHand,
    };
    final pill = _GlassSurface(
      opaque: opaque,
      name: 'gesture-dock',
      width: layout.pillWidth,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Behind the icons and inside the pill's clip: it never spills
          // out of it. Its own layer, so a glide repaints one gradient and
          // neither the icons nor anything outside the pill.
          IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                key: const ValueKey('gesture-dock-light'),
                painter: DockLightPainter(
                  light: _c.light,
                  slots: layout.places.length,
                  color: colors.accent,
                  rtl: _rtl,
                  inset: layout.inset,
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: layout.inset),
            child: Row(
              children: [
                for (final tab in layout.places)
                  SizedBox(
                    width: layout.slot,
                    child: _buildTab(context, tab, strings, colors),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    final pieces = Row(
      children: [
        pill,
        if (layout.create) ...[
          SizedBox(width: layout.gap),
          _GlassSurface(
            opaque: opaque,
            name: 'gesture-dock-create',
            width: gestureDockHeight,
            child: _buildTab(context, GestureDockTab.create, strings, colors),
          ),
        ],
      ],
    );
    return Semantics(
      key: const ValueKey('gesture-dock'),
      container: true,
      explicitChildNodes: true,
      customSemanticsActions: actions,
      child: Listener(
        key: const ValueKey('gesture-dock-pointer'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) => _onDown(e, layout),
        onPointerMove: _onMove,
        onPointerUp: _onUp,
        onPointerCancel: _onCancel,
        child: AnimatedBuilder(
          animation: _hide,
          builder: (context, child) => _transformed(
            HermesLiquidMotion(
              moving: _hide.isAnimating || _hide.value != 0,
              child: child!,
            ),
          ),
          child: RepaintBoundary(
            child: HermesGlassStrip(
              zone: FrostedZone.bottom,
              liquid: tone == null ? HermesLiquid.dock : null,
              tone: tone,
              toneInks: HermesSmokedGlass.barInks(colors),
              enabled: !opaque && dockVisual.blurSigma > 0,
              blurSigma: dockVisual.blurSigma,
              veil: dockVisual.background,
              weakInk: colors.textPrimary,
              child: pieces,
            ),
          ),
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

  /// One item: its icon only, no label (QA 9709). The selected place sits
  /// on a faint pill of the accent colour, its icon filled in the accent;
  /// every other item is outlined in the colour of the text. Its name is
  /// for a screen reader, and a long press reaches its menu.
  Widget _buildTab(
    BuildContext context,
    GestureDockTab tab,
    Strings strings,
    HermesThemeColors colors,
  ) {
    final action = widget.onTab[tab];
    final selected = tab.isPlace && widget.current == tab;
    final shortcuts = widget.shortcuts[tab] ?? const <DockShortcut>[];
    final label = gestureDockTabLabel(strings, tab);
    final enabled = action != null || selected;
    final selection = colors.accent.withValues(
      alpha: HermesGel.dockGlowCertified(HermesChrome.of(colors).dark),
    );
    final glyph = Builder(
      builder: (context) => Icon(
        gestureDockTabIcon(tab, selected: selected),
        size: HermesIcon.xl,
        color: selected
            ? _selectedDockInk(
                colors,
                selection,
                _DockSurfaceFill.of(context),
                tone: HermesGlassStrip.of(context)?.tone,
              )
            : (enabled ? colors.textPrimary : colors.textDisabled),
      ),
    );
    return Semantics(
      key: ValueKey('gesture-dock-tab-${tab.name}'),
      button: true,
      selected: selected,
      enabled: enabled,
      label: label,
      onTap: action == null ? null : () => _run(tab),
      onLongPress: shortcuts.isNotEmpty
          ? () => _openPopover(tab)
          : widget.onEdit,
      excludeSemantics: true,
      child: ValueListenableBuilder<GestureDockTab?>(
        valueListenable: _pressed,
        builder: (context, pressed, child) => AnimatedScale(
          scale: pressed == tab ? .9 : 1,
          duration: _reduced
              ? Duration.zero
              : const Duration(milliseconds: 120),
          child: child,
        ),
        // A hover name for a pointer; touch keeps its long press (the item's
        // menu), so the tooltip never opens by itself.
        child: Tooltip(
          message: label,
          triggerMode: TooltipTriggerMode.manual,
          excludeFromSemantics: true,
          child: SizedBox(
            height: HermesSpace.tap,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (selected)
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: HermesSpace.x1,
                        vertical: _activeInset,
                      ),
                      child: DecoratedBox(
                        key: const ValueKey('gesture-dock-active'),
                        decoration: HermesGel.glow(
                          colors.accent,
                          BorderRadius.circular(HermesRadius.tag),
                        ),
                      ),
                    ),
                  ),
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
  // Agents (the terminal's agent mode): a robot at a prompt, not the bot
  // face of Bots.
  GestureDockTab.agents =>
    selected ? Icons.terminal_rounded : Icons.terminal_outlined,
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
      GestureDockTab.agents => strings.navAgents,
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

/// The visible outline and fill of one piece of the dock's shared band.
class _GlassSurface extends StatelessWidget {
  /// Either the user's opaque dock (Editar dock › opaco) or high contrast.
  final bool opaque;

  /// Key prefix: `<name>-glass` or `<name>-opaque` on the fill.
  final String name;
  final double width;
  final Widget child;

  const _GlassSurface({
    required this.opaque,
    required this.name,
    required this.width,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    // The dock's glass, the same recipe as the rail's and the classic
    // bar's (Ajustes › Dock › Transparencia): a light translucent veil, a
    // line of light and a soft shadow, over a moderate blur.
    final visual = resolveDockVisual(
      colors,
      DockPreferencesController.instance.value.general.style,
    );
    final radius = BorderRadius.circular(HermesRadius.tag);
    final glass = HermesGlassStrip.of(context);
    final tint = opaque ? chrome.opaque : visual.background;
    Widget fill(BuildContext context, Color color) => _DockSurfaceFill(
      color: color,
      child: DecoratedBox(
        key: ValueKey(opaque ? '$name-opaque' : '$name-glass'),
        decoration: BoxDecoration(
          color: color,
          borderRadius: radius,
          border: Border.all(color: opaque ? chrome.line : visual.border),
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: HermesGelSurface(
            shape: RoundedRectangleBorder(borderRadius: radius),
            pressable: false,
            child: child,
          ),
        ),
      ),
    );
    return HermesGlassPiece(
      shape: RoundedRectangleBorder(borderRadius: radius),
      child: SizedBox(
        width: width,
        height: gestureDockHeight,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: glass?.tone != null
                ? null
                : opaque
                ? chrome.shadow
                : visual.shadows,
          ),
          child: fill(
            context,
            glass?.veil ?? Color.alphaBlend(tint, colors.background),
          ),
        ),
      ),
    );
  }
}

/// The fill actually painted by the owning dock surface, also in opaque
/// and policy fallback states. This carries color, never material/state.
class _DockSurfaceFill extends InheritedWidget {
  const _DockSurfaceFill({required this.color, required super.child});

  final Color color;

  static Color of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_DockSurfaceFill>()!.color;

  @override
  bool updateShouldNotify(_DockSurfaceFill oldWidget) =>
      color != oldWidget.color;
}

HermesSmokedGlass? _dockTone(HermesThemeColors colors, Color fill) {
  if (fill.a >= 1) return null;
  final chrome = HermesChrome.of(colors);
  final tone = HermesSmokedGlass.dockOf(chrome).withVeilFloor(fill.a);
  final selection = colors.accent.withValues(alpha: chrome.dark ? .16 : .14);
  final ink = _tonedSelectedDockInk(colors, selection, tone);
  // Test the whole range, including an equal-luminance interior and the
  // opaque fallback painted immediately when another strip takes the zone.
  return ink.achieved &&
          tone.worstRatio(ink.color, chrome, over: selection) >= 3.05
      ? tone
      : null;
}

ThemeContrastAdjustment _tonedSelectedDockInk(
  HermesThemeColors colors,
  Color selection,
  HermesSmokedGlass tone,
) {
  final (dark, light) = tone.underExtremes(
    HermesChrome.of(colors),
    over: selection,
  );
  return ThemeContrast.adjustForContrastResult(
    colors.accentText,
    [dark, light],
    minimum: 3.05,
    maximumHueShift: 10,
  );
}

Color _selectedDockInk(
  HermesThemeColors colors,
  Color selection,
  Color fill, {
  HermesSmokedGlass? tone,
}) {
  if (tone != null) return _tonedSelectedDockInk(colors, selection, tone).color;
  final backgrounds = <Color>[];
  if (fill.a > 0) {
    for (final behind in [Colors.black, Colors.white]) {
      backgrounds.add(
        ThemeContrast.composite(
          selection,
          ThemeContrast.composite(fill, behind),
        ),
      );
    }
  } else {
    // With an adaptive shader the child fill is transparent. Bound the
    // background by its guaranteed primary-ink AA, then the REAL selection
    // tint. Convex sRGB luminance gives the dark upper bound; scaling RGB
    // by (1-alpha) gives at least (1-alpha)^2.4 luminance in a light theme.
    // The margin/gray rounding cover integer compositing. No title badge.
    final primary = ThemeContrast.luminance(colors.textPrimary);
    final alpha = ((selection.toARGB32() >> 24) & 255) / 255;
    final dark = HermesChrome.of(colors).dark;
    final limit = dark
        ? (1 - alpha) * ((primary + .05) / HermesLiquid.target - .05) +
              alpha * ThemeContrast.luminance(selection.withValues(alpha: 1)) +
              .01
        : math.pow(1 - alpha, 2.4) *
                  (HermesLiquid.target * (primary + .05) - .05) -
              .01;
    var channel = 0;
    Color gray(int value) => Color.fromARGB(255, value, value, value);
    while (channel < 255 && ThemeContrast.luminance(gray(channel)) < limit) {
      channel++;
    }
    if (!dark && channel > 0) channel--;
    backgrounds.addAll(
      dark ? [Colors.black, gray(channel)] : [gray(channel), Colors.white],
    );
  }
  final adjustment = ThemeContrast.adjustForContrastResult(
    colors.accentText,
    backgrounds,
    minimum: 3.05,
    maximumHueShift: 10,
  );
  assert(adjustment.achieved, 'dock selection ink must reach its contrast');
  return adjustment.color;
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

  /// Horizontal centre of [tab]'s piece, from the left of the dock's
  /// parent.
  final double center;
  final double bottom;
  final List<DockShortcut> shortcuts;
  final ValueChanged<DockShortcut> onSelected;

  const _ShortcutPopover({
    required this.tab,
    required this.center,
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
