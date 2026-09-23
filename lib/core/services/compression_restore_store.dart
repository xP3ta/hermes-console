import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/session.dart';

/// Where a manual `/compress` ran, so a relaunched app can ask the gateway
/// whether it is still running.
///
/// This is not a lock. Hermes Desktop never blocks input on a compression;
/// the only durable fact Console keeps is the gateway runtime that ran the
/// attempt, because the tui_gateway reaps a clientless session ~20 s after
/// its socket drops (`session_reaper.py`) while its replay ring
/// (`session.events.since`, keyed by that runtime) survives. Nothing else
/// (`session.active_list`, `session.resume`) can name that runtime again.
abstract interface class CompressionRestoreStorage {
  Future<String?> read();

  Future<void> write(String value);
}

final class FlutterSecureCompressionRestoreStorage
    implements CompressionRestoreStorage {
  FlutterSecureCompressionRestoreStorage({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const storageKey = 'compression_restore_v1';

  /// The retired fail-closed fence container; dropped on first use.
  static const legacyFenceKey = 'desktop_compression_fences_v1';
  static bool _legacyDropped = false;

  final FlutterSecureStorage _secureStorage;

  @override
  Future<String?> read() async {
    if (!_legacyDropped) {
      _legacyDropped = true;
      try {
        await _secureStorage.delete(key: legacyFenceKey);
      } catch (_) {}
    }
    return _secureStorage.read(key: storageKey);
  }

  @override
  Future<void> write(String value) =>
      _secureStorage.write(key: storageKey, value: value);
}

final class CompressionRestoreRecord {
  const CompressionRestoreRecord({
    required this.connectionId,
    required this.profile,
    required this.storedSessionId,
    required this.runtimeId,
    required this.startedAtMs,
  });

  static final RegExp _opaqueId = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._:@/+\-]{0,255}$',
  );
  static const _keys = <String>{
    'connection_id',
    'profile',
    'stored_session_id',
    'runtime_id',
    'started_at_ms',
  };

  final String connectionId;
  final String profile;
  final String storedSessionId;
  final String runtimeId;
  final int startedAtMs;

  static String keyFor({
    required String connectionId,
    required String profile,
    required String storedSessionId,
  }) => jsonEncode([
    connectionId,
    Session.profileOwner(profile),
    storedSessionId,
  ]);

  String get key => keyFor(
    connectionId: connectionId,
    profile: profile,
    storedSessionId: storedSessionId,
  );

  Map<String, Object?> toJson() => {
    'connection_id': connectionId,
    'profile': Session.profileOwner(profile),
    'stored_session_id': storedSessionId,
    'runtime_id': runtimeId,
    'started_at_ms': startedAtMs,
  };

  static CompressionRestoreRecord? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final keys = raw.keys.toSet();
    if (keys.length != _keys.length || !keys.containsAll(_keys)) return null;
    final connectionId = raw['connection_id'];
    final profile = raw['profile'];
    final stored = raw['stored_session_id'];
    final runtime = raw['runtime_id'];
    final started = raw['started_at_ms'];
    if (connectionId is! String ||
        profile is! String ||
        stored is! String ||
        runtime is! String ||
        started is! int ||
        started < 0 ||
        !_opaqueId.hasMatch(connectionId) ||
        !_opaqueId.hasMatch(profile) ||
        !_opaqueId.hasMatch(stored) ||
        !_opaqueId.hasMatch(runtime)) {
      return null;
    }
    return CompressionRestoreRecord(
      connectionId: connectionId,
      profile: profile,
      storedSessionId: stored,
      runtimeId: runtime,
      startedAtMs: started,
    );
  }

  bool get isValid =>
      _opaqueId.hasMatch(connectionId) &&
      _opaqueId.hasMatch(Session.profileOwner(profile)) &&
      _opaqueId.hasMatch(storedSessionId) &&
      _opaqueId.hasMatch(runtimeId) &&
      startedAtMs >= 0;
}

/// Best-effort, fail-open store of [CompressionRestoreRecord]s. Every error
/// reads as "nothing recorded": a missing record only means a relaunched app
/// shows no restored progress, never that the chat is blocked.
final class CompressionRestoreStore {
  CompressionRestoreStore({
    CompressionRestoreStorage? storage,
    int maxRecords = 64,
    String? mutationNamespaceForTesting,
  }) : _storage = storage ?? FlutterSecureCompressionRestoreStorage(),
       _maxRecords = maxRecords > 0 ? maxRecords : 1,
       _namespace =
           mutationNamespaceForTesting ??
           FlutterSecureCompressionRestoreStorage.storageKey;

  static final Map<String, Future<void>> _tails = {};
  static const int _maxEncodedCodeUnits = 64 * 1024;
  final CompressionRestoreStorage _storage;
  final int _maxRecords;
  final String _namespace;

  Future<CompressionRestoreRecord?> lookup({
    required String connectionId,
    required String profile,
    required String storedSessionId,
  }) async {
    try {
      final records = await _read();
      return records[CompressionRestoreRecord.keyFor(
        connectionId: connectionId,
        profile: profile,
        storedSessionId: storedSessionId,
      )];
    } catch (_) {
      return null;
    }
  }

  Future<void> save(CompressionRestoreRecord record) => _serialized(() async {
    if (!record.isValid) return;
    final records = await _read();
    records.remove(record.key);
    records[record.key] = record;
    while (records.length > _maxRecords) {
      records.remove(records.keys.first);
    }
    await _write(records);
  });

  /// Removes the record only while it still names [runtimeId] (a newer
  /// attempt on the same chat keeps its own).
  Future<void> clear({
    required String connectionId,
    required String profile,
    required String storedSessionId,
    String? runtimeId,
  }) => _serialized(() async {
    final records = await _read();
    final key = CompressionRestoreRecord.keyFor(
      connectionId: connectionId,
      profile: profile,
      storedSessionId: storedSessionId,
    );
    final current = records[key];
    if (current == null ||
        (runtimeId != null && current.runtimeId != runtimeId)) {
      return;
    }
    records.remove(key);
    await _write(records);
  });

  Future<void> clearConnection(String connectionId) => _serialized(() async {
    final records = await _read();
    final before = records.length;
    records.removeWhere((_, record) => record.connectionId == connectionId);
    if (records.length != before) await _write(records);
  });

  Future<Map<String, CompressionRestoreRecord>> _read() async {
    final encoded = await _storage.read();
    final records = <String, CompressionRestoreRecord>{};
    if (encoded == null || encoded.length > _maxEncodedCodeUnits) {
      return records;
    }
    final decoded = jsonDecode(encoded);
    if (decoded is! Map || decoded['v'] != 1 || decoded['records'] is! List) {
      return records;
    }
    for (final raw in decoded['records'] as List) {
      final record = CompressionRestoreRecord.tryParse(raw);
      if (record != null) records[record.key] = record;
    }
    return records;
  }

  Future<void> _write(Map<String, CompressionRestoreRecord> records) =>
      _storage.write(
        jsonEncode({
          'v': 1,
          'records': [for (final record in records.values) record.toJson()],
        }),
      );

  Future<void> _serialized(Future<void> Function() operation) {
    final completer = Completer<void>();
    _tails[_namespace] = (_tails[_namespace] ?? Future<void>.value()).then((
      _,
    ) async {
      try {
        await operation();
      } catch (_) {
        // Fail open: a lost record only hides restored progress.
      }
      completer.complete();
    });
    return completer.future;
  }
}

/// What the gateway's per-runtime replay ring (`session.events.since` with
/// `last_seen: 0`) says about a manual compression that runtime ran.
///
/// `tui_gateway/methods_session.py` `_compress_live` pins
/// `status.update(kind: compressing)` before the work and ALWAYS emits
/// `status.update(ready)` in its `finally` (success, no-op, refusal or
/// error; server.py `_status_update` sends it as `{kind: status, text:
/// ready}`); the compute-host path ends with `compacted`. Hermes Desktop
/// clears its compacting flag on exactly those events
/// (`gateway-event/status.ts`). Every frame is stamped into the ring even
/// when the owning client is gone.
///
/// Only [running] is positive evidence; anything else leaves the chat free.
enum CompressionReplayVerdict {
  running,
  finished,
  unknown;

  static bool _isTerminal(Map<dynamic, dynamic> event) {
    final type = event['type'];
    if (type == 'error') return true;
    if (type != 'status.update') return false;
    final payload = event['payload'];
    if (payload is! Map) return false;
    final kind = payload['kind'];
    return kind == 'ready' ||
        kind == 'compacted' ||
        (kind == 'status' && payload['text'] == 'ready');
  }

  static bool isCompressing(Map<dynamic, dynamic> event) {
    if (event['type'] != 'status.update') return false;
    final payload = event['payload'];
    return payload is Map &&
        (payload['kind'] == 'compressing' || payload['kind'] == 'compacting');
  }

  static CompressionReplayVerdict evaluate(Map<String, dynamic> result) {
    final events = result['events'];
    final latest = result['latest_seq'];
    final truncated = result['truncated'];
    if (events is! List ||
        latest is! int ||
        latest <= 0 ||
        truncated is! bool) {
      return CompressionReplayVerdict.unknown;
    }
    var sawCompressing = false;
    var terminalAfter = false;
    for (final raw in events) {
      if (raw is! Map) return CompressionReplayVerdict.unknown;
      if (isCompressing(raw)) {
        sawCompressing = true;
        terminalAfter = false;
      } else if (sawCompressing && _isTerminal(raw)) {
        terminalAfter = true;
      }
    }
    if (!sawCompressing) {
      return truncated
          ? CompressionReplayVerdict.unknown
          : CompressionReplayVerdict.finished;
    }
    return terminalAfter
        ? CompressionReplayVerdict.finished
        : CompressionReplayVerdict.running;
  }

  /// The `compressing N messages (~T tok)` text of the latest pin, if any.
  static String? latestCompressingText(Map<String, dynamic> result) {
    final events = result['events'];
    if (events is! List) return null;
    String? text;
    for (final raw in events) {
      if (raw is Map && isCompressing(raw)) {
        final payload = raw['payload'];
        final value = payload is Map ? payload['text'] : null;
        text = value is String ? value : text;
      }
    }
    return text;
  }
}
