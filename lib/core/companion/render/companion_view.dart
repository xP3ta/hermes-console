import 'package:flutter/material.dart';

import '../../services/bot_roster_store.dart';
import '../models/companion_animation_state.dart';
import '../models/companion_mood.dart';
import '../state/companion_controller.dart';
import 'companion_face.dart';
import 'spritesheet_renderer.dart';
import '../../../l10n/app_localizations.dart';

/// Punto único de render de la mascota.
///
/// Si hay un [CompanionController] con una mascota activa y válida, renderiza el
/// [SpritesheetRenderer]; en cualquier otro caso (controller ausente, mascota
/// desactivada, slug inválido o nulo) pinta la cara original del perfil activo
/// ([CompanionProfileFace]): foto propia > cara del bot > cara de Hermes.
class CompanionView extends StatelessWidget {
  final CompanionMood mood;
  final double size;
  final CompanionController? controller;

  /// Acento heredado de las superficies; los sprites y las caras de perfil
  /// tienen sus propios colores.
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
    this.mood = CompanionMood.idle,
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
        // Desactivada: no se muestra NINGUNA mascota (ni la cara de reserva).
        // Se reserva el espacio base para no descuadrar el layout.
        if (!controller.enabled) {
          return SizedBox(width: size, height: size);
        }
        // Tamaño continuo acotado sobre el size base.
        final scaledSize = size * controller.sizeMultiplier;
        final companion = controller.activeCompanion;
        if (companion == null) {
          // Activada pero sin mascota válida → la cara original del perfil.
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

  // La cara ocupa su caja entera (un sprite deja aire transparente), así que
  // se reduce para no dominar la superficie cuando no hay mascota.
  Widget _fallback(double s) => CompanionProfileFace(
    controller: controller,
    mood: mood,
    size: s * kCompanionFaceScale,
    animate: animate,
  );
}

/// Fracción del hueco de la mascota que ocupa la cara de reserva.
const kCompanionFaceScale = 0.6;

/// La cara original del perfil del ámbito de [controller] (conexión + perfil
/// activos), con su foto o su forma del roster compartido cuando se conocen.
/// Sin controller o sin ámbito, la cara estándar de Hermes.
class CompanionProfileFace extends StatelessWidget {
  final CompanionController? controller;
  final CompanionMood mood;
  final double size;
  final bool animate;

  /// Roster con los metadatos del perfil (forma, foto); el compartido de la
  /// app por defecto.
  final BotRosterRegistry? roster;

  const CompanionProfileFace({
    super.key,
    required this.controller,
    this.mood = CompanionMood.idle,
    this.size = 44,
    this.animate = true,
    this.roster,
  });

  @override
  Widget build(BuildContext context) {
    final scope = controller?.scope;
    if (scope == null) {
      return CompanionFace(mood: mood, size: size, animate: animate);
    }
    final store = (roster ?? BotRosterRegistry.shared).store(scope.connId);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => CompanionFace(
        profileName: scope.profileId,
        profile: store.profile(scope.profileId),
        avatarCache: controller!.avatarCacheFor(scope.connId),
        mood: mood,
        size: size,
        animate: animate,
      ),
    );
  }
}
