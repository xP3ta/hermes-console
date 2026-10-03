import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../widgets/hermes_spark_mascot.dart';
import '../models/companion_presence_level.dart';
import '../state/companion_controller.dart';
import '../state/companion_presence_controller.dart';
import 'companion_view.dart';

/// Paseo decorativo y opt-in de la mascota sobre una superficie segura.
///
/// La pista es horizontal y empieza en [padding.top]. El overlay se limita al
/// [child] que recibe y no usa un `OverlayEntry` global, por lo que AppBar,
/// drawer, conversaciones y diálogos conservan su prioridad visual. La mascota
/// solo intercepta el toque cuando [onPetTap] está configurado.
class CompanionRoamingOverlay extends StatefulWidget {
  const CompanionRoamingOverlay({
    super.key,
    required this.child,
    required this.controller,
    this.presence,
    this.baseMood = HermesSparkMood.idle,
    this.accent,
    this.size = 58,
    this.padding = const EdgeInsets.fromLTRB(10, 10, 10, 18),
    this.random,
    this.minPause = const Duration(milliseconds: 1400),
    this.maxPause = const Duration(milliseconds: 3600),
    this.minTravel = const Duration(milliseconds: 2200),
    this.maxTravel = const Duration(milliseconds: 5200),
    this.minRest = const Duration(seconds: 20),
    this.maxRest = const Duration(seconds: 40),
    this.onPetTap,
    this.petSemanticLabel,
    this.onTravelFrame,
  });

  final Widget child;
  final CompanionController? controller;
  final CompanionPresenceController? presence;
  final HermesSparkMood baseMood;
  final Color? accent;
  final double size;
  final EdgeInsets padding;

  /// Inyectables para tests deterministas.
  final math.Random? random;
  final Duration minPause;
  final Duration maxPause;
  final Duration minTravel;
  final Duration maxTravel;

  /// Pausa larga que sustituye a [minPause]/[maxPause] cuando la mascota lleva
  /// [CompanionRoamingOverlay.tripsBeforeRest] paseos sin ninguna interacción.
  final Duration minRest;
  final Duration maxRest;
  final VoidCallback? onPetTap;
  final String? petSemanticLabel;

  /// Sonda de presupuesto para tests. Solo informa la posición decorativa que
  /// acaba de cambiar; no expone contenido de la app ni se usa en producción.
  @visibleForTesting
  final ValueChanged<Offset>? onTravelFrame;

  /// Paseos seguidos sin interacción tras los que la mascota descansa. Cada
  /// paso del paseo es un frame completo (composición y desenfoque del dock
  /// incluidos); un Home desatendido no necesita animarse sin pausa.
  static const int tripsBeforeRest = 3;

  @override
  State<CompanionRoamingOverlay> createState() =>
      _CompanionRoamingOverlayState();
}

class _CompanionRoamingOverlayState extends State<CompanionRoamingOverlay>
    with WidgetsBindingObserver {
  late math.Random _random;
  Timer? _phaseTimer;
  Timer? _travelTimer;
  Rect _bounds = Rect.zero;
  final ValueNotifier<Offset> _visualPosition = ValueNotifier(Offset.zero);
  bool _hasPosition = false;
  bool _moving = false;
  bool _facingRight = true;
  bool _foreground = true;
  bool _canAnimate = false;
  bool _syncQueued = false;

  /// Paseos completados desde la última interacción del usuario.
  int _tripsSinceActivity = 0;

  /// La pausa en curso es el descanso largo (no la pausa normal).
  bool _resting = false;

  /// El paseo es pixel-art decorativo y no necesita los 120 ticks/s del panel
  /// del Pixel. Doce pasos por segundo, la cadencia típica del pixel-art,
  /// conservan una trayectoria continua; cada paso cuesta un frame completo.
  @visibleForTesting
  static const Duration travelFrameInterval = Duration(microseconds: 83334);

  @override
  void initState() {
    super.initState();
    _random = widget.random ?? math.Random();
    WidgetsBinding.instance.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
    widget.presence?.addListener(_registerActivity);
  }

  /// Cualquier toque en la app (o un cambio de presencia) cuenta como
  /// actividad: reinicia el contador de descanso y, si la mascota dormía,
  /// vuelve en seguida al ritmo normal de paseo.
  void _onGlobalPointer(PointerEvent event) {
    if (event is PointerDownEvent) _registerActivity();
  }

  void _registerActivity() {
    _tripsSinceActivity = 0;
    if (!_resting || !mounted) return;
    _resting = false;
    _phaseTimer?.cancel();
    _phaseTimer = null;
    _schedulePause();
  }

  @override
  void didUpdateWidget(covariant CompanionRoamingOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.random != widget.random) {
      _random = widget.random ?? math.Random();
    }
    if (oldWidget.presence != widget.presence) {
      oldWidget.presence?.removeListener(_registerActivity);
      widget.presence?.addListener(_registerActivity);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (!foreground) _stopPhases();
    if (foreground) _tripsSinceActivity = 0;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
    widget.presence?.removeListener(_registerActivity);
    _stopPhases();
    _visualPosition.dispose();
    super.dispose();
  }

  void _stopPhases() {
    _phaseTimer?.cancel();
    _phaseTimer = null;
    _travelTimer?.cancel();
    _travelTimer = null;
    _canAnimate = false;
    _moving = false;
    _resting = false;
  }

  Duration _randomDuration(Duration min, Duration max) {
    final low = min.inMilliseconds;
    final high = math.max(low, max.inMilliseconds);
    if (high == low) return Duration(milliseconds: low);
    return Duration(milliseconds: low + _random.nextInt(high - low + 1));
  }

  Offset _clampToBounds(Offset value, Rect bounds) => Offset(
    value.dx.clamp(bounds.left, bounds.right).toDouble(),
    value.dy.clamp(bounds.top, bounds.bottom).toDouble(),
  );

  Offset _nextDestination() {
    final current = _visualPosition.value;
    if (_bounds.width <= 0) return current;
    final minDistance = math.min(72.0, _bounds.width * 0.35);
    var candidate = current;
    for (var attempt = 0; attempt < 8; attempt++) {
      candidate = Offset(
        _bounds.left + _random.nextDouble() * _bounds.width,
        _bounds.top,
      );
      if ((candidate - current).distance >= minDistance) break;
    }
    return candidate;
  }

  void _setVisualPosition(Offset value, {bool reportTravelFrame = false}) {
    if (_visualPosition.value == value) return;
    _visualPosition.value = value;
    if (reportTravelFrame) widget.onTravelFrame?.call(value);
  }

  void _schedulePause() {
    if (!_canAnimate ||
        _moving ||
        _travelTimer != null ||
        _phaseTimer != null) {
      return;
    }
    _resting = _tripsSinceActivity >= CompanionRoamingOverlay.tripsBeforeRest;
    final pause = _resting
        ? _randomDuration(widget.minRest, widget.maxRest)
        : _randomDuration(widget.minPause, widget.maxPause);
    _phaseTimer = Timer(pause, () {
      _phaseTimer = null;
      _resting = false;
      if (!mounted || !_canAnimate) return;
      _startTravel();
    });
  }

  void _startTravel() {
    final start = _visualPosition.value;
    final destination = _nextDestination();
    final distance = (destination - start).distance;
    final minMs = widget.minTravel.inMilliseconds;
    final maxMs = math.max(minMs, widget.maxTravel.inMilliseconds);
    final proportionalMs = (distance / 34 * 1000).round();
    final durationMs = proportionalMs.clamp(minMs, maxMs);
    final totalSteps = math.max(
      1,
      (Duration(milliseconds: durationMs).inMicroseconds /
              travelFrameInterval.inMicroseconds)
          .ceil(),
    );
    var step = 0;

    setState(() {
      _facingRight = destination.dx >= start.dx;
      _moving = true;
    });

    _travelTimer?.cancel();
    _travelTimer = Timer.periodic(travelFrameInterval, (timer) {
      if (!mounted || !_canAnimate) {
        timer.cancel();
        _travelTimer = null;
        return;
      }
      step++;
      final progress = (step / totalSteps).clamp(0.0, 1.0);
      _setVisualPosition(
        Offset.lerp(start, destination, progress)!,
        reportTravelFrame: true,
      );
      if (step < totalSteps) return;

      timer.cancel();
      _travelTimer = null;
      _tripsSinceActivity++;
      setState(() => _moving = false);
      _schedulePause();
    });
  }

  void _queueLayoutSync({
    required Rect bounds,
    required bool canAnimate,
    required bool reduceMotion,
  }) {
    if (_syncQueued) return;
    _syncQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncQueued = false;
      if (!mounted) return;

      final boundsChanged = bounds != _bounds;
      _bounds = bounds;
      _canAnimate = canAnimate && !reduceMotion;

      if (!_hasPosition) {
        _hasPosition = true;
        _setVisualPosition(Offset(bounds.right, bounds.bottom));
      } else if (boundsChanged) {
        _travelTimer?.cancel();
        _travelTimer = null;
        _moving = false;
        _setVisualPosition(_clampToBounds(_visualPosition.value, bounds));
      }

      if (!_canAnimate) {
        _phaseTimer?.cancel();
        _phaseTimer = null;
        _resting = false;
        _travelTimer?.cancel();
        _travelTimer = null;
        final staticPosition = Offset(bounds.right, bounds.bottom);
        final changed =
            _moving || _visualPosition.value != staticPosition || boundsChanged;
        _moving = false;
        _setVisualPosition(staticPosition);
        if (changed) setState(() {});
        return;
      }

      if (boundsChanged) setState(() {});
      _schedulePause();
    });
  }

  HermesSparkMood _effectiveMood() {
    final presenceMood = widget.presence?.mood;
    if (presenceMood == HermesSparkMood.error ||
        presenceMood == HermesSparkMood.waiting ||
        presenceMood == HermesSparkMood.success ||
        presenceMood == HermesSparkMood.jump) {
      return presenceMood!;
    }
    return _moving
        ? HermesSparkMood.thinking
        : (presenceMood ?? widget.baseMood);
  }

  Widget _buildSurface(BuildContext context) {
    final controller = widget.controller;
    final media = MediaQuery.of(context);
    final reduceMotion = media.disableAnimations;
    final tickerEnabled = TickerMode.valuesOf(context).enabled;
    // Scaffold puede consumir `MediaQuery.viewInsets` al redimensionar el body.
    // El View conserva el inset Android real y evita que el paseo siga encima
    // del formulario mientras el IME está visible.
    final view = View.maybeOf(context);
    final rawKeyboardInset = view?.viewInsets.bottom ?? 0;
    final keyboardVisible = media.viewInsets.bottom > 0 || rawKeyboardInset > 0;
    final preferenceVisible =
        controller != null &&
        controller.isInitialized &&
        controller.enabled &&
        controller.showOnHome &&
        controller.roamingEnabled &&
        controller.presenceLevel.isVisible;
    final showPet =
        preferenceVisible && _foreground && tickerEnabled && !keyboardVisible;

    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = controller?.sizeMultiplier ?? 1;
        final extent = widget.size * scale;
        final right = math.max(
          widget.padding.left,
          constraints.maxWidth - widget.padding.right - extent,
        );
        final bounds = Rect.fromLTRB(
          widget.padding.left,
          widget.padding.top,
          right,
          widget.padding.top,
        );

        _queueLayoutSync(
          bounds: bounds,
          canAnimate: showPet,
          reduceMotion: reduceMotion,
        );

        final pet = Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(_facingRight ? 1 : -1, 1, 1),
          child: SizedBox(
            key: const ValueKey('companion-roaming-pet'),
            width: extent,
            height: extent,
            child: FittedBox(
              fit: BoxFit.contain,
              child: CompanionView(
                controller: controller,
                mood: _effectiveMood(),
                size: widget.size,
                accent: widget.accent,
                replayToken: widget.presence?.replayToken ?? 0,
                animate: !reduceMotion && tickerEnabled && _foreground,
              ),
            ),
          ),
        );
        final onPetTap = widget.onPetTap;
        final petSurface = onPetTap == null
            ? IgnorePointer(child: ExcludeSemantics(child: pet))
            : Semantics(
                button: true,
                label: widget.petSemanticLabel,
                onTap: onPetTap,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onPetTap,
                  onLongPress: onPetTap,
                  child: ExcludeSemantics(child: pet),
                ),
              );

        return Stack(
          fit: StackFit.passthrough,
          clipBehavior: Clip.hardEdge,
          children: [
            widget.child,
            if (showPet && _hasPosition)
              // La capa propia cubre toda la pista: mover la mascota solo
              // vuelve a grabar esta capa (un desplazamiento sobre el sprite
              // ya cacheado), sin reconstruir widgets ni repintar el Home que
              // queda debajo. Fuera del sprite no hay hit-test, así que el
              // compositor sigue recibiendo sus toques.
              Positioned.fill(
                child: CompanionRoamingPosition(
                  key: const ValueKey('companion-roaming-position'),
                  position: _visualPosition,
                  child: petSurface,
                ),
              ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller == null) return widget.child;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final presence = widget.presence;
        if (presence == null) return _buildSurface(context);
        return ListenableBuilder(
          listenable: presence,
          builder: (context, _) => _buildSurface(context),
        );
      },
    );
  }
}

/// Desplaza a [child] hasta [position] escuchando el notifier desde la capa de
/// render: cada paso del paseo repinta solo esta frontera de repintado.
///
/// El `Transform` anterior no era frontera de repintado: cada paso repintaba
/// todo el Home que queda debajo (compositor y recientes) además de
/// reconstruir un elemento.
@visibleForTesting
class CompanionRoamingPosition extends SingleChildRenderObjectWidget {
  const CompanionRoamingPosition({
    super.key,
    required this.position,
    required Widget super.child,
  });

  final ValueListenable<Offset> position;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderRoamingPosition(position);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderRoamingPosition).position = position;
  }
}

class _RenderRoamingPosition extends RenderProxyBox {
  _RenderRoamingPosition(this._position);

  ValueListenable<Offset> _position;

  set position(ValueListenable<Offset> value) {
    if (identical(value, _position)) return;
    if (attached) {
      _position.removeListener(_onPositionChanged);
      value.addListener(_onPositionChanged);
    }
    _position = value;
    _onPositionChanged();
  }

  void _onPositionChanged() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _position.addListener(_onPositionChanged);
  }

  @override
  void detach() {
    _position.removeListener(_onPositionChanged);
    super.detach();
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    child?.layout(constraints.loosen());
  }

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintOffset(
      offset: _position.value,
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child != null) context.paintChild(child, offset + _position.value);
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final offset = _position.value;
    transform.translateByDouble(offset.dx, offset.dy, 0, 1);
  }
}
