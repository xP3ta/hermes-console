import 'dart:convert';

import '../models/desktop_session_snapshot.dart';

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

class DesktopSessionReconciler {
  const DesktopSessionReconciler();

  /// REST 0.19 conserva el contenido autoritativo pero puede omitir los campos
  /// editoriales que sí entrega `session.resume`. Superpone esos campos solo
  /// cuando el mismo mensaje se identifica por id estable o por una coincidencia
  /// única y exacta de rol + contenido. No clasifica texto mediante heurísticas.
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

    final byId = <String, DesktopSessionMessage>{};
    final bySignature = <String, List<DesktopSessionMessage>>{};
    for (final candidate in candidates) {
      final stableId = candidate.stableId;
      if (stableId != null) byId[stableId] = candidate;
      final signature = _persistedMessageSignature(candidate);
      (bySignature[signature] ??= []).add(candidate);
    }

    return fallbackNewestFirst
        .map((message) {
          final stableId =
              message['_desktopMessageId']?.toString() ??
              message['message_id']?.toString() ??
              message['id']?.toString();
          var candidate = stableId == null ? null : byId[stableId];
          if (candidate == null) {
            final matches = bySignature[_fallbackMessageSignature(message)];
            if (matches?.length == 1) candidate = matches!.single;
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
    final latestUserRun = _latestContiguousUserRun(chronological);
    final unmatchedLatestUsers = List<bool>.filled(latestUserRun.length, true);
    int consumeFromLatestUserRun(String text) {
      for (var index = 0; index < latestUserRun.length; index++) {
        if (unmatchedLatestUsers[index] &&
            latestUserRun[index]['content'] == text) {
          unmatchedLatestUsers[index] = false;
          return index;
        }
      }
      return -1;
    }

    if (inflightUser != null && inflightUser.trim().isNotEmpty) {
      if (consumeFromLatestUserRun(inflightUser) < 0) {
        chronological.add(
          Map<String, dynamic>.unmodifiable({
            'role': 'user',
            'content': inflightUser,
            '_desktopSnapshotKey': 'user-inflight-${snapshot.runtimeSessionId}',
            '_desktopSnapshotKind': 'inflight',
          }),
        );
      }
    }

    final inflightCorrections =
        inflight?.corrections ?? const <DesktopInflightCorrection>[];
    for (var index = 0; index < inflightCorrections.length; index++) {
      final correction = inflightCorrections[index];
      final existingIndex = consumeFromLatestUserRun(correction.text);
      if (existingIndex >= 0) {
        final existing = latestUserRun[existingIndex];
        if (existing['_steer'] != true) {
          final projected = Map<String, dynamic>.unmodifiable({
            ...existing,
            '_steer': true,
          });
          final chronologicalIndex = chronological.indexWhere(
            (message) => identical(message, existing),
          );
          if (chronologicalIndex >= 0) {
            chronological[chronologicalIndex] = projected;
            latestUserRun[existingIndex] = projected;
          }
        }
        continue;
      }
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
    final rowId = message.raw['row_id'];
    final main = Map<String, dynamic>.unmodifiable({
      'role': role,
      'content': content,
      '_desktopSnapshotKey': 'message-$runtimeSessionId-$ordinal',
      '_desktopSnapshotKind': 'persisted',
      '_desktopMessageOrdinal': ordinal,
      if (rowId is int) '_desktopRowId': rowId,
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

List<Map<String, dynamic>> _latestContiguousUserRun(
  List<Map<String, dynamic>> chronological,
) {
  final latestUserIndex = chronological.lastIndexWhere(
    (message) => message['role'] == 'user',
  );
  if (latestUserIndex < 0) return const [];
  var firstUserIndex = latestUserIndex;
  while (firstUserIndex > 0 &&
      chronological[firstUserIndex - 1]['role'] == 'user') {
    firstUserIndex--;
  }
  return chronological.sublist(firstUserIndex, latestUserIndex + 1);
}

String _persistedMessageSignature(DesktopSessionMessage message) {
  final role = switch (message.role) {
    DesktopSessionMessageRole.system => 'system',
    DesktopSessionMessageRole.user => 'user',
    DesktopSessionMessageRole.assistant => 'assistant',
    DesktopSessionMessageRole.tool => 'tool',
    DesktopSessionMessageRole.unknown => message.rawRole.toLowerCase(),
  };
  final content =
      message.text ??
      desktopSessionDisplayText(message.content) ??
      desktopSessionDisplayText(message.context) ??
      '';
  return '$role\u0000$content';
}

String _fallbackMessageSignature(Map<String, dynamic> message) =>
    '${message['role'] ?? 'assistant'}\u0000${message['content'] ?? ''}';

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
