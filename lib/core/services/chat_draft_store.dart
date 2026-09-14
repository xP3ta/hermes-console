import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/attachment_draft.dart';
import '../models/session.dart';
import 'attachment_uploader.dart';
import 'session_deletion.dart';
import 'turn_outbox_store.dart';

enum MissionRoomTaskPhase { prepared, submitting, outcomeUnknown }

class ChatDraft {
  final String text;
  final List<AttachmentDraft> attachments;
  final String? preparedTurnClientTurnId;
  final String? missionRoomIntentId;
  final String? missionRoomWorkerProfile;
  final String? missionRoomBoardId;
  final String? missionRoomBoardQuery;
  final MissionRoomTaskPhase? missionRoomTaskPhase;

  const ChatDraft({
    required this.text,
    required this.attachments,
    this.preparedTurnClientTurnId,
    this.missionRoomIntentId,
    this.missionRoomWorkerProfile,
    this.missionRoomBoardId,
    this.missionRoomBoardQuery,
    this.missionRoomTaskPhase,
  });

  bool get missionRoomOutcomeUnknown =>
      missionRoomTaskPhase == MissionRoomTaskPhase.outcomeUnknown;

  bool get hasMissionRoomOperation =>
      missionRoomIntentId != null ||
      missionRoomWorkerProfile != null ||
      missionRoomBoardId != null ||
      missionRoomBoardQuery != null ||
      missionRoomTaskPhase != null;
}

/// Entrada recuperable de un chat que todavía no existe en el servidor.
///
/// El índice se deriva directamente de las claves cifradas del Keystore: no se
/// duplica texto, nombres de archivo ni previews sensibles en SharedPreferences.
class ChatDraftEntry {
  final String sessionId;
  final String profile;
  final DateTime savedAt;
  final ChatDraft draft;

  const ChatDraftEntry({
    required this.sessionId,
    this.profile = 'default',
    required this.savedAt,
    required this.draft,
  });

  Session toSession({required String fallbackTitle}) {
    final textTitle = Session.titleFromText(draft.text);
    final attachmentTitle = draft.attachments.isEmpty
        ? ''
        : draft.attachments.first.name.trim();
    final title = textTitle.isNotEmpty
        ? textTitle
        : attachmentTitle.isNotEmpty
        ? attachmentTitle
        : fallbackTitle;
    return Session(
      id: sessionId,
      title: title,
      model: 'hermes-agent',
      source: 'mobile-draft',
      messageCount: 0,
      isActive: false,
      preview: draft.text,
      startedAt: savedAt.millisecondsSinceEpoch / 1000,
      updatedAt: savedAt.millisecondsSinceEpoch / 1000,
      profile: profile,
      hasLocalDraft: true,
    );
  }
}

/// Borrador local cifrado por instancia y sesión. El texto puede contener datos
/// sensibles aunque no sea una credencial, por eso vive en el Keystore y no en
/// SharedPreferences. Las rutas SAF/caché se validan al restaurar porque Android
/// puede revocarlas o borrarlas.
typedef ChatDraftChange = ({
  String connectionId,
  String profile,
  String sessionId,
});

class ChatDraftStore {
  static final _changes = StreamController<ChatDraftChange>.broadcast();

  /// Invalidation only, emitted after a confirmed mutation; never draft text.
  static Stream<ChatDraftChange> get changes => _changes.stream;

  // Secure storage operations are asynchronous and Android may complete an
  // older write after a newer delete. Serialize mutations by the exact
  // connection/profile/session key so an autosave can never resurrect a draft
  // that an acknowledged send already cleared. Static scope also covers the
  // short window where two widget lifecycles construct separate store objects.
  static final Map<String, Future<void>> _mutationTails = {};
  static final Map<String, int> _mutationGenerations = {};
  static final Map<
    String,
    ({String connectionId, String profile, String sessionId})
  >
  _mutationIdentities = {};

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;
  final Future<bool> Function(AttachmentDraft) _deletePrivateCopy;
  final String mutationNamespaceForTesting;

  ChatDraftStore(
    this._prefs, {
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
    Future<bool> Function(AttachmentDraft)? deletePrivateCopy,
    this.mutationNamespaceForTesting = '',
  }) : _secure = secureStorage,
       _deletePrivateCopy =
           deletePrivateCopy ?? AttachmentUploader.deletePrivateDraftCopy;

  static String _scope(String value) =>
      base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  static String _unScope(String value) {
    final padded = value.padRight((value.length + 3) ~/ 4 * 4, '=');
    return utf8.decode(base64Url.decode(padded));
  }

  static bool _isDedicatedSurfaceScope(String value) =>
      value.startsWith('mob-bot-') || value.startsWith('mob-room-');

  static bool _belongsToDedicatedSurface(String sessionId, String owner) =>
      _isDedicatedSurfaceScope(sessionId) || _isDedicatedSurfaceScope(owner);

  String _key(String connectionId, String sessionId, String profile) =>
      'chat_draft_v3.${_scope(connectionId)}.${_scope(profile)}.${_scope(sessionId)}';

  String _mutationScope(String key) => mutationNamespaceForTesting.isEmpty
      ? key
      : '$mutationNamespaceForTesting\u0000$key';

  static Future<T> _serializeMutation<T>(
    String scope,
    Future<T> Function() action,
  ) async {
    final previous = _mutationTails[scope];
    final gate = Completer<void>();
    final tail = gate.future;
    _mutationTails[scope] = tail;
    if (previous != null) {
      await previous;
    }
    try {
      return await action();
    } finally {
      gate.complete();
      if (identical(_mutationTails[scope], tail)) {
        _mutationTails.remove(scope);
      }
    }
  }

  static int _currentMutationGeneration(String scope) =>
      _mutationGenerations[scope] ?? 0;

  static int _advanceMutationGeneration(String scope) => _mutationGenerations
      .update(scope, (value) => value + 1, ifAbsent: () => 1);

  static String keyForTesting(
    String connectionId,
    String sessionId, {
    String profile = 'default',
  }) =>
      'chat_draft_v3.${_scope(connectionId)}.${_scope(profile)}.${_scope(sessionId)}';

  static const Duration maxAge = Duration(days: 30);

  ChatDraftEntry? _decodeEntry(String sessionId, String profile, String raw) {
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final savedAt = DateTime.fromMillisecondsSinceEpoch(
        (data['savedAt'] as num?)?.toInt() ?? 0,
      );
      final roomTaskPhase = _taskPhase(data['missionRoomTaskPhase']);
      final unresolvedRoomWrite =
          roomTaskPhase == MissionRoomTaskPhase.submitting ||
          roomTaskPhase == MissionRoomTaskPhase.outcomeUnknown;
      if (savedAt.millisecondsSinceEpoch <= 0 ||
          (!unresolvedRoomWrite &&
              DateTime.now().difference(savedAt) > maxAge)) {
        return null;
      }
      final attachments = <AttachmentDraft>[];
      for (final item in (data['attachments'] as List? ?? const [])) {
        if (item is! Map) continue;
        final draft = AttachmentDraft.fromJson(Map<String, dynamic>.from(item));
        if (draft.uploadState == AttachmentUploadState.removed) continue;
        final hasLocalCopy =
            draft.localPath.isNotEmpty && File(draft.localPath).existsSync();
        final hasReusableRemote =
            draft.uploadState == AttachmentUploadState.attached &&
            draft.remoteRef?.isNotEmpty == true &&
            draft.remoteSessionId?.isNotEmpty == true;
        if (hasLocalCopy || hasReusableRemote) {
          attachments.add(draft);
        }
      }
      final draft = ChatDraft(
        text: (data['text'] ?? '').toString(),
        attachments: attachments,
        preparedTurnClientTurnId: _safeOpaqueIdentity(
          data['preparedTurnClientTurnId'],
        ),
        missionRoomIntentId: _safeMetadata(
          data['missionRoomIntentId'],
          maxLength: 128,
        ),
        missionRoomWorkerProfile: _safeMetadata(
          data['missionRoomWorkerProfile'],
          maxLength: 64,
          pattern: RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$'),
        ),
        missionRoomBoardId: _safeMetadata(
          data['missionRoomBoardId'],
          maxLength: 128,
        ),
        missionRoomBoardQuery: _safeMetadata(
          data['missionRoomBoardQuery'],
          maxLength: 128,
        ),
        missionRoomTaskPhase: roomTaskPhase,
      );
      if (draft.text.isEmpty && draft.attachments.isEmpty) return null;
      return ChatDraftEntry(
        sessionId: sessionId,
        profile: profile,
        savedAt: savedAt,
        draft: draft,
      );
    } catch (_) {
      return null;
    }
  }

  Future<ChatDraft> load(
    String connectionId,
    String sessionId, {
    String profile = 'default',
    // Conservado para compatibilidad; V1/V2 no tienen ownership demostrable.
    bool claimUnscopedLegacy = false,
  }) async {
    await LocalConversationCleanupFence.waitForSessionClears(
      connectionId: connectionId,
      sessionId: sessionId,
    );
    final owner = profile.trim().isEmpty ? 'default' : profile.trim();
    final key = _key(connectionId, sessionId, owner);
    final pendingMutation = _mutationTails[_mutationScope(key)];
    if (pendingMutation != null) await pendingMutation;
    final raw = await _secure.read(key: key);
    // V1/V2 concatenaban connectionId y sessionId con `_` sin escape. Incluso
    // un lookup aparentemente exacto puede pertenecer a otra pareja de IDs,
    // por lo que nunca se reclama ni migra automáticamente.
    if (raw == null || raw.isEmpty) {
      return const ChatDraft(text: '', attachments: []);
    }
    final entry = _decodeEntry(sessionId, owner, raw);
    if (entry == null) {
      await clear(connectionId, sessionId, profile: owner);
      return const ChatDraft(text: '', attachments: []);
    }
    return entry.draft;
  }

  /// Lista borradores vivos de una conexión para que Inicio/Conversaciones
  /// puedan reabrir chats aún no materializados en Hermes.
  Future<List<ChatDraftEntry>> listForConnection(String connectionId) async {
    final prefix = 'chat_draft_v3.${_scope(connectionId)}.';
    final entries = <ChatDraftEntry>[];
    final secureEntries = await _secure.readAll();
    for (final item in secureEntries.entries) {
      if (!item.key.startsWith(prefix)) continue;
      final suffix = item.key.substring(prefix.length).split('.');
      if (suffix.length != 2) {
        await _deleteSecureDraft(item.key, item.value);
        continue;
      }
      late final String profile;
      late final String sessionId;
      try {
        profile = _unScope(suffix[0]);
        sessionId = _unScope(suffix[1]);
      } catch (_) {
        await _deleteSecureDraft(item.key, item.value);
        continue;
      }
      if (profile.isEmpty || sessionId.isEmpty) {
        await _deleteSecureDraft(item.key, item.value);
        continue;
      }
      // Bot Chat y Room usan ids/owners móviles estables para rehidratar su
      // propio compositor. Siguen cifrados y cargables por load(owner), pero
      // no son conversaciones genéricas recuperables desde Inicio/Listas.
      // No decodificar ni limpiar aquí: la superficie propietaria conserva la
      // autoridad para validar su edad, FSM y adjuntos cuando vuelva a abrirse.
      if (_belongsToDedicatedSurface(sessionId, profile)) continue;
      final decoded = _decodeEntry(sessionId, profile, item.value);
      if (decoded == null) {
        await _deleteSecureDraft(item.key, item.value);
      } else {
        entries.add(decoded);
      }
    }
    // V2 used `_` as an unescaped delimiter for both connection and session
    // identifiers. Neither bulk listing nor an apparently exact lookup can
    // prove where either identifier ends, so V1/V2 remain inaccessible and
    // untouched rather than being parsed, migrated or deleted.
    entries.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return entries;
  }

  Future<bool> save(
    String connectionId,
    String sessionId,
    String text,
    List<AttachmentDraft> attachments, {
    String profile = 'default',
    String? missionRoomIntentId,
    String? missionRoomWorkerProfile,
    String? missionRoomBoardId,
    String? missionRoomBoardQuery,
    MissionRoomTaskPhase? missionRoomTaskPhase,
    String? preparedTurnClientTurnId,
    LocalConversationLifecycle? lifecycle,
    // Admit before waiting on a screen's two-key move. Cleanup must see this
    // request even while an earlier snapshot is still using storage.
    Future<bool>? afterSave,
  }) async {
    final normalizedAttachments = attachments
        .where((item) => item.uploadState != AttachmentUploadState.removed)
        .map(
          (item) => item.localId.isEmpty
              ? AttachmentDraft.fromJson(item.toJson())
              : item,
        )
        .toList(growable: false);
    final owner = profile.trim().isEmpty ? 'default' : profile.trim();
    final key = _key(connectionId, sessionId, owner);
    final mutationScope = _mutationScope(key);
    _mutationIdentities[mutationScope] = (
      connectionId: connectionId,
      profile: owner,
      sessionId: sessionId,
    );
    final resource = LocalConversationResourceKey(
      connectionId: connectionId,
      profile: owner,
      sessionId: sessionId,
      physicalKey: key,
    );
    final journalOperation = LocalConversationCleanupFence.admitOperation(
      connectionId: connectionId,
      profile: owner,
      sessionId: sessionId,
      lifecycle: lifecycle,
      kind: LocalConversationOperationKind.save,
      resources: [resource],
    );
    // A rejected producer must not invalidate another producer's admission.
    final admittedGeneration = text.isEmpty && normalizedAttachments.isEmpty
        ? _advanceMutationGeneration(mutationScope)
        : _currentMutationGeneration(mutationScope);
    final pendingOwner = AttachmentOwnershipCoordinator.reservePendingOwner(
      normalizedAttachments,
    );
    var didCommit = false;
    try {
      if (afterSave != null && !await afterSave) return false;
      await LocalConversationCleanupFence.write(
        connectionId: connectionId,
        profile: owner,
        sessionId: sessionId,
        lifecycle: lifecycle,
        admittedOperation: journalOperation,
        operation: () => _serializeMutation(
          mutationScope,
          () => AttachmentOwnershipCoordinator.serialize(() async {
            LocalConversationCleanupFence.ensureOperationAllowed(
              journalOperation,
            );
            if (_currentMutationGeneration(mutationScope) !=
                admittedGeneration) {
              return;
            }
            if (text.isEmpty && normalizedAttachments.isEmpty) {
              didCommit = await _clearUnlocked(
                connectionId,
                sessionId,
                owner: owner,
                operation: journalOperation,
                resource: resource,
              );
              return;
            }
            final safePreparedTurnId = _safeOpaqueIdentity(
              preparedTurnClientTurnId,
            );
            if (safePreparedTurnId != null &&
                await TurnOutboxStore(
                  secureStorage: _secure,
                ).isFailedBeforeAcceptanceDiscarded(
                  connectionId: connectionId,
                  profile: owner,
                  sessionId: sessionId,
                  clientTurnId: safePreparedTurnId,
                )) {
              return;
            }
            final previous = await _secure.read(key: key);
            LocalConversationCleanupFence.ensureOperationAllowed(
              journalOperation,
            );
            final safeIntentId = _safeMetadata(
              missionRoomIntentId,
              maxLength: 128,
            );
            final safeWorker = _safeMetadata(
              missionRoomWorkerProfile,
              maxLength: 64,
              pattern: RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$'),
            );
            final safeBoardId = _safeMetadata(
              missionRoomBoardId,
              maxLength: 128,
            );
            final safeBoardQuery = _safeMetadata(
              missionRoomBoardQuery,
              maxLength: 128,
            );
            final safePhase = safeIntentId != null && safeWorker != null
                ? missionRoomTaskPhase
                : null;
            final encoded = jsonEncode({
              'savedAt': DateTime.now().millisecondsSinceEpoch,
              'text': text,
              'preparedTurnClientTurnId': ?safePreparedTurnId,
              'missionRoomIntentId': ?safeIntentId,
              'missionRoomWorkerProfile': ?safeWorker,
              'missionRoomBoardId': ?safeBoardId,
              'missionRoomBoardQuery': ?safeBoardQuery,
              'missionRoomTaskPhase': ?safePhase?.name,
              'attachments': normalizedAttachments
                  .map((item) => item.toJson())
                  .toList(),
            });
            final committed = await LocalConversationCleanupFence.commitEffect(
              operation: journalOperation,
              resource: resource,
              mutation: () => _secure.write(key: key, value: encoded),
            );
            if (!committed) return;
            didCommit = true;
            _changes.add((
              connectionId: connectionId,
              profile: owner,
              sessionId: sessionId,
            ));
            await _cleanupUnowned([
              if (previous != null) ..._attachmentsFromRaw(previous),
            ]);
          }),
        ),
      );
    } finally {
      await AttachmentOwnershipCoordinator.withdrawPendingOwner(
        pendingOwner,
        _cleanupUnownedLocked,
      );
    }
    return didCommit;
  }

  static String? _safeMetadata(
    Object? value, {
    required int maxLength,
    RegExp? pattern,
  }) {
    if (value is! String) return null;
    final normalized = value.trim();
    if (normalized.isEmpty ||
        normalized.length > maxLength ||
        normalized.contains(RegExp(r'[\u0000-\u001f\u007f]')) ||
        (pattern != null && !pattern.hasMatch(normalized))) {
      return null;
    }
    return normalized;
  }

  static String? _safeOpaqueIdentity(Object? value) {
    if (value is! String ||
        value.trim().isEmpty ||
        value.length > 256 ||
        value.contains(RegExp(r'[\u0000-\u001f\u007f]'))) {
      return null;
    }
    return value;
  }

  static MissionRoomTaskPhase? _taskPhase(Object? value) {
    if (value is! String) return null;
    for (final phase in MissionRoomTaskPhase.values) {
      if (phase.name == value) return phase;
    }
    return null;
  }

  Future<void> clear(
    String connectionId,
    String sessionId, {
    String profile = 'default',
    // Conservado para compatibilidad; nunca autoriza V1/V2 ambiguos.
    bool includeUnscoped = false,
  }) {
    final owner = profile.trim().isEmpty ? 'default' : profile.trim();
    final key = _key(connectionId, sessionId, owner);
    final mutationScope = _mutationScope(key);
    _advanceMutationGeneration(mutationScope);
    final resource = LocalConversationResourceKey(
      connectionId: connectionId,
      profile: owner,
      sessionId: sessionId,
      physicalKey: key,
    );
    late final LocalConversationOperation journalOperation;
    try {
      journalOperation = LocalConversationCleanupFence.admitOperation(
        connectionId: connectionId,
        profile: owner,
        sessionId: sessionId,
        kind: LocalConversationOperationKind.clearExact,
        resources: [resource],
      );
    } catch (error, stackTrace) {
      return Future<void>.error(error, stackTrace);
    }
    return _serializeMutation(
      mutationScope,
      () => _clearUnlocked(
        connectionId,
        sessionId,
        owner: owner,
        operation: journalOperation,
        resource: resource,
      ),
    );
  }

  Future<bool> _clearUnlocked(
    String connectionId,
    String sessionId, {
    required String owner,
    LocalConversationOperation? operation,
    LocalConversationResourceKey? resource,
  }) async {
    final key = _key(connectionId, sessionId, owner);
    final raw = await _secure.read(key: key);
    if (operation != null && resource != null) {
      final committed = await LocalConversationCleanupFence.commitEffect(
        operation: operation,
        resource: resource,
        mutation: () => _secure.delete(key: key),
      );
      if (!committed) return false;
    } else {
      await _secure.delete(key: key);
    }
    if (raw != null) {
      _changes.add((
        connectionId: connectionId,
        profile: owner,
        sessionId: sessionId,
      ));
    }
    await _cleanupUnowned([if (raw != null) ..._attachmentsFromRaw(raw)]);
    return true;
  }

  /// Elimina el borrador de una sesión en todos sus owners conocidos.
  ///
  /// El endpoint de borrado histórico recibe solo el id opaco de sesión. Un
  /// borrador v3, en cambio, también está sellado por perfil; limitar la
  /// limpieza a `default` permite que otro owner reaparezca después de que el
  /// servidor ya confirmó el borrado. La coincidencia sigue siendo exacta por
  /// conexión y sesión, sin tocar borradores vecinos.
  Future<void> clearForSession(String connectionId, String sessionId) async {
    final clearOperation = LocalConversationCleanupFence.admitSessionClear(
      connectionId: connectionId,
      sessionId: sessionId,
      physicalKeyPrefix: 'chat_draft_v3.',
    );
    try {
      for (final entry
          in _mutationIdentities.entries
              .where(
                (entry) =>
                    entry.value.connectionId == connectionId &&
                    entry.value.sessionId == sessionId,
              )
              .toList(growable: false)) {
        _advanceMutationGeneration(entry.key);
      }
      final securePrefix = 'chat_draft_v3.${_scope(connectionId)}.';
      final secureSuffix = '.${_scope(sessionId)}';
      final secureEntries = await _secure.readAll();
      final matchingKeys = <String>{
        ...secureEntries.keys.where(
          (key) => key.startsWith(securePrefix) && key.endsWith(secureSuffix),
        ),
        ...LocalConversationCleanupFence.resourcesBefore(clearOperation)
            .map((resource) => resource.physicalKey)
            .where(
              (key) =>
                  key.startsWith(securePrefix) && key.endsWith(secureSuffix),
            ),
      };
      await LocalConversationCleanupFence.settleDeliveredEffectsBefore(
        clearOperation,
      );
      final removedAttachments = <AttachmentDraft>[];
      for (final key in matchingKeys) {
        final encodedOwner = key.substring(
          securePrefix.length,
          key.length - secureSuffix.length,
        );
        late final String owner;
        try {
          owner = _unScope(encodedOwner);
        } catch (_) {
          continue;
        }
        final resource = LocalConversationResourceKey(
          connectionId: connectionId,
          profile: owner,
          sessionId: sessionId,
          physicalKey: key,
        );
        await _serializeMutation(_mutationScope(key), () async {
          if (LocalConversationCleanupFence.hasConfirmedCommitAfter(
            resource,
            clearOperation.admissionSequence,
          )) {
            return;
          }
          final raw = await _secure.read(key: key);
          final committed = await LocalConversationCleanupFence.commitEffect(
            operation: clearOperation,
            resource: resource,
            mutation: () => _secure.delete(key: key),
          );
          if (committed && raw != null) {
            removedAttachments.addAll(_attachmentsFromRaw(raw));
          }
        });
      }
      await _cleanupUnowned(removedAttachments);
    } finally {
      LocalConversationCleanupFence.completeOperation(clearOperation);
    }
  }

  /// Elimina únicamente los borradores V3 del perfil indicado.
  /// V1/V2 no codifican fronteras ni owner de forma no ambigua y se conservan.
  Future<int> deleteForProfile(String connectionId, String profile) {
    final owner = profile.trim().isEmpty ? 'default' : profile.trim();
    return LocalConversationCleanupFence.cleanupProfile(
      connectionId: connectionId,
      profile: owner,
      operation: () async {
        final securePrefix =
            'chat_draft_v3.${_scope(connectionId)}.${_scope(owner)}.';
        var removed = 0;
        final removedAttachments = <AttachmentDraft>[];
        final secureEntries = await _secure.readAll();
        bool shouldRemoveSecure(String key) {
          if (key.startsWith(securePrefix)) {
            try {
              final sessionId = _unScope(key.substring(securePrefix.length));
              return !_isDedicatedSurfaceScope(sessionId);
            } catch (_) {
              return true;
            }
          }
          return false;
        }

        for (final key in secureEntries.keys.where(shouldRemoveSecure)) {
          removedAttachments.addAll(
            _attachmentsFromRaw(secureEntries[key] ?? ''),
          );
          await _secure.delete(key: key);
          removed++;
        }
        await _cleanupUnowned(removedAttachments);
        return removed;
      },
    );
  }

  /// Elimina únicamente borradores pertenecientes a una conexión retirada.
  /// `readAll` nunca se copia a prefs/logs y las demás entradas del Keystore se
  /// conservan intactas.
  Future<int> deleteForConnection(String connectionId) =>
      LocalConversationCleanupFence.cleanupConnection(
        connectionId: connectionId,
        operation: () async {
          final securePrefix = 'chat_draft_v3.${_scope(connectionId)}.';
          var removed = 0;
          final removedAttachments = <AttachmentDraft>[];
          final secureEntries = await _secure.readAll();
          for (final key in secureEntries.keys.where(
            (key) => key.startsWith(securePrefix),
          )) {
            removedAttachments.addAll(
              _attachmentsFromRaw(secureEntries[key] ?? ''),
            );
            await _secure.delete(key: key);
            removed++;
          }
          await _cleanupUnowned(removedAttachments);
          return removed;
        },
      );

  Future<void> _deleteSecureDraft(String key, String raw) async {
    await _secure.delete(key: key);
    await _cleanupUnowned(_attachmentsFromRaw(raw));
  }

  Future<void> retireAttachments(List<AttachmentDraft> attachments) =>
      _cleanupUnowned(List<AttachmentDraft>.of(attachments));

  Future<void> _cleanupUnowned(List<AttachmentDraft> candidates) =>
      AttachmentOwnershipCoordinator.serialize(
        () => _cleanupUnownedLocked(candidates),
      );

  Future<void> _cleanupUnownedLocked(List<AttachmentDraft> candidates) async {
    if (candidates.isEmpty) return;
    final decoded = await AttachmentOwnershipCoordinator.loadDurableReferences(
      _secure,
      preferences: _prefs,
    );
    if (decoded == null) return;
    final visitedPaths = <String>{};
    for (final candidate in candidates) {
      if (candidate.localPath.isEmpty ||
          !visitedPaths.add(candidate.localPath)) {
        continue;
      }
      if (AttachmentOwnershipCoordinator.hasPendingOwner(candidate)) {
        AttachmentOwnershipCoordinator.deferCleanup(
          candidate,
          _cleanupUnownedLocked,
        );
        continue;
      }
      if (decoded.any(
        (value) => AttachmentOwnershipCoordinator.durableReferencesAttachment(
          value,
          candidate,
        ),
      )) {
        continue;
      }
      await _deletePrivateCopy(candidate);
    }
  }
}

List<AttachmentDraft> _attachmentsFromRaw(String raw) {
  try {
    final decoded = jsonDecode(raw);
    final result = <AttachmentDraft>[];
    void visit(Object? value) {
      if (value is List) {
        for (final item in value) {
          visit(item);
        }
        return;
      }
      if (value is! Map) return;
      final map = Map<String, dynamic>.from(value);
      if (map.containsKey('local_path') && map.containsKey('type')) {
        result.add(AttachmentDraft.fromJson(map));
        return;
      }
      for (final nested in map.values) {
        visit(nested);
      }
    }

    visit(decoded);
    return result;
  } catch (_) {
    return const [];
  }
}
