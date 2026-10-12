import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../design/tokens.dart';
import '../../../shell/dock_geometry.dart';
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

/// Test hook: timers the floating mascot holds right now (settle, hop,
/// sleep, look, scroll fade, bubble auto-close, long press).
@visibleForTesting
int get debugMascotOverlayTimers => _MascotOverlayState._timers;

/// Test hook: the random source of the idle looks.
@visibleForTesting
math.Random Function() debugMascotOverlayRandom = math.Random.new;

/// The pet drawn when the app provides none: Hermes' own sprite, always on.
class MascotEnginePet extends ChangeNotifier implements MascotPet {
  MascotEnginePet();

  @override
  bool get shown => true;

  @override
  String get name => 'Hermes';

  @override
  double get scale => 1;

  @override
  Widget build(
    BuildContext context, {
    required MascotState state,
    required double size,
    required bool asleep,
    required int look,
    bool airborne = false,
  }) => MascotSprite(
    state: state,
    still: asleep,
    identity: MascotIdentity.hermes,
    size: size,
    excludeSemantics: true,
  );

  @override
  Future<void> hide() async {}
}

/// Mounts the floating mascot above [child] (the root navigator).
///
/// While [pet] is not shown (presence "Apagada" or "Solo en el chat") or
/// the host is [suspended] (onboarding, the locked cold start) nothing of
/// it exists: no overlay, no timer, no stored value read.
class MascotOverlayHost extends StatefulWidget {
  const MascotOverlayHost({
    required this.child,
    this.pet,
    this.prefs,
    this.sources,
    this.actions = const MascotOverlayActions(),
    this.geometry,
    this.routeWatch,
    this.locked,
    this.suspended = false,
    super.key,
  });

  final Widget child;
  final MascotPet? pet;
  final MascotPrefs? prefs;
  final MascotSources? sources;
  final MascotOverlayActions actions;
  final DockGeometry? geometry;
  final MascotRouteWatch? routeWatch;
  final ValueListenable<bool>? locked;
  final bool suspended;

  @override
  State<MascotOverlayHost> createState() => _MascotOverlayHostState();
}

class _MascotOverlayHostState extends State<MascotOverlayHost> {
  static final MascotEnginePet _engine = MascotEnginePet();

  final ValueNotifier<int> _scrolls = ValueNotifier<int>(0);
  final GlobalKey _under = GlobalKey(debugLabel: 'mascot-overlay-under');

  MascotPrefs get _prefs => widget.prefs ?? MascotPrefs.instance;
  MascotPet get _pet => widget.pet ?? _engine;
  bool get _on => !widget.suspended && _pet.shown;

  @override
  void initState() {
    super.initState();
    _pet.addListener(_onPet);
    _onPet();
  }

  @override
  void didUpdateWidget(covariant MascotOverlayHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.pet ?? _engine;
    if (!identical(old, _pet)) {
      old.removeListener(_onPet);
      _pet.addListener(_onPet);
    }
    _onPet();
  }

  @override
  void dispose() {
    _pet.removeListener(_onPet);
    _scrolls.dispose();
    super.dispose();
  }

  /// The stored spot is read the first time the mascot is on, never before.
  void _onPet() {
    if (_on) unawaited(_prefs.ensureLoaded());
  }

  /// Whether a fixed control (a top-bar button, a sticky Save) of the page
  /// is under [box]: something tappable and small that does not scroll.
  /// Rows and cards that scroll, and big tappable areas, are not controls
  /// the mascot has to keep off.
  bool _fixedControlAt(Rect box) {
    final render = _under.currentContext?.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      return false;
    }
    // A 3 x 3 grid over the box, so a control under any part of it counts.
    final inner = box.deflate(4);
    for (final dy in const [0.0, 0.5, 1.0]) {
      for (final dx in const [0.0, 0.5, 1.0]) {
        final point = Offset(
          inner.left + inner.width * dx,
          inner.top + inner.height * dy,
        );
        final result = BoxHitTestResult();
        render.hitTest(result, position: render.globalToLocal(point));
        if (hitsFixedControl(result)) return true;
      }
    }
    return false;
  }

  /// A fixed control is at most this tall (or wide): a button or a bar,
  /// not a card.
  static const double _controlExtent = 72;

  @visibleForTesting
  static bool hitsFixedControl(HitTestResult result) {
    var tappable = false;
    // The path runs from the deepest target up to the root.
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderAbstractViewport || target is RenderSliver) {
        // It scrolls with its content.
        if (tappable) return false;
        continue;
      }
      if (!tappable &&
          target is RenderMouseRegion &&
          target.hasSize &&
          target.size.shortestSide <= _controlExtent) {
        tappable = true;
      }
    }
    return tappable;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        NotificationListener<ScrollUpdateNotification>(
          onNotification: (_) {
            if (_on) _scrolls.value++;
            return false;
          },
          child: KeyedSubtree(key: _under, child: widget.child),
        ),
        ListenableBuilder(
          listenable: Listenable.merge([_pet, _prefs]),
          builder: (context, _) => _on && _prefs.loaded
              ? RepaintBoundary(
                  child: MascotOverlay(
                    pet: _pet,
                    prefs: _prefs,
                    sources: widget.sources ?? MascotSources.instance,
                    actions: widget.actions,
                    geometry: widget.geometry ?? DockGeometry.instance,
                    routes: widget.routeWatch ?? MascotRouteWatch.instance,
                    locked: widget.locked ?? MascotSprite.appLocked,
                    scrolls: _scrolls,
                    fixedControlAt: _fixedControlAt,
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// Whether [result] (a hit test of the page under the mascot) found a fixed
/// control. Exposed for tests.
@visibleForTesting
bool debugMascotHitsFixedControl(HitTestResult result) =>
    _MascotOverlayHostState.hitsFixedControl(result);

enum _Bubble { none, menu, permission, notice }

enum _Motion { none, glide, hop }

/// The way back to the dock: a free fall, then (landed beside its place) a
/// slide along the edge; or a spring up when its place is above it.
enum _Return { none, fall, slide, rise }

/// The floating mascot itself. Mounted by [MascotOverlayHost]; public for
/// tests.
class MascotOverlay extends StatefulWidget {
  const MascotOverlay({
    required this.pet,
    required this.prefs,
    required this.sources,
    required this.actions,
    required this.geometry,
    required this.routes,
    required this.scrolls,
    this.locked,
    this.fixedControlAt,
    this.random,
    super.key,
  });

  final MascotPet pet;
  final MascotPrefs prefs;
  final MascotSources sources;
  final MascotOverlayActions actions;
  final DockGeometry geometry;
  final MascotRouteWatch routes;
  final ValueListenable<int> scrolls;
  final ValueListenable<bool>? locked;

  /// True when a fixed control of the page is under that box.
  final bool Function(Rect box)? fixedControlAt;
  final math.Random? random;

  @override
  State<MascotOverlay> createState() => _MascotOverlayState();
}

class _MascotOverlayState extends State<MascotOverlay>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static int _timers = 0;

  /// Top-left of the sprite box, in the overlay's (= global) coordinates.
  final ValueNotifier<Offset> _pos = ValueNotifier<Offset>(Offset.zero);

  /// Extra lift of a hop (px, up).
  final ValueNotifier<double> _hopLift = ValueNotifier<double>(0);

  /// Lean and squash of the sprite while it is held.
  final ValueNotifier<_Pose> _pose = ValueNotifier<_Pose>(_Pose.rest);

  late final math.Random _random = widget.random ?? debugMascotOverlayRandom();
  Size _screen = Size.zero;
  EdgeInsets _padding = EdgeInsets.zero;
  EdgeInsets _gestures = EdgeInsets.zero;
  double _keyboard = 0;
  double _size = MascotFloatPhysics.baseSize;
  bool _placed = false;
  bool _reseatQueued = false;

  // Motion (one ~30 fps timer, only while something moves).
  Timer? _motionTimer;
  _Motion _motion = _Motion.none;
  double _t = 0; // seconds into the current motion
  double _duration = 0;
  Offset _from = Offset.zero;
  Offset _to = Offset.zero;

  // "Volver al dock": its own ticker, running only while it travels.
  late final Ticker _returnTicker = createTicker(_onReturnTick);
  _Return _return = _Return.none;
  Offset _returnFrom = Offset.zero;
  Offset _returnTo = Offset.zero;
  Duration? _returnLast;
  double _returnT = 0; // seconds into the slide or the rise
  double _returnFor = 0; // how long the slide or the rise lasts
  double _fallSpeed = 0; // px/s, down

  /// It was somewhere of the user's choosing (see [MascotPrefs.moved]).
  bool _wasMoved = false;

  /// The next move is the way back to the dock, not a settle.
  bool _backNext = false;

  Timer? _sleepTimer;
  Timer? _lookTimer;
  bool _asleep = false;
  int _look = 0;

  Timer? _scrollTimer;
  bool _scrolling = false;

  Timer? _bubbleTimer;
  _Bubble _bubble = _Bubble.none;
  MascotNotice? _notice;

  /// Notices and permissions the mascot already showed by itself.
  final Set<String> _told = <String>{};

  // Drag.
  Offset? _downAt;
  Offset _grab = Offset.zero;
  bool _dragging = false;
  bool _pressed = false; // the long press already opened the menu
  (Duration, Offset)? _lastMove;
  Timer? _pressTimer;
  Timer? _relaxTimer;

  bool _reduced = false;
  bool _on = false; // on screen, app in front
  bool _active = false; // on screen and allowed to move

  /// Just back on screen: it is put where it rests on this screen, it does
  /// not travel there from where it stood on the last one it was seen on.
  bool _fresh = true;
  MascotState _lastState = MascotState.idle;

  MascotPrefs get _prefs => widget.prefs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    for (final l in _signals) {
      l.addListener(_onSignal);
    }
    widget.geometry.rect.addListener(_onGeometry);
    widget.geometry.hidden.addListener(_onGeometry);
    widget.routes.settled.addListener(_onSettled);
    widget.scrolls.addListener(_onScroll);
    widget.sources.permissions.addListener(_onAttention);
    widget.sources.notices.addListener(_onAttention);
    _prefs.addListener(_onPrefs);
    widget.pet.addListener(_onPrefs);
    _lastState = _state;
    _wasMoved = _prefs.moved;
  }

  List<Listenable> get _signals => [
    widget.routes.covered,
    widget.geometry.menuOpen,
    MascotSprite.visibleHeaders,
    widget.sources.activity,
    if (widget.locked != null) widget.locked!,
  ];

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final l in _signals) {
      l.removeListener(_onSignal);
    }
    widget.geometry.rect.removeListener(_onGeometry);
    widget.geometry.hidden.removeListener(_onGeometry);
    widget.routes.settled.removeListener(_onSettled);
    widget.scrolls.removeListener(_onScroll);
    widget.sources.permissions.removeListener(_onAttention);
    widget.sources.notices.removeListener(_onAttention);
    _prefs.removeListener(_onPrefs);
    widget.pet.removeListener(_onPrefs);
    _stopMotion();
    for (final timer in [
      _sleepTimer,
      _lookTimer,
      _scrollTimer,
      _bubbleTimer,
      _pressTimer,
      _relaxTimer,
    ]) {
      _cancel(timer);
    }
    _returnTicker.dispose();
    _pos.dispose();
    _hopLift.dispose();
    _pose.dispose();
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

  /// Marks it for a rebuild; while a frame is being built, after it.
  void _rebuild() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  // ---------------------------------------------------------------------
  // Visibility and motion gate.

  /// Nothing shows until the navigator has said what its first route is:
  /// a chat opened from a notification never sees the mascot flash.
  bool get _visible =>
      widget.routes.settled.value > 0 &&
      !(widget.locked?.value ?? false) &&
      !widget.routes.covered.value &&
      !widget.geometry.menuOpen.value &&
      MascotSprite.visibleHeaders.value == 0 &&
      _keyboard == 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _sync();

  /// True when a frame is being built or laid out right now. What the
  /// mascot listens to may change at such a moment (a dock closing its menu
  /// as its route is covered, a list correcting its scroll while it lays
  /// out): [retry] then runs after the frame, when it may mark itself.
  bool _midFrame(VoidCallback retry) {
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      return false;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) retry();
    });
    return true;
  }

  void _onSignal() {
    if (!mounted || _midFrame(_onSignal)) return;
    final state = _state;
    if (state != _lastState) {
      _lastState = state;
      _wake();
    }
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
    final wasOn = _on;
    final wasActive = _active;
    _on = _visible && foreground;
    _active = _on && TickerMode.valuesOf(context).enabled && !_reduced;
    if (!_visible) {
      _closeBubble(seen: false);
      _endPress();
    }
    if (_active) {
      _armIdle();
    } else {
      // Frozen: finish any motion at its destination, hold no timer.
      if (_motion != _Motion.none) _finishMotion();
      _endReturn(land: true);
      _cancel(_sleepTimer);
      _sleepTimer = null;
      _cancel(_lookTimer);
      _lookTimer = null;
    }
    if (_active != wasActive) {
      if (_active) _asleep = false;
      _rebuild();
    }
    // Back on screen: it says what the user has not been told.
    if (_on && !wasOn) {
      _fresh = true;
      if (_placed) _reseatLater();
      _tellLater();
    }
  }

  // ---------------------------------------------------------------------
  // Where it stands.

  /// The dock's bar, while it is on this screen and shown. Only a bar that
  /// lies along the bottom is something to stand on: a side rail (wide
  /// windows) is not, and the mascot then keeps its corner.
  Rect? get _bar {
    if (widget.geometry.hidden.value) return null;
    final rect = widget.geometry.rect.value;
    return rect != null && rect.width > rect.height * 2 ? rect : null;
  }

  /// The handle a dock hidden by hand leaves behind.
  Rect? get _handle =>
      widget.geometry.hidden.value ? widget.geometry.rect.value : null;

  bool get _free =>
      _prefs.placement == MascotPlacement.free && _prefs.position != null;

  /// Where a free mascot may rest on this screen.
  Rect get _bounds => MascotFloatPhysics.floatBounds(
    screen: _screen,
    size: _size,
    padding: _padding,
    gestures: _gestures,
    keyboard: _keyboard,
    keepOut: _bar ?? _handle,
  );

  /// The safe area, dock or not (a mascot that lives on the dock may stand
  /// on it).
  Rect get _safe => MascotFloatPhysics.floatBounds(
    screen: _screen,
    size: _size,
    padding: _padding,
    gestures: _gestures,
    keyboard: _keyboard,
  );

  Offset get _home => MascotFloatPhysics.home(
    screen: _screen,
    size: _size,
    padding: _padding,
    gestures: _gestures,
    dock: _bar,
    dockAlong: _prefs.dockAlong,
  );

  bool _blocked(Offset topLeft) {
    final box = topLeft & Size.square(_size);
    final handle = _handle;
    if (handle != null && box.overlaps(handle.inflate(4))) return true;
    return widget.fixedControlAt?.call(box) ?? false;
  }

  /// Where it rests on this screen: its own spot, moved off any fixed
  /// control of the page. The stored spot never changes here.
  Offset _rest({bool probe = true}) {
    final Offset rest;
    final Rect bounds;
    if (_free) {
      bounds = _bounds;
      final stored = _prefs.position!;
      rest = MascotFloatPhysics.clampInto(
        Offset(stored.dx * _screen.width, stored.dy * _screen.height),
        bounds,
      );
    } else {
      bounds = _safe;
      rest = _home;
    }
    // On the dock's edge it is home: that spot is the dock's, whatever the
    // page shows above it. Anywhere else it keeps off the page's controls.
    if (!probe || (!_free && _bar != null)) return rest;
    final candidates = MascotFloatPhysics.avoidCandidates(
      rest: rest,
      screen: _screen,
      size: _size,
      bounds: bounds,
    );
    for (final candidate in candidates) {
      if (!_blocked(candidate)) return candidate;
    }
    return rest;
  }

  void _place(Size screen, EdgeInsets padding, EdgeInsets gestures) {
    final size = MascotFloatPhysics.baseSize * widget.pet.scale;
    final first = !_placed;
    if (!first &&
        screen == _screen &&
        padding == _padding &&
        gestures == _gestures &&
        size == _size) {
      return;
    }
    _screen = screen;
    _padding = padding;
    _gestures = gestures;
    _size = size;
    _placed = true;
    if (first) {
      // The page under it is not laid out yet: stand at the plain spot now
      // and look for fixed controls after this frame.
      _pos.value = _rest(probe: false);
    }
    _reseatLater();
  }

  /// Moves to where it rests now, after the frame (the page has to be laid
  /// out to be looked at). Called from builds and listeners alike.
  void _reseatLater() {
    if (_reseatQueued) return;
    _reseatQueued = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _reseatQueued = false;
      _reseat();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _reseat() {
    if (!mounted || !_placed || _dragging) return;
    final target = _rest();
    final back = _backNext;
    _backNext = false;
    final fresh = _fresh;
    _fresh = false;
    if (_return != _Return.none) {
      // On its way back. Its place is where it was (keep falling), or it
      // moved under it (a rotation, the dock hidden): it is put there.
      if ((target - _returnTo).distance >= 0.5) {
        _endReturn();
        _setPos(target);
      }
      return;
    }
    final current = _motion == _Motion.glide ? _to : _pos.value;
    // Already there (a stored fraction never lands on the exact pixel).
    if ((target - current).distance < 0.5) return;
    if (fresh) {
      _stopMotion();
      _motion = _Motion.none;
      _hopLift.value = 0;
      _setPos(target);
      return;
    }
    if (back) {
      _goBackTo(target);
      return;
    }
    _glideTo(target);
  }

  void _onGeometry() {
    if (!mounted || !_placed) return;
    // While a route is still moving the dock reports where it is passing
    // through: wait until the navigator settles.
    if (widget.routes.inTransition) return;
    _reseatLater();
  }

  void _onSettled() {
    if (!mounted) return;
    _rebuild();
    _sync();
    if (!_placed) return;
    _wake();
    // The dock says where it rests now; then look at the new page.
    widget.geometry.refresh();
    _reseatLater();
  }

  void _onPrefs() {
    if (!mounted || _midFrame(_onPrefs)) return;
    // Sent home ("Volver al dock", here or in Mascotas): it falls there.
    final moved = _prefs.moved;
    if (_wasMoved && !moved && !_dragging) _backNext = true;
    _wasMoved = moved;
    setState(() {});
    if (_placed && !_dragging) _reseatLater();
  }

  // ---------------------------------------------------------------------
  // Motion.

  void _startMotion(_Motion kind, Duration duration, {Offset? to}) {
    _stopMotion();
    _hopLift.value = 0;
    _motion = kind;
    _t = 0;
    _duration = duration.inMicroseconds / 1e6;
    _from = _pos.value;
    _to = to ?? _pos.value;
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
    if (kind == _Motion.glide) _setPos(_to);
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
      case _Motion.glide:
        _setPos(
          Offset.lerp(_from, _to, MascotFloatPhysics.settleCurve.transform(k))!,
        );
      case _Motion.hop:
        debugMascotOverlayFrames++;
        _hopLift.value = math.sin(k * math.pi) * MascotFloatPhysics.hopHeight;
      case _Motion.none:
        return;
    }
    _motionTimer = _timer(MascotFloatPhysics.frame, _tick);
  }

  void _glideTo(Offset target) =>
      _startMotion(_Motion.glide, MascotFloatPhysics.settle, to: target);

  // ---------------------------------------------------------------------
  // The way back to the dock, as Hermes Desktop's pet drops: straight down
  // under gravity from rest, a flush landing, then idle.

  /// In the air: falling or springing up.
  bool get _airborne => _return == _Return.fall || _return == _Return.rise;

  void _goBackTo(Offset target) {
    _stopMotion();
    _motion = _Motion.none;
    _hopLift.value = 0;
    _endReturn();
    if (!_active) {
      // Reduced motion, hidden, in the background: it is simply there.
      _setPos(target);
      return;
    }
    _returnFrom = _pos.value;
    _returnTo = target;
    _returnLast = null;
    _returnT = 0;
    _fallSpeed = 0;
    if (target.dy > _pos.value.dy + 1) {
      _return = _Return.fall;
    } else if (target.dy < _pos.value.dy - 1) {
      _return = _Return.rise;
      _returnFor = MascotFloatPhysics.rise.inMicroseconds / 1e6;
    } else {
      _beginSlide();
    }
    unawaited(_returnTicker.start());
    _rebuild();
  }

  void _beginSlide() {
    _return = _Return.slide;
    _returnFrom = _pos.value;
    _returnT = 0;
    _returnFor = MascotFloatPhysics.slideSeconds(_returnTo.dx - _pos.value.dx);
  }

  void _onReturnTick(Duration elapsed) {
    final last = _returnLast ?? elapsed;
    _returnLast = elapsed;
    final dt = math.min(
      MascotFloatPhysics.fallMaxStep,
      (elapsed - last).inMicroseconds / 1e6,
    );
    switch (_return) {
      case _Return.none:
        return;
      case _Return.fall:
        _fallSpeed += MascotFloatPhysics.fallGravity * dt;
        final y = _pos.value.dy + _fallSpeed * dt;
        if (y < _returnTo.dy) {
          _setPos(Offset(_pos.value.dx, y));
          return;
        }
        // Landed, flush with the edge.
        _setPos(Offset(_pos.value.dx, _returnTo.dy));
        if ((_returnTo.dx - _pos.value.dx).abs() < 0.5) {
          _endReturn(land: true);
        } else {
          _beginSlide();
          _rebuild();
        }
      case _Return.slide:
      case _Return.rise:
        _returnT += dt;
        final k = (_returnT / _returnFor).clamp(0.0, 1.0);
        _setPos(
          Offset.lerp(
            _returnFrom,
            _returnTo,
            Curves.easeOutCubic.transform(k),
          )!,
        );
        if (k >= 1) _endReturn(land: true);
    }
  }

  /// Ends the way back and stops its ticker. [land] puts it at its place;
  /// without it, it stays where it is (a finger caught it).
  void _endReturn({bool land = false}) {
    if (_return == _Return.none) return;
    _return = _Return.none;
    if (_returnTicker.isActive) _returnTicker.stop();
    if (land) _setPos(_returnTo);
    _rebuild();
  }

  void _hop() {
    // Never cuts a settle or a fall short.
    if (_return != _Return.none) return;
    if (!_active || _motion != _Motion.none || _dragging) return;
    _startMotion(_Motion.hop, MascotFloatPhysics.hop);
  }

  // ---------------------------------------------------------------------
  // Awake, looking around, asleep.

  /// What it shows: offline first, then somebody waiting for the user,
  /// then something that failed and he has not seen, then what Hermes is
  /// doing.
  MascotState get _state {
    final activity = widget.sources.activity.value;
    if (activity == MascotState.offline) return activity;
    if (widget.sources.permissions.value.isNotEmpty) {
      return MascotState.needsYou;
    }
    var failed = activity == MascotState.error;
    for (final notice in _notices) {
      if (_seen.contains(notice.key)) continue;
      if (notice.waiting) return MascotState.needsYou;
      if (notice.kind == MascotNoticeKind.failed) failed = true;
    }
    return failed ? MascotState.error : activity;
  }

  /// Something happened: it is awake again.
  void _wake() {
    final was = _asleep;
    _asleep = false;
    _cancel(_sleepTimer);
    _sleepTimer = null;
    if (was) _rebuild();
    if (_active) _armIdle();
  }

  /// While it rests it looks around now and then, and falls asleep after a
  /// while. A busy mascot does neither: its state animates by itself.
  void _armIdle() {
    final resting = _active && !_asleep && !_dragging && !_state.isActive;
    if (!resting) {
      _cancel(_lookTimer);
      _lookTimer = null;
      _cancel(_sleepTimer);
      _sleepTimer = null;
      return;
    }
    _sleepTimer ??= _timer(MascotFloatPhysics.sleepAfter, () {
      _sleepTimer = null;
      if (!mounted) return;
      _cancel(_lookTimer);
      _lookTimer = null;
      if (_bubble != _Bubble.none) {
        _armIdle();
        return;
      }
      setState(() => _asleep = true);
    });
    if (_lookTimer != null) return;
    const min = MascotFloatPhysics.minLook;
    final span = MascotFloatPhysics.maxLook - min;
    _lookTimer = _timer(min + span * _random.nextDouble(), () {
      _lookTimer = null;
      if (!mounted) return;
      if (_bubble == _Bubble.none && _motion == _Motion.none) {
        setState(() => _look++);
      }
      _armIdle();
    });
  }

  // ---------------------------------------------------------------------
  // Scroll fade.

  void _onScroll() {
    if (!mounted || _midFrame(_onScroll)) return;
    _cancel(_scrollTimer);
    _scrollTimer = _timer(MascotFloatPhysics.scrollQuiet, () {
      _scrollTimer = null;
      if (mounted) setState(() => _scrolling = false);
    });
    if (!_scrolling) setState(() => _scrolling = true);
  }

  // ---------------------------------------------------------------------
  // What it tells the user.

  /// Notices the user closed (or acted on): never counted or shown again
  /// while they stay in the source.
  final Set<String> _seen = <String>{};

  List<MascotNotice> get _notices => [
    for (final notice in widget.sources.notices.value)
      if (!notice.isSuggestion || !_prefs.mutedSuggestions.contains(notice.key))
        notice,
  ];

  /// What the badge counts: permissions and unseen things that are not
  /// suggestions.
  int get _count =>
      widget.sources.permissions.value.length +
      _notices.where((n) => !n.isSuggestion && !_seen.contains(n.key)).length;

  MascotNotice? get _nextNotice {
    for (final notice in _notices) {
      if (!notice.isSuggestion && !_seen.contains(notice.key)) return notice;
    }
    return null;
  }

  int _lastCount = 0;

  void _onAttention() {
    if (!mounted || _midFrame(_onAttention)) return;
    final permissions = widget.sources.permissions.value;
    final live = {for (final n in _notices) n.key};
    _seen.removeWhere((key) => !live.contains(key));
    final count = _count;
    if (count > _lastCount) {
      _wake();
      _hop();
    }
    _lastCount = count;
    if (permissions.isEmpty && _bubble == _Bubble.permission) {
      _closeBubble(seen: false);
    }
    final shown = _notice;
    if (_bubble == _Bubble.notice &&
        shown != null &&
        !live.contains(shown.key)) {
      _closeBubble(seen: false);
    }
    final state = _state;
    if (state != _lastState) {
      _lastState = state;
      _wake();
    }
    setState(() {});
  }

  /// Shows by itself, once, the next thing the user has not been told. It
  /// speaks up when it comes back on screen (the app opens, a chat or a
  /// sheet closes), never the moment something arrives: the app's own
  /// banner does that, and the mascot only hops and counts.
  void _tellLater() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tell();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _tell() {
    if (!_visible || _bubble != _Bubble.none || _dragging) return;
    final permissions = widget.sources.permissions.value;
    for (final permission in permissions) {
      if (_told.add('permission:${permission.key}')) {
        // The Inicio card already shows it: no second bubble.
        if (widget.sources.needsCardVisible.value) return;
        _openBubble(
          _Bubble.permission,
          autoClose: const Duration(seconds: 12),
          byItself: true,
        );
        return;
      }
    }
    if (permissions.isNotEmpty) return;
    for (final notice in _notices) {
      if (notice.isSuggestion) {
        if (_state != MascotState.idle || _count > 0) continue;
        if (!_prefs.maySuggest(notice.key, DateTime.now())) continue;
      }
      if (!_told.add(notice.key)) continue;
      if (notice.isSuggestion) {
        unawaited(_prefs.markSuggested(notice.key, DateTime.now()));
      }
      _openBubble(
        _Bubble.notice,
        notice: notice,
        autoClose: const Duration(seconds: 9),
        byItself: true,
      );
      return;
    }
  }

  /// True while the open bubble came by itself: it then takes no touch
  /// away from the page (no barrier) and leaves by itself.
  bool _byItself = false;

  void _openBubble(
    _Bubble kind, {
    MascotNotice? notice,
    Duration? autoClose,
    bool byItself = false,
  }) {
    _cancel(_bubbleTimer);
    _bubbleTimer = null;
    _wake();
    setState(() {
      _bubble = kind;
      _notice = notice;
      _byItself = byItself;
    });
    if (kind == _Bubble.permission) _announcePermission();
    if (autoClose != null) {
      _bubbleTimer = _timer(autoClose, () {
        _bubbleTimer = null;
        // Left unanswered it goes back behind the badge.
        _closeBubble(seen: false);
      });
    }
  }

  /// An approval is read out at once, over whatever the reader was saying.
  void _announcePermission() {
    final permissions = widget.sources.permissions.value;
    if (permissions.isEmpty) return;
    final item = permissions.first;
    final strings = Strings.of(context);
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        [
          strings.mascotStateNeedsYou(item.title),
          if (item.command != null) item.command!,
        ].join('. '),
        Directionality.of(context),
        assertiveness: Assertiveness.assertive,
      ),
    );
  }

  /// Closes the bubble. [seen] marks a notice as read by the user: it is
  /// not counted or shown again, and its source is told.
  void _closeBubble({required bool seen}) {
    _cancel(_bubbleTimer);
    _bubbleTimer = null;
    if (_bubble == _Bubble.none) return;
    final notice = _notice;
    if (seen && _bubble == _Bubble.notice && notice != null) {
      _seen.add(notice.key);
      notice.onSeen?.call();
    }
    _bubble = _Bubble.none;
    _notice = null;
    _byItself = false;
    _lastCount = _count;
    _rebuild();
    if (mounted) _armIdle();
  }

  void _onTap() {
    _wake();
    if (_bubble != _Bubble.none) {
      // A bubble that came by itself stays for a tap: the tap is for it.
      if (_byItself) {
        _cancel(_bubbleTimer);
        _bubbleTimer = null;
        setState(() => _byItself = false);
        return;
      }
      _closeBubble(seen: true);
      return;
    }
    if (widget.sources.permissions.value.isNotEmpty) {
      // The Inicio card already shows it: hop and count, no second bubble.
      if (widget.sources.needsCardVisible.value) {
        _hop();
      } else {
        _openBubble(_Bubble.permission);
      }
      return;
    }
    final notice = _nextNotice;
    if (notice != null) {
      _told.add(notice.key);
      _openBubble(_Bubble.notice, notice: notice);
      return;
    }
    _openBubble(_Bubble.menu);
  }

  void _openMenu() {
    _wake();
    _openBubble(_Bubble.menu);
  }

  // ---------------------------------------------------------------------
  // Drag (7 px threshold) and drop. It stays where it is dropped.

  void _onDown(PointerDownEvent e) {
    _downAt = e.position;
    _dragging = false;
    _pressed = false;
    _lastMove = (e.timeStamp, e.position);
    _grab = e.position - _pos.value;
    _cancel(_pressTimer);
    _pressTimer = _timer(MascotFloatPhysics.longPress, () {
      _pressTimer = null;
      if (!mounted || _dragging || _downAt == null) return;
      _pressed = true;
      _openMenu();
    });
  }

  void _endPress() {
    _cancel(_pressTimer);
    _pressTimer = null;
  }

  void _onMove(PointerMoveEvent e) {
    final start = _downAt;
    if (start == null) return;
    if (!_dragging && pastDragThreshold(e.position - start)) {
      // Picked up.
      _dragging = true;
      _endPress();
      _stopMotion();
      _motion = _Motion.none;
      _hopLift.value = 0;
      _endReturn();
      _closeBubble(seen: false);
      _wake();
      setState(() {});
    }
    if (_dragging) {
      _setPos(e.position - _grab); // 1:1 with the finger
      _lean(e);
    }
    _lastMove = (e.timeStamp, e.position);
  }

  /// While held it leans and squashes towards where the finger goes, and
  /// straightens up [MascotFloatPhysics.holdRelax] after it stops.
  void _lean(PointerMoveEvent e) {
    final last = _lastMove;
    if (_reduced || last == null) return;
    final dt = (e.timeStamp - last.$1).inMicroseconds / 1e6;
    if (dt <= 0) return;
    _pose.value = _Pose.lean((e.position - last.$2) / dt);
    _cancel(_relaxTimer);
    _relaxTimer = _timer(MascotFloatPhysics.holdRelax, () {
      _relaxTimer = null;
      if (mounted) _pose.value = _Pose.rest;
    });
  }

  void _onUp(PointerUpEvent e) => _release(cancelled: false);

  void _onCancel(PointerCancelEvent e) => _release(cancelled: true);

  void _release({required bool cancelled}) {
    final dragged = _dragging;
    final pressed = _pressed;
    _downAt = null;
    _dragging = false;
    _pressed = false;
    _lastMove = null;
    _endPress();
    _cancel(_relaxTimer);
    _relaxTimer = null;
    _pose.value = _Pose.rest;
    if (!dragged) {
      if (!cancelled && !pressed) _onTap();
      return;
    }
    _wake();
    final box = _pos.value & Size.square(_size);
    final bar = _bar;
    if (bar != null && MascotFloatPhysics.landsOnDock(box, bar)) {
      // On the dock it stands on the dock again, where it was let go.
      unawaited(
        _prefs.placeOnDock(
          along: MascotFloatPhysics.dockAlongOf(box.left, bar, _size),
        ),
      );
    } else {
      final spot = MascotFloatPhysics.clampInto(_pos.value, _bounds);
      unawaited(
        _prefs.placeFree(
          Offset(spot.dx / _screen.width, spot.dy / _screen.height),
        ),
      );
    }
    setState(() {});
    _reseat();
  }

  void _backToDock() {
    _closeBubble(seen: false);
    unawaited(_prefs.placeOnDock());
  }

  // ---------------------------------------------------------------------

  String _label(Strings strings) {
    final name = widget.pet.name;
    final state = switch (_state) {
      MascotState.idle => strings.mascotStateIdle(name),
      MascotState.thinking => strings.mascotStateThinking(name),
      MascotState.tool => strings.mascotStateTool(name),
      MascotState.needsYou => strings.mascotStateNeedsYou(name),
      MascotState.done => strings.mascotStateDone(name),
      MascotState.offline => strings.mascotStateOffline(name),
      MascotState.error => strings.mascotStateError(name),
    };
    final count = _count;
    return [
      strings.mascotOverlayLabel(name),
      state,
      if (count > 0) strings.mascotPendingCount(count),
    ].join('. ');
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    final count = _count;
    return LayoutBuilder(
      builder: (context, constraints) {
        _place(
          constraints.biggest,
          MediaQuery.viewPaddingOf(context),
          MediaQuery.systemGestureInsetsOf(context),
        );
        final visible = _visible;
        final size = _size;
        final mascot = Semantics(
          container: true,
          button: true,
          label: _label(strings),
          excludeSemantics: true,
          onTap: _onTap,
          onLongPress: _openMenu,
          customSemanticsActions: {
            CustomSemanticsAction(label: strings.mascotMenuHide): () =>
                unawaited(widget.pet.hide()),
          },
          child: Listener(
            key: const ValueKey('mascot-overlay-sprite'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onDown,
            onPointerMove: _onMove,
            onPointerUp: _onUp,
            onPointerCancel: _onCancel,
            child: SizedBox.square(
              dimension: size,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  ValueListenableBuilder<double>(
                    valueListenable: _hopLift,
                    builder: (context, lift, child) => Transform.translate(
                      offset: Offset(0, -lift),
                      child: child,
                    ),
                    child: ValueListenableBuilder<_Pose>(
                      valueListenable: _pose,
                      builder: (context, pose, child) => Transform(
                        key: const ValueKey('mascot-overlay-pose'),
                        alignment: Alignment.center,
                        transform: pose.matrix,
                        child: child,
                      ),
                      child: widget.pet.build(
                        context,
                        state: _state,
                        size: size,
                        asleep: _asleep || !_active,
                        look: _look,
                        airborne: _airborne,
                      ),
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
        final fade = _reduced
            ? Duration.zero
            : const Duration(milliseconds: 140);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            if (visible && _bubble != _Bubble.none && !_byItself)
              Positioned.fill(
                child: GestureDetector(
                  key: const ValueKey('mascot-overlay-barrier'),
                  behavior: HitTestBehavior.translucent,
                  excludeFromSemantics: true,
                  onTap: () => _closeBubble(seen: true),
                ),
              ),
            ValueListenableBuilder<Offset>(
              valueListenable: _pos,
              builder: (context, pos, child) =>
                  Positioned(left: pos.dx, top: pos.dy, child: child!),
              child: AnimatedSwitcher(
                duration: fade,
                child: !visible
                    ? const SizedBox.shrink(key: ValueKey('mascot-away'))
                    : IgnorePointer(
                        key: const ValueKey('mascot-here'),
                        ignoring: _scrolling,
                        child: AnimatedOpacity(
                          key: const ValueKey('mascot-overlay-opacity'),
                          duration: fade,
                          opacity: _scrolling
                              ? MascotFloatPhysics.scrollOpacity
                              : _asleep
                              ? MascotFloatPhysics.asleepOpacity
                              : 1,
                          child: mascot,
                        ),
                      ),
              ),
            ),
            if (visible && _bubble != _Bubble.none)
              _bubbleWidget(context, strings, colors, chrome),
          ],
        );
      },
    );
  }

  Widget _bubbleWidget(
    BuildContext context,
    Strings strings,
    HermesThemeColors colors,
    HermesChrome chrome,
  ) {
    final menu = _bubble == _Bubble.menu;
    // The most it may take; it is as wide as what it says.
    final width = math.min(menu ? 232.0 : 284.0, _screen.width - 24);
    final pos = _pos.value;
    final centre = pos.dx + _size / 2;
    // It hangs from the mascot's side of the screen, never off it.
    final left = (centre + _size / 2 - width)
        .clamp(12.0, math.max(12.0, _screen.width - width - 12))
        .toDouble();
    final fromRight = centre > left + width / 2;
    final above = pos.dy + _size / 2 > _screen.height / 2;
    final content = switch (_bubble) {
      _Bubble.permission => _permissionBubble(strings, chrome),
      _Bubble.menu => _menuBubble(strings, chrome),
      _Bubble.notice => _noticeBubble(strings, chrome, _notice!),
      _Bubble.none => const SizedBox.shrink(),
    };
    const tail = 7.0;
    // The tail points at the mascot, measured from the side it hangs from.
    final tailInset =
        ((fromRight ? left + width - centre : centre - left) - tail)
            .clamp(18.0, math.max(18.0, width - 18 - tail * 2))
            .toDouble();
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: chrome.opaque,
        border: Border.all(color: chrome.line),
        borderRadius: BorderRadius.circular(HermesRadius.floating),
        boxShadow: chrome.shadow,
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(HermesRadius.floating),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: menu
              ? const EdgeInsets.symmetric(vertical: 6)
              : const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: content,
        ),
      ),
    );
    return Positioned(
      left: left,
      width: width,
      top: above ? null : pos.dy + _size + tail + 4,
      bottom: above ? _screen.height - pos.dy + tail + 4 : null,
      child: Align(
        alignment: fromRight ? Alignment.centerRight : Alignment.centerLeft,
        child: IntrinsicWidth(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 132),
            child: Semantics(
              key: const ValueKey('mascot-overlay-bubble'),
              container: true,
              // A notice is read when the reader is free; an approval is
              // announced at once (see [_announcePermission]).
              liveRegion: _bubble == _Bubble.notice,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: fromRight ? null : tailInset,
                    right: fromRight ? tailInset : null,
                    top: above ? null : -tail + 1,
                    bottom: above ? -tail + 1 : null,
                    child: Transform.rotate(
                      angle: math.pi / 4,
                      child: Container(
                        width: tail * 2,
                        height: tail * 2,
                        decoration: BoxDecoration(
                          color: chrome.opaque,
                          border: Border.all(color: chrome.line),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                  surface,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pill(
    String key,
    String label,
    VoidCallback onTap,
    HermesChrome chrome, {
    bool primary = false,
  }) {
    final colors = Theme.of(context).hermes;
    return Material(
      key: ValueKey('mascot-bubble-$key'),
      color: primary ? colors.accent : chrome.fill,
      shape: StadiumBorder(
        side: primary ? BorderSide.none : BorderSide(color: chrome.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40, minWidth: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              widthFactor: 1,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: primary ? colors.onAccent : chrome.ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _permissionBubble(Strings strings, HermesChrome chrome) {
    final item = widget.sources.permissions.value.first;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: chrome.ink,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (item.command != null) ...[
          const SizedBox(height: 6),
          Text(
            item.command!,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: chrome.mutedInk,
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
            _pill(
              'allow',
              strings.mascotPermissionAllow,
              () => _answer(item, true),
              chrome,
              primary: true,
            ),
            _pill(
              'deny',
              strings.mascotPermissionDeny,
              () => _answer(item, false),
              chrome,
            ),
            if (item.openChat != null)
              _pill('open', strings.mascotPermissionOpenChat, () {
                _closeBubble(seen: false);
                item.openChat!();
              }, chrome),
          ],
        ),
      ],
    );
  }

  void _answer(MascotPermission item, bool allow) {
    _closeBubble(seen: false);
    unawaited(item.resolve(allow).catchError((Object _) {}));
  }

  Widget _noticeBubble(
    Strings strings,
    HermesChrome chrome,
    MascotNotice notice,
  ) {
    final action = notice.action;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          notice.text(strings),
          key: const ValueKey('mascot-bubble-text'),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: chrome.ink, fontSize: 15, height: 1.3),
        ),
        if (action != null || notice.isSuggestion) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (action != null)
                _pill(
                  'action',
                  action(strings),
                  () {
                    final run = notice.onAction;
                    _closeBubble(seen: true);
                    run?.call();
                  },
                  chrome,
                  primary: true,
                ),
              if (notice.isSuggestion)
                _pill('never', strings.mascotSuggestionNever, () {
                  _closeBubble(seen: true);
                  unawaited(_prefs.muteSuggestion(notice.key));
                }, chrome),
            ],
          ),
        ],
      ],
    );
  }

  Widget _menuBubble(Strings strings, HermesChrome chrome) {
    Widget item(String key, IconData icon, String label, VoidCallback onTap) =>
        InkWell(
          key: ValueKey('mascot-menu-$key'),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: HermesSpace.tap),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: chrome.mutedInk),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: chrome.ink, fontSize: 15),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
    void then(VoidCallback? action) {
      _closeBubble(seen: false);
      action?.call();
    }

    final actions = widget.actions;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (actions.onTalk != null)
          item(
            'talk',
            Icons.graphic_eq_rounded,
            strings.mascotMenuTalk,
            () => then(actions.onTalk),
          ),
        if (actions.onChange != null)
          item(
            'change',
            Icons.refresh_rounded,
            strings.mascotChange,
            () => then(actions.onChange),
          ),
        if (_prefs.moved)
          item(
            'dock',
            Icons.vertical_align_bottom_rounded,
            strings.mascotMenuDock,
            _backToDock,
          ),
        item('hide', Icons.close_rounded, strings.mascotMenuHide, () {
          _closeBubble(seen: false);
          unawaited(widget.pet.hide());
        }),
      ],
    );
  }
}

/// Lean and squash of the sprite around its centre.
@immutable
class _Pose {
  const _Pose({this.angle = 0, this.scaleX = 1, this.scaleY = 1});

  /// Leaning into a drag at [velocity] (px/s): tilted the way it goes
  /// sideways, stretched along the motion and squashed across it.
  factory _Pose.lean(Offset velocity) {
    const full = MascotFloatPhysics.holdFullSpeed;
    final speed = velocity.distance;
    if (speed == 0) return rest;
    final tilt =
        (velocity.dx / full).clamp(-1.0, 1.0) * MascotFloatPhysics.holdTilt;
    final s = (speed / full).clamp(0.0, 1.0) * MascotFloatPhysics.holdSquash;
    final along = (velocity.dx.abs() - velocity.dy.abs()) / speed;
    return _Pose(angle: tilt, scaleX: 1 + s * along, scaleY: 1 - s * along);
  }

  static const rest = _Pose();

  final double angle;
  final double scaleX;
  final double scaleY;

  Matrix4 get matrix =>
      Matrix4.rotationZ(angle)
        ..multiply(Matrix4.diagonal3Values(scaleX, scaleY, 1));
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
