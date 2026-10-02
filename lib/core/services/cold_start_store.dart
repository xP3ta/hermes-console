import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/session.dart';

/// Key/value boundary of [ColdStartStore]. Production writes through
/// `flutter_secure_storage` (Android Keystore-backed encryption), the same
/// storage that already holds drafts, the outbox and local transcripts.
abstract interface class ColdStartStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

final class SecureColdStartStorage implements ColdStartStorage {
  const SecureColdStartStorage({
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
  }) : _secure = secureStorage;

  final FlutterSecureStorage _secure;

  @override
  Future<String?> read(String key) => _secure.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _secure.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _secure.delete(key: key);
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
  ColdStartStore({ColdStartStorage? storage, int Function()? nowMs})
    : _storage = storage ?? const SecureColdStartStorage(),
      _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  static const int maxTails = 8;
  static const int maxRows = 120;
  static const int maxEntryBytes = 1024 * 1024;
  static const int maxTotalBytes = 4 * 1024 * 1024;
  static const Duration maxAge = Duration(days: 30);

  static const indexKey = 'cold_start_index_v1';
  static const _tailPrefix = 'cold_start_tail_v1.';

  final ColdStartStorage _storage;
  final int Function() _nowMs;

  _ColdStartIndex? _index;
  Future<void> _queue = Future<void>.value();

  /// Last persisted encoding per tail key: an unchanged tail is not rewritten.
  final Map<String, String> _written = {};

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
    } catch (error) {
      // An unreadable index never blocks startup; it is rebuilt on write.
      debugPrint('[cold-start] index unavailable (${error.runtimeType})');
      index = _ColdStartIndex.empty();
    }
    _index = index;
    return index;
  }

  Future<void> _saveIndex(_ColdStartIndex index) =>
      _storage.write(indexKey, index.encode());

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
    if (previous != null && previous.sameTarget(stamped)) return;
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

  // ── Transcript tails ────────────────────────────────────────────────────

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
    final unchanged = _written[key] == payload && index.tails.containsKey(key);
    if (!unchanged) {
      await _storage.write(key, payload);
      _written[key] = payload;
    }
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
      bytes: utf8.encode(payload).length,
      savedAtMs: _nowMs(),
    );
    final evicted = <String>{};
    while (index.tails.length > maxTails || index.totalBytes > maxTotalBytes) {
      final oldest = index.tails.keys.first;
      if (oldest == key && index.tails.length == 1) break;
      index.tails.remove(oldest);
      evicted.add(oldest);
    }
    for (final stale in evicted) {
      _written.remove(stale);
      await _storage.delete(stale);
    }
    await _saveIndex(index);
  });

  /// Newest-first list of persisted tails (most recently saved first).
  /// [where] filters on identity before anything is read or decrypted.
  Future<List<ColdStartTail>> loadTails({
    int? limit,
    bool Function(String connectionId, String profile, Set<String> aliases)?
    where,
  }) => _serial(() async {
    final index = await _loadIndex();
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
        final raw = await _storage.read(entry.key);
        final tail = raw == null ? null : _decodeTail(raw, meta);
        if (tail == null) {
          drop.add(entry.key);
          continue;
        }
        _written[entry.key] = raw!;
        out.add(tail);
      } catch (error) {
        debugPrint('[cold-start] tail unavailable (${error.runtimeType})');
      }
    }
    if (drop.isNotEmpty) await _deleteTails(index, drop);
    return out;
  });

  ColdStartTail? _decodeTail(String raw, _TailMeta meta) {
    final data = jsonDecode(raw);
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
    var changed = false;
    for (final key in keys) {
      changed = index.tails.remove(key) != null || changed;
      _written.remove(key);
      await _storage.delete(key);
    }
    if (changed) await _saveIndex(index);
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
      });

  /// Removes everything this store ever wrote.
  Future<void> clearAll() => _serial(() async {
    final index = await _loadIndex();
    for (final key in index.tails.keys.toList()) {
      await _storage.delete(key);
    }
    index.tails.clear();
    index.routes.clear();
    _written.clear();
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
  _ColdStartIndex(this.routes, this.tails);

  _ColdStartIndex.empty() : routes = {}, tails = {};

  /// Per connection id.
  final Map<String, ColdStartRoute> routes;

  /// Least recently saved first.
  final Map<String, _TailMeta> tails;

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
    return _ColdStartIndex(routes, tails);
  }

  String encode() => jsonEncode({
    'v': 1,
    'routes': {
      for (final entry in routes.entries) entry.key: entry.value.toJson(),
    },
    'tails': [
      for (final entry in tails.entries)
        {'k': entry.key, ...entry.value.toJson()},
    ],
  });
}
