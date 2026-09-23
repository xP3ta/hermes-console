import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../models/session.dart';

abstract interface class DesktopCompressionFenceStorage {
  Future<String?> read();

  Future<void> write(String value);
}

final class FlutterSecureDesktopCompressionFenceStorage
    implements DesktopCompressionFenceStorage {
  FlutterSecureDesktopCompressionFenceStorage({
    FlutterSecureStorage? secureStorage,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const storageKey = 'desktop_compression_fences_v1';
  final FlutterSecureStorage _secureStorage;

  @override
  Future<String?> read() => _secureStorage.read(key: storageKey);

  @override
  Future<void> write(String value) =>
      _secureStorage.write(key: storageKey, value: value);
}

enum DesktopCompressionFencePhase {
  armed('armed'),
  serverPending('server_pending'),
  transportUnknown('transport_unknown');

  const DesktopCompressionFencePhase(this.storageValue);
  final String storageValue;
}

final class DesktopCompressionFenceScope {
  DesktopCompressionFenceScope({
    required this.connectionId,
    required String profile,
    required this.logicalSessionId,
  }) : profile = Session.profileOwner(profile);

  final String connectionId;
  final String profile;
  final String logicalSessionId;

  String get key => jsonEncode([connectionId, profile, logicalSessionId]);
}

final class DesktopCompressionFenceRecord {
  static const _jsonKeys = <String>{
    'connection_id',
    'profile',
    'logical_session_id',
    'attempt_id',
    'phase',
    'tip_at_start',
    'compressions_at_start',
    'created_at_ms',
    'reconcile_until_ms',
  };
  // Optional: records armed before the in-place baseline existed omit it.
  static const _optionalMessagesKey = 'messages_at_start';
  // Optional: the gateway runtime that ran the attempt, whose replay ring
  // (`session.events.since`) tells a later process whether it still runs.
  static const _optionalRuntimeKey = 'runtime_at_start';
  static final RegExp _opaqueId = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._:@/+\-]{0,255}$',
  );

  const DesktopCompressionFenceRecord({
    required this.scope,
    required this.attemptId,
    required this.phase,
    required this.tipAtStart,
    required this.compressionsAtStart,
    this.messagesAtStart,
    this.runtimeAtStart,
    required this.createdAtMs,
    required this.reconcileUntilMs,
  });

  final DesktopCompressionFenceScope scope;
  final String attemptId;
  final DesktopCompressionFencePhase phase;
  final String tipAtStart;
  final int? compressionsAtStart;

  /// Stored `message_count` read right before dispatch. The server compacts
  /// in place (same id, no lineage change, no counter in REST), so a smaller
  /// count on the exact row is the only durable proof the attempt finished.
  final int? messagesAtStart;
  final String? runtimeAtStart;
  final int createdAtMs;
  final int reconcileUntilMs;

  Map<String, Object?> toJson() => {
    'connection_id': scope.connectionId,
    'profile': scope.profile,
    'logical_session_id': scope.logicalSessionId,
    'attempt_id': attemptId,
    'phase': phase.storageValue,
    'tip_at_start': tipAtStart,
    'compressions_at_start': compressionsAtStart,
    if (messagesAtStart != null) _optionalMessagesKey: messagesAtStart,
    if (runtimeAtStart != null) _optionalRuntimeKey: runtimeAtStart,
    'created_at_ms': createdAtMs,
    'reconcile_until_ms': reconcileUntilMs,
  };

  DesktopCompressionFenceRecord transition({
    required DesktopCompressionFencePhase phase,
    required int reconcileUntilMs,
  }) => DesktopCompressionFenceRecord(
    scope: scope,
    attemptId: attemptId,
    phase: phase,
    tipAtStart: tipAtStart,
    compressionsAtStart: compressionsAtStart,
    messagesAtStart: messagesAtStart,
    runtimeAtStart: runtimeAtStart,
    createdAtMs: createdAtMs,
    reconcileUntilMs: reconcileUntilMs,
  );

  static DesktopCompressionFenceRecord fromJson(Map<String, Object?> json) {
    final keys = json.keys.toSet()
      ..remove(_optionalMessagesKey)
      ..remove(_optionalRuntimeKey);
    if (keys.length != _jsonKeys.length || !keys.containsAll(_jsonKeys)) {
      throw const FormatException('record shape');
    }
    final messagesAtStart = json[_optionalMessagesKey];
    if (messagesAtStart != null &&
        (messagesAtStart is! int || messagesAtStart < 0)) {
      throw const FormatException('record value');
    }
    final runtimeAtStart = json[_optionalRuntimeKey];
    if (runtimeAtStart != null &&
        (runtimeAtStart is! String || !_opaqueId.hasMatch(runtimeAtStart))) {
      throw const FormatException('record value');
    }
    final connectionId = json['connection_id'];
    final profile = json['profile'];
    final logicalSessionId = json['logical_session_id'];
    final attemptId = json['attempt_id'];
    final tipAtStart = json['tip_at_start'];
    final compressionCount = json['compressions_at_start'];
    final createdAtMs = json['created_at_ms'];
    final reconcileUntilMs = json['reconcile_until_ms'];
    if (connectionId is! String ||
        profile is! String ||
        logicalSessionId is! String ||
        attemptId is! String ||
        tipAtStart is! String ||
        !_opaqueId.hasMatch(connectionId) ||
        !_opaqueId.hasMatch(profile) ||
        Session.profileOwner(profile) != profile ||
        !_opaqueId.hasMatch(logicalSessionId) ||
        !_opaqueId.hasMatch(attemptId) ||
        !_opaqueId.hasMatch(tipAtStart) ||
        (compressionCount != null &&
            (compressionCount is! int || compressionCount < 0)) ||
        createdAtMs is! int ||
        createdAtMs < 0 ||
        reconcileUntilMs is! int ||
        reconcileUntilMs < createdAtMs) {
      throw const FormatException('record value');
    }
    final phaseValue = json['phase'];
    return DesktopCompressionFenceRecord(
      scope: DesktopCompressionFenceScope(
        connectionId: connectionId,
        profile: profile,
        logicalSessionId: logicalSessionId,
      ),
      attemptId: attemptId,
      phase: DesktopCompressionFencePhase.values.singleWhere(
        (phase) => phase.storageValue == phaseValue,
      ),
      tipAtStart: tipAtStart,
      compressionsAtStart: compressionCount as int?,
      messagesAtStart: messagesAtStart as int?,
      runtimeAtStart: runtimeAtStart as String?,
      createdAtMs: createdAtMs,
      reconcileUntilMs: reconcileUntilMs,
    );
  }
}

final class DesktopCompressionFenceEvidence {
  const DesktopCompressionFenceEvidence._({
    required this.provesSettlement,
    this.authoritativeTip,
  });

  const DesktopCompressionFenceEvidence.none()
    : this._(provesSettlement: false);

  final bool provesSettlement;
  final String? authoritativeTip;

  static DesktopCompressionFenceEvidence evaluate(
    DesktopCompressionFenceRecord record,
    Map<String, dynamic> payload,
  ) {
    final wrappedSession = payload['session'];
    final candidate = wrappedSession is Map ? wrappedSession : payload;
    final rawInfo = candidate['info'];
    if (rawInfo != null && rawInfo is! Map) {
      return const DesktopCompressionFenceEvidence.none();
    }
    final info = rawInfo is Map ? rawInfo : null;
    final maps = <Map<dynamic, dynamic>>[
      candidate,
      if (info != null && !identical(info, candidate)) info,
    ];

    const rootKeys = <String>[
      '_lineage_root_id',
      'lineage_root_id',
      'lineage_root',
    ];
    final roots = <String>[];
    for (final map in maps) {
      for (final key in rootKeys) {
        if (!map.containsKey(key)) continue;
        final value = map[key];
        if (value is! String ||
            !DesktopCompressionFenceRecord._opaqueId.hasMatch(value)) {
          return const DesktopCompressionFenceEvidence.none();
        }
        roots.add(value);
      }
    }
    if (roots.any((root) => root != record.scope.logicalSessionId)) {
      return const DesktopCompressionFenceEvidence.none();
    }
    // `GET /api/sessions/{id}` never advertises a lineage root; the exact row
    // is its own authority, and only the in-place proof applies to it.
    if (roots.isEmpty) return _inPlaceSettlement(record, candidate);

    final tips = <String>[];
    void addTip(Map<dynamic, dynamic> map, String key) {
      if (!map.containsKey(key)) return;
      final value = map[key];
      if (value is! String ||
          !DesktopCompressionFenceRecord._opaqueId.hasMatch(value)) {
        throw const FormatException('tip');
      }
      tips.add(value);
    }

    try {
      addTip(candidate, 'id');
      addTip(candidate, 'stored_session_id');
      if (info != null) addTip(info, 'stored_session_id');
    } on FormatException {
      return const DesktopCompressionFenceEvidence.none();
    }
    if (tips.isNotEmpty && tips.any((tip) => tip != tips.first)) {
      return const DesktopCompressionFenceEvidence.none();
    }
    final counts = <int>[];
    for (final map in maps) {
      final usage = map['usage'];
      if (usage == null) continue;
      if (usage is! Map) {
        return const DesktopCompressionFenceEvidence.none();
      }
      if (!usage.containsKey('compressions')) continue;
      final value = usage['compressions'];
      if (value is! int || value < 0) {
        return const DesktopCompressionFenceEvidence.none();
      }
      counts.add(value);
    }
    if (counts.isNotEmpty && counts.any((count) => count != counts.first)) {
      return const DesktopCompressionFenceEvidence.none();
    }
    final baseline = record.compressionsAtStart;
    final changedTip = tips.isNotEmpty && tips.first != record.tipAtStart;
    final increasedCount =
        baseline != null && counts.isNotEmpty && counts.first > baseline;
    if (changedTip || increasedCount) {
      return DesktopCompressionFenceEvidence._(
        provesSettlement: true,
        authoritativeTip: changedTip ? tips.first : null,
      );
    }
    return _inPlaceSettlement(record, candidate);
  }

  /// Hermes compacts in place: the session keeps its id and only its stored
  /// `message_count` shrinks. The exact row we compacted reporting fewer
  /// messages than right before dispatch proves the attempt committed.
  static DesktopCompressionFenceEvidence _inPlaceSettlement(
    DesktopCompressionFenceRecord record,
    Map<dynamic, dynamic> row,
  ) {
    final baseline = record.messagesAtStart;
    final id = row['id'];
    final stored = row['stored_session_id'];
    final count = row['message_count'];
    if (baseline == null ||
        id is! String ||
        id != record.tipAtStart ||
        (stored != null && stored != id) ||
        count is! int ||
        count < 0 ||
        count >= baseline) {
      return const DesktopCompressionFenceEvidence.none();
    }
    return const DesktopCompressionFenceEvidence._(provesSettlement: true);
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
/// when the owning client is gone, so a relaunched Console can read it.
enum DesktopCompressionReplayVerdict {
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

  static bool _isCompressing(Map<dynamic, dynamic> event) {
    if (event['type'] != 'status.update') return false;
    final payload = event['payload'];
    return payload is Map &&
        (payload['kind'] == 'compressing' || payload['kind'] == 'compacting');
  }

  static DesktopCompressionReplayVerdict evaluate(Map<String, dynamic> result) {
    final events = result['events'];
    final latest = result['latest_seq'];
    final truncated = result['truncated'];
    // latest_seq 0: this server process never stamped the runtime (restart
    // or ring eviction), which alone proves nothing.
    if (events is! List ||
        latest is! int ||
        latest <= 0 ||
        truncated is! bool) {
      return DesktopCompressionReplayVerdict.unknown;
    }
    var sawCompressing = false;
    var terminalAfter = false;
    for (final raw in events) {
      if (raw is! Map) return DesktopCompressionReplayVerdict.unknown;
      if (_isCompressing(raw)) {
        sawCompressing = true;
        terminalAfter = false;
      } else if (sawCompressing && _isTerminal(raw)) {
        terminalAfter = true;
      }
    }
    if (sawCompressing) {
      return terminalAfter
          ? DesktopCompressionReplayVerdict.finished
          : DesktopCompressionReplayVerdict.running;
    }
    // A complete ring with no pin: the gateway pins before any real work, so
    // nothing of this runtime is compressing (the attempt never arrived, or
    // finished instantly on a tiny transcript).
    return truncated
        ? DesktopCompressionReplayVerdict.unknown
        : DesktopCompressionReplayVerdict.finished;
  }
}

enum DesktopCompressionFenceLookupStatus { absent, present, unavailable }

final class DesktopCompressionFenceLookup {
  const DesktopCompressionFenceLookup._(this.status, this.record);

  const DesktopCompressionFenceLookup.absent()
    : this._(DesktopCompressionFenceLookupStatus.absent, null);
  const DesktopCompressionFenceLookup.present(
    DesktopCompressionFenceRecord record,
  ) : this._(DesktopCompressionFenceLookupStatus.present, record);
  const DesktopCompressionFenceLookup.unavailable()
    : this._(DesktopCompressionFenceLookupStatus.unavailable, null);

  final DesktopCompressionFenceLookupStatus status;
  final DesktopCompressionFenceRecord? record;
  bool get isFenced => status != DesktopCompressionFenceLookupStatus.absent;
}

final class DesktopCompressionFenceArmResult {
  const DesktopCompressionFenceArmResult({
    required this.claimed,
    required this.lookup,
  });

  final bool claimed;
  final DesktopCompressionFenceLookup lookup;
}

final class DesktopCompressionFenceStore {
  DesktopCompressionFenceStore({
    DesktopCompressionFenceStorage? storage,
    String Function()? attemptId,
    int maxRecords = 128,
    String? mutationNamespaceForTesting,
  }) : _storage = storage ?? FlutterSecureDesktopCompressionFenceStorage(),
       _attemptId = attemptId ?? const Uuid().v4,
       _maxRecords = maxRecords > 0 ? maxRecords : 0,
       _mutationNamespace =
           mutationNamespaceForTesting ??
           FlutterSecureDesktopCompressionFenceStorage.storageKey;

  static final Map<String, Future<void>> _mutationTails = {};
  static const int _maxEncodedCodeUnits = 256 * 1024;
  final DesktopCompressionFenceStorage _storage;
  final String Function() _attemptId;
  final int _maxRecords;
  final String _mutationNamespace;

  Future<DesktopCompressionFenceLookup> lookup(
    DesktopCompressionFenceScope scope,
  ) async {
    try {
      final records = await _readRecords();
      final record = records[scope.key];
      return record == null
          ? const DesktopCompressionFenceLookup.absent()
          : DesktopCompressionFenceLookup.present(record);
    } catch (_) {
      return const DesktopCompressionFenceLookup.unavailable();
    }
  }

  Future<DesktopCompressionFenceArmResult> arm(
    DesktopCompressionFenceScope scope, {
    required String tipAtStart,
    required int? compressionsAtStart,
    int? messagesAtStart,
    String? runtimeAtStart,
    required int createdAtMs,
    required int reconcileUntilMs,
  }) => _serialized(() async {
    try {
      final records = await _readRecords();
      final existing = records[scope.key];
      if (existing != null) {
        return DesktopCompressionFenceArmResult(
          claimed: false,
          lookup: DesktopCompressionFenceLookup.present(existing),
        );
      }
      if (_maxRecords <= 0 || records.length >= _maxRecords) {
        return const DesktopCompressionFenceArmResult(
          claimed: false,
          lookup: DesktopCompressionFenceLookup.unavailable(),
        );
      }
      final record = DesktopCompressionFenceRecord.fromJson(
        DesktopCompressionFenceRecord(
          scope: scope,
          attemptId: _attemptId(),
          phase: DesktopCompressionFencePhase.armed,
          tipAtStart: tipAtStart,
          compressionsAtStart: compressionsAtStart,
          messagesAtStart: messagesAtStart,
          runtimeAtStart: runtimeAtStart,
          createdAtMs: createdAtMs,
          reconcileUntilMs: reconcileUntilMs,
        ).toJson(),
      );
      records[scope.key] = record;
      await _writeRecords(records);
      return DesktopCompressionFenceArmResult(
        claimed: true,
        lookup: DesktopCompressionFenceLookup.present(record),
      );
    } catch (_) {
      return const DesktopCompressionFenceArmResult(
        claimed: false,
        lookup: DesktopCompressionFenceLookup.unavailable(),
      );
    }
  });

  Future<bool> updatePhase(
    DesktopCompressionFenceScope scope, {
    required String attemptId,
    required DesktopCompressionFencePhase phase,
  }) => _serialized(() async {
    try {
      final records = await _readRecords();
      final current = records[scope.key];
      if (current == null || current.attemptId != attemptId) return false;
      records[scope.key] = current.transition(
        phase: phase,
        reconcileUntilMs: current.reconcileUntilMs,
      );
      await _writeRecords(records);
      return true;
    } catch (_) {
      return false;
    }
  });

  Future<DesktopCompressionFenceRecord?> transitionAttempt(
    DesktopCompressionFenceScope scope, {
    required String attemptId,
    required DesktopCompressionFencePhase phase,
    required int reconcileUntilMs,
  }) => _serialized(() async {
    try {
      final records = await _readRecords();
      final current = records[scope.key];
      if (current == null || current.attemptId != attemptId) return null;
      final transitioned = DesktopCompressionFenceRecord.fromJson(
        current
            .transition(phase: phase, reconcileUntilMs: reconcileUntilMs)
            .toJson(),
      );
      records[scope.key] = transitioned;
      await _writeRecords(records);
      return transitioned;
    } catch (_) {
      return null;
    }
  });

  Future<bool> deleteAttempt(
    DesktopCompressionFenceScope scope, {
    required String attemptId,
  }) => _serialized(() async {
    try {
      final records = await _readRecords();
      final current = records[scope.key];
      if (current == null || current.attemptId != attemptId) return false;
      records.remove(scope.key);
      await _writeRecords(records);
      return true;
    } catch (_) {
      return false;
    }
  });

  Future<int> clearSession(DesktopCompressionFenceScope scope) =>
      _serialized(() async {
        try {
          final records = await _readRecords();
          if (records.remove(scope.key) == null) return 0;
          await _writeRecords(records);
          return 1;
        } catch (_) {
          return 0;
        }
      });

  Future<int> clearConnection(String connectionId) => _serialized(() async {
    try {
      final records = await _readRecords();
      final before = records.length;
      records.removeWhere(
        (_, record) => record.scope.connectionId == connectionId,
      );
      final removed = before - records.length;
      if (removed > 0) await _writeRecords(records);
      return removed;
    } catch (_) {
      return 0;
    }
  });

  Future<Map<String, DesktopCompressionFenceRecord>> _readRecords() async {
    final encoded = await _storage.read();
    if (encoded == null) return {};
    if (encoded.length > _maxEncodedCodeUnits) {
      throw const FormatException('container too large');
    }
    final decoded = jsonDecode(encoded);
    if (decoded is! Map<String, dynamic> ||
        decoded.keys.length != 2 ||
        !decoded.containsKey('v') ||
        !decoded.containsKey('records') ||
        decoded['v'] != 1) {
      throw const FormatException('container');
    }
    final rawRecords = decoded['records'];
    if (rawRecords is! List<dynamic> || rawRecords.length > _maxRecords) {
      throw const FormatException('records');
    }
    final records = <String, DesktopCompressionFenceRecord>{};
    for (final raw in rawRecords) {
      if (raw is! Map) throw const FormatException('record');
      final record = DesktopCompressionFenceRecord.fromJson(
        Map<String, Object?>.from(raw),
      );
      if (records.containsKey(record.scope.key)) {
        throw const FormatException('duplicate scope');
      }
      records[record.scope.key] = record;
    }
    return records;
  }

  Future<void> _writeRecords(
    Map<String, DesktopCompressionFenceRecord> records,
  ) => _storage.write(
    jsonEncode({
      'v': 1,
      'records': records.values.map((record) => record.toJson()).toList(),
    }),
  );

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _mutationTails[_mutationNamespace] =
        (_mutationTails[_mutationNamespace] ?? Future<void>.value())
            .then((_) async {
              try {
                completer.complete(await operation());
              } catch (error, stackTrace) {
                completer.completeError(error, stackTrace);
              }
            })
            .catchError((_) {});
    return completer.future;
  }
}
