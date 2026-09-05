// Small value types shared across the chat pipeline: lifecycle states, the
// event enum the UI listens to, and transcript projection helpers.
part of 'active_chat_service.dart';

/// Estados del pipeline del chat — solo estados respaldados por señales reales.
///
///   idle        — sin petición activa
///   connecting  — petición HTTP enviada, esperando cabeceras del servidor
///   waiting     — HTTP 200 recibido (onConnected), aún sin token/herramienta
///   executing   — llegan frames hermes.tool.progress (onToolProgress)
///   streaming   — llegan tokens de contenido (onToken)
///   completed   — onDone recibido, mensajes refrescados
///   failed      — onError recibido; error guardado en el mensaje assistant_error
///   cancelled   — el usuario tocó parar; contenido parcial preservado
enum ChatPipelineState {
  idle,
  connecting,
  waiting,
  executing,
  streaming,
  completed,
  failed,
  cancelled,
}

/// Estado compacto y comprobable que otras superficies pueden mostrar sin
/// interpretar mensajes del modelo ni inventar progreso.
enum ChatActivityKind { thinking, usingTools, responding, awaitingApproval }

/// Tipo de cambio emitido por un [ActiveChat] hacia sus oyentes (la pantalla).
enum ActiveChatEvent {
  started,
  connected,
  waiting,
  messagesHydrated,
  earlierMessagesLoaded,
  responseMetrics,
  token,
  toolProgress,
  approvalRequest,
  interactiveRequest,
  sessionInfo,
  subagentActivity,
  done,
  error,
  cancelled,
  queueChanged,
}

Future<({Object? error, T? value})> _captureAsync<T>(
  Future<T> Function() operation,
) async {
  try {
    return (error: null, value: await operation());
  } catch (error) {
    return (error: error, value: null);
  }
}

typedef SteerProjection = ({int anchorUserOrdinal, String content});

typedef StoredSessionMessageLoader =
    Future<List<Map<String, dynamic>>> Function(
      String sessionId,
      String profile,
    );

/// Proyección oral monotónica del turno actual.
///
/// Es deliberadamente independiente de [ActiveChat.messages]: el transcript
/// puede reconciliar o reemplazar un `message.interim`, pero el audio que ya se
/// aceptó no puede des-oírse. Solo entran eventos assistant naturales; tools,
/// logs, reasoning y resultados técnicos nunca llaman a este colector.
class _AssistantNarrationProjection {
  String _content = '';

  String get content => _content;

  void reset() => _content = '';

  void appendDelta(String value) {
    if (value.isEmpty) return;
    // `message.delta` es una pieza nueva, no un snapshot acumulado. Aplicar
    // dedupe aquí perdería repeticiones legítimas ("ja" + " ja"). La
    // reconciliación pertenece solo a interim/final, que sí son autoritativos.
    _content += value;
  }

  void sealInterim(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    _content = _appendWithOverlap(_content, trimmed);
  }

  void settleFinal(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return;
    _content = _appendWithOverlap(_content, trimmed);
  }

  static String _appendWithOverlap(String current, String incoming) {
    if (current.isEmpty) return incoming;
    if (incoming.isEmpty || current.endsWith(incoming)) return current;
    if (incoming.startsWith(current)) return incoming;

    // Un final puede decorar delante de un cuerpo ya aceptado ("¡Listo! …").
    // Si el cuerpo completo reaparece de forma inequívoca, conserva lo ya
    // narrado y añade únicamente su cola autoritativa.
    if (current.length >= 48 &&
        current.trim().split(RegExp(r'\s+')).length >= 6) {
      final acceptedStart = incoming.indexOf(current);
      if (acceptedStart >= 0) {
        final acceptedEnd = acceptedStart + current.length;
        return current + incoming.substring(acceptedEnd);
      }
    }

    final lastBoundary = current.lastIndexOf('\n\n');
    final lastSegment = lastBoundary < 0
        ? current
        : current.substring(lastBoundary + 2);
    if (lastSegment.isNotEmpty && incoming.startsWith(lastSegment)) {
      return current + incoming.substring(lastSegment.length);
    }

    final limit = current.length < incoming.length
        ? current.length
        : incoming.length;
    var overlap = 0;
    for (var length = limit; length >= 8; length--) {
      if (current.substring(current.length - length) ==
          incoming.substring(0, length)) {
        overlap = length;
        break;
      }
    }
    if (overlap > 0) return current + incoming.substring(overlap);

    final separator =
        RegExp(r'\s$').hasMatch(current) || RegExp(r'^\s').hasMatch(incoming)
        ? ''
        : '\n\n';
    return '$current$separator$incoming';
  }
}

enum _TranscriptExtent { unknown, partial, complete }

enum _HydrationTailStatus { incomplete, partial, complete }

const _terminalProjectionIdKey = '_localTerminalProjectionId';
const _terminalProjectionAnchorKey = '_localTerminalAnchorMessageId';
const _terminalProjectionAnchorRowKey = '_localTerminalAnchorRowId';
const _terminalProjectionAnchorOrdinalKey = '_localTerminalOrdinalAfterAnchor';
const _terminalProjectionAbsoluteOrdinalKey =
    '_localTerminalAbsoluteUserOrdinal';
const _stopProofAnchorMessageIdKey = '_localStopProofAnchorMessageId';
const _stopProofAnchorRowIdKey = '_localStopProofAnchorRowId';

class _TerminalProjectionFence {
  const _TerminalProjectionFence({
    required this.projectionId,
    required this.userMessageId,
    required this.userRowId,
    required this.anchorMessageId,
    required this.anchorRowId,
    required this.ordinalAfterAnchor,
    required this.absoluteUserOrdinal,
    required this.localAssistantText,
  });

  final String projectionId;
  final String? userMessageId;
  final int? userRowId;
  final String? anchorMessageId;
  final int? anchorRowId;
  final int? ordinalAfterAnchor;
  final int? absoluteUserOrdinal;
  final String? localAssistantText;
}

typedef _TerminalTurnEvidence = ({
  bool complete,
  List<int> projectionIndices,
  String? assistantText,
});

typedef _RefreshedTranscriptGraft = ({
  List<Map<String, dynamic>> messages,
  bool preservesExistingCoverage,
  bool acceptedRefreshed,
  bool retainsExistingRows,
  List<TranscriptMessageIdentity> unconfirmedRetainedIdentities,
});
