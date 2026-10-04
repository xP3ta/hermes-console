import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../models/session.dart';
import '../utils/session_title.dart';

/// Local archive + hidden store for sessions.
///
/// The Gateway API Server has no archive concept, so we persist sets of
/// session IDs in [SharedPreferences] keyed by connection ID.
///
///  - `archived_sessions_<connectionId>` — sesiones archivadas (intencional).
///  - `pinned_sessions_<connectionId>` — sesiones fijadas (aparecen primero).
///  - `hidden_sessions_<connectionId>` — sesiones OCULTAS localmente cuando el
///    servidor no permitió borrarlas (PRIORIDAD 4): salida visual sin tocar el
///    backend. Difiere de "archivada": ocultar = "limpiar la vista".
///  - `hidden_rows_<connectionId>` — the chats hidden from this device (on
///    the server or only here), as small row snapshots: the server's default
///    listing omits hidden rows, so this is what lets Archive list them and
///    show them again.
///  - `session_titles_<connectionId>` — local title overrides: renames made
///    while the server could not take them, and those of older builds.
///  - `session_auto_titles_<connectionId>` — the chat's prompt-derived title,
///    shown only while the server title is still a placeholder.
///
/// Hidden, title and read state live on the server when it publishes them
/// (PATCH /api/sessions/{id}, as Desktop): see [attachRemoteState]. The local
/// sets are then only a fallback and an optimistic overlay until the server
/// confirms.
///
/// All mutations are persisted immediately (synchronous write via the
/// SharedPreferences instance obtained at construction time).
///
/// There is ONE store per preferences instance and connection: every screen
/// (Home, Conversations, session detail, chat auto-title, drawer) receives the
/// same object from [load] and listens to it. A private copy per screen used
/// to flush its stale sets over another screen's write (an archive made in
/// Conversations undone by a later hide in Home) and left the other screens
/// showing the old title until their next network refresh.
class SessionArchive extends ChangeNotifier {
  static const _prefix = 'archived_sessions_';
  static const _pinnedPrefix = 'pinned_sessions_';
  static const _hiddenPrefix = 'hidden_sessions_';
  static const _hiddenRowsPrefix = 'hidden_rows_';
  static const _titlePrefix = 'session_titles_';
  static const _deletedPrefix = 'deleted_sessions_';
  static const _autoTitlePrefix = 'session_auto_titles_';

  final SharedPreferences _prefs;
  final String _connectionId;

  /// The live sets; mutated in-place and flushed on every change.
  Set<String> _archived = {};
  Set<String> _pinned = {};
  Set<String> _hidden = {};

  /// Snapshots of the chats hidden from this device, by logical id. A
  /// snapshot with `hidden: true` is hidden on the server (confirmed).
  Map<String, Session> _hiddenRows = {};

  /// Chats just shown again, kept in the lists until a read made after the
  /// server confirmed carries them (a read begun earlier omits them).
  final Map<String, Session> _revealed = {};
  Map<String, String> _titles = {};
  Map<String, String> _autoTitles = {};

  /// Server-confirmed deletions: physical session id -> activity watermark
  /// (seconds). See [markSessionDeleted].
  Map<String, double> _deleted = {};

  /// For each tombstone a complete listing can confirm, the profile whose
  /// default listing would carry the row (see [SessionListRead.end]).
  /// Persisted with the tombstone; an id without one is only released by
  /// the session's recreation.
  Map<String, String> _deletedScope = {};

  /// Tombstones a complete listing confirmed gone, waiting for the reads
  /// that began before their deletion to end.
  final Set<String> _confirmedGone = {};

  /// List reads of this process that have not finished (see
  /// [beginListRead]), and for each tombstone of this process the last read
  /// that had started when it was recorded. Not persisted: no read of an
  /// earlier process can still answer.
  int _listReadSeq = 0;
  final Set<int> _openListReads = {};
  final Map<String, int> _deletedAfterRead = {};

  int _revision = 0;

  /// Advances synchronously with every in-memory change (archive, pin,
  /// hidden, titles), including remote pin reconciliation, so readers can
  /// memoize derived views on it. Every mutation path persists through
  /// [_flush]/[_flushTitles], which bump it before their first await.
  int get revision => _revision;

  SessionArchive._(this._prefs, this._connectionId);

  static final Expando<Map<String, SessionArchive>> _stores = Expando(
    'SessionArchive stores',
  );

  /// The shared archive for [connectionId] in [prefs].
  ///
  /// Every caller receives the same instance. It re-reads the preferences on
  /// each call, so a removal made outside the store (connection cleanup) is
  /// adopted; in-memory state is always written to the preferences cache
  /// before any await, so this re-read can never lose a pending change.
  static Future<SessionArchive> load(
    SharedPreferences prefs,
    String connectionId,
  ) async {
    final stores = _stores[prefs] ??= <String, SessionArchive>{};
    final existing = stores[connectionId];
    if (existing != null) {
      existing._resync();
      return existing;
    }
    final archive = SessionArchive._(prefs, connectionId);
    archive._read();
    stores[connectionId] = archive;
    return archive;
  }

  String get _key => '$_prefix$_connectionId';
  String get _pinnedKey => '$_pinnedPrefix$_connectionId';
  String get _hiddenKey => '$_hiddenPrefix$_connectionId';
  String get _hiddenRowsKey => '$_hiddenRowsPrefix$_connectionId';
  String get _titleKey => '$_titlePrefix$_connectionId';
  String get _deletedKey => '$_deletedPrefix$_connectionId';
  String get _autoTitleKey => '$_autoTitlePrefix$_connectionId';

  void _read() {
    _archived = (_prefs.getStringList(_key) ?? []).toSet();
    _pinned = (_prefs.getStringList(_pinnedKey) ?? []).toSet();
    _hidden = (_prefs.getStringList(_hiddenKey) ?? []).toSet();
    _hiddenRows = _decodeHiddenRows(
      _prefs.getStringList(_hiddenRowsKey) ?? const [],
    );
    _titles = _decodeTitles(_prefs.getStringList(_titleKey) ?? const []);
    _autoTitles = _decodeTitles(
      _prefs.getStringList(_autoTitleKey) ?? const [],
    );
    final deleted = _decodeDeleted(
      _prefs.getStringList(_deletedKey) ?? const [],
    );
    _deleted = deleted.watermarks;
    _deletedScope = deleted.scopes;
  }

  void _resync() {
    final archived = _archived;
    final pinned = _pinned;
    final hidden = _hidden;
    final hiddenRows = _encodeHiddenRows(_hiddenRows);
    final titles = _titles;
    final autoTitles = _autoTitles;
    final deleted = _deleted;
    final deletedScope = _deletedScope;
    _read();
    if (setEquals(archived, _archived) &&
        setEquals(pinned, _pinned) &&
        setEquals(hidden, _hidden) &&
        listEquals(hiddenRows, _encodeHiddenRows(_hiddenRows)) &&
        mapEquals(titles, _titles) &&
        mapEquals(autoTitles, _autoTitles) &&
        mapEquals(deleted, _deleted) &&
        mapEquals(deletedScope, _deletedScope)) {
      return;
    }
    _revision++;
    notifyListeners();
  }

  // Helpers canónicos: viven en el modelo Session (single source of truth).
  static bool isPlaceholderTitle(String title) =>
      Session.isPlaceholderTitle(title);

  static String generateTitleFromPrompt(String prompt) =>
      Session.titleFromText(prompt);

  // ── Archivado ───────────────────────────────────────────────────────────

  /// Returns true if the session with [sessionId] is archived.
  bool isArchived(String sessionId) => _archived.contains(sessionId);

  bool isSessionArchived(Session session) =>
      session.archived || _archived.contains(session.logicalId);

  /// Archives the session with [sessionId] and persists immediately.
  /// Archivar desfija: una sesión guardada para más tarde no debe ocupar el
  /// espacio de "fijadas" arriba.
  Future<void> archive(String sessionId) async {
    _archived.add(sessionId);
    _pinned.remove(sessionId);
    await _flush();
  }

  /// Removes [sessionId] from the archive and persists immediately.
  Future<void> unarchive(String sessionId) async {
    _archived.remove(sessionId);
    await _flush();
  }

  Future<void> archiveSession(Session session) => archive(session.logicalId);

  Future<void> unarchiveSession(Session session) =>
      unarchive(session.logicalId);

  // ── Fijadas (pin) ──────────────────────────────────────────────────────────

  /// Returns true if the session with [sessionId] is pinned.
  bool isPinned(String sessionId) => _pinned.contains(sessionId);

  bool isSessionPinned(Session session) => _pinned.contains(session.logicalId);

  int get pinnedCount => _pinned.length;

  Set<String> get pinnedIds => Set<String>.unmodifiable(_pinned);

  /// Pins the session with [sessionId]. Archivar y fijar son mutuamente
  /// excluyentes: una sesión archivada no debería seguir fijada arriba.
  Future<void> pin(String sessionId) async {
    _pinned.add(sessionId);
    _archived.remove(sessionId);
    await _flush();
  }

  Future<void> unpin(String sessionId) async {
    _pinned.remove(sessionId);
    await _flush();
  }

  Future<void> pinSession(Session session) => pin(session.logicalId);

  Future<void> unpinSession(Session session) async {
    _pinned.removeAll({
      session.logicalId,
      session.id,
      if (session.lineageRootId != null &&
          session.parentSessionId?.isNotEmpty == true)
        session.parentSessionId!,
    });
    await _flush();
  }

  // ── Ocultas localmente ────────────────────────────────────────────────────

  bool isHidden(String sessionId) =>
      _hiddenOverlay[sessionId]?.value ?? _hidden.contains(sessionId);

  /// Hidden on any surface: a write not yet confirmed (or a newer local
  /// toggle) wins, then the server's flag, then the local fallback set.
  /// A row without the flag (a search hit) is hidden when this device hid
  /// it on the server.
  bool isSessionHidden(Session session) {
    final overlay = _hiddenOverlay[session.logicalId];
    if (overlay != null) return overlay.value;
    if (session.hidden == true) return true;
    if (_hidden.contains(session.logicalId)) return true;
    return session.hidden == null &&
        _hiddenRows[session.logicalId]?.hidden == true;
  }

  /// Hidden on the server (so on Desktop too), not only on this device.
  bool isSessionHiddenOnServer(Session session) {
    final overlay = _hiddenOverlay[session.logicalId];
    if (overlay != null) return overlay.value && overlay.ack != null;
    if (session.hidden == true) return true;
    return session.hidden == null &&
        _hiddenRows[session.logicalId]?.hidden == true;
  }

  int get hiddenCount => _hidden.length;

  /// Every chat hidden from this device, newest first: what Archive >
  /// Hidden lists. Hermes' default listing omits hidden rows and Desktop has
  /// no hidden view, so these come from the snapshots taken when hiding (or
  /// when a read showed a legacy local id); a local id never seen in a read
  /// is listed by id alone.
  List<Session> get hiddenSessions {
    final rows = <Session>[];
    final covered = <String>{};
    for (final row in _hiddenRows.values) {
      if (!isSessionHidden(row)) continue;
      rows.add(row);
      covered.addAll(_aliases(row));
    }
    for (final id in _hidden) {
      if (!covered.add(id)) continue;
      rows.add(_placeholderRow(id));
    }
    rows.sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
    return List<Session>.unmodifiable(rows);
  }

  /// Chats shown again whose row a list may still omit: a read begun before
  /// the server confirmed does not carry them. Lists add them back until a
  /// later read does.
  List<Session> get revealedSessions =>
      List<Session>.unmodifiable(_revealed.values);

  static Session _placeholderRow(String id) => Session(
    id: id,
    title: '',
    model: '',
    source: '',
    messageCount: 0,
    isActive: false,
    preview: '',
    startedAt: 0,
  );

  Future<void> hide(String sessionId) async {
    _hidden.add(sessionId);
    await _flush();
  }

  Future<void> hideAll(Iterable<String> ids) async {
    _hidden.addAll(ids);
    await _flush();
  }

  Future<void> unhide(String sessionId) async {
    _hidden.remove(sessionId);
    _hiddenRows.remove(sessionId);
    _hiddenOverlay.remove(sessionId);
    await _flush();
  }

  /// Hides [session] on every surface. The id is persisted locally BEFORE
  /// the server is asked, and dropped only once the server confirms
  /// `hidden: true`; until then (failure, restart, offline) it keeps the
  /// session hidden here and is retried on the next list read.
  Future<void> hideSession(Session session) async {
    final id = session.logicalId;
    final generation = _newIntent(_hiddenField, id);
    _hiddenOverlay.remove(id);
    _hidden.add(id);
    _revealed.remove(id);
    final known = _hiddenRows[id];
    _hiddenRows[id] = known != null && session.hidden == null ? known : session;
    await _flush();
    if (_canWriteHidden(session)) _writeHidden(session, true, generation);
  }

  Future<void> unhideSession(Session session) async {
    final id = session.logicalId;
    final generation = _newIntent(_hiddenField, id);
    final aliases = _aliases(session);
    final heldLocally = aliases.where(_hidden.contains).toSet();
    _hidden.removeAll(aliases);
    final snapshot = _hiddenRows[id];
    _hiddenRows.removeWhere((key, _) => aliases.contains(key));
    // A search hit carries no hidden flag: the snapshot says whether the
    // server holds the hide.
    final remote =
        _writable(_hiddenField) &&
        !session.isUnpersistedMobileDraft &&
        (session.hidden != null || snapshot?.hidden == true);
    if (remote) {
      _hiddenOverlay[id] = _StateOverlay(false, generation);
    } else {
      _hiddenOverlay.remove(id);
    }
    // The list row taken when hiding, not a search hit with its snippet.
    _revealed[id] = (snapshot ?? session).copyWith(hidden: false);
    await _flush();
    if (remote) {
      _writeHidden(
        session,
        false,
        generation,
        restore: heldLocally,
        restoreRow: snapshot,
      );
    }
  }

  /// Restaura todas las ocultas (las vuelve a mostrar).
  Future<void> clearHidden() async {
    _hidden.clear();
    await _flush();
  }

  // ── Borradas en el servidor ───────────────────────────────────────────────

  /// True when [session] is a row the server already confirmed deleted.
  ///
  /// Every screen (Home recents, Conversations, drawer) filters with this, so
  /// a delete made on any screen drops the row everywhere in the same frame
  /// and a stale retained page, cached tail or slow refresh cannot bring it
  /// back. Any id the row answers to matches (live id, lineage root, each
  /// compression segment, as Desktop's `tombstoneRowIds`), so a page naming
  /// the same conversation by another segment stays hidden; and only up to
  /// the activity watermark recorded at deletion: a row with newer activity
  /// is real data (the server recreated it) and is shown.
  bool isSessionDeleted(Session session) {
    if (_deleted.isEmpty) return false;
    final activity = _activitySeconds(session.lastActivityAt);
    for (final id in session.identityIds) {
      final watermark = _deleted[id];
      if (watermark != null && activity <= watermark) return true;
    }
    return false;
  }

  /// True when the server confirmed [sessionId] deleted and no server list
  /// row has shown it recreated since.
  ///
  /// For surfaces that only hold an id (the home screen widget): a late
  /// event from the deleted chat stamps fresh activity, so the watermark
  /// rule of [isSessionDeleted] would let it back in. Only an authoritative
  /// list row with activity after the delete releases it (see
  /// [SessionListRead.end]).
  bool isSessionIdDeleted(String sessionId) => _deleted.containsKey(sessionId);

  /// Records a deletion the server confirmed for [session] (every id it
  /// answers to) and [sessionIds] (the physical ids that were deleted).
  /// Notifies every screen synchronously.
  ///
  /// The tombstone stays until the server's own data proves it is no longer
  /// needed (see [SessionListRead.end]); no count bound ever drops one.
  Future<void> markSessionDeleted(
    Session session, {
    Iterable<String> sessionIds = const [],
    DateTime? now,
  }) {
    final nowSeconds = (now ?? DateTime.now()).millisecondsSinceEpoch / 1000.0;
    final activity = _activitySeconds(session.lastActivityAt);
    final watermark = activity > nowSeconds ? activity : nowSeconds;
    // Only a row the default listing carries (an own, unarchived row) can
    // be confirmed absent by it; any other tombstone is kept.
    final scope = !session.archived && session.listsAsOwnRow
        ? Session.profileOwner(session.profile)
        : null;
    for (final id in {...session.identityIds, ...sessionIds}) {
      if (id.isEmpty) continue;
      final previous = _deleted[id];
      if (scope != null && (previous == null || _deletedScope[id] == scope)) {
        _deletedScope[id] = scope;
      } else {
        _deletedScope.remove(id);
      }
      if (previous == null || previous < watermark) _deleted[id] = watermark;
      _deletedAfterRead[id] = _listReadSeq;
      _confirmedGone.remove(id);
    }
    return _flush();
  }

  /// Starts a session list read (a page or walk of `/api/sessions`) whose
  /// rows will be stored or painted. Call [SessionListRead.end] with the
  /// server rows once its result has been applied, or without rows when it
  /// was abandoned.
  ///
  /// As in Desktop (projects.ts keeps a tombstone while the authoritative
  /// snapshot still lists the id), a tombstone goes only when a complete
  /// listing of its profile, started after the delete, no longer names any
  /// id of the row, and once every read that began before the delete has
  /// ended (one of those could still carry the row). A page, a bounded walk
  /// or a cached answer proves nothing about rows it does not show, so it
  /// never drops one, whatever the count.
  SessionListRead beginListRead() {
    final id = ++_listReadSeq;
    _openListReads.add(id);
    return SessionListRead._(this, id, _ackSeq);
  }

  void _endListRead(
    int id,
    Iterable<Session> rows,
    String? completeProfile,
    int ackFence,
  ) {
    if (!_openListReads.remove(id)) return;
    _reconcileServerState(rows, ackFence);
    final released = _releaseRecreated(rows);
    // A read started after the delete that still names a confirmed id
    // contradicts the confirmation: keep the tombstone. (A read begun
    // before the delete naming it is the stale answer it guards against.)
    if (_confirmedGone.isNotEmpty) {
      for (final row in rows) {
        for (final named in row.identityIds) {
          if (!_confirmedGone.contains(named)) continue;
          final lastReadBefore = _deletedAfterRead[named];
          if (lastReadBefore == null || id > lastReadBefore) {
            _confirmedGone.remove(named);
          }
        }
      }
    }
    if (completeProfile != null) _confirmAbsent(id, rows, completeProfile);
    if (_evictConfirmedGone() || released) unawaited(_flush());
  }

  /// [rows] are the complete default listing of [profile], read by [readId]:
  /// every tombstone of that profile recorded before the read started whose
  /// ids it does not name is confirmed gone on the server.
  void _confirmAbsent(int readId, Iterable<Session> rows, String profile) {
    if (_deletedScope.isEmpty) return;
    final owner = Session.profileOwner(profile);
    final listed = <String>{for (final row in rows) ...row.identityIds};
    _deletedScope.forEach((id, scope) {
      if (scope != owner || listed.contains(id)) return;
      final lastReadBefore = _deletedAfterRead[id];
      if (lastReadBefore != null && readId <= lastReadBefore) return;
      _confirmedGone.add(id);
    });
  }

  /// Drops the confirmed tombstones no read still in flight can need.
  /// Returns whether any went.
  bool _evictConfirmedGone() {
    var evicted = false;
    for (final id in _confirmedGone.toList()) {
      if (_tombstoneNeeded(id)) continue;
      _forgetTombstone(id);
      evicted = true;
    }
    return evicted;
  }

  void _forgetTombstone(String id) {
    _deleted.remove(id);
    _deletedScope.remove(id);
    _deletedAfterRead.remove(id);
    _confirmedGone.remove(id);
  }

  /// A server row with activity newer than a tombstone's watermark is the
  /// session recreated (real data, as [isSessionDeleted] already shows it):
  /// its tombstone goes, so readers that only hold an id (the home screen
  /// widget, [isSessionIdDeleted]) show it again. An older copy of the
  /// deleted row never releases it. Returns whether any went.
  bool _releaseRecreated(Iterable<Session> rows) {
    if (_deleted.isEmpty) return false;
    var released = false;
    for (final row in rows) {
      final activity = _activitySeconds(row.lastActivityAt);
      for (final id in row.identityIds) {
        final watermark = _deleted[id];
        if (watermark == null || activity <= watermark) continue;
        _forgetTombstone(id);
        released = true;
      }
    }
    return released;
  }

  /// A tombstone is still needed while a list read that began before it was
  /// recorded is open.
  bool _tombstoneNeeded(String id) {
    final lastReadBefore = _deletedAfterRead[id];
    if (lastReadBefore == null) return false;
    return _openListReads.any((read) => read <= lastReadBefore);
  }

  /// Session timestamps arrive in seconds or milliseconds.
  static double _activitySeconds(double value) =>
      value > 100000000000 ? value / 1000 : value;

  /// Rows are `id<TAB>watermark[<TAB>profile]`; older builds wrote no
  /// profile, so their tombstones are never confirmed absent, only kept.
  static ({Map<String, double> watermarks, Map<String, String> scopes})
  _decodeDeleted(List<String> rows) {
    final watermarks = <String, double>{};
    final scopes = <String, String>{};
    for (final row in rows) {
      final fields = row.split('\t');
      if (fields.length < 2 || fields.first.isEmpty) continue;
      final watermark = double.tryParse(fields[1]);
      if (watermark == null || !watermark.isFinite) continue;
      watermarks[fields.first] = watermark;
      if (fields.length > 2 && fields[2].isNotEmpty) {
        scopes[fields.first] = fields[2];
      }
    }
    return (watermarks: watermarks, scopes: scopes);
  }

  String _encodeDeleted(String id, double watermark) {
    final scope = _deletedScope[id];
    return scope == null ? '$id\t$watermark' : '$id\t$watermark\t$scope';
  }

  // ── Títulos locales ──────────────────────────────────────────────────────

  String titleFor(String sessionId, String serverTitle) =>
      _overrideTitle(sessionId, placeholder: isPlaceholderTitle(serverTitle)) ??
      serverTitle;

  /// A rename the server has not confirmed yet, then a local override, then
  /// (only while the server title is a placeholder) the chat's auto-title,
  /// then the server's own title.
  String titleForSession(Session session, {Strings? strings}) =>
      _overrideTitle(
        session.logicalId,
        physicalId: session.id,
        placeholder: isPlaceholderTitle(session.title),
      ) ??
      (strings == null
          ? session.displayTitle
          : localizedSessionTitle(strings, session));

  String? _overrideTitle(
    String id, {
    String? physicalId,
    required bool placeholder,
  }) {
    final pending = _titleOverlay[id]?.value;
    if (pending != null) return pending;
    final local = _titles[id]?.trim();
    if (local != null && local.isNotEmpty) return local;
    if (!placeholder) return null;
    final auto = (_autoTitles[id] ?? _autoTitles[physicalId])?.trim();
    return auto != null && auto.isNotEmpty ? auto : null;
  }

  Future<void> setTitle(String sessionId, String title) async {
    final clean = title.trim();
    if (clean.isEmpty) {
      _titles.remove(sessionId);
    } else {
      _titles[sessionId] = clean;
    }
    await _flushTitles();
  }

  Future<void> setSessionTitle(Session session, String title) =>
      setTitle(session.logicalId, title);

  /// Lazily copies physical-id preferences to the stable lineage key.
  ///
  /// Legacy entries are intentionally retained after the verified write. This
  /// makes the migration idempotent across crashes and preserves conflict
  /// evidence without deleting any local or remote session state.
  Future<void> migrateLogicalIdentity(
    Session session, {
    Iterable<String> knownPhysicalIds = const [],
  }) async {
    final logicalId = session.logicalId;
    if (logicalId == session.id) return;
    final physicalIds = <String>{
      session.id,
      if (session.parentSessionId?.isNotEmpty == true) session.parentSessionId!,
      ...knownPhysicalIds.where((id) => id.isNotEmpty),
    };
    var changed = false;
    if (physicalIds.any(_archived.contains) && _archived.add(logicalId)) {
      changed = true;
    }
    if (physicalIds.any(_pinned.contains) && _pinned.add(logicalId)) {
      changed = true;
    }
    if (physicalIds.any(_hidden.contains) && _hidden.add(logicalId)) {
      changed = true;
    }
    if (_titles[logicalId]?.trim().isNotEmpty != true) {
      for (final id in physicalIds) {
        final title = _titles[id]?.trim();
        if (title != null && title.isNotEmpty) {
          _titles[logicalId] = title;
          changed = true;
          break;
        }
      }
    }
    if (_autoTitles[logicalId]?.trim().isNotEmpty != true) {
      for (final id in physicalIds) {
        final title = _autoTitles[id]?.trim();
        if (title != null && title.isNotEmpty) {
          _autoTitles[logicalId] = title;
          changed = true;
          break;
        }
      }
    }
    if (!changed) return;
    await _flush();
    final verified =
        (!physicalIds.any(_archived.contains) ||
            _archived.contains(logicalId)) &&
        (!physicalIds.any(_pinned.contains) || _pinned.contains(logicalId)) &&
        (!physicalIds.any(_hidden.contains) || _hidden.contains(logicalId));
    if (!verified) {
      throw StateError('Session preference lineage migration was not verified');
    }
  }

  Future<bool> autoTitleIfPlaceholder({
    required String sessionId,
    required String currentTitle,
    required String prompt,
  }) async {
    if (_titles[sessionId]?.trim().isNotEmpty == true) return false;
    if (_autoTitles[sessionId]?.trim().isNotEmpty == true) return false;
    if (!isPlaceholderTitle(currentTitle)) return false;
    final title = generateTitleFromPrompt(prompt);
    if (title.isEmpty) return false;
    _autoTitles[sessionId] = title;
    await _flushTitles();
    return true;
  }

  // ── Server-synced state (hidden, title, read) ────────────────────────────

  static const _hiddenField = 'hidden';
  static const _titleField = 'title';
  static const _unreadField = 'unread';

  /// Attached writers, newest last: a screen that closes detaches its own
  /// and the one beneath (Home's) takes over.
  final List<({SessionStateWriter write, int? Function(Object) statusOf})>
  _remotes = [];

  SessionStateWriter? get _remote =>
      _remotes.isEmpty ? null : _remotes.last.write;

  int? _httpStatusOf(Object error) =>
      _remotes.isEmpty ? null : _remotes.last.statusOf(error);

  /// Fields this server's PATCH handler refused: written locally only from
  /// then on (this process).
  final Set<String> _rejectedFields = {};

  /// Latest local intent per field and session; an answer that belongs to
  /// an older intent never touches the state.
  int _intentSeq = 0;
  final Map<String, int> _intents = {};

  /// One write per field and session at a time, in intent order, so the
  /// server ends with the last value the user chose.
  final Map<String, Future<void>> _writeChains = {};
  final Set<Future<void>> _writesInFlight = {};

  /// Server writes acknowledged so far; see [SessionListRead].
  int _ackSeq = 0;
  final Map<String, _StateOverlay<bool>> _hiddenOverlay = {};
  final Map<String, _StateOverlay<bool>> _unreadOverlay = {};
  final Map<String, _StateOverlay<String>> _titleOverlay = {};

  /// Local hidden ids with a `hidden: true` write queued or in flight, and
  /// those the server answered 404 for (no such session there).
  final Set<String> _hiddenQueued = {};
  final Set<String> _hiddenMissing = {};

  /// Rows of the last list read, for a writer attached after it.
  List<Session> _lastRows = const [];

  static int? _noHttpStatus(Object _) => null;

  /// Lets this store write hidden, title and read state to the server with
  /// [writer] (PATCH /api/sessions/{id}). [httpStatusOf] maps a failure to
  /// its HTTP status: 400/405/422 mean the handler does not take the field,
  /// which then stays local. Pending local hides are pushed at once against
  /// the rows already read.
  void attachRemoteState(
    SessionStateWriter writer, {
    int? Function(Object error)? httpStatusOf,
  }) {
    _remotes
      ..removeWhere((remote) => remote.write == writer)
      ..add((write: writer, statusOf: httpStatusOf ?? _noHttpStatus));
    _migrateHidden(_lastRows);
  }

  /// Forgets [writer] (its owner closed); an earlier one takes over.
  void detachRemoteState(SessionStateWriter writer) =>
      _remotes.removeWhere((remote) => remote.write == writer);

  /// Completes once every server write started so far has ended.
  Future<void> get remoteStateSettled async {
    while (_writesInFlight.isNotEmpty) {
      await Future.wait(_writesInFlight.toList());
    }
  }

  bool _writable(String field) =>
      _remote != null && !_rejectedFields.contains(field);

  /// The server takes `hidden` for [session]: its rows publish the flag.
  bool _canWriteHidden(Session session) =>
      _writable(_hiddenField) &&
      session.hidden != null &&
      !session.isUnpersistedMobileDraft;

  /// A hide of [session] reaches the server (and so Desktop).
  bool hidesOnServer(Session session) => _canWriteHidden(session);

  String _intentKey(String field, String id) => '$field\u0000$id';

  int _newIntent(String field, String id) =>
      _intents[_intentKey(field, id)] = ++_intentSeq;

  bool _isCurrent(String field, String id, int generation) =>
      _intents[_intentKey(field, id)] == generation;

  /// The handler refused the field itself (older server: unknown keys are
  /// ignored, so a body with only that key is "nothing to update").
  bool _rejectsField(Object error) {
    final status = _httpStatusOf(error);
    return status == 400 || status == 405 || status == 422;
  }

  Set<String> _aliases(Session session) => {
    session.logicalId,
    ...session.identityIds,
    if (session.lineageRootId != null &&
        session.parentSessionId?.isNotEmpty == true)
      session.parentSessionId!,
  };

  Future<T> _serialized<T>(String key, Future<T> Function() task) {
    final previous = _writeChains[key] ?? Future<void>.value();
    final result = previous.then((_) => task());
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _writeChains[key] = tail;
    _writesInFlight.add(tail);
    unawaited(
      tail.whenComplete(() {
        _writesInFlight.remove(tail);
        if (identical(_writeChains[key], tail)) _writeChains.remove(key);
      }),
    );
    return result;
  }

  void _changed() {
    _revision++;
    notifyListeners();
  }

  bool _dropOverlay<T>(
    Map<String, _StateOverlay<T>> overlays,
    String id,
    int generation,
  ) {
    if (overlays[id]?.generation != generation) return false;
    overlays.remove(id);
    return true;
  }

  void _writeHidden(
    Session row,
    bool hidden,
    int generation, {
    Set<String> restore = const {},
    Session? restoreRow,
  }) {
    final id = row.logicalId;
    if (hidden) _hiddenQueued.add(id);
    unawaited(
      _serialized<void>(_intentKey(_hiddenField, id), () async {
        try {
          if (!_isCurrent(_hiddenField, id, generation) ||
              !_writable(_hiddenField)) {
            return;
          }
          final Map<String, Object?> answer;
          try {
            answer = await _remote!(row.id, {'hidden': hidden}, row.profile);
          } catch (error) {
            final rejected = _rejectsField(error);
            if (rejected) {
              _rejectedFields.add(_hiddenField);
            } else if (_httpStatusOf(error) == 404) {
              _hiddenMissing.add(id);
            }
            await _hiddenWriteFailed(
              id,
              generation,
              restore,
              rejected,
              restoreRow,
            );
            return;
          }
          if (answer['hidden'] != hidden) {
            final rejected = !answer.containsKey('hidden');
            if (rejected) _rejectedFields.add(_hiddenField);
            await _hiddenWriteFailed(
              id,
              generation,
              restore,
              rejected,
              restoreRow,
            );
            return;
          }
          final ack = ++_ackSeq;
          if (!_isCurrent(_hiddenField, id, generation)) return;
          if (hidden) {
            // Confirmed: the server's copy holds it now. Only here does the
            // local copy go.
            _hiddenOverlay[id] = _StateOverlay(true, generation)..ack = ack;
            _hidden.removeAll(_aliases(row));
            _hiddenRows[id] = (_hiddenRows[id] ?? row).copyWith(hidden: true);
            await _flush();
          } else {
            _hiddenOverlay[id]?.ack ??= ack;
          }
        } finally {
          if (hidden) _hiddenQueued.remove(id);
        }
      }),
    );
  }

  /// A hide keeps its local id (retried on a later read). A failed unhide
  /// is rolled back visibly, unless the server does not take the field, in
  /// which case the local unhide stands.
  Future<void> _hiddenWriteFailed(
    String id,
    int generation,
    Set<String> restore,
    bool rejected,
    Session? restoreRow,
  ) async {
    if (!_isCurrent(_hiddenField, id, generation)) return;
    final dropped = _dropOverlay(_hiddenOverlay, id, generation);
    if (!rejected && (restore.isNotEmpty || restoreRow != null)) {
      _hidden.addAll(restore);
      if (restoreRow != null) {
        _hiddenRows[id] = restoreRow;
        _revealed.remove(id);
      }
      await _flush();
    } else if (dropped) {
      _changed();
    }
  }

  /// Pushes local hidden ids (older builds, or hides the server has not
  /// confirmed) for the rows a list read returned. Idempotent: only ids
  /// still held locally, for a row that exists and is not hidden there yet,
  /// with no write already queued. Never sends `hidden: false`.
  void _migrateHidden(List<Session> rows) {
    if (_hidden.isEmpty || !_writable(_hiddenField)) return;
    for (final row in rows) {
      if (!_canWriteHidden(row) || row.hidden == true) continue;
      final id = row.logicalId;
      if (_hiddenQueued.contains(id) || _hiddenMissing.contains(id)) continue;
      if (_hiddenOverlay[id]?.value == false) continue;
      if (!_aliases(row).any(_hidden.contains)) continue;
      final generation =
          _intents[_intentKey(_hiddenField, id)] ??
          _newIntent(_hiddenField, id);
      _writeHidden(row, true, generation);
    }
  }

  /// Applies a finished list read: optimistic values acknowledged before the
  /// read began give way to its rows, a row the server shows hidden
  /// confirms a pending local hide, and pending hides are pushed.
  void _reconcileServerState(Iterable<Session> rows, int ackFence) {
    final list = rows.toList(growable: false);
    var changed = false;
    var persist = false;
    bool settle<T>(Map<String, _StateOverlay<T>> overlays, String id) {
      final ack = overlays[id]?.ack;
      if (ack == null || ack > ackFence) return false;
      overlays.remove(id);
      return true;
    }

    for (final row in list) {
      final id = row.logicalId;
      if (settle(_hiddenOverlay, id)) changed = true;
      if (settle(_unreadOverlay, id)) changed = true;
      if (settle(_titleOverlay, id)) changed = true;
      final overlay = _hiddenOverlay[id];
      final heldLocally = _aliases(row).any(_hidden.contains);
      // A legacy local id gets the row it needs to be listed in Hidden.
      if (heldLocally && overlay == null && !_hiddenRows.containsKey(id)) {
        _hiddenRows[id] = row;
        persist = true;
      }
      if (row.hidden == true && overlay == null) {
        final before = _hidden.length;
        _hidden.removeAll(_aliases(row));
        if (_hidden.length != before) persist = true;
        final known = _hiddenRows[id];
        if (known != null && known.hidden != true) {
          _hiddenRows[id] = known.copyWith(hidden: true);
          persist = true;
        }
      } else if (row.hidden == false &&
          overlay == null &&
          !heldLocally &&
          !_hiddenQueued.contains(id) &&
          _hiddenRows.remove(id) != null) {
        // Shown again elsewhere (another device, or a pin on Desktop).
        persist = true;
      }
      if (overlay == null && _revealed.remove(id) != null) {
        changed = true;
      }
      // An override equal to the server's title is redundant; dropping it
      // lets a later rename from Desktop show here.
      final local = _titles[id]?.trim();
      if (local != null && local.isNotEmpty && local == row.title.trim()) {
        _titles.remove(id);
        persist = true;
      }
    }
    if (list.isNotEmpty) _lastRows = list;
    if (persist) {
      unawaited(_flush());
    } else if (changed) {
      _changed();
    }
    _migrateHidden(list);
  }

  /// Renames [session] on the server (PATCH title, as Desktop). The new
  /// title shows at once and stays until a list read started after the
  /// answer carries the row. Without a server that takes titles (gateway
  /// only, read-only, an older handler, an unpersisted chat) the rename is
  /// a local override, as before. Any other failure rolls back and throws.
  Future<void> renameSession(Session session, String title) async {
    final clean = title.trim();
    if (clean.isEmpty) return;
    final id = session.logicalId;
    if (!_writable(_titleField) || session.isUnpersistedMobileDraft) {
      return setSessionTitle(session, clean);
    }
    final generation = _newIntent(_titleField, id);
    _titleOverlay[id] = _StateOverlay(clean, generation);
    _changed();
    return _serialized<void>(_intentKey(_titleField, id), () async {
      if (!_isCurrent(_titleField, id, generation)) return;
      final Map<String, Object?> answer;
      try {
        answer = await _remote!(session.id, {'title': clean}, session.profile);
      } catch (error) {
        final status = _httpStatusOf(error);
        final unsupported = status == 405 || status == 422;
        if (unsupported) _rejectedFields.add(_titleField);
        final dropped = _dropOverlay(_titleOverlay, id, generation);
        if ((unsupported || status == 404) &&
            _isCurrent(_titleField, id, generation)) {
          await setTitle(id, clean);
          return;
        }
        if (dropped) _changed();
        rethrow;
      }
      final confirmed = answer['title'];
      if (answer['ok'] != true || confirmed is! String) {
        if (_dropOverlay(_titleOverlay, id, generation)) _changed();
        throw const FormatException('Invalid Dashboard rename response');
      }
      final ack = ++_ackSeq;
      if (!_isCurrent(_titleField, id, generation)) return;
      _titleOverlay[id] = _StateOverlay(
        confirmed.trim().isEmpty ? clean : confirmed.trim(),
        generation,
      )..ack = ack;
      for (final alias in _aliases(session)) {
        _titles.remove(alias);
        _autoTitles.remove(alias);
      }
      await _flushTitles();
    });
  }

  /// Unread as the server derives it, under a toggle not yet confirmed.
  bool isSessionUnread(Session session) =>
      _unreadOverlay[session.logicalId]?.value ?? session.unread == true;

  /// The read state can be written: the server publishes it on its rows and
  /// takes it in PATCH.
  bool canToggleUnread(Session session) =>
      _writable(_unreadField) &&
      session.unread != null &&
      !session.isUnpersistedMobileDraft;

  /// Marks [session] unread or read on the server (Desktop's row toggle):
  /// shown at once, rolled back and rethrown when the write fails. A
  /// handler that does not take the field drops it silently.
  Future<void> setSessionUnread(Session session, bool unread) {
    if (!canToggleUnread(session)) return Future.value();
    final id = session.logicalId;
    final generation = _newIntent(_unreadField, id);
    _unreadOverlay[id] = _StateOverlay(unread, generation);
    _changed();
    return _serialized<void>(_intentKey(_unreadField, id), () async {
      if (!_isCurrent(_unreadField, id, generation)) return;
      final Map<String, Object?> answer;
      try {
        answer = await _remote!(session.id, {
          'unread': unread,
        }, session.profile);
      } catch (error) {
        final rejected = _rejectsField(error);
        if (rejected) _rejectedFields.add(_unreadField);
        if (_dropOverlay(_unreadOverlay, id, generation)) _changed();
        if (rejected) return;
        rethrow;
      }
      if (answer['unread'] != unread) {
        if (_dropOverlay(_unreadOverlay, id, generation)) _changed();
        if (!answer.containsKey('unread')) {
          _rejectedFields.add(_unreadField);
          return;
        }
        throw const FormatException('Invalid Dashboard read-state response');
      }
      final ack = ++_ackSeq;
      final overlay = _unreadOverlay[id];
      if (overlay != null && overlay.generation == generation) {
        overlay.ack = ack;
      }
    });
  }

  /// Opening a session marks it read on the server when it shows unread
  /// (Desktop `clearUnreadOnOpen`: on every open, no debounce). Best effort:
  /// a failure only leaves the dot until the next read.
  Future<void> markSessionReadOnOpen(Session session) async {
    if (!isSessionUnread(session) || !canToggleUnread(session)) return;
    try {
      await setSessionUnread(session, false);
    } catch (_) {}
  }

  /// Writes every set into the preferences cache before the first await and
  /// notifies readers synchronously, so all screens observe one coherent cut.
  Future<void> _flush() {
    _revision++;
    final writes = Future.wait<bool>([
      _prefs.setStringList(_key, _archived.toList()),
      _prefs.setStringList(_pinnedKey, _pinned.toList()),
      _prefs.setStringList(_hiddenKey, _hidden.toList()),
      if (_hiddenRows.isNotEmpty || _prefs.containsKey(_hiddenRowsKey))
        _prefs.setStringList(_hiddenRowsKey, _encodeHiddenRows(_hiddenRows)),
      _writeTitles(),
      _writeAutoTitles(),
      if (_deleted.isNotEmpty || _prefs.containsKey(_deletedKey))
        _prefs.setStringList(
          _deletedKey,
          _deleted.entries.map((e) => _encodeDeleted(e.key, e.value)).toList(),
        ),
    ]);
    notifyListeners();
    return writes;
  }

  Future<void> _flushTitles() {
    _revision++;
    final write = Future.wait<bool>([_writeTitles(), _writeAutoTitles()]);
    notifyListeners();
    return write;
  }

  Future<bool> _writeAutoTitles() =>
      _autoTitles.isEmpty && !_prefs.containsKey(_autoTitleKey)
      ? Future.value(true)
      : _prefs.setStringList(
          _autoTitleKey,
          _autoTitles.entries.map((e) => '${e.key}\t${e.value}').toList(),
        );

  Future<bool> _writeTitles() => _prefs.setStringList(
    _titleKey,
    _titles.entries.map((e) => '${e.key}\t${e.value}').toList(),
  );

  /// The few fields a Hidden row needs, in the server's JSON shape.
  static List<String> _encodeHiddenRows(Map<String, Session> rows) => [
    for (final row in rows.values)
      jsonEncode({
        'id': row.id,
        'title': row.title,
        'source': row.source,
        'profile': ?row.profile,
        'started_at': row.startedAt,
        'last_active': row.lastActivityAt,
        'lineage_root': ?row.lineageRootId,
        'parent_session_id': ?row.parentSessionId,
        'message_count': row.messageCount,
        'archived': row.archived,
        'hidden': ?row.hidden,
      }),
  ];

  static Map<String, Session> _decodeHiddenRows(List<String> rows) {
    final decoded = <String, Session>{};
    for (final raw in rows) {
      Object? json;
      try {
        json = jsonDecode(raw);
      } on FormatException {
        continue;
      }
      final row = Session.tryParse(json);
      if (row != null) decoded[row.logicalId] = row;
    }
    return decoded;
  }

  static Map<String, String> _decodeTitles(List<String> rows) {
    final titles = <String, String>{};
    for (final row in rows) {
      final tab = row.indexOf('\t');
      if (tab <= 0) continue;
      final id = row.substring(0, tab);
      final title = row.substring(tab + 1).trim();
      if (title.isNotEmpty) titles[id] = title;
    }
    return titles;
  }
}

/// PATCH /api/sessions/{id} with [fields] for the row owned by [profile];
/// returns the handler's JSON answer.
typedef SessionStateWriter =
    Future<Map<String, Object?>> Function(
      String sessionId,
      Map<String, Object> fields,
      String? profile,
    );

typedef RemoteSessionPinWriter =
    Future<void> Function(String sessionId, bool pinned, String? profile);

/// Bidirectional pin reconciliation matching Hermes Desktop's durable-pin
/// contract. Local intent is pushed before a remote page is pulled, so a page
/// captured before an in-flight PATCH cannot silently undo the user's toggle.
/// A missing `pinned` field is a legacy server with no opinion.
final class SessionPinSync {
  final SessionArchive _archive;
  final RemoteSessionPinWriter? _writeRemote;
  final bool Function(Object error) _isUnsupported;

  List<Session> _sessions = const [];
  final Set<String> _mirrored = {};
  final Set<String> _pending = {};
  final Map<String, bool> _unconfirmed = {};
  final Map<String, bool> _localIntents = {};
  final Map<String, _AcknowledgedPinWrite> _acknowledged = {};
  int _nextWriteRevision = 0;
  int _lastAcknowledgedRevision = 0;
  bool _remoteUnsupported;

  SessionPinSync(
    this._archive, {
    RemoteSessionPinWriter? writeRemote,
    bool Function(Object error)? isUnsupported,
  }) : _writeRemote = writeRemote,
       _isUnsupported = isUnsupported ?? _neverUnsupported,
       _remoteUnsupported = writeRemote == null;

  bool get remoteUnsupported => _remoteUnsupported;

  /// Captures which pin writes were acknowledged when a remote read starts.
  /// The returned fence must travel with that page until [updateSessions].
  int beginRemoteRead() => _lastAcknowledgedRevision;

  Future<void> updateSessions(
    Iterable<Session> sessions, {
    int? readFence,
  }) async {
    _sessions = List<Session>.unmodifiable(sessions);
    _pushLocalState();
    await _pullRemoteState(readFence: readFence);
  }

  Future<void> setLocalPinned(Session session, bool pinned) async {
    final pinId = session.logicalId;
    _localIntents[pinId] = pinned;
    if (!_sessions.any((row) => _matches(row, pinId))) {
      _sessions = List<Session>.unmodifiable([..._sessions, session]);
    }
    try {
      if (pinned) {
        _archive._pinned.add(pinId);
        _archive._archived.remove(pinId);
      } else {
        _archive._pinned.removeAll(_aliasesFor(session));
      }
      await _archive._flush();
      _pushLocalState();
      await _pullRemoteState();
    } finally {
      _localIntents.remove(pinId);
    }
  }

  void _pushLocalState() {
    if (_remoteUnsupported) return;
    final current = _normalizedCurrentPins();

    for (final id in <String>{..._mirrored, ..._pending}) {
      if (current.contains(id)) continue;
      _mirrored.remove(id);
      _pending.remove(id);
      _writePin(id, false, _profileFor(id));
    }

    for (final id in current) {
      if (!_mirrored.contains(id)) _pending.add(id);
    }

    for (final id in _pending.toList(growable: false)) {
      final row = _writableRowFor(id);
      if (row == null) continue;
      _pending.remove(id);
      _mirrored.add(id);
      _writePin(id, true, row.profile);
    }
  }

  Future<void> _pullRemoteState({int? readFence}) async {
    if (_remoteUnsupported) return;
    var changed = false;
    for (final row in _sessions) {
      final remote = row.pinned;
      if (remote == null) continue;
      final pinId = row.logicalId;
      final localIntent = _localIntents[pinId] ?? _localIntents[row.id];
      if (localIntent != null) continue;
      final awaited = _unconfirmed[pinId] ?? _unconfirmed[row.id];
      if (awaited != null && awaited != remote) continue;
      if (_pending.contains(pinId) || _pending.contains(row.id)) continue;
      final acknowledged = _acknowledged[pinId] ?? _acknowledged[row.id];
      if (readFence != null && acknowledged != null) {
        if (acknowledged.revision > readFence &&
            acknowledged.pinned != remote) {
          continue;
        }
        if (!acknowledged.confirmed) {
          if (acknowledged.pinned != remote) continue;
          if (readFence >= acknowledged.revision) {
            _acknowledged[pinId] = acknowledged.confirmedCopy();
          }
        }
      }

      final aliases = _aliasesFor(row);
      final heldLocally = aliases.any(_archive._pinned.contains);
      if (remote) {
        _mirrored.add(pinId);
        if (!heldLocally || !_archive._pinned.contains(pinId)) {
          _archive._pinned.add(pinId);
          _archive._archived.remove(pinId);
          changed = true;
        }
      } else if (heldLocally) {
        _mirrored.removeAll(aliases);
        _pending.removeAll(aliases);
        final pinnedCount = _archive._pinned.length;
        _archive._pinned.removeAll(aliases);
        if (_archive._pinned.length != pinnedCount) changed = true;
      }
    }
    if (changed) await _archive._flush();
  }

  Set<String> _normalizedCurrentPins() {
    final current = <String>{};
    for (final id in _archive._pinned) {
      current.add(_rowFor(id)?.logicalId ?? id);
    }
    for (final entry in _localIntents.entries) {
      if (entry.value) {
        current.add(entry.key);
      } else {
        current.remove(entry.key);
      }
    }
    return current;
  }

  Session? _rowFor(String id) {
    for (final row in _sessions) {
      if (_matches(row, id)) return row;
    }
    return null;
  }

  Session? _writableRowFor(String id) {
    for (final row in _sessions) {
      if (_matches(row, id) && !row.isUnpersistedMobileDraft) return row;
    }
    return null;
  }

  String? _profileFor(String id) => _rowFor(id)?.profile;

  Set<String> _aliasesFor(Session session) => {
    session.logicalId,
    session.id,
    if (session.lineageRootId != null &&
        session.parentSessionId?.isNotEmpty == true)
      session.parentSessionId!,
    for (final row in _sessions)
      if (row.logicalId == session.logicalId) ...{
        row.id,
        if (row.lineageRootId != null &&
            row.parentSessionId?.isNotEmpty == true)
          row.parentSessionId!,
      },
  };

  void _writePin(String id, bool pinned, String? profile) {
    final writer = _writeRemote;
    if (writer == null || _remoteUnsupported) return;
    final revision = ++_nextWriteRevision;
    _unconfirmed[id] = pinned;
    unawaited(
      Future<void>.sync(() => writer(id, pinned, profile)).then<void>(
        (_) {
          if (_unconfirmed[id] == pinned) _unconfirmed.remove(id);
          final current = _acknowledged[id];
          if (current == null || revision > current.revision) {
            _acknowledged[id] = _AcknowledgedPinWrite(revision, pinned);
          }
          if (revision > _lastAcknowledgedRevision) {
            _lastAcknowledgedRevision = revision;
          }
        },
        onError: (Object error, StackTrace _) {
          if (_unconfirmed[id] == pinned) _unconfirmed.remove(id);
          if (_isUnsupported(error)) {
            _remoteUnsupported = true;
            _pending.clear();
            _mirrored.clear();
            return;
          }
          if (pinned && _archive._pinned.contains(id)) {
            _mirrored.remove(id);
            _pending.add(id);
          }
        },
      ),
    );
  }

  static bool _matches(Session row, String id) =>
      row.id == id || row.logicalId == id;

  static bool _neverUnsupported(Object _) => false;
}

/// A local value shown over the server's until a list read that began after
/// the server acknowledged it ([ack]) carries the row again.
final class _StateOverlay<T> {
  _StateOverlay(this.value, this.generation);

  final T value;

  /// The local intent this value belongs to (see `SessionArchive._intents`).
  final int generation;
  int? ack;
}

final class _AcknowledgedPinWrite {
  final int revision;
  final bool pinned;
  final bool confirmed;

  const _AcknowledgedPinWrite(
    this.revision,
    this.pinned, {
    this.confirmed = false,
  });

  _AcknowledgedPinWrite confirmedCopy() =>
      _AcknowledgedPinWrite(revision, pinned, confirmed: true);
}

/// An open session list read; see [SessionArchive.beginListRead].
final class SessionListRead {
  SessionListRead._(this._archive, this._id, this._ackFence);

  final SessionArchive _archive;
  final int _id;

  /// Server writes acknowledged when this read started: only a read that
  /// began after a write's answer can overrule its optimistic value.
  final int _ackFence;

  /// Ends this read; [rows] are the server rows it returned (any subset).
  /// A row recreating a deleted session releases its tombstone. Pass
  /// [completeProfile] only when [rows] are that profile's complete default
  /// listing (every page of `/api/sessions`, no filter): tombstones of that
  /// profile it does not name are then confirmed gone. Only the first call
  /// counts.
  void end({Iterable<Session> rows = const [], String? completeProfile}) =>
      _archive._endListRead(_id, rows, completeProfile, _ackFence);
}
