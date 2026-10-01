import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import '../models/capability_matrix.dart';
import '../models/connection.dart';
import '../models/prepared_turn.dart';
import '../utils/transport_privacy.dart';
import 'app_error_log.dart';
import 'connection_diagnostics.dart';
import 'turn_outbox_store.dart';

enum DiagnosticFlavor { qa, full, play, unknown }

enum DiagnosticFormFactor { phone, tablet }

enum DiagnosticTransportClass { https, privateHttp, publicHttp }

enum DiagnosticComponent {
  gateway,
  dashboard,
  bridge,
  websocket,
  outbox,
  cache,
  // Uncaught errors from the local AppErrorLog, by where they surfaced.
  flutter,
  platform,
}

enum DiagnosticCode {
  ok,
  authRequired,
  notFound,
  timeout,
  dns,
  tls,
  refused,
  httpError,
  error,
  unknown,
}

enum DiagnosticCacheKind { sentImages, attachments }

class DiagnosticHealthSample {
  final DiagnosticComponent component;
  final DiagnosticCode code;
  final int? latencyMs;

  const DiagnosticHealthSample({
    required this.component,
    required this.code,
    this.latencyMs,
  });

  factory DiagnosticHealthSample.fromProbe({
    required DiagnosticComponent component,
    required ProbeResult result,
  }) => DiagnosticHealthSample(
    component: component,
    code: switch (result.status) {
      ProbeStatus.ok => DiagnosticCode.ok,
      ProbeStatus.authInvalid ||
      ProbeStatus.authRequired => DiagnosticCode.authRequired,
      ProbeStatus.notFound ||
      ProbeStatus.methodNotAllowed => DiagnosticCode.notFound,
      ProbeStatus.timeout => DiagnosticCode.timeout,
      ProbeStatus.dnsError => DiagnosticCode.dns,
      ProbeStatus.tlsError => DiagnosticCode.tls,
      ProbeStatus.refused => DiagnosticCode.refused,
      ProbeStatus.httpError => DiagnosticCode.httpError,
      ProbeStatus.error => DiagnosticCode.error,
      ProbeStatus.skipped => DiagnosticCode.unknown,
    },
    latencyMs: result.latencyMs,
  );

  Map<String, dynamic> toJson() => {
    'component': component.name,
    'code': code.name,
    if (latencyMs != null) 'latencyBucket': _latencyBucket(latencyMs!),
  };
}

class DiagnosticConnectionSnapshot {
  final int ordinal;
  final DiagnosticTransportClass transportClass;
  final bool desktopWs;
  final bool turnIdempotencyV1;
  final List<DiagnosticHealthSample> health;

  const DiagnosticConnectionSnapshot({
    required this.ordinal,
    required this.transportClass,
    required this.desktopWs,
    required this.turnIdempotencyV1,
    this.health = const [],
  });

  factory DiagnosticConnectionSnapshot.fromConnection({
    required int ordinal,
    required SavedConnection connection,
    required CapabilityMatrix matrix,
    List<DiagnosticHealthSample> health = const [],
  }) {
    final privacy = TransportPrivacy.classify(connection.gatewayUrl);
    final transportClass = switch (privacy) {
      TransportPrivacyClass.secure => DiagnosticTransportClass.https,
      TransportPrivacyClass.privateCleartext =>
        DiagnosticTransportClass.privateHttp,
      TransportPrivacyClass.publicCleartext =>
        DiagnosticTransportClass.publicHttp,
    };
    return DiagnosticConnectionSnapshot(
      ordinal: max(1, ordinal),
      transportClass: transportClass,
      desktopWs: matrix.chatSupported.isYes,
      turnIdempotencyV1: matrix.turnIdempotency.isYes,
      health: health.take(16).toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => {
    'ordinal': ordinal,
    'transportClass': transportClass.name,
    'capabilities': {
      'desktopWs': desktopWs,
      'turnIdempotencyV1': turnIdempotencyV1,
    },
    'health': health.map((item) => item.toJson()).toList(),
  };
}

class DiagnosticTurnsSnapshot {
  final Map<PreparedTurnState, int> counts;
  final String oldestPendingAge;

  const DiagnosticTurnsSnapshot({
    this.counts = const {},
    this.oldestPendingAge = 'none',
  });

  factory DiagnosticTurnsSnapshot.fromPreparedTurns(
    Iterable<PreparedTurn> turns, {
    required DateTime now,
  }) {
    final counts = <PreparedTurnState, int>{};
    int? oldestMs;
    for (final turn in turns) {
      counts.update(turn.state, (value) => value + 1, ifAbsent: () => 1);
      if (turn.state != PreparedTurnState.terminal) {
        oldestMs = oldestMs == null
            ? turn.updatedAtMs
            : min(oldestMs, turn.updatedAtMs);
      }
    }
    final age = oldestMs == null
        ? Duration.zero
        : now.difference(DateTime.fromMillisecondsSinceEpoch(oldestMs));
    return DiagnosticTurnsSnapshot(
      counts: Map.unmodifiable(counts),
      oldestPendingAge: oldestMs == null ? 'none' : _ageBucket(age),
    );
  }

  factory DiagnosticTurnsSnapshot.fromOutboxSummary(
    TurnOutboxDiagnosticSummary summary, {
    required DateTime now,
  }) {
    final oldest = summary.oldestPendingUpdatedAtMs;
    return DiagnosticTurnsSnapshot(
      counts: summary.counts,
      oldestPendingAge: oldest == null
          ? 'none'
          : _ageBucket(
              now.difference(DateTime.fromMillisecondsSinceEpoch(oldest)),
            ),
    );
  }

  Map<String, dynamic> toJson() => {
    for (final state in PreparedTurnState.values)
      state.name: counts[state] ?? 0,
    'oldestPendingAge': oldestPendingAge,
  };
}

class DiagnosticCacheSnapshot {
  final int entries;
  final int sizeBytes;

  const DiagnosticCacheSnapshot({
    required this.entries,
    required this.sizeBytes,
  });

  static Future<DiagnosticCacheSnapshot> fromDirectory(
    Directory directory,
  ) async {
    if (!await directory.exists()) {
      return const DiagnosticCacheSnapshot(entries: 0, sizeBytes: 0);
    }
    var entries = 0;
    var bytes = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        entries++;
        bytes += await entity.length();
      } catch (_) {
        // Una carrera de borrado solo omite esa entrada; nunca expone su ruta.
      }
    }
    return DiagnosticCacheSnapshot(entries: entries, sizeBytes: bytes);
  }

  Map<String, dynamic> toJson() => {
    'entries': max(0, entries),
    'sizeBucket': _sizeBucket(sizeBytes),
  };
}

class DiagnosticErrorEvent {
  final DiagnosticComponent component;
  final DiagnosticCode code;
  final DateTime occurredAt;

  /// Runtime type of an uncaught error (never its message or stack).
  final String? errorType;

  const DiagnosticErrorEvent({
    required this.component,
    required this.code,
    required this.occurredAt,
    this.errorType,
  });

  /// Maps one local [AppErrorRecord]: origin, error type and time only.
  factory DiagnosticErrorEvent.fromAppError(AppErrorRecord record) =>
      DiagnosticErrorEvent(
        component: record.source == 'flutter'
            ? DiagnosticComponent.flutter
            : DiagnosticComponent.platform,
        code: DiagnosticCode.error,
        occurredAt: record.at,
        errorType: _safeTypeName(record.errorType),
      );

  Map<String, dynamic> toJson() => {
    'component': component.name,
    'code': code.name,
    'occurredAt': occurredAt.toUtc().toIso8601String(),
    'errorType': ?errorType,
  };
}

/// A type name is code, not user data; still keep only identifier-like
/// characters and a bounded length so nothing unexpected can ride along.
String _safeTypeName(String value) {
  final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9_<>, ]'), '');
  if (cleaned.isEmpty) return 'unknown';
  return cleaned.length <= 80 ? cleaned : cleaned.substring(0, 80);
}

class DiagnosticBundleInput {
  final String appVersion;
  final int buildNumber;
  final DiagnosticFlavor flavor;
  final int androidApi;
  final DiagnosticFormFactor formFactor;
  final List<DiagnosticConnectionSnapshot> connections;
  final DiagnosticTurnsSnapshot turns;
  final Map<DiagnosticCacheKind, DiagnosticCacheSnapshot> caches;
  final List<DiagnosticErrorEvent> recentErrors;

  const DiagnosticBundleInput({
    required this.appVersion,
    required this.buildNumber,
    required this.flavor,
    required this.androidApi,
    required this.formFactor,
    this.connections = const [],
    this.turns = const DiagnosticTurnsSnapshot(),
    this.caches = const {},
    this.recentErrors = const [],
  });
}

class DiagnosticBundle {
  final Map<String, dynamic> _json;
  final String preview;

  const DiagnosticBundle._(this._json, this.preview);

  Map<String, dynamic> toJson() => Map.unmodifiable(_json);
}

class DiagnosticBundleService {
  static const schemaVersion = 1;
  static const maxBytes = 256 * 1024;
  static const retention = Duration(hours: 24);
  static const _filePrefix = 'hermes-diagnostic-';

  final Future<Directory> Function() _cacheDirectory;
  final DateTime Function() _now;
  final String Function() _randomToken;

  DiagnosticBundleService({
    Future<Directory> Function()? cacheDirectory,
    DateTime Function()? now,
    String Function()? randomToken,
  }) : _cacheDirectory = cacheDirectory ?? _defaultCacheDirectory,
       _now = now ?? DateTime.now,
       _randomToken = randomToken ?? _secureRandomToken;

  DiagnosticBundle build(DiagnosticBundleInput input) {
    final errors = input.recentErrors.toList()
      ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    final connections = input.connections.take(64).toList(growable: false);
    Map<String, dynamic> json;
    String preview;
    do {
      json = _buildJson(input, connections, errors);
      preview = jsonEncode(json);
      if (utf8.encode(preview).length <= maxBytes) break;
      if (errors.isNotEmpty) {
        // Retira primero la mitad más antigua. Evita un bucle cuadrático si
        // una fuente trae decenas de miles de eventos, manteniendo siempre los
        // más recientes y un JSON completo (nunca bytes truncados).
        final removeCount = max(1, errors.length ~/ 2);
        errors.removeRange(errors.length - removeCount, errors.length);
        continue;
      }
      throw const FormatException('Diagnostic bundle exceeds size limit');
    } while (true);
    return DiagnosticBundle._(json, preview);
  }

  Map<String, dynamic> _buildJson(
    DiagnosticBundleInput input,
    List<DiagnosticConnectionSnapshot> connections,
    List<DiagnosticErrorEvent> errors,
  ) => {
    'schemaVersion': schemaVersion,
    'generatedAt': _now().toUtc().toIso8601String(),
    'app': {
      'version': _safeVersion(input.appVersion),
      'build': max(0, input.buildNumber),
      'flavor': input.flavor.name,
    },
    'device': {
      'androidApi': input.androidApi.clamp(0, 999),
      'formFactor': input.formFactor.name,
    },
    'connections': connections.map((item) => item.toJson()).toList(),
    'turns': input.turns.toJson(),
    'caches': {
      for (final entry in input.caches.entries)
        entry.key.name: entry.value.toJson(),
    },
    'recentErrors': errors.map((item) => item.toJson()).toList(),
  };

  Future<File> write(DiagnosticBundle bundle) async {
    final bytes = utf8.encode(bundle.preview);
    if (bytes.length > maxBytes) {
      throw const FormatException('Diagnostic bundle exceeds size limit');
    }
    await cleanupExpired();
    final directory = await _cacheDirectory();
    await directory.create(recursive: true);
    final token = _safeFileToken(_randomToken());
    final file = File(
      '${directory.path}${Platform.pathSeparator}$_filePrefix$token.json',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<int> cleanupExpired() async {
    final directory = await _cacheDirectory();
    if (!await directory.exists()) return 0;
    var removed = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.startsWith(_filePrefix) || !name.endsWith('.json')) continue;
      try {
        final stat = await entity.stat();
        if (_now().difference(stat.modified) > retention) {
          await entity.delete();
          removed++;
        }
      } catch (_) {
        // Best-effort local cleanup. Nunca amplía el alcance fuera del prefijo.
      }
    }
    return removed;
  }

  Future<void> delete(File file) async {
    final directory = await _cacheDirectory();
    final prefix = '${directory.absolute.path}${Platform.pathSeparator}';
    final path = file.absolute.path;
    if (!path.startsWith(prefix)) return;
    final name = file.uri.pathSegments.last;
    if (!name.startsWith(_filePrefix) || !name.endsWith('.json')) return;
    if (await file.exists()) await file.delete();
  }

  static Future<Directory> _defaultCacheDirectory() async {
    final base = await getTemporaryDirectory();
    return Directory('${base.path}${Platform.pathSeparator}hermes-diagnostics');
  }

  static String _secureRandomToken() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static String _safeFileToken(String value) {
    final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    return safe.isEmpty
        ? _secureRandomToken()
        : safe.substring(0, min(64, safe.length));
  }
}

String _safeVersion(String value) {
  final trimmed = value.trim();
  return RegExp(r'^\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9.-]+)?$').hasMatch(trimmed)
      ? trimmed
      : 'unknown';
}

String _latencyBucket(int value) => switch (max(0, value)) {
  < 250 => 'lt250ms',
  < 1000 => 'lt1s',
  < 5000 => 'lt5s',
  _ => 'gte5s',
};

String _ageBucket(Duration value) => switch (value) {
  final age when age < const Duration(days: 1) => 'lt1d',
  final age when age < const Duration(days: 7) => 'lt7d',
  final age when age < const Duration(days: 30) => 'lt30d',
  _ => 'gte30d',
};

String _sizeBucket(int value) => switch (max(0, value)) {
  < 1024 * 1024 => 'lt1mb',
  < 10 * 1024 * 1024 => 'lt10mb',
  < 50 * 1024 * 1024 => 'lt50mb',
  _ => 'gte50mb',
};
