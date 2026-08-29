import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/attachment_draft.dart';
import '../models/prepared_turn.dart';
import 'attachment_uploader.dart';

/// Contrato mínimo que consume el lifecycle de un turno activo. Permite probar
/// cada frontera sin Keystore ni red y mantiene la implementación cifrada como
/// detalle de [TurnOutboxStore].
abstract interface class TurnOutboxPersistence {
  Future<void> save(PreparedTurn turn);

  Future<void> delete(PreparedTurn turn);
}

/// Única vista permitida para diagnóstico: contadores y edad, nunca IDs,
/// texto, configuración, adjuntos o rutas de la outbox cifrada.
class TurnOutboxDiagnosticSummary {
  final Map<PreparedTurnState, int> counts;
  final int? oldestPendingUpdatedAtMs;

  const TurnOutboxDiagnosticSummary({
    required this.counts,
    required this.oldestPendingUpdatedAtMs,
  });
}

/// Outbox pequeña y cifrada. Una única clave evita mantener un índice sensible
/// en SharedPreferences. La cola estática serializa instancias del store dentro
/// del mismo isolate para no perder updates read-modify-write.
class TurnOutboxStore implements TurnOutboxPersistence {
  static const _storageKey = 'chat_turn_outbox_v1';
  static const maxAge = Duration(days: 30);
  static final Queue<Future<void> Function()> _operations = Queue();
  static bool _operationRunning = false;

  static String _profileOwner(String value) {
    final owner = value.trim();
    return owner.isEmpty ? 'default' : owner;
  }

  static PreparedTurn _normalizedTurn(PreparedTurn turn) {
    final owner = _profileOwner(turn.profile);
    return owner == turn.profile ? turn : turn.copyWith(profile: owner);
  }

  final FlutterSecureStorage _secure;
  final Future<bool> Function(AttachmentDraft) _deletePrivateCopy;

  TurnOutboxStore({
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
    Future<bool> Function(AttachmentDraft)? deletePrivateCopy,
  }) : _secure = secureStorage,
       _deletePrivateCopy =
           deletePrivateCopy ?? AttachmentUploader.deletePrivateDraftCopy;

  /// Cada widget test usa una zona FakeAsync distinta. Un Future estático que
  /// quedó ligado a la zona anterior no puede avanzar en la siguiente aunque
  /// ya estuviera completado. Producción tiene un único isolate/zona; este reset
  /// existe únicamente para aislar casos de prueba consecutivos.
  @visibleForTesting
  static void resetSerializationForTesting() {
    _operations.clear();
    _operationRunning = false;
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _operations.add(() async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    _drainOperations();
    return completer.future;
  }

  static void _drainOperations() {
    if (_operationRunning || _operations.isEmpty) return;
    _operationRunning = true;
    final operation = _operations.removeFirst();
    Future<void>.sync(operation).whenComplete(() {
      _operationRunning = false;
      _drainOperations();
    });
  }

  Future<Map<String, PreparedTurn>> _readAll() async {
    final raw = await _secure.read(key: _storageKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final result = <String, PreparedTurn>{};
      for (final entry in decoded.entries) {
        if (entry.value is! Map) continue;
        try {
          final turn = PreparedTurn.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
          if (entry.key == turn.storageId ||
              entry.key == turn.legacyStorageId) {
            final normalized = _normalizedTurn(turn);
            result[normalized.storageId] = normalized;
          }
        } catch (_) {
          // Entrada inválida: fail-closed y se elimina en la próxima escritura.
        }
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeAll(Map<String, PreparedTurn> turns) async {
    if (turns.isEmpty) {
      await _secure.delete(key: _storageKey);
      return;
    }
    await _secure.write(
      key: _storageKey,
      value: jsonEncode({
        for (final entry in turns.entries) entry.key: entry.value.toJson(),
      }),
    );
  }

  @override
  Future<void> save(PreparedTurn turn) => _serialized(() async {
    final turns = await _readAll();
    final normalized = _normalizedTurn(turn);
    final previous = turns[normalized.storageId];
    turns[normalized.storageId] = normalized;
    await _writeAll(turns);
    if (previous != null) await _cleanupUnowned(previous.attachments);
  });

  Future<List<PreparedTurn>> loadAllForChat(
    String connectionId,
    String sessionId, {
    String? profile,
  }) => _serialized(() async {
    final now = DateTime.now();
    final turns = await _readAll();
    final restored = <PreparedTurn>[];
    final cleanupCandidates = <AttachmentDraft>[];
    var changed = false;
    for (final entry in turns.entries.toList()) {
      final turn = entry.value;
      final age = now.difference(
        DateTime.fromMillisecondsSinceEpoch(turn.updatedAtMs),
      );
      if (age > maxAge || turn.state == PreparedTurnState.terminal) {
        turns.remove(entry.key);
        cleanupCandidates.addAll(turn.attachments);
        changed = true;
        continue;
      }
      if (turn.connectionId != connectionId ||
          turn.sessionId != sessionId ||
          (profile != null &&
              _profileOwner(turn.profile) != _profileOwner(profile))) {
        continue;
      }
      final validAttachments = <AttachmentDraft>[];
      var attachmentsChanged = false;
      for (final item in turn.attachments) {
        if (item.uploadState == AttachmentUploadState.removed) {
          cleanupCandidates.add(item);
          attachmentsChanged = true;
          changed = true;
          continue;
        }
        final hasLocalCopy =
            item.localPath.isNotEmpty && File(item.localPath).existsSync();
        final hasRemoteAssociation =
            item.uploadState == AttachmentUploadState.attached &&
            item.remoteRef?.isNotEmpty == true &&
            item.remoteSessionId?.isNotEmpty == true &&
            item.remoteTransport != null;
        if (!hasLocalCopy && !hasRemoteAssociation) {
          cleanupCandidates.add(item);
          attachmentsChanged = true;
          changed = true;
          continue;
        }
        if (item.uploadState == AttachmentUploadState.uploading) {
          validAttachments.add(
            item.copyWith(
              uploadState: AttachmentUploadState.error,
              errorKind: AttachmentErrorKind.interrupted,
            ),
          );
          attachmentsChanged = true;
          changed = true;
        } else {
          validAttachments.add(item);
        }
      }
      var candidate = attachmentsChanged
          ? turn.copyWith(attachments: validAttachments)
          : turn;
      if (candidate.state == PreparedTurnState.submitting) {
        candidate = candidate.copyWith(
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
          state: PreparedTurnState.ambiguous,
        );
        changed = true;
      }
      if (candidate.text.trim().isEmpty && candidate.attachments.isEmpty) {
        turns.remove(entry.key);
        cleanupCandidates.addAll(turn.attachments);
        changed = true;
        continue;
      }
      if (!identical(candidate, turn)) turns[entry.key] = candidate;
      restored.add(candidate);
    }
    restored.sort((left, right) {
      final byCreated = left.createdAtMs.compareTo(right.createdAtMs);
      return byCreated != 0
          ? byCreated
          : left.clientTurnId.compareTo(right.clientTurnId);
    });
    if (changed) await _writeAll(turns);
    await _cleanupUnowned(cleanupCandidates);
    return List<PreparedTurn>.unmodifiable(restored);
  });

  Future<PreparedTurn?> loadForChat(
    String connectionId,
    String sessionId, {
    String? profile,
  }) => _serialized(() async {
    final now = DateTime.now();
    final turns = await _readAll();
    var changed = false;
    final cleanupCandidates = <AttachmentDraft>[];
    PreparedTurn? newest;
    String? matchedProfile;
    var ambiguousOwners = false;
    for (final entry in turns.entries.toList()) {
      final turn = entry.value;
      final age = now.difference(
        DateTime.fromMillisecondsSinceEpoch(turn.updatedAtMs),
      );
      if (age > maxAge || turn.state == PreparedTurnState.terminal) {
        turns.remove(entry.key);
        cleanupCandidates.addAll(turn.attachments);
        changed = true;
        continue;
      }
      if (turn.connectionId != connectionId ||
          turn.sessionId != sessionId ||
          (profile != null &&
              _profileOwner(turn.profile) != _profileOwner(profile))) {
        continue;
      }
      final validAttachments = <AttachmentDraft>[];
      var attachmentsChanged = false;
      for (final item in turn.attachments) {
        if (item.uploadState == AttachmentUploadState.removed) {
          cleanupCandidates.add(item);
          changed = true;
          attachmentsChanged = true;
          continue;
        }
        final hasLocalCopy =
            item.localPath.isNotEmpty && File(item.localPath).existsSync();
        final hasRemoteAssociation =
            item.uploadState == AttachmentUploadState.attached &&
            item.remoteRef?.isNotEmpty == true &&
            item.remoteSessionId?.isNotEmpty == true &&
            item.remoteTransport != null;
        if (!hasLocalCopy && !hasRemoteAssociation) {
          cleanupCandidates.add(item);
          changed = true;
          attachmentsChanged = true;
          continue;
        }
        if (item.uploadState == AttachmentUploadState.uploading) {
          validAttachments.add(
            item.copyWith(
              uploadState: AttachmentUploadState.error,
              errorKind: AttachmentErrorKind.interrupted,
            ),
          );
          changed = true;
          attachmentsChanged = true;
        } else {
          validAttachments.add(item);
        }
      }
      var candidate = attachmentsChanged
          ? turn.copyWith(attachments: validAttachments)
          : turn;
      // Si el proceso murió mientras esperaba el ACK, no hay evidencia para
      // clasificarlo como no enviado. Se restaura como ambiguo y jamás se
      // reenvía automáticamente.
      if (candidate.state == PreparedTurnState.submitting) {
        candidate = candidate.copyWith(
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
          state: PreparedTurnState.ambiguous,
        );
        turns[entry.key] = candidate;
        changed = true;
      }
      if (candidate.text.trim().isEmpty && candidate.attachments.isEmpty) {
        turns.remove(entry.key);
        cleanupCandidates.addAll(turn.attachments);
        changed = true;
        continue;
      }
      if (!identical(candidate, turn)) {
        turns[entry.key] = candidate;
        changed = true;
      }
      if (profile == null) {
        final candidateOwner = _profileOwner(candidate.profile);
        if (matchedProfile != null && matchedProfile != candidateOwner) {
          ambiguousOwners = true;
        }
        matchedProfile ??= candidateOwner;
      }
      if (newest == null || candidate.updatedAtMs > newest.updatedAtMs) {
        newest = candidate;
      }
    }
    if (changed) await _writeAll(turns);
    await _cleanupUnowned(cleanupCandidates);
    return ambiguousOwners ? null : newest;
  });

  @override
  Future<void> delete(PreparedTurn turn) => _serialized(() async {
    final turns = await _readAll();
    final removed = turns.remove(_normalizedTurn(turn).storageId);
    if (removed != null) {
      await _writeAll(turns);
      await _cleanupUnowned(removed.attachments);
    }
  });

  Future<int> deleteForChat(
    String connectionId,
    String sessionId, {
    String? profile,
  }) => _serialized(() async {
    final turns = await _readAll();
    final before = turns.length;
    final removedAttachments = <AttachmentDraft>[];
    turns.removeWhere((_, turn) {
      final remove =
          turn.connectionId == connectionId &&
          turn.sessionId == sessionId &&
          (profile == null ||
              _profileOwner(turn.profile) == _profileOwner(profile));
      if (remove) removedAttachments.addAll(turn.attachments);
      return remove;
    });
    if (turns.length != before) await _writeAll(turns);
    await _cleanupUnowned(removedAttachments);
    return before - turns.length;
  });

  Future<int> deleteForConnection(String connectionId) => _serialized(() async {
    final turns = await _readAll();
    final before = turns.length;
    final removedAttachments = <AttachmentDraft>[];
    turns.removeWhere((_, turn) {
      final remove = turn.connectionId == connectionId;
      if (remove) removedAttachments.addAll(turn.attachments);
      return remove;
    });
    if (turns.length != before) await _writeAll(turns);
    await _cleanupUnowned(removedAttachments);
    return before - turns.length;
  });

  Future<int> prune() => _serialized(() async {
    final turns = await _readAll();
    final now = DateTime.now();
    final before = turns.length;
    final removedAttachments = <AttachmentDraft>[];
    turns.removeWhere((_, turn) {
      final expired =
          now.difference(
            DateTime.fromMillisecondsSinceEpoch(turn.updatedAtMs),
          ) >
          maxAge;
      final remove = expired || turn.state == PreparedTurnState.terminal;
      if (remove) removedAttachments.addAll(turn.attachments);
      return remove;
    });
    if (turns.length != before) await _writeAll(turns);
    await _cleanupUnowned(removedAttachments);
    return before - turns.length;
  });

  Future<TurnOutboxDiagnosticSummary> diagnosticSummary() =>
      _serialized(() async {
        final turns = await _readAll();
        final counts = <PreparedTurnState, int>{};
        int? oldest;
        for (final turn in turns.values) {
          counts.update(turn.state, (value) => value + 1, ifAbsent: () => 1);
          if (turn.state == PreparedTurnState.terminal) continue;
          oldest = oldest == null
              ? turn.updatedAtMs
              : oldest < turn.updatedAtMs
              ? oldest
              : turn.updatedAtMs;
        }
        return TurnOutboxDiagnosticSummary(
          counts: Map.unmodifiable(counts),
          oldestPendingUpdatedAtMs: oldest,
        );
      });

  Future<void> _cleanupUnowned(List<AttachmentDraft> candidates) async {
    if (candidates.isEmpty) return;
    late final Map<String, String> remaining;
    try {
      remaining = await _secure.readAll();
    } catch (_) {
      // Sin inventario completo no se puede demostrar ownership exclusivo.
      return;
    }
    final decoded = <Object?>[];
    for (final raw in remaining.values) {
      try {
        decoded.add(jsonDecode(raw));
      } catch (_) {}
    }
    final visitedPaths = <String>{};
    for (final candidate in candidates) {
      if (candidate.localPath.isEmpty ||
          !visitedPaths.add(candidate.localPath) ||
          decoded.any(
            (value) => _outboxReferencesAttachment(value, candidate),
          )) {
        continue;
      }
      await _deletePrivateCopy(candidate);
    }
  }
}

bool _outboxReferencesAttachment(Object? value, AttachmentDraft target) {
  if (value is List) {
    return value.any((item) => _outboxReferencesAttachment(item, target));
  }
  if (value is! Map) return false;
  final map = Map<String, dynamic>.from(value);
  if ((map['upload_state'] ?? '').toString() ==
      AttachmentUploadState.removed.name) {
    return false;
  }
  if ((map['local_path'] ?? '').toString() == target.localPath) {
    final storedId = (map['local_id'] ?? '').toString();
    if (storedId.isEmpty ||
        target.localId.isEmpty ||
        storedId == target.localId) {
      return true;
    }
  }
  return map.values.any(
    (nested) => _outboxReferencesAttachment(nested, target),
  );
}
