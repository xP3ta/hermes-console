import 'dart:async';

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
///  - `session_titles_<connectionId>` — overrides locales de título cuando el
///    gateway devuelve placeholders como "Untitled".
///
/// All mutations are persisted immediately (synchronous write via the
/// SharedPreferences instance obtained at construction time).
class SessionArchive {
  static const _prefix = 'archived_sessions_';
  static const _pinnedPrefix = 'pinned_sessions_';
  static const _hiddenPrefix = 'hidden_sessions_';
  static const _titlePrefix = 'session_titles_';

  final SharedPreferences _prefs;
  final String _connectionId;

  /// The live sets; mutated in-place and flushed on every change.
  Set<String> _archived = {};
  Set<String> _pinned = {};
  Set<String> _hidden = {};
  Map<String, String> _titles = {};

  SessionArchive._(this._prefs, this._connectionId);

  /// Load the archive for [connectionId] from [prefs].
  static Future<SessionArchive> load(
    SharedPreferences prefs,
    String connectionId,
  ) async {
    final archive = SessionArchive._(prefs, connectionId);
    await archive._load();
    return archive;
  }

  String get _key => '$_prefix$_connectionId';
  String get _pinnedKey => '$_pinnedPrefix$_connectionId';
  String get _hiddenKey => '$_hiddenPrefix$_connectionId';
  String get _titleKey => '$_titlePrefix$_connectionId';

  Future<void> _load() async {
    _archived = (_prefs.getStringList(_key) ?? []).toSet();
    _pinned = (_prefs.getStringList(_pinnedKey) ?? []).toSet();
    _hidden = (_prefs.getStringList(_hiddenKey) ?? []).toSet();
    _titles = _decodeTitles(_prefs.getStringList(_titleKey) ?? const []);
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

  bool isHidden(String sessionId) => _hidden.contains(sessionId);

  bool isSessionHidden(Session session) => _hidden.contains(session.logicalId);

  int get hiddenCount => _hidden.length;

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
    await _flush();
  }

  Future<void> hideSession(Session session) => hide(session.logicalId);

  Future<void> unhideSession(Session session) => unhide(session.logicalId);

  /// Restaura todas las ocultas (las vuelve a mostrar).
  Future<void> clearHidden() async {
    _hidden.clear();
    await _flush();
  }

  // ── Títulos locales ──────────────────────────────────────────────────────

  String titleFor(String sessionId, String serverTitle) {
    final local = _titles[sessionId]?.trim();
    if (local != null && local.isNotEmpty) return local;
    return serverTitle;
  }

  String titleForSession(Session session, {Strings? strings}) => titleFor(
    session.logicalId,
    strings == null
        ? session.displayTitle
        : localizedSessionTitle(strings, session),
  );

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
    if (!isPlaceholderTitle(currentTitle)) return false;
    final title = generateTitleFromPrompt(prompt);
    if (title.isEmpty) return false;
    _titles[sessionId] = title;
    await _flushTitles();
    return true;
  }

  Future<void> _flush() async {
    await _prefs.setStringList(_key, _archived.toList());
    await _prefs.setStringList(_pinnedKey, _pinned.toList());
    await _prefs.setStringList(_hiddenKey, _hidden.toList());
    await _flushTitles();
  }

  Future<void> _flushTitles() async {
    await _prefs.setStringList(
      _titleKey,
      _titles.entries.map((e) => '${e.key}\t${e.value}').toList(),
    );
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
