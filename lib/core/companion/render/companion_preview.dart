import 'package:flutter/material.dart';

import '../models/companion.dart';
import '../models/companion_animation_state.dart';
import '../state/companion_controller.dart';
import 'companion_view.dart';
import 'spritesheet_renderer.dart';

/// Render estático de una mascota **concreta** (en estado `idle`), independiente
/// del [CompanionController] y de si la mascota está activada.
///
/// Se usa en la UI de selección (Settings → Apariencia): cada fila muestra SU
/// propia mascota, y `null` representa la opción por defecto: la cara
/// original del perfil activo.
class CompanionPreview extends StatelessWidget {
  /// Mascota a previsualizar; `null` → la cara del perfil (opción por defecto).
  final Companion? companion;
  final double size;
  final Color? accent;

  /// Ámbito (conexión + perfil) cuya cara se previsualiza para `null`.
  final CompanionController? controller;

  const CompanionPreview({
    super.key,
    required this.companion,
    this.size = 40,
    this.accent,
    this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final companion = this.companion;
    if (companion == null) {
      return CompanionProfileFace(
        controller: controller,
        size: size,
        animate: false,
      );
    }
    return SpritesheetRenderer(
      companion: companion,
      state: CompanionAnimationState.idle,
      size: size,
      // Un selector puede montar muchas filas. Su contrato es una miniatura
      // estática, no una cuadrícula de timers en segundo plano.
      animate: false,
    );
  }
}
