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
import 'tui_gateway_client.dart';
import 'turn_outbox_store.dart';

/// Hermes Desktop espera hasta cinco segundos a que el turno interrumpido deje
/// de estar busy antes de entregar la corrección capturada por barge-in.
@visibleForTesting
const activeChatVoiceBargeSettleTimeout = Duration(seconds: 5);

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

/// Identidad para deduplicar filas del transcript entre páginas: el row id
/// durable cuando el servidor lo envía; si no, una huella de contenido.
Object _transcriptMessageKey(Map<String, dynamic> message) {
  final id = message['id'] ?? message['message_id'];
  if (id != null) return 'id:\u0000$id';
  return 'fp:\u0000${message['role']}\u0000${message['content'] ?? message['text']}\u0000${message['timestamp']}';
}

/// Antepone una página de mensajes ANTERIORES a la lista viva (newest-first:
/// los más antiguos van al final), deduplicando filas ya presentes. El drift
/// de offsets (mensajes persistidos tras la hidratación) hace normal el
/// solape; conserva la identidad de referencia cuando no cambia nada.
List<Map<String, dynamic>> _mergeOlderTranscriptPage(
  List<Map<String, dynamic>> existingNewestFirst,
  List<Map<String, dynamic>> olderPageNewestFirst,
) {
  if (existingNewestFirst.isEmpty || olderPageNewestFirst.isEmpty) {
    return existingNewestFirst;
  }
  final seen = <Object>{
    for (final message in existingNewestFirst) _transcriptMessageKey(message),
  };
  final fresh = olderPageNewestFirst
      .where((message) => seen.add(_transcriptMessageKey(message)))
      .toList(growable: false);
  if (fresh.isEmpty) return existingNewestFirst;
  return <Map<String, dynamic>>[...existingNewestFirst, ...fresh];
}

@immutable
class CancelledTurnTombstone {
  const CancelledTurnTombstone({
    required this.content,
    this.anchorMessageId,
    this.firstUser = false,
    this.createdAtMs,
  });

  final String content;
  final String? anchorMessageId;
  final bool firstUser;
  final int? createdAtMs;

  bool matchesContent(String candidate) => content == candidate;

  CancelledTurnTombstone stamped(int timestampMs) => CancelledTurnTombstone(
    content: content,
    anchorMessageId: anchorMessageId,
    firstUser: firstUser,
    createdAtMs: createdAtMs ?? timestampMs,
  );

  Map<String, dynamic> toJson() => {
    'content': content,
    'anchor_message_id': anchorMessageId,
    'first_user': firstUser,
    'created_at_ms': createdAtMs,
  };

  static CancelledTurnTombstone? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final content = raw['content'];
    final anchor = raw['anchor_message_id'];
    final firstUser = raw['first_user'];
    final createdAtMs = raw['created_at_ms'];
    final normalizedAnchor = anchor is String && anchor.trim().isNotEmpty
        ? anchor.trim()
        : null;
    if (content is! String ||
        content.isEmpty ||
        firstUser is! bool ||
        (normalizedAnchor == null && !firstUser) ||
        (normalizedAnchor != null && firstUser) ||
        createdAtMs is! int ||
        createdAtMs < 0) {
      return null;
    }
    return CancelledTurnTombstone(
      content: content,
      anchorMessageId: normalizedAnchor,
      firstUser: firstUser,
      createdAtMs: createdAtMs,
    );
  }
}

String? _stableTranscriptMessageId(Map<String, dynamic> message) {
  final raw = message['message_id'] ?? message['id'];
  final value = raw?.toString().trim() ?? '';
  return value.isEmpty ? null : value;
}

class CancelledTurnTombstoneStore {
  CancelledTurnTombstoneStore({
    required Future<String?> Function() read,
    required Future<void> Function(String value) write,
    int Function()? nowMs,
  }) : _read = read,
       _write = write,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  factory CancelledTurnTombstoneStore.secure({
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
  }) => CancelledTurnTombstoneStore(
    read: () => secureStorage.read(key: _storageKey),
    write: (value) => secureStorage.write(key: _storageKey, value: value),
  );

  static const _storageKey = 'cancelled_turn_tombstones_v2';

  final Future<String?> Function() _read;
  final Future<void> Function(String value) _write;
  final int Function() _nowMs;
  Future<void> _writeTail = Future<void>.value();
  Map<String, dynamic> _root = <String, dynamic>{};
  bool _initialized = false;

  String _scopeKey({
    required String connectionId,
    required String profile,
    required String sessionId,
    String generation = '',
  }) => jsonEncode([connectionId, generation, profile, sessionId]);

  Future<void> initialize() async {
    if (_initialized) return;
    final raw = await _read();
    final decoded = raw == null || raw.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('invalid cancelled-turn tombstone root');
    }
    final candidate = Map<String, dynamic>.from(decoded);
    for (final entry in candidate.entries) {
      final value = entry.value;
      if (value is! List ||
          value.any((item) => CancelledTurnTombstone.fromJson(item) == null)) {
        throw FormatException(
          'invalid cancelled-turn tombstone scope ${entry.key}',
        );
      }
    }
    _root = candidate;
    _initialized = true;
  }

  List<CancelledTurnTombstone> load({
    required String connectionId,
    required String profile,
    required String sessionId,
    String generation = '',
  }) {
    if (!_initialized) {
      throw StateError('cancelled-turn tombstone store not initialized');
    }
    final raw =
        _root[_scopeKey(
          connectionId: connectionId,
          profile: profile,
          sessionId: sessionId,
          generation: generation,
        )];
    if (raw is! List) return const [];
    return raw
        .map(CancelledTurnTombstone.fromJson)
        .whereType<CancelledTurnTombstone>()
        .toList(growable: false);
  }

  Future<void> add({
    required String connectionId,
    required String profile,
    required String sessionId,
    required CancelledTurnTombstone tombstone,
    String generation = '',
  }) {
    final operation = _writeTail.then((_) async {
      if (!_initialized) await initialize();
      final candidate = Map<String, dynamic>.from(_root);
      final scope = _scopeKey(
        connectionId: connectionId,
        profile: profile,
        sessionId: sessionId,
        generation: generation,
      );
      final current = candidate[scope] is List
          ? List<Object?>.from(candidate[scope] as List)
          : <Object?>[];
      final durable = tombstone.stamped(_nowMs());
      current.removeWhere((raw) {
        final item = CancelledTurnTombstone.fromJson(raw);
        return item != null &&
            item.content == durable.content &&
            item.anchorMessageId == durable.anchorMessageId &&
            item.firstUser == durable.firstUser;
      });
      current.add(durable.toJson());
      candidate[scope] = current;
      await _write(jsonEncode(candidate));
      _root = candidate;
    });
    _writeTail = operation.catchError((_) {});
    return operation;
  }

  Future<int> removeSession({
    required String connectionId,
    required String profile,
    required String sessionId,
  }) => _removeScopes((scope) {
    try {
      final parts = jsonDecode(scope);
      return parts is List &&
          parts.length == 4 &&
          parts[0] == connectionId &&
          parts[2] == profile &&
          parts[3] == sessionId;
    } catch (_) {
      return false;
    }
  });

  Future<int> removeConnection(String connectionId) => _removeScopes((scope) {
    try {
      final parts = jsonDecode(scope);
      return parts is List && parts.isNotEmpty && parts.first == connectionId;
    } catch (_) {
      return false;
    }
  });

  Future<int> _removeScopes(bool Function(String scope) matches) {
    var removed = 0;
    final operation = _writeTail.then((_) async {
      if (!_initialized) await initialize();
      final candidate = Map<String, dynamic>.from(_root);
      for (final scope in candidate.keys.toList(growable: false)) {
        if (!matches(scope)) continue;
        final value = candidate.remove(scope);
        if (value is List) removed += value.length;
      }
      if (removed == 0) return;
      await _write(jsonEncode(candidate));
      _root = candidate;
    });
    _writeTail = operation.catchError((_) {});
    return operation.then((_) => removed);
  }
}

/// Reaplica los tombstones locales de Stop sobre un transcript canónico.
///
/// Las listas están en orden newest-first. Para cada usuario detenido elimina
/// exclusivamente el bloque de respuesta situado entre ese usuario y el turno
/// de usuario posterior; así una respuesta que el servidor terminó mientras el
/// móvil estaba offline no reaparece al reconciliar, sin tocar turnos nuevos.
@visibleForTesting
List<Map<String, dynamic>> projectCancelledTurnTombstones({
  required List<Map<String, dynamic>> existingNewestFirst,
  required List<Map<String, dynamic>> incomingNewestFirst,
  List<CancelledTurnTombstone> durableTombstones = const [],
}) {
  if (durableTombstones.isEmpty) return incomingNewestFirst;

  for (final tombstone in durableTombstones) {
    final anchor = tombstone.anchorMessageId;
    final anchorPresent =
        anchor == null ||
        incomingNewestFirst.any(
          (message) => _stableTranscriptMessageId(message) == anchor,
        );
    final firstUserPresent =
        !tombstone.firstUser || incomingNewestFirst.any(isRealUserTurn);
    if (!anchorPresent || !firstUserPresent) {
      // Snapshot/compresión parcial: conservar la proyección ya saneada es más
      // seguro que reintroducir una respuesta cuyo ancla aún no llegó.
      return existingNewestFirst;
    }
  }

  final projected = incomingNewestFirst
      .map((message) => Map<String, dynamic>.of(message))
      .toList();
  for (final tombstone in durableTombstones) {
    var userIndex = -1;
    if (tombstone.firstUser) {
      for (var index = projected.length - 1; index >= 0; index--) {
        if (!isRealUserTurn(projected[index])) continue;
        if (tombstone.matchesContent(
          (projected[index]['content'] ?? '').toString(),
        )) {
          userIndex = index;
        }
        break;
      }
    } else {
      final anchorId = tombstone.anchorMessageId;
      final anchorIndex = anchorId == null
          ? -1
          : projected.indexWhere(
              (message) => _stableTranscriptMessageId(message) == anchorId,
            );
      if (anchorIndex >= 0) {
        for (var index = anchorIndex - 1; index >= 0; index--) {
          if (!isRealUserTurn(projected[index])) continue;
          if (tombstone.matchesContent(
            (projected[index]['content'] ?? '').toString(),
          )) {
            userIndex = index;
          }
          break;
        }
      }
    }
    if (userIndex < 0) continue;

    var newerUserIndex = -1;
    for (var index = userIndex - 1; index >= 0; index--) {
      if (isRealUserTurn(projected[index])) {
        newerUserIndex = index;
        break;
      }
    }
    final responseStart = newerUserIndex + 1;
    if (responseStart < userIndex) {
      final preservedMetadata = projected
          .sublist(responseStart, userIndex)
          .where((message) => message['role'] != 'assistant')
          .toList(growable: false);
      projected.replaceRange(responseStart, userIndex, preservedMetadata);
      userIndex = responseStart + preservedMetadata.length;
    }
    projected[userIndex] = {...projected[userIndex], '_cancelledUser': true};
  }
  return projected;
}

String _artifactEntryIdentity(String? stableId, int ordinal) =>
    stableId == null ? 'ordinal:$ordinal' : 'message:$stableId';

bool _sameArtifactTranscript(
  List<ArtifactTranscriptEntry> current,
  List<ArtifactTranscriptEntry> previous,
) {
  for (var index = 0; index < current.length; index++) {
    final candidate = current[index];
    final prior = previous[index];
    if (candidate.messageOrdinal != prior.messageOrdinal ||
        candidate.stableMessageId != prior.stableMessageId ||
        !_sameArtifactMessage(candidate.message, prior.message)) {
      return false;
    }
  }
  return true;
}

bool _sameArtifactMessage(
  DesktopSessionMessage left,
  DesktopSessionMessage right,
) =>
    left.stableId == right.stableId &&
    left.role == right.role &&
    _artifactValueEquals(left.content, right.content) &&
    _artifactValueEquals(left.context, right.context) &&
    _artifactValueEquals(left.artifactContainers, right.artifactContainers);

bool _artifactValueEquals(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_artifactValueEquals(left[index], right[index])) return false;
    }
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_artifactValueEquals(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  return left == right;
}

/// Propietario de la evidencia local mientras un turno vive fuera de la ruta.
/// La escritura `submitting` siempre termina antes de tocar el transporte; un
/// fallo ahí bloquea el request. Un corte posterior queda ambiguo y nunca se
/// degrada a «no enviado».
class ActiveTurnDelivery {
  ActiveTurnDelivery({
    required PreparedTurn prepared,
    required TurnOutboxPersistence store,
    int Function()? nowMs,
    ValueChanged<List<AttachmentDraft>>? onAttachmentsChanged,
  }) : _current = prepared,
       _store = store,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch) {
    if (onAttachmentsChanged != null) {
      _attachmentListeners.add(onAttachmentsChanged);
    }
    // Al reconstruir una entrega desde la outbox también hay que reconstruir
    // sus fronteras internas. De lo contrario un accepted/running restaurado
    // recibe el terminal real, pero se niega a borrarse porque el nuevo objeto
    // olvidó que ya existía ACK antes del process death.
    _transportStarted = switch (prepared.state) {
      PreparedTurnState.prepared ||
      PreparedTurnState.failedBeforeAcceptance => false,
      PreparedTurnState.submitting ||
      PreparedTurnState.accepted ||
      PreparedTurnState.running ||
      PreparedTurnState.ambiguous ||
      PreparedTurnState.terminal => true,
    };
    _acknowledged = switch (prepared.state) {
      PreparedTurnState.accepted ||
      PreparedTurnState.running ||
      PreparedTurnState.terminal => true,
      PreparedTurnState.prepared ||
      PreparedTurnState.submitting ||
      PreparedTurnState.ambiguous ||
      PreparedTurnState.failedBeforeAcceptance => false,
    };
  }

  final TurnOutboxPersistence _store;
  final int Function() _nowMs;
  final Set<ValueChanged<List<AttachmentDraft>>> _attachmentListeners = {};
  PreparedTurn _current;
  bool _transportStarted = false;
  bool _acknowledged = false;
  bool _persistenceFailed = false;
  Future<void> _mutationTail = Future<void>.value();

  PreparedTurn get current => _current;
  bool get transportStarted => _transportStarted;
  bool get acknowledged => _acknowledged;
  bool get persistenceFailed => _persistenceFailed;

  Future<bool> persistPrepared() => _serializeMutation(() async {
    if (_transportStarted || _acknowledged) return false;
    try {
      await _store.save(_current);
      return true;
    } catch (_) {
      _persistenceFailed = true;
      return false;
    }
  });

  Future<bool> discardPrepared() => _serializeMutation(() async {
    if (_transportStarted || _acknowledged) return false;
    try {
      await _store.delete(_current);
      return true;
    } catch (_) {
      _persistenceFailed = true;
      return false;
    }
  });

  void addAttachmentListener(
    ValueChanged<List<AttachmentDraft>> listener, {
    bool notifyImmediately = false,
  }) {
    _attachmentListeners.add(listener);
    if (notifyImmediately) {
      listener(List<AttachmentDraft>.unmodifiable(_current.attachments));
    }
  }

  void removeAttachmentListener(ValueChanged<List<AttachmentDraft>> listener) {
    _attachmentListeners.remove(listener);
  }

  Future<T> _serializeMutation<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _mutationTail = _mutationTail.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  void _notifyAttachments() {
    final snapshot = List<AttachmentDraft>.unmodifiable(_current.attachments);
    for (final listener in _attachmentListeners.toList(growable: false)) {
      try {
        listener(snapshot);
      } catch (_) {
        // La proyección visual nunca gobierna la evidencia persistida.
      }
    }
  }

  int _attachmentIndex(String localId) =>
      _current.attachments.indexWhere((item) => item.localId == localId);

  PreparedTurn _withAttachment(int index, AttachmentDraft attachment) {
    final nextAttachments = List<AttachmentDraft>.of(_current.attachments);
    nextAttachments[index] = attachment;
    return _current.copyWith(
      updatedAtMs: _nowMs(),
      attachments: nextAttachments,
    );
  }

  Future<bool> beginTransport(PreparedTurnTransport transport) =>
      _serializeMutation(() async {
        if (_transportStarted) return true;
        final next = _current.copyWith(
          updatedAtMs: _nowMs(),
          transport: transport,
          state: PreparedTurnState.submitting,
        );
        try {
          await _store.save(next);
          _current = next;
          _transportStarted = true;
          return true;
        } catch (_) {
          _persistenceFailed = true;
          return false;
        }
      });

  Future<AttachmentDraft?> beginAttachmentUpload(
    String localId, {
    required String remoteSessionId,
    required AttachmentRemoteTransport transport,
  }) => _serializeMutation(() async {
    final index = _attachmentIndex(localId);
    if (index < 0) return null;
    final current = _current.attachments[index];
    if (current.uploadState == AttachmentUploadState.removed) return null;
    final rebound = current.resetForRemoteOwner(
      remoteSessionId: remoteSessionId,
      transport: transport,
    );
    if (rebound.isAttachedTo(remoteSessionId, transport: transport)) {
      return rebound;
    }
    if (rebound.uploadState == AttachmentUploadState.uploading &&
        rebound.remoteSessionId == remoteSessionId &&
        rebound.remoteTransport == transport) {
      return rebound;
    }
    final uploading = rebound.copyWith(
      uploadState: AttachmentUploadState.uploading,
      attempt: rebound.attempt + 1,
      errorKind: null,
      remoteRef: null,
      remoteSessionId: remoteSessionId,
      remoteTransport: transport,
    );
    final next = _withAttachment(index, uploading);
    try {
      await _store.save(next);
      _current = next;
      _notifyAttachments();
      return uploading;
    } catch (_) {
      _persistenceFailed = true;
      return null;
    }
  });

  Future<bool> markAttachmentAttached(
    String localId, {
    required int attempt,
    required String remoteSessionId,
    required AttachmentRemoteTransport transport,
    required String remoteRef,
  }) => _serializeMutation(() async {
    if (remoteRef.isEmpty) return false;
    final index = _attachmentIndex(localId);
    if (index < 0) return false;
    final current = _current.attachments[index];
    if (!current.acceptsCallback(localId: localId, attempt: attempt) ||
        current.remoteSessionId != remoteSessionId ||
        current.remoteTransport != transport) {
      return false;
    }
    final attached = current.copyWith(
      uploadState: AttachmentUploadState.attached,
      errorKind: null,
      remoteRef: remoteRef,
    );
    final next = _withAttachment(index, attached);
    try {
      await _store.save(next);
      _current = next;
      _notifyAttachments();
      return true;
    } catch (_) {
      _persistenceFailed = true;
      // El caller revoca la asociación remota. No conservar en memoria una ref
      // que ya fue detached: un retry en este mismo proceso debe subir de nuevo.
      final failed = current.copyWith(
        uploadState: AttachmentUploadState.error,
        errorKind: AttachmentErrorKind.persistence,
        remoteRef: null,
      );
      _current = _withAttachment(index, failed);
      _notifyAttachments();
      return false;
    }
  });

  Future<bool> markAttachmentFailed(
    String localId, {
    required int attempt,
    required AttachmentErrorKind errorKind,
  }) => _serializeMutation(() async {
    final index = _attachmentIndex(localId);
    if (index < 0) return false;
    final current = _current.attachments[index];
    if (!current.acceptsCallback(localId: localId, attempt: attempt)) {
      return false;
    }
    final failed = current.copyWith(
      uploadState: AttachmentUploadState.error,
      errorKind: errorKind,
      remoteRef: null,
    );
    final next = _withAttachment(index, failed);
    _current = next;
    _notifyAttachments();
    try {
      await _store.save(next);
      return true;
    } catch (_) {
      _persistenceFailed = true;
      return false;
    }
  });

  /// Persiste primero el tombstone. Devuelve el item previo para que el owner
  /// del transporte pueda ejecutar un detach best-effort si existe.
  Future<AttachmentDraft?> removeAttachment(String localId) =>
      _serializeMutation(() async {
        final index = _attachmentIndex(localId);
        if (index < 0) return null;
        final current = _current.attachments[index];
        if (current.uploadState == AttachmentUploadState.removed) return null;
        final removed = current.copyWith(
          uploadState: AttachmentUploadState.removed,
          attempt: current.attempt + 1,
          errorKind: null,
        );
        final next = _withAttachment(index, removed);
        _current = next;
        _notifyAttachments();
        try {
          await _store.save(next);
        } catch (_) {
          _persistenceFailed = true;
        }
        return current;
      });

  Future<bool> retryAttachment(String localId) => _serializeMutation(() async {
    final index = _attachmentIndex(localId);
    if (index < 0) return false;
    final current = _current.attachments[index];
    if (current.uploadState != AttachmentUploadState.error) return false;
    final pending = current.copyWith(
      uploadState: AttachmentUploadState.pending,
      errorKind: null,
      remoteRef: null,
      remoteSessionId: null,
      remoteTransport: null,
    );
    final next = _withAttachment(index, pending);
    _current = next;
    _notifyAttachments();
    try {
      await _store.save(next);
      return true;
    } catch (_) {
      _persistenceFailed = true;
      return false;
    }
  });

  Future<void> waitForAttachmentMutations() => _mutationTail;

  Future<void> markAccepted() => _serializeMutation(() async {
    _acknowledged = true;
    final next = _current.copyWith(
      updatedAtMs: _nowMs(),
      state: PreparedTurnState.accepted,
    );
    _current = next;
    try {
      await _store.save(next);
    } catch (_) {
      // El ACK es verdad aunque Keystore falle. La UI no debe ofrecer este lote
      // como no enviado ni volver a tocar el transporte.
      _persistenceFailed = true;
    }
  });

  Future<void> markRunning() => _serializeMutation(() async {
    if (!_acknowledged || _current.state == PreparedTurnState.running) return;
    final next = _current.copyWith(
      updatedAtMs: _nowMs(),
      state: PreparedTurnState.running,
    );
    _current = next;
    try {
      await _store.save(next);
    } catch (_) {
      _persistenceFailed = true;
    }
  });

  Future<void> markTerminalAndDelete() => _serializeMutation(() async {
    if (!_acknowledged) return;
    final next = _current.copyWith(
      updatedAtMs: _nowMs(),
      state: PreparedTurnState.terminal,
    );
    _current = next;
    try {
      await _store.save(next);
      await _store.delete(next);
    } catch (_) {
      _persistenceFailed = true;
    }
  });

  Future<void> markUnaccepted() => _serializeMutation(() async {
    if (_acknowledged) return;
    final next = _current.copyWith(
      updatedAtMs: _nowMs(),
      state: _transportStarted
          ? PreparedTurnState.ambiguous
          : PreparedTurnState.failedBeforeAcceptance,
    );
    _current = next;
    try {
      await _store.save(next);
    } catch (_) {
      _persistenceFailed = true;
    }
  });
}

class QueuedPreparedTurn {
  const QueuedPreparedTurn(this.delivery, {required this.queueOrder});

  final ActiveTurnDelivery delivery;
  final int queueOrder;
  PreparedTurn get turn => delivery.current;
}

class _QueuedTextTurn {
  const _QueuedTextTurn(this.text, this.queueOrder);

  final String text;
  final int queueOrder;
}

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

class _RewriteReservation {
  _RewriteReservation({
    required this.transcriptRevision,
    required this.turnEpoch,
    required this.runtimeSessionId,
  });

  int transcriptRevision;
  int turnEpoch;
  String? runtimeSessionId;
  bool transportStarted = false;
}

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
  int _messageLoadEpoch = 0;
  int _desktopBindEpoch = 0;
  int _desktopInterimSerial = 0;
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

  /// El usuario ya cargó páginas anteriores: un refresh de la cola debe
  /// injertarse sobre ese prefijo en vez de clobberarlo.
  bool _hasBackfilledPrefix = false;

  /// Resume diferido (Hermes Agent 0.20, upstream 60be8ef26): el ack de
  /// `session.resume` llega con `hydrating:true` y el historial se carga en
  /// segundo plano; `session.resume_progress` anuncia el desenlace.
  bool _desktopHistoryHydrating = false;
  bool? _desktopHydrationOutcome;
  Completer<bool>? _desktopHydrationWaiter;

  /// Quedan mensajes anteriores en el servidor más allá de lo ya cargado.
  bool get hasEarlierMessages => _earlierMessagesAvailable;

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
  }

  @visibleForTesting
  bool get storedSessionKnownMissing => _desktopStoredSessionKnownMissing;

  /// Stream de cambios. La pantalla se suscribe para re-renderizar; al cerrarse
  /// cancela la suscripción SIN cancelar el stream del agente.
  Stream<ActiveChatEvent> get changes => _changes.stream;

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
    _cancelledTurnTombstones.clear();
    for (var index = 0; index < messages.length; index++) {
      if (messages[index]['_cancelledUser'] != true) continue;
      final cleaned = Map<String, dynamic>.of(messages[index])
        ..remove('_cancelledUser');
      messages[index] = cleaned;
    }
  }

  bool get hasPendingDurableCancellation =>
      _cancelledTurnPersistencePending ||
      _cancelledTurnPersistenceFailed ||
      _durableCancelFlight != null;

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
    List<Map<String, dynamic>> incoming,
  ) => projectCancelledTurnTombstones(
    existingNewestFirst: messages,
    incomingNewestFirst: incoming,
    durableTombstones: _cancelledTurnTombstones,
  );

  /// Carga el historial (lectura). No toca el stream.
  ///
  /// Instancia LOCAL (bridge): el agente oneshot no conserva el historial
  /// server-side, así que `getMessages` daría vacío. Reconstruimos el chat
  /// desde el transcript persistido localmente ([LocalTranscriptStore]).
  Future<void> loadMessages({
    int? expectedMessageCount,
    String profile = '',
  }) async {
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
      messages = _applyCancelledTurnTombstones(_normalizedNewestFirst(saved));
      messagesLoaded = true;
      return;
    }

    if (gateway != null && lifecycleGateway != null) {
      _listenToDesktopGateway(gateway);

      // Hermes Desktop no serializa estas dos lecturas. El transcript REST y
      // session.resume son independientes: REST puede pintar el historial
      // mientras el RPC termina de enlazar el runtime (MCP/prompt incluidos).
      // Capturamos los errores dentro de cada Future para que una rama que
      // falle pronto nunca se publique como error asíncrono no gestionado.
      ({Object? error, List<Map<String, dynamic>>? value})?
      prefetchCompletedBeforeResume;
      final prefetchFuture =
          _captureAsync<List<Map<String, dynamic>>>(
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
        final prefetched = prefetchCompletedBeforeResume?.value;
        final hasAuthoritativePrefetch =
            prefetched != null &&
            (prefetched.isNotEmpty || expectedMessageCount == 0);
        return lifecycleGateway.resumeExisting(
          serverSessionId,
          profile: _storedSessionProfile,
          // Desktop omite el transcript porque su repositorio local ya lo
          // posee. Android solo puede hacer lo mismo si REST terminó antes de
          // enlazar el runtime. Si REST sigue pendiente, falló o devolvió un
          // vacío inesperado, pedimos el snapshot completo sin retrasar resume.
          omitMessages: hasAuthoritativePrefetch,
          // Hermes Agent 0.20: ack inmediato e hidratación del historial en
          // segundo plano (`session.resume_progress`). Un gateway antiguo
          // ignora el parámetro y responde como siempre (sin `hydrating`).
          deferHistory: true,
        );
      });

      List<Map<String, dynamic>>? prefetchedNewestFirst;
      DesktopSessionSnapshot? resumedSnapshot;
      Object? prefetchError;
      Object? resumeError;

      void publishMessages(List<Map<String, dynamic>> next) {
        if (_disposed || loadEpoch != _messageLoadEpoch) return;
        messages = _applyCancelledTurnTombstones(
          _associateGeneratedImagesNewestFirst(
            _preserveLocalAssistantErrors(next, messages),
          ),
        );
        _mergeSteerRecords();
        messagesLoaded = true;
        _emit(ActiveChatEvent.messagesHydrated);
      }

      void publishSnapshot(DesktopSessionSnapshot snapshot) {
        if (_disposed || loadEpoch != _messageLoadEpoch) return;
        // Ack diferido de Hermes Agent 0.20: el historial llega en segundo
        // plano; un ack nuevo reinicia el desenlace registrado.
        _desktopHistoryHydrating = snapshot.hydrating;
        if (snapshot.hydrating) _desktopHydrationOutcome = null;
        final rawFallback = prefetchedNewestFirst?.isNotEmpty == true
            ? prefetchedNewestFirst!
            : messages;
        final preferFallback =
            prefetchedNewestFirst?.isNotEmpty == true ||
            (snapshot.messages.isEmpty && rawFallback.isNotEmpty);
        const reconciler = DesktopSessionReconciler();
        final fallback = preferFallback && snapshot.messagesProvided
            ? reconciler.overlayDurableDisplayMetadata(
                rawFallback,
                snapshot.messages,
              )
            : rawFallback;
        final projectionSource = preferFallback
            ? _withoutPersistedMessages(snapshot)
            : snapshot;
        if (!preferFallback && snapshot.messagesProvided) {
          _captureArtifactMessages(
            snapshot.messages,
            logicalSessionId: logicalSessionId,
          );
        }
        final projection = reconciler.project(
          projectionSource,
          fallbackNewestFirst: fallback,
        );
        final projected = projection.messagesNewestFirst
            .map(Map<String, dynamic>.from)
            .toList(growable: true);
        final expectsTranscript =
            (expectedMessageCount ?? 0) > 0 || (snapshot.messageCount ?? 0) > 0;
        if (projected.isNotEmpty || !expectsTranscript) {
          publishMessages(projected);
        }
        _desktopStoredSessionId = snapshot.storedSessionId;
        _adoptDesktopRuntime(snapshot.runtimeSessionId, info: snapshot.info);
        _restorePendingClarify(snapshot);
        _desktopStoredSessionKnownMissing = false;
        _desktopRuntimeInfo = snapshot.info;
        _rememberDesktopLiveStatus(
          projection.status,
          running: projection.running,
        );
        _desktopStartedAt = snapshot.startedAt;
        _desktopTurnStartedAt = projection.running
            ? snapshot.inflight?.startedAt
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
        if (prefetch.value case final chronological?) {
          _captureArtifactMaps(
            chronological,
            logicalSessionId: logicalSessionId,
          );
          final normalized = _graftRefreshedTail(
            _normalizedNewestFirst(chronological),
            messages,
          );
          if (normalized.isNotEmpty) {
            prefetchedNewestFirst = _preserveLocalAssistantErrors(
              normalized,
              messages,
            );
            final snapshot = resumedSnapshot;
            if (snapshot == null) {
              publishMessages(prefetchedNewestFirst!);
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
              final deferred = await _loadStoredMessagesTail(
                _storedSessionProfile,
              );
              if (_disposed || loadEpoch != _messageLoadEpoch) return;
              if (deferred.isNotEmpty) {
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
                );
                _mergeSteerRecords();
                messagesLoaded = true;
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
        messagesLoaded = true;
        return;
      }
      if (capturedResumeError is TuiGatewayRpcError &&
          capturedResumeError.code == 4007) {
        _desktopStoredSessionKnownMissing = true;
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

    final m = await _loadStoredMessagesTail(_storedSessionProfile);
    if (_disposed || loadEpoch != _messageLoadEpoch) return;
    if (m.isEmpty && (expectedMessageCount ?? 0) > 0) {
      if (messages.isNotEmpty) {
        messagesLoaded = true;
        return;
      }
      throw StateError(
        'Hermes returned an empty transcript for a non-empty session',
      );
    }
    _captureArtifactMaps(m, logicalSessionId: logicalSessionId);
    // API devuelve más antiguo primero; lo invertimos: index 0 = más nuevo.
    messages = _applyCancelledTurnTombstones(
      _associateGeneratedImagesNewestFirst(
        _preserveLocalAssistantErrors(
          _graftRefreshedTail(_normalizedNewestFirst(m), messages),
          messages,
        ),
      ),
    );
    _mergeSteerRecords();
    messagesLoaded = true;
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
  void _recordTranscriptPage(SessionMessagesPage page) {
    final limit = page.limit;
    if (limit == null || limit <= 0) {
      _earlierMessagesAvailable = false;
      _earlierMessagesNextOffset = page.messages.length;
      return;
    }
    _earlierMessagesNextOffset = page.offset + page.messages.length;
    _earlierMessagesAvailable = page.messages.length >= limit;
  }

  /// Cola del transcript (los ~120 más recientes) para la hidratación
  /// inicial, en orden cronológico. Las páginas anteriores se piden bajo
  /// demanda con [loadEarlierMessages].
  Future<List<Map<String, dynamic>>> _loadStoredMessagesTail(
    String profile,
  ) async {
    var page = await _fetchStoredMessagesPage(profile);
    final collected = <Map<String, dynamic>>[...page.messages];
    final requiredAnchors = <String>{};
    for (final tombstone in _cancelledTurnTombstones) {
      final anchor = tombstone.anchorMessageId;
      if (anchor != null) requiredAnchors.add(anchor);
    }
    final needsAbsoluteStart = _cancelledTurnTombstones.any(
      (tombstone) => tombstone.firstUser,
    );

    bool anchorPresent(String anchor) => collected.any(
      (message) => _stableTranscriptMessageId(message) == anchor,
    );

    while (true) {
      final limit = page.limit;
      if (limit == null || limit <= 0) break;
      final hasMore = page.messages.length >= limit;
      final missingAnchor = requiredAnchors.any(
        (anchor) => !anchorPresent(anchor),
      );
      if (!hasMore || (!needsAbsoluteStart && !missingAnchor)) break;
      final nextOffset = page.offset + page.messages.length;
      final older = await _fetchStoredMessagesPage(
        profile,
        limit: limit,
        offset: nextOffset,
      );
      if (older.messages.isEmpty || older.offset <= page.offset) {
        page = older;
        break;
      }
      collected.insertAll(0, older.messages);
      page = older;
    }
    _recordTranscriptPage(page);
    return collected;
  }

  /// Re-ancla una cola refrescada sobre un transcript al que ya se le
  /// cargaron páginas anteriores. Sustituir la lista por la cola nueva
  /// descartaría el prefijo recuperado con [loadEarlierMessages]; si la fila
  /// más antigua de la cola no ancla en lo visible (reescritura por
  /// compactación, otra sesión), la cola refrescada es la autoridad.
  List<Map<String, dynamic>> _graftRefreshedTail(
    List<Map<String, dynamic>> refreshedNewestFirst,
    List<Map<String, dynamic>> previous,
  ) {
    if (!_hasBackfilledPrefix ||
        refreshedNewestFirst.isEmpty ||
        previous.isEmpty) {
      return refreshedNewestFirst;
    }
    final anchor = _transcriptMessageKey(refreshedNewestFirst.last);
    final index = previous.indexWhere(
      (message) => _transcriptMessageKey(message) == anchor,
    );
    if (index < 0 || index == previous.length - 1) {
      return refreshedNewestFirst;
    }
    return <Map<String, dynamic>>[
      ...refreshedNewestFirst,
      ...previous.sublist(index + 1),
    ];
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
    try {
      final page = await _fetchStoredMessagesPage(
        _storedSessionProfile,
        offset: _earlierMessagesNextOffset,
      );
      if (_disposed || loadEpoch != _messageLoadEpoch) return false;
      _recordTranscriptPage(page);
      if (page.messages.isEmpty) return false;
      _captureArtifactMaps(page.messages, logicalSessionId: logicalSessionId);
      final merged = _associateGeneratedImagesNewestFirst(
        _mergeOlderTranscriptPage(
          messages,
          _normalizedNewestFirst(page.messages),
        ),
      );
      final projectedMerged = _applyCancelledTurnTombstones(merged);
      if (identical(projectedMerged, messages)) return false;
      messages = projectedMerged;
      _hasBackfilledPrefix = true;
      _emit(ActiveChatEvent.earlierMessagesLoaded);
      return true;
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
        if (waiter == null && messages.isEmpty && !_disposed) {
          unawaited(_hydrateDeferredDesktopHistory());
        }
      case 'failed':
        _desktopHistoryHydrating = false;
        _desktopHydrationOutcome = false;
        final waiter = _desktopHydrationWaiter;
        if (waiter != null && !waiter.isCompleted) waiter.complete(false);
    }
  }

  Future<void> _hydrateDeferredDesktopHistory() async {
    final loadEpoch = _messageLoadEpoch;
    try {
      final m = await _loadStoredMessagesTail(_storedSessionProfile);
      if (_disposed || loadEpoch != _messageLoadEpoch || m.isEmpty) return;
      _captureArtifactMaps(m, logicalSessionId: logicalSessionId);
      messages = _applyCancelledTurnTombstones(
        _associateGeneratedImagesNewestFirst(
          _preserveLocalAssistantErrors(
            _graftRefreshedTail(_normalizedNewestFirst(m), messages),
            messages,
          ),
        ),
      );
      _mergeSteerRecords();
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
    messageCount: snapshot.messageCount,
    inflight: snapshot.inflight,
    queued: snapshot.queued,
    running: snapshot.running,
    status: snapshot.status,
    startedAt: snapshot.startedAt,
    info: snapshot.info,
    raw: snapshot.raw,
  );

  List<Map<String, dynamic>> _preserveLocalAssistantErrors(
    List<Map<String, dynamic>> next,
    List<Map<String, dynamic>> current,
  ) {
    final existing = <String>{
      for (final message in next)
        if (message['role'] == 'assistant_error')
          '${message['content']}\u0000${message['_prompt']}',
    };
    final existingUsers = <String>{
      for (final message in next)
        if (isRealUserTurn(message)) (message['content'] ?? '').toString(),
    };
    final preserved = <Map<String, dynamic>>[];
    for (var index = 0; index < current.length; index++) {
      final message = current[index];
      if (message['role'] != 'assistant_error') continue;
      final identity = '${message['content']}\u0000${message['_prompt']}';
      if (existing.add(identity)) {
        preserved.add(Map<String, dynamic>.from(message));
        final prompt = (message['_prompt'] ?? '').toString();
        if (prompt.isEmpty || existingUsers.contains(prompt)) continue;
        for (
          var candidate = index + 1;
          candidate < current.length;
          candidate++
        ) {
          final paired = current[candidate];
          if (!isRealUserTurn(paired)) continue;
          if ((paired['content'] ?? '').toString() != prompt) break;
          preserved.add(Map<String, dynamic>.from(paired));
          existingUsers.add(prompt);
          break;
        }
      }
    }
    if (preserved.isEmpty) return next;
    return <Map<String, dynamic>>[...preserved, ...next];
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
    if (_cancelledTurnPersistencePending || _cancelledTurnPersistenceFailed) {
      await _cancelledTurnPersistence;
      if (_disposed) return false;
    }
    final pendingCancel = _desktopCancelRecovery;
    if (pendingCancel != null) {
      await pendingCancel;
      if (_disposed) return false;
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
    if (serverSessionId != _serverSessionOverride) {
      _retireDesktopRuntime();
      _desktopStoredSessionId = null;
      _usingDesktopGateway = false;
    }
    _serverSessionOverride = serverSessionId;
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
    // Un terminal sin texto o una reconciliación tardía no puede arrastrar el
    // placeholder del turno anterior al nuevo timeline.
    _settlePipelinePlaceholders();
    // Optimista: el mensaje del usuario aparece de inmediato.
    messages.insert(0, {'role': 'user', 'content': fullText});
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
      _failRun('No se pudo conservar el turno antes de enviarlo.');
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
      var truncateBeforeRowId = target['_desktopRowId'] is int
          ? target['_desktopRowId'] as int
          : null;

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
      _adoptDesktopRuntime(snapshot.runtimeSessionId, info: snapshot.info);
      _restorePendingClarify(snapshot);
      _desktopStoredSessionKnownMissing = false;
      _desktopRuntimeInfo = snapshot.info;
      _rememberDesktopLiveStatus(snapshot.status, running: snapshot.running);
      _desktopStartedAt = snapshot.startedAt;
      _desktopTurnStartedAt = snapshot.running
          ? snapshot.inflight?.startedAt
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
          if (!_disposed &&
              _desktopRuntimeSessionId == runtimeId &&
              sessionEpoch == _desktopSessionEpoch &&
              connectionEpoch == _desktopBindEpoch) {
            _applyNativeCompressionResult(compression, runtimeId);
          }
          return result;
        } on TuiGatewayRpcError catch (error) {
          // No se reintenta un timeout ni un fallo remoto ambiguo: solo la
          // ausencia inequívoca del método habilita la compatibilidad antigua.
          if (error.code != -32601) rethrow;
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
          );
      if (_disposed ||
          _desktopRuntimeSessionId != runtimeId ||
          sessionEpoch != _desktopSessionEpoch ||
          connectionEpoch != _desktopBindEpoch) {
        return result;
      }
      if (result.accepted != DesktopCommandAcceptance.accepted) return result;

      final reconciled = await _reconcileCompressionSnapshot(
        runtimeId,
        sessionEpoch,
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

  void _applyNativeCompressionResult(
    DesktopCompressionResult compression,
    String runtimeId,
  ) {
    _messageLoadEpoch += 1;
    final compressedStoredId = compression.info.storedSessionId?.trim();
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
    final snapshot = DesktopSessionSnapshot(
      runtimeSessionId: runtimeId,
      storedSessionId: _desktopStoredSessionId ?? serverSessionId,
      created: false,
      messages: compression.messages,
      messagesProvided: true,
      messageCount: compression.afterMessages,
      running: false,
      status: compression.status,
      info: compression.info,
    );
    final projection = const DesktopSessionReconciler().project(snapshot);
    messages = _applyCancelledTurnTombstones(
      _associateGeneratedImagesNewestFirst(
        projection.messagesNewestFirst
            .map(Map<String, dynamic>.from)
            .toList(growable: true),
      ),
    );
    _steerRecords.clear();
    messagesLoaded = true;
    _desktopRuntimeInfo = compression.info;
    _desktopTurnStartedAt = null;
    _observeSessionConfigInfo(compression.info);
    _emit(ActiveChatEvent.messagesHydrated);
    _emit(ActiveChatEvent.sessionInfo);
  }

  Future<bool> _reconcileCompressionSnapshot(
    String expectedRuntimeId,
    int expectedSessionEpoch,
  ) async {
    final gateway = _desktopGateway;
    if (gateway is! HermesDesktopSessionLifecycleGateway) return false;
    final durableId = _desktopStoredSessionId ?? serverSessionId;
    try {
      final snapshot = await (gateway as HermesDesktopSessionLifecycleGateway)
          .resumeExisting(durableId, profile: _storedSessionProfile);
      if (_disposed ||
          expectedSessionEpoch != _desktopSessionEpoch ||
          _desktopRuntimeSessionId != expectedRuntimeId) {
        return false;
      }
      _messageLoadEpoch += 1;
      if (snapshot.messagesProvided) {
        _captureArtifactMessages(
          snapshot.messages,
          logicalSessionId: logicalSessionId,
        );
        final projection = const DesktopSessionReconciler().project(snapshot);
        messages = _applyCancelledTurnTombstones(
          _associateGeneratedImagesNewestFirst(
            projection.messagesNewestFirst
                .map(Map<String, dynamic>.from)
                .toList(growable: true),
          ),
        );
        _steerRecords.clear();
        messagesLoaded = true;
      }
      _desktopStoredSessionId = snapshot.storedSessionId;
      _adoptDesktopRuntime(snapshot.runtimeSessionId, info: snapshot.info);
      _desktopRuntimeInfo = snapshot.info;
      _rememberDesktopLiveStatus(snapshot.status, running: snapshot.running);
      _desktopTurnStartedAt = null;
      _observeSessionConfigInfo(snapshot.info);
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
  Future<DesktopSessionBinding> _resumeDesktopSessionForRecovery(
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
      final snapshot = await recoveryGateway.resumeExistingForRecovery(
        storedSessionId,
        profile: profile,
      );
      return snapshot is DesktopSessionBinding
          ? snapshot
          : DesktopSessionBinding.fromSnapshot(snapshot);
    }
    if (gateway is HermesDesktopSessionLifecycleGateway) {
      final lifecycleGateway = gateway as HermesDesktopSessionLifecycleGateway;
      final snapshot = await lifecycleGateway.resumeExisting(
        storedSessionId,
        profile: profile,
      );
      return snapshot is DesktopSessionBinding
          ? snapshot
          : DesktopSessionBinding.fromSnapshot(snapshot);
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
            _failRun('No se pudo leer un adjunto local.');
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
                _failRun('No se pudo conservar el estado de un adjunto.');
              } else {
                _failRun('El lote de adjuntos cambió durante la subida.');
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
                    ? 'No se pudo conservar el estado de un adjunto.'
                    : 'El lote de adjuntos cambió durante la subida.',
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
            _failRun('El lote de adjuntos cambió durante la subida.');
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
      if (idempotentSubmission) {
        // Anunciada pero incompatible (method-not-found, eco/payload inválido o
        // timeout): se invalida durante esta generación. No hay fallback porque
        // el servidor pudo haber aceptado el turno.
        _turnIdempotencyInvalid = true;
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
        _failRun(error.toString());
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
          unawaited(_recoverDesktopTurn(gateway, _turnEpoch, error));
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
        await _recoverTurnFromTranscript(turnEpoch, originalError);
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
              _failRun('Hermes confirmó que el turno falló tras reconectar.');
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
        _failRun('No se pudo reanudar el turno: $lastError');
      }
    } finally {
      if (_recoveringDesktopTurnEpoch == turnEpoch) {
        _recoveringDesktopTurnEpoch = null;
      }
    }
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
      if (!_canRecoverTurn(turnEpoch)) return;
      if (delay > Duration.zero) {
        final elapsed = await _waitForTerminalReconcileDelay(
          delay,
          epochInvalidated,
        );
        if (!elapsed || !_canRecoverTurn(turnEpoch)) return;
      }
      try {
        final transcript = await _loadStoredMessages(_storedSessionProfile);
        if (!_canRecoverTurn(turnEpoch)) return;
        if (_containsCompletedTurn(transcript, expectedUsers)) {
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
    if (_canRecoverTurn(turnEpoch)) {
      // Sin respuesta recuperable en el servidor: propagar el error original
      // (la capa de presentación lo muestra legible), como antes de este fix.
      _failRun(originalError.toString());
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

  void _scheduleTerminalTranscriptRecovery(
    int completingEpoch, {
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
      if (!_isCurrentEpoch(completingEpoch)) return;
      if (requireAssistantText && assistantContent.trim().isNotEmpty) return;
      final elapsed = await _waitForTerminalReconcileDelay(
        delay,
        epochInvalidated,
      );
      if (!elapsed || !_isCurrentEpoch(completingEpoch)) return;
      if (requireAssistantText && assistantContent.trim().isNotEmpty) return;
      try {
        final transcript = await _loadStoredMessages(_storedSessionProfile);
        if (!_isCurrentEpoch(completingEpoch)) return;
        final ready = requireAssistantText
            ? _latestTurnAssistantText(transcript, expectedUsers) != null
            : _terminalTranscriptCanReplaceVisibleProjection(
                transcript,
                expectedUsers,
              );
        if (ready) {
          _captureArtifactMaps(transcript, logicalSessionId: logicalSessionId);
          messages = projectCancelledTurnTombstones(
            existingNewestFirst: messages,
            incomingNewestFirst: _normalizedNewestFirst(transcript),
            durableTombstones: _cancelledTurnTombstones,
          );
          _mergeSteerRecords();
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
                  ? 'No se pudo conservar el estado de un adjunto.'
                  : 'El lote de adjuntos cambió durante la subida.',
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
          _failRun('No se pudo preparar un adjunto para esta instancia.');
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
                ? 'No se pudo conservar el estado de un adjunto.'
                : 'El lote de adjuntos cambió durante la subida.',
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
          _failRun('El lote de adjuntos cambió durante la subida.');
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
        parentSessionId: serverSessionId,
        runtimeSessionId: runtimeId,
        turnEpoch: _turnEpoch,
      );

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
    final event = SubagentActivityEvent.tryParseLegacyDelegateTool(
      type: type,
      scope: _subagentScope(runtimeId),
      payload: payload,
      toolName: (payload['name'] ?? payload['tool'])?.toString(),
      toolCallId:
          (payload['tool_call_id'] ?? payload['call_id'] ?? payload['id'])
              ?.toString(),
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
    final scoped = current == null || current.scope != event.scope
        ? SubagentActivityState.empty(event.scope)
        : current;
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
          'No se pudo conectar con el agente local (Mobile Bridge). '
          'Arranca el agente y reintenta.',
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
        text: 'El agente local está procesando tu mensaje…',
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
                    ? 'No se pudo conservar el estado de un adjunto.'
                    : 'El lote de adjuntos cambió durante la subida.',
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
            _failRun('No se pudo preparar un adjunto para esta instancia.');
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
                  ? 'No se pudo conservar el estado de un adjunto.'
                  : 'El lote de adjuntos cambió durante la subida.',
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
          _failRun('El lote de adjuntos cambió durante la subida.');
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
      if (hasPendingDurableCancellation) {
        try {
          await (_durableCancelFlight ?? _cancelledTurnPersistence);
        } catch (_) {
          // Mantiene el turno cancelable para que Stop pueda reintentarse.
        }
        return;
      }
      _observeFirstResponseContent(text);
      _runTerminal = true;
      text = text.trim();
      if (messages.isNotEmpty && messages[0]['role'] == 'assistant') {
        messages[0] = {...messages[0], 'content': text, '_pipeline': false};
      }
      state = ChatPipelineState.completed;
      traceActive = false;
      if (text.isNotEmpty && _shouldNotifyReplies) {
        _notifications?.replyReady(
          preview: text.length > 140 ? '${text.substring(0, 140)}…' : text,
          instance: connection.label,
          session: sessionTitle.isNotEmpty ? sessionTitle : sessionId,
          connId: connection.id,
          sessionId: serverSessionId,
          surface: notificationSurface,
          profile: sessionProfile,
          roomId: notificationRoomId,
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
      return 'El agente local se detuvo durante la respuesta (el proceso se '
          'cerró, normalmente por falta de memoria). Vuelve a arrancar el '
          'agente local y reintenta. Si se repite, usa un modelo más pequeño o '
          'da más RAM al dispositivo/emulador.';
    }
    if (low.contains('timeout') || low.contains('timed out')) {
      return 'El agente local tardó demasiado en responder. El modelo puede '
          'estar cargándose; espera unos segundos y reintenta.';
    }
    return 'Chat local: $s';
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
            '[Turno detenido por el usuario. No continúes este trabajo '
            'automáticamente; úsalo como contexto solo si el usuario vuelve a '
            'referirse a él.]\n$content';
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
          'firstTokenTimeout: El servidor conectó pero lleva $secs s sin '
          'actividad (ni texto ni herramientas). El modelo puede estar cargando '
          'o el servidor sobrecargado. Reintenta en unos segundos.',
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
        pendingApproval = null;
        state = ChatPipelineState.executing;
        _emit(ActiveChatEvent.toolProgress);
      case 'run.completed':
        final out = (event['output'] ?? '').toString();
        _completeRun(finalOutput: out.isNotEmpty ? out : null);
      case 'run.failed':
        _failRun((event['error'] ?? 'La ejecución falló').toString());
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

    if (decision != null && decision.kind == ApprovalDecisionKind.autoApprove) {
      // YOLO / regla "siempre": resolver sin molestar al usuario.
      pendingApproval = null;
      state = ChatPipelineState.executing;
      _emit(ActiveChatEvent.toolProgress);
      resolveApproval(decision.scope!.wire);
      return;
    }
    if (decision != null && decision.kind == ApprovalDecisionKind.blocked) {
      // Solo lectura: el agente no puede ejecutar; denegamos automáticamente.
      pendingApproval = null;
      state = ChatPipelineState.executing;
      resolveApproval(ApprovalScope.deny.wire);
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
    _notifications?.approvalPending(
      tool: tool,
      instance: sessionTitle.isNotEmpty ? sessionTitle : null,
      connId: connection.id,
      // La pantalla y la superficie de voz marcan como visible la identidad
      // persistida. Usar aquí el id móvil provisional clasifica la aprobación
      // del propio chat como si viniera de "otro chat" y oculta su acceso.
      sessionId: serverSessionId,
      sessionTitle: sessionTitle,
      surface: notificationSurface,
      profile: sessionProfile,
      roomId: notificationRoomId,
    );
  }

  /// Resuelve la aprobación pendiente del run (once|session|always|deny).
  Future<void> resolveApproval(String choice) async {
    final desktop = _desktopGateway;
    final runtimeId = _desktopRuntimeSessionId;
    if (_usingDesktopGateway && desktop != null && runtimeId != null) {
      await desktop.resolveApproval(runtimeId, choice);
      pendingApproval = null;
      state = ChatPipelineState.executing;
      if (!_streamingConfirmed) _armFirstTokenTimer();
      _emit(ActiveChatEvent.toolProgress);
      return;
    }
    final runId = currentRunId;
    if (runId == null) return;
    await _api.resolveRunApproval(runId, choice);
    pendingApproval = null;
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
  ) async {
    // Mutual exclusion: concurrent calls for the same request are serialized
    // so two confirmations never race and duplicate accepted answers.
    final inFlight = _batchLocks[key];
    if (inFlight != null) return inFlight;

    final operation = _respondToClarifyBatch(key, answers);
    _batchLocks[key] = operation;
    try {
      return await operation;
    } finally {
      if (_batchLocks[key] == operation) {
        _batchLocks.remove(key);
      }
    }
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
    if (!_interactivePromptResponseStillLive(
      key,
      expectedKind: InteractivePromptKind.clarify,
      expectedRequest: request,
    )) {
      return DesktopPromptResponse.fromJson(
        const {'status': 'expired'},
        method: 'clarify.respond',
        allowExpired: true,
      );
    }
    try {
      // Resume from confirmed progress: skip locked answers and preserve the
      // original question order.
      final pending = request.questions;

      if (pending.isEmpty) {
        final result = DesktopPromptResponse.fromJson(const {
          'status': 'ok',
        }, method: 'clarify.respond');
        _reduceInteractivePrompt(InteractivePromptResponded(key));
        return result;
      }

      DesktopPromptResponse? lastResult;
      for (final question in pending) {
        final liveRequest = _respondingBatchRequest(key);
        if (liveRequest == null) {
          return lastResult ??
              DesktopPromptResponse.fromJson(
                const {'status': 'expired'},
                method: 'clarify.respond',
                allowExpired: true,
              );
        }
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
        final liveAfterAck = _respondingBatchRequest(key);
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
      if (!_batchPromptIsResponding(key)) {
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

  bool _batchPromptIsResponding(InteractivePromptKey key) {
    return _respondingBatchRequest(key) != null;
  }

  ClarifyPromptRequest? _respondingBatchRequest(InteractivePromptKey key) {
    if (_disposed) return null;
    if (_desktopRuntimeSessionId != key.runtimeSessionId) {
      // A runtime rotation invalidates only this exact in-flight batch. Seal its
      // entry before returning so a late ACK cannot leave it stuck responding;
      // terminal tombstones and prompts from every other identity stay intact.
      _reduceInteractivePrompt(InteractivePromptExpired(key));
      return null;
    }
    final current = _interactivePrompts[key];
    final request = current?.request;
    return request is ClarifyPromptRequest &&
            request.isBatch &&
            current?.status == InteractivePromptStatus.responding
        ? request
        : null;
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
  ) async {
    try {
      return await _respondToInteractivePrompt(
        key,
        expectedKind: InteractivePromptKind.sudo,
        invoke: (gateway) => gateway.respondToSudo(key.requestId, password),
      );
    } finally {
      password.dispose();
    }
  }

  Future<DesktopPromptResponse> respondToSecret(
    InteractivePromptKey key,
    EphemeralSensitiveValue value,
  ) async {
    try {
      return await _respondToInteractivePrompt(
        key,
        expectedKind: InteractivePromptKind.secret,
        invoke: (gateway) => gateway.respondToSecret(key.requestId, value),
      );
    } finally {
      value.dispose();
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
    pendingApproval = null;
    _expireInteractivePromptsForRuntime(_desktopRuntimeSessionId);
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
    _advanceTurnEpoch();
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

  /// Cierre exitoso del turno: fija el texto final, refresca el historial real
  /// (con sus tool events para agrupar) y notifica si procede.
  Future<void> _completeRun({
    String? finalOutput,
    bool finalOutputNarratable = true,
  }) async {
    if (_runTerminal) return;
    if (hasPendingDurableCancellation) {
      try {
        await (_durableCancelFlight ?? _cancelledTurnPersistence);
      } catch (_) {
        // Stop sigue visible y reintentable; el terminal no puede cerrar el run.
      }
      return;
    }
    _observeFirstResponseContent(finalOutput);
    _assistantNarration.settleFinal(finalOutputNarratable ? finalOutput : null);
    _clearDesktopCompactingIndicator();
    final completingEpoch = _turnEpoch;
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
    pendingApproval = null;
    _expireInteractivePromptsForRuntime(_desktopRuntimeSessionId);
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
    );
    if (!_isCurrentEpoch(completingEpoch)) return;
    state = ChatPipelineState.completed;
    traceActive = false;
    final content = assistantContent.trim();
    if (content.isNotEmpty && _shouldNotifyReplies) {
      _notifications?.replyReady(
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
  Future<bool> _reconcileTerminalTranscript(int completingEpoch) async {
    if (!_isCurrentEpoch(completingEpoch)) return false;
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
      if (!_isCurrentEpoch(completingEpoch)) return false;
      var remaining = deadline.difference(DateTime.now());
      if (remaining.inMicroseconds <= 0) return false;
      if (delay > Duration.zero) {
        final wait = delay < remaining ? delay : remaining;
        final elapsed = await _waitForTerminalReconcileDelay(
          wait,
          epochInvalidated,
        );
        if (!elapsed) return false;
        if (!_isCurrentEpoch(completingEpoch)) return false;
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
        if (!_isCurrentEpoch(completingEpoch) || transcript == null) {
          return false;
        }
        if (!_terminalTranscriptCanReplaceVisibleProjection(
          transcript,
          expectedUsers,
        )) {
          continue;
        }
        _captureArtifactMaps(transcript, logicalSessionId: logicalSessionId);
        messages = projectCancelledTurnTombstones(
          existingNewestFirst: messages,
          incomingNewestFirst: _normalizedNewestFirst(transcript),
          durableTombstones: _cancelledTurnTombstones,
        );
        _mergeSteerRecords();
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
    if (_runTerminal || hasPendingDurableCancellation) return;
    _clearDesktopCompactingIndicator();
    _runTerminal = true;
    _desktopTurnStartedAt = null;
    _firstTokenTimer?.cancel();
    _firstTokenTimer = null;
    _flushTokenBuffer();
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
      messages[0] = {
        'role': 'assistant_error',
        'content': error,
        '_prompt': lastPrompt,
        ...failureMetadata,
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
      messages.insert(0, {
        'role': 'assistant_error',
        'content': error,
        '_prompt': lastPrompt,
        ...failureMetadata,
      });
    }
    // Avisa del problema si la app está en 2º plano (no molesta en primer plano).
    if (_shouldNotifyReplies) {
      _notifications?.replyFailed(
        instance: connection.label,
        session: sessionTitle.isNotEmpty ? sessionTitle : sessionId,
        detail: error,
        connId: connection.id,
        sessionId: serverSessionId,
        surface: notificationSurface,
        profile: sessionProfile,
        roomId: notificationRoomId,
      );
    }
    _emit(ActiveChatEvent.error);
    _drainOrTerminal(expectedEpoch: _turnEpoch);
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
      String? anchorMessageId;
      for (var older = index + 1; older < messages.length; older++) {
        anchorMessageId = _stableTranscriptMessageId(messages[older]);
        if (anchorMessageId != null) break;
      }
      if (anchorMessageId != null) {
        return (
          index: index,
          tombstone: CancelledTurnTombstone(
            content: content,
            anchorMessageId: anchorMessageId,
          ),
        );
      }
      final hasOlderRealUser = messages.skip(index + 1).any(isRealUserTurn);
      if (!hasOlderRealUser && !_earlierMessagesAvailable) {
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
  ) =>
      left.content == right.content &&
      left.anchorMessageId == right.anchorMessageId &&
      left.firstUser == right.firstUser;

  void _commitCancelledTurnLocally(
    ({int index, CancelledTurnTombstone tombstone}) candidate,
  ) {
    final durable = candidate.tombstone;
    if (!_cancelledTurnTombstones.any(
      (item) => _sameCancelledTurn(item, durable),
    )) {
      _cancelledTurnTombstones.add(durable);
    }
    final message = messages[candidate.index];
    messages[candidate.index] = {...message, '_cancelledUser': true};
  }

  void _markLatestUserCancelledLocally() {
    for (var index = 0; index < messages.length; index++) {
      final message = messages[index];
      if (!isRealUserTurn(message)) continue;
      messages[index] = {...message, '_cancelledUser': true};
      return;
    }
  }

  Future<void> _persistLatestUserCancellation() async {
    final before = _latestUserCancellationCandidate();
    final persist = _onCancelledTurn;
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
    if (after == null ||
        !_sameCancelledTurn(before.tombstone, after.tombstone)) {
      throw StateError('cancelled turn changed while persisting tombstone');
    }
    _commitCancelledTurnLocally(after);
  }

  /// El run fue cancelado por el servidor (no por el usuario).
  void _cancelRunState() {
    if (_runTerminal || hasPendingDurableCancellation) return;
    _clearDesktopCompactingIndicator();
    _runTerminal = true;
    _desktopTurnStartedAt = null;
    _firstTokenTimer?.cancel();
    _firstTokenTimer = null;
    _flushTokenBuffer();
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

  /// Reconciliación al volver de 2º plano. Si el SSE murió mientras la app
  /// estaba suspendida (caso raro: el SO mató el isolate pese al foreground
  /// service) y quedó un placeholder/parcial sin cerrar, re-sincroniza los
  /// mensajes desde el servidor (el run sigue su curso server-side). Devuelve
  /// true si hubo cambios. No toca un stream vivo.
  Future<bool> reconcileAfterResume() async {
    if (isStreaming) return false;
    final top = messages.isNotEmpty ? messages.first : null;
    final looksUnfinished =
        top != null &&
        top['role'] == 'assistant' &&
        (top['_pipeline'] == true ||
            ((top['content'] as String?) ?? '').trim().isEmpty);
    if (!looksUnfinished) return false;
    final expectedUsers = messages.where(isRealUserTurn).length;
    try {
      // Instancia LOCAL: no hay historial remoto que re-sincronizar; recupera
      // lo persistido localmente (el bridge no expone /api/sessions/.../messages).
      final List<Map<String, dynamic>> m;
      if (connection.kind == InstanceKind.localhost) {
        m = await LocalTranscriptStore.load(connection.id, sessionId);
      } else {
        m = await _loadStoredMessages(_storedSessionProfile);
      }
      // El endpoint puede ir por detrás del stream justo al volver del fondo.
      // Un [] o el turno anterior no son autoridad suficiente para borrar la
      // burbuja/scrollback local que el usuario ya estaba viendo.
      if (!_containsCompletedTurn(m, expectedUsers)) return false;
      _captureArtifactMaps(m, logicalSessionId: logicalSessionId);
      messages = _applyCancelledTurnTombstones(_normalizedNewestFirst(m));
      if (state != ChatPipelineState.failed) {
        state = ChatPipelineState.completed;
      }
      traceActive = false;
      _emit(ActiveChatEvent.done);
      return true;
    } catch (e) {
      debugPrint('[active-chat] excepción silenciada (se asume false): $e');
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

class _HomeWidgetChatMetadata {
  _HomeWidgetChatMetadata.fromSession(Session session)
    : model = _nonEmpty(session.model),
      inputTokens = session.inputTokens,
      outputTokens = session.outputTokens,
      cacheReadTokens = session.cacheReadTokens,
      cacheWriteTokens = session.cacheWriteTokens,
      lastActivityAtMs = (session.lastActivityAt * 1000).round(),
      isUnpersistedMobileDraft = session.isUnpersistedMobileDraft;

  String? model;
  String? provider;
  int inputTokens;
  int outputTokens;
  int? cacheReadTokens;
  int? cacheWriteTokens;
  int lastActivityAtMs;
  bool isUnpersistedMobileDraft;
  bool hasContextSnapshot = false;
  int? contextUsed;
  int? contextMax;
  int? contextPercent;

  void refresh(Session session) {
    model = _nonEmpty(session.model) ?? model;
    inputTokens = session.inputTokens;
    outputTokens = session.outputTokens;
    cacheReadTokens = session.cacheReadTokens;
    cacheWriteTokens = session.cacheWriteTokens;
    lastActivityAtMs = (session.lastActivityAt * 1000).round();
    isUnpersistedMobileDraft = session.isUnpersistedMobileDraft;
  }

  static String? _nonEmpty(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}

/// Registro de chats con streaming activo. Singleton vivo en HermesAppState.
class ActiveChatService {
  ActiveChatService({
    this.notifications,
    this.policy,
    SharedPreferences? prefs,
    CancelledTurnTombstoneStore? cancelledTurnStore,
  }) : _prefs = prefs,
       _cancelledTurnStore = cancelledTurnStore {
    _restoreObservedFirstTokenLatencies();
    unawaited(_drainPendingCancelledTurnCleanup());
  }

  final NotificationService? notifications;

  /// Política de aprobaciones compartida. Inyectada para que el auto-approval
  /// (YOLO / reglas guardadas) ocurra en la capa de servicio, no en la pantalla.
  final ApprovalPolicyService? policy;

  /// Prefs para registrar runs en RunRegistry cuando se inician desde el chat.
  /// Si es null (p.ej. en tests), el registro se omite sin efecto secundario.
  final SharedPreferences? _prefs;
  final CancelledTurnTombstoneStore? _cancelledTurnStore;

  final Map<String, ActiveChat> _chats = {};
  final Map<String, List<SteerProjection>> _steerProjectionCache = {};
  final Map<ActiveChat, _HomeWidgetChatMetadata> _homeWidgetMetadata = {};
  final LinkedHashMap<String, int> _observedFirstTokenLatencyCache =
      LinkedHashMap<String, int>();
  static const _observedFirstTokenLatencyPrefsKey =
      'active_chat_observed_ttft_v1';
  HermesHomeWidgetPublisher? _homeWidgetPublisher;
  String? _homeWidgetActiveConnectionId;
  HermesHomeWidgetSnapshot? _lastHomeWidgetSemantic;

  static String chatKey(String connectionId, String sessionId) =>
      '$connectionId::$sessionId';

  static const _pendingCancelledTurnCleanupKey =
      'cancelled_turn_cleanup_pending_v1';
  Future<void> _cleanupMutation = Future<void>.value();

  Future<void> _enqueueCancelledTurnCleanup(List<String> command) {
    final prefs = _prefs;
    if (prefs == null) return Future<void>.value();
    final operation = _cleanupMutation.then((_) async {
      final encoded = jsonEncode(command);
      final pending =
          prefs.getStringList(_pendingCancelledTurnCleanupKey) ?? [];
      if (!pending.contains(encoded)) pending.add(encoded);
      await prefs.setStringList(_pendingCancelledTurnCleanupKey, pending);
    });
    _cleanupMutation = operation.catchError((_) {});
    return operation;
  }

  Future<void> _drainPendingCancelledTurnCleanup() {
    final operation = _cleanupMutation.then((_) async {
      final prefs = _prefs;
      final store = _cancelledTurnStore;
      if (prefs == null || store == null) return;
      final pending =
          prefs.getStringList(_pendingCancelledTurnCleanupKey) ?? [];
      if (pending.isEmpty) return;
      final remaining = <String>[];
      for (final encoded in pending) {
        try {
          final command = jsonDecode(encoded);
          if (command is! List || command.isEmpty) continue;
          if (command.first == 'session' && command.length == 4) {
            await store.removeSession(
              connectionId: command[1] as String,
              profile: command[2] as String,
              sessionId: command[3] as String,
            );
          } else if (command.first == 'connection' && command.length == 2) {
            await store.removeConnection(command[1] as String);
          }
        } catch (_) {
          remaining.add(encoded);
        }
      }
      await prefs.setStringList(_pendingCancelledTurnCleanupKey, remaining);
    });
    _cleanupMutation = operation.catchError((_) {});
    return operation;
  }

  Future<int> clearCancelledTurnsForSession({
    required String connectionId,
    required String profile,
    required String sessionId,
  }) async {
    final owner = Session.profileOwner(profile);
    final scopeIds = <String>{sessionId};
    final matchingChats = <ActiveChat>[];
    for (final chat in _chats.values) {
      if (chat.connection.id != connectionId || chat.sessionProfile != owner) {
        continue;
      }
      final aliases = <String>{
        chat.sessionId,
        chat.serverSessionId,
        chat.logicalSessionId,
      };
      if (!aliases.contains(sessionId)) continue;
      matchingChats.add(chat);
      scopeIds.addAll(aliases);
    }

    var removed = 0;
    Object? firstError;
    StackTrace? firstStack;
    for (final scopeId in scopeIds) {
      try {
        removed +=
            await _cancelledTurnStore?.removeSession(
              connectionId: connectionId,
              profile: owner,
              sessionId: scopeId,
            ) ??
            0;
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStack ??= stackTrace;
        await _enqueueCancelledTurnCleanup([
          'session',
          connectionId,
          owner,
          scopeId,
        ]);
      }
    }
    for (final chat in matchingChats) {
      chat.clearCancelledTurnTombstones();
    }
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
    return removed;
  }

  Future<int> clearCancelledTurnsForConnection(String connectionId) async {
    var removed = 0;
    try {
      removed = await _cancelledTurnStore?.removeConnection(connectionId) ?? 0;
    } catch (_) {
      await _enqueueCancelledTurnCleanup(['connection', connectionId]);
      rethrow;
    } finally {
      for (final entry in _chats.entries) {
        try {
          final parts = jsonDecode(entry.key);
          if (parts is List &&
              parts.isNotEmpty &&
              parts.first == connectionId) {
            entry.value.clearCancelledTurnTombstones();
          }
        } catch (_) {
          if (entry.key.startsWith('$connectionId::')) {
            entry.value.clearCancelledTurnTombstones();
          }
        }
      }
    }
    return removed;
  }

  static String _registryKey(
    String connectionId,
    String sessionId,
    String profile,
  ) => jsonEncode(<String>[
    connectionId,
    Session.profileOwner(profile),
    sessionId,
  ]);

  static String _legacyChatKey(String connectionId, String sessionId) =>
      '$connectionId::$sessionId';

  int? _cachedObservedFirstTokenLatencyMs(
    String connectionId,
    String sessionId, {
    required String profile,
  }) {
    final owner = Session.profileOwner(profile);
    final current =
        _observedFirstTokenLatencyCache[_registryKey(
          connectionId,
          sessionId,
          owner,
        )];
    if (current != null) return current;
    // Las versiones anteriores no sellaban el perfil. Solo `default` puede
    // adoptar esa métrica: aplicarla a un owner alternativo mezclaría chats
    // que comparten ids entre perfiles.
    if (owner != 'default') return null;
    return _observedFirstTokenLatencyCache[_legacyChatKey(
      connectionId,
      sessionId,
    )];
  }

  String _projectionKey(
    String connectionId,
    String sessionId, {
    required String profile,
  }) => _registryKey(connectionId, sessionId, profile);

  /// Condición extra para NO bajar el foreground service aunque no haya runs en
  /// curso. La usa el modo voz: mientras el TTS sigue hablando en 2º plano tras
  /// completar el run, el proceso debe seguir vivo o el SO cortaría la voz a
  /// media frase. La cablea HermesAppState con el estado del VoiceConversation.
  bool Function()? keepAliveWhile;

  /// Reevalúa si procede bajar el foreground service (lo llama el modo voz cuando
  /// el TTS deja de hablar en 2º plano: ya no hay nada que mantener vivo).
  Future<void> maybeReleaseForeground() => _maybeStopForeground();

  /// Identidades `conexión + perfil + sesión` con un stream EN CURSO.
  ///
  /// Las superficies lo observan como señal de invalidación y consultan
  /// [isActive] para resolver el estado. Incluir el perfil garantiza que el fin
  /// de A notifique aunque B conserve el mismo sessionId en otro owner.
  final ValueNotifier<Set<String>> activeIds = ValueNotifier<Set<String>>({});

  /// Conecta la salida no sensible hacia Glance. El servicio sigue siendo el
  /// único reducer del estado vivo del chat; la app solo conserva la parte base
  /// (instancia, salud y tema) del snapshot.
  void bindHomeWidgetPublisher(
    HermesHomeWidgetPublisher publisher, {
    required String? activeConnectionId,
  }) {
    _homeWidgetPublisher = publisher;
    _homeWidgetActiveConnectionId = activeConnectionId;
    _lastHomeWidgetSemantic = null;
  }

  /// Cambiar de instancia invalida inmediatamente toda identidad y métrica de
  /// la sesión anterior. Los eventos tardíos se ignoran por connection id.
  Future<void> setHomeWidgetActiveConnection(String? connectionId) async {
    if (_homeWidgetActiveConnectionId == connectionId) return;
    _homeWidgetActiveConnectionId = connectionId;
    _lastHomeWidgetSemantic = null;
    final publisher = _homeWidgetPublisher;
    if (publisher == null) return;
    try {
      await publisher.update(
        (current) => current.copyWith(
          clearModel: true,
          clearProvider: true,
          clearSessionId: true,
          clearSessionTitle: true,
          agentState: HomeWidgetAgentState.disconnected,
          clearToolName: true,
          clearContextUsed: true,
          clearContextMax: true,
          clearContextPercent: true,
          clearInputTokens: true,
          clearOutputTokens: true,
          clearCacheReadTokens: true,
          clearCacheWriteTokens: true,
          clearFirstTokenLatencyMs: true,
          clearLastActivityAtMs: true,
        ),
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[home-widget] session clear unavailable (${error.runtimeType})',
        );
      }
    }
  }

  MapEntry<String, ActiveChat>? _entryFor(
    String connectionId,
    String sessionId, {
    String? profile,
  }) {
    final owner = profile == null ? null : Session.profileOwner(profile);
    if (owner != null) {
      final key = _registryKey(connectionId, sessionId, owner);
      final direct = _chats[key];
      if (direct != null) return MapEntry(key, direct);
    }
    MapEntry<String, ActiveChat>? match;
    for (final entry in _chats.entries) {
      final chat = entry.value;
      if (chat.connection.id != connectionId ||
          (owner != null && chat.sessionProfile != owner) ||
          (chat.sessionId != sessionId && chat.storedSessionId != sessionId)) {
        continue;
      }
      // Sin perfil explícito nunca elegimos arbitrariamente entre dos homes.
      // Los payloads legacy deben resolver primero su Session autoritativa.
      if (match != null && !identical(match.value, chat)) return null;
      match = entry;
    }
    return match;
  }

  /// Devuelve el chat activo por su ID móvil o por el ID persistido de Hermes.
  ActiveChat? of(String connectionId, String sessionId, {String? profile}) =>
      _entryFor(connectionId, sessionId, profile: profile)?.value;

  /// ¿La sesión tiene un stream en curso?
  bool isActive(String connectionId, String sessionId, {String? profile}) {
    if (profile == null) {
      // Uso de indicador únicamente: sin perfil no elegimos un chat ni
      // devolvemos contenido, pero sí podemos afirmar si cualquiera de los
      // owners con ese id sigue ejecutándose.
      return _chats.values.any(
        (chat) =>
            chat.connection.id == connectionId &&
            (chat.sessionId == sessionId ||
                chat.storedSessionId == sessionId) &&
            chat.isStreaming,
      );
    }
    return _entryFor(
          connectionId,
          sessionId,
          profile: profile,
        )?.value.isStreaming ??
        false;
  }

  int? observedFirstTokenLatencyMs(
    String connectionId,
    String sessionId, {
    String? profile,
  }) {
    final chat = of(connectionId, sessionId, profile: profile);
    if (chat != null) return chat.observedFirstTokenLatencyMs;
    return _cachedObservedFirstTokenLatencyMs(
      connectionId,
      sessionId,
      profile: Session.profileOwner(profile),
    );
  }

  void _restoreObservedFirstTokenLatencies() {
    final raw = _prefs?.getString(_observedFirstTokenLatencyPrefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String &&
            key.isNotEmpty &&
            key.length <= 520 &&
            value is int &&
            value >= 0) {
          _observedFirstTokenLatencyCache[key] = value;
        }
      }
      while (_observedFirstTokenLatencyCache.length > 128) {
        _observedFirstTokenLatencyCache.remove(
          _observedFirstTokenLatencyCache.keys.first,
        );
      }
    } catch (_) {
      // Métrica local opcional: datos antiguos/corruptos no bloquean el chat.
    }
  }

  Future<void> _persistObservedFirstTokenLatencies() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setString(
      _observedFirstTokenLatencyPrefsKey,
      jsonEncode(_observedFirstTokenLatencyCache),
    );
  }

  void _rememberObservedFirstTokenLatency(ActiveChat chat, int? latencyMs) {
    final ids = <String>{chat.sessionId, chat.logicalSessionId};
    final storedId = chat.storedSessionId;
    if (storedId != null && storedId.isNotEmpty) ids.add(storedId);
    final owner = Session.profileOwner(chat.sessionProfile);
    for (final id in ids) {
      final key = _registryKey(chat.connection.id, id, owner);
      if (latencyMs == null) {
        _observedFirstTokenLatencyCache.remove(key);
      } else {
        _observedFirstTokenLatencyCache.remove(key);
        _observedFirstTokenLatencyCache[key] = latencyMs;
      }
      if (owner == 'default') {
        _observedFirstTokenLatencyCache.remove(
          _legacyChatKey(chat.connection.id, id),
        );
      }
    }
    while (_observedFirstTokenLatencyCache.length > 128) {
      _observedFirstTokenLatencyCache.remove(
        _observedFirstTokenLatencyCache.keys.first,
      );
    }
    unawaited(_persistObservedFirstTokenLatencies());
  }

  /// Refresca selección local de modelo/proveedor sin publicar desde la UI.
  /// La proyección final siempre se reduce aquí junto al runtime autoritativo.
  void updateHomeWidgetSessionMetadata(
    ActiveChat chat, {
    Session? session,
    String? model,
    String? provider,
  }) {
    final metadata = _homeWidgetMetadata[chat];
    if (metadata == null) return;
    if (session != null) metadata.refresh(session);
    final normalizedModel = _nonEmptyWidgetText(model);
    final normalizedProvider = _nonEmptyWidgetText(provider);
    if (normalizedModel != null && normalizedModel != 'hermes-agent') {
      metadata.model = normalizedModel;
    }
    if (normalizedProvider != null && normalizedProvider != 'gateway') {
      metadata.provider = normalizedProvider;
    }
    _publishHomeWidgetChat(chat);
  }

  /// Mirrors the exact context projection already accepted by ChatScreen.
  /// Values may be null to represent the same honest unknown state; this
  /// reducer never estimates occupancy from cumulative token counters.
  void updateHomeWidgetSessionContext(
    ActiveChat chat, {
    required int? contextUsed,
    required int? contextMax,
    required int? contextPercent,
  }) {
    final metadata = _homeWidgetMetadata[chat];
    if (metadata == null) return;
    metadata
      ..hasContextSnapshot = true
      ..contextUsed = contextUsed
      ..contextMax = contextMax
      ..contextPercent = contextPercent;
    _publishHomeWidgetChat(chat);
  }

  void _onHomeWidgetChatEvent(ActiveChat chat, ActiveChatEvent event) {
    _publishHomeWidgetChat(chat, event: event);
  }

  HomeWidgetAgentState _homeWidgetAgentState(
    ActiveChat chat,
    ActiveChatEvent? event,
  ) {
    if (event == ActiveChatEvent.error) return HomeWidgetAgentState.error;
    if (event == ActiveChatEvent.done || event == ActiveChatEvent.cancelled) {
      return HomeWidgetAgentState.idle;
    }
    if (event == ActiveChatEvent.token) return HomeWidgetAgentState.streaming;
    if (event == ActiveChatEvent.toolProgress ||
        event == ActiveChatEvent.subagentActivity) {
      return HomeWidgetAgentState.toolExecution;
    }
    if (event == ActiveChatEvent.started ||
        event == ActiveChatEvent.connected ||
        event == ActiveChatEvent.waiting) {
      return HomeWidgetAgentState.thinking;
    }
    if (chat.needsInput ||
        event == ActiveChatEvent.approvalRequest ||
        event == ActiveChatEvent.interactiveRequest) {
      return HomeWidgetAgentState.waitingApproval;
    }
    return switch (chat.state) {
      ChatPipelineState.connecting ||
      ChatPipelineState.waiting => HomeWidgetAgentState.thinking,
      ChatPipelineState.executing => HomeWidgetAgentState.toolExecution,
      ChatPipelineState.streaming => HomeWidgetAgentState.streaming,
      ChatPipelineState.failed => HomeWidgetAgentState.error,
      ChatPipelineState.idle ||
      ChatPipelineState.completed ||
      ChatPipelineState.cancelled => HomeWidgetAgentState.idle,
    };
  }

  String? _runningHomeWidgetTool(ActiveChat chat) {
    for (final tool in chat.trace.reversed) {
      if (tool.status == 'running') return _nonEmptyWidgetText(tool.label);
    }
    return null;
  }

  bool _homeWidgetEventTouchesActivity(
    ActiveChat chat,
    ActiveChatEvent? event,
  ) => switch (event) {
    ActiveChatEvent.started ||
    ActiveChatEvent.connected ||
    ActiveChatEvent.waiting ||
    ActiveChatEvent.token ||
    ActiveChatEvent.toolProgress ||
    ActiveChatEvent.approvalRequest ||
    ActiveChatEvent.interactiveRequest ||
    ActiveChatEvent.subagentActivity ||
    ActiveChatEvent.done ||
    ActiveChatEvent.error ||
    ActiveChatEvent.cancelled => true,
    ActiveChatEvent.sessionInfo => chat.isStreaming,
    _ => false,
  };

  void _publishHomeWidgetChat(ActiveChat chat, {ActiveChatEvent? event}) {
    final publisher = _homeWidgetPublisher;
    final metadata = _homeWidgetMetadata[chat];
    if (publisher == null ||
        metadata == null ||
        chat.connection.id != _homeWidgetActiveConnectionId) {
      return;
    }
    // A draft created by the composer is not addressable through Hermes yet.
    // Publishing its provisional mob-* id would replace the last real session
    // and make the widget's Return action point at a non-existent REST record.
    if (metadata.isUnpersistedMobileDraft &&
        chat.storedSessionId == null &&
        chat.serverSessionId.startsWith('mob-')) {
      return;
    }
    final current = publisher.latest;
    final usage = chat.desktopRuntimeInfo.usage;
    final runtimeModel = _nonEmptyWidgetText(chat.desktopRuntimeInfo.model);
    final turnModel = _nonEmptyWidgetText(chat._lastModel);
    final runtimeProvider = _nonEmptyWidgetText(
      chat.desktopRuntimeInfo.provider,
    );
    final sameSession = current.sessionId == chat.serverSessionId;
    final candidateSessionTitle = _meaningfulWidgetSessionTitle(
      chat.sessionTitle,
    );
    final sessionTitle =
        candidateSessionTitle ?? (sameSession ? current.sessionTitle : null);
    final contextUsed = metadata.hasContextSnapshot
        ? metadata.contextUsed
        : usage?.contextUsed ?? (sameSession ? current.contextUsed : null);
    final contextMax = metadata.hasContextSnapshot
        ? metadata.contextMax
        : usage?.contextMax ?? (sameSession ? current.contextMax : null);
    final contextPercent = metadata.hasContextSnapshot
        ? metadata.contextPercent
        : usage?.contextPercent?.round().clamp(0, 100);
    final livePublishesCache =
        usage?.cacheReadTokens != null || usage?.cacheWriteTokens != null;
    final metadataPublishesCache =
        metadata.cacheReadTokens != null || metadata.cacheWriteTokens != null;
    final useMetadataPromptUsage =
        metadataPublishesCache && !livePublishesCache;
    final agentState = _homeWidgetAgentState(chat, event);
    final toolName = agentState == HomeWidgetAgentState.toolExecution
        ? _runningHomeWidgetTool(chat)
        : null;
    final previousSessionActivity = current.sessionId == chat.serverSessionId
        ? current.lastActivityAtMs
        : null;
    var next = HermesHomeWidgetSnapshot(
      configured: true,
      instanceId: chat.connection.id,
      instanceLabel: chat.connection.label,
      connectionState: switch (event) {
        ActiveChatEvent.connected ||
        ActiveChatEvent.waiting ||
        ActiveChatEvent.token ||
        ActiveChatEvent.toolProgress ||
        ActiveChatEvent.approvalRequest ||
        ActiveChatEvent.interactiveRequest ||
        ActiveChatEvent.subagentActivity ||
        ActiveChatEvent.done ||
        ActiveChatEvent.cancelled => HomeWidgetConnectionState.connected,
        ActiveChatEvent.started
            when current.connectionState ==
                HomeWidgetConnectionState.disconnected =>
          HomeWidgetConnectionState.connecting,
        _ => current.connectionState,
      },
      model:
          runtimeModel ??
          (turnModel == 'hermes-agent' ? null : turnModel) ??
          metadata.model,
      provider: runtimeProvider ?? metadata.provider,
      sessionId: chat.serverSessionId,
      sessionTitle: sessionTitle,
      agentState: agentState,
      toolName: toolName,
      contextUsed: contextUsed,
      contextMax: contextMax,
      contextPercent: contextPercent,
      inputTokens: useMetadataPromptUsage
          ? metadata.inputTokens
          : usage?.input ?? metadata.inputTokens,
      outputTokens: usage?.output ?? metadata.outputTokens,
      cacheReadTokens: livePublishesCache
          ? usage?.cacheReadTokens
          : metadata.cacheReadTokens,
      cacheWriteTokens: livePublishesCache
          ? usage?.cacheWriteTokens
          : metadata.cacheWriteTokens,
      firstTokenLatencyMs: chat.observedFirstTokenLatencyMs,
      lastActivityAtMs: previousSessionActivity ?? metadata.lastActivityAtMs,
      theme: current.theme,
      showAdvancedMetrics: current.showAdvancedMetrics,
    );
    var semantic = next.copyWith(updatedAtMs: 0);
    if (semantic == _lastHomeWidgetSemantic) return;
    if (_homeWidgetEventTouchesActivity(chat, event)) {
      next = next.copyWith(
        lastActivityAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      semantic = next.copyWith(updatedAtMs: 0);
    }
    _lastHomeWidgetSemantic = semantic;
    unawaited(_publishHomeWidgetSnapshot(publisher, next));
  }

  Future<void> _publishHomeWidgetSnapshot(
    HermesHomeWidgetPublisher publisher,
    HermesHomeWidgetSnapshot snapshot,
  ) async {
    try {
      await publisher.publish(snapshot);
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[home-widget] chat state unavailable (${error.runtimeType})',
        );
      }
    }
  }

  static String? _nonEmptyWidgetText(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static String? _meaningfulWidgetSessionTitle(String? value) {
    final normalized = _nonEmptyWidgetText(value);
    if (normalized == null) return null;
    final placeholder = normalized.toLowerCase();
    if (const <String>{
      'untitled',
      'sin titulo',
      'sin título',
      'new session',
      'new conversation',
      'nueva conversacion',
      'nueva conversación',
    }.contains(placeholder)) {
      return null;
    }
    return normalized;
  }

  /// Engancha (o crea) el chat de una sesión. Lo usa la pantalla al abrirse.
  ActiveChat attach({
    required SavedConnection connection,
    required String sessionId,
    String? logicalSessionId,
    required String sessionTitle,
    Session? sessionSnapshot,
    String? sessionProfile,
    String? initialStoredSessionId,
    NotificationChatSurface notificationSurface =
        NotificationChatSurface.normal,
    String? notificationRoomId,
    bool authoritativeStoredSessionBinding = false,
    String? selectedProvider,
    @visibleForTesting ApiClient? api,
    @visibleForTesting HermesDesktopGateway? desktopGateway,
    @visibleForTesting StoredSessionMessageLoader? storedMessageLoader,
    @visibleForTesting Future<bool> Function()? turnIdempotencyCapability,
    @visibleForTesting bool disableForegroundKeepAlive = false,
  }) {
    final owner = Session.profileOwner(
      sessionProfile ?? sessionSnapshot?.profile,
    );
    final key = _registryKey(connection.id, sessionId, owner);
    final existing = of(connection.id, sessionId, profile: owner);
    if (existing != null) {
      if (existing.bindKnownStoredSession(
        initialStoredSessionId,
        authoritative: authoritativeStoredSessionBinding,
      )) {
        existing.sessionTitle = sessionTitle;
        existing._bindSessionProfile(owner);
        existing.bindNotificationTarget(
          notificationSurface,
          roomId: notificationRoomId,
        );
        final metadata = _homeWidgetMetadata[existing];
        if (sessionSnapshot != null) metadata?.refresh(sessionSnapshot);
        final provider = _nonEmptyWidgetText(selectedProvider);
        if (provider != null && provider != 'gateway') {
          metadata?.provider = provider;
        }
        _publishHomeWidgetChat(existing);
        return existing;
      }
      // Un binding nuevo no puede saltarse una escritura durable en vuelo. La
      // próxima invalidación/attach resolverá la identidad tras el commit.
      if (existing.hasPendingDurableCancellation) return existing;
      // A stable mobile Bot/Room route can be reopened after its authoritative
      // stored id changes. Never retarget an existing runtime; dispose that
      // binding and attach a fresh chat for the new durable identity.
      _dispose(key);
    }
    final tombstoneGeneration = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              connection.id,
              connection.kind.name,
              connection.host,
              connection.port,
              connection.useHttps,
              connection.gatewayAuthMode.storageKey,
              connection.apiKey,
            ]),
          ),
        )
        .toString();
    late final ActiveChat chat;
    chat = ActiveChat(
      connection: connection,
      sessionId: sessionId,
      logicalSessionId: logicalSessionId,
      sessionTitle: sessionTitle,
      notificationSurface: notificationSurface,
      notificationRoomId: notificationRoomId,
      sessionProfile: owner,
      initialStoredSessionId: initialStoredSessionId,
      notifications: notifications,
      policy: policy,
      onTerminal: () => _onChatTerminal(key),
      onUnused: () => _onChatUnused(key),
      onRunStarted: (runId) => _onRunStarted(key, runId),
      onForegroundKeepAlive: disableForegroundKeepAlive
          ? null
          : () async {
              await BackgroundListener.start();
              _refreshActiveIds();
            },
      api: api,
      desktopGateway: desktopGateway,
      storedMessageLoader: storedMessageLoader,
      turnIdempotencyCapability: turnIdempotencyCapability,
      initialObservedFirstTokenLatencyMs: _cachedObservedFirstTokenLatencyMs(
        connection.id,
        sessionId,
        profile: owner,
      ),
      onObservedFirstTokenLatency: (latencyMs) {
        _rememberObservedFirstTokenLatency(chat, latencyMs);
        if (latencyMs != null) {
          _onHomeWidgetChatEvent(chat, ActiveChatEvent.token);
        }
      },
      onEvent: (event) => _onHomeWidgetChatEvent(chat, event),
      initialSteerProjections:
          _steerProjectionCache[_projectionKey(
            connection.id,
            sessionId,
            profile: owner,
          )] ??
          const [],
      // El id de ruta del chat es el scope estable. El storedSessionId puede
      // rotar por resume/compresión y nunca debe varar la protección local.
      initialCancelledTurnTombstones:
          _cancelledTurnStore?.load(
            connectionId: connection.id,
            profile: owner,
            sessionId: sessionId,
            generation: tombstoneGeneration,
          ) ??
          const [],
      onCancelledTurn: _cancelledTurnStore == null
          ? null
          : (tombstone) => _cancelledTurnStore.add(
              connectionId: connection.id,
              profile: owner,
              sessionId: sessionId,
              tombstone: tombstone,
              generation: tombstoneGeneration,
            ),
    );
    _chats[key] = chat;
    final seed =
        sessionSnapshot ??
        Session(
          id: sessionId,
          title: sessionTitle,
          model: '',
          source: 'mobile',
          messageCount: 0,
          isActive: false,
          preview: '',
          startedAt: DateTime.now().millisecondsSinceEpoch / 1000,
        );
    final metadata = _HomeWidgetChatMetadata.fromSession(seed);
    final provider = _nonEmptyWidgetText(selectedProvider);
    if (provider != null && provider != 'gateway') {
      metadata.provider = provider;
    }
    _homeWidgetMetadata[chat] = metadata;
    _publishHomeWidgetChat(chat);
    return chat;
  }

  /// Un run arrancó: registra la vigilancia en 2º plano y levanta el foreground
  /// service. Esto mantiene vivo el proceso (y con él el isolate de UI que
  /// corre el SSE) mientras el agente responde, aunque el usuario salga de la
  /// app, bloquee o apague la pantalla. Si el SO matase el proceso igualmente,
  /// el isolate del servicio sigue sondeando el run y avisa al terminar.
  Future<void> _onRunStarted(String key, String runId) async {
    final chat = _chats[key];
    if (chat == null) return;
    // Registrar en RunRegistry para que Task Center (Ejecuciones) vea los runs
    // lanzados desde el chat, no solo los de RunsTab. Es un añadido puro:
    // si prefs es null (tests) se omite sin efecto. RunRegistry.add es idempotente.
    final prefs = _prefs;
    if (prefs != null) {
      try {
        final registry = await RunRegistry.load(prefs, chat.connection.id);
        await registry.add(
          RunRecord(
            runId: runId,
            prompt: chat.lastPrompt,
            sessionId: chat.sessionId,
            createdAt: DateTime.now().millisecondsSinceEpoch / 1000,
            lastStatus: 'queued',
            connId: chat.connection.id,
          ),
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint('ActiveChatService RunRegistry add falló: $e');
        }
      }
    }
    try {
      await BackgroundWatch.add(
        SavedRunWatch(
          connId: chat.connection.id,
          base: chat.connection.baseUrl,
          runId: runId,
          prompt: chat.lastPrompt,
          sessionId: chat.sessionId,
        ),
      );
      await BackgroundListener.start();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('ActiveChatService foreground start falló: $e');
      }
    }
    _refreshActiveIds();
  }

  /// Reconciliación global al volver de 2º plano: re-sincroniza cualquier chat
  /// cuyo stream pudiera haberse cortado mientras la app estaba suspendida.
  Future<void> reconcileAfterResume() async {
    for (final chat in _chats.values.toList()) {
      await chat.reconcileAfterResume();
    }
  }

  Future<void> suspendIdleConnections() async {
    await Future.wait(
      _chats.values.map((chat) => chat.suspendIdleDesktopConnection()),
    );
  }

  /// Suelta el chat al cerrar la pantalla: si NO está en streaming, lo libera
  /// (cierra el cliente HTTP); si está en streaming, lo deja correr en segundo
  /// plano (se reaprovechará al volver y se reapará al terminar sin oyentes).
  void release(String connectionId, String sessionId, {String? profile}) {
    final entry = _entryFor(connectionId, sessionId, profile: profile);
    if (entry == null) return;
    final chat = entry.value;
    _rememberSteerProjections(chat);
    chat.requestReleaseWhenUnused();
    if (chat.isStreaming ||
        chat.hasPendingDurableCancellation ||
        chat.hasListeners ||
        chat.voiceBargeHandoffPending) {
      _refreshActiveIds();
      return;
    }
    _dispose(entry.key);
  }

  void _onChatUnused(String key) {
    final chat = _chats[key];
    if (chat == null ||
        !chat.releaseRequested ||
        chat.isStreaming ||
        chat.hasPendingDurableCancellation ||
        chat.hasListeners ||
        chat.voiceBargeHandoffPending) {
      return;
    }
    _dispose(key);
  }

  /// Marca el inicio de un envío: registra la sesión como activa.
  void markStarted(String connectionId, String sessionId) =>
      _refreshActiveIds();

  void _onChatTerminal(String key) {
    final chat = _chats[key];
    if (chat != null) {
      _rememberObservedFirstTokenLatency(
        chat,
        chat.observedFirstTokenLatencyMs,
      );
    }
    _refreshActiveIds();
    // El run terminó: deja de vigilarlo en 2º plano y, si ya no queda ningún
    // run activo, baja el foreground service.
    final runId = chat?.currentRunId;
    if (runId != null) BackgroundWatch.remove(runId);
    _maybeStopForeground();
    if (chat == null) return;
    // Si nadie está mirando el chat (la pantalla se cerró), libéralo: el
    // refetch y la notificación ya ocurrieron en onDone.
    if (!chat.isStreaming &&
        !chat.hasPendingDurableCancellation &&
        !chat.hasListeners &&
        !chat.voiceBargeHandoffPending) {
      _dispose(key);
    }
  }

  /// Baja el foreground service salvo que (a) el usuario activó la escucha
  /// permanente opt-in, o (b) aún hay otro run en curso.
  Future<void> _maybeStopForeground() async {
    if (_chats.values.any((c) => c.isStreaming)) return;
    // El modo voz puede seguir hablando en 2º plano tras completar el run.
    if (keepAliveWhile?.call() ?? false) return;
    try {
      if (await BackgroundListener.isEnabled()) return;
      final stopped = await BackgroundListener.stop();
      // `stopService()` ejecuta `stopForeground(STOP_FOREGROUND_REMOVE)`, cuyo
      // evento de borrado puede arrastrar la notificación de respuesta recién
      // posteada (la app está en 2º plano). Tras un breve margen para que el
      // desmontaje termine, la re-afirmamos en silencio para que sobreviva.
      if (stopped) {
        await Future.delayed(const Duration(milliseconds: 300));
        await notifications?.reassertRecent();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('ActiveChatService foreground stop falló: $e');
    }
  }

  void _rememberSteerProjections(ActiveChat chat) {
    final sessionIds = <String>{chat.sessionId};
    final storedId = chat.storedSessionId;
    if (storedId != null && storedId.isNotEmpty) sessionIds.add(storedId);
    final projections = chat.steerProjections;
    for (final id in sessionIds) {
      final key = _projectionKey(
        chat.connection.id,
        id,
        profile: chat.sessionProfile,
      );
      if (projections.isEmpty) {
        _steerProjectionCache.remove(key);
      } else {
        _steerProjectionCache[key] = List<SteerProjection>.of(projections);
      }
    }
    // Memoria acotada: son proyecciones de UI, no un transcript local.
    while (_steerProjectionCache.length > 32) {
      _steerProjectionCache.remove(_steerProjectionCache.keys.first);
    }
  }

  void _dispose(String key) {
    final chat = _chats.remove(key);
    if (chat != null) {
      _homeWidgetMetadata.remove(chat);
      _rememberSteerProjections(chat);
      _rememberObservedFirstTokenLatency(
        chat,
        chat.observedFirstTokenLatencyMs,
      );
    }
    chat?.dispose();
    _refreshActiveIds();
  }

  void _refreshActiveIds() {
    final ids = <String>{};
    for (final entry in _chats.entries) {
      if (!entry.value.isStreaming) continue;
      final profile = entry.value.sessionProfile;
      ids.add(
        _registryKey(entry.value.connection.id, entry.value.sessionId, profile),
      );
      final storedId = entry.value.storedSessionId;
      if (storedId != null && storedId.isNotEmpty) {
        ids.add(_registryKey(entry.value.connection.id, storedId, profile));
      }
    }
    if (ids.length != activeIds.value.length ||
        !ids.containsAll(activeIds.value)) {
      activeIds.value = ids;
    }
  }

  void dispose() {
    for (final chat in _chats.values) {
      chat.dispose();
    }
    _chats.clear();
    _homeWidgetMetadata.clear();
    _observedFirstTokenLatencyCache.clear();
    activeIds.dispose();
  }
}
