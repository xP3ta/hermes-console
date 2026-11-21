import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/attachment_draft.dart';
import '../models/session.dart';
import 'app_error_log.dart';
import 'attachment_uploader.dart';
import 'app_lock_sensitive_read_fence.dart';
import 'sealed_local_files.dart';
import 'secure_storage.dart';
import 'session_deletion.dart';
import 'turn_outbox_store.dart';

class ChatDraft {
  final String text;
  final List<AttachmentDraft> attachments;
  final String? preparedTurnClientTurnId;

  /// Leading part of [text] that is the bound send's own text; the rest was
  /// typed after it and is never part of that send. Null: all of [text].
  final String? preparedTurnText;
  final String? replyThreadId;

  /// Turno ya persistido en la outbox cuyo lote es exactamente este borrador.
  /// Solo vive en el store: la pantalla nunca lo adopta como autoridad del
  /// composer, y cualquier edición posterior lo retira al reescribir la clave.
  final String? submittedTurnClientTurnId;

  const ChatDraft({
    required this.text,
    required this.attachments,
    this.preparedTurnClientTurnId,
    this.preparedTurnText,
    this.replyThreadId,
    this.submittedTurnClientTurnId,
  });
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
/// sensibles aunque no sea una credencial, por eso vive cifrado
/// ([SealedLocalFiles], con la clave en el Keystore) y no en
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
  static final Map<String, Future<void>> _admittedSaveTails = {};
  static final Map<String, int> _mutationGenerations = {};
  static final Map<
    String,
    ({String connectionId, String profile, String sessionId})
  >
  _mutationIdentities = {};

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;
  final SealedLocalFiles _files;
  final Future<bool> Function(AttachmentDraft) _deletePrivateCopy;
  final String mutationNamespaceForTesting;

  ChatDraftStore(
    this._prefs, {
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
    Future<bool> Function(AttachmentDraft)? deletePrivateCopy,
    this.mutationNamespaceForTesting = '',
  }) : _secure = secureStorage,
       _files = SealedLocalFiles(
         SealedLocalFiles.drafts,
         secureStorage: secureStorage,
       ),
       _deletePrivateCopy =
           deletePrivateCopy ?? AttachmentUploader.deletePrivateDraftCopy;

  /// What a draft file that does not open reads as: like an entry that does
  /// not parse, it is never a draft (load and list delete it).
  static const _unreadable = '\u0000';

  /// An entry an older version wrote is moved into its file only when it
  /// parses; one that does not is left for the unreadable path.
  static bool _movable(String raw) {
    try {
      return jsonDecode(raw) is Map;
    } on FormatException {
      return false;
    }
  }

  static SealedName _name(String key) =>
      AttachmentOwnershipCoordinator.draftName(key);

  /// The draft stored under [key]. An entry an older version wrote is moved
  /// into its file unless [move] is false (a cleanup about to delete it) or
  /// its key is not a well-formed v3 key (it is only ever deleted).
  Future<String?> _read({
    required String key,
    bool move = true,
    void Function()? onSettled,
  }) async {
    final ticket = AppLockSensitiveReadFence.current;
    ticket.ensureCurrent();
    await _prefs.reload();
    ticket.ensureCurrent();
    final name = _name(key);
    try {
      return await _files.read(
        name,
        fence: ticket.ensureCurrent,
        movable: move && name.scope.length == 3 ? _movable : (_) => false,
        onSettled: onSettled,
      );
    } on SealedFileUnreadable catch (error) {
      SecureStorageDiagnostics.record(SecureStorageOperation.draftLoad, error);
      return _unreadable;
    }
  }

  /// The drafts of [scope] (connection, profile, chat; a null part matches
  /// any) whose key passes [matches]: their files, and the entries an older
  /// version left, found by the names of the index (built once, see
  /// [_indexNames]). A file that does not open is deleted, with its
  /// breadcrumb. [move] as for [_read]. With [unfinished], a draft whose
  /// only file is a write a process death interrupted is included too (a
  /// cleanup must find it).
  Future<Map<String, String>> _stored(
    List<String?> scope,
    bool Function(String key) matches, {
    bool move = false,
    bool unfinished = false,
    List<String>? unreadablePartialOut,
    Map<String, String>? unfinishedOut,
  }) async {
    final ticket = AppLockSensitiveReadFence.current;
    ticket.ensureCurrent();
    await _prefs.reload();
    ticket.ensureCurrent();
    final files = await _files.readScope(scope, fence: ticket.ensureCurrent);
    ticket.ensureCurrent();
    if (files.unreadable.isNotEmpty) {
      SecureStorageDiagnostics.record(
        SecureStorageOperation.draftList,
        const SealedFileUnreadable(),
      );
      await _files.deleteFiles(files.unreadable);
      ticket.ensureCurrent();
    }
    unreadablePartialOut?.addAll(files.unreadablePartial);
    unfinishedOut?.addAll(files.unfinished);
    final drafts = {
      for (final MapEntry(:key, :value) in files.values.entries)
        if (matches(key)) key: value,
      if (unfinished)
        for (final MapEntry(:key, :value) in files.unfinished.entries)
          if (matches(key) && !files.values.containsKey(key)) key: value,
    };
    final settled = <String>{};
    for (final key in await _indexNames()) {
      ticket.ensureCurrent();
      if (!matches(key)) continue;
      if (drafts.containsKey(key)) {
        if (move && files.values.containsKey(key)) {
          await _files.settleLegacy(key);
          ticket.ensureCurrent();
          settled.add(key);
        }
        continue;
      }
      var wasSettled = false;
      final raw = await _read(
        key: key,
        move: move,
        onSettled: () => wasSettled = true,
      );
      ticket.ensureCurrent();
      // Absent: a write that never landed. Its name is harmless.
      if (raw != null) drafts[key] = raw;
      if (wasSettled) settled.add(key);
    }
    if (settled.isNotEmpty && ticket.isCurrent) {
      await _pruneIndexed(settled);
      ticket.ensureCurrent();
    }
    return drafts;
  }

  /// Deletes the draft stored under [key], and (with [unfinished]) a write
  /// of it a process death interrupted: not from a list, which runs beside
  /// the draft's own saves.
  Future<void> _delete({required String key, bool unfinished = true}) async {
    final ticket = AppLockSensitiveReadFence.current;
    ticket.ensureCurrent();
    await _files.delete(_name(key), unfinished: unfinished);
    // The app lock closed during the delete: nothing else is read. The
    // name stays in the index and reads as absent.
    if (!ticket.isCurrent) return;
    await _pruneIndexed([key]);
  }

  Future<void> _write({required String key, required String value}) async {
    final ticket = AppLockSensitiveReadFence.current;
    ticket.ensureCurrent();
    AttachmentOwnershipCoordinator.noteDraftKeyWritten(key);
    await _files.write(_name(key), value);
  }

  // The names of legacy secure-storage drafts, in one small Keystore entry,
  // so lists and attachment cleanup can check them by name. The first list
  // builds it once from the keys an older version stored.
  // File-backed drafts are found by listing
  // their sealed directory and are never added here; entries shrink out of
  // this index as each legacy v3 draft moves into a file or is deleted.
  // Legacy v2 drafts stay listed here until removed.
  static const String _indexKey = AttachmentOwnershipCoordinator.draftIndexKey;

  Future<Set<String>?> _readIndex() async {
    final raw = await _secure.read(key: _indexKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.whereType<String>().toSet();
    } catch (_) {
      // Unreadable: the next list builds it again.
    }
    return null;
  }

  /// Removes legacy [keys] that moved into files or were deleted.
  Future<void> _pruneIndexed(Iterable<String> keys) async {
    final index = await _readIndex();
    if (index == null) return;
    var changed = false;
    for (final key in keys) {
      changed = index.remove(key) || changed;
    }
    if (!changed) return;
    await _secure.write(key: _indexKey, value: jsonEncode(index.toList()));
  }

  /// The names of the index, built from secure key names when absent.
  Future<Set<String>> _indexNames() async {
    final ticket = AppLockSensitiveReadFence.current;
    var names = await _readIndex();
    ticket.ensureCurrent();
    if (names == null) {
      final keys = await SecureStorage.listKeys(_secure);
      ticket.ensureCurrent();
      names = keys.where(AttachmentOwnershipCoordinator.isDraftKey).toSet();
      await _secure.write(key: _indexKey, value: jsonEncode(names.toList()));
      ticket.ensureCurrent();
    }
    return names;
  }

  SensitiveReadTicket captureDisclosure() =>
      AppLockSensitiveReadFence.capture(_prefs);

  static String _scope(String value) =>
      base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  static String _unScope(String value) {
    final padded = value.padRight((value.length + 3) ~/ 4 * 4, '=');
    return utf8.decode(base64Url.decode(padded));
  }

  /// Borrador del compositor de Inicio (chat nuevo sin sesión todavía).
  /// Equivale a `NEW_SESSION_DRAFT_KEY='__new__'` de Hermes Desktop
  /// (store/composer.ts), pero con alcance por conexión y perfil vía la clave
  /// v3. Es una superficie dedicada: no se lista como conversación.
  static const String newChatDraftSessionId = 'mob-home-new';

  static bool _isDedicatedSurfaceScope(String value) =>
      value.startsWith('mob-bot-') ||
      value.startsWith('mob-room-') ||
      value == newChatDraftSessionId;

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
    AppLockSensitiveReadFence.current.ensureCurrent();
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final savedAt = DateTime.fromMillisecondsSinceEpoch(
        (data['savedAt'] as num?)?.toInt() ?? 0,
      );
      if (savedAt.millisecondsSinceEpoch <= 0 ||
          DateTime.now().difference(savedAt) > maxAge) {
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
        replyThreadId: _safeOpaqueIdentity(data['replyThreadId']),
        preparedTurnClientTurnId: _safeOpaqueIdentity(
          data['preparedTurnClientTurnId'],
        ),
        preparedTurnText: data['preparedTurnText'] is String
            ? data['preparedTurnText'] as String
            : null,
        submittedTurnClientTurnId: _safeOpaqueIdentity(
          data['submittedTurnClientTurnId'],
        ),
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
  }) => SecureStorageDiagnostics.watch(
    SecureStorageOperation.draftLoad,
    AppLockSensitiveReadFence.run(
      _prefs,
      () => _privacyLoad(
        connectionId,
        sessionId,
        profile: profile,
        claimUnscopedLegacy: claimUnscopedLegacy,
      ),
    ),
  );

  Future<ChatDraft> _privacyLoad(
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
    final admittedSave = _admittedSaveTails[_mutationScope(key)];
    if (admittedSave != null) await admittedSave;
    final pendingMutation = _mutationTails[_mutationScope(key)];
    if (pendingMutation != null) await pendingMutation;
    final raw = await _read(key: key);
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
  Future<List<ChatDraftEntry>> listForConnection(String connectionId) =>
      SecureStorageDiagnostics.watch(
        SecureStorageOperation.draftList,
        AppLockSensitiveReadFence.run(
          _prefs,
          () => _privacyListForConnection(connectionId),
        ),
      );

  Future<List<ChatDraftEntry>> _privacyListForConnection(
    String connectionId,
  ) async {
    final prefix = 'chat_draft_v3.${_scope(connectionId)}.';
    final entries = <ChatDraftEntry>[];
    bool matches(String key) => key.startsWith(prefix);
    final secureEntries = await _stored([connectionId], matches, move: true);
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
    String? preparedTurnClientTurnId,
    String? preparedTurnText,
    String? replyThreadId,
    String? submittedTurnClientTurnId,
    String? rescueActionUid,
    LocalConversationLifecycle? lifecycle,
    Future<bool>? afterSave,
  }) => SecureStorageDiagnostics.watch(
    SecureStorageOperation.draftSave,
    AppLockSensitiveReadFence.run(
      _prefs,
      () => _privacySave(
        connectionId,
        sessionId,
        text,
        attachments,
        profile: profile,
        preparedTurnClientTurnId: preparedTurnClientTurnId,
        preparedTurnText: preparedTurnText,
        replyThreadId: replyThreadId,
        submittedTurnClientTurnId: submittedTurnClientTurnId,
        rescueActionUid: rescueActionUid,
        lifecycle: lifecycle,
        afterSave: afterSave,
      ),
    ),
  );

  Future<bool> _privacySave(
    String connectionId,
    String sessionId,
    String text,
    List<AttachmentDraft> attachments, {
    String profile = 'default',
    String? preparedTurnClientTurnId,
    String? preparedTurnText,
    String? replyThreadId,
    String? submittedTurnClientTurnId,
    String? rescueActionUid,
    LocalConversationLifecycle? lifecycle,
    Future<bool>? afterSave,
  }) {
    final owner = profile.trim().isEmpty ? 'default' : profile.trim();
    final scope = _mutationScope(_key(connectionId, sessionId, owner));
    final previous = _admittedSaveTails[scope];
    final result = _save(
      connectionId,
      sessionId,
      text,
      attachments,
      profile: owner,
      preparedTurnClientTurnId: preparedTurnClientTurnId,
      preparedTurnText: preparedTurnText,
      replyThreadId: replyThreadId,
      submittedTurnClientTurnId: submittedTurnClientTurnId,
      rescueActionUid: rescueActionUid,
      lifecycle: lifecycle,
      afterSave: afterSave,
    );
    final tail = Future.wait<void>([
      ?previous,
      result.then<void>((_) {}, onError: (Object _) {}),
    ]).then<void>((_) {});
    _admittedSaveTails[scope] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_admittedSaveTails[scope], tail)) {
          _admittedSaveTails.remove(scope);
        }
      }),
    );
    return result;
  }

  Future<bool> _save(
    String connectionId,
    String sessionId,
    String text,
    List<AttachmentDraft> attachments, {
    String profile = 'default',
    String? preparedTurnClientTurnId,
    String? preparedTurnText,
    String? replyThreadId,
    String? submittedTurnClientTurnId,
    String? rescueActionUid,
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
          () => AttachmentOwnershipCoordinator.serialize(
            () => _recoverAdmittedSnapshot(() async {
              AppLockSensitiveReadFence.current.ensureCurrent();
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
              final previous = await _read(key: key);
              final removedAttachments = previous == null
                  ? <AttachmentDraft>[]
                  : _attachmentsFromRaw(previous);
              LocalConversationCleanupFence.ensureOperationAllowed(
                journalOperation,
              );
              // Receipt and appended text share one encrypted value/commit.
              // The key binds connection + profile + session; never dedupe by
              // text, nor by an install-global UID. Legacy v3 has no receipts.
              final previousData = previous == null
                  ? <String, dynamic>{}
                  : Map<String, dynamic>.from(jsonDecode(previous) as Map);
              final rawReceipts = previousData['rescuedActions'];
              if (rawReceipts != null && rawReceipts is! Map) {
                throw StateError('invalid rescue receipts');
              }
              final receipts = rawReceipts == null
                  ? <String, dynamic>{}
                  : Map<String, dynamic>.from(rawReceipts as Map);
              var savedText = text;
              var savedAttachments = normalizedAttachments;
              var savedPreparedId = safePreparedTurnId;
              var savedPreparedText = preparedTurnText;
              var savedSubmittedId = _safeOpaqueIdentity(
                submittedTurnClientTurnId,
              );
              var savedThreadId = _safeOpaqueIdentity(replyThreadId);
              if (rescueActionUid != null) {
                if (_safeOpaqueIdentity(rescueActionUid) != rescueActionUid ||
                    text.trim().isEmpty) {
                  throw StateError('invalid rescue identity');
                }
                if (receipts.containsKey(rescueActionUid)) {
                  if (receipts[rescueActionUid] != text) {
                    throw StateError('rescue identity payload conflict');
                  }
                  didCommit =
                      true; // Exact durable receipt, not suffix evidence.
                  return;
                }
                final stored = previous == null
                    ? null
                    : _decodeEntry(sessionId, owner, previous)?.draft;
                if (previous != null && stored == null) {
                  throw StateError('rescue draft unavailable');
                }
                final currentText = stored?.text ?? '';
                savedText = currentText.isEmpty ? text : '$currentText\n$text';
                savedAttachments = stored?.attachments ?? const [];
                savedPreparedId = stored?.preparedTurnClientTurnId;
                savedPreparedText = stored?.preparedTurnText;
                savedSubmittedId = stored?.submittedTurnClientTurnId;
                savedThreadId = stored?.replyThreadId ?? savedThreadId;
                receipts[rescueActionUid] = text;
              }
              final encoded = jsonEncode({
                'savedAt': DateTime.now().millisecondsSinceEpoch,
                'text': savedText,
                if (receipts.isNotEmpty) 'rescuedActions': receipts,
                'replyThreadId': ?savedThreadId,
                'preparedTurnClientTurnId': ?savedPreparedId,
                if (savedPreparedId != null)
                  'preparedTurnText': ?savedPreparedText,
                'submittedTurnClientTurnId': ?savedSubmittedId,
                'attachments': savedAttachments
                    .map((item) => item.toJson())
                    .toList(),
              });
              final committed =
                  await LocalConversationCleanupFence.commitEffect(
                    operation: journalOperation,
                    resource: resource,
                    mutation: () => _write(key: key, value: encoded),
                  );
              if (!committed) return;
              didCommit = true;
              _changes.add((
                connectionId: connectionId,
                profile: owner,
                sessionId: sessionId,
              ));
              await _cleanupUnowned(removedAttachments);
            }),
          ),
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

  Future<T> _recoverAdmittedSnapshot<T>(Future<T> Function() attempt) async {
    final retired = AppLockSensitiveReadFence.current;
    try {
      return await attempt();
    } on SensitiveReadUnavailable {
      // A disabled-lock app replacement may recover an already admitted UI
      // snapshot in its original journal lane. Never renew an enabled-lock
      // ticket, a same-issuer ABA, or a locked successor. Cleanup and mutation
      // generations remain authoritative; this is not transport recovery.
      if (_prefs.getBool('app_lock_enabled') == true ||
          retired.issuerIsCurrent ||
          !AppLockSensitiveReadFence.capture(_prefs).isCurrent) {
        rethrow;
      }
      return AppLockSensitiveReadFence.recover(attempt);
    }
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

  Future<void> clear(
    String connectionId,
    String sessionId, {
    String profile = 'default',
    // Conservado para compatibilidad; nunca autoriza V1/V2 ambiguos.
    bool includeUnscoped = false,
    String? onlyPreparedTurnClientTurnId,
    // Retira solo el borrador que sigue siendo el lote exacto de ese turno ya
    // persistido. No depende de ninguna pantalla viva y nunca invalida una
    // escritura concurrente con contenido nuevo.
    String? onlySubmittedTurnClientTurnId,
  }) => SecureStorageDiagnostics.watch(
    SecureStorageOperation.draftClear,
    AppLockSensitiveReadFence.run(
      _prefs,
      () => _privacyClear(
        connectionId,
        sessionId,
        profile: profile,
        includeUnscoped: includeUnscoped,
        onlyPreparedTurnClientTurnId: onlyPreparedTurnClientTurnId,
        onlySubmittedTurnClientTurnId: onlySubmittedTurnClientTurnId,
      ),
    ),
  );

  Future<void> _privacyClear(
    String connectionId,
    String sessionId, {
    String profile = 'default',
    // Conservado para compatibilidad; nunca autoriza V1/V2 ambiguos.
    bool includeUnscoped = false,
    String? onlyPreparedTurnClientTurnId,
    // Retira solo el borrador que sigue siendo el lote exacto de ese turno ya
    // persistido. No depende de ninguna pantalla viva y nunca invalida una
    // escritura concurrente con contenido nuevo.
    String? onlySubmittedTurnClientTurnId,
  }) {
    final owner = profile.trim().isEmpty ? 'default' : profile.trim();
    final key = _key(connectionId, sessionId, owner);
    final mutationScope = _mutationScope(key);
    final conditional =
        onlyPreparedTurnClientTurnId != null ||
        onlySubmittedTurnClientTurnId != null;
    if (!conditional) {
      _advanceMutationGeneration(mutationScope);
    }
    final admittedSaves = _admittedSaveTails[mutationScope];
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
    Future<void> clearMatching() => _serializeMutation(mutationScope, () async {
      if (conditional) {
        final raw = await _read(key: key);
        final stored = raw == null
            ? null
            : _decodeEntry(sessionId, owner, raw)?.draft;
        if (stored == null ||
            (onlyPreparedTurnClientTurnId != null &&
                stored.preparedTurnClientTurnId !=
                    onlyPreparedTurnClientTurnId) ||
            (onlySubmittedTurnClientTurnId != null &&
                stored.submittedTurnClientTurnId !=
                    onlySubmittedTurnClientTurnId)) {
          return;
        }
        // Text typed after the bound send is not part of it: retire only
        // the send's own text and keep the rest as an ordinary draft.
        final sendText = stored.preparedTurnText;
        if (onlyPreparedTurnClientTurnId != null &&
            sendText != null &&
            stored.text.length > sendText.length &&
            stored.text.startsWith(sendText)) {
          final rest = stored.text.substring(sendText.length);
          final kept = rest.startsWith('\n') ? rest.substring(1) : rest;
          if (kept.trim().isNotEmpty) {
            final encoded = jsonEncode({
              'savedAt': DateTime.now().millisecondsSinceEpoch,
              'text': kept,
              'attachments': stored.attachments
                  .map((item) => item.toJson())
                  .toList(),
            });
            final committed = await LocalConversationCleanupFence.commitEffect(
              operation: journalOperation,
              resource: resource,
              mutation: () => _write(key: key, value: encoded),
            );
            if (committed) {
              _changes.add((
                connectionId: connectionId,
                profile: owner,
                sessionId: sessionId,
              ));
            }
            return;
          }
        }
      }
      await _clearUnlocked(
        connectionId,
        sessionId,
        owner: owner,
        operation: journalOperation,
        resource: resource,
      );
    });
    // An acknowledged room send clears only its own captured draft.
    if (conditional && admittedSaves != null) {
      return admittedSaves.then((_) => clearMatching());
    }
    return clearMatching();
  }

  Future<bool> _clearUnlocked(
    String connectionId,
    String sessionId, {
    required String owner,
    LocalConversationOperation? operation,
    LocalConversationResourceKey? resource,
  }) async {
    final key = _key(connectionId, sessionId, owner);
    final raw = await _read(key: key);
    final removedAttachments = raw == null
        ? <AttachmentDraft>[]
        : _attachmentsFromRaw(raw);
    if (operation != null && resource != null) {
      final committed = await LocalConversationCleanupFence.commitEffect(
        operation: operation,
        resource: resource,
        mutation: () => _delete(key: key),
      );
      if (!committed) return false;
    } else {
      await _delete(key: key);
    }
    if (raw != null) {
      _changes.add((
        connectionId: connectionId,
        profile: owner,
        sessionId: sessionId,
      ));
    }
    await _cleanupUnowned(removedAttachments);
    return true;
  }

  /// Elimina el borrador de una sesión en todos sus owners conocidos.
  ///
  /// El endpoint de borrado histórico recibe solo el id opaco de sesión. Un
  /// borrador v3, en cambio, también está sellado por perfil; limitar la
  /// limpieza a `default` permite que otro owner reaparezca después de que el
  /// servidor ya confirmó el borrado. La coincidencia sigue siendo exacta por
  /// conexión y sesión, sin tocar borradores vecinos.
  Future<void> clearForSession(String connectionId, String sessionId) =>
      AppLockSensitiveReadFence.run(
        _prefs,
        () => _privacyClearForSession(connectionId, sessionId),
      );

  Future<void> _privacyClearForSession(
    String connectionId,
    String sessionId,
  ) async {
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
      bool matches(String key) =>
          key.startsWith(securePrefix) && key.endsWith(secureSuffix);
      final scope = [connectionId, null, sessionId];
      final secureEntries = await _stored(scope, matches, unfinished: true);
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
          final raw = await _read(key: key);
          final candidates = raw == null
              ? <AttachmentDraft>[]
              : _attachmentsFromRaw(raw);
          final committed = await LocalConversationCleanupFence.commitEffect(
            operation: clearOperation,
            resource: resource,
            mutation: () => _delete(key: key),
          );
          if (committed && raw != null) {
            removedAttachments.addAll(candidates);
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
  Future<int> deleteForProfile(String connectionId, String profile) =>
      AppLockSensitiveReadFence.run(
        _prefs,
        () => _privacyDeleteForProfile(connectionId, profile),
      );

  Future<int> _privacyDeleteForProfile(String connectionId, String profile) {
    final owner = profile.trim().isEmpty ? 'default' : profile.trim();
    return LocalConversationCleanupFence.cleanupProfile(
      connectionId: connectionId,
      profile: owner,
      operation: () async {
        final securePrefix =
            'chat_draft_v3.${_scope(connectionId)}.${_scope(owner)}.';
        var removed = 0;
        final removedAttachments = <AttachmentDraft>[];
        final unreadablePartial = <String>[];
        final unfinished = <String, String>{};
        bool inProfile(String key) => key.startsWith(securePrefix);
        final secureEntries = await _stored(
          [connectionId, owner],
          inProfile,
          unreadablePartialOut: unreadablePartial,
          unfinishedOut: unfinished,
        );
        bool shouldRemoveSecure(String key) {
          if (key.startsWith(securePrefix)) {
            try {
              final sessionId = _unScope(key.substring(securePrefix.length));
              // El borrador de Inicio pertenece a este ámbito (conexión +
              // perfil): «borrar datos locales» también lo retira. Bots y
              // salas conservan su borrador dedicado.
              return sessionId == newChatDraftSessionId ||
                  !_isDedicatedSurfaceScope(sessionId);
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
          await _delete(key: key);
          removed++;
        }
        // Unfinished writes of removed chats (its saves are held while this
        // runs); dedicated bot and room drafts keep their unfinished writes.
        for (final entry in unfinished.entries) {
          if (!shouldRemoveSecure(entry.key)) continue;
          if (!secureEntries.containsKey(entry.key)) {
            removedAttachments.addAll(_attachmentsFromRaw(entry.value));
            await _delete(key: entry.key);
          }
        }
        if (unreadablePartial.isNotEmpty) {
          await _files.deleteFiles(unreadablePartial);
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
      AppLockSensitiveReadFence.run(
        _prefs,
        () => _privacyDeleteForConnection(connectionId),
      );

  Future<int> _privacyDeleteForConnection(String connectionId) =>
      LocalConversationCleanupFence.cleanupConnection(
        connectionId: connectionId,
        operation: () async {
          final securePrefix = 'chat_draft_v3.${_scope(connectionId)}.';
          var removed = 0;
          final removedAttachments = <AttachmentDraft>[];
          final unfinished = <String, String>{};
          bool matches(String key) => key.startsWith(securePrefix);
          final secureEntries = await _stored(
            [connectionId],
            matches,
            unfinishedOut: unfinished,
          );
          for (final key in secureEntries.keys.where(
            (key) => key.startsWith(securePrefix),
          )) {
            removedAttachments.addAll(
              _attachmentsFromRaw(secureEntries[key] ?? ''),
            );
            await _delete(key: key);
            removed++;
          }
          for (final entry in unfinished.entries) {
            if (matches(entry.key) && !secureEntries.containsKey(entry.key)) {
              removedAttachments.addAll(_attachmentsFromRaw(entry.value));
            }
          }
          // Writes a process death interrupted: no name of the connection
          // survives it (its saves are held while this runs).
          await _files.deleteFiles(await _files.unfinishedIn([connectionId]));
          await _cleanupUnowned(removedAttachments);
          return removed;
        },
      );

  Future<void> _deleteSecureDraft(String key, String raw) async {
    final candidates = _attachmentsFromRaw(raw);
    await _delete(key: key, unfinished: false);
    await _cleanupUnowned(candidates);
  }

  Future<void> retireAttachments(List<AttachmentDraft> attachments) =>
      AppLockSensitiveReadFence.run(
        _prefs,
        () => _privacyRetireAttachments(attachments),
      );

  Future<void> _privacyRetireAttachments(List<AttachmentDraft> attachments) =>
      _cleanupUnowned(List<AttachmentDraft>.of(attachments));

  Future<void> _cleanupUnowned(List<AttachmentDraft> candidates) =>
      AttachmentOwnershipCoordinator.serialize(
        () => _cleanupUnownedLocked(candidates),
      );

  Future<void> _cleanupUnownedLocked(List<AttachmentDraft> candidates) async {
    if (candidates.isEmpty) return;
    final ticket = AppLockSensitiveReadFence.current;
    final decoded = await AttachmentOwnershipCoordinator.loadDurableReferences(
      _secure,
      preferences: _prefs,
    );
    if (decoded == null || !ticket.isCurrent) {
      void retry() {
        if (!AppLockSensitiveReadFence.capture().isCurrent) return;
        AppLockSensitiveReadFence.changes.removeListener(retry);
        unawaited(
          AppLockSensitiveReadFence.recover(
            () => AttachmentOwnershipCoordinator.serialize(
              () => _cleanupUnownedLocked(candidates),
            ),
          ),
        );
      }

      AppLockSensitiveReadFence.changes.addListener(retry);
      return;
    }
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
      if (!ticket.isCurrent) {
        await _cleanupUnownedLocked(candidates);
        return;
      }
      await _deletePrivateCopy(candidate);
    }
  }
}

List<AttachmentDraft> _attachmentsFromRaw(String raw) {
  AppLockSensitiveReadFence.current.ensureCurrent();
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
