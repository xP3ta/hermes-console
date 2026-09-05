// Servicio singleton que posee el streaming SSE de los chats. Vive por encima
// del Navigator (en HermesAppState), así que la respuesta/ejecución del agente
// CONTINÚA aunque el usuario salga de la pantalla del chat. La pantalla del chat
// se "engancha" a un [ActiveChat] al abrirse y se "suelta" al cerrarse, sin
// cancelar el stream. La lista de sesiones observa [activeIds] para pintar el
// indicador de "chat en curso".
//
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/chat_event_cards.dart';
import '../models/attachment_draft.dart';
import '../models/command_descriptor.dart';
import '../models/desktop_compression_result.dart';
import '../models/desktop_context_breakdown.dart';
import '../models/desktop_model_catalog.dart';
import '../models/desktop_session_config.dart';
import '../models/desktop_session_snapshot.dart';
import '../models/home_widget_snapshot.dart';
import '../models/interactive_prompt.dart';
import '../models/prepared_turn.dart';
import '../models/session_artifact.dart';
import '../models/subagent_activity.dart';
import '../utils/chat_turn.dart';
import 'approval_policy.dart';
import 'artifact_index.dart';
import 'attachment_uploader.dart';
import 'bridge_client.dart';
import 'bridge_version.dart';
import 'command_risk.dart';
import 'compression_dispatcher.dart';
import 'connection_manager.dart';
import 'desktop_control_gateway.dart';
import 'desktop_gateway_capabilities.dart';
import 'home_widget_publisher.dart';
import 'generated_image_service.dart';
import 'local_transcript_store.dart';
import 'interactive_prompt_reducer.dart';
import 'profile_chat_mode.dart';
import 'notifications/background_listener.dart';
import 'notifications/notification_service.dart';
import 'run_registry.dart';
import 'session_config_reducer.dart';
import 'session_reconciler.dart';
import 'subagent_activity_reducer.dart';
import 'subagent_transcript_projection.dart';
import 'tui_gateway_client.dart';
import 'turn_outbox_store.dart';

part 'active_chat_cancellation.dart';
part 'active_chat_registry.dart';
part 'active_chat_turn_delivery.dart';
part 'active_chat_types.dart';

/// Hermes Desktop espera hasta cinco segundos a que el turno interrumpido deje
/// de estar busy antes de entregar la corrección capturada por barge-in.
@visibleForTesting
const activeChatVoiceBargeSettleTimeout = Duration(seconds: 5);

@visibleForTesting
String activeChatDesktopRecoveryUiMessage(Object _) =>
    'Could not recover the turn. Please try again.';

@visibleForTesting
String activeChatDesktopSnapshotFailureUiMessage(String? _) =>
    'Could not recover the turn. Please try again.';

@visibleForTesting
String activeChatDesktopRecoveryDiagnostic(Object error) {
  final code = error is TuiGatewayRpcError ? ', code=${error.code}' : '';
  return '[active-chat] Desktop recovery failed '
      '(${error.runtimeType}$code)';
}

const _sessionNotOwnedReason = 'SESSION_NOT_OWNED';
const _maxConcurrentSessionsReason = 'MAX_CONCURRENT_SESSIONS';
const _sessionCoordinationUnavailableReason =
    'SESSION_COORDINATION_UNAVAILABLE';

@visibleForTesting
bool activeChatPromptWasRejectedBeforeAcceptance(Object error) =>
    error is TuiGatewayRpcError &&
    error.method == 'prompt.submit' &&
    error.code == 4090;

@visibleForTesting
String activeChatPromptFailureUiMessage(Object error) {
  if (error is TuiGatewayRpcError && error.method == 'prompt.submit') {
    return switch (error.reason) {
      _sessionNotOwnedReason =>
        'This conversation is open in another window or device. '
            'Close it there and try again.',
      _maxConcurrentSessionsReason =>
        'Hermes has reached its maximum number of active sessions. '
            'Close another session and try again.',
      _sessionCoordinationUnavailableReason =>
        'Hermes could not reserve this conversation safely. '
            'Check the server and try again.',
      _ => 'Could not send the message. Please try again.',
    };
  }
  return 'Could not send the message. Please try again.';
}

/// Redacta únicamente el formato técnico que builds antiguas pudieron guardar
/// en el transcript local. No se usa para decidir entrega ni reintentos: esas
/// decisiones dependen del código y `error.data.reason` estructurados.
String activeChatStoredErrorUiMessage(String error) {
  if (error.trimLeft().startsWith('TuiGatewayRpcError(prompt.submit, 4090):')) {
    return 'Hermes could not reserve this conversation. '
        'Check other active sessions and try again.';
  }
  return error;
}

List<Map<String, dynamic>> _sanitizeDesktopFailureProjection(
  Iterable<Map<String, dynamic>> projected,
) => projected
    .map((message) {
      if (message['role'] != 'assistant_error' ||
          message['_desktopSnapshotKind'] != 'inflight') {
        return message;
      }
      final safe = activeChatDesktopSnapshotFailureUiMessage(null);
      return Map<String, dynamic>.unmodifiable({
        ...message,
        'content': safe,
        'error': safe,
      });
    })
    .toList(growable: true);

@visibleForTesting
bool activeChatVoiceBargeRunIsTerminal(Map<String, dynamic> snapshot) =>
    const <String>{
      'completed',
      'failed',
      'cancelled',
    }.contains((snapshot['status'] ?? '').toString().trim().toLowerCase());

/// Espera pollable para el transporte REST, cuyo `/stop` oficial responde
/// `stopping` antes de que el run sea realmente terminal.
@visibleForTesting
Future<void> waitForActiveChatVoiceBargeTerminal({
  required Future<Map<String, dynamic>> Function() readStatus,
  Duration timeout = activeChatVoiceBargeSettleTimeout,
  Duration pollInterval = const Duration(milliseconds: 100),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) return;
    Map<String, dynamic> snapshot;
    try {
      snapshot = await readStatus().timeout(remaining);
    } catch (_) {
      // 404 significa que el run ya salió del registro; red/gateway antiguo
      // degradan al mismo timeout best-effort que Desktop.
      return;
    }
    if (activeChatVoiceBargeRunIsTerminal(snapshot)) return;
    final afterRead = deadline.difference(DateTime.now());
    if (afterRead <= Duration.zero) return;
    final delay = pollInterval < afterRead ? pollInterval : afterRead;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
  }
}

/// Los marcadores `⟦img:…⟧` solo sirven para reconstruir miniaturas locales.
/// Nunca deben cruzar al servidor: contienen rutas privadas de Android que el
/// agente no puede leer y que pueden reaparecer desde el historial.
@visibleForTesting
String sanitizeRemoteChatText(String text) => text
    .split('\n')
    .where((line) => !RegExp(r'^\s*⟦img:[^⟧]+⟧\s*$').hasMatch(line))
    .join('\n')
    .trimRight();

/// `hermes-agent` es el alias del endpoint OpenAI-compatible, no un modelo de
/// proveedor válido para `/v1/runs`. Omitirlo deja que Hermes use su modelo
/// activo real.
@visibleForTesting
String? explicitRunModel(String model) {
  final value = model.trim();
  if (value.isEmpty || value.toLowerCase() == 'hermes-agent') return null;
  return value;
}

const _artifactContainerKeys = <String>{
  'attachment',
  'attachments',
  'artifact',
  'artifacts',
  'generated_image',
  'generated_images',
  'tool_result',
  'tool_results',
};

bool _rawMessageMayContainArtifact(Map<String, dynamic> message) {
  final content = message['content'];
  if (content is Map || content is List) return true;
  final role = message['role']?.toString().toLowerCase();
  final context = message['context'];
  if (role == 'tool' && (context is Map || context is List)) return true;
  for (final key in _artifactContainerKeys) {
    final value = message[key];
    if (value is Map || value is List) return true;
  }
  return false;
}

bool _messageMayContainArtifact(DesktopSessionMessage message) =>
    message.content is Map ||
    message.content is List ||
    message.artifactContainers.isNotEmpty ||
    (message.role == DesktopSessionMessageRole.tool &&
        (message.context is Map || message.context is List));

@visibleForTesting
Map<String, dynamic> normalizeTranscriptMessageForDisplay(
  Map<String, dynamic> message,
) {
  final normalized = Map<String, dynamic>.from(message);
  final role = message['role'];
  normalized['role'] = role is String ? role : role?.toString() ?? 'assistant';
  normalized['content'] =
      desktopSessionDisplayText(message['content']) ??
      desktopSessionDisplayText(message['text']) ??
      '';
  final displayKind = effectiveUserDisplayKind(normalized);
  if (displayKind.isNotEmpty &&
      (normalized['display_kind']?.toString().trim().isEmpty ?? true)) {
    normalized['display_kind'] = displayKind;
  }
  return normalized;
}

List<Map<String, dynamic>> _normalizedNewestFirst(
  Iterable<Map<String, dynamic>> chronological,
) => _associateGeneratedImagesNewestFirst(
  chronological
      .map(normalizeTranscriptMessageForDisplay)
      .toList(growable: false)
      .reversed
      .toList(growable: true),
);

const _generatedImagesMetadataKey = '_generatedImages';

String? _nonEmptyMetadataString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _toolCallId(
  Map<String, dynamic> value, {
  bool allowGenericId = false,
}) => _nonEmptyMetadataString(
  value['tool_call_id'] ??
      value['tool_id'] ??
      value['call_id'] ??
      (allowGenericId ? value['id'] : null),
);

String? _toolName(Map<String, dynamic> value) => _nonEmptyMetadataString(
  value['tool_name'] ?? value['name'] ?? value['tool'],
);

bool _isImageGenerateName(String? value) =>
    value?.trim().toLowerCase() == 'image_generate';

Iterable<({String id, String name})> _messageToolCalls(
  Map<String, dynamic> message,
) sync* {
  final rawCalls = message['tool_calls'];
  if (rawCalls is! List) return;
  for (final raw in rawCalls) {
    if (raw is! Map) continue;
    final call = Map<String, dynamic>.from(raw);
    final function = call['function'];
    final functionMap = function is Map
        ? Map<String, dynamic>.from(function)
        : const <String, dynamic>{};
    final id = _toolCallId(call, allowGenericId: true);
    final name = _nonEmptyMetadataString(
      functionMap['name'] ?? call['name'] ?? call['tool_name'],
    );
    if (id != null && name != null) yield (id: id, name: name);
  }
}

Map<String, dynamic> _generatedImageMetadata(
  GeneratedImageReference reference,
  String toolCallId,
) => Map<String, dynamic>.unmodifiable({
  'kind': reference.kind.name,
  'source': reference.source,
  if (reference.basename != null) 'basename': reference.basename,
  'tool_call_id': toolCallId,
  if (reference.echoSources.isNotEmpty)
    'echo_sources': List<String>.unmodifiable(reference.echoSources),
});

final RegExp _generatedImageBasenameRe = RegExp(
  r'^[A-Za-z0-9._-]+\.(?:png|jpe?g|webp)$',
  caseSensitive: false,
);

Map<String, dynamic>? _normalizedGeneratedImageMetadata(
  Map<String, dynamic> value,
) {
  final toolCallId = _nonEmptyMetadataString(value['tool_call_id']);
  if (toolCallId == null) return null;
  final rawKind = _nonEmptyMetadataString(value['kind']);
  final rawSource = _nonEmptyMetadataString(value['source']);
  final rawBasename = _nonEmptyMetadataString(value['basename']);

  late final GeneratedImageSourceKind kind;
  late final String source;
  String? basename;
  if (rawKind == GeneratedImageSourceKind.https.name) {
    if (rawSource == null) return null;
    final parsed = GeneratedImageService.imageReferencesFromResult({
      'success': true,
      'image': rawSource,
    });
    if (parsed.isEmpty ||
        parsed.single.kind != GeneratedImageSourceKind.https) {
      return null;
    }
    kind = GeneratedImageSourceKind.https;
    source = parsed.single.source;
  } else if (rawKind == null ||
      rawKind == GeneratedImageSourceKind.serverCache.name) {
    // Compatibilidad con snapshots previos a `kind`/`source`: un basename
    // válido siempre representaba el cache del servidor servido por Bridge.
    if (rawBasename == null ||
        !_generatedImageBasenameRe.hasMatch(rawBasename)) {
      return null;
    }
    kind = GeneratedImageSourceKind.serverCache;
    basename = rawBasename;
    source = rawSource ?? rawBasename;
  } else {
    return null;
  }

  final echoSources = value['echo_sources'];
  return Map<String, dynamic>.unmodifiable({
    'kind': kind.name,
    'source': source,
    'basename': ?basename,
    'tool_call_id': toolCallId,
    if (echoSources is List)
      'echo_sources': List<String>.unmodifiable(
        echoSources
            .whereType<String>()
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty)
            .toSet(),
      ),
  });
}

List<Map<String, dynamic>> _generatedImageMetadataOf(
  Map<String, dynamic> message,
) {
  final raw = message[_generatedImagesMetadataKey];
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map<Map<String, dynamic>>((value) => Map<String, dynamic>.from(value))
      .map(_normalizedGeneratedImageMetadata)
      .whereType<Map<String, dynamic>>()
      .toList(growable: false);
}

List<Map<String, dynamic>> _mergeGeneratedImageMetadata(
  Iterable<Map<String, dynamic>> current,
  Iterable<Map<String, dynamic>> incoming,
) {
  final merged = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final value in [...current, ...incoming]) {
    final normalized = _normalizedGeneratedImageMetadata(value);
    if (normalized == null) continue;
    final toolCallId = normalized['tool_call_id'] as String;
    final source = normalized['source'] as String;
    if (!seen.add('$toolCallId\u0000$source')) continue;
    merged.add(normalized);
  }
  return List<Map<String, dynamic>>.unmodifiable(merged);
}

/// Asocia resultados persistidos de `image_generate` con la siguiente
/// respuesta final del asistente. La entrada y la salida son newest-first; el
/// escaneo se hace cronológicamente para respetar tool_call → tool result →
/// assistant incluso cuando las filas llegan tras un backfill.
List<Map<String, dynamic>> _associateGeneratedImagesNewestFirst(
  List<Map<String, dynamic>> messages,
) {
  if (messages.isEmpty) return messages;
  final imageCallIds = <String>{};
  final pending = <Map<String, dynamic>>[];
  final additions = <int, List<Map<String, dynamic>>>{};

  for (var index = messages.length - 1; index >= 0; index--) {
    final message = messages[index];
    final role = message['role']?.toString().trim().toLowerCase();
    if (role == 'user' && message['_steer'] != true) {
      // Un resultado sin cierre pertenece como máximo al turno anterior. No
      // puede atravesar una nueva petición y terminar dentro de la respuesta
      // siguiente. Las correcciones `_steer` sí forman parte del mismo turno.
      pending.clear();
      imageCallIds.clear();
      continue;
    }
    if (role == 'assistant') {
      final calls = _messageToolCalls(message).toList(growable: false);
      if (pending.isNotEmpty && calls.isEmpty && message['_pipeline'] != true) {
        additions[index] = List<Map<String, dynamic>>.of(pending);
        pending.clear();
      }
      for (final call in calls) {
        if (_isImageGenerateName(call.name)) imageCallIds.add(call.id);
      }
      continue;
    }
    if (role != 'tool') continue;
    final callId = _toolCallId(message);
    if (callId == null) continue;
    final name = _toolName(message);
    if (!imageCallIds.contains(callId) && !_isImageGenerateName(name)) {
      continue;
    }
    final rawResult =
        message['result'] ?? message['output'] ?? message['content'];
    final references = GeneratedImageService.imageReferencesFromResult(
      rawResult,
    );
    for (final reference in references) {
      pending.add(_generatedImageMetadata(reference, callId));
    }
  }

  if (additions.isEmpty) return messages;
  final projected = List<Map<String, dynamic>>.of(messages);
  for (final entry in additions.entries) {
    final message = projected[entry.key];
    final merged = _mergeGeneratedImageMetadata(
      _generatedImageMetadataOf(message),
      entry.value,
    );
    if (merged.isEmpty) continue;
    projected[entry.key] = Map<String, dynamic>.unmodifiable({
      ...message,
      _generatedImagesMetadataKey: merged,
    });
  }
  return projected;
}

/// Identidad para deduplicar filas del transcript entre páginas.
///
/// Sin un id durable no existe evidencia de igualdad: dos filas con el mismo
/// rol/contenido pueden ser turnos legítimos distintos y deben conservarse.
bool _desktopSnapshotTranscriptIsComplete(DesktopSessionSnapshot snapshot) {
  if (!snapshot.messagesProvided ||
      !snapshot.messagesFullyParsed ||
      snapshot.hydrating ||
      !_desktopSnapshotIdentitiesAreUnambiguous(snapshot.messages)) {
    return false;
  }
  final expectedCount = snapshot.messageCount;
  return expectedCount == null || snapshot.messages.length == expectedCount;
}

bool _desktopSnapshotIdentitiesAreUnambiguous(
  Iterable<DesktopSessionMessage> messages,
) {
  final seen = <TranscriptMessageIdentity>[];
  for (final message in messages) {
    if (!message.identityAliasesConsistent) return false;
    final identity = _desktopSnapshotTranscriptIdentity(message);
    if (identity == null) continue;
    if (seen.any(identity.sharesExactCoordinate)) return false;
    seen.add(identity);
  }
  return true;
}

bool _fallbackExactlyMatchesDesktopSnapshot(
  List<Map<String, dynamic>> fallbackNewestFirst,
  DesktopSessionSnapshot snapshot,
) {
  if (snapshot.messages.isEmpty ||
      fallbackNewestFirst.length != snapshot.messages.length ||
      !_transcriptRowsHaveUnambiguousIdentityEvidence(fallbackNewestFirst) ||
      !_desktopSnapshotIdentitiesAreUnambiguous(snapshot.messages)) {
    return false;
  }
  for (var index = 0; index < fallbackNewestFirst.length; index++) {
    final fallbackIdentity = _transcriptMessageIdentity(
      fallbackNewestFirst[index],
    );
    final snapshotIdentity = _desktopSnapshotTranscriptIdentity(
      snapshot.messages[snapshot.messages.length - index - 1],
    );
    if (fallbackIdentity == null ||
        snapshotIdentity == null ||
        !fallbackIdentity.matches(snapshotIdentity)) {
      return false;
    }
  }
  return true;
}

bool _tailPageProvesTranscriptComplete(SessionMessagesPage page) {
  if (page.offset != 0 ||
      !page.messagesFullyParsed ||
      !page.paginationFullyParsed ||
      !_transcriptRowsHaveUnambiguousIdentityEvidence(page.messages)) {
    return false;
  }
  final limit = page.limit;
  return limit == null || limit <= 0 || page.rawMessageCount < limit;
}

TranscriptMessageIdentity? _transcriptMessageIdentity(
  Map<String, dynamic> message,
) => canonicalTranscriptIdentity(message);

DateTime? _transcriptTimestamp(Map<String, dynamic> message) {
  final value = message['timestamp'];
  if (value is! num || !value.isFinite || value < 0) return null;
  try {
    return DateTime.fromMicrosecondsSinceEpoch(
      (value.toDouble() * Duration.microsecondsPerSecond).round(),
      isUtc: true,
    );
  } on RangeError {
    return null;
  }
}

TranscriptMessageIdentity? _desktopSnapshotTranscriptIdentity(
  DesktopSessionMessage message,
) {
  if (!message.identityAliasesConsistent) return null;
  final identity = TranscriptMessageIdentity(
    messageId: message.stableId,
    rowId: message.rowId,
  );
  return identity.isDurable ? identity : null;
}

bool _identityCollectionContains(
  Iterable<TranscriptMessageIdentity> identities,
  TranscriptMessageIdentity candidate,
) => identities.any(candidate.matches);

bool _removeMatchingIdentities(
  List<TranscriptMessageIdentity> identities,
  TranscriptMessageIdentity candidate,
) {
  final overlaps = identities
      .where(candidate.sharesExactCoordinate)
      .toList(growable: false);
  if (overlaps.length != 1 || !candidate.matches(overlaps.single)) {
    return false;
  }
  return identities.remove(overlaps.single);
}

TranscriptMessageIdentity? _uniqueTranscriptIdentityMatch(
  TranscriptMessageIdentity candidate,
  Iterable<Map<String, dynamic>> transcript,
) {
  TranscriptMessageIdentity? found;
  for (final message in transcript) {
    if (!transcriptIdentityAliasesAreConsistent(message)) {
      if (transcriptIdentityAliasesShareExactCoordinate(message, candidate)) {
        return null;
      }
      continue;
    }
    final identity = _transcriptMessageIdentity(message);
    if (identity == null || !candidate.sharesExactCoordinate(identity)) {
      continue;
    }
    if (!candidate.matches(identity) || found != null) return null;
    found = identity;
  }
  final match = found;
  if (match == null) return null;

  // La página entrante puede declarar solo una coordenada. Verifica también
  // la otra coordenada de la fila visible enriquecida para no confirmar, por
  // ejemplo, (m1, 42) si el transcript contiene además (m2, 42).
  var overlaps = 0;
  for (final message in transcript) {
    if (!transcriptIdentityAliasesAreConsistent(message)) {
      if (transcriptIdentityAliasesShareExactCoordinate(message, match)) {
        return null;
      }
      continue;
    }
    final identity = _transcriptMessageIdentity(message);
    if (identity == null || !match.sharesExactCoordinate(identity)) continue;
    if (!match.matches(identity)) return null;
    overlaps++;
  }
  return overlaps == 1 ? match : null;
}

List<TranscriptMessageIdentity> _transcriptIdentities(
  Iterable<Map<String, dynamic>> messages,
) => <TranscriptMessageIdentity>[
  for (final message in messages) ?_transcriptMessageIdentity(message),
];

bool _hasDurableTranscriptIdentity(Map<String, dynamic> message) =>
    _transcriptMessageIdentity(message) != null;

bool _allTranscriptRowsHaveDurableIds(Iterable<Map<String, dynamic>> messages) {
  final seen = <TranscriptMessageIdentity>[];
  for (final message in messages) {
    final identity = _transcriptMessageIdentity(message);
    if (identity == null || seen.any(identity.sharesExactCoordinate)) {
      return false;
    }
    seen.add(identity);
  }
  return true;
}

bool _transcriptRowsHaveUnambiguousIdentityEvidence(
  Iterable<Map<String, dynamic>> messages,
) {
  final seen = <TranscriptMessageIdentity>[];
  for (final message in messages) {
    if (!transcriptIdentityAliasesAreConsistent(message)) return false;
    final identity = _transcriptMessageIdentity(message);
    if (identity == null) continue;
    if (seen.any(identity.sharesExactCoordinate)) return false;
    seen.add(identity);
  }
  return true;
}

bool _isKnownLocalTranscriptProjection(
  List<Map<String, dynamic>> newestFirst,
  int index,
) {
  final message = newestFirst[index];
  if (message['role'] == 'assistant_error' ||
      message['_steer'] == true ||
      message['_pipeline'] == true ||
      message['_desktopInterim'] == true ||
      message['_desktopSnapshotKind'] == 'inflight' ||
      message['_cancelled'] == true ||
      message['_cancelledUser'] == true) {
    return true;
  }
  if (!isRealUserTurn(message) || index == 0) return false;
  final newer = newestFirst[index - 1];
  if (newer['role'] == 'assistant_error') {
    return (newer['_prompt'] ?? '').toString() ==
        (message['content'] ?? '').toString();
  }
  return newer['role'] == 'assistant' &&
      (newer['_pipeline'] == true ||
          newer['_desktopSnapshotKind'] == 'inflight');
}

bool _isLiveTranscriptProjection(Map<String, dynamic> message) =>
    message['_desktopSnapshotKind'] == 'inflight' ||
    message['_pipeline'] == true ||
    message['_optimistic'] == true;

int? _durableTranscriptCoverageCount(Iterable<Map<String, dynamic>> messages) {
  final identities = <TranscriptMessageIdentity>[];
  for (final message in messages) {
    if (_isLiveTranscriptProjection(message)) continue;
    final identity = _transcriptMessageIdentity(message);
    // Una fila durable sin identidad sigue ocupando una posición real del
    // transcript, pero no se puede comparar de forma segura con messageCount.
    // Ignorarla haría que 2 filas visibles pareciesen coincidir con count=1.
    if (identity == null || identities.any(identity.sharesExactCoordinate)) {
      return null;
    }
    identities.add(identity);
  }
  return identities.length;
}

/// Antepone una página de mensajes ANTERIORES a la lista viva (newest-first:
/// los más antiguos van al final), deduplicando filas ya presentes. El drift
/// de offsets (mensajes persistidos tras la hidratación) hace normal el
/// solape; conserva la identidad de referencia cuando no cambia nada.
List<Map<String, dynamic>> _mergeOlderTranscriptPage(
  List<Map<String, dynamic>> existingNewestFirst,
  List<Map<String, dynamic>> olderPageNewestFirst,
) {
  if (existingNewestFirst.isEmpty) return olderPageNewestFirst;
  if (olderPageNewestFirst.isEmpty) {
    return existingNewestFirst;
  }
  final existingIdentities = _transcriptIdentities(existingNewestFirst);
  final fresh = olderPageNewestFirst
      .where((message) {
        final identity = _transcriptMessageIdentity(message);
        if (identity == null) return true;
        final overlaps = existingIdentities
            .where(identity.sharesExactCoordinate)
            .toList(growable: false);
        if (overlaps.length == 1 && identity.matches(overlaps.single)) {
          return false;
        }
        return true;
      })
      .toList(growable: false);
  if (fresh.isEmpty) return existingNewestFirst;
  return <Map<String, dynamic>>[...existingNewestFirst, ...fresh];
}

/// Estado vivo de un chat con streaming. Es la fuente de verdad de los mensajes,
/// el trace y el estado del pipeline mientras el chat está activo. Sobrevive al
/// pop de la ruta del chat porque lo posee [ActiveChatService], no el widget.
class ActiveChat {
  static final Stopwatch _defaultMonotonicClock = Stopwatch()..start();
  static const Duration _voiceBargeHandoffRetention = Duration(seconds: 30);
  static const Duration _desktopRecoveryDelayCap = Duration(seconds: 30);
  static const Duration _desktopRecoveryFallbackDelay = Duration(seconds: 1);

  static List<Duration> _normalizeDesktopRecoveryBackoff(
    List<Duration> configured,
  ) {
    final normalized = <Duration>[];
    for (final delay in configured) {
      if (delay <= Duration.zero) {
        if (normalized.isEmpty) normalized.add(Duration.zero);
        continue;
      }
      normalized.add(
        delay > _desktopRecoveryDelayCap ? _desktopRecoveryDelayCap : delay,
      );
    }
    if (normalized.isEmpty) normalized.add(Duration.zero);
    if (normalized.last <= Duration.zero) {
      normalized.add(_desktopRecoveryFallbackDelay);
    }
    return List<Duration>.unmodifiable(normalized);
  }

  final SavedConnection connection;
  final String sessionId;
  final String logicalSessionId;
  String sessionTitle;
  NotificationChatSurface notificationSurface;
  String? notificationRoomId;

  final NotificationService? _notifications;
  bool? _notifyRepliesOverride;
  final ApprovalPolicyService? _policy;
  final VoidCallback _onTerminal;
  final VoidCallback? _onUnused;
  final Future<void> Function()? _beforeTerminalNotification;

  /// Se invoca cuando el run obtiene su id. La capa de servicio lo usa para
  /// arrancar el foreground service y registrar la vigilancia en 2º plano, de
  /// modo que el proceso (y con él el SSE) siga vivo aunque la app pase atrás.
  final void Function(String runId)? _onRunStarted;

  /// Solo arranca el foreground service (sin vigilancia de runs). Lo usa el chat
  /// LOCAL por el bridge: su turno es una llamada HTTP larga a `hermes -z`, no un
  /// run pollable, pero el proceso debe seguir vivo si la app pasa a 2º plano.
  final Future<void> Function()? _onForegroundKeepAlive;
  final ValueChanged<int?>? _onObservedFirstTokenLatency;
  final ValueChanged<ActiveChatEvent>? _onEvent;
  final List<CancelledTurnTombstone> _cancelledTurnTombstones;
  final Future<void> Function(CancelledTurnTombstone)? _onCancelledTurn;
  Future<void> _cancelledTurnPersistence = Future<void>.value();
  bool _cancelledTurnPersistencePending = false;
  bool _cancelledTurnPersistenceFailed = false;
  final Map<String, CancelledTurnTombstone> _pendingCancelledTombstoneUpdates =
      {};
  int _cancelledTombstoneRevision = 0;
  Future<void>? _cancelledTombstoneUpdateFlight;
  Future<void>? _durableCancelFlight;
  final int Function() _monotonicMicros;
  int? _responseStartedAtMicros;
  int? _observedFirstTokenLatencyMs;

  late ApiClient _api;
  final StoredSessionMessageLoader? _storedMessageLoader;
  String? _sessionProfileOwner;
  String _storedSessionProfile = '';
  bool _desktopStoredSessionKnownMissing = false;

  /// Canal oficial de Hermes Desktop (`/api/ws`). En producción es el camino
  /// remoto preferido; en tests que inyectan [ApiClient] queda desactivado salvo
  /// que se inyecte explícitamente un fake.
  final HermesDesktopGateway? _desktopGateway;
  final Future<AttachmentUploadResult> Function(
    SavedConnection,
    AttachmentDraft,
  )
  _attachmentUploader;
  final BridgeClientFactory _bridgeClientFactory;
  final BridgeProvisioner _bridgeProvisioner;
  final Future<bool> Function() _turnIdempotencyCapability;
  bool? _turnIdempotencySupported;
  bool _turnIdempotencyInvalid = false;
  StreamSubscription<TuiGatewayEvent>? _desktopEventSubscription;
  Completer<void>? _desktopInterruptDrain;
  bool _discardLateInterruptTerminal = false;
  Timer? _voiceBargeHandoffTimer;
  bool _voiceBargeHandoffPending = false;
  String? _desktopRuntimeSessionId;
  String? _retiringDesktopRuntimeSessionId;
  String? _desktopStoredSessionId;
  bool _usingDesktopGateway = false;
  int? _recoveringDesktopTurnEpoch;
  Future<void>? _desktopTurnRecovery;
  int _messageLoadEpoch = 0;
  int _desktopBindEpoch = 0;
  int? _activeTurnTranscriptBoundaryEpoch;
  TranscriptMessageIdentity? _activeTurnTranscriptBoundaryIdentity;
  String? _activeTurnTranscriptBoundarySessionId;
  String? _activeTurnTranscriptBoundaryProfile;
  int _desktopInterimSerial = 0;
  int _localTranscriptProjectionSerial = 0;
  String? _pendingDesktopInterimKey;
  final _AssistantNarrationProjection _assistantNarration =
      _AssistantNarrationProjection();
  int _desktopSessionEpoch = 0;
  int _sessionConfigRequestEpoch = 0;
  int _sessionInfoEpoch = 0;
  bool _desktopCompressionInFlight = false;
  bool _desktopAutoCompacting = false;
  bool _suppressTerminalHydrationAfterCompaction = false;
  String? _desktopCompactionLineageId;
  SessionConfigScope? _sessionConfigScope;
  SessionConfigReducerState _sessionConfigState =
      const SessionConfigReducerState.empty();

  DesktopSessionRuntimeInfo _desktopRuntimeInfo =
      const DesktopSessionRuntimeInfo();
  String? _desktopLiveStatus;
  ChatActivityKind? _lastLiveActivityKind;
  // `snapshot.started_at` es el inicio del runtime, no del turno actual.
  DateTime? _desktopStartedAt;
  DateTime? _desktopTurnStartedAt;
  InteractivePromptState _interactivePrompts =
      const InteractivePromptState.empty();
  final Map<InteractivePromptKey, Future<DesktopPromptResponse>> _batchLocks =
      {};
  SubagentActivityState? _subagentActivities;
  String? _subagentTranscriptTurnAnchor;
  final Set<SubagentActivityKey> _pendingSubagentInterrupts = {};
  ArtifactIndexSnapshot? _artifactIndex;
  ArtifactIndexScope? _artifactScope;
  List<ArtifactTranscriptEntry> _pendingArtifactTranscript = const [];
  int _artifactTranscriptRevision = 0;

  bool get turnIdempotencyInvalid => _turnIdempotencyInvalid;

  /// `null` hereda el ajuste global; `false` silencia únicamente este lineage.
  /// Un `true` no puede saltarse un ajuste global desactivado: esa política
  /// sigue aplicándose dentro de [NotificationService].
  set notifyRepliesOverride(bool? value) => _notifyRepliesOverride = value;
  bool get _shouldNotifyReplies => _notifyRepliesOverride != false;

  DesktopSessionRuntimeInfo get desktopRuntimeInfo => _desktopRuntimeInfo;
  String? get desktopRuntimeSessionId => _desktopRuntimeSessionId;
  String? get desktopLiveStatus => _desktopLiveStatus;

  void _rememberDesktopLiveStatus(String? value, {required bool running}) {
    final normalized = value?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      _desktopLiveStatus = normalized;
    } else if (!running) {
      _desktopLiveStatus = null;
    }
  }

  HermesDesktopControlGateway? get desktopControlGateway {
    final gateway = _desktopGateway;
    return gateway is HermesDesktopControlGateway
        ? gateway as HermesDesktopControlGateway
        : null;
  }

  DesktopGatewayCapabilityState desktopCapabilityState(
    DesktopGatewayCapability capability,
  ) {
    final gateway = _desktopGateway;
    return gateway is HermesDesktopSessionActivityGateway
        ? (gateway as HermesDesktopSessionActivityGateway).capabilityState(
            capability,
          )
        : DesktopGatewayCapabilityState.unknown;
  }

  /// Inicio del runtime remoto (equivalente a sessionStartedAt en Desktop).
  DateTime? get desktopStartedAt => _desktopStartedAt;

  /// Inicio del turno visible (equivalente a turnStartedAt en Desktop).
  DateTime? get desktopTurnStartedAt => _desktopTurnStartedAt;
  bool get hasDesktopRuntime => _desktopRuntimeSessionId != null;
  bool get desktopManualCompressionInFlight => _desktopCompressionInFlight;
  bool get desktopCompressionInFlight =>
      _desktopCompressionInFlight || _desktopAutoCompacting;
  bool get desktopAutoCompacting => _desktopAutoCompacting;
  String get desktopCompactionLineageId =>
      _desktopCompactionLineageId ?? logicalSessionId;
  bool get canLoadDesktopContextBreakdown =>
      _desktopRuntimeSessionId != null &&
      _desktopGateway is HermesDesktopContextUsageGateway;
  bool get canCompressDesktopSession =>
      !connection.readOnly &&
      _desktopRuntimeSessionId != null &&
      _desktopGateway is HermesDesktopCommandGateway;
  bool get canConfigureDesktopSession =>
      !connection.readOnly &&
      _desktopRuntimeSessionId != null &&
      _desktopGateway is HermesDesktopSessionConfigGateway;

  SessionEffectiveConfig get effectiveSessionConfig {
    final scope = _sessionConfigScope;
    return scope == null
        ? const SessionEffectiveConfig()
        : _sessionConfigState[scope]?.effective ??
              const SessionEffectiveConfig();
  }

  PendingSessionConfigChange? pendingSessionConfigChange(
    DesktopSessionConfigKey key,
  ) {
    final scope = _sessionConfigScope;
    return scope == null ? null : _sessionConfigState.changeFor(scope, key);
  }

  void stageFirstSubmitConfig(DesktopSessionCreateConfig config) {
    if (_desktopRuntimeSessionId == null) _stagedFirstSubmitConfig = config;
  }

  InteractivePromptState get interactivePrompts => _interactivePrompts;

  /// First live prompt owned by the currently attached runtime. Other chats
  /// keep their own parked state in their own [ActiveChat] instance.
  InteractivePromptEntry? get pendingInteractivePrompt {
    final runtimeId = _desktopRuntimeSessionId;
    if (runtimeId == null) return null;
    for (final entry in _interactivePrompts.forRuntime(runtimeId)) {
      if (entry.needsInput && entry.request != null) return entry;
    }
    return null;
  }

  bool get needsInput =>
      pendingApproval != null || pendingInteractivePrompt != null;

  List<SubagentActivity> get subagentActivities =>
      _subagentActivities?.activities.toList(growable: false) ?? const [];

  bool isSubagentInterruptPending(SubagentActivity activity) =>
      _pendingSubagentInterrupts.contains(activity.key);

  bool canInterruptSubagent(SubagentActivity activity) {
    if (connection.readOnly ||
        activity.isTerminal ||
        activity.subagentId == null) {
      return false;
    }
    final current = _subagentActivities;
    if (current == null || current.scope != activity.key.scope) return false;
    if (!identical(current[activity.key], activity)) return false;
    final gateway = _desktopGateway;
    if (gateway is! HermesDesktopSubagentGateway) return false;
    final capability = (gateway as HermesDesktopSubagentGateway)
        .capabilityState(DesktopGatewayCapability.subagentInterrupt);
    return capability != DesktopGatewayCapabilityState.unsupported &&
        capability != DesktopGatewayCapabilityState.invalid;
  }

  /// Detiene un único hijo mediante el RPC oficial. El reducer no cambia a
  /// cancelado hasta recibir un evento autoritativo del servidor.
  Future<bool> interruptSubagent(SubagentActivity activity) async {
    if (!canInterruptSubagent(activity) ||
        !_pendingSubagentInterrupts.add(activity.key)) {
      throw StateError('Subagent interrupt is unavailable');
    }
    _emit(ActiveChatEvent.subagentActivity);
    final gateway = _desktopGateway as HermesDesktopSubagentGateway;
    try {
      final result = await gateway.interruptSubagent(activity.subagentId!);
      if (_disposed || _subagentActivities?.scope != activity.key.scope) {
        return false;
      }
      return result.found;
    } finally {
      final changed = _pendingSubagentInterrupts.remove(activity.key);
      if (changed && !_disposed) _emit(ActiveChatEvent.subagentActivity);
    }
  }

  /// Builds the session artifact index only when its view is opened. The
  /// pending input contains structured messages only, never the full text
  /// transcript, and comes from a snapshot/REST response already loaded by the
  /// chat. Reopening the same revision returns the cached immutable result.
  List<SessionArtifact> resolveSessionArtifacts() {
    final scope = _artifactScope;
    if (scope == null) return const [];
    final policy = _artifactPolicy();
    _artifactIndex = ArtifactIndex.resolve(
      previous: _artifactIndex,
      scope: scope,
      transcriptRevision: _artifactTranscriptRevision,
      transcript: _pendingArtifactTranscript,
      policy: policy,
    );
    return _artifactIndex!.artifacts;
  }

  @visibleForTesting
  ArtifactIndexSnapshot? get resolvedArtifactIndex => _artifactIndex;

  /// index 0 = mensaje más nuevo (el ListView del chat es reverse:true).
  List<Map<String, dynamic>> messages = [];
  bool messagesLoaded = false;

  /// Bookkeeping de la hidratación paginada del transcript (Hermes Agent
  /// 0.20, upstream 577093def). La carga inicial solo pide la cola (~120);
  /// si la página vino llena, quedan mensajes anteriores disponibles bajo
  /// demanda. Los offsets se miden hacia atrás desde el mensaje más reciente.
  static const int _transcriptPageSize = 120;
  bool _earlierMessagesAvailable = false;
  int _earlierMessagesNextOffset = 0;
  bool _earlierMessagesInFlight = false;

  /// Un snapshot que omite mensajes puede demostrar que la proyección visible
  /// ya no cubre la cola actual. En ese caso el siguiente gesto debe hidratar
  /// `offset=0` antes de continuar con las páginas anteriores.
  bool _needsTranscriptTailHydration = false;

  /// Filas conservadas provisionalmente cuando una cola paginada nueva no
  /// comparte ancla con lo visible. Si una página posterior no confirma sus
  /// ids antes de alcanzar el inicio absoluto, pertenecían a una proyección
  /// compactada vieja y se retiran entonces, nunca durante el refresh.
  final List<TranscriptMessageIdentity>
  _unconfirmedRetainedTranscriptIdentities = <TranscriptMessageIdentity>[];

  /// Evidencia sobre el alcance de la ventana visible. `unknown` y `partial`
  /// fallan cerrado: solo una lectura one-shot, una página final o un snapshot
  /// que incluya mensajes permiten proyectar un tombstone `firstUser`.
  _TranscriptExtent _transcriptExtent = _TranscriptExtent.unknown;

  /// Una fila REST descartada deja un hueco durable aunque páginas posteriores
  /// alcancen el inicio absoluto. Se limpia únicamente cuando una fuente
  /// autoritativa y completa sustituye toda la cobertura, no al terminar el
  /// backfill que contiene el hueco.
  bool _transcriptCoverageHasParseGap = false;

  /// Revisión transaccional del cursor/cobertura. Un refresh y un backfill
  /// pueden compartir `_messageLoadEpoch` cuando el gesto de scroll empieza
  /// después del refresh; esta revisión impide que la respuesta pedida con el
  /// cursor anterior aterrice sobre el bookkeeping que el refresh ya reemplazó.
  int _transcriptCoverageRevision = 0;

  /// Resume diferido (Hermes Agent 0.20, upstream 60be8ef26): el ack de
  /// `session.resume` llega con `hydrating:true` y el historial se carga en
  /// segundo plano; `session.resume_progress` anuncia el desenlace.
  bool _desktopHistoryHydrating = false;
  bool _desktopHistoryNeedsHydration = false;
  int? _desktopHydrationExpectedMessageCount;
  Future<void>? _desktopHistoryHydrationFlight;
  int? _desktopHistoryHydrationFlightEpoch;
  bool? _desktopHydrationOutcome;
  Completer<bool>? _desktopHydrationWaiter;

  /// Quedan mensajes anteriores en el servidor más allá de lo ya cargado.
  bool get hasEarlierMessages => _earlierMessagesAvailable;

  bool get _transcriptIsComplete =>
      _transcriptExtent == _TranscriptExtent.complete &&
      !_transcriptCoverageHasParseGap;

  /// El runtime enlazado está hidratando su historial en segundo plano.
  bool get isHydratingDesktopHistory => _desktopHistoryHydrating;

  final List<ChatTraceEvent> trace = [];
  // Projection-only tracker for Voz. It intentionally does not rewrite the
  // approved chat trace: progress frames are coalesced here while the visible
  // cards keep their established semantics.
  final List<({String? callId, String label})> _activeVoiceTools = [];
  bool traceActive = false;
  ChatPipelineState state = ChatPipelineState.idle;
  String lastPrompt = '';

  /// Modelo y perfil del último turno. Los reutiliza el fallback de cola para
  /// enviar una indicación como turno siguiente cuando `session.redirect` no está
  /// disponible o el agente ya no puede aceptarla en el turno vivo.
  String _lastModel = '';
  String _turnProfile = '';
  DesktopSessionCreateConfig _turnSessionConfig =
      const DesktopSessionCreateConfig();
  DesktopSessionCreateConfig _stagedFirstSubmitConfig =
      const DesktopSessionCreateConfig();

  ActiveTurnDelivery? _activeTurnDelivery;

  /// Evidencia viva del turno, accesible al reenganchar una pantalla. Mientras
  /// exista, la reapertura no debe reinterpretar `submitting` como process death.
  ActiveTurnDelivery? get activeTurnDelivery => _activeTurnDelivery;

  /// Retira un adjunto del turno vivo y revoca la asociación de imagen que ya
  /// hubiese aceptado Desktop. Un remove durante el RPC queda cubierto por el
  /// attempt fence del callback; este camino cubre el intervalo posterior al
  /// ACK de `image.attach_bytes` y anterior a `prompt.submit`.
  Future<bool> removeActiveAttachment(String localId) async {
    final delivery = _activeTurnDelivery;
    if (delivery == null) return false;
    final previous = await delivery.removeAttachment(localId);
    if (previous == null) return false;
    final remoteRef = previous.remoteRef;
    final remoteSessionId = previous.remoteSessionId;
    final gateway = _desktopGateway;
    if (previous.isImage &&
        previous.remoteTransport == AttachmentRemoteTransport.desktop &&
        remoteRef != null &&
        remoteRef.isNotEmpty &&
        remoteSessionId != null &&
        remoteSessionId.isNotEmpty &&
        gateway is HermesDesktopAttachmentGateway) {
      try {
        await (gateway as HermesDesktopAttachmentGateway).detachImage(
          remoteSessionId,
          remoteRef,
        );
      } catch (error) {
        debugPrint('[attachment] image detach failed (${error.runtimeType})');
      }
    }
    return true;
  }

  void releaseTurnDelivery(ActiveTurnDelivery delivery) {
    if (identical(_activeTurnDelivery, delivery)) _activeTurnDelivery = null;
  }

  /// Fallback compatible con cualquier instancia. Hermes Desktop también
  /// conserva en cola el texto cuando la corrección viva se rechaza o falla.
  final Queue<_QueuedTextTurn> _messageQueue = Queue<_QueuedTextTurn>();
  final Queue<QueuedPreparedTurn> _preparedTurnQueue =
      Queue<QueuedPreparedTurn>();
  int _nextQueueOrder = 0;
  bool _preparedTurnDrainInFlight = false;
  bool _queueDrainSuspended = false;
  String? _blockedPreparedTurnId;
  String? _desktopAcceptedQueuedPrompt;

  List<String> get queuedTextMessages => List<String>.unmodifiable([
    ?_desktopAcceptedQueuedPrompt,
    ..._messageQueue.map((item) => item.text),
  ]);

  List<String> get queuedMessages {
    final local = <({int order, String text})>[
      ..._messageQueue.map((item) => (order: item.queueOrder, text: item.text)),
      ..._preparedTurnQueue.map(
        (item) => (order: item.queueOrder, text: item.turn.text),
      ),
    ]..sort((left, right) => left.order.compareTo(right.order));
    return List<String>.unmodifiable([
      ?_desktopAcceptedQueuedPrompt,
      ...local.map((item) => item.text),
    ]);
  }

  List<QueuedPreparedTurn> get queuedTurns =>
      List<QueuedPreparedTurn>.unmodifiable(_preparedTurnQueue);

  /// Modelo lento y sin streaming (p.ej. Mixture of Agents): cada turno se
  /// calcula entero por dentro y puede estar 1-3 min en silencio antes de
  /// emitir. Con el watchdog normal de 90 s el run se cortaría en falso ("se
  /// cayó") mientras el servidor sigue trabajando. Para estos, el watchdog de
  /// inactividad sube a 4 min.
  bool _slowModel = false;
  Duration get _idleTimeout =>
      _slowModel ? const Duration(seconds: 240) : const Duration(seconds: 90);

  /// Identidad monotónica del turno. Al cancelar/iniciar otro se incrementa;
  /// cualquier callback tardío del transporte anterior queda invalidado y no
  /// puede escribir sobre el estado del nuevo run.
  int _turnEpoch = 0;
  Completer<void> _turnEpochInvalidated = Completer<void>();
  int _transcriptRevision = 0;
  _RewriteReservation? _activeRewrite;

  /// Run en curso (motor /v1/runs). Necesario para resolver aprobaciones y
  /// para cancelar.
  String? currentRunId;

  /// Override de la sesión server-side para el turno en curso (lo fija [send]).
  /// null = usar [sessionId]. El modo voz lo usa para rotar su sesión al cancelar.
  String? _serverSessionOverride;

  /// Solicitud de aprobación pendiente del agente (`approval.request`), o null.
  /// La pantalla la pinta como tarjeta con botones (once/session/always/deny).
  Map<String, dynamic>? pendingApproval;

  // Batching de tokens: acumula y vuelca cada ~33ms para evitar reconstrucciones
  // por token. Vive aquí para que el streaming no dependa del widget.
  static const _desktopStreamCadence = Duration(milliseconds: 33);
  final StringBuffer _tokenBuffer = StringBuffer();
  Timer? _tokenFlushTimer;
  Timer? _terminalTimer;
  Future<void>? _terminalTranscriptRecovery;
  int? _terminalTranscriptRecoveryEpoch;
  // Por defecto conserva la cadencia histórica que consumen modo voz y tareas
  // sin pantalla. ChatScreen activa el modo fluido o inmediato explícitamente.
  bool _fluidStreaming = false;
  bool _immediateStreaming = false;

  /// La pantalla visible puede desactivar el typewriter cuando Android pide
  /// reducir movimiento. Al apagarlo, vuelca inmediatamente lo pendiente.
  set smoothStreaming(bool value) {
    final changed = _fluidStreaming != value || _immediateStreaming == value;
    if (!changed) return;
    _fluidStreaming = value;
    _immediateStreaming = !value;
    if (_immediateStreaming && _tokenBuffer.isNotEmpty) {
      _flushTokenBuffer();
      state = ChatPipelineState.streaming;
      _emit(ActiveChatEvent.token);
    }
  }

  bool _streamingConfirmed = false;
  bool _cancelling = false;
  bool _disposed = false;
  final Completer<void> _disposeSignal = Completer<void>();
  final Duration _terminalReconcileBudget;
  final Duration _desktopRecoveryAttemptTimeout;
  final List<Duration> _desktopRecoveryBackoff;
  Future<void>? _desktopCancelRecovery;
  // Se marca cuando el run llega a un estado terminal (completed/failed/
  // cancelled) para que el cierre del SSE no lo procese dos veces.
  bool _runTerminal = false;
  bool _releaseRequested = false;
  List<Map<String, dynamic>>? _rewindRollbackMessages;
  ChatPipelineState? _rewindRollbackState;
  int? _rewind4018FallbackOrdinal;
  bool _rewindRestoredOnError = false;
  bool _rewindDashboardAuthRequired = false;

  /// La pantalla consume esta señal para explicar que la edición falló pero la
  /// línea temporal original ya fue restaurada.
  bool takeRewindRestoredOnError() {
    final value = _rewindRestoredOnError;
    _rewindRestoredOnError = false;
    return value;
  }

  bool takeRewindDashboardAuthRequired() {
    final value = _rewindDashboardAuthRequired;
    _rewindDashboardAuthRequired = false;
    return value;
  }

  // `/steer` no aparece como mensaje user independiente en el transcript del
  // Gateway (vive dentro de un tool-result). Conservamos una proyección local
  // anclada al ordinal del prompt user para reinsertarla en su posición correcta
  // tras cada refetch, incluso con prompts idénticos o más turnos posteriores.
  final List<SteerProjection> _steerRecords = [];

  // Timer de primer token para el path remoto (/v1/runs). Se inicia al recibir
  // el run_id y se cancela al llegar el primer message.delta. Si dispara antes de
  // que llegue cualquier token, falla el run con un error descriptivo de
  // "firstTokenTimeout" para que classifyChatError lo clasifique correctamente
  // (en lugar de colgar la UI indefinidamente).
  Timer? _firstTokenTimer;

  late final StreamController<ActiveChatEvent> _changes;

  ActiveChat({
    required this.connection,
    required this.sessionId,
    String? logicalSessionId,
    required this.sessionTitle,
    this.notificationSurface = NotificationChatSurface.normal,
    this.notificationRoomId,
    required NotificationService? notifications,
    required VoidCallback onTerminal,
    VoidCallback? onUnused,
    Future<void> Function()? beforeTerminalNotification,
    ApprovalPolicyService? policy,
    void Function(String runId)? onRunStarted,
    Future<void> Function()? onForegroundKeepAlive,
    ValueChanged<int?>? onObservedFirstTokenLatency,
    ValueChanged<ActiveChatEvent>? onEvent,
    int Function()? monotonicMicros,
    int? initialObservedFirstTokenLatencyMs,
    ApiClient? api,
    HermesDesktopGateway? desktopGateway,
    Future<AttachmentUploadResult> Function(SavedConnection, AttachmentDraft)?
    attachmentUploader,
    BridgeClientFactory? bridgeClientFactory,
    BridgeProvisioner? bridgeProvisioner,
    String? sessionProfile,
    String? initialStoredSessionId,
    StoredSessionMessageLoader? storedMessageLoader,
    Future<bool> Function()? turnIdempotencyCapability,
    List<SteerProjection> initialSteerProjections = const [],
    List<CancelledTurnTombstone> initialCancelledTurnTombstones = const [],
    Future<void> Function(CancelledTurnTombstone)? onCancelledTurn,
    Duration terminalReconcileBudget = const Duration(seconds: 4),
    Duration desktopRecoveryAttemptTimeout = const Duration(seconds: 15),
    List<Duration> desktopRecoveryBackoff = const [
      Duration.zero,
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 15),
      Duration(seconds: 30),
    ],
  }) : logicalSessionId = logicalSessionId ?? sessionId,
       _notifications = notifications,
       _policy = policy,
       _onTerminal = onTerminal,
       _onUnused = onUnused,
       _beforeTerminalNotification = beforeTerminalNotification,
       _onRunStarted = onRunStarted,
       _onForegroundKeepAlive = onForegroundKeepAlive,
       _onObservedFirstTokenLatency = onObservedFirstTokenLatency,
       _onEvent = onEvent,
       _cancelledTurnTombstones = List<CancelledTurnTombstone>.of(
         initialCancelledTurnTombstones,
       ),
       _onCancelledTurn = onCancelledTurn,
       _monotonicMicros =
           monotonicMicros ??
           (() => _defaultMonotonicClock.elapsedMicroseconds),
       _observedFirstTokenLatencyMs = initialObservedFirstTokenLatencyMs,
       _terminalReconcileBudget = terminalReconcileBudget,
       _desktopRecoveryAttemptTimeout =
           desktopRecoveryAttemptTimeout > Duration.zero
           ? desktopRecoveryAttemptTimeout
           : const Duration(seconds: 15),
       _desktopRecoveryBackoff = _normalizeDesktopRecoveryBackoff(
         desktopRecoveryBackoff,
       ),
       _turnIdempotencyCapability =
           turnIdempotencyCapability ??
           (() => ConnectionManager.isTurnIdempotencySupported(connection.id)),
       _storedMessageLoader = storedMessageLoader,
       _desktopGateway =
           desktopGateway ??
           (api == null &&
                   !(connection.kind == InstanceKind.localhost &&
                       connection.onDeviceLoopback)
               ? TuiGatewayClient(connection)
               : null),
       _attachmentUploader = attachmentUploader ?? AttachmentUploader.upload,
       _bridgeClientFactory =
           bridgeClientFactory ??
           (({required baseUrl, required token}) =>
               BridgeClient(baseUrl: baseUrl, token: token)),
       _bridgeProvisioner = bridgeProvisioner ?? BridgeClient.provision {
    _steerRecords.addAll(initialSteerProjections);
    _changes = StreamController<ActiveChatEvent>.broadcast(
      onCancel: _handleLastListenerCancelled,
    );
    _api =
        api ??
        ApiClient(baseUrl: connection.baseUrl, apiKey: connection.apiKey);
    if (sessionProfile != null) _bindSessionProfile(sessionProfile);
    bindKnownStoredSession(initialStoredSessionId);
  }

  /// Adopts a durable state.db identity without ever retargeting a live runtime.
  ///
  /// Bot Mode and Mission Rooms keep a stable mobile route while Hermes owns an
  /// opaque stored id. Reopening that route may repeat the same binding, but a
  /// different authoritative id must get a fresh [ActiveChat] instead of mixing
  /// transcript, usage and prompt delivery across two server conversations.
  bool bindKnownStoredSession(
    String? storedSessionId, {
    bool authoritative = false,
  }) {
    final durable = storedSessionId?.trim();
    if (durable == null || durable.isEmpty) {
      if (!authoritative) return true;
      return _desktopStoredSessionId == null &&
          _desktopRuntimeSessionId == null;
    }
    final current = _desktopStoredSessionId;
    if (current != null && current != durable) return false;
    if (authoritative && current == null && _desktopRuntimeSessionId != null) {
      return false;
    }
    _desktopStoredSessionId = durable;
    _desktopStoredSessionKnownMissing = false;
    return true;
  }

  /// Perfil propietario fijado en el binding de esta sesión.
  ///
  /// Es inmutable después de la primera fuente autoritativa (snapshot, carga o
  /// primer submit). Así un cambio posterior de `active_profile_<connId>` no
  /// puede reubicar un resume, rewrite o turno de Voz en otro home.
  String get sessionProfile => _sessionProfileOwner ?? '';

  /// Fija el owner únicamente si este chat todavía no estaba enlazado.
  /// Repetirlo con otro perfil devuelve el owner original y no lo sustituye.
  String bindSessionProfile(String profile) => _bindSessionProfile(profile);

  void bindNotificationTarget(
    NotificationChatSurface surface, {
    String? roomId,
  }) {
    // Una apertura genérica nunca degrada una superficie dedicada que ya
    // conoce su propietario. Bot/Room sí pueden completar un binding legacy.
    if (surface == NotificationChatSurface.normal &&
        notificationSurface != NotificationChatSurface.normal) {
      return;
    }
    notificationSurface = surface;
    notificationRoomId = surface == NotificationChatSurface.room
        ? roomId
        : null;
  }

  String _bindSessionProfile(String requested) {
    final current = _sessionProfileOwner;
    if (current != null) return current;
    final owner = Session.profileOwner(requested);
    _sessionProfileOwner = owner;
    _storedSessionProfile = owner;
    return owner;
  }

  /// Marca un id móvil que todavía no existe en state.db. Además de evitar I/O
  /// al abrir el borrador, permite que el primer submit vaya directamente a
  /// session.create sin pagar antes un session.resume destinado a devolver 4007.
  void markStoredSessionMissing() {
    if (_desktopRuntimeSessionId != null ||
        _desktopStoredSessionId != null ||
        messages.isNotEmpty) {
      return;
    }
    _desktopStoredSessionKnownMissing = true;
    messagesLoaded = true;
    _markTranscriptComplete(visibleCount: 0);
  }

  @visibleForTesting
  bool get storedSessionKnownMissing => _desktopStoredSessionKnownMissing;

  /// Stream de cambios. La pantalla se suscribe para re-renderizar; al cerrarse
  /// cancela la suscripción SIN cancelar el stream del agente.
  Stream<ActiveChatEvent> get changes => _changes.stream;

  @visibleForTesting
  void debugEmitMessagesHydrated() => _emit(ActiveChatEvent.messagesHydrated);

  /// Tiempo de respuesta observado por Android para el último turno. Incluye
  /// red, cola y herramientas previas al primer contenido; no es una métrica
  /// publicada por el modelo ni por Hermes.
  int? get observedFirstTokenLatencyMs => _observedFirstTokenLatencyMs;

  void _beginObservedResponseTiming() {
    _responseStartedAtMicros = _monotonicMicros();
    _observedFirstTokenLatencyMs = null;
    _onObservedFirstTokenLatency?.call(null);
  }

  void _observeFirstResponseContent(String? content) {
    if (_observedFirstTokenLatencyMs != null ||
        content == null ||
        content.trim().isEmpty) {
      return;
    }
    final startedAt = _responseStartedAtMicros;
    if (startedAt == null) return;
    final elapsedMicros = math.max(0, _monotonicMicros() - startedAt);
    final latencyMs = elapsedMicros ~/ Duration.microsecondsPerMillisecond;
    _observedFirstTokenLatencyMs = latencyMs;
    _onObservedFirstTokenLatency?.call(latencyMs);
    // TTFT is independent from transcript rendering. Some Hermes transports
    // expose the first visible content through an interim or terminal frame,
    // so waiting for a later token/done event can leave the context panel on
    // its previous null snapshot even though the metric is already persisted.
    _emit(ActiveChatEvent.responseMetrics);
  }

  bool get hasListeners => _changes.hasListener;

  void requestReleaseWhenUnused() => _releaseRequested = true;

  /// La pantalla volvió a enlazar este chat: la salida anterior ya no puede
  /// liberarlo por debajo de la sesión que ahora lo está mirando.
  void cancelReleaseRequest() => _releaseRequested = false;

  bool get releaseRequested => _releaseRequested;

  void _handleLastListenerCancelled() {
    if (_disposed || !_releaseRequested) return;
    scheduleMicrotask(() {
      if (_disposed || _changes.hasListener || !_releaseRequested) return;
      _onUnused?.call();
    });
  }

  /// Mantiene el mismo runtime vivo entre el corte inmediato por VAD y el
  /// prompt que llega después de transcribir. Sin esta retención, una voz en
  /// segundo plano podía dejar el chat momentáneamente sin oyentes y el
  /// servicio cerraba el socket antes del `prompt.submit(interrupted: true)`.
  bool get voiceBargeHandoffPending => _voiceBargeHandoffPending;

  /// El runtime conserva todavía la valla que separa el terminal del turno
  /// interrumpido de los eventos del reemplazo. Es diagnóstico de protocolo;
  /// la retención del chat se gobierna por [voiceBargeHandoffPending].
  bool get hasPendingDesktopInterruptHandoff =>
      _voiceBargeHandoffPending ||
      _desktopInterruptDrain != null ||
      _discardLateInterruptTerminal;

  List<SteerProjection> get steerProjections =>
      List<SteerProjection>.unmodifiable(_steerRecords);

  /// ID persistido que devuelve session.resume. En chats recién creados puede
  /// diferir del ID móvil con el que se abrió la primera pantalla.
  String? get storedSessionId => _desktopStoredSessionId;

  /// Mission Rooms require Hermes' canonical create/resume lifecycle so their
  /// manager pin can be replaced with a server-confirmed stored id. Endpoint
  /// location is not evidence: a modern Gateway reached through localhost or
  /// adb reverse is valid, while a stateless Bridge/REST transport is not.
  bool get canBindDurableMissionSession =>
      _desktopGateway is HermesDesktopSessionLifecycleGateway;

  /// Identidad real que debe usarse contra el historial del servidor.
  ///
  /// `session.resume` puede convertir el id provisional `mob-…` en un id
  /// persistido distinto. Desde ese momento el persistido gana para lecturas,
  /// reanudaciones y borrado; seguir consultando [sessionId] produciría un 404
  /// transitorio y haría que el chat pareciese desaparecer.
  String get serverSessionId =>
      _desktopStoredSessionId ?? _serverSessionOverride ?? sessionId;

  /// Reads the same persisted session snapshot used by Session Details.
  ///
  /// This is intentionally on-demand (screen attach / terminal event / context
  /// panel), never polling. It lets the chat chrome consume usage fields that
  /// Hermes publishes through REST but older `session.info` events omit.
  Future<Session?> loadPersistedSessionSnapshot() async {
    final requestedId = serverSessionId;
    final snapshot = await _api.getSession(requestedId);
    if (_disposed || serverSessionId != requestedId) return null;
    return snapshot;
  }

  ArtifactAuthorizationPolicy _artifactPolicy() {
    final host = Uri.tryParse(connection.baseUrl)?.host.trim().toLowerCase();
    return ArtifactAuthorizationPolicy(
      revision: 1,
      allowedManagedUriSchemes: host == null || host.isEmpty
          ? const ['hermes']
          : const ['hermes', 'http', 'https'],
      allowedManagedHosts: host == null || host.isEmpty ? const [] : [host],
    );
  }

  void _captureArtifactMessages(
    Iterable<DesktopSessionMessage> transcript, {
    required String logicalSessionId,
  }) {
    late final ArtifactIndexScope scope;
    try {
      scope = ArtifactIndexScope(
        connectionId: connection.id,
        logicalSessionId: logicalSessionId,
      );
    } on FormatException {
      _artifactScope = null;
      _pendingArtifactTranscript = const [];
      _artifactIndex = null;
      return;
    }

    final candidates = <ArtifactTranscriptEntry>[];
    var fallbackOrdinal = 0;
    for (final message in transcript) {
      if (_messageMayContainArtifact(message)) {
        candidates.add(
          ArtifactTranscriptEntry(
            message: message,
            messageOrdinal: message.serverOrdinal ?? fallbackOrdinal,
            messageRevision: 0,
            stableMessageId: message.stableId,
          ),
        );
      }
      fallbackOrdinal++;
    }

    final sameScope = _artifactScope == scope;
    if (sameScope &&
        candidates.length == _pendingArtifactTranscript.length &&
        _sameArtifactTranscript(candidates, _pendingArtifactTranscript)) {
      return;
    }

    final revision = ++_artifactTranscriptRevision;
    final previousByIdentity = <String, ArtifactTranscriptEntry>{};
    if (sameScope) {
      for (final entry in _pendingArtifactTranscript) {
        previousByIdentity[_artifactEntryIdentity(
              entry.stableMessageId,
              entry.messageOrdinal,
            )] =
            entry;
      }
    }
    final structured = <ArtifactTranscriptEntry>[];
    for (final candidate in candidates) {
      final previous =
          previousByIdentity[_artifactEntryIdentity(
            candidate.stableMessageId,
            candidate.messageOrdinal,
          )];
      final unchanged =
          previous != null &&
          _sameArtifactMessage(previous.message, candidate.message);
      structured.add(
        candidate.withMessageRevision(
          unchanged ? previous.messageRevision : revision,
        ),
      );
    }
    _artifactScope = scope;
    _pendingArtifactTranscript = List.unmodifiable(structured);
  }

  void _captureArtifactMaps(
    Iterable<Map<String, dynamic>> transcript, {
    required String logicalSessionId,
  }) {
    final parsed = <DesktopSessionMessage>[];
    var ordinal = 0;
    for (final message in transcript) {
      if (!_rawMessageMayContainArtifact(message)) {
        ordinal++;
        continue;
      }
      final value = DesktopSessionMessage.tryParse(
        message,
        serverOrdinal: ordinal,
      );
      if (value != null) parsed.add(value);
      ordinal++;
    }
    _captureArtifactMessages(parsed, logicalSessionId: logicalSessionId);
  }

  void clearCancelledTurnTombstones() {
    if (_cancelledTurnTombstones.isNotEmpty) {
      _cancelledTombstoneRevision += 1;
    }
    _cancelledTurnTombstones.clear();
    _pendingCancelledTombstoneUpdates.clear();
    for (var index = 0; index < messages.length; index++) {
      if (messages[index]['_cancelledUser'] != true) continue;
      final cleaned = Map<String, dynamic>.of(messages[index])
        ..remove('_cancelledUser')
        ..remove('_cancelledTurnAnchorMessageId')
        ..remove('_cancelledTurnAnchorRowId')
        ..remove('_cancelledTurnFirstUser')
        ..remove('_cancelledTurnMessageId')
        ..remove('_cancelledTurnRowId');
      messages[index] = cleaned;
    }
  }

  bool get hasPendingDurableCancellation =>
      _cancelledTurnPersistencePending ||
      _cancelledTurnPersistenceFailed ||
      _pendingCancelledTombstoneUpdates.isNotEmpty ||
      _cancelledTombstoneUpdateFlight != null ||
      _durableCancelFlight != null;

  bool get _hasPendingActiveTurnCancellation =>
      _cancelledTurnPersistencePending ||
      _cancelledTurnPersistenceFailed ||
      _durableCancelFlight != null;

  bool get _hasPendingTombstoneMetadataUpdate =>
      _pendingCancelledTombstoneUpdates.isNotEmpty;

  /// ¿Hay una petición/ejecución viva en el gateway?
  bool get isStreaming =>
      state == ChatPipelineState.connecting ||
      state == ChatPipelineState.waiting ||
      state == ChatPipelineState.executing ||
      state == ChatPipelineState.streaming;

  /// Estado "enviando" derivado (para deshabilitar el composer, mostrar spinner).
  bool get sending =>
      state != ChatPipelineState.idle &&
      state != ChatPipelineState.completed &&
      state != ChatPipelineState.failed &&
      state != ChatPipelineState.cancelled;

  /// Texto del último mensaje del asistente (index 0 si es assistant).
  String get assistantContent =>
      (messages.isNotEmpty && messages.first['role'] == 'assistant')
      ? ((messages.first['content'] as String?) ?? '')
      : '';

  /// Texto assistant natural aceptado para Voz durante el turno actual.
  ///
  /// A diferencia de [assistantContent], conserva intermedios ya sellados y no
  /// deriva nada de trace/tools/logs. No modifica el transcript ni su render.
  String get assistantNarrationContent => _assistantNarration.content;

  /// Último comentario assistant público del turno vivo (`message.interim`).
  ///
  /// Desktop lo mantiene visible como una burbuja antes/alrededor de las
  /// herramientas. Voz Android puede proyectarlo en su única línea sin buscar
  /// texto en reasoning, tools, previews o turnos históricos.
  String get assistantPublicCommentary {
    final currentTurnPrefix = 'assistant-interim-$_turnEpoch-';
    for (final message in messages) {
      final key = message['_desktopInterimKey'];
      if (message['role'] != 'assistant' ||
          message['_desktopInterim'] != true ||
          key is! String ||
          !key.startsWith(currentTurnPrefix)) {
        continue;
      }
      // `messages` is newest-first. The latest interim owns the projection:
      // an explicitly classified payload must clear an older public line
      // instead of letting Voz repeat stale commentary.
      if (message['_desktopInterimPublic'] != true) return '';
      final content = message['content'];
      if (content is String && content.trim().isNotEmpty) {
        return content.trim();
      }
    }
    return '';
  }

  /// Latest live tool name for the compact Voice projection.
  ///
  /// This multiset is separate from [trace], so Voice can close concurrent or
  /// progress-only tool lifecycles without changing chat cards or their order.
  String? get activeVoiceToolLabel =>
      traceActive && _activeVoiceTools.isNotEmpty
      ? _activeVoiceTools.last.label
      : null;

  ChatActivityKind? get activityKind {
    if (pendingApproval != null) {
      return _lastLiveActivityKind = ChatActivityKind.awaitingApproval;
    }
    if (!isStreaming) return null;
    return switch (state) {
      ChatPipelineState.executing =>
        _lastLiveActivityKind = ChatActivityKind.usingTools,
      ChatPipelineState.streaming =>
        _lastLiveActivityKind = ChatActivityKind.responding,
      ChatPipelineState.connecting || ChatPipelineState.waiting =>
        _lastLiveActivityKind ?? ChatActivityKind.thinking,
      _ => null,
    };
  }

  void _emit(ActiveChatEvent e) {
    if (const {
      ActiveChatEvent.started,
      ActiveChatEvent.messagesHydrated,
      ActiveChatEvent.earlierMessagesLoaded,
      ActiveChatEvent.token,
      ActiveChatEvent.toolProgress,
      ActiveChatEvent.done,
      ActiveChatEvent.error,
      ActiveChatEvent.cancelled,
    }.contains(e)) {
      _transcriptRevision += 1;
    }
    switch (e) {
      case ActiveChatEvent.started:
        _lastLiveActivityKind = ChatActivityKind.thinking;
        break;
      case ActiveChatEvent.approvalRequest:
        _lastLiveActivityKind = ChatActivityKind.awaitingApproval;
        break;
      case ActiveChatEvent.toolProgress:
        _lastLiveActivityKind = ChatActivityKind.usingTools;
        break;
      case ActiveChatEvent.token:
        _lastLiveActivityKind = ChatActivityKind.responding;
        break;
      case ActiveChatEvent.done:
      case ActiveChatEvent.error:
      case ActiveChatEvent.cancelled:
        _lastLiveActivityKind = null;
        break;
      default:
        break;
    }
    _onEvent?.call(e);
    if (!_changes.isClosed) _changes.add(e);
  }

  void _adoptDesktopRuntime(
    String runtimeSessionId, {
    DesktopSessionRuntimeInfo? info,
  }) {
    final runtimeId = runtimeSessionId.trim();
    if (runtimeId.isEmpty) {
      throw const TuiGatewayRpcError(
        'session',
        'Hermes returned an empty runtime session identity',
      );
    }
    final scope = _sessionConfigScope;
    final profile = _storedSessionProfile.isEmpty
        ? 'default'
        : _storedSessionProfile;
    if (_desktopRuntimeSessionId != runtimeId ||
        scope == null ||
        scope.storedSessionId != serverSessionId ||
        scope.profileName != profile) {
      _retireDesktopRuntime();
      _desktopRuntimeSessionId = runtimeId;
      _retiringDesktopRuntimeSessionId = null;
      _desktopSessionEpoch += 1;
      _sessionInfoEpoch = 0;
      _sessionConfigScope = SessionConfigScope(
        connectionId: connection.id,
        storedSessionId: serverSessionId,
        runtimeSessionId: runtimeId,
        profileName: profile,
        sessionEpoch: _desktopSessionEpoch,
      );
    }
    if (info != null) {
      _observeSessionConfigInfo(info);
      _adoptDesktopSessionTitle(info);
    }
  }

  bool _adoptDesktopSessionTitle(DesktopSessionRuntimeInfo info) {
    final title = info.title?.trim() ?? '';
    if (title.isEmpty || title == sessionTitle) return false;
    sessionTitle = title;
    return true;
  }

  void _retireDesktopRuntime() {
    _desktopBindEpoch += 1;
    final retiredRuntimeId = _desktopRuntimeSessionId;
    if (retiredRuntimeId != null) {
      // The reducer emits callbacks synchronously. Fence and detach first so a
      // callback cannot register or submit new work for the retiring runtime.
      _retiringDesktopRuntimeSessionId = retiredRuntimeId;
      _desktopRuntimeSessionId = null;
      _expireInteractivePromptsForRuntime(retiredRuntimeId);
    }
    final scope = _sessionConfigScope;
    if (scope != null) {
      _sessionConfigState = SessionConfigReducer.reduce(
        _sessionConfigState,
        SessionConfigScopeSuperseded(scope),
      );
    }
    _sessionConfigScope = null;
    _desktopRuntimeSessionId = null;
    _desktopAutoCompacting = false;
    _suppressTerminalHydrationAfterCompaction = false;
    _desktopCompactionLineageId = null;
    _desktopSessionEpoch += 1;
    _sessionInfoEpoch = 0;
    _pendingSubagentInterrupts.clear();
  }

  bool _observeSessionConfigInfo(DesktopSessionRuntimeInfo info) {
    final scope = _sessionConfigScope;
    if (scope == null) return false;
    final before = _sessionConfigState[scope];
    _sessionConfigState = SessionConfigReducer.reduce(
      _sessionConfigState,
      SessionConfigInfoObserved(
        scope: scope,
        infoEpoch: ++_sessionInfoEpoch,
        observedRequestEpoch: _sessionConfigRequestEpoch,
        info: SessionConfigAuthoritativeInfo.fromRuntimeInfo(info),
      ),
    );
    final after = _sessionConfigState[scope];
    if (before?.effective != after?.effective) return true;
    for (final key in DesktopSessionConfigKey.values) {
      if (!identical(before?[key], after?[key])) return true;
    }
    return false;
  }

  List<Map<String, dynamic>> _applyCancelledTurnTombstones(
    List<Map<String, dynamic>> incoming, {
    required bool incomingTranscriptComplete,
  }) {
    _bindTombstonesToDurableIds(
      incoming,
      incomingTranscriptComplete: incomingTranscriptComplete,
    );
    if (_pendingCancelledTombstoneUpdates.isNotEmpty) {
      unawaited(_flushPendingCancelledTombstoneUpdates().catchError((_) {}));
    }
    final withoutSupersededLocalUsers = incoming
        .asMap()
        .entries
        .where((entry) {
          final message = entry.value;
          if (message['_cancelledUser'] != true ||
              canonicalTranscriptMessageId(message) != null ||
              canonicalTranscriptRowId(message) != null) {
            return true;
          }
          final tombstone = _durableTombstoneForLocalCancelledUser(
            incoming,
            entry.key,
          );
          if (tombstone == null) return true;
          final durableIndex = _cancelledTurnUserIndex(
            incoming,
            tombstone,
            incomingTranscriptComplete: incomingTranscriptComplete,
          );
          return durableIndex < 0 ||
              (canonicalTranscriptMessageId(incoming[durableIndex]) == null &&
                  canonicalTranscriptRowId(incoming[durableIndex]) == null);
        })
        .map((entry) => entry.value)
        .toList(growable: true);
    return projectCancelledTurnTombstones(
      existingNewestFirst: messages,
      incomingNewestFirst: withoutSupersededLocalUsers,
      durableTombstones: _cancelledTurnTombstones,
      incomingTranscriptComplete: incomingTranscriptComplete,
    );
  }

  void _persistUpdatedTombstone(CancelledTurnTombstone tombstone) {
    final persist = _onCancelledTurn;
    if (persist == null) return;
    final key = jsonEncode([
      tombstone.content,
      tombstone.anchorMessageId,
      tombstone.anchorRowId,
      tombstone.firstUser,
      if (!tombstone.hasAnchorIdentity && !tombstone.firstUser) ...[
        tombstone.cancelledMessageId,
        tombstone.cancelledRowId,
      ],
    ]);
    _pendingCancelledTombstoneUpdates[key] = tombstone;
    unawaited(_flushPendingCancelledTombstoneUpdates().catchError((_) {}));
  }

  Future<void> _flushPendingCancelledTombstoneUpdates() {
    final persist = _onCancelledTurn;
    if (persist == null || _pendingCancelledTombstoneUpdates.isEmpty) {
      return Future<void>.value();
    }
    final existing = _cancelledTombstoneUpdateFlight;
    if (existing != null) return existing;

    late final Future<void> operation;
    operation = () async {
      while (_pendingCancelledTombstoneUpdates.isNotEmpty) {
        final entry = _pendingCancelledTombstoneUpdates.entries.first;
        final expected = entry.value;
        await persist(expected);
        if (identical(_pendingCancelledTombstoneUpdates[entry.key], expected)) {
          _pendingCancelledTombstoneUpdates.remove(entry.key);
        }
      }
    }();
    _cancelledTombstoneUpdateFlight = operation;
    unawaited(
      operation.then<void>(
        (_) {
          if (identical(_cancelledTombstoneUpdateFlight, operation)) {
            _cancelledTombstoneUpdateFlight = null;
          }
        },
        onError: (Object _, StackTrace _) {
          // Keep the exact update queued. The next hydration, compression or
          // send retries it instead of silently reverting to an ambiguous
          // content/position tombstone after process recreation.
          if (identical(_cancelledTombstoneUpdateFlight, operation)) {
            _cancelledTombstoneUpdateFlight = null;
          }
        },
      ),
    );
    return operation;
  }

  Future<bool> _settleTombstoneMetadataBeforeTerminal(
    int expectedTurnEpoch,
  ) async {
    if (!_hasPendingTombstoneMetadataUpdate) return true;
    try {
      await _flushPendingCancelledTombstoneUpdates();
    } catch (_) {
      // La identidad anterior sigue en cola durable. No publiques un terminal
      // que permita liberar el chat mientras esa migración continúa ambigua.
      return false;
    }
    return !_disposed && expectedTurnEpoch == _turnEpoch && !_runTerminal;
  }

  void _bindTombstonesToDurableIds(
    List<Map<String, dynamic>> incoming, {
    required bool incomingTranscriptComplete,
  }) {
    for (var index = 0; index < _cancelledTurnTombstones.length; index++) {
      final tombstone = _cancelledTurnTombstones[index];
      if (tombstone.invalidated) continue;
      final userIndex = _cancelledTurnUserIndex(
        incoming,
        tombstone,
        incomingTranscriptComplete: incomingTranscriptComplete,
      );
      if (userIndex < 0) continue;
      final messageId = canonicalTranscriptMessageId(incoming[userIndex]);
      final rowId = canonicalTranscriptRowId(incoming[userIndex]);
      if (messageId == null && rowId == null) continue;
      final bound = tombstone.bindToMessage(messageId: messageId, rowId: rowId);
      if (bound.cancelledMessageId == tombstone.cancelledMessageId &&
          bound.cancelledRowId == tombstone.cancelledRowId) {
        continue;
      }
      _cancelledTurnTombstones[index] = bound;
      _cancelledTombstoneRevision += 1;
      _persistUpdatedTombstone(bound);
    }
  }

  /// Carga el historial (lectura). No toca el stream.
  ///
  /// Instancia LOCAL (bridge): el agente oneshot no conserva el historial
  /// server-side, así que `getMessages` daría vacío. Reconstruimos el chat
  /// desde el transcript persistido localmente ([LocalTranscriptStore]).
  Future<void> loadMessages({
    int? expectedMessageCount,
    String profile = '',
    VoidCallback? onMessagesPublished,
  }) async {
    _ensureLocalAssistantErrorIdentities();
    final loadTerminalFences = _terminalReconciliationFences(messages);
    final loadEpoch = ++_messageLoadEpoch;
    _storedSessionProfile = _bindSessionProfile(profile);
    if (_desktopStoredSessionKnownMissing) {
      messagesLoaded = true;
      return;
    }
    final gateway = _desktopGateway;
    final lifecycleGateway = gateway is HermesDesktopSessionLifecycleGateway
        ? gateway as HermesDesktopSessionLifecycleGateway
        : null;
    if (connection.kind == InstanceKind.localhost && lifecycleGateway == null) {
      final saved = await LocalTranscriptStore.load(connection.id, sessionId);
      if (_disposed || loadEpoch != _messageLoadEpoch) return;
      // Guardado en orden cronológico; index 0 = más nuevo en la lista viva.
      _markTranscriptComplete(visibleCount: saved.length);
      messages = _applyCancelledTurnTombstones(
        _normalizedNewestFirst(saved),
        incomingTranscriptComplete: true,
      );
      messagesLoaded = true;
      onMessagesPublished?.call();
      return;
    }

    if (gateway != null && lifecycleGateway != null) {
      _listenToDesktopGateway(gateway);

      // Hermes Desktop no serializa estas dos lecturas. El transcript REST y
      // session.resume son independientes: REST puede pintar el historial
      // mientras el RPC termina de enlazar el runtime (MCP/prompt incluidos).
      // Capturamos los errores dentro de cada Future para que una rama que
      // falle pronto nunca se publique como error asíncrono no gestionado.
      ({Object? error, SessionMessagesPage? value})?
      prefetchCompletedBeforeResume;
      final prefetchFuture =
          _captureAsync<SessionMessagesPage>(
            () => _loadStoredMessagesTail(_storedSessionProfile),
          ).then((result) {
            prefetchCompletedBeforeResume = result;
            return result;
          });
      final resumeFuture = _captureAsync<DesktopSessionSnapshot>(() async {
        await gateway.connect();
        if (prefetchCompletedBeforeResume == null) {
          // Damos una vuelta de event loop al REST que ya terminó en memoria o
          // caché. Una lectura de red todavía pendiente no bloquea el binding.
          await Future.any<void>([
            prefetchFuture.then<void>((_) {}),
            Future<void>.delayed(Duration.zero),
          ]);
        }
        // El transcript REST es autoritativo para el contenido, pero las
        // versiones actuales del Dashboard omiten display_kind y
        // display_metadata. Un 0 también puede significar contador ausente o
        // una apertura desde notificación, así que nunca prueba que una sesión
        // existente esté vacía. Pedimos siempre el transcript editorial al
        // Gateway; las sesiones móviles nuevas no pasan por resumeExisting.
        return lifecycleGateway.resumeExisting(
          serverSessionId,
          profile: _storedSessionProfile,
          omitMessages: false,
          // Hermes Agent 0.20 puede devolver un ack inmediato y completar la
          // hidratación mediante `session.resume_progress`. Solicitamos los
          // mensajes (`omitMessages=false`) y además reparamos abajo los markers
          // estables que REST 0.19 entrega sin metadata durante ese intervalo.
          deferHistory: true,
        );
      });

      List<Map<String, dynamic>>? prefetchedNewestFirst;
      var prefetchedTranscriptAccepted = false;
      var prefetchedTranscriptComplete = false;
      int? prefetchedRawMessageCount;
      DesktopSessionSnapshot? resumedSnapshot;
      Object? prefetchError;
      Object? resumeError;

      void publishMessages(
        List<Map<String, dynamic>> next, {
        required bool incomingTranscriptComplete,
      }) {
        if (_disposed || loadEpoch != _messageLoadEpoch) return;
        final fencedNext = _carryNewestTerminalFence(
          messages,
          next,
          candidateTranscriptComplete: incomingTranscriptComplete,
        );
        messages = _applyCancelledTurnTombstones(
          _associateGeneratedImagesNewestFirst(
            _preserveLocalAssistantErrors(fencedNext, messages),
          ),
          incomingTranscriptComplete: incomingTranscriptComplete,
        );
        _mergeSteerRecords();
        _reconcileSubagentsFromTranscript();
        messagesLoaded = true;
        onMessagesPublished?.call();
        _emit(ActiveChatEvent.messagesHydrated);
      }

      void publishSnapshot(DesktopSessionSnapshot snapshot) {
        if (_disposed || loadEpoch != _messageLoadEpoch) return;
        // Ack diferido de Hermes Agent 0.20: el historial llega en segundo
        // plano; un ack nuevo reinicia el desenlace registrado.
        _desktopHistoryHydrating = snapshot.hydrating;
        if (snapshot.hydrating) _desktopHydrationOutcome = null;
        _rememberDesktopHydrationExpectation(snapshot);
        final snapshotTranscriptComplete = _desktopSnapshotTranscriptIsComplete(
          snapshot,
        );
        const reconciler = DesktopSessionReconciler();
        final visibleTerminalFences = <_TerminalProjectionFence>[];
        final visibleFenceIds = <String>{};
        for (final fence in <_TerminalProjectionFence>[
          ...loadTerminalFences,
          ..._terminalReconciliationFences(messages),
        ]) {
          if (visibleFenceIds.add(fence.projectionId)) {
            visibleTerminalFences.add(fence);
          }
        }
        final durableSnapshotProjection = reconciler.project(
          _withoutLiveDesktopProjection(snapshot),
        );
        final snapshotCoversVisibleTerminal = _terminalFencesAreCovered(
          durableSnapshotProjection.messagesNewestFirst,
          visibleTerminalFences,
          candidateTranscriptComplete: snapshotTranscriptComplete,
        );
        final snapshotRejectedByTerminalFence =
            visibleTerminalFences.isNotEmpty && !snapshotCoversVisibleTerminal;
        final liveAuthorityFences = <_TerminalProjectionFence>[
          ...visibleTerminalFences,
        ];
        final liveAuthorityFenceIds = <String>{
          for (final fence in liveAuthorityFences) fence.projectionId,
        };
        for (final fence in _terminalReconciliationFences(
          messages,
          includeSettledTerminalBoundary: true,
        )) {
          if (liveAuthorityFenceIds.add(fence.projectionId)) {
            liveAuthorityFences.add(fence);
          }
        }
        final snapshotCoversLiveTerminal = _terminalFencesAreCovered(
          durableSnapshotProjection.messagesNewestFirst,
          liveAuthorityFences,
          candidateTranscriptComplete: snapshotTranscriptComplete,
        );
        final liveSnapshotProjection = reconciler.project(snapshot);
        final snapshotHasDistinctInflightUser = liveSnapshotProjection
            .messagesNewestFirst
            .any(
              (message) =>
                  isRealUserTurn(message) &&
                  message['_desktopSnapshotKind'] == 'inflight',
            );
        final snapshotHasLiveActivity =
            snapshot.running || snapshot.inflight != null;
        final rejectSnapshotLiveActivity =
            snapshotHasLiveActivity &&
            (snapshotRejectedByTerminalFence ||
                (_runTerminal &&
                    (liveAuthorityFences.isEmpty ||
                        !snapshotCoversLiveTerminal ||
                        !snapshotHasDistinctInflightUser)));
        var rawFallback = prefetchedNewestFirst ?? messages;
        final snapshotAllowsAuthoritativeEmptyRest =
            snapshot.messages.isEmpty &&
            !snapshot.hydrating &&
            (snapshot.messageCount ?? 0) <= 0;
        final restPrefetchIsAuthoritative =
            prefetchedTranscriptAccepted &&
            prefetchedNewestFirst != null &&
            (prefetchedNewestFirst!.isNotEmpty ||
                snapshotAllowsAuthoritativeEmptyRest);
        // Si REST terminó primero con una cola parcial nueva, injértala sobre
        // el snapshot completo para conservar su prefijo antiguo sin permitir
        // que el snapshot stale tape IDs más recientes.
        if (restPrefetchIsAuthoritative &&
            !prefetchedTranscriptComplete &&
            snapshotTranscriptComplete &&
            snapshot.messagesProvided) {
          final restTail = prefetchedNewestFirst!;
          final snapshotProjection = reconciler.project(
            _withoutLiveDesktopProjection(snapshot),
          );
          final combined = _graftRefreshedTail(
            restTail,
            snapshotProjection.messagesNewestFirst,
            refreshedTranscriptComplete: false,
            requiredTerminalFences: loadTerminalFences,
          );
          if (combined.acceptedRefreshed) {
            _commitRefreshedTailEvidence(restTail, combined);
            rawFallback = _preserveLocalAssistantErrors(
              combined.messages,
              messages,
            );
            prefetchedNewestFirst = rawFallback;
          }
        }
        final announcedHydrationCount = snapshot.messageCount;
        final completeRestMatchesHydrationCount =
            !snapshot.hydrating ||
            announcedHydrationCount == null ||
            prefetchedRawMessageCount == announcedHydrationCount;
        final completeRestCoversHydration =
            restPrefetchIsAuthoritative &&
            prefetchedTranscriptComplete &&
            completeRestMatchesHydrationCount;
        _desktopHistoryNeedsHydration =
            snapshot.hydrating && !completeRestCoversHydration;
        final fallbackExactlyMatchesSnapshot =
            snapshotTranscriptComplete &&
            _fallbackExactlyMatchesDesktopSnapshot(rawFallback, snapshot);
        final preferFallback =
            snapshotRejectedByTerminalFence ||
            (restPrefetchIsAuthoritative && prefetchedTranscriptComplete) ||
            (rawFallback.isNotEmpty &&
                (restPrefetchIsAuthoritative ||
                    !snapshotTranscriptComplete ||
                    snapshot.messages.isEmpty ||
                    fallbackExactlyMatchesSnapshot));
        final fallback = preferFallback && snapshot.messagesProvided
            ? reconciler.overlayDurableDisplayMetadata(
                rawFallback,
                snapshot.messages,
              )
            : rawFallback;
        var projectionSource = preferFallback
            ? _withoutPersistedMessages(snapshot)
            : snapshot;
        if (rejectSnapshotLiveActivity) {
          projectionSource = _withoutLiveDesktopProjection(projectionSource);
        }
        if (snapshot.messagesProvided) {
          _captureArtifactMessages(
            snapshot.messages,
            logicalSessionId: logicalSessionId,
          );
          if (!preferFallback || fallbackExactlyMatchesSnapshot) {
            _recordDesktopSnapshotTranscript(snapshot);
          } else if ((!snapshotTranscriptComplete ||
                  snapshot.messages.isEmpty) &&
              !completeRestCoversHydration) {
            _recordDesktopSnapshotTranscript(
              snapshot,
              preserveVisibleFallback: true,
            );
          }
        } else {
          final announcedCount = snapshot.messageCount;
          final durableFallbackCount = _durableTranscriptCoverageCount(
            rawFallback,
          );
          final fallbackCoverageIsInsufficient =
              announcedCount == null ||
              durableFallbackCount == null ||
              announcedCount != durableFallbackCount;
          if (!preferFallback ||
              fallbackCoverageIsInsufficient ||
              _desktopHistoryNeedsHydration) {
            _recordDesktopSnapshotTranscript(
              snapshot,
              preserveVisibleFallback: preferFallback,
            );
          }
        }
        final projection = reconciler.project(
          projectionSource,
          fallbackNewestFirst: fallback,
        );
        final projected = _sanitizeDesktopFailureProjection(
          projection.messagesNewestFirst.map(Map<String, dynamic>.from),
        );
        if (_runTerminal && (projection.running || projection.failed)) {
          _beginExternallyObservedDesktopTurn(snapshot);
        }
        final expectsTranscript =
            (expectedMessageCount ?? 0) > 0 || (snapshot.messageCount ?? 0) > 0;
        if (projected.isNotEmpty || !expectsTranscript) {
          publishMessages(
            projected,
            incomingTranscriptComplete: preferFallback
                ? _transcriptIsComplete
                : snapshotTranscriptComplete,
          );
        }
        _desktopStoredSessionId = snapshot.storedSessionId;
        _adoptDesktopRuntime(snapshot.runtimeSessionId, info: snapshot.info);
        _reconcileSubagentsFromTranscript();
        _restorePendingClarify(snapshot);
        _desktopStoredSessionKnownMissing = false;
        _desktopRuntimeInfo = snapshot.info;
        _rememberDesktopLiveStatus(
          projection.status,
          running: projection.running,
        );
        _desktopStartedAt = snapshot.startedAt;
        _desktopTurnStartedAt = projection.running
            ? snapshot.resolvedTurnStartedAt
            : null;
        _replaceDesktopAcceptedQueue(projection.queuedUser);
        if (projection.failed) {
          _firstTokenTimer?.cancel();
          _firstTokenTimer = null;
          _usingDesktopGateway = false;
          _runTerminal = true;
          traceActive = false;
          pendingApproval = null;
          _cancelling = false;
          state = ChatPipelineState.failed;
        } else if (projection.running) {
          _usingDesktopGateway = true;
          state = snapshot.inflight?.assistant?.isNotEmpty == true
              ? ChatPipelineState.streaming
              : ChatPipelineState.executing;
        }
      }

      // Ambas ramas publican en cuanto traen un transcript útil. La última en
      // terminar vuelve a proyectar con todos los datos disponibles: REST tiene
      // precedencia para lo persistido y el snapshot conserva inflight/queued.
      final prefetchTask = () async {
        final prefetch = await prefetchFuture;
        if (_disposed || loadEpoch != _messageLoadEpoch) return;
        prefetchError = prefetch.error;
        if (prefetch.value case final page?) {
          final chronological = page.messages;
          _captureArtifactMaps(
            chronological,
            logicalSessionId: logicalSessionId,
          );
          final normalized = _normalizedNewestFirst(chronological);
          final pageProvesComplete = _tailPageProvesTranscriptComplete(page);
          final graft = _graftRefreshedTail(
            normalized,
            messages,
            refreshedTranscriptComplete: pageProvesComplete,
            requiredTerminalFences: loadTerminalFences,
          );
          final authoritativeEmptyPage =
              chronological.isEmpty &&
              pageProvesComplete &&
              (messages.isEmpty ||
                  messages.every(_isLiveTranscriptProjection)) &&
              (expectedMessageCount ?? 0) == 0;
          if (graft.messages.isNotEmpty || authoritativeEmptyPage) {
            prefetchedTranscriptAccepted =
                graft.acceptedRefreshed || authoritativeEmptyPage;
            if (prefetchedTranscriptAccepted) {
              _desktopHistoryNeedsHydration = false;
              // Es una página REST pura: el count bruto incluye filas id-less
              // sin inventarles identidad y excluye las proyecciones live que
              // solo existen en el fallback de UI.
              prefetchedRawMessageCount = page.rawMessageCount;
            }
            _recordTranscriptPage(
              page,
              preserveExistingCoverage:
                  !authoritativeEmptyPage && graft.preservesExistingCoverage,
            );
            _commitRefreshedTailEvidence(normalized, graft);
            prefetchedTranscriptComplete =
                pageProvesComplete && prefetchedTranscriptAccepted;
            prefetchedNewestFirst = authoritativeEmptyPage
                ? <Map<String, dynamic>>[]
                : _preserveLocalAssistantErrors(graft.messages, messages);
            final snapshot = resumedSnapshot;
            if (snapshot == null) {
              publishMessages(
                authoritativeEmptyPage
                    ? graft.messages
                    : prefetchedNewestFirst!,
                // El lifecycle aún puede responder con un ack hydrating cuyo
                // count demuestre que esta cola corta es provisional. Aplica
                // anchors durables ya, pero difiere firstUser hasta conocerlo.
                incomingTranscriptComplete: false,
              );
            } else {
              publishSnapshot(snapshot);
            }
          }
        }
      }();

      final resumeTask = () async {
        final resumed = await resumeFuture;
        if (_disposed || loadEpoch != _messageLoadEpoch) return;
        resumeError = resumed.error;
        if (resumed.value case final snapshot?) {
          resumedSnapshot = snapshot;
          publishSnapshot(snapshot);
        }
      }();

      await Future.wait<void>([prefetchTask, resumeTask]);
      if (_disposed || loadEpoch != _messageLoadEpoch) return;

      final snapshot = resumedSnapshot;
      if (snapshot != null) {
        final expectsTranscript =
            (expectedMessageCount ?? 0) > 0 || (snapshot.messageCount ?? 0) > 0;
        if (expectsTranscript && messages.isEmpty) {
          // Ack diferido sin transcript y REST no pintó nada: el historial se
          // está cargando server-side en segundo plano. Espera el
          // `session.resume_progress` y reintenta la cola paginada ya lista.
          if (snapshot.hydrating) {
            final hydrated = await _awaitDesktopHistoryHydration();
            if (_disposed || loadEpoch != _messageLoadEpoch) return;
            if (hydrated) {
              final coverageRevision = _transcriptCoverageRevision;
              final requestedTailHydration = _needsTranscriptTailHydration;
              final requestedNextOffset = _earlierMessagesNextOffset;
              final requestedExtent = _transcriptExtent;
              final requestedEarlierMessagesAvailable =
                  _earlierMessagesAvailable;
              final deferredPage = await _loadStoredMessagesTail(
                _storedSessionProfile,
              );
              if (_disposed ||
                  loadEpoch != _messageLoadEpoch ||
                  coverageRevision != _transcriptCoverageRevision ||
                  requestedTailHydration != _needsTranscriptTailHydration ||
                  requestedNextOffset != _earlierMessagesNextOffset ||
                  requestedExtent != _transcriptExtent ||
                  requestedEarlierMessagesAvailable !=
                      _earlierMessagesAvailable) {
                return;
              }
              final deferred = deferredPage.messages;
              if (deferred.isNotEmpty) {
                final hydrationStatus = _hydrationTailStatus(deferredPage);
                if (hydrationStatus == _HydrationTailStatus.incomplete) {
                  _recordIncompleteHydrationTail();
                } else {
                  _desktopHistoryNeedsHydration = false;
                  _recordTranscriptPage(deferredPage);
                }
                _unconfirmedRetainedTranscriptIdentities.clear();
                _captureArtifactMaps(
                  deferred,
                  logicalSessionId: logicalSessionId,
                );
                messages = _applyCancelledTurnTombstones(
                  _associateGeneratedImagesNewestFirst(
                    _preserveLocalAssistantErrors(
                      _normalizedNewestFirst(deferred),
                      messages,
                    ),
                  ),
                  incomingTranscriptComplete: _transcriptIsComplete,
                );
                _mergeSteerRecords();
                _reconcileSubagentsFromTranscript();
                messagesLoaded = true;
                onMessagesPublished?.call();
                _emit(ActiveChatEvent.messagesHydrated);
                return;
              }
            }
          }
          messagesLoaded = false;
          throw StateError(
            'Hermes returned an empty transcript for a non-empty session',
          );
        }
        if (!messagesLoaded) {
          messagesLoaded = true;
          onMessagesPublished?.call();
          _emit(ActiveChatEvent.messagesHydrated);
        }
        return;
      }

      final capturedResumeError = resumeError;
      if (capturedResumeError is TuiGatewayRpcError) {
        // Un borrador local no existe todavía hasta su primer prompt y los
        // gateways antiguos pueden carecer del lifecycle 0.19. REST conserva
        // compatibilidad; esta ruta de lectura nunca crea una sesión.
        if (capturedResumeError.code != 4007 &&
            capturedResumeError.code != -32601) {
          debugPrint(
            '[active-chat] Desktop resume unavailable '
            '(${capturedResumeError.runtimeType}, '
            'code=${capturedResumeError.code})',
          );
        }
      } else if (capturedResumeError != null) {
        debugPrint(
          '[active-chat] Desktop snapshot unavailable '
          '(${capturedResumeError.runtimeType})',
        );
      }

      // Si REST ya pintó un transcript legible, un fallo del canal vivo no lo
      // vuelve a ocultar. El próximo envío/reintento podrá enlazar el runtime.
      if (prefetchedNewestFirst?.isNotEmpty == true || messages.isNotEmpty) {
        if (prefetchedTranscriptComplete && _transcriptIsComplete) {
          final projected = _applyCancelledTurnTombstones(
            messages,
            incomingTranscriptComplete: true,
          );
          if (!_sameTranscriptProjection(projected, messages)) {
            messages = projected;
            _mergeSteerRecords();
            _reconcileSubagentsFromTranscript();
            onMessagesPublished?.call();
            _emit(ActiveChatEvent.messagesHydrated);
          }
        }
        messagesLoaded = true;
        return;
      }
      if (capturedResumeError is TuiGatewayRpcError &&
          capturedResumeError.code == 4007) {
        _desktopStoredSessionKnownMissing = true;
        // 4007 es evidencia autoritativa de que el id aún no existe en
        // state.db. Igual que markStoredSessionMissing, habilita el tombstone
        // firstUser del primer Stop sin inferir completitud desde un [] REST.
        _markTranscriptComplete(visibleCount: 0);
      }
      if (prefetchError == null) {
        if ((expectedMessageCount ?? 0) > 0) {
          throw StateError(
            'Hermes returned an empty transcript for a non-empty session',
          );
        }
        messagesLoaded = true;
        return;
      }
      throw capturedResumeError ??
          prefetchError ??
          StateError('Chat load failed');
    }

    final page = await _loadStoredMessagesTail(_storedSessionProfile);
    if (_disposed || loadEpoch != _messageLoadEpoch) return;
    final m = page.messages;
    if (m.isEmpty && messages.isNotEmpty) {
      messagesLoaded = true;
      return;
    }
    if (m.isEmpty && (expectedMessageCount ?? 0) > 0) {
      throw StateError(
        'Hermes returned an empty transcript for a non-empty session',
      );
    }
    final normalized = _normalizedNewestFirst(m);
    final graft = _graftRefreshedTail(
      normalized,
      messages,
      refreshedTranscriptComplete: _tailPageProvesTranscriptComplete(page),
      requiredTerminalFences: loadTerminalFences,
    );
    _recordTranscriptPage(
      page,
      preserveExistingCoverage: graft.preservesExistingCoverage,
    );
    _commitRefreshedTailEvidence(normalized, graft);
    _captureArtifactMaps(m, logicalSessionId: logicalSessionId);
    // API devuelve más antiguo primero; lo invertimos: index 0 = más nuevo.
    messages = _applyCancelledTurnTombstones(
      _associateGeneratedImagesNewestFirst(
        _preserveLocalAssistantErrors(graft.messages, messages),
      ),
      incomingTranscriptComplete: _transcriptIsComplete,
    );
    _mergeSteerRecords();
    messagesLoaded = true;
    onMessagesPublished?.call();
  }

  Future<List<Map<String, dynamic>>> _loadStoredMessages(String profile) async {
    final normalizedProfile = profile.trim();
    final injected = _storedMessageLoader;
    if (injected != null) {
      return injected(serverSessionId, normalizedProfile);
    }
    // `default` es una identidad explícita para los RPC de Desktop, pero no
    // convierte el historial principal en una lectura Dashboard. Mantenerlo
    // en el endpoint Gateway conserva el contrato legacy/offline y evita que
    // una sesión normal dependa de credenciales Dashboard. Solo los perfiles
    // alternativos necesitan la superficie profile-aware del Dashboard.
    if (normalizedProfile.isEmpty || normalizedProfile == 'default') {
      return _api.getMessages(serverSessionId);
    }
    final dashboard = DashboardClient.lazy(connection);
    try {
      return await dashboard.getSessionMessages(
        serverSessionId,
        profile: normalizedProfile,
      );
    } finally {
      dashboard.close();
    }
  }

  /// Lee una página del transcript almacenado por la MISMA superficie que
  /// [_loadStoredMessages] (Gateway :8642 para `default`, Dashboard para
  /// perfiles alternativos), con la semántica `order=latest` de Hermes Agent
  /// 0.20: [offset] hacia atrás desde el mensaje más reciente y la página en
  /// orden cronológico. El loader inyectado y los gateways antiguos devuelven
  /// el transcript completo sin metadata `pagination`.
  Future<SessionMessagesPage> _fetchStoredMessagesPage(
    String profile, {
    int limit = _transcriptPageSize,
    int offset = 0,
  }) async {
    final normalizedProfile = profile.trim();
    final injected = _storedMessageLoader;
    if (injected != null) {
      return SessionMessagesPage(
        messages: await injected(serverSessionId, normalizedProfile),
        pagination: null,
      );
    }
    if (normalizedProfile.isEmpty || normalizedProfile == 'default') {
      return _api.getMessagesPage(
        serverSessionId,
        limit: limit,
        offset: offset,
      );
    }
    final dashboard = DashboardClient.lazy(connection);
    try {
      return await dashboard.getSessionMessagesPage(
        serverSessionId,
        profile: normalizedProfile,
        limit: limit,
        offset: offset,
      );
    } finally {
      dashboard.close();
    }
  }

  /// Actualiza el bookkeeping de la cola paginada tras cada página recibida.
  /// Sin metadata `pagination` (gateway legacy) la respuesta ES el transcript
  /// completo: no queda nada anterior que pedir.
  void _markTranscriptComplete({required int visibleCount}) {
    _transcriptCoverageRevision += 1;
    _transcriptCoverageHasParseGap = false;
    _transcriptExtent = _TranscriptExtent.complete;
    _earlierMessagesAvailable = false;
    _earlierMessagesNextOffset = visibleCount;
    _needsTranscriptTailHydration = false;
    _desktopHydrationExpectedMessageCount = null;
    _unconfirmedRetainedTranscriptIdentities.clear();
  }

  void _rememberDesktopHydrationExpectation(DesktopSessionSnapshot snapshot) {
    final announced = snapshot.messageCount;
    if (_desktopSnapshotTranscriptIsComplete(snapshot)) {
      _desktopHydrationExpectedMessageCount = null;
      return;
    }
    if (!snapshot.hydrating) {
      // Un snapshot posterior ya fuera de hydration pertenece a la generación
      // vigente. Su count (también null) sustituye cualquier expectativa alta
      // de un ack hydrating anterior; conservar el máximo bloquearía para
      // siempre una compactación 300 -> 1 aunque REST acreditase esa única fila.
      _desktopHydrationExpectedMessageCount = announced;
    } else if (announced != null && announced > snapshot.messages.length) {
      _desktopHydrationExpectedMessageCount = math.max(
        _desktopHydrationExpectedMessageCount ?? 0,
        announced,
      );
    }
  }

  _HydrationTailStatus _hydrationTailStatus(SessionMessagesPage page) {
    final expected = _desktopHydrationExpectedMessageCount;
    final limit = page.limit;
    if (page.offset == 0 &&
        limit != null &&
        limit > 0 &&
        page.rawMessageCount >= limit) {
      // Un count del snapshot y esta página REST pueden pertenecer a
      // generaciones distintas. Una página llena nunca acredita el inicio
      // absoluto; offset=120 debe confirmar una página corta o vacía.
      return _HydrationTailStatus.partial;
    }
    if (!_tailPageProvesTranscriptComplete(page)) {
      return _HydrationTailStatus.partial;
    }
    return expected == null || page.rawMessageCount >= expected
        ? _HydrationTailStatus.complete
        : _HydrationTailStatus.incomplete;
  }

  bool _pageFallsShortOfAnnouncedCoverage(SessionMessagesPage page) {
    final expected = _desktopHydrationExpectedMessageCount;
    if (expected == null || !page.paginationFullyParsed) return false;
    final limit = page.limit;
    final pageIsShort =
        limit == null || limit <= 0 || page.rawMessageCount < limit;
    return pageIsShort && page.offset + page.rawMessageCount < expected;
  }

  void _recordIncompleteHydrationTail() {
    _transcriptCoverageRevision += 1;
    _transcriptExtent = _TranscriptExtent.partial;
    _earlierMessagesAvailable = true;
    _earlierMessagesNextOffset = 0;
    _needsTranscriptTailHydration = true;
    _desktopHistoryNeedsHydration = true;
  }

  bool _preserveInflightOutsideHydrationGraft(Map<String, dynamic> message) =>
      message['_desktopSnapshotKind'] == 'inflight' &&
      message[_terminalProjectionIdKey] == null;

  void _recordDesktopSnapshotTranscript(
    DesktopSessionSnapshot snapshot, {
    bool preserveVisibleFallback = false,
  }) {
    _rememberDesktopHydrationExpectation(snapshot);
    final visibleCount = snapshot.messages.length;
    if (_desktopSnapshotTranscriptIsComplete(snapshot) &&
        !preserveVisibleFallback) {
      _markTranscriptComplete(visibleCount: visibleCount);
      return;
    }
    _transcriptCoverageRevision += 1;

    // Un fallback paginado con offset positivo ya demuestra qué cola se leyó.
    // Un snapshot que omite mensajes no puede rebobinarlo a cero: hacerlo
    // mezclaría la cola actual con una página anterior interpretada como tail.
    if (preserveVisibleFallback &&
        _transcriptExtent == _TranscriptExtent.partial &&
        _earlierMessagesNextOffset > 0) {
      _earlierMessagesAvailable = true;
      _needsTranscriptTailHydration = true;
      return;
    }

    _transcriptExtent = _TranscriptExtent.partial;
    final expectedCount = snapshot.messageCount;
    final snapshotCoverageIsUncertain =
        !snapshot.messagesFullyParsed ||
        !_desktopSnapshotIdentitiesAreUnambiguous(snapshot.messages) ||
        (expectedCount != null && expectedCount < visibleCount);
    _earlierMessagesNextOffset =
        preserveVisibleFallback ||
            snapshot.hydrating ||
            snapshotCoverageIsUncertain
        ? 0
        : snapshot.messagesProvided
        ? visibleCount
        : 0;
    _earlierMessagesAvailable =
        preserveVisibleFallback ||
        !snapshot.messagesProvided ||
        snapshot.hydrating ||
        snapshotCoverageIsUncertain ||
        (expectedCount != null && expectedCount > visibleCount);
    _needsTranscriptTailHydration =
        preserveVisibleFallback ||
        snapshot.hydrating ||
        !snapshot.messagesProvided ||
        snapshotCoverageIsUncertain;
  }

  void _recordTranscriptPage(
    SessionMessagesPage page, {
    bool preserveExistingCoverage = false,
  }) {
    final identitiesAreUnambiguous =
        _transcriptRowsHaveUnambiguousIdentityEvidence(page.messages);
    if (preserveExistingCoverage) {
      if (!page.messagesFullyParsed ||
          !page.paginationFullyParsed ||
          !identitiesAreUnambiguous) {
        _transcriptCoverageRevision += 1;
        _transcriptCoverageHasParseGap = true;
        _transcriptExtent = _TranscriptExtent.partial;
      }
      return;
    }
    _transcriptCoverageRevision += 1;
    if (!page.paginationFullyParsed) {
      // `pagination` presente pero inválida no es un transcript legacy. Las
      // filas siguen siendo visibles, pero no acreditan ni el inicio absoluto
      // ni un cursor de backfill seguro, así que firstUser queda diferido.
      _transcriptCoverageHasParseGap = true;
      _transcriptExtent = _TranscriptExtent.partial;
      _earlierMessagesAvailable = true;
      _earlierMessagesNextOffset = 0;
      _needsTranscriptTailHydration = true;
      _desktopHistoryNeedsHydration = true;
      return;
    }
    final limit = page.limit;
    final pageProvesWholeTranscript =
        page.offset == 0 &&
        page.messagesFullyParsed &&
        identitiesAreUnambiguous &&
        (limit == null || limit <= 0 || page.rawMessageCount < limit);
    if (pageProvesWholeTranscript) {
      _transcriptCoverageHasParseGap = false;
    } else if (!page.messagesFullyParsed || !identitiesAreUnambiguous) {
      _transcriptCoverageHasParseGap = true;
    }
    if (limit == null || limit <= 0) {
      // Una respuesta legacy es completa, pero esta función también puede
      // cerrar un backfill que ya conservaba ids provisionales. No los borres
      // hasta que el caller confirme/prune las filas contra esta respuesta.
      _transcriptExtent = _transcriptCoverageHasParseGap
          ? _TranscriptExtent.partial
          : _TranscriptExtent.complete;
      _earlierMessagesAvailable = false;
      _earlierMessagesNextOffset = page.rawMessageCount;
      _needsTranscriptTailHydration = false;
      if (!_transcriptCoverageHasParseGap) {
        _desktopHydrationExpectedMessageCount = null;
      }
      return;
    }
    _earlierMessagesNextOffset = page.offset + page.rawMessageCount;
    _earlierMessagesAvailable = page.rawMessageCount >= limit;
    _transcriptExtent =
        _earlierMessagesAvailable || _transcriptCoverageHasParseGap
        ? _TranscriptExtent.partial
        : _TranscriptExtent.complete;
    _needsTranscriptTailHydration = false;
    if (!_earlierMessagesAvailable && !_transcriptCoverageHasParseGap) {
      _desktopHydrationExpectedMessageCount = null;
    }
  }

  /// Cola del transcript (los ~120 más recientes) para la hidratación
  /// inicial, en orden cronológico. Las páginas anteriores se piden bajo
  /// demanda con [loadEarlierMessages].
  Future<SessionMessagesPage> _loadStoredMessagesTail(String profile) =>
      _fetchStoredMessagesPage(profile);

  CancelledTurnTombstone? _durableTombstoneForLocalCancelledUser(
    List<Map<String, dynamic>> newestFirst,
    int userIndex,
  ) {
    final message = newestFirst[userIndex];
    if (!isRealUserTurn(message) || message['_cancelledUser'] != true) {
      return null;
    }
    final content = (message['content'] ?? '').toString();
    if (content.isEmpty) return null;
    final projectedAnchor = message['_cancelledTurnAnchorMessageId'];
    final projectedAnchorRow = message['_cancelledTurnAnchorRowId'];
    final projectedFirstUser = message['_cancelledTurnFirstUser'] == true;
    final projectedTarget = message['_cancelledTurnMessageId'];
    final projectedTargetRow = message['_cancelledTurnRowId'];
    final targetMessageId =
        projectedTarget is String && projectedTarget.isNotEmpty
        ? projectedTarget
        : canonicalTranscriptMessageId(message);
    final targetRowId = projectedTargetRow is int && projectedTargetRow > 0
        ? projectedTargetRow
        : canonicalTranscriptRowId(message);
    final anchorMessageId =
        projectedAnchor is String && projectedAnchor.isNotEmpty
        ? projectedAnchor
        : null;
    final anchorRowId = projectedAnchorRow is int && projectedAnchorRow > 0
        ? projectedAnchorRow
        : null;
    if (targetMessageId != null ||
        targetRowId != null ||
        anchorMessageId != null ||
        anchorRowId != null ||
        projectedFirstUser) {
      final candidate = CancelledTurnTombstone(
        content: content,
        anchorMessageId: anchorMessageId,
        anchorRowId: anchorRowId,
        firstUser: projectedFirstUser,
        cancelledMessageId: targetMessageId,
        cancelledRowId: targetRowId,
      );
      for (final durable in _cancelledTurnTombstones) {
        if (!durable.invalidated && _sameCancelledTurn(durable, candidate)) {
          return durable;
        }
      }
      return null;
    }
    String? olderAnchorMessageId;
    int? olderAnchorRowId;
    for (var older = userIndex + 1; older < newestFirst.length; older++) {
      final olderMessage = newestFirst[older];
      olderAnchorMessageId = canonicalTranscriptMessageId(olderMessage);
      olderAnchorRowId = canonicalTranscriptRowId(olderMessage);
      if (olderAnchorMessageId != null || olderAnchorRowId != null) break;
      if (isRealUserTurn(olderMessage)) return null;
    }
    final hasOlderRealUser = newestFirst
        .skip(userIndex + 1)
        .any(isRealUserTurn);
    final candidate = olderAnchorMessageId != null || olderAnchorRowId != null
        ? CancelledTurnTombstone(
            content: content,
            anchorMessageId: olderAnchorMessageId,
            anchorRowId: olderAnchorRowId,
          )
        : !hasOlderRealUser && _transcriptIsComplete
        ? CancelledTurnTombstone(content: content, firstUser: true)
        : null;
    if (candidate == null) return null;
    for (final durable in _cancelledTurnTombstones) {
      if (!durable.invalidated && _sameCancelledTurn(durable, candidate)) {
        return durable;
      }
    }
    return null;
  }

  bool _refreshedTranscriptReplacesLocalCancelledUser(
    List<Map<String, dynamic>> previous,
    int previousIndex,
    List<Map<String, dynamic>> refreshed, {
    required bool refreshedTranscriptComplete,
  }) {
    final tombstone = _durableTombstoneForLocalCancelledUser(
      previous,
      previousIndex,
    );
    if (tombstone == null) return false;
    final refreshedIndex = _cancelledTurnUserIndex(
      refreshed,
      tombstone,
      incomingTranscriptComplete: refreshedTranscriptComplete,
    );
    return refreshedIndex >= 0 &&
        (canonicalTranscriptMessageId(refreshed[refreshedIndex]) != null ||
            canonicalTranscriptRowId(refreshed[refreshedIndex]) != null);
  }

  int? _terminalProjectionInt(Object? value) => switch (value) {
    int number => number,
    num number => number.toInt(),
    _ => null,
  };

  int? _terminalProjectionRowId(Object? value) =>
      value is int && value > 0 ? value : null;

  _TerminalTurnEvidence _terminalTurnEvidence(
    List<Map<String, dynamic>> newestFirst,
    int userIndex,
  ) {
    final projectionIndices = <int>[userIndex];
    var complete = false;
    String? assistantText;
    for (var index = userIndex - 1; index >= 0; index--) {
      final message = newestFirst[index];
      if (isRealUserTurn(message)) break;
      projectionIndices.add(index);
      if (message['role'] == 'tool') {
        complete = true;
        continue;
      }
      if (message['role'] != 'assistant') continue;
      final content = (message['content'] as String? ?? '').trim();
      final toolCalls = message['tool_calls'];
      if (content.isNotEmpty || (toolCalls is List && toolCalls.isNotEmpty)) {
        complete = true;
      }
      if (content.isNotEmpty) assistantText = content;
    }
    return (
      complete: complete,
      projectionIndices: projectionIndices,
      assistantText: assistantText,
    );
  }

  List<_TerminalProjectionFence> _terminalProjectionFences(
    List<Map<String, dynamic>> newestFirst,
  ) {
    final fences = <_TerminalProjectionFence>[];
    final seen = <String>{};
    for (var index = 0; index < newestFirst.length; index++) {
      final message = newestFirst[index];
      if (!isRealUserTurn(message)) continue;
      final rawProjectionId = message[_terminalProjectionIdKey];
      if (rawProjectionId is! String ||
          rawProjectionId.isEmpty ||
          !seen.add(rawProjectionId)) {
        continue;
      }
      final anchor = message[_terminalProjectionAnchorKey];
      final evidence = _terminalTurnEvidence(newestFirst, index);
      fences.add(
        _TerminalProjectionFence(
          projectionId: rawProjectionId,
          userMessageId: canonicalTranscriptMessageId(message),
          userRowId: canonicalTranscriptRowId(message),
          anchorMessageId: anchor is String && anchor.isNotEmpty
              ? anchor
              : null,
          anchorRowId: _terminalProjectionRowId(
            message[_terminalProjectionAnchorRowKey],
          ),
          ordinalAfterAnchor: _terminalProjectionInt(
            message[_terminalProjectionAnchorOrdinalKey],
          ),
          absoluteUserOrdinal: _terminalProjectionInt(
            message[_terminalProjectionAbsoluteOrdinalKey],
          ),
          localAssistantText: evidence.assistantText,
        ),
      );
    }
    return fences;
  }

  List<_TerminalProjectionFence> _terminalReconciliationFences(
    List<Map<String, dynamic>> newestFirst, {
    bool includeSettledTerminalBoundary = false,
  }) {
    final explicit = _terminalProjectionFences(newestFirst);
    if (explicit.isNotEmpty ||
        !_runTerminal ||
        (!includeSettledTerminalBoundary &&
            state != ChatPipelineState.completed)) {
      return explicit;
    }
    final userIndex = newestFirst.indexWhere(isRealUserTurn);
    if (userIndex < 0) return const [];
    final user = newestFirst[userIndex];
    final evidence = _terminalTurnEvidence(newestFirst, userIndex);
    final userMessageId = canonicalTranscriptMessageId(user);
    final userRowId = canonicalTranscriptRowId(user);
    var anchorIndex = -1;
    String? anchorMessageId;
    int? anchorRowId;
    for (var index = userIndex + 1; index < newestFirst.length; index++) {
      final candidateId = canonicalTranscriptMessageId(newestFirst[index]);
      final candidateRowId = canonicalTranscriptRowId(newestFirst[index]);
      if (candidateId == null && candidateRowId == null) continue;
      anchorIndex = index;
      anchorMessageId = candidateId;
      anchorRowId = candidateRowId;
      break;
    }
    final ordinalAfterAnchor = anchorIndex < 0
        ? null
        : newestFirst.sublist(0, anchorIndex).where(isRealUserTurn).length;
    final absoluteUserOrdinal = _transcriptIsComplete
        ? newestFirst.where(isRealUserTurn).length
        : null;
    if (userMessageId == null &&
        userRowId == null &&
        anchorMessageId == null &&
        anchorRowId == null &&
        absoluteUserOrdinal == null) {
      return const [];
    }
    return [
      _TerminalProjectionFence(
        projectionId: 'terminal-boundary-$_turnEpoch',
        userMessageId: userMessageId,
        userRowId: userRowId,
        anchorMessageId: anchorMessageId,
        anchorRowId: anchorRowId,
        ordinalAfterAnchor: ordinalAfterAnchor,
        absoluteUserOrdinal: absoluteUserOrdinal,
        localAssistantText: evidence.assistantText,
      ),
    ];
  }

  int _terminalFenceTargetIndex(
    List<Map<String, dynamic>> candidateNewestFirst,
    _TerminalProjectionFence fence, {
    required bool candidateTranscriptComplete,
  }) {
    if (fence.userMessageId != null || fence.userRowId != null) {
      final exact = _resolveTranscriptIdentity(
        candidateNewestFirst,
        messageId: fence.userMessageId,
        rowId: fence.userRowId,
        accepts: isRealUserTurn,
      );
      if (exact.kind == _TranscriptIdentityResolutionKind.unique) {
        return exact.index;
      }
      if (exact.kind == _TranscriptIdentityResolutionKind.conflicting) {
        return -1;
      }
    }

    final ordinalAfterAnchor = fence.ordinalAfterAnchor;
    if ((fence.anchorMessageId != null || fence.anchorRowId != null) &&
        ordinalAfterAnchor != null &&
        ordinalAfterAnchor > 0) {
      final anchor = _resolveTranscriptIdentity(
        candidateNewestFirst,
        messageId: fence.anchorMessageId,
        rowId: fence.anchorRowId,
        accepts: (_) => true,
      );
      if (anchor.kind == _TranscriptIdentityResolutionKind.conflicting) {
        return -1;
      }
      if (anchor.kind == _TranscriptIdentityResolutionKind.unique) {
        var ordinal = 0;
        for (var index = anchor.index - 1; index >= 0; index--) {
          if (!isRealUserTurn(candidateNewestFirst[index])) continue;
          ordinal++;
          if (ordinal == ordinalAfterAnchor) return index;
        }
      }
    }

    final absoluteUserOrdinal = fence.absoluteUserOrdinal;
    if (candidateTranscriptComplete &&
        absoluteUserOrdinal != null &&
        absoluteUserOrdinal > 0) {
      var ordinal = 0;
      for (var index = candidateNewestFirst.length - 1; index >= 0; index--) {
        if (!isRealUserTurn(candidateNewestFirst[index])) continue;
        ordinal++;
        if (ordinal == absoluteUserOrdinal) return index;
      }
    }
    return -1;
  }

  bool _terminalFenceIsCovered(
    List<Map<String, dynamic>> candidateNewestFirst,
    _TerminalProjectionFence fence, {
    required bool candidateTranscriptComplete,
  }) {
    final userIndex = _terminalFenceTargetIndex(
      candidateNewestFirst,
      fence,
      candidateTranscriptComplete: candidateTranscriptComplete,
    );
    if (userIndex < 0) return false;
    final evidence = _terminalTurnEvidence(candidateNewestFirst, userIndex);
    if (evidence.projectionIndices.any(
      (index) =>
          candidateNewestFirst[index][_terminalProjectionIdKey] ==
          fence.projectionId,
    )) {
      // Un fallback local no puede acreditarse a sí mismo como persistido.
      return false;
    }
    if (!evidence.complete) return false;
    final local = fence.localAssistantText?.replaceAll(RegExp(r'\s+'), ' ');
    if (local == null || local.isEmpty) return true;
    final remote = evidence.assistantText?.replaceAll(RegExp(r'\s+'), ' ');
    if (remote == null || remote.isEmpty) return false;
    // El contenido no identifica mensajes. Solo evita sustituir una respuesta
    // visible por un prefijo demostrablemente anterior de esa misma posición.
    return !(remote.length < local.length && local.startsWith(remote));
  }

  bool _terminalFencesAreCovered(
    List<Map<String, dynamic>> candidateNewestFirst,
    List<_TerminalProjectionFence> fences, {
    required bool candidateTranscriptComplete,
  }) => fences.every(
    (fence) => _terminalFenceIsCovered(
      candidateNewestFirst,
      fence,
      candidateTranscriptComplete: candidateTranscriptComplete,
    ),
  );

  List<Map<String, dynamic>> _carryNewestTerminalFence(
    List<Map<String, dynamic>> previous,
    List<Map<String, dynamic>> candidateNewestFirst, {
    required bool candidateTranscriptComplete,
  }) {
    final fences = _terminalProjectionFences(previous);
    if (fences.isEmpty ||
        !_terminalFencesAreCovered(
          candidateNewestFirst,
          fences,
          candidateTranscriptComplete: candidateTranscriptComplete,
        )) {
      return candidateNewestFirst;
    }
    return candidateNewestFirst
        .map((message) {
          if (message[_terminalProjectionIdKey] == null &&
              message[_terminalProjectionAnchorKey] == null &&
              message[_terminalProjectionAnchorRowKey] == null &&
              message[_terminalProjectionAnchorOrdinalKey] == null &&
              message[_terminalProjectionAbsoluteOrdinalKey] == null) {
            return message;
          }
          return Map<String, dynamic>.of(message)
            ..remove(_terminalProjectionIdKey)
            ..remove(_terminalProjectionAnchorKey)
            ..remove(_terminalProjectionAnchorRowKey)
            ..remove(_terminalProjectionAnchorOrdinalKey)
            ..remove(_terminalProjectionAbsoluteOrdinalKey);
        })
        .toList(growable: true);
  }

  void _attachTerminalProjectionMetadata(
    int index,
    Map<String, dynamic> metadata,
  ) {
    final message = messages[index];
    try {
      // Las burbujas vivas usan la identidad del mapa para retener su host de
      // viewport. Añadir metadata privada in-place conserva esa identidad.
      message.addAll(metadata);
    } on UnsupportedError {
      // Las filas proyectadas por Desktop son inmutables; su copia sigue
      // siendo segura porque no existe un host local que deba conservarse.
      messages[index] = {...message, ...metadata};
    }
  }

  void _markCurrentTurnAwaitingTranscript() {
    final userIndex = messages.indexWhere(isRealUserTurn);
    if (userIndex < 0) return;
    final currentProjection = messages.take(userIndex + 1);
    final hasLiveEvidence = currentProjection.any(
      (message) =>
          message['_optimistic'] == true ||
          message['_pipeline'] == true ||
          message['_desktopSnapshotKind'] == 'inflight' ||
          message['_desktopInterim'] == true,
    );
    if (!hasLiveEvidence) return;

    var anchorIndex = -1;
    String? anchorMessageId;
    int? anchorRowId;
    for (var index = userIndex + 1; index < messages.length; index++) {
      final candidateId = canonicalTranscriptMessageId(messages[index]);
      final candidateRowId = canonicalTranscriptRowId(messages[index]);
      if (candidateId == null && candidateRowId == null) continue;
      anchorIndex = index;
      anchorMessageId = candidateId;
      anchorRowId = candidateRowId;
      break;
    }
    final ordinalAfterAnchor = anchorIndex < 0
        ? null
        : messages.sublist(0, anchorIndex).where(isRealUserTurn).length;
    final absoluteUserOrdinal = _transcriptIsComplete
        ? messages.where(isRealUserTurn).length
        : null;
    final projectionId = 'terminal-$_turnEpoch';
    for (var index = 0; index <= userIndex; index++) {
      _attachTerminalProjectionMetadata(index, {
        _terminalProjectionIdKey: projectionId,
      });
    }
    _attachTerminalProjectionMetadata(userIndex, {
      _terminalProjectionIdKey: projectionId,
      _terminalProjectionAnchorKey: ?anchorMessageId,
      _terminalProjectionAnchorRowKey: ?anchorRowId,
      _terminalProjectionAnchorOrdinalKey: ?ordinalAfterAnchor,
      _terminalProjectionAbsoluteOrdinalKey: ?absoluteUserOrdinal,
    });
  }

  /// Re-ancla una cola refrescada sobre un transcript al que ya se le
  /// cargaron páginas anteriores. Sustituir la lista por la cola nueva
  /// descartaría el prefijo recuperado con [loadEarlierMessages]. Solo adopta
  /// cobertura solapada o disjunta cuando sus IDs permiten demostrar y podar
  /// el prefijo; ante filas históricas sin identidad falla cerrado.
  _RefreshedTranscriptGraft _graftRefreshedTail(
    List<Map<String, dynamic>> refreshedNewestFirst,
    List<Map<String, dynamic>> previous, {
    required bool refreshedTranscriptComplete,
    List<_TerminalProjectionFence> requiredTerminalFences = const [],
    bool enforceTerminalFences = true,
  }) {
    final terminalFences = <_TerminalProjectionFence>[];
    if (enforceTerminalFences) {
      final seen = <String>{};
      for (final fence in <_TerminalProjectionFence>[
        ...requiredTerminalFences,
        ..._terminalReconciliationFences(previous),
      ]) {
        if (seen.add(fence.projectionId)) terminalFences.add(fence);
      }
    }
    if (terminalFences.isNotEmpty) {
      if (!_terminalFencesAreCovered(
        refreshedNewestFirst,
        terminalFences,
        candidateTranscriptComplete: refreshedTranscriptComplete,
      )) {
        // Un único turno puede producir más de una página de tools antes de
        // que offset=120 alcance su user canónico. La cola durable puede
        // avanzar provisionalmente, pero la proyección terminal local sigue
        // vallada y visible hasta que una página posterior acredite el turno.
        if (!refreshedTranscriptComplete &&
            refreshedNewestFirst.isNotEmpty &&
            _allTranscriptRowsHaveDurableIds(refreshedNewestFirst)) {
          final fenceIds = {
            for (final fence in terminalFences) fence.projectionId,
          };
          final terminalUserIndex = previous.indexWhere(
            (message) =>
                isRealUserTurn(message) &&
                fenceIds.contains(message[_terminalProjectionIdKey]),
          );
          if (terminalUserIndex >= 0) {
            final prefix = previous.sublist(0, terminalUserIndex);
            final terminalProjectionId =
                previous[terminalUserIndex][_terminalProjectionIdKey];
            final protectedPrefix = previous
                .take(terminalUserIndex + 1)
                .where(
                  (message) =>
                      !_hasDurableTranscriptIdentity(message) ||
                      message[_terminalProjectionIdKey] == terminalProjectionId,
                )
                .toList(growable: false);
            final durablePrefix = prefix
                .where(
                  (message) =>
                      _hasDurableTranscriptIdentity(message) &&
                      message[_terminalProjectionIdKey] != terminalProjectionId,
                )
                .toList(growable: false);
            final refreshedAndKnown = _mergeOlderTranscriptPage(
              refreshedNewestFirst,
              durablePrefix,
            );
            final protectedIdentities = _transcriptIdentities(protectedPrefix);
            final refreshedAndKnownPrefix = refreshedAndKnown
                .where((message) {
                  final identity = _transcriptMessageIdentity(message);
                  return identity == null ||
                      !_identityCollectionContains(
                        protectedIdentities,
                        identity,
                      );
                })
                .toList(growable: false);
            final refreshedIdentities = _transcriptIdentities(
              refreshedNewestFirst,
            );
            final provisionalPreviousIdentities =
                _transcriptIdentities(previous)
                    .where(
                      (identity) => !_identityCollectionContains(
                        refreshedIdentities,
                        identity,
                      ),
                    )
                    .toList(growable: false);
            final knownIdentities = _transcriptIdentities(
              refreshedAndKnownPrefix,
            );
            final older = previous
                .skip(terminalUserIndex + 1)
                .where((message) {
                  final identity = _transcriptMessageIdentity(message);
                  return identity == null ||
                      !_identityCollectionContains(knownIdentities, identity);
                })
                .toList(growable: false);
            return (
              messages: <Map<String, dynamic>>[
                ...protectedPrefix,
                ...refreshedAndKnownPrefix,
                ...older,
              ],
              preservesExistingCoverage: false,
              acceptedRefreshed: true,
              retainsExistingRows: true,
              unconfirmedRetainedIdentities: provisionalPreviousIdentities,
            );
          }
        }
        return (
          messages: previous,
          preservesExistingCoverage: true,
          acceptedRefreshed: false,
          retainsExistingRows: true,
          unconfirmedRetainedIdentities: const <TranscriptMessageIdentity>[],
        );
      }
      final withoutCoveredTerminal = previous
          .where((message) => message[_terminalProjectionIdKey] == null)
          .toList(growable: false);
      final reconciled = _graftRefreshedTail(
        refreshedNewestFirst,
        withoutCoveredTerminal,
        refreshedTranscriptComplete: refreshedTranscriptComplete,
        enforceTerminalFences: false,
      );
      if (!reconciled.acceptedRefreshed) {
        return (
          messages: previous,
          preservesExistingCoverage: true,
          acceptedRefreshed: false,
          retainsExistingRows: true,
          unconfirmedRetainedIdentities: const <TranscriptMessageIdentity>[],
        );
      }
      return (
        messages: _carryNewestTerminalFence(
          previous,
          reconciled.messages,
          candidateTranscriptComplete: refreshedTranscriptComplete,
        ),
        preservesExistingCoverage: reconciled.preservesExistingCoverage,
        acceptedRefreshed: true,
        retainsExistingRows: reconciled.retainsExistingRows,
        unconfirmedRetainedIdentities: reconciled.unconfirmedRetainedIdentities,
      );
    }
    if (refreshedTranscriptComplete && refreshedNewestFirst.isNotEmpty) {
      final retainedLocal = <Map<String, dynamic>>[
        for (var index = 0; index < previous.length; index++)
          if (!_hasDurableTranscriptIdentity(previous[index]) &&
              _isKnownLocalTranscriptProjection(previous, index) &&
              previous[index]['_steer'] != true &&
              previous[index]['_cancelled'] != true &&
              !_refreshedTranscriptReplacesLocalCancelledUser(
                previous,
                index,
                refreshedNewestFirst,
                refreshedTranscriptComplete: refreshedTranscriptComplete,
              ))
            previous[index],
      ];
      return (
        messages: retainedLocal.isEmpty
            ? refreshedNewestFirst
            : <Map<String, dynamic>>[...retainedLocal, ...refreshedNewestFirst],
        preservesExistingCoverage: false,
        acceptedRefreshed: true,
        retainsExistingRows: retainedLocal.isNotEmpty,
        unconfirmedRetainedIdentities: const <TranscriptMessageIdentity>[],
      );
    }
    if (previous.isEmpty) {
      return (
        messages: refreshedNewestFirst,
        preservesExistingCoverage: false,
        acceptedRefreshed: true,
        retainsExistingRows: false,
        unconfirmedRetainedIdentities: const <TranscriptMessageIdentity>[],
      );
    }
    if (refreshedNewestFirst.isEmpty) {
      return (
        messages: previous,
        preservesExistingCoverage: true,
        acceptedRefreshed: false,
        retainsExistingRows: true,
        unconfirmedRetainedIdentities: const <TranscriptMessageIdentity>[],
      );
    }

    final canPartitionPrevious =
        <int>[
          for (var index = 0; index < previous.length; index++) index,
        ].every(
          (index) =>
              _hasDurableTranscriptIdentity(previous[index]) ||
              _isKnownLocalTranscriptProjection(previous, index),
        );
    final durablePrevious = canPartitionPrevious
        ? previous.where(_hasDurableTranscriptIdentity).toList(growable: false)
        : previous;
    final retainedLocal = canPartitionPrevious
        ? <Map<String, dynamic>>[
            for (var index = 0; index < previous.length; index++)
              if (!_hasDurableTranscriptIdentity(previous[index]) &&
                  previous[index]['_steer'] != true &&
                  previous[index]['_cancelled'] != true &&
                  !_refreshedTranscriptReplacesLocalCancelledUser(
                    previous,
                    index,
                    refreshedNewestFirst,
                    refreshedTranscriptComplete: refreshedTranscriptComplete,
                  ))
                previous[index],
          ]
        : const <Map<String, dynamic>>[];
    List<Map<String, dynamic>> withRetainedLocal(
      List<Map<String, dynamic>> durable,
    ) => retainedLocal.isEmpty
        ? durable
        : <Map<String, dynamic>>[...retainedLocal, ...durable];

    final exactlyMatchesKnownTail =
        _transcriptIsComplete &&
        refreshedNewestFirst.length <= durablePrevious.length &&
        <int>[
          for (var index = 0; index < refreshedNewestFirst.length; index++)
            index,
        ].every((index) {
          final refreshedIdentity = _transcriptMessageIdentity(
            refreshedNewestFirst[index],
          );
          final previousIdentity = _transcriptMessageIdentity(
            durablePrevious[index],
          );
          return refreshedIdentity != null &&
              previousIdentity != null &&
              refreshedIdentity.matches(previousIdentity);
        });
    if (exactlyMatchesKnownTail) {
      return (
        messages: withRetainedLocal(<Map<String, dynamic>>[
          ...refreshedNewestFirst,
          ...durablePrevious.sublist(refreshedNewestFirst.length),
        ]),
        preservesExistingCoverage: true,
        acceptedRefreshed: true,
        retainsExistingRows:
            durablePrevious.length > refreshedNewestFirst.length ||
            retainedLocal.isNotEmpty,
        unconfirmedRetainedIdentities: const <TranscriptMessageIdentity>[],
      );
    }

    final anchor = _transcriptMessageIdentity(refreshedNewestFirst.last);
    if (anchor == null) {
      return (
        messages: previous,
        preservesExistingCoverage: true,
        acceptedRefreshed: false,
        retainsExistingRows: true,
        unconfirmedRetainedIdentities: const <TranscriptMessageIdentity>[],
      );
    }
    var index = -1;
    for (
      var candidateIndex = 0;
      candidateIndex < durablePrevious.length;
      candidateIndex++
    ) {
      final candidateIdentity = _transcriptMessageIdentity(
        durablePrevious[candidateIndex],
      );
      if (candidateIdentity == null ||
          !anchor.sharesExactCoordinate(candidateIdentity)) {
        continue;
      }
      if (!anchor.matches(candidateIdentity) || index >= 0) {
        index = -2;
        break;
      }
      index = candidateIndex;
    }
    if (index < 0) {
      if (_allTranscriptRowsHaveDurableIds(refreshedNewestFirst) &&
          canPartitionPrevious &&
          _allTranscriptRowsHaveDurableIds(durablePrevious)) {
        return (
          messages: withRetainedLocal(
            _mergeOlderTranscriptPage(refreshedNewestFirst, durablePrevious),
          ),
          preservesExistingCoverage: false,
          acceptedRefreshed: true,
          retainsExistingRows:
              durablePrevious.isNotEmpty || retainedLocal.isNotEmpty,
          unconfirmedRetainedIdentities: _transcriptIdentities(durablePrevious),
        );
      }
      return (
        messages: previous,
        preservesExistingCoverage: true,
        acceptedRefreshed: false,
        retainsExistingRows: true,
        unconfirmedRetainedIdentities: const <TranscriptMessageIdentity>[],
      );
    }
    if (!canPartitionPrevious) {
      return (
        messages: previous,
        preservesExistingCoverage: true,
        acceptedRefreshed: false,
        retainsExistingRows: true,
        unconfirmedRetainedIdentities: const <TranscriptMessageIdentity>[],
      );
    }
    final retainedPrefix = durablePrevious.sublist(index + 1);
    if (!_allTranscriptRowsHaveDurableIds(retainedPrefix)) {
      return (
        messages: previous,
        preservesExistingCoverage: true,
        acceptedRefreshed: false,
        retainsExistingRows: true,
        unconfirmedRetainedIdentities: const <TranscriptMessageIdentity>[],
      );
    }
    return (
      messages: withRetainedLocal(<Map<String, dynamic>>[
        ...refreshedNewestFirst,
        ...retainedPrefix,
      ]),
      preservesExistingCoverage: false,
      acceptedRefreshed: true,
      retainsExistingRows:
          retainedPrefix.isNotEmpty || retainedLocal.isNotEmpty,
      unconfirmedRetainedIdentities: _transcriptIdentities(retainedPrefix),
    );
  }

  List<Map<String, dynamic>> _reconcileCoveredTerminalProjection(
    List<Map<String, dynamic>> candidateNewestFirst, {
    required bool candidateTranscriptComplete,
  }) {
    final fences = _terminalProjectionFences(messages);
    if (fences.isEmpty) return candidateNewestFirst;
    final withoutLocalProjection = <Map<String, dynamic>>[];
    for (final message in candidateNewestFirst) {
      if (message[_terminalProjectionIdKey] == null) {
        withoutLocalProjection.add(message);
        continue;
      }
      final messageIdentity = _transcriptMessageIdentity(message);
      if (messageIdentity == null ||
          _identityCollectionContains(
            _unconfirmedRetainedTranscriptIdentities,
            messageIdentity,
          )) {
        continue;
      }
      withoutLocalProjection.add(
        Map<String, dynamic>.of(message)
          ..remove(_terminalProjectionIdKey)
          ..remove(_terminalProjectionAnchorKey)
          ..remove(_terminalProjectionAnchorRowKey)
          ..remove(_terminalProjectionAnchorOrdinalKey)
          ..remove(_terminalProjectionAbsoluteOrdinalKey),
      );
    }
    if (!_terminalFencesAreCovered(
      withoutLocalProjection,
      fences,
      candidateTranscriptComplete: candidateTranscriptComplete,
    )) {
      return candidateNewestFirst;
    }
    return _carryNewestTerminalFence(
      messages,
      withoutLocalProjection,
      candidateTranscriptComplete: candidateTranscriptComplete,
    );
  }

  void _commitRefreshedTailEvidence(
    List<Map<String, dynamic>> refreshedNewestFirst,
    _RefreshedTranscriptGraft graft, {
    bool preserveTailHydration = false,
  }) {
    if (!graft.acceptedRefreshed) return;
    _transcriptCoverageRevision += 1;
    final refreshedIdentities = _transcriptIdentities(refreshedNewestFirst);
    if (!graft.retainsExistingRows) {
      _unconfirmedRetainedTranscriptIdentities.clear();
    } else {
      for (final identity in refreshedIdentities) {
        _removeMatchingIdentities(
          _unconfirmedRetainedTranscriptIdentities,
          identity,
        );
      }
    }
    for (final identity in graft.unconfirmedRetainedIdentities) {
      if (!_identityCollectionContains(
        _unconfirmedRetainedTranscriptIdentities,
        identity,
      )) {
        _unconfirmedRetainedTranscriptIdentities.add(identity);
      }
    }
    if (!preserveTailHydration) _needsTranscriptTailHydration = false;
  }

  void _confirmTranscriptRows(Iterable<Map<String, dynamic>> rows) {
    for (final message in rows) {
      final identity = _transcriptMessageIdentity(message);
      if (identity != null) {
        final visibleIdentity = _uniqueTranscriptIdentityMatch(
          identity,
          messages,
        );
        if (visibleIdentity == null) continue;
        _removeMatchingIdentities(
          _unconfirmedRetainedTranscriptIdentities,
          visibleIdentity,
        );
      }
    }
  }

  List<Map<String, dynamic>> _mergeOlderPageBeforeUnconfirmedPrefix(
    List<Map<String, dynamic>> existingNewestFirst,
    List<Map<String, dynamic>> olderPageNewestFirst,
  ) {
    if (_unconfirmedRetainedTranscriptIdentities.isEmpty) {
      return _mergeOlderTranscriptPage(
        existingNewestFirst,
        olderPageNewestFirst,
      );
    }
    final confirmed = <Map<String, dynamic>>[];
    final provisional = <Map<String, dynamic>>[];
    final olderPageIdentities = _transcriptIdentities(olderPageNewestFirst);
    for (final message in existingNewestFirst) {
      final identity = _transcriptMessageIdentity(message);
      final terminalProjectionStillMissing =
          message[_terminalProjectionIdKey] != null &&
          identity != null &&
          !_identityCollectionContains(olderPageIdentities, identity);
      if (identity != null &&
          _identityCollectionContains(
            _unconfirmedRetainedTranscriptIdentities,
            identity,
          ) &&
          !terminalProjectionStillMissing) {
        provisional.add(message);
      } else {
        confirmed.add(message);
      }
    }
    return _mergeOlderTranscriptPage(
      _mergeOlderTranscriptPage(confirmed, olderPageNewestFirst),
      provisional,
    );
  }

  List<Map<String, dynamic>> _pruneUnconfirmedRowsAtTranscriptStart(
    List<Map<String, dynamic>> candidate,
  ) {
    if (!_transcriptIsComplete ||
        _unconfirmedRetainedTranscriptIdentities.isEmpty) {
      return candidate;
    }
    final retainedTerminalIdentities = <TranscriptMessageIdentity>[];
    final projected = candidate
        .where((message) {
          final identity = _transcriptMessageIdentity(message);
          if (identity == null ||
              !_identityCollectionContains(
                _unconfirmedRetainedTranscriptIdentities,
                identity,
              )) {
            return true;
          }
          if (message[_terminalProjectionIdKey] != null) {
            // Esta fila sigue siendo parte de una proyección terminal vallada:
            // podarla separaría el user canónico de su assistant local. Sigue
            // sin confirmar hasta que una página REST traiga esa identidad.
            retainedTerminalIdentities.add(identity);
            return true;
          }
          return false;
        })
        .toList(growable: true);
    _unconfirmedRetainedTranscriptIdentities
      ..clear()
      ..addAll(retainedTerminalIdentities);
    return projected;
  }

  /// Carga bajo demanda la siguiente página de mensajes ANTERIORES y la
  /// antepone al timeline (backfill, patrón "Show earlier" de Desktop). Una
  /// petición en vuelo por chat; un fallo no es fatal y el gesto lo reintenta.
  Future<bool> loadEarlierMessages() async {
    if (_disposed ||
        !_earlierMessagesAvailable ||
        _earlierMessagesInFlight ||
        connection.kind == InstanceKind.localhost) {
      return false;
    }
    _earlierMessagesInFlight = true;
    final loadEpoch = _messageLoadEpoch;
    final coverageRevision = _transcriptCoverageRevision;
    final requestedTailHydration = _needsTranscriptTailHydration;
    final requestedNextOffset = _earlierMessagesNextOffset;
    final requestedExtent = _transcriptExtent;
    final requestedEarlierMessagesAvailable = _earlierMessagesAvailable;
    try {
      final page = await _fetchStoredMessagesPage(
        _storedSessionProfile,
        offset: requestedTailHydration ? 0 : requestedNextOffset,
      );
      if (_disposed ||
          loadEpoch != _messageLoadEpoch ||
          coverageRevision != _transcriptCoverageRevision ||
          requestedTailHydration != _needsTranscriptTailHydration ||
          requestedNextOffset != _earlierMessagesNextOffset ||
          requestedExtent != _transcriptExtent ||
          requestedEarlierMessagesAvailable != _earlierMessagesAvailable) {
        return false;
      }

      if (requestedTailHydration) {
        // Un snapshot omitido no aportó transcript. Esta lectura de offset 0
        // es la cola actual, no una página más antigua: reconcíliala con el
        // fallback conservado y solo después habilita el backfill normal.
        final hydrationStatus = _hydrationTailStatus(page);
        if (page.messages.isEmpty) {
          final onlyLiveProjection = messages.every(
            _isLiveTranscriptProjection,
          );
          if (hydrationStatus == _HydrationTailStatus.incomplete) {
            _recordIncompleteHydrationTail();
            return false;
          }
          if (!onlyLiveProjection) {
            return false;
          }
          _desktopHistoryNeedsHydration = false;
          _recordTranscriptPage(page);
          _needsTranscriptTailHydration = false;
          _unconfirmedRetainedTranscriptIdentities.clear();
          messagesLoaded = true;
          _emit(ActiveChatEvent.earlierMessagesLoaded);
          return true;
        }
        final normalized = _normalizedNewestFirst(page.messages);
        final inflight = messages
            .where(_preserveInflightOutsideHydrationGraft)
            .toList(growable: false);
        final durableFallback = messages
            .where(
              (message) => !_preserveInflightOutsideHydrationGraft(message),
            )
            .toList(growable: false);
        final graft = _graftRefreshedTail(
          normalized,
          durableFallback,
          refreshedTranscriptComplete:
              hydrationStatus == _HydrationTailStatus.complete,
        );
        if (!graft.acceptedRefreshed) return false;
        _captureArtifactMaps(page.messages, logicalSessionId: logicalSessionId);
        // Al hidratar offset cero la metadata de esta página sustituye el
        // cursor provisional del snapshot, aunque hubiera fallback completo.
        if (hydrationStatus == _HydrationTailStatus.incomplete) {
          _recordIncompleteHydrationTail();
        } else {
          _desktopHistoryNeedsHydration = false;
          _recordTranscriptPage(page);
        }
        _commitRefreshedTailEvidence(
          normalized,
          graft,
          preserveTailHydration:
              hydrationStatus == _HydrationTailStatus.incomplete,
        );
        final hydrated = <Map<String, dynamic>>[
          ...inflight,
          ..._preserveLocalAssistantErrors(graft.messages, durableFallback),
        ];
        final projected = _applyCancelledTurnTombstones(
          _associateGeneratedImagesNewestFirst(
            _pruneUnconfirmedRowsAtTranscriptStart(hydrated),
          ),
          incomingTranscriptComplete: _transcriptIsComplete,
        );
        messages = projected;
        _mergeSteerRecords();
        _reconcileSubagentsFromTranscript();
        _emit(ActiveChatEvent.earlierMessagesLoaded);
        return true;
      }

      if (_pageFallsShortOfAnnouncedCoverage(page)) {
        return false;
      }
      final normalized = _normalizedNewestFirst(page.messages);
      final mergedWithPage = _mergeOlderPageBeforeUnconfirmedPrefix(
        messages,
        normalized,
      );
      _confirmTranscriptRows(normalized);
      _recordTranscriptPage(page);
      if (page.messages.isNotEmpty) {
        _captureArtifactMaps(page.messages, logicalSessionId: logicalSessionId);
      }
      var merged = _pruneUnconfirmedRowsAtTranscriptStart(mergedWithPage);
      merged = _reconcileCoveredTerminalProjection(
        merged,
        candidateTranscriptComplete: _transcriptIsComplete,
      );
      final projectedMerged = _applyCancelledTurnTombstones(
        _associateGeneratedImagesNewestFirst(merged),
        incomingTranscriptComplete: _transcriptIsComplete,
      );
      final changed = !_sameTranscriptProjection(projectedMerged, messages);
      if (!changed && page.messages.isEmpty) return false;
      if (changed) messages = projectedMerged;
      if (changed || page.messages.isNotEmpty) {
        _mergeSteerRecords();
        _reconcileSubagentsFromTranscript();
        _emit(ActiveChatEvent.earlierMessagesLoaded);
        return true;
      }
      return false;
    } catch (error) {
      debugPrint(
        '[active-chat] earlier transcript page unavailable '
        '(${error.runtimeType})',
      );
      return false;
    } finally {
      _earlierMessagesInFlight = false;
    }
  }

  /// Espera el desenlace de una hidratación diferida del historial
  /// (`session.resume_progress`), con un tope para no colgar la apertura del
  /// chat si el evento nunca llega.
  Future<bool> _awaitDesktopHistoryHydration() {
    final recorded = _desktopHydrationOutcome;
    if (recorded != null) return Future.value(recorded);
    final waiter = Completer<bool>();
    _desktopHydrationWaiter = waiter;
    return waiter.future
        .timeout(const Duration(seconds: 30), onTimeout: () => false)
        .whenComplete(() {
          if (identical(_desktopHydrationWaiter, waiter)) {
            _desktopHydrationWaiter = null;
          }
        });
  }

  void _handleDesktopResumeProgress(Map<String, dynamic> payload) {
    final status = (payload['status'] ?? '').toString().trim().toLowerCase();
    final announced = _terminalProjectionInt(payload['message_count']);
    if (status == 'complete' && announced != null && announced >= 0) {
      // Este evento es posterior al ack de resume y puede anunciar una
      // compactación 300→2. Sustituye la expectativa vieja; usar max dejaría
      // offset=0 en reintento eterno aunque la cola nueva ya esté completa.
      _desktopHydrationExpectedMessageCount = announced > 0 ? announced : null;
    } else if (announced != null && announced > 0) {
      _desktopHydrationExpectedMessageCount = math.max(
        _desktopHydrationExpectedMessageCount ?? 0,
        announced,
      );
    }
    switch (status) {
      case 'loading':
        _desktopHistoryHydrating = true;
        _desktopHydrationOutcome = null;
      case 'complete':
        _desktopHistoryHydrating = false;
        _desktopHydrationOutcome = true;
        final waiter = _desktopHydrationWaiter;
        if (waiter != null && !waiter.isCompleted) waiter.complete(true);
        // Si loadMessages ya no está esperando y REST no había pintado nada,
        // el historial ya está listo server-side: recupéralo ahora.
        if (waiter == null && _desktopHistoryNeedsHydration && !_disposed) {
          _scheduleDeferredDesktopHistoryHydration();
        }
      case 'failed':
        _desktopHistoryHydrating = false;
        _desktopHistoryNeedsHydration = false;
        _desktopHydrationOutcome = false;
        final waiter = _desktopHydrationWaiter;
        if (waiter != null && !waiter.isCompleted) waiter.complete(false);
    }
  }

  void _scheduleDeferredDesktopHistoryHydration() {
    final loadEpoch = _messageLoadEpoch;
    if (_disposed ||
        !_desktopHistoryNeedsHydration ||
        (_desktopHistoryHydrationFlight != null &&
            _desktopHistoryHydrationFlightEpoch == loadEpoch)) {
      return;
    }
    late final Future<void> flight;
    flight = _hydrateDeferredDesktopHistory().whenComplete(() {
      if (identical(_desktopHistoryHydrationFlight, flight)) {
        _desktopHistoryHydrationFlight = null;
        _desktopHistoryHydrationFlightEpoch = null;
      }
    });
    _desktopHistoryHydrationFlight = flight;
    _desktopHistoryHydrationFlightEpoch = loadEpoch;
    unawaited(flight);
  }

  Future<void> _hydrateDeferredDesktopHistory() async {
    final loadEpoch = _messageLoadEpoch;
    final coverageRevision = _transcriptCoverageRevision;
    final requestedTailHydration = _needsTranscriptTailHydration;
    final requestedNextOffset = _earlierMessagesNextOffset;
    final requestedExtent = _transcriptExtent;
    final requestedEarlierMessagesAvailable = _earlierMessagesAvailable;
    try {
      final page = await _loadStoredMessagesTail(_storedSessionProfile);
      final m = page.messages;
      if (_disposed ||
          loadEpoch != _messageLoadEpoch ||
          coverageRevision != _transcriptCoverageRevision ||
          requestedTailHydration != _needsTranscriptTailHydration ||
          requestedNextOffset != _earlierMessagesNextOffset ||
          requestedExtent != _transcriptExtent ||
          requestedEarlierMessagesAvailable != _earlierMessagesAvailable) {
        return;
      }
      final hydrationStatus = _hydrationTailStatus(page);
      if (m.isEmpty) {
        final onlyLiveProjection = messages.every(_isLiveTranscriptProjection);
        if (hydrationStatus == _HydrationTailStatus.incomplete) {
          _recordIncompleteHydrationTail();
          return;
        }
        if (!onlyLiveProjection) {
          return;
        }
        _desktopHistoryNeedsHydration = false;
        _recordTranscriptPage(page);
        _needsTranscriptTailHydration = false;
        _unconfirmedRetainedTranscriptIdentities.clear();
        messagesLoaded = true;
        _emit(ActiveChatEvent.messagesHydrated);
        return;
      }
      final normalized = _normalizedNewestFirst(m);
      final inflight = messages
          .where(_preserveInflightOutsideHydrationGraft)
          .toList(growable: false);
      final durableFallback = messages
          .where((message) => !_preserveInflightOutsideHydrationGraft(message))
          .toList(growable: false);
      final graft = _graftRefreshedTail(
        normalized,
        durableFallback,
        refreshedTranscriptComplete:
            hydrationStatus == _HydrationTailStatus.complete,
      );
      if (!graft.acceptedRefreshed) return;
      if (hydrationStatus == _HydrationTailStatus.incomplete) {
        _recordIncompleteHydrationTail();
      } else {
        _desktopHistoryNeedsHydration = false;
        _recordTranscriptPage(page);
      }
      _commitRefreshedTailEvidence(
        normalized,
        graft,
        preserveTailHydration:
            hydrationStatus == _HydrationTailStatus.incomplete,
      );
      _captureArtifactMaps(m, logicalSessionId: logicalSessionId);
      final hydrated = <Map<String, dynamic>>[
        ...inflight,
        ..._preserveLocalAssistantErrors(graft.messages, durableFallback),
      ];
      messages = _applyCancelledTurnTombstones(
        _associateGeneratedImagesNewestFirst(hydrated),
        incomingTranscriptComplete: _transcriptIsComplete,
      );
      _mergeSteerRecords();
      _reconcileSubagentsFromTranscript();
      messagesLoaded = true;
      _emit(ActiveChatEvent.messagesHydrated);
    } catch (error) {
      debugPrint(
        '[active-chat] deferred history hydration failed '
        '(${error.runtimeType})',
      );
    }
  }

  DesktopSessionSnapshot _withoutPersistedMessages(
    DesktopSessionSnapshot snapshot,
  ) => DesktopSessionSnapshot(
    runtimeSessionId: snapshot.runtimeSessionId,
    storedSessionId: snapshot.storedSessionId,
    created: snapshot.created,
    messagesProvided: false,
    messagesFullyParsed: snapshot.messagesFullyParsed,
    messageCount: snapshot.messageCount,
    inflight: snapshot.inflight,
    queued: snapshot.queued,
    running: snapshot.running,
    status: snapshot.status,
    startedAt: snapshot.startedAt,
    turnStartedAt: snapshot.turnStartedAt,
    info: snapshot.info,
    raw: snapshot.raw,
  );

  DesktopSessionSnapshot _withoutLiveDesktopProjection(
    DesktopSessionSnapshot snapshot,
  ) => DesktopSessionSnapshot(
    runtimeSessionId: snapshot.runtimeSessionId,
    storedSessionId: snapshot.storedSessionId,
    created: snapshot.created,
    messages: snapshot.messages,
    messagesProvided: snapshot.messagesProvided,
    messagesFullyParsed: snapshot.messagesFullyParsed,
    messageCount: snapshot.messageCount,
    hydrating: snapshot.hydrating,
    running: false,
    status: snapshot.status,
    startedAt: snapshot.startedAt,
    turnStartedAt: snapshot.turnStartedAt,
    info: snapshot.info,
    raw: snapshot.raw,
  );

  List<Map<String, dynamic>> _preserveLocalAssistantErrors(
    List<Map<String, dynamic>> next,
    List<Map<String, dynamic>> current,
  ) {
    const projectionIdKey = '_localTranscriptProjectionId';
    const pairIdKey = '_localTranscriptPairId';
    final currentProjectionIds =
        HashMap<Map<String, dynamic>, String>.identity();
    for (final message in current) {
      if (message['role'] != 'assistant_error') continue;
      final existingId = message[projectionIdKey];
      currentProjectionIds[message] =
          existingId is String && existingId.isNotEmpty
          ? existingId
          : _nextLocalTranscriptProjectionId();
    }
    final normalizedNext = List<Map<String, dynamic>>.of(next);
    final existing = <String>{};
    for (var index = 0; index < normalizedNext.length; index++) {
      final message = normalizedNext[index];
      if (message['role'] != 'assistant_error') continue;
      final rawId = message[projectionIdKey];
      final projectionId = rawId is String && rawId.isNotEmpty
          ? rawId
          : currentProjectionIds[message] ?? _nextLocalTranscriptProjectionId();
      existing.add(projectionId);
      if (rawId != projectionId) {
        normalizedNext[index] = {...message, projectionIdKey: projectionId};
      }
    }
    final existingUserIdentities = <TranscriptMessageIdentity>[
      for (final message in normalizedNext)
        if (isRealUserTurn(message)) ?_transcriptMessageIdentity(message),
    ];
    final existingPairIds = <String>{
      for (final message in normalizedNext)
        if (message[pairIdKey] case final String pairId)
          if (pairId.isNotEmpty) pairId,
    };
    final preserved = <Map<String, dynamic>>[];
    for (var index = 0; index < current.length; index++) {
      final message = current[index];
      if (message['role'] != 'assistant_error') continue;
      final projectionId = currentProjectionIds[message]!;
      if (existing.add(projectionId)) {
        preserved.add({...message, projectionIdKey: projectionId});
        final prompt = (message['_prompt'] ?? '').toString();
        if (prompt.isEmpty) continue;
        for (
          var candidate = index + 1;
          candidate < current.length;
          candidate++
        ) {
          final paired = current[candidate];
          if (!isRealUserTurn(paired)) continue;
          if ((paired['content'] ?? '').toString() != prompt) break;
          final pairedIdentity = _transcriptMessageIdentity(paired);
          if (pairedIdentity != null &&
              _identityCollectionContains(
                existingUserIdentities,
                pairedIdentity,
              )) {
            break;
          }
          final pairId = paired[pairIdKey];
          if (pairId is String && existingPairIds.contains(pairId)) break;
          if (normalizedNext.any((item) => identical(item, paired))) break;
          preserved.add({...paired, pairIdKey: projectionId});
          existingPairIds.add(projectionId);
          if (pairedIdentity != null) {
            existingUserIdentities.add(pairedIdentity);
          }
          break;
        }
      }
    }
    if (preserved.isEmpty) return normalizedNext;
    return <Map<String, dynamic>>[...preserved, ...normalizedNext];
  }

  String _nextLocalTranscriptProjectionId() =>
      'local-assistant-error-${++_localTranscriptProjectionSerial}';

  void _ensureLocalAssistantErrorIdentities() {
    const projectionIdKey = '_localTranscriptProjectionId';
    const pairIdKey = '_localTranscriptPairId';
    for (var index = 0; index < messages.length; index++) {
      final error = messages[index];
      if (error['role'] != 'assistant_error') continue;
      final rawProjectionId = error[projectionIdKey];
      final projectionId =
          rawProjectionId is String && rawProjectionId.isNotEmpty
          ? rawProjectionId
          : _nextLocalTranscriptProjectionId();
      if (rawProjectionId != projectionId) {
        messages[index] = {...error, projectionIdKey: projectionId};
      }
      final prompt = (error['_prompt'] ?? '').toString();
      if (prompt.isEmpty) continue;
      for (
        var candidate = index + 1;
        candidate < messages.length;
        candidate++
      ) {
        final user = messages[candidate];
        if (!isRealUserTurn(user)) continue;
        if ((user['content'] ?? '').toString() != prompt) break;
        if (user[pairIdKey] != projectionId) {
          messages[candidate] = {...user, pairIdKey: projectionId};
        }
        break;
      }
    }
  }

  void _tagLatestUserForLocalError(String projectionId) {
    for (var index = 0; index < messages.length; index++) {
      if (!isRealUserTurn(messages[index])) continue;
      messages[index] = {
        ...messages[index],
        '_localTranscriptPairId': projectionId,
      };
      return;
    }
  }

  void _mergeSteerRecords() {
    if (_steerRecords.isEmpty || messages.isEmpty) return;
    final anchors = <int, List<String>>{};
    for (final record in _steerRecords) {
      anchors
          .putIfAbsent(record.anchorUserOrdinal, () => [])
          .add(record.content);
    }
    final userIndexesOldestFirst = <int>[];
    for (var index = messages.length - 1; index >= 0; index--) {
      if (isRealUserTurn(messages[index])) {
        userIndexesOldestFirst.add(index);
      }
    }
    final ordinals = anchors.keys.toList()..sort();
    for (final ordinal in ordinals) {
      if (ordinal < 0 || ordinal >= userIndexesOldestFirst.length) continue;
      final userIndex = userIndexesOldestFirst[ordinal];
      var steerRunStart = userIndex;
      while (steerRunStart > 0 &&
          messages[steerRunStart - 1]['_steer'] == true) {
        steerRunStart--;
      }
      final existingChronological = messages
          .sublist(steerRunStart, userIndex)
          .reversed
          .toList(growable: false);
      final unusedExisting = List<bool>.filled(
        existingChronological.length,
        true,
      );
      final mergedChronological = <Map<String, dynamic>>[];
      for (final content in anchors[ordinal]!) {
        var matchingIndex = -1;
        for (var index = 0; index < existingChronological.length; index++) {
          if (unusedExisting[index] &&
              existingChronological[index]['content'] == content) {
            matchingIndex = index;
            break;
          }
        }
        if (matchingIndex >= 0) {
          unusedExisting[matchingIndex] = false;
          mergedChronological.add(existingChronological[matchingIndex]);
        } else {
          mergedChronological.add({
            'role': 'user',
            'content': content,
            '_steer': true,
          });
        }
      }
      for (var index = 0; index < existingChronological.length; index++) {
        if (unusedExisting[index]) {
          mergedChronological.add(existingChronological[index]);
        }
      }

      // Lista viva = más nuevo primero. Reconstruir el bloque completo evita
      // duplicar una corrección que ya llegó desde inflight.corrections.
      messages
        ..removeRange(steerRunStart, userIndex)
        ..insertAll(steerRunStart, mergedChronological.reversed);
    }
  }

  /// Persiste el transcript de un chat LOCAL (bridge) para que sobreviva al
  /// cierre de la pantalla. No-op en instancias remotas (el gateway ya guarda
  /// el historial server-side). Nunca lanza: la persistencia es best-effort.
  Future<void> _persistLocalTranscript() async {
    if (connection.kind != InstanceKind.localhost) return;
    try {
      await LocalTranscriptStore.saveFromNewestFirst(
        connection.id,
        sessionId,
        messages,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('persistLocalTranscript falló: $e');
    }
  }

  bool get _hasUnanchoredCancelledUser => messages.any(
    (message) =>
        isRealUserTurn(message) &&
        message['_cancelledUser'] == true &&
        message['_cancelledTurnFirstUser'] != true &&
        canonicalTranscriptMessageId(message) == null &&
        canonicalTranscriptRowId(message) == null,
  );

  /// A second optimistic turn must never start behind a cancelled user that
  /// still has no server identity: Stop could not anchor the new tombstone
  /// without crossing that ambiguous row. Refresh the complete transcript
  /// first and publish it only if every such row is now durably identified.
  Future<bool> _hydrateCancelledUserAnchorsBeforeSend() async {
    if (_onCancelledTurn == null) return true;
    if (!_hasUnanchoredCancelledUser) return true;
    final target = _latestUserCancellationCandidate();
    if (target == null) return false;
    final localTarget = messages[target.index];
    if (localTarget['_cancelledUser'] != true ||
        canonicalTranscriptMessageId(localTarget) != null ||
        canonicalTranscriptRowId(localTarget) != null) {
      return false;
    }
    final loadEpoch = _messageLoadEpoch;
    try {
      final page = await _loadStoredMessagesTail(_storedSessionProfile);
      if (_disposed || loadEpoch != _messageLoadEpoch) return false;
      if (page.messages.isEmpty) return false;
      final pageProvesComplete = _tailPageProvesTranscriptComplete(page);
      final normalized = _normalizedNewestFirst(page.messages);
      final hydratedTargetIndex = _cancelledTurnUserIndex(
        normalized,
        target.tombstone,
        incomingTranscriptComplete: pageProvesComplete,
      );
      if (hydratedTargetIndex < 0 ||
          (canonicalTranscriptMessageId(normalized[hydratedTargetIndex]) ==
                  null &&
              canonicalTranscriptRowId(normalized[hydratedTargetIndex]) ==
                  null)) {
        return false;
      }
      final projected = _applyCancelledTurnTombstones(
        _associateGeneratedImagesNewestFirst(normalized),
        incomingTranscriptComplete: pageProvesComplete,
      );

      final graft = _graftRefreshedTail(
        projected,
        messages,
        refreshedTranscriptComplete: pageProvesComplete,
      );
      if (!graft.acceptedRefreshed) return false;

      _captureArtifactMaps(page.messages, logicalSessionId: logicalSessionId);
      _recordTranscriptPage(
        page,
        preserveExistingCoverage: graft.preservesExistingCoverage,
      );
      _commitRefreshedTailEvidence(projected, graft);
      final anchored = graft.messages
          .where((message) => !identical(message, localTarget))
          .toList();
      messages = _preserveLocalAssistantErrors(anchored, messages);
      _mergeSteerRecords();
      _reconcileSubagentsFromTranscript();
      messagesLoaded = true;
      _emit(ActiveChatEvent.messagesHydrated);
      return !_hasUnanchoredCancelledUser;
    } catch (error) {
      debugPrint(
        '[active-chat] cancelled turn identity unavailable '
        '(${error.runtimeType})',
      );
      return false;
    }
  }

  /// Lanza el envío con streaming. Inserta los mensajes optimistas y arranca el
  /// SSE en este servicio (no en el widget), de modo que continúa al navegar.
  Future<bool> send({
    required String fullText,
    required String model,
    required List<Map<String, dynamic>> history,
    String profile = '',
    String? serverSessionId,
    bool slowModel = false,
    List<AttachmentDraft> nativeAttachments = const [],
    String? desktopText,
    bool voicePlaybackInterrupted = false,
    int? truncateBeforeUserOrdinal,
    ActiveTurnDelivery? delivery,
    DesktopSessionCreateConfig sessionConfig =
        const DesktopSessionCreateConfig(),
    Future<void> Function(String storedSessionId)? beforeDesktopPromptSubmit,
  }) => _send(
    fullText: fullText,
    model: model,
    history: history,
    profile: profile,
    serverSessionId: serverSessionId,
    slowModel: slowModel,
    nativeAttachments: nativeAttachments,
    desktopText: desktopText,
    voicePlaybackInterrupted: voicePlaybackInterrupted,
    truncateBeforeUserOrdinal: truncateBeforeUserOrdinal,
    delivery: delivery,
    sessionConfig: sessionConfig,
    beforeDesktopPromptSubmit: beforeDesktopPromptSubmit,
  );

  Future<bool> _send({
    required String fullText,
    required String model,
    required List<Map<String, dynamic>> history,
    String profile = '',
    String? serverSessionId,
    bool slowModel = false,
    List<AttachmentDraft> nativeAttachments = const [],
    String? desktopText,
    bool voicePlaybackInterrupted = false,
    int? truncateBeforeUserOrdinal,
    int? truncateBeforeRowId,
    ActiveTurnDelivery? delivery,
    DesktopSessionCreateConfig sessionConfig =
        const DesktopSessionCreateConfig(),
    Future<void> Function(String storedSessionId)? beforeDesktopPromptSubmit,
    _RewriteReservation? rewriteReservation,
  }) async {
    try {
      await _flushPendingCancelledTombstoneUpdates();
    } catch (_) {
      await delivery?.markUnaccepted();
      return false;
    }
    if (_cancelledTurnPersistencePending || _cancelledTurnPersistenceFailed) {
      await _cancelledTurnPersistence;
      if (_disposed) return false;
    }
    final pendingCancel = _desktopCancelRecovery;
    if (pendingCancel != null) {
      await pendingCancel;
      if (_disposed) return false;
    }
    if (!await _hydrateCancelledUserAnchorsBeforeSend()) {
      await delivery?.markUnaccepted();
      return false;
    }
    if (desktopCompressionInFlight) {
      throw const TuiGatewayRpcError(
        'prompt.submit',
        'Session compression is still running',
        code: 4009,
      );
    }
    final reservedRewrite = _activeRewrite;
    if (reservedRewrite != null &&
        !identical(reservedRewrite, rewriteReservation) &&
        reservedRewrite.transportStarted) {
      return false;
    }
    if (rewriteReservation != null) {
      if (!identical(reservedRewrite, rewriteReservation)) return false;
      rewriteReservation.transportStarted = true;
    }
    _finishVoiceBargeHandoff(notifyTerminal: false);
    _beginObservedResponseTiming();
    final capturedSessionConfig = sessionConfig.isEmpty
        ? _stagedFirstSubmitConfig
        : sessionConfig;
    if (truncateBeforeUserOrdinal == null) {
      _rewindRollbackMessages = null;
      _rewindRollbackState = null;
      _rewind4018FallbackOrdinal = null;
      _rewindRestoredOnError = false;
    }
    final turnEpoch = _advanceTurnEpoch();
    // Una hidratación iniciada al abrir la ruta nunca puede aterrizar después
    // del primer submit y sustituir el turno optimista recién insertado.
    _messageLoadEpoch += 1;
    final sessionProfile = _bindSessionProfile(profile);
    _storedSessionProfile = sessionProfile;
    _expireInteractivePromptsForRuntime(_desktopRuntimeSessionId);
    _activeTurnDelivery = delivery;
    lastPrompt = fullText;
    _lastModel = model;
    _turnProfile = sessionProfile;
    _turnSessionConfig = capturedSessionConfig;
    _slowModel = slowModel;
    // Sesión server-side a usar para este turno (y los reintentos/cola de este
    // turno). Si es null se usa la propia [sessionId] del chat. El modo voz pasa
    // su sesión rotable aquí: así puede empezar de cero tras cancelar sin tocar
    // la identidad del ActiveChat. El contexto se conserva porque el historial
    // completo viaja en cada turno (no depende de la sesión del servidor).
    // El modo voz puede rotar deliberadamente su sesión server-side. Solo una
    // rotación real invalida el binding Desktop anterior; los turnos normales
    // (override null → null) conservan el id canónico obtenido por resume.
    final serverSessionScopeChanged = serverSessionId != _serverSessionOverride;
    if (serverSessionScopeChanged) {
      _retireDesktopRuntime();
      _desktopStoredSessionId = null;
      _usingDesktopGateway = false;
    }
    _serverSessionOverride = serverSessionId;
    _captureActiveTurnTranscriptBoundary(
      turnEpoch,
      allowExistingTranscript: !serverSessionScopeChanged,
    );
    state = ChatPipelineState.connecting;
    trace.clear();
    _activeVoiceTools.clear();
    traceActive = true;
    pendingApproval = null;
    _pendingDesktopInterimKey = null;
    _assistantNarration.reset();
    currentRunId = null;
    _terminalTimer?.cancel();
    _terminalTimer = null;
    _runTerminal = false;
    _desktopTurnStartedAt = null;
    _subagentActivities = null;
    _subagentTranscriptTurnAnchor = null;
    // Un terminal sin texto o una reconciliación tardía no puede arrastrar el
    // placeholder del turno anterior al nuevo timeline.
    _settlePipelinePlaceholders();
    // Optimista: el mensaje del usuario aparece de inmediato.
    messages.insert(0, {
      'role': 'user',
      'content': fullText,
      '_optimistic': true,
    });
    // Burbuja placeholder del asistente con el estado del pipeline.
    messages.insert(0, {'role': 'assistant', 'content': '', '_pipeline': true});
    _emit(ActiveChatEvent.started);
    if (rewriteReservation != null) {
      rewriteReservation.transcriptRevision = _transcriptRevision;
    }

    if (!capturedSessionConfig.allowTransportFallback &&
        _desktopGateway is! HermesDesktopSessionLifecycleGateway) {
      _failRun('Hermes Desktop session lifecycle is required');
      return _finishTurnDelivery(delivery, false, turnEpoch);
    }

    // Perfil activo (no-default): routing por capacidad, AISLADO en su propio
    // método para NO tocar el camino default. Local → aislamiento completo vía
    // bridge (`hermes --profile`); remoto → personalidad (SOUL inyectado).
    // Degrada con seguridad a default si nada aplica.
    // Hermes Desktop 0.19 ya aísla el perfil de forma nativa en
    // session.resume/session.create. En ese contrato no sondeamos el Mobile
    // Bridge: además de añadir latencia, podía desviar un chat moderno al
    // transporte heredado. El bridge queda solo para gateways sin lifecycle.
    if (profileRoutes(sessionProfile) &&
        _desktopGateway is! HermesDesktopSessionLifecycleGateway) {
      final accepted = await _dispatchWithProfile(
        fullText,
        model,
        history,
        sessionProfile,
        turnEpoch,
        nativeAttachments: nativeAttachments,
      );
      return _finishTurnDelivery(delivery, accepted, turnEpoch);
    }

    // Instancia LOCAL: no expone la API HTTP `/v1/runs` (su chat nativo es por
    // WebSocket). Se ejecuta el turno vía el Mobile Bridge (`/bridge/chat` →
    // `hermes -z`), que carga modelo/tools/memoria/skills y devuelve la
    // respuesta final.
    if (connection.kind == InstanceKind.localhost &&
        _desktopGateway is! HermesDesktopSessionLifecycleGateway) {
      await _sendViaBridge(
        fullText,
        history,
        profile: sessionProfile,
        turnEpoch: turnEpoch,
        nativeAttachments: nativeAttachments,
      );
      final accepted =
          _turnEpoch == turnEpoch && state != ChatPipelineState.failed;
      return _finishTurnDelivery(delivery, accepted, turnEpoch);
    }
    // Mismo transporte que Hermes Desktop. Si la instancia no expone
    // `/api/ws`, degrada al motor REST `/v1/runs` sin steering parcheado.
    final accepted = await _startRemoteAgentTurn(
      fullText,
      model,
      history,
      turnEpoch,
      sessionConfig: capturedSessionConfig,
      profile: sessionProfile,
      nativeAttachments: nativeAttachments,
      desktopText: desktopText,
      voicePlaybackInterrupted: voicePlaybackInterrupted,
      truncateBeforeUserOrdinal: truncateBeforeUserOrdinal,
      truncateBeforeRowId: truncateBeforeRowId,
      beforeDesktopPromptSubmit: beforeDesktopPromptSubmit,
    );
    return _finishTurnDelivery(delivery, accepted, turnEpoch);
  }

  Future<bool> _finishTurnDelivery(
    ActiveTurnDelivery? delivery,
    bool accepted,
    int turnEpoch,
  ) async {
    if (delivery == null || _turnEpoch != turnEpoch) return accepted;
    if (accepted) {
      await delivery.markAccepted();
      if (_runTerminal ||
          state == ChatPipelineState.completed ||
          state == ChatPipelineState.failed ||
          state == ChatPipelineState.cancelled) {
        await delivery.markTerminalAndDelete();
        if (identical(_activeTurnDelivery, delivery)) {
          _activeTurnDelivery = null;
        }
      } else {
        await delivery.markRunning();
      }
    } else {
      await delivery.markUnaccepted();
    }
    return accepted;
  }

  void _finalizeAcceptedTurnDelivery() {
    final delivery = _activeTurnDelivery;
    if (delivery == null || !delivery.acknowledged) return;
    _activeTurnDelivery = null;
    unawaited(delivery.markTerminalAndDelete());
  }

  Future<bool> _beginTurnTransport(
    int turnEpoch,
    PreparedTurnTransport transport,
  ) async {
    if (_turnEpoch != turnEpoch || _runTerminal) return false;
    final delivery = _activeTurnDelivery;
    if (delivery == null) return true;
    final ready = await delivery.beginTransport(transport);
    if (!ready && _turnEpoch == turnEpoch && !_runTerminal) {
      _failRun('Could not save the turn before sending it.');
    }
    return ready;
  }

  void _rebindSurvivorUserRowIds(List<int?>? rowIds) {
    final authoritativeRowIds = rowIds ?? const <int?>[];
    final userIndexesOldestFirst = <int>[];
    for (var index = messages.length - 1; index >= 0; index--) {
      if (isRealUserTurn(messages[index])) {
        userIndexesOldestFirst.add(index);
      }
    }
    if (userIndexesOldestFirst.isEmpty) return;
    // El último usuario es el prompt nuevo insertado por send(); el ACK solo
    // describe las filas del prefijo que el gateway acaba de reinsertar.
    final survivorIndexes = userIndexesOldestFirst.sublist(
      0,
      userIndexesOldestFirst.length - 1,
    );
    final exact = survivorIndexes.length == authoritativeRowIds.length;
    for (var ordinal = 0; ordinal < survivorIndexes.length; ordinal++) {
      final index = survivorIndexes[ordinal];
      final rebound = Map<String, dynamic>.from(messages[index]);
      final rowId = exact ? authoritativeRowIds[ordinal] : null;
      if (rowId == null) {
        rebound.remove('_desktopRowId');
      } else {
        rebound['_desktopRowId'] = rowId;
      }
      messages[index] = rebound;
    }
    _transcriptRevision += 1;
    final reservation = _activeRewrite;
    if (reservation != null) {
      reservation.transcriptRevision = _transcriptRevision;
    }
  }

  /// Rebobina hasta un prompt visible y lo vuelve a ejecutar. El ordinal usa el
  /// mismo índice de usuarios (0-based, de antiguo a nuevo) que Hermes Desktop.
  /// La conversación visible se recorta de forma optimista; si el transporte
  /// falla antes de aceptar el prompt, [_startDesktopTurn] restaura la copia.
  Future<void> rewrite({
    required int userOrdinal,
    required String text,
    required String model,
    String profile = '',
  }) async {
    if (_activeRewrite != null) {
      throw StateError('Another conversation rewrite is already active');
    }
    final reservation = _RewriteReservation(
      transcriptRevision: _transcriptRevision,
      turnEpoch: _turnEpoch,
      runtimeSessionId: _desktopRuntimeSessionId,
    );
    _activeRewrite = reservation;
    _rewindDashboardAuthRequired = false;
    try {
      final snapshot = messages
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      final chronological = messages.reversed.toList();
      var seenUsers = 0;
      var targetIndex = -1;
      for (var i = 0; i < chronological.length; i++) {
        final message = chronological[i];
        if (!isRealUserTurn(message)) continue;
        if (seenUsers == userOrdinal) {
          targetIndex = i;
          break;
        }
        seenUsers++;
      }
      if (targetIndex < 0) {
        throw StateError('The message is no longer in this conversation');
      }
      final target = chronological[targetIndex];
      final fallbackOrdinal = modelSwitchRepairFallbackOrdinal(
        messages,
        target,
        desktopOrdinal: userOrdinal,
      );
      var runtimeId = _desktopRuntimeSessionId;
      var gateway = _desktopGateway;
      var truncateBeforeRowId = canonicalTranscriptRowId(target);

      if (truncateBeforeRowId == null && runtimeId == null) {
        final ready = await ensureDesktopRuntime();
        if (!identical(_activeRewrite, reservation) ||
            _turnEpoch != reservation.turnEpoch) {
          return;
        }
        if (!ready) {
          throw StateError('The message has no durable Desktop row identity');
        }
        runtimeId = _desktopRuntimeSessionId;
        gateway = _desktopGateway;
        reservation.runtimeSessionId = runtimeId;
        reservation.transcriptRevision = _transcriptRevision;
      }
      if (truncateBeforeRowId == null) {
        final resolver = gateway is HermesDesktopRewindResolverGateway
            ? gateway as HermesDesktopRewindResolverGateway
            : null;
        if (runtimeId == null || resolver == null) {
          throw StateError('The message has no durable Desktop row identity');
        }
        truncateBeforeRowId = await resolver.resolveDurableUserRowId(
          runtimeId,
          sourceText: (target['content'] ?? '').toString(),
          expectedOrdinal: userOrdinal,
        );
        if (truncateBeforeRowId == null) {
          throw StateError(
            'The message has no unambiguous durable Desktop row identity',
          );
        }
      }
      if (!identical(_activeRewrite, reservation) ||
          _transcriptRevision != reservation.transcriptRevision ||
          _turnEpoch != reservation.turnEpoch ||
          _desktopRuntimeSessionId != reservation.runtimeSessionId) {
        return;
      }
      if (gateway is! HermesDesktopDurableRewindGateway) {
        throw const TuiGatewayRpcError(
          'prompt.submit',
          'Durable conversation rewind is unavailable',
          code: -32601,
        );
      }

      if (isStreaming) {
        final interruptDrain = runtimeId != null && gateway != null
            ? Completer<void>()
            : null;
        _desktopInterruptDrain = interruptDrain;
        _discardLateInterruptTerminal = interruptDrain != null;
        _cancelCurrent(requestServerStop: false);
        reservation.transcriptRevision = _transcriptRevision;
        reservation.turnEpoch = _turnEpoch;
        if (runtimeId != null && gateway != null) {
          try {
            await gateway.interrupt(runtimeId);
            // session.interrupt confirma el RPC, pero el terminal del turno viejo
            // puede llegar después. No suscribimos el rewind hasta drenarlo: si no,
            // "Operation interrupted" puede cerrar el turno editado recién creado.
            await interruptDrain?.future.timeout(const Duration(seconds: 3));
          } on TimeoutException {
            // Gateways antiguos pueden no publicar terminal de interrupción. El
            // guard de _onDesktopEvent seguirá descartándolo si llega más tarde.
          } catch (_) {
            // prompt.submit también aplica el busy gate; el envío mostrará el
            // error real si el agente todavía no estuviera listo.
          } finally {
            if (identical(_desktopInterruptDrain, interruptDrain)) {
              _desktopInterruptDrain = null;
            }
          }
        }
      }
      if (!identical(_activeRewrite, reservation) ||
          _turnEpoch != reservation.turnEpoch) {
        return;
      }
      reservation.runtimeSessionId = _desktopRuntimeSessionId;
      reservation.transcriptRevision = _transcriptRevision;

      final prefix = chronological
          .take(targetIndex)
          .where((m) {
            final role = m['role'];
            return (role == 'user' || role == 'assistant') &&
                m['_pipeline'] != true;
          })
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      final rollbackState = state;
      messages = prefix.reversed.toList();
      _rewindRollbackMessages = snapshot;
      _rewindRollbackState = rollbackState;
      _rewind4018FallbackOrdinal = fallbackOrdinal;
      _rewindRestoredOnError = false;
      final history = _buildHistoryFromMessages();
      try {
        final accepted = await _send(
          fullText: text,
          model: model,
          history: history,
          profile: profile,
          truncateBeforeUserOrdinal: userOrdinal,
          truncateBeforeRowId: truncateBeforeRowId,
          rewriteReservation: reservation,
        );
        if (!accepted) return;
      } catch (_) {
        messages = snapshot;
        state = rollbackState;
        _rewindRollbackMessages = null;
        _rewindRollbackState = null;
        _rewind4018FallbackOrdinal = null;
        rethrow;
      }
    } finally {
      if (identical(_activeRewrite, reservation)) {
        _activeRewrite = null;
      }
    }
  }

  /// Calienta la conexión al gateway (ver [ApiClient.warmUp]). Lo llama el modo
  /// voz al entrar para que el primer turno no pague el handshake en frío.
  Future<void> warmUp() => _api.warmUp();

  /// Abre anticipadamente el canal oficial de chat. Además de reducir la
  /// latencia del primer prompt, ejecuta la reparación de credenciales del
  /// Dashboard antes de que un seguimiento pueda caer al fallback de cola.
  Future<void> warmDesktopGateway() async {
    if (connection.kind == InstanceKind.localhost) return;
    // Antes de reconectar: un socket ya caído bajo un turno todavía "vivo" es
    // la evidencia de que el turno se quedó colgado, y reconectar aquí la
    // borraría. Reabrir el chat es la ocasión en que el usuario lo ve.
    recoverTurnIfTransportLost();
    try {
      if (_desktopRuntimeSessionId != null &&
          _desktopGateway?.isConnected != true) {
        await ensureDesktopRuntime();
        return;
      }
      await _desktopGateway?.connect();
    } catch (error) {
      debugPrint(
        '[active-chat] Desktop gateway warm-up failed '
        '(${error.runtimeType})',
      );
      // Best-effort: send conserva su fallback REST para bridges antiguos.
    }
  }

  /// Ensures an existing durable chat has a live runtime without ever creating
  /// one. A 4007 means this is still a local draft and is reported as `false`.
  Future<bool> ensureDesktopRuntime() async {
    final gateway = _desktopGateway;
    if (_desktopRuntimeSessionId != null && gateway?.isConnected == true) {
      return true;
    }
    if (gateway == null || gateway is! HermesDesktopSessionLifecycleGateway) {
      return false;
    }
    if (_desktopStoredSessionKnownMissing) return false;
    final lifecycle = gateway as HermesDesktopSessionLifecycleGateway;
    final previousRuntimeId = _desktopRuntimeSessionId;
    final durableId = _desktopStoredSessionId ?? serverSessionId;
    final bindEpoch = ++_desktopBindEpoch;
    try {
      _listenToDesktopGateway(gateway);
      await gateway.connect();
      DesktopSessionSnapshot snapshot;
      final activity = gateway is HermesDesktopSessionActivityGateway
          ? gateway as HermesDesktopSessionActivityGateway
          : null;
      if (previousRuntimeId != null && activity != null) {
        try {
          snapshot = await activity.activateSession(
            previousRuntimeId,
            storedSessionId: durableId,
          );
        } on TuiGatewayRpcError catch (error) {
          final invalidCapability =
              activity.capabilityState(
                DesktopGatewayCapability.sessionActivate,
              ) ==
              DesktopGatewayCapabilityState.invalid;
          if (error.code != 4007 &&
              error.code != -32601 &&
              !invalidCapability) {
            rethrow;
          }
          snapshot = await lifecycle.resumeExisting(
            durableId,
            profile: _storedSessionProfile,
          );
        }
      } else {
        snapshot = await lifecycle.resumeExisting(
          durableId,
          profile: _storedSessionProfile,
        );
      }
      if (_disposed || bindEpoch != _desktopBindEpoch) {
        return _desktopRuntimeSessionId != null;
      }
      if (snapshot.messagesProvided) {
        _captureArtifactMessages(
          snapshot.messages,
          logicalSessionId: logicalSessionId,
        );
      }
      final infoChanged = snapshot.info != _desktopRuntimeInfo;
      _desktopStoredSessionId = snapshot.storedSessionId;
      _rebaseSubagentActivityScope(snapshot.runtimeSessionId);
      _adoptDesktopRuntime(snapshot.runtimeSessionId, info: snapshot.info);
      _restorePendingClarify(snapshot);
      _desktopStoredSessionKnownMissing = false;
      _desktopRuntimeInfo = snapshot.info;
      _rememberDesktopLiveStatus(snapshot.status, running: snapshot.running);
      _desktopStartedAt = snapshot.startedAt;
      _desktopTurnStartedAt = snapshot.running
          ? snapshot.resolvedTurnStartedAt
          : null;
      if (infoChanged || snapshot.info != const DesktopSessionRuntimeInfo()) {
        _emit(ActiveChatEvent.sessionInfo);
      }
      return true;
    } on TuiGatewayRpcError catch (error) {
      if (error.code == 4007 || error.code == -32601) return false;
      rethrow;
    }
  }

  /// Loads the authenticated 0.19 catalog for this live session without ever
  /// creating a runtime. Drafts and legacy servers return `null` so the caller
  /// can use its existing Dashboard/Bridge read-only fallback.
  Future<DesktopModelCatalog?> loadDesktopModelCatalog({
    bool refresh = false,
  }) async {
    if (!await ensureDesktopRuntime()) return null;
    final gateway = _desktopGateway;
    final runtimeId = _desktopRuntimeSessionId;
    if (gateway is! HermesDesktopModelCatalogGateway || runtimeId == null) {
      return null;
    }
    final catalogGateway = gateway as HermesDesktopModelCatalogGateway;
    try {
      return await catalogGateway.modelOptions(runtimeId, refresh: refresh);
    } on TuiGatewayRpcError catch (error) {
      if (error.code == 4007 || error.code == -32601) return null;
      rethrow;
    }
  }

  /// Pide el desglose bajo demanda, igual que el panel de Hermes Desktop.
  ///
  /// Nunca crea una sesión: un draft o un servidor anterior a 0.19 devuelve
  /// `null` y la UI conserva el resumen de `session.info`.
  Future<DesktopContextBreakdown?> loadDesktopContextBreakdown() async {
    if (!await ensureDesktopRuntime()) return null;
    final gateway = _desktopGateway;
    final runtimeId = _desktopRuntimeSessionId;
    if (gateway is! HermesDesktopContextUsageGateway || runtimeId == null) {
      return null;
    }
    final contextGateway = gateway as HermesDesktopContextUsageGateway;
    try {
      final result = await contextGateway.contextBreakdown(runtimeId);
      if (_disposed || _desktopRuntimeSessionId != runtimeId) return null;
      return result;
    } on TuiGatewayRpcError catch (error) {
      if (error.code == 4007 || error.code == -32601) return null;
      rethrow;
    }
  }

  /// Catálogo vivo del mismo Gateway que usa Hermes Desktop. No crea sesión.
  Future<DesktopCommandCatalog?> loadDesktopCommandCatalog() async {
    final gateway = _desktopGateway;
    if (gateway is! HermesDesktopCommandGateway) return null;
    try {
      return await (gateway as HermesDesktopCommandGateway).commandsCatalog();
    } on TuiGatewayRpcError catch (error) {
      if (error.code == -32601) return null;
      rethrow;
    }
  }

  /// Completion efímera. El llamador debe resolver de nuevo contra catálogo o
  /// comando nativo antes de ejecutar; una suggestion nunca concede capability.
  Future<SlashCompletionBatch?> completeDesktopSlash(String text) async {
    final gateway = _desktopGateway;
    if (gateway is! HermesDesktopCommandGateway) return null;
    try {
      return await (gateway as HermesDesktopCommandGateway).completeSlash(text);
    } on TuiGatewayRpcError catch (error) {
      if (error.code == -32601) return null;
      rethrow;
    }
  }

  /// Ejecuta un comando publicado sin convertirlo jamás en prompt ordinario.
  Future<DesktopCommandRpcResult> executeDesktopSlash(
    String name, {
    String arg = '',
  }) async {
    if (connection.readOnly) {
      throw const TuiGatewayRpcError(
        'slash.exec',
        'Remote commands are unavailable in read-only mode',
        code: 403,
      );
    }
    final canonical = CommandDescriptor.tryNormalizeName(name);
    if (canonical == null ||
        canonical == 'compact' ||
        canonical == 'compress') {
      throw const TuiGatewayRpcError(
        'slash.exec',
        'Command requires a dedicated Console adapter',
        code: 4004,
      );
    }
    late final String argument;
    try {
      argument = CommandArgumentSpec(
        kind: CommandArgumentKind.freeText,
        maxLength: 500,
      ).validate(arg);
    } on FormatException {
      throw const TuiGatewayRpcError(
        'slash.exec',
        'Invalid command argument',
        code: 4004,
      );
    }
    if (!await ensureDesktopRuntime()) {
      throw const TuiGatewayRpcError(
        'slash.exec',
        'No live runtime is available for this command',
        code: 4007,
      );
    }
    final gateway = _desktopGateway;
    final runtimeId = _desktopRuntimeSessionId;
    if (gateway is! HermesDesktopCommandGateway || runtimeId == null) {
      throw const TuiGatewayRpcError(
        'slash.exec',
        'Desktop command dispatch is unsupported',
        code: -32601,
      );
    }
    final command = argument.isEmpty ? canonical : '$canonical $argument';
    return (gateway as HermesDesktopCommandGateway).slashExec(
      runtimeId,
      command,
    );
  }

  /// Comprime mediante `session.compress`, el contrato autoritativo actual de
  /// Hermes Desktop. Solo un Gateway antiguo que responda `method not found`
  /// degrada a `slash.exec`/`command.dispatch`.
  ///
  /// No existe fallback local: recortar mensajes en el móvil desalinearía el
  /// historial visible del que realmente usa el agente.
  Future<DesktopCommandDispatch> compressDesktopSession({
    String focusTopic = '',
  }) async {
    try {
      _bindTombstonesToDurableIds(
        messages,
        incomingTranscriptComplete: _transcriptIsComplete,
      );
      if (_cancelledTurnTombstones.any(
        (tombstone) => !tombstone.invalidated && !tombstone.hasTargetIdentity,
      )) {
        final completeTranscript = await _loadStoredMessages(
          _storedSessionProfile,
        );
        _bindTombstonesToDurableIds(
          _normalizedNewestFirst(completeTranscript),
          incomingTranscriptComplete: true,
        );
      }
      if (_cancelledTurnTombstones.any(
        (tombstone) => !tombstone.invalidated && !tombstone.hasTargetIdentity,
      )) {
        throw StateError('cancelled turn identity is still ambiguous');
      }
      await _flushPendingCancelledTombstoneUpdates();
    } catch (_) {
      throw const TuiGatewayRpcError(
        'session.compress',
        'Cancelled turn metadata is not durable yet',
        code: 4009,
      );
    }
    if (connection.readOnly) {
      throw const TuiGatewayRpcError(
        'session.compress',
        'Session compression is unavailable in read-only mode',
        code: 403,
      );
    }
    if (isStreaming ||
        _messageQueue.isNotEmpty ||
        needsInput ||
        desktopCompressionInFlight) {
      throw const TuiGatewayRpcError(
        'session.compress',
        'Session is busy',
        code: 4009,
      );
    }
    final gateway = _desktopGateway;
    if (gateway is! HermesDesktopCompressionGateway &&
        gateway is! HermesDesktopCommandGateway) {
      throw const TuiGatewayRpcError(
        'session.compress',
        'Session compression is unsupported by this connection',
        code: -32601,
      );
    }
    final runtimeId = _desktopRuntimeSessionId;
    if (runtimeId == null) {
      throw const TuiGatewayRpcError(
        'session.compress',
        'No live runtime is available for session compression',
        code: 4007,
      );
    }

    _desktopCompressionInFlight = true;
    _emit(ActiveChatEvent.sessionInfo);
    final connectionEpoch = _desktopBindEpoch;
    final sessionEpoch = _desktopSessionEpoch;
    final compressionMessageLoadEpoch = _messageLoadEpoch;
    final compressionTombstoneRevision = _cancelledTombstoneRevision;
    bool compressionFenceStillValid() =>
        !_disposed &&
        _desktopRuntimeSessionId == runtimeId &&
        sessionEpoch == _desktopSessionEpoch &&
        connectionEpoch == _desktopBindEpoch &&
        compressionMessageLoadEpoch == _messageLoadEpoch &&
        compressionTombstoneRevision == _cancelledTombstoneRevision;
    try {
      if (gateway case final HermesDesktopCompressionGateway nativeGateway) {
        try {
          final compression = await nativeGateway.compressSession(
            runtimeId,
            focusTopic: focusTopic,
          );
          final result = _nativeCompressionDispatch(
            compression,
            runtimeId: runtimeId,
            focusTopic: focusTopic,
            connectionEpoch: connectionEpoch,
            sessionEpoch: sessionEpoch,
          );
          if (compressionFenceStillValid()) {
            await _applyNativeCompressionResult(
              compression,
              runtimeId,
              expectedMessageLoadEpoch: compressionMessageLoadEpoch,
              expectedTombstoneRevision: compressionTombstoneRevision,
            );
          }
          return result;
        } on TuiGatewayRpcError catch (error) {
          // No se reintenta un timeout ni un fallo remoto ambiguo: solo la
          // ausencia inequívoca del método habilita la compatibilidad antigua.
          if (error.code != -32601) rethrow;
          if (!compressionFenceStillValid()) {
            throw const TuiGatewayRpcError(
              'session.compress',
              'Session changed while compression fallback was pending',
              code: 4009,
            );
          }
        }
      }

      if (gateway is! HermesDesktopCommandGateway) {
        throw const TuiGatewayRpcError(
          'session.compress',
          'Session compression unsupported by this connection',
          code: -32601,
        );
      }
      final result =
          await CompressionDispatcher(
            gateway as HermesDesktopCommandGateway,
          ).compress(
            runtimeId,
            focusTopic: focusTopic,
            connectionEpoch: connectionEpoch,
            sessionEpoch: sessionEpoch,
            fallbackStillValid: compressionFenceStillValid,
          );
      if (!compressionFenceStillValid()) {
        return result;
      }
      if (result.accepted != DesktopCommandAcceptance.accepted) return result;

      final reconciled = await _reconcileCompressionSnapshot(
        runtimeId,
        sessionEpoch,
        expectedMessageLoadEpoch: compressionMessageLoadEpoch,
        expectedTombstoneRevision: compressionTombstoneRevision,
      );
      if (reconciled) return result;
      return DesktopCommandDispatch(
        commandName: result.commandName,
        arg: result.arg,
        sessionId: result.sessionId,
        connectionEpoch: result.connectionEpoch,
        sessionEpoch: result.sessionEpoch,
        attemptedRoute: result.attemptedRoute,
        fallbackUsed: result.fallbackUsed,
        dispatchKind: result.dispatchKind,
        output: result.output,
        accepted: DesktopCommandAcceptance.unknown,
        failure: const CommandFailure(
          kind: CommandFailureKind.transport,
          retryable: false,
        ),
      );
    } finally {
      _desktopCompressionInFlight = false;
      _clearDesktopCompactingIndicator();
      _emit(ActiveChatEvent.sessionInfo);
    }
  }

  DesktopCommandDispatch _nativeCompressionDispatch(
    DesktopCompressionResult compression, {
    required String runtimeId,
    required String focusTopic,
    required int connectionEpoch,
    required int sessionEpoch,
  }) {
    final output =
        <String?>[
              compression.summary.headline,
              compression.summary.tokenLine,
              compression.summary.note,
            ]
            .whereType<String>()
            .map((line) => line.trim())
            .where((line) {
              return line.isNotEmpty;
            })
            .join('\n');
    return DesktopCommandDispatch(
      commandName: 'compress',
      arg: focusTopic.trim(),
      sessionId: runtimeId,
      connectionEpoch: connectionEpoch,
      sessionEpoch: sessionEpoch,
      attemptedRoute: DesktopCommandRoute.sessionCompress,
      fallbackUsed: false,
      dispatchKind: output.isEmpty
          ? DesktopCommandDispatchKind.none
          : DesktopCommandDispatchKind.output,
      output: output.isEmpty ? null : output,
      accepted: DesktopCommandAcceptance.accepted,
    );
  }

  Future<void> _applyNativeCompressionResult(
    DesktopCompressionResult compression,
    String runtimeId, {
    required int expectedMessageLoadEpoch,
    required int expectedTombstoneRevision,
  }) async {
    if (_disposed ||
        expectedMessageLoadEpoch != _messageLoadEpoch ||
        expectedTombstoneRevision != _cancelledTombstoneRevision) {
      return;
    }
    final compressionMessageLoadEpoch = ++_messageLoadEpoch;
    final expectedSessionEpoch = _desktopSessionEpoch;
    final expectedBindEpoch = _desktopBindEpoch;
    final compressedStoredId = compression.info.storedSessionId?.trim();
    final nextStoredId =
        compressedStoredId != null && compressedStoredId.isNotEmpty
        ? compressedStoredId
        : _desktopStoredSessionId ?? serverSessionId;
    final snapshot = DesktopSessionSnapshot(
      runtimeSessionId: runtimeId,
      storedSessionId: nextStoredId,
      created: false,
      messages: compression.messages,
      messagesProvided: true,
      messageCount: compression.afterMessages,
      running: false,
      status: compression.status,
      info: compression.info,
    );
    final projection = const DesktopSessionReconciler().project(snapshot);
    if (_disposed ||
        compressionMessageLoadEpoch != _messageLoadEpoch ||
        expectedTombstoneRevision != _cancelledTombstoneRevision ||
        expectedSessionEpoch != _desktopSessionEpoch ||
        expectedBindEpoch != _desktopBindEpoch ||
        _desktopRuntimeSessionId != runtimeId) {
      return;
    }
    if (compressedStoredId != null && compressedStoredId.isNotEmpty) {
      final storedIdentityChanged =
          compressedStoredId != _desktopStoredSessionId;
      _desktopStoredSessionId = compressedStoredId;
      if (storedIdentityChanged) _adoptDesktopRuntime(runtimeId);
    }
    _captureArtifactMessages(
      compression.messages,
      logicalSessionId: logicalSessionId,
    );
    _markTranscriptComplete(
      visibleCount: projection.messagesNewestFirst.length,
    );
    messages = _applyCancelledTurnTombstones(
      _associateGeneratedImagesNewestFirst(
        _sanitizeDesktopFailureProjection(
          projection.messagesNewestFirst.map(Map<String, dynamic>.from),
        ),
      ),
      incomingTranscriptComplete: true,
    );
    _steerRecords.clear();
    messagesLoaded = true;
    _desktopRuntimeInfo = compression.info;
    _desktopTurnStartedAt = null;
    _observeSessionConfigInfo(compression.info);
    _reconcileSubagentsFromTranscript();
    _emit(ActiveChatEvent.messagesHydrated);
    _emit(ActiveChatEvent.sessionInfo);
  }

  Future<bool> _reconcileCompressionSnapshot(
    String expectedRuntimeId,
    int expectedSessionEpoch, {
    required int expectedMessageLoadEpoch,
    required int expectedTombstoneRevision,
  }) async {
    final gateway = _desktopGateway;
    if (gateway is! HermesDesktopSessionLifecycleGateway) return false;
    final durableId = _desktopStoredSessionId ?? serverSessionId;
    final expectedBindEpoch = _desktopBindEpoch;
    try {
      final snapshot = await (gateway as HermesDesktopSessionLifecycleGateway)
          .resumeExisting(durableId, profile: _storedSessionProfile);
      if (_disposed ||
          expectedMessageLoadEpoch != _messageLoadEpoch ||
          expectedTombstoneRevision != _cancelledTombstoneRevision ||
          expectedBindEpoch != _desktopBindEpoch ||
          expectedSessionEpoch != _desktopSessionEpoch ||
          _desktopRuntimeSessionId != expectedRuntimeId) {
        return false;
      }
      final snapshotTranscriptComplete = _desktopSnapshotTranscriptIsComplete(
        snapshot,
      );
      if (!snapshotTranscriptComplete) return false;
      final compressionMessageLoadEpoch = ++_messageLoadEpoch;
      final projection = const DesktopSessionReconciler().project(snapshot);
      if (_disposed ||
          compressionMessageLoadEpoch != _messageLoadEpoch ||
          expectedTombstoneRevision != _cancelledTombstoneRevision ||
          expectedBindEpoch != _desktopBindEpoch ||
          expectedSessionEpoch != _desktopSessionEpoch ||
          _desktopRuntimeSessionId != expectedRuntimeId) {
        return false;
      }
      _captureArtifactMessages(
        snapshot.messages,
        logicalSessionId: logicalSessionId,
      );
      _recordDesktopSnapshotTranscript(snapshot);
      messages = _applyCancelledTurnTombstones(
        _associateGeneratedImagesNewestFirst(
          projection.messagesNewestFirst
              .map(Map<String, dynamic>.from)
              .toList(growable: true),
        ),
        incomingTranscriptComplete: true,
      );
      _steerRecords.clear();
      messagesLoaded = true;
      _desktopStoredSessionId = snapshot.storedSessionId;
      _adoptDesktopRuntime(snapshot.runtimeSessionId, info: snapshot.info);
      _desktopRuntimeInfo = snapshot.info;
      _rememberDesktopLiveStatus(snapshot.status, running: snapshot.running);
      _desktopTurnStartedAt = null;
      _observeSessionConfigInfo(snapshot.info);
      _reconcileSubagentsFromTranscript();
      _emit(ActiveChatEvent.sessionInfo);
      return true;
    } on TuiGatewayRpcError catch (error) {
      if (error.code == 4007 || error.code == -32601) return false;
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<PendingSessionConfigChange> setSessionModel(
    DesktopModelSelection selection, {
    bool confirmExpensiveModel = false,
  }) => _setDesktopSessionConfig(
    SessionModelConfigValue.requested(selection),
    (gateway, runtimeId) => gateway.setSessionModel(
      runtimeId,
      selection,
      confirmExpensiveModel: confirmExpensiveModel,
    ),
  );

  Future<PendingSessionConfigChange> confirmSessionModel(
    PendingSessionConfigChange pending,
  ) {
    final scope = _sessionConfigScope;
    final current = scope == null
        ? null
        : _sessionConfigState.changeFor(scope, DesktopSessionConfigKey.model);
    final requested = pending.requestedValue;
    if (scope != pending.scope ||
        current?.requestEpoch != pending.requestEpoch ||
        current?.status != SessionConfigChangeStatus.confirmRequired ||
        requested is! SessionModelConfigValue ||
        requested.providerSlug == null) {
      throw const TuiGatewayRpcError(
        'config.set',
        'The model confirmation is no longer current',
        code: 4009,
      );
    }
    return setSessionModel(
      DesktopModelSelection(
        modelId: requested.modelId,
        providerSlug: requested.providerSlug!,
      ),
      confirmExpensiveModel: true,
    );
  }

  Future<PendingSessionConfigChange> setSessionReasoning(
    DesktopReasoningEffort effort,
  ) => _setDesktopSessionConfig(
    SessionReasoningConfigValue.requested(effort),
    (gateway, runtimeId) => gateway.setSessionReasoning(runtimeId, effort),
  );

  Future<PendingSessionConfigChange> setSessionFastMode(DesktopFastMode mode) =>
      _setDesktopSessionConfig(
        SessionFastConfigValue.requested(mode),
        (gateway, runtimeId) => gateway.setSessionFastMode(runtimeId, mode),
      );

  Future<PendingSessionConfigChange> _setDesktopSessionConfig(
    SessionConfigValue requested,
    Future<DesktopConfigSetResult> Function(
      HermesDesktopSessionConfigGateway gateway,
      String runtimeId,
    )
    send,
  ) async {
    if (connection.readOnly) {
      throw const TuiGatewayRpcError(
        'config.set',
        'Session configuration is unavailable in read-only mode',
        code: 403,
      );
    }
    final gateway = _desktopGateway;
    if (gateway is! HermesDesktopSessionConfigGateway) {
      throw const TuiGatewayRpcError(
        'config.set',
        'Session configuration is unsupported by this connection',
        code: -32601,
      );
    }
    final configGateway = gateway as HermesDesktopSessionConfigGateway;
    final scope = _sessionConfigScope;
    final runtimeId = _desktopRuntimeSessionId;
    if (scope == null || runtimeId == null) {
      throw const TuiGatewayRpcError(
        'config.set',
        'No live runtime is available for session configuration',
        code: 4007,
      );
    }

    final requestEpoch = ++_sessionConfigRequestEpoch;
    _sessionConfigState = SessionConfigReducer.reduce(
      _sessionConfigState,
      SessionConfigSendStarted(
        scope: scope,
        requestedValue: requested,
        requestEpoch: requestEpoch,
      ),
    );
    _emit(ActiveChatEvent.sessionInfo);

    try {
      final result = await send(configGateway, runtimeId);
      if (_disposed || _sessionConfigScope != scope) {
        return _capturedSessionConfigChange(scope, requested.key, requestEpoch);
      }
      _sessionConfigState = SessionConfigReducer.reduce(
        _sessionConfigState,
        SessionConfigRpcAccepted(
          scope: scope,
          requestEpoch: requestEpoch,
          result: result,
        ),
      );
    } catch (error) {
      if (_disposed || _sessionConfigScope != scope) {
        return _capturedSessionConfigChange(scope, requested.key, requestEpoch);
      }
      final failure = _sessionConfigFailure(error);
      _sessionConfigState = SessionConfigReducer.reduce(
        _sessionConfigState,
        failure == SessionConfigFailureKind.timeout ||
                failure == SessionConfigFailureKind.transport
            ? SessionConfigTimedOut(
                scope: scope,
                key: requested.key,
                requestEpoch: requestEpoch,
              )
            : SessionConfigRpcRejected(
                scope: scope,
                key: requested.key,
                requestEpoch: requestEpoch,
                failureKind: failure,
              ),
      );
    }
    _emit(ActiveChatEvent.sessionInfo);
    return _capturedSessionConfigChange(scope, requested.key, requestEpoch);
  }

  PendingSessionConfigChange _capturedSessionConfigChange(
    SessionConfigScope scope,
    DesktopSessionConfigKey key,
    int requestEpoch,
  ) {
    final change = _sessionConfigState.changeFor(scope, key);
    if (change == null || change.requestEpoch != requestEpoch) {
      throw StateError('Session configuration state was superseded');
    }
    return change;
  }

  SessionConfigFailureKind _sessionConfigFailure(Object error) {
    if (error is! TuiGatewayRpcError) {
      return SessionConfigFailureKind.transport;
    }
    return switch (error.code) {
      -32601 => SessionConfigFailureKind.unsupportedMethod,
      4002 => SessionConfigFailureKind.unsupported,
      4009 => SessionConfigFailureKind.busy,
      5001 => SessionConfigFailureKind.rejected,
      5032 => SessionConfigFailureKind.initialization,
      _ when error.message.contains('invalid session config response') =>
        SessionConfigFailureKind.invalidResponse,
      _ when error.message.toLowerCase().contains('timeout') =>
        SessionConfigFailureKind.timeout,
      _ => SessionConfigFailureKind.rejected,
    };
  }

  /// Reanuda una sesión durable sin permitir creación implícita en gateways
  /// modernos. Gateways legacy conservan su contrato anterior hasta que puedan
  /// anunciar [HermesDesktopSessionLifecycleGateway].
  Future<DesktopSessionSnapshot> _resumeDesktopSessionForRecovery(
    HermesDesktopGateway gateway,
    String storedSessionId, {
    required String profile,
    required String legacyModel,
    bool deferRuntimeCommit = false,
  }) async {
    if (deferRuntimeCommit &&
        gateway is HermesDesktopRecoverySessionLifecycleGateway) {
      final recoveryGateway =
          gateway as HermesDesktopRecoverySessionLifecycleGateway;
      return recoveryGateway.resumeExistingForRecovery(
        storedSessionId,
        profile: profile,
      );
    }
    if (gateway is HermesDesktopSessionLifecycleGateway) {
      final lifecycleGateway = gateway as HermesDesktopSessionLifecycleGateway;
      return lifecycleGateway.resumeExisting(storedSessionId, profile: profile);
    }
    return gateway.resumeSession(
      storedSessionId,
      profile: profile,
      model: legacyModel,
    );
  }

  void _commitDesktopRecoveryRuntime(
    HermesDesktopGateway gateway,
    String runtimeSessionId,
  ) {
    if (gateway is HermesDesktopRecoverySessionLifecycleGateway) {
      (gateway as HermesDesktopRecoverySessionLifecycleGateway)
          .commitRecoveryRuntime(runtimeSessionId);
    }
  }

  /// Resuelve una entrega ambigua únicamente mediante el contrato negociado.
  /// `known:false`, capability ausente o cualquier violación dejan el turno
  /// ambiguo; este método nunca llama submit ni cambia de transporte.
  Future<PreparedTurn> reconcileAmbiguousTurn(
    PreparedTurn turn,
    TurnOutboxPersistence store,
  ) async {
    if (turn.state != PreparedTurnState.ambiguous &&
        turn.state != PreparedTurnState.accepted &&
        turn.state != PreparedTurnState.running) {
      return turn;
    }
    final sessionProfile = _bindSessionProfile(turn.profile);
    final gateway = _desktopGateway;
    if (gateway == null || !await _canUseTurnIdempotency(gateway)) return turn;
    try {
      _listenToDesktopGateway(gateway);
      await gateway.connect();
      final binding = await _resumeDesktopSessionForRecovery(
        gateway,
        turn.sessionId,
        profile: sessionProfile,
        legacyModel: turn.model,
      );
      final status = await (gateway as HermesDesktopIdempotentGateway)
          .getTurnStatus(binding.runtimeSessionId, turn.clientTurnId);
      if (!status.known || status.state == null) return turn;
      final localState = switch (status.state!) {
        DesktopTurnState.accepted => PreparedTurnState.accepted,
        DesktopTurnState.running => PreparedTurnState.running,
        DesktopTurnState.terminal ||
        DesktopTurnState.failed ||
        DesktopTurnState.cancelled => PreparedTurnState.terminal,
      };
      final resolved = turn.copyWith(
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        state: localState,
      );
      await store.save(resolved);
      if (localState == PreparedTurnState.terminal) {
        await store.delete(resolved);
      }
      if (localState == PreparedTurnState.accepted ||
          localState == PreparedTurnState.running) {
        _desktopStoredSessionId = binding.storedSessionId;
        _adoptDesktopRuntime(binding.runtimeSessionId, info: binding.info);
        _usingDesktopGateway = true;
        _runTerminal = false;
        _activeTurnDelivery = ActiveTurnDelivery(
          prepared: resolved,
          store: store,
        );
        state = ChatPipelineState.waiting;
        _emit(ActiveChatEvent.connected);
        _armFirstTokenTimer();
      }
      return resolved;
    } on TuiGatewayRpcError {
      _turnIdempotencyInvalid = true;
      return turn;
    } catch (_) {
      // Corte de red/socket: no contradice la capability y tampoco demuestra
      // que el turno sea desconocido. Conserva ambiguous sin automatismos.
      return turn;
    }
  }

  /// Selecciona el canal oficial de Desktop cuando está disponible. El fallback
  /// REST conserva compatibilidad con instalaciones que solo publican 8642.
  Future<bool> _startRemoteAgentTurn(
    String fullText,
    String model,
    List<Map<String, dynamic>> history,
    int turnEpoch, {
    required DesktopSessionCreateConfig sessionConfig,
    String profile = '',
    List<AttachmentDraft> nativeAttachments = const [],
    String? desktopText,
    bool voicePlaybackInterrupted = false,
    int? truncateBeforeUserOrdinal,
    int? truncateBeforeRowId,
    Future<void> Function(String storedSessionId)? beforeDesktopPromptSubmit,
  }) {
    final gateway = _desktopGateway;
    if (gateway == null) {
      if (!sessionConfig.allowTransportFallback) {
        _failRun('Hermes Desktop session lifecycle is required');
        return Future<bool>.value(false);
      }
      return _startRestFallbackWithAttachments(
        fullText,
        model,
        history,
        turnEpoch,
        nativeAttachments,
      );
    }
    return _startDesktopTurn(
      gateway,
      fullText,
      turnEpoch,
      profile: profile,
      history: history,
      model: model,
      sessionConfig: sessionConfig,
      nativeAttachments: nativeAttachments,
      desktopText: desktopText,
      voicePlaybackInterrupted: voicePlaybackInterrupted,
      truncateBeforeUserOrdinal: truncateBeforeUserOrdinal,
      truncateBeforeRowId: truncateBeforeRowId,
      beforeDesktopPromptSubmit: beforeDesktopPromptSubmit,
      fallback: () {
        _rewindRollbackMessages = null;
        _rewindRollbackState = null;
        _rewind4018FallbackOrdinal = null;
        return _startRestFallbackWithAttachments(
          fullText,
          model,
          history,
          turnEpoch,
          nativeAttachments,
        );
      },
    );
  }

  /// Binds an existing durable session or creates a new runtime only after the
  /// first submit. Modern gateways keep resume and create separate so a 4007
  /// during read/recovery can never generate server-side session garbage.
  Future<DesktopSessionBinding> _bindDesktopSessionForFirstSubmit(
    HermesDesktopGateway gateway, {
    required String profile,
    required List<Map<String, dynamic>> history,
    required String legacyModel,
    required DesktopSessionCreateConfig config,
  }) async {
    if (gateway is HermesDesktopSessionLifecycleGateway) {
      final lifecycle = gateway as HermesDesktopSessionLifecycleGateway;
      if (_desktopStoredSessionKnownMissing && !config.createIfMissing) {
        throw const TuiGatewayRpcError(
          'session.resume',
          'Pinned session does not exist',
          code: 4007,
        );
      }
      if (!_desktopStoredSessionKnownMissing) {
        try {
          final snapshot = await lifecycle.resumeExisting(
            serverSessionId,
            profile: profile,
          );
          _desktopStoredSessionKnownMissing = false;
          return snapshot is DesktopSessionBinding
              ? snapshot
              : DesktopSessionBinding.fromSnapshot(snapshot);
        } on TuiGatewayRpcError catch (error) {
          if (error.code != 4007) rethrow;
          if (!config.createIfMissing) rethrow;
          _desktopStoredSessionKnownMissing = true;
        }
      }

      final DesktopSessionSnapshot snapshot;
      if (gateway is HermesDesktopConfiguredSessionLifecycleGateway) {
        snapshot =
            await (gateway as HermesDesktopConfiguredSessionLifecycleGateway)
                .createForFirstSubmitConfigured(
                  profile: profile,
                  seedMessages: history,
                  config: config,
                );
      } else {
        snapshot = await lifecycle.createForFirstSubmit(
          profile: profile,
          seedMessages: history,
          model: config.model?.modelId ?? legacyModel,
        );
      }
      _desktopStoredSessionKnownMissing = false;
      return snapshot is DesktopSessionBinding
          ? snapshot
          : DesktopSessionBinding.fromSnapshot(snapshot);
    }

    if (!config.allowTransportFallback) {
      throw const TuiGatewayRpcError(
        'session.resume',
        'Hermes Desktop session lifecycle is required',
        code: -32601,
      );
    }

    return gateway.resumeSession(
      serverSessionId,
      profile: profile,
      seedMessages: history,
      model: config.model?.modelId ?? legacyModel,
    );
  }

  Future<bool> _startDesktopTurn(
    HermesDesktopGateway gateway,
    String fullText,
    int turnEpoch, {
    required String profile,
    required List<Map<String, dynamic>> history,
    required String model,
    required DesktopSessionCreateConfig sessionConfig,
    required Future<bool> Function() fallback,
    List<AttachmentDraft> nativeAttachments = const [],
    String? desktopText,
    bool voicePlaybackInterrupted = false,
    int? truncateBeforeUserOrdinal,
    int? truncateBeforeRowId,
    Future<void> Function(String storedSessionId)? beforeDesktopPromptSubmit,
  }) async {
    var submissionAttempted = false;
    var idempotentSubmission = false;
    try {
      _listenToDesktopGateway(gateway);
      await gateway.connect();
      if (_turnEpoch != turnEpoch || _runTerminal) return false;
      var runtimeId = _desktopRuntimeSessionId;
      if (runtimeId == null) {
        final binding =
            _desktopStoredSessionKnownMissing || !sessionConfig.isEmpty
            ? await _bindDesktopSessionForFirstSubmit(
                gateway,
                profile: profile,
                history: history,
                legacyModel: model,
                config: sessionConfig,
              )
            : await gateway.resumeSession(
                serverSessionId,
                profile: profile,
                seedMessages: history,
                model: model,
              );
        runtimeId = binding.runtimeSessionId;
        if (binding.created) {
          _stagedFirstSubmitConfig = const DesktopSessionCreateConfig();
        }
        _desktopStoredSessionId = binding.storedSessionId;
        _desktopStoredSessionKnownMissing = false;
        _adoptDesktopRuntime(runtimeId, info: binding.info);
        if (binding.info != _desktopRuntimeInfo) {
          _desktopRuntimeInfo = binding.info;
          _emit(ActiveChatEvent.sessionInfo);
        }
      }
      if (beforeDesktopPromptSubmit != null) {
        final storedId = _desktopStoredSessionId?.trim();
        if (storedId == null || storedId.isEmpty) {
          throw StateError('Hermes did not confirm a durable session id');
        }
        await beforeDesktopPromptSubmit(storedId);
      }
      if (_turnEpoch != turnEpoch || _runTerminal) return false;
      _adoptDesktopRuntime(runtimeId);
      _usingDesktopGateway = true;
      currentRunId = null;
      state = ChatPipelineState.waiting;
      await _onForegroundKeepAlive?.call();
      _emit(ActiveChatEvent.connected);
      _armFirstTokenTimer();
      var promptText = desktopText ?? fullText;
      final attachedImagePaths = <String>[];
      final legacyFileRefs = <String>[];
      final delivery = _activeTurnDelivery;
      final attachmentsForRuntime =
          delivery?.current.activeAttachments ??
          nativeAttachments
              .where(
                (item) => item.uploadState != AttachmentUploadState.removed,
              )
              .toList(growable: false);
      if (attachmentsForRuntime.isNotEmpty) {
        final String attachmentRuntimeId = runtimeId;
        final HermesDesktopAttachmentGateway? attachmentGateway =
            gateway is HermesDesktopAttachmentGateway
            ? gateway as HermesDesktopAttachmentGateway
            : null;
        if (attachmentGateway == null) {
          throw const TuiGatewayRpcError(
            'attachment',
            'Native Desktop attachments are unavailable',
            code: -32601,
          );
        }
        for (final attachment in attachmentsForRuntime) {
          final alreadyAttached = attachment.isAttachedTo(
            attachmentRuntimeId,
            transport: AttachmentRemoteTransport.desktop,
          );
          if (!alreadyAttached &&
              (attachment.localPath.isEmpty ||
                  !await File(attachment.localPath).exists())) {
            _failRun('Could not read a local attachment.');
            return false;
          }
        }
        if (!await _beginTurnTransport(
          turnEpoch,
          PreparedTurnTransport.desktop,
        )) {
          return false;
        }
        // Desde este punto ya puede existir una mutación remota aunque todavía
        // no se haya llamado prompt.submit. Nunca degradamos a otro transporte.
        submissionAttempted = true;
        for (final initialAttachment in attachmentsForRuntime) {
          var attachment = initialAttachment;
          if (delivery != null && attachment.localId.isNotEmpty) {
            final staged = await delivery.beginAttachmentUpload(
              attachment.localId,
              remoteSessionId: attachmentRuntimeId,
              transport: AttachmentRemoteTransport.desktop,
            );
            if (staged == null) {
              if (delivery.persistenceFailed) {
                _failRun('Could not save the state of an attachment.');
              } else {
                _failRun('The attachment batch changed during upload.');
              }
              return false;
            }
            attachment = staged;
            if (attachment.isAttachedTo(
              attachmentRuntimeId,
              transport: AttachmentRemoteTransport.desktop,
            )) {
              continue;
            }
          }
          try {
            final bytes = await File(attachment.localPath).readAsBytes();
            final encoded = base64Encode(bytes);
            late final String remoteRef;
            if (attachment.isImage) {
              final result = await attachmentGateway.attachImageBytes(
                attachmentRuntimeId,
                filename: attachment.name,
                contentBase64: encoded,
              );
              remoteRef = result.path ?? '';
            } else {
              final result = await attachmentGateway.attachFileBytes(
                attachmentRuntimeId,
                filename: attachment.name,
                mimeType: attachment.mimeType.isEmpty
                    ? 'application/octet-stream'
                    : attachment.mimeType,
                contentBase64: encoded,
              );
              remoteRef = result.refText ?? '';
            }
            if (remoteRef.isEmpty) {
              throw const TuiGatewayRpcError(
                'attachment',
                'Hermes omitted the attachment reference',
              );
            }
            if (delivery == null || attachment.localId.isEmpty) {
              if (attachment.isImage) {
                attachedImagePaths.add(remoteRef);
              } else {
                legacyFileRefs.add(remoteRef);
              }
              continue;
            }
            final persisted = await delivery.markAttachmentAttached(
              attachment.localId,
              attempt: attachment.attempt,
              remoteSessionId: attachmentRuntimeId,
              transport: AttachmentRemoteTransport.desktop,
              remoteRef: remoteRef,
            );
            if (!persisted) {
              if (attachment.isImage) {
                try {
                  await attachmentGateway.detachImage(
                    attachmentRuntimeId,
                    remoteRef,
                  );
                } catch (_) {}
              }
              _failRun(
                delivery.persistenceFailed
                    ? 'Could not save the state of an attachment.'
                    : 'The attachment batch changed during upload.',
              );
              return false;
            }
          } catch (_) {
            if (delivery != null && attachment.localId.isNotEmpty) {
              await delivery.markAttachmentFailed(
                attachment.localId,
                attempt: attachment.attempt,
                errorKind: AttachmentErrorKind.transport,
              );
            } else {
              for (final path in attachedImagePaths) {
                try {
                  await attachmentGateway.detachImage(
                    attachmentRuntimeId,
                    path,
                  );
                } catch (_) {}
              }
            }
            rethrow;
          }
        }
        await delivery?.waitForAttachmentMutations();
        if (delivery != null) {
          final expectedIds = attachmentsForRuntime
              .map((item) => item.localId)
              .where((id) => id.isNotEmpty)
              .toSet();
          final completedIds = delivery.current.activeAttachments
              .where(
                (item) =>
                    expectedIds.contains(item.localId) &&
                    item.isAttachedTo(
                      attachmentRuntimeId,
                      transport: AttachmentRemoteTransport.desktop,
                    ),
              )
              .map((item) => item.localId)
              .toSet();
          if (completedIds.length != expectedIds.length) {
            _failRun('The attachment batch changed during upload.');
            return false;
          }
          final refs = delivery.current.activeAttachments
              .where(
                (item) =>
                    !item.isImage &&
                    item.isAttachedTo(
                      attachmentRuntimeId,
                      transport: AttachmentRemoteTransport.desktop,
                    ),
              )
              .map((item) => item.remoteRef!)
              .toList(growable: false);
          if (refs.isNotEmpty) {
            promptText = '$promptText\n\n${refs.join('\n')}'.trim();
          }
        } else {
          if (legacyFileRefs.isNotEmpty) {
            promptText = '$promptText\n\n${legacyFileRefs.join('\n')}'.trim();
          }
        }
      }
      final HermesDesktopRewindGateway? rewindGateway =
          gateway is HermesDesktopRewindGateway
          ? gateway as HermesDesktopRewindGateway
          : null;
      final HermesDesktopDurableRewindGateway? durableRewindGateway =
          gateway is HermesDesktopDurableRewindGateway
          ? gateway as HermesDesktopDurableRewindGateway
          : null;
      if (truncateBeforeUserOrdinal != null) {
        final rewindRuntimeId = runtimeId;
        Future<DesktopRewindAck> submitRewind(int ordinal) async {
          final rowId = truncateBeforeRowId;
          if (rowId != null) {
            if (durableRewindGateway == null) {
              throw const TuiGatewayRpcError(
                'prompt.submit',
                'Durable conversation rewind is unavailable',
                code: -32601,
              );
            }
            return durableRewindGateway.submitDurableRewindPrompt(
              rewindRuntimeId,
              promptText,
              ordinal,
              truncateBeforeRowId: rowId,
            );
          }
          if (rewindGateway == null) {
            throw const TuiGatewayRpcError(
              'prompt.submit',
              'Conversation rewind is unavailable',
              code: -32601,
            );
          }
          await rewindGateway.submitRewindPrompt(
            rewindRuntimeId,
            promptText,
            ordinal,
          );
          return const DesktopRewindAck();
        }

        if (!await _beginTurnTransport(
          turnEpoch,
          PreparedTurnTransport.desktop,
        )) {
          return false;
        }
        submissionAttempted = true;
        late DesktopRewindAck rewindAck;
        try {
          rewindAck = await submitRewind(truncateBeforeUserOrdinal);
        } on TuiGatewayRpcError catch (error) {
          final fallbackOrdinal = _rewind4018FallbackOrdinal;
          if (error.code != 4018 ||
              fallbackOrdinal == null ||
              fallbackOrdinal == truncateBeforeUserOrdinal) {
            rethrow;
          }
          debugPrint(
            '[active-chat] retrying rewind after Hermes model-switch '
            'ordinal repair ($truncateBeforeUserOrdinal -> $fallbackOrdinal)',
          );
          rewindAck = await submitRewind(fallbackOrdinal);
        }
        _rebindSurvivorUserRowIds(rewindAck.survivorUserRowIds);
        _rewindRollbackMessages = null;
        _rewindRollbackState = null;
        _rewind4018FallbackOrdinal = null;
      } else {
        if (!await _beginTurnTransport(
          turnEpoch,
          PreparedTurnTransport.desktop,
        )) {
          return false;
        }
        submissionAttempted = true;
        final delivery = _activeTurnDelivery;
        final idempotentGateway =
            !voicePlaybackInterrupted &&
                delivery != null &&
                await _canUseTurnIdempotency(gateway)
            ? gateway as HermesDesktopIdempotentGateway
            : null;
        if (voicePlaybackInterrupted &&
            gateway is HermesDesktopInterruptedPromptGateway) {
          await (gateway as HermesDesktopInterruptedPromptGateway)
              .submitInterruptedPrompt(runtimeId, promptText);
        } else if (idempotentGateway != null) {
          idempotentSubmission = true;
          final ack = await idempotentGateway.submitPromptIdempotent(
            runtimeId,
            promptText,
            delivery!.current.clientTurnId,
          );
          if (ack.state == DesktopTurnState.terminal) {
            await _completeRun();
          }
        } else {
          await gateway.submitPrompt(runtimeId, promptText);
        }
      }
      return true;
    } catch (error) {
      if (_turnEpoch != turnEpoch || _runTerminal) return false;
      if (truncateBeforeUserOrdinal != null) {
        if (error is TuiGatewayRpcError) {
          debugPrint(
            '[active-chat] rewind RPC failed '
            '(type=${error.runtimeType}, method=${error.method}, '
            'code=${error.code ?? 'none'})',
          );
        } else {
          debugPrint('[active-chat] rewind failed (type=${error.runtimeType})');
        }
      }
      if (truncateBeforeUserOrdinal != null && !submissionAttempted) {
        final rollback = _rewindRollbackMessages;
        final rollbackState = _rewindRollbackState;
        if (rollback != null) {
          _firstTokenTimer?.cancel();
          _firstTokenTimer = null;
          messages = rollback;
          _rewindRollbackMessages = null;
          _rewindRollbackState = null;
          _rewind4018FallbackOrdinal = null;
          _rewindRestoredOnError = true;
          _rewindDashboardAuthRequired = error is DashboardAuthException;
          _runTerminal = true;
          traceActive = false;
          pendingApproval = null;
          state = rollbackState ?? ChatPipelineState.completed;
          _emit(ActiveChatEvent.error);
          _onTerminal();
          return false;
        }
      }
      if (truncateBeforeUserOrdinal != null && submissionAttempted) {
        final rollback = _rewindRollbackMessages;
        final rollbackState = _rewindRollbackState;
        final deterministicRejection =
            (error is TuiGatewayRpcError && error.code != null) ||
            (error is DashboardAuthException &&
                _isTerminalDesktopRecoveryError(error));
        if (deterministicRejection && rollback != null) {
          _firstTokenTimer?.cancel();
          _firstTokenTimer = null;
          messages = rollback;
          _rewindRollbackMessages = null;
          _rewindRollbackState = null;
          _rewind4018FallbackOrdinal = null;
          _rewindRestoredOnError = true;
          _rewindDashboardAuthRequired = error is DashboardAuthException;
          _runTerminal = true;
          traceActive = false;
          pendingApproval = null;
          state = rollbackState ?? ChatPipelineState.completed;
          _emit(ActiveChatEvent.error);
          _onTerminal();
          return false;
        }
        // Sin un error JSON-RPC con código, el servidor pudo haber aplicado el
        // rewind antes de perderse el ACK. Restaurar el transcript antiguo sería
        // afirmar una línea temporal que quizá ya no existe en Desktop.
        _rewindRollbackMessages = null;
        _rewindRollbackState = null;
        _rewind4018FallbackOrdinal = null;
      }
      if (error is TuiGatewayRpcError) {
        debugPrint(
          '[active-chat] Desktop RPC failed '
          '(method=${error.method}, code=${error.code ?? 'none'})',
        );
      } else {
        debugPrint('[active-chat] Desktop turn failed (${error.runtimeType})');
      }
      final rejectedBeforeAcceptance =
          activeChatPromptWasRejectedBeforeAcceptance(error);
      if (idempotentSubmission && !rejectedBeforeAcceptance) {
        // Anunciada pero incompatible (method-not-found, eco/payload inválido o
        // timeout): se invalida durante esta generación. No hay fallback porque
        // el servidor pudo haber aceptado el turno.
        _turnIdempotencyInvalid = true;
      }
      if (rejectedBeforeAcceptance) {
        await _activeTurnDelivery?.markRejectedBeforeAcceptance();
      }
      _firstTokenTimer?.cancel();
      _firstTokenTimer = null;
      _expireInteractivePromptsForRuntime(_desktopRuntimeSessionId);
      _usingDesktopGateway = false;
      _retireDesktopRuntime();
      // Solo degradamos antes de entregar el prompt. Después podría estar
      // ejecutándose pese a un timeout de respuesta y repetirlo sería peor.
      if (!submissionAttempted && sessionConfig.allowTransportFallback) {
        return fallback();
      } else {
        _failRun(activeChatPromptFailureUiMessage(error));
        return false;
      }
    }
  }

  void _listenToDesktopGateway(HermesDesktopGateway gateway) {
    _desktopEventSubscription ??= gateway.events.listen(
      _onDesktopEvent,
      onError: (Object error, StackTrace stackTrace) {
        final interruptedActiveTurn =
            _usingDesktopGateway && isStreaming && !_runTerminal;
        // El runtime vive dentro del socket de Desktop. Tras un corte no se
        // puede reutilizar su id en el siguiente intento: fuerza un nuevo
        // session.resume sobre el socket reconectado y evita una cadena de
        // reintentos contra un runtime ya desaparecido.
        final disconnectedRuntimeId = _desktopRuntimeSessionId;
        _expireInteractivePromptsForRuntime(disconnectedRuntimeId);
        _usingDesktopGateway = false;
        _retireDesktopRuntime();
        if (interruptedActiveTurn) {
          _scheduleDesktopTurnRecovery(gateway, _turnEpoch, error);
        }
      },
    );
  }

  bool _isCurrentEpoch(int expectedEpoch) =>
      !_disposed && _turnEpoch == expectedEpoch;

  int _advanceTurnEpoch() {
    if (!_turnEpochInvalidated.isCompleted) {
      _turnEpochInvalidated.complete();
    }
    _turnEpochInvalidated = Completer<void>();
    return ++_turnEpoch;
  }

  bool _canRecoverTurn(int expectedEpoch) =>
      _isCurrentEpoch(expectedEpoch) && !_runTerminal;

  bool _isTerminalDesktopRecoveryError(Object error) {
    if (error is DashboardAuthException) {
      final status = error.statusCode;
      if ((error.code == DashboardAuthFailureCode.rateLimited &&
              status == 429) ||
          (error.code == DashboardAuthFailureCode.loginFailed &&
              status != null &&
              status >= 500 &&
              status < 600)) {
        return false;
      }
      return true;
    }
    if (error is DashboardHttpException) {
      final status = error.statusCode;
      return status >= 400 && status < 500 && status != 408 && status != 429;
    }
    if (error is! TuiGatewayRpcError) return false;
    final code = error.code;
    return code == null ||
        code == 4007 ||
        code == 4030 ||
        code == -32700 ||
        code == -32600 ||
        code == -32601 ||
        code == -32602;
  }

  bool _canRetryDesktopCancel(
    int expectedEpoch,
    HermesDesktopGateway gateway,
  ) =>
      _isCurrentEpoch(expectedEpoch) &&
      state == ChatPipelineState.cancelled &&
      identical(_desktopGateway, gateway);

  void _scheduleDesktopCancelRecovery({
    required HermesDesktopGateway gateway,
    required String? runtimeSessionId,
    required String storedSessionId,
    required String profile,
    required String model,
    required int cancelEpoch,
  }) {
    late final Future<void> task;
    task = _recoverDesktopCancel(
      gateway: gateway,
      runtimeSessionId: runtimeSessionId,
      storedSessionId: storedSessionId,
      profile: profile,
      model: model,
      cancelEpoch: cancelEpoch,
    );
    _desktopCancelRecovery = task;
    unawaited(
      task.whenComplete(() {
        if (identical(_desktopCancelRecovery, task)) {
          _desktopCancelRecovery = null;
        }
      }),
    );
  }

  Future<void> _recoverDesktopCancel({
    required HermesDesktopGateway gateway,
    required String? runtimeSessionId,
    required String storedSessionId,
    required String profile,
    required String model,
    required int cancelEpoch,
  }) async {
    final epochInvalidated = _turnEpochInvalidated.future;
    final delays = _desktopRecoveryBackoff;
    var attempt = runtimeSessionId == null ? 1 : 0;
    var targetRuntimeId = runtimeSessionId;
    while (_canRetryDesktopCancel(cancelEpoch, gateway)) {
      if (attempt > 0 &&
          gateway is! HermesDesktopSessionLifecycleGateway &&
          gateway is! HermesDesktopRecoverySessionLifecycleGateway) {
        // El contrato legacy resumeSession puede crear si el stored id falta.
        // Una cancelación nunca debe generar una sesión nueva.
        return;
      }
      final delay = delays[attempt.clamp(0, delays.length - 1)];
      if (attempt > 0 && delay > Duration.zero) {
        final elapsed = await _waitForTerminalReconcileDelay(
          delay,
          epochInvalidated,
        );
        if (!elapsed || !_canRetryDesktopCancel(cancelEpoch, gateway)) return;
      }
      Completer<void>? interruptDrain;
      var interruptAcknowledged = false;
      var runtimeRetired = false;
      try {
        if (attempt > 0) {
          final connected = await _desktopRecoveryOperationBeforeDeadline(
            gateway.connect().then((_) => true),
            epochInvalidated,
          );
          if (connected == null ||
              !_canRetryDesktopCancel(cancelEpoch, gateway)) {
            if (!_canRetryDesktopCancel(cancelEpoch, gateway)) return;
            attempt++;
            continue;
          }
          final binding = await _desktopRecoveryOperationBeforeDeadline(
            _resumeDesktopSessionForRecovery(
              gateway,
              storedSessionId,
              profile: profile,
              legacyModel: model,
              deferRuntimeCommit: true,
            ),
            epochInvalidated,
          );
          if (binding == null ||
              !_canRetryDesktopCancel(cancelEpoch, gateway)) {
            if (!_canRetryDesktopCancel(cancelEpoch, gateway)) return;
            attempt++;
            continue;
          }
          targetRuntimeId = binding.runtimeSessionId;
          _commitDesktopRecoveryRuntime(gateway, targetRuntimeId);
          _desktopStoredSessionId = binding.storedSessionId;
          _adoptDesktopRuntime(targetRuntimeId, info: binding.info);
          _usingDesktopGateway = true;
        }
        final interruptRuntimeId = targetRuntimeId;
        if (interruptRuntimeId == null) {
          attempt++;
          continue;
        }
        interruptDrain = Completer<void>();
        _desktopInterruptDrain = interruptDrain;
        _discardLateInterruptTerminal = true;
        final interrupted = await _desktopRecoveryOperationBeforeDeadline(
          gateway.interrupt(interruptRuntimeId).then((_) => true),
          epochInvalidated,
        );
        if (interrupted == null) {
          if (!_canRetryDesktopCancel(cancelEpoch, gateway)) return;
        } else {
          interruptAcknowledged = true;
          try {
            await _desktopRecoveryOperationBeforeDeadline(
              interruptDrain.future.then((_) => true),
              epochInvalidated,
            );
          } on TimeoutException {
            // El ACK evita reenviar interrupt, pero sin terminal no podemos
            // distinguir de forma segura un evento viejo del turno siguiente.
            // Retiramos el runtime: cualquier terminal tardío queda aislado por
            // session_id y el próximo prompt reanuda el stored id.
            if (_canRetryDesktopCancel(cancelEpoch, gateway)) {
              _usingDesktopGateway = false;
              _retireDesktopRuntime();
              _discardLateInterruptTerminal = false;
              runtimeRetired = true;
            }
          }
          return;
        }
      } catch (error) {
        if (!_canRetryDesktopCancel(cancelEpoch, gateway)) return;
        if (_isTerminalDesktopRecoveryError(error)) {
          _usingDesktopGateway = false;
          _retireDesktopRuntime();
          _discardLateInterruptTerminal = false;
          runtimeRetired = true;
          return;
        }
      } finally {
        if (identical(_desktopInterruptDrain, interruptDrain)) {
          _desktopInterruptDrain = null;
        }
        if (!runtimeRetired &&
            interruptAcknowledged &&
            interruptDrain?.isCompleted == false) {
          _discardLateInterruptTerminal = true;
        }
      }
      attempt++;
    }
  }

  void _scheduleDesktopTurnRecovery(
    HermesDesktopGateway gateway,
    int turnEpoch,
    Object originalError,
  ) {
    if (!_canRecoverTurn(turnEpoch) ||
        _recoveringDesktopTurnEpoch == turnEpoch) {
      return;
    }
    late final Future<void> recovery;
    recovery = _recoverDesktopTurn(gateway, turnEpoch, originalError)
        .whenComplete(() {
          if (identical(_desktopTurnRecovery, recovery)) {
            _desktopTurnRecovery = null;
          }
        });
    _desktopTurnRecovery = recovery;
    unawaited(recovery);
  }

  Future<void> _recoverDesktopTurn(
    HermesDesktopGateway gateway,
    int turnEpoch,
    Object originalError,
  ) async {
    if (!_canRecoverTurn(turnEpoch)) return;
    if (_recoveringDesktopTurnEpoch == turnEpoch) return;
    _recoveringDesktopTurnEpoch = turnEpoch;
    _firstTokenTimer?.cancel();
    _firstTokenTimer = null;
    state = ChatPipelineState.connecting;
    _emit(ActiveChatEvent.connected);
    try {
      final delivery = _activeTurnDelivery;
      final HermesDesktopIdempotentGateway? idempotentGateway =
          gateway is HermesDesktopIdempotentGateway
          ? gateway as HermesDesktopIdempotentGateway
          : null;
      if (delivery == null || idempotentGateway == null) {
        if (gateway is! HermesDesktopSessionLifecycleGateway &&
            gateway is! HermesDesktopRecoverySessionLifecycleGateway) {
          await _recoverTurnFromTranscript(turnEpoch, originalError);
          return;
        }
        await _recoverDesktopTurnFromSnapshot(
          gateway,
          turnEpoch,
          originalError,
        );
        return;
      }
      final canUseIdempotency = await _canUseTurnIdempotency(gateway);
      if (!_canRecoverTurn(turnEpoch)) return;
      if (!canUseIdempotency) {
        await _recoverTurnFromTranscript(turnEpoch, originalError);
        return;
      }

      // Paridad con Desktop: una pérdida de cobertura no es un fallo terminal.
      // Seguimos marcando el turno como vivo y reemplazamos el socket con
      // backoff acotado (30 s máximo entre intentos) hasta que vuelva la red,
      // el usuario cancele, llegue un terminal o se destruya el chat.
      final delays = _desktopRecoveryBackoff;
      final epochInvalidated = _turnEpochInvalidated.future;
      var attempt = 0;
      Object lastError = originalError;
      while (_canRecoverTurn(turnEpoch)) {
        final delay = delays[attempt.clamp(0, delays.length - 1)];
        attempt++;
        if (!_canRecoverTurn(turnEpoch)) return;
        if (delay > Duration.zero) {
          final elapsed = await _waitForTerminalReconcileDelay(
            delay,
            epochInvalidated,
          );
          if (!elapsed || !_canRecoverTurn(turnEpoch)) return;
        }
        if (!_canRecoverTurn(turnEpoch)) return;
        try {
          final connected = await _desktopRecoveryOperationBeforeDeadline(
            gateway.connect().then((_) => true),
            epochInvalidated,
          );
          if (connected == null || !_canRecoverTurn(turnEpoch)) return;
          final binding = await _desktopRecoveryOperationBeforeDeadline(
            _resumeDesktopSessionForRecovery(
              gateway,
              serverSessionId,
              profile: _turnProfile,
              legacyModel: _lastModel,
              deferRuntimeCommit: true,
            ),
            epochInvalidated,
          );
          if (binding == null || !_canRecoverTurn(turnEpoch)) return;
          final status = await _desktopRecoveryOperationBeforeDeadline(
            idempotentGateway.getTurnStatus(
              binding.runtimeSessionId,
              delivery.current.clientTurnId,
            ),
            epochInvalidated,
          );
          if (status == null || !_canRecoverTurn(turnEpoch)) return;
          if (!status.known || status.state == null) continue;
          switch (status.state!) {
            case DesktopTurnState.accepted:
              _commitDesktopRecoveryRuntime(gateway, binding.runtimeSessionId);
              _desktopStoredSessionId = binding.storedSessionId;
              _adoptDesktopRuntime(
                binding.runtimeSessionId,
                info: binding.info,
              );
              _usingDesktopGateway = true;
              state = ChatPipelineState.waiting;
              _armFirstTokenTimer();
              _emit(ActiveChatEvent.waiting);
              return;
            case DesktopTurnState.running:
              final markedRunning =
                  await _desktopRecoveryOperationBeforeDeadline(
                    delivery.markRunning().then((_) => true),
                    epochInvalidated,
                  );
              if (markedRunning == null || !_canRecoverTurn(turnEpoch)) return;
              _commitDesktopRecoveryRuntime(gateway, binding.runtimeSessionId);
              _desktopStoredSessionId = binding.storedSessionId;
              _adoptDesktopRuntime(
                binding.runtimeSessionId,
                info: binding.info,
              );
              _usingDesktopGateway = true;
              state = ChatPipelineState.executing;
              _armFirstTokenTimer();
              _emit(ActiveChatEvent.toolProgress);
              return;
            case DesktopTurnState.terminal:
              if (!_canRecoverTurn(turnEpoch)) return;
              await _completeRun();
              return;
            case DesktopTurnState.failed:
              if (!_canRecoverTurn(turnEpoch)) return;
              _failRun('Hermes confirmed the turn failed after reconnecting.');
              return;
            case DesktopTurnState.cancelled:
              if (!_canRecoverTurn(turnEpoch)) return;
              _cancelRunState();
              return;
          }
        } catch (error) {
          if (!_canRecoverTurn(turnEpoch)) return;
          lastError = error;
          if (_isTerminalDesktopRecoveryError(error)) break;
        }
      }
      if (_canRecoverTurn(turnEpoch)) {
        debugPrint(activeChatDesktopRecoveryDiagnostic(lastError));
        _failRun(activeChatDesktopRecoveryUiMessage(lastError));
      }
    } finally {
      if (_recoveringDesktopTurnEpoch == turnEpoch) {
        _recoveringDesktopTurnEpoch = null;
      }
    }
  }

  Future<void> _recoverDesktopTurnFromSnapshot(
    HermesDesktopGateway gateway,
    int turnEpoch,
    Object originalError,
  ) async {
    final epochInvalidated = _turnEpochInvalidated.future;
    final delays = _desktopRecoveryBackoff;
    var attempt = 0;
    Object lastError = originalError;
    while (_canRecoverTurn(turnEpoch)) {
      final delay = delays[attempt.clamp(0, delays.length - 1)];
      attempt++;
      if (delay > Duration.zero) {
        final elapsed = await _waitForTerminalReconcileDelay(
          delay,
          epochInvalidated,
        );
        if (!elapsed || !_canRecoverTurn(turnEpoch)) return;
      }
      try {
        final connected = await _desktopRecoveryOperationBeforeDeadline(
          gateway.connect().then((_) => true),
          epochInvalidated,
        );
        if (connected == null || !_canRecoverTurn(turnEpoch)) return;
        final snapshot = await _desktopRecoveryOperationBeforeDeadline(
          _resumeDesktopSessionForRecovery(
            gateway,
            _desktopStoredSessionId ?? serverSessionId,
            profile: _turnProfile,
            legacyModel: _lastModel,
            deferRuntimeCommit: true,
          ),
          epochInvalidated,
        );
        if (snapshot == null || !_canRecoverTurn(turnEpoch)) return;
        if (snapshot is DesktopSessionBinding) {
          await _recoverTurnFromTranscript(turnEpoch, originalError);
          return;
        }
        _commitDesktopRecoveryRuntime(gateway, snapshot.runtimeSessionId);
        _applyDesktopRecoverySnapshot(snapshot, turnEpoch);
        return;
      } catch (error) {
        if (!_canRecoverTurn(turnEpoch)) return;
        lastError = error;
        if (_isTerminalDesktopRecoveryError(error)) break;
      }
    }
    if (_canRecoverTurn(turnEpoch)) {
      debugPrint(activeChatDesktopRecoveryDiagnostic(lastError));
      _failRun(activeChatDesktopRecoveryUiMessage(lastError));
    }
  }

  void _applyDesktopRecoverySnapshot(
    DesktopSessionSnapshot snapshot,
    int turnEpoch,
  ) {
    if (!_canRecoverTurn(turnEpoch)) return;
    // Recovery is a newer authoritative publication than any refresh that was
    // already in flight when the socket dropped.
    _messageLoadEpoch += 1;
    // Recovery puede recibir el mismo ack diferido que la apertura normal.
    // Sin un REST fresco que demuestre cobertura completa, conserva el
    // fallback visible pero deja armado el refetch al llegar `complete`.
    _desktopHistoryHydrating = snapshot.hydrating;
    _desktopHistoryNeedsHydration = snapshot.hydrating;
    if (snapshot.hydrating) _desktopHydrationOutcome = null;
    const reconciler = DesktopSessionReconciler();
    final snapshotTranscriptComplete = _desktopSnapshotTranscriptIsComplete(
      snapshot,
    );
    final preferFallback =
        messages.isNotEmpty &&
        (!snapshotTranscriptComplete || snapshot.messages.isEmpty);
    final terminalSnapshot = !snapshot.running && snapshot.inflight == null;
    final persistedTail = snapshot.messagesProvided
        ? reconciler
              .project(_withoutLiveDesktopProjection(snapshot))
              .messagesNewestFirst
        : const <Map<String, dynamic>>[];
    final terminalTailCompletesCurrentTurn =
        terminalSnapshot &&
        _partialTerminalTailCompletesCurrentTurn(persistedTail);
    final terminalSnapshotNeedsProof =
        preferFallback &&
        terminalSnapshot &&
        (!snapshotTranscriptComplete || snapshot.messages.isEmpty);
    if (terminalSnapshotNeedsProof && !terminalTailCompletesCurrentTurn) {
      // A terminal status does not prove that a partial message window covers
      // this turn. Keep the visible prompt/partial intact and fall back to a
      // full transcript read; otherwise an assistant-only page could delete
      // the prompt or an old tool row could falsely seal the run.
      if (snapshot.messagesProvided) {
        _captureArtifactMessages(
          snapshot.messages,
          logicalSessionId: logicalSessionId,
        );
      }
      _recordDesktopSnapshotTranscript(snapshot, preserveVisibleFallback: true);
      _desktopStoredSessionId = snapshot.storedSessionId;
      _rebaseSubagentActivityScope(snapshot.runtimeSessionId);
      _adoptDesktopRuntime(snapshot.runtimeSessionId, info: snapshot.info);
      _reconcileSubagentsFromTranscript();
      _desktopStoredSessionKnownMissing = false;
      _desktopRuntimeInfo = snapshot.info;
      _rememberDesktopLiveStatus(snapshot.status, running: false);
      _desktopStartedAt = snapshot.startedAt;
      _desktopTurnStartedAt = null;
      _replaceDesktopAcceptedQueue(snapshot.queued?.user);
      _restorePendingClarify(snapshot);
      _usingDesktopGateway = true;
      state = ChatPipelineState.connecting;
      _emit(ActiveChatEvent.waiting);
      unawaited(
        _recoverTurnFromTranscript(
          turnEpoch,
          StateError('terminal recovery snapshot did not cover current turn'),
        ),
      );
      return;
    }
    var rawFallback = messages;
    _RefreshedTranscriptGraft? acceptedTerminalTail;
    if (preferFallback &&
        snapshot.messagesProvided &&
        snapshot.messages.isNotEmpty &&
        !snapshot.running &&
        snapshot.inflight == null) {
      // A terminal recovery snapshot may expose only the newest durable page.
      // It is still authoritative for that tail: merge it by stable IDs and
      // discard the superseded synthetic inflight rows before sealing the run.
      // Older visible coverage is retained only when the graft can prove its
      // position; content equality is never used as identity.
      final durableFallback = messages
          .where(
            (message) =>
                message['_desktopSnapshotKind'] != 'inflight' &&
                message['_pipeline'] != true &&
                message['_optimistic'] != true,
          )
          .toList(growable: false);
      final graft = _graftRefreshedTail(
        persistedTail,
        durableFallback,
        refreshedTranscriptComplete: false,
      );
      if (graft.acceptedRefreshed) {
        acceptedTerminalTail = graft;
        rawFallback = _preserveLocalAssistantErrors(graft.messages, messages);
      }
    }
    final fallback = preferFallback && snapshot.messagesProvided
        ? reconciler.overlayDurableDisplayMetadata(
            rawFallback,
            snapshot.messages,
          )
        : messages;
    final projectionSource = preferFallback
        ? _withoutPersistedMessages(snapshot)
        : snapshot;
    final projection = reconciler.project(
      projectionSource,
      fallbackNewestFirst: fallback,
    );
    if (snapshot.messagesProvided) {
      _captureArtifactMessages(
        snapshot.messages,
        logicalSessionId: logicalSessionId,
      );
      if (preferFallback &&
          (!snapshotTranscriptComplete || snapshot.messages.isEmpty)) {
        final terminalTail = acceptedTerminalTail;
        _recordDesktopSnapshotTranscript(
          snapshot,
          preserveVisibleFallback:
              terminalTail == null || terminalTail.preservesExistingCoverage,
        );
        if (terminalTail != null) {
          _commitRefreshedTailEvidence(persistedTail, terminalTail);
        }
      }
    } else {
      final announcedCount = snapshot.messageCount;
      final durableFallbackCount = _durableTranscriptCoverageCount(messages);
      final fallbackCoverageIsInsufficient =
          announcedCount == null ||
          durableFallbackCount == null ||
          announcedCount != durableFallbackCount;
      if (!preferFallback ||
          fallbackCoverageIsInsufficient ||
          _desktopHistoryNeedsHydration) {
        _recordDesktopSnapshotTranscript(
          snapshot,
          preserveVisibleFallback: preferFallback,
        );
      }
    }
    final incomingTranscriptComplete = preferFallback
        ? _transcriptIsComplete
        : snapshotTranscriptComplete;
    messages = _applyCancelledTurnTombstones(
      _associateGeneratedImagesNewestFirst(
        _sanitizeDesktopFailureProjection(
          projection.messagesNewestFirst.map(Map<String, dynamic>.from),
        ),
      ),
      incomingTranscriptComplete: incomingTranscriptComplete,
    );
    if (snapshot.messagesProvided && !preferFallback) {
      _recordDesktopSnapshotTranscript(snapshot);
    }
    _mergeSteerRecords();
    _desktopStoredSessionId = snapshot.storedSessionId;
    _rebaseSubagentActivityScope(snapshot.runtimeSessionId);
    _adoptDesktopRuntime(snapshot.runtimeSessionId, info: snapshot.info);
    _reconcileSubagentsFromTranscript();
    _desktopStoredSessionKnownMissing = false;
    _desktopRuntimeInfo = snapshot.info;
    _rememberDesktopLiveStatus(projection.status, running: projection.running);
    _desktopStartedAt = snapshot.startedAt;
    _desktopTurnStartedAt = projection.running
        ? snapshot.resolvedTurnStartedAt
        : null;
    _replaceDesktopAcceptedQueue(projection.queuedUser);
    _restorePendingClarify(snapshot);

    if (projection.failed) {
      _sealRecoveredLiveActivity(completed: false);
      final failure =
          snapshot.inflight?.error ??
          StateError('desktop recovery snapshot reported failure');
      debugPrint(activeChatDesktopRecoveryDiagnostic(failure));
      _failRun(
        activeChatDesktopSnapshotFailureUiMessage(snapshot.inflight?.error),
      );
      return;
    }
    if (projection.running) {
      _usingDesktopGateway = true;
      state = snapshot.inflight?.assistant?.isNotEmpty == true
          ? ChatPipelineState.streaming
          : ChatPipelineState.executing;
      _emit(ActiveChatEvent.toolProgress);
      return;
    }

    _usingDesktopGateway = true;
    _sealRecoveredLiveActivity(completed: true);
    final finalText = _latestTurnAssistantText(
      projection.messagesNewestFirst.reversed.toList(growable: false),
      projection.messagesNewestFirst.where(isRealUserTurn).length,
    );
    unawaited(_completeRun(finalOutput: finalText));
  }

  void _sealRecoveredLiveActivity({required bool completed}) {
    for (final event in trace) {
      if (!event.isDone && !event.isFailed) {
        event.status = completed ? 'completed' : 'interrupted';
      }
    }
    final current = _subagentActivities;
    if (current == null) return;
    final entries = <SubagentActivityKey, SubagentActivity>{};
    for (final entry in current.entries.entries) {
      final activity = entry.value;
      entries[entry.key] = activity.isTerminal
          ? activity
          : SubagentActivity(
              key: activity.key,
              source: activity.source,
              phase: completed
                  ? SubagentActivityPhase.completed
                  : SubagentActivityPhase.cancelled,
              details: activity.details,
              subagentId: activity.subagentId,
              delegationId: activity.delegationId,
              childSessionId: activity.childSessionId,
              legacyToolCallId: activity.legacyToolCallId,
              eventRevision: activity.eventRevision,
              seenEventIds: activity.seenEventIds,
            );
    }
    _subagentActivities = SubagentActivityState.withEntries(
      current.scope,
      entries,
    );
  }

  /// Recuperación cuando el gateway NO soporta idempotencia de turno (no se
  /// puede consultar el estado del turno tras un corte de transporte). La única
  /// vía válida es releer la conversación del servidor —igual que al reabrir el
  /// chat—: el gateway no conserva runs, pero el transcript sí guarda el turno.
  ///
  /// Reintenta con backoff para sobrevivir a una ventana de red caída y, si el
  /// servidor ya tiene el turno completo, lo muestra con [_completeRun]. Solo
  /// declara error si tras agotar el presupuesto sigue sin haber respuesta, y
  /// con un mensaje legible en vez de la excepción cruda del transporte.
  Future<void> _recoverTurnFromTranscript(
    int turnEpoch,
    Object originalError,
  ) async {
    final messageLoadEpoch = _messageLoadEpoch;
    final expectedUsers = messages.where(isRealUserTurn).length;
    final epochInvalidated = _turnEpochInvalidated.future;
    const delays = <Duration>[
      Duration.zero,
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 6),
      Duration(seconds: 8),
      Duration(seconds: 8),
    ];
    for (final delay in delays) {
      if (!_canRecoverTurn(turnEpoch) ||
          messageLoadEpoch != _messageLoadEpoch) {
        return;
      }
      if (delay > Duration.zero) {
        final elapsed = await _waitForTerminalReconcileDelay(
          delay,
          epochInvalidated,
        );
        if (!elapsed ||
            !_canRecoverTurn(turnEpoch) ||
            messageLoadEpoch != _messageLoadEpoch) {
          return;
        }
      }
      try {
        final transcript = await _loadStoredMessages(_storedSessionProfile);
        if (!_canRecoverTurn(turnEpoch) ||
            messageLoadEpoch != _messageLoadEpoch) {
          return;
        }
        if (_containsDurableFinalAssistantTurn(transcript, expectedUsers)) {
          await _completeRun();
          return;
        }
      } catch (error) {
        // Un 4xx (p.ej. 404 sesión inexistente por este id, 401 auth) no se
        // arregla reintentando la misma petición: salimos y fallamos rápido.
        // Los errores de red sí son transitorios (ventana offline): reintentar.
        if (RegExp(r'HTTP 4\d\d').hasMatch(error.toString())) break;
        debugPrint(
          '[active-chat] reconciliación por transcript aún no lista: '
          '${error.runtimeType}',
        );
      }
    }
    if (_canRecoverTurn(turnEpoch) && messageLoadEpoch == _messageLoadEpoch) {
      debugPrint(activeChatDesktopRecoveryDiagnostic(originalError));
      _failRun(activeChatDesktopRecoveryUiMessage(originalError));
    }
  }

  /// Texto del asistente del TURNO ACTUAL (tras el último mensaje de usuario
  /// esperado) en un transcript cronológico, o null si aún no hay texto. A
  /// diferencia de [_containsCompletedTurn], NO da por buena la presencia de
  /// tools: exige texto real del asistente, que es lo que falta en el bug S3.
  String? _latestTurnAssistantText(
    List<Map<String, dynamic>> chronological,
    int expectedUsers,
  ) {
    var userCount = 0;
    var latestUserIndex = -1;
    for (var i = 0; i < chronological.length; i++) {
      if (isRealUserTurn(chronological[i])) {
        userCount++;
        latestUserIndex = i;
      }
    }
    if (userCount < expectedUsers || latestUserIndex < 0) return null;
    // El turno puede contener assistant(tool_call) → tool → assistant(final).
    // La última respuesta no vacía representa la proyección visible final.
    for (var i = chronological.length - 1; i > latestUserIndex; i--) {
      if (chronological[i]['role'] == 'assistant') {
        final text = (chronological[i]['content'] as String? ?? '').trim();
        if (text.isNotEmpty) return text;
      }
    }
    return null;
  }

  bool _partialTerminalTailCompletesCurrentTurn(
    List<Map<String, dynamic>> tailNewestFirst,
  ) {
    TranscriptMessageIdentity? currentUserIdentity;
    for (final message in messages) {
      if (!isRealUserTurn(message)) continue;
      currentUserIdentity = _transcriptMessageIdentity(message);
      break;
    }
    if (currentUserIdentity == null || tailNewestFirst.isEmpty) return false;

    final chronological = tailNewestFirst.reversed.toList(growable: false);
    final user = _resolveTranscriptIdentity(
      chronological,
      messageId: currentUserIdentity.messageId,
      rowId: currentUserIdentity.rowId,
      accepts: isRealUserTurn,
    );
    final userIndex = user.kind == _TranscriptIdentityResolutionKind.unique
        ? user.index
        : -1;
    if (userIndex < 0) return false;
    for (var index = chronological.length - 1; index > userIndex; index--) {
      final message = chronological[index];
      if (message['role'] != 'assistant') continue;
      final text = (message['content'] as String? ?? '').trim();
      final toolCalls = message['tool_calls'];
      if (text.isNotEmpty && (toolCalls is! List || toolCalls.isEmpty)) {
        return true;
      }
    }
    return false;
  }

  bool _containsDurableFinalAssistantTurn(
    List<Map<String, dynamic>> chronological,
    int expectedUsers,
  ) {
    var userCount = 0;
    var latestUserIndex = -1;
    for (var index = 0; index < chronological.length; index++) {
      if (!isRealUserTurn(chronological[index])) continue;
      userCount++;
      latestUserIndex = index;
    }
    if (userCount < expectedUsers || latestUserIndex < 0) return false;
    for (
      var index = chronological.length - 1;
      index > latestUserIndex;
      index--
    ) {
      final message = chronological[index];
      if (message['role'] != 'assistant') continue;
      final content = (message['content'] as String? ?? '').trim();
      final toolCalls = message['tool_calls'];
      return content.isNotEmpty && (toolCalls is! List || toolCalls.isEmpty);
    }
    return false;
  }

  void _scheduleTerminalTranscriptRecovery(
    int completingEpoch, {
    required int messageLoadEpoch,
    required bool requireAssistantText,
  }) {
    if (_terminalTranscriptRecoveryEpoch == completingEpoch &&
        _terminalTranscriptRecovery != null) {
      return;
    }
    final previous = _terminalTranscriptRecovery;
    late final Future<void> recovery;
    recovery =
        () async {
          if (previous != null) await previous;
          if (!_isCurrentEpoch(completingEpoch)) return;
          await _recoverTerminalTranscriptLate(
            completingEpoch,
            messageLoadEpoch: messageLoadEpoch,
            requireAssistantText: requireAssistantText,
          );
        }().whenComplete(() {
          if (!identical(_terminalTranscriptRecovery, recovery)) return;
          _terminalTranscriptRecovery = null;
          _terminalTranscriptRecoveryEpoch = null;
        });
    _terminalTranscriptRecoveryEpoch = completingEpoch;
    _terminalTranscriptRecovery = recovery;
  }

  /// Red de seguridad común para dos carreras del terminal:
  ///  * no llegó texto local (bug S3);
  ///  * sí llegó por streaming, pero API Server aún devuelve 404 para la sesión.
  ///
  /// Relee con backoff acotado, no registra texto privado y solo sustituye la
  /// proyección local cuando el transcript contiene el turno completo.
  Future<void> _recoverTerminalTranscriptLate(
    int completingEpoch, {
    required int messageLoadEpoch,
    required bool requireAssistantText,
  }) async {
    final expectedUsers = messages.where(isRealUserTurn).length;
    debugPrint(
      '[active-chat] terminal transcript recovery started '
      '(users=$expectedUsers, needs_text=$requireAssistantText)',
    );
    final epochInvalidated = _turnEpochInvalidated.future;
    final delays = requireAssistantText
        ? const <Duration>[
            Duration(seconds: 1),
            Duration(seconds: 2),
            Duration(seconds: 3),
            Duration(seconds: 5),
            Duration(seconds: 8),
            Duration(seconds: 8),
          ]
        : const <Duration>[
            // La respuesta ya está segura en la proyección local. Solo damos al
            // commit normal del API un margen corto que no supera el timer
            // terminal de 800 ms ni mantiene un chat cerrado artificialmente.
            Duration(milliseconds: 100),
            Duration(milliseconds: 250),
            Duration(milliseconds: 400),
          ];
    for (final delay in delays) {
      if (!_isCurrentEpoch(completingEpoch) ||
          messageLoadEpoch != _messageLoadEpoch) {
        return;
      }
      if (requireAssistantText && assistantContent.trim().isNotEmpty) return;
      final elapsed = await _waitForTerminalReconcileDelay(
        delay,
        epochInvalidated,
      );
      if (!elapsed ||
          !_isCurrentEpoch(completingEpoch) ||
          messageLoadEpoch != _messageLoadEpoch) {
        return;
      }
      if (requireAssistantText && assistantContent.trim().isNotEmpty) return;
      try {
        final transcript = await _loadStoredMessages(_storedSessionProfile);
        if (!_isCurrentEpoch(completingEpoch) ||
            messageLoadEpoch != _messageLoadEpoch) {
          return;
        }
        final ready = requireAssistantText
            ? _latestTurnAssistantText(transcript, expectedUsers) != null
            : _terminalTranscriptCanReplaceVisibleProjection(
                transcript,
                expectedUsers,
              );
        if (ready) {
          _captureArtifactMaps(transcript, logicalSessionId: logicalSessionId);
          final fencedTranscript = _carryNewestTerminalFence(
            messages,
            _normalizedNewestFirst(transcript),
            candidateTranscriptComplete: true,
          );
          messages = projectCancelledTurnTombstones(
            existingNewestFirst: messages,
            incomingNewestFirst: fencedTranscript,
            durableTombstones: _cancelledTurnTombstones,
            incomingTranscriptComplete: true,
          );
          _markTranscriptComplete(visibleCount: messages.length);
          _mergeSteerRecords();
          _reconcileSubagentsFromTranscript();
          _emit(ActiveChatEvent.done);
          return;
        }
      } catch (error) {
        // 404 es precisamente la carrera observada: la sesión todavía no es
        // visible. 401/403 sí son permanentes para este intento.
        if (RegExp(r'HTTP (401|403)\b').hasMatch(error.toString())) return;
        debugPrint(
          '[active-chat] terminal transcript still pending '
          '(${error.runtimeType})',
        );
      }
    }
  }

  /// Background no demuestra que un canal Desktop esté ocioso: el estado
  /// local puede ir por detrás de un turno remoto ya aceptado. Conservamos el
  /// transporte y dejamos que dispose/process death ejecute el cierre real.
  Future<void> suspendIdleDesktopConnection() => Future<void>.value();

  Future<bool> _canUseTurnIdempotency(HermesDesktopGateway gateway) async {
    if (_turnIdempotencyInvalid || gateway is! HermesDesktopIdempotentGateway) {
      return false;
    }
    final cached = _turnIdempotencySupported;
    if (cached != null) return cached;
    try {
      final supported = await _turnIdempotencyCapability();
      _turnIdempotencySupported = supported;
      return supported;
    } catch (_) {
      _turnIdempotencySupported = false;
      return false;
    }
  }

  Future<bool> _startRestFallbackWithAttachments(
    String fullText,
    String model,
    List<Map<String, dynamic>> history,
    int turnEpoch,
    List<AttachmentDraft> attachments,
  ) async {
    var fallbackText = sanitizeRemoteChatText(fullText);
    final refs = <String>[];
    final delivery = _activeTurnDelivery;
    final binaryAttachments =
        (delivery?.current.activeAttachments ??
                attachments
                    .where(
                      (item) =>
                          item.uploadState != AttachmentUploadState.removed,
                    )
                    .toList(growable: false))
            .where((item) => !AttachmentUploader.isTextEmbeddable(item))
            .toList(growable: false);
    if (binaryAttachments.isNotEmpty) {
      if (!await _beginTurnTransport(turnEpoch, PreparedTurnTransport.rest)) {
        return false;
      }
      final attachmentOwner = connection.id;
      for (final initialAttachment in binaryAttachments) {
        var attachment = initialAttachment;
        if (delivery != null && attachment.localId.isNotEmpty) {
          final staged = await delivery.beginAttachmentUpload(
            attachment.localId,
            remoteSessionId: attachmentOwner,
            transport: AttachmentRemoteTransport.rest,
          );
          if (staged == null) {
            _failRun(
              delivery.persistenceFailed
                  ? 'Could not save the state of an attachment.'
                  : 'The attachment batch changed during upload.',
            );
            return false;
          }
          attachment = staged;
          if (attachment.isAttachedTo(
            attachmentOwner,
            transport: AttachmentRemoteTransport.rest,
          )) {
            continue;
          }
        }
        AttachmentUploadResult result;
        try {
          result = await _attachmentUploader(connection, attachment);
        } catch (_) {
          result = const AttachmentUploadResult.failure(
            AttachmentErrorKind.transport,
          );
        }
        if (_turnEpoch != turnEpoch || _runTerminal) return false;
        final managedPath = result.managedPath;
        if (!result.ok || managedPath == null || managedPath.isEmpty) {
          if (delivery != null && attachment.localId.isNotEmpty) {
            await delivery.markAttachmentFailed(
              attachment.localId,
              attempt: attachment.attempt,
              errorKind: result.errorKind ?? AttachmentErrorKind.transport,
            );
          }
          _failRun('Could not prepare an attachment for this instance.');
          return false;
        }
        if (delivery == null || attachment.localId.isEmpty) {
          refs.add('[Archivo adjunto disponible en $managedPath]');
          continue;
        }
        final persisted = await delivery.markAttachmentAttached(
          attachment.localId,
          attempt: attachment.attempt,
          remoteSessionId: attachmentOwner,
          transport: AttachmentRemoteTransport.rest,
          remoteRef: managedPath,
        );
        if (!persisted) {
          _failRun(
            delivery.persistenceFailed
                ? 'Could not save the state of an attachment.'
                : 'The attachment batch changed during upload.',
          );
          return false;
        }
      }
      await delivery?.waitForAttachmentMutations();
      if (delivery != null) {
        final expectedIds = binaryAttachments
            .map((item) => item.localId)
            .where((id) => id.isNotEmpty)
            .toSet();
        final completed = delivery.current.activeAttachments
            .where(
              (item) =>
                  expectedIds.contains(item.localId) &&
                  item.isAttachedTo(
                    attachmentOwner,
                    transport: AttachmentRemoteTransport.rest,
                  ),
            )
            .toList(growable: false);
        if (completed.length != expectedIds.length) {
          _failRun('The attachment batch changed during upload.');
          return false;
        }
        refs.addAll(
          completed.map(
            (item) => '[Archivo adjunto disponible en ${item.remoteRef}]',
          ),
        );
      }
    }
    if (refs.isNotEmpty) {
      final separator = fallbackText.contains('⟦adjunto⟧')
          ? '\n'
          : '\n⟦adjunto⟧\n';
      fallbackText = '$fallbackText$separator${refs.join('\n')}';
    }
    return _startRemoteRun(fallbackText, model, history, turnEpoch);
  }

  void _onDesktopEvent(TuiGatewayEvent event) {
    final runtimeId = _desktopRuntimeSessionId;
    if (runtimeId == null || event.sessionId != runtimeId) return;
    final payload = event.payload;
    final isTerminal =
        event.type == 'message.complete' || event.type == 'error';
    final interruptDrain = _desktopInterruptDrain;
    if (interruptDrain != null && isTerminal) {
      _clearDesktopCompactingIndicator();
      if (!interruptDrain.isCompleted) interruptDrain.complete();
      _discardLateInterruptTerminal = false;
      return;
    }

    if (isTerminal && !_runTerminal && _desktopAcceptedQueuedPrompt != null) {
      final terminalText =
          '${payload['text'] ?? payload['rendered'] ?? payload['message'] ?? ''}';
      _beginDesktopAcceptedQueuedTurn(
        finalOutput: terminalText.trim().isEmpty ? null : terminalText,
      );
      return;
    }

    if (_discardLateInterruptTerminal && isTerminal) {
      final terminalText =
          '${payload['text'] ?? payload['rendered'] ?? payload['message'] ?? ''}'
              .toLowerCase();
      _discardLateInterruptTerminal = false;
      if (terminalText.contains('interrupt') ||
          terminalText.contains('cancel')) {
        _clearDesktopCompactingIndicator();
        return;
      }
    }

    if (event.type == 'session.info') {
      _applyDesktopSessionInfo(payload);
      return;
    }
    // Resume diferido (Hermes Agent 0.20): progreso de la hidratación del
    // historial en segundo plano. Se atiende aunque no haya turno vivo.
    if (event.type == 'session.resume_progress') {
      _handleDesktopResumeProgress(payload);
      return;
    }
    if (event.type == 'status.update') {
      _applyDesktopStatusUpdate(payload);
      return;
    }
    if (_isInteractivePromptEvent(event.type)) {
      _handleInteractivePromptEvent(event.type, runtimeId, payload);
      return;
    }
    if (event.type.startsWith('subagent.')) {
      if (_usingDesktopGateway && !_runTerminal) {
        _handleNativeSubagentEvent(event.type, runtimeId, payload);
      }
      return;
    }
    if (!_usingDesktopGateway || _runTerminal) return;

    if (!_streamingConfirmed &&
        event.type != 'message.delta' &&
        event.type != 'message.interim' &&
        event.type != 'message.complete' &&
        event.type != 'error') {
      _armFirstTokenTimer();
    }

    switch (event.type) {
      case 'message.start':
        _clearDesktopCompactingIndicator();
        _desktopTurnStartedAt = DateTime.now();
        state = ChatPipelineState.waiting;
        _emit(ActiveChatEvent.waiting);
      case 'message.delta':
        if (!_streamingConfirmed) {
          _streamingConfirmed = true;
          _firstTokenTimer?.cancel();
          _firstTokenTimer = null;
          ConnectionManager.markStreamingSupported(connection.id);
        }
        _enqueueToken(
          (payload['text'] ?? '').toString(),
          narratable: _isNarrableDesktopAssistantPayload(event.type, payload),
        );
      case 'message.interim':
        _sealDesktopInterim(
          payload,
          narratable: _isNarrableDesktopAssistantPayload(event.type, payload),
        );
      case 'tool.start':
      case 'tool.progress':
      case 'tool.generating':
        _flushTokenBuffer();
        state = ChatPipelineState.executing;
        if (event.type == 'tool.start') {
          _handleLegacyDelegateEvent(event.type, runtimeId, payload);
        }
        _trackVoiceToolEvent(
          payload,
          running: true,
          startsNew: event.type == 'tool.start',
        );
        _upsertRunTool({
          'tool': payload['name'] ?? payload['tool'] ?? payload['tool_id'],
          'preview': payload['preview'] ?? payload['input'] ?? '',
        }, running: true);
        _emit(ActiveChatEvent.toolProgress);
      case 'tool.complete':
        _flushTokenBuffer();
        _captureDesktopGeneratedImage(payload);
        _handleLegacyDelegateEvent(event.type, runtimeId, payload);
        _trackVoiceToolEvent(payload, running: false, startsNew: false);
        _upsertRunTool({
          'tool': payload['name'] ?? payload['tool'] ?? payload['tool_id'],
          'preview': payload['preview'] ?? payload['input'] ?? '',
          'error': payload['error'] != null || payload['status'] == 'error',
        }, running: false);
        _emit(ActiveChatEvent.toolProgress);
      case 'approval.request':
        _flushTokenBuffer();
        _handleApprovalRequest(payload);
      case 'message.complete':
        _clearDesktopCompactingIndicator();
        final text = (payload['text'] ?? payload['rendered'] ?? '').toString();
        final narratable = _isNarrableDesktopAssistantPayload(
          event.type,
          payload,
        );
        if ((payload['status'] ?? '').toString().trim().toLowerCase() ==
            'error') {
          final structuredError = (payload['error'] ?? '').toString().trim();
          final fallbackText = text.trim();
          final error = structuredError.isNotEmpty
              ? structuredError
              : fallbackText.isNotEmpty
              ? fallbackText
              : 'Hermes reported an error';
          final billing = payload['billing'];
          _failRun(
            error,
            terminalText: text,
            terminalTextIsPartial: payload['partial'] == true,
            failureMetadata: {
              'error': error,
              'partial': payload['partial'] == true,
              if (payload['recoverable'] is bool)
                'recoverable': payload['recoverable'],
              'billing': ?billing,
              'failure_reason': ?payload['failure_reason'],
            },
          );
          break;
        }
        _settleDesktopInterim(
          text,
          responsePreviewed: payload['response_previewed'] == true,
        );
        _completeRun(
          finalOutput: text.isEmpty ? null : text,
          finalOutputNarratable: narratable,
        );
      case 'error':
        _clearDesktopCompactingIndicator();
        _failRun((payload['message'] ?? 'Hermes reported an error').toString());
    }
  }

  void _applyDesktopStatusUpdate(Map<String, dynamic> payload) {
    final kind = (payload['kind'] ?? payload['status'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (kind != 'compacting') return;

    final rawLineage =
        payload['_lineage_root_id'] ??
        payload['lineage_root_id'] ??
        payload['lineage_root'];
    final lineage = rawLineage is String ? rawLineage.trim() : '';
    // El runtime ya se comprobó arriba; una lineage nueva puede ser justo el
    // resultado de rotar un id provisional, así que se adopta en vez de
    // rechazarla por no coincidir todavía con la identidad local.
    _desktopCompactionLineageId = lineage.isEmpty ? logicalSessionId : lineage;
    _desktopAutoCompacting = true;
    _suppressTerminalHydrationAfterCompaction = true;
    // Cualquier snapshot iniciado antes del evento ya es potencialmente
    // obsoleto y no puede reemplazar la proyección viva.
    _messageLoadEpoch += 1;
    _emit(ActiveChatEvent.sessionInfo);
  }

  void _clearDesktopCompactingIndicator() {
    if (!_desktopAutoCompacting) return;
    _desktopAutoCompacting = false;
    _emit(ActiveChatEvent.sessionInfo);
  }

  bool _isInteractivePromptEvent(String type) =>
      type == 'clarify.request' ||
      type == 'sudo.request' ||
      type == 'secret.request' ||
      type == 'terminal.read.request';

  void _applyDesktopSessionInfo(Map<String, dynamic> payload) {
    final rawInfo = payload['info'];
    final parsed = DesktopSessionRuntimeInfo.fromJson(
      rawInfo is Map ? rawInfo : payload,
    );
    // `status.update(compacting)` es transitorio. Algunos Gateway publican el
    // terminal únicamente como `session.info(running=false)`, sin repetir
    // message.complete/error para el tip anterior. No dejar ese flag pegado:
    // bloquearía cada turno posterior con 4009 aunque el servidor ya esté idle.
    final autoCompactionCleared =
        _desktopAutoCompacting && parsed.running == false;
    if (autoCompactionCleared) _desktopAutoCompacting = false;
    final storedId = parsed.storedSessionId?.trim();
    if (storedId != null &&
        storedId.isNotEmpty &&
        storedId != _desktopStoredSessionId) {
      _desktopStoredSessionId = storedId;
      final runtimeId = _desktopRuntimeSessionId;
      if (runtimeId != null) _adoptDesktopRuntime(runtimeId);
    }
    final configChanged = _observeSessionConfigInfo(parsed);
    final infoChanged = parsed != _desktopRuntimeInfo;
    final titleChanged = _adoptDesktopSessionTitle(parsed);
    var turnTimingChanged = false;
    if (parsed.running == true &&
        isStreaming &&
        _desktopTurnStartedAt == null) {
      _desktopTurnStartedAt = DateTime.now();
      turnTimingChanged = true;
    }
    if (!configChanged &&
        !infoChanged &&
        !titleChanged &&
        !turnTimingChanged &&
        !autoCompactionCleared) {
      return;
    }
    if (infoChanged) _desktopRuntimeInfo = parsed;
    _emit(ActiveChatEvent.sessionInfo);
  }

  void _handleInteractivePromptEvent(
    String type,
    String runtimeId,
    Map<String, dynamic> payload,
  ) {
    if (_retiringDesktopRuntimeSessionId == runtimeId) return;
    late final InteractivePromptRequest request;
    try {
      request = InteractivePromptRequest.fromGatewayEvent(
        type: type,
        runtimeSessionId: runtimeId,
        payload: payload,
      );
    } on FormatException {
      return;
    }
    final changed = _reduceInteractivePrompt(
      InteractivePromptReceived(request),
    );
    if (!changed) return;
    _firstTokenTimer?.cancel();
    _firstTokenTimer = null;
    if (!_runTerminal) state = ChatPipelineState.executing;
    if (request is TerminalReadPromptRequest) {
      unawaited(respondToTerminalRead(request.key));
    }
  }

  bool _reduceInteractivePrompt(InteractivePromptEvent event) {
    final next = InteractivePromptReducer.reduce(_interactivePrompts, event);
    if (identical(next, _interactivePrompts)) return false;
    _interactivePrompts = next;
    _emit(ActiveChatEvent.interactiveRequest);
    return true;
  }

  void _restorePendingClarify(DesktopSessionSnapshot snapshot) {
    _reconcilePendingClarifySnapshot(snapshot, unlockResponding: false);
  }

  void _reconcilePendingClarifySnapshot(
    DesktopSessionSnapshot snapshot, {
    required bool unlockResponding,
  }) {
    if (!snapshot.pendingClarifyProvided) return;
    final pending = snapshot.pendingClarify;
    if (pending == null || pending.isEmpty) {
      _reduceInteractivePrompt(
        InteractivePromptClarifySnapshotCleared(snapshot.runtimeSessionId),
      );
      return;
    }
    try {
      final request = InteractivePromptRequest.fromGatewayEvent(
        type: 'clarify.request',
        runtimeSessionId: snapshot.runtimeSessionId,
        payload: pending,
      );
      if (request is ClarifyPromptRequest) {
        _reduceInteractivePrompt(
          InteractivePromptSnapshotReconciled(
            request,
            unlockResponding: unlockResponding,
          ),
        );
      }
    } on FormatException {
      // The field was present, so the snapshot is authoritative even though
      // its payload is malformed. Fail closed only for clarifies in this
      // runtime; unrelated prompt kinds and runtimes remain untouched.
      _reduceInteractivePrompt(
        InteractivePromptClarifySnapshotCleared(snapshot.runtimeSessionId),
      );
    }
  }

  void _expireInteractivePromptsForRuntime(String? runtimeId) {
    if (runtimeId == null) return;
    _reduceInteractivePrompt(InteractivePromptRuntimeExpired(runtimeId));
  }

  SubagentActivityScope _subagentScope(String runtimeId) =>
      SubagentActivityScope(
        connectionId: connection.id,
        profile: _storedSessionProfile,
        parentSessionId: serverSessionId,
        runtimeSessionId: runtimeId,
        turnEpoch: _turnEpoch,
      );

  void _reconcileSubagentsFromTranscript() {
    final runtimeId = _desktopRuntimeSessionId;
    if (runtimeId == null || runtimeId.trim().isEmpty || messages.isEmpty) {
      return;
    }
    final before = _subagentActivities;
    final projection = projectSubagentsFromTranscript(
      messagesNewestFirst: messages,
      scope: _subagentScope(runtimeId),
      current: before,
      currentTurnAnchor: _subagentTranscriptTurnAnchor,
    );
    final anchor = projection.turnAnchor;
    if (anchor == null) return;
    _subagentTranscriptTurnAnchor = anchor;
    _subagentActivities = projection.state;
    if (!identical(before, projection.state)) {
      _emit(ActiveChatEvent.subagentActivity);
    }
  }

  void _rebaseSubagentActivityScope(String runtimeId) {
    final current = _subagentActivities;
    if (current == null) return;
    final recoveredScope = _subagentScope(runtimeId);
    if (current.scope == recoveredScope) return;
    if (current.scope.durableLineageKey != recoveredScope.durableLineageKey) {
      return;
    }
    _subagentActivities = current.rebaseScope(recoveredScope);
    _pendingSubagentInterrupts.clear();
  }

  void _handleNativeSubagentEvent(
    String type,
    String runtimeId,
    Map<String, dynamic> payload,
  ) {
    final scope = _subagentScope(runtimeId);
    final event = SubagentActivityEvent.tryParseNative(
      type: type,
      scope: scope,
      payload: payload,
    );
    if (event != null) _reduceSubagentActivity(event);
  }

  void _handleLegacyDelegateEvent(
    String type,
    String runtimeId,
    Map<String, dynamic> payload,
  ) {
    final toolName = (payload['name'] ?? payload['tool'])?.toString();
    final toolCallId =
        (payload['tool_id'] ??
                payload['tool_call_id'] ??
                payload['call_id'] ??
                payload['id'])
            ?.toString();
    final event = SubagentActivityEvent.tryParseLegacyDelegateTool(
      type: type,
      scope: _subagentScope(runtimeId),
      payload: payload,
      toolName: toolName,
      toolCallId: toolCallId,
    );
    if (event != null) _reduceSubagentActivity(event);
  }

  /// Captura lateral del resultado estructurado de `image_generate`. No emite
  /// eventos propios ni altera contenido/streaming: `tool.complete` publicará
  /// el `toolProgress` habitual después de adjuntar esta metadata compacta al
  /// segmento del asistente que ya posee el turno vivo.
  void _captureDesktopGeneratedImage(Map<String, dynamic> payload) {
    if (!_isImageGenerateName(_toolName(payload))) return;
    final callId = _toolCallId(payload);
    if (callId == null) return;
    final rawResult =
        payload['result'] ?? payload['output'] ?? payload['content'];
    final references = GeneratedImageService.imageReferencesFromResult(
      rawResult,
    );
    if (references.isEmpty) return;
    final assistantIndex = messages.indexWhere(
      (message) => message['role'] == 'assistant',
    );
    if (assistantIndex < 0) return;
    final assistant = messages[assistantIndex];
    final incoming = references
        .map((reference) => _generatedImageMetadata(reference, callId))
        .toList(growable: false);
    final merged = _mergeGeneratedImageMetadata(
      _generatedImageMetadataOf(assistant),
      incoming,
    );
    messages[assistantIndex] = Map<String, dynamic>.unmodifiable({
      ...assistant,
      _generatedImagesMetadataKey: merged,
    });
  }

  void _reduceSubagentActivity(SubagentActivityEvent event) {
    final current = _subagentActivities;
    if (current != null && current.scope != event.scope) return;
    final scoped = current ?? SubagentActivityState.empty(event.scope);
    final next = SubagentActivityReducer.reduce(scoped, event);
    if (identical(next, scoped)) return;
    _subagentActivities = next;
    if (!_streamingConfirmed) _armFirstTokenTimer();
    state = ChatPipelineState.executing;
    _emit(ActiveChatEvent.subagentActivity);
  }

  static bool _isNarrableDesktopAssistantPayload(
    String eventType,
    Map<String, dynamic> payload,
  ) {
    if (!const {
      'message.delta',
      'message.interim',
      'message.complete',
    }.contains(eventType)) {
      return false;
    }
    for (final key in const ['hidden', 'is_hidden', 'is_reasoning']) {
      if (payload.containsKey(key)) return false;
    }
    if (eventType != 'message.complete' && payload.containsKey('reasoning')) {
      return false;
    }
    // `message.complete` puede transportar `reasoning` como sidecar canónico.
    // El texto público sigue siendo `text`; nunca concatenamos ese sidecar.
    if (eventType == 'message.complete' && payload['reasoning'] == true) {
      return false;
    }
    // El contrato Desktop publica assistant por TIPO (`message.delta`,
    // `message.interim`, `message.complete`); thinking/reasoning/tool usan
    // eventos distintos y el payload público no necesita classifier. Para
    // compatibilidad aceptamos su ausencia, pero cualquier classifier explícito
    // desconocido falla cerrado en Voz en vez de adivinar que es narrable.
    for (final key in const ['channel', 'kind', 'content_type']) {
      if (payload.containsKey(key)) return false;
    }
    return true;
  }

  void _sealDesktopInterim(
    Map<String, dynamic> payload, {
    required bool narratable,
  }) {
    final rawText = payload['text'];
    if (rawText is! String || rawText.trim().isEmpty) return;
    if (narratable) _assistantNarration.sealInterim(rawText);
    _observeFirstResponseContent(rawText);
    if (!_streamingConfirmed) _armFirstTokenTimer();
    _flushTokenBuffer();
    final key = 'assistant-interim-$_turnEpoch-${++_desktopInterimSerial}';
    if (messages.isNotEmpty && messages.first['role'] == 'assistant') {
      messages[0] = {
        ...messages[0],
        'content': rawText,
        '_pipeline': false,
        '_desktopInterim': true,
        '_desktopInterimPublic': narratable,
        '_desktopInterimKey': key,
      };
    } else {
      messages.insert(0, {
        'role': 'assistant',
        'content': rawText,
        '_pipeline': false,
        '_desktopInterim': true,
        '_desktopInterimPublic': narratable,
        '_desktopInterimKey': key,
      });
    }
    // Subsequent deltas belong to a new assistant segment while the same turn
    // keeps running. The event remains visual for chat, while Voz observes the
    // separate monotonic narration projection populated above.
    messages.insert(0, {
      'role': 'assistant',
      'content': '',
      '_pipeline': true,
      '_desktopPostInterimKey': key,
    });
    _pendingDesktopInterimKey = key;
    state = ChatPipelineState.executing;
    _emit(ActiveChatEvent.toolProgress);
  }

  bool _settleDesktopInterim(
    String finalText, {
    required bool responsePreviewed,
  }) {
    final key = _pendingDesktopInterimKey;
    _pendingDesktopInterimKey = null;
    if (key == null || finalText.trim().isEmpty) {
      return false;
    }
    final interimIndex = messages.indexWhere(
      (message) => message['_desktopInterimKey'] == key,
    );
    if (interimIndex < 0) return false;
    final interimText = (messages[interimIndex]['content'] as String? ?? '')
        .trim();
    if (interimText.isEmpty) return false;
    final trimmedFinal = finalText.trim();
    // Continuidad, no igualdad exacta (paridad con Desktop, fix #63679): el
    // streaming puede perder caracteres y el terminal añadir un delta final,
    // así que un prefijo en cualquier dirección cuenta como el MISMO mensaje.
    // `responsePreviewed` sigue cubriendo el caso verify-on-stop aunque el
    // final reescrito ya no comparta prefijo con el preview.
    final finalContinuesInterim =
        trimmedFinal == interimText ||
        trimmedFinal.startsWith(interimText) ||
        interimText.startsWith(trimmedFinal);
    if (!responsePreviewed && !finalContinuesInterim) return false;
    messages.removeWhere((message) => message['_desktopPostInterimKey'] == key);
    final settledIndex = messages.indexWhere(
      (message) => message['_desktopInterimKey'] == key,
    );
    if (settledIndex < 0) return false;
    if (trimmedFinal.startsWith(interimText)) {
      // Conserva el prefijo que ya estaba visible: _completeRun encola el
      // sufijo autoritativo y lo revela con la misma cadencia que los deltas.
      messages[settledIndex] = {
        ...messages[settledIndex],
        '_pipeline': false,
        '_responsePreviewed': true,
      };
    } else {
      // Final reescrito o más corto que el preview: el texto autoritativo
      // sustituye al interim entero. Conservar el prefijo aquí dejaría en el
      // transcript caracteres que el servidor nunca produjo.
      messages[settledIndex] = {
        ...messages[settledIndex],
        'content': finalText,
        '_pipeline': false,
        '_responsePreviewed': true,
      };
    }
    return true;
  }

  /// Lanza el turno remoto vía `/v1/runs` (motor de runs con aprobaciones
  /// once/session/always/deny). Extraído sin cambios de comportamiento para poder
  /// reutilizarlo con el `history` original o con el SOUL del perfil inyectado.
  Future<bool> _startRemoteRun(
    String fullText,
    String model,
    List<Map<String, dynamic>> history,
    int turnEpoch,
  ) async {
    try {
      if (!await _beginTurnTransport(turnEpoch, PreparedTurnTransport.rest)) {
        return false;
      }
      final runId = await _api.startRun(
        input: sanitizeRemoteChatText(fullText),
        sessionId: serverSessionId,
        model: explicitRunModel(model),
        history: history
            .map(
              (message) => <String, dynamic>{
                ...message,
                if (message['content'] is String)
                  'content': sanitizeRemoteChatText(
                    message['content'] as String,
                  ),
              },
            )
            .toList(),
      );
      if (_turnEpoch != turnEpoch) {
        // El POST pudo crear el run justo después de que el usuario pulsase Stop.
        // Su id identifica de forma inequívoca el turno viejo: detenlo y nunca lo
        // adoptes como currentRunId del epoch siguiente.
        try {
          await _api.stopRun(runId);
        } catch (_) {}
        return false;
      }
      currentRunId = runId;
      state = ChatPipelineState.waiting;
      // Arranca el foreground service / vigilancia en 2º plano para este run
      // (la app está en primer plano aquí, así que iniciarlo está permitido).
      _onRunStarted?.call(runId);
      _emit(ActiveChatEvent.connected);
      // Watchdog de actividad: si en 90s NO llega ninguna señal de vida del run
      // (ni texto ni herramientas) se da por fallido. Lo rearma cualquier evento
      // (ver _onRunEvent): así un run agéntico que tira herramientas largo rato
      // (sin texto aún) NO se marca como "Model not responding" en falso.
      _armFirstTokenTimer();
      _api.streamRunEvents(
        runId,
        onEvent: (event) {
          if (_turnEpoch == turnEpoch) _onRunEvent(event);
        },
        onDone: () {
          if (_turnEpoch == turnEpoch) _onRunStreamDone();
        },
        onError: (e) {
          // Paridad con la ruta Desktop: ante un corte de transporte,
          // reconciliar el transcript (releer la conversación) antes de
          // declarar error; si el servidor ya produjo la respuesta, se muestra.
          if (_turnEpoch == turnEpoch) {
            unawaited(_recoverTurnFromTranscript(turnEpoch, e));
          }
        },
        idleTimeout: _idleTimeout,
      );
      return true;
    } catch (e) {
      if (_turnEpoch != turnEpoch) return false;
      _firstTokenTimer?.cancel();
      _firstTokenTimer = null;
      _failRun(e.toString());
      return false;
    }
  }

  /// ¿El último turno con perfil NO pudo aislarse de verdad? (remoto sin bridge
  /// con soporte). La UI lo usa para avisar honestamente ("actualiza el bridge
  /// para aislar este perfil") sin fingir aislamiento.
  bool profileNotIsolated = false;

  /// Routing del chat cuando hay un perfil activo (no-default y válido).
  ///
  /// El aislamiento REAL (SOUL+skills+memoria+modelo del perfil) SOLO es posible
  /// ejecutando el turno en el home del perfil vía el Mobile Bridge
  /// (`hermes --profile`). El gateway HTTP no puede: siempre antepone el SOUL del
  /// home default. Por eso:
  /// - LOCAL (Termux): bridge nativo con `profile` → aislamiento completo.
  /// - REMOTO con bridge ≥ versión con soporte: se enruta por el bridge (modo
  ///   agente). Si no hay bridge capaz → degrada al gateway (SIN aislar) y marca
  ///   [profileNotIsolated] para que la UI avise. NUNCA rompe ni finge.
  Future<bool> _dispatchWithProfile(
    String fullText,
    String model,
    List<Map<String, dynamic>> history,
    String profile,
    int turnEpoch, {
    List<AttachmentDraft> nativeAttachments = const [],
  }) async {
    profileNotIsolated = false;
    if (connection.kind == InstanceKind.localhost) {
      await _sendViaBridge(
        fullText,
        history,
        profile: profile,
        turnEpoch: turnEpoch,
        nativeAttachments: nativeAttachments,
      );
      return _turnEpoch == turnEpoch && state != ChatPipelineState.failed;
    }
    final ready = await _remoteBridgeProfileReady();
    // Guarda de ciclo de vida: el turno pudo cancelarse durante el await.
    if (_turnEpoch != turnEpoch ||
        _runTerminal ||
        state == ChatPipelineState.cancelled) {
      return false;
    }
    if (ready) {
      // Aislamiento real vía bridge remoto (modo agente, no el chat-simple local).
      await _sendViaBridge(
        fullText,
        history,
        profile: profile,
        forceAgent: true,
        turnEpoch: turnEpoch,
        nativeAttachments: nativeAttachments,
      );
      return _turnEpoch == turnEpoch && state != ChatPipelineState.failed;
    } else {
      // Sin bridge capaz no se puede aislar en remoto. Degradamos al gateway
      // (comportamiento actual, sin aislar) y avisamos — no inyectamos un SOUL
      // débil que el gateway ignora.
      profileNotIsolated = true;
      return _startRemoteAgentTurn(
        fullText,
        model,
        history,
        turnEpoch,
        sessionConfig: _turnSessionConfig,
        profile: profile,
        nativeAttachments: nativeAttachments,
      );
    }
  }

  /// ¿La instancia remota tiene un bridge alcanzable con soporte de perfil
  /// (`hermes --profile`, v1.10.0+)? Cacheado por instancia. Usa `/bridge/health`
  /// (sin auth). Cualquier fallo → false (degrada al gateway).
  static const String _bridgeProfileMinVersion = '1.10.0';
  static final Map<String, bool> _bridgeProfileCache = {};
  Future<bool> _remoteBridgeProfileReady() async {
    final key = connection.id;
    final cached = _bridgeProfileCache[key];
    if (cached != null) return cached;
    final base = connection.derivedBridgeUrl;
    if (base.isEmpty) return _bridgeProfileCache[key] = false;
    try {
      final ver = await BridgeClient.probeVersion(base);
      final ok =
          ver != null &&
          ver.isNotEmpty &&
          BridgeVersion.compare(ver, _bridgeProfileMinVersion) >= 0;
      return _bridgeProfileCache[key] = ok;
    } catch (e) {
      debugPrint(
        '[active-chat] excepción silenciada (fallback: return _bridgeProfileCache[key] = false): $e',
      );
      return _bridgeProfileCache[key] = false;
    }
  }

  /// Invalida la caché de capacidad de perfil del bridge (p.ej. tras actualizarlo).
  static void invalidateBridgeProfileCache([String? connId]) {
    if (connId == null) {
      _bridgeProfileCache.clear();
    } else {
      _bridgeProfileCache.remove(connId);
    }
  }

  /// (Sin uso activo) Antepone el SOUL como system al [history]. Conservado solo
  /// como utilidad pura testeable; la degradación remota ya NO lo usa porque el
  /// gateway antepone su propio SOUL y este se ignora (ver spec 012, FR-016).
  @visibleForTesting
  static List<Map<String, dynamic>> historyWithSoul(
    String? soul,
    List<Map<String, dynamic>> history,
  ) {
    if (soul == null || soul.trim().isEmpty) return history;
    return <Map<String, dynamic>>[
      {'role': 'system', 'content': soul},
      ...history,
    ];
  }

  /// LEGACY (TASK-014): SIN USO. El modo voz ya no envía ningún comando
  /// `/reasoning` automático (era frágil y podía ensuciar la sesión remota si el
  /// servidor no lo interpretaba). Se conserva el método por si una integración
  /// futura lo necesita de forma explícita; candidato a eliminar en una TASK
  /// posterior. No lo llames desde el flujo de voz.
  ///
  /// Aplica el esfuerzo de razonamiento a ESTA sesión vía el comando
  /// `/reasoning <nivel>` del gateway. No inserta mensajes ni emite eventos. Solo
  /// aplica a instancias remotas (`/v1/runs`). Best-effort: si falla, se ignora.
  void applyReasoningEffort(String level, {required String model}) {
    if (connection.kind == InstanceKind.localhost) return;
    if (level.trim().isEmpty) return;
    try {
      _api
          .startRun(
            input: '/reasoning $level',
            sessionId: sessionId,
            model: explicitRunModel(model),
            history: const [],
          )
          .then(
            (runId) => _api.streamRunEvents(
              runId,
              onEvent: (_) {},
              onDone: () {},
              onError: (_) {},
            ),
          )
          .catchError((_) {});
    } catch (_) {
      // best-effort: el override de razonamiento es una optimización, no crítico.
    }
  }

  /// Camino de chat para instancias LOCALES (Termux): ejecuta un turno del
  /// agente a través del Mobile Bridge (`/bridge/chat` → `hermes -z`). Llega la
  /// respuesta final completa (sin streaming token a token; el oneshot no
  /// mantiene estado de sesión en el agente — cada turno es independiente).
  Future<void> _sendViaBridge(
    String prompt,
    List<Map<String, dynamic>> history, {
    String profile = '',
    bool forceAgent = false,
    required int turnEpoch,
    List<AttachmentDraft> nativeAttachments = const [],
  }) async {
    state = ChatPipelineState.waiting;
    _emit(ActiveChatEvent.connected);
    // Persiste ya el mensaje del usuario: si el turno se interrumpe (el SO mata
    // el proceso durante la llamada larga), al reabrir el chat seguirá la
    // pregunta en pantalla en vez de un historial vacío.
    await _persistLocalTranscript();
    if (_turnEpoch != turnEpoch) return;
    try {
      final base = connection.derivedBridgeUrl;
      // Reintentos con backoff: el agente local puede estar despertando de una
      // congelación (Doze/App Standby) o recién arrancado; un único intento
      // fallaría aunque vuelva a responder en 1-2 s. 3 intentos ~6 s de margen.
      String? token;
      for (var attempt = 0; attempt < 3; attempt++) {
        token = await _bridgeProvisioner(base, connection.apiKey.trim());
        if (token != null && token.isNotEmpty) break;
        if (_turnEpoch != turnEpoch || _runTerminal) return;
        if (attempt < 2) {
          await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
        }
      }
      if (token == null || token.isEmpty) {
        if (_turnEpoch != turnEpoch) return;
        _failRun(
          'Could not connect to the local agent (Mobile Bridge). '
          'Start the agent and retry.',
        );
        return;
      }
      final client = _bridgeClientFactory(baseUrl: base, token: token);
      if (_turnEpoch != turnEpoch) {
        client.close();
        return;
      }
      state = ChatPipelineState.executing;
      _emit(ActiveChatEvent.waiting);
      // Mantén vivo el proceso durante la llamada larga a `hermes -z` aunque la
      // app pase a 2º plano (isStreaming=true evita que se baje hasta terminar).
      await _onForegroundKeepAlive?.call();
      // El isolate del servicio sondea /v1/runs, que el bridge no expone, así
      // que no reflejaría este turno. Actualizamos la notificación persistente
      // a mano para que en 2º plano se vea que el agente local está procesando.
      await BackgroundListener.updateText(
        title: sessionTitle.isNotEmpty ? sessionTitle : 'Hermes Console',
        text: 'The local agent is processing your message…',
      );

      var effectivePrompt = prompt;
      final attachmentPaths = <String>[];
      final delivery = _activeTurnDelivery;
      final binaryAttachments =
          (delivery?.current.activeAttachments ??
                  nativeAttachments
                      .where(
                        (item) =>
                            item.uploadState != AttachmentUploadState.removed,
                      )
                      .toList(growable: false))
              .where((item) => !AttachmentUploader.isTextEmbeddable(item))
              .toList(growable: false);
      if (!await _beginTurnTransport(
        turnEpoch,
        PreparedTurnTransport.bridgeLocal,
      )) {
        client.close();
        return;
      }
      final attachmentOwner = connection.id;
      try {
        for (final initialAttachment in binaryAttachments) {
          var attachment = initialAttachment;
          if (delivery != null && attachment.localId.isNotEmpty) {
            final staged = await delivery.beginAttachmentUpload(
              attachment.localId,
              remoteSessionId: attachmentOwner,
              transport: AttachmentRemoteTransport.bridgeLocal,
            );
            if (staged == null) {
              client.close();
              _failRun(
                delivery.persistenceFailed
                    ? 'Could not save the state of an attachment.'
                    : 'The attachment batch changed during upload.',
              );
              return;
            }
            attachment = staged;
            if (attachment.isAttachedTo(
              attachmentOwner,
              transport: AttachmentRemoteTransport.bridgeLocal,
            )) {
              continue;
            }
          }
          late final String path;
          try {
            path = await client.uploadAttachment(
              File(attachment.localPath),
              filename: attachment.name,
              mimeType: attachment.mimeType,
            );
          } catch (_) {
            if (delivery != null && attachment.localId.isNotEmpty) {
              await delivery.markAttachmentFailed(
                attachment.localId,
                attempt: attachment.attempt,
                errorKind: AttachmentErrorKind.transport,
              );
            }
            rethrow;
          }
          if (_turnEpoch != turnEpoch || _runTerminal) {
            client.close();
            return;
          }
          if (path.isEmpty) {
            if (delivery != null && attachment.localId.isNotEmpty) {
              await delivery.markAttachmentFailed(
                attachment.localId,
                attempt: attachment.attempt,
                errorKind: AttachmentErrorKind.transport,
              );
            }
            client.close();
            _failRun('Could not prepare an attachment for this instance.');
            return;
          }
          if (delivery == null || attachment.localId.isEmpty) {
            attachmentPaths.add(path);
            continue;
          }
          final persisted = await delivery.markAttachmentAttached(
            attachment.localId,
            attempt: attachment.attempt,
            remoteSessionId: attachmentOwner,
            transport: AttachmentRemoteTransport.bridgeLocal,
            remoteRef: path,
          );
          if (!persisted) {
            client.close();
            _failRun(
              delivery.persistenceFailed
                  ? 'Could not save the state of an attachment.'
                  : 'The attachment batch changed during upload.',
            );
            return;
          }
        }
      } catch (_) {
        client.close();
        rethrow;
      }
      await delivery?.waitForAttachmentMutations();
      if (delivery != null) {
        final expectedIds = binaryAttachments
            .map((item) => item.localId)
            .where((id) => id.isNotEmpty)
            .toSet();
        final completed = delivery.current.activeAttachments
            .where(
              (item) =>
                  expectedIds.contains(item.localId) &&
                  item.isAttachedTo(
                    attachmentOwner,
                    transport: AttachmentRemoteTransport.bridgeLocal,
                  ),
            )
            .toList(growable: false);
        if (completed.length != expectedIds.length) {
          client.close();
          _failRun('The attachment batch changed during upload.');
          return;
        }
        attachmentPaths.addAll(completed.map((item) => item.remoteRef!));
      }
      if (attachmentPaths.isNotEmpty) {
        final refs = attachmentPaths
            .map((path) => '[Archivo adjunto disponible en $path]')
            .join('\n');
        effectivePrompt = '$effectivePrompt\n\n$refs'.trim();
      }

      // Resolución del modo de chat: simple evita el bucle de tool-calling que
      // deja vacío a los modelos pequeños (OlliteRT/Ollama ≤3B). Auto → simple
      // porque sin captura del modelo activo no podemos distinguir la capacidad
      // en runtime. Agent → agente completo (requiere modelo ≥7B).
      // `forceAgent` (chat de perfil remoto): exige el modo agente completo
      // (`hermes --profile -z`, con tools/skills/memoria del perfil); el chat
      // simple sería un POST directo al modelo, sin aislamiento. Para instancias
      // locales se respeta su `localChatMode` configurado.
      final useSimple =
          !forceAgent &&
          attachmentPaths.isEmpty &&
          (connection.localChatMode == LocalChatMode.simple ||
              connection.localChatMode == LocalChatMode.auto);

      var text = '';
      try {
        if (useSimple) {
          // Chat directo sin tools (bridge v1.9.0+). Sin SSE: el bridge devuelve
          // JSON plano. Renderizamos la respuesta completa de golpe (al igual que
          // el fallback chat() anterior, pero con modo=simple en el payload).
          text = (await client.chatSimple(
            effectivePrompt,
            history: history,
            profile: profile,
          )).trim();
        } else {
          // Streaming token a token (PTY en el bridge): se va emitiendo cada delta
          // como ActiveChatEvent.token, de modo que el modo voz hable frase a frase y
          // la burbuja crezca en vivo. Si el bridge es viejo (sin /bridge/chat/stream)
          // se cae al chat clásico sin re-ejecutar el turno.
          var gotAny = false;
          try {
            await for (final delta in client.chatStream(
              effectivePrompt,
              history: history,
              profile: profile,
              attachmentPaths: attachmentPaths,
            )) {
              if (_turnEpoch != turnEpoch || _runTerminal) break;
              _observeFirstResponseContent(delta);
              gotAny = true;
              text += delta;
              if (messages.isNotEmpty && messages[0]['role'] == 'assistant') {
                messages[0] = {
                  ...messages[0],
                  'content': text,
                  '_pipeline': false,
                };
              }
              _emit(ActiveChatEvent.token);
            }
          } on BridgeException catch (e) {
            debugPrint(
              '[active-chat] excepción silenciada (se avisa al usuario y se sigue): $e',
            );
            final endpointDefinitelyMissing =
                !gotAny &&
                e.kind == BridgeErrorKind.notFound &&
                e.status == 404;
            // Un error SSE llega después del HTTP 200: aunque aún no haya
            // texto, el agente pudo ejecutar herramientas. Solo un 404 del
            // endpoint demuestra que el stream nunca empezó y permite usar el
            // bridge legacy sin duplicar el turno.
            if (!endpointDefinitelyMissing) rethrow;
            text = (await client.chat(
              effectivePrompt,
              history: history,
              profile: profile,
              attachmentPaths: attachmentPaths,
            )).trim();
          }
        }
      } finally {
        client.close();
      }
      if (_turnEpoch != turnEpoch || _runTerminal) return;
      if (_hasPendingActiveTurnCancellation) {
        try {
          await (_durableCancelFlight ?? _cancelledTurnPersistence);
        } catch (_) {
          // Mantiene el turno cancelable para que Stop pueda reintentarse.
        }
        return;
      }
      if (!await _settleTombstoneMetadataBeforeTerminal(turnEpoch)) return;
      _observeFirstResponseContent(text);
      _runTerminal = true;
      text = text.trim();
      if (messages.isNotEmpty && messages[0]['role'] == 'assistant') {
        messages[0] = {...messages[0], 'content': text, '_pipeline': false};
      }
      state = ChatPipelineState.completed;
      traceActive = false;
      if (text.isNotEmpty && _shouldNotifyReplies && _notifications != null) {
        await _deliverTerminalNotification(
          () => _notifications.replyReady(
            preview: text.length > 140 ? '${text.substring(0, 140)}…' : text,
            instance: connection.label,
            session: sessionTitle.isNotEmpty ? sessionTitle : sessionId,
            connId: connection.id,
            sessionId: serverSessionId,
            surface: notificationSurface,
            profile: sessionProfile,
            roomId: notificationRoomId,
          ),
        );
      }
      _emit(ActiveChatEvent.done);
      // Guarda la conversación completa (pregunta + respuesta) para que
      // sobreviva al cierre de la pantalla.
      await _persistLocalTranscript();
      if (_turnEpoch == turnEpoch) {
        _drainOrTerminal(expectedEpoch: turnEpoch);
      }
    } catch (e) {
      if (_turnEpoch == turnEpoch) _failRun(_humanizeBridgeError(e));
    }
  }

  /// Traduce errores crudos del transporte del bridge a un mensaje accionable.
  /// El caso típico en local: el agente (o el Mobile Bridge) se cae a mitad del
  /// turno y Dart lanza «connection closed before full header was received» —
  /// que para el usuario no significa nada. En el emulador / equipos con poca RAM
  /// la causa habitual es que Android mató el proceso por memoria.
  String _humanizeBridgeError(Object e) {
    final s = e.toString();
    final low = s.toLowerCase();
    if (low.contains('connection closed') ||
        low.contains('before full header') ||
        low.contains('connection reset') ||
        low.contains('connection refused') ||
        low.contains('socketexception')) {
      return 'The local agent stopped mid-response (the process exited, '
          'usually out of memory). Start the local agent again and retry. If '
          'it keeps happening, use a smaller model or give the '
          'device/emulator more RAM.';
    }
    if (low.contains('timeout') || low.contains('timed out')) {
      return 'The local agent took too long to respond. The model may still '
          'be loading; wait a few seconds and retry.';
    }
    return 'Local chat: $s';
  }

  /// Conserva una indicación que no pudo entrar en el turno vivo. Se enviará
  /// automáticamente como turno normal al terminar, sin perder el texto.
  void enqueue(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _messageQueue.add(_QueuedTextTurn(trimmed, _nextQueueOrder++));
    _emit(ActiveChatEvent.queueChanged);
    if (!_queueDrainSuspended && !isStreaming) Timer.run(_drainQueue);
  }

  Future<bool> enqueuePreparedTurn(ActiveTurnDelivery delivery) async {
    final id = delivery.current.clientTurnId;
    if (_preparedTurnQueue.any((item) => item.turn.clientTurnId == id)) {
      return true;
    }
    if (!await delivery.persistPrepared()) return false;
    _preparedTurnQueue.add(
      QueuedPreparedTurn(delivery, queueOrder: _nextQueueOrder++),
    );
    _emit(ActiveChatEvent.queueChanged);
    if (!_queueDrainSuspended && !isStreaming) Timer.run(_drainQueue);
    return true;
  }

  Future<void> restoreQueuedTurns(
    Iterable<PreparedTurn> turns,
    TurnOutboxPersistence store, {
    bool scheduleDrain = true,
  }) async {
    _queueDrainSuspended = !scheduleDrain;
    var changed = false;
    for (final turn in turns) {
      if (!turn.queued ||
          (turn.state != PreparedTurnState.prepared &&
              turn.state != PreparedTurnState.failedBeforeAcceptance)) {
        continue;
      }
      if (_preparedTurnQueue.any(
        (item) => item.turn.clientTurnId == turn.clientTurnId,
      )) {
        continue;
      }
      _preparedTurnQueue.add(
        QueuedPreparedTurn(
          ActiveTurnDelivery(prepared: turn, store: store),
          queueOrder: _nextQueueOrder++,
        ),
      );
      changed = true;
    }
    if (changed) {
      _emit(ActiveChatEvent.queueChanged);
      if (scheduleDrain && !isStreaming) Timer.run(_drainQueue);
    }
  }

  Future<bool> cancelQueuedTurn(String clientTurnId) async {
    final queued = _preparedTurnQueue.where(
      (item) => item.turn.clientTurnId == clientTurnId,
    );
    if (queued.isEmpty) return false;
    final target = queued.first;
    if (_preparedTurnQueue.isNotEmpty &&
        identical(_preparedTurnQueue.first, target) &&
        _preparedTurnDrainInFlight) {
      return false;
    }
    if (!await target.delivery.discardPrepared()) return false;
    _preparedTurnQueue.remove(target);
    if (_blockedPreparedTurnId == clientTurnId) _blockedPreparedTurnId = null;
    _emit(ActiveChatEvent.queueChanged);
    return true;
  }

  void cancelQueued(int index) {
    if (_desktopAcceptedQueuedPrompt != null) {
      // El Gateway ya aceptó este siguiente turno. Ocultarlo localmente no lo
      // cancelaría en servidor, por lo que solo las entradas aún no enviadas
      // admiten eliminación individual.
      if (index == 0) return;
      index--;
    }
    if (index < 0 || index >= _messageQueue.length) return;
    final items = _messageQueue.toList()..removeAt(index);
    _messageQueue
      ..clear()
      ..addAll(items);
    _emit(ActiveChatEvent.queueChanged);
  }

  void _clearQueue() {
    final hasAcceptedOptimistic = messages.any(
      (message) => message['_desktopAcceptedQueued'] == true,
    );
    if (_messageQueue.isEmpty &&
        _preparedTurnQueue.isEmpty &&
        _desktopAcceptedQueuedPrompt == null &&
        !hasAcceptedOptimistic) {
      return;
    }
    _messageQueue.clear();
    final prepared = _preparedTurnQueue.toList(growable: false);
    _preparedTurnQueue.clear();
    _blockedPreparedTurnId = null;
    for (final item in prepared) {
      unawaited(item.delivery.discardPrepared());
    }
    _desktopAcceptedQueuedPrompt = null;
    messages.removeWhere(
      (message) => message['_desktopAcceptedQueued'] == true,
    );
    _emit(ActiveChatEvent.queueChanged);
  }

  void _replaceDesktopAcceptedQueue(String? text) {
    final normalized = text?.trim();
    final next = normalized == null || normalized.isEmpty ? null : normalized;
    if (_desktopAcceptedQueuedPrompt == next) return;
    _desktopAcceptedQueuedPrompt = next;
    _emit(ActiveChatEvent.queueChanged);
  }

  void _appendDesktopAcceptedQueue(String text) {
    final normalized = text.trim();
    if (normalized.isEmpty) return;
    final previous = _desktopAcceptedQueuedPrompt;
    _desktopAcceptedQueuedPrompt = previous == null || previous.isEmpty
        ? normalized
        : '$previous\n\n$normalized';
    _emit(ActiveChatEvent.queueChanged);
  }

  Future<void> _drainQueue() async {
    if (_queueDrainSuspended || isStreaming || _preparedTurnDrainInFlight) {
      return;
    }
    final preparedComesFirst =
        _preparedTurnQueue.isNotEmpty &&
        (_messageQueue.isEmpty ||
            _preparedTurnQueue.first.queueOrder <
                _messageQueue.first.queueOrder);
    if (preparedComesFirst) {
      final next = _preparedTurnQueue.first;
      if (_blockedPreparedTurnId == next.turn.clientTurnId) return;
      final turn = next.turn;
      _preparedTurnDrainInFlight = true;
      try {
        final accepted = await send(
          fullText: turn.fullText,
          desktopText: turn.desktopText,
          model: turn.model,
          history: _buildHistoryFromMessages(),
          profile: turn.profile,
          nativeAttachments: turn.activeAttachments,
          delivery: next.delivery,
        );
        if (accepted &&
            _preparedTurnQueue.isNotEmpty &&
            identical(_preparedTurnQueue.first, next)) {
          _preparedTurnQueue.removeFirst();
          _blockedPreparedTurnId = null;
          _emit(ActiveChatEvent.queueChanged);
        } else if (!accepted) {
          _blockedPreparedTurnId = next.turn.clientTurnId;
          _emit(ActiveChatEvent.queueChanged);
        }
      } finally {
        _preparedTurnDrainInFlight = false;
      }
      return;
    }
    if (_messageQueue.isEmpty) return;
    final next = _messageQueue.first;
    final accepted = await send(
      fullText: next.text,
      model: _lastModel,
      history: _buildHistoryFromMessages(),
      profile: _turnProfile,
    );
    if (accepted &&
        _messageQueue.isNotEmpty &&
        identical(_messageQueue.first, next)) {
      _messageQueue.removeFirst();
      _emit(ActiveChatEvent.queueChanged);
    }
  }

  /// Los mensajes pendientes son independientes de que el turno anterior haya
  /// terminado, fallado o sido detenido. Desktop aplica el mismo fallback.
  void _drainOrTerminal({required int expectedEpoch}) {
    if (_messageQueue.isEmpty && _preparedTurnQueue.isEmpty) {
      _onTerminal();
      return;
    }
    _terminalTimer?.cancel();
    _terminalTimer = Timer(const Duration(milliseconds: 800), () {
      _terminalTimer = null;
      if (_turnEpoch != expectedEpoch) return;
      _drainQueue();
      if (!isStreaming) _onTerminal();
    });
  }

  /// Historial conversacional reconstruido desde [messages] para reenviarlo al
  /// agente y mantener el contexto del hilo. Lo usan la cola interna y el modo
  /// voz (que no tiene acceso a la lógica privada). Ver
  /// [_buildHistoryFromMessages].
  /// [excludeCancelled] se conserva por compatibilidad de API, pero ya no elimina
  /// contenido: Stop detiene el trabajo, no borra la memoria conversacional.
  /// Los turnos detenidos se etiquetan solo en el payload del modelo para que no
  /// se reanuden por iniciativa propia y sí puedan retomarse si el usuario los
  /// menciona expresamente.
  List<Map<String, dynamic>> buildHistory({bool excludeCancelled = false}) =>
      _buildHistoryFromMessages();

  /// Reconstruye el historial OpenAI `[{role, content}]` en orden cronológico a
  /// partir de [messages] (index 0 = más nuevo), descartando placeholders del
  /// pipeline y errores: solo turnos conversacionales reales de user/assistant.
  List<Map<String, dynamic>> _buildHistoryFromMessages() {
    final history = <Map<String, dynamic>>[];
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      final role = (m['role'] ?? '').toString();
      if (role != 'user' && role != 'assistant') continue;
      if (m['_pipeline'] == true) continue;
      var content = (m['content'] as String?) ?? '';
      if (content.trim().isEmpty) continue;
      if (m['_cancelled'] == true || m['_cancelledUser'] == true) {
        content =
            '[Turn stopped by the user. Do not continue this work '
            'automatically; use it as context only if the user refers to it '
            'again.]\n$content';
      }
      history.add({'role': role, 'content': content});
    }
    return history;
  }

  /// Procesa un evento del SSE de `/v1/runs/{id}/events`.
  /// (Re)arma el watchdog de actividad del run: 90 s sin NINGUNA señal de vida
  /// (texto o herramientas) → se da por fallido. Cualquier evento lo reinicia.
  void _armFirstTokenTimer() {
    _firstTokenTimer?.cancel();
    final secs = _idleTimeout.inSeconds;
    _firstTokenTimer = Timer(_idleTimeout, () {
      if (!_streamingConfirmed && !_runTerminal) {
        _failRun(
          'firstTokenTimeout: The server connected but has been idle for '
          '$secs s (no text and no tools). The model may still be loading or '
          'the server may be overloaded. Retry in a few seconds.',
        );
      }
    });
  }

  void _onRunEvent(Map<String, dynamic> event) {
    // El run ya cerró localmente (el usuario tocó parar, o llegó un terminal):
    // ignora los frames rezagados que el gateway siga emitiendo hasta que el
    // SSE se cierre del todo. Si no, un `message.delta` tardío reprogramaría el
    // flush que hace `state = streaming` y resucitaría el estado "respondiendo"
    // (STOP + spinner) pese a estar ya cancelado/fallado.
    if (_runTerminal) return;
    final type = (event['event'] ?? '').toString();
    // Mientras no haya llegado texto, cualquier señal de vida del run (tools,
    // aprobaciones, progreso…) reinicia el watchdog de 90 s. Evita el falso
    // "Model not responding" en runs agénticos que ejecutan herramientas un buen
    // rato antes de emitir el primer token. message.delta lo cancela del todo;
    // los terminales se gestionan en sus casos.
    if (!_streamingConfirmed &&
        type != 'message.delta' &&
        type != 'run.completed' &&
        type != 'run.failed' &&
        type != 'run.cancelled') {
      _armFirstTokenTimer();
    }
    switch (type) {
      case 'message.delta':
        if (!_streamingConfirmed) {
          _streamingConfirmed = true;
          _firstTokenTimer?.cancel();
          _firstTokenTimer = null;
          ConnectionManager.markStreamingSupported(connection.id);
        }
        _enqueueToken((event['delta'] ?? '').toString());
      case 'tool.started':
        _flushTokenBuffer();
        state = ChatPipelineState.executing;
        _trackVoiceToolEvent(event, running: true, startsNew: true);
        _upsertRunTool(event, running: true);
        _emit(ActiveChatEvent.toolProgress);
      case 'tool.completed':
        _flushTokenBuffer();
        _trackVoiceToolEvent(event, running: false, startsNew: false);
        _upsertRunTool(event, running: false);
        _emit(ActiveChatEvent.toolProgress);
      case 'approval.request':
        _flushTokenBuffer();
        _handleApprovalRequest(event);
      case 'approval.responded':
        final respondedId = _approvalRequestId(event);
        final pendingId = _approvalRequestId(pendingApproval);
        if (respondedId == null ||
            pendingId == null ||
            respondedId != pendingId) {
          return;
        }
        _cancelApprovalNotification(pendingApproval!, terminal: false);
        pendingApproval = null;
        state = ChatPipelineState.executing;
        _emit(ActiveChatEvent.toolProgress);
      case 'run.completed':
        final out = (event['output'] ?? '').toString();
        _completeRun(finalOutput: out.isNotEmpty ? out : null);
      case 'run.failed':
        _failRun((event['error'] ?? 'The run failed').toString());
      case 'run.cancelled':
        _cancelRunState();
    }
  }

  /// El SSE del run cerró. Si no llegó un evento terminal explícito, asume que
  /// el turno completó y refresca.
  void _onRunStreamDone() {
    if (_runTerminal) return;
    _completeRun();
  }

  /// Adapta un evento tool.started/tool.completed del run a una línea de trace.
  void _upsertRunTool(Map<String, dynamic> event, {required bool running}) {
    final tool = (event['tool'] ?? 'herramienta').toString();
    final failed = event['error'] == true;
    final status = running ? 'running' : (failed ? 'failed' : 'completed');
    // Empareja con la última línea abierta de esa herramienta, o crea una nueva.
    final idx = trace.lastIndexWhere(
      (e) => e.id == tool && !e.isDone && !e.isFailed,
    );
    if (!running && idx >= 0) {
      trace[idx].status = status;
    } else {
      // `preview` (el argumento real: query, ruta…) viaja en tool.started y se
      // conserva solo para la tarjeta técnica. Voz clasifica el NOMBRE del tool
      // y jamás consume este campo porque puede contener rutas o secretos.
      final preview = (event['preview'] ?? '').toString();
      trace.add(
        ChatTraceEvent(
          id: tool,
          label: tool,
          status: status,
          emoji: '🔧',
          preview: preview,
        ),
      );
    }
  }

  void _trackVoiceToolEvent(
    Map<String, dynamic> event, {
    required bool running,
    required bool startsNew,
  }) {
    final label =
        (event['name'] ?? event['tool'] ?? event['tool_id'] ?? 'herramienta')
            .toString();
    final rawCallId = event['tool_call_id'] ?? event['call_id'] ?? event['id'];
    final normalizedCallId = rawCallId?.toString().trim();
    final callId = normalizedCallId == null || normalizedCallId.isEmpty
        ? null
        : normalizedCallId;
    var openIndex = callId == null
        ? -1
        : _activeVoiceTools.lastIndexWhere((tool) => tool.callId == callId);
    if (openIndex < 0 && !startsNew) {
      openIndex = _activeVoiceTools.lastIndexWhere(
        (tool) => tool.label == label,
      );
    }
    if (!running) {
      if (openIndex >= 0) _activeVoiceTools.removeAt(openIndex);
      return;
    }
    // A real start represents a new invocation, including two concurrent calls
    // with the same name. Progress/generating only adopts an invocation when a
    // start was not observed (legacy gateways may begin mid-lifecycle).
    if (startsNew) {
      if (callId == null || openIndex < 0) {
        _activeVoiceTools.add((callId: callId, label: label));
      }
      return;
    }
    if (openIndex < 0) {
      _activeVoiceTools.add((callId: callId, label: label));
    }
  }

  /// Aplica la política de aprobaciones a una `approval.request`. Vive aquí (en
  /// el servicio, no en la pantalla) para que YOLO/reglas guardadas auto-resuelvan
  /// AUNQUE el chat esté cerrado o la app en segundo plano —antes esto solo
  /// ocurría en RunsScreen, así que en el chat YOLO seguía preguntando—.
  ///
  ///   autoApprove → resuelve solo con el scope decidido (sin tarjeta).
  ///   blocked     → deniega solo (instancia/sesión solo-lectura).
  ///   ask / sin política → muestra la tarjeta y notifica si está en 2º plano.
  void _handleApprovalRequest(Map<String, dynamic> event) {
    // User input may legitimately take longer than the transport watchdog.
    // Resume the inactivity budget only after the approval is answered.
    _firstTokenTimer?.cancel();
    _firstTokenTimer = null;
    final command = (event['command'] ?? '').toString();
    final patternKey = (event['pattern_key'] ?? '').toString();
    final policy = _policy;
    final decision = policy?.evaluate(
      mode: policy.effectiveMode(sessionId),
      risk: assessCommandRisk(command.isEmpty ? null : command),
      readOnlyInstance: connection.readOnly,
      hasSavedAlways: policy.hasSavedAlways(
        connection.id,
        patternKey: patternKey.isEmpty ? null : patternKey,
        command: command.isEmpty ? null : command,
      ),
    );

    final requestId = _approvalRequestId(event);
    if (requestId == null) return;
    if (decision != null && decision.kind == ApprovalDecisionKind.autoApprove) {
      // YOLO / regla "siempre": resolver sin molestar al usuario.
      pendingApproval = event;
      state = ChatPipelineState.executing;
      _emit(ActiveChatEvent.toolProgress);
      _resolveApprovalRequest(decision.scope!.wire, event);
      return;
    }
    if (decision != null && decision.kind == ApprovalDecisionKind.blocked) {
      // Solo lectura: el agente no puede ejecutar; denegamos automáticamente.
      pendingApproval = event;
      state = ChatPipelineState.executing;
      _resolveApprovalRequest(ApprovalScope.deny.wire, event);
      return;
    }

    // Pedir: tarjeta inline + notificación (acciona aunque la app esté atrás).
    pendingApproval = event;
    state = ChatPipelineState.executing;
    _emit(ActiveChatEvent.approvalRequest);
    final tool =
        (event['command'] ??
                event['tool'] ??
                event['description'] ??
                'una herramienta')
            .toString();
    final approvalId = (event['request_id'] ?? event['approval_id'])
        ?.toString()
        .trim();
    _notifications?.approvalPending(
      tool: tool,
      instance: sessionTitle.isNotEmpty ? sessionTitle : null,
      connId: connection.id,
      // La pantalla y la superficie de voz marcan como visible la identidad
      // persistida. Usar aquí el id móvil provisional clasifica la aprobación
      // del propio chat como si viniera de "otro chat" y oculta su acceso.
      sessionId: serverSessionId,
      sessionTitle: sessionTitle,
      runId: _approvalRunOwner,
      approvalId: approvalId,
      surface: notificationSurface,
      profile: sessionProfile,
      roomId: notificationRoomId,
    );
  }

  /// Resuelve la aprobación pendiente del run (once|session|always|deny).
  Future<void> resolveApproval(String choice) {
    final approval = pendingApproval;
    if (_approvalRequestId(approval) == null) {
      return Future<void>.error(StateError('Approval is no longer pending'));
    }
    return _resolveApprovalRequest(choice, approval!);
  }

  String? _approvalRequestId(Map<String, dynamic>? approval) {
    final value = (approval?['request_id'] ?? approval?['approval_id'])
        ?.toString()
        .trim();
    return value == null || value.isEmpty ? null : value;
  }

  String? get _approvalRunOwner =>
      currentRunId ?? (_usingDesktopGateway ? _desktopRuntimeSessionId : null);

  void _cancelApprovalNotification(
    Map<String, dynamic> approval, {
    required bool terminal,
  }) {
    final approvalId = _approvalRequestId(approval);
    final runId = _approvalRunOwner;
    if (approvalId == null || runId == null) return;
    final operation = _notifications?.cancelApproval(
      connId: connection.id,
      profile: sessionProfile,
      runId: runId,
      approvalId: approvalId,
      terminal: terminal,
    );
    if (operation != null) {
      unawaited(operation.catchError((Object _) {}));
    }
  }

  Future<void> _resolveApprovalRequest(
    String choice,
    Map<String, dynamic> approval,
  ) async {
    final runId = _approvalRunOwner;
    final approvalId = _approvalRequestId(approval);
    if (approvalId == null) return;
    final desktop = _desktopGateway;
    final runtimeId = _desktopRuntimeSessionId;
    if (_usingDesktopGateway && desktop != null && runtimeId != null) {
      await desktop.resolveApproval(runtimeId, choice, requestId: approvalId);
      if (runId != null) {
        await _notifications?.cancelApproval(
          connId: connection.id,
          profile: sessionProfile,
          runId: runId,
          approvalId: approvalId,
        );
      }
      if (_approvalRequestId(pendingApproval) == approvalId) {
        pendingApproval = null;
      }
      state = ChatPipelineState.executing;
      if (!_streamingConfirmed) _armFirstTokenTimer();
      _emit(ActiveChatEvent.toolProgress);
      return;
    }
    if (runId == null) return;
    await _api.resolveRunApproval(runId, choice, requestId: approvalId);
    await _notifications?.cancelApproval(
      connId: connection.id,
      profile: sessionProfile,
      runId: runId,
      approvalId: approvalId,
    );
    if (_approvalRequestId(pendingApproval) == approvalId) {
      pendingApproval = null;
    }
    state = ChatPipelineState.executing;
    if (!_streamingConfirmed) _armFirstTokenTimer();
    _emit(ActiveChatEvent.toolProgress);
  }

  Future<DesktopPromptResponse> respondToClarify(
    InteractivePromptKey key,
    String answer,
  ) {
    final request = _interactivePrompts[key]?.request;
    if (request is ClarifyPromptRequest && request.isBatch) {
      return Future.error(StateError('Batch clarify requires batch response'));
    }
    return _respondToInteractivePrompt(
      key,
      expectedKind: InteractivePromptKind.clarify,
      invoke: (gateway) => gateway.respondToClarify(key.requestId, answer),
    );
  }

  Future<DesktopPromptResponse> respondToClarifyBatch(
    InteractivePromptKey key,
    Map<String, String> answers,
  ) {
    // Mutual exclusion includes synchronous ResponseStarted callbacks: publish
    // the shared operation before starting any work that can emit an event.
    final inFlight = _batchLocks[key];
    if (inFlight != null) return inFlight;

    final submittedAnswers = Map<String, String>.unmodifiable(answers);
    final completer = Completer<DesktopPromptResponse>();
    final sharedOperation = completer.future;
    _batchLocks[key] = sharedOperation;

    void release() {
      if (identical(_batchLocks[key], sharedOperation)) {
        _batchLocks.remove(key);
      }
    }

    final source = Future<DesktopPromptResponse>.sync(
      () => _respondToClarifyBatch(key, submittedAnswers),
    );
    source.then<void>(
      (result) {
        release();
        completer.complete(result);
      },
      onError: (Object error, StackTrace stackTrace) {
        release();
        completer.completeError(error, stackTrace);
      },
    );
    return sharedOperation;
  }

  Future<DesktopPromptResponse> _respondToClarifyBatch(
    InteractivePromptKey key,
    Map<String, String> answers,
  ) async {
    final runtimeId = _desktopRuntimeSessionId;
    final entry = _interactivePrompts[key];
    if (_retiringDesktopRuntimeSessionId == key.runtimeSessionId ||
        runtimeId != key.runtimeSessionId ||
        entry?.request is! ClarifyPromptRequest ||
        entry?.status != InteractivePromptStatus.pending) {
      throw StateError('Interactive prompt is no longer pending');
    }
    final request = entry!.request as ClarifyPromptRequest;
    if (!request.isBatch) {
      throw StateError('Legacy clarify requires legacy response');
    }
    final desktop = _desktopGateway;
    final HermesDesktopInteractivePromptGateway? interactiveGateway =
        desktop is HermesDesktopInteractivePromptGateway
        ? desktop as HermesDesktopInteractivePromptGateway
        : null;
    if (interactiveGateway == null) {
      throw const TuiGatewayRpcError(
        'interactive.respond',
        'Hermes interactive prompts are unavailable',
        code: -32601,
      );
    }

    _reduceInteractivePrompt(InteractivePromptResponseStarted(key));
    if (_respondingBatchRequest(key, expectedRequest: request) == null) {
      return DesktopPromptResponse.fromJson(
        const {'status': 'expired'},
        method: 'clarify.respond',
        allowExpired: true,
      );
    }
    try {
      DesktopPromptResponse? lastResult;
      var questionIndex = 0;
      while (true) {
        final liveRequest = _respondingBatchRequest(
          key,
          expectedRequest: request,
        );
        if (liveRequest == null) {
          return lastResult ??
              DesktopPromptResponse.fromJson(
                const {'status': 'expired'},
                method: 'clarify.respond',
                allowExpired: true,
              );
        }
        if (questionIndex >= liveRequest.questions.length) break;
        final question = liveRequest.questions[questionIndex++];
        // A passive authoritative snapshot may confirm a later qid while an
        // earlier ACK is in flight. Re-read the live monotonic fence before
        // every send instead of relying on the list captured at submission.
        if (liveRequest.lockedAnswers.containsKey(question.qid)) continue;
        final answer = answers[question.qid];
        if (answer == null || answer.isEmpty) {
          _reduceInteractivePrompt(InteractivePromptResponseFailed(key));
          throw const TuiGatewayRpcError(
            'clarify.respond',
            'Missing answer for a batch question',
            code: 4004,
          );
        }
        lastResult = await interactiveGateway.respondToClarify(
          key.requestId,
          answer,
          questionId: question.qid,
        );
        final liveAfterAck = _respondingBatchRequest(
          key,
          expectedRequest: request,
        );
        if (liveAfterAck == null) return lastResult;
        // Evaluate each response immediately and stop on any non-success
        // outcome, before sending the next sequential answer.
        if (lastResult.isExpired) {
          _reduceInteractivePrompt(InteractivePromptExpired(key));
          return lastResult;
        }
        final authoritativeAnswer = liveAfterAck.lockedAnswers[question.qid];
        if (authoritativeAnswer != null && authoritativeAnswer != answer) {
          _reduceInteractivePrompt(InteractivePromptExpired(key));
          throw StateError('Authoritative clarify answer conflict');
        }
        _reduceInteractivePrompt(
          InteractivePromptBatchProgressConfirmed(key, question.qid, answer),
        );
      }
      final result =
          lastResult ??
          DesktopPromptResponse.fromJson(const {
            'status': 'ok',
          }, method: 'clarify.respond');
      if (_respondingBatchRequest(key, expectedRequest: request) == null) {
        _reduceInteractivePrompt(InteractivePromptExpired(key));
        return result;
      }
      _reduceInteractivePrompt(InteractivePromptResponded(key));
      if (!_runTerminal && !_streamingConfirmed) {
        _armFirstTokenTimer();
      }
      return result;
    } catch (error) {
      if (_interactivePrompts[key]?.isTerminal == true) {
        // A local fail-closed fence (for example, an authoritative answer
        // conflict) must remain terminal and must not be reopened by resume.
      } else if (_disposed ||
          _desktopRuntimeSessionId != key.runtimeSessionId) {
        _reduceInteractivePrompt(InteractivePromptExpired(key));
      } else if (error is TuiGatewayRpcError && error.code != null) {
        _reduceInteractivePrompt(
          error.code == 4009
              ? InteractivePromptExpired(key)
              : InteractivePromptResponseFailed(key),
        );
      } else {
        // A transport failure can happen after the server consumed the answer
        // but before its ACK arrived. Never reopen the card until a fresh
        // session snapshot says exactly which question IDs remain.
        await _reconcileAmbiguousClarify(key);
      }
      rethrow;
    }
  }

  bool _interactivePromptResponseStillLive(
    InteractivePromptKey key, {
    required InteractivePromptKind expectedKind,
    required InteractivePromptRequest expectedRequest,
  }) {
    final current = _interactivePrompts[key];
    final currentRequest = current?.request;
    final isLive =
        !_disposed &&
        _retiringDesktopRuntimeSessionId != key.runtimeSessionId &&
        _desktopRuntimeSessionId == key.runtimeSessionId &&
        currentRequest?.kind == expectedKind &&
        identical(currentRequest, expectedRequest) &&
        current?.status == InteractivePromptStatus.responding;
    if (isLive) return true;

    // A callback may install a different request under a reused identity. Seal
    // only the exact request that started this response, never its replacement
    // or a successor runtime's composite key.
    if (identical(currentRequest, expectedRequest) &&
        current?.isTerminal != true) {
      _reduceInteractivePrompt(InteractivePromptExpired(key));
    }
    return false;
  }

  ClarifyPromptRequest? _respondingBatchRequest(
    InteractivePromptKey key, {
    required ClarifyPromptRequest expectedRequest,
  }) {
    if (_disposed) return null;
    if (_retiringDesktopRuntimeSessionId == key.runtimeSessionId ||
        _desktopRuntimeSessionId != key.runtimeSessionId) {
      // A runtime rotation invalidates only this exact in-flight batch. Seal its
      // entry before returning so a late ACK cannot leave it stuck responding;
      // terminal tombstones and prompts from every other identity stay intact.
      _reduceInteractivePrompt(InteractivePromptExpired(key));
      return null;
    }
    final current = _interactivePrompts[key];
    final request = current?.request;
    return current?.key == key &&
            request is ClarifyPromptRequest &&
            request.key == key &&
            request.isBatch &&
            current?.status == InteractivePromptStatus.responding &&
            _orderedBatchDefinitionsEqual(expectedRequest, request) &&
            _lockedAnswersAdvanceMonotonically(
              expectedRequest.lockedAnswers,
              request.lockedAnswers,
            )
        ? request
        : null;
  }

  bool _orderedBatchDefinitionsEqual(
    ClarifyPromptRequest expected,
    ClarifyPromptRequest current,
  ) {
    if (expected.key != current.key ||
        !expected.isBatch ||
        !current.isBatch ||
        expected.questions.length != current.questions.length) {
      return false;
    }
    for (var index = 0; index < expected.questions.length; index++) {
      final expectedQuestion = expected.questions[index];
      final currentQuestion = current.questions[index];
      if (expectedQuestion.qid != currentQuestion.qid ||
          expectedQuestion.question != currentQuestion.question ||
          expectedQuestion.multiSelect != currentQuestion.multiSelect ||
          expectedQuestion.choices.length != currentQuestion.choices.length) {
        return false;
      }
      for (
        var choiceIndex = 0;
        choiceIndex < expectedQuestion.choices.length;
        choiceIndex++
      ) {
        if (expectedQuestion.choices[choiceIndex] !=
            currentQuestion.choices[choiceIndex]) {
          return false;
        }
      }
    }
    return true;
  }

  bool _lockedAnswersAdvanceMonotonically(
    Map<String, String> expected,
    Map<String, String> current,
  ) {
    for (final answer in expected.entries) {
      if (current[answer.key] != answer.value) return false;
    }
    return true;
  }

  Future<void> _reconcileAmbiguousClarify(InteractivePromptKey key) async {
    final desktop = _desktopGateway;
    if (desktop is! HermesDesktopSessionLifecycleGateway) return;
    final lifecycle = desktop as HermesDesktopSessionLifecycleGateway;
    final bindEpoch = _desktopBindEpoch;
    try {
      final snapshot = await lifecycle.resumeExisting(
        serverSessionId,
        profile: _storedSessionProfile,
        omitMessages: true,
      );
      if (_disposed ||
          bindEpoch != _desktopBindEpoch ||
          _desktopRuntimeSessionId != key.runtimeSessionId) {
        return;
      }
      if (snapshot.runtimeSessionId != key.runtimeSessionId) {
        _reduceInteractivePrompt(InteractivePromptExpired(key));
        return;
      }
      _reconcilePendingClarifySnapshot(snapshot, unlockResponding: true);
    } on Object {
      // Fail closed: keep `responding`, which disables retries until a later
      // authoritative resume/reconnect reconciles the prompt.
    }
  }

  Future<DesktopPromptResponse> respondToSudo(
    InteractivePromptKey key,
    EphemeralSensitiveValue password,
  ) => _respondToSensitiveInteractivePrompt(
    key,
    callerValue: password,
    expectedKind: InteractivePromptKind.sudo,
    invoke: (gateway, ownedValue) =>
        gateway.respondToSudo(key.requestId, ownedValue),
  );

  Future<DesktopPromptResponse> respondToSecret(
    InteractivePromptKey key,
    EphemeralSensitiveValue value,
  ) => _respondToSensitiveInteractivePrompt(
    key,
    callerValue: value,
    expectedKind: InteractivePromptKind.secret,
    invoke: (gateway, ownedValue) =>
        gateway.respondToSecret(key.requestId, ownedValue),
  );

  Future<DesktopPromptResponse> _respondToSensitiveInteractivePrompt(
    InteractivePromptKey key, {
    required EphemeralSensitiveValue callerValue,
    required InteractivePromptKind expectedKind,
    required Future<DesktopPromptResponse> Function(
      HermesDesktopInteractivePromptGateway gateway,
      EphemeralSensitiveValue ownedValue,
    )
    invoke,
  }) {
    String sensitiveValue;
    try {
      sensitiveValue = callerValue.take();
    } catch (error, stackTrace) {
      callerValue.dispose();
      return Future<DesktopPromptResponse>.error(error, stackTrace);
    }
    callerValue.dispose();

    final ownedValue = EphemeralSensitiveValue(sensitiveValue);
    try {
      final operation = _respondToInteractivePrompt(
        key,
        expectedKind: expectedKind,
        invoke: (gateway) => invoke(gateway, ownedValue),
      );
      return operation.whenComplete(ownedValue.dispose);
    } catch (error, stackTrace) {
      ownedValue.dispose();
      return Future<DesktopPromptResponse>.error(error, stackTrace);
    }
  }

  Future<DesktopPromptResponse> respondToTerminalRead(
    InteractivePromptKey key,
  ) => _respondToInteractivePrompt(
    key,
    expectedKind: InteractivePromptKind.terminalRead,
    invoke: (gateway) => gateway.respondToTerminalRead(key.requestId),
  );

  Future<DesktopPromptResponse> _respondToInteractivePrompt(
    InteractivePromptKey key, {
    required InteractivePromptKind expectedKind,
    required Future<DesktopPromptResponse> Function(
      HermesDesktopInteractivePromptGateway gateway,
    )
    invoke,
  }) async {
    final runtimeId = _desktopRuntimeSessionId;
    final entry = _interactivePrompts[key];
    if (_retiringDesktopRuntimeSessionId == key.runtimeSessionId ||
        runtimeId != key.runtimeSessionId ||
        entry?.request?.kind != expectedKind ||
        entry?.status != InteractivePromptStatus.pending) {
      throw StateError('Interactive prompt is no longer pending');
    }
    final desktop = _desktopGateway;
    final HermesDesktopInteractivePromptGateway? interactiveGateway =
        desktop is HermesDesktopInteractivePromptGateway
        ? desktop as HermesDesktopInteractivePromptGateway
        : null;
    if (interactiveGateway == null) {
      throw const TuiGatewayRpcError(
        'interactive.respond',
        'Hermes interactive prompts are unavailable',
        code: -32601,
      );
    }

    _reduceInteractivePrompt(InteractivePromptResponseStarted(key));
    if (!_interactivePromptResponseStillLive(
      key,
      expectedKind: expectedKind,
      expectedRequest: entry!.request!,
    )) {
      if (expectedKind == InteractivePromptKind.terminalRead) {
        return DesktopPromptResponse.fromJson(
          const {'status': 'expired'},
          method: 'terminal.read.respond',
          allowExpired: true,
        );
      }
      throw StateError('Interactive prompt is no longer responding');
    }
    try {
      final result = await invoke(interactiveGateway);
      if (_disposed || _desktopRuntimeSessionId != key.runtimeSessionId) {
        _reduceInteractivePrompt(InteractivePromptExpired(key));
        return result;
      }
      _reduceInteractivePrompt(
        result.isExpired
            ? InteractivePromptExpired(key)
            : InteractivePromptResponded(key),
      );
      if (!result.isExpired && !_runTerminal && !_streamingConfirmed) {
        _armFirstTokenTimer();
      }
      return result;
    } catch (error) {
      final rpcCode = error is TuiGatewayRpcError ? error.code : null;
      if (expectedKind == InteractivePromptKind.clarify && rpcCode == null) {
        // A malformed/lost ACK may arrive after Hermes consumed the legacy
        // answer. Keep it fenced until session.resume reconciles authority.
        await _reconcileAmbiguousClarify(key);
      } else {
        _reduceInteractivePrompt(
          rpcCode == 4009
              ? InteractivePromptExpired(key)
              : InteractivePromptResponseFailed(key),
        );
      }
      rethrow;
    }
  }

  /// Adopta un turno iniciado fuera de Console que `session.resume` demuestra
  /// posterior al terminal visible. No reenvía el prompt: solo abre una época
  /// nueva para que delta/complete, recovery y subagentes no compartan las
  /// vallas ni el timer del turno anterior.
  void _beginExternallyObservedDesktopTurn(DesktopSessionSnapshot snapshot) {
    _terminalTimer?.cancel();
    _terminalTimer = null;
    final turnEpoch = _advanceTurnEpoch();
    // Un turno descubierto por resume no tiene un instante pre-submit
    // observado por Console: REST puede haber publicado ya su fila actual.
    // Resetea la procedencia y deja que solo target+timestamp o un tombstone
    // previo acrediten Stop.
    _captureActiveTurnTranscriptBoundary(
      turnEpoch,
      allowExistingTranscript: false,
    );
    _beginObservedResponseTiming();
    final prompt = snapshot.inflight?.user?.trim() ?? '';
    if (prompt.isNotEmpty) lastPrompt = prompt;
    trace.clear();
    _activeVoiceTools.clear();
    traceActive = true;
    if (pendingApproval != null) {
      _cancelApprovalNotification(pendingApproval!, terminal: true);
    }
    pendingApproval = null;
    _expireInteractivePromptsForRuntime(_desktopRuntimeSessionId);
    _pendingDesktopInterimKey = null;
    _assistantNarration.reset();
    currentRunId = null;
    _runTerminal = false;
    _streamingConfirmed =
        snapshot.inflight?.assistant?.trim().isNotEmpty == true;
    _cancelling = false;
    _discardLateInterruptTerminal = false;
    _subagentActivities = null;
    _subagentTranscriptTurnAnchor = null;
    _pendingSubagentInterrupts.clear();
  }

  /// Cierra la proyección visible del turno anterior y prepara el siguiente que
  /// Desktop ya aceptó. El Gateway conserva la autoridad sobre su envío.
  void _beginDesktopAcceptedQueuedTurn({String? finalOutput}) {
    final queuedPrompt = _desktopAcceptedQueuedPrompt;
    if (queuedPrompt == null || queuedPrompt.isEmpty) return;

    _observeFirstResponseContent(finalOutput);
    _clearDesktopCompactingIndicator();
    _desktopTurnStartedAt = null;
    _firstTokenTimer?.cancel();
    _firstTokenTimer = null;
    if (_fluidStreaming) {
      _queueAuthoritativeFinalTail(finalOutput);
      _publishBufferedTokenBatch();
    }
    _flushTokenBuffer();
    if (pendingApproval != null) {
      _cancelApprovalNotification(pendingApproval!, terminal: true);
    }
    pendingApproval = null;
    _expireInteractivePromptsForRuntime(_desktopRuntimeSessionId);
    _markCurrentTurnAwaitingTranscript();
    if (finalOutput != null &&
        messages.isNotEmpty &&
        messages.first['role'] == 'assistant') {
      messages[0] = {
        ...messages[0],
        'content': finalOutput,
        '_pipeline': false,
      };
    }
    _settlePipelinePlaceholders();
    _finalizeAcceptedTurnDelivery();

    // `session.redirect → queued` ya fue aceptado por el Gateway y este nuevo
    // turno se dispara desde su propio drenado. Solo avanzamos la proyección y
    // conservamos la suscripción; llamar a send/submitPrompt lo duplicaría.
    _messageLoadEpoch += 1;
    final turnEpoch = _advanceTurnEpoch();
    // El turno queued ya fue aceptado antes de que llegue aquí; una lectura
    // intermedia puede contener su user durable y no prueba que sea anterior.
    _captureActiveTurnTranscriptBoundary(
      turnEpoch,
      allowExistingTranscript: false,
    );
    _desktopAcceptedQueuedPrompt = null;
    _beginObservedResponseTiming();
    lastPrompt = queuedPrompt;
    state = ChatPipelineState.waiting;
    trace.clear();
    _activeVoiceTools.clear();
    traceActive = true;
    pendingApproval = null;
    _pendingDesktopInterimKey = null;
    _assistantNarration.reset();
    currentRunId = null;
    _terminalTimer?.cancel();
    _terminalTimer = null;
    _runTerminal = false;
    _streamingConfirmed = false;
    _cancelling = false;
    _discardLateInterruptTerminal = false;
    _subagentActivities = null;
    _subagentTranscriptTurnAnchor = null;
    _pendingSubagentInterrupts.clear();
    final acceptedOptimistic = messages
        .where((message) => message['_desktopAcceptedQueued'] == true)
        .toList(growable: false);
    if (acceptedOptimistic.isEmpty) {
      // Un resume puede descubrir una cola aceptada por el Gateway sin que
      // exista la optimista de este proceso.
      messages.insert(0, {'role': 'user', 'content': queuedPrompt});
    } else {
      messages.removeWhere(
        (message) => message['_desktopAcceptedQueued'] == true,
      );
      for (final message in acceptedOptimistic) {
        message.remove('_desktopAcceptedQueued');
      }
      // Lista newest-first: al cerrar el reply anterior estas filas pasan a ser
      // el tail visible y quedan justo detrás del placeholder del turno nuevo.
      messages.insertAll(0, acceptedOptimistic);
    }
    messages.insert(0, {'role': 'assistant', 'content': '', '_pipeline': true});
    _armFirstTokenTimer();
    _emit(ActiveChatEvent.queueChanged);
    _emit(ActiveChatEvent.started);
  }

  Future<void> _deliverTerminalNotification(
    Future<void> Function() show,
  ) async {
    await _beforeTerminalNotification?.call();
    await show();
  }

  /// Cierre exitoso del turno: fija el texto final, refresca el historial real
  /// (con sus tool events para agrupar) y notifica si procede.
  Future<void> _completeRun({
    String? finalOutput,
    bool finalOutputNarratable = true,
  }) async {
    if (_runTerminal) return;
    if (_hasPendingActiveTurnCancellation) {
      try {
        await (_durableCancelFlight ?? _cancelledTurnPersistence);
      } catch (_) {
        // Stop sigue visible y reintentable; el terminal no puede cerrar el run.
      }
      return;
    }
    final pendingMetadataTurnEpoch = _turnEpoch;
    if (!await _settleTombstoneMetadataBeforeTerminal(
      pendingMetadataTurnEpoch,
    )) {
      return;
    }
    _observeFirstResponseContent(finalOutput);
    _assistantNarration.settleFinal(finalOutputNarratable ? finalOutput : null);
    _clearDesktopCompactingIndicator();
    final completingEpoch = _turnEpoch;
    // A transport terminal is newer than any refresh already in flight.
    _messageLoadEpoch += 1;
    final completingMessageLoadEpoch = _messageLoadEpoch;
    _runTerminal = true;
    _desktopTurnStartedAt = null;
    _firstTokenTimer?.cancel();
    _firstTokenTimer = null;
    if (_fluidStreaming) {
      _queueAuthoritativeFinalTail(finalOutput);
      _publishBufferedTokenBatch();
    }
    if (!_isCurrentEpoch(completingEpoch)) return;
    _flushTokenBuffer();
    if (pendingApproval != null) {
      _cancelApprovalNotification(pendingApproval!, terminal: true);
    }
    pendingApproval = null;
    _expireInteractivePromptsForRuntime(_desktopRuntimeSessionId);
    _markCurrentTurnAwaitingTranscript();
    if (finalOutput != null &&
        messages.isNotEmpty &&
        messages[0]['role'] == 'assistant') {
      messages[0] = {
        ...messages[0],
        'content': finalOutput,
        '_pipeline': false,
      };
    }
    _settlePipelinePlaceholders();
    // El terminal del transporte ya confirma que este turno no debe volver a
    // enviarse. Su outbox se cierra antes de esperar la persistencia tardía del
    // transcript; esa espera solo afecta a la proyección visual.
    _finalizeAcceptedTurnDelivery();
    final transcriptReconciled = await _reconcileTerminalTranscript(
      completingEpoch,
      completingMessageLoadEpoch,
    );
    if (!_isCurrentEpoch(completingEpoch) ||
        completingMessageLoadEpoch != _messageLoadEpoch) {
      return;
    }
    state = ChatPipelineState.completed;
    traceActive = false;
    final content = assistantContent.trim();
    if (content.isNotEmpty && _shouldNotifyReplies && _notifications != null) {
      await _deliverTerminalNotification(
        () => _notifications.replyReady(
          preview: content.length > 140
              ? '${content.substring(0, 140)}…'
              : content,
          instance: connection.label,
          session: sessionTitle.isNotEmpty ? sessionTitle : sessionId,
          connId: connection.id,
          sessionId: serverSessionId,
          surface: notificationSurface,
          profile: sessionProfile,
          roomId: notificationRoomId,
        ),
      );
    }
    _emit(ActiveChatEvent.done);
    if (!transcriptReconciled || content.isEmpty) {
      // El Gateway puede emitir el terminal antes de que API Server publique la
      // sesión. Si ya tenemos texto por streaming no retrasamos el estado done:
      // reconciliamos en segundo plano y conservamos la proyección local hasta
      // que el transcript autoritativo incluya este turno.
      _scheduleTerminalTranscriptRecovery(
        completingEpoch,
        messageLoadEpoch: completingMessageLoadEpoch,
        requireAssistantText: content.isEmpty,
      );
    }
    _terminalTimer?.cancel();
    _terminalTimer = Timer(const Duration(milliseconds: 800), () {
      _terminalTimer = null;
      if (!_isCurrentEpoch(completingEpoch)) return;
      if (_messageQueue.isNotEmpty || _preparedTurnQueue.isNotEmpty) {
        _drainQueue();
        if (isStreaming) return;
      }
      if (state == ChatPipelineState.completed) {
        state = ChatPipelineState.idle;
        _emit(ActiveChatEvent.done);
      }
      _onTerminal();
    });
  }

  /// El placeholder `_pipeline` es estado efímero de UI, no transcript.
  /// Al cerrar/iniciar un turno se eliminan los vacíos y cualquier contenido
  /// defensivo se convierte en mensaje normal para no ocultar texto recibido.
  void _settlePipelinePlaceholders() {
    for (var index = messages.length - 1; index >= 0; index--) {
      final message = messages[index];
      if (message['_pipeline'] != true) continue;
      final content = (message['content'] as String?) ?? '';
      if (content.trim().isEmpty) {
        messages.removeAt(index);
      } else {
        messages[index] = {...message, '_pipeline': false};
      }
    }
  }

  /// El terminal de Desktop puede adelantarse unos milisegundos al commit del
  /// transcript. Una sola lectura en ese instante devuelve el turno anterior y
  /// deja una burbuja vacía hasta reabrir el chat. El intento bloqueante sigue
  /// siendo único cuando ya existe texto local; si todavía llega un 404, el
  /// backoff de segundo plano completa la reconciliación sin alargar el run.
  Future<bool> _reconcileTerminalTranscript(
    int completingEpoch,
    int messageLoadEpoch,
  ) async {
    bool stillCurrent() =>
        _isCurrentEpoch(completingEpoch) &&
        messageLoadEpoch == _messageLoadEpoch;
    if (!stillCurrent()) return false;
    if (_suppressTerminalHydrationAfterCompaction) {
      // Tras una compactación el stream/snapshot de Desktop es la fuente viva.
      // El endpoint REST puede seguir apuntando al tip anterior durante unos
      // instantes y no debe borrar la conversación recién rotada.
      _suppressTerminalHydrationAfterCompaction = false;
      return true;
    }
    final epochInvalidated = _turnEpochInvalidated.future;
    final expectedUsers = messages.where(isRealUserTurn).length;
    final needsRemoteText = assistantContent.trim().isEmpty;
    final delays = needsRemoteText
        ? const <Duration>[
            Duration.zero,
            Duration(milliseconds: 250),
            Duration(milliseconds: 750),
            Duration(milliseconds: 1500),
            Duration(seconds: 3),
          ]
        : const <Duration>[Duration.zero];
    final deadline = DateTime.now().add(_terminalReconcileBudget);

    for (final delay in delays) {
      if (!stillCurrent()) return false;
      var remaining = deadline.difference(DateTime.now());
      if (remaining.inMicroseconds <= 0) return false;
      if (delay > Duration.zero) {
        final wait = delay < remaining ? delay : remaining;
        final elapsed = await _waitForTerminalReconcileDelay(
          wait,
          epochInvalidated,
        );
        if (!elapsed) return false;
        if (!stillCurrent()) return false;
        if (wait < delay) return false;
      }
      remaining = deadline.difference(DateTime.now());
      if (remaining.inMicroseconds <= 0) return false;
      try {
        final transcript = await _terminalTranscriptBeforeDeadline(
          _loadStoredMessages(_storedSessionProfile),
          remaining,
          epochInvalidated,
        );
        if (!stillCurrent() || transcript == null) {
          return false;
        }
        if (!_terminalTranscriptCanReplaceVisibleProjection(
          transcript,
          expectedUsers,
        )) {
          continue;
        }
        _captureArtifactMaps(transcript, logicalSessionId: logicalSessionId);
        final fencedTranscript = _carryNewestTerminalFence(
          messages,
          _normalizedNewestFirst(transcript),
          candidateTranscriptComplete: true,
        );
        messages = projectCancelledTurnTombstones(
          existingNewestFirst: messages,
          incomingNewestFirst: fencedTranscript,
          durableTombstones: _cancelledTurnTombstones,
          incomingTranscriptComplete: true,
        );
        _markTranscriptComplete(visibleCount: messages.length);
        _mergeSteerRecords();
        _reconcileSubagentsFromTranscript();
        return true;
      } catch (error) {
        debugPrint(
          '[active-chat] terminal transcript not ready '
          '(${error.runtimeType})',
        );
      }
    }
    return false;
  }

  /// Espera un backoff cancelable sin dejar un `Future.delayed` vivo después
  /// de cerrar el chat o invalidar el turno.
  Future<bool> _waitForTerminalReconcileDelay(
    Duration delay,
    Future<void> epochInvalidated,
  ) async {
    final elapsed = Completer<bool>();
    final timer = Timer(delay, () => elapsed.complete(true));
    try {
      return await Future.any<bool>([
        elapsed.future,
        _disposeSignal.future.then((_) => false),
        epochInvalidated.then((_) => false),
      ]);
    } finally {
      timer.cancel();
    }
  }

  Future<T?> _desktopRecoveryOperationBeforeDeadline<T>(
    Future<T> operation,
    Future<void> epochInvalidated,
  ) async {
    final deadline = Completer<T?>();
    final timer = Timer(_desktopRecoveryAttemptTimeout, () {
      deadline.completeError(
        TimeoutException(
          'Desktop recovery operation timed out',
          _desktopRecoveryAttemptTimeout,
        ),
      );
    });
    try {
      return await Future.any<T?>([
        operation,
        deadline.future,
        _disposeSignal.future.then((_) => null),
        epochInvalidated.then((_) => null),
      ]);
    } finally {
      timer.cancel();
    }
  }

  /// Acota un GET y cancela el temporizador al terminar antes (éxito o error).
  /// `Future.any` por sí solo no cancela su `Future.delayed`; en widget tests y
  /// chats cerrados ese timer quedaba retenido durante todo el presupuesto.
  Future<List<Map<String, dynamic>>?> _terminalTranscriptBeforeDeadline(
    Future<List<Map<String, dynamic>>> request,
    Duration remaining,
    Future<void> epochInvalidated,
  ) async {
    final deadline = Completer<List<Map<String, dynamic>>?>();
    final timer = Timer(remaining, () => deadline.complete(null));
    try {
      return await Future.any<List<Map<String, dynamic>>?>([
        request,
        deadline.future,
        _disposeSignal.future.then((_) => null),
        epochInvalidated.then((_) => null),
      ]);
    } finally {
      timer.cancel();
    }
  }

  bool _containsCompletedTurn(
    List<Map<String, dynamic>> chronological,
    int expectedUsers,
  ) {
    var userCount = 0;
    var latestUserIndex = -1;
    for (var i = 0; i < chronological.length; i++) {
      if (isRealUserTurn(chronological[i])) {
        userCount++;
        latestUserIndex = i;
      }
    }
    if (userCount < expectedUsers || latestUserIndex < 0) return false;
    for (var i = latestUserIndex + 1; i < chronological.length; i++) {
      final message = chronological[i];
      if (message['role'] == 'tool') return true;
      if (message['role'] == 'assistant' &&
          ((message['content'] as String? ?? '').trim().isNotEmpty ||
              (message['tool_calls'] is List &&
                  (message['tool_calls'] as List).isNotEmpty))) {
        return true;
      }
    }
    return false;
  }

  /// Distingue una invocación de herramienta cuyo `assistant` final aún puede
  /// estar pendiente de un transcript legítimamente terminal `user -> tool`.
  /// Este último existe en fuentes antiguas y no debe provocar polling eterno.
  bool _turnAwaitsFinalAfterToolInvocation(
    List<Map<String, dynamic>> chronological,
    int expectedUsers,
  ) {
    var userCount = 0;
    var latestUserIndex = -1;
    for (var index = 0; index < chronological.length; index++) {
      if (!isRealUserTurn(chronological[index])) continue;
      userCount++;
      latestUserIndex = index;
    }
    if (userCount < expectedUsers || latestUserIndex < 0) return false;

    for (
      var index = latestUserIndex + 1;
      index < chronological.length;
      index++
    ) {
      final message = chronological[index];
      final toolCalls = message['tool_calls'];
      if (message['role'] == 'assistant' &&
          toolCalls is List &&
          toolCalls.isNotEmpty) {
        return true;
      }
      if (message['role'] == 'tool') {
        final linkedCallId = message['tool_call_id'] ?? message['call_id'];
        if (linkedCallId is String && linkedCallId.isNotEmpty) return true;
      }
    }
    return false;
  }

  /// Un transcript recién persistido puede contener ya el usuario y una parte
  /// de la respuesta, pero seguir por detrás del `message.complete` que recibió
  /// la UI. Nunca debe sustituir una proyección local más completa: hacerlo
  /// ocultaba párrafos hasta la siguiente recarga del historial.
  bool _terminalTranscriptCanReplaceVisibleProjection(
    List<Map<String, dynamic>> chronological,
    int expectedUsers,
  ) {
    if (!_containsCompletedTurn(chronological, expectedUsers)) return false;
    final visible = assistantContent.trim();
    if (visible.isEmpty) return true;
    final remote = _latestTurnAssistantText(chronological, expectedUsers);
    // Un texto canónico puede diferir legítimamente del emitido por streaming
    // (normalización del renderer, redacción final, etc.). Solo es regresión
    // demostrable cuando lo persistido es un prefijo propio de lo ya visible.
    final normalizedVisible = visible.replaceAll(RegExp(r'\s+'), ' ');
    final normalizedRemote = remote?.replaceAll(RegExp(r'\s+'), ' ');
    final stalePrefix =
        normalizedRemote != null &&
        normalizedRemote.length < normalizedVisible.length &&
        normalizedVisible.startsWith(normalizedRemote);
    final preservesVisible = remote != null && !stalePrefix;
    if (!preservesVisible) {
      debugPrint(
        '[active-chat] terminal transcript deferred '
        '(visible_chars=${visible.length}, remote_chars=${remote?.length ?? 0})',
      );
    }
    return preservesVisible;
  }

  /// Cierre con error del turno.
  void _failRun(
    String error, {
    String? terminalText,
    bool terminalTextIsPartial = false,
    Map<String, dynamic> failureMetadata = const {},
  }) {
    if (_runTerminal || _hasPendingActiveTurnCancellation) return;
    if (_hasPendingTombstoneMetadataUpdate) {
      final expectedTurnEpoch = _turnEpoch;
      unawaited(
        _deferFailRunUntilTombstoneMetadataSettles(
          expectedTurnEpoch,
          error,
          terminalText: terminalText,
          terminalTextIsPartial: terminalTextIsPartial,
          failureMetadata: failureMetadata,
        ),
      );
      return;
    }
    _clearDesktopCompactingIndicator();
    _messageLoadEpoch += 1;
    _runTerminal = true;
    _desktopTurnStartedAt = null;
    _firstTokenTimer?.cancel();
    _firstTokenTimer = null;
    _flushTokenBuffer();
    if (pendingApproval != null) {
      _cancelApprovalNotification(pendingApproval!, terminal: true);
    }
    pendingApproval = null;
    _expireInteractivePromptsForRuntime(_desktopRuntimeSessionId);
    if (messages.isNotEmpty && messages[0]['role'] == 'assistant') {
      final current = ((messages[0]['content'] as String?) ?? '').trim();
      final terminal = terminalText?.trim() ?? '';
      final continuesCurrent =
          current.isNotEmpty &&
          (terminal.startsWith(current) || current.startsWith(terminal));
      if (terminal.isNotEmpty && (terminalTextIsPartial || continuesCurrent)) {
        messages[0] = {...messages[0], 'content': terminal};
      }
    }
    final hasPartial =
        messages.isNotEmpty &&
        messages[0]['role'] == 'assistant' &&
        ((messages[0]['content'] as String?) ?? '').isNotEmpty;
    state = ChatPipelineState.failed;
    _finalizeAcceptedTurnDelivery();
    traceActive = false;
    _cancelling = false;
    if (!hasPartial &&
        messages.isNotEmpty &&
        messages[0]['role'] == 'assistant') {
      final projectionId = _nextLocalTranscriptProjectionId();
      _tagLatestUserForLocalError(projectionId);
      messages[0] = {
        'role': 'assistant_error',
        'content': error,
        '_prompt': lastPrompt,
        ...failureMetadata,
        '_localTranscriptProjectionId': projectionId,
      };
    } else if (hasPartial &&
        messages.isNotEmpty &&
        messages[0]['role'] == 'assistant') {
      // A-012 (spec 028): el stream falló a media respuesta. Antes el parcial
      // quedaba pintado como un mensaje normal terminado (sin marca ni
      // reintento) y se podía leer una respuesta truncada creyéndola completa.
      // Se marca como interrumpido (misma marca visual que la cancelación) y
      // se añade la burbuja de error con "Reintentar" encima del parcial.
      messages[0] = {...messages[0], '_cancelled': true, '_pipeline': false};
      final projectionId = _nextLocalTranscriptProjectionId();
      _tagLatestUserForLocalError(projectionId);
      messages.insert(0, {
        'role': 'assistant_error',
        'content': error,
        '_prompt': lastPrompt,
        ...failureMetadata,
        '_localTranscriptProjectionId': projectionId,
      });
    }
    // Avisa del problema si la app está en 2º plano (no molesta en primer plano).
    if (_shouldNotifyReplies && _notifications != null) {
      unawaited(
        _deliverTerminalNotification(
          () => _notifications.replyFailed(
            instance: connection.label,
            session: sessionTitle.isNotEmpty ? sessionTitle : sessionId,
            detail: error,
            connId: connection.id,
            sessionId: serverSessionId,
            surface: notificationSurface,
            profile: sessionProfile,
            roomId: notificationRoomId,
          ),
        ),
      );
    }
    _emit(ActiveChatEvent.error);
    _drainOrTerminal(expectedEpoch: _turnEpoch);
  }

  Future<void> _deferFailRunUntilTombstoneMetadataSettles(
    int expectedTurnEpoch,
    String error, {
    String? terminalText,
    required bool terminalTextIsPartial,
    required Map<String, dynamic> failureMetadata,
  }) async {
    if (!await _settleTombstoneMetadataBeforeTerminal(expectedTurnEpoch)) {
      return;
    }
    _failRun(
      error,
      terminalText: terminalText,
      terminalTextIsPartial: terminalTextIsPartial,
      failureMetadata: failureMetadata,
    );
  }

  void _trackCancelledTurnPersistence(Future<void> operation) {
    _cancelledTurnPersistence = operation;
    _cancelledTurnPersistencePending = true;
    _cancelledTurnPersistenceFailed = false;
    unawaited(
      operation.then<void>(
        (_) {
          if (identical(_cancelledTurnPersistence, operation)) {
            _cancelledTurnPersistencePending = false;
            _cancelledTurnPersistenceFailed = false;
          }
        },
        onError: (Object _, StackTrace _) {
          if (identical(_cancelledTurnPersistence, operation)) {
            _cancelledTurnPersistencePending = false;
            _cancelledTurnPersistenceFailed = true;
          }
        },
      ),
    );
  }

  ({int index, CancelledTurnTombstone tombstone})?
  _latestUserCancellationCandidate() {
    for (var index = 0; index < messages.length; index++) {
      final message = messages[index];
      if (!isRealUserTurn(message)) continue;
      final content = (message['content'] ?? '').toString();
      if (content.isEmpty) return null;
      final provenAnchorMessageId = message[_stopProofAnchorMessageIdKey];
      final provenAnchorRowId = message[_stopProofAnchorRowIdKey];
      final exactProvenAnchorMessageId =
          provenAnchorMessageId is String && provenAnchorMessageId.isNotEmpty
          ? provenAnchorMessageId
          : null;
      final exactProvenAnchorRowId =
          provenAnchorRowId is int && provenAnchorRowId > 0
          ? provenAnchorRowId
          : null;
      if (exactProvenAnchorMessageId != null ||
          exactProvenAnchorRowId != null) {
        return (
          index: index,
          tombstone: CancelledTurnTombstone(
            content: content,
            anchorMessageId: exactProvenAnchorMessageId,
            anchorRowId: exactProvenAnchorRowId,
          ),
        );
      }
      final targetMessageId = canonicalTranscriptMessageId(message);
      final targetRowId = canonicalTranscriptRowId(message);
      if (targetMessageId != null || targetRowId != null) {
        return (
          index: index,
          tombstone: CancelledTurnTombstone(
            content: content,
            cancelledMessageId: targetMessageId,
            cancelledRowId: targetRowId,
          ),
        );
      }
      String? anchorMessageId;
      int? anchorRowId;
      var anchorIndex = -1;
      final candidateIsLive = _isLiveTranscriptProjection(message);
      for (var older = index + 1; older < messages.length; older++) {
        final olderMessage = messages[older];
        anchorMessageId = canonicalTranscriptMessageId(olderMessage);
        anchorRowId = canonicalTranscriptRowId(olderMessage);
        if (anchorMessageId != null || anchorRowId != null) {
          anchorIndex = older;
          break;
        }
        // Un usuario intermedio sin identidad impide demostrar qué turno
        // sigue al ancla. No lo cruces: prompts repetidos podrían cancelar el
        // turno histórico y resucitar precisamente el que se detuvo.
        if (isRealUserTurn(olderMessage)) {
          final isSameLocalTurnProjection =
              candidateIsLive &&
              _isLiveTranscriptProjection(olderMessage) &&
              (olderMessage['content'] ?? '').toString() == content;
          if (!isSameLocalTurnProjection) return null;
        }
      }
      if (anchorMessageId != null || anchorRowId != null) {
        if (candidateIsLive && anchorIndex >= 0) {
          final anchorMessage = messages[anchorIndex];
          if (isRealUserTurn(anchorMessage) &&
              (anchorMessage['content'] ?? '').toString() == content) {
            // El primer ID encontrado puede ser la copia durable del propio
            // inflight. No es un ancla anterior; la prueba de pertenencia se
            // obtiene por separado del snapshot vivo y su timestamp.
            return null;
          }
          final adjacentDurableUser = messages
              .skip(anchorIndex + 1)
              .where(isRealUserTurn)
              .firstOrNull;
          if (adjacentDurableUser != null &&
              (adjacentDurableUser['content'] ?? '').toString() == content) {
            // Una fila adyacente por posición puede ser un turno histórico
            // homónimo que llegó tarde. El contenido nunca acredita identidad.
            return null;
          }
        }
        return (
          index: index,
          tombstone: CancelledTurnTombstone(
            content: content,
            anchorMessageId: anchorMessageId,
            anchorRowId: anchorRowId,
          ),
        );
      }
      final hasOlderRealUser = messages.skip(index + 1).any(isRealUserTurn);
      if (!hasOlderRealUser && _transcriptIsComplete) {
        return (
          index: index,
          tombstone: CancelledTurnTombstone(content: content, firstUser: true),
        );
      }
      return null;
    }
    return null;
  }

  bool _sameCancelledTurn(
    CancelledTurnTombstone left,
    CancelledTurnTombstone right,
  ) => _sameCancelledTurnIdentity(left, right);

  bool _cancelledTurnIdentityWasUpgraded(
    ({int index, CancelledTurnTombstone tombstone}) before,
    ({int index, CancelledTurnTombstone tombstone}) after,
  ) {
    if (!after.tombstone.hasTargetIdentity ||
        before.tombstone.content != after.tombstone.content) {
      return false;
    }
    final reboundIndex = _cancelledTurnUserIndex(
      messages,
      before.tombstone,
      incomingTranscriptComplete: _transcriptIsComplete,
    );
    return reboundIndex >= 0 && reboundIndex == after.index;
  }

  void _commitCancelledTurnLocally(
    ({int index, CancelledTurnTombstone tombstone}) candidate,
  ) {
    final durable = candidate.tombstone;
    final existingIndex = _cancelledTurnTombstones.indexWhere(
      (item) => _sameCancelledTurn(item, durable),
    );
    if (existingIndex < 0) {
      _cancelledTurnTombstones.add(durable);
      _cancelledTombstoneRevision += 1;
    } else if (_cancelledTurnTombstones[existingIndex].invalidated) {
      _cancelledTurnTombstones[existingIndex] = durable;
      _cancelledTombstoneRevision += 1;
    }
    final message = Map<String, dynamic>.of(messages[candidate.index])
      ..remove(_stopProofAnchorMessageIdKey)
      ..remove(_stopProofAnchorRowIdKey)
      ..addAll({
        '_cancelledUser': true,
        '_cancelledTurnAnchorMessageId': durable.anchorMessageId,
        '_cancelledTurnAnchorRowId': durable.anchorRowId,
        '_cancelledTurnFirstUser': durable.firstUser,
        '_cancelledTurnMessageId': durable.cancelledMessageId,
        '_cancelledTurnRowId': durable.cancelledRowId,
      });
    messages[candidate.index] = message;
  }

  void _markLatestUserCancelledLocally() {
    for (var index = 0; index < messages.length; index++) {
      final message = messages[index];
      if (!isRealUserTurn(message)) continue;
      messages[index] = {...message, '_cancelledUser': true};
      return;
    }
  }

  /// Conserva únicamente la identidad exacta del último user durable que ya
  /// era visible antes de iniciar el turno. No guarda contenido ni ordinales:
  /// una fila que aparece después del submit no puede convertirse por posición
  /// en el predecessor del inflight.
  void _captureActiveTurnTranscriptBoundary(
    int turnEpoch, {
    bool allowExistingTranscript = true,
  }) {
    _activeTurnTranscriptBoundaryEpoch = turnEpoch;
    _activeTurnTranscriptBoundaryIdentity = null;
    _activeTurnTranscriptBoundarySessionId = serverSessionId;
    _activeTurnTranscriptBoundaryProfile = _storedSessionProfile;
    if (!allowExistingTranscript) return;
    for (final message in messages) {
      if (!isRealUserTurn(message)) continue;
      // El primer user visible ES la frontera. Si aún es una proyección local
      // no se puede atravesar para capturar como predecessor otro user más
      // antiguo: el tombstone caería sobre esta fila intermedia.
      if (_isLiveTranscriptProjection(message) ||
          message['_desktopAcceptedQueued'] == true) {
        return;
      }
      if (!transcriptIdentityAliasesAreConsistent(message)) return;
      final identity = _transcriptMessageIdentity(message);
      if (identity == null ||
          _uniqueTranscriptIdentityMatch(identity, messages) == null) {
        return;
      }
      _activeTurnTranscriptBoundaryIdentity = identity;
      return;
    }
  }

  bool _activeTurnBoundaryAlreadyProven(TranscriptMessageIdentity identity) {
    final baseline = _activeTurnTranscriptBoundaryIdentity;
    return _activeTurnTranscriptBoundaryEpoch == _turnEpoch &&
        _activeTurnTranscriptBoundarySessionId == serverSessionId &&
        _activeTurnTranscriptBoundaryProfile == _storedSessionProfile &&
        baseline != null &&
        baseline.matches(identity);
  }

  /// Una identidad que no estaba visible antes del submit todavía puede ser
  /// un predecessor acreditado si una página completa la enlaza de forma
  /// única a un Stop anterior. Es el caso del firstUser que se vuelve durable
  /// entre la primera cancelación y el segundo turno.
  bool _completeTranscriptBindsPriorCancellationToBoundary(
    List<Map<String, dynamic>> incoming,
    TranscriptMessageIdentity boundaryIdentity, {
    required bool incomingTranscriptComplete,
  }) {
    if (!incomingTranscriptComplete) return false;
    for (final tombstone in _cancelledTurnTombstones) {
      if (tombstone.invalidated) continue;
      final index = _cancelledTurnUserIndex(
        incoming,
        tombstone,
        incomingTranscriptComplete: true,
      );
      if (index < 0) continue;
      final identity = _transcriptMessageIdentity(incoming[index]);
      if (identity != null &&
          identity.matches(boundaryIdentity) &&
          _uniqueTranscriptIdentityMatch(identity, incoming) != null) {
        return true;
      }
    }
    return false;
  }

  /// Hidrata la identidad exacta del prompt vivo sin inferirla por posición.
  ///
  /// El Gateway actual publica `turn_started_at` antes de ejecutar el turno;
  /// versiones experimentales usaron `inflight.started_at`. El resolver exige
  /// que ambos coincidan cuando coexisten y falla cerrado ante un conflicto.
  /// La fila durable del usuario se escribe después de esa frontera. Por tanto,
  /// una única fila user con ID y timestamp posterior es el target exacto; si
  /// la última fila user es anterior, su ID es un ancla exacta para el inflight
  /// que aún no se persistió. Toda la lectura queda vallada por el epoch de
  /// transcript y por el runtime exacto.
  Future<bool> _hydrateCurrentTurnCancellationIdentity() async {
    bool reject(String reason) {
      debugPrint('[active-chat] Stop identity rejected ($reason)');
      return false;
    }

    final expectedTurnEpoch = _turnEpoch;
    String expectedPrompt = '';
    for (final message in messages) {
      if (!isRealUserTurn(message) || !_isLiveTranscriptProjection(message)) {
        continue;
      }
      expectedPrompt = (message['content'] ?? '').toString();
      if (expectedPrompt.isNotEmpty) break;
    }
    if (expectedPrompt.isEmpty) expectedPrompt = lastPrompt;
    final gateway = _desktopGateway;
    final expectedRuntimeId = _desktopRuntimeSessionId;
    if (!isStreaming ||
        !_usingDesktopGateway ||
        expectedPrompt.isEmpty ||
        expectedRuntimeId == null ||
        gateway is! HermesDesktopSessionLifecycleGateway) {
      return reject('precondition');
    }
    final lifecycle = gateway as HermesDesktopSessionLifecycleGateway;

    // Stop supersede cualquier refresh anterior. Una carga nueva que empiece
    // después incrementará el epoch y hará fallar esta prueba antes de mutar.
    final proofMessageLoadEpoch = ++_messageLoadEpoch;
    final expectedCoverageRevision = _transcriptCoverageRevision;
    final expectedSessionEpoch = _desktopSessionEpoch;
    final expectedBindEpoch = _desktopBindEpoch;
    final expectedStoredId = serverSessionId;
    final expectedProfile = _storedSessionProfile;

    bool proofStillCurrent() =>
        !_disposed &&
        isStreaming &&
        _usingDesktopGateway &&
        _turnEpoch == expectedTurnEpoch &&
        _messageLoadEpoch == proofMessageLoadEpoch &&
        _transcriptCoverageRevision == expectedCoverageRevision &&
        _desktopSessionEpoch == expectedSessionEpoch &&
        _desktopBindEpoch == expectedBindEpoch &&
        _desktopRuntimeSessionId == expectedRuntimeId &&
        serverSessionId == expectedStoredId &&
        _storedSessionProfile == expectedProfile;

    try {
      final snapshot = await lifecycle.resumeExisting(
        expectedStoredId,
        profile: expectedProfile,
        omitMessages: true,
      );
      if (!proofStillCurrent() ||
          snapshot.runtimeSessionId != expectedRuntimeId ||
          snapshot.storedSessionId != expectedStoredId ||
          !snapshot.running) {
        return reject('snapshot-fence');
      }
      final inflight = snapshot.inflight;
      final startedAt = snapshot.resolvedTurnStartedAt;
      final inflightUser = inflight?.user;
      if (startedAt == null || inflightUser != expectedPrompt) {
        return reject('inflight-proof');
      }

      final page = await _loadStoredMessagesTail(_storedSessionProfile);
      if (!proofStillCurrent() ||
          page.offset != 0 ||
          !page.messagesFullyParsed ||
          !page.paginationFullyParsed) {
        return reject('transcript-page');
      }
      final pageProvesComplete = _tailPageProvesTranscriptComplete(page);
      final incoming = _normalizedNewestFirst(page.messages);
      Map<String, dynamic>? durableBoundary;
      for (final message in incoming) {
        if (isRealUserTurn(message)) {
          durableBoundary = message;
          break;
        }
      }
      if (durableBoundary == null ||
          !transcriptIdentityAliasesAreConsistent(durableBoundary)) {
        return reject('durable-boundary');
      }
      final durableIdentity = _transcriptMessageIdentity(durableBoundary);
      final durableTimestamp = _transcriptTimestamp(durableBoundary);
      if (durableIdentity == null ||
          _uniqueTranscriptIdentityMatch(durableIdentity, incoming) == null ||
          durableTimestamp == null ||
          durableTimestamp.isAtSameMomentAs(startedAt)) {
        return reject('durable-identity');
      }
      final boundaryIsCurrent = durableTimestamp.isAfter(startedAt);
      if (boundaryIsCurrent &&
          (durableBoundary['content'] ?? '').toString() != inflightUser) {
        return reject('current-content');
      }
      if (!boundaryIsCurrent &&
          !_activeTurnBoundaryAlreadyProven(durableIdentity) &&
          !_completeTranscriptBindsPriorCancellationToBoundary(
            incoming,
            durableIdentity,
            incomingTranscriptComplete: pageProvesComplete,
          )) {
        // Una fila homónima que apareció tras submit también puede ser el
        // target actual con timestamp atrasado. Sin procedencia pre-turno o
        // un tombstone previo enlazado, tratarla como ancla podría ocultar el
        // siguiente turno legítimo.
        return reject('historical-boundary');
      }

      // Un segundo user iniciado bajo la misma frontera indicaría que la
      // página y el inflight no describen una única extensión del transcript.
      for (final message
          in incoming
              .skipWhile((message) => !identical(message, durableBoundary))
              .skip(1)) {
        if (!isRealUserTurn(message)) continue;
        final timestamp = _transcriptTimestamp(message);
        if (timestamp != null && !timestamp.isBefore(startedAt)) {
          return reject('multiple-current-users');
        }
      }

      final localIndex = messages.indexWhere(
        (message) =>
            isRealUserTurn(message) &&
            _isLiveTranscriptProjection(message) &&
            (message['content'] ?? '').toString() == expectedPrompt,
      );
      if (localIndex < 0) return reject('local-projection');
      if (!proofStillCurrent()) return reject('commit-fence');
      messages[localIndex] = {
        ...messages[localIndex],
        if (boundaryIsCurrent && durableIdentity.messageId != null)
          '_desktopMessageId': durableIdentity.messageId,
        if (boundaryIsCurrent && durableIdentity.rowId != null)
          '_desktopRowId': durableIdentity.rowId,
        if (!boundaryIsCurrent && durableIdentity.messageId != null)
          _stopProofAnchorMessageIdKey: durableIdentity.messageId,
        if (!boundaryIsCurrent && durableIdentity.rowId != null)
          _stopProofAnchorRowIdKey: durableIdentity.rowId,
      };
      // La misma lectura puede completar de forma autoritativa la identidad
      // de Stops anteriores (por ejemplo, el firstUser del primer turno). No
      // basta con encontrar el ancla del turno vivo: si dejamos aquel
      // tombstone ambiguo, un segundo Stop queda pendiente entre dos
      // escrituras y la siguiente continuación puede bloquearse. Solo se
      // enlaza cuando offset=0 y la página demuestra cobertura completa; una
      // cola paginada sigue fallando cerrado.
      _bindTombstonesToDurableIds(
        incoming,
        incomingTranscriptComplete: pageProvesComplete,
      );
      return true;
    } catch (error) {
      debugPrint(
        '[active-chat] Stop identity hydration unavailable '
        '(${error.runtimeType})',
      );
      return false;
    }
  }

  Future<void> _persistLatestUserCancellation() async {
    var before = _latestUserCancellationCandidate();
    final persist = _onCancelledTurn;
    if (before == null && persist != null) {
      if (await _hydrateCurrentTurnCancellationIdentity()) {
        before = _latestUserCancellationCandidate();
      }
    }
    if (before == null) {
      if (persist != null) {
        throw StateError('cancelled turn has no durable transcript anchor');
      }
      _markLatestUserCancelledLocally();
      return;
    }
    if (persist != null) {
      Future<void> operation;
      try {
        operation = persist(before.tombstone);
      } catch (error, stackTrace) {
        operation = Future<void>.error(error, stackTrace);
      }
      _trackCancelledTurnPersistence(operation);
      await operation;
    } else {
      _cancelledTurnPersistence = Future<void>.value();
      _cancelledTurnPersistencePending = false;
      _cancelledTurnPersistenceFailed = false;
    }
    final after = _latestUserCancellationCandidate();
    if (after == null) {
      throw StateError('cancelled turn changed while persisting tombstone');
    }
    if (_sameCancelledTurn(before.tombstone, after.tombstone)) {
      _commitCancelledTurnLocally(after);
      return;
    }
    if (!_cancelledTurnIdentityWasUpgraded(before, after)) {
      throw StateError('cancelled turn changed while persisting tombstone');
    }
    // El tombstone anclado ya está confirmado. Conserva esa autoridad y deja
    // que el mismo reconciliador que usa refresh lo enriquezca con los IDs
    // exactos recién hidratados, sin equiparar mensajes por contenido.
    _commitCancelledTurnLocally((
      index: after.index,
      tombstone: before.tombstone,
    ));
    _bindTombstonesToDurableIds(
      messages,
      incomingTranscriptComplete: _transcriptIsComplete,
    );
  }

  /// El run fue cancelado por el servidor (no por el usuario).
  void _cancelRunState() {
    if (_runTerminal || _hasPendingActiveTurnCancellation) return;
    if (_hasPendingTombstoneMetadataUpdate) {
      final expectedTurnEpoch = _turnEpoch;
      unawaited(
        _deferCancelRunUntilTombstoneMetadataSettles(expectedTurnEpoch),
      );
      return;
    }
    _clearDesktopCompactingIndicator();
    _messageLoadEpoch += 1;
    _runTerminal = true;
    _desktopTurnStartedAt = null;
    _firstTokenTimer?.cancel();
    _firstTokenTimer = null;
    _flushTokenBuffer();
    if (pendingApproval != null) {
      _cancelApprovalNotification(pendingApproval!, terminal: true);
    }
    pendingApproval = null;
    _expireInteractivePromptsForRuntime(_desktopRuntimeSessionId);
    final hasPartial =
        messages.isNotEmpty &&
        messages[0]['role'] == 'assistant' &&
        ((messages[0]['content'] as String?) ?? '').isNotEmpty;
    state = ChatPipelineState.cancelled;
    _finalizeAcceptedTurnDelivery();
    traceActive = false;
    _cancelling = false;
    if (!hasPartial &&
        messages.isNotEmpty &&
        messages[0]['role'] == 'assistant') {
      messages.removeAt(0);
    } else if (hasPartial &&
        messages.isNotEmpty &&
        messages[0]['role'] == 'assistant') {
      messages[0] = {...messages[0], '_cancelled': true, '_pipeline': false};
    }
    // Marca también el mensaje de usuario para que el historial lo conserve con
    // la instrucción de no reanudarlo automáticamente. Usa una clave propia:
    // `_cancelled` pintaría la burbuja como cancelada y no queremos eso aquí.
    _markLatestUserCancelledLocally();
    _emit(ActiveChatEvent.cancelled);
    _drainOrTerminal(expectedEpoch: _turnEpoch);
  }

  Future<void> _deferCancelRunUntilTombstoneMetadataSettles(
    int expectedTurnEpoch,
  ) async {
    if (!await _settleTombstoneMetadataBeforeTerminal(expectedTurnEpoch)) {
      return;
    }
    _cancelRunState();
  }

  /// Cancela el run en curso y no completa hasta que el tombstone cifrado
  /// queda confirmado por el almacenamiento durable.
  Future<void> cancel() {
    if (_onCancelledTurn == null) {
      final candidate = _latestUserCancellationCandidate();
      if (candidate != null) {
        _commitCancelledTurnLocally(candidate);
      } else {
        _markLatestUserCancelledLocally();
      }
      _cancelCurrent(requestServerStop: true, markUserCancelled: false);
      return Future<void>.value();
    }
    final existing = _durableCancelFlight;
    if (existing != null) return existing;
    final operation = _cancelDurably();
    _durableCancelFlight = operation;
    unawaited(
      operation
          .whenComplete(() {
            if (identical(_durableCancelFlight, operation)) {
              _durableCancelFlight = null;
              if (releaseRequested && !isStreaming && !hasListeners) {
                _onUnused?.call();
              }
            }
          })
          .catchError((_) {}),
    );
    return operation;
  }

  Future<void> _cancelDurably() async {
    final cancelEpoch = _turnEpoch;
    await _persistLatestUserCancellation();
    if (_disposed || cancelEpoch != _turnEpoch) return;
    _cancelCurrent(
      requestServerStop: true,
      deferConfirmation: true,
      markUserCancelled: false,
    );
    final terminalEpoch = _turnEpoch;
    _emit(ActiveChatEvent.cancelled);
    _drainOrTerminal(expectedEpoch: terminalEpoch);
  }

  void _beginVoiceBargeHandoff() {
    _voiceBargeHandoffPending = true;
    _voiceBargeHandoffTimer?.cancel();
    _voiceBargeHandoffTimer = Timer(_voiceBargeHandoffRetention, () {
      _voiceBargeHandoffTimer = null;
      if (!_voiceBargeHandoffPending || _disposed) return;
      _voiceBargeHandoffPending = false;
      if (!isStreaming) _onTerminal();
    });
  }

  void _finishVoiceBargeHandoff({required bool notifyTerminal}) {
    if (!_voiceBargeHandoffPending && _voiceBargeHandoffTimer == null) return;
    _voiceBargeHandoffPending = false;
    _voiceBargeHandoffTimer?.cancel();
    _voiceBargeHandoffTimer = null;
    if (notifyTerminal && !_disposed && !isStreaming) _onTerminal();
  }

  /// Interrumpe un turno porque el usuario empezó a hablar sobre la respuesta.
  ///
  /// Replica el orden de Hermes Desktop: corta el turno en cuanto el VAD
  /// confirma voz, espera brevemente su terminal y deja que la transcripción se
  /// envíe después como un turno nuevo marcado `interrupted`. Así una STT lenta
  /// no permite que la respuesta vieja termine y haga parecer que se perdió el
  /// contexto de la corrección.
  Future<void> interruptForVoiceBarge({
    Duration settleTimeout = activeChatVoiceBargeSettleTimeout,
  }) async {
    if (!isStreaming) return;
    final settleDeadline = DateTime.now().add(settleTimeout);
    Duration remainingSettle() => settleDeadline.difference(DateTime.now());
    _beginVoiceBargeHandoff();
    final runtimeId = _desktopRuntimeSessionId;
    final desktop = _desktopGateway;
    final runId = currentRunId;

    if (_usingDesktopGateway && runtimeId != null && desktop != null) {
      final durableId = _desktopStoredSessionId ?? serverSessionId;
      final ownerProfile = _storedSessionProfile;
      final interruptDrain = Completer<void>();
      _desktopInterruptDrain = interruptDrain;
      _discardLateInterruptTerminal = true;
      _cancelCurrent(requestServerStop: false);
      final interruptEpoch = _turnEpoch;

      Future<void> interruptOnce(String targetRuntimeId) async {
        final remaining = remainingSettle();
        if (remaining <= Duration.zero) {
          throw TimeoutException('Voice barge-in settle deadline elapsed');
        }
        await desktop.interrupt(targetRuntimeId).timeout(remaining);
      }

      try {
        try {
          await interruptOnce(runtimeId);
        } on TuiGatewayRpcError catch (error) {
          if (error.code != 4001 ||
              desktop is! HermesDesktopSessionLifecycleGateway) {
            rethrow;
          }
          final lifecycleDesktop =
              desktop as HermesDesktopSessionLifecycleGateway;

          // Desktop solo reata un runtime obsoleto ante el 4001 oficial. El
          // stored id y el perfil quedan fijados antes del primer interrupt;
          // si otro turno cambia el binding durante el resume, no se adopta ni
          // se envía el retry a ese destino nuevo.
          var remaining = remainingSettle();
          if (remaining <= Duration.zero) {
            throw TimeoutException('Voice barge-in settle deadline elapsed');
          }
          final snapshot = await lifecycleDesktop
              .resumeExisting(
                durableId,
                profile: ownerProfile,
                omitMessages: true,
              )
              .timeout(remaining);
          final currentDurableId = _desktopStoredSessionId ?? serverSessionId;
          if (_disposed ||
              !identical(_desktopGateway, desktop) ||
              !_usingDesktopGateway ||
              _turnEpoch != interruptEpoch ||
              _desktopRuntimeSessionId != runtimeId ||
              _storedSessionProfile != ownerProfile ||
              currentDurableId != durableId) {
            throw StateError('voice_barge_interrupt_target_changed');
          }
          _desktopStoredSessionId = snapshot.storedSessionId;
          _adoptDesktopRuntime(snapshot.runtimeSessionId, info: snapshot.info);
          _desktopStoredSessionKnownMissing = false;
          await interruptOnce(snapshot.runtimeSessionId);
        }

        final remaining = remainingSettle();
        if (remaining > Duration.zero) {
          await interruptDrain.future.timeout(remaining);
        }
      } on TimeoutException {
        // Gateways antiguos pueden confirmar el RPC sin publicar un terminal.
        // El guard existente descartará ese terminal si llega más tarde.
      } catch (_) {
        // `prompt.submit` conserva su propio busy gate en el servidor. El
        // siguiente envío mostrará el error real si el turno no se asentó.
      } finally {
        if (identical(_desktopInterruptDrain, interruptDrain)) {
          _desktopInterruptDrain = null;
        }
      }
      return;
    }

    _cancelCurrent(requestServerStop: false);
    if (runId != null) {
      try {
        var remaining = remainingSettle();
        if (remaining <= Duration.zero) return;
        final stopped = await _api.stopRun(runId).timeout(remaining);
        remaining = remainingSettle();
        if (!activeChatVoiceBargeRunIsTerminal(stopped) &&
            remaining > Duration.zero) {
          await waitForActiveChatVoiceBargeTerminal(
            readStatus: () => _api.getRun(runId),
            timeout: remaining,
          );
        }
      } catch (_) {
        // Compatibilidad REST best-effort; el turno siguiente sigue llevando
        // el historial local con la marca de interrupción.
      }
    }
  }

  void _cancelCurrent({
    required bool requestServerStop,
    bool deferConfirmation = false,
    bool markUserCancelled = true,
  }) {
    if (_cancelling) return;
    _cancelling = true;
    _clearDesktopCompactingIndicator();
    final activeTurnTransport = _activeTurnDelivery?.current.transport;
    final hadDesktopTurn =
        (_usingDesktopGateway && currentRunId == null) ||
        activeTurnTransport == PreparedTurnTransport.desktop ||
        _recoveringDesktopTurnEpoch == _turnEpoch;
    // Invalida todos los callbacks del transporte que se está abandonando.
    _advanceTurnEpoch();
    _messageLoadEpoch += 1;
    _firstTokenTimer?.cancel();
    _firstTokenTimer = null;
    _flushTokenBuffer();
    // Pide al servidor detener el run; el SSE cerrará (o emitirá run.cancelled),
    // pero ya marcamos terminal para no procesarlo dos veces.
    final runtimeId = _desktopRuntimeSessionId;
    final desktop = _desktopGateway;
    final runId = currentRunId;
    final cancelStoredSessionId = _desktopStoredSessionId ?? serverSessionId;
    final shouldRecoverDesktopCancel =
        requestServerStop &&
        desktop != null &&
        hadDesktopTurn &&
        cancelStoredSessionId.isNotEmpty;
    final cancelProfile = _turnProfile;
    final cancelModel = _lastModel;
    if (requestServerStop && !shouldRecoverDesktopCancel && runId != null) {
      _api.stopRun(runId).catchError((_) => <String, dynamic>{});
    }
    // Stop significa detener el trabajo completo solicitado desde el composer,
    // no solo el run que está delante. Ningún seguimiento pendiente debe
    // arrancar después de una cancelación explícita del usuario.
    _clearQueue();
    _runTerminal = true;
    _desktopTurnStartedAt = null;
    pendingApproval = null;
    _expireInteractivePromptsForRuntime(_desktopRuntimeSessionId);
    final hasPartial =
        messages.isNotEmpty &&
        messages[0]['role'] == 'assistant' &&
        ((messages[0]['content'] as String?) ?? '').isNotEmpty;
    state = ChatPipelineState.cancelled;
    _finalizeAcceptedTurnDelivery();
    traceActive = false;
    _cancelling = false;
    if (shouldRecoverDesktopCancel) {
      _scheduleDesktopCancelRecovery(
        gateway: desktop,
        runtimeSessionId: runtimeId,
        storedSessionId: cancelStoredSessionId,
        profile: cancelProfile,
        model: cancelModel,
        cancelEpoch: _turnEpoch,
      );
    }
    if (!hasPartial &&
        messages.isNotEmpty &&
        messages[0]['role'] == 'assistant') {
      messages.removeAt(0);
    } else if (hasPartial &&
        messages.isNotEmpty &&
        messages[0]['role'] == 'assistant') {
      messages[0] = {...messages[0], '_cancelled': true, '_pipeline': false};
    }
    // Stop conserva el tema como memoria, pero buildHistory lo etiqueta para que
    // ni voz ni texto lo retomen salvo referencia explícita. Steering no pasa
    // por aquí: mantiene este mismo run vivo.
    if (markUserCancelled) _markLatestUserCancelledLocally();
    if (!deferConfirmation) {
      _emit(ActiveChatEvent.cancelled);
      _drainOrTerminal(expectedEpoch: _turnEpoch);
    }
  }

  /// Corrige el turno vivo mediante `session.redirect`, igual que Hermes
  /// Desktop. No llama a `/stop`, no abre otro run y conserva herramientas,
  /// estado y trabajo ya completado. Gateways antiguos degradan a
  /// `session.steer` únicamente cuando no publican el RPC moderno.
  Future<void> steer(String fullText) async {
    if (desktopCompressionInFlight) {
      throw const TuiGatewayRpcError(
        'session.redirect',
        'Session compression is still running',
        code: 4009,
      );
    }
    if (connection.kind == InstanceKind.localhost) {
      throw StateError('steer_not_available_for_local_bridge');
    }
    if (!isStreaming) throw StateError('run_not_active');

    final steerEpoch = _turnEpoch;
    final recovery = _recoveringDesktopTurnEpoch == steerEpoch
        ? _desktopTurnRecovery
        : null;
    if (recovery != null) {
      await recovery;
      if (_turnEpoch != steerEpoch || !isStreaming) {
        throw StateError('run_not_active');
      }
    }

    var runtimeId = _desktopRuntimeSessionId;
    for (
      var attempt = 0;
      attempt < 100 && runtimeId == null && currentRunId == null && isStreaming;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      runtimeId = _desktopRuntimeSessionId;
    }
    final desktop = _desktopGateway;
    if (!_usingDesktopGateway || desktop == null) {
      throw StateError('steer_desktop_gateway_unavailable');
    }
    if (runtimeId == null || !isStreaming) throw StateError('run_not_ready');

    Future<({DesktopRedirectDisposition disposition, bool usedLegacySteer})>
    redirectOnce(String targetRuntimeId) async {
      final anchorUserOrdinal = messages.where(isRealUserTurn).length - 1;
      final optimisticMessage = <String, dynamic>{
        'role': 'user',
        'content': fullText,
        '_steer': true,
      };

      // Desktop inserta la corrección antes del await: session.redirect puede
      // completar el run y publicar su terminal antes de responder al RPC. Si
      // esperásemos al ACK, la fila acabaría debajo de una respuesta a la que
      // ya afectó o desaparecería durante la reconciliación.
      final insertAt =
          messages.isNotEmpty && messages.first['role'] == 'assistant' ? 1 : 0;
      messages.insert(insertAt, optimisticMessage);
      _emit(ActiveChatEvent.waiting);

      void rollbackOptimisticMessage() {
        messages.removeWhere(
          (message) => identical(message, optimisticMessage),
        );
      }

      try {
        var disposition = DesktopRedirectDisposition.redirected;
        var usedLegacySteer = false;
        if (desktop case final HermesDesktopRedirectGateway redirectGateway) {
          try {
            disposition = await redirectGateway.redirect(
              targetRuntimeId,
              fullText,
            );
          } on TuiGatewayRpcError catch (error) {
            // Un timeout o error de transporte es ambiguo: reintentar podría
            // duplicar una corrección que el servidor sí alcanzó a aceptar.
            if (error.code != -32601) rethrow;
            await desktop.steer(targetRuntimeId, fullText);
            usedLegacySteer = true;
          }
        } else {
          await desktop.steer(targetRuntimeId, fullText);
          usedLegacySteer = true;
        }

        if (disposition == DesktopRedirectDisposition.queued) {
          // El Gateway ya aceptó este texto como siguiente turno. Conservamos
          // la misma fila que se mostró antes del ACK; el terminal del reply
          // vivo la mueve a su posición definitiva sin reconstruirla.
          optimisticMessage
            ..remove('_steer')
            ..['_desktopAcceptedQueued'] = true;
          _appendDesktopAcceptedQueue(fullText);
          return (disposition: disposition, usedLegacySteer: usedLegacySteer);
        }

        _steerRecords.add((
          anchorUserOrdinal: anchorUserOrdinal,
          content: fullText,
        ));
        return (disposition: disposition, usedLegacySteer: usedLegacySteer);
      } catch (_) {
        rollbackOptimisticMessage();
        rethrow;
      }
    }

    late ({DesktopRedirectDisposition disposition, bool usedLegacySteer})
    result;
    try {
      result = await redirectOnce(runtimeId);
    } on TuiGatewayRpcError catch (error) {
      if (error.code != 4001 ||
          desktop is! HermesDesktopSessionLifecycleGateway) {
        rethrow;
      }

      // Igual que Desktop: un runtime obsoleto se reata al stored id con su
      // perfil propietario y session.redirect se reintenta exactamente una
      // vez. No se crea una sesión y no se reintentan timeouts ambiguos.
      final durableId = _desktopStoredSessionId ?? serverSessionId;
      final snapshot = await (desktop as HermesDesktopSessionLifecycleGateway)
          .resumeExisting(
            durableId,
            profile: _storedSessionProfile,
            omitMessages: true,
          );
      if (_disposed || !isStreaming) throw StateError('run_not_active');
      _desktopStoredSessionId = snapshot.storedSessionId;
      _adoptDesktopRuntime(snapshot.runtimeSessionId, info: snapshot.info);
      _desktopStoredSessionKnownMissing = false;
      result = await redirectOnce(snapshot.runtimeSessionId);
    }

    if (result.disposition == DesktopRedirectDisposition.queued) {
      debugPrint('[active-chat] live correction disposition=queued');
      return;
    }

    debugPrint(
      '[active-chat] live correction disposition='
      '${result.usedLegacySteer ? 'legacy_steer' : 'redirected'}',
    );
    debugPrint('[active-chat] live correction accepted');
  }

  /// Un socket puede morir mientras Android tiene el isolate congelado: el
  /// frame de cierre no se entrega y el heartbeat tampoco corre, así que
  /// `onError` nunca dispara y el turno se queda en `executing` para siempre.
  /// Al volver a foreground —y al reabrir el chat— el estado real del
  /// transporte SÍ es observable, y un transporte caído bajo un turno activo se
  /// trata exactamente igual que un corte observado en vivo: el recovery normal
  /// lo reengancha o, si Hermes ya no conoce el turno, lo cierra con un error
  /// visible en vez de dejarlo colgado. Es idempotente: `_recoveringDesktopTurnEpoch`
  /// impide arrancar dos recoveries para el mismo turno.
  void recoverTurnIfTransportLost() {
    final gateway = _desktopGateway;
    if (gateway == null ||
        !_usingDesktopGateway ||
        _runTerminal ||
        _disposed ||
        gateway.isConnected) {
      return;
    }
    debugPrint('[active-chat] transport lost under a live turn; recovering');
    _expireInteractivePromptsForRuntime(_desktopRuntimeSessionId);
    _usingDesktopGateway = false;
    _retireDesktopRuntime();
    _scheduleDesktopTurnRecovery(
      gateway,
      _turnEpoch,
      StateError('Hermes Desktop transport closed while suspended'),
    );
  }

  /// Reconciliación al volver de 2º plano. Si el SSE murió mientras la app
  /// estaba suspendida (caso raro: el SO mató el isolate pese al foreground
  /// service) y quedó un placeholder/parcial sin cerrar, re-sincroniza los
  /// mensajes desde el servidor (el run sigue su curso server-side). Devuelve
  /// true si hubo cambios. No toca un stream vivo.
  Future<bool> reconcileAfterResume() async {
    if (isStreaming) {
      // Un turno "vivo" cuyo transporte ya no lo está es la única forma en que
      // el chat puede quedarse ejecutando para siempre. Reengánchalo aquí: sin
      // esto ni el chat se recupera ni la pantalla vuelve a cargar al reabrirlo.
      recoverTurnIfTransportLost();
      return false;
    }
    final expectedUsers = messages.where(isRealUserTurn).length;
    Map<String, dynamic>? latestVisibleUser;
    for (final message in messages) {
      if (!isRealUserTurn(message)) continue;
      latestVisibleUser = message;
      break;
    }
    // Stop es una autoridad terminal local y durable. Un snapshot `running`
    // retrasado nunca puede convertir esa cancelación en un turno vivo.
    if (state == ChatPipelineState.cancelled ||
        latestVisibleUser?['_cancelledUser'] == true) {
      return false;
    }
    final top = messages.isNotEmpty ? messages.first : null;
    final looksUnfinished =
        top != null &&
        top['role'] == 'assistant' &&
        (top['_pipeline'] == true ||
            ((top['content'] as String?) ?? '').trim().isEmpty);
    final visibleChronological = messages.reversed.toList(growable: false);
    final endsInToolInvocationWithoutFinal =
        expectedUsers > 0 &&
        _turnAwaitsFinalAfterToolInvocation(
          visibleChronological,
          expectedUsers,
        ) &&
        !_containsDurableFinalAssistantTurn(
          visibleChronological,
          expectedUsers,
        );
    if (!looksUnfinished && !endsInToolInvocationWithoutFinal) return false;

    // Cerrar/reabrir durante una herramienta puede dejar la proyección local
    // terminada en `tool` justo antes de que Hermes publique el assistant
    // final. Una lectura REST aislada solo ve ese corte y no vuelve a enlazar
    // los eventos del runtime. Repite el mismo lifecycle autoritativo que usa
    // Actualizar: si el turno sigue vivo restaura el WebSocket; si ya terminó
    // adopta el transcript final sin borrar el fallback visible.
    if (endsInToolInvocationWithoutFinal &&
        _desktopGateway is HermesDesktopSessionLifecycleGateway) {
      final previousMessages = messages
          .map(Map<String, dynamic>.from)
          .toList(growable: false);
      final previousState = state;
      // `loadMessages` incrementa este epoch síncronamente antes de su primer
      // await. Stop, send y cualquier refresh posterior vuelven a avanzarlo.
      final lifecycleLoadEpoch = _messageLoadEpoch + 1;
      try {
        await loadMessages(
          expectedMessageCount: math.max(messages.length, expectedUsers),
          profile: _storedSessionProfile,
        );
        if (_disposed || lifecycleLoadEpoch != _messageLoadEpoch) return false;
        final changed =
            previousState != state ||
            !_sameTranscriptProjection(previousMessages, messages);
        final refreshedChronological = messages.reversed.toList(
          growable: false,
        );
        final stillMissingFinal =
            !isStreaming &&
            expectedUsers > 0 &&
            _turnAwaitsFinalAfterToolInvocation(
              refreshedChronological,
              expectedUsers,
            ) &&
            !_containsDurableFinalAssistantTurn(
              refreshedChronological,
              expectedUsers,
            );
        if (stillMissingFinal) {
          _scheduleTerminalTranscriptRecovery(
            _turnEpoch,
            messageLoadEpoch: _messageLoadEpoch,
            requireAssistantText: true,
          );
        }
        return changed;
      } catch (error) {
        if (_disposed || lifecycleLoadEpoch != _messageLoadEpoch) return false;
        debugPrint(
          '[active-chat] resume lifecycle reconciliation unavailable '
          '(${error.runtimeType})',
        );
        // Conserva el fallback y prueba debajo la lectura REST acotada.
      }
    }
    final loadEpoch = ++_messageLoadEpoch;
    final turnEpoch = _turnEpoch;
    try {
      // Instancia LOCAL: no hay historial remoto que re-sincronizar; recupera
      // lo persistido localmente (el bridge no expone /api/sessions/.../messages).
      final List<Map<String, dynamic>> m;
      if (connection.kind == InstanceKind.localhost) {
        m = await LocalTranscriptStore.load(connection.id, sessionId);
      } else {
        m = await _loadStoredMessages(_storedSessionProfile);
      }
      if (_disposed ||
          loadEpoch != _messageLoadEpoch ||
          turnEpoch != _turnEpoch ||
          isStreaming) {
        return false;
      }
      // El endpoint puede ir por detrás del stream justo al volver del fondo.
      // Un [] o el turno anterior no son autoridad suficiente para borrar la
      // burbuja/scrollback local que el usuario ya estaba viendo.
      if (!_containsCompletedTurn(m, expectedUsers)) return false;
      final awaitsToolFinal = _turnAwaitsFinalAfterToolInvocation(
        m,
        expectedUsers,
      );
      if (awaitsToolFinal &&
          !_containsDurableFinalAssistantTurn(m, expectedUsers)) {
        _scheduleTerminalTranscriptRecovery(
          turnEpoch,
          messageLoadEpoch: loadEpoch,
          requireAssistantText: true,
        );
        return false;
      }
      _captureArtifactMaps(m, logicalSessionId: logicalSessionId);
      messages = _applyCancelledTurnTombstones(
        _normalizedNewestFirst(m),
        incomingTranscriptComplete: true,
      );
      _markTranscriptComplete(visibleCount: messages.length);
      _reconcileSubagentsFromTranscript();
      if (state != ChatPipelineState.failed) {
        state = ChatPipelineState.completed;
      }
      traceActive = false;
      _emit(ActiveChatEvent.done);
      return true;
    } catch (e) {
      debugPrint(
        '[active-chat] resume reconciliation unavailable '
        '(${e.runtimeType})',
      );
      return false;
    }
  }

  /// Coalescing visual equivalente a Desktop: publica deltas a 30 Hz para no
  /// reconstruir Markdown por token. Android añade una adaptación acotada para
  /// ráfagas grandes, porque algunos transportes móviles entregan varios deltas
  /// juntos aunque Desktop los recibiese separados.
  void _ensureTokenFlush() {
    if (_tokenFlushTimer != null && _tokenFlushTimer!.isActive) return;
    final cadence = _desktopStreamCadence;
    _tokenFlushTimer = Timer.periodic(cadence, (t) {
      final pending = _tokenBuffer.toString();
      if (pending.isEmpty) {
        t.cancel();
        _tokenFlushTimer = null;
        return;
      }
      // Igual que Hermes Desktop: limita la frecuencia de repintado, no vuelve
      // a trocear el texto recibido. Inventar frames de 1–6 unidades UTF-16
      // exponía media palabra, marcadores Markdown y grafemas incompletos que
      // nunca habían existido como deltas del Gateway.
      _publishTokenChunk(pending, pending.length);
    });
  }

  void _publishTokenChunk(String pending, int take) {
    _tokenBuffer.clear();
    if (take < pending.length) _tokenBuffer.write(pending.substring(take));
    final chunk = pending.substring(0, take);
    state = ChatPipelineState.streaming;
    if (messages.isNotEmpty && messages[0]['role'] == 'assistant') {
      messages[0] = {
        ...messages[0],
        'content': ((messages[0]['content'] as String?) ?? '') + chunk,
        '_pipeline': false,
      };
    }
    _emit(ActiveChatEvent.token);
  }

  void _enqueueToken(String token, {bool narratable = true}) {
    if (token.isEmpty) return;
    _observeFirstResponseContent(token);
    if (narratable) _assistantNarration.appendDelta(token);
    _tokenBuffer.write(token);
    if (_immediateStreaming) {
      _flushTokenBuffer();
      state = ChatPipelineState.streaming;
      _emit(ActiveChatEvent.token);
    } else {
      _ensureTokenFlush();
    }
  }

  /// Convierte el sufijo autoritativo todavía invisible en la misma cola
  /// visual. Así el terminal no sustituye de golpe una respuesta que el
  /// transporte entregó coalescida.
  void _queueAuthoritativeFinalTail(String? finalOutput) {
    if (finalOutput == null ||
        messages.isEmpty ||
        messages[0]['role'] != 'assistant') {
      return;
    }
    final visible = (messages[0]['content'] as String?) ?? '';
    if (!finalOutput.startsWith(visible)) return;
    _tokenBuffer
      ..clear()
      ..write(finalOutput.substring(visible.length));
  }

  void _publishBufferedTokenBatch() {
    if (_tokenBuffer.isEmpty) return;
    _tokenFlushTimer?.cancel();
    _tokenFlushTimer = null;
    final pending = _tokenBuffer.toString();
    _publishTokenChunk(pending, pending.length);
  }

  void _flushTokenBuffer() {
    _tokenFlushTimer?.cancel();
    _tokenFlushTimer = null;
    if (_tokenBuffer.isEmpty) return;
    final accumulated = _tokenBuffer.toString();
    _tokenBuffer.clear();
    if (messages.isNotEmpty && messages[0]['role'] == 'assistant') {
      messages[0] = {
        ...messages[0],
        'content': ((messages[0]['content'] as String?) ?? '') + accumulated,
        '_pipeline': false,
      };
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _messageLoadEpoch++;
    if (!_turnEpochInvalidated.isCompleted) {
      _turnEpochInvalidated.complete();
    }
    _turnEpoch++;
    if (!_disposeSignal.isCompleted) _disposeSignal.complete();
    _firstTokenTimer?.cancel();
    _voiceBargeHandoffTimer?.cancel();
    _voiceBargeHandoffTimer = null;
    _voiceBargeHandoffPending = false;
    _tokenFlushTimer?.cancel();
    _terminalTimer?.cancel();
    _desktopEventSubscription?.cancel();
    _interactivePrompts = InteractivePromptReducer.reduce(
      _interactivePrompts,
      const InteractivePromptDisposed(),
    );
    _retireDesktopRuntime();
    unawaited(_desktopGateway?.close());
    _api.close();
    _changes.close();
  }
}
