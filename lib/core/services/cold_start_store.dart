import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../models/session.dart';
import 'app_error_log.dart';
import 'app_lock_sensitive_read_fence.dart';
import 'cache_settings.dart';
import 'cold_start_tail_cipher.dart';
import 'transcript_rehydrate_cost.dart' show decodeJsonOffMain;

/// Storage boundary of [ColdStartStore]. Small entries (the index, the list
/// snapshots, the key of the tail files) go to `flutter_secure_storage`
/// (Android Keystore-backed encryption); the chat tails go to files sealed
/// with that key ([ColdStartTailCipher]).
///
/// The tails are not kept in secure storage: the plugin holds every value
/// of the app in one SharedPreferences file, which Android loads whole into
/// memory as soon as any key is read, so megabytes of tails weighed on the
/// whole process from its first secure read.
abstract interface class ColdStartStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);

  /// Every key in the store, so cleanup can sweep blobs the index lost.
  ///
  /// Expensive in production: `flutter_secure_storage` has no key-only
  /// listing, so this decrypts every entry. Call it only from explicit
  /// cleanup (forget/clear), never from load, save or startup paths.
  Future<Iterable<String>> keys();

  /// The tail file [name], or null when there is none.
  Future<Uint8List?> readFile(String name);

  /// Replaces the tail file [name] whole: a reader finds the old bytes or
  /// the new ones, never part of them.
  Future<void> writeFile(String name, Uint8List bytes);

  Future<void> deleteFile(String name);

  /// The names of the tail files, unfinished writes included. Nothing is
  /// read or decrypted.
  Future<List<String>> fileNames();
}

final class SecureColdStartStorage implements ColdStartStorage {
  SecureColdStartStorage({
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
    Future<Directory> Function()? directory,
  }) : _secure = secureStorage,
       _directory = directory ?? _supportDirectory;

  /// A file being written carries this suffix until it is complete; then it
  /// is renamed over the old one.
  static const partialSuffix = '.part';

  final FlutterSecureStorage _secure;
  final Future<Directory> Function() _directory;

  /// App-private: Android `Context.getFilesDir()`, which neither the cloud
  /// backup nor a device transfer copies (`allowBackup="false"` and the
  /// `file` domain excluded in `data_extraction_rules.xml`).
  static Future<Directory> _supportDirectory() async => Directory(
    '${(await getApplicationSupportDirectory()).path}/cold_start_tails',
  );

  Future<String> _path(String name) async {
    final directory = await _directory();
    await directory.create(recursive: true);
    return '${directory.path}/$name';
  }

  @override
  Future<String?> read(String key) => _secure.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _secure.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _secure.delete(key: key);

  /// `readAll()` is the only listing the plugin offers (it decrypts every
  /// value); see [ColdStartStorage.keys] for where it may be called.
  @override
  Future<Iterable<String>> keys() async => (await _secure.readAll()).keys;

  @override
  Future<Uint8List?> readFile(String name) async {
    final file = File(await _path(name));
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  @override
  Future<void> writeFile(String name, Uint8List bytes) async {
    final path = await _path(name);
    final partial = File('$path$partialSuffix');
    await partial.writeAsBytes(bytes, flush: true);
    await partial.rename(path);
  }

  @override
  Future<void> deleteFile(String name) async {
    final file = File(await _path(name));
    if (await file.exists()) await file.delete();
  }

  @override
  Future<List<String>> fileNames() async {
    final directory = await _directory();
    if (!await directory.exists()) return const [];
    final names = <String>[];
    await for (final entry in directory.list()) {
      if (entry is File) names.add(entry.uri.pathSegments.last);
    }
    return names;
  }
}

/// The key of the tail files is gone (secure storage wiped) or unusable.
final class ColdStartKeyLost implements Exception {
  const ColdStartKeyLost();
}

/// Surface the app was showing when it last went to the background.
enum ColdStartRouteKind {
  /// A normal conversation ([ColdStartRoute.sessionId] is its durable id).
  chat,

  /// A Bot Chat inside Bot Mode (profile + durable id when known).
  bot,

  /// A hosted room inside Bot Mode ([ColdStartRoute.roomId]).
  room,

  /// Bot Mode itself, with nothing opened on top.
  missionControl,
}

/// cs1215: last foreground route of one connection, like Desktop's
/// remembered route. Only identifiers: never a title, preview or content.
@immutable
final class ColdStartRoute {
  const ColdStartRoute({
    required this.kind,
    required this.connectionId,
    required this.profile,
    required this.sessionId,
    this.source = '',
    this.roomId,
    this.savedAtMs = 0,
  });

  final ColdStartRouteKind kind;
  final String connectionId;
  final String profile;
  final String sessionId;

  /// Session source, so a reopened chat keeps its surface (normal/Bot Chat).
  final String source;
  final String? roomId;
  final int savedAtMs;

  Map<String, Object?> toJson() => {
    'k': kind.name,
    'c': connectionId,
    'p': profile,
    's': sessionId,
    if (source.isNotEmpty) 'src': source,
    if (roomId != null) 'r': roomId,
    't': savedAtMs,
  };

  static ColdStartRoute? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = ColdStartRouteKind.values
        .where((value) => value.name == raw['k'])
        .firstOrNull;
    final connectionId = raw['c'];
    final profile = raw['p'];
    final sessionId = raw['s'];
    final source = raw['src'] ?? '';
    final roomId = raw['r'];
    final savedAt = raw['t'];
    if (kind == null ||
        connectionId is! String ||
        connectionId.isEmpty ||
        profile is! String ||
        sessionId is! String ||
        source is! String ||
        (roomId != null && roomId is! String) ||
        savedAt is! int) {
      return null;
    }
    final valid = switch (kind) {
      ColdStartRouteKind.chat => sessionId.isNotEmpty,
      ColdStartRouteKind.bot => profile.isNotEmpty,
      ColdStartRouteKind.room => (roomId as String?)?.isNotEmpty == true,
      ColdStartRouteKind.missionControl => true,
    };
    if (!valid) return null;
    return ColdStartRoute(
      kind: kind,
      connectionId: connectionId,
      profile: Session.profileOwner(profile),
      sessionId: sessionId,
      source: source,
      roomId: roomId as String?,
      savedAtMs: savedAt,
    );
  }

  bool sameTarget(ColdStartRoute other) =>
      kind == other.kind &&
      connectionId == other.connectionId &&
      profile == other.profile &&
      sessionId == other.sessionId &&
      roomId == other.roomId;
}

/// Encrypted, bounded tail of a recently opened chat. A cold open paints it
/// as cached and reconciles with the server; it is never authoritative.
@immutable
final class ColdStartTail {
  const ColdStartTail({
    required this.connectionId,
    required this.profile,
    required this.storedSessionId,
    required this.routeSessionId,
    required this.aliases,
    required this.newestFirst,
    required this.savedAtMs,
  });

  final String connectionId;
  final String profile;
  final String storedSessionId;

  /// Id the chat route was opened with (registry key of the live chat).
  final String routeSessionId;
  final Set<String> aliases;
  final List<Map<String, dynamic>> newestFirst;
  final int savedAtMs;
}

/// cs1215: cold-start continuity, persisted encrypted per connection and
/// profile. Desktop keeps the remembered route and warm transcript tails on
/// disk (`session-states.ts`, `session-state-cache.ts`); Console kept the tails
/// only in memory, so every relaunch landed on Home and reloaded from the
/// network. Bounds: [maxTails] chats × [maxRows] newest rows, at most
/// [maxEntryBytes] each and [maxTotalBytes] together, [maxAge] old.
class ColdStartStore {
  ColdStartStore({
    ColdStartStorage? storage,
    int Function()? nowMs,
    this.settings,
  }) : _storage = storage ?? SecureColdStartStorage(),
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Chats whose tail survives a relaunch by default (the user picks 10, 20,
  /// 50 or 100 in Settings → Cache). Raised from 8 so that a chat opened days
  /// ago still opens on its rows, not on a skeleton.
  static const int maxTails = 20;
  static const int maxRows = 120;
  static const int maxEntryBytes = 1024 * 1024;
  static const int maxTotalBytes = 16 * 1024 * 1024;
  static const Duration maxAge = Duration(days: 30);

  static const indexKey = 'cold_start_index_v1';

  /// Secure-storage entry holding the key of the tail files.
  static const fileKeyKey = 'cold_start_file_key_v1';
  static const Duration _routeRenewal = Duration(hours: 1);
  static const _tailPrefix = 'cold_start_tail_v1.';
  static const _recentsPrefix = 'cold_start_recents_v1.';
  static const _listPrefix = 'cold_start_list_v1.';

  /// Rows kept per Home recents snapshot.
  static const int maxRecentRows = 24;

  /// Encoded bytes of one recents row; a longer row (a huge preview or
  /// lineage) is left out of the snapshot.
  static const int maxRecentRowBytes = 4 * 1024;

  /// Encoded bytes of one recents snapshot; the newest rows that fit are
  /// kept. Secure Storage loads every snapshot at launch.
  static const int maxRecentsBytes = 64 * 1024;

  /// The Chats list's own snapshot (what Conversaciones paints before the
  /// server answers): more rows than Home's, same row and encryption rules.
  static const int maxListRows = 100;
  static const int maxListBytes = 256 * 1024;

  final ColdStartStorage _storage;
  final int Function() _nowMs;

  _ColdStartIndex? _index;
  Future<void> _queue = Future<void>.value();

  /// The index was read and understood (or there was none): a tail file it
  /// does not name can never be reached.
  bool _indexTrusted = false;

  ColdStartTailCipher? _cipher;
  bool _filesSwept = false;

  /// Last persisted encoding per tail key: an unchanged tail is not rewritten.
  final Map<String, String> _written = {};

  /// What the user chose to keep (Settings → Data → Cache); null keeps the
  /// defaults (everything on, [maxTails] chats).
  final CacheSettings? settings;

  /// Chats whose messages are kept now.
  int get tailLimit => settings?.maxChats ?? maxTails;

  bool get _messagesOn => settings?.messages ?? true;
  bool get _listOn => settings?.chatList ?? true;

  static const _recentsKind = _SnapshotKind(
    _recentsPrefix,
    maxRecentRows,
    maxRecentsBytes,
  );
  static const _listKind = _SnapshotKind(
    _listPrefix,
    maxListRows,
    maxListBytes,
  );

  static String _hex(String value) => value.codeUnits
      .map((unit) => unit.toRadixString(16).padLeft(4, '0'))
      .join();

  static String tailKey(
    String connectionId,
    String profile,
    String storedSessionId,
  ) =>
      '$_tailPrefix${_hex(connectionId)}.${_hex(Session.profileOwner(profile))}'
      '.${_hex(storedSessionId)}';

  static String recentsKey(String connectionId, String profile) =>
      '$_recentsPrefix${_hex(connectionId)}.'
      '${_hex(Session.profileOwner(profile))}';

  static String listKey(String connectionId, String profile) =>
      '$_listPrefix${_hex(connectionId)}.'
      '${_hex(Session.profileOwner(profile))}';

  Future<T> _serial<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _queue = _queue.catchError((_) {}).then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<_ColdStartIndex> _loadIndex() async {
    final cached = _index;
    if (cached != null) return cached;
    _ColdStartIndex index;
    try {
      index = _ColdStartIndex.decode(await _storage.read(indexKey));
      _indexTrusted = true;
    } catch (error) {
      // An unreadable index never blocks startup; it is rebuilt on write.
      debugPrint('[cold-start] index unavailable (${error.runtimeType})');
      SecureStorageDiagnostics.record(
        SecureStorageOperation.coldStartIndex,
        error,
      );
      index = _ColdStartIndex.empty();
    }
    _index = index;
    await _retireSecureTails(index);
    return index;
  }

  /// Tails an older version kept in secure storage are deleted by the names
  /// its index lists, never by listing the store; their chats refill from
  /// the server when opened. Until the index is saved without them, the
  /// stored index still lists them, so a process death at any point leaves
  /// the next launch to finish (deleting twice is harmless).
  Future<void> _retireSecureTails(_ColdStartIndex index) async {
    if (index.secureTails.isEmpty) return;
    try {
      for (final key in index.secureTails.toList()) {
        await _storage.delete(key);
        index.secureTails.remove(key);
      }
    } catch (error) {
      SecureStorageDiagnostics.record(
        SecureStorageOperation.coldStartTail,
        error,
      );
    }
    try {
      await _saveIndex(index);
    } catch (error) {
      SecureStorageDiagnostics.record(
        SecureStorageOperation.coldStartIndex,
        error,
      );
    }
  }

  Future<void> _saveIndex(_ColdStartIndex index) =>
      _storage.write(indexKey, index.encode());

  /// Names the list snapshot [key] in the index, before it is written: the
  /// index may name a snapshot that is not there, never miss one that is.
  Future<void> _nameSnapshot(String key) async {
    final index = await _loadIndex();
    if (index.snapshots.add(key)) await _saveIndex(index);
  }

  Future<void> _unnameSnapshot(String key) async {
    final index = await _loadIndex();
    if (index.snapshots.remove(key)) await _saveIndex(index);
  }

  // ── Remembered route ────────────────────────────────────────────────────

  Future<void> rememberRoute(ColdStartRoute route) => _serial(() async {
    final index = await _loadIndex();
    final stamped = ColdStartRoute(
      kind: route.kind,
      connectionId: route.connectionId,
      profile: Session.profileOwner(route.profile),
      sessionId: route.sessionId,
      source: route.source,
      roomId: route.roomId,
      savedAtMs: _nowMs(),
    );
    final previous = index.routes[route.connectionId];
    // Staying on the same surface keeps it alive: its age is renewed, at most
    // once per [_routeRenewal] so a visibility tick never rewrites the index.
    if (previous != null &&
        previous.sameTarget(stamped) &&
        stamped.savedAtMs - previous.savedAtMs < _routeRenewal.inMilliseconds) {
      return;
    }
    index.routes[route.connectionId] = stamped;
    await _saveIndex(index);
  });

  /// Forgets the remembered route of [connectionId] (back to Home/library),
  /// only while [when] still accepts it.
  Future<void> forgetRoute(
    String connectionId, {
    bool Function(ColdStartRoute route)? when,
  }) => _serial(() async {
    final index = await _loadIndex();
    final current = index.routes[connectionId];
    if (current == null) return;
    if (when != null && !when(current)) return;
    index.routes.remove(connectionId);
    await _saveIndex(index);
  });

  Future<ColdStartRoute?> routeFor(String connectionId) => _serial(() async {
    final route = (await _loadIndex()).routes[connectionId];
    if (route == null) return null;
    if (_nowMs() - route.savedAtMs > maxAge.inMilliseconds) return null;
    return route;
  });

  // ── Home recents ────────────────────────────────────────────────────────

  /// Persists the recents Home last painted for one connection and profile,
  /// so the next cold start paints them before any network read lands.
  /// Session list fields only (ids, title, preview, timestamps), never a
  /// transcript. An empty list forgets the scope's snapshot.
  Future<void> saveRecents({
    required String connectionId,
    required String profile,
    required List<Session> sessions,
  }) => _saveSnapshot(_recentsKind, connectionId, profile, sessions);

  /// The recents of this scope this process already read or wrote, decoded
  /// synchronously from memory (no storage access), or null. Lets Home's
  /// first frame paint them when bootstrap decrypted them before runApp.
  List<Session>? peekRecents({
    required String connectionId,
    required String profile,
  }) => _peekSnapshot(_recentsKind, connectionId, profile);

  /// The recents saved by [saveRecents] for this scope, or null.
  Future<List<Session>?> loadRecents({
    required String connectionId,
    required String profile,
  }) => _loadSnapshot(_recentsKind, connectionId, profile);

  /// Persists the Chats list (default view) of one connection and profile,
  /// the way [saveRecents] does Home's: list fields only, never a transcript.
  Future<void> saveList({
    required String connectionId,
    required String profile,
    required List<Session> sessions,
  }) => _saveSnapshot(_listKind, connectionId, profile, sessions);

  /// [peekRecents] for the Chats list.
  List<Session>? peekList({
    required String connectionId,
    required String profile,
  }) => _peekSnapshot(_listKind, connectionId, profile);

  /// [loadRecents] for the Chats list.
  Future<List<Session>?> loadList({
    required String connectionId,
    required String profile,
  }) => _loadSnapshot(_listKind, connectionId, profile);

  Future<void> _saveSnapshot(
    _SnapshotKind kind,
    String connectionId,
    String profile,
    List<Session> sessions,
  ) => _serial(() async {
    if (!_listOn) return;
    final owner = Session.profileOwner(profile);
    final key = kind.key(connectionId, owner);
    final rows = _boundedRecentRows(sessions, connectionId, owner, kind);
    if (rows.isEmpty) {
      _written.remove(key);
      await _storage.delete(key);
      await _unnameSnapshot(key);
      return;
    }
    final payload = _recentsPayload(connectionId, owner, rows);
    if (_written[key] == payload) return;
    _written.remove(key);
    await _nameSnapshot(key);
    await _storage.write(key, payload);
    _written[key] = payload;
  });

  List<Session>? _peekSnapshot(
    _SnapshotKind kind,
    String connectionId,
    String profile,
  ) {
    if (!_listOn) return null;
    final owner = Session.profileOwner(profile);
    final raw = _written[kind.key(connectionId, owner)];
    if (raw == null || _oversized(raw, kind)) return null;
    return _decodeRecents(raw, connectionId, owner, kind);
  }

  Future<List<Session>?> _loadSnapshot(
    _SnapshotKind kind,
    String connectionId,
    String profile,
  ) => _serial(() async {
    if (!_listOn) return null;
    final owner = Session.profileOwner(profile);
    final key = kind.key(connectionId, owner);
    final raw = await _storage.read(key);
    if (raw == null) return null;
    final rows = _oversized(raw, kind)
        ? null
        : _decodeRecents(raw, connectionId, owner, kind);
    if (rows == null) {
      _written.remove(key);
      await _storage.delete(key);
      await _unnameSnapshot(key);
      return null;
    }
    // A snapshot an older version stored is named when first read.
    await _nameSnapshot(key);
    _written[key] = raw;
    return rows;
  });

  /// The encoded rows of [sessions] a snapshot keeps: at most
  /// [maxRecentRows], each within [maxRecentRowBytes], all together within
  /// [maxRecentsBytes] (newest first; the first row past it ends the list).
  static List<String> _boundedRecentRows(
    Iterable<Session> sessions,
    String connectionId,
    String owner, [
    _SnapshotKind kind = _recentsKind,
  ]) {
    final rows = <String>[];
    // The envelope, then each row and the comma before it (none first).
    var bytes = utf8.encode(_recentsPayload(connectionId, owner, [])).length;
    for (final session in sessions) {
      if (rows.length >= kind.maxRows) break;
      if (session.id.isEmpty) continue;
      final String encoded;
      try {
        encoded = jsonEncode(_recentRow(session));
      } catch (_) {
        continue;
      }
      final rowBytes = utf8.encode(encoded).length;
      if (rowBytes > maxRecentRowBytes) continue;
      final cost = rowBytes + (rows.isEmpty ? 0 : 1);
      if (bytes + cost > kind.maxBytes) break;
      bytes += cost;
      rows.add(encoded);
    }
    return rows;
  }

  /// A stored snapshot no [saveRecents] could have written.
  static bool _oversized(String raw, [_SnapshotKind kind = _recentsKind]) =>
      raw.length > kind.maxBytes || utf8.encode(raw).length > kind.maxBytes;

  static String _recentsPayload(
    String connectionId,
    String owner,
    List<String> rows,
  ) =>
      '{"v":1,"c":${jsonEncode(connectionId)},"p":${jsonEncode(owner)},'
      '"rows":[${rows.join(',')}]}';

  static Map<String, Object?> _recentRow(Session s) => {
    'id': s.id,
    'title': s.title,
    'model': s.model,
    'source': s.source,
    'message_count': s.messageCount,
    'is_active': s.isActive,
    'preview': s.preview,
    'started_at': s.startedAt,
    'ended_at': ?s.endedAt,
    'last_active': ?s.updatedAt,
    'parent_session_id': ?s.parentSessionId,
    '_lineage_root_id': ?s.lineageRootId,
    if (s.lineageIds.isNotEmpty) '_lineage_ids': s.lineageIds,
    'is_internal_child': ?s.isInternalChild,
    'archived': s.archived,
    'pinned': ?s.pinned,
    'hidden': ?s.hidden,
    'unread': ?s.unread,
    'profile': ?s.profile,
  };

  static List<Session>? _decodeRecents(
    String raw,
    String connectionId,
    String owner, [
    _SnapshotKind kind = _recentsKind,
  ]) {
    try {
      final data = jsonDecode(raw);
      if (data is! Map || data['v'] != 1) return null;
      if (data['c'] != connectionId || data['p'] != owner) return null;
      final rows = data['rows'];
      if (rows is! List) return null;
      return [
        for (final row in rows.take(kind.maxRows)) ?Session.tryParse(row),
      ];
    } catch (_) {
      return null;
    }
  }

  /// Drops the rows naming any of [ids] from every recents snapshot of
  /// [connectionId] among [keys] (one profile when [owner] is set).
  Future<void> _forgetRecentsSession(
    Iterable<String> keys, {
    required String connectionId,
    String? owner,
    required Set<String> ids,
  }) async {
    for (final key in keys) {
      if (!_inRecentsScope(key, connectionId, owner)) continue;
      final raw = await _storage.read(key);
      if (raw == null) continue;
      final kind = key.startsWith(_listPrefix) ? _listKind : _recentsKind;
      Object? keyOwner;
      if (!_oversized(raw, kind)) {
        try {
          final data = jsonDecode(raw);
          keyOwner = data is Map ? data['p'] : null;
        } catch (_) {}
      }
      final rows = keyOwner is String
          ? _decodeRecents(raw, connectionId, keyOwner, kind)
          : null;
      if (keyOwner is! String || rows == null) {
        _written.remove(key);
        await _storage.delete(key);
        await _unnameSnapshot(key);
        continue;
      }
      final kept = [
        for (final row in rows)
          if (!row.identityIds.any(ids.contains) && !ids.contains(row.id)) row,
      ];
      if (kept.length == rows.length) continue;
      _written.remove(key);
      final keptRows = _boundedRecentRows(kept, connectionId, keyOwner, kind);
      if (keptRows.isEmpty) {
        await _storage.delete(key);
        await _unnameSnapshot(key);
      } else {
        final payload = _recentsPayload(connectionId, keyOwner, keptRows);
        await _nameSnapshot(key);
        await _storage.write(key, payload);
        _written[key] = payload;
      }
    }
  }

  /// A recents key of [connectionId] (every connection when null), of one
  /// profile when [owner] is set.
  /// The Chats list snapshots ([listKey]) follow the same scopes.
  static bool _inRecentsScope(String key, String? connectionId, String? owner) {
    if (connectionId == null) {
      return key.startsWith(_recentsPrefix) || key.startsWith(_listPrefix);
    }
    if (owner != null) {
      return key == recentsKey(connectionId, owner) ||
          key == listKey(connectionId, owner);
    }
    return key.startsWith('$_recentsPrefix${_hex(connectionId)}.') ||
        key.startsWith('$_listPrefix${_hex(connectionId)}.');
  }

  // ── Transcript tails ────────────────────────────────────────────────────

  /// The cipher of the tail files, or null when there is no key and
  /// [create] is false. Without a usable key no file opens again: the files
  /// are deleted, the index forgets them and the cache starts empty.
  Future<ColdStartTailCipher?> _tailCipher(
    _ColdStartIndex index, {
    bool create = false,
  }) async {
    final cached = _cipher;
    if (cached != null) return cached;
    Object? lost;
    Uint8List? key;
    try {
      final raw = await _storage.read(fileKeyKey);
      if (raw != null) {
        key = _decodeFileKey(raw);
        if (key == null) lost = const ColdStartKeyLost();
      }
    } catch (error) {
      lost = error;
    }
    if (key == null) {
      if (index.tails.isNotEmpty) lost ??= const ColdStartKeyLost();
      if (lost != null) {
        debugPrint('[cold-start] file key unavailable (${lost.runtimeType})');
        SecureStorageDiagnostics.record(
          SecureStorageOperation.coldStartKey,
          lost,
        );
        for (final name in await _storage.fileNames()) {
          await _storage.deleteFile(name);
        }
        if (index.tails.isNotEmpty) {
          index.tails.keys.forEach(_written.remove);
          index.tails.clear();
          await _saveIndex(index);
        }
      }
      if (!create) return null;
      key = ColdStartTailCipher.newKey();
      await _storage.write(fileKeyKey, base64Encode(key));
    }
    return _cipher = ColdStartTailCipher(key);
  }

  static Uint8List? _decodeFileKey(String raw) {
    try {
      final key = base64Decode(raw);
      return key.length == ColdStartTailCipher.keyBytes ? key : null;
    } on FormatException {
      return null;
    }
  }

  static String _fileOf(ColdStartTailCipher cipher, String key, _TailMeta m) =>
      cipher.fileName(m.connectionId, m.profile, key);

  /// Persists the newest [maxRows] rows of a chat. Rows are encoded one by
  /// one and the tail stops at the first row JSON cannot carry, so a gap is
  /// never stored as if it were contiguous.
  Future<void> saveTail({
    required String connectionId,
    required String profile,
    required String storedSessionId,
    required String routeSessionId,
    required Set<String> aliases,
    required List<Map<String, dynamic>> newestFirst,
  }) => _serial(() async {
    if (!_messagesOn) return;
    final owner = Session.profileOwner(profile);
    final key = tailKey(connectionId, owner, storedSessionId);
    final encodedRows = <String>[];
    var bytes = 0;
    for (final row in newestFirst.take(maxRows)) {
      final String encoded;
      try {
        encoded = jsonEncode(row);
      } catch (_) {
        break;
      }
      final rowBytes = utf8.encode(encoded).length + 1;
      if (bytes + rowBytes > maxEntryBytes) break;
      bytes += rowBytes;
      encodedRows.add(encoded);
    }
    final index = await _loadIndex();
    if (encodedRows.isEmpty) {
      await _deleteTails(index, {key});
      return;
    }
    final payload =
        '{"v":1,"c":${jsonEncode(connectionId)},"p":${jsonEncode(owner)},'
        '"s":${jsonEncode(storedSessionId)},"r":${jsonEncode(routeSessionId)},'
        '"a":${jsonEncode(aliases.where((a) => a.isNotEmpty).toList()..sort())},'
        '"rows":[${encodedRows.join(',')}]}';
    final content = utf8.encode(payload);
    final cipher = (await _tailCipher(index, create: true))!;
    final unchanged = _written[key] == payload && index.tails.containsKey(key);
    index.tails.remove(key);
    index.tails[key] = _TailMeta(
      connectionId: connectionId,
      profile: owner,
      storedSessionId: storedSessionId,
      aliases: {
        ...aliases.where((a) => a.isNotEmpty),
        storedSessionId,
        routeSessionId,
      },
      // What the file takes on disk.
      bytes: content.length + ColdStartTailCipher.overhead,
      savedAtMs: _nowMs(),
    );
    final evicted = <String, _TailMeta>{};
    while (index.tails.length > tailLimit || index.totalBytes > maxTotalBytes) {
      final oldest = index.tails.keys.first;
      if (oldest == key && index.tails.length == 1) break;
      evicted[oldest] = index.tails.remove(oldest)!;
    }
    // Crash-safe order: evicted files go first (an index entry without its
    // file is dropped on load), then the index records the intent, and only
    // then is the tail written. A process death between any two writes never
    // leaves a file that the index cannot reach.
    for (final MapEntry(key: stale, value: meta) in evicted.entries) {
      _written.remove(stale);
      await _storage.deleteFile(_fileOf(cipher, stale, meta));
    }
    await _saveIndex(index);
    if (!unchanged) {
      _written.remove(key);
      final name = cipher.fileName(connectionId, owner, key);
      await _storage.writeFile(name, await cipher.seal(name, content));
      _written[key] = payload;
    }
  });

  /// Newest-first list of persisted tails (most recently saved first).
  /// [where] filters on identity before anything is read or decrypted.
  ///
  /// App Lock: nothing is read while it is closed, and a read it revokes
  /// reads nothing more ([SensitiveReadUnavailable]), like the drafts.
  Future<List<ColdStartTail>> loadTails({
    int? limit,
    bool Function(String connectionId, String profile, Set<String> aliases)?
    where,
  }) => _serial(() async {
    if (!_messagesOn) return const <ColdStartTail>[];
    final ticket = AppLockSensitiveReadFence.current;
    ticket.ensureCurrent();
    final index = await _loadIndex();
    ticket.ensureCurrent();
    final cipher = await _tailCipher(index);
    ticket.ensureCurrent();
    if (cipher == null) return const <ColdStartTail>[];
    if (!_filesSwept && _indexTrusted) {
      // Once per process: unfinished writes and files no index names.
      _filesSwept = true;
      await _sweepTailFiles(index, cipher);
    }
    final now = _nowMs();
    final out = <ColdStartTail>[];
    final drop = <String>{};
    for (final entry in index.tails.entries.toList().reversed) {
      if (limit != null && out.length >= limit) break;
      final meta = entry.value;
      if (where != null &&
          !where(meta.connectionId, meta.profile, meta.aliases)) {
        continue;
      }
      if (now - meta.savedAtMs > maxAge.inMilliseconds) {
        drop.add(entry.key);
        continue;
      }
      try {
        final name = _fileOf(cipher, entry.key, meta);
        final sealed = await _storage.readFile(name);
        ticket.ensureCurrent();
        // A file that does not open (altered, truncated, another key) is a
        // miss: it is deleted with its entry, and the server refills it.
        final content = sealed == null ? null : await cipher.open(name, sealed);
        ticket.ensureCurrent();
        final raw = content == null ? null : utf8.decode(content);
        // Up to 1 MB per tail, read while the app starts: a large one is
        // decoded off the main isolate so the first frames keep their
        // input.
        final tail = raw == null
            ? null
            : _tailFrom(await decodeJsonOffMain(raw), meta);
        if (tail == null) {
          drop.add(entry.key);
          continue;
        }
        _written[entry.key] = raw!;
        out.add(tail);
      } on SensitiveReadUnavailable {
        rethrow;
      } catch (error) {
        debugPrint('[cold-start] tail unavailable (${error.runtimeType})');
        SecureStorageDiagnostics.record(
          SecureStorageOperation.coldStartTail,
          error,
        );
      }
    }
    if (drop.isNotEmpty) await _deleteTails(index, drop);
    return out;
  });

  ColdStartTail? _tailFrom(Object? data, _TailMeta meta) {
    if (data is! Map || data['v'] != 1) return null;
    if (data['c'] != meta.connectionId ||
        data['p'] != meta.profile ||
        data['s'] != meta.storedSessionId) {
      return null;
    }
    final routeSessionId = data['r'];
    final rows = data['rows'];
    if (routeSessionId is! String || routeSessionId.isEmpty) return null;
    if (rows is! List || rows.isEmpty) return null;
    final newestFirst = <Map<String, dynamic>>[
      for (final row in rows)
        if (row is Map) Map<String, dynamic>.from(row),
    ];
    if (newestFirst.length != rows.length) return null;
    return ColdStartTail(
      connectionId: meta.connectionId,
      profile: meta.profile,
      storedSessionId: meta.storedSessionId,
      routeSessionId: routeSessionId,
      aliases: {
        ...meta.aliases,
        for (final alias in (data['a'] as List? ?? const []))
          if (alias is String && alias.isNotEmpty) alias,
      },
      newestFirst: List<Map<String, dynamic>>.unmodifiable(newestFirst),
      savedAtMs: meta.savedAtMs,
    );
  }

  Future<void> _deleteTails(_ColdStartIndex index, Set<String> keys) async {
    final stored = {for (final key in keys) key: ?index.tails[key]};
    if (stored.isNotEmpty) {
      // No key: the files went with it (see [_tailCipher]).
      final cipher = await _tailCipher(index);
      for (final MapEntry(:key, value: meta) in stored.entries) {
        _written.remove(key);
        if (cipher != null) {
          await _storage.deleteFile(_fileOf(cipher, key, meta));
        }
      }
    }
    var changed = false;
    for (final key in keys) {
      _written.remove(key);
      changed = index.tails.remove(key) != null || changed;
    }
    if (changed) await _saveIndex(index);
  }

  /// Deletes the tail files of the scope (every scope when [connectionId]
  /// is null) that the index does not name: unfinished writes, and files
  /// whose entry a corrupt index or an older crash lost. File names start
  /// with keyed hashes of connection and profile, so the scope is known
  /// without the index: forgetting one connection never deletes another
  /// connection's files.
  Future<void> _sweepTailFiles(
    _ColdStartIndex index,
    ColdStartTailCipher cipher, {
    String? connectionId,
    String? owner,
  }) async {
    final scope = connectionId == null
        ? ''
        : owner == null
        ? cipher.connectionPrefix(connectionId)
        : cipher.profilePrefix(connectionId, owner);
    final named = {
      for (final entry in index.tails.entries)
        _fileOf(cipher, entry.key, entry.value),
    };
    for (final name in await _storage.fileNames()) {
      if (!name.startsWith(scope) || named.contains(name)) continue;
      await _storage.deleteFile(name);
    }
  }

  /// Deletes what the index cannot reach in the cleaned scope and must not
  /// outlive a cleanup: tail files it does not name, and tails an older
  /// version kept in secure storage (all of them: none lives there now).
  /// The scope of those comes from the key itself ([tailKey] encodes
  /// connection and profile), never from the index. A null [connectionId]
  /// sweeps every scope.
  ///
  /// Returns the listing it swept, so a caller can clean other blobs of the
  /// scope without decrypting the whole store a second time.
  Future<List<String>> _sweepUnindexed(
    _ColdStartIndex index, {
    String? connectionId,
    String? owner,
  }) async {
    final cipher = await _tailCipher(index);
    if (cipher != null) {
      await _sweepTailFiles(
        index,
        cipher,
        connectionId: connectionId,
        owner: owner,
      );
    }
    final scope = connectionId == null
        ? _tailPrefix
        : '$_tailPrefix${_hex(connectionId)}.'
              '${owner == null ? '' : '${_hex(owner)}.'}';
    final keys = (await _storage.keys()).toList();
    for (final key in keys) {
      if (!key.startsWith(scope)) continue;
      index.secureTails.remove(key);
      await _storage.delete(key);
    }
    return keys;
  }

  /// Deletes every Home recents snapshot of the scope among [keys].
  Future<void> _deleteRecents(
    Iterable<String> keys, {
    String? connectionId,
    String? owner,
  }) async {
    for (final key in keys) {
      if (!_inRecentsScope(key, connectionId, owner)) continue;
      _written.remove(key);
      await _storage.delete(key);
      await _unnameSnapshot(key);
    }
  }

  /// A confirmed remote deletion: drops the tail and a route naming it.
  Future<void> forgetSession({
    required String connectionId,
    String? profile,
    required String sessionId,
  }) => _serial(() async {
    final index = await _loadIndex();
    final owner = profile == null ? null : Session.profileOwner(profile);
    final keys = {
      for (final entry in index.tails.entries)
        if (entry.value.connectionId == connectionId &&
            (owner == null || entry.value.profile == owner) &&
            entry.value.aliases.contains(sessionId))
          entry.key,
    };
    final ids = {
      sessionId,
      for (final key in keys) ...index.tails[key]!.aliases,
    };
    final route = index.routes[connectionId];
    final routeGone =
        route != null &&
        ids.contains(route.sessionId) &&
        (owner == null || route.profile == owner);
    if (routeGone) index.routes.remove(connectionId);
    await _deleteTails(index, keys);
    if (routeGone && keys.isEmpty) await _saveIndex(index);
    final listed = await _sweepUnindexed(
      index,
      connectionId: connectionId,
      owner: owner,
    );
    await _forgetRecentsSession(
      listed,
      connectionId: connectionId,
      owner: owner,
      ids: ids,
    );
  });

  /// Connection deleted, a profile's local history cleared, or credentials
  /// wiped: nothing of that scope may survive on disk.
  Future<void> forgetScope(String connectionId, {String? profile}) =>
      _serial(() async {
        final index = await _loadIndex();
        final owner = profile == null ? null : Session.profileOwner(profile);
        final keys = {
          for (final entry in index.tails.entries)
            if (entry.value.connectionId == connectionId &&
                (owner == null || entry.value.profile == owner))
              entry.key,
        };
        final route = index.routes[connectionId];
        final routeGone =
            route != null && (owner == null || route.profile == owner);
        if (routeGone) index.routes.remove(connectionId);
        await _deleteTails(index, keys);
        if (routeGone && keys.isEmpty) await _saveIndex(index);
        final listed = await _sweepUnindexed(
          index,
          connectionId: connectionId,
          owner: owner,
        );
        await _deleteRecents(listed, connectionId: connectionId, owner: owner);
      });

  /// Settings → Cache: deletes every kept chat message tail (the remembered
  /// route stays: it is where the app reopens, not a copy of a chat), and
  /// the key of their files: the next tail gets a new one.
  Future<void> clearMessages() => _serial(() async {
    final index = await _loadIndex();
    await _deleteTails(index, index.tails.keys.toSet());
    await _sweepUnindexed(index);
    await _forgetFileKey();
  });

  Future<void> _forgetFileKey() async {
    _cipher = null;
    await _storage.delete(fileKeyKey);
  }

  /// Settings → Cache: deletes every kept Chats list and Home recents.
  Future<void> clearLists() => _serial(() async {
    await _deleteRecents(await _storage.keys());
  });

  /// Settings → Cache: bytes this device holds for the three caches.
  ///
  /// The lists are read by the names the index keeps: listing the keys
  /// would decrypt every secret of the app just to open the screen. A list
  /// an older version stored counts once it has been read again (Home and
  /// Chats read theirs at launch). The tails count the size of their files.
  Future<int> usedBytes() => _serial(() async {
    final index = await _loadIndex();
    var total = index.totalBytes;
    for (final key in index.snapshots.toList()) {
      total += utf8.encode(await _storage.read(key) ?? '').length;
    }
    return total;
  });

  /// Removes everything this store ever wrote.
  Future<void> clearAll() => _serial(() async {
    final index = await _loadIndex();
    // With no tail named, the sweep deletes every file.
    index.tails.clear();
    index.routes.clear();
    index.snapshots.clear();
    await _deleteRecents(await _sweepUnindexed(index));
    _written.clear();
    await _forgetFileKey();
    await _storage.delete(indexKey);
  });
}

final class _TailMeta {
  _TailMeta({
    required this.connectionId,
    required this.profile,
    required this.storedSessionId,
    required this.aliases,
    required this.bytes,
    required this.savedAtMs,
  });

  final String connectionId;
  final String profile;
  final String storedSessionId;
  final Set<String> aliases;
  final int bytes;
  final int savedAtMs;

  Map<String, Object?> toJson() => {
    'c': connectionId,
    'p': profile,
    's': storedSessionId,
    'a': aliases.toList()..sort(),
    'b': bytes,
    't': savedAtMs,
  };

  static _TailMeta? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final c = raw['c'], p = raw['p'], s = raw['s'], b = raw['b'];
    final t = raw['t'], a = raw['a'];
    if (c is! String ||
        p is! String ||
        s is! String ||
        b is! int ||
        t is! int ||
        a is! List) {
      return null;
    }
    return _TailMeta(
      connectionId: c,
      profile: p,
      storedSessionId: s,
      aliases: {
        for (final alias in a)
          if (alias is String) alias,
      },
      bytes: b,
      savedAtMs: t,
    );
  }
}

final class _ColdStartIndex {
  _ColdStartIndex(this.routes, this.tails, this.snapshots, this.secureTails);

  _ColdStartIndex.empty()
    : routes = {},
      tails = {},
      snapshots = {},
      secureTails = {};

  /// Per connection id.
  final Map<String, ColdStartRoute> routes;

  /// Least recently saved first. Each one is a file.
  final Map<String, _TailMeta> tails;

  /// Keys of the Home recents and Chats list snapshots.
  final Set<String> snapshots;

  /// Tails an older version kept in secure storage, still to delete.
  final Set<String> secureTails;

  int get totalBytes =>
      tails.values.fold<int>(0, (sum, meta) => sum + meta.bytes);

  static _ColdStartIndex decode(String? raw) {
    if (raw == null || raw.isEmpty) return _ColdStartIndex.empty();
    final data = jsonDecode(raw);
    if (data is! Map || data['v'] != 1) return _ColdStartIndex.empty();
    final routes = <String, ColdStartRoute>{};
    final rawRoutes = data['routes'];
    if (rawRoutes is Map) {
      for (final entry in rawRoutes.entries) {
        final route = ColdStartRoute.fromJson(entry.value);
        if (route != null && route.connectionId == entry.key) {
          routes[route.connectionId] = route;
        }
      }
    }
    final tails = <String, _TailMeta>{};
    final rawTails = data['tails'];
    if (rawTails is List) {
      for (final item in rawTails) {
        if (item is! Map) continue;
        final key = item['k'];
        final meta = _TailMeta.fromJson(item);
        if (key is! String || meta == null) continue;
        if (key !=
            ColdStartStore.tailKey(
              meta.connectionId,
              meta.profile,
              meta.storedSessionId,
            )) {
          continue;
        }
        tails[key] = meta;
      }
    }
    final rawSnapshots = data['lists'];
    final snapshots = <String>{
      if (rawSnapshots is List)
        for (final key in rawSnapshots)
          if (key is String && ColdStartStore._inRecentsScope(key, null, null))
            key,
    };
    final rawSecureTails = data['st'];
    final secureTails = <String>{
      if (rawSecureTails is List)
        for (final key in rawSecureTails)
          if (key is String && key.startsWith(ColdStartStore._tailPrefix)) key,
    };
    // Written before tails were files: every tail it lists is a secure
    // entry, to delete by that name.
    if (data['tf'] != 1) {
      secureTails.addAll(tails.keys);
      tails.clear();
    }
    return _ColdStartIndex(routes, tails, snapshots, secureTails);
  }

  String encode() => jsonEncode({
    'v': 1,
    'tf': 1,
    'routes': {
      for (final entry in routes.entries) entry.key: entry.value.toJson(),
    },
    'tails': [
      for (final entry in tails.entries)
        {'k': entry.key, ...entry.value.toJson()},
    ],
    if (snapshots.isNotEmpty) 'lists': snapshots.toList(),
    if (secureTails.isNotEmpty) 'st': secureTails.toList(),
  });
}

/// A session-list snapshot family: where it lives and how much it may keep.
final class _SnapshotKind {
  const _SnapshotKind(this.prefix, this.maxRows, this.maxBytes);

  final String prefix;
  final int maxRows;
  final int maxBytes;

  String key(String connectionId, String owner) =>
      '$prefix${ColdStartStore._hex(connectionId)}.'
      '${ColdStartStore._hex(Session.profileOwner(owner))}';
}
