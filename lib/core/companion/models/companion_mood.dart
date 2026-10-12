/// Estado de ánimo de la presencia del Companion. Mapea estados reales de la
/// app (conexión, chat pensando, diagnóstico, etc.) y lo interpretan tanto la
/// mascota instalada (spritesheet) como la cara original del perfil cuando no
/// hay mascota.
enum CompanionMood {
  idle,
  thinking,
  connecting,
  success,
  error,
  offline,
  waiting,

  /// Gesto breve de salto (p. ej. al enviar un mensaje). Transitorio.
  jump,
}
