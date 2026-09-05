import 'package:flutter/material.dart';

import '../../widgets/hermes_spark_mascot.dart';
import '../models/companion_presence_level.dart';
import '../state/companion_controller.dart';
import '../state/companion_presence_controller.dart';
import 'companion_view.dart';

/// Presencia **mini y no invasiva** del Companion (feature 006): una mascota
/// pequeña (28–36 px) que refleja el ánimo de [CompanionPresenceController] y,
/// opcionalmente, un texto de estado ("Pensando…", "Esperando permiso…").
///
/// Reutiliza [CompanionView] (misma mascota activa/escala). Reglas:
/// - Si el Companion está **deshabilitado** → invisible (`SizedBox.shrink`).
/// - **reduce-motion**: el ánimo se sigue reflejando; el render no fuerza loops
///   nuevos (no se inyecta `replayToken` salvo en one-shots ya disparados).
/// - **Tap** → `petTapped` (saludo), sin abrir nada pesado (D6).
/// - No bloquea la UI subyacente más allá de su propia área.
class CompanionPresence extends StatelessWidget {
  final CompanionPresenceController presence;
  final CompanionController companion;

  /// Tamaño de la mascota mini (D5: 28–36 px).
  final double size;

  /// Muestra el texto de estado junto a la mascota (modo "completa").
  final bool showLabel;

  const CompanionPresence({
    super.key,
    required this.presence,
    required this.companion,
    this.size = 32,
    this.showLabel = false,
  });

  static String? labelFor(HermesSparkMood mood) {
    switch (mood) {
      case HermesSparkMood.thinking:
        return 'Pensando…';
      case HermesSparkMood.waiting:
        return 'Esperando permiso…';
      case HermesSparkMood.connecting:
        return 'Conectando…';
      case HermesSparkMood.offline:
        return 'Offline';
      case HermesSparkMood.idle:
      case HermesSparkMood.success:
      case HermesSparkMood.error:
      case HermesSparkMood.jump:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([presence, companion]),
      builder: (context, _) {
        // Invisible si el Companion está apagado o el nivel de presencia es off.
        if (!companion.isInitialized ||
            !companion.enabled ||
            !companion.presenceLevel.isVisible) {
          return const SizedBox.shrink();
        }

        final mood = presence.mood;
        final mascot = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => presence.onEvent(PresenceEvent.petTapped),
          child: CompanionView(
            mood: mood,
            size: size,
            controller: companion,
            replayToken: presence.replayToken,
          ),
        );

        // El texto solo aparece en nivel "completa".
        if (!showLabel || !companion.presenceLevel.showsLabel) return mascot;
        final label = labelFor(mood);
        if (label == null) return mascot;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            mascot,
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        );
      },
    );
  }
}
