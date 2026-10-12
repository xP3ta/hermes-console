import 'companion_mood.dart';

/// Estados de animación de una mascota "Companion", alineados con el formato
/// Petdex. En Fase A se usan idle/run/waiting/wave/failed; `review` y `jump`
/// quedan reservados para Fase B (el modelo los admite, pero no se mapean aún).
///
/// Ver docs/PETDEX_CONTRACT.md.
enum CompanionAnimationState {
  idle,
  run,
  review,
  waiting,
  wave,
  jump,
  failed,
}

extension CompanionAnimationStateX on CompanionAnimationState {
  /// Identificador estable usado en pet.json (== nombre del enum).
  String get id => name;

  /// Estados que ciclan por defecto (idle/run/waiting) frente a los one-shot
  /// (wave/jump/failed/review), que se reproducen una vez y vuelven a idle.
  bool get loopsByDefault =>
      this == CompanionAnimationState.idle ||
      this == CompanionAnimationState.run ||
      this == CompanionAnimationState.waiting;
}

/// Mapea el estado visual de la app (`CompanionMood`) al estado de animación
/// de la mascota. Tabla fijada en data-model.md (Clarifications 2026-06-25):
///
/// idle→idle, thinking→run, connecting→waiting, waiting→waiting,
/// success→wave, error→failed, offline→idle.
CompanionAnimationState companionStateForMood(CompanionMood mood) {
  switch (mood) {
    case CompanionMood.idle:
      return CompanionAnimationState.idle;
    case CompanionMood.thinking:
      return CompanionAnimationState.run;
    case CompanionMood.connecting:
      return CompanionAnimationState.waiting;
    case CompanionMood.waiting:
      return CompanionAnimationState.waiting;
    case CompanionMood.success:
      return CompanionAnimationState.wave;
    case CompanionMood.error:
      return CompanionAnimationState.failed;
    case CompanionMood.offline:
      return CompanionAnimationState.idle;
    case CompanionMood.jump:
      return CompanionAnimationState.jump;
  }
}

/// Convierte un identificador de estado (de pet.json) al enum, o `null` si no
/// corresponde a ningún estado conocido (parseo tolerante).
CompanionAnimationState? companionStateFromId(String id) {
  for (final state in CompanionAnimationState.values) {
    if (state.name == id) return state;
  }
  return null;
}
