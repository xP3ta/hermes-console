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
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/kanban.dart';
import '../../utils/home_recent_sessions.dart';
import '../connection_manager.dart';
import '../secure_storage.dart';
import '../../utils/transport_privacy.dart';
import 'notification_service.dart';
import 'notification_strings.dart';
import 'voice_notification_card_adapter.dart';

/// Una ejecución vigilada en segundo plano. Sin secretos: el token se resuelve
/// desde el Keystore por [connId].
class WatchedRun {
  final String connId;
  final String base; // baseUrl del gateway (http(s)://host:port)
  final String runId;
  final String prompt;
  // Sesión asociada (para que la notificación navegue al chat al pulsarla).
  // Vacío en runs sueltas sin sesión.
  final String sessionId;
  final bool approvalNotified;

  const WatchedRun({
    required this.connId,
    required this.base,
    required this.runId,
    required this.prompt,
    this.sessionId = '',
    this.approvalNotified = false,
  });

  Map<String, dynamic> toJson() => {
    'connId': connId,
    'base': base,
    'runId': runId,
    'prompt': prompt,
    if (sessionId.isNotEmpty) 'sessionId': sessionId,
    'approvalNotified': approvalNotified,
  };

  static WatchedRun fromJson(Map<String, dynamic> j) => WatchedRun(
    connId: j['connId']?.toString() ?? '',
    base: j['base']?.toString() ?? '',
    runId: j['runId']?.toString() ?? '',
    prompt: j['prompt']?.toString() ?? '',
    sessionId: j['sessionId']?.toString() ?? '',
    approvalNotified: j['approvalNotified'] == true,
  );

  WatchedRun copyWith({bool? approvalNotified}) => WatchedRun(
    connId: connId,
    base: base,
    runId: runId,
    prompt: prompt,
    sessionId: sessionId,
    approvalNotified: approvalNotified ?? this.approvalNotified,
  );
}

/// Lista de runs vigiladas, persistida en SharedPreferences (sin secretos).
/// Compartida entre el isolate de UI (que añade/quita) y el del servicio.
class BackgroundWatch {
  static const String _key = 'bg_watch_runs';

  static Future<Directory> _lockDirectory() async {
    try {
      return await getApplicationSupportDirectory();
    } catch (error) {
      // Los tests de Dart y algunos arranques tempranos del isolate no tienen
      // aún registrado path_provider. El directorio temporal sigue siendo
      // privado para la app en Android y permite conservar la exclusión mutua.
      debugPrint(
        '[hermes-notif] support dir no disponible; se usa temp para el lock: '
        '$error',
      );
      return Directory.systemTemp;
    }
  }

  /// SharedPreferences no ofrece transacciones entre isolates. Un lock de
  /// archivo en el almacenamiento privado de la app serializa únicamente las
  /// secciones read-modify-write; nunca se mantiene durante una petición de red.
  static Future<T> _locked<T>(
    Future<T> Function(SharedPreferences prefs) action,
  ) async {
    final dir = await _lockDirectory();
    final lockFile = File('${dir.path}/background_watch.lock');
    final handle = await lockFile.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return await action(prefs);
    } finally {
      try {
        await handle.unlock();
      } catch (_) {}
      await handle.close();
    }
  }

  static List<WatchedRun> _read(SharedPreferences prefs) {
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list.map(WatchedRun.fromJson).toList();
    } catch (e) {
      debugPrint(
        '[hermes-notif] excepción silenciada (se devuelve lista vacía): $e',
      );
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

  /// Empieza a vigilar una ejecución (idempotente por runId).
  static Future<void> add(SavedRunWatch w) async {
    final safeBase = TransportPrivacy.requireAllowed(w.base);
    await _locked((prefs) async {
      final runs = _read(prefs)..removeWhere((r) => r.runId == w.runId);
      runs.add(
        WatchedRun(
          connId: w.connId,
          base: safeBase,
          runId: w.runId,
          prompt: w.prompt,
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

  static Future<void> remove(String runId) async {
    await _locked((prefs) async {
      final runs = _read(prefs)..removeWhere((r) => r.runId == runId);
      await _write(prefs, runs);
    });
  }

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
    final polledIds = snapshot.map((run) => run.runId).toSet();
    final keptById = {for (final run in keep) run.runId: run};
    final merged = <WatchedRun>[];
    for (final current in latest) {
      if (!polledIds.contains(current.runId)) {
        merged.add(current);
        continue;
      }
      final updated = keptById[current.runId];
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
    final polledIds = snapshot.map((run) => run.runId).toSet();
    final keptById = {for (final run in keep) run.runId: run};
    final merged = <WatchedRun>[];
    for (final current in latest) {
      if (!polledIds.contains(current.runId)) {
        merged.add(current);
        continue;
      }
      final updated = keptById[current.runId];
      if (updated != null) merged.add(updated);
    }
    return merged;
  }
}

/// Datos mínimos para vigilar una run (los pasa el isolate de UI).
class SavedRunWatch {
  final String connId;
  final String base;
  final String runId;
  final String prompt;
  final String sessionId;
  const SavedRunWatch({
    required this.connId,
    required this.base,
    required this.runId,
    required this.prompt,
    this.sessionId = '',
  });
}

class CronExecutionSnapshot {
  final String jobKey;
  final String jobId;
  final String title;
  final String profile;
  final String executionId;
  final String status;

  const CronExecutionSnapshot({
    required this.jobKey,
    required this.jobId,
    required this.title,
    required this.profile,
    required this.executionId,
    required this.status,
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
    );
  }

  static CronExecutionSnapshot? fromJob(Object? value) {
    if (value is! Map) return null;
    final job = value.cast<Object?, Object?>();
    final latestValue = job['latest_execution'];
    if (latestValue is! Map) return null;
    final latest = latestValue.cast<Object?, Object?>();
    final jobId = (job['id'] ?? '').toString().trim();
    final profile = (job['profile'] ?? '').toString().trim();
    final executionId = (latest['id'] ?? '').toString().trim();
    final status = (latest['status'] ?? '').toString().trim().toLowerCase();
    if (jobId.isEmpty || executionId.isEmpty || status.isEmpty) return null;
    final name = (job['name'] ?? '').toString().trim();
    return CronExecutionSnapshot(
      jobKey: '${profile.isEmpty ? 'default' : profile}::$jobId',
      jobId: jobId,
      title: name.isEmpty ? jobId : name,
      profile: profile,
      executionId: executionId,
      status: status,
    );
  }
}

/// Instancias cuyos resultados Cron puede descubrir el servicio aunque el run
/// no haya sido iniciado desde Android. Solo persiste metadatos de conexión y
/// cursores de ejecución; las credenciales siguen resolviéndose desde Keystore.
class BackgroundCronWatch {
  static const String _targetsKey = 'bg_cron_targets_v1';
  static const String _executionStateKey = 'bg_cron_executions_v2';
  static const int _maxJobsPerConnection = 200;
  static const int _maxFreshPerPoll = 5;

  static List<String> cronJobEndpoints() => const [
    'cron/jobs?profile=all',
    'cron/jobs',
  ];

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

  static Session? sessionForExecution(
    CronExecutionSnapshot execution,
    List<Session> sessions,
  ) {
    final prefix = 'cron_${execution.jobId}_';
    for (final session in sessions) {
      if (!session.id.startsWith(prefix)) continue;
      final sessionProfile = session.profile?.trim() ?? '';
      if (execution.profile.isNotEmpty &&
          sessionProfile.isNotEmpty &&
          execution.profile != sessionProfile) {
        continue;
      }
      return session;
    }
    return null;
  }

  static Future<List<CronExecutionSnapshot>?> loadExecutions(
    Future<Map<String, dynamic>> Function(String endpoint) apiGet,
  ) async {
    final endpoints = cronJobEndpoints();
    late final Map<String, dynamic> data;
    try {
      data = await apiGet(endpoints.first);
    } on DashboardHttpException catch (error) {
      if (!_unsupportedAllProfiles(error.statusCode)) rethrow;
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

  static bool _unsupportedAllProfiles(int statusCode) =>
      statusCode == 400 ||
      statusCode == 404 ||
      statusCode == 405 ||
      statusCode == 422 ||
      statusCode == 501;

  static Future<void> syncConnections(List<SavedConnection> connections) =>
      BackgroundWatch._locked((prefs) async {
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
      });

  static Future<List<SavedConnection>> snapshotTargets() =>
      BackgroundWatch._locked((prefs) async {
        final raw = prefs.getString(_targetsKey);
        if (raw == null || raw.isEmpty) return const [];
        try {
          return (jsonDecode(raw) as List)
              .whereType<Map>()
              .map(
                (value) =>
                    SavedConnection.fromMap(value.cast<String, dynamic>()),
              )
              .toList(growable: false);
        } catch (error) {
          debugPrint('[hermes-notif] cron targets inválidos: $error');
          return const [];
        }
      });

  /// Reclama transiciones terminales del ledger oficial de ejecuciones Cron.
  /// Crear la sesión ya no se confunde con terminarla: `claimed` y `running`
  /// solo avanzan el cursor, mientras `completed`/`failed`/`unknown` avisan.
  static Future<List<CronExecutionSnapshot>> claimExecutions(
    String connId,
    List<CronExecutionSnapshot> executions,
  ) => BackgroundWatch._locked((prefs) async {
    final state = _readExecutionState(prefs);
    final rawRow = state[connId];
    final row = rawRow is Map
        ? rawRow.cast<String, dynamic>()
        : const <String, dynamic>{};
    final previous = <String, CronExecutionSnapshot>{};
    final rawJobs = row['jobs'];
    if (rawJobs is Map) {
      for (final entry in rawJobs.entries) {
        final snapshot = CronExecutionSnapshot.fromJson(entry.value);
        if (snapshot != null) previous[entry.key.toString()] = snapshot;
      }
    }
    final claimed = claimExecutionsForTest(
      initialized: row['initialized'] == true,
      previous: previous,
      current: executions,
    );
    state[connId] = {
      'initialized': true,
      'jobs': {
        for (final entry in claimed.states.entries)
          entry.key: entry.value.toJson(),
      },
    };
    await prefs.setString(_executionStateKey, jsonEncode(state));
    return claimed.fresh;
  });

  static Map<String, dynamic> _readExecutionState(SharedPreferences prefs) {
    final raw = prefs.getString(_executionStateKey);
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic>
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

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
      if (initialized && becameTerminal && fresh.length < _maxFreshPerPoll) {
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

/// Cursor local para los estados del Kanban oficial de Hermes Agent.
///
/// La primera lectura siembra el tablero y no repite el historial. Después
/// solo reclama transiciones que requieren atención en móvil: completada,
/// bloqueada o enviada a triage. El estado se avanza incluso si la UI está en
/// primer plano, de modo que una transición no se duplica al volver al fondo.
class BackgroundKanbanWatch {
  static const String _stateKey = 'bg_kanban_state_v1';
  static const int _maxTasksPerConnection = 500;
  static const int _maxFreshPerPoll = 5;
  static const Set<String> _notifiableStatuses = {'done', 'blocked', 'triage'};

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

  static Future<List<KanbanNotificationTransition>> claimTransitions(
    String connId,
    List<KanbanTask> tasks,
  ) => BackgroundWatch._locked((prefs) async {
    final state = _readState(prefs);
    final rawRow = state[connId];
    final row = rawRow is Map
        ? rawRow.cast<String, dynamic>()
        : const <String, dynamic>{};
    final previous = <String, String>{};
    final rawStatuses = row['statuses'];
    if (rawStatuses is Map) {
      for (final entry in rawStatuses.entries) {
        final id = entry.key.toString().trim();
        final status = entry.value.toString().trim().toLowerCase();
        if (id.isNotEmpty && status.isNotEmpty) previous[id] = status;
      }
    }

    final claimed = claimForTest(
      initialized: row['initialized'] == true,
      previous: previous,
      current: tasks,
    );
    state[connId] = {'initialized': true, 'statuses': claimed.statuses};
    await prefs.setString(_stateKey, jsonEncode(state));
    return claimed.fresh;
  });

  static Map<String, dynamic> _readState(SharedPreferences prefs) {
    final raw = prefs.getString(_stateKey);
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic>
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
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
          !_notifiableStatuses.contains(status) ||
          fresh.length >= _maxFreshPerPoll) {
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

/// Propietario del único foreground service con audio. La prioridad es
/// deliberada: una conversación opt-in conserva sus controles y micrófono;
/// después va la lectura puntual y finalmente el sondeo dataSync.
enum ForegroundAudioOwner { dataSync, readAloud, voiceConversation }

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

  static const int _kActiveIntervalMs = 30000;
  static const int _kCronIntervalMs = 60000;
  static const int _kIdleIntervalMs = 180000;
  int _currentIntervalMs = _kActiveIntervalMs;

  /// Cambia el ritmo del repeat del FGS solo cuando difiere del actual.
  void _setPollInterval(int ms) {
    if (ms == _currentIntervalMs) return;
    _currentIntervalMs = ms;
    FlutterForegroundTask.updateService(
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(ms),
        allowWakeLock: false,
        allowWifiLock: false,
      ),
    );
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[hermes-notif] foreground task onStart (isolate de servicio)');
    final prefs = await SharedPreferences.getInstance();
    _notif = NotificationService(prefs)..appInForeground = false;
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // onRepeatEvent es síncrono; lanzamos el sondeo sin bloquear.
    _poll();
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final voiceCardActive =
          prefs.getBool(BackgroundListener.voiceCardActiveKey) == true;
      final audioCardActive = voiceCardActive;
      final runs = await BackgroundWatch.snapshot();
      final cronTargets = await BackgroundCronWatch.snapshotTargets();
      _dashboardClients.retainConnections(cronTargets);
      _discoveryBackoff.retainConnections(cronTargets);
      if (runs.isEmpty && cronTargets.isEmpty) {
        if (!audioCardActive) _setPollInterval(_kIdleIntervalMs);
        if (audioCardActive) {
          _emptyPolls = 0;
          return;
        }
        return await _maybeAutoStop(prefs);
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
        // Con opt-in de escucha permanente y NADA que vigilar, baja el ritmo
        // a 3 min: cada tick despierta CPU con wakelock retenido, y a 30s el
        // coste de batería no compra nada (spec 028). Vuelve a 30s en cuanto
        // entra una run vigilada.
        if (!audioCardActive) {
          _setPollInterval(
            watchesCron || watchesKanban ? _kCronIntervalMs : _kIdleIntervalMs,
          );
        }
        if (audioCardActive) {
          _emptyPolls = 0;
          return;
        }
        return await _maybeAutoStop(prefs);
      }
      _emptyPolls = 0;
      if (!audioCardActive) _setPollInterval(_kActiveIntervalMs);

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
      debugPrint(
        '[hermes-notif] BG updateService (keep=${keep.length}) @${DateTime.now().toIso8601String()}',
      );
      if (!audioCardActive) {
        final t = NotifL10n.of(prefs);
        FlutterForegroundTask.updateService(
          notificationTitle: 'Hermes Console',
          notificationText: keep.isEmpty
              ? t.bgActive
              : t.bgWatching(keep.length),
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('BG poll error: $e');
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
            '[hermes-notif] cron discovery ${connection.id} falló: $error',
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
        final fresh = await BackgroundCronWatch.claimExecutions(
          connection.id,
          executions,
        );
        if (fresh.isEmpty || (uiForeground && !notif.evenInForeground)) {
          continue;
        }

        var sessions = const <Session>[];
        try {
          final endpoints = BackgroundCronWatch.cronSessionEndpoints();
          late final Map<String, dynamic> data;
          try {
            data = await dashboard.apiGet(endpoints.first);
          } on DashboardHttpException catch (error) {
            if (error.statusCode != 404) rethrow;
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
              '[hermes-notif] cron destinations ${connection.id} falló: $error',
            );
          }
        }

        for (final execution in fresh.reversed) {
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
          } catch (error) {
            if (kDebugMode) {
              debugPrint(
                '[hermes-notif] cron preview ${connection.id} no disponible: '
                '${error.runtimeType}',
              );
            }
          }
          await notif.cronFinished(
            title: session?.displayTitle ?? execution.title,
            ok: execution.ok,
            connId: connection.id,
            sessionId: destination?.sessionId ?? '',
            profile:
                destination?.profile ??
                (execution.profile.isEmpty ? null : execution.profile),
            preview: preview,
          );
        }
      } catch (error) {
        if (kDebugMode) {
          debugPrint(
            '[hermes-notif] cron processing ${connection.id} falló: $error',
          );
        }
      }
    }
    return true;
  }

  /// Observa el board nativo de Agent 0.20 con el mismo opt-in de
  /// "Resultados de automatizaciones" usado por Cron. En servidores legacy
  /// sin Kanban, [BackgroundKanbanWatch.loadTasks] devuelve null y este camino
  /// se limita a no hacer nada.
  Future<bool> _discoverKanbanTransitions(
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
            '[hermes-notif] kanban discovery ${connection.id} falló: $error',
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
        final fresh = await BackgroundKanbanWatch.claimTransitions(
          connection.id,
          tasks,
        );
        if (uiForeground && !notif.evenInForeground) continue;
        for (final transition in fresh) {
          await notif.kanbanTransition(
            taskId: transition.taskId,
            title: transition.title,
            status: transition.status,
          );
        }
      } catch (error) {
        if (kDebugMode) {
          debugPrint(
            '[hermes-notif] kanban processing ${connection.id} falló: $error',
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
  /// sin trabajo y el servicio huérfano tras barrer la app; los turnos
  /// locales y sesiones SSH en 2º plano quedan protegidos porque el isolate
  /// de UI vivo refresca el heartbeat cada minuto.
  Future<void> _maybeAutoStop(SharedPreferences prefs) async {
    if (prefs.getBool(BackgroundListener.prefKey) == true) {
      _emptyPolls = 0;
      return;
    }
    _emptyPolls++;
    if (_emptyPolls < 2) return;
    final uiAt = prefs.getInt(BackgroundListener.uiAliveKey) ?? 0;
    final staleMs = DateTime.now().millisecondsSinceEpoch - uiAt;
    if (staleMs < 3 * 60 * 1000) return;
    debugPrint(
      '[hermes-notif] auto-stop: sin trabajo, sin opt-in y sin UI viva',
    );
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
    // Parada pedida desde la notificación: apaga también el opt-in para que
    // el servicio no se rearme en el siguiente arranque (boot o app).
    SharedPreferences.getInstance()
        .then((p) => p.setBool(BackgroundListener.prefKey, false))
        .whenComplete(FlutterForegroundTask.stopService);
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
      debugPrint('[hermes-notif] poll run ${r.runId} → HTTP ${res.statusCode}');

      // 404 = run barrida por el gateway tras completar. Como solo vigilamos
      // runs que creamos con id válido, esto significa que terminó mientras el
      // isolate de UI estaba muerto: avisamos (la UI viva ya habría quitado la
      // vigilancia antes de este sondeo, así que no duplicamos).
      if (res.statusCode == 404) {
        final title = r.prompt.trim().isEmpty ? 'Agent task' : r.prompt.trim();
        await notif.cancelApproval();
        await notif.runFinished(
          title: title,
          ok: true,
          connId: r.connId,
          sessionId: r.sessionId,
        );
        return null;
      }
      if (res.statusCode != 200) return r; // reintentar luego

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final status = (body['status'] ?? '').toString();
      debugPrint('[hermes-notif] run ${r.runId} status="$status"');
      final title = r.prompt.trim().isEmpty ? 'Agent task' : r.prompt.trim();

      if (status == 'waiting_for_approval') {
        if (!r.approvalNotified) {
          await notif.approvalPending(
            tool: title,
            connId: r.connId,
            sessionId: r.sessionId,
            // runId + base habilitan los botones Aprobar/Rechazar resolubles en
            // segundo plano (POST /v1/runs/{id}/approval) sin abrir la app.
            runId: r.runId,
            base: r.base,
          );
          return r.copyWith(approvalNotified: true);
        }
        return r;
      }
      if (status == 'completed' ||
          status == 'failed' ||
          status == 'cancelled') {
        await notif.cancelApproval();
        await notif.runFinished(
          title: title,
          ok: status == 'completed',
          connId: r.connId,
          sessionId: r.sessionId,
        );
        return null; // dejar de vigilar
      }
      return r; // queued/running → seguir
    } catch (e) {
      debugPrint(
        '[hermes-notif] excepción silenciada (se continúa sin propagar): $e',
      );
      return r; // error transitorio → reintentar en el próximo ciclo
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
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
  /// Margen para que el port entre isolates entregue `end` antes de destruir
  /// el engine del foreground task. Sin él, el servicio podía cortar el
  /// micrófono pero perder la orden destinada a cerrar la UI principal.
  @visibleForTesting
  static const Duration terminalActionDeliveryGrace = Duration(
    milliseconds: 750,
  );

  static const String _voiceSessionEnvelopeType = 'voice_session';
  static const String _readAloudEnvelopeType = 'read_aloud';
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
  static Timer? _uiHeartbeat;
  static final OrderedForegroundStateWriter _uiForegroundWriter =
      OrderedForegroundStateWriter();

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
    // Un FGS de micrófono nunca puede resucitar desde BOOT_COMPLETED. Al entrar
    // en voz esta opción se guarda como false antes de reiniciar el servicio;
    // al degradar de nuevo a dataSync se restaura el opt-in normal.
    autoRunOnBoot: autoRunOnBoot,
    autoRunOnMyPackageReplaced: autoRunOnBoot,
    // Un propietario de audio nunca se reconstruye desde RestartReceiver: el
    // siguiente arranque válido pertenece a una Activity visible y repite el
    // handshake. dataSync conserva la recuperación histórica.
    allowAutoRestart: autoRunOnBoot,
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
    } catch (e) {
      debugPrint('[hermes-notif] excepción silenciada (se ignora sin más): $e');
    }
    _configure(t, autoRunOnBoot: true);
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
      }
    } catch (e) {
      if (kDebugMode) debugPrint('BackgroundListener.updateText falló: $e');
    }
  }

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefKey) == true;
  }

  /// Arranca el servicio. Devuelve si quedó corriendo.
  static Future<bool> start() async {
    await ensureInitialized();
    await _touchUiAlive();
    _armUiHeartbeat();
    if (await FlutterForegroundTask.isRunningService) return true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(voiceCardActiveKey, false);
    _voiceTypeSaved = false;
    _voiceNotificationState = null;
    _readAloudTypeSaved = false;
    _readAloudPaused = null;
    final t = NotifL10n.of(prefs);
    _configure(t, autoRunOnBoot: true);
    final result = await FlutterForegroundTask.startService(
      serviceId: 256,
      // SOLO dataSync: seguro en el arranque de boot (contexto background en
      // Android 14+). El tipo `microphone` NO puede iniciarse desde background
      // (ForegroundServiceStartNotAllowedException) — se añade solo al entrar al
      // modo voz desde foreground vía startForVoice().
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      notificationTitle: 'Hermes Console',
      notificationText: t.bgActive,
      notificationIcon: _serviceNotificationIcon,
      // A-303 (spec 028): acción de parada directa en la notificación — la
      // declaración FGS de Play promete que el usuario controla el servicio.
      notificationButtons: [NotificationButton(id: 'stop', text: t.bgStop)],
      callback: hermesForegroundCallback,
    );
    final ok = result is ServiceRequestSuccess;
    if (kDebugMode && !ok) {
      debugPrint('BackgroundListener.start falló: $result');
    }
    return ok;
  }

  /// True si el FGS se arrancó en esta sesión con el tipo `microphone`
  /// (vía [startForVoice]). Permite que startForVoice sea idempotente.
  static bool _voiceTypeSaved = false;
  static bool _readAloudTypeSaved = false;
  static VoiceNotificationState? _voiceNotificationState;
  static bool? _readAloudPaused;

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

  /// Arranca/reinicia el servicio con microphone + mediaPlayback. Debe llamarse
  /// desde foreground (al entrar al modo voz): en Android 14+ un FGS
  /// `microphone` no puede iniciarse desde background. El plugin no permite
  /// cambiar `serviceTypes` en caliente (solo actualiza la notificación), así
  /// que si ya corre con dataSync lo para y lo reinicia (stop limpia los tipos
  /// en prefs; el siguiente
  /// start los reescribe). Idempotente en la sesión (si ya tenía microphone).
  static Future<bool> startForVoice() async {
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
      return true;
    }
    if (running) await FlutterForegroundTask.stopService();
    _readAloudTypeSaved = false;
    _readAloudPaused = null;
    final result = await FlutterForegroundTask.startService(
      serviceId: 256,
      serviceTypes: const [
        ForegroundServiceTypes.microphone,
        ForegroundServiceTypes.mediaPlayback,
      ],
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
      await prefs.setBool(voiceCardActiveKey, false);
      _configure(t, autoRunOnBoot: true);
    }
    if (kDebugMode && !ok) {
      debugPrint('BackgroundListener.startForVoice falló: $result');
    }
    return ok;
  }

  /// Arranca el mismo FGS con `mediaPlayback`, sin micrófono. El contenido es
  /// siempre redactado y la sesión no se restaura tras process death/boot.
  static Future<bool> startForReadAloud({required bool paused}) async {
    await ensureInitialized();
    final prefs = await SharedPreferences.getInstance();
    final t = NotifL10n.of(prefs);
    await prefs.setBool(voiceCardActiveKey, true);
    _configure(t, autoRunOnBoot: false);
    final running = await FlutterForegroundTask.isRunningService;
    if (running && _readAloudTypeSaved) {
      await updateReadAloudNotification(paused: paused);
      return true;
    }
    if (running) await FlutterForegroundTask.stopService();
    await VoiceNotificationCardAdapter.clear();
    _voiceTypeSaved = false;
    _voiceNotificationState = null;
    final result = await FlutterForegroundTask.startService(
      serviceId: 256,
      serviceTypes: const [ForegroundServiceTypes.mediaPlayback],
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
    } else {
      await prefs.setBool(voiceCardActiveKey, false);
      _configure(t, autoRunOnBoot: true);
    }
    if (kDebugMode && !ok) {
      debugPrint('BackgroundListener.startForReadAloud falló: $result');
    }
    return ok;
  }

  static Future<void> updateReadAloudNotification({
    required bool paused,
  }) async {
    if (!_readAloudTypeSaved || _readAloudPaused == paused) return;
    if (!await FlutterForegroundTask.isRunningService) return;
    final t = NotifL10n.of(await SharedPreferences.getInstance());
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
    _readAloudPaused = paused;
  }

  /// Proyecta el estado de voz en la misma notificación del único FGS.
  /// Los textos son genéricos: nunca incluyen chat, transcript, respuesta,
  /// herramienta, URL ni error crudo.
  static Future<void> updateVoiceNotification({
    required VoiceNotificationState state,
  }) async {
    if (_voiceNotificationState == state) return;
    if (!await FlutterForegroundTask.isRunningService) return;
    final t = NotifL10n.of(await SharedPreferences.getInstance());
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
    _voiceNotificationState = state;
  }

  /// Vuelve a dataSync-solo tras salir del modo voz, para que el BootReceiver no
  /// intente arrancar con `microphone` desde background en el próximo reinicio.
  /// DEBE llamarse desde foreground. No-op si no corre o ya está en dataSync.
  /// Errores no fatales (la salida del modo voz nunca se bloquea).
  static Future<void> downgradeFromVoice() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(voiceCardActiveKey, false);
    await VoiceNotificationCardAdapter.clear();
    final t = NotifL10n.of(prefs);
    _configure(t, autoRunOnBoot: true);
    if (!_voiceTypeSaved) return;
    _voiceTypeSaved = false;
    _voiceNotificationState = null;
    try {
      if (!await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.stopService();
      await FlutterForegroundTask.startService(
        serviceId: 256,
        serviceTypes: const [ForegroundServiceTypes.dataSync],
        notificationTitle: 'Hermes Console',
        notificationText: t.bgActive,
        notificationIcon: _serviceNotificationIcon,
        notificationButtons: [NotificationButton(id: 'stop', text: t.bgStop)],
        callback: hermesForegroundCallback,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('BackgroundListener.downgradeFromVoice falló: $e');
      }
    }
  }

  /// Libera únicamente el lease `mediaPlayback` de ReadAloud. No toca una
  /// conversación que haya ganado prioridad mientras se serializaba el cambio.
  static Future<void> downgradeFromReadAloud() async {
    if (!_readAloudTypeSaved || _voiceTypeSaved) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(voiceCardActiveKey, false);
    final t = NotifL10n.of(prefs);
    _configure(t, autoRunOnBoot: true);
    _readAloudTypeSaved = false;
    _readAloudPaused = null;
    try {
      if (!await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.stopService();
      await FlutterForegroundTask.startService(
        serviceId: 256,
        serviceTypes: const [ForegroundServiceTypes.dataSync],
        notificationTitle: 'Hermes Console',
        notificationText: t.bgActive,
        notificationIcon: _serviceNotificationIcon,
        notificationButtons: [NotificationButton(id: 'stop', text: t.bgStop)],
        callback: hermesForegroundCallback,
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('BackgroundListener.downgradeFromReadAloud falló: $error');
      }
    }
  }

  /// Para el servicio. Devuelve `true` si estaba corriendo y se detuvo (para que
  /// el llamador sepa que `stopForeground` se ejecutó y conviene re-afirmar la
  /// notificación de respuesta, que el desmontaje puede arrastrar).
  static Future<bool> stop() async {
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
    _configure(NotifL10n.of(prefs), autoRunOnBoot: true);
    if (await FlutterForegroundTask.isRunningService) {
      debugPrint(
        '[hermes-notif] BackgroundListener.stop → stopService @${DateTime.now().toIso8601String()}',
      );
      await FlutterForegroundTask.stopService();
      return true;
    }
    return false;
  }

  /// Llamar al arrancar la app: si el usuario dejó la escucha activada, la
  /// re-arranca (p.ej. tras reinicio del móvil con la app abierta de nuevo).
  static Future<void> restoreIfEnabled(SharedPreferences prefs) async {
    // Una sesión de voz nunca se restaura tras proceso/boot. Limpiar primero la
    // lease visual y rearmar únicamente la política dataSync normal. El rearme
    // del detector consentido pertenece después a la Activity visible.
    await prefs.setBool(voiceCardActiveKey, false);
    await VoiceNotificationCardAdapter.clear();
    _voiceTypeSaved = false;
    _voiceNotificationState = null;
    _readAloudTypeSaved = false;
    _readAloudPaused = null;
    _configure(NotifL10n.of(prefs), autoRunOnBoot: true);
    if (prefs.getBool(prefKey) == true) {
      await start();
    }
  }
}
