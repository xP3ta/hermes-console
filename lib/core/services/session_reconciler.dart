import 'dart:convert';

import '../models/desktop_session_snapshot.dart';
import '../models/transcript_privacy_state.dart';
import '../utils/assistant_content.dart';
import '../utils/chat_turn.dart';
import 'terminal_transcript_authority.dart';

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

enum _LiveUserProjectionProof { none, exactAnchorPrefix }

class _LiveUserProjectionPlan {
  final int representedPrefixLength;
  final _LiveUserProjectionProof proof;

  const _LiveUserProjectionPlan({
    required this.representedPrefixLength,
    required this.proof,
  });

  static const none = _LiveUserProjectionPlan(
    representedPrefixLength: 0,
    proof: _LiveUserProjectionProof.none,
  );

  bool emits(int liveUserIndex) =>
      proof == _LiveUserProjectionProof.none ||
      liveUserIndex >= representedPrefixLength;
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

  static bool _isDurableTerminalAssistant(Map<String, dynamic> message) {
    final role = message['role']?.toString().trim().toLowerCase();
    if (role != 'assistant' && role != 'assistant_error') return false;
    if (message['_desktopSnapshotKind'] == 'inflight' ||
        message['_pipeline'] == true ||
        message['_interim'] == true) {
      return false;
    }
    final isDurable =
        message['_desktopSnapshotKind'] == 'persisted' ||
        canonicalTranscriptMessageId(message) != null ||
        canonicalTranscriptRowId(message) != null;
    if (!isDurable) return false;
    final authority = decideTerminalAuthority(
      chronological: [
        const {
          'message_id': '__desktop_reconciler_terminal_anchor__',
          'role': 'user',
          'content': '',
        },
        message,
      ],
      expectedUsers: 1,
      source: TerminalEvidenceSource.desktopSnapshot,
      sourceTranscriptComplete: true,
      transportTerminalObserved: false,
      transportTerminalIsError: false,
      compactionFenceActive: false,
      currentAuthorityFence: true,
      visibleAssistantTextPresent: false,
      allowLegacyDirectToolTerminal: false,
    );
    return authority.isAuthoritative;
  }

  static bool _isCrossableNonUserLiveProjection(Map<String, dynamic> message) {
    if (message['role'] == 'user') return false;
    return message['_desktopSnapshotKind'] == 'inflight' ||
        message['_pipeline'] == true;
  }

  static bool _isBridgeableOwnedLiveUserProjection(
    Map<String, dynamic> message,
  ) =>
      message['role'] == 'user' &&
      (message['_desktopSnapshotKind'] == 'inflight' ||
          message['_optimistic'] == true ||
          message['_steer'] == true);

  static int? _exactPreviousAnchorIndex(
    List<Map<String, dynamic>> chronological,
    List<Map<String, dynamic>> previousNewestFirst,
    bool bridgeOwnedLiveUser,
  ) {
    TranscriptMessageIdentity? anchor;
    for (final previous in previousNewestFirst) {
      if (_isCrossableNonUserLiveProjection(previous)) continue;
      if (bridgeOwnedLiveUser &&
          _isBridgeableOwnedLiveUserProjection(previous)) {
        continue;
      }
      anchor = canonicalTranscriptIdentity(previous);
      // Never cross an id-less durable-looking survivor to recover an older
      // anchor: that row could be the unanswered repeated prompt.
      if (anchor == null) return null;
      break;
    }
    if (anchor == null) return null;

    int? matchedIndex;
    for (var index = 0; index < chronological.length; index++) {
      final candidate = chronological[index];
      if (!transcriptIdentityAliasesShareExactCoordinate(candidate, anchor)) {
        continue;
      }
      final candidateIdentity = canonicalTranscriptIdentity(candidate);
      if (candidateIdentity == null || !candidateIdentity.matches(anchor)) {
        return null;
      }
      if (matchedIndex != null) return null;
      matchedIndex = index;
    }
    return matchedIndex;
  }

  static DateTime? _projectedTimestamp(Map<String, dynamic> message) {
    final value = message['timestamp'];
    if (value is! num || !value.isFinite || value < 0) return null;
    try {
      return DateTime.fromMicrosecondsSinceEpoch(
        (value * Duration.microsecondsPerSecond).round(),
      );
    } on RangeError {
      return null;
    }
  }

  static _LiveUserProjectionPlan _liveUserProjectionPlan(
    List<Map<String, dynamic>> chronological,
    List<Map<String, dynamic>> previousNewestFirst,
    DesktopInflightTurn? inflight,
    bool bridgeOwnedLiveUser,
    DateTime? turnStartedAt,
  ) {
    if (inflight == null) return _LiveUserProjectionPlan.none;
    final liveUsers = <String>[
      if (inflight.user?.trim().isNotEmpty == true) inflight.user!,
      ...inflight.corrections.map((correction) => correction.text),
    ];
    if (liveUsers.isEmpty) return _LiveUserProjectionPlan.none;

    final anchorIndex = _exactPreviousAnchorIndex(
      chronological,
      previousNewestFirst,
      bridgeOwnedLiveUser,
    );
    if (anchorIndex == null) return _LiveUserProjectionPlan.none;

    var terminalBoundary = anchorIndex;
    var terminalFoundAfterAnchor = false;
    for (var index = anchorIndex + 1; index < chronological.length; index++) {
      if (_isDurableTerminalAssistant(chronological[index])) {
        terminalBoundary = index;
        terminalFoundAfterAnchor = true;
      }
    }

    // On the next passive refresh, the latest previous row can already be the
    // durable form of the active input itself. Treat that exact, uniquely
    // anchored open tail as part of the current inflight turn; otherwise the
    // reconciler appends the same synthetic user again on every later snapshot.
    // A previous terminal assistant still wins, so an identical completed
    // prompt remains a distinct new turn.
    final anchoredMessage = chronological[anchorIndex];
    final anchoredAt = _projectedTimestamp(anchoredMessage);
    final anchorIsDurableOpenInput =
        !terminalFoundAfterAnchor &&
        turnStartedAt != null &&
        anchoredAt != null &&
        anchoredAt.isAfter(turnStartedAt) &&
        canonicalTranscriptIdentity(anchoredMessage) != null &&
        (isRealUserTurn(anchoredMessage) ||
            (anchoredMessage['role'] == 'user' &&
                anchoredMessage['_steer'] == true));
    if (anchorIsDurableOpenInput) {
      terminalBoundary = -1;
      for (var index = anchorIndex - 1; index >= 0; index--) {
        if (_isDurableTerminalAssistant(chronological[index])) {
          terminalBoundary = index;
          break;
        }
      }
    }

    final durableOpenInputs = <Map<String, dynamic>>[];
    for (
      var index = terminalBoundary + 1;
      index < chronological.length;
      index++
    ) {
      final message = chronological[index];
      final isLiveUserInput =
          isRealUserTurn(message) ||
          (message['role'] == 'user' && message['_steer'] == true);
      if (isLiveUserInput) durableOpenInputs.add(message);
    }
    if (durableOpenInputs.isEmpty) return _LiveUserProjectionPlan.none;

    final sharedLength = durableOpenInputs.length < liveUsers.length
        ? durableOpenInputs.length
        : liveUsers.length;
    for (var index = 0; index < sharedLength; index++) {
      if (durableOpenInputs[index]['content']?.toString() != liveUsers[index]) {
        return _LiveUserProjectionPlan.none;
      }
    }
    if (durableOpenInputs.length > liveUsers.length &&
        durableOpenInputs
            .skip(liveUsers.length)
            .any((message) => message['_steer'] != true)) {
      return _LiveUserProjectionPlan.none;
    }
    return _LiveUserProjectionPlan(
      representedPrefixLength: sharedLength,
      proof: _LiveUserProjectionProof.exactAnchorPrefix,
    );
  }

  /// Extrae vetos privados de identidades durables no contradictorias.
  ///
  /// Repetir exactamente una fila no revoca evidencia negativa. En cambio, dos
  /// identidades que comparten una coordenada y contradicen la otra quedan
  /// aisladas: ninguna se usa para clasificar filas de otra superficie.
  List<TranscriptMessageIdentity> privateTranscriptIdentityVetoes(
    List<DesktopSessionMessage> persistedChronological,
  ) {
    final identities = <DesktopSessionMessage, TranscriptMessageIdentity>{};
    final conflicting = <DesktopSessionMessage>{};
    for (final candidate in persistedChronological) {
      final identity = _desktopTranscriptIdentity(candidate);
      if (identity == null) continue;
      for (final entry in identities.entries) {
        if (!identity.sharesExactCoordinate(entry.value) ||
            identity.matches(entry.value)) {
          continue;
        }
        conflicting
          ..add(candidate)
          ..add(entry.key);
      }
      identities[candidate] = identity;
    }

    final vetoes = <TranscriptMessageIdentity>[];
    for (final entry in identities.entries) {
      if (entry.key.publiclyRenderable || conflicting.contains(entry.key)) {
        continue;
      }
      if (!vetoes.any(entry.value.matches)) vetoes.add(entry.value);
    }
    return List<TranscriptMessageIdentity>.unmodifiable(vetoes);
  }

  /// REST 0.19 conserva el contenido autoritativo pero puede omitir los campos
  /// editoriales que sí entrega `session.resume`. Superpone esos campos solo
  /// cuando el mismo mensaje se identifica por id estable. El contenido no es
  /// identidad: dos turnos legítimos pueden tener exactamente el mismo texto.
  List<Map<String, dynamic>> overlayDurableDisplayMetadata(
    List<Map<String, dynamic>> fallbackNewestFirst,
    List<DesktopSessionMessage> persistedChronological,
  ) {
    if (fallbackNewestFirst.isEmpty || persistedChronological.isEmpty) {
      return fallbackNewestFirst;
    }

    final graph = TranscriptPrivacyGraph([
      ...persistedChronological.map((row) => row.transcriptPrivacyObservation),
      ...fallbackNewestFirst.map(TranscriptPrivacyObservation.fromRaw),
    ]);

    final identities = <DesktopSessionMessage, TranscriptMessageIdentity>{};
    final ambiguous = <DesktopSessionMessage>{};
    for (final candidate in persistedChronological) {
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

    final merged = <Map<String, dynamic>>[];
    for (final message in fallbackNewestFirst) {
      final identity = canonicalTranscriptIdentity(message);
      // El veto es una operación de conjunto: todos los duplicados exactos de
      // una identidad privada se eliminan. La ambigüedad sigue bloqueando solo
      // la superposición positiva de metadata, no convierte un duplicado en
      // autorización para mostrar contenido sin classifier.
      final observation = TranscriptPrivacyObservation.fromRaw(message);
      if (graph.excludes(observation)) continue;
      if (ambiguousFallback.contains(message)) {
        merged.add(message);
        continue;
      }
      DesktopSessionMessage? candidate;
      if (identity != null && graph.permitsPartialInference(observation)) {
        for (final entry in identities.entries) {
          if (ambiguous.contains(entry.key) || !identity.matches(entry.value)) {
            continue;
          }
          if (candidate != null) {
            candidate = null;
            break;
          }
          candidate = entry.key;
        }
      }
      if (candidate == null) {
        merged.add(message);
        continue;
      }

      // La clasificación del snapshot es evidencia autoritativa negativa. Una
      // identidad igual permite vetar o superponer metadata, nunca convertir el
      // contenido REST/cache sin classifier en permiso público.
      if (!candidate.publiclyRenderable) continue;
      if (message['_steer'] == true) {
        merged.add(message);
        continue;
      }
      final displayKind =
          candidate.raw['display_kind']?.toString().trim() ?? '';
      if (displayKind.isEmpty) {
        merged.add(message);
        continue;
      }
      final next = Map<String, dynamic>.from(message)
        ..['display_kind'] = displayKind;
      final metadata = sanitizeDelegationDisplayMetadata(
        candidate.displayMetadata,
      );
      if (metadata == null) {
        next.remove('display_metadata');
      } else {
        next['display_metadata'] = metadata;
      }
      merged.add(Map<String, dynamic>.unmodifiable(next));
    }
    return List<Map<String, dynamic>>.unmodifiable(merged);
  }

  DesktopSessionProjection project(
    DesktopSessionSnapshot snapshot, {
    List<Map<String, dynamic>> fallbackNewestFirst = const [],
    List<Map<String, dynamic>> previousNewestFirst = const [],
    bool bridgeOwnedLiveUser = false,
    bool retainMediaEvidence = false,
  }) {
    final chronological = snapshot.messagesProvided
        ? <Map<String, dynamic>>[
            for (var index = 0; index < snapshot.messages.length; index++)
              ..._projectPersistedMessage(
                snapshot.messages[index],
                runtimeSessionId: snapshot.runtimeSessionId,
                ordinal: snapshot.messages[index].serverOrdinal ?? index,
                retainMediaEvidence: retainMediaEvidence,
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
    final liveUserPlan = _liveUserProjectionPlan(
      chronological,
      previousNewestFirst,
      inflight,
      bridgeOwnedLiveUser,
      snapshot.resolvedTurnStartedAt,
    );
    final hasInflightUser = inflightUser?.trim().isNotEmpty == true;
    // The Gateway does not link inflight users to durable row IDs. Suppress
    // only a positionally matching suffix proven by one exact prior anchor;
    // text/timestamps alone never authorize hiding a user bubble.
    if (inflightUser != null &&
        inflightUser.trim().isNotEmpty &&
        liveUserPlan.emits(0)) {
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
    final inflightAssistant = inflight?.assistant;
    final hasInflight =
        !inflightFailed &&
        (inflight != null || snapshot.running || inflight?.streaming == true);
    final correctionOffsets = inflight?.correctionOffsets ?? const <int?>[];
    final correctionOffsetsUsable =
        !inflightFailed &&
        inflightAssistant != null &&
        inflightAssistant.isNotEmpty &&
        inflightCorrections.isNotEmpty &&
        correctionOffsets.length >= inflightCorrections.length &&
        correctionOffsets
            .take(inflightCorrections.length)
            .every((offset) => offset != null);

    Map<String, dynamic> correctionMessage(
      DesktopInflightCorrection correction,
      int index,
    ) => Map<String, dynamic>.unmodifiable({
      'role': 'user',
      'content': correction.text,
      '_steer': true,
      '_desktopSnapshotKey':
          'user-inflight-correction-$index-${snapshot.runtimeSessionId}',
      '_desktopSnapshotKind': 'inflight',
    });

    Map<String, dynamic> assistantMessage(
      String content, {
      required String key,
      required bool live,
    }) => Map<String, dynamic>.unmodifiable({
      'role': 'assistant',
      'content': content,
      '_pipeline': live,
      if (!live) '_interim': true,
      '_desktopSnapshotKey': key,
      '_desktopSnapshotKind': 'inflight',
    });

    if (correctionOffsetsUsable) {
      final publicProjection = projectPublicAssistantText(
        inflightAssistant,
        streaming: true,
      );
      final publicAssistant = publicProjection.text;
      var cursor = 0;
      var publicCursor = 0;
      for (var index = 0; index < inflightCorrections.length; index++) {
        final boundary = correctionOffsets[index]!.clamp(
          cursor,
          inflightAssistant.length,
        );
        var safeBoundary = publicProjection.publicOffsetAtRawOffset(boundary);
        if (safeBoundary < publicCursor) safeBoundary = publicCursor;
        final segment = publicAssistant.substring(publicCursor, safeBoundary);
        if (segment.isNotEmpty) {
          chronological.add(
            assistantMessage(
              segment,
              key:
                  'assistant-stream-segment-$index-${snapshot.runtimeSessionId}',
              live: false,
            ),
          );
        }
        cursor = boundary;
        publicCursor = safeBoundary;
        final liveUserIndex = (hasInflightUser ? 1 : 0) + index;
        if (liveUserPlan.emits(liveUserIndex)) {
          chronological.add(
            correctionMessage(inflightCorrections[index], index),
          );
        }
      }
      chronological.add(
        assistantMessage(
          publicAssistant.substring(publicCursor),
          key: 'assistant-stream-${snapshot.runtimeSessionId}',
          live: true,
        ),
      );
    } else {
      if (hasInflight &&
          (inflightAssistant != null ||
              inflightUser != null ||
              inflightCorrections.isNotEmpty ||
              snapshot.running)) {
        chronological.add(
          assistantMessage(
            streamingPublicAssistantText(inflightAssistant ?? ''),
            key: 'assistant-stream-${snapshot.runtimeSessionId}',
            live: true,
          ),
        );
      }
      for (var index = 0; index < inflightCorrections.length; index++) {
        final liveUserIndex = (hasInflightUser ? 1 : 0) + index;
        if (liveUserPlan.emits(liveUserIndex)) {
          chronological.add(
            correctionMessage(inflightCorrections[index], index),
          );
        }
      }
    }

    if (inflightFailed) {
      final partial = streamingPublicAssistantText(
        inflightAssistant ?? '',
      ).trim();
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
    required bool retainMediaEvidence,
  }) {
    if (!message.publiclyRenderable) return const [];
    final role = switch (message.role) {
      DesktopSessionMessageRole.system => 'system',
      DesktopSessionMessageRole.user => 'user',
      DesktopSessionMessageRole.assistant => 'assistant',
      DesktopSessionMessageRole.tool => 'tool',
      DesktopSessionMessageRole.unknown => message.rawRole.toLowerCase(),
    };
    final displayKind = message.raw['display_kind']?.toString().trim() ?? '';
    final displayMetadata = sanitizeDelegationDisplayMetadata(
      message.displayMetadata,
    );
    if (role != 'user' && role != 'assistant' && !retainMediaEvidence) {
      return const [];
    }

    // Bloques estructurados estilo Anthropic dentro de `content: [...]`.
    // Solo el texto narrativo es público; thinking, tool_use y tool_result se
    // eliminan aquí. La ruta de medios puede conservar temporalmente la forma
    // mínima de herramientas para asociar adjuntos y la proyección final la
    // vuelve a retirar.
    final blocks = message.content is List ? message.content as List : null;
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

    final toolResultMessages = !retainMediaEvidence
        ? const <Map<String, dynamic>>[]
        : <Map<String, dynamic>>[
            for (var index = 0; index < toolResultBlocks.length; index++)
              Map<String, dynamic>.unmodifiable({
                'role': 'tool',
                'content':
                    desktopSessionDisplayText(
                      toolResultBlocks[index]['content'],
                    ) ??
                    '',
                if (toolResultBlocks[index]['name'] != null)
                  'tool_name': toolResultBlocks[index]['name'].toString(),
                if (toolResultBlocks[index]['tool_use_id'] != null)
                  'tool_call_id': toolResultBlocks[index]['tool_use_id']
                      .toString(),
                '_desktopSnapshotKey':
                    'message-$runtimeSessionId-$ordinal-toolresult-$index',
                '_desktopSnapshotKind': 'persisted',
              }),
          ];

    // Un mensaje user cuyo contenido eran SOLO bloques tool_result (formato
    // Anthropic) no es un prompt real: se proyecta como mensajes tool y no
    // deja una burbuja de usuario vacía.
    if (role == 'assistant') content = finalizedPublicAssistantText(content);
    final dropMain =
        (role == 'user' && content.isEmpty && toolResultBlocks.isNotEmpty) ||
        (!retainMediaEvidence && content.trim().isEmpty) ||
        (role == 'tool' && !retainMediaEvidence);
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
      if (retainMediaEvidence && message.name != null) 'name': message.name,
      if (retainMediaEvidence && message.toolName != null)
        'tool_name': message.toolName,
      if (retainMediaEvidence && message.toolCallId != null)
        'tool_call_id': message.toolCallId,
      if (retainMediaEvidence && message.toolCalls != null)
        'tool_calls': message.toolCalls
      else if (retainMediaEvidence && synthesizedToolCalls.isNotEmpty)
        'tool_calls': synthesizedToolCalls,
      if (message.timestamp != null)
        'timestamp': message.timestamp!.millisecondsSinceEpoch / 1000,
    });
    return dropMain ? toolResultMessages : [main, ...toolResultMessages];
  }
}

/// Conserva únicamente el pequeño contrato editorial que Hermes Desktop usa
/// para resumir eventos duraderos. Algunos gateways antiguos serializan el
/// objeto como JSON; nunca propagamos campos arbitrarios al árbol de widgets.
Map<String, dynamic>? sanitizeDelegationDisplayMetadata(Object? raw) {
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
  final rawSubagentIds = decoded['subagent_ids'];
  if (rawSubagentIds is List &&
      rawSubagentIds.isNotEmpty &&
      rawSubagentIds.length <= 64) {
    final ids = <String>[];
    var valid = true;
    for (final rawId in rawSubagentIds) {
      if (rawId is! String) {
        valid = false;
        break;
      }
      final id = rawId.trim();
      if (id.isEmpty ||
          id.length > 180 ||
          !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(id) ||
          ids.contains(id)) {
        valid = false;
        break;
      }
      ids.add(id);
    }
    final taskCount = safe['task_count'];
    if (valid && (taskCount == null || taskCount == ids.length)) {
      safe['subagent_ids'] = List<String>.unmodifiable(ids);
    }
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
