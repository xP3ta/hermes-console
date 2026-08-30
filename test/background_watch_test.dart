import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/services/notifications/background_listener.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';

WatchedRun _run(String id, {bool approvalNotified = false}) => WatchedRun(
  connId: 'conn',
  base: 'https://hermes.example',
  runId: id,
  prompt: id,
  approvalNotified: approvalNotified,
);

KanbanTask _kanbanTask(String id, String status) =>
    KanbanTask(id: id, title: 'Task $id', body: '', status: status);

CronExecutionSnapshot _cronExecution(String executionId, String status) =>
    CronExecutionSnapshot(
      jobKey: 'default::job-1',
      jobId: 'job-1',
      title: 'Housing search',
      profile: 'default',
      executionId: executionId,
      status: status,
    );

SavedConnection _dashboardConnection({
  String id = 'demo-node',
  String dashboardUrl = 'http://192.168.1.40:9119',
  AuthMode dashboardAuthMode = AuthMode.cookieSession,
}) => SavedConnection(
  id: id,
  label: 'Hermes Demo',
  host: '192.168.1.40',
  port: 8642,
  apiKey: '',
  dashboardUrl: dashboardUrl,
  dashboardAuthMode: dashboardAuthMode,
);

class _TrackedHttpClient extends http.BaseClient {
  int closeCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnimplementedError();

  @override
  void close() {
    closeCalls++;
    super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => BackgroundWatch.automationNotificationsEnabledOverride = true);
  tearDown(() => BackgroundWatch.automationNotificationsEnabledOverride = null);

  test('1.2.8 conservative does not persist background watches', () async {
    BackgroundWatch.automationNotificationsEnabledOverride = false;
    SharedPreferences.setMockInitialValues({});
    await BackgroundWatch.add(
      const SavedRunWatch(
        connId: 'conn',
        base: 'https://hermes.example',
        runId: 'run-1',
        prompt: 'safe',
      ),
    );
    expect(await BackgroundWatch.snapshot(), isEmpty);
  });

  test('rechaza una vigilancia HTTP pública antes de persistirla', () async {
    SharedPreferences.setMockInitialValues({});

    await expectLater(
      BackgroundWatch.add(
        const SavedRunWatch(
          connId: 'conn',
          base: 'http://gateway.example.com:8642',
          runId: 'unsafe',
          prompt: 'must stay local',
        ),
      ),
      throwsArgumentError,
    );
    expect(await BackgroundWatch.snapshot(), isEmpty);
  });

  test('merge del poll conserva runs añadidos mientras había red en curso', () {
    final original = _run('a');
    final addedDuringPoll = _run('b');

    final merged = BackgroundWatch.mergeForTest(
      latest: [original, addedDuringPoll],
      snapshot: [original],
      keep: [original.copyWith(approvalNotified: true)],
    );

    expect(merged.map((run) => run.runId), ['a', 'b']);
    expect(merged.first.approvalNotified, isTrue);
  });

  test('merge del poll no resucita runs eliminados por la UI', () {
    final original = _run('a');
    final merged = BackgroundWatch.mergeForTest(
      latest: const [],
      snapshot: [original],
      keep: [original],
    );

    expect(merged, isEmpty);
  });

  test('merge elimina únicamente terminales presentes en el snapshot', () {
    final terminal = _run('a');
    final newRun = _run('b');
    final merged = BackgroundWatch.mergeForTest(
      latest: [terminal, newRun],
      snapshot: [terminal],
      keep: const [],
    );

    expect(merged.map((run) => run.runId), ['b']);
  });

  test('foreground writer conserva el orden real del lifecycle', () async {
    final writer = OrderedForegroundStateWriter();
    final releaseFirst = Completer<void>();
    final persisted = <bool>[];

    final initial = writer.write(true, (value) async {
      persisted.add(value);
      await releaseFirst.future;
    });
    final background = writer.write(false, (value) async {
      persisted.add(value);
    });
    await Future<void>.delayed(Duration.zero);

    expect(persisted, [true]);
    releaseFirst.complete();
    await Future.wait([initial, background]);
    expect(persisted, [true, false]);
  });

  test('cron siembra ejecuciones previas sin repetir resultados antiguos', () {
    final seeded = BackgroundCronWatch.claimExecutionsForTest(
      initialized: false,
      previous: const {},
      current: [_cronExecution('execution-old', 'completed')],
    );
    expect(seeded.fresh, isEmpty);
    expect(seeded.states['default::job-1']?.status, 'completed');
  });

  test('cron no avisa al crear sesión y espera al terminal de ejecución', () {
    final running = BackgroundCronWatch.claimExecutionsForTest(
      initialized: true,
      previous: const {},
      current: [_cronExecution('execution-1', 'running')],
    );
    expect(running.fresh, isEmpty);

    final completed = BackgroundCronWatch.claimExecutionsForTest(
      initialized: true,
      previous: running.states,
      current: [_cronExecution('execution-1', 'completed')],
    );
    expect(completed.fresh.single.executionId, 'execution-1');
    expect(completed.fresh.single.ok, isTrue);

    final repeated = BackgroundCronWatch.claimExecutionsForTest(
      initialized: true,
      previous: completed.states,
      current: [_cronExecution('execution-1', 'completed')],
    );
    expect(repeated.fresh, isEmpty);
  });

  test('cron avisa si una ejecución nueva ya apareció terminada', () {
    final completed = BackgroundCronWatch.claimExecutionsForTest(
      initialized: true,
      previous: {
        'default::job-1': _cronExecution('execution-old', 'completed'),
      },
      current: [_cronExecution('execution-new', 'failed')],
    );

    expect(completed.fresh.single.executionId, 'execution-new');
    expect(completed.fresh.single.ok, isFalse);
  });

  test(
    'resultados cron son opt-in y migran la escucha ya autorizada',
    () async {
      SharedPreferences.setMockInitialValues({});
      var prefs = await SharedPreferences.getInstance();
      var notifications = NotificationService(
        prefs,
        automationNotificationsEnabled: true,
      );
      expect(notifications.notifyCronResults, isFalse);

      SharedPreferences.setMockInitialValues({
        BackgroundListener.prefKey: true,
      });
      prefs = await SharedPreferences.getInstance();
      notifications = NotificationService(
        prefs,
        automationNotificationsEnabled: true,
      );
      expect(notifications.notifyCronResults, isTrue);

      await notifications.setNotifyCronResults(false);
      expect(notifications.notifyCronResults, isFalse);
    },
  );

  test('cron solo interrumpe por resultado material tipado o fallo', () {
    final completed = _cronExecution('execution-ok', 'completed');
    final failed = _cronExecution('execution-failed', 'failed');
    const cronSession = Session(
      id: 'cron_job-1_20260828',
      title: 'Housing search',
      model: '',
      source: 'cron',
      messageCount: 2,
      isActive: false,
      preview: '',
      startedAt: 0,
    );

    expect(
      BackgroundCronWatch.shouldNotifyResult(
        completed,
        session: cronSession,
        preview: null,
      ),
      isFalse,
    );
    expect(
      BackgroundCronWatch.shouldNotifyResult(
        completed,
        session: cronSession,
        preview: '   ',
      ),
      isFalse,
    );
    expect(
      BackgroundCronWatch.shouldNotifyResult(
        completed,
        session: cronSession,
        preview: '[SILENT]',
      ),
      isFalse,
    );
    expect(
      BackgroundCronWatch.shouldNotifyResult(
        completed,
        session: cronSession,
        preview: 'no_change',
      ),
      isFalse,
    );
    expect(
      BackgroundCronWatch.shouldNotifyResult(
        completed,
        session: cronSession,
        preview: 'Entrada registrada y verificada · 08:03',
      ),
      isTrue,
    );
    expect(
      BackgroundCronWatch.shouldNotifyResult(
        completed,
        session: null,
        preview: 'Texto sin sesión autoritativa',
      ),
      isFalse,
    );
    expect(
      BackgroundCronWatch.shouldNotifyResult(
        completed,
        session: cronSession,
        preview: 'silent',
      ),
      isTrue,
    );
    expect(
      BackgroundCronWatch.shouldNotifyResult(
        failed,
        session: null,
        preview: null,
      ),
      isTrue,
    );
  });

  test('HTTP 404 no permite inferir que un run terminó correctamente', () {
    expect(BackgroundListener.canInferRunOutcomeFromHttpStatus(404), isFalse);
    expect(BackgroundListener.canInferRunOutcomeFromHttpStatus(500), isFalse);
    expect(BackgroundListener.canInferRunOutcomeFromHttpStatus(200), isTrue);
  });

  test('cron usa el agregado de perfiles de Desktop y fallback compatible', () {
    final endpoints = BackgroundCronWatch.cronSessionEndpoints();
    final jobEndpoints = BackgroundCronWatch.cronJobEndpoints();

    expect(endpoints, hasLength(2));
    expect(endpoints.first, startsWith('profiles/sessions?'));
    expect(endpoints.first, contains('profile=all'));
    expect(endpoints.first, contains('source=cron'));
    expect(endpoints.last, startsWith('sessions?'));
    expect(endpoints.last, isNot(contains('profile=all')));
    expect(endpoints.last, contains('source=cron'));
    expect(jobEndpoints, ['cron/jobs?profile=all', 'cron/jobs']);
  });

  test('cron lee el ledger terminal oficial de Agent 0.20', () async {
    final executions = await BackgroundCronWatch.loadExecutions((
      endpoint,
    ) async {
      expect(endpoint, 'cron/jobs?profile=all');
      return {
        'data': [
          {
            'id': 'job-1',
            'name': 'Housing search',
            'profile': 'research',
            'latest_execution': {'id': 'execution-1', 'status': 'completed'},
          },
        ],
      };
    });

    expect(executions, hasLength(1));
    expect(executions!.single.jobKey, 'research::job-1');
    expect(executions.single.executionId, 'execution-1');
    expect(executions.single.terminal, isTrue);
  });

  test('cron notification opens its chat instead of Task Center', () {
    const session = Session(
      id: 'cron_job_20260802_0010',
      title: 'QA notification',
      model: '',
      source: 'cron',
      messageCount: 2,
      isActive: false,
      preview: 'prueba cron completada',
      startedAt: 0,
      profile: 'research',
      isDefaultProfile: false,
    );

    final destination = BackgroundCronWatch.notificationDestination(session);

    expect(destination.sessionId, session.id);
    expect(destination.profile, 'research');
    expect(destination.taskCenterRunId, isNull);
  });

  test(
    'cron hidrata el último resultado si la lista no trae preview',
    () async {
      const session = Session(
        id: 'cron_job_20260804_180956',
        title: 'Housing search',
        model: '',
        source: 'cron',
        messageCount: 3,
        isActive: false,
        preview: 'prompt privado que no debe notificarse',
        startedAt: 0,
        profile: 'research',
        isDefaultProfile: false,
      );
      final calls = <(String, String)>[];

      final preview = await BackgroundCronWatch.notificationPreview(session, (
        sessionId,
        profile,
      ) async {
        calls.add((sessionId, profile));
        return const [
          {'role': 'user', 'content': 'prompt privado'},
          {'role': 'assistant', 'content': '**2 compras nuevas verificadas**'},
        ];
      });

      expect(calls, [('cron_job_20260804_180956', 'research')]);
      expect(preview, '2 compras nuevas verificadas');
      expect(preview, isNot(contains('prompt privado')));
    },
  );

  test('cron no relee mensajes si Agent ya anuncia el resultado', () async {
    const session = Session(
      id: 'cron_job_20260804_180956',
      title: 'Housing search',
      model: '',
      source: 'cron',
      messageCount: 3,
      isActive: false,
      preview: 'prompt privado',
      lastAssistantPreview: 'Sin compras nuevas verificadas.',
      startedAt: 0,
    );

    final preview = await BackgroundCronWatch.notificationPreview(
      session,
      (_, _) => throw StateError('no debe consultar el transcript'),
    );

    expect(preview, 'Sin compras nuevas verificadas.');
  });

  test('cron targets persist connection metadata without API keys', () async {
    SharedPreferences.setMockInitialValues({});
    await BackgroundCronWatch.syncConnections([
      SavedConnection(
        id: 'demo-node',
        label: 'Server',
        host: '192.168.1.40',
        port: 8642,
        apiKey: 'must-not-be-persisted',
        dashboardUrl: 'http://192.168.1.40:9119',
      ),
    ]);

    final targets = await BackgroundCronWatch.snapshotTargets();
    expect(targets.single.id, 'demo-node');
    expect(targets.single.apiKey, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getKeys().map((key) => prefs.get(key).toString()).join(' '),
      isNot(contains('must-not-be-persisted')),
    );
  });

  test('cron y kanban reutilizan el mismo cliente Dashboard por instancia', () {
    final transports = <_TrackedHttpClient>[];
    final cache = BackgroundDashboardClientCache(
      create: (connection) {
        final transport = _TrackedHttpClient();
        transports.add(transport);
        return DashboardClient.lazy(connection, httpClientOverride: transport);
      },
    );
    final connection = _dashboardConnection();

    final cronClient = cache.clientFor(connection);
    final kanbanClient = cache.clientFor(connection);

    expect(kanbanClient, same(cronClient));
    expect(transports, hasLength(1));
    cache.close();
    expect(transports.single.closeCalls, 1);
  });

  test('cache Dashboard invalida URL, auth y conexiones retiradas', () {
    final transports = <_TrackedHttpClient>[];
    final cache = BackgroundDashboardClientCache(
      create: (connection) {
        final transport = _TrackedHttpClient();
        transports.add(transport);
        return DashboardClient.lazy(connection, httpClientOverride: transport);
      },
    );

    cache.clientFor(_dashboardConnection());
    cache.clientFor(
      _dashboardConnection(
        dashboardUrl: 'https://hermes-demo.example/dashboard',
      ),
    );
    expect(transports, hasLength(2));
    expect(transports.first.closeCalls, 1);

    final basic = _dashboardConnection(
      dashboardUrl: 'https://hermes-demo.example/dashboard',
      dashboardAuthMode: AuthMode.basicAuth,
    );
    cache.clientFor(basic);
    expect(transports, hasLength(3));
    expect(transports[1].closeCalls, 1);

    cache.retainConnections(const []);
    expect(transports.last.closeCalls, 1);
    cache.close();
    expect(transports.every((transport) => transport.closeCalls == 1), isTrue);
  });

  test('kanban siembra el tablero inicial sin repetir estados antiguos', () {
    final seeded = BackgroundKanbanWatch.claimForTest(
      initialized: false,
      previous: const {},
      current: [_kanbanTask('old-done', 'done')],
    );

    expect(seeded.fresh, isEmpty);
    expect(seeded.statuses, {'old-done': 'done'});
  });

  test('kanban avisa una sola vez al pasar de running a done', () {
    final completed = BackgroundKanbanWatch.claimForTest(
      initialized: true,
      previous: const {'task-1': 'running'},
      current: [_kanbanTask('task-1', 'done')],
    );

    expect(completed.fresh, hasLength(1));
    expect(completed.fresh.single.taskId, 'task-1');
    expect(completed.fresh.single.previousStatus, 'running');
    expect(completed.fresh.single.status, 'done');

    final repeated = BackgroundKanbanWatch.claimForTest(
      initialized: true,
      previous: completed.statuses,
      current: [_kanbanTask('task-1', 'done')],
    );
    expect(repeated.fresh, isEmpty);
  });

  test('kanban avisa al pasar de running a blocked o triage', () {
    for (final status in const ['blocked', 'triage']) {
      final result = BackgroundKanbanWatch.claimForTest(
        initialized: true,
        previous: const {'task-1': 'running'},
        current: [_kanbanTask('task-1', status)],
      );

      expect(result.fresh.single.status, status);
    }
  });

  test('kanban legacy sin endpoint degrada sin desactivar cron', () async {
    final tasks = await BackgroundKanbanWatch.loadTasks((endpoint) async {
      expect(endpoint, 'plugins/kanban/board');
      throw const DashboardHttpException(404);
    });

    expect(tasks, isNull);
  });

  test('discovery aplica curva exponencial acotada y resetea al recuperar', () {
    var now = DateTime.utc(2026, 8, 21, 12);
    final backoff = BackgroundDiscoveryBackoff(
      now: () => now,
      baseDelay: const Duration(seconds: 10),
      maxDelay: const Duration(seconds: 40),
    );
    final connection = _dashboardConnection();
    backoff.retainConnections([connection]);

    for (final expected in const [10, 20, 40, 40]) {
      backoff.recordFailure(connection.id, BackgroundDiscoveryCapability.cron);
      expect(
        backoff.retryAfter(connection.id, BackgroundDiscoveryCapability.cron),
        Duration(seconds: expected),
      );
      expect(
        backoff.allowsBackgroundAttempt(
          connection.id,
          BackgroundDiscoveryCapability.cron,
        ),
        isFalse,
      );
      now = now.add(Duration(seconds: expected));
      expect(
        backoff.allowsBackgroundAttempt(
          connection.id,
          BackgroundDiscoveryCapability.cron,
        ),
        isTrue,
      );
    }

    backoff.recordSuccess(connection.id, BackgroundDiscoveryCapability.cron);
    expect(
      backoff.retryAfter(connection.id, BackgroundDiscoveryCapability.cron),
      isNull,
    );
    expect(
      backoff.allowsBackgroundAttempt(
        connection.id,
        BackgroundDiscoveryCapability.cron,
      ),
      isTrue,
    );
  });

  test('discovery aísla Cron y Kanban por conexión', () {
    final backoff = BackgroundDiscoveryBackoff(
      now: () => DateTime.utc(2026, 8, 21, 12),
    );
    final first = _dashboardConnection();
    final second = _dashboardConnection(id: 'demo-node-2');
    backoff.retainConnections([first, second]);

    backoff.recordFailure(first.id, BackgroundDiscoveryCapability.cron);

    expect(
      backoff.allowsBackgroundAttempt(
        first.id,
        BackgroundDiscoveryCapability.cron,
      ),
      isFalse,
    );
    expect(
      backoff.allowsBackgroundAttempt(
        first.id,
        BackgroundDiscoveryCapability.kanban,
      ),
      isTrue,
    );
    expect(
      backoff.allowsBackgroundAttempt(
        second.id,
        BackgroundDiscoveryCapability.cron,
      ),
      isTrue,
    );
  });

  test('discovery cancela backoff al retirar o cambiar conexión', () {
    final backoff = BackgroundDiscoveryBackoff(
      now: () => DateTime.utc(2026, 8, 21, 12),
    );
    final original = _dashboardConnection();
    backoff.retainConnections([original]);
    backoff.recordFailure(original.id, BackgroundDiscoveryCapability.cron);
    backoff.recordFailure(original.id, BackgroundDiscoveryCapability.kanban);

    final changed = _dashboardConnection(
      dashboardUrl: 'https://hermes-demo.example/dashboard',
    );
    backoff.retainConnections([changed]);
    expect(
      backoff.allowsBackgroundAttempt(
        changed.id,
        BackgroundDiscoveryCapability.cron,
      ),
      isTrue,
    );
    expect(
      backoff.allowsBackgroundAttempt(
        changed.id,
        BackgroundDiscoveryCapability.kanban,
      ),
      isTrue,
    );

    backoff.recordFailure(changed.id, BackgroundDiscoveryCapability.cron);
    backoff.retainConnections(const []);
    backoff.retainConnections([changed]);
    expect(
      backoff.allowsBackgroundAttempt(
        changed.id,
        BackgroundDiscoveryCapability.cron,
      ),
      isTrue,
    );
  });

  test('backoff de background no bloquea una carga manual', () async {
    final backoff = BackgroundDiscoveryBackoff(
      now: () => DateTime.utc(2026, 8, 21, 12),
    );
    final connection = _dashboardConnection();
    backoff.retainConnections([connection]);
    backoff.recordFailure(connection.id, BackgroundDiscoveryCapability.cron);
    var calls = 0;

    final executions = await BackgroundCronWatch.loadExecutions((_) async {
      calls++;
      return const {'data': <Object>[]};
    });

    expect(
      backoff.allowsBackgroundAttempt(
        connection.id,
        BackgroundDiscoveryCapability.cron,
      ),
      isFalse,
    );
    expect(calls, 1);
    expect(executions, isEmpty);
  });
}
