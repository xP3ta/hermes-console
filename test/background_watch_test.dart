import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
  sqfliteFfiInit();
  sqflite.databaseFactory = databaseFactoryFfi;

  setUp(
    () => NotificationService.setAutomationNotificationsEnabledForTest(true),
  );
  tearDown(
    () => NotificationService.setAutomationNotificationsEnabledForTest(false),
  );

  test(
    'watch transaction serializes overlapping isolate/process owners',
    () async {
      final dir = await Directory.systemTemp.createTemp('hermes-watch-mutex-');
      addTearDown(() => dir.delete(recursive: true));
      final databasePath = '${dir.path}/watch-mutex.db';
      final first = BackgroundWatchTransactionMutex(
        databasePath,
        databaseFactory: databaseFactoryFfi,
        retryDelay: const Duration(milliseconds: 1),
        busyTimeout: const Duration(milliseconds: 5),
      );
      final second = BackgroundWatchTransactionMutex(
        databasePath,
        databaseFactory: databaseFactoryFfi,
        retryDelay: const Duration(milliseconds: 1),
        busyTimeout: const Duration(milliseconds: 5),
      );
      final firstEntered = Completer<void>();
      final releaseFirst = Completer<void>();
      final order = <String>[];

      final firstRun = first.protect(() async {
        firstEntered.complete();
        await releaseFirst.future;
        order.add('first');
      });
      await firstEntered.future;

      var secondEntered = false;
      final secondRun = second.protect(() async {
        secondEntered = true;
        order.add('second');
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(secondEntered, isFalse);

      releaseFirst.complete();
      await Future.wait([firstRun, secondRun]);
      expect(order, const ['first', 'second']);
    },
  );

  test('watch transaction recovers when an owner connection dies', () async {
    final dir = await Directory.systemTemp.createTemp('hermes-watch-death-');
    addTearDown(() => dir.delete(recursive: true));
    final databasePath = '${dir.path}/watch-mutex.db';
    final abandonedOwner = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: sqflite.OpenDatabaseOptions(singleInstance: false),
    );
    await abandonedOwner.rawQuery('PRAGMA busy_timeout = 0');
    await abandonedOwner.execute('BEGIN EXCLUSIVE');
    final mutex = BackgroundWatchTransactionMutex(
      databasePath,
      databaseFactory: databaseFactoryFfi,
      retryDelay: const Duration(milliseconds: 1),
      busyTimeout: const Duration(milliseconds: 5),
    );

    var entered = false;
    final waiting = mutex.protect(() async => entered = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(entered, isFalse);

    // Closing the connection models the OS closing SQLite handles after a
    // process death. The uncommitted transaction is rolled back atomically.
    await abandonedOwner.close();
    await waiting.timeout(const Duration(seconds: 2));

    expect(entered, isTrue);
  });

  test('watch transaction rolls back a failed owner before hand-off', () async {
    final dir = await Directory.systemTemp.createTemp('hermes-watch-rollback-');
    addTearDown(() => dir.delete(recursive: true));
    final databasePath = '${dir.path}/watch-mutex.db';
    final first = BackgroundWatchTransactionMutex(
      databasePath,
      databaseFactory: databaseFactoryFfi,
      retryDelay: const Duration(milliseconds: 1),
      busyTimeout: const Duration(milliseconds: 5),
    );
    final second = BackgroundWatchTransactionMutex(
      databasePath,
      databaseFactory: databaseFactoryFfi,
      retryDelay: const Duration(milliseconds: 1),
      busyTimeout: const Duration(milliseconds: 5),
    );

    await expectLater(
      first.protect<void>(() async => throw StateError('injected failure')),
      throwsStateError,
    );

    var entered = false;
    await second.protect(() async => entered = true);
    expect(entered, isTrue);
  });

  test(
    'watch mutex path fails closed instead of changing lock domain',
    () async {
      expect(
        await resolveBackgroundWatchMutexDatabasePathForTest(
          () async => '/canonical/databases',
        ),
        '/canonical/databases/background_watch_mutex_v1.db',
      );

      await expectLater(
        resolveBackgroundWatchMutexDatabasePathForTest(
          () async => throw StateError('database path unavailable'),
        ),
        throwsStateError,
      );
      await expectLater(
        resolveBackgroundWatchMutexDatabasePathForTest(() async => ''),
        throwsStateError,
      );
    },
  );

  test('1.2.9 persists opted-in background work', () async {
    expect(NotificationService.automationNotificationsAvailable, isTrue);
    SharedPreferences.setMockInitialValues({BackgroundListener.prefKey: true});
    await BackgroundWatch.add(
      const SavedRunWatch(
        connId: 'conn',
        base: 'https://hermes.example',
        runId: 'run-1',
        prompt: 'safe',
      ),
    );
    expect(await BackgroundWatch.snapshot(), hasLength(1));
    await BackgroundCronWatch.syncConnections([_dashboardConnection()]);
    expect(await BackgroundCronWatch.snapshotTargets(), hasLength(1));
  });

  test(
    'cold listener opt-in repopulates cron and kanban targets before polling',
    () async {
      NotificationService.setAutomationNotificationsEnabledForTest(false);
      addTearDown(
        () =>
            NotificationService.setAutomationNotificationsEnabledForTest(true),
      );
      SharedPreferences.setMockInitialValues({
        BackgroundListener.prefKey: false,
      });
      final prefs = await SharedPreferences.getInstance();
      // Simula el arranque en frío con la escucha apagada: el constructor deja
      // también el gate estático apagado y el primer sync limpia el snapshot.
      NotificationService(prefs);
      await BackgroundCronWatch.syncConnections([_dashboardConnection()]);
      expect(await BackgroundCronWatch.snapshotTargets(), isEmpty);

      // El switch maestro persiste primero el consentimiento. El repoblado no
      // puede depender de reconstruir NotificationService ni de reiniciar UI.
      await prefs.setBool(BackgroundListener.prefKey, true);
      await BackgroundCronWatch.syncConnections([_dashboardConnection()]);

      expect(await BackgroundCronWatch.snapshotTargets(), hasLength(1));
    },
  );

  test('target revision advances on same-metadata credential resync', () async {
    SharedPreferences.setMockInitialValues({BackgroundListener.prefKey: true});
    final connection = _dashboardConnection();

    await BackgroundCronWatch.syncConnections([connection]);
    final before = await BackgroundCronWatch.snapshotTargetState();
    await BackgroundCronWatch.syncConnections([connection]);
    final after = await BackgroundCronWatch.snapshotTargetState();

    expect(after.connections.single.id, connection.id);
    expect(after.revision, greaterThan(before.revision));
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

  test(
    'cron empty and running-only snapshots still expose cursor profiles',
    () {
      expect(BackgroundCronWatch.discoveryProfiles(const []), <String>{
        'default',
      });
      expect(
        BackgroundCronWatch.discoveryProfiles(<CronExecutionSnapshot>[
          _cronExecution('running-1', 'running'),
        ]),
        <String>{'default'},
      );
      expect(
        BackgroundCronWatch.discoveryProfiles(<CronExecutionSnapshot>[
          CronExecutionSnapshot(
            jobKey: 'research::job-1',
            jobId: 'job-1',
            title: 'Research',
            profile: 'Research',
            executionId: 'running-2',
            status: 'running',
          ),
        ]),
        <String>{'default', 'research'},
      );
    },
  );

  test('FGS persists canonical approval request identity across restart', () {
    const watched = WatchedRun(
      connId: 'conn',
      base: 'https://hermes.example',
      runId: 'run-a',
      prompt: 'approval',
      approvalRequestId: 'request-a',
    );

    final restored = WatchedRun.fromJson(watched.toJson());
    expect(restored.approvalRequestId, 'request-a');
    expect(restored.approvalNotified, isTrue);
    final replacement = restored.copyWith(approvalRequestId: 'request-b');
    expect(replacement.approvalRequestId, 'request-b');
    expect(replacement.copyWith(clearApproval: true).approvalRequestId, isNull);
  });

  test('FGS notification owner preserves exact profile route', () {
    const watched = WatchedRun(
      connId: 'conn-a',
      profile: ' Room-Alpha ',
      base: 'https://hermes.example',
      runId: 'shared-run',
      prompt: 'approval',
    );

    expect(watched.notificationOwner, (
      connId: 'conn-a',
      profile: 'room-alpha',
      runId: 'shared-run',
    ));
  });

  test('same run id survives and is removed by exact owner', () async {
    SharedPreferences.setMockInitialValues({});
    for (final profile in ['room-alpha', 'room-beta']) {
      await BackgroundWatch.add(
        SavedRunWatch(
          connId: 'conn-a',
          profile: profile,
          base: 'https://hermes.example',
          runId: 'shared-run',
          prompt: profile,
        ),
      );
    }

    final before = await BackgroundWatch.snapshot();
    expect(before.map((run) => run.profile).toSet(), {
      'room-alpha',
      'room-beta',
    });

    await BackgroundWatch.remove(
      'shared-run',
      connId: 'conn-a',
      profile: 'room-alpha',
    );
    final after = await BackgroundWatch.snapshot();
    expect(after, hasLength(1));
    expect(after.single.profile, 'room-beta');
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

  test('poll merge fences the same run id by connection and profile', () {
    const alpha = WatchedRun(
      connId: 'conn-a',
      profile: 'room-alpha',
      base: 'https://hermes.example',
      runId: 'shared-run',
      prompt: 'alpha',
    );
    const beta = WatchedRun(
      connId: 'conn-a',
      profile: 'room-beta',
      base: 'https://hermes.example',
      runId: 'shared-run',
      prompt: 'beta',
    );

    final merged = BackgroundWatch.mergeForTest(
      latest: const [alpha, beta],
      snapshot: const [alpha],
      keep: [alpha.copyWith(approvalRequestId: 'approval-alpha')],
    );

    expect(merged, hasLength(2));
    expect(
      merged
          .singleWhere((run) => run.profile == 'room-alpha')
          .approvalRequestId,
      'approval-alpha',
    );
    expect(
      merged.singleWhere((run) => run.profile == 'room-beta').prompt,
      'beta',
    );
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

  test('FGS cierra la autoridad SQLite al destruir el isolate', () {
    final source = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();
    final start = source.indexOf('Future<void> onDestroy(');
    final end = source.indexOf('\n  }', start);
    expect(start, isNonNegative);
    expect(source.substring(start, end), contains('closeDelivery()'));
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

  test(
    'cron ingiere los 6/50 terminales sin aplicar el límite de despacho',
    () {
      for (final count in const [6, 50]) {
        final current = List<CronExecutionSnapshot>.generate(
          count,
          (index) => CronExecutionSnapshot(
            jobKey: 'default::job-$index',
            jobId: 'job-$index',
            title: 'Job $index',
            profile: 'default',
            executionId: 'execution-$index',
            status: 'completed',
          ),
        );
        final claimed = BackgroundCronWatch.claimExecutionsForTest(
          initialized: true,
          previous: const {},
          current: current,
        );
        expect(claimed.fresh, hasLength(count));
        expect(claimed.states, hasLength(count));
      }
    },
  );

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
      var notifications = NotificationService(prefs);
      expect(notifications.notifyCronResults, isFalse);

      SharedPreferences.setMockInitialValues({
        BackgroundListener.prefKey: true,
      });
      prefs = await SharedPreferences.getInstance();
      notifications = NotificationService(prefs);
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

  test('cron job ledger is not replaced without matching execution proof', () {
    const older = Session(
      id: 'cron_job-1_20260831_020000',
      title: 'Housing search',
      model: '',
      source: 'cron',
      messageCount: 2,
      isActive: false,
      preview: '',
      startedAt: 10,
      endedAt: 11,
      updatedAt: 11,
      profile: 'default',
    );
    const newest = Session(
      id: 'cron_job-1_20260831_025100',
      title: 'Housing search',
      model: '',
      source: 'cron',
      messageCount: 2,
      isActive: false,
      preview: '',
      startedAt: 20,
      endedAt: 21,
      updatedAt: 21,
      profile: 'default',
    );

    final executions = BackgroundCronWatch.mergeExecutionAuthority(
      jobExecutions: [_cronExecution('stale-execution', 'completed')],
      sessions: const [older, newest],
    );

    expect(executions, hasLength(1));
    expect(executions.single.executionId, 'stale-execution');
    expect(executions.single.jobId, 'job-1');
    expect(executions.single.title, 'Housing search');
    expect(executions.single.status, 'completed');
    expect(executions.single.sessionAuthority, isFalse);
    expect(
      BackgroundCronWatch.sessionForExecution(executions.single, const [
        older,
        newest,
      ]),
      isNull,
    );
  });

  test('cron sessions supply authority only for a job absent from ledger', () {
    const older = Session(
      id: 'cron_job-1_20260831_020000',
      title: 'Housing search',
      model: '',
      source: 'cron',
      messageCount: 2,
      isActive: false,
      preview: '',
      startedAt: 10,
      endedAt: 11,
      updatedAt: 11,
      profile: 'default',
    );
    const newest = Session(
      id: 'cron_job-1_20260831_025100',
      title: 'Housing search',
      model: '',
      source: 'cron',
      messageCount: 2,
      isActive: false,
      preview: '',
      startedAt: 20,
      endedAt: 21,
      updatedAt: 21,
      profile: 'default',
    );

    final executions = BackgroundCronWatch.mergeExecutionAuthority(
      jobExecutions: const [],
      sessions: const [older, newest],
    );

    expect(executions, hasLength(1));
    expect(executions.single.executionId, newest.id);
    expect(executions.single.status, 'completed');
    expect(executions.single.sessionAuthority, isTrue);
    expect(
      BackgroundCronWatch.sessionForExecution(executions.single, const [
        older,
        newest,
      ]),
      same(newest),
    );
    expect(
      BackgroundCronWatch.discoveryScopeKey(
        connId: 'conn',
        profile: 'default',
        syntheticExecutionId: false,
        sessionAuthority: true,
      ),
      'conn/default/cron/sessions',
    );
  });

  test('a running job fences an older terminal session for the same job', () {
    const olderTerminal = Session(
      id: 'cron_job-1_20260831_020000',
      title: 'Housing search',
      model: '',
      source: 'cron',
      messageCount: 2,
      isActive: false,
      preview: 'old result',
      startedAt: 10,
      endedAt: 11,
      updatedAt: 11,
      profile: 'default',
    );

    final executions = BackgroundCronWatch.mergeExecutionAuthority(
      jobExecutions: [_cronExecution('new-running-execution', 'running')],
      sessions: const [olderTerminal],
    );

    expect(executions, hasLength(1));
    expect(executions.single.executionId, 'new-running-execution');
    expect(executions.single.status, 'running');
    expect(executions.single.sessionAuthority, isFalse);
  });

  test(
    'a newer failed job ledger is not replaced by an older completed session',
    () {
      const olderTerminal = Session(
        id: 'cron_job-1_20260831_020000',
        title: 'Housing search',
        model: '',
        source: 'cron',
        messageCount: 2,
        isActive: false,
        preview: 'old result',
        startedAt: 10,
        endedAt: 11,
        updatedAt: 11,
        profile: 'default',
      );

      final executions = BackgroundCronWatch.mergeExecutionAuthority(
        jobExecutions: [_cronExecution('execution-new', 'failed')],
        sessions: const [olderTerminal],
      );

      expect(executions, hasLength(1));
      expect(executions.single.executionId, 'execution-new');
      expect(executions.single.status, 'failed');
      expect(executions.single.sessionAuthority, isFalse);
    },
  );

  test('cron discovery keeps one durable cursor per job, not per snapshot', () {
    final first = BackgroundCronWatch.discoveryCursorForExecution(
      connId: 'conn',
      profile: 'default',
      execution: _cronExecution('execution-1', 'completed'),
    );
    final next = BackgroundCronWatch.discoveryCursorForExecution(
      connId: 'conn',
      profile: 'default',
      execution: _cronExecution('execution-2', 'completed'),
    );
    final otherJob = BackgroundCronWatch.discoveryCursorForExecution(
      connId: 'conn',
      profile: 'default',
      execution: const CronExecutionSnapshot(
        jobKey: 'default::job-2',
        jobId: 'job-2',
        title: 'Other job',
        profile: 'default',
        executionId: 'execution-1',
        status: 'completed',
      ),
    );

    expect(next.scopeKey, first.scopeKey);
    expect(next.objectId, first.objectId);
    expect(otherJob.scopeKey, isNot(first.scopeKey));
    expect(otherJob.objectId, isNot(first.objectId));
  });

  test(
    'initial unhydrated cron terminal is seeded instead of alerted later',
    () {
      expect(
        BackgroundCronWatch.shouldSeedUnnotifiableTerminal(
          initialBaseline: true,
        ),
        isTrue,
      );
      expect(
        BackgroundCronWatch.shouldSeedUnnotifiableTerminal(
          initialBaseline: false,
        ),
        isFalse,
      );
    },
  );

  test(
    'cron seeds the empty session-authority cursor before the first run',
    () {
      final groups = BackgroundCronWatch.discoveryGroups(const []);

      expect(
        groups,
        contains((
          profile: 'default',
          syntheticExecutionId: false,
          sessionAuthority: true,
        )),
      );
    },
  );

  test('cron seeds the empty legacy cursor before the first terminal', () {
    final groups = BackgroundCronWatch.discoveryGroups(const []);

    expect(
      groups,
      contains((
        profile: 'default',
        syntheticExecutionId: true,
        sessionAuthority: false,
      )),
    );
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
    for (final status in <int>[400, 404, 405, 422, 501]) {
      expect(
        BackgroundCronWatch.shouldFallbackFromAllProfilesStatus(status),
        isTrue,
        reason: 'HTTP $status debe usar el endpoint legacy de sesiones',
      );
    }
    expect(
      BackgroundCronWatch.shouldFallbackFromAllProfilesStatus(401),
      isFalse,
    );
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
    expect(executions.single.syntheticExecutionId, isFalse);
    expect(executions.single.terminal, isTrue);
  });

  test('cron conserva unknown como estado terminal oficial', () async {
    final executions = await BackgroundCronWatch.loadExecutions((_) async {
      return {
        'data': [
          {
            'id': 'job-unknown',
            'profile': 'default',
            'latest_execution': {
              'id': 'execution-unknown',
              'status': 'unknown',
            },
          },
        ],
      };
    });

    expect(executions, hasLength(1));
    expect(executions!.single.status, 'unknown');
    expect(executions.single.terminal, isTrue);
  });

  test(
    'cron acepta el contrato legacy top-level sin filtrar el resultado',
    () async {
      final executions = await BackgroundCronWatch.loadExecutions((_) async {
        return {
          'jobs': [
            {
              'id': 'job-legacy',
              'name': 'QA legacy cron',
              'profile': 'default',
              'last_run_at': '2026-08-31T02:02:36.442618+01:00',
              'last_status': 'ok',
            },
          ],
        };
      });

      expect(executions, hasLength(1));
      expect(executions!.single.jobId, 'job-legacy');
      expect(executions.single.status, 'completed');
      expect(executions.single.executionId, hasLength(64));
      expect(executions.single.syntheticExecutionId, isTrue);
      expect(executions.single.terminal, isTrue);
      expect(
        BackgroundCronWatch.discoveryScopeKey(
          connId: 'conn',
          profile: 'default',
          syntheticExecutionId: true,
        ),
        isNot(
          BackgroundCronWatch.discoveryScopeKey(
            connId: 'conn',
            profile: 'default',
            syntheticExecutionId: false,
          ),
        ),
      );
    },
  );

  test('cron modern and legacy execution ids cannot collide durably', () {
    const opaqueId =
        'e437ea2e9a36d2c99bdc53649913c440cab390549314077e3476527b3346dde7';
    final modern = BackgroundCronWatch.notificationIdentity(
      connId: 'conn',
      profile: 'default',
      execution: _cronExecution(opaqueId, 'completed'),
    );
    final legacy = BackgroundCronWatch.notificationIdentity(
      connId: 'conn',
      profile: 'default',
      execution: CronExecutionSnapshot(
        jobKey: 'default::job-1',
        jobId: 'job-1',
        title: 'Housing search',
        profile: 'default',
        executionId: opaqueId,
        status: 'completed',
        syntheticExecutionId: true,
      ),
    );
    final session = BackgroundCronWatch.notificationIdentity(
      connId: 'conn',
      profile: 'default',
      execution: CronExecutionSnapshot(
        jobKey: 'default::job-1',
        jobId: 'job-1',
        title: 'Housing search',
        profile: 'default',
        executionId: opaqueId,
        status: 'completed',
        sessionAuthority: true,
      ),
    );

    expect({modern.eventKey, legacy.eventKey, session.eventKey}, hasLength(3));
    expect(modern.objectId, 'discovery.$opaqueId');
    expect(legacy.objectId, 'legacy_discovery.$opaqueId');
    expect(session.objectId, 'session_discovery.$opaqueId');
  });

  test(
    'legacy cron routing ignores colliding ids and picks the latest exact job session',
    () {
      const opaqueId =
          'e437ea2e9a36d2c99bdc53649913c440cab390549314077e3476527b3346dde7';
      final execution = CronExecutionSnapshot(
        jobKey: 'research::job-1',
        jobId: 'job-1',
        title: 'Housing search',
        profile: 'research',
        executionId: opaqueId,
        status: 'completed',
        syntheticExecutionId: true,
      );
      const collidingModernSession = Session(
        id: opaqueId,
        title: 'Different modern execution',
        model: '',
        source: 'cron',
        messageCount: 2,
        isActive: false,
        preview: 'wrong',
        startedAt: 300,
        profile: 'research',
        isDefaultProfile: false,
      );
      const staleJobSession = Session(
        id: 'cron_job-1_old',
        title: 'Old job execution',
        model: '',
        source: 'cron',
        messageCount: 2,
        isActive: false,
        preview: 'old',
        startedAt: 100,
        profile: 'research',
        isDefaultProfile: false,
      );
      const latestJobSession = Session(
        id: 'cron_job-1_latest',
        title: 'Latest job execution',
        model: '',
        source: 'cron',
        messageCount: 2,
        isActive: false,
        preview: 'latest',
        startedAt: 200,
        profile: 'research',
        isDefaultProfile: false,
      );
      const activeJobSession = Session(
        id: 'cron_job-1_active',
        title: 'Still running',
        model: '',
        source: 'cron',
        messageCount: 1,
        isActive: true,
        preview: 'working',
        startedAt: 400,
        profile: 'research',
        isDefaultProfile: false,
      );
      const otherProfileSession = Session(
        id: 'cron_job-1_other',
        title: 'Other profile',
        model: '',
        source: 'cron',
        messageCount: 2,
        isActive: false,
        preview: 'other',
        startedAt: 500,
        profile: 'default',
      );

      final match = BackgroundCronWatch.sessionForExecution(execution, const [
        collidingModernSession,
        activeJobSession,
        staleJobSession,
        otherProfileSession,
        latestJobSession,
      ]);

      expect(match?.id, latestJobSession.id);
      expect(
        BackgroundCronWatch.sessionForExecution(execution, const [
          latestJobSession,
          staleJobSession,
        ])?.id,
        latestJobSession.id,
      );
    },
  );

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
    SharedPreferences.setMockInitialValues({BackgroundListener.prefKey: true});
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

  test('kanban ingiere las 6/50 transiciones sin límite de despacho', () {
    for (final count in const [6, 50]) {
      final previous = <String, String>{
        for (var index = 0; index < count; index++) 'task-$index': 'running',
      };
      final claimed = BackgroundKanbanWatch.claimForTest(
        initialized: true,
        previous: previous,
        current: List<KanbanTask>.generate(
          count,
          (index) => _kanbanTask('task-$index', 'done'),
        ),
      );
      expect(claimed.fresh, hasLength(count));
      expect(claimed.statuses, hasLength(count));
    }
  });

  test(
    'kanban durable separa el estado anterior por tarjeta y permite reentrada',
    () {
      final entries = BackgroundKanbanWatch.discoveryEntriesForTest(
        connId: 'conn-a',
        tasks: [
          _kanbanTask('blocked-old', 'blocked'),
          _kanbanTask('changed-other', 'done'),
        ],
      );

      expect(entries.map((entry) => entry.scopeKey).toSet(), {
        'conn-a/default/kanban/blocked-old',
        'conn-a/default/kanban/changed-other',
      });
      expect(
        entries.singleWhere((entry) => entry.taskId == 'blocked-old').state,
        'blocked',
      );
      expect(
        BackgroundKanbanWatch.transitionVersionForTest(
          taskId: 'blocked-old',
          previousStatus: 'ready',
          status: 'blocked',
        ),
        'blocked-old:blocked:after:ready',
      );
    },
  );

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
