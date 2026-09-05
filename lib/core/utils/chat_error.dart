import 'package:flutter/material.dart';

/// Categorías de error del chat, usadas para mostrar título, pista e icono
/// adecuados al tipo real de fallo — sin mezclar errores de credenciales con
/// errores locales ni timeouts locales con errores de API.
enum ChatErrorKind {
  connection,
  model,
  tool,
  local,
  localColdStart,
  firstTokenTimeout,
  searchToolUnavailable,
  unknown,
}

extension ChatErrorKindMeta on ChatErrorKind {
  IconData get icon => switch (this) {
        ChatErrorKind.connection => Icons.wifi_off_rounded,
        ChatErrorKind.model => Icons.cloud_off_rounded,
        ChatErrorKind.tool => Icons.build_circle_outlined,
        ChatErrorKind.local => Icons.phonelink_erase_outlined,
        ChatErrorKind.localColdStart => Icons.hourglass_empty_rounded,
        ChatErrorKind.firstTokenTimeout => Icons.hourglass_empty_rounded,
        ChatErrorKind.searchToolUnavailable => Icons.search_off_rounded,
        ChatErrorKind.unknown => Icons.error_outline_rounded,
      };
}

/// Clasifica un string de error en una categoría accionable para la UI.
///
/// ORDEN CRÍTICO: los checks de local deben ir ANTES que el check de model,
/// porque la palabra española "modelo" contiene el substring inglés "model"
/// y clasificaría erróneamente timeouts locales como errores de API/credenciales.
ChatErrorKind classifyChatError(String raw) {
  final e = raw.toLowerCase();
  bool has(List<String> needles) => needles.any(e.contains);

  // 1a. Primer token no llegó en tiempo (remoto): emitido por el timer de
  //     active_chat_service.dart. Prefijo "firstTokenTimeout:" garantiza detección.
  if (e.startsWith('firsttokentimeout:') || has(['firsttokentimeout'])) {
    return ChatErrorKind.firstTokenTimeout;
  }

  // 1b. Search tool no disponible: emitido por el gateway o detectado por texto.
  if (has([
    'search tool unavailable',
    'searchtoolavailable',
    'no search tool',
    'search tool not found',
    'web search not available',
    'search unavailable',
    // Transcripts guardados por builds anteriores siguen en español.
    'búsqueda no disponible',
    'herramienta de búsqueda no',
    'no tiene herramienta de búsqueda',
  ])) {
    return ChatErrorKind.searchToolUnavailable;
  }

  // 1c. Modelo local en arranque en frío / primer token tardando.
  //    Generado por _humanizeBridgeError en active_chat_service.dart.
  if (has([
    'took too long',
    'still be loading',
    'timed out',
    'local model loading',
    'cold start',
    'first token',
    // Transcripts guardados por builds anteriores siguen en español.
    'tardó demasiado',
    'cargándose',
  ])) {
    return ChatErrorKind.localColdStart;
  }

  // 2. Agente local caído / bridge no disponible (ANTES que model).
  if (has([
    'bridge',
    'local agent',
    'localhost',
    '127.0.0.1',
    '10.0.2.2',
    'the process exited',
    'start the agent',
    'could not connect to the local agent',
    'mobile bridge',
    'out of memory',
    // Transcripts guardados por builds anteriores siguen en español.
    'agente local',
    'proceso se cerró',
    'arranca el agente',
    'no se pudo conectar con el agente',
    'falta de memoria',
  ])) {
    return ChatErrorKind.local;
  }

  // 3. Errores de red / conectividad.
  if (has([
    'socketexception',
    'connection refused',
    'connection reset',
    'failed host lookup',
    'timeout',
    'unreachable',
    'handshake',
    'certificate',
    'no route to host',
  ])) {
    return ChatErrorKind.connection;
  }

  // 4. Errores de modelo / API / credenciales (solo aquí llega "model" en inglés).
  if (has([
    '401',
    '403',
    '429',
    'unauthorized',
    'forbidden',
    'rate limit',
    'quota',
    'api key',
    'invalid key',
    'model not found',
    'model',
    'overloaded',
  ])) {
    return ChatErrorKind.model;
  }

  // 5. Errores de herramienta / aprobación.
  if (has(['tool', 'approval', 'command failed', 'exit code'])) {
    return ChatErrorKind.tool;
  }

  return ChatErrorKind.unknown;
}
