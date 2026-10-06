import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'dock_geometry.dart';
import 'gesture_dock_state.dart';

/// Height of the floating bar.
const double gestureDockHeight = 60;

/// Gap between the bar and the screen sides.
const double gestureDockSideMargin = 14;

/// Gap between the bar and the system navigation area.
const double gestureDockBottomGap = 14;

/// Space kept free between the end of a list and the top of the bar.
const double gestureDockBreathing = 8;

/// Gesture thresholds (owner guide § 2), in logical pixels.
const double dockAxisLock = 9;
const double dockSwipeThreshold = 40;
const double dockHideThreshold = 32;
const double dockGotoThreshold = 28;
const double dockBounceDistance = 12;
const double dockLineTapSlop = 8;
const double dockLineDragThreshold = 12;
const Duration dockLongPress = Duration(milliseconds: 480);
const Duration dockBounceDuration = Duration(milliseconds: 240);
const Duration dockTapSwallow = Duration(milliseconds: 120);
const Duration dockHideDuration = Duration(milliseconds: 350);

/// Bottom space content keeps free so the bar never covers its last row:
/// system inset, gap, bar and a breathing gap. It does not change while
/// the dock hides or shows, so content never relayouts for it.
double gestureDockFootprint(BuildContext context) =>
    MediaQuery.viewPaddingOf(context).bottom +
    gestureDockBottomGap +
    gestureDockHeight +
    gestureDockBreathing;

/// One shortcut in a tab's long-press popover.
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

/// The floating glass dock with gestures: "Flotante · iconos".
///
/// It fills its parent `Stack` and places itself; the screen keeps the
/// [gestureDockFootprint] free at the bottom. Navigation is the host's:
/// the dock only reports which tab was chosen.
class GestureDock extends StatefulWidget {
  /// The tab this screen is. Null on screens that are none of them.
  final GestureDockTab? current;

  /// What each tab does here. A missing or null entry renders the tab
  /// disabled.
  final Map<GestureDockTab, VoidCallback?> onTab;

  /// The long-press popover of each tab.
  final Map<GestureDockTab, List<DockShortcut>> shortcuts;

  /// Opens "Ir a" (swipe up).
  final VoidCallback? onGoto;

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
    this.onGoto,
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

enum _Axis { none, x, up, down }

class _GestureDockState extends State<GestureDock>
    with TickerProviderStateMixin {
  GestureDockController get _c =>
      widget.controller ?? GestureDockController.instance;
  DockGeometry get _geometry => widget.geometry ?? DockGeometry.instance;

  late final AnimationController _hide = AnimationController(
    vsync: this,
    duration: dockHideDuration,
  );
  late final AnimationController _bounce = AnimationController(
    vsync: this,
    duration: dockBounceDuration,
  );
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  final ValueNotifier<Offset> _drag = ValueNotifier<Offset>(Offset.zero);
  final ValueNotifier<int?> _pressed = ValueNotifier<int?>(null);
  final GlobalKey _barSlot = GlobalKey(debugLabel: 'gesture-dock-bar');
  final GlobalKey _lineSlot = GlobalKey(debugLabel: 'gesture-dock-line');

  Offset _releaseOffset = Offset.zero;
  Offset _settleFrom = Offset.zero;
  double _bounceDir = 0;

  int? _pointer;
  Offset _start = Offset.zero;
  Offset _last = Offset.zero;
  _Axis? _axis;
  int? _downTab;
  bool _edge = false;
  bool _longPressed = false;
  Timer? _longPressTimer;
  Timer? _swallowTimer;
  bool _swallowing = false;

  GestureDockTab? _popover;
  bool _attached = false;
  bool _geometryQueued = false;

  static const _tabs = GestureDockTab.values;

  bool get _reduced => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void initState() {
    super.initState();
    _hide.value = _c.hidden.value ? 1 : 0;
    _c.hidden.addListener(_onHiddenChanged);
    _settle.addListener(() {
      _drag.value = Offset.lerp(
        _settleFrom,
        Offset.zero,
        Curves.easeOutCubic.transform(_settle.value),
      )!;
    });
    unawaited(_c.ensureLoaded());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible && !_attached) {
      _attached = true;
      _c.attach(this, _queueGeometry);
    } else if (!visible && _attached) {
      _attached = false;
      _geometry.clear(this);
      _c.detach(this);
      _closePopover();
    }
    final duration = _reduced ? Duration.zero : dockHideDuration;
    _hide.duration = duration;
    _hide.reverseDuration = duration;
    _bounce.duration = _reduced ? Duration.zero : dockBounceDuration;
    _settle.duration = _reduced
        ? Duration.zero
        : const Duration(milliseconds: 200);
  }

  @override
  void didUpdateWidget(covariant GestureDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      (oldWidget.controller ?? GestureDockController.instance).hidden
          .removeListener(_onHiddenChanged);
      _c.hidden.addListener(_onHiddenChanged);
    }
  }

  @override
  void dispose() {
    _c.hidden.removeListener(_onHiddenChanged);
    _geometry.clear(this);
    if (_attached) _c.detach(this);
    _longPressTimer?.cancel();
    _swallowTimer?.cancel();
    if (_c.dragging && _pointer != null) _c.dragging = false;
    _hide.dispose();
    _bounce.dispose();
    _settle.dispose();
    _drag.dispose();
    _pressed.dispose();
    super.dispose();
  }

  void _onHiddenChanged() {
    if (!mounted) return;
    final hidden = _c.hidden.value;
    if (hidden) {
      unawaited(_hide.forward());
    } else {
      _releaseOffset = Offset.zero;
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
    final hidden = _c.hidden.value && _c.value.mode != DockHideMode.fixed;
    final key = hidden ? _lineSlot : _barSlot;
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return;
    final origin = box.localToGlobal(Offset.zero);
    _geometry.publish(this, origin & box.size, hidden: hidden);
  }

  // ---- gestures --------------------------------------------------------

  int? _tabAt(Offset local, double width) {
    if (local.dx < 0 || local.dx > width) return null;
    final index = (local.dx / (width / _tabs.length)).floor();
    return index.clamp(0, _tabs.length - 1);
  }

  bool _inSystemGestureInset(Offset global) {
    final insets = MediaQuery.systemGestureInsetsOf(context);
    final size = MediaQuery.sizeOf(context);
    return global.dx < insets.left ||
        global.dx > size.width - insets.right ||
        global.dy > size.height - insets.bottom;
  }

  void _onDown(PointerDownEvent event, double width, Offset inset) {
    if (_pointer != null) return;
    _closePopover();
    _pointer = event.pointer;
    _start = event.position;
    _last = event.position;
    _axis = null;
    _longPressed = false;
    _edge = _inSystemGestureInset(event.position);
    _settle.stop();
    _downTab = _tabAt(event.localPosition - inset, width);
    _pressed.value = _downTab;
    final tab = _downTab == null ? null : _tabs[_downTab!];
    _longPressTimer?.cancel();
    if (tab != null &&
        _c.value.gestures &&
        (widget.shortcuts[tab]?.isNotEmpty ?? false)) {
      _longPressTimer = Timer(dockLongPress, () {
        if (_axis != null || _pointer == null) return;
        _longPressed = true;
        _pressed.value = null;
        unawaited(HapticFeedback.selectionClick());
        _openPopover(tab);
        _c.learn(DockGesture.hold);
      });
    }
  }

  void _onMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || _longPressed) return;
    _last = event.position;
    final d = event.position - _start;
    if (_axis == null) {
      if (math.max(d.dx.abs(), d.dy.abs()) <= dockAxisLock) return;
      _longPressTimer?.cancel();
      _pressed.value = null;
      var axis = d.dx.abs() > d.dy.abs()
          ? _Axis.x
          : (d.dy > 0 ? _Axis.down : _Axis.up);
      final s = _c.value;
      if ((axis == _Axis.x || axis == _Axis.up) && (!s.gestures || _edge)) {
        axis = _Axis.none;
      }
      if (axis == _Axis.down && s.mode == DockHideMode.fixed) {
        axis = _Axis.none;
      }
      _axis = axis;
      _c.dragging = axis != _Axis.none;
    }
    switch (_axis) {
      case _Axis.down:
        _drag.value = Offset(0, math.max(0.0, d.dy));
      case _Axis.up:
        _drag.value = Offset(0, math.min(0.0, d.dy) * .35);
      case _Axis.x:
        _drag.value = Offset(d.dx * .25, 0);
      case _Axis.none:
      case null:
        break;
    }
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
    final axis = _axis;
    final d = _last - _start;
    _c.dragging = false;
    if (cancelled) {
      _springBack();
      return;
    }
    if (_longPressed) {
      _swallow();
      return;
    }
    if (axis == null) {
      if (_swallowing || _downTab == null) return;
      final tab = _tabs[_downTab!];
      final action = widget.onTab[tab];
      if (action == null) return;
      action();
      _c.recordTap();
      return;
    }
    _swallow();
    switch (axis) {
      case _Axis.down when d.dy > dockHideThreshold:
        _releaseOffset = _drag.value;
        _drag.value = Offset.zero;
        _c.setHidden(true);
        _c.learn(DockGesture.hide);
      case _Axis.up when d.dy < -dockGotoThreshold:
        _springBack();
        widget.onGoto?.call();
        _c.learn(DockGesture.up);
      case _Axis.x when d.dx.abs() > dockSwipeThreshold:
        _springBack();
        _step(d.dx < 0 ? 1 : -1);
      default:
        _springBack();
    }
  }

  void _swallow() {
    _swallowing = true;
    _swallowTimer?.cancel();
    _swallowTimer = Timer(dockTapSwallow, () => _swallowing = false);
  }

  void _springBack() {
    if (_drag.value == Offset.zero) return;
    _settleFrom = _drag.value;
    if (_reduced) {
      _drag.value = Offset.zero;
      return;
    }
    unawaited(_settle.forward(from: 0));
  }

  /// Next (+1) or previous (-1) place; bounces 12 dp at either end.
  void _step(int dir) {
    const order = GestureDockTab.swipeOrder;
    final index = widget.current == null ? -1 : order.indexOf(widget.current!);
    final next = index + dir;
    final action = (index < 0 || next < 0 || next >= order.length)
        ? null
        : widget.onTab[order[next]];
    if (action == null) {
      _bounceDir = -dir.toDouble();
      if (!_reduced) unawaited(_bounce.forward(from: 0));
      return;
    }
    _c.learn(DockGesture.swipe);
    action();
  }

  void _openPopover(GestureDockTab tab) {
    setState(() => _popover = tab);
    _c.sheetOpen = true;
  }

  void _closePopover() {
    if (_popover == null) return;
    _c.sheetOpen = false;
    if (mounted) setState(() => _popover = null);
  }

  // ---- hidden line -----------------------------------------------------

  Offset? _lineStart;
  Offset _lineLast = Offset.zero;

  void _showFromLine() {
    _c.setHidden(false);
    _c.learn(DockGesture.show);
  }

  // ---- build -----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final padding = MediaQuery.viewPaddingOf(context);
    final dockBottom = padding.bottom + gestureDockBottomGap;
    _queueGeometry();
    return _KeyboardGate(
      onChanged: _queueGeometry,
      child: ValueListenableBuilder<GestureDockSettings>(
        valueListenable: _c.settings,
        builder: (context, settings, _) {
          final hidden = _c.hidden.value && settings.mode != DockHideMode.fixed;
          return Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              _TourScrim(controller: _c),
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
                child: IgnorePointer(
                  ignoring: hidden,
                  child: LayoutBuilder(
                    builder: (context, constraints) =>
                        _buildBar(context, constraints.maxWidth, settings),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: padding.bottom,
                child: Center(
                  child: KeyedSubtree(
                    key: _lineSlot,
                    child: _buildLine(context, strings, hidden),
                  ),
                ),
              ),
              if (_popover != null)
                _ShortcutPopover(
                  key: const ValueKey('gesture-dock-popover'),
                  tab: _popover!,
                  bottom: dockBottom + gestureDockHeight + 10,
                  shortcuts: widget.shortcuts[_popover!] ?? const [],
                  onSelected: (shortcut) {
                    _closePopover();
                    shortcut.onTap();
                  },
                ),
              _CoachLayer(
                controller: _c,
                bottom: dockBottom + gestureDockHeight + 12,
                lineBottom: padding.bottom,
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
    final hideAllowed = settings.mode != DockHideMode.fixed;
    final showGrab =
        hideAllowed && !settings.learned.contains(DockGesture.hide);
    final actions = <CustomSemanticsAction, VoidCallback>{
      if (settings.gestures) ...{
        CustomSemanticsAction(label: strings.gdNextTab): () => _step(1),
        CustomSemanticsAction(label: strings.gdPrevTab): () => _step(-1),
        if (widget.onGoto != null)
          CustomSemanticsAction(label: strings.gdGoto): () {
            widget.onGoto!();
            _c.learn(DockGesture.up);
          },
      },
      if (hideAllowed)
        CustomSemanticsAction(label: strings.gdHideDock): () {
          _c.setHidden(true);
          _c.learn(DockGesture.hide);
        },
    };
    final surface = _GlassSurface(
      opaque: opaque,
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: [
                  for (var i = 0; i < _tabs.length; i++)
                    Expanded(child: _buildTab(context, i, strings, colors)),
                ],
              ),
            ),
          ),
          if (showGrab)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Center(
                child: Semantics(
                  key: const ValueKey('gesture-dock-grab'),
                  button: true,
                  label: strings.gdHideDock,
                  onTap: () {
                    _c.setHidden(true);
                    _c.learn(DockGesture.hide);
                  },
                  child: Container(
                    margin: const EdgeInsets.only(top: 5),
                    width: 26,
                    height: 3,
                    decoration: BoxDecoration(
                      color: colors.textDisabled.withValues(alpha: .8),
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                ),
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
        // Tabs sit inside a 6 dp side padding.
        onPointerDown: (e) => _onDown(e, width - 12, const Offset(6, 0)),
        onPointerMove: _onMove,
        onPointerUp: _onUp,
        onPointerCancel: _onCancel,
        child: AnimatedBuilder(
          animation: Listenable.merge([_hide, _bounce, _drag]),
          builder: (context, child) => _transformed(child!),
          child: RepaintBoundary(child: surface),
        ),
      ),
    );
  }

  /// Every show/hide/drag/bounce frame is a transform and an opacity on the
  /// bar alone: nothing above or beside it rebuilds.
  Widget _transformed(Widget child) {
    final t = const Cubic(.3, .8, .3, 1).transform(_hide.value);
    final drag = _drag.value;
    var dx = drag.dx;
    if (_bounce.isAnimating) {
      final b = _bounce.value;
      dx += _bounceDir * dockBounceDistance * (b < .5 ? b * 2 : (1 - b) * 2);
    }
    final dragOpacity = 1 - math.min<double>(.75, math.max(0.0, drag.dy) / 90);
    final releaseOpacity =
        1 - math.min<double>(.75, math.max(0.0, _releaseOffset.dy) / 90);
    final base = Offset.lerp(
      _releaseOffset,
      const Offset(0, gestureDockHeight / 2),
      t,
    )!;
    final opacity = _hide.value == 0
        ? dragOpacity
        : (releaseOpacity * (1 - t)).clamp(0.0, 1.0).toDouble();
    final sx = 1 - (1 - .16) * t;
    final sy = 1 - (1 - .22) * t;
    return Opacity(
      opacity: opacity,
      child: Transform(
        alignment: Alignment.bottomCenter,
        transform: Matrix4.translationValues(dx + base.dx, drag.dy + base.dy, 0)
          ..scaleByDouble(sx, sy, 1, 1),
        child: child,
      ),
    );
  }

  Widget _buildTab(
    BuildContext context,
    int index,
    Strings strings,
    HermesThemeColors colors,
  ) {
    final tab = _tabs[index];
    final action = widget.onTab[tab];
    final selected = widget.current == tab;
    final shortcuts = widget.shortcuts[tab] ?? const <DockShortcut>[];
    final label = gestureDockTabLabel(strings, tab);
    final icon = switch (tab) {
      GestureDockTab.home =>
        selected ? Icons.home_rounded : Icons.home_outlined,
      GestureDockTab.create => Icons.add_rounded,
      GestureDockTab.projects =>
        selected ? Icons.folder_rounded : Icons.folder_outlined,
      GestureDockTab.settings =>
        selected ? Icons.settings_rounded : Icons.settings_outlined,
    };
    final enabled = action != null || selected;
    final iconColor = selected
        ? colors.accent
        : (enabled ? colors.textSecondary : colors.textDisabled);
    Widget glyph = Icon(
      icon,
      size: tab == GestureDockTab.create ? 28 : 24,
      color: iconColor,
      shadows: selected
          ? [
              Shadow(
                color: colors.accent.withValues(alpha: .85),
                blurRadius: 6,
              ),
              Shadow(
                color: colors.accent.withValues(alpha: .45),
                blurRadius: 14,
              ),
            ]
          : null,
    );
    if (selected) {
      glyph = Transform.translate(offset: const Offset(0, -1), child: glyph);
    }
    return Semantics(
      key: ValueKey('gesture-dock-tab-${tab.name}'),
      button: true,
      selected: selected,
      enabled: enabled,
      label: label,
      onTap: action == null
          ? null
          : () {
              action();
              _c.recordTap();
            },
      onLongPress: shortcuts.isEmpty ? null : () => _openPopover(tab),
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
              if (selected)
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 3,
                    ),
                    child: DecoratedBox(
                      key: const ValueKey('gesture-dock-glow'),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(99),
                        gradient: RadialGradient(
                          colors: [
                            colors.accent.withValues(alpha: .30),
                            colors.accent.withValues(alpha: 0),
                          ],
                        ),
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
    );
  }

  Widget _buildLine(BuildContext context, Strings strings, bool hidden) {
    final colors = Theme.of(context).hermes;
    final duration = _reduced
        ? Duration.zero
        : const Duration(milliseconds: 300);
    return IgnorePointer(
      ignoring: !hidden,
      child: AnimatedOpacity(
        opacity: hidden ? 1 : 0,
        duration: duration,
        child: Semantics(
          key: const ValueKey('gesture-dock-line'),
          button: true,
          label: strings.gdShowDock,
          onTap: hidden ? _showFromLine : null,
          excludeSemantics: true,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) {
              _lineStart = e.position;
              _lineLast = e.position;
            },
            onPointerMove: (e) => _lineLast = e.position,
            onPointerCancel: (_) => _lineStart = null,
            onPointerUp: (e) {
              final start = _lineStart;
              _lineStart = null;
              if (start == null) return;
              final d = e.position - start;
              final moved = (_lineLast - start).distance;
              if (math.max(moved, d.distance) < dockLineTapSlop ||
                  d.dy < -dockLineDragThreshold) {
                _showFromLine();
              }
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(46, 16, 46, 14),
              child: Container(
                width: 56,
                height: 5,
                decoration: BoxDecoration(
                  color: colors.accent,
                  borderRadius: BorderRadius.circular(9),
                  boxShadow: [
                    BoxShadow(
                      color: colors.accent.withValues(alpha: .7),
                      blurRadius: 12,
                      spreadRadius: -1,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String gestureDockTabLabel(Strings strings, GestureDockTab tab) =>
    switch (tab) {
      GestureDockTab.home => strings.gdTabHome,
      GestureDockTab.create => strings.gdTabNew,
      GestureDockTab.projects => strings.gdTabProjects,
      GestureDockTab.settings => strings.gdTabSettings,
    };

/// Rebuilds only its builder when the keyboard opens or closes; the dock
/// slides away while it is open.
class _KeyboardGate extends StatelessWidget {
  final Widget child;
  final VoidCallback onChanged;

  const _KeyboardGate({required this.child, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    // The Scaffold zeroes the inset for its body; the view still has it.
    final open = View.of(context).viewInsets.bottom > 0;
    onChanged();
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return IgnorePointer(
      key: const ValueKey('gesture-dock-keyboard-gate'),
      ignoring: open,
      child: AnimatedOpacity(
        opacity: open ? 0 : 1,
        duration: reduced ? Duration.zero : const Duration(milliseconds: 140),
        child: child,
      ),
    );
  }
}

/// Glass bar: the blur is clipped to the bar's own 60 dp rounded rect so
/// the compositor only samples that area; opaque when asked to or when the
/// system asks for high contrast.
class _GlassSurface extends StatelessWidget {
  final bool opaque;
  final Widget child;

  const _GlassSurface({required this.opaque, required this.child});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final radius = BorderRadius.circular(gestureDockHeight / 2);
    final border = Border.all(color: colors.divider.withValues(alpha: .7));
    final body = DecoratedBox(
      key: ValueKey(opaque ? 'gesture-dock-opaque' : 'gesture-dock-glass'),
      decoration: BoxDecoration(
        color: opaque ? colors.surface : colors.surface.withValues(alpha: .58),
        borderRadius: radius,
        border: border,
      ),
      child: child,
    );
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
      child: ClipRRect(
        borderRadius: radius,
        child: opaque
            ? body
            : BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: body,
              ),
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
  final double bottom;
  final List<DockShortcut> shortcuts;
  final ValueChanged<DockShortcut> onSelected;

  const _ShortcutPopover({
    required this.tab,
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
    final center =
        gestureDockSideMargin +
        6 +
        barWidth / GestureDockTab.values.length * (tab.index + .5);
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

/// Dims the screen during the guided tour; the dock stays above it.
class _TourScrim extends StatelessWidget {
  final GestureDockController controller;

  const _TourScrim({required this.controller});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int?>(
    valueListenable: controller.tourStep,
    builder: (context, step, _) => step == null
        ? const SizedBox.shrink()
        : const Positioned.fill(
            child: ModalBarrier(
              key: ValueKey('gesture-dock-tour-scrim'),
              color: Color(0x8C000000),
              dismissible: false,
            ),
          ),
  );
}

/// Welcome, tour step, tip, the one-time hide hint and the practice finger.
class _CoachLayer extends StatelessWidget {
  final GestureDockController controller;
  final double bottom;
  final double lineBottom;

  const _CoachLayer({
    required this.controller,
    required this.bottom,
    required this.lineBottom,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller.welcome,
        controller.tourStep,
        controller.tourCelebrating,
        controller.tip,
        controller.hint,
        controller.practice,
        controller.hidden,
      ]),
      builder: (context, _) {
        final strings = Strings.of(context);
        final step = controller.tourStep.value;
        final tip = controller.tip.value;
        final practice = controller.practice.value;
        final demo = step != null && !controller.tourCelebrating.value
            ? dockTourSteps[step]
            : practice;
        Widget? card;
        if (step != null) {
          final gesture = dockTourSteps[step];
          final celebrating = controller.tourCelebrating.value;
          card = _CoachCard(
            key: const ValueKey('gesture-dock-tour-card'),
            tag: strings.gdTourStep(step + 1, dockTourSteps.length),
            title: celebrating
                ? strings.gdTourGood
                : _tourTitle(strings, gesture),
            body: celebrating ? null : _tourBody(strings, gesture),
            trailing: TextButton(
              key: const ValueKey('gesture-dock-tour-skip'),
              onPressed: controller.skipTour,
              child: Text(strings.gdTourSkip),
            ),
          );
        } else if (controller.welcome.value) {
          card = _CoachCard(
            key: const ValueKey('gesture-dock-welcome'),
            tag: strings.gdWelcomeTag,
            title: strings.gdWelcomeTitle,
            body: strings.gdWelcomeBody,
            actions: [
              FilledButton(
                key: const ValueKey('gesture-dock-welcome-teach'),
                onPressed: () => controller.answerWelcome(teach: true),
                child: Text(strings.gdWelcomeTeach),
              ),
              TextButton(
                key: const ValueKey('gesture-dock-welcome-later'),
                onPressed: () => controller.answerWelcome(teach: false),
                child: Text(strings.gdWelcomeLater),
              ),
            ],
          );
        } else if (tip != null) {
          card = _CoachCard(
            key: const ValueKey('gesture-dock-tip'),
            tag: strings.gdTipTag,
            title: gestureTipTitle(strings, tip),
            body: gestureTipBody(strings, tip),
            actions: [
              FilledButton(
                key: const ValueKey('gesture-dock-tip-try'),
                onPressed: () => controller.tryGesture(tip),
                child: Text(strings.gdTipTry),
              ),
              TextButton(
                key: const ValueKey('gesture-dock-tip-known'),
                onPressed: controller.tipKnown,
                child: Text(strings.gdTipKnown),
              ),
              TextButton(
                key: const ValueKey('gesture-dock-tip-notnow'),
                onPressed: controller.tipNotNow,
                child: Text(strings.gdTipNotNow),
              ),
            ],
          );
        } else if (controller.hint.value) {
          card = _CoachCard(
            key: const ValueKey('gesture-dock-hint'),
            title: strings.gdHiddenHint,
            compact: true,
          );
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            if (demo != null)
              _FingerDemo(
                key: ValueKey('gesture-dock-finger-${demo.name}'),
                gesture: demo,
                lineBottom: lineBottom,
              ),
            if (card != null)
              Positioned(
                left: gestureDockSideMargin,
                right: gestureDockSideMargin,
                bottom: controller.hidden.value ? lineBottom + 48 : bottom,
                child: card,
              ),
          ],
        );
      },
    );
  }
}

String _tourTitle(Strings s, DockGesture g) => switch (g) {
  DockGesture.swipe => s.gdTourSwipeTitle,
  DockGesture.hide => s.gdTourHideTitle,
  _ => s.gdTourShowTitle,
};

String _tourBody(Strings s, DockGesture g) => switch (g) {
  DockGesture.swipe => s.gdTourSwipeBody,
  DockGesture.hide => s.gdTourHideBody,
  _ => s.gdTourShowBody,
};

String gestureTipTitle(Strings s, DockGesture g) => switch (g) {
  DockGesture.swipe => s.gdTipSwipeTitle,
  DockGesture.hide => s.gdTipHideTitle,
  DockGesture.up => s.gdTipUpTitle,
  _ => s.gdTipHoldTitle,
};

String gestureTipBody(Strings s, DockGesture g) => switch (g) {
  DockGesture.swipe => s.gdTipSwipeBody,
  DockGesture.hide => s.gdTipHideBody,
  DockGesture.up => s.gdTipUpBody,
  _ => s.gdTipHoldBody,
};

class _CoachCard extends StatelessWidget {
  final String? tag;
  final String title;
  final String? body;
  final List<Widget> actions;
  final Widget? trailing;
  final bool compact;

  const _CoachCard({
    required this.title,
    this.tag,
    this.body,
    this.actions = const [],
    this.trailing,
    this.compact = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Material(
        color: colors.surface,
        elevation: 10,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, compact ? 12 : 14, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (tag != null || trailing != null)
                Row(
                  children: [
                    if (tag != null)
                      Expanded(
                        child: Text(
                          tag!,
                          style: TextStyle(
                            color: colors.accent,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ?trailing,
                  ],
                ),
              Text(
                title,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: compact ? 14 : 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (body != null) ...[
                const SizedBox(height: 4),
                Text(body!, style: TextStyle(color: colors.textSecondary)),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 4, children: actions),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A fingertip showing the gesture on the dock. Mounted only while the
/// tour or a practice needs it; still (no loop) with reduced motion.
class _FingerDemo extends StatefulWidget {
  final DockGesture gesture;
  final double lineBottom;

  const _FingerDemo({
    required this.gesture,
    required this.lineBottom,
    super.key,
  });

  @override
  State<_FingerDemo> createState() => _FingerDemoState();
}

class _FingerDemoState extends State<_FingerDemo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduced) {
      _loop.stop();
      _loop.value = .5;
    } else if (!_loop.isAnimating) {
      unawaited(_loop.repeat());
    }
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.viewPaddingOf(context);
    final dockCenterY =
        size.height -
        padding.bottom -
        gestureDockBottomGap -
        gestureDockHeight / 2;
    final cx = size.width / 2;
    final (Offset a, Offset b) = switch (widget.gesture) {
      DockGesture.swipe => (
        Offset(cx + 62, dockCenterY),
        Offset(cx - 62, dockCenterY),
      ),
      DockGesture.hide => (
        Offset(cx, dockCenterY - 8),
        Offset(cx, dockCenterY + 54),
      ),
      DockGesture.up => (
        Offset(cx, dockCenterY + 10),
        Offset(cx, dockCenterY - 80),
      ),
      DockGesture.show => (
        Offset(cx, size.height - widget.lineBottom - 17),
        Offset(cx, size.height - widget.lineBottom - 17),
      ),
      _ => (Offset(cx, dockCenterY), Offset(cx, dockCenterY)),
    };
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _loop,
        builder: (context, _) {
          final v = _loop.value;
          final travel = ((v - .28) / .42).clamp(0.0, 1.0);
          final opacity = v < .15
              ? v / .15
              : (v > .7
                    ? (1 - (v - .7) / .12).clamp(0.0, 1.0).toDouble()
                    : 1.0);
          final p = Offset.lerp(a, b, Curves.easeInOut.transform(travel))!;
          return Stack(
            children: [
              Positioned(
                left: p.dx - 18,
                top: p.dy - 18,
                child: Opacity(
                  opacity: opacity,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: .35),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: .8),
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
