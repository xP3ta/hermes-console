import 'package:flutter/material.dart';

import '../../widgets/hermes_spark_mascot.dart';
import '../models/companion_presence_level.dart';
import '../state/companion_controller.dart';
import 'companion_view.dart';

/// Presencia **por mensaje** del Companion en la cabecera de cada turno de
/// Hermes (feature 006, FASE 2).
///
/// A diferencia de [CompanionPresence] (que refleja el ánimo **app-wide** del
/// [CompanionPresenceController]), aquí el ánimo es **local al mensaje**: lo
/// decide quien la pinta a partir del estado de ESE turno (streaming →
/// `thinking`; error → `error`; terminado → `idle`). Así los mensajes
/// históricos no "piensan" cuando llega uno nuevo.
///
/// Reglas:
/// - Invisible (`SizedBox.shrink`) salvo con presencia `full`: `minimal` está
///   reservada a Home/Mascotas y no ocupa espacio dentro del chat.
/// - **No intercepta gestos**: es puramente decorativa (sin `GestureDetector`),
///   para no romper selección de texto, copiar ni el botón de voz del mensaje.
/// - reduce-motion: lo hereda de [CompanionView]/[SpritesheetRenderer].
/// - El tamaño continuo del usuario se aplica vía [CompanionView], dentro del
///   rango seguro previsto.
class CompanionMessagePresence extends StatelessWidget {
  final CompanionController companion;
  final HermesSparkMood mood;

  /// Tamaño base de la mascota mini (antes del multiplicador continuo).
  final double size;

  /// Mantiene el reposo animado en superficies vivas como el estado vacío.
  final bool animateIdle;

  /// Fuerza animación viva o fotograma estático para cualquier mood.
  final bool? animate;

  const CompanionMessagePresence({
    super.key,
    required this.companion,
    required this.mood,
    this.size = 22,
    this.animateIdle = false,
    this.animate,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: companion,
      builder: (context, _) {
        if (!companion.isInitialized ||
            !companion.enabled ||
            !companion.presenceLevel.showsStatusPresence) {
          return const SizedBox.shrink();
        }
        return CompanionView(
          mood: mood,
          size: size,
          controller: companion,
          animate: animate ?? (animateIdle || mood != HermesSparkMood.idle),
        );
      },
    );
  }
}
