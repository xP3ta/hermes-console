import 'dart:async';

import 'package:flutter/widgets.dart';

import '../theme/motion.dart';

/// Entrada sutil (fade + leve deslizamiento ascendente) que se reproduce UNA
/// vez cuando el widget aparece por primera vez. Respeta "reducir movimiento"
/// (aparece instantáneo). Pensada para bloques de contenido y elementos de
/// lista, para que la app se sienta fluida al abrir pantallas y mostrar cosas.
class MotionEntrance extends StatefulWidget {
  const MotionEntrance({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.offset = 8,
  });

  /// Contenido que entra.
  final Widget child;

  /// Retardo antes de arrancar (para escalonar entradas de lista).
  final Duration delay;

  /// Desplazamiento vertical inicial en píxeles.
  final double offset;

  @override
  State<MotionEntrance> createState() => _MotionEntranceState();
}

class _MotionEntranceState extends State<MotionEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Motion.base,
  );
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _controller,
    curve: Motion.enter,
  );
  Timer? _delayTimer;
  bool _entranceStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entranceStarted) return;
    _entranceStarted = true;
    if (Motion.reduced(context)) {
      // Avoid painting even one opacity-zero frame when motion is reduced.
      _controller.value = 1;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.delay == Duration.zero) {
        _controller.forward();
      } else {
        _delayTimer = Timer(widget.delay, () {
          if (mounted) _controller.forward();
        });
      }
    });
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _curved,
      child: AnimatedBuilder(
        animation: _curved,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, widget.offset * (1 - _curved.value)),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}
