import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/session.dart';
import '../session_archive.dart';

/// Clears this phone's chat notifications once the chat was read elsewhere.
///
/// Every chat notification this process posts is recorded under its tray
/// address (id + tag) with the connection, profile and session it is about,
/// and a sequence number. A session list read (Home, Conversations, drawer:
/// reads the app already makes, see [SessionArchive.beginListRead]) takes
/// the current sequence when it starts. When it ends, a row the server shows
/// read ([Session.readOnServer]: Desktop opened it, or this phone did)
/// cancels the notifications recorded for that connection, profile and
/// session **before the read started**. A notification posted while the read
/// was in flight belongs to newer activity than the rows can prove read, so
/// it stays until a later read.
///
/// Fails closed: anything not proven read (unread rows, rows without a read
/// watermark, rows without a profile, other connections or profiles, a
/// different notification since reposted at the same address) keeps the
/// notification. Desktop itself never retracts a native notification on read
/// (it only bounds retention); this mirrors its read state, not its tray.
///
/// Only the main isolate records; the ledger is persisted so a notification
/// left in the tray by an earlier process is still cleared.
class ChatNotificationReadSync implements SessionListReadObserver {
  ChatNotificationReadSync(this._prefs, {required this.cancel}) {
    _load();
  }

  static const prefsKey = 'notif_chat_read_sync_v1';

  /// Entries kept at most; the oldest go first (a dropped entry only means
  /// its notification is not retracted).
  static const maxEntries = 128;

  final SharedPreferences? _prefs;

  /// Cancels the tray notification at (id, tag).
  final Future<void> Function(int id, String? tag) cancel;

  int _seq = 0;
  final Map<String, _Entry> _entries = {};

  static String _address(int id, String? tag) => '$id|${tag ?? ''}';

  static String _profile(String? profile) =>
      Session.profileOwner(profile).toLowerCase();

  /// The sequence of the newest notification recorded so far.
  int get fence => _seq;

  /// A chat notification for [sessionId] is now at (id, tag) in the tray.
  void record({
    required int id,
    String? tag,
    required String connId,
    String? profile,
    required String sessionId,
  }) {
    final conn = connId.trim();
    final sid = sessionId.trim();
    if (conn.isEmpty || sid.isEmpty) {
      forget(id, tag);
      return;
    }
    final address = _address(id, tag);
    _entries.remove(address);
    _entries[address] = _Entry(
      id: id,
      tag: tag,
      connId: conn,
      profile: _profile(profile),
      sessionId: sid,
      seq: ++_seq,
    );
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    _persist();
  }

  /// Something else now lives at (id, tag), or it was cancelled.
  void forget(int id, String? tag) {
    if (_entries.remove(_address(id, tag)) != null) _persist();
  }

  @override
  int listReadStarted() => _seq;

  @override
  void listReadEnded(String connectionId, int startToken, List<Session> rows) {
    unawaited(
      sessionsReadOnServer(connId: connectionId, fence: startToken, rows: rows),
    );
  }

  /// Cancels what [rows] (read from [connId] by a list read that began at
  /// [fence]) prove read. Returns how many were cancelled.
  Future<int> sessionsReadOnServer({
    required String connId,
    required int fence,
    required Iterable<Session> rows,
  }) {
    final read = <String, Set<String>>{};
    for (final row in rows) {
      final published = row.profile?.trim();
      if (!row.readOnServer || published == null || published.isEmpty) {
        continue;
      }
      read.putIfAbsent(_profile(published), () => {}).addAll(row.identityIds);
    }
    if (read.isEmpty) return Future.value(0);
    return _cancelWhere(
      (entry) =>
          entry.seq <= fence &&
          entry.connId == connId &&
          (read[entry.profile]?.contains(entry.sessionId) ?? false),
    );
  }

  /// The user is looking at [sessionId] on this phone: whatever was posted
  /// for it so far is seen.
  Future<int> clearSession({
    required String connId,
    String? profile,
    required String sessionId,
  }) {
    final fence = _seq;
    final owner = _profile(profile);
    final sid = sessionId.trim();
    if (sid.isEmpty) return Future.value(0);
    return _cancelWhere(
      (entry) =>
          entry.seq <= fence &&
          entry.connId == connId &&
          entry.profile == owner &&
          entry.sessionId == sid,
    );
  }

  Future<int> _cancelWhere(bool Function(_Entry entry) test) async {
    final due = _entries.entries.where((e) => test(e.value)).toList();
    if (due.isEmpty) return 0;
    for (final e in due) {
      _entries.remove(e.key);
    }
    _persist();
    var cancelled = 0;
    for (final e in due) {
      try {
        await cancel(e.value.id, e.value.tag);
        cancelled++;
      } catch (_) {
        // Best effort: the tray keeps it; nothing else depends on this.
      }
    }
    return cancelled;
  }

  void _load() {
    final raw = _prefs?.getString(prefsKey);
    if (raw == null) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _seq = (json['seq'] as num?)?.toInt() ?? 0;
      final list = (json['entries'] as List?) ?? const [];
      for (final item in list) {
        final entry = _Entry.tryParse(item);
        if (entry == null) continue;
        _entries[_address(entry.id, entry.tag)] = entry;
        if (entry.seq > _seq) _seq = entry.seq;
      }
    } catch (_) {
      _entries.clear();
    }
  }

  void _persist() {
    final prefs = _prefs;
    if (prefs == null) return;
    unawaited(
      prefs.setString(
        prefsKey,
        jsonEncode({
          'seq': _seq,
          'entries': [for (final e in _entries.values) e.toJson()],
        }),
      ),
    );
  }
}

class _Entry {
  const _Entry({
    required this.id,
    required this.tag,
    required this.connId,
    required this.profile,
    required this.sessionId,
    required this.seq,
  });

  final int id;
  final String? tag;
  final String connId;
  final String profile;
  final String sessionId;
  final int seq;

  Map<String, Object?> toJson() => {
    'id': id,
    'tag': ?tag,
    'conn': connId,
    'profile': profile,
    'sid': sessionId,
    'seq': seq,
  };

  static _Entry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final seq = raw['seq'];
    final conn = raw['conn'];
    final profile = raw['profile'];
    final sid = raw['sid'];
    final tag = raw['tag'];
    if (id is! int || seq is! int || conn is! String || sid is! String) {
      return null;
    }
    return _Entry(
      id: id,
      tag: tag is String ? tag : null,
      connId: conn,
      profile: profile is String ? profile : 'default',
      sessionId: sid,
      seq: seq,
    );
  }
}
