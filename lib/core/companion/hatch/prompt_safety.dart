/// Moderación mínima del prompt de "Hatch" (cosmético).
///
/// No pretende ser un filtro completo: bloquea términos manifiestamente
/// inapropiados y normaliza el texto, para evitar generar contenido fuera del
/// tono cosmético de la app. Función pura y testeable (sin red, sin estado).
class PromptSafety {
  const PromptSafety();

  /// Longitud máxima razonable de un prompt cosmético.
  static const int maxLength = 300;

  /// Raíces de términos bloqueados (cosmético seguro). Lista corta y conservadora.
  static const List<String> _blocked = [
    'nsfw', 'nude', 'naked', 'sex', 'porn', 'gore', 'blood', 'nazi',
    'desnud', 'sangre', 'sexual', 'porno',
  ];

  /// Devuelve el prompt saneado (recortado/normalizado) o lanza
  /// [PromptRejectedException] si está vacío, es demasiado largo o contiene
  /// términos bloqueados.
  String sanitize(String raw) {
    final trimmed = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (trimmed.isEmpty) {
      throw PromptRejectedException('Write a description for your pet.');
    }
    if (trimmed.length > maxLength) {
      throw PromptRejectedException('The description is too long.');
    }
    final lower = trimmed.toLowerCase();
    for (final term in _blocked) {
      if (lower.contains(term)) {
        throw PromptRejectedException(
            'That description is not allowed. Try something cosmetic.');
      }
    }
    return trimmed;
  }

  /// Variante no lanzante: `true` si el prompt es aceptable.
  bool isAcceptable(String raw) {
    try {
      sanitize(raw);
      return true;
    } on PromptRejectedException {
      return false;
    }
  }
}

/// El prompt fue rechazado por la moderación mínima.
class PromptRejectedException implements Exception {
  final String message;
  PromptRejectedException(this.message);

  @override
  String toString() => 'PromptRejectedException: $message';
}
