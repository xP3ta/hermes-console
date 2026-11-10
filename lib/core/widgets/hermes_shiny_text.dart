import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Texto con un brillo que lo recorre de lado a lado, para el estado «en
/// curso» (pasos, píldora «pensando») en lugar de un spinner.
///
/// Es solo presentación: [child] (normalmente un `Text`) conserva su texto,
/// sus claves y su semántica. Mientras corre, la tinta del texto pasa de
/// [base] a [highlight] en una banda estrecha que se desplaza; entre barridos
/// el texto queda en [base]. Los dos colores salen del tema por defecto.
///
/// Con «reducir movimiento» (o con [active] en `false`) devuelve el [child]
/// tal cual y no crea ni deja corriendo ningún reloj.
class HermesShinyText extends StatefulWidget {
  const HermesShinyText({
    required this.child,
    this.active = true,
    this.base,
    this.highlight,
    this.period = const Duration(seconds: 1, milliseconds: 800),
    super.key,
  });

  final Widget child;

  /// `false` deja el texto quieto (el paso ya terminó).
  final bool active;

  /// Tinta del texto fuera de la banda. Por defecto, `textSecondary`.
  final Color? base;

  /// Tinta en el centro de la banda. Por defecto, `textPrimary`.
  final Color? highlight;

  /// Lo que tarda un barrido completo.
  final Duration period;

  @override
  State<HermesShinyText> createState() => _HermesShinyTextState();
}

class _HermesShinyTextState extends State<HermesShinyText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.period,
  );
  bool _reduceMotion = false;

  bool get _animating => widget.active && !_reduceMotion;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(HermesShinyText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.period != widget.period) {
      _controller.duration = widget.period;
    }
    _sync();
  }

  void _sync() {
    if (_animating) {
      if (!_controller.isAnimating) _controller.repeat();
    } else if (_controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_animating) return widget.child;
    final colors = Theme.of(context).hermes;
    final base = widget.base ?? colors.textSecondary;
    final highlight = widget.highlight ?? colors.textPrimary;
    final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        child: widget.child,
        builder: (context, child) => ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) => LinearGradient(
            colors: [base, highlight, base],
            stops: const [0.35, 0.5, 0.65],
            transform: _ShineSlide(_controller.value, direction),
          ).createShader(bounds),
          child: child,
        ),
      ),
    );
  }
}

/// Desplaza la banda de [progress] 0 (fuera por un lado) a 1 (fuera por el
/// otro); espeja el sentido en textos de derecha a izquierda.
class _ShineSlide extends GradientTransform {
  const _ShineSlide(this.progress, this.direction);

  final double progress;
  final TextDirection direction;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    final travel = bounds.width * (progress * 1.6 - 0.8);
    final dx = direction == TextDirection.rtl ? -travel : travel;
    return Matrix4.translationValues(dx, 0, 0);
  }
}
