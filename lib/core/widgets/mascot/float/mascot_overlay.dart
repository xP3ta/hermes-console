import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../config/feature_flags.dart';
import '../../../shell/dock_geometry.dart';
import '../../../shell/gesture_dock_state.dart';
import '../../../theme/app_theme.dart';
import '../mascot_identity.dart';
import '../mascot_sprite.dart';
import '../mascot_state.dart';
import 'mascot_float_physics.dart';
import 'mascot_prefs.dart';
import 'mascot_route_watch.dart';
import 'mascot_sources.dart';

/// Test hook: position updates of every floating mascot (one per motion
/// frame or drag move).
@visibleForTesting
int debugMascotOverlayFrames = 0;

/// Test hook: timers the floating mascot holds right now (motion, wander,
/// sleep, scroll fade, bubble auto-close).
@visibleForTesting
int get debugMascotOverlayTimers => _MascotOverlayState._timers;

/// Test hook: the random source of the wander decisions.
@visibleForTesting
math.Random Function() debugMascotOverlayRandom = math.Random.new;

/// Mounts the floating mascot above [child] (the root navigator), behind
/// [FeatureFlags.floatingMascot]. With the flag off it returns [child]
/// itself: nothing is mounted, listened to or scheduled.
class MascotOverlayHost extends StatefulWidget {
  const MascotOverlayHost({
    required this.child,
    this.prefs,
    this.sources,
    this.actions = const MascotOverlayActions(),
    this.geometry,
    this.routeWatch,
    this.locked,
    super.key,
  });

  final Widget child;
  final MascotPrefs? prefs;
  final MascotSources? sources;
  final MascotOverlayActions actions;
  final DockGeometry? geometry;
  final MascotRouteWatch? routeWatch;
  final ValueListenable<bool>? locked;

  @override
  State<MascotOverlayHost> createState() => _MascotOverlayHostState();
}

class _MascotOverlayHostState extends State<MascotOverlayHost> {
  final ValueNotifier<int> _scrolls = ValueNotifier<int>(0);

  MascotPrefs get _prefs => widget.prefs ?? MascotPrefs.instance;

  @override
  void initState() {
    super.initState();
    if (FeatureFlags.floatingMascot) unawaited(_prefs.ensureLoaded());
  }

  @override
  void dispose() {
    _scrolls.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!FeatureFlags.floatingMascot) return widget.child;
    return Stack(
      fit: StackFit.expand,
      children: [
        NotificationListener<ScrollUpdateNotification>(
          onNotification: (_) {
            _scrolls.value++;
            return false;
          },
          child: widget.child,
        ),
        ListenableBuilder(
          listenable: _prefs,
          builder: (context, _) => _prefs.loaded && _prefs.enabled
              ? MascotOverlay(
                  prefs: _prefs,
                  sources: widget.sources ?? MascotSources.instance,
                  actions: widget.actions,
                  geometry: widget.geometry ?? DockGeometry.instance,
                  modalOnTop: (widget.routeWatch ?? MascotRouteWatch.instance)
                      .modalOnTop,
                  locked: widget.locked ?? MascotSprite.appLocked,
                  scrolls: _scrolls,
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

enum _Bubble { none, permission, suggestion, menu, info, welcome }

enum _Motion { none, walk, fall, glide, hop }

/// The floating mascot itself (see the owner's guide, section 3). Mounted by
/// [MascotOverlayHost]; public for tests.
class MascotOverlay extends StatefulWidget {
  const MascotOverlay({
    required this.prefs,
    required this.sources,
    required this.actions,
    required this.geometry,
    required this.modalOnTop,
    required this.scrolls,
    this.locked,
    this.random,
    super.key,
  });

  final MascotPrefs prefs;
  final MascotSources sources;
  final MascotOverlayActions actions;
  final DockGeometry geometry;
  final ValueListenable<bool> modalOnTop;
  final ValueListenable<int> scrolls;
  final ValueListenable<bool>? locked;
  final math.Random? random;

  @override
  State<MascotOverlay> createState() => _MascotOverlayState();
}

class _MascotOverlayState extends State<MascotOverlay>
    with WidgetsBindingObserver {
  static int _timers = 0;
  static const double _size = MascotFloatPhysics.spriteSize;

  /// Top-left of the sprite box, in the overlay's (= global) coordinates.
  final ValueNotifier<Offset> _pos = ValueNotifier<Offset>(Offset.zero);

  /// Extra lift of a hop (px, up).
  final ValueNotifier<double> _hopLift = ValueNotifier<double>(0);

  late final math.Random _random = widget.random ?? debugMascotOverlayRandom();
  Size _screen = Size.zero;
  EdgeInsets _padding = EdgeInsets.zero;
  bool _placed = false;

  // Motion (one ~30 fps timer, only while something moves).
  Timer? _motionTimer;
  _Motion _motion = _Motion.none;
  double _t = 0; // seconds into the current motion
  double _duration = 0;
  Offset _from = Offset.zero;
  Offset _to = Offset.zero;
  MascotFall? _fall;
  VoidCallback? _onMotionEnd;

  Timer? _wanderTimer;
  Timer? _sleepTimer;
  bool _asleep = false;

  Timer? _scrollTimer;
  bool _scrolling = false;

  Timer? _bubbleTimer;
  _Bubble _bubble = _Bubble.none;
  String? _info;

  // Drag.
  Offset? _downAt;
  Offset _grab = Offset.zero;
  bool _dragging = false;

  bool _reduced = false;
  bool _active = false; // visible and allowed to move

  MascotPlacement get _placement => widget.prefs.placement;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The gesture dock's first-run welcome speaks through the mascot.
    GestureDockController.welcomePresenter = _presentWelcome;
    for (final l in _listenables) {
      l.addListener(_onSignal);
    }
    widget.geometry.rect.addListener(_onGeometry);
    widget.geometry.hidden.addListener(_onGeometry);
    widget.scrolls.addListener(_onScroll);
    widget.sources.permissions.addListener(_onPermissions);
  }

  List<Listenable> get _listenables => [
    widget.modalOnTop,
    MascotSprite.visibleHeaders,
    widget.sources.activity,
    widget.sources.suggestions,
    if (widget.locked != null) widget.locked!,
  ];

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (identical(GestureDockController.welcomePresenter, _presentWelcome)) {
      GestureDockController.welcomePresenter = null;
    }
    for (final l in _listenables) {
      l.removeListener(_onSignal);
    }
    widget.geometry.rect.removeListener(_onGeometry);
    widget.geometry.hidden.removeListener(_onGeometry);
    widget.scrolls.removeListener(_onScroll);
    widget.sources.permissions.removeListener(_onPermissions);
    _stopMotion();
    _cancel(_wanderTimer);
    _wanderTimer = null;
    _cancel(_sleepTimer);
    _sleepTimer = null;
    _cancel(_scrollTimer);
    _scrollTimer = null;
    _cancel(_bubbleTimer);
    _bubbleTimer = null;
    _pos.dispose();
    _hopLift.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Timers (counted so tests can prove nothing is left running).

  Timer _timer(Duration d, VoidCallback f) {
    _timers++;
    late final Timer t;
    t = Timer(d, () {
      _timers--;
      f();
    });
    return t;
  }

  void _cancel(Timer? t) {
    if (t != null && t.isActive) {
      t.cancel();
      _timers--;
    }
  }

  // ---------------------------------------------------------------------
  // Visibility and motion gate.

  bool get _visible =>
      !(widget.locked?.value ?? false) &&
      !widget.modalOnTop.value &&
      MascotSprite.visibleHeaders.value == 0 &&
      _keyboard == 0;

  double _keyboard = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _sync();

  void _onSignal() {
    if (!mounted) return;
    setState(() {});
    _sync();
  }

  void _sync() {
    if (!mounted) return;
    _reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final foreground =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    final active =
        _visible &&
        foreground &&
        TickerMode.valuesOf(context).enabled &&
        !_reduced;
    _active = active;
    if (!active) {
      // Frozen: finish any motion at its destination, hold no timer.
      if (_motion != _Motion.none) _finishMotion();
      _cancel(_wanderTimer);
      _wanderTimer = null;
      _cancel(_sleepTimer);
      _sleepTimer = null;
      return;
    }
    _armWander();
  }

  // ---------------------------------------------------------------------
  // Placement.

  double get _baseline => MascotFloatPhysics.baseline(
    dock: widget.geometry.rect.value,
    screen: _screen,
    bottomInset: _padding.bottom,
  );

  Offset get _restOnDock => Offset(_pos.value.dx, _baseline - _size);

  void _place(Size screen, EdgeInsets padding) {
    final first = !_placed;
    _screen = screen;
    _padding = padding;
    _placed = true;
    if (!first) return;
    final stored = widget.prefs.position;
    if (_placement == MascotPlacement.float && stored != null) {
      _pos.value = Offset(
        MascotFloatPhysics.snapLeft(
          stored.dx * screen.width,
          _size,
          screen.width,
        ),
        MascotFloatPhysics.clampTop(
          stored.dy * screen.height,
          _size,
          screen,
          padding.top,
        ),
      );
    } else {
      _pos.value = Offset(screen.width - _size - 24, _baseline - _size);
    }
  }

  void _onGeometry() {
    if (!mounted || !_placed || _dragging) return;
    final box = _pos.value & const Size(_size, _size);
    if (_placement == MascotPlacement.dock) {
      // Rests on the dock, or drops onto the line when it hides.
      _glideTo(_restOnDock);
    } else {
      final top = MascotFloatPhysics.avoidTop(box, widget.geometry.rect.value);
      if (top != null) _glideTo(Offset(box.left, top));
    }
  }

  // ---------------------------------------------------------------------
  // Motion.

  void _startMotion(
    _Motion kind,
    double seconds, {
    Offset? to,
    VoidCallback? onEnd,
  }) {
    _stopMotion();
    _motion = kind;
    _t = 0;
    _duration = seconds;
    _from = _pos.value;
    _to = to ?? _pos.value;
    _onMotionEnd = onEnd;
    if (!_active) {
      _finishMotion();
      return;
    }
    _motionTimer = _timer(MascotFloatPhysics.frame, _tick);
  }

  void _stopMotion() {
    _cancel(_motionTimer);
    _motionTimer = null;
  }

  void _finishMotion() {
    _stopMotion();
    final kind = _motion;
    _motion = _Motion.none;
    _hopLift.value = 0;
    if (kind == _Motion.fall) {
      _setPos(Offset(_pos.value.dx, _fall!.floorTop));
    } else if (kind != _Motion.hop) {
      _setPos(_to);
    }
    final end = _onMotionEnd;
    _onMotionEnd = null;
    // Called from didChangeDependencies too (a freeze mid-motion): only
    // mark dirty outside a build.
    if (mounted &&
        SchedulerBinding.instance.schedulerPhase !=
            SchedulerPhase.persistentCallbacks) {
      setState(() {});
    }
    end?.call();
  }

  void _setPos(Offset value) {
    if (_pos.value == value) return;
    debugMascotOverlayFrames++;
    _pos.value = value;
  }

  void _tick() {
    _motionTimer = null;
    if (!mounted) return;
    _t += MascotFloatPhysics.frame.inMicroseconds / 1e6;
    if (_t >= _duration) {
      _finishMotion();
      return;
    }
    final k = (_t / _duration).clamp(0.0, 1.0);
    switch (_motion) {
      case _Motion.walk:
        _setPos(Offset.lerp(_from, _to, k)!);
      case _Motion.glide:
        _setPos(
          Offset.lerp(_from, _to, MascotFloatPhysics.avoidCurve.transform(k))!,
        );
      case _Motion.fall:
        _setPos(Offset(_pos.value.dx, _fall!.topAt(_t)));
      case _Motion.hop:
        debugMascotOverlayFrames++;
        _hopLift.value = math.sin(k * math.pi) * 12;
      case _Motion.none:
        return;
    }
    _motionTimer = _timer(MascotFloatPhysics.frame, _tick);
  }

  void _glideTo(Offset target, {VoidCallback? onEnd}) => _startMotion(
    _Motion.glide,
    MascotFloatPhysics.avoidDuration.inMicroseconds / 1e6,
    to: target,
    onEnd: onEnd,
  );

  void _fallToDock() {
    final floor = _baseline - _size;
    final start = math.min(_pos.value.dy, floor);
    _pos.value = Offset(_pos.value.dx, start);
    _fall = MascotFall(startTop: start, floorTop: floor);
    _startMotion(
      _Motion.fall,
      _fall!.duration,
      to: Offset(_pos.value.dx, floor),
      onEnd: () => unawaited(widget.prefs.setPlacement(MascotPlacement.dock)),
    );
  }

  void _hop() {
    if (!_active) return;
    _startMotion(_Motion.hop, 0.3);
  }

  // ---------------------------------------------------------------------
  // Wander and sleep (dock placement only).

  bool get _busy => switch (widget.sources.activity.value) {
    MascotState.thinking || MascotState.tool => true,
    _ => false,
  };

  bool get _canSleep => !_busy && widget.sources.permissions.value.isEmpty;

  void _touch() {
    _asleep = false;
    _cancel(_sleepTimer);
    _sleepTimer = null;
    if (mounted) _sync();
  }

  void _armWander() {
    if (!_active || _placement != MascotPlacement.dock || _dragging) return;
    if (_sleepTimer == null && !_asleep) {
      _sleepTimer = _timer(MascotFloatPhysics.sleepAfter, () {
        _sleepTimer = null;
        if (_canSleep) {
          _asleep = true;
          _cancel(_wanderTimer);
          _wanderTimer = null;
        } else {
          _armWander();
        }
      });
    }
    if (_asleep || _wanderTimer != null) return;
    const min = MascotFloatPhysics.minDecision;
    final span = MascotFloatPhysics.maxDecision - min;
    _wanderTimer = _timer(min + span * _random.nextDouble(), () {
      _wanderTimer = null;
      _decide();
      _armWander();
    });
  }

  void _decide() {
    if (!_active || _motion != _Motion.none || !_placed) return;
    if (_placement != MascotPlacement.dock || _bubble != _Bubble.none) return;
    // 20 % look around / blink: the sprite already blinks on its own.
    if (_random.nextDouble() < 0.2) return;
    final offset =
        (_random.nextDouble() * 2 - 1) * MascotFloatPhysics.maxWander;
    final dock = widget.geometry.rect.value;
    final minLeft = math.max(
      MascotFloatPhysics.edgeMargin,
      dock == null || widget.geometry.hidden.value ? 0.0 : dock.left,
    );
    final maxLeft = math.min(
      _screen.width - _size - MascotFloatPhysics.edgeMargin,
      dock == null || widget.geometry.hidden.value
          ? double.infinity
          : dock.right - _size,
    );
    final left = MascotFloatPhysics.wanderLeft(
      from: _pos.value.dx,
      offset: offset,
      width: _size,
      minLeft: minLeft,
      maxLeft: maxLeft,
    );
    final distance = left - _pos.value.dx;
    if (distance.abs() < 4) return;
    _startMotion(
      _Motion.walk,
      MascotFloatPhysics.walkSeconds(distance, busy: _busy),
      to: Offset(left, _baseline - _size),
    );
  }

  // ---------------------------------------------------------------------
  // Scroll fade.

  void _onScroll() {
    if (!mounted) return;
    _cancel(_scrollTimer);
    _scrollTimer = _timer(MascotFloatPhysics.scrollQuiet, () {
      _scrollTimer = null;
      if (mounted) setState(() => _scrolling = false);
    });
    if (!_scrolling) setState(() => _scrolling = true);
  }

  // ---------------------------------------------------------------------
  // Permissions, suggestions and the menu.

  int _lastPermissionCount = 0;

  void _onPermissions() {
    if (!mounted) return;
    final count = widget.sources.permissions.value.length;
    if (count > _lastPermissionCount) {
      _touch();
      _hop();
    }
    if (count == 0 && _bubble == _Bubble.permission) _closeBubble();
    _lastPermissionCount = count;
    setState(() {});
  }

  GestureDockController? _welcomeFrom;

  /// [GestureDockController.welcomePresenter]: shows the welcome in the
  /// mascot's bubble when the mascot is on screen; otherwise the dock
  /// shows its own card.
  late final bool Function(GestureDockController) _presentWelcome =
      (controller) {
        if (!mounted || !_visible || _dragging) return false;
        _welcomeFrom = controller;
        _openBubble(_Bubble.welcome);
        return true;
      };

  void _answerWelcome({required bool teach, bool noMascot = false}) {
    final controller = _welcomeFrom;
    _welcomeFrom = null;
    _closeBubble();
    controller?.answerWelcome(teach: teach);
    if (noMascot) unawaited(widget.prefs.setEnabled(false));
  }

  void _dismissBubble() {
    if (_bubble == _Bubble.welcome) {
      _answerWelcome(teach: false);
    } else {
      _closeBubble();
    }
  }

  void _openBubble(_Bubble kind, {String? info, Duration? autoClose}) {
    _cancel(_bubbleTimer);
    _bubbleTimer = null;
    setState(() {
      _bubble = kind;
      _info = info;
    });
    if (autoClose != null) {
      _bubbleTimer = _timer(autoClose, () {
        _bubbleTimer = null;
        _closeBubble();
      });
    }
  }

  void _closeBubble() {
    _cancel(_bubbleTimer);
    _bubbleTimer = null;
    if (mounted && _bubble != _Bubble.none) {
      setState(() {
        _bubble = _Bubble.none;
        _info = null;
      });
    }
  }

  void _onTap() {
    _touch();
    if (_bubble != _Bubble.none) {
      _dismissBubble();
      return;
    }
    final permissions = widget.sources.permissions.value;
    if (permissions.isNotEmpty) {
      // The Inicio card already shows it: hop and count, no second bubble.
      if (widget.sources.needsCardVisible.value) {
        _hop();
      } else {
        _openBubble(_Bubble.permission);
      }
      return;
    }
    if (widget.sources.suggestions.value.isNotEmpty) {
      _openBubble(_Bubble.suggestion, autoClose: const Duration(seconds: 9));
      return;
    }
    _openBubble(_Bubble.menu);
  }

  // ---------------------------------------------------------------------
  // Drag (7 px threshold), drop, snap and fall.

  void _onDown(PointerDownEvent e) {
    _downAt = e.position;
    _grab = e.position - _pos.value;
    _dragging = false;
  }

  void _onMove(PointerMoveEvent e) {
    final start = _downAt;
    if (start == null) return;
    if (!_dragging && pastDragThreshold(e.position - start)) {
      _dragging = true;
      _stopMotion();
      _motion = _Motion.none;
      _cancel(_wanderTimer);
      _wanderTimer = null;
      _closeBubble();
      setState(() {});
    }
    if (_dragging) _setPos(e.position - _grab);
  }

  void _onUp(PointerUpEvent e) {
    final dragged = _dragging;
    _downAt = null;
    _dragging = false;
    if (!dragged) {
      _onTap();
      return;
    }
    _touch();
    final box = _pos.value & const Size(_size, _size);
    if (MascotFloatPhysics.landsOnDock(box, widget.geometry.rect.value)) {
      _fallToDock();
      return;
    }
    final target = Offset(
      MascotFloatPhysics.snapLeft(box.left, _size, _screen.width),
      MascotFloatPhysics.clampTop(box.top, _size, _screen, _padding.top),
    );
    unawaited(widget.prefs.setPlacement(MascotPlacement.float));
    unawaited(
      widget.prefs.setPosition(
        Offset(target.dx / _screen.width, target.dy / _screen.height),
      ),
    );
    _glideTo(target);
    setState(() {});
  }

  void _onCancel(PointerCancelEvent e) {
    _downAt = null;
    _dragging = false;
  }

  void _toggleFloat() {
    _closeBubble();
    if (_placement == MascotPlacement.dock) {
      final target = Offset(_pos.value.dx, _pos.value.dy - _size * 2);
      unawaited(widget.prefs.setPlacement(MascotPlacement.float));
      unawaited(
        widget.prefs.setPosition(
          Offset(target.dx / _screen.width, target.dy / _screen.height),
        ),
      );
      _glideTo(target);
    } else {
      _fallToDock();
    }
    setState(() {});
  }

  // ---------------------------------------------------------------------

  MascotState get _spriteState {
    if (widget.sources.permissions.value.isNotEmpty) {
      return MascotState.needsYou;
    }
    if (_motion == _Motion.walk) return MascotState.tool;
    return widget.sources.activity.value;
  }

  MascotIdentity get _identity {
    final sprite = widget.prefs.sprite;
    return sprite == null
        ? MascotIdentity.hermes
        : MascotIdentity(sprite: sprite, color: MascotIdentity.hermes.color);
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final count = widget.sources.permissions.value.length;
    return LayoutBuilder(
      builder: (context, constraints) {
        _place(constraints.biggest, MediaQuery.viewPaddingOf(context));
        if (!_visible) return const SizedBox.shrink();
        final mascot = Semantics(
          button: true,
          label: count > 0
              ? '${strings.mascotOverlayLabel('Hermes')}. '
                    '${strings.mascotPendingCount(count)}'
              : strings.mascotOverlayLabel('Hermes'),
          excludeSemantics: true,
          onTap: _onTap,
          child: Listener(
            key: const ValueKey('mascot-overlay-sprite'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onDown,
            onPointerMove: _onMove,
            onPointerUp: _onUp,
            onPointerCancel: _onCancel,
            child: SizedBox.square(
              dimension: _size,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  ValueListenableBuilder<double>(
                    valueListenable: _hopLift,
                    builder: (context, lift, child) => Transform.translate(
                      offset: Offset(0, -lift),
                      child: child,
                    ),
                    child: MascotSprite(
                      state: _spriteState,
                      identity: _identity,
                      size: _size,
                      locked: widget.locked,
                      excludeSemantics: true,
                    ),
                  ),
                  if (count > 0)
                    Positioned(
                      right: -2,
                      top: -2,
                      child: _Badge(count: count, color: colors.warning),
                    ),
                ],
              ),
            ),
          ),
        );
        return Stack(
          clipBehavior: Clip.none,
          children: [
            if (_bubble != _Bubble.none)
              Positioned.fill(
                child: GestureDetector(
                  key: const ValueKey('mascot-overlay-barrier'),
                  behavior: HitTestBehavior.translucent,
                  onTap: _dismissBubble,
                ),
              ),
            ValueListenableBuilder<Offset>(
              valueListenable: _pos,
              builder: (context, pos, child) =>
                  Positioned(left: pos.dx, top: pos.dy, child: child!),
              child: IgnorePointer(
                ignoring: _scrolling,
                child: Opacity(
                  key: const ValueKey('mascot-overlay-opacity'),
                  opacity: _scrolling ? MascotFloatPhysics.scrollOpacity : 1,
                  child: mascot,
                ),
              ),
            ),
            if (_bubble != _Bubble.none) _bubbleWidget(context, strings),
          ],
        );
      },
    );
  }

  Widget _bubbleWidget(BuildContext context, Strings strings) {
    final colors = Theme.of(context).hermes;
    final width = math.min(300.0, _screen.width - 24);
    final pos = _pos.value;
    final left = (pos.dx + _size / 2 - width / 2)
        .clamp(12.0, math.max(12.0, _screen.width - width - 12))
        .toDouble();
    final above = pos.dy > _screen.height / 2;
    final content = switch (_bubble) {
      _Bubble.permission => _permissionBubble(strings, colors),
      _Bubble.suggestion => _suggestionBubble(strings, colors),
      _Bubble.menu => _menuBubble(strings, colors),
      _Bubble.info => Text(
        _info ?? '',
        style: TextStyle(color: colors.textPrimary, fontSize: 14),
      ),
      _Bubble.welcome => _welcomeBubble(strings, colors),
      _Bubble.none => const SizedBox.shrink(),
    };
    return Positioned(
      left: left,
      width: width,
      top: above ? null : pos.dy + _size + 8,
      bottom: above ? _screen.height - pos.dy + 8 : null,
      child: Material(
        key: const ValueKey('mascot-overlay-bubble'),
        color: colors.surface,
        elevation: 6,
        borderRadius: BorderRadius.circular(18),
        child: Padding(padding: const EdgeInsets.all(14), child: content),
      ),
    );
  }

  Widget _permissionBubble(Strings strings, HermesThemeColors colors) {
    final item = widget.sources.permissions.value.first;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.title,
          style: TextStyle(
            color: colors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (item.command != null) ...[
          const SizedBox(height: 8),
          Text(
            item.command!,
            style: TextStyle(
              color: colors.textPrimary,
              fontFamily: 'JetBrainsMono',
              fontSize: 13,
            ),
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            TextButton(
              onPressed: () => _answer(item, false),
              child: Text(strings.mascotPermissionDeny),
            ),
            FilledButton(
              onPressed: () => _answer(item, true),
              child: Text(strings.mascotPermissionAllow),
            ),
            if (item.openChat != null)
              TextButton(
                onPressed: () {
                  _closeBubble();
                  item.openChat!();
                },
                child: Text(strings.mascotPermissionOpenChat),
              ),
          ],
        ),
      ],
    );
  }

  Widget _welcomeBubble(Strings strings, HermesThemeColors colors) => Column(
    key: const ValueKey('mascot-overlay-welcome'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        strings.gdWelcomeTitle,
        style: TextStyle(
          color: colors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 6),
      Text(
        strings.gdWelcomeBody,
        style: TextStyle(color: colors.textSecondary),
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          FilledButton(
            onPressed: () => _answerWelcome(teach: true),
            child: Text(strings.gdWelcomeTeach),
          ),
          TextButton(
            onPressed: () => _answerWelcome(teach: false),
            child: Text(strings.gdWelcomeLater),
          ),
          TextButton(
            onPressed: () => _answerWelcome(teach: false, noMascot: true),
            child: Text(strings.mascotWelcomeNoMascot),
          ),
        ],
      ),
    ],
  );

  void _answer(MascotPermission item, bool allow) {
    _closeBubble();
    unawaited(item.resolve(allow).catchError((Object _) {}));
  }

  Widget _suggestionBubble(Strings strings, HermesThemeColors colors) {
    final item = widget.sources.suggestions.value.first;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(item.text, style: TextStyle(color: colors.textPrimary)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            FilledButton(
              onPressed: () {
                _closeBubble();
                item.onAction();
              },
              child: Text(item.actionLabel),
            ),
            TextButton(
              onPressed: () {
                _closeBubble();
                item.onNotNow?.call();
              },
              child: Text(strings.mascotSuggestionNotNow),
            ),
            if (item.onNever != null)
              TextButton(
                onPressed: () {
                  _closeBubble();
                  item.onNever!();
                },
                child: Text(strings.mascotSuggestionNever),
              ),
          ],
        ),
      ],
    );
  }

  Widget _menuBubble(Strings strings, HermesThemeColors colors) {
    Widget item(String key, String label, VoidCallback onTap) => InkWell(
      key: ValueKey('mascot-menu-$key'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(label, style: TextStyle(color: colors.textPrimary)),
          ),
        ),
      ),
    );
    void then(VoidCallback? action) {
      _closeBubble();
      action?.call();
    }

    final actions = widget.actions;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (actions.onTalk != null)
          item('talk', strings.mascotMenuTalk, () => then(actions.onTalk)),
        item(
          'whatsup',
          strings.mascotMenuWhatsUp,
          () => _openBubble(
            _Bubble.info,
            info:
                widget.sources.activitySummary.value ??
                strings.mascotNothingRunning,
            autoClose: const Duration(seconds: 6),
          ),
        ),
        item('suggest', strings.mascotMenuSuggest, () {
          if (widget.sources.suggestions.value.isNotEmpty) {
            _openBubble(
              _Bubble.suggestion,
              autoClose: const Duration(seconds: 9),
            );
          } else {
            _openBubble(
              _Bubble.info,
              info: strings.mascotNoSuggestions,
              autoClose: const Duration(seconds: 6),
            );
          }
        }),
        item(
          'placement',
          _placement == MascotPlacement.dock
              ? strings.mascotMenuFloat
              : strings.mascotMenuDock,
          _toggleFloat,
        ),
        if (actions.onKnowledge != null)
          item(
            'knowledge',
            strings.mascotMenuKnowledge,
            () => then(actions.onKnowledge),
          ),
        if (actions.onSettings != null)
          item(
            'settings',
            strings.mascotMenuSettings,
            () => then(actions.onSettings),
          ),
        item('hide', strings.mascotMenuHide, () {
          _closeBubble();
          unawaited(widget.prefs.setEnabled(false));
        }),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count, required this.color});

  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('mascot-overlay-badge'),
    constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
    padding: const EdgeInsets.symmetric(horizontal: 5),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(9),
    ),
    child: Text(
      '$count',
      style: const TextStyle(
        color: Colors.black,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        height: 1,
      ),
    ),
  );
}
