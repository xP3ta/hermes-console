// Value types for the chat render pipeline: assistant body chunks, the
// cached render plan and the list-entry projection the ListView consumes.
part of 'chat_screen.dart';

sealed class _AssistantBodyChunk {
  const _AssistantBodyChunk();
}

final class _AssistantMarkdownChunk extends _AssistantBodyChunk {
  final String data;

  const _AssistantMarkdownChunk(this.data);
}

final class _AssistantGeneratedImageChunk extends _AssistantBodyChunk {
  final String basename;

  const _AssistantGeneratedImageChunk(this.basename);
}

final class _AssistantRenderPlan {
  final String sourceContent;
  final ReasoningSplit split;
  final List<_AssistantBodyChunk> chunks;

  const _AssistantRenderPlan({
    required this.sourceContent,
    required this.split,
    required this.chunks,
  });
}

final class _CachedAssistantRenderPlan {
  final _AssistantRenderPlan? plan;

  const _CachedAssistantRenderPlan(this.plan);
}

final class _AssistantRenderSlice {
  final _AssistantRenderPlan plan;
  final int index;

  const _AssistantRenderSlice(this.plan, this.index);

  _AssistantBodyChunk get body => plan.chunks[index];
  bool get showHeader => index == 0;
  bool get showFooter => index == plan.chunks.length - 1;
}

final class _AssistantTerminalProjectionKey {
  final String sourceContent;
  final String sliceKey;
  final bool suggestionsEnabled;

  const _AssistantTerminalProjectionKey({
    required this.sourceContent,
    required this.sliceKey,
    required this.suggestionsEnabled,
  });

  @override
  bool operator ==(Object other) =>
      other is _AssistantTerminalProjectionKey &&
      other.sourceContent == sourceContent &&
      other.sliceKey == sliceKey &&
      other.suggestionsEnabled == suggestionsEnabled;

  @override
  int get hashCode => Object.hash(sourceContent, sliceKey, suggestionsEnabled);
}

sealed class _ProjectedAssistantBlock {
  const _ProjectedAssistantBlock();
}

final class _ProjectedAssistantMarkdown extends _ProjectedAssistantBlock {
  final String data;
  const _ProjectedAssistantMarkdown(this.data);
}

final class _ProjectedAssistantTable extends _ProjectedAssistantBlock {
  final List<List<String>> rows;
  const _ProjectedAssistantTable(this.rows);
}

final class _ProjectedAssistantImage extends _ProjectedAssistantBlock {
  final String basename;
  const _ProjectedAssistantImage(this.basename);
}

final class _ProjectedAssistantGap extends _ProjectedAssistantBlock {
  const _ProjectedAssistantGap();
}

final class _AssistantTerminalProjection {
  final ReasoningSplit split;
  final AssistantSuggestionsProjection suggestions;
  final List<_ProjectedAssistantBlock> blocks;

  const _AssistantTerminalProjection({
    required this.split,
    required this.suggestions,
    required this.blocks,
  });
}

sealed class _ChatListEntry {
  ChatRenderUnitPlan get sourcePlan;
}

final class _WholeChatListEntry extends _ChatListEntry {
  @override
  final ChatRenderUnitPlan sourcePlan;

  _WholeChatListEntry(this.sourcePlan);
}

final class _AssistantSliceChatListEntry extends _ChatListEntry {
  @override
  final ChatMessageUnitPlan sourcePlan;
  final _AssistantRenderSlice slice;

  _AssistantSliceChatListEntry(this.sourcePlan, this.slice);
}

/// Conserva el host del asistente en el mismo slot cuando un error terminal
/// añade su tarjeta debajo de una respuesta parcial.
///
/// En una lista `reverse:true` virtualizada, convertir de golpe el índice 0 en
/// dos filas hace que `maxScrollExtent` mezcle geometría real y estimaciones
/// lazy. Agruparlas mientras el lector está apartado permite que el reporter
/// vivo mida el delta real del conjunto en el mismo layout.
final class _RetainedTerminalErrorChatListEntry extends _ChatListEntry {
  final ChatMessageUnitPlan errorPlan;
  final ChatMessageUnitPlan assistantPlan;

  _RetainedTerminalErrorChatListEntry({
    required this.errorPlan,
    required this.assistantPlan,
  });

  @override
  ChatRenderUnitPlan get sourcePlan => assistantPlan;
}

int? messageIndexForArtifactSource(
  List<Map<String, dynamic>> messagesNewestFirst,
  SessionArtifactSource source,
) {
  final sourceIdentity = TranscriptMessageIdentity(
    messageId: source.messageId,
    rowId: source.rowId,
  );
  if (sourceIdentity.isDurable) {
    var found = -1;
    for (var index = 0; index < messagesNewestFirst.length; index++) {
      final message = messagesNewestFirst[index];
      if (!transcriptIdentityAliasesAreConsistent(message)) {
        if (transcriptIdentityAliasesShareExactCoordinate(
          message,
          sourceIdentity,
        )) {
          return null;
        }
        continue;
      }
      final candidate = canonicalTranscriptIdentity(message);
      if (candidate == null ||
          !sourceIdentity.sharesExactCoordinate(candidate)) {
        continue;
      }
      if (!sourceIdentity.matches(candidate) || found >= 0) return null;
      found = index;
    }
    if (found >= 0) return found;
    // Un ID estable que ya no existe pertenece a otra revisión/compresión. No
    // degradar a un ordinal que ahora podría señalar otro mensaje.
    return null;
  }
  for (var index = 0; index < messagesNewestFirst.length; index++) {
    if (messagesNewestFirst[index]['_desktopMessageOrdinal'] ==
        source.messageOrdinal) {
      return index;
    }
  }

  var serverOrdinal = 0;
  for (var index = messagesNewestFirst.length - 1; index >= 0; index--) {
    final message = messagesNewestFirst[index];
    if (message['_steer'] == true ||
        message['_pipeline'] == true ||
        message['_desktopSnapshotKind'] == 'inflight') {
      continue;
    }
    if (serverOrdinal == source.messageOrdinal) return index;
    serverOrdinal++;
  }
  return null;
}

/// Fuente de lectura del catálogo. La selección siempre se aplica al runtime
/// de esta sesión; ninguna de estas rutas autoriza una mutación global.
enum _ModelSource { desktop, bridge, dashboard, gateway }

enum _ChatControlAction {
  permissions,
  refresh,
  artifacts,
  details,
  cron,
  recovery,
  extensions,
  delete,
}

// ChatPipelineState vive ahora en active_chat_service.dart (el streaming lo
// posee el servicio singleton, no el widget) y se reexporta vía ese import.
//
// La orquestación del modo voz (bucle, fases, feed de TTS) vive en el
// controlador local global (sobrevive a la navegación y al 2º plano).
// La pantalla solo observa ese servicio para pintar el overlay. VoicePhase se
// reexporta vía ese import.

/// Nombre corto y amigable de un modelo, para mostrarlo en la UI sin el id
/// crudo del servidor. Quita el prefijo de proveedor y la fecha del build:
///
///   "claude-opus-4-8-20251101"  → "Opus 4.8"
///   "anthropic/claude-sonnet-4-6" → "Sonnet 4.6"
///   "claude-haiku-4-5"          → "Haiku 4.5"
///   "gpt-4o"                    → "GPT-4o"
///
/// Modelos desconocidos: el id (sin proveedor) tal cual, truncado a 20 chars.
String friendlyModelName(String id) {
  // "anthropic/claude-…" → "claude-…": nos quedamos con el segmento del modelo.
  final slash = id.lastIndexOf('/');
  final raw = slash >= 0 && slash < id.length - 1
      ? id.substring(slash + 1)
      : id;
  final lower = raw.toLowerCase();

  // Familia Claude: "claude-familia-major-minor[-fecha]" → "Familia major.minor".
  final claude = RegExp(
    r'^claude-(opus|sonnet|haiku)-(\d+)-(\d+)',
  ).firstMatch(lower);
  if (claude != null) {
    final family = claude.group(1)!;
    final capitalized = family[0].toUpperCase() + family.substring(1);
    return '$capitalized ${claude.group(2)}.${claude.group(3)}';
  }

  // Familia GPT: mantiene "GPT-" en mayúsculas y conserva el resto del nombre.
  final gpt = RegExp(r'^gpt-(.+)$').firstMatch(lower);
  if (gpt != null) return 'GPT-${gpt.group(1)}';

  return raw.length > 20 ? '${raw.substring(0, 19)}…' : raw;
}

/// Contadores opt-in para demostrar que el streaming queda aislado del árbol
/// histórico. Solo se inyecta desde widget tests; en producción permanece null.
@visibleForTesting
class ChatPerformanceProbe {
  int screenBuilds = 0;
  int composerBuilds = 0;
  int terminalAssistantBuilds = 0;
  int liveAssistantBuilds = 0;
  int terminalProjectionComputations = 0;
  int liveStableProjectionComputations = 0;

  void reset() {
    screenBuilds = 0;
    composerBuilds = 0;
    terminalAssistantBuilds = 0;
    liveAssistantBuilds = 0;
    terminalProjectionComputations = 0;
    liveStableProjectionComputations = 0;
  }
}

bool chatRefreshMessagesShareAnchorIdentity(
  Map<String, dynamic> selected,
  Map<String, dynamic> candidate,
) {
  if (!transcriptIdentityAliasesAreConsistent(selected) ||
      !transcriptIdentityAliasesAreConsistent(candidate)) {
    return false;
  }
  final selectedIdentity = canonicalTranscriptIdentity(selected);
  final candidateIdentity = canonicalTranscriptIdentity(candidate);
  if (selectedIdentity != null &&
      candidateIdentity != null &&
      selectedIdentity.matches(candidateIdentity)) {
    return true;
  }
  // Sin identidad durable no hay equivalencia entre proyecciones: dos turnos
  // legítimos pueden compartir rol y texto. Solo el mismo objeto conserva el
  // ancla mientras la lista no haya sido sustituida.
  return identical(selected, candidate);
}

@visibleForTesting
Map<String, dynamic>? chatRefreshFindAnchorMessage(
  Map<String, dynamic> selected,
  Iterable<Map<String, dynamic>> candidates,
) {
  if (!transcriptIdentityAliasesAreConsistent(selected)) return null;
  final selectedIdentity = canonicalTranscriptIdentity(selected);
  Map<String, dynamic>? match;
  for (final candidate in candidates) {
    if (selectedIdentity != null) {
      if (!transcriptIdentityAliasesAreConsistent(candidate)) {
        if (transcriptIdentityAliasesShareExactCoordinate(
          candidate,
          selectedIdentity,
        )) {
          return null;
        }
        continue;
      }
      final candidateIdentity = canonicalTranscriptIdentity(candidate);
      if (candidateIdentity == null ||
          !selectedIdentity.sharesExactCoordinate(candidateIdentity)) {
        continue;
      }
      if (!selectedIdentity.matches(candidateIdentity)) return null;
    } else if (!identical(selected, candidate)) {
      continue;
    }
    if (match != null) return null;
    match = candidate;
  }
  return match;
}

@visibleForTesting
String chatReadAloudMessageKey(
  String sessionId,
  Map<String, dynamic>? message,
  String answer,
) {
  final identity = message == null
      ? null
      : canonicalTranscriptIdentity(message);
  final durableKey = identity?.rowId != null
      ? 'row:${identity!.rowId}'
      : identity?.messageId != null
      ? 'message:${identity!.messageId}'
      : null;
  return '$sessionId:assistant:'
      '${durableKey ?? 'content:${_stableChatReadAloudHash(answer)}'}';
}

String _stableChatReadAloudHash(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
