import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/hermes_premium_ui.dart';
import '../../widgets/hermes_spark_mascot.dart';
import '../models/companion_animation_state.dart';
import '../models/companion_presence_level.dart';
import '../state/companion_controller.dart';
import 'companion_view.dart';
import '../../../l10n/app_localizations.dart';

void showCompanionActionsSheet({
  required BuildContext context,
  required CompanionController? controller,
  required VoidCallback onOpenMascotas,
}) {
  final colors = Theme.of(context).hermes;
  showHermesFloatingSurface<void>(
    context: context,
    surfaceKey: const ValueKey('companion-actions-surface'),
    maxWidth: 420,
    maxHeightFactor: 0.72,
    builder: (sheetCtx) => SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(Icons.swap_horiz, color: colors.accent),
            title: Text(
              Localizations.of<Strings>(context, Strings)?.mascotChange ??
                  'Cambiar mascota',
              style: TextStyle(color: colors.textPrimary),
            ),
            onTap: () {
              Navigator.pop(sheetCtx);
              onOpenMascotas();
            },
          ),
          ListTile(
            leading: Icon(
              Icons.visibility_off_outlined,
              color: colors.textSecondary,
            ),
            title: Text(
              Localizations.of<Strings>(context, Strings)?.mascotTurnOff ??
                  'Apagar mascota',
              style: TextStyle(color: colors.textPrimary),
            ),
            onTap: () {
              controller?.setEnabled(false);
              Navigator.pop(sheetCtx);
            },
          ),
          ListTile(
            leading: Icon(Icons.pets_outlined, color: colors.accent),
            title: Text(
              Localizations.of<Strings>(context, Strings)?.mascotOpenPets ??
                  'Abrir Mascotas',
              style: TextStyle(color: colors.textPrimary),
            ),
            onTap: () {
              Navigator.pop(sheetCtx);
              onOpenMascotas();
            },
          ),
        ],
      ),
    ),
  );
}

/// Mascota del Home con interacción (Fase B / US3).
///
/// Envuelve [CompanionView] (sin modificar el widget compartido) y añade:
/// - **Tap / long-press** → menú para cambiar, apagar o abrir Mascotas.
/// - **Double-tap** → animación lúdica de saludo (`wave`), reproducida pasando un
///   `mood` transitorio `success` (que el mapeo de Fase A traduce a `wave`) y
///   revirtiendo al estado real tras un instante. Se omite con *reduce-motion*.
///
/// Cuando el Companion está **desactivado** o su presencia está en `off`, no se
/// pinta mascota y **no** se instala ningún objetivo táctil (sin zonas táctiles
/// invisibles).
class CompanionHomeMascot extends StatefulWidget {
  /// Controller global (puede ser null → cae a Spark sin interacción de sheet).
  final CompanionController? controller;

  /// Estado base derivado de la conexión (idle/connecting/offline…).
  final HermesSparkMood baseMood;
  final double size;
  final Color accent;

  /// Acción para "Cambiar mascota" / "Abrir Mascotas" (el Home navega a la
  /// pantalla Mascotas). Inyectable para tests.
  final VoidCallback onOpenMascotas;

  /// Etiqueta del atajo del Home para TalkBack. Se aplica dentro del mismo
  /// árbol que controla la visibilidad, de modo que `presenceLevel.off` no deje
  /// un botón semántico invisible alrededor del saludo.
  final String? semanticLabel;

  const CompanionHomeMascot({
    super.key,
    required this.controller,
    required this.baseMood,
    required this.size,
    required this.accent,
    required this.onOpenMascotas,
    this.semanticLabel,
  });

  @override
  State<CompanionHomeMascot> createState() => _CompanionHomeMascotState();
}

class _CompanionHomeMascotState extends State<CompanionHomeMascot> {
  /// Mood transitorio del saludo (success → wave); `null` = estado base.
  HermesSparkMood? _transient;

  /// Único timer de reversión activo (nunca se acumulan).
  Timer? _timer;

  /// Generación del saludo. Cada tap aceptado la incrementa: invalida timers
  /// antiguos (la reversión solo aplica si su generación sigue vigente) y, vía
  /// `replayToken`, reinicia la animación de saludo desde el frame 0 aunque ya
  /// se esté reproduciendo (tap repetido = vuelve a saludar, sin parpadeo).
  int _waveGen = 0;

  /// Momento del último saludo aceptado, para la ventana de enfriamiento.
  DateTime? _lastWaveAt;

  /// Ventana corta que coalesce el "tap spam": taps dentro de ella se ignoran,
  /// así la animación avanza de forma visible en vez de reiniciarse sin parar.
  static const Duration _cooldown = Duration(milliseconds: 300);

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  /// Duración real del saludo a partir de los frames/fps de la mascota activa;
  /// cae a un valor por defecto razonable para el fallback (Spark).
  Duration _waveDuration() {
    final companion = widget.controller?.activeCompanion;
    final row = companion?.states[CompanionAnimationState.wave];
    if (companion != null && row != null) {
      final ms = ((row.frameCount / companion.fps) * 1000).round();
      // Margen mínimo para que un saludo muy corto siga siendo perceptible.
      return Duration(milliseconds: ms.clamp(500, 4000));
    }
    return const Duration(milliseconds: 900);
  }

  void _playWave() {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) return; // accesibilidad: sin animación lúdica

    final now = DateTime.now();
    final last = _lastWaveAt;
    if (last != null && now.difference(last) < _cooldown) {
      return; // dentro del enfriamiento: se ignora para no churn-ear setState
    }
    _lastWaveAt = now;

    final gen = ++_waveGen;
    setState(() => _transient = HermesSparkMood.success); // success → wave
    _timer?.cancel();
    _timer = Timer(_waveDuration(), () {
      // Solo revierte si sigue siendo la última generación y el widget vive:
      // un timer viejo no puede apagar un saludo más reciente ni tocar un
      // State ya desmontado.
      if (mounted && gen == _waveGen) setState(() => _transient = null);
    });
  }

  void _openSheet() {
    showCompanionActionsSheet(
      context: context,
      controller: widget.controller,
      onOpenMascotas: widget.onOpenMascotas,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller == null) {
      // Sin controller: solo render (Spark), sin sheet ni interacción.
      final view = CompanionView(
        controller: null,
        mood: _transient ?? widget.baseMood,
        size: widget.size,
        accent: widget.accent,
        replayToken: _waveGen,
      );
      return _withSemantics(view);
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        // `presenceLevel.off` debe ocultar también la presencia grande del Home,
        // no solo desactivar sus cambios de ánimo. Se comprueba dentro del
        // AnimatedBuilder para que el selector de Mascotas lo aplique al instante.
        if (!controller.isInitialized ||
            !controller.enabled ||
            controller.roamingEnabled ||
            !controller.presenceLevel.isVisible) {
          return const SizedBox.shrink();
        }
        final view = CompanionView(
          controller: controller,
          mood: _transient ?? widget.baseMood,
          size: widget.size,
          accent: widget.accent,
          replayToken: _waveGen,
        );
        final interactive = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _openSheet,
          onDoubleTap: _playWave,
          onLongPress: _openSheet,
          child: view,
        );
        return _withSemantics(interactive);
      },
    );
  }

  Widget _withSemantics(Widget child) {
    final label = widget.semanticLabel;
    if (label == null || label.isEmpty) return child;
    return Semantics(
      button: true,
      label: label,
      onTap: _openSheet,
      child: ExcludeSemantics(child: child),
    );
  }
}
