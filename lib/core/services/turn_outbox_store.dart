import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/attachment_draft.dart';
import '../models/prepared_turn.dart';
import 'attachment_uploader.dart';
import 'session_deletion.dart';

/// Contrato mínimo que consume el lifecycle de un turno activo. Permite probar
/// cada frontera sin Keystore ni red y mantiene la implementación cifrada como
/// detalle de [TurnOutboxStore].
abstract interface class TurnOutboxPersistence {
  Future<void> save(PreparedTurn turn);

  Future<void> delete(PreparedTurn turn);
}

/// Capacidad adicional para retirar un rechazo demostrado antes del ACK.
///
/// Se mantiene separada de [TurnOutboxPersistence] para no convertir un delete
/// genérico de fakes/otros stores en una promesa falsa de tombstone durable.
abstract interface class FailedPreparedTurnDiscardPersistence {
  Future<bool> discardFailedBeforeAcceptance(PreparedTurn turn);
}

final class _FailedPreparedTurnDiscard {
  static const recordType = 'failed_before_acceptance_discard';
  static const schemaVersion = 1;

  final String connectionId;
  final String profile;
  final String sessionId;
  final String clientTurnId;
  final int discardedAtMs;

  const _FailedPreparedTurnDiscard({
    required this.connectionId,
    required this.profile,
    required this.sessionId,
    required this.clientTurnId,
    required this.discardedAtMs,
  });

  String get identity =>
      jsonEncode([connectionId, profile, sessionId, clientTurnId]);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'record_type': recordType,
    'schema_version': schemaVersion,
    'connection_id': connectionId,
    'profile': profile,
    'session_id': sessionId,
    'client_turn_id': clientTurnId,
    'discarded_at_ms': discardedAtMs,
  };

  factory _FailedPreparedTurnDiscard.fromJson(Map<String, dynamic> json) {
    String requiredString(String key) {
      final value = (json[key] ?? '').toString();
      if (value.isEmpty) throw FormatException('Missing $key');
      return value;
    }

    if (json['record_type'] != recordType ||
        json['schema_version'] != schemaVersion) {
      throw const FormatException('Unsupported discard tombstone');
    }
    final discardedAtMs = (json['discarded_at_ms'] as num?)?.toInt() ?? 0;
    if (discardedAtMs <= 0) {
      throw const FormatException('Invalid discard timestamp');
    }
    return _FailedPreparedTurnDiscard(
      connectionId: requiredString('connection_id'),
      profile: requiredString('profile'),
      sessionId: requiredString('session_id'),
      clientTurnId: requiredString('client_turn_id'),
      discardedAtMs: discardedAtMs,
    );
  }
}

final class _TurnOutboxState {
  final Map<String, PreparedTurn> turns;
  final Map<String, _FailedPreparedTurnDiscard> discards;
  final Set<String> retiredDiscardIdentities;
  bool dirty;

  _TurnOutboxState({
    Map<String, PreparedTurn>? turns,
    Map<String, _FailedPreparedTurnDiscard>? discards,
  }) : turns = turns ?? <String, PreparedTurn>{},
       discards = discards ?? <String, _FailedPreparedTurnDiscard>{},
       retiredDiscardIdentities = <String>{},
       dirty = false;
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

final class _DeferredAttachmentCleanup {
  final AttachmentDraft attachment;
  final Future<void> Function(List<AttachmentDraft>) cleanup;

  const _DeferredAttachmentCleanup(this.attachment, this.cleanup);
}

/// Serializa el inventario compartido de copias privadas. La admisión es
/// síncrona: un save de outbox ya invocado precede a una limpieza posterior.
class AttachmentOwnershipCoordinator {
  static final Queue<Future<void> Function()> _operations = Queue();
  static bool _operationRunning = false;
  static final Map<int, List<AttachmentDraft>> _pendingOwners = {};
  static final Map<int, List<AttachmentDraft>> _producerOwners = {};
  static final List<_DeferredAttachmentCleanup> _deferredCleanups = [];
  static int _nextPendingOwner = 0;
  static final Object _ownershipZoneKey = Object();

  static int? reservePendingOwner(Iterable<AttachmentDraft> attachments) {
    final owned = attachments
        .where((item) => item.uploadState != AttachmentUploadState.removed)
        .toList(growable: false);
    if (owned.isEmpty) return null;
    final token = ++_nextPendingOwner;
    _pendingOwners[token] = owned;
    return token;
  }

  static Future<void> withdrawPendingOwner(
    int? token,
    Future<void> Function(List<AttachmentDraft>) cleanup,
  ) {
    if (token == null) return Future<void>.value();
    return serialize(() async {
      if (_pendingOwners.remove(token) == null) return;
      await _runReadyCleanups();
    });
  }

  static int? retainProducer(Iterable<AttachmentDraft> attachments) {
    final retained = attachments
        .where((item) => item.uploadState != AttachmentUploadState.removed)
        .toList(growable: false);
    if (retained.isEmpty) return null;
    final token = ++_nextPendingOwner;
    _producerOwners[token] = retained;
    return token;
  }

  static void updateProducerRetention(
    int? token,
    Iterable<AttachmentDraft> attachments,
  ) {
    if (token == null) return;
    _producerOwners[token] = attachments
        .where((item) => item.uploadState != AttachmentUploadState.removed)
        .toList(growable: false);
  }

  static Future<void> releaseProducer(
    int? token,
    Future<void> Function(List<AttachmentDraft>) cleanup,
  ) {
    if (token == null) return Future<void>.value();
    return serialize(() async {
      final released = _producerOwners.remove(token);
      if (released == null) return;
      for (final attachment in released) {
        deferCleanup(attachment, cleanup);
      }
      await _runReadyCleanups();
    });
  }

  static Future<void> _runReadyCleanups() async {
    final ready = _deferredCleanups
        .where((item) => !hasPendingOwner(item.attachment))
        .toList(growable: false);
    _deferredCleanups.removeWhere(ready.contains);
    for (final item in ready) {
      await item.cleanup([item.attachment]);
    }
  }

  static void deferCleanup(
    AttachmentDraft attachment,
    Future<void> Function(List<AttachmentDraft>) cleanup,
  ) {
    if (_deferredCleanups.any(
      (item) => _sameAttachment(item.attachment, attachment),
    )) {
      return;
    }
    _deferredCleanups.add(_DeferredAttachmentCleanup(attachment, cleanup));
  }

  static bool _sameAttachment(AttachmentDraft left, AttachmentDraft right) =>
      left.localPath == right.localPath;

  static bool hasPendingOwner(AttachmentDraft candidate) => [
    ..._pendingOwners.values,
    ..._producerOwners.values,
  ].expand((items) => items).any((item) => _sameAttachment(item, candidate));

  /// Returns null when any relevant ownership surface is unavailable or
  /// structurally unreadable; callers must then veto physical deletion.
  static Future<List<Object?>?> loadDurableReferences(
    FlutterSecureStorage secure, {
    SharedPreferences? preferences,
  }) async {
    try {
      final values = <Object?>[];
      final secureEntries = await secure.readAll();
      for (final entry in secureEntries.entries) {
        final relevant =
            entry.key == 'chat_turn_outbox_v1' ||
            entry.key.startsWith('chat_draft_v3.') ||
            entry.key.startsWith('chat_draft_v2_');
        if (!relevant) continue;
        final decoded = jsonDecode(entry.value);
        if (decoded is! Map) return null;
        values.add(decoded);
      }
      final prefs = preferences ?? await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        if (!key.startsWith('chat_draft_v1_')) continue;
        final raw = prefs.getString(key);
        if (raw == null) return null;
        final decoded = jsonDecode(raw);
        if (decoded is! Map) return null;
        values.add(decoded);
      }
      return values;
    } catch (_) {
      return null;
    }
  }

  static bool durableReferencesAttachment(
    Object? value,
    AttachmentDraft target,
  ) => _outboxReferencesAttachment(value, target);

  static Future<T> serialize<T>(Future<T> Function() operation) {
    if (Zone.current[_ownershipZoneKey] == true) {
      return Future<T>.sync(operation);
    }
    final completer = Completer<T>();
    _operations.add(() async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    _drain();
    return completer.future;
  }

  static void resetForTesting() {
    _operations.clear();
    _operationRunning = false;
    _pendingOwners.clear();
    _producerOwners.clear();
    _deferredCleanups.clear();
    _nextPendingOwner = 0;
  }

  static void _drain() {
    if (_operationRunning || _operations.isEmpty) return;
    _operationRunning = true;
    final operation = _operations.removeFirst();
    Future<void>.sync(
      () => runZoned(operation, zoneValues: {_ownershipZoneKey: true}),
    ).whenComplete(() {
      _operationRunning = false;
      _drain();
    });
  }
}

/// Outbox pequeña y cifrada. Una única clave evita mantener un índice sensible
/// en SharedPreferences. La cola compartida serializa el ownership de adjuntos
/// frente a los drafts dentro del mismo isolate.
class TurnOutboxStore
    implements TurnOutboxPersistence, FailedPreparedTurnDiscardPersistence {
  static const _storageKey = 'chat_turn_outbox_v1';
  static const _discardStoragePrefix = '@failed-before-acceptance-discard-v1:';
  static const maxAge = Duration(days: 30);
  static const discardTombstoneMaxAge = Duration(days: 30);
  static const maxDiscardTombstones = 64;

  @visibleForTesting
  static const storageKeyForTesting = _storageKey;
  static final Map<
    ({
      String connectionId,
      String profile,
      String sessionId,
      String clientTurnId,
    }),
    int
  >
  _mutationGenerations = {};

  static String _profileOwner(String value) {
    final owner = value.trim();
    return owner.isEmpty ? 'default' : owner;
  }

  static PreparedTurn _normalizedTurn(PreparedTurn turn) {
    final owner = _profileOwner(turn.profile);
    return owner == turn.profile ? turn : turn.copyWith(profile: owner);
  }

  static ({
    String connectionId,
    String profile,
    String sessionId,
    String clientTurnId,
  })
  _mutationScope(
    String connectionId,
    String profile,
    String sessionId,
    String clientTurnId,
  ) => (
    connectionId: connectionId,
    profile: _profileOwner(profile),
    sessionId: sessionId,
    clientTurnId: clientTurnId,
  );

  static int _currentMutationGeneration(
    ({
      String connectionId,
      String profile,
      String sessionId,
      String clientTurnId,
    })
    scope,
  ) => _mutationGenerations.putIfAbsent(scope, () => 0);

  static int _advanceMutationGeneration(
    ({
      String connectionId,
      String profile,
      String sessionId,
      String clientTurnId,
    })
    scope,
  ) => _mutationGenerations.update(
    scope,
    (value) => value + 1,
    ifAbsent: () => 1,
  );

  final FlutterSecureStorage _secure;
  final Future<bool> Function(AttachmentDraft) _deletePrivateCopy;
  final int Function() _nowMs;
  final LocalConversationLifecycle? lifecycle;

  TurnOutboxStore({
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
    Future<bool> Function(AttachmentDraft)? deletePrivateCopy,
    int Function()? nowMs,
    this.lifecycle,
  }) : _secure = secureStorage,
       _deletePrivateCopy =
           deletePrivateCopy ?? AttachmentUploader.deletePrivateDraftCopy,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Cada widget test usa una zona FakeAsync distinta. Un Future estático que
  /// quedó ligado a la zona anterior no puede avanzar en la siguiente aunque
  /// ya estuviera completado. Producción tiene un único isolate/zona; este reset
  /// existe únicamente para aislar casos de prueba consecutivos.
  @visibleForTesting
  static void resetSerializationForTesting() {
    AttachmentOwnershipCoordinator.resetForTesting();
    _mutationGenerations.clear();
  }

  Future<T> _serialized<T>(Future<T> Function() operation) =>
      AttachmentOwnershipCoordinator.serialize(operation);

  static String _discardStorageKey(String identity) =>
      '$_discardStoragePrefix${sha256.convert(utf8.encode(identity))}';

  static String _draftStorageScope(String value) =>
      base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  static String _linkedDraftStorageKey(_FailedPreparedTurnDiscard discard) =>
      'chat_draft_v3.${_draftStorageScope(discard.connectionId)}.'
      '${_draftStorageScope(discard.profile)}.'
      '${_draftStorageScope(discard.sessionId)}';

  Future<bool> _retireLinkedDraftBeforeDiscardEviction(
    _FailedPreparedTurnDiscard discard,
  ) async {
    final key = _linkedDraftStorageKey(discard);
    final raw = await _secure.read(key: key);
    if (raw == null || raw.isEmpty) return true;
    late final Map<String, dynamic> decoded;
    try {
      final value = jsonDecode(raw);
      if (value is! Map) return false;
      decoded = Map<String, dynamic>.from(value);
    } catch (_) {
      // Sin identidad legible no se borra ni el draft ni su valla.
      return false;
    }
    if ((decoded['preparedTurnClientTurnId'] ?? '').toString() !=
        discard.clientTurnId) {
      // La clave ya pertenece a un sucesor o a otro draft independiente.
      return true;
    }
    final attachments = <AttachmentDraft>[];
    try {
      for (final value in decoded['attachments'] as List? ?? const []) {
        if (value is! Map) return false;
        attachments.add(
          AttachmentDraft.fromJson(Map<String, dynamic>.from(value)),
        );
      }
    } catch (_) {
      return false;
    }
    // Orden seguro de compactación: draft primero, tombstone después. Un
    // process death entre ambos deja una valla redundante, nunca resurrección.
    await _secure.delete(key: key);
    await _cleanupUnowned(attachments);
    return true;
  }

  Future<void> _pruneDiscards(_TurnOutboxState state) async {
    final oldestAllowed = _nowMs() - discardTombstoneMaxAge.inMilliseconds;
    List<_FailedPreparedTurnDiscard> oldestFirst() =>
        state.discards.values.toList(growable: false)..sort((left, right) {
          final byTime = left.discardedAtMs.compareTo(right.discardedAtMs);
          return byTime != 0 ? byTime : left.identity.compareTo(right.identity);
        });
    final attempted = <String>{};
    for (final discard in oldestFirst().where(
      (discard) => discard.discardedAtMs < oldestAllowed,
    )) {
      attempted.add(discard.identity);
      if (await _retireLinkedDraftBeforeDiscardEviction(discard)) {
        state.discards.remove(discard.identity);
        state.retiredDiscardIdentities.add(discard.identity);
        state.dirty = true;
      }
    }
    for (final discard in oldestFirst()) {
      if (state.discards.length <= maxDiscardTombstones) break;
      if (!attempted.add(discard.identity)) continue;
      if (!await _retireLinkedDraftBeforeDiscardEviction(discard)) continue;
      state.discards.remove(discard.identity);
      state.retiredDiscardIdentities.add(discard.identity);
      state.dirty = true;
    }
  }

  Future<_TurnOutboxState> _readState({bool failOnCorruption = false}) async {
    final raw = await _secure.read(key: _storageKey);
    if (raw == null || raw.isEmpty) return _TurnOutboxState();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid turn outbox');
      }
      final state = _TurnOutboxState();
      for (final entry in decoded.entries) {
        if (entry.value is! Map) {
          if (failOnCorruption) {
            throw const FormatException('Invalid turn outbox entry');
          }
          throw StateError('Encrypted turn outbox contains an invalid entry');
        }
        try {
          final value = Map<String, dynamic>.from(entry.value as Map);
          if (entry.key.startsWith(_discardStoragePrefix) ||
              value.containsKey('record_type')) {
            final discard = _FailedPreparedTurnDiscard.fromJson(value);
            if (entry.key != _discardStorageKey(discard.identity)) {
              throw const FormatException('Invalid discard identity');
            }
            if (state.discards.containsKey(discard.identity)) {
              throw const FormatException('Duplicate discard identity');
            }
            state.discards[discard.identity] = discard;
            continue;
          }
          final turn = PreparedTurn.fromJson(value);
          if (entry.key != turn.storageId &&
              entry.key != turn.legacyStorageId) {
            if (failOnCorruption) {
              throw const FormatException('Invalid turn outbox identity');
            }
            throw StateError('Encrypted turn outbox identity mismatch');
          }
          final normalized = _normalizedTurn(turn);
          final existing = state.turns[normalized.storageId];
          if (existing != null &&
              jsonEncode(existing.toJson()) !=
                  jsonEncode(normalized.toJson())) {
            if (failOnCorruption) {
              throw const FormatException('Invalid turn outbox identity');
            }
            throw StateError('Encrypted turn outbox identity collision');
          }
          state.turns[normalized.storageId] = normalized;
        } on StateError {
          rethrow;
        } on FormatException {
          rethrow;
        } catch (_) {
          if (failOnCorruption) {
            throw const FormatException('Invalid turn outbox entry');
          }
          throw StateError('Encrypted turn outbox contains an invalid entry');
        }
      }
      await _pruneDiscards(state);
      return state;
    } on StateError {
      rethrow;
    } on FormatException {
      if (failOnCorruption) rethrow;
      throw StateError('Encrypted turn outbox cannot be read safely');
    } catch (_) {
      if (failOnCorruption) {
        throw const FormatException('Corrupt turn outbox');
      }
      throw StateError('Encrypted turn outbox cannot be read safely');
    }
  }

  Future<void> _writeState(_TurnOutboxState state) async {
    if (state.turns.isEmpty && state.discards.isEmpty) {
      await _secure.delete(key: _storageKey);
      return;
    }
    await _secure.write(
      key: _storageKey,
      value: jsonEncode({
        for (final entry in state.turns.entries)
          entry.key: entry.value.toJson(),
        for (final discard in state.discards.values)
          _discardStorageKey(discard.identity): discard.toJson(),
      }),
    );
    state.dirty = false;
  }

  @override
  Future<void> save(PreparedTurn turn) {
    final normalized = _normalizedTurn(turn);
    final scope = _mutationScope(
      normalized.connectionId,
      normalized.profile,
      normalized.sessionId,
      normalized.clientTurnId,
    );
    final admittedGeneration = _currentMutationGeneration(scope);
    final resource = LocalConversationResourceKey(
      connectionId: normalized.connectionId,
      profile: normalized.profile,
      sessionId: normalized.sessionId,
      clientTurnId: normalized.clientTurnId,
      physicalKey: _storageKey,
    );
    late final LocalConversationOperation journalOperation;
    try {
      journalOperation = LocalConversationCleanupFence.admitOperation(
        connectionId: normalized.connectionId,
        profile: normalized.profile,
        sessionId: normalized.sessionId,
        clientTurnId: normalized.clientTurnId,
        lifecycle: lifecycle,
        kind: LocalConversationOperationKind.save,
        resources: [resource],
      );
    } catch (error, stackTrace) {
      return Future<void>.error(error, stackTrace);
    }
    final pendingOwner = AttachmentOwnershipCoordinator.reservePendingOwner(
      normalized.attachments,
    );
    final saving = LocalConversationCleanupFence.write(
      connectionId: normalized.connectionId,
      profile: normalized.profile,
      sessionId: normalized.sessionId,
      lifecycle: lifecycle,
      admittedOperation: journalOperation,
      operation: () => _serialized(() async {
        LocalConversationCleanupFence.ensureOperationAllowed(journalOperation);
        if (_currentMutationGeneration(scope) != admittedGeneration) return;
        final state = await _readState();
        LocalConversationCleanupFence.ensureOperationAllowed(journalOperation);
        // El tombstone es la autoridad del descarte, no una optimización de
        // delete. Un callback P0 que se admite después del descarte ve aquí
        // la identidad exacta y queda en no-op; un clientTurnId nuevo sí entra.
        if (state.discards.containsKey(normalized.storageId) ||
            state.retiredDiscardIdentities.contains(normalized.storageId)) {
          if (state.dirty) await _writeState(state);
          return;
        }
        final previous = state.turns[normalized.storageId];
        state.turns[normalized.storageId] = normalized;
        final committed = await LocalConversationCleanupFence.commitEffect(
          operation: journalOperation,
          resource: resource,
          mutation: () => _writeState(state),
        );
        if (committed && previous != null) {
          await _cleanupUnowned(previous.attachments);
        }
      }),
    );
    return saving.whenComplete(
      () => AttachmentOwnershipCoordinator.withdrawPendingOwner(
        pendingOwner,
        _cleanupUnowned,
      ),
    );
  }

  Future<List<PreparedTurn>> loadAllForChat(
    String connectionId,
    String sessionId, {
    String? profile,
  }) => _serialized(() async {
    if (profile == null) {
      throw StateError('A canonical profile is required for outbox recovery');
    }
    final outboxState = await _readState();
    final turns = outboxState.turns;
    final restored = <PreparedTurn>[];
    final cleanupCandidates = <AttachmentDraft>[];
    var changed = outboxState.dirty;
    for (final entry in turns.entries.toList()) {
      final turn = entry.value;
      if (turn.state == PreparedTurnState.terminal) {
        turns.remove(entry.key);
        cleanupCandidates.addAll(turn.attachments);
        changed = true;
        continue;
      }
      if (turn.connectionId != connectionId ||
          turn.sessionId != sessionId ||
          _profileOwner(turn.profile) != _profileOwner(profile)) {
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
          validAttachments.add(
            item.copyWith(
              uploadState: AttachmentUploadState.error,
              errorKind: AttachmentErrorKind.missingFile,
            ),
          );
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
      if (candidate.queued && candidate.queueOrder == null) {
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
    final orderCounts = <int, int>{};
    for (final turn in restored) {
      final order = turn.queueOrder;
      if (turn.queued && order != null) {
        orderCounts.update(order, (value) => value + 1, ifAbsent: () => 1);
      }
    }
    for (var index = 0; index < restored.length; index++) {
      final turn = restored[index];
      final order = turn.queueOrder;
      if (turn.queued && order != null && orderCounts[order]! > 1) {
        final ambiguous = turn.copyWith(
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
          state: PreparedTurnState.ambiguous,
        );
        restored[index] = ambiguous;
        turns[ambiguous.storageId] = ambiguous;
        changed = true;
      }
    }
    restored.sort((left, right) {
      final leftOrder = left.queueOrder;
      final rightOrder = right.queueOrder;
      if (!left.queued && !right.queued) {
        final byCreated = left.createdAtMs.compareTo(right.createdAtMs);
        return byCreated != 0
            ? byCreated
            : left.clientTurnId.compareTo(right.clientTurnId);
      }
      if (leftOrder == null && rightOrder == null) return 0;
      if (leftOrder == null) return -1;
      if (rightOrder == null) return 1;
      return leftOrder.compareTo(rightOrder);
    });
    if (changed) await _writeState(outboxState);
    await _cleanupUnowned(cleanupCandidates);
    return List<PreparedTurn>.unmodifiable(restored);
  });

  Future<PreparedTurn?> loadForChat(
    String connectionId,
    String sessionId, {
    String? profile,
  }) => _serialized(() async {
    final outboxState = await _readState();
    final turns = outboxState.turns;
    var changed = outboxState.dirty;
    final cleanupCandidates = <AttachmentDraft>[];
    PreparedTurn? newest;
    String? matchedProfile;
    var ambiguousOwners = false;
    for (final entry in turns.entries.toList()) {
      final turn = entry.value;
      if (turn.state == PreparedTurnState.terminal) {
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
          validAttachments.add(
            item.copyWith(
              uploadState: AttachmentUploadState.error,
              errorKind: AttachmentErrorKind.missingFile,
            ),
          );
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
    if (changed) await _writeState(outboxState);
    await _cleanupUnowned(cleanupCandidates);
    return ambiguousOwners ? null : newest;
  });

  @override
  Future<void> delete(PreparedTurn turn) {
    final normalized = _normalizedTurn(turn);
    _advanceMutationGeneration(
      _mutationScope(
        normalized.connectionId,
        normalized.profile,
        normalized.sessionId,
        normalized.clientTurnId,
      ),
    );
    return _serialized(() async {
      final state = await _readState();
      final removed = state.turns.remove(normalized.storageId);
      if (removed != null) {
        await _writeState(state);
        await _cleanupUnowned(removed.attachments);
      } else if (state.dirty) {
        await _writeState(state);
      }
    });
  }

  @override
  Future<bool> discardFailedBeforeAcceptance(PreparedTurn turn) {
    final normalized = _normalizedTurn(turn);
    if (normalized.state != PreparedTurnState.failedBeforeAcceptance ||
        !normalized.restoresComposer) {
      return Future<bool>.value(false);
    }
    final scope = _mutationScope(
      normalized.connectionId,
      normalized.profile,
      normalized.sessionId,
      normalized.clientTurnId,
    );
    // Invalida de forma síncrona todo save que ya fue admitido pero todavía
    // no entregó su efecto. Los saves admitidos después quedan cercados por el
    // tombstone cifrado que se consulta dentro de la misma cola serializada.
    _advanceMutationGeneration(scope);
    return _serialized(() async {
      final state = await _readState(failOnCorruption: true);
      final existingDiscard = state.discards[normalized.storageId];
      if (existingDiscard != null ||
          state.retiredDiscardIdentities.contains(normalized.storageId)) {
        if (state.dirty) await _writeState(state);
        return true;
      }
      final stored = state.turns[normalized.storageId];
      if (stored != null &&
          (stored.state != PreparedTurnState.failedBeforeAcceptance ||
              !stored.restoresComposer)) {
        if (state.dirty) await _writeState(state);
        return false;
      }
      final discard = _FailedPreparedTurnDiscard(
        connectionId: normalized.connectionId,
        profile: normalized.profile,
        sessionId: normalized.sessionId,
        clientTurnId: normalized.clientTurnId,
        discardedAtMs: _nowMs(),
      );
      final removed = state.turns.remove(normalized.storageId);
      state.discards[discard.identity] = discard;
      await _pruneDiscards(state);
      await _writeState(state);
      if (removed != null) await _cleanupUnowned(removed.attachments);
      return true;
    });
  }

  Future<bool> isFailedBeforeAcceptanceDiscarded({
    required String connectionId,
    required String profile,
    required String sessionId,
    required String clientTurnId,
  }) => _serialized(() async {
    final identity = jsonEncode([
      connectionId,
      _profileOwner(profile),
      sessionId,
      clientTurnId,
    ]);
    final state = await _readState(failOnCorruption: true);
    final discarded =
        state.discards.containsKey(identity) ||
        state.retiredDiscardIdentities.contains(identity);
    if (state.dirty) await _writeState(state);
    return discarded;
  });

  Future<int> deleteForChat(
    String connectionId,
    String sessionId, {
    String? profile,
  }) {
    for (final scope
        in _mutationGenerations.keys
            .where(
              (scope) =>
                  scope.connectionId == connectionId &&
                  scope.sessionId == sessionId &&
                  (profile == null || scope.profile == _profileOwner(profile)),
            )
            .toList(growable: false)) {
      _advanceMutationGeneration(scope);
    }
    return _serialized(() async {
      final state = await _readState(failOnCorruption: true);
      final turns = state.turns;
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
      final discardsBefore = state.discards.length;
      state.discards.removeWhere(
        (_, discard) =>
            discard.connectionId == connectionId &&
            discard.sessionId == sessionId &&
            (profile == null || discard.profile == _profileOwner(profile)),
      );
      if (turns.length != before ||
          state.discards.length != discardsBefore ||
          state.dirty) {
        await _writeState(state);
      }
      await _cleanupUnowned(removedAttachments);
      return before - turns.length;
    });
  }

  Future<int> deleteForProfile(String connectionId, String profile) {
    final owner = _profileOwner(profile);
    return LocalConversationCleanupFence.cleanupProfile(
      connectionId: connectionId,
      profile: owner,
      operation: () => _serialized(() async {
        final state = await _readState(failOnCorruption: true);
        final turns = state.turns;
        final before = turns.length;
        final removedAttachments = <AttachmentDraft>[];
        turns.removeWhere((_, turn) {
          final remove =
              turn.connectionId == connectionId &&
              _profileOwner(turn.profile) == owner;
          if (remove) removedAttachments.addAll(turn.attachments);
          return remove;
        });
        final discardsBefore = state.discards.length;
        state.discards.removeWhere(
          (_, discard) =>
              discard.connectionId == connectionId && discard.profile == owner,
        );
        if (turns.length != before ||
            state.discards.length != discardsBefore ||
            state.dirty) {
          await _writeState(state);
        }
        await _cleanupUnowned(removedAttachments);
        return before - turns.length;
      }),
    );
  }

  Future<int> deleteForConnection(String connectionId) =>
      LocalConversationCleanupFence.cleanupConnection(
        connectionId: connectionId,
        operation: () => _serialized(() async {
          final state = await _readState(failOnCorruption: true);
          final turns = state.turns;
          final before = turns.length;
          final removedAttachments = <AttachmentDraft>[];
          turns.removeWhere((_, turn) {
            final remove = turn.connectionId == connectionId;
            if (remove) removedAttachments.addAll(turn.attachments);
            return remove;
          });
          final discardsBefore = state.discards.length;
          state.discards.removeWhere(
            (_, discard) => discard.connectionId == connectionId,
          );
          if (turns.length != before ||
              state.discards.length != discardsBefore ||
              state.dirty) {
            await _writeState(state);
          }
          await _cleanupUnowned(removedAttachments);
          return before - turns.length;
        }),
      );

  Future<int> prune() => _serialized(() async {
    final state = await _readState();
    final turns = state.turns;
    final before = turns.length;
    final removedAttachments = <AttachmentDraft>[];
    turns.removeWhere((_, turn) {
      final remove = turn.state == PreparedTurnState.terminal;
      if (remove) removedAttachments.addAll(turn.attachments);
      return remove;
    });
    if (turns.length != before || state.dirty) await _writeState(state);
    await _cleanupUnowned(removedAttachments);
    return before - turns.length;
  });

  Future<TurnOutboxDiagnosticSummary> diagnosticSummary() =>
      _serialized(() async {
        final state = await _readState();
        final turns = state.turns;
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
        if (state.dirty) await _writeState(state);
        return TurnOutboxDiagnosticSummary(
          counts: Map.unmodifiable(counts),
          oldestPendingUpdatedAtMs: oldest,
        );
      });

  Future<void> _cleanupUnowned(List<AttachmentDraft> candidates) async {
    if (candidates.isEmpty) return;
    final decoded = await AttachmentOwnershipCoordinator.loadDurableReferences(
      _secure,
    );
    if (decoded == null) return;
    final visitedPaths = <String>{};
    for (final candidate in candidates) {
      if (candidate.localPath.isEmpty ||
          !visitedPaths.add(candidate.localPath)) {
        continue;
      }
      if (AttachmentOwnershipCoordinator.hasPendingOwner(candidate)) {
        AttachmentOwnershipCoordinator.deferCleanup(candidate, _cleanupUnowned);
        continue;
      }
      if (decoded.any(
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
    // Logical IDs cannot prove two references name different physical files.
    return true;
  }
  return map.values.any(
    (nested) => _outboxReferencesAttachment(nested, target),
  );
}
