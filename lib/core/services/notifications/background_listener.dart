// Servicio en primer plano (foreground service) que mantiene a Hermes Console
// "escuchando" eventos del agente AUNQUE la app esté cerrada — sin FCM/Google.
//
// Cómo funciona: un isolate del servicio (independiente de la UI) sondea por
// REST el estado de las ejecuciones (/v1/runs/{id}) que la app está vigilando y
// dispara notificaciones locales cuando terminan o piden aprobación. El token
// del gateway se lee del Keystore (flutter_secure_storage), nunca se guarda en
// claro. Sigue vivo aunque deslices la app fuera de recientes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

import '../../models/kanban.dart';
import '../../utils/home_recent_sessions.dart';
import '../connection_manager.dart';
import '../secure_storage.dart';
import '../../utils/transport_privacy.dart';
import 'notification_delivery_store.dart';
import 'notification_service.dart';
import 'notification_strings.dart';
import 'voice_notification_card_adapter.dart';

/// La notificación de automatización/audio pertenece al servicio Flutter
/// compartido. La UI del listener solo puede declararlo activo cuando además
/// existe consentimiento durable; Voz, Read Aloud o el dataSync nativo de
/// SSH/SFTP por sí solos no encienden ese indicador.
bool backgroundAutomationRunningForUi({
  required bool serviceRunning,
  required bool automationOptIn,
}) => serviceRunning && automationOptIn;

@visibleForTesting
bool backgroundRuntimeMayAutoStopForTest({
  required bool automationOptIn,
  required bool audioCardActive,
  required int externalDataSyncDemand,
  required int emptyPolls,
  required int uiHeartbeatStaleMs,
}) =>
    !automationOptIn &&
    !audioCardActive &&
    externalDataSyncDemand <= 0 &&
    emptyPolls >= 2 &&
    uiHeartbeatStaleMs >= const Duration(minutes: 3).inMilliseconds;

/// Reduce la demanda conjunta de SSH/SFTP a una única transición booleana.
/// Los callbacks de ambos servicios son señales de que el estado cambió, no
/// leases contables: un fallo o un cierre duplicado nunca puede liberar la
/// demanda que todavía conserva el otro propietario.
class ExternalDataSyncDemandGate {
  ExternalDataSyncDemandGate(this._onChanged);

  final FutureOr<bool> Function(bool required) _onChanged;
  Future<void> _tail = Future<void>.value();
  bool _required = false;

  bool get required => _required;

  Future<bool> reconcile({required bool sftpActive, required bool sshActive}) {
    return _enqueue(sftpActive || sshActive, force: false);
  }

  /// Confirma contra el servicio real que el lease externo ya se liberó.
  ///
  /// Es deliberadamente forzado: tras recrear el proceso, [_required] empieza
  /// en false aunque Android aún pueda conservar una orden Stop durable. El ACK
  /// de esa orden no es seguro hasta aplicar de nuevo la liberación nativa.
  Future<bool> confirmReleased() => _enqueue(false, force: true);

  Future<bool> _enqueue(bool next, {required bool force}) {
    final result = _tail.then((_) async {
      if (!force && next == _required) return true;
      var applied = false;
      try {
        applied = await _onChanged(next);
      } on Object {
        applied = false;
      }
      // La transición solo queda confirmada después de adquirir/liberar el
      // servicio real. Si falla, el siguiente callback del mismo owner vuelve
      // a intentarla en vez de quedar atrapado en un true local ficticio.
      if (applied) _required = next;
      return applied;
    });
    _tail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }
}

/// Serializa las mutaciones del servicio Flutter y el arbitraje del dataSync
/// nativo. Es reentrante dentro de la misma operación para que una
/// reconciliación de red pueda reconstruir Voz/Read Aloud sin interbloquearse.
class ForegroundMutationSerializer {
  final Object _zoneKey = Object();
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() operation) {
    if (identical(Zone.current[_zoneKey], this)) return operation();
    final result = _tail.then(
      (_) =>
          runZoned(operation, zoneValues: <Object?, Object?>{_zoneKey: this}),
    );
    _tail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }
}

/// Valla síncrona del isolate del TaskHandler. La acción Stop puede llegar
/// mientras `_poll` espera red; desde ese instante ningún callback tardío debe
/// volver a escribir API_UPDATE en el estado global del plugin.
class ForegroundTaskStopFence {
  bool _requested = false;

  bool get allowsUpdate => !_requested;

  void requestStop() {
    _requested = true;
  }
}

/// Una ejecución vigilada en segundo plano. Sin secretos: el token se resuelve
/// desde el Keystore por [connId].
class WatchedRun {
  final String connId;
  final String profile;
  final String base; // baseUrl del gateway (http(s)://host:port)
  final String runId;
  final String prompt;
  // Sesión asociada (para que la notificación navegue al chat al pulsarla).
  // Vacío en runs sueltas sin sesión.
  final String sessionId;
  final bool approvalNotified;
  final String? approvalRequestId;

  const WatchedRun({
    required this.connId,
    this.profile = 'default',
    required this.base,
    required this.runId,
    required this.prompt,
    this.sessionId = '',
    bool approvalNotified = false,
    this.approvalRequestId,
  }) : approvalNotified = approvalNotified || approvalRequestId != null;

  Map<String, dynamic> toJson() => {
    'connId': connId,
    'profile': profile,
    'base': base,
    'runId': runId,

    if (sessionId.isNotEmpty) 'sessionId': sessionId,
    'approvalNotified': approvalNotified,
    if (approvalRequestId != null && approvalRequestId!.isNotEmpty)
      'approvalRequestId': approvalRequestId,
  };

  static WatchedRun fromJson(Map<String, dynamic> j) {
    final rawRequestId = j['approvalRequestId'];
    final requestId = rawRequestId is String && rawRequestId.trim().isNotEmpty
        ? rawRequestId.trim()
        : null;
    return WatchedRun(
      connId: j['connId']?.toString() ?? '',
      profile: _normalizeRunOwnerProfile(j['profile']?.toString() ?? ''),
      base: j['base']?.toString() ?? '',
      runId: j['runId']?.toString() ?? '',
      // Historical prompt values are deliberately discarded during migration.
      prompt: '',
      sessionId: j['sessionId']?.toString() ?? '',
      approvalNotified: j['approvalNotified'] == true,
      approvalRequestId: requestId,
    );
  }

  WatchedRun copyWith({
    bool? approvalNotified,
    String? approvalRequestId,
    bool clearApproval = false,
  }) => WatchedRun(
    connId: connId,
    profile: profile,
    base: base,
    runId: runId,
    prompt: prompt,
    sessionId: sessionId,
    approvalNotified: clearApproval
        ? false
        : (approvalNotified ?? this.approvalNotified),
    approvalRequestId: clearApproval
        ? null
        : (approvalRequestId ?? this.approvalRequestId),
  );

  ({String connId, String profile, String runId}) get notificationOwner =>
      _watchedRunOwner(this);
}

/// Lista de runs vigiladas, persistida en SharedPreferences (sin secretos).
/// Compartida entre el isolate de UI (que añade/quita) y el del servicio.
@visibleForTesting
class BackgroundWatchTransactionMutex {
  BackgroundWatchTransactionMutex(
    this.databasePath, {
    this.databaseFactory,
    this.retryDelay = const Duration(milliseconds: 20),
    this.busyTimeout = const Duration(milliseconds: 250),
  });

  final String databasePath;
  final sqflite.DatabaseFactory? databaseFactory;
  final Duration retryDelay;
  final Duration busyTimeout;

  /// SQLite es la autoridad de exclusión entre engines, isolates y procesos.
  /// `BEGIN EXCLUSIVE` se adquiere de forma atómica y el SO revierte/libera la
  /// transacción si muere el propietario; no hay lease temporal que otro
  /// participante pueda robar ni archivo huérfano que tenga que borrar.
  Future<T> protect<T>(Future<T> Function() action) async {
    final factory = databaseFactory ?? sqflite.databaseFactory;
    final database = await factory.openDatabase(
      databasePath,
      options: sqflite.OpenDatabaseOptions(
        singleInstance: false,
        onConfigure: (database) => database.rawQuery(
          'PRAGMA busy_timeout = ${busyTimeout.inMilliseconds}',
        ),
      ),
    );
    try {
      while (true) {
        try {
          return await database.transaction<T>(
            (_) => action(),
            exclusive: true,
          );
        } on sqflite.DatabaseException catch (error) {
          final primaryCode = (error.getResultCode() ?? -1) & 0xff;
          if (primaryCode != 5 && primaryCode != 6) rethrow;
          await Future<void>.delayed(retryDelay);
        }
      }
    } finally {
      await database.close();
    }
  }
}

Future<String> _resolveBackgroundWatchMutexDatabasePath(
  Future<String> Function() getDatabasesPath,
) async {
  final directory = await getDatabasesPath();
  if (directory.trim().isEmpty) {
    throw StateError('SQLite database path unavailable');
  }
  final separator = directory.endsWith('/') ? '' : '/';
  return '$directory${separator}background_watch_mutex_v1.db';
}

@visibleForTesting
Future<String> resolveBackgroundWatchMutexDatabasePathForTest(
  Future<String> Function() getDatabasesPath,
) => _resolveBackgroundWatchMutexDatabasePath(getDatabasesPath);

class BackgroundWatch {
  static const String _key = 'bg_watch_runs';
  static final ForegroundMutationSerializer _isolateSerializer =
      ForegroundMutationSerializer();

  /// SharedPreferences no ofrece transacciones entre isolates. Una transacción
  /// SQLite dedicada serializa únicamente las secciones read-modify-write;
  /// nunca se mantiene durante una petición de red.
  static Future<T> _locked<T>(
    Future<T> Function(SharedPreferences prefs) action,
  ) => _isolateSerializer.run(() async {
    final databaseFactory = sqflite.databaseFactory;
    final databasePath = await _resolveBackgroundWatchMutexDatabasePath(
      databaseFactory.getDatabasesPath,
    );
    final mutex = BackgroundWatchTransactionMutex(
      databasePath,
      databaseFactory: databaseFactory,
    );
    return mutex.protect(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return await action(prefs);
    });
  });

  static List<WatchedRun> _read(SharedPreferences prefs) {
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list.map(WatchedRun.fromJson).toList();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[hermes-notif] watch inválido (${error.runtimeType})');
      }
      return [];
    }
  }

  static Future<void> _write(
    SharedPreferences prefs,
    List<WatchedRun> runs,
  ) async {
    await prefs.setString(
      _key,
      jsonEncode(runs.map((r) => r.toJson()).toList()),
    );
  }

  /// Empieza a vigilar una ejecución (idempotente por dueño exacto).
  static Future<void> add(SavedRunWatch w) async {
    final safeBase = TransportPrivacy.requireAllowed(w.base);
    if (!NotificationService.automationNotificationsEnabled) return;
    final profile = _normalizeRunOwnerProfile(w.profile);
    await _locked((prefs) async {
      final runs = _read(prefs)
        ..removeWhere(
          (r) =>
              r.connId == w.connId &&
              r.profile == profile &&
              r.runId == w.runId,
        );
      runs.add(
        WatchedRun(
          connId: w.connId,
          profile: profile,
          base: safeBase,
          runId: w.runId,
          // Presentation text never crosses the durable watch boundary.
          prompt: '',
          sessionId: w.sessionId,
        ),
      );
      // Cota de seguridad: no acumular indefinidamente.
      while (runs.length > 20) {
        runs.removeAt(0);
      }
      await _write(prefs, runs);
    });
  }

  static Future<void> remove(
    String runId, {
    required String connId,
    String profile = 'default',
  }) async {
    final ownerProfile = _normalizeRunOwnerProfile(profile);
    await _locked((prefs) async {
      final runs = _read(prefs)
        ..removeWhere(
          (r) =>
              r.connId == connId &&
              r.profile == ownerProfile &&
              r.runId == runId,
        );
      await _write(prefs, runs);
    });
  }

  static Future<void> clearAll() => _locked((prefs) async {
    await prefs.remove(_key);
  });

  static Future<List<WatchedRun>> snapshot() =>
      _locked((prefs) async => _read(prefs));

  /// Aplica el resultado de un sondeo sobre la lista más reciente. Los runs
  /// añadidos por la UI mientras había HTTP en curso no estaban en [snapshot]
  /// y se conservan; los eliminados por la UI tampoco resucitan.
  static Future<List<WatchedRun>> mergePollResults({
    required List<WatchedRun> snapshot,
    required List<WatchedRun> keep,
  }) => _locked((prefs) async {
    final latest = _read(prefs);
    final polledOwners = snapshot.map(_watchedRunOwner).toSet();
    final keptByOwner = {for (final run in keep) _watchedRunOwner(run): run};
    final merged = <WatchedRun>[];
    for (final current in latest) {
      final owner = _watchedRunOwner(current);
      if (!polledOwners.contains(owner)) {
        merged.add(current);
        continue;
      }
      final updated = keptByOwner[owner];
      if (updated != null) merged.add(updated);
    }
    await _write(prefs, merged);
    return merged;
  });

  @visibleForTesting
  static List<WatchedRun> mergeForTest({
    required List<WatchedRun> latest,
    required List<WatchedRun> snapshot,
    required List<WatchedRun> keep,
  }) {
    final polledOwners = snapshot.map(_watchedRunOwner).toSet();
    final keptByOwner = {for (final run in keep) _watchedRunOwner(run): run};
    final merged = <WatchedRun>[];
    for (final current in latest) {
      final owner = _watchedRunOwner(current);
      if (!polledOwners.contains(owner)) {
        merged.add(current);
        continue;
      }
      final updated = keptByOwner[owner];
      if (updated != null) merged.add(updated);
    }
    return merged;
  }
}

/// Datos mínimos para vigilar una run (los pasa el isolate de UI).
class SavedRunWatch {
  final String connId;
  final String profile;
  final String base;
  final String runId;
  final String prompt;
  final String sessionId;
  const SavedRunWatch({
    required this.connId,
    this.profile = 'default',
    required this.base,
    required this.runId,
    required this.prompt,
    this.sessionId = '',
  });
}

String _normalizeRunOwnerProfile(String value) {
  final normalized = value.trim().toLowerCase();
  return normalized.isEmpty ? 'default' : normalized;
}

({String connId, String profile, String runId}) _watchedRunOwner(
  WatchedRun run,
) => (
  connId: run.connId,
  profile: _normalizeRunOwnerProfile(run.profile),
  runId: run.runId,
);

class CronExecutionSnapshot {
  final String jobKey;
  final String jobId;
  final String title;
  final String profile;
  final String executionId;
  final String status;
  final bool syntheticExecutionId;
  final bool sessionAuthority;

  const CronExecutionSnapshot({
    required this.jobKey,
    required this.jobId,
    required this.title,
    required this.profile,
    required this.executionId,
    required this.status,
    this.syntheticExecutionId = false,
    this.sessionAuthority = false,
  });

  bool get terminal =>
      const {'completed', 'failed', 'unknown'}.contains(status);
  bool get ok => status == 'completed';

  Map<String, dynamic> toJson() => {
    'jobKey': jobKey,
    'jobId': jobId,
    'title': title,
    'profile': profile,
    'executionId': executionId,
    'status': status,
    'syntheticExecutionId': syntheticExecutionId,
    'sessionAuthority': sessionAuthority,
  };

  static CronExecutionSnapshot? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = value.cast<Object?, Object?>();
    final jobKey = (json['jobKey'] ?? '').toString().trim();
    final jobId = (json['jobId'] ?? '').toString().trim();
    final executionId = (json['executionId'] ?? '').toString().trim();
    final status = (json['status'] ?? '').toString().trim().toLowerCase();
    if (jobKey.isEmpty ||
        jobId.isEmpty ||
        executionId.isEmpty ||
        status.isEmpty) {
      return null;
    }
    final title = (json['title'] ?? '').toString().trim();
    return CronExecutionSnapshot(
      jobKey: jobKey,
      jobId: jobId,
      title: title.isEmpty ? jobId : title,
      profile: (json['profile'] ?? '').toString().trim(),
      executionId: executionId,
      status: status,
      syntheticExecutionId: json['syntheticExecutionId'] == true,
      sessionAuthority: json['sessionAuthority'] == true,
    );
  }

  static CronExecutionSnapshot? fromJob(Object? value) {
    if (value is! Map) return null;
    final job = value.cast<Object?, Object?>();
    final latestValue = job['latest_execution'];
    final latest = latestValue is Map
        ? latestValue.cast<Object?, Object?>()
        : const <Object?, Object?>{};
    final jobId = (job['id'] ?? job['job_id'] ?? '').toString().trim();
    final profile = (job['profile'] ?? '').toString().trim();
    final rawStatus = (latest['status'] ?? job['last_status'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final status = switch (rawStatus) {
      'ok' || 'success' || 'completed' => 'completed',
      'error' || 'failure' || 'failed' => 'failed',
      'running' || 'started' || 'queued' => rawStatus,
      'unknown' => 'unknown',
      _ => '',
    };
    var executionId = (latest['id'] ?? '').toString().trim();
    final syntheticExecutionId = executionId.isEmpty;
    if (executionId.isEmpty) {
      final lastRunAt = (job['last_run_at'] ?? '').toString().trim();
      if (jobId.isEmpty || lastRunAt.isEmpty || status.isEmpty) return null;
      executionId = sha256
          .convert(utf8.encode('$jobId|$lastRunAt|$status'))
          .toString();
    }
    if (jobId.isEmpty || executionId.isEmpty || status.isEmpty) return null;
    final name = (job['name'] ?? '').toString().trim();
    return CronExecutionSnapshot(
      jobKey: '${profile.isEmpty ? 'default' : profile}::$jobId',
      jobId: jobId,
      title: name.isEmpty ? jobId : name,
      profile: profile,
      executionId: executionId,
      status: status,
      syntheticExecutionId: syntheticExecutionId,
    );
  }
}

/// Instancias cuyos resultados Cron puede descubrir el servicio aunque el run
/// no haya sido iniciado desde Android. Solo persiste metadatos de conexión y
/// cursores de ejecución; las credenciales siguen resolviéndose desde Keystore.
class BackgroundCronWatch {
  static const String _targetsKey = 'bg_cron_targets_v1';
  static const String _targetsRevisionKey = 'bg_cron_targets_revision_v1';
  static const int _maxJobsPerConnection = 200;

  static String discoveryScopeKey({
    required String connId,
    required String profile,
    required bool syntheticExecutionId,
    bool sessionAuthority = false,
  }) =>
      '$connId/$profile/cron/${sessionAuthority
          ? 'sessions'
          : syntheticExecutionId
          ? 'legacy'
          : 'discovery'}';

  static String discoveryObjectId(
    bool syntheticExecutionId, {
    bool sessionAuthority = false,
  }) => sessionAuthority
      ? 'session_discovery'
      : syntheticExecutionId
      ? 'legacy_discovery'
      : 'discovery';

  /// Baseline versionada para que la migración al cursor por job siembre el
  /// estado existente sin elevar resultados antiguos como si fueran nuevos.
  static String discoveryBaselineScopeKey({
    required String connId,
    required String profile,
    required bool syntheticExecutionId,
    bool sessionAuthority = false,
  }) =>
      '${discoveryScopeKey(connId: connId, profile: profile, syntheticExecutionId: syntheticExecutionId, sessionAuthority: sessionAuthority)}/baseline-v2';

  static String discoveryBaselineObjectId(
    bool syntheticExecutionId, {
    bool sessionAuthority = false,
  }) =>
      '${discoveryObjectId(syntheticExecutionId, sessionAuthority: sessionAuthority)}_baseline_v2';

  /// Un cursor estable por job contiene únicamente su ejecución más reciente.
  /// Así, al cambiar un job no se reingestan todos los terminales históricos
  /// de la instantánea Cron después de podar tombstones.
  @visibleForTesting
  static ({String scopeKey, String objectId}) discoveryCursorForExecution({
    required String connId,
    required String profile,
    required CronExecutionSnapshot execution,
  }) {
    final jobDigest = sha256.convert(utf8.encode(execution.jobKey)).toString();
    return (
      scopeKey: '$connId/$profile/cron/job/$jobDigest',
      objectId: 'job_$jobDigest',
    );
  }

  @visibleForTesting
  static bool shouldSeedUnnotifiableTerminal({required bool initialBaseline}) =>
      initialBaseline;

  @visibleForTesting
  static NotificationEventIdentity notificationIdentity({
    required String connId,
    required String profile,
    required CronExecutionSnapshot execution,
  }) {
    final authority = discoveryObjectId(
      execution.syntheticExecutionId,
      sessionAuthority: execution.sessionAuthority,
    );
    return NotificationEventIdentity(
      connId: connId,
      profile: profile,
      sourceKind: 'cron',
      objectId: '$authority.${execution.executionId}',
      eventKind: 'terminal',
      sourceVersion: '${execution.executionId}:${execution.status}',
    );
  }

  static List<String> cronJobEndpoints() => const [
    'cron/jobs?profile=all',
    'cron/jobs',
  ];

  @visibleForTesting
  static List<CronExecutionSnapshot> mergeExecutionAuthority({
    required List<CronExecutionSnapshot> jobExecutions,
    required List<Session> sessions,
  }) {
    final byJob = <String, CronExecutionSnapshot>{
      for (final execution in jobExecutions) execution.jobKey: execution,
    };
    final latestSessions = <String, Session>{};
    for (final session in sessions) {
      if (!session.isJob || session.isActive) continue;
      final jobId = session.cronJobId;
      if (jobId == null || jobId.isEmpty) continue;
      final profile = Session.profileOwner(session.profile).toLowerCase();
      final jobKey = '$profile::$jobId';
      final current = latestSessions[jobKey];
      if (current == null || _isNewerCronSession(session, current)) {
        latestSessions[jobKey] = session;
      }
    }
    for (final entry in latestSessions.entries) {
      final session = entry.value;
      final jobId = session.cronJobId!;
      final existing = byJob[entry.key];
      // `/cron/jobs` es la autoridad de la última ejecución publicada. La
      // lista de sesiones puede ir retrasada y no ofrece una identidad que
      // permita demostrar que otro terminal del mismo job corresponde a ese
      // ledger. Sustituirlo por jobKey perdería un fallo nuevo o resucitaría
      // un resultado anterior. Las sesiones solo cubren jobs ausentes; para
      // una ejecución moderna ya presente, [sessionForExecution] exige el ID
      // opaco exacto antes de hidratar destino y preview.
      if (existing != null) continue;
      final failure =
          session.handoffError?.trim().isNotEmpty == true ||
          const {
            'error',
            'failed',
            'failure',
          }.contains(session.endReason?.trim().toLowerCase());
      byJob[entry.key] = CronExecutionSnapshot(
        jobKey: entry.key,
        jobId: jobId,
        title: existing?.title ?? session.displayTitle,
        profile: Session.profileOwner(session.profile),
        executionId: session.id,
        status: failure ? 'failed' : 'completed',
        sessionAuthority: true,
      );
    }
    final merged = byJob.values.toList(growable: false);
    merged.sort((left, right) => left.jobKey.compareTo(right.jobKey));
    return merged;
  }

  static bool _isNewerCronSession(Session candidate, Session current) {
    final candidateTime =
        candidate.updatedAt ?? candidate.endedAt ?? candidate.startedAt;
    final currentTime =
        current.updatedAt ?? current.endedAt ?? current.startedAt;
    final timeOrder = candidateTime.compareTo(currentTime);
    return timeOrder != 0
        ? timeOrder > 0
        : candidate.id.compareTo(current.id) > 0;
  }

  @visibleForTesting
  static Set<String> discoveryProfiles(
    List<CronExecutionSnapshot> executions,
  ) => <String>{
    'default',
    for (final execution in executions)
      execution.profile.trim().isEmpty
          ? 'default'
          : execution.profile.trim().toLowerCase(),
  };

  @visibleForTesting
  static Set<
    ({String profile, bool syntheticExecutionId, bool sessionAuthority})
  >
  discoveryGroups(List<CronExecutionSnapshot> executions) {
    final profiles = discoveryProfiles(executions);
    return {
      for (final profile in profiles)
        (
          profile: profile,
          syntheticExecutionId: false,
          sessionAuthority: false,
        ),
      for (final profile in profiles)
        (profile: profile, syntheticExecutionId: false, sessionAuthority: true),
      for (final profile in profiles)
        (profile: profile, syntheticExecutionId: true, sessionAuthority: false),
      for (final execution in executions)
        (
          profile: execution.profile.trim().isEmpty
              ? 'default'
              : execution.profile.trim().toLowerCase(),
          syntheticExecutionId: execution.syntheticExecutionId,
          sessionAuthority: execution.sessionAuthority,
        ),
    };
  }

  /// Hermes Desktop aggregates Cron conversations through
  /// `/api/profiles/sessions?profile=all&source=cron`. Older Dashboards do not
  /// expose that aggregator, so the listener retries the default-profile
  /// `/api/sessions` route without the invalid `profile=all` parameter.
  static List<String> cronSessionEndpoints() {
    final common = <String, String>{
      'limit': '50',
      'offset': '0',
      'min_messages': '1',
      'archived': 'exclude',
      'order': 'recent',
      'source': 'cron',
      'full': '0',
    };
    return [
      'profiles/sessions?${Uri(queryParameters: {...common, 'profile': 'all'}).query}',
      'sessions?${Uri(queryParameters: common).query}',
    ];
  }

  /// A Cron result is a chat session in Hermes Desktop, never a Task Center
  /// run. Keeping this mapping explicit prevents notification taps from being
  /// routed to RunDetailScreen by a synthetic run id.
  static ({String sessionId, String? taskCenterRunId, String? profile})
  notificationDestination(Session session) =>
      (sessionId: session.id, taskCenterRunId: null, profile: session.profile);

  /// La lista ligera de sesiones de Agent 0.20 puede omitir el último turno.
  /// Hermes Desktop abre entonces el transcript oficial de esa sesión; el
  /// listener replica ese fallback solo para una ejecución recién terminada.
  @visibleForTesting
  static Future<String?> notificationPreview(
    Session? session,
    Future<List<Map<String, dynamic>>> Function(
      String sessionId,
      String profile,
    )
    loadMessages,
  ) async {
    if (session == null) return null;
    final advertised = session.lastAssistantPreview?.trim();
    if (advertised != null && advertised.isNotEmpty) return advertised;
    final messages = await loadMessages(
      session.id,
      session.profile?.trim() ?? '',
    );
    return latestAssistantPreview(messages);
  }

  /// Solo eleva al plano de interrupción un resultado material. Esta regla se
  /// aplica exclusivamente a sesiones tipadas como Cron; por eso los tokens de
  /// supresión no pueden ocultar texto humano de un chat normal.
  @visibleForTesting
  static bool shouldNotifyResult(
    CronExecutionSnapshot execution, {
    required Session? session,
    required String? preview,
  }) {
    // Los fallos son accionables incluso si el Dashboard no pudo hidratar su
    // sesión: ocultarlos por datos incompletos sería el fallo inseguro.
    if (!execution.ok) return true;
    // Un completed solo puede elevarse usando la proyección autoritativa Cron.
    if (session == null || session.source.trim().toLowerCase() != 'cron') {
      return false;
    }
    final outcome = (preview ?? '').trim();
    if (outcome.isEmpty) return false;
    return outcome != '[SILENT]' && outcome != 'no_change';
  }

  static Session? sessionForExecution(
    CronExecutionSnapshot execution,
    List<Session> sessions,
  ) {
    final executionProfile = _normalizeRunOwnerProfile(execution.profile);
    bool eligible(Session session) =>
        session.source.trim().toLowerCase() == 'cron' &&
        !session.isActive &&
        _normalizeRunOwnerProfile(session.profile ?? '') == executionProfile;

    // A synthetic legacy ID is a digest of job state, never a session ID. An
    // opaque modern session may coincidentally have the same bytes.
    if (!execution.syntheticExecutionId) {
      for (final session in sessions) {
        if (session.id == execution.executionId && eligible(session)) {
          return session;
        }
      }
      return null;
    }

    final prefix = 'cron_${execution.jobId}_';
    Session? winner;
    for (final session in sessions) {
      if (!session.id.startsWith(prefix) || !eligible(session)) continue;
      final candidateTime =
          session.updatedAt ?? session.endedAt ?? session.startedAt;
      final winnerTime = winner == null
          ? double.negativeInfinity
          : winner.updatedAt ?? winner.endedAt ?? winner.startedAt;
      if (winner == null ||
          candidateTime > winnerTime ||
          (candidateTime == winnerTime &&
              session.id.compareTo(winner.id) > 0)) {
        winner = session;
      }
    }
    return winner;
  }

  static Future<List<CronExecutionSnapshot>?> loadExecutions(
    Future<Map<String, dynamic>> Function(String endpoint) apiGet,
  ) async {
    final endpoints = cronJobEndpoints();
    late final Map<String, dynamic> data;
    try {
      data = await apiGet(endpoints.first);
    } on DashboardHttpException catch (error) {
      if (!shouldFallbackFromAllProfilesStatus(error.statusCode)) rethrow;
      try {
        data = await apiGet(endpoints.last);
      } on DashboardHttpException catch (fallbackError) {
        if (fallbackError.statusCode == 404 ||
            fallbackError.statusCode == 405) {
          return null;
        }
        rethrow;
      }
    }
    final raw = data['jobs'] ?? data['data'];
    return (raw as List? ?? const [])
        .map(CronExecutionSnapshot.fromJob)
        .whereType<CronExecutionSnapshot>()
        .toList(growable: false);
  }

  @visibleForTesting
  static bool shouldFallbackFromAllProfilesStatus(int statusCode) =>
      statusCode == 400 ||
      statusCode == 404 ||
      statusCode == 405 ||
      statusCode == 422 ||
      statusCode == 501;

  static Future<void> syncConnections(List<SavedConnection> connections) =>
      BackgroundWatch._locked((prefs) async {
        // La preferencia durable es la autoridad. El gate estático puede
        // seguir apagado durante el primer toggle de una UI nacida con la
        // escucha desactivada y no debe vaciar el snapshot recién solicitado.
        if (prefs.getBool(BackgroundListener.prefKey) != true) {
          await prefs.remove(_targetsKey);
          await prefs.setInt(
            _targetsRevisionKey,
            (prefs.getInt(_targetsRevisionKey) ?? 0) + 1,
          );
          return;
        }
        final safe = <Map<String, dynamic>>[];
        for (final connection in connections) {
          try {
            TransportPrivacy.requireAllowed(connection.effectiveDashboardUrl);
            safe.add(connection.toMap());
          } on ArgumentError {
            // Una conexión HTTP pública no debe convertirse en vigilancia de
            // fondo aunque estuviera guardada por una versión antigua.
          }
        }
        await prefs.setString(_targetsKey, jsonEncode(safe));
        await prefs.setInt(
          _targetsRevisionKey,
          (prefs.getInt(_targetsRevisionKey) ?? 0) + 1,
        );
      });

  static Future<({List<SavedConnection> connections, int revision})>
  snapshotTargetState() => BackgroundWatch._locked((prefs) async {
    final revision = prefs.getInt(_targetsRevisionKey) ?? 0;
    final raw = prefs.getString(_targetsKey);
    if (raw == null || raw.isEmpty) {
      return (connections: const <SavedConnection>[], revision: revision);
    }
    try {
      final connections = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map(
            (value) => SavedConnection.fromMap(value.cast<String, dynamic>()),
          )
          .toList(growable: false);
      return (connections: connections, revision: revision);
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[hermes-notif] cron targets inválidos '
          '(${error.runtimeType})',
        );
      }
      return (connections: const <SavedConnection>[], revision: revision);
    }
  });

  static Future<List<SavedConnection>> snapshotTargets() async =>
      (await snapshotTargetState()).connections;

  @visibleForTesting
  static ({
    List<CronExecutionSnapshot> fresh,
    Map<String, CronExecutionSnapshot> states,
  })
  claimExecutionsForTest({
    required bool initialized,
    required Map<String, CronExecutionSnapshot> previous,
    required List<CronExecutionSnapshot> current,
  }) {
    final states = <String, CronExecutionSnapshot>{};
    final fresh = <CronExecutionSnapshot>[];
    for (final execution in current) {
      if (states.length >= _maxJobsPerConnection) break;
      states[execution.jobKey] = execution;
      final old = previous[execution.jobKey];
      final becameTerminal =
          execution.terminal &&
          (old == null ||
              old.executionId != execution.executionId ||
              !old.terminal);
      if (initialized && becameTerminal) {
        fresh.add(execution);
      }
    }
    return (fresh: fresh, states: states);
  }
}

class KanbanNotificationTransition {
  final String taskId;
  final String title;
  final String previousStatus;
  final String status;

  const KanbanNotificationTransition({
    required this.taskId,
    required this.title,
    required this.previousStatus,
    required this.status,
  });
}

class KanbanDiscoveryEntry {
  const KanbanDiscoveryEntry({
    required this.scopeKey,
    required this.taskId,
    required this.title,
    required this.state,
  });

  final String scopeKey;
  final String taskId;
  final String title;
  final String state;
}

/// Cursor local para los estados del Kanban oficial de Hermes Agent.
///
/// La primera lectura siembra el tablero y no repite el historial. Después
/// solo reclama transiciones que requieren atención en móvil: completada,
/// bloqueada o enviada a triage. El estado se avanza incluso si la UI está en
/// primer plano, de modo que una transición no se duplica al volver al fondo.
class BackgroundKanbanWatch {
  static const int _maxTasksPerConnection = 500;
  static const Set<String> _notifiableStatuses = {'done', 'blocked', 'triage'};

  @visibleForTesting
  static List<KanbanDiscoveryEntry> discoveryEntriesForTest({
    required String connId,
    required List<KanbanTask> tasks,
  }) => <KanbanDiscoveryEntry>[
    for (final task in tasks)
      if (task.id.trim().isNotEmpty && task.status.trim().isNotEmpty)
        KanbanDiscoveryEntry(
          scopeKey: '$connId/default/kanban/${task.id.trim()}',
          taskId: task.id.trim(),
          title: task.title.trim().isEmpty ? task.id.trim() : task.title.trim(),
          state: task.status.trim().toLowerCase(),
        ),
  ];

  @visibleForTesting
  static String transitionVersionForTest({
    required String taskId,
    required String previousStatus,
    required String status,
  }) => '$taskId:$status:after:$previousStatus';

  /// Carga el board nativo de Agent 0.20. Un Dashboard legacy sin el plugin
  /// devuelve null para que Cron siga funcionando de forma independiente.
  static Future<List<KanbanTask>?> loadTasks(
    Future<Map<String, dynamic>> Function(String endpoint) apiGet,
  ) async {
    try {
      final data = await apiGet('plugins/kanban/board');
      final board = KanbanBoard.fromJson(data);
      return <KanbanTask>[for (final column in board.columns) ...column.tasks];
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  @visibleForTesting
  static ({
    List<KanbanNotificationTransition> fresh,
    Map<String, String> statuses,
  })
  claimForTest({
    required bool initialized,
    required Map<String, String> previous,
    required List<KanbanTask> current,
  }) {
    final statuses = <String, String>{};
    final fresh = <KanbanNotificationTransition>[];
    for (final task in current) {
      if (statuses.length >= _maxTasksPerConnection) break;
      final taskId = task.id.trim();
      final status = task.status.trim().toLowerCase();
      if (taskId.isEmpty || status.isEmpty) continue;
      statuses[taskId] = status;

      final previousStatus = previous[taskId]?.trim().toLowerCase();
      if (!initialized ||
          previousStatus == null ||
          previousStatus == status ||
          !_notifiableStatuses.contains(status)) {
        continue;
      }
      final title = task.title.trim();
      fresh.add(
        KanbanNotificationTransition(
          taskId: taskId,
          title: title.isEmpty ? taskId : title,
          previousStatus: previousStatus,
          status: status,
        ),
      );
    }
    return (fresh: fresh, statuses: statuses);
  }
}

/// Punto de entrada del isolate del servicio. Debe ser top-level y anotado.
@pragma('vm:entry-point')
void hermesForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_HermesTaskHandler());
}

/// Acciones locales de la tarjeta de voz. No contienen texto de conversación y
/// nunca se convierten en mensajes para el agente.
enum VoiceSessionAction { open, pause, continueSession, end }

/// Acciones de la lectura puntual. Usan un envelope distinto al de la
/// conversación para que una notificación antigua nunca abra el micrófono.
enum ReadAloudNotificationAction { pause, resume, end }

/// Propietario del servicio Flutter compartido con audio. La prioridad es
/// deliberada: una conversación opt-in conserva sus controles y micrófono;
/// después va la lectura puntual y finalmente el sondeo dataSync.
enum ForegroundAudioOwner { dataSync, readAloud, voiceConversation }

enum BackgroundTaskStartDisposition { runtimeOwner, restoreAutomation, stop }

enum ForegroundNetworkReconcileAction { start, stop, none }

@visibleForTesting
ForegroundNetworkReconcileAction resolveForegroundNetworkReconcileAction({
  required bool audioOwner,
  required bool flutterNetworkDemand,
  required bool serviceRunning,
}) {
  if (audioOwner || flutterNetworkDemand) {
    return ForegroundNetworkReconcileAction.start;
  }
  return serviceRunning
      ? ForegroundNetworkReconcileAction.stop
      : ForegroundNetworkReconcileAction.none;
}

@visibleForTesting
BackgroundTaskStartDisposition resolveBackgroundTaskStartDisposition({
  required TaskStarter starter,
  required bool automationEnabled,
}) {
  if (starter == TaskStarter.developer) {
    return BackgroundTaskStartDisposition.runtimeOwner;
  }
  return automationEnabled
      ? BackgroundTaskStartDisposition.restoreAutomation
      : BackgroundTaskStartDisposition.stop;
}

enum _ForegroundNetworkMode { none, dataSync, remoteMessaging }

ForegroundAudioOwner resolveForegroundAudioOwner({
  required bool voiceConversationNeedsForeground,
  required bool readAloudNeedsForeground,
}) {
  if (voiceConversationNeedsForeground) {
    return ForegroundAudioOwner.voiceConversation;
  }
  if (readAloudNeedsForeground) return ForegroundAudioOwner.readAloud;
  return ForegroundAudioOwner.dataSync;
}

/// Estado redactado que la conversación proyecta en la notificación del FGS.
/// `waitingPermission` es deliberadamente distinto de una pausa manual: el
/// botón abre la app para revisar la solicitud y nunca autoriza por voz.
enum VoiceNotificationState { active, paused, waitingPermission }

/// Conserva una única sesión autenticada del Dashboard por instancia durante
/// la vida del FGS. Cron y Kanban comparten así cookies/token y no repiten dos
/// logins en cada tick. Un cambio de URL o modo de autenticación invalida solo
/// esa instancia; retirar una conexión o destruir el servicio cierra su HTTP.
@visibleForTesting
class BackgroundDashboardClientCache {
  final DashboardClient Function(SavedConnection connection) _create;
  final Map<String, ({String url, AuthMode authMode, DashboardClient client})>
  _clients = {};

  BackgroundDashboardClientCache({
    DashboardClient Function(SavedConnection connection)? create,
  }) : _create = create ?? DashboardClient.lazy;

  DashboardClient clientFor(SavedConnection connection) {
    final url = connection.effectiveDashboardUrl;
    final authMode = connection.dashboardAuthMode;
    final current = _clients[connection.id];
    if (current != null && current.url == url && current.authMode == authMode) {
      return current.client;
    }
    current?.client.close();
    final client = _create(connection);
    _clients[connection.id] = (url: url, authMode: authMode, client: client);
    return client;
  }

  void retainConnections(Iterable<SavedConnection> connections) {
    final expected = <String, ({String url, AuthMode authMode})>{
      for (final connection in connections)
        connection.id: (
          url: connection.effectiveDashboardUrl,
          authMode: connection.dashboardAuthMode,
        ),
    };
    for (final id in _clients.keys.toList(growable: false)) {
      final current = _clients[id]!;
      final wanted = expected[id];
      if (wanted != null &&
          wanted.url == current.url &&
          wanted.authMode == current.authMode) {
        continue;
      }
      _clients.remove(id)?.client.close();
    }
  }

  void close() {
    for (final entry in _clients.values) {
      entry.client.close();
    }
    _clients.clear();
  }
}

enum BackgroundDiscoveryCapability { cron, kanban }

/// Backoff sin timers para el discovery que ejecuta el tick ya existente del
/// foreground service. Cada capacidad falla y se recupera de forma aislada por
/// conexión; una edición de URL/auth invalida el estado igual que retirar la
/// conexión.
@visibleForTesting
class BackgroundDiscoveryBackoff {
  final DateTime Function() _now;
  final Duration baseDelay;
  final Duration maxDelay;
  final Map<(String, BackgroundDiscoveryCapability), _DiscoveryBackoffState>
  _states = {};
  final Map<String, String> _connectionSignatures = {};

  BackgroundDiscoveryBackoff({
    DateTime Function()? now,
    this.baseDelay = const Duration(minutes: 1),
    this.maxDelay = const Duration(minutes: 30),
  }) : assert(baseDelay > Duration.zero),
       assert(maxDelay >= baseDelay),
       _now = now ?? DateTime.now;

  bool allowsBackgroundAttempt(
    String connectionId,
    BackgroundDiscoveryCapability capability,
  ) {
    final state = _states[(connectionId, capability)];
    return state == null || !_now().isBefore(state.retryAt);
  }

  void recordFailure(
    String connectionId,
    BackgroundDiscoveryCapability capability,
  ) {
    final key = (connectionId, capability);
    final failures = (_states[key]?.failures ?? 0) + 1;
    var delayMs = baseDelay.inMilliseconds;
    for (var index = 1; index < failures; index++) {
      if (delayMs >= maxDelay.inMilliseconds) break;
      delayMs = (delayMs * 2).clamp(0, maxDelay.inMilliseconds).toInt();
    }
    _states[key] = _DiscoveryBackoffState(
      failures: failures,
      retryAt: _now().add(Duration(milliseconds: delayMs)),
    );
  }

  void recordSuccess(
    String connectionId,
    BackgroundDiscoveryCapability capability,
  ) {
    _states.remove((connectionId, capability));
  }

  void retainConnections(Iterable<SavedConnection> connections) {
    final signatures = <String, String>{
      for (final connection in connections)
        connection.id:
            '${connection.effectiveDashboardUrl}\n'
            '${connection.dashboardAuthMode.name}',
    };
    final changedOrRemoved = <String>{
      ..._connectionSignatures.keys.where(
        (id) => signatures[id] != _connectionSignatures[id],
      ),
    };
    for (final id in changedOrRemoved) {
      _states.removeWhere((key, _) => key.$1 == id);
    }
    _connectionSignatures
      ..clear()
      ..addAll(signatures);
  }

  void reset() {
    _states.clear();
    _connectionSignatures.clear();
  }

  @visibleForTesting
  Duration? retryAfter(
    String connectionId,
    BackgroundDiscoveryCapability capability,
  ) {
    final retryAt = _states[(connectionId, capability)]?.retryAt;
    if (retryAt == null) return null;
    final remaining = retryAt.difference(_now());
    return remaining.isNegative ? Duration.zero : remaining;
  }
}

class _DiscoveryBackoffState {
  final int failures;
  final DateTime retryAt;

  const _DiscoveryBackoffState({required this.failures, required this.retryAt});
}

class _HermesTaskHandler extends TaskHandler {
  NotificationService? _notif;
  final SecureStorage _secure = SecureStorage();
  bool _polling = false;

  int _emptyPolls = 0;

  /// Cliente HTTP REUTILIZADO entre ticks: sin él, cada sondeo abría una
  /// conexión TCP nueva por run vigilada cada 30 s (handshake con la radio
  /// despierta). Se cierra en [onDestroy].
  final http.Client _http = http.Client();
  final BackgroundDashboardClientCache _dashboardClients =
      BackgroundDashboardClientCache();
  final BackgroundDiscoveryBackoff _discoveryBackoff =
      BackgroundDiscoveryBackoff();
  int _targetRevision = -1;
  final ForegroundTaskStopFence _stopFence = ForegroundTaskStopFence();

  static const int _kActiveIntervalMs = 30000;
  static const int _kCronIntervalMs = 60000;
  static const int _kIdleIntervalMs = 180000;
  int _currentIntervalMs = _kActiveIntervalMs;

  /// Cambia el ritmo del repeat del FGS solo cuando difiere del actual.
  void _setPollInterval(int ms, {required bool persistentAutomation}) {
    if (!_stopFence.allowsUpdate) return;
    if (ms == _currentIntervalMs) return;
    _currentIntervalMs = ms;
    FlutterForegroundTask.updateService(
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(ms),
        autoRunOnBoot: persistentAutomation,
        autoRunOnMyPackageReplaced: persistentAutomation,
        allowAutoRestart: false,
        stopWithTask: false,
        allowWakeLock: false,
        allowWifiLock: false,
      ),
    );
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    if (kDebugMode) {
      debugPrint('[hermes-notif] foreground task onStart');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final automationOptIn = prefs.getBool(BackgroundListener.prefKey) == true;
    // Cada TaskHandler vive en su propio isolate: los estáticos inicializados
    // por la UI no cruzan esa frontera. Hidratar el gate antes de construir el
    // servicio permite que boot/package-replaced sondeen Cron/Kanban de verdad.
    NotificationService.setAutomationNotificationsOptedIn(automationOptIn);
    _notif = NotificationService(prefs)..appInForeground = false;
    final disposition = resolveBackgroundTaskStartDisposition(
      starter: starter,
      automationEnabled: automationOptIn,
    );
    if (disposition == BackgroundTaskStartDisposition.stop) {
      _stopFence.requestStop();
      await prefs.setBool(BackgroundListener.voiceCardActiveKey, false);
      await VoiceNotificationCardAdapter.clear();
      await FlutterForegroundTask.stopService();
      return;
    }
    if (disposition == BackgroundTaskStartDisposition.restoreAutomation) {
      // START_STICKY, boot y package-replaced nunca poseen una sesión de audio
      // ni una lease SSH/SFTP. Reemplazar inmediatamente contenido/botones
      // persistidos evita una tarjeta de Voz/TTS huérfana sobre remoteMessaging.
      await prefs.setBool(BackgroundListener.voiceCardActiveKey, false);
      await VoiceNotificationCardAdapter.clear();
      final t = NotifL10n.of(prefs);
      await FlutterForegroundTask.updateService(
        foregroundTaskOptions: BackgroundListener._taskOptions(
          autoRunOnBoot: true,
        ),
        notificationTitle: 'Hermes Console',
        notificationText: t.bgActive,
        notificationIcon: BackgroundListener._serviceNotificationIcon,
        notificationButtons: [NotificationButton(id: 'stop', text: t.bgStop)],
      );
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // onRepeatEvent es síncrono; lanzamos el sondeo sin bloquear.
    _poll();
  }

  Future<void> _poll() async {
    if (!_stopFence.allowsUpdate) return;
    if (_polling) return;
    _polling = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final automationOptIn = prefs.getBool(BackgroundListener.prefKey) == true;
      // Stop/toggles pueden venir del isolate principal entre ticks. La pref
      // durable es la única autoridad compartida y debe refrescar el estático
      // local antes de evaluar cualquier política de entrega.
      NotificationService.setAutomationNotificationsOptedIn(automationOptIn);
      final voiceCardActive =
          prefs.getBool(BackgroundListener.voiceCardActiveKey) == true;
      final audioCardActive = voiceCardActive;
      // El servicio también puede estar vivo por Voz, Read Aloud o una
      // transferencia puntual. Solo el opt-in persistente autoriza el sondeo
      // de runs, Cron y Kanban.
      if (!automationOptIn) {
        if (audioCardActive) {
          _emptyPolls = 0;
          return;
        }
        // Sin consentimiento no se descubre ni entrega automatización, pero
        // sí debe poder cerrarse un runtime huérfano. Esta comprobación tiene
        // que estar antes del gate: _maybeAutoStop valida dos ticks y el
        // heartbeat de UI antes de tocar el servicio compartido.
        await _maybeAutoStop(prefs);
        return;
      }
      if (!NotificationService.automationNotificationsEnabled) return;
      final runs = await BackgroundWatch.snapshot();
      final targetState = await BackgroundCronWatch.snapshotTargetState();
      final cronTargets = targetState.connections;
      if (_targetRevision != targetState.revision) {
        // Una revisión también cambia tras rotar secretos. No se persiste el
        // secreto, pero sí se invalida el cliente lazy que pudo cachearlo.
        _dashboardClients.close();
        _discoveryBackoff.reset();
        _targetRevision = targetState.revision;
      }
      _dashboardClients.retainConnections(cronTargets);
      _discoveryBackoff.retainConnections(cronTargets);
      if (runs.isEmpty && cronTargets.isEmpty) {
        if (!_stopFence.allowsUpdate) return;
        if (!audioCardActive) {
          _setPollInterval(_kIdleIntervalMs, persistentAutomation: true);
        }
        if (audioCardActive) {
          _emptyPolls = 0;
          return;
        }
        await _maybeAutoStop(prefs);
        return;
      }
      final notif = _notif ??= (NotificationService(prefs)
        ..appInForeground = false);
      await notif.init();
      final watchesCron = await _discoverCronRuns(notif, prefs, cronTargets);
      final watchesKanban = await _discoverKanbanTransitions(
        notif,
        prefs,
        cronTargets,
      );
      if (runs.isEmpty) {
        if (!_stopFence.allowsUpdate) return;
        // Con opt-in de escucha permanente y NADA que vigilar, baja el ritmo
        // a 3 min: cada tick despierta CPU con wakelock retenido, y a 30s el
        // coste de batería no compra nada (spec 028). Vuelve a 30s en cuanto
        // entra una run vigilada.
        if (!audioCardActive) {
          _setPollInterval(
            watchesCron || watchesKanban ? _kCronIntervalMs : _kIdleIntervalMs,
            persistentAutomation: true,
          );
        }
        if (audioCardActive) {
          _emptyPolls = 0;
          return;
        }
        await _maybeAutoStop(prefs);
        return;
      }
      _emptyPolls = 0;
      if (!audioCardActive) {
        if (!_stopFence.allowsUpdate) return;
        _setPollInterval(_kActiveIntervalMs, persistentAutomation: true);
      }

      final pollKeep = <WatchedRun>[];
      for (final r in runs) {
        final result = await _checkRun(notif, r);
        if (result != null) pollKeep.add(result);
      }
      final keep = await BackgroundWatch.mergePollResults(
        snapshot: runs,
        keep: pollKeep,
      );

      // Texto vivo en la notificación persistente.
      if (kDebugMode) {
        debugPrint('[hermes-notif] BG updateService (keep=${keep.length})');
      }
      if (!audioCardActive) {
        await prefs.reload();
        if (!_stopFence.allowsUpdate) return;
        if (prefs.getBool(BackgroundListener.prefKey) != true) return;
        final t = NotifL10n.of(prefs);
        FlutterForegroundTask.updateService(
          notificationTitle: 'Hermes Console',
          notificationText: keep.isEmpty
              ? t.bgActive
              : t.bgWatching(keep.length),
        );
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[hermes-notif] BG poll error (${error.runtimeType})');
      }
    } finally {
      _polling = false;
    }
  }

  /// Descubre sesiones `source=cron` directamente desde el Dashboard. A
  /// diferencia de [BackgroundWatch], esto cubre ejecuciones disparadas por el
  /// scheduler del servidor y no solo runs que creó la app.
  Future<bool> _discoverCronRuns(
    NotificationService notif,
    SharedPreferences prefs,
    List<SavedConnection> targets,
  ) async {
    if (targets.isEmpty || !notif.notifyCronResults) return false;
    final uiForeground =
        prefs.getBool(BackgroundListener.uiForegroundKey) == true;
    for (final connection in targets) {
      if (!_discoveryBackoff.allowsBackgroundAttempt(
        connection.id,
        BackgroundDiscoveryCapability.cron,
      )) {
        continue;
      }
      final dashboard = _dashboardClients.clientFor(connection);
      List<CronExecutionSnapshot>? executions;
      try {
        executions = await BackgroundCronWatch.loadExecutions(dashboard.apiGet);
      } catch (error) {
        _discoveryBackoff.recordFailure(
          connection.id,
          BackgroundDiscoveryCapability.cron,
        );
        if (kDebugMode) {
          debugPrint(
            '[hermes-notif] cron discovery falló (${error.runtimeType})',
          );
        }
        continue;
      }
      if (executions == null) {
        _discoveryBackoff.recordFailure(
          connection.id,
          BackgroundDiscoveryCapability.cron,
        );
        continue;
      }
      // El endpoint ya respondió: la recuperación no espera a que termine el
      // procesamiento local ni una notificación del SO.
      _discoveryBackoff.recordSuccess(
        connection.id,
        BackgroundDiscoveryCapability.cron,
      );
      try {
        var sessions = const <Session>[];
        try {
          final endpoints = BackgroundCronWatch.cronSessionEndpoints();
          late final Map<String, dynamic> data;
          try {
            data = await dashboard.apiGet(endpoints.first);
          } on DashboardHttpException catch (error) {
            if (!BackgroundCronWatch.shouldFallbackFromAllProfilesStatus(
              error.statusCode,
            )) {
              rethrow;
            }
            data = await dashboard.apiGet(endpoints.last);
          }
          final raw = data['sessions'] ?? data['data'];
          sessions = (raw as List? ?? const [])
              .map(Session.tryParse)
              .whereType<Session>()
              .toList(growable: false);
        } catch (error) {
          if (kDebugMode) {
            debugPrint(
              '[hermes-notif] cron destinations falló '
              '(${error.runtimeType})',
            );
          }
        }

        executions = BackgroundCronWatch.mergeExecutionAuthority(
          jobExecutions: executions,
          sessions: sessions,
        );

        final groups = BackgroundCronWatch.discoveryGroups(executions);
        final initialBaseline =
            <
              ({
                String profile,
                bool syntheticExecutionId,
                bool sessionAuthority,
              }),
              bool
            >{};
        for (final group in groups) {
          initialBaseline[group] = await notif.deliverDiscoveryBatch(
            scopeKey: BackgroundCronWatch.discoveryBaselineScopeKey(
              connId: connection.id,
              profile: group.profile,
              syntheticExecutionId: group.syntheticExecutionId,
              sessionAuthority: group.sessionAuthority,
            ),
            connId: connection.id,
            profile: group.profile,
            sourceKind: 'cron',
            objectId: BackgroundCronWatch.discoveryBaselineObjectId(
              group.syntheticExecutionId,
              sessionAuthority: group.sessionAuthority,
            ),
            lastState: 'snapshot',
            sourceVersion: 'baseline-v2',
            events: const <DurableDiscoveryNotification>[],
            suppressByPolicy: false,
            suppressEventsWhenVersionUnchanged: true,
          );
        }
        final t = NotifL10n.of(prefs);
        for (final execution in executions) {
          final executionProfile = execution.profile.trim().toLowerCase();
          final initialProfile = executionProfile.isEmpty
              ? 'default'
              : executionProfile;
          final initialGroup = (
            profile: initialProfile,
            syntheticExecutionId: execution.syntheticExecutionId,
            sessionAuthority: execution.sessionAuthority,
          );
          final initialCursor = BackgroundCronWatch.discoveryCursorForExecution(
            connId: connection.id,
            profile: initialProfile,
            execution: execution,
          );
          final version = '${execution.executionId}:${execution.status}';
          if (!execution.terminal) {
            await notif.deliverDiscoveryBatch(
              scopeKey: initialCursor.scopeKey,
              connId: connection.id,
              profile: initialProfile,
              sourceKind: 'cron',
              objectId: initialCursor.objectId,
              lastState: 'running',
              sourceVersion: version,
              events: const <DurableDiscoveryNotification>[],
              suppressByPolicy: false,
              suppressEventsWhenVersionUnchanged: true,
              suppressInitialEvents: initialBaseline[initialGroup] ?? true,
            );
            continue;
          }
          final session = BackgroundCronWatch.sessionForExecution(
            execution,
            sessions,
          );
          final destination = session == null
              ? null
              : BackgroundCronWatch.notificationDestination(session);
          String? preview;
          try {
            preview = await BackgroundCronWatch.notificationPreview(
              session,
              (sessionId, profile) =>
                  dashboard.getSessionMessages(sessionId, profile: profile),
            );
          } catch (_) {
            // Preview is display-only; identity and cursor remain authoritative.
          }
          if (!BackgroundCronWatch.shouldNotifyResult(
            execution,
            session: session,
            preview: preview,
          )) {
            if (BackgroundCronWatch.shouldSeedUnnotifiableTerminal(
              initialBaseline: initialBaseline[initialGroup] ?? true,
            )) {
              await notif.deliverDiscoveryBatch(
                scopeKey: initialCursor.scopeKey,
                connId: connection.id,
                profile: initialProfile,
                sourceKind: 'cron',
                objectId: initialCursor.objectId,
                lastState: 'snapshot',
                sourceVersion: version,
                events: const <DurableDiscoveryNotification>[],
                suppressByPolicy: false,
                suppressEventsWhenVersionUnchanged: true,
              );
            }
            continue;
          }
          final profile = (destination?.profile ?? execution.profile)
              .trim()
              .toLowerCase();
          final normalizedProfile = profile.isEmpty ? 'default' : profile;
          final group = (
            profile: normalizedProfile,
            syntheticExecutionId: execution.syntheticExecutionId,
            sessionAuthority: execution.sessionAuthority,
          );
          final identity = BackgroundCronWatch.notificationIdentity(
            connId: connection.id,
            profile: normalizedProfile,
            execution: execution,
          );
          final cursor = BackgroundCronWatch.discoveryCursorForExecution(
            connId: connection.id,
            profile: normalizedProfile,
            execution: execution,
          );
          await notif.deliverDiscoveryBatch(
            scopeKey: cursor.scopeKey,
            connId: connection.id,
            profile: normalizedProfile,
            sourceKind: 'cron',
            objectId: cursor.objectId,
            lastState: 'snapshot',
            sourceVersion: version,
            events: <DurableDiscoveryNotification>[
              DurableDiscoveryNotification(
                identity: identity,
                destinationKind: 'cron_terminal',
                kind: NotificationKind.run,
                title: execution.ok ? t.cronCompleted : t.cronFailed,
                body: NotificationService.compactAutomationPreview(
                  preview,
                  fallback: session?.displayTitle ?? execution.title,
                ),
                sessionId: destination?.sessionId,
                jobId: destination == null ? execution.jobId : null,
                subText: NotificationService.compactSessionLabel(
                  session?.displayTitle ?? execution.title,
                ),
              ),
            ],
            suppressByPolicy: uiForeground && !notif.evenInForeground,
            suppressEventsWhenVersionUnchanged: true,
            suppressInitialEvents: initialBaseline[group] ?? true,
          );
        }
      } catch (error) {
        if (kDebugMode) {
          debugPrint(
            '[hermes-notif] cron processing falló (${error.runtimeType})',
          );
        }
      }
    }
    return true;
  }

  /// Observa el board nativo de Agent 0.20 con su propio opt-in
  /// ([NotificationService.notifyKanbanResults]), independiente del de Cron.
  /// En servidores legacy sin Kanban, [BackgroundKanbanWatch.loadTasks]
  /// devuelve null y este camino se limita a no hacer nada.
  Future<bool> _discoverKanbanTransitions(
    NotificationService notif,
    SharedPreferences prefs,
    List<SavedConnection> targets,
  ) async {
    if (targets.isEmpty || !notif.notifyKanbanResults) return false;
    final uiForeground =
        prefs.getBool(BackgroundListener.uiForegroundKey) == true;
    for (final connection in targets) {
      if (!_discoveryBackoff.allowsBackgroundAttempt(
        connection.id,
        BackgroundDiscoveryCapability.kanban,
      )) {
        continue;
      }
      final dashboard = _dashboardClients.clientFor(connection);
      List<KanbanTask>? tasks;
      try {
        tasks = await BackgroundKanbanWatch.loadTasks(dashboard.apiGet);
      } catch (error) {
        _discoveryBackoff.recordFailure(
          connection.id,
          BackgroundDiscoveryCapability.kanban,
        );
        if (kDebugMode) {
          debugPrint(
            '[hermes-notif] kanban discovery falló (${error.runtimeType})',
          );
        }
        continue;
      }
      if (tasks == null) {
        _discoveryBackoff.recordFailure(
          connection.id,
          BackgroundDiscoveryCapability.kanban,
        );
        continue;
      }
      _discoveryBackoff.recordSuccess(
        connection.id,
        BackgroundDiscoveryCapability.kanban,
      );
      try {
        const materialStatuses = <String>{'done', 'blocked', 'triage'};
        final t = NotifL10n.of(prefs);
        final entries = BackgroundKanbanWatch.discoveryEntriesForTest(
          connId: connection.id,
          tasks: tasks,
        );
        for (final entry in entries) {
          final status = entry.state;
          final events = <DurableDiscoveryNotification>[];
          if (materialStatuses.contains(status)) {
            final identity = NotificationEventIdentity(
              connId: connection.id,
              profile: 'default',
              sourceKind: 'kanban',
              objectId: entry.taskId,
              eventKind: status,
              sourceVersion: '${entry.taskId}:$status',
            );
            final title = switch (status) {
              'done' => t.kanbanCompleted,
              'blocked' => t.kanbanBlocked,
              'triage' => t.kanbanNeedsAttention,
              _ => t.kanbanUpdated,
            };
            events.add(
              DurableDiscoveryNotification(
                identity: identity,
                destinationKind: 'kanban_transition',
                kind: NotificationKind.run,
                title: title,
                body: entry.title,
                taskId: entry.taskId,
                subText: 'Kanban · ${entry.taskId}',
              ),
            );
          }
          await notif.deliverDiscoveryBatch(
            scopeKey: entry.scopeKey,
            connId: connection.id,
            profile: 'default',
            sourceKind: 'kanban',
            objectId: entry.taskId,
            lastState: status,
            sourceVersion: status,
            events: events,
            suppressByPolicy: uiForeground && !notif.evenInForeground,
            versionEventsByPreviousSnapshot: true,
          );
        }
      } catch (error) {
        if (kDebugMode) {
          debugPrint(
            '[hermes-notif] kanban processing falló (${error.runtimeType})',
          );
        }
      }
    }
    return true;
  }

  /// A-302/U-11 (spec 028): el servicio no debe quedarse vivo sin trabajo.
  /// Para cuando la lista de vigilancia lleva vacía ≥2 sondeos, no hay opt-in
  /// de escucha permanente y la UI no da señales de vida (heartbeat
  /// `uiAliveKey` con >3 min de antigüedad). Cubre la resurrección tras boot
  /// sin trabajo y el servicio huérfano tras barrer la app. Voz/Read Aloud y
  /// SSH/SFTP quedan protegidos por sus markers durables exactos; el heartbeat
  /// es una defensa adicional para trabajo local que aún posee la UI.
  Future<void> _maybeAutoStop(SharedPreferences prefs) async {
    final automationOptIn = prefs.getBool(BackgroundListener.prefKey) == true;
    final audioCardActive =
        prefs.getBool(BackgroundListener.voiceCardActiveKey) == true;
    final externalDataSyncDemand =
        prefs.getInt(BackgroundListener.externalDataSyncDemandKey) ?? 0;
    if (automationOptIn || audioCardActive || externalDataSyncDemand > 0) {
      _emptyPolls = 0;
      return;
    }
    _emptyPolls++;
    final uiAt = prefs.getInt(BackgroundListener.uiAliveKey) ?? 0;
    final staleMs = DateTime.now().millisecondsSinceEpoch - uiAt;
    if (!backgroundRuntimeMayAutoStopForTest(
      automationOptIn: automationOptIn,
      audioCardActive: audioCardActive,
      externalDataSyncDemand: externalDataSyncDemand,
      emptyPolls: _emptyPolls,
      uiHeartbeatStaleMs: staleMs,
    )) {
      return;
    }
    debugPrint(
      '[hermes-notif] auto-stop: sin trabajo, sin opt-in y sin UI viva',
    );
    _stopFence.requestStop();
    await FlutterForegroundTask.stopService();
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == BackgroundListener.readAloudPauseButtonId) {
      FlutterForegroundTask.sendDataToMain(
        BackgroundListener.readAloudActionEnvelope(
          ReadAloudNotificationAction.pause,
        ),
      );
      return;
    }
    if (id == BackgroundListener.readAloudResumeButtonId) {
      FlutterForegroundTask.sendDataToMain(
        BackgroundListener.readAloudActionEnvelope(
          ReadAloudNotificationAction.resume,
        ),
      );
      return;
    }
    if (id == BackgroundListener.readAloudEndButtonId) {
      unawaited(
        BackgroundListener.sendTerminalActionThenStop(
          BackgroundListener.readAloudActionEnvelope(
            ReadAloudNotificationAction.end,
          ),
        ),
      );
      return;
    }
    if (id == BackgroundListener.voiceReviewApprovalButtonId) {
      FlutterForegroundTask.launchApp();
      return;
    }
    if (id == BackgroundListener.voicePauseButtonId) {
      FlutterForegroundTask.sendDataToMain(
        BackgroundListener.voiceSessionActionEnvelope(VoiceSessionAction.pause),
      );
      return;
    }
    if (id == BackgroundListener.voiceContinueButtonId) {
      FlutterForegroundTask.sendDataToMain(
        BackgroundListener.voiceSessionActionEnvelope(
          VoiceSessionAction.continueSession,
        ),
      );
      return;
    }
    if (id == BackgroundListener.voiceEndButtonId) {
      unawaited(
        BackgroundListener.sendTerminalActionThenStop(
          BackgroundListener.voiceSessionActionEnvelope(VoiceSessionAction.end),
        ),
      );
      return;
    }
    if (id != 'stop') return;
    _stopFence.requestStop();
    // Parada pedida desde la notificación: apaga también el opt-in para que
    // el servicio no se rearme en el siguiente arranque (boot o app). Primero
    // entrega la orden a la UI para que cierre SSH/SFTP reales; la valla local
    // impide que un poll tardío publique API_UPDATE durante el margen.
    FlutterForegroundTask.sendDataToMain(
      BackgroundListener.foregroundStopActionEnvelope(),
    );
    unawaited(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(BackgroundListener.prefKey, false);
      await Future<void>.delayed(
        BackgroundListener.terminalActionDeliveryGrace,
      );
      await prefs.reload();
      // Durante el margen la UI puede haber adquirido Voz/Read Aloud, una
      // transferencia SSH/SFTP o un opt-in nuevo. El botón pertenece a la
      // tarjeta de red anterior y nunca puede detener a ese propietario nuevo.
      if (prefs.getBool(BackgroundListener.voiceCardActiveKey) == true ||
          (prefs.getInt(BackgroundListener.externalDataSyncDemandKey) ?? 0) >
              0 ||
          prefs.getBool(BackgroundListener.prefKey) == true) {
        return;
      }
      await FlutterForegroundTask.stopService();
    }());
  }

  @override
  void onNotificationPressed() {
    // El content intent del plugin ya es un PendingIntent de Activity iniciado
    // directamente por Android. Pedir otro lanzamiento desde este callback
    // convertiría el toque en un notification trampoline, bloqueado
    // por Android 12+ cuando Hermes está en segundo plano. El PendingIntent del
    // plugin abre la Activity; este envelope solo indica al isolate principal
    // qué chat debe mostrar cuando Navigator y App Lock estén listos.
    FlutterForegroundTask.sendDataToMain(
      BackgroundListener.voiceSessionActionEnvelope(VoiceSessionAction.open),
    );
  }

  /// Sondea una run. Devuelve la entrada actualizada para seguir vigilando, o
  /// `null` si ya terminó (dejar de vigilar).
  Future<WatchedRun?> _checkRun(NotificationService notif, WatchedRun r) async {
    final owner = r.notificationOwner;
    late final String safeBase;
    try {
      safeBase = TransportPrivacy.requireAllowed(r.base);
    } on ArgumentError {
      // Entrada antigua/corrupta: se elimina sin leer la API key ni tocar red.
      debugPrint('[hermes-notif] unsafe watch discarded');
      return null;
    }
    try {
      final token = await _secure.readApiKey(r.connId);
      final uri = Uri.parse('$safeBase/v1/runs/${r.runId}');
      final res = await _http
          .get(
            uri,
            headers: {
              if (token != null && token.isNotEmpty)
                'Authorization': 'Bearer $token',
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 12));
      if (kDebugMode) {
        debugPrint('[hermes-notif] run poll HTTP ${res.statusCode}');
      }

      // Solo un 200 aporta estado autoritativo. Un 404 también puede significar
      // expiración o pérdida del ledger: nunca se convierte en éxito inventado.
      if (!BackgroundListener.canInferRunOutcomeFromHttpStatus(
        res.statusCode,
      )) {
        return r; // reintentar luego
      }

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final status = (body['status'] ?? '').toString();
      final title = r.prompt.trim().isEmpty ? 'Agent task' : r.prompt.trim();

      if (status == 'waiting_for_approval') {
        final approvalId =
            (body['approval_request_id'] ??
                    body['approval_id'] ??
                    body['request_id'])
                ?.toString()
                .trim();
        if (approvalId == null || approvalId.isEmpty) {
          // Polling sin identidad autoritativa no puede crear una alerta durable.
          return r;
        }
        if (r.approvalRequestId == approvalId) return r;
        if (r.approvalRequestId != null) {
          await notif.cancelApproval(
            connId: owner.connId,
            profile: owner.profile,
            runId: owner.runId,
            approvalId: r.approvalRequestId,
          );
        }
        await notif.approvalPending(
          tool: title,
          connId: r.connId,
          sessionId: r.sessionId,
          runId: r.runId,
          approvalId: approvalId,
          base: r.base,
          profile: owner.profile,
        );
        return r.copyWith(
          approvalNotified: true,
          approvalRequestId: approvalId,
        );
      }
      if (status == 'completed' ||
          status == 'failed' ||
          status == 'cancelled') {
        await notif.cancelApproval(
          connId: owner.connId,
          profile: owner.profile,
          runId: owner.runId,
          terminal: true,
        );
        await notif.runFinished(
          title: title,
          ok: status == 'completed',
          connId: r.connId,
          sessionId: r.sessionId,
          runId: r.runId,
          profile: owner.profile,
        );
        return null; // dejar de vigilar
      }
      if (r.approvalRequestId != null) {
        await notif.cancelApproval(
          connId: owner.connId,
          profile: owner.profile,
          runId: owner.runId,
          approvalId: r.approvalRequestId,
        );
        return r.copyWith(clearApproval: true);
      }
      return r; // queued/running
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[hermes-notif] run poll transient (${error.runtimeType})');
      }
      return r; // error transitorio → reintentar en el próximo ciclo
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _stopFence.requestStop();
    NotificationService.setAutomationNotificationsOptedIn(false);
    await _notif?.closeDelivery();
    _notif = null;
    _dashboardClients.close();
    _http.close();
  }
}

/// API sencilla para arrancar/parar la escucha en segundo plano.
/// Serializa las escrituras de lifecycle emitidas por la UI. `initState` y un
/// `paused` inmediato pueden solaparse; el valor más reciente debe persistirse
/// siempre después del anterior, aunque SharedPreferences tarde en responder.
@visibleForTesting
class OrderedForegroundStateWriter {
  Future<void> _tail = Future<void>.value();

  Future<void> write(bool value, Future<void> Function(bool value) persist) {
    final result = _tail.then((_) => persist(value));
    _tail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }
}

class BackgroundListener {
  @visibleForTesting
  static bool canInferRunOutcomeFromHttpStatus(int statusCode) =>
      statusCode == 200;

  /// Margen para que el port entre isolates entregue `end` antes de destruir
  /// el engine del foreground task. Sin él, el servicio podía cortar el
  /// micrófono pero perder la orden destinada a cerrar la UI principal.
  @visibleForTesting
  static const Duration terminalActionDeliveryGrace = Duration(
    milliseconds: 750,
  );

  static const String _voiceSessionEnvelopeType = 'voice_session';
  static const String _readAloudEnvelopeType = 'read_aloud';
  static const String _foregroundStopEnvelopeType = 'foreground_stop';
  static const String voicePauseButtonId = 'voice_pause';
  static const String voiceContinueButtonId = 'voice_continue';
  static const String voiceReviewApprovalButtonId = 'voice_review_approval';
  static const String voiceEndButtonId = 'voice_end';
  static const String readAloudPauseButtonId = 'read_aloud_pause';
  static const String readAloudResumeButtonId = 'read_aloud_resume';
  static const String readAloudEndButtonId = 'read_aloud_end';

  static const String _serviceIconMeta =
      'dev.xpetalab.hermesconsole.service.NOTIFICATION_ICON';
  static const String _voiceActiveIconMeta =
      'dev.xpetalab.hermesconsole.voice.NOTIFICATION_ICON_ACTIVE';
  static const String _voicePausedIconMeta =
      'dev.xpetalab.hermesconsole.voice.NOTIFICATION_ICON_PAUSED';

  static const NotificationIcon _serviceNotificationIcon = NotificationIcon(
    metaDataName: _serviceIconMeta,
    backgroundColor: Color(0xFFE8821C),
  );

  static NotificationIcon _voiceNotificationIcon({required bool paused}) =>
      NotificationIcon(
        metaDataName: paused ? _voicePausedIconMeta : _voiceActiveIconMeta,
        backgroundColor: paused
            ? const Color(0xFF6F625A)
            : const Color(0xFFE8821C),
      );

  static Map<String, String> voiceSessionActionEnvelope(
    VoiceSessionAction action,
  ) => {
    'type': _voiceSessionEnvelopeType,
    'action': switch (action) {
      VoiceSessionAction.open => 'open',
      VoiceSessionAction.pause => 'pause',
      VoiceSessionAction.continueSession => 'continue',
      VoiceSessionAction.end => 'end',
    },
  };

  static Map<String, String> readAloudActionEnvelope(
    ReadAloudNotificationAction action,
  ) => {
    'type': _readAloudEnvelopeType,
    'action': switch (action) {
      ReadAloudNotificationAction.pause => 'pause',
      ReadAloudNotificationAction.resume => 'resume',
      ReadAloudNotificationAction.end => 'end',
    },
  };

  static Map<String, String> foregroundStopActionEnvelope() => const {
    'type': _foregroundStopEnvelopeType,
    'action': 'stop',
  };

  static bool foregroundStopRequestedFromData(Object? data) =>
      data is Map &&
      data['type'] == _foregroundStopEnvelopeType &&
      data['action'] == 'stop';

  /// Entrega primero la orden terminal al isolate principal y conserva un
  /// fallback fail-closed: si ese propietario ya murió, el FGS se detiene tras
  /// un margen breve y nunca deja una tarjeta de audio huérfana.
  @visibleForTesting
  static Future<void> sendTerminalActionThenStop(
    Object envelope, {
    Duration grace = terminalActionDeliveryGrace,
    void Function(Object data)? sendToMain,
    Future<bool> Function()? shouldStop,
    Future<void> Function()? stopService,
  }) async {
    (sendToMain ?? FlutterForegroundTask.sendDataToMain)(envelope);
    await Future<void>.delayed(grace);
    final mustStop = shouldStop != null
        ? await shouldStop()
        : await _terminalAudioCardStillActive();
    if (!mustStop) return;
    if (stopService != null) {
      await stopService();
    } else {
      await FlutterForegroundTask.stopService();
    }
  }

  static Future<bool> _terminalAudioCardStillActive() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getBool(voiceCardActiveKey) == true;
  }

  static ReadAloudNotificationAction? readAloudActionFromData(Object? data) {
    if (data is! Map || data['type'] != _readAloudEnvelopeType) return null;
    return switch (data['action']) {
      'pause' => ReadAloudNotificationAction.pause,
      'resume' => ReadAloudNotificationAction.resume,
      'end' => ReadAloudNotificationAction.end,
      _ => null,
    };
  }

  static VoiceSessionAction? voiceSessionActionFromData(Object? data) {
    if (data is! Map || data['type'] != _voiceSessionEnvelopeType) return null;
    return switch (data['action']) {
      'open' => VoiceSessionAction.open,
      'pause' => VoiceSessionAction.pause,
      'continue' => VoiceSessionAction.continueSession,
      'end' => VoiceSessionAction.end,
      _ => null,
    };
  }

  /// Pref que recuerda la preferencia del usuario (re-arrancar al abrir).
  static const String prefKey =
      NotificationService.backgroundListenPreferenceKey;

  /// Lease efímera compartida con el isolate del FGS. Mientras está activa, el
  /// sondeo de runs no reconstruye la notificación y por tanto no pisa el
  /// `customBigContentView` aplicado al mismo id. Se limpia en cada arranque de
  /// UI y al salir; no representa consentimiento ni reanuda una sesión.
  static const String voiceCardActiveKey = 'voice_fgs_card_active';

  /// Heartbeat "la UI sigue viva" (A-302, spec 028): mientras el isolate
  /// principal exista y el servicio corra, se refresca cada minuto. Si la app
  /// muere (swipe) o el servicio resucita tras boot sin UI, el timestamp se
  /// queda estale y el isolate del servicio puede auto-detenerse sin trabajo.
  static const String uiAliveKey = 'notif_ui_alive_at';
  static const String uiForegroundKey = 'notif_ui_foreground';
  // Solo para retirar el estado de la implementación finita de 1.2.9 al
  // activar/restaurar la escucha permanente. No gobiernan comportamiento.
  static const String _legacyAutomationDeadlinePreference =
      'notif_automation_session_deadline';
  static const String _legacyAutomationPausedPreference =
      'notif_automation_session_paused';
  static const String externalDataSyncDemandKey =
      'notif_external_data_sync_demand';
  static const MethodChannel _platformInfo = MethodChannel(
    'hermes/platform_info',
  );
  static const MethodChannel _restartContract = MethodChannel(
    'hermes/foreground_restart_contract',
  );
  static const MethodChannel _externalDataSync = MethodChannel(
    'hermes/foreground_external_data_sync',
  );
  static Timer? _uiHeartbeat;
  static final OrderedForegroundStateWriter _uiForegroundWriter =
      OrderedForegroundStateWriter();
  static final ForegroundMutationSerializer _foregroundMutations =
      ForegroundMutationSerializer();

  static Future<void> _touchUiAlive() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(uiAliveKey, DateTime.now().millisecondsSinceEpoch);
  }

  static Future<void> setUiForeground(bool foreground) =>
      _uiForegroundWriter.write(foreground, (value) async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(uiForegroundKey, value);
      });

  static void _armUiHeartbeat() {
    _uiHeartbeat ??= Timer.periodic(const Duration(minutes: 1), (_) async {
      if (await FlutterForegroundTask.isRunningService) await _touchUiAlive();
    });
  }

  static bool _inited = false;
  static Future<void>? _initFuture;

  static AndroidNotificationOptions _androidOptions(NotifL10n t) =>
      AndroidNotificationOptions(
        // Id NUEVO: recrear el mismo id puede heredar la importancia vieja
        // (Android guarda los ajustes de canales borrados). Este nace en LOW.
        channelId: 'hermes_service_v2',
        channelName: t.bgChannel,
        channelDescription: t.bgChannelDesc,
        // LOW (A-303, spec 028): silenciosa (sin sonido ni heads-up) pero con
        // icono visible en la barra.
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      );

  static ForegroundTaskOptions _taskOptions({
    required bool autoRunOnBoot,
  }) => ForegroundTaskOptions(
    eventAction: ForegroundTaskEventAction.repeat(30000),
    // La automatización usa remoteMessaging en Android 15+ y puede conservar
    // el opt-in tras boot/actualización. Voz y Read Aloud siempre configuran
    // este valor a false antes de adquirir tipos de audio.
    autoRunOnBoot: autoRunOnBoot,
    autoRunOnMyPackageReplaced: autoRunOnBoot,
    allowAutoRestart: false,
    // Removing the task from Recents is not a force-stop and must not stop the
    // already-visible FGS session.
    stopWithTask: false,
    allowWakeLock: false,
    allowWifiLock: false,
  );

  static void _configure(NotifL10n t, {required bool autoRunOnBoot}) {
    FlutterForegroundTask.init(
      androidNotificationOptions: _androidOptions(t),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: _taskOptions(autoRunOnBoot: autoRunOnBoot),
    );
  }

  /// Memoizada: varias llamadas concurrentes comparten la misma init (evita
  /// que `start()` lance el servicio antes de configurar el canal).
  static Future<void> ensureInitialized() => _initFuture ??= _doInit();

  static Future<void> _doInit() async {
    if (_inited) return;
    _inited = true;
    final t = NotifL10n.of(await SharedPreferences.getInstance());
    // Los canales de Android son INMUTABLES tras crearse: si una versión previa
    // creó `hermes_listener` en LOW, volver a init en MIN no lo baja. Borramos
    // el canal viejo para que FlutterForegroundTask lo recree en MIN (sin icono
    // en la barra de estado, plegado al fondo).
    try {
      final android = FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android?.deleteNotificationChannel('hermes_listener');
      // Canal MIN de la etapa anterior (sustituido por hermes_service_v2 LOW).
      await android?.deleteNotificationChannel('hermes_service');
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[hermes-notif] channel cleanup falló (${error.runtimeType})',
        );
      }
    }
    _configure(t, autoRunOnBoot: false);
  }

  static Future<bool> isRunning() => FlutterForegroundTask.isRunningService;

  /// Actualiza el texto de la notificación persistente del foreground service
  /// (si está corriendo). Lo usa el chat LOCAL (bridge): su turno es una llamada
  /// HTTP larga a `hermes -z`, no un run pollable, así que el isolate del
  /// servicio (que sondea /v1/runs) no tiene nada que reflejar. Esto deja la
  /// notificación persistente informando del turno en curso aunque la app esté
  /// en 2º plano. No-op si el servicio no está activo. Nunca lanza.
  static Future<void> updateText({
    required String title,
    required String text,
  }) => _foregroundMutations.run(
    () => _updateTextSerialized(title: title, text: text),
  );

  static Future<void> _updateTextSerialized({
    required String title,
    required String text,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (prefs.getBool(voiceCardActiveKey) == true) {
        return;
      }
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText: text,
        );
        await _persistDurableRestartContract(prefs);
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[hermes-notif] updateText falló (${error.runtimeType})');
      }
    }
  }

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefKey) == true;
  }

  /// Inicia la escucha persistente tras un opt-in visible. Android 15+ usa el
  /// tipo remoteMessaging: el producto transporta mensajes entre el agente
  /// autoalojado y este dispositivo y no queda sujeto al timeout de dataSync.
  static Future<bool> startForAutomation() async {
    final prefs = await SharedPreferences.getInstance();
    NotificationService.setAutomationNotificationsOptedIn(
      prefs.getBool(NotificationService.backgroundListenPreferenceKey) ?? false,
    );
    if (!NotificationService.automationNotificationsEnabled) return false;
    await _clearLegacyFiniteSessionState(prefs);
    return start();
  }

  /// Mantiene residente el foreground service mientras el agente responde.
  ///
  /// El opt-in permanente lo mantiene siempre; sin él, un turno vivo lo
  /// adquiere igualmente durante la respuesta ([setActiveTurnRequired]). Sin
  /// esa lease, Android congela el isolate en cuanto la app pasa a 2º plano y
  /// el socket del turno muere sin entregar su cierre: la respuesta se pierde
  /// y el chat se queda "ejecutando" para siempre.
  static Future<bool> ensureAutomationForeground() async {
    final prefs = await SharedPreferences.getInstance();
    if (!_automationForegroundDemand(prefs)) return false;
    return start();
  }

  /// Lease del turno vivo: mientras hay una respuesta en curso, el proceso debe
  /// seguir ejecutándose aunque el usuario minimice la app. Es transitoria y no
  /// representa consentimiento: no toca [prefKey], así que nunca habilita el
  /// re-arranque tras boot ni la escucha permanente.
  static Future<bool> setActiveTurnRequired(bool required) {
    final revision = ++_activeTurnRevision;
    _activeTurnDemand = required ? 1 : 0;
    return _foregroundMutations.run(
      () => _applyActiveTurnRequirement(required, revision),
    );
  }

  static Future<bool> _applyActiveTurnRequirement(
    bool required,
    int revision,
  ) async {
    // Una adquisición posterior ya reclamó la lease: esta no puede soltarla.
    if (revision != _activeTurnRevision) return false;
    if (!required) {
      // El opt-in permanente, el audio y SSH/SFTP siguen mandando: soltar la
      // lease del turno solo puede parar un runtime que ya no tiene dueño.
      await _releaseIdleRuntimeSerialized();
      return false;
    }
    final started = await start();
    if (!started && revision == _activeTurnRevision) _activeTurnDemand = 0;
    return started;
  }

  /// Releases only automation demand. Audio and external dataSync owners remain.
  static Future<void> stopAutomation() =>
      _foregroundMutations.run(_stopAutomationSerialized);

  static Future<void> _stopAutomationSerialized() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, false);
    NotificationService.setAutomationNotificationsOptedIn(false);
    await _clearLegacyFiniteSessionState(prefs);
    await BackgroundCronWatch.syncConnections(const <SavedConnection>[]);
    await _persistDurableRestartContract(prefs);
    await _reconcileAfterDataSyncRelease(prefs);
  }

  /// Reconciliación idempotente de la demanda agregada SSH/SFTP. El llamador
  /// deriva el booleano desde el estado vivo de ambos servicios; no se usa un
  /// refcount porque sus señales de cierre pueden ser duplicadas o proceder de
  /// intentos que nunca llegaron a adquirir el FGS.
  static Future<bool> setExternalDataSyncRequired(bool required) {
    final revision = ++_externalDataSyncRevision;
    _externalDataSyncDemand = required ? 1 : 0;
    return _foregroundMutations.run(
      () => _applyExternalDataSyncRequirement(required, revision),
    );
  }

  static Future<bool> _applyExternalDataSyncRequirement(
    bool required,
    int revision,
  ) async {
    if (revision != _externalDataSyncRevision) return false;
    final prefs = await SharedPreferences.getInstance();
    if (revision != _externalDataSyncRevision) return false;
    await prefs.setInt(externalDataSyncDemandKey, required ? 1 : 0);
    final sdk = await _androidSdkInt();
    if (Platform.isAndroid && sdk >= 35) {
      final applied = await _setNativeExternalDataSyncRequired(required);
      if (revision != _externalDataSyncRevision) return false;
      if (!applied && required) {
        _externalDataSyncDemand = 0;
        await prefs.setInt(externalDataSyncDemandKey, 0);
        if (kDebugMode) {
          debugPrint('[hermes-notif] external dataSync unavailable');
        }
      }
      return applied;
    }
    if (required) {
      final started = await start();
      if (!started && revision == _externalDataSyncRevision) {
        _externalDataSyncDemand = 0;
        await prefs.setInt(externalDataSyncDemandKey, 0);
        await _reconcileAfterDataSyncRelease(prefs);
      }
      return started;
    }
    await _reconcileAfterDataSyncRelease(prefs);
    return true;
  }

  /// Libera solo un runtime transitorio que ya no tiene propietario. A
  /// diferencia de [stop], no borra demanda SSH/SFTP ni estado de audio; la
  /// lectura se hace dentro del mismo serializer que sus adquisiciones.
  static Future<void> releaseIdleRuntime() =>
      _foregroundMutations.run(_releaseIdleRuntimeSerialized);

  static Future<void> _releaseIdleRuntimeSerialized() async {
    final prefs = await SharedPreferences.getInstance();
    if (_networkDemand(prefs) ||
        _voiceTypeSaved ||
        _readAloudTypeSaved ||
        prefs.getBool(voiceCardActiveKey) == true) {
      return;
    }
    _uiHeartbeat?.cancel();
    _uiHeartbeat = null;
    _activeNetworkMode = _ForegroundNetworkMode.none;
    if (await FlutterForegroundTask.isRunningService) {
      await _hardStopFlutterRuntime();
    }
    await _persistDurableRestartContract(prefs);
  }

  static Future<bool> _setNativeExternalDataSyncRequired(bool required) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _externalDataSync.invokeMethod<bool>(
            'setRequired',
            <String, Object>{'required': required},
          ) ==
          true;
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[hermes-notif] external dataSync channel failed '
          '(${error.runtimeType})',
        );
      }
      return false;
    }
  }

  static Future<void> _reconcileAfterDataSyncRelease(SharedPreferences prefs) =>
      _foregroundMutations.run(
        () => _reconcileAfterDataSyncReleaseSerialized(prefs),
      );

  static Future<void> _reconcileAfterDataSyncReleaseSerialized(
    SharedPreferences prefs,
  ) async {
    final desiredMode = await _desiredNetworkMode(prefs);
    final running = await FlutterForegroundTask.isRunningService;
    final action = resolveForegroundNetworkReconcileAction(
      audioOwner: _voiceTypeSaved || _readAloudTypeSaved,
      flutterNetworkDemand: desiredMode != _ForegroundNetworkMode.none,
      serviceRunning: running,
    );
    switch (action) {
      case ForegroundNetworkReconcileAction.start:
        // Reconstruye audio con el modo de red restante o aplica el tipo de red
        // exacto. El dataSync nativo de API>=35 no cuenta como demanda Flutter.
        await start();
      case ForegroundNetworkReconcileAction.stop:
        _activeNetworkMode = _ForegroundNetworkMode.none;
        await _hardStopFlutterRuntime();
      case ForegroundNetworkReconcileAction.none:
        break;
    }
  }

  static Future<void> _clearLegacyFiniteSessionState(
    SharedPreferences prefs,
  ) async {
    await prefs.remove(_legacyAutomationDeadlinePreference);
    await prefs.remove(_legacyAutomationPausedPreference);
  }

  static Future<int> _androidSdkInt() async {
    if (!Platform.isAndroid) return 0;
    try {
      final value = await _platformInfo.invokeMethod<int>('getSdkInt');
      if (value != null && value > 0) return value;
    } catch (_) {
      // El canal solo existe con una Activity. El fallback cubre hosts y
      // pruebas; un fallo desconocido conserva dataSync, compatible y seguro.
    }
    final match = RegExp(
      r'(?:SDK|API)\s*([0-9]+)',
      caseSensitive: false,
    ).firstMatch(Platform.operatingSystemVersion);
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  @visibleForTesting
  static ForegroundServiceTypes automationServiceTypeForTest({
    required int androidSdkInt,
  }) => androidSdkInt >= 35
      ? ForegroundServiceTypes.remoteMessaging
      : ForegroundServiceTypes.dataSync;

  static Future<_ForegroundNetworkMode> _desiredNetworkMode(
    SharedPreferences prefs,
  ) async {
    final automation = _automationForegroundDemand(prefs);
    final external = _externalDataSyncDemand > 0;
    return _networkModeFor(
      automation: automation,
      externalDataSync: external,
      androidSdkInt: automation || external ? await _androidSdkInt() : 0,
    );
  }

  static _ForegroundNetworkMode _networkModeFor({
    required bool automation,
    required bool externalDataSync,
    required int androidSdkInt,
  }) {
    // Android 15+ ejecuta SSH/SFTP en un servicio nativo efímero separado.
    // Su cuota dataSync nunca puede derribar el listener remoteMessaging.
    final externalUsesFlutterService = externalDataSync && androidSdkInt < 35;
    if (!automation) {
      return externalUsesFlutterService
          ? _ForegroundNetworkMode.dataSync
          : _ForegroundNetworkMode.none;
    }
    final automationType = automationServiceTypeForTest(
      androidSdkInt: androidSdkInt,
    );
    if (automationType.rawValue == ForegroundServiceTypes.dataSync.rawValue) {
      return _ForegroundNetworkMode.dataSync;
    }
    return _ForegroundNetworkMode.remoteMessaging;
  }

  static List<ForegroundServiceTypes> _serviceTypesFor(
    _ForegroundNetworkMode mode,
  ) => switch (mode) {
    _ForegroundNetworkMode.dataSync => const [ForegroundServiceTypes.dataSync],
    _ForegroundNetworkMode.remoteMessaging => const [
      ForegroundServiceTypes.remoteMessaging,
    ],
    _ForegroundNetworkMode.none => const [],
  };

  @visibleForTesting
  static List<ForegroundServiceTypes> networkServiceTypesForTest({
    required bool automation,
    required bool externalDataSync,
    required int androidSdkInt,
  }) => _serviceTypesFor(
    _networkModeFor(
      automation: automation,
      externalDataSync: externalDataSync,
      androidSdkInt: androidSdkInt,
    ),
  );

  static List<ForegroundServiceTypes> _audioServiceTypesFor({
    required bool voice,
    required bool automation,
    required bool externalDataSync,
    required int androidSdkInt,
  }) {
    final types = <ForegroundServiceTypes>[
      if (voice) ForegroundServiceTypes.microphone,
      ForegroundServiceTypes.mediaPlayback,
    ];
    for (final type in networkServiceTypesForTest(
      automation: automation,
      externalDataSync: externalDataSync,
      androidSdkInt: androidSdkInt,
    )) {
      if (!types.any((candidate) => candidate.rawValue == type.rawValue)) {
        types.add(type);
      }
    }
    return types;
  }

  @visibleForTesting
  static List<ForegroundServiceTypes> voiceServiceTypesForTest({
    required bool automation,
    required bool externalDataSync,
    required int androidSdkInt,
  }) => _audioServiceTypesFor(
    voice: true,
    automation: automation,
    externalDataSync: externalDataSync,
    androidSdkInt: androidSdkInt,
  );

  @visibleForTesting
  static List<ForegroundServiceTypes> readAloudServiceTypesForTest({
    required bool automation,
    required bool externalDataSync,
    required int androidSdkInt,
  }) => _audioServiceTypesFor(
    voice: false,
    automation: automation,
    externalDataSync: externalDataSync,
    androidSdkInt: androidSdkInt,
  );

  static Future<List<ForegroundServiceTypes>> _voiceServiceTypes(
    SharedPreferences prefs,
  ) async => voiceServiceTypesForTest(
    automation: _automationForegroundDemand(prefs),
    externalDataSync: _externalDataSyncDemand > 0,
    androidSdkInt: await _androidSdkInt(),
  );

  static Future<List<ForegroundServiceTypes>> _readAloudServiceTypes(
    SharedPreferences prefs,
  ) async => readAloudServiceTypesForTest(
    automation: _automationForegroundDemand(prefs),
    externalDataSync: _externalDataSyncDemand > 0,
    androidSdkInt: await _androidSdkInt(),
  );

  /// Separa el runtime del servicio Flutter de su contrato restaurable. Voz,
  /// Read Aloud y su tipo de red pueden coexistir, pero un restart
  /// sticky, boot o package-replaced solo puede resucitar automatización; sin
  /// opt-in, cualquier owner transitorio queda marcado non-restorable.
  static Future<void> _persistDurableRestartContract(
    SharedPreferences prefs,
  ) async {
    if (!Platform.isAndroid) return;
    try {
      // El host relee la preferencia nativa: ningún cache de otro isolate
      // puede reactivar un contrato después de Stop.
      await _restartContract.invokeMethod<void>('persist');
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[hermes-notif] durable restart contract unavailable '
          '(${error.runtimeType})',
        );
      }
    }
  }

  static Future<bool> _prepareFlutterRuntimeService() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _restartContract.invokeMethod<bool>(
            'prepareRuntimeService',
          ) ==
          true;
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[hermes-notif] runtime service prepare failed '
          '(${error.runtimeType})',
        );
      }
      return false;
    }
  }

  /// Stop físico independiente de `ForegroundServiceAction`: el plugin guarda
  /// START/UPDATE/STOP en una preferencia global y un poll de otro isolate
  /// podría sobrescribir STOP. El gate nativo deshabilita el componente antes
  /// de detenerlo; un runtime nuevo lo habilita explícitamente justo al iniciar.
  static Future<void> _hardStopFlutterRuntime() async {
    if (Platform.isAndroid) {
      try {
        final stopped =
            await _restartContract.invokeMethod<bool>(
              'hardStopRuntimeService',
            ) ==
            true;
        if (stopped) return;
      } catch (error) {
        if (kDebugMode) {
          debugPrint(
            '[hermes-notif] native runtime stop failed '
            '(${error.runtimeType})',
          );
        }
      }
    }
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  /// Arranca o reconcilia el servicio Flutter con los tipos de red exactos.
  /// SSH/SFTP de Android 15+ vive en el servicio nativo separado.
  static Future<bool> start() => _foregroundMutations.run(_startSerialized);

  static Future<bool> _startSerialized() async {
    await ensureInitialized();
    await _touchUiAlive();
    _armUiHeartbeat();
    final prefs = await SharedPreferences.getInstance();
    final mode = await _desiredNetworkMode(prefs);
    final running = await FlutterForegroundTask.isRunningService;
    if (running && _voiceTypeSaved) {
      if (_activeNetworkMode == mode) {
        await _persistDurableRestartContract(prefs);
        return true;
      }
      final previousState =
          _voiceNotificationState ?? VoiceNotificationState.active;
      _voiceTypeSaved = false;
      _voiceNotificationState = null;
      await _hardStopFlutterRuntime();
      _activeNetworkMode = _ForegroundNetworkMode.none;
      final restarted = await startForVoice();
      if (restarted && previousState != VoiceNotificationState.active) {
        await updateVoiceNotification(state: previousState);
      }
      return restarted;
    }
    if (running && _readAloudTypeSaved) {
      if (_activeNetworkMode == mode) {
        await _persistDurableRestartContract(prefs);
        return true;
      }
      final paused = _readAloudPaused ?? false;
      _readAloudTypeSaved = false;
      _readAloudPaused = null;
      await _hardStopFlutterRuntime();
      _activeNetworkMode = _ForegroundNetworkMode.none;
      return startForReadAloud(paused: paused);
    }
    if (mode == _ForegroundNetworkMode.none) {
      if (running) {
        _activeNetworkMode = _ForegroundNetworkMode.none;
        await _hardStopFlutterRuntime();
      }
      return false;
    }
    if (running && _activeNetworkMode == mode) {
      await _persistDurableRestartContract(prefs);
      return true;
    }
    if (running) await _hardStopFlutterRuntime();
    await prefs.setBool(voiceCardActiveKey, false);
    _voiceTypeSaved = false;
    _voiceNotificationState = null;
    _readAloudTypeSaved = false;
    _readAloudPaused = null;
    final t = NotifL10n.of(prefs);
    final persistentAutomation = _automationMessagingDemand(prefs);
    _configure(t, autoRunOnBoot: persistentAutomation);
    if (!await _prepareFlutterRuntimeService()) return false;
    final result = await FlutterForegroundTask.startService(
      serviceId: 256,
      serviceTypes: _serviceTypesFor(mode),
      notificationTitle: 'Hermes Console',
      notificationText: t.bgActive,
      notificationIcon: _serviceNotificationIcon,
      // A-303 (spec 028): acción de parada directa en la notificación — la
      // declaración FGS de Play promete que el usuario controla el servicio.
      notificationButtons: [NotificationButton(id: 'stop', text: t.bgStop)],
      callback: hermesForegroundCallback,
    );
    final ok = result is ServiceRequestSuccess;
    _activeNetworkMode = ok ? mode : _ForegroundNetworkMode.none;
    if (ok) await _persistDurableRestartContract(prefs);
    if (kDebugMode && !ok) {
      debugPrint('[hermes-notif] start falló (${result.runtimeType})');
    }
    return ok;
  }

  /// True si el FGS se arrancó en esta sesión con el tipo `microphone`
  /// (vía [startForVoice]). Permite que startForVoice sea idempotente.
  static bool _voiceTypeSaved = false;
  static bool _readAloudTypeSaved = false;
  static VoiceNotificationState? _voiceNotificationState;
  static bool? _readAloudPaused;
  static int _externalDataSyncDemand = 0;
  static int _externalDataSyncRevision = 0;
  static int _activeTurnDemand = 0;
  static int _activeTurnRevision = 0;
  static _ForegroundNetworkMode _activeNetworkMode =
      _ForegroundNetworkMode.none;

  /// Consentimiento permanente del usuario. Gobierna el re-arranque tras boot
  /// y la escucha continua; una lease de turno NUNCA lo activa.
  static bool _automationMessagingDemand(SharedPreferences prefs) =>
      prefs.getBool(prefKey) == true;

  /// ¿Debe estar corriendo ahora el servicio de automatización? El opt-in
  /// permanente o un turno vivo bastan; ambos necesitan la misma red.
  static bool _automationForegroundDemand(SharedPreferences prefs) =>
      _automationMessagingDemand(prefs) || _activeTurnDemand > 0;

  @visibleForTesting
  static bool automationMessagingDemandForTest(SharedPreferences prefs) =>
      _automationMessagingDemand(prefs);

  @visibleForTesting
  static bool automationForegroundDemandForTest(SharedPreferences prefs) =>
      _automationForegroundDemand(prefs);

  /// Mueve solo el contador de la lease, sin tocar el servicio nativo.
  @visibleForTesting
  static void setActiveTurnDemandForTest(bool required) {
    _activeTurnRevision++;
    _activeTurnDemand = required ? 1 : 0;
  }

  static bool _networkDemand(SharedPreferences prefs) =>
      _externalDataSyncDemand > 0 || _automationForegroundDemand(prefs);

  static ({
    bool paused,
    String text,
    String primaryId,
    String primaryText,
    String stateLabel,
    String microphoneLabel,
    String openHintLabel,
  })
  _voiceProjection(NotifL10n t, VoiceNotificationState state) =>
      switch (state) {
        VoiceNotificationState.active => (
          paused: false,
          text: t.voiceActive,
          primaryId: voicePauseButtonId,
          primaryText: t.voicePause,
          stateLabel: t.voiceCardListening,
          microphoneLabel: t.voiceCardMicActive,
          openHintLabel: t.voiceOpenHintActive,
        ),
        VoiceNotificationState.paused => (
          paused: true,
          text: t.voicePaused,
          primaryId: voiceContinueButtonId,
          primaryText: t.voiceContinue,
          stateLabel: t.voiceCardPaused,
          microphoneLabel: t.voiceCardMicPaused,
          openHintLabel: t.voiceOpenHintPaused,
        ),
        VoiceNotificationState.waitingPermission => (
          paused: true,
          text: t.voiceWaitingApproval,
          primaryId: voiceReviewApprovalButtonId,
          primaryText: t.voiceReviewApproval,
          stateLabel: t.voiceCardWaitingApproval,
          microphoneLabel: t.voiceCardMicPaused,
          openHintLabel: t.voiceOpenHintApproval,
        ),
      };

  static Future<void> _recoverNetworkAfterAudioStartFailure(
    SharedPreferences prefs,
    NotifL10n t,
  ) async {
    // La transición a audio detiene primero el FGS de red porque Android no
    // permite cambiar sus tipos en caliente. Si el gate nativo o el arranque
    // de audio falla, no puede quedar una tarjeta durable ficticia ni perderse
    // el opt-in de Cron/Kanban/WebSocket que ya estaba activo.
    await prefs.setBool(voiceCardActiveKey, false);
    _voiceTypeSaved = false;
    _voiceNotificationState = null;
    _readAloudTypeSaved = false;
    _readAloudPaused = null;
    _activeNetworkMode = _ForegroundNetworkMode.none;
    await VoiceNotificationCardAdapter.clear();
    _configure(t, autoRunOnBoot: _automationMessagingDemand(prefs));
    if (_networkDemand(prefs)) {
      await start();
    } else {
      await _persistDurableRestartContract(prefs);
    }
  }

  /// Arranca/reinicia el servicio con microphone + mediaPlayback. Debe llamarse
  /// desde foreground (al entrar al modo voz): en Android 14+ un FGS
  /// `microphone` no puede iniciarse desde background. El plugin no permite
  /// cambiar `serviceTypes` en caliente (solo actualiza la notificación), así
  /// que si ya corre con un tipo de red lo para y lo reinicia (stop limpia los
  /// tipos en prefs; el siguiente
  /// start los reescribe). Idempotente en la sesión (si ya tenía microphone).
  static Future<bool> startForVoice() =>
      _foregroundMutations.run(_startForVoiceSerialized);

  static Future<bool> _startForVoiceSerialized() async {
    await ensureInitialized();
    final prefs = await SharedPreferences.getInstance();
    final t = NotifL10n.of(prefs);
    await prefs.setBool(voiceCardActiveKey, true);
    // Guardar primero `autoRunOnBoot=false`: si el proceso muere antes de la
    // degradación, el BootReceiver no intentará resucitar un FGS de micrófono.
    _configure(t, autoRunOnBoot: false);
    final running = await FlutterForegroundTask.isRunningService;
    if (running && _voiceTypeSaved) {
      final projection = _voiceProjection(
        t,
        _voiceNotificationState ?? VoiceNotificationState.active,
      );
      // El icono y las acciones ya reflejan `_voiceNotificationState`. Enviar
      // aquí otro updateService no es idempotente: el plugin lo procesa de
      // forma asíncrona y puede reconstruir la notificación DESPUÉS de aplicar
      // el customBigContentView, borrando la tarjeta aunque el estado no cambie.
      await VoiceNotificationCardAdapter.apply(
        paused: projection.paused,
        expectedPrimaryAction: projection.primaryText,
        stateLabel: projection.stateLabel,
        microphoneLabel: projection.microphoneLabel,
        openHintLabel: projection.openHintLabel,
        orbDescription: t.voiceCardOrbDescription,
        durationDescription: t.voiceCardDurationDescription,
      );
      await _persistDurableRestartContract(prefs);
      return true;
    }
    if (running) await _hardStopFlutterRuntime();
    _activeNetworkMode = _ForegroundNetworkMode.none;
    _readAloudTypeSaved = false;
    _readAloudPaused = null;
    if (!await _prepareFlutterRuntimeService()) {
      await _recoverNetworkAfterAudioStartFailure(prefs, t);
      return false;
    }
    final result = await FlutterForegroundTask.startService(
      serviceId: 256,
      serviceTypes: await _voiceServiceTypes(prefs),
      notificationTitle: 'Hermes Console',
      notificationText: t.voiceActive,
      notificationIcon: _voiceNotificationIcon(paused: false),
      notificationButtons: [
        NotificationButton(id: voicePauseButtonId, text: t.voicePause),
        NotificationButton(id: voiceEndButtonId, text: t.voiceEndConversation),
      ],
      callback: hermesForegroundCallback,
    );
    final ok = result is ServiceRequestSuccess;
    if (ok) {
      _voiceTypeSaved = true;
      _voiceNotificationState = VoiceNotificationState.active;
      _activeNetworkMode = await _desiredNetworkMode(prefs);
      await _persistDurableRestartContract(prefs);
      await VoiceNotificationCardAdapter.apply(
        paused: false,
        expectedPrimaryAction: t.voicePause,
        stateLabel: t.voiceCardListening,
        microphoneLabel: t.voiceCardMicActive,
        openHintLabel: t.voiceOpenHintActive,
        orbDescription: t.voiceCardOrbDescription,
        durationDescription: t.voiceCardDurationDescription,
      );
    } else {
      await _recoverNetworkAfterAudioStartFailure(prefs, t);
    }
    if (kDebugMode && !ok) {
      debugPrint('[hermes-notif] voice start falló (${result.runtimeType})');
    }
    return ok;
  }

  /// Arranca el mismo FGS con `mediaPlayback`, sin micrófono. El contenido es
  /// siempre redactado y la sesión no se restaura tras process death/boot.
  static Future<bool> startForReadAloud({required bool paused}) =>
      _foregroundMutations.run(
        () => _startForReadAloudSerialized(paused: paused),
      );

  static Future<bool> _startForReadAloudSerialized({
    required bool paused,
  }) async {
    await ensureInitialized();
    final prefs = await SharedPreferences.getInstance();
    final t = NotifL10n.of(prefs);

    await prefs.setBool(voiceCardActiveKey, true);
    _configure(t, autoRunOnBoot: false);
    final running = await FlutterForegroundTask.isRunningService;
    if (running && _readAloudTypeSaved) {
      await updateReadAloudNotification(paused: paused);
      await _persistDurableRestartContract(prefs);
      return true;
    }
    if (running) await _hardStopFlutterRuntime();
    _activeNetworkMode = _ForegroundNetworkMode.none;
    await VoiceNotificationCardAdapter.clear();
    _voiceTypeSaved = false;
    _voiceNotificationState = null;
    if (!await _prepareFlutterRuntimeService()) {
      await _recoverNetworkAfterAudioStartFailure(prefs, t);
      return false;
    }
    final result = await FlutterForegroundTask.startService(
      serviceId: 256,
      serviceTypes: await _readAloudServiceTypes(prefs),
      notificationTitle: 'Hermes Console',
      notificationText: paused ? t.readAloudPaused : t.readAloudPlaying,
      notificationIcon: _serviceNotificationIcon,
      notificationButtons: [
        NotificationButton(
          id: paused ? readAloudResumeButtonId : readAloudPauseButtonId,
          text: paused ? t.voiceContinue : t.voicePause,
        ),
        NotificationButton(id: readAloudEndButtonId, text: t.voiceEnd),
      ],
      callback: hermesForegroundCallback,
    );
    final ok = result is ServiceRequestSuccess;
    if (ok) {
      _readAloudTypeSaved = true;
      _readAloudPaused = paused;
      _activeNetworkMode = await _desiredNetworkMode(prefs);
      await _persistDurableRestartContract(prefs);
    } else {
      await _recoverNetworkAfterAudioStartFailure(prefs, t);
    }
    if (kDebugMode && !ok) {
      debugPrint(
        '[hermes-notif] read aloud start falló (${result.runtimeType})',
      );
    }
    return ok;
  }

  static Future<void> updateReadAloudNotification({required bool paused}) =>
      _foregroundMutations.run(
        () => _updateReadAloudNotificationSerialized(paused: paused),
      );

  static Future<void> _updateReadAloudNotificationSerialized({
    required bool paused,
  }) async {
    if (!_readAloudTypeSaved || _readAloudPaused == paused) return;
    if (!await FlutterForegroundTask.isRunningService) return;
    final prefs = await SharedPreferences.getInstance();
    final t = NotifL10n.of(prefs);
    await FlutterForegroundTask.updateService(
      notificationTitle: 'Hermes Console',
      notificationText: paused ? t.readAloudPaused : t.readAloudPlaying,
      notificationIcon: _serviceNotificationIcon,
      notificationButtons: [
        NotificationButton(
          id: paused ? readAloudResumeButtonId : readAloudPauseButtonId,
          text: paused ? t.voiceContinue : t.voicePause,
        ),
        NotificationButton(id: readAloudEndButtonId, text: t.voiceEnd),
      ],
    );
    await _persistDurableRestartContract(prefs);
    _readAloudPaused = paused;
  }

  /// Proyecta Voz en la notificación del servicio Flutter compartido.
  /// Los textos son genéricos: nunca incluyen chat, transcript, respuesta,
  /// herramienta, URL ni error crudo.
  static Future<void> updateVoiceNotification({
    required VoiceNotificationState state,
  }) => _foregroundMutations.run(
    () => _updateVoiceNotificationSerialized(state: state),
  );

  static Future<void> _updateVoiceNotificationSerialized({
    required VoiceNotificationState state,
  }) async {
    if (_voiceNotificationState == state) return;
    if (!await FlutterForegroundTask.isRunningService) return;
    final prefs = await SharedPreferences.getInstance();
    final t = NotifL10n.of(prefs);
    final projection = _voiceProjection(t, state);
    await FlutterForegroundTask.updateService(
      notificationTitle: 'Hermes Console',
      notificationText: projection.text,
      notificationIcon: _voiceNotificationIcon(paused: projection.paused),
      notificationButtons: [
        NotificationButton(
          id: projection.primaryId,
          text: projection.primaryText,
        ),
        NotificationButton(id: voiceEndButtonId, text: t.voiceEndConversation),
      ],
    );
    await VoiceNotificationCardAdapter.apply(
      paused: projection.paused,
      expectedPrimaryAction: projection.primaryText,
      stateLabel: projection.stateLabel,
      microphoneLabel: projection.microphoneLabel,
      openHintLabel: projection.openHintLabel,
      orbDescription: t.voiceCardOrbDescription,
      durationDescription: t.voiceCardDurationDescription,
    );
    await _persistDurableRestartContract(prefs);
    _voiceNotificationState = state;
  }

  /// Vuelve al tipo de red exacto tras salir del modo voz, para que el
  /// BootReceiver no intente arrancar con `microphone` desde background.
  /// DEBE llamarse desde foreground. No-op si no corre o ya está degradado.
  /// Errores no fatales (la salida del modo voz nunca se bloquea).
  static Future<void> downgradeFromVoice() =>
      _foregroundMutations.run(_downgradeFromVoiceSerialized);

  static Future<void> _downgradeFromVoiceSerialized() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(voiceCardActiveKey, false);
    await VoiceNotificationCardAdapter.clear();
    if (!_voiceTypeSaved) return;
    _voiceTypeSaved = false;
    _voiceNotificationState = null;
    try {
      _configure(NotifL10n.of(prefs), autoRunOnBoot: false);
      if (await FlutterForegroundTask.isRunningService) {
        await _hardStopFlutterRuntime();
      }
      _activeNetworkMode = _ForegroundNetworkMode.none;
      if (_networkDemand(prefs)) {
        await start();
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[hermes-notif] voice downgrade falló (${error.runtimeType})',
        );
      }
    }
  }

  /// Libera únicamente el lease `mediaPlayback` de ReadAloud. No toca una
  /// conversación que haya ganado prioridad mientras se serializaba el cambio.
  static Future<void> downgradeFromReadAloud() =>
      _foregroundMutations.run(_downgradeFromReadAloudSerialized);

  static Future<void> _downgradeFromReadAloudSerialized() async {
    if (!_readAloudTypeSaved || _voiceTypeSaved) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(voiceCardActiveKey, false);
    final t = NotifL10n.of(prefs);
    _configure(t, autoRunOnBoot: false);
    _readAloudTypeSaved = false;
    _readAloudPaused = null;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await _hardStopFlutterRuntime();
      }
      _activeNetworkMode = _ForegroundNetworkMode.none;
      if (_networkDemand(prefs)) {
        await start();
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[hermes-notif] read aloud downgrade falló '
          '(${error.runtimeType})',
        );
      }
    }
  }

  /// Para el servicio. Devuelve `true` si estaba corriendo y se detuvo (para que
  /// el llamador sepa que `stopForeground` se ejecutó y conviene re-afirmar la
  /// notificación de respuesta, que el desmontaje puede arrastrar).
  static Future<bool> stop() => _foregroundMutations.run(_stopSerialized);

  static Future<bool> _stopSerialized() async {
    // El heartbeat pertenece al ciclo de vida del listener, no al de la app.
    // Cancelarlo incluso si Android ya bajó el servicio evita dejar trabajo
    // periódico vivo tras Stop, un rewind o un fallo de arranque del FGS.
    _uiHeartbeat?.cancel();
    _uiHeartbeat = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(voiceCardActiveKey, false);
    await VoiceNotificationCardAdapter.clear();
    _voiceTypeSaved = false;
    _voiceNotificationState = null;
    _readAloudTypeSaved = false;
    _readAloudPaused = null;
    _activeNetworkMode = _ForegroundNetworkMode.none;
    _externalDataSyncRevision++;
    _externalDataSyncDemand = 0;
    _activeTurnRevision++;
    _activeTurnDemand = 0;
    await prefs.setInt(externalDataSyncDemandKey, 0);
    if (await _androidSdkInt() >= 35) {
      await _setNativeExternalDataSyncRequired(false);
    }
    _configure(NotifL10n.of(prefs), autoRunOnBoot: false);
    final wasRunning = await FlutterForegroundTask.isRunningService;
    if (wasRunning && kDebugMode) {
      debugPrint('[hermes-notif] stopService');
    }
    await _hardStopFlutterRuntime();
    await _persistDurableRestartContract(prefs);
    return wasRunning;
  }

  /// Llamar al arrancar la app: si el usuario dejó la escucha activada, la
  /// re-arranca (p.ej. tras reinicio del móvil con la app abierta de nuevo).
  static Future<void> restoreIfEnabled(SharedPreferences prefs) =>
      _foregroundMutations.run(() => _restoreIfEnabledSerialized(prefs));

  static Future<void> _restoreIfEnabledSerialized(
    SharedPreferences prefs,
  ) async {
    // Una sesión de voz nunca se restaura tras proceso/boot.
    await prefs.setBool(voiceCardActiveKey, false);
    await VoiceNotificationCardAdapter.clear();
    _voiceTypeSaved = false;
    _voiceNotificationState = null;
    _readAloudTypeSaved = false;
    _readAloudPaused = null;
    _activeNetworkMode = _ForegroundNetworkMode.none;
    _externalDataSyncRevision++;
    _externalDataSyncDemand = 0;
    _activeTurnRevision++;
    _activeTurnDemand = 0;
    await prefs.setInt(externalDataSyncDemandKey, 0);
    if (await _androidSdkInt() >= 35) {
      await _setNativeExternalDataSyncRequired(false);
    }
    await _clearLegacyFiniteSessionState(prefs);
    if (!NotificationService.automationNotificationsEnabled) {
      await prefs.setBool(prefKey, false);
      await BackgroundWatch.clearAll();
      await BackgroundCronWatch.syncConnections(const <SavedConnection>[]);
      try {
        await _hardStopFlutterRuntime();
      } catch (_) {
        // Plugin ausente/no inicializado: no hay FGS gestionable en este proceso.
      }
      return;
    }
    if (prefs.getBool(prefKey) == true) {
      await ensureAutomationForeground();
    } else {
      _configure(NotifL10n.of(prefs), autoRunOnBoot: false);
      await _reconcileAfterDataSyncRelease(prefs);
    }
  }
}
