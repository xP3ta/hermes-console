import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:uuid/uuid.dart';

typedef DeliveryClock = int Function();
typedef LeaseTokenFactory = String Function();
typedef DeliveryDigest = List<int> Function(List<int> input);
typedef IngestFaultInjector = void Function(int index, DeliveryEventSpec event);

enum DeliveryStatus {
  pending,
  leased,
  presented,
  cancelPending,
  cancelled,
  suppressed,
  expired;

  String get databaseValue => switch (this) {
    cancelPending => 'cancel_pending',
    _ => name,
  };

  static DeliveryStatus fromDatabase(String value) => switch (value) {
    'cancel_pending' => cancelPending,
    _ => DeliveryStatus.values.singleWhere((status) => status.name == value),
  };
}

/// Typed opaque identity for one material source event.
class NotificationEventIdentity {
  const NotificationEventIdentity({
    required this.connId,
    required this.profile,
    required this.sourceKind,
    required this.objectId,
    required this.eventKind,
    required this.sourceVersion,
  });

  final String connId;
  final String profile;
  final String sourceKind;
  final String objectId;
  final String eventKind;
  final String sourceVersion;

  String get normalizedProfile => profile.trim().toLowerCase();

  /// UTF-8 byte-length-delimited tuple. Delimiters inside values are harmless.
  String get canonical => <String>[
    connId,
    normalizedProfile,
    sourceKind,
    objectId,
    eventKind,
    sourceVersion,
  ].map((value) => '${utf8.encode(value).length}:$value').join('|');

  String get eventKey => sha256.convert(utf8.encode(canonical)).toString();
}

class DeliveryEventSpec {
  const DeliveryEventSpec({
    required this.identity,
    required this.destinationKind,
    this.sessionId,
    this.runId,
    this.taskId,
    this.jobId,
  });

  final NotificationEventIdentity identity;
  final String destinationKind;
  final String? sessionId;
  final String? runId;
  final String? taskId;
  final String? jobId;
}

class SourceCursorUpdate {
  const SourceCursorUpdate({
    required this.scopeKey,
    required this.connId,
    required this.profile,
    required this.sourceKind,
    required this.objectId,
    required this.lastState,
    required this.lastVersion,
    required this.generation,
    required this.initialized,
    required this.events,
  });

  final String scopeKey;
  final String connId;
  final String profile;
  final String sourceKind;
  final String objectId;
  final String lastState;
  final String lastVersion;
  final int generation;
  final bool initialized;
  final List<DeliveryEventSpec> events;
}

class DeliveryEventRecord {
  const DeliveryEventRecord({
    required this.eventKey,
    required this.connId,
    required this.profile,
    required this.sourceKind,
    required this.objectId,
    required this.eventKind,
    required this.sourceVersion,
    required this.destinationKind,
    required this.status,
    required this.androidId,
    required this.androidTag,
    required this.attemptCount,
    required this.nextAttemptAt,
    required this.createdAt,
    required this.updatedAt,
    this.sessionId,
    this.runId,
    this.taskId,
    this.jobId,
    this.leaseToken,
    this.leaseUntil,
    this.presentedAt,
    this.cancelledAt,
    this.presentationSurface,
    this.lastErrorCode,
  });

  final String eventKey;
  final String connId;
  final String profile;
  final String sourceKind;
  final String objectId;
  final String eventKind;
  final String sourceVersion;
  final String destinationKind;
  final String? sessionId;
  final String? runId;
  final String? taskId;
  final String? jobId;
  final DeliveryStatus status;
  final int androidId;
  final String androidTag;
  final int attemptCount;
  final int nextAttemptAt;
  final String? leaseToken;
  final int? leaseUntil;
  final int createdAt;
  final int updatedAt;
  final int? presentedAt;
  final int? cancelledAt;
  final String? presentationSurface;
  final String? lastErrorCode;

  factory DeliveryEventRecord.fromRow(Map<String, Object?> row) {
    return DeliveryEventRecord(
      eventKey: row['event_key']! as String,
      connId: row['conn_id']! as String,
      profile: row['profile']! as String,
      sourceKind: row['source_kind']! as String,
      objectId: row['object_id']! as String,
      eventKind: row['event_kind']! as String,
      sourceVersion: row['source_version']! as String,
      destinationKind: row['destination_kind']! as String,
      sessionId: row['session_id'] as String?,
      runId: row['run_id'] as String?,
      taskId: row['task_id'] as String?,
      jobId: row['job_id'] as String?,
      status: DeliveryStatus.fromDatabase(row['status']! as String),
      androidId: row['android_id']! as int,
      androidTag: row['android_tag']! as String,
      attemptCount: row['attempt_count']! as int,
      nextAttemptAt: row['next_attempt_at']! as int,
      leaseToken: row['lease_token'] as String?,
      leaseUntil: row['lease_until'] as int?,
      createdAt: row['created_at']! as int,
      updatedAt: row['updated_at']! as int,
      presentedAt: row['presented_at'] as int?,
      cancelledAt: row['cancelled_at'] as int?,
      presentationSurface: row['presentation_surface'] as String?,
      lastErrorCode: row['last_error_code'] as String?,
    );
  }
}

class DeliveryLease {
  const DeliveryLease({required this.event, required this.token});

  final DeliveryEventRecord event;
  final String token;
}

class DeliveryCapacityException implements Exception {
  const DeliveryCapacityException(this.capacity);

  final int capacity;

  @override
  String toString() => 'DeliveryCapacityException(capacity: $capacity)';
}

class _Mutex {
  Future<void>? _current;

  Future<T> withLock<T>(Future<T> Function() action) async {
    final previous = _current;
    final completer = Completer<void>();
    _current = completer.future;
    if (previous != null) await previous;
    try {
      return await action();
    } finally {
      completer.complete();
    }
  }
}

/// Durable, app-private delivery state shared by every Flutter engine.
///
/// SQLite transactions are the only serialization authority. This store holds
/// opaque identity and routing metadata only; presentation text is deliberately
/// outside its contract.
class NotificationDeliveryStore {
  NotificationDeliveryStore({
    sqflite.DatabaseFactory? databaseFactory,
    this.databasePath,
    DeliveryClock? clock,
    LeaseTokenFactory? tokenFactory,
    DeliveryDigest? digest,
    this.ingestFaultInjector,
    this.pendingCapacity = 512,
    this.leaseDuration = const Duration(seconds: 30),
    this.maximumFutureLease = const Duration(minutes: 2),
    this.mappingRetention = const Duration(days: 30),
  }) : _databaseFactory = databaseFactory ?? sqflite.databaseFactory,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       _tokenFactory = tokenFactory ?? const Uuid().v4,
       _digest = digest ?? ((input) => sha256.convert(input).bytes) {
    if (pendingCapacity <= 0) {
      throw ArgumentError.value(pendingCapacity, 'pendingCapacity');
    }
    if (leaseDuration <= Duration.zero) {
      throw ArgumentError.value(leaseDuration, 'leaseDuration');
    }
    if (maximumFutureLease <= leaseDuration) {
      throw ArgumentError.value(
        maximumFutureLease,
        'maximumFutureLease',
        'must be greater than leaseDuration',
      );
    }
    if (mappingRetention <= Duration.zero) {
      throw ArgumentError.value(mappingRetention, 'mappingRetention');
    }
  }

  static const databaseFileName = 'notification_delivery_v1.db';
  static const schemaVersionNumber = 1;
  static const busyTimeoutMilliseconds = 2000;

  /// Closed routing vocabulary: presentation text has no place here.
  static const destinationKinds = <String>{
    'run_terminal',
    'cron_terminal',
    'kanban_transition',
    'approval',
    'chat_reply',
  };
  static const presentationSurfaces = <String>{'alert', 'inline'};

  static final RegExp _identifierPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$',
  );
  static final RegExp _scopeKeyPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._/-]{0,511}$',
  );
  static final RegExp _codePattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
  static final RegExp _tokenPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$',
  );

  static const _secretPrefixes = <String>{
    'sk-',
    'api_key',
    'apikey',
    'token',
    'bearer',
    'secret',
    'password',
    'private',
  };

  static void _requireIdentifier(String? value, String name) {
    if (value == null) return;
    if (!_identifierPattern.hasMatch(value)) {
      throw ArgumentError.value(value, name, 'not an opaque identifier');
    }
    final lower = value.toLowerCase();
    for (final prefix in _secretPrefixes) {
      if (lower.startsWith(prefix) || lower.contains(' $prefix')) {
        throw ArgumentError.value(
          value,
          name,
          'resembles a secret-bearing value',
        );
      }
    }
  }

  static void _requireToken(String value, String name) {
    if (!_tokenPattern.hasMatch(value)) {
      throw ArgumentError.value(value, name, 'not a machine token');
    }
  }

  static void _validateCursorUpdate(SourceCursorUpdate update) {
    if (!_scopeKeyPattern.hasMatch(update.scopeKey)) {
      throw ArgumentError.value(update.scopeKey, 'scopeKey');
    }
    _requireIdentifier(update.connId, 'connId');
    _requireIdentifier(update.profile.trim().toLowerCase(), 'profile');
    _requireIdentifier(update.sourceKind, 'sourceKind');
    _requireIdentifier(update.objectId, 'objectId');
    _requireToken(update.lastState, 'lastState');
    _requireToken(update.lastVersion, 'lastVersion');
    for (final event in update.events) {
      final identity = event.identity;
      _requireIdentifier(identity.connId, 'identity.connId');
      _requireIdentifier(identity.normalizedProfile, 'identity.profile');
      _requireIdentifier(identity.sourceKind, 'identity.sourceKind');
      _requireIdentifier(identity.objectId, 'identity.objectId');
      _requireIdentifier(identity.eventKind, 'identity.eventKind');
      _requireIdentifier(identity.sourceVersion, 'identity.sourceVersion');
      if (!destinationKinds.contains(event.destinationKind)) {
        throw ArgumentError.value(
          event.destinationKind,
          'destinationKind',
          'outside the closed routing vocabulary',
        );
      }
      _requireIdentifier(event.sessionId, 'sessionId');
      _requireIdentifier(event.runId, 'runId');
      _requireIdentifier(event.taskId, 'taskId');
      _requireIdentifier(event.jobId, 'jobId');
    }
  }

  final sqflite.DatabaseFactory _databaseFactory;
  final DeliveryClock _clock;
  final LeaseTokenFactory _tokenFactory;
  final DeliveryDigest _digest;
  final IngestFaultInjector? ingestFaultInjector;
  final String? databasePath;
  final int pendingCapacity;
  final Duration leaseDuration;
  final Duration maximumFutureLease;
  final Duration mappingRetention;
  sqflite.Database? _database;
  final _Mutex _lifecycleLock = _Mutex();

  Future<void> open() async {
    return _lifecycleLock.withLock(() async {
      if (_database != null) return;
      final path = databasePath ?? await _defaultDatabasePath();
      _database = await _databaseFactory.openDatabase(
        path,
        options: sqflite.OpenDatabaseOptions(
          version: schemaVersionNumber,
          singleInstance: false,
          onConfigure: _configure,
          onCreate: (database, _) => _ensureSchema(database),
          onOpen: _ensureSchema,
        ),
      );
    });
  }

  Future<String> _defaultDatabasePath() async {
    final directory = await _databaseFactory.getDatabasesPath();
    final separator = directory.endsWith('/') ? '' : '/';
    return '$directory$separator$databaseFileName';
  }

  Future<void> _configure(sqflite.Database database) async {
    await database.execute('PRAGMA journal_mode = WAL');
    await database.execute('PRAGMA foreign_keys = ON');
    await database.execute('PRAGMA synchronous = FULL');
    await database.execute('PRAGMA busy_timeout = $busyTimeoutMilliseconds');
  }

  Future<void> _ensureSchema(sqflite.Database database) async {
    await database.execute('''
CREATE TABLE IF NOT EXISTS delivery_event (
  event_key TEXT PRIMARY KEY,
  conn_id TEXT NOT NULL,
  profile TEXT NOT NULL,
  source_kind TEXT NOT NULL,
  object_id TEXT NOT NULL,
  event_kind TEXT NOT NULL,
  source_version TEXT NOT NULL,
  destination_kind TEXT NOT NULL,
  session_id TEXT,
  run_id TEXT,
  task_id TEXT,
  job_id TEXT,
  status TEXT NOT NULL CHECK (status IN (
    'pending', 'leased', 'presented', 'cancel_pending', 'cancelled',
    'suppressed', 'expired'
  )),
  android_id INTEGER NOT NULL UNIQUE,
  android_tag TEXT NOT NULL,
  attempt_count INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NOT NULL,
  lease_token TEXT,
  lease_until INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  presented_at INTEGER,
  cancelled_at INTEGER,
  presentation_surface TEXT,
  last_error_code TEXT,
  UNIQUE(conn_id, profile, source_kind, object_id, event_kind, source_version)
)
''');
    await database.execute('''
CREATE TABLE IF NOT EXISTS source_cursor (
  scope_key TEXT PRIMARY KEY,
  conn_id TEXT NOT NULL,
  profile TEXT NOT NULL,
  source_kind TEXT NOT NULL,
  object_id TEXT NOT NULL,
  last_state TEXT NOT NULL,
  last_version TEXT NOT NULL,
  generation INTEGER NOT NULL,
  initialized INTEGER NOT NULL CHECK (initialized IN (0, 1)),
  updated_at INTEGER NOT NULL,
  UNIQUE(conn_id, profile, source_kind, object_id)
)
''');
    await database.execute('''
CREATE TABLE IF NOT EXISTS android_id_map (
  event_key TEXT PRIMARY KEY,
  android_id INTEGER NOT NULL UNIQUE,
  android_tag TEXT NOT NULL UNIQUE,
  allocated_at INTEGER NOT NULL,
  retain_until INTEGER NOT NULL
)
''');
    await database.execute('''
CREATE TABLE IF NOT EXISTS delivery_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
)
''');
    await database.execute('''
CREATE INDEX IF NOT EXISTS delivery_event_due_idx
ON delivery_event(status, next_attempt_at, created_at)
''');
    await database.execute('''
CREATE INDEX IF NOT EXISTS delivery_event_lease_idx
ON delivery_event(status, lease_until)
''');
    await database.execute('''
CREATE INDEX IF NOT EXISTS delivery_event_run_idx
ON delivery_event(conn_id, profile, run_id, destination_kind, status)
''');
    await database.insert('delivery_meta', const <String, Object?>{
      'key': 'schema_version',
      'value': '1',
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.ignore);
  }

  sqflite.Database get _db {
    final database = _database;
    if (database == null) {
      throw StateError('NotificationDeliveryStore is not open');
    }
    return database;
  }

  Future<T> _exclusive<T>(
    Future<T> Function(sqflite.Transaction transaction) action,
  ) async {
    final stopwatch = Stopwatch()..start();
    while (true) {
      try {
        return await _db.transaction(action, exclusive: true);
      } on sqflite.DatabaseException catch (error) {
        final primaryCode = (error.getResultCode() ?? -1) & 0xff;
        final locked = primaryCode == 5 || primaryCode == 6;
        if (!locked ||
            stopwatch.elapsedMilliseconds >= busyTimeoutMilliseconds) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
  }

  Future<void> ingestSourceBatch(List<SourceCursorUpdate> updates) async {
    for (final update in updates) {
      _validateCursorUpdate(update);
    }
    final now = _clock();
    await _exclusive((transaction) async {
      var eventIndex = 0;
      for (final update in updates) {
        final cursors = await transaction.query(
          'source_cursor',
          where: 'scope_key = ?',
          whereArgs: <Object?>[update.scopeKey],
          limit: 1,
        );
        var storedGeneration = -1;
        if (cursors.isNotEmpty) {
          final cursor = cursors.single;
          final sameIdentity =
              cursor['conn_id']! as String == update.connId &&
              cursor['profile']! as String ==
                  update.profile.trim().toLowerCase() &&
              cursor['source_kind']! as String == update.sourceKind &&
              cursor['object_id']! as String == update.objectId;
          if (!sameIdentity) {
            throw ArgumentError.value(
              update.scopeKey,
              'scopeKey',
              'cursor identity mismatch for scope',
            );
          }
          storedGeneration = cursor['generation']! as int;
        }

        for (final event in update.events) {
          ingestFaultInjector?.call(eventIndex, event);
          eventIndex += 1;
          await _insertEvent(transaction, event, now);
        }
        if (update.generation < storedGeneration) {
          continue;
        }
        await transaction.rawInsert(
          '''
INSERT INTO source_cursor (
  scope_key, conn_id, profile, source_kind, object_id, last_state,
  last_version, generation, initialized, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(scope_key) DO UPDATE SET
  conn_id = excluded.conn_id,
  profile = excluded.profile,
  source_kind = excluded.source_kind,
  object_id = excluded.object_id,
  last_state = excluded.last_state,
  last_version = excluded.last_version,
  generation = excluded.generation,
  initialized = excluded.initialized,
  updated_at = excluded.updated_at
''',
          <Object?>[
            update.scopeKey,
            update.connId,
            update.profile.trim().toLowerCase(),
            update.sourceKind,
            update.objectId,
            update.lastState,
            update.lastVersion,
            update.generation,
            update.initialized ? 1 : 0,
            now,
          ],
        );
      }
    });
  }

  Future<void> _insertEvent(
    sqflite.DatabaseExecutor executor,
    DeliveryEventSpec event,
    int now,
  ) async {
    final digestBytes = _digest(utf8.encode(event.identity.canonical));
    if (digestBytes.length < 8) {
      throw StateError('Delivery digest must contain at least 8 bytes');
    }
    final digestHex = _hex(digestBytes);
    final eventKey = digestHex;
    final existing = await executor.query(
      'delivery_event',
      columns: const <String>['event_key'],
      where: 'event_key = ?',
      whereArgs: <Object?>[eventKey],
      limit: 1,
    );
    if (existing.isNotEmpty) return;
    final retained = await executor.query(
      'android_id_map',
      columns: const <String>['event_key'],
      where: 'event_key = ?',
      whereArgs: <Object?>[eventKey],
      limit: 1,
    );
    if (retained.isNotEmpty) return;

    final active = sqflite.Sqflite.firstIntValue(
      await executor.rawQuery('''
SELECT COUNT(*) FROM delivery_event
WHERE status IN ('pending', 'leased', 'cancel_pending')
'''),
    )!;
    if (active >= pendingCapacity) {
      throw DeliveryCapacityException(pendingCapacity);
    }

    final allocation = await _allocateAndroidIdentity(
      executor,
      eventKey: eventKey,
      digestBytes: digestBytes,
      digestHex: digestHex,
      now: now,
    );
    final identity = event.identity;
    await executor.insert('delivery_event', <String, Object?>{
      'event_key': eventKey,
      'conn_id': identity.connId,
      'profile': identity.normalizedProfile,
      'source_kind': identity.sourceKind,
      'object_id': identity.objectId,
      'event_kind': identity.eventKind,
      'source_version': identity.sourceVersion,
      'destination_kind': event.destinationKind,
      'session_id': event.sessionId,
      'run_id': event.runId,
      'task_id': event.taskId,
      'job_id': event.jobId,
      'status': DeliveryStatus.pending.databaseValue,
      'android_id': allocation.$1,
      'android_tag': allocation.$2,
      'attempt_count': 0,
      'next_attempt_at': now,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<(int, String)> _allocateAndroidIdentity(
    sqflite.DatabaseExecutor executor, {
    required String eventKey,
    required List<int> digestBytes,
    required String digestHex,
    required int now,
  }) async {
    final prior = await executor.query(
      'android_id_map',
      where: 'event_key = ?',
      whereArgs: <Object?>[eventKey],
      limit: 1,
    );
    if (prior.isNotEmpty) {
      return (
        prior.single['android_id']! as int,
        prior.single['android_tag']! as String,
      );
    }

    const mask = 0x3fffffff;
    const base = 0x40000000;
    final offset =
        ((digestBytes[0] << 22) |
            (digestBytes[1] << 14) |
            (digestBytes[2] << 6) |
            (digestBytes[3] >> 2)) &
        mask;
    final step =
        (((digestBytes[3] & 0x03) << 28) |
            (digestBytes[4] << 20) |
            (digestBytes[5] << 12) |
            (digestBytes[6] << 4) |
            (digestBytes[7] >> 4)) |
        1;
    final tag = 'hermes.event.$digestHex';
    for (var probe = 0; probe <= mask; probe++) {
      final androidId = base + ((offset + probe * step) & mask);
      try {
        await executor.insert('android_id_map', <String, Object?>{
          'event_key': eventKey,
          'android_id': androidId,
          'android_tag': tag,
          'allocated_at': now,
          'retain_until': now + mappingRetention.inMilliseconds,
        });
        return (androidId, tag);
      } on sqflite.DatabaseException catch (error) {
        if (!error.isUniqueConstraintError()) rethrow;
      }
    }
    throw StateError('Android notification ID range exhausted');
  }

  Future<DeliveryLease?> leaseNext() async {
    final leases = await leaseBatch(1);
    return leases.isEmpty ? null : leases.single;
  }

  Future<List<DeliveryLease>> leaseBatch(int limit) async {
    if (limit <= 0) throw ArgumentError.value(limit, 'limit');
    final now = _clock();
    final futureLimit = now + maximumFutureLease.inMilliseconds;
    return _exclusive((transaction) async {
      final leases = <DeliveryLease>[];
      while (leases.length < limit) {
        final rows = await transaction.rawQuery(
          '''
SELECT * FROM delivery_event
WHERE (status = 'pending' AND next_attempt_at <= ?)
   OR (status = 'leased' AND (lease_until <= ? OR lease_until > ?))
ORDER BY CASE status WHEN 'pending' THEN 0 ELSE 1 END,
         next_attempt_at, created_at, event_key
LIMIT 1
''',
          <Object?>[now, now, futureLimit],
        );
        if (rows.isEmpty) break;
        final eventKey = rows.single['event_key']! as String;
        final token = _tokenFactory();
        final leaseUntil = now + leaseDuration.inMilliseconds;
        final changed = await transaction.rawUpdate(
          '''
UPDATE delivery_event
SET status = 'leased', lease_token = ?, lease_until = ?,
    attempt_count = attempt_count + 1, updated_at = ?
WHERE event_key = ?
  AND ((status = 'pending' AND next_attempt_at <= ?)
    OR (status = 'leased' AND (lease_until <= ? OR lease_until > ?)))
''',
          <Object?>[token, leaseUntil, now, eventKey, now, now, futureLimit],
        );
        if (changed != 1) continue;
        final leased = await transaction.query(
          'delivery_event',
          where: 'event_key = ?',
          whereArgs: <Object?>[eventKey],
          limit: 1,
        );
        leases.add(
          DeliveryLease(
            event: DeliveryEventRecord.fromRow(leased.single),
            token: token,
          ),
        );
      }
      return leases;
    });
  }

  Future<int> reclaimExpiredLeases() async {
    final now = _clock();
    final futureLimit = now + maximumFutureLease.inMilliseconds;
    return _exclusive((transaction) async {
      return transaction.rawUpdate(
        '''
UPDATE delivery_event
SET status = 'pending', lease_token = NULL, lease_until = NULL,
    next_attempt_at = ?, updated_at = ?
WHERE status = 'leased' AND (lease_until <= ? OR lease_until > ?)
''',
        <Object?>[now, now, now, futureLimit],
      );
    });
  }

  Future<bool> renewLease(
    String eventKey,
    String token, {
    Duration? duration,
  }) async {
    final now = _clock();
    final futureLimit = now + maximumFutureLease.inMilliseconds;
    final requested = now + (duration ?? leaseDuration).inMilliseconds;
    final leaseUntil = requested.clamp(now + 1, futureLimit);
    return _exclusive((transaction) async {
      final changed = await transaction.rawUpdate(
        '''
UPDATE delivery_event
SET lease_until = ?, updated_at = ?
WHERE event_key = ? AND status = 'leased' AND lease_token = ?
  AND lease_until >= ? AND lease_until <= ?
''',
        <Object?>[leaseUntil, now, eventKey, token, now, futureLimit],
      );
      return changed == 1;
    });
  }

  Future<bool> markPresented(
    String eventKey,
    String token,
    String presentationSurface,
  ) async {
    if (!presentationSurfaces.contains(presentationSurface)) {
      throw ArgumentError.value(
        presentationSurface,
        'presentationSurface',
        'outside the closed surface vocabulary',
      );
    }
    final now = _clock();
    final futureLimit = now + maximumFutureLease.inMilliseconds;
    return _exclusive((transaction) async {
      final changed = await transaction.rawUpdate(
        '''
UPDATE delivery_event
SET status = 'presented', presented_at = ?, presentation_surface = ?,
    lease_token = NULL, lease_until = NULL, updated_at = ?,
    last_error_code = NULL
WHERE event_key = ? AND status = 'leased' AND lease_token = ?
  AND lease_until > ? AND lease_until <= ?
''',
        <Object?>[
          now,
          presentationSurface,
          now,
          eventKey,
          token,
          now,
          futureLimit,
        ],
      );
      return changed == 1;
    });
  }

  Future<bool> retry(
    String eventKey,
    String token, {
    required Duration delay,
    String? errorCode,
  }) async {
    if (errorCode != null && !_codePattern.hasMatch(errorCode)) {
      throw ArgumentError.value(errorCode, 'errorCode', 'not a machine code');
    }
    final now = _clock();
    final futureLimit = now + maximumFutureLease.inMilliseconds;
    return _exclusive((transaction) async {
      final changed = await transaction.rawUpdate(
        '''
UPDATE delivery_event
SET status = 'pending', next_attempt_at = ?, lease_token = NULL,
    lease_until = NULL, updated_at = ?, last_error_code = ?
WHERE event_key = ? AND status = 'leased' AND lease_token = ?
  AND lease_until > ? AND lease_until <= ?
''',
        <Object?>[
          now + delay.inMilliseconds,
          now,
          errorCode,
          eventKey,
          token,
          now,
          futureLimit,
        ],
      );
      return changed == 1;
    });
  }

  Future<bool> markCancelPending(String eventKey) async {
    final now = _clock();
    return _exclusive((transaction) async {
      final changed = await transaction.rawUpdate(
        '''
UPDATE delivery_event
SET status = 'cancel_pending', lease_token = NULL, lease_until = NULL,
    updated_at = ?
WHERE event_key = ? AND status IN ('pending', 'presented')
''',
        <Object?>[now, eventKey],
      );
      return changed == 1;
    });
  }

  Future<int> markApprovalsCancelPendingForRun({
    required String connId,
    required String profile,
    required String runId,
  }) async {
    final now = _clock();
    return _exclusive((transaction) async {
      return transaction.rawUpdate(
        '''
UPDATE delivery_event
SET status = 'cancel_pending', lease_token = NULL, lease_until = NULL,
    updated_at = ?
WHERE conn_id = ? AND profile = ? AND run_id = ?
  AND destination_kind = 'approval'
  AND status IN ('pending', 'presented')
''',
        <Object?>[now, connId, profile.trim().toLowerCase(), runId],
      );
    });
  }

  Future<bool> markCancelled(String eventKey) async {
    final now = _clock();
    return _exclusive((transaction) async {
      final changed = await transaction.rawUpdate(
        '''
UPDATE delivery_event
SET status = 'cancelled', cancelled_at = ?, updated_at = ?
WHERE event_key = ? AND status = 'cancel_pending'
''',
        <Object?>[now, now, eventKey],
      );
      return changed == 1;
    });
  }

  Future<bool> suppress(String eventKey) =>
      _markPendingOutcome(eventKey, DeliveryStatus.suppressed);

  Future<bool> expire(String eventKey) =>
      _markPendingOutcome(eventKey, DeliveryStatus.expired);

  Future<bool> _markPendingOutcome(
    String eventKey,
    DeliveryStatus outcome,
  ) async {
    final now = _clock();
    return _exclusive((transaction) async {
      final changed = await transaction.rawUpdate(
        '''
UPDATE delivery_event
SET status = ?, updated_at = ?
WHERE event_key = ? AND status = 'pending'
''',
        <Object?>[outcome.databaseValue, now, eventKey],
      );
      return changed == 1;
    });
  }

  Future<int> countActiveWork() =>
      _countWhere("status IN ('pending', 'leased', 'cancel_pending')");

  Future<int> countTombstones() => _countWhere(
    "status IN ('presented', 'cancelled', 'suppressed', 'expired')",
  );

  Future<int> _countWhere(String clause) async {
    return sqflite.Sqflite.firstIntValue(
      await _db.rawQuery('SELECT COUNT(*) FROM delivery_event WHERE $clause'),
    )!;
  }

  Future<int> androidMappingCount() async {
    return sqflite.Sqflite.firstIntValue(
      await _db.rawQuery('SELECT COUNT(*) FROM android_id_map'),
    )!;
  }

  Future<int> pruneRetention({
    required Duration maxAge,
    required int maxTombstones,
  }) async {
    if (maxTombstones < 0) {
      throw ArgumentError.value(maxTombstones, 'maxTombstones');
    }
    final now = _clock();
    final cutoff = now - maxAge.inMilliseconds;
    return _exclusive((transaction) async {
      var deleted = await transaction.rawDelete(
        '''
DELETE FROM delivery_event
WHERE status IN ('presented', 'cancelled', 'suppressed', 'expired')
  AND updated_at < ?
''',
        <Object?>[cutoff],
      );
      final overflow = await transaction.rawQuery(
        '''
SELECT event_key FROM delivery_event
WHERE status IN ('presented', 'cancelled', 'suppressed', 'expired')
ORDER BY updated_at DESC, event_key DESC
LIMIT -1 OFFSET ?
''',
        <Object?>[maxTombstones],
      );
      for (final row in overflow) {
        deleted += await transaction.delete(
          'delivery_event',
          where: 'event_key = ?',
          whereArgs: <Object?>[row['event_key']],
        );
      }

      await transaction.rawDelete(
        '''
DELETE FROM android_id_map
WHERE retain_until <= ?
  AND NOT EXISTS (
    SELECT 1 FROM delivery_event
    WHERE delivery_event.event_key = android_id_map.event_key
  )
''',
        <Object?>[now],
      );
      final mappingOverflow = await transaction.rawQuery(
        '''
SELECT event_key FROM android_id_map
WHERE retain_until <= ?
  AND NOT EXISTS (
    SELECT 1 FROM delivery_event
    WHERE delivery_event.event_key = android_id_map.event_key
  )
ORDER BY allocated_at DESC, event_key DESC
LIMIT -1 OFFSET ?
''',
        <Object?>[now, maxTombstones],
      );
      for (final row in mappingOverflow) {
        await transaction.delete(
          'android_id_map',
          where: 'event_key = ?',
          whereArgs: <Object?>[row['event_key']],
        );
      }
      return deleted;
    });
  }

  Future<DeliveryEventRecord?> eventByKey(String eventKey) async {
    final rows = await _db.query(
      'delivery_event',
      where: 'event_key = ?',
      whereArgs: <Object?>[eventKey],
      limit: 1,
    );
    return rows.isEmpty ? null : DeliveryEventRecord.fromRow(rows.single);
  }

  Future<List<DeliveryEventRecord>> allEvents() async {
    final rows = await _db.query(
      'delivery_event',
      orderBy: 'created_at, event_key',
    );
    return rows.map(DeliveryEventRecord.fromRow).toList();
  }

  Future<int> eventCount() async {
    return sqflite.Sqflite.firstIntValue(
      await _db.rawQuery('SELECT COUNT(*) FROM delivery_event'),
    )!;
  }

  Future<int?> sourceCursorGeneration(String scopeKey) async {
    final rows = await _db.query(
      'source_cursor',
      columns: const <String>['generation'],
      where: 'scope_key = ?',
      whereArgs: <Object?>[scopeKey],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['generation']! as int;
  }

  Future<int> countByStatus(DeliveryStatus status) async {
    return sqflite.Sqflite.firstIntValue(
      await _db.rawQuery(
        'SELECT COUNT(*) FROM delivery_event WHERE status = ?',
        <Object?>[status.databaseValue],
      ),
    )!;
  }

  static String _hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  Future<int> schemaVersion() async {
    final rows = await _db.query(
      'delivery_meta',
      columns: const <String>['value'],
      where: 'key = ?',
      whereArgs: const <Object?>['schema_version'],
      limit: 1,
    );
    return int.parse(rows.single['value']! as String);
  }

  Future<List<String>> tableNames() async {
    final rows = await _db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
    );
    return rows.map((row) => row['name']! as String).toList();
  }

  Future<List<String>> tableColumns(String table) async {
    const allowed = <String>{
      'delivery_event',
      'source_cursor',
      'android_id_map',
      'delivery_meta',
    };
    if (!allowed.contains(table)) throw ArgumentError.value(table, 'table');
    final rows = await _db.rawQuery('PRAGMA table_info($table)');
    return rows.map((row) => row['name']! as String).toList();
  }

  Future<Object?> pragmaValue(String name) async {
    const allowed = <String>{
      'foreign_keys',
      'synchronous',
      'busy_timeout',
      'journal_mode',
    };
    if (!allowed.contains(name)) throw ArgumentError.value(name, 'name');
    final rows = await _db.rawQuery('PRAGMA $name');
    return rows.single.values.first;
  }

  Future<void> close() async {
    return _lifecycleLock.withLock(() async {
      final database = _database;
      if (database == null) return;
      await database.close();
      _database = null;
    });
  }
}
