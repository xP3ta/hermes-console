final RegExp _asyncDelegationMarkerPattern = RegExp(
  r'^\[ASYNC DELEGATION (?:BATCH )?COMPLETE — deleg_[0-9a-f]{8}\](?:\r?\n|$)',
);

/// Las dos coordenadas durables que Hermes puede exponer para una misma fila.
///
/// `messageId` y `rowId` viven en espacios de nombres distintos. Una identidad
/// enriquecida puede llevar ambas; una proyección REST o Desktop puede llevar
/// solo una. Dos identidades coinciden si comparten al menos una coordenada
/// exacta y ninguna coordenada que ambas declaren se contradice.
class TranscriptMessageIdentity {
  const TranscriptMessageIdentity({this.messageId, this.rowId});

  final String? messageId;
  final int? rowId;

  bool get isDurable => messageId != null || rowId != null;

  bool sharesExactCoordinate(TranscriptMessageIdentity other) =>
      (messageId != null && messageId == other.messageId) ||
      (rowId != null && rowId == other.rowId);

  bool conflictsWith(TranscriptMessageIdentity other) =>
      (messageId != null &&
          other.messageId != null &&
          messageId != other.messageId &&
          rowId != null &&
          rowId == other.rowId) ||
      (rowId != null &&
          other.rowId != null &&
          rowId != other.rowId &&
          messageId != null &&
          messageId == other.messageId);

  bool matches(TranscriptMessageIdentity other) =>
      sharesExactCoordinate(other) && !conflictsWith(other);
}

/// Extrae la identidad tipada sin recortar ni convertir valores.
///
/// Más de un valor válido distinto dentro del mismo canal es evidencia
/// contradictoria: toda la identidad falla cerrada en vez de escoger el primer
/// alias. Los aliases ausentes o de otro tipo simplemente no aportan evidencia.
TranscriptMessageIdentity? canonicalTranscriptIdentity(
  Map<String, dynamic> message,
) {
  final messageIds = <String>{};
  for (final key in const ['_desktopMessageId', 'message_id', 'id']) {
    final raw = message[key];
    if (raw is String && raw.isNotEmpty) messageIds.add(raw);
  }
  final rowIds = <int>{};
  for (final key in const ['_desktopRowId', 'row_id', '_row_id', 'id']) {
    final raw = message[key];
    if (raw is int && raw > 0) rowIds.add(raw);
  }
  if (messageIds.length > 1 || rowIds.length > 1) return null;
  final identity = TranscriptMessageIdentity(
    messageId: messageIds.firstOrNull,
    rowId: rowIds.firstOrNull,
  );
  return identity.isDurable ? identity : null;
}

/// Distingue una fila sin identidad (válida pero no direccionable) de una fila
/// que declara aliases incompatibles entre sí.
bool transcriptIdentityAliasesAreConsistent(Map<String, dynamic> message) {
  final messageIds = <String>{};
  for (final key in const ['_desktopMessageId', 'message_id', 'id']) {
    final raw = message[key];
    if (raw is String && raw.isNotEmpty) messageIds.add(raw);
  }
  final rowIds = <int>{};
  for (final key in const ['_desktopRowId', 'row_id', '_row_id', 'id']) {
    final raw = message[key];
    if (raw is int && raw > 0) rowIds.add(raw);
  }
  return messageIds.length <= 1 && rowIds.length <= 1;
}

/// Comprueba coordenadas declaradas incluso cuando sus aliases internos son
/// contradictorios y [canonicalTranscriptIdentity] debe fallar cerrado.
///
/// Sirve para no ignorar evidencia ambigua: una fila inválida que reclama la
/// misma coordenada que un ancla impide escoger otra coincidencia aparente.
bool transcriptIdentityAliasesShareExactCoordinate(
  Map<String, dynamic> message,
  TranscriptMessageIdentity identity,
) {
  final messageId = identity.messageId;
  if (messageId != null) {
    for (final key in const ['_desktopMessageId', 'message_id', 'id']) {
      if (message[key] == messageId) return true;
    }
  }
  final rowId = identity.rowId;
  if (rowId != null) {
    for (final key in const ['_desktopRowId', 'row_id', '_row_id', 'id']) {
      if (message[key] == rowId) return true;
    }
  }
  return false;
}

/// Identidad durable y opaca compartida por transcript, refresh y recovery.
///
/// Desktop proyecta `message_id`/`id` como `_desktopMessageId`; Console y REST
/// pueden conservar cualquiera de los otros aliases. El valor se devuelve
/// exactamente como llegó: no se recorta, normaliza ni infiere una equivalencia
/// cuando ninguno de los campos está presente.
String? canonicalTranscriptMessageId(Map<String, dynamic> message) {
  return canonicalTranscriptIdentity(message)?.messageId;
}

/// Identidad durable de la fila SQLite que Hermes expone en sus dos
/// superficies de historial.
///
/// `session.resume` la proyecta como `_desktopRowId`/`row_id`, mientras el
/// endpoint REST usa `id` numérico. Se conserva como [int]: convertirlo a
/// string haría que la fila `42` pareciese el message-id opaco `"42"`, una
/// equivalencia que el protocolo nunca afirmó.
int? canonicalTranscriptRowId(Map<String, dynamic> message) {
  return canonicalTranscriptIdentity(message)?.rowId;
}

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
  if (message['role'] != 'user' ||
      message['_steer'] == true ||
      message['_optimistic'] == true) {
    return '';
  }

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
