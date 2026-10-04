import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'hermes_spark_mascot.dart' show HermesSparkMood;

/// Pulso cuadrado al estilo del `StatusPulse` de Hermes Desktop: un
/// cuadradito de 12 px (esquinas de 2 px) que late mientras el agente
/// trabaja. Es la señal de "sigue trabajando" del hilo del chat cuando la
/// mascota del Companion está apagada; Desktop no usa ningún spinner circular
/// junto a la burbuja del asistente.
class HermesStatusPulse extends StatefulWidget {
  final double size;
  final Color? color;

  const HermesStatusPulse({super.key, this.size = 12, this.color});

  @override
  State<HermesStatusPulse> createState() => _HermesStatusPulseState();
}

class _HermesStatusPulseState extends State<HermesStatusPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion) {
      _controller
        ..stop()
        ..value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).hermes.accent;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final square = DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(2),
      ),
      child: SizedBox(width: widget.size, height: widget.size),
    );
    if (reduceMotion) return square;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Opacity(
        opacity: 0.35 + 0.65 * _controller.value,
        child: Transform.scale(
          scale: 0.8 + 0.2 * _controller.value,
          child: child,
        ),
      ),
      child: square,
    );
  }
}

/// Indicador de estado NEUTRO (sin mascota) para progreso/diagnóstico:
/// comprobando → spinner, OK → check verde, error → icono rojo,
/// sin conexión → "cloud off", reposo → punto tenue.
///
/// El `HermesSparkMascot` se reserva como mascota/companion; este widget cubre
/// los usos puramente funcionales de estado.
class HermesStatusIndicator extends StatelessWidget {
  final HermesSparkMood mood;
  final double size;

  const HermesStatusIndicator({super.key, required this.mood, this.size = 24});

  static const _ok = Color(0xFF3FB950);
  static const _err = Color(0xFFE5534B);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    switch (mood) {
      case HermesSparkMood.connecting:
      case HermesSparkMood.thinking:
        return SizedBox(
          width: size,
          height: size,
          child: CircularProgressIndicator(
            strokeWidth: size >= 40 ? 3 : 2,
            valueColor: AlwaysStoppedAnimation<Color>(colors.accent),
          ),
        );
      case HermesSparkMood.success:
        return Icon(Icons.check_circle, color: _ok, size: size);
      case HermesSparkMood.error:
        return Icon(Icons.error_outline, color: _err, size: size);
      case HermesSparkMood.offline:
        return Icon(
          Icons.cloud_off,
          color: colors.textSecondary,
          size: size * 0.9,
        );
      case HermesSparkMood.idle:
      case HermesSparkMood.waiting:
      case HermesSparkMood
          .jump: // no se usa aquí; icono neutro por exhaustividad
        return Icon(
          Icons.radio_button_unchecked,
          color: colors.textSecondary,
          size: size * 0.8,
        );
    }
  }
}
