import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/session.dart';
import '../models/transcript_privacy_state.dart';
import '../utils/assistant_content.dart';
import '../utils/chat_turn.dart';
import 'session_deletion.dart';
import 'session_reconciler.dart';

final class _SanitizedTranscript {
  final List<Map<String, dynamic>> messages;
  final bool truncated;
  final bool olderHistoryTruncated;
  final bool hadValidMessage;

  const _SanitizedTranscript({
    required this.messages,
    required this.truncated,
    required this.olderHistoryTruncated,
    required this.hadValidMessage,
  });
}

/// Bounded public transcript plus evidence that its retained suffix is partial.
final class LocalTranscriptSnapshot {
  final List<Map<String, dynamic>> messages;
  final bool olderHistoryTruncated;
  final TranscriptPrivacyCheckpoint? privacyCheckpoint;

  const LocalTranscriptSnapshot({
    required this.messages,
    required this.olderHistoryTruncated,
    this.privacyCheckpoint,
  });
}

/// Persistencia LOCAL del transcript de chat para instancias localhost (bridge).
///
/// El agente local responde por el Mobile Bridge (`/bridge/chat` → `hermes -z`,
/// oneshot): cada turno es independiente y el agente NO conserva el historial de
/// la sesión server-side como el gateway remoto (`/api/sessions/{id}/messages`).
/// Por eso, al cerrar y reabrir el chat de una instancia local, `getMessages`
/// devolvería vacío (o fallaría) y la conversación se perdería.
///
/// Aquí guardamos los turnos conversacionales reales (user/assistant) por
/// conexión+sesión, en orden CRONOLÓGICO (más antiguo primero) — el mismo
/// contrato que devuelve la API remota — para poder reconstruir el chat sin
/// depender de un endpoint que no existe.
///
/// Los transcripts nuevos se escriben cifrados vía flutter_secure_storage. Las
/// claves históricas quedan conservadas pero fuera del alcance operativo; una
/// copia v3 previa en SharedPreferences solo se admite como fallback de lectura.
class LocalTranscriptStore {
  static const _storage = FlutterSecureStorage();
  static const _maxStoredMessages = 120;
  static const _maxEncodedBytes = 512 * 1024;

  static const _v3Prefix = 'hermes.transcript.v3.';
  static final Map<String, Future<void>> _writeTails = {};

  static Future<T> _serialize<T>(String key, Future<T> Function() operation) {
    final previous = _writeTails[key] ?? Future<void>.value();
    final completer = Completer<T>();
    late final Future<void> next;
    next = previous
        .catchError((_) {})
        .then((_) async {
          try {
            completer.complete(await operation());
          } catch (error, stackTrace) {
            completer.completeError(error, stackTrace);
          }
        })
        .whenComplete(() {
          if (identical(_writeTails[key], next)) _writeTails.remove(key);
        });
    _writeTails[key] = next;
    return completer.future;
  }

  static String _canonicalProfile(String? profile) =>
      profile == null || profile.isEmpty ? 'default' : profile;

  static String _scope(String value) => value.codeUnits
      .map((unit) => unit.toRadixString(16).padLeft(4, '0'))
      .join();

  static String? _unScope(String value) {
    if (value.length % 4 != 0 || !RegExp(r'^[0-9a-f]*$').hasMatch(value)) {
      return null;
    }
    return String.fromCharCodes([
      for (var offset = 0; offset < value.length; offset += 4)
        int.parse(value.substring(offset, offset + 4), radix: 16),
    ]);
  }

  static String _key(String connId, String sessionId, {String? profile}) =>
      '$_v3Prefix${_scope(connId)}.${_scope(_canonicalProfile(profile))}.${_scope(sessionId)}';

  static ({String connectionId, String profile, String sessionId})? _parseKey(
    String key,
  ) {
    if (!key.startsWith(_v3Prefix)) return null;
    final components = key.substring(_v3Prefix.length).split('.');
    if (components.length != 3) return null;
    final connectionId = _unScope(components[0]);
    final profile = _unScope(components[1]);
    final sessionId = _unScope(components[2]);
    if (connectionId == null ||
        profile == null ||
        sessionId == null ||
        _canonicalProfile(profile) != profile) {
      return null;
    }
    final parsed = (
      connectionId: connectionId,
      profile: profile,
      sessionId: sessionId,
    );
    return _key(
              parsed.connectionId,
              parsed.sessionId,
              profile: parsed.profile,
            ) ==
            key
        ? parsed
        : null;
  }

  /// Guarda el transcript a partir de la lista viva del chat ([ActiveChat]
  /// usa index 0 = más nuevo). Filtra placeholders del pipeline, errores y
  /// turnos vacíos: solo user/assistant con contenido. Si no queda nada, borra
  /// la entrada en vez de dejar un `[]`.
  static Future<LocalTranscriptSnapshot> saveFromNewestFirst(
    String connId,
    String sessionId,
    List<Map<String, dynamic>> messagesNewestFirst, {
    String? profile,
    LocalConversationLifecycle? lifecycle,
  }) {
    final owner = _canonicalProfile(profile);
    final snapshot = messagesNewestFirst
        .map((message) => Map<String, dynamic>.from(message))
        .toList(growable: false);
    final resource = LocalConversationResourceKey(
      connectionId: connId,
      profile: owner,
      sessionId: sessionId,
      physicalKey: _key(connId, sessionId, profile: owner),
    );
    late final LocalConversationOperation journalOperation;
    try {
      journalOperation = LocalConversationCleanupFence.admitOperation(
        connectionId: connId,
        profile: owner,
        sessionId: sessionId,
        lifecycle: lifecycle,
        kind: LocalConversationOperationKind.save,
        resources: [resource],
      );
    } catch (error, stackTrace) {
      return Future<LocalTranscriptSnapshot>.error(error, stackTrace);
    }
    return LocalConversationCleanupFence.write(
      connectionId: connId,
      profile: owner,
      sessionId: sessionId,
      lifecycle: lifecycle,
      admittedOperation: journalOperation,
      operation: () => _saveFromNewestFirstUnlocked(
        connId,
        sessionId,
        snapshot,
        profile: owner,
        operation: journalOperation,
        resource: resource,
      ),
    );
  }

  static Future<LocalTranscriptSnapshot> _saveFromNewestFirstUnlocked(
    String connId,
    String sessionId,
    List<Map<String, dynamic>> messagesNewestFirst, {
    String? profile,
    required LocalConversationOperation operation,
    required LocalConversationResourceKey resource,
  }) async {
    final key = _key(connId, sessionId, profile: profile);
    var previouslyTruncated = false;
    LocalTranscriptSnapshot? previous;
    final secureRaw = await _storage.read(key: key);
    LocalConversationCleanupFence.ensureOperationAllowed(operation);
    Object? previousRaw = secureRaw;
    if (secureRaw == null) {
      previousRaw = (await SharedPreferences.getInstance()).get(key);
      LocalConversationCleanupFence.ensureOperationAllowed(operation);
    }
    if (previousRaw is String && previousRaw.isNotEmpty) {
      try {
        previous = _decodeSnapshot(previousRaw);
        previouslyTruncated = previous.olderHistoryTruncated;
      } catch (_) {
        // A corrupt previous value is neither authority nor safe content.
      }
    }
    final bounded = _sanitizeAndBoundTranscript(
      messagesNewestFirst.reversed.where(
        (message) => message['_pipeline'] != true,
      ),
      olderHistoryTruncated: previouslyTruncated,
    );
    final clean = bounded.messages;
    if (clean.isEmpty) {
      if (previous?.privacyCheckpoint?.suppressedWindow == true) {
        final snapshot = LocalTranscriptSnapshot(
          messages: const [],
          olderHistoryTruncated: bounded.olderHistoryTruncated,
          privacyCheckpoint: previous!.privacyCheckpoint,
        );
        await _storage.write(key: key, value: _encodeSnapshot(snapshot));
        return snapshot;
      }
      if (bounded.hadValidMessage && bounded.olderHistoryTruncated) {
        final retained = previous?.messages ?? const <Map<String, dynamic>>[];
        final snapshot = LocalTranscriptSnapshot(
          messages: retained,
          olderHistoryTruncated: true,
          privacyCheckpoint: previous?.privacyCheckpoint,
        );
        await LocalConversationCleanupFence.commitEffect(
          operation: operation,
          resource: resource,
          mutation: () =>
              _storage.write(key: key, value: _encodeSnapshot(snapshot)),
        );
        return snapshot;
      }
      await LocalConversationCleanupFence.commitEffect(
        operation: operation,
        resource: resource,
        mutation: () => _clearUnlocked(connId, sessionId, profile: profile),
      );
      return const LocalTranscriptSnapshot(
        messages: [],
        olderHistoryTruncated: false,
      );
    }
    final snapshot = LocalTranscriptSnapshot(
      messages: clean,
      olderHistoryTruncated: bounded.olderHistoryTruncated,
      privacyCheckpoint: previous?.privacyCheckpoint,
    );
    await LocalConversationCleanupFence.commitEffect(
      operation: operation,
      resource: resource,
      mutation: () =>
          _storage.write(key: key, value: _encodeSnapshot(snapshot)),
    );
    return snapshot;
  }

  /// Commits evidence and its receipt under the exact transcript scope. The
  /// envelope contains only already-sanitized public rows and typed facts.
  static Future<LocalTranscriptSnapshot> savePrivacyCheckpoint(
    String connId,
    String sessionId,
    TranscriptPrivacyCheckpoint checkpoint, {
    String? profile,
    LocalConversationLifecycle? lifecycle,
  }) {
    final owner = _canonicalProfile(profile);
    if (checkpoint.connectionId != connId ||
        checkpoint.profile != owner ||
        checkpoint.storedSessionId != sessionId) {
      return Future.error(const FormatException('Privacy scope mismatch'));
    }
    final key = _key(connId, sessionId, profile: owner);
    final resource = LocalConversationResourceKey(
      connectionId: connId,
      profile: owner,
      sessionId: sessionId,
      physicalKey: key,
    );
    late final LocalConversationOperation journalOperation;
    try {
      journalOperation = LocalConversationCleanupFence.admitOperation(
        connectionId: connId,
        profile: owner,
        sessionId: sessionId,
        lifecycle: lifecycle,
        kind: LocalConversationOperationKind.projection,
        resources: [resource],
      );
    } catch (error, stackTrace) {
      return Future<LocalTranscriptSnapshot>.error(error, stackTrace);
    }
    return _serialize(key, () async {
      try {
        final secureRaw = await _storage.read(key: key);
        LocalConversationCleanupFence.ensureOperationAllowed(journalOperation);
        Object? raw = secureRaw;
        if (secureRaw == null) {
          raw = (await SharedPreferences.getInstance()).get(key);
          LocalConversationCleanupFence.ensureOperationAllowed(
            journalOperation,
          );
        }
        LocalTranscriptSnapshot previous = const LocalTranscriptSnapshot(
          messages: [],
          olderHistoryTruncated: false,
        );
        if (raw is String && raw.isNotEmpty) previous = _decodeSnapshot(raw);
        final oldCheckpoint = previous.privacyCheckpoint;
        final accepted =
            oldCheckpoint != null &&
                oldCheckpoint.revision > checkpoint.revision
            ? oldCheckpoint
            : checkpoint;
        final snapshot = LocalTranscriptSnapshot(
          messages: previous.messages,
          olderHistoryTruncated: previous.olderHistoryTruncated,
          privacyCheckpoint: accepted,
        );
        await LocalConversationCleanupFence.commitEffect(
          operation: journalOperation,
          resource: resource,
          mutation: () =>
              _storage.write(key: key, value: _encodeSnapshot(snapshot)),
        );
        if (LocalConversationCleanupFence.wasInvalidatedByCleanup(
              journalOperation,
            ) &&
            !LocalConversationCleanupFence.hasConfirmedCommitAfter(
              resource,
              journalOperation.admissionSequence,
            )) {
          await _clearUnlocked(connId, sessionId, profile: owner);
        }
        return snapshot;
      } finally {
        LocalConversationCleanupFence.completeOperation(journalOperation);
      }
    });
  }

  /// Lee el transcript guardado en orden CRONOLÓGICO (más antiguo primero),
  /// igual que la API remota; el llamador lo invierte si necesita newest-first.
  /// Si secure no contiene la clave v3 exacta, admite una copia v3 plaintext sin
  /// migrarla ni borrarla. La presencia secure siempre tiene precedencia.
  static Future<List<Map<String, dynamic>>> load(
    String connId,
    String sessionId, {
    String? profile,
  }) async =>
      (await loadSnapshot(connId, sessionId, profile: profile)).messages;

  /// Loads the retained public suffix and whether older local rows were capped.
  static Future<LocalTranscriptSnapshot> loadSnapshot(
    String connId,
    String sessionId, {
    String? profile,
  }) async {
    final key = _key(connId, sessionId, profile: profile);
    final secureRaw = await _storage.read(key: key);
    Object? raw = secureRaw;
    if (secureRaw == null) {
      final prefs = await SharedPreferences.getInstance();
      raw = prefs.get(key);
    }
    if (raw is! String || raw.isEmpty) {
      return const LocalTranscriptSnapshot(
        messages: [],
        olderHistoryTruncated: false,
      );
    }
    try {
      return _decodeSnapshot(raw);
    } catch (error) {
      debugPrint(
        '[transcript-store] transcript local corrupto, se descarta '
        '(${error.runtimeType})',
      );
      return const LocalTranscriptSnapshot(
        messages: [],
        olderHistoryTruncated: false,
      );
    }
  }

  static LocalTranscriptSnapshot _decodeSnapshot(String raw) {
    final decoded = jsonDecode(raw);
    final (messages, recordedTruncation) = switch (decoded) {
      List<Object?> list => (list, false),
      Map<Object?, Object?> envelope
          when (envelope['version'] == 1 || envelope['version'] == 2) &&
              envelope['messages'] is List<Object?> &&
              envelope['older_history_truncated'] is bool =>
        (
          envelope['messages']! as List<Object?>,
          envelope['older_history_truncated']! as bool,
        ),
      _ => throw const FormatException('Invalid transcript'),
    };
    final bounded = _sanitizeAndBoundTranscript(
      messages,
      olderHistoryTruncated: recordedTruncation,
    );
    final checkpoint = decoded is Map && decoded['version'] == 2
        ? TranscriptPrivacyCheckpoint.fromJson(decoded['privacy_checkpoint'])
        : null;
    if (decoded is Map &&
        decoded['version'] == 2 &&
        decoded.containsKey('privacy_checkpoint') &&
        decoded['privacy_checkpoint'] != null &&
        checkpoint == null) {
      throw const FormatException('Invalid privacy checkpoint');
    }
    return LocalTranscriptSnapshot(
      messages: bounded.messages,
      olderHistoryTruncated: bounded.olderHistoryTruncated,
      privacyCheckpoint: checkpoint,
    );
  }

  static String _encodeSnapshot(LocalTranscriptSnapshot snapshot) =>
      jsonEncode({
        'version': snapshot.privacyCheckpoint == null ? 1 : 2,
        'older_history_truncated': snapshot.olderHistoryTruncated,
        'messages': snapshot.messages,
        if (snapshot.privacyCheckpoint != null)
          'privacy_checkpoint': snapshot.privacyCheckpoint!.toJson(),
      });

  static Map<String, dynamic>? _sanitizeTranscriptMessage(Object? raw) {
    if (raw is! Map) return null;
    final message = Map<String, dynamic>.from(raw);
    final role = (message['role'] ?? '').toString().trim().toLowerCase();
    if (role != 'user' && role != 'assistant') return null;
    for (final key in const [
      'hidden',
      'is_hidden',
      'is_reasoning',
      'channel',
      'kind',
      'content_type',
    ]) {
      if (message.containsKey(key)) return null;
    }
    if (role == 'assistant' && message['reasoning'] == true) return null;
    final rawDisplayKind = message['display_kind']?.toString().trim() ?? '';
    if (rawDisplayKind == 'hidden' ||
        (rawDisplayKind.isNotEmpty &&
            rawDisplayKind != 'async_delegation_complete')) {
      return null;
    }
    final rawContent = message['content'];
    if (rawContent is! String || rawContent.trim().isEmpty) return null;
    final content = role == 'assistant'
        ? finalizedPublicAssistantText(rawContent)
        : rawContent;
    if (content.trim().isEmpty) return null;

    final sanitized = <String, dynamic>{'role': role, 'content': content};
    if (role == 'user' &&
        effectiveUserDisplayKind(message) == 'async_delegation_complete') {
      sanitized['display_kind'] = 'async_delegation_complete';
      final metadata = sanitizeDelegationDisplayMetadata(
        message['display_metadata'],
      );
      if (metadata != null) sanitized['display_metadata'] = metadata;
    }
    return sanitized;
  }

  static _SanitizedTranscript _sanitizeAndBoundTranscript(
    Iterable<Object?> rawMessages, {
    bool olderHistoryTruncated = false,
  }) {
    final messages = <Map<String, dynamic>>[];
    var truncated = false;
    var cappedOlderHistory = olderHistoryTruncated;
    var hadValidMessage = false;
    for (final raw in rawMessages) {
      final sanitized = _sanitizeTranscriptMessage(raw);
      if (sanitized == null) {
        truncated = true;
        continue;
      }
      hadValidMessage = true;
      messages.add(sanitized);
      if (messages.length > _maxStoredMessages) {
        messages.removeAt(0);
        truncated = true;
        cappedOlderHistory = true;
      }
    }
    while (messages.isNotEmpty &&
        utf8
                .encode(
                  _encodeSnapshot(
                    LocalTranscriptSnapshot(
                      messages: messages,
                      olderHistoryTruncated: cappedOlderHistory,
                    ),
                  ),
                )
                .length >
            _maxEncodedBytes) {
      messages.removeAt(0);
      truncated = true;
      cappedOlderHistory = true;
    }
    return _SanitizedTranscript(
      messages: List<Map<String, dynamic>>.unmodifiable(messages),
      truncated: truncated,
      olderHistoryTruncated: cappedOlderHistory,
      hadValidMessage: hadValidMessage,
    );
  }

  static Future<void> clear(
    String connId,
    String sessionId, {
    String? profile,
    LocalConversationLifecycle? lifecycle,
  }) {
    final owner = _canonicalProfile(profile);
    final resource = LocalConversationResourceKey(
      connectionId: connId,
      profile: owner,
      sessionId: sessionId,
      physicalKey: _key(connId, sessionId, profile: owner),
    );
    late final LocalConversationOperation journalOperation;
    try {
      journalOperation = LocalConversationCleanupFence.admitOperation(
        connectionId: connId,
        profile: owner,
        sessionId: sessionId,
        lifecycle: lifecycle,
        kind: LocalConversationOperationKind.clearExact,
        resources: [resource],
      );
    } catch (error, stackTrace) {
      return Future<void>.error(error, stackTrace);
    }
    return LocalConversationCleanupFence.write(
      connectionId: connId,
      profile: owner,
      sessionId: sessionId,
      lifecycle: lifecycle,
      admittedOperation: journalOperation,
      operation: () async {
        await LocalConversationCleanupFence.commitEffect(
          operation: journalOperation,
          resource: resource,
          mutation: () => _clearUnlocked(connId, sessionId, profile: owner),
        );
      },
    );
  }

  static Future<void> _clearUnlocked(
    String connId,
    String sessionId, {
    String? profile,
  }) async {
    final key = _key(connId, sessionId, profile: profile);
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await _storage.delete(key: key);
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(key) && !await prefs.remove(key)) {
        throw StateError('Failed to remove transcript');
      }
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  }

  static Future<int> _deleteMatching(
    bool Function(({String connectionId, String profile, String sessionId}))
    matches,
  ) async {
    Object? firstError;
    StackTrace? firstStackTrace;
    final keys = <String>{};
    SharedPreferences? prefs;

    void remember(Object error, StackTrace stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }

    try {
      prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        final identity = _parseKey(key);
        if (identity != null && matches(identity)) keys.add(key);
      }
    } catch (error, stackTrace) {
      remember(error, stackTrace);
    }
    try {
      final secure = await _storage.readAll();
      for (final key in secure.keys) {
        final identity = _parseKey(key);
        if (identity != null && matches(identity)) keys.add(key);
      }
    } catch (error, stackTrace) {
      remember(error, stackTrace);
    }
    for (final key in keys) {
      try {
        await _storage.delete(key: key);
      } catch (error, stackTrace) {
        remember(error, stackTrace);
      }
      try {
        if (prefs != null &&
            prefs.containsKey(key) &&
            !await prefs.remove(key)) {
          throw StateError('Failed to remove transcript');
        }
      } catch (error, stackTrace) {
        remember(error, stackTrace);
      }
    }
    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
    return keys.length;
  }

  static Future<int> deleteForProfile(String connId, String? profile) {
    final owner = _canonicalProfile(profile);
    return LocalConversationCleanupFence.cleanupProfile(
      connectionId: connId,
      profile: owner,
      operation: () => _deleteMatching(
        (identity) =>
            identity.connectionId == connId && identity.profile == owner,
      ),
    );
  }

  static Future<int> deleteForConnection(String connId) =>
      LocalConversationCleanupFence.cleanupConnection(
        connectionId: connId,
        operation: () =>
            _deleteMatching((identity) => identity.connectionId == connId),
      );

  /// Devuelve una [Session] mínima por cada transcript guardado para [connId],
  /// ordenadas de más reciente a más antigua. Permite mostrar el historial de
  /// chats locales en la home sin depender de `/api/sessions` (que el bridge
  /// no expone).
  static Future<List<Session>> listForConnection(
    String connId, {
    String? profile,
  }) async {
    final requestedOwner = profile == null ? null : _canonicalProfile(profile);
    final secure = await _storage.readAll();
    final prefs = await SharedPreferences.getInstance();
    final entries = <String, Object?>{
      for (final key in prefs.getKeys()) key: prefs.get(key),
      ...secure,
    };
    final sessions = <Session>[];
    for (final entry in entries.entries) {
      final identity = _parseKey(entry.key);
      if (identity == null || identity.connectionId != connId) continue;
      if (requestedOwner != null && identity.profile != requestedOwner) {
        continue;
      }
      final raw = entry.value;
      if (raw is! String || raw.isEmpty) continue;
      List<Map<String, dynamic>> msgs;
      try {
        msgs = _decodeSnapshot(raw).messages;
      } catch (error) {
        debugPrint(
          '[transcript-store] transcript de sesión corrupto, se omite '
          '(${error.runtimeType})',
        );
        continue;
      }
      if (msgs.isEmpty) continue;
      final lastAssistant = msgs.lastWhere(
        (m) => m['role'] == 'assistant',
        orElse: () => <String, dynamic>{},
      );
      final preview = ((lastAssistant['content'] as String?) ?? '').trim();
      double startedAt = 0;
      final mobMatch = RegExp(r'mob-(\d+)').firstMatch(identity.sessionId);
      if (mobMatch != null) {
        final ms = int.tryParse(mobMatch.group(1) ?? '') ?? 0;
        startedAt = ms / 1000.0;
      }
      sessions.add(
        Session(
          id: identity.sessionId,
          title: 'Chat local',
          model: 'hermes-agent',
          source: 'mobile-local',
          messageCount: msgs.length,
          isActive: false,
          profile: identity.profile,
          preview: preview.length > 120
              ? '${preview.substring(0, 120)}…'
              : preview,
          startedAt: startedAt,
          updatedAt: startedAt,
        ),
      );
    }
    sessions.sort(
      (a, b) =>
          (b.updatedAt ?? b.startedAt).compareTo(a.updatedAt ?? a.startedAt),
    );
    return sessions;
  }
}
