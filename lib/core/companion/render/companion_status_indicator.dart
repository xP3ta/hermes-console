import 'package:flutter/material.dart';

import '../../widgets/hermes_spark_mascot.dart';
import '../../widgets/hermes_status_indicator.dart';
import '../models/companion_presence_level.dart';
import '../state/companion_controller.dart';
import 'companion_message_presence.dart';

/// Indicador de estado de un turno que muestra la mascota del Companion en
/// encabezados y otras superficies de presencia cuando está activa.
///
/// Si el Companion está apagado, deshabilitado o no hay controller, cae al
/// pulso cuadrado de Hermes Desktop para los estados de trabajo; el indicador
/// clásico queda reservado a resultados (ok/error/offline).
class CompanionStatusIndicator extends StatelessWidget {
  /// Controller del Companion. Si es null, se usa el fallback sin mascota.
  final CompanionController? companion;
  final HermesSparkMood mood;
  final double size;
  final bool? animate;

  const CompanionStatusIndicator({
    super.key,
    required this.companion,
    required this.mood,
    this.size = 24,
    this.animate,
  });

  /// Señal de estado sin mascota. Los estados de trabajo (conectando,
  /// esperando, pensando) usan el pulso cuadrado discreto de Desktop en vez
  /// del spinner circular, que a tamaño de mascota (42-88 px) resultaba
  /// tosco. El lado del cuadrado se mantiene pequeño aunque el hueco
  /// reservado sea grande.
  Widget _fallback() {
    return switch (mood) {
      HermesSparkMood.connecting ||
      HermesSparkMood.waiting ||
      HermesSparkMood.thinking => HermesStatusPulse(size: size >= 64 ? 16 : 12),
      _ => HermesStatusIndicator(size: size, mood: mood),
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = companion;
    if (c == null) return _fallback();
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        if (c.isInitialized &&
            c.enabled &&
            c.presenceLevel.showsStatusPresence) {
          return CompanionMessagePresence(
            companion: c,
            mood: mood,
            size: size,
            animate: animate,
          );
        }
        return _fallback();
      },
    );
  }
}
