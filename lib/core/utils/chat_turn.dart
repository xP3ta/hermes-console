final RegExp _asyncDelegationMarkerPattern = RegExp(
  r'^\[ASYNC DELEGATION BATCH COMPLETE — deleg_[0-9a-f]{8}\](?:\r?\n|$)',
);

/// True únicamente para mensajes enviados realmente por el usuario.
///
/// Hermes puede persistir metadatos de runtime como `role=user` para mantener
/// compatibilidad con proveedores estrictos. Esas filas no cuentan para los
/// ordinales de rewind ni para decidir cuál fue el último prompt real.
bool isRealUserTurn(Map<String, dynamic> message) {
  if (message['role'] != 'user' || message['_steer'] == true) return false;

  return effectiveUserDisplayKind(message).isEmpty;
}

/// Devuelve la clase editorial efectiva de una fila `role=user`.
///
/// REST 0.19 omite `display_kind`; los markers abren con sentinelas estables
/// generados por Hermes. Reconocer únicamente esos prefijos mantiene el fallo
/// cerrado durante la hidratación sin reinterpretar texto normal del usuario.
String effectiveUserDisplayKind(Map<String, dynamic> message) {
  final displayKind = message['display_kind']?.toString().trim() ?? '';
  if (displayKind.isNotEmpty) return displayKind;
  if (message['role'] != 'user' || message['_steer'] == true) return '';

  final rawContent = (message['content'] ?? message['text'] ?? '').toString();
  if (_asyncDelegationMarkerPattern.hasMatch(rawContent)) {
    return 'async_delegation_complete';
  }
  final content = rawContent.trimLeft().toLowerCase();
  final isLegacyModelSwitch =
      content.startsWith('[system:') &&
      content.contains('active model') &&
      content.contains('changed');
  return isLegacyModelSwitch ? 'model_switch' : '';
}

/// Ordinal alternativo para el bug de Hermes que fusiona
/// `model_switch + siguiente prompt` al reparar una secuencia `user;user`.
///
/// El cliente Desktop cuenta únicamente los turnos de usuario visibles. El
/// backend también excluye `display_kind`, pero antes puede fusionar mensajes
/// `user` contiguos conservando el `display_kind` del primero. En ese caso el
/// prompt real inmediatamente posterior a `model_switch` desaparece del
/// espacio de ordinales del runtime y los turnos posteriores quedan desplazados.
///
/// Devuelve un ordinal únicamente para el último prompt real, cuando el patrón
/// exacto ya se observó y el objetivo sigue siendo un turno independiente. Es
/// un fallback para un `4018` seguro; nunca debe sustituir el primer intento con
/// la semántica normal de Hermes Desktop.
int? modelSwitchRepairFallbackOrdinal(
  List<Map<String, dynamic>> newestFirst,
  Map<String, dynamic> target, {
  required int desktopOrdinal,
}) {
  Map<String, dynamic>? latestRealUser;
  for (final message in newestFirst) {
    if (isRealUserTurn(message)) {
      latestRealUser = message;
      break;
    }
  }
  if (!identical(latestRealUser, target)) return null;

  var repairedOrdinal = 0;
  var previousWasUser = false;
  var runStartsWithModelSwitch = false;
  var sawCollapsedModelPrompt = false;

  for (var index = newestFirst.length - 1; index >= 0; index--) {
    final message = newestFirst[index];
    if (message['_steer'] == true) continue;

    if (message['role'] != 'user') {
      previousWasUser = false;
      runStartsWithModelSwitch = false;
      continue;
    }

    final displayKind = effectiveUserDisplayKind(message);
    if (!previousWasUser) {
      previousWasUser = true;
      runStartsWithModelSwitch = displayKind == 'model_switch';

      if (identical(message, target)) {
        if (displayKind.isNotEmpty || !sawCollapsedModelPrompt) return null;
        return repairedOrdinal < desktopOrdinal ? repairedOrdinal : null;
      }

      if (displayKind.isEmpty) repairedOrdinal++;
      continue;
    }

    if (runStartsWithModelSwitch && isRealUserTurn(message)) {
      sawCollapsedModelPrompt = true;
    }
    // Hermes ya fusionó este mensaje con el primero del bloque; no existe un
    // ordinal seguro que permita seleccionar solo este turno.
    if (identical(message, target)) return null;
  }

  return null;
}
