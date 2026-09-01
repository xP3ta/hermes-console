import 'dart:convert';

import '../models/desktop_session_snapshot.dart';
import '../utils/chat_turn.dart';

/// Pure projection of a Hermes Desktop 0.19 resume/activate snapshot into the
/// newest-first message shape consumed by [ActiveChat].
///
/// This class performs no I/O and deliberately carries no raw gateway payload.
/// `queued` remains a singleton: Hermes may merge multiple steer inputs with
/// two newlines, which is still one remotely queued prompt.
class DesktopSessionProjection {
  final List<Map<String, dynamic>> messagesNewestFirst;
  final String? queuedUser;
  final String? queuedSyntheticId;
  final bool running;
  final bool failed;
  final String? status;

  const DesktopSessionProjection({
    required this.messagesNewestFirst,
    required this.running,
    this.failed = false,
    this.queuedUser,
    this.queuedSyntheticId,
    this.status,
  });
}

TranscriptMessageIdentity? _desktopTranscriptIdentity(
  DesktopSessionMessage message,
) {
  if (!message.identityAliasesConsistent) return null;
  final identity = TranscriptMessageIdentity(
    messageId: message.stableId,
    rowId: message.rowId,
  );
  return identity.isDurable ? identity : null;
}

class DesktopSessionReconciler {
  const DesktopSessionReconciler();

  /// REST 0.19 conserva el contenido autoritativo pero puede omitir los campos
  /// editoriales que sí entrega `session.resume`. Superpone esos campos solo
  /// cuando el mismo mensaje se identifica por id estable. El contenido no es
  /// identidad: dos turnos legítimos pueden tener exactamente el mismo texto.
  List<Map<String, dynamic>> overlayDurableDisplayMetadata(
    List<Map<String, dynamic>> fallbackNewestFirst,
    List<DesktopSessionMessage> persistedChronological,
  ) {
    final candidates = persistedChronological
        .where(
          (message) =>
              (message.raw['display_kind']?.toString().trim().isNotEmpty ??
              false),
        )
        .toList(growable: false);
    if (fallbackNewestFirst.isEmpty || candidates.isEmpty) {
      return fallbackNewestFirst;
    }

    final identities = <DesktopSessionMessage, TranscriptMessageIdentity>{};
    final ambiguous = <DesktopSessionMessage>{};
    for (final candidate in candidates) {
      final identity = _desktopTranscriptIdentity(candidate);
      if (identity == null) continue;
      for (final entry in identities.entries) {
        if (!identity.sharesExactCoordinate(entry.value)) continue;
        ambiguous
          ..add(candidate)
          ..add(entry.key);
      }
      identities[candidate] = identity;
    }
    final fallbackIdentities =
        <Map<String, dynamic>, TranscriptMessageIdentity>{};
    final ambiguousFallback = <Map<String, dynamic>>{};
    for (final message in fallbackNewestFirst) {
      final identity = canonicalTranscriptIdentity(message);
      if (identity == null) continue;
      for (final entry in fallbackIdentities.entries) {
        if (!identity.sharesExactCoordinate(entry.value)) continue;
        ambiguousFallback
          ..add(message)
          ..add(entry.key);
      }
      fallbackIdentities[message] = identity;
    }

    return fallbackNewestFirst
        .map((message) {
          if (ambiguousFallback.contains(message)) return message;
          final identity = canonicalTranscriptIdentity(message);
          DesktopSessionMessage? candidate;
          if (identity != null) {
            for (final entry in identities.entries) {
              if (ambiguous.contains(entry.key) ||
                  !identity.matches(entry.value)) {
                continue;
              }
              if (candidate != null) {
                candidate = null;
                break;
              }
              candidate = entry.key;
            }
          }
          if (candidate == null || message['_steer'] == true) return message;

          final displayKind =
              candidate.raw['display_kind']?.toString().trim() ?? '';
          if (displayKind.isEmpty) return message;
          final next = Map<String, dynamic>.from(message)
            ..['display_kind'] = displayKind;
          final metadata = _sanitizeDisplayMetadata(candidate.displayMetadata);
          if (metadata == null) {
            next.remove('display_metadata');
          } else {
            next['display_metadata'] = metadata;
          }
          return Map<String, dynamic>.unmodifiable(next);
        })
        .toList(growable: false);
  }

  DesktopSessionProjection project(
    DesktopSessionSnapshot snapshot, {
    List<Map<String, dynamic>> fallbackNewestFirst = const [],
  }) {
    final chronological = snapshot.messagesProvided
        ? <Map<String, dynamic>>[
            for (var index = 0; index < snapshot.messages.length; index++)
              ..._projectPersistedMessage(
                snapshot.messages[index],
                runtimeSessionId: snapshot.runtimeSessionId,
                ordinal: snapshot.messages[index].serverOrdinal ?? index,
              ),
          ]
        : fallbackNewestFirst.reversed
              .map<Map<String, dynamic>>(_copyMessage)
              .toList(growable: true);

    // A repeated resume may feed the previous live projection back as fallback.
    // Replace those synthetic rows with the current snapshot instead of
    // appending another prompt/correction/assistant tail on every hydration.
    if (!snapshot.messagesProvided) {
      chronological.removeWhere(
        (message) => message['_desktopSnapshotKind'] == 'inflight',
      );
    }

    final inflight = snapshot.inflight;
    final inflightUser = inflight?.user;
    final inflightError = inflight?.error?.trim() ?? '';
    final inflightStatus = inflight?.status?.trim().toLowerCase() ?? '';
    final inflightFailed =
        inflightError.isNotEmpty || inflightStatus == 'error';
    if (inflightUser != null && inflightUser.trim().isNotEmpty) {
      // `inflight.user` no comparte una identidad protocolaria con las filas
      // persistidas. El upstream mantiene ambos planos separados: el history
      // durable puede acabar en un user histórico/cancelado y el inflight ser
      // un turno nuevo con el mismo texto. Fusionarlos por contenido haría que
      // Stop anclase el turno nuevo al ID del histórico.
      chronological.add(
        Map<String, dynamic>.unmodifiable({
          'role': 'user',
          'content': inflightUser,
          '_desktopSnapshotKey': 'user-inflight-${snapshot.runtimeSessionId}',
          '_desktopSnapshotKind': 'inflight',
        }),
      );
    }

    final inflightCorrections =
        inflight?.corrections ?? const <DesktopInflightCorrection>[];
    for (var index = 0; index < inflightCorrections.length; index++) {
      final correction = inflightCorrections[index];
      // Igual que el prompt original, una corrección sin ID explícito nunca
      // adquiere la identidad de una fila durable solo porque coincida el texto.
      chronological.add(
        Map<String, dynamic>.unmodifiable({
          'role': 'user',
          'content': correction.text,
          '_steer': true,
          '_desktopSnapshotKey':
              'user-inflight-correction-$index-${snapshot.runtimeSessionId}',
          '_desktopSnapshotKind': 'inflight',
        }),
      );
    }

    final inflightAssistant = inflight?.assistant;
    final hasInflight =
        !inflightFailed &&
        (inflight != null || snapshot.running || inflight?.streaming == true);
    if (hasInflight &&
        (inflightAssistant != null ||
            inflightUser != null ||
            inflightCorrections.isNotEmpty ||
            snapshot.running)) {
      chronological.add(
        Map<String, dynamic>.unmodifiable({
          'role': 'assistant',
          'content': inflightAssistant ?? '',
          '_pipeline': true,
          '_desktopSnapshotKey':
              'assistant-stream-${snapshot.runtimeSessionId}',
          '_desktopSnapshotKind': 'inflight',
        }),
      );
    }

    if (inflightFailed) {
      final partial = inflightAssistant?.trim() ?? '';
      if (partial.isNotEmpty) {
        chronological.add(
          Map<String, dynamic>.unmodifiable({
            'role': 'assistant',
            'content': partial,
            '_cancelled': true,
            '_pipeline': false,
            '_desktopSnapshotKey':
                'assistant-stream-${snapshot.runtimeSessionId}',
            '_desktopSnapshotKind': 'inflight',
          }),
        );
      }
      final error = inflightError.isEmpty
          ? 'Hermes reported an error'
          : inflightError;
      chronological.add(
        Map<String, dynamic>.unmodifiable({
          'role': 'assistant_error',
          'content': error,
          if (inflightUser?.trim().isNotEmpty == true)
            '_prompt': inflightUser!.trim(),
          'error': error,
          'partial': partial.isNotEmpty,
          'recoverable': ?inflight?.recoverable,
          '_desktopSnapshotKey': 'assistant-error-${snapshot.runtimeSessionId}',
          '_desktopSnapshotKind': 'inflight',
        }),
      );
    }

    final queuedUser = snapshot.queued?.user;
    final newestFirst = chronological.reversed
        .map<Map<String, dynamic>>(_copyMessage)
        .toList(growable: false);
    return DesktopSessionProjection(
      messagesNewestFirst: List<Map<String, dynamic>>.unmodifiable(newestFirst),
      queuedUser: queuedUser,
      queuedSyntheticId: queuedUser == null
          ? null
          : 'user-queued-${snapshot.runtimeSessionId}',
      running: !inflightFailed && (snapshot.running || inflight != null),
      failed: inflightFailed,
      status: inflightFailed ? 'error' : snapshot.status,
    );
  }

  List<Map<String, dynamic>> _projectPersistedMessage(
    DesktopSessionMessage message, {
    required String runtimeSessionId,
    required int ordinal,
  }) {
    final role = switch (message.role) {
      DesktopSessionMessageRole.system => 'system',
      DesktopSessionMessageRole.user => 'user',
      DesktopSessionMessageRole.assistant => 'assistant',
      DesktopSessionMessageRole.tool => 'tool',
      DesktopSessionMessageRole.unknown => message.rawRole.toLowerCase(),
    };
    final displayKind = message.raw['display_kind']?.toString().trim() ?? '';
    final displayMetadata = _sanitizeDisplayMetadata(message.displayMetadata);

    // Bloques estructurados estilo Anthropic dentro de `content: [...]`. El
    // aplanado a texto solo conserva los bloques de texto; el resto se proyecta
    // a su equivalente del timeline para no descartarlo en silencio:
    // thinking → reasoning, tool_use → tool_calls, tool_result → mensaje tool.
    final blocks = message.content is List ? message.content as List : null;
    final blockReasoning = <String>[];
    final synthesizedToolCalls = <Map<String, dynamic>>[];
    final toolResultBlocks = <Map<dynamic, dynamic>>[];
    var imageCount = 0;
    Object? displaySource = message.content;
    if (blocks != null) {
      final textBlocks = <Object?>[];
      var droppedAny = false;
      for (final block in blocks) {
        if (block is! Map) {
          textBlocks.add(block);
          continue;
        }
        final type = (block['type'] ?? '').toString().trim().toLowerCase();
        switch (type) {
          case 'thinking':
          case 'redacted_thinking':
            droppedAny = true;
            final thinking =
                (block['thinking'] ?? block['text'])?.toString().trim() ?? '';
            blockReasoning.add(
              thinking.isNotEmpty ? thinking : '(razonamiento redactado)',
            );
          case 'tool_use':
            droppedAny = true;
            final name = block['name']?.toString().trim() ?? '';
            if (name.isNotEmpty) {
              final input = block['input'];
              synthesizedToolCalls.add(
                Map<String, dynamic>.unmodifiable({
                  if (block['id'] != null) 'id': block['id'].toString(),
                  'type': 'function',
                  'function': Map<String, dynamic>.unmodifiable({
                    'name': name,
                    'arguments': input is String
                        ? input
                        : jsonEncode(input ?? const {}),
                  }),
                }),
              );
            }
          case 'tool_result':
            droppedAny = true;
            toolResultBlocks.add(block);
          case 'image':
          case 'input_image':
            droppedAny = true;
            imageCount++;
          default:
            textBlocks.add(block);
        }
      }
      if (droppedAny) displaySource = textBlocks;
    }

    var content =
        message.text ??
        desktopSessionDisplayText(displaySource) ??
        desktopSessionDisplayText(message.context) ??
        '';
    if (imageCount > 0) {
      // Aún no hay tarjeta para imágenes de bloques estructurados; el marcador
      // conserva al menos la señal de que el turno incluía una imagen.
      const marker = '*(imagen adjunta)*';
      content = content.isEmpty ? marker : '$content\n\n$marker';
    }

    final toolResultMessages = <Map<String, dynamic>>[
      for (var index = 0; index < toolResultBlocks.length; index++)
        Map<String, dynamic>.unmodifiable({
          'role': 'tool',
          'content':
              desktopSessionDisplayText(toolResultBlocks[index]['content']) ??
              '',
          if (toolResultBlocks[index]['name'] != null)
            'tool_name': toolResultBlocks[index]['name'].toString(),
          if (toolResultBlocks[index]['tool_use_id'] != null)
            'tool_call_id': toolResultBlocks[index]['tool_use_id'].toString(),
          '_desktopSnapshotKey':
              'message-$runtimeSessionId-$ordinal-toolresult-$index',
          '_desktopSnapshotKind': 'persisted',
        }),
    ];

    // Un mensaje user cuyo contenido eran SOLO bloques tool_result (formato
    // Anthropic) no es un prompt real: se proyecta como mensajes tool y no
    // deja una burbuja de usuario vacía.
    final dropMain =
        role == 'user' && content.isEmpty && toolResultMessages.isNotEmpty;
    final main = Map<String, dynamic>.unmodifiable({
      'role': role,
      'content': content,
      '_desktopSnapshotKey': 'message-$runtimeSessionId-$ordinal',
      '_desktopSnapshotKind': 'persisted',
      '_desktopMessageOrdinal': ordinal,
      if (message.rowId != null) '_desktopRowId': message.rowId,
      if (message.stableId != null) '_desktopMessageId': message.stableId,
      if (displayKind.isNotEmpty) 'display_kind': displayKind,
      'display_metadata': ?displayMetadata,
      if (message.name != null) 'name': message.name,
      if (message.toolName != null) 'tool_name': message.toolName,
      if (message.toolCallId != null) 'tool_call_id': message.toolCallId,
      if (message.toolCalls != null)
        'tool_calls': message.toolCalls
      else if (synthesizedToolCalls.isNotEmpty)
        'tool_calls': synthesizedToolCalls,
      if (message.reasoning != null)
        'reasoning': message.reasoning
      else if (blockReasoning.isNotEmpty)
        'reasoning': blockReasoning.join('\n\n'),
      if (message.reasoningContent != null)
        'reasoning_content': message.reasoningContent,
      if (message.reasoningDetails != null)
        'reasoning_details': message.reasoningDetails,
      if (message.codexReasoningItems != null)
        'codex_reasoning_items': message.codexReasoningItems,
      if (message.timestamp != null)
        'timestamp': message.timestamp!.millisecondsSinceEpoch / 1000,
    });
    return dropMain ? toolResultMessages : [main, ...toolResultMessages];
  }
}

/// Conserva únicamente el pequeño contrato editorial que Hermes Desktop usa
/// para resumir eventos duraderos. Algunos gateways antiguos serializan el
/// objeto como JSON; nunca propagamos campos arbitrarios al árbol de widgets.
Map<String, dynamic>? _sanitizeDisplayMetadata(Object? raw) {
  Object? decoded = raw;
  if (raw is String) {
    final value = raw.trim();
    if (value.isEmpty || value.length > 4096) return null;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      return null;
    }
  }
  if (decoded is! Map) return null;

  const countKeys = {'task_count', 'completed_count', 'failed_count'};
  final safe = <String, dynamic>{};
  for (final key in countKeys) {
    final value = decoded[key];
    if (value is int && value >= 0 && value <= 10000) {
      safe[key] = value;
    }
  }
  final duration = decoded['duration_seconds'];
  if (duration is num &&
      duration.isFinite &&
      duration >= 0 &&
      duration <= 604800) {
    safe['duration_seconds'] = duration;
  }
  final delegationId = decoded['delegation_id'];
  if (delegationId is String &&
      delegationId.isNotEmpty &&
      delegationId.length <= 180 &&
      RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(delegationId)) {
    safe['delegation_id'] = delegationId;
  }
  return safe.isEmpty ? null : Map<String, dynamic>.unmodifiable(safe);
}

Map<String, dynamic> _copyMessage(Map<String, dynamic> value) =>
    Map<String, dynamic>.unmodifiable(Map<String, dynamic>.from(value));

/// Proyecta contenido estructurado del contrato Desktop/REST a texto seguro
/// para la UI. Los adjuntos permanecen en el índice estructural y nunca se
/// serializan como mapas dentro de las burbujas del chat.
String? desktopSessionDisplayText(Object? value) {
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  if (value is List) {
    final out = StringBuffer();
    var previousWasTextPart = false;
    for (final item in value) {
      final part = desktopSessionDisplayText(item);
      if (part == null || part.trim().isEmpty) continue;
      final isTextPart = _isStructuredTextPart(item);
      if (out.isNotEmpty && !(previousWasTextPart && isTextPart)) {
        out.write('\n');
      }
      out.write(part);
      previousWasTextPart = isTextPart;
    }
    return out.isEmpty ? null : out.toString();
  }
  if (value is Map) {
    final text = value['text'] ?? value['content'];
    return desktopSessionDisplayText(text);
  }
  return null;
}

bool _isStructuredTextPart(Object? value) {
  if (value is! Map) return false;
  final type = (value['type'] ?? '').toString().trim().toLowerCase();
  return type.isEmpty ||
      type == 'text' ||
      type == 'input_text' ||
      type == 'output_text' ||
      type == 'summary_text';
}
