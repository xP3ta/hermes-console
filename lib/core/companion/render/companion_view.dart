import 'package:flutter/material.dart';

import '../../widgets/hermes_spark_mascot.dart';
import '../models/companion_animation_state.dart';
import '../state/companion_controller.dart';
import 'spritesheet_renderer.dart';
import '../../../l10n/app_localizations.dart';

/// Punto único de render de la mascota.
///
/// Si hay un [CompanionController] con una mascota activa y válida, renderiza el
/// [SpritesheetRenderer]; en cualquier otro caso (controller ausente, mascota
/// desactivada, slug inválido o nulo) hace fallback a un `HermesSparkMascot`
/// reducido (×0.6) para que el placeholder sea discreto.
///
/// Esto permite reemplazar `HermesSparkMascot` por `CompanionView` en las
/// superficies actuales (Home/Chat…) sin cambiar el comportamiento por defecto.
class CompanionView extends StatelessWidget {
  final HermesSparkMood mood;
  final double size;
  final CompanionController? controller;

  /// Acento reenviado al fallback `HermesSparkMascot` (los sprites tienen sus
  /// propios colores, así que no se usa en el renderer de mascota).
  final Color? accent;

  /// Reenviado al renderer para reiniciar la animación actual sin cambiar de
  /// estado (tap repetido en Home → vuelve a saludar). Por defecto 0 (inerte),
  /// así el resto de superficies — Chat incluido — no cambian de comportamiento.
  final int replayToken;

  /// Permite que superficies repetidas (mensajes históricos) conserven la
  /// presencia visual sin mantener un reloj de animación cada una.
  final bool animate;

  const CompanionView({
    super.key,
    this.mood = HermesSparkMood.idle,
    this.size = 96,
    this.controller,
    this.accent,
    this.replayToken = 0,
    this.animate = true,
  });

  @override
  Widget build(BuildContext context) {
    final controller = this.controller;
    if (controller == null) {
      // Sin controller no hay preferencia de escala: tamaño base (Fase A).
      return _labeled(context, _fallback(size));
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        // Desactivada: no se muestra NINGUNA mascota (ni siquiera el Spark).
        // Se reserva el espacio base para no descuadrar el layout.
        if (!controller.enabled) {
          return SizedBox(width: size, height: size);
        }
        // Tamaño continuo acotado sobre el size base.
        final scaledSize = size * controller.sizeMultiplier;
        final companion = controller.activeCompanion;
        if (companion == null) {
          // Activada pero sin mascota válida seleccionada → Spark por defecto.
          return _labeled(context, _fallback(scaledSize));
        }
        return _labeled(
          context,
          SpritesheetRenderer(
            companion: companion,
            state: companionStateForMood(mood),
            size: scaledSize,
            replayToken: replayToken,
            animate: animate,
            speedMultiplier: controller.animationSpeed,
          ),
        );
      },
    );
  }

  Widget _labeled(BuildContext context, Widget child) => Semantics(
    label:
        Localizations.of<Strings>(context, Strings)?.companionAnimatedLabel ??
        'Companion animado',
    image: true,
    child: child,
  );

  // El Spark es un placeholder discreto: se renderiza reducido respecto al
  // tamaño pedido para no dominar la pantalla cuando no hay sprite.
  Widget _fallback(double s) => HermesSparkMascot(
    mood: mood,
    size: s * 0.6,
    accent: accent,
    animate: animate,
  );
}
