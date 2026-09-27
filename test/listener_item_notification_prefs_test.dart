// Spec 080 P0: per-job/per-task notification preferences must be honoured by
// the REAL delivery path (BackgroundAutomationDiscovery → deliverDiscoveryBatch),
// not only by legacy helpers without callers.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/notifications/background_listener.dart';
import 'package:hermes_android/core/services/notifications/notification_delivery_store.dart';
import 'package:hermes_android/core/services/notifications/notification_mute_store.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _connId = 'demo-node';

SavedConnection _connection() => SavedConnection(
  id: _connId,
  label: 'Hermes Demo',
  host: '192.168.1.40',
  port: 8642,
  apiKey: 'fixture',
  dashboardUrl: 'http://192.168.1.40:9119',
);

/// Dashboard fixture: answers the discovery endpoints from mutable state.
class _FakeDashboard extends DashboardClient {
  _FakeDashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'x');

  List<Map<String, dynamic>> jobs = [];
  List<Map<String, dynamic>> kanban = [];
  List<Map<String, dynamic>> sessions = [];

  @override
  Future<Map<String, dynamic>> apiGet(
    String endpoint, {
    bool retried = false,
  }) async {
    if (endpoint.startsWith('cron/jobs')) return {'jobs': jobs};
    if (endpoint.startsWith('plugins/kanban/board')) {
      return {
        'columns': [
          {'name': 'all', 'tasks': kanban},
        ],
      };
    }
    return {'sessions': sessions};
  }
}

Map<String, dynamic> _job(String id, String execution, String status) => {
  'id': id,
  'name': 'Job $id',
  'latest_execution': {'id': execution, 'status': status},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  sqflite.databaseFactory = databaseFactoryFfi;

  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> shows;
  late String dbPath;
  late _FakeDashboard dashboard;
  late List<Object> sentToMain;
  late SharedPreferences prefs;
  late NotificationService notif;
  late BackgroundAutomationDiscovery discovery;

  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('listener-mute-');
    dbPath = '${dir.path}/delivery.db';
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    NotificationService.setAutomationNotificationsEnabledForTest(true);
    shows = [];
    sentToMain = [];
    SharedPreferences.setMockInitialValues({
      'app_locale': 'en',
      'notif_perm_requested': true,
      'notif_background_listen': true,
      'notif_cron_results': true,
      'notif_kanban_results': true,
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'show') shows.add(call);
      return switch (call.method) {
        'initialize' || 'areNotificationsEnabled' => true,
        'getNotificationAppLaunchDetails' => <String, dynamic>{
          'notificationLaunchedApp': false,
          'notificationResponse': null,
        },
        _ => null,
      };
    });
    prefs = await SharedPreferences.getInstance();
    notif = NotificationService(
      prefs,
      deliveryStore: NotificationDeliveryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: dbPath,
      ),
    )..appInForeground = false;
    await notif.init();
    dashboard = _FakeDashboard();
    discovery = BackgroundAutomationDiscovery(
      dashboardClients: BackgroundDashboardClientCache(
        create: (_) => dashboard,
      ),
      discoveryBackoff: BackgroundDiscoveryBackoff(),
      sendToMain: sentToMain.add,
    );
  });

  tearDown(() async {
    await notif.closeDelivery();
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> cronTick() =>
      discovery.discoverCronRuns(notif, prefs, [_connection()]);
  Future<void> kanbanTick() =>
      discovery.discoverKanbanTransitions(notif, prefs, [_connection()]);

  NotificationMuteStore mutes() => NotificationMuteStore(prefs);

  group('cron', () {
    test('baseline: a new failed run notifies once', () async {
      dashboard.jobs = [_job('job-1', 'e1', 'completed')];
      await cronTick();
      dashboard.jobs = [_job('job-1', 'e2', 'failed')];
      await cronTick();
      expect(shows, hasLength(1));
    });

    test('job turned off never notifies (real listener path)', () async {
      await mutes().setCronPolicy(
        connId: _connId,
        profile: 'default',
        jobId: 'job-1',
        policy: CronNotifyPolicy.off,
      );
      dashboard.jobs = [_job('job-1', 'e1', 'completed')];
      await cronTick();
      dashboard.jobs = [_job('job-1', 'e2', 'failed')];
      await cronTick();
      expect(shows, isEmpty);
    });

    test('legacy unscoped mute is honoured too', () async {
      await mutes().setJobMuted('job-1', true);
      dashboard.jobs = [_job('job-1', 'e1', 'completed')];
      await cronTick();
      dashboard.jobs = [_job('job-1', 'e2', 'failed')];
      await cronTick();
      expect(shows, isEmpty);
    });

    test('mute is scoped per connection', () async {
      await mutes().setCronPolicy(
        connId: 'other-node',
        profile: 'default',
        jobId: 'job-1',
        policy: CronNotifyPolicy.off,
      );
      dashboard.jobs = [_job('job-1', 'e1', 'completed')];
      await cronTick();
      dashboard.jobs = [_job('job-1', 'e2', 'failed')];
      await cronTick();
      expect(shows, hasLength(1));
    });

    test('"only if it fails" lets failures through and nothing else', () async {
      await mutes().setCronPolicy(
        connId: _connId,
        profile: 'default',
        jobId: 'job-1',
        policy: CronNotifyPolicy.failuresOnly,
      );
      dashboard.jobs = [_job('job-1', 'e1', 'completed')];
      await cronTick();
      dashboard.jobs = [_job('job-1', 'e2', 'failed')];
      await cronTick();
      expect(shows, hasLength(1));
    });

    test('re-enabling does not replay runs seen while muted', () async {
      final store = mutes();
      await store.setCronPolicy(
        connId: _connId,
        profile: 'default',
        jobId: 'job-1',
        policy: CronNotifyPolicy.off,
      );
      dashboard.jobs = [_job('job-1', 'e1', 'completed')];
      await cronTick();
      dashboard.jobs = [_job('job-1', 'e2', 'failed')];
      await cronTick();
      await store.setCronPolicy(
        connId: _connId,
        profile: 'default',
        jobId: 'job-1',
        policy: CronNotifyPolicy.all,
      );
      await cronTick();
      expect(shows, isEmpty);
      dashboard.jobs = [_job('job-1', 'e3', 'failed')];
      await cronTick();
      expect(shows, hasLength(1));
    });

    test('foreground: no tray notification but an in-app notice', () async {
      await prefs.setBool(BackgroundListener.uiForegroundKey, true);
      dashboard.jobs = [_job('job-1', 'e1', 'completed')];
      await cronTick();
      expect(sentToMain, isEmpty, reason: 'baseline is never announced');
      dashboard.jobs = [_job('job-1', 'e2', 'failed')];
      await cronTick();
      expect(shows, isEmpty);
      expect(sentToMain, hasLength(1));
      final notice = BackgroundListener.automationNoticeFromData(
        sentToMain.single,
      );
      expect(notice, isNotNull);
      expect(notice!.open.connId, _connId);
      expect(notice.open.jobId, 'job-1');
      // Same snapshot again: no duplicate notice.
      await cronTick();
      expect(sentToMain, hasLength(1));
    });

    test('foreground + muted job: no in-app notice either', () async {
      await prefs.setBool(BackgroundListener.uiForegroundKey, true);
      await mutes().setCronPolicy(
        connId: _connId,
        profile: 'default',
        jobId: 'job-1',
        policy: CronNotifyPolicy.off,
      );
      dashboard.jobs = [_job('job-1', 'e1', 'completed')];
      await cronTick();
      dashboard.jobs = [_job('job-1', 'e2', 'failed')];
      await cronTick();
      expect(sentToMain, isEmpty);
    });
  });

  // Real Hermes Agent 0.20 `/api/cron/jobs` shape: the execution ledger id is
  // an opaque UUID that is never a session id, `delivery_outcome` says whether
  // a result left the process, and no-agent jobs never create a session.
  group('cron success on the real server contract', () {
    Map<String, dynamic> serverJob({
      required String execution,
      String status = 'completed',
      String deliver = 'local',
      bool noAgent = true,
      String? outcome = 'suppressed',
      String claimed = '2026-09-26T20:34:20.404144+01:00',
      String finished = '2026-09-26T20:34:21.044206+01:00',
    }) => {
      'id': 'job-1',
      'name': 'Nightly summary',
      'profile': null,
      'deliver': deliver,
      'no_agent': noAgent,
      'last_status': status == 'completed' ? 'ok' : 'error',
      'last_run_at': finished,
      'latest_execution': {
        'id': execution,
        'job_id': 'job-1',
        'source': 'builtin',
        'status': status,
        'claimed_at': claimed,
        'started_at': claimed,
        'finished_at': finished,
        'error': null,
        'delivery_outcome': outcome,
      },
    };

    Map<String, dynamic> cronSession(String id, double startedAt, String p) => {
      'id': id,
      'title': 'Nightly summary job',
      'source': 'cron',
      'model': '',
      'message_count': 2,
      'is_active': false,
      'started_at': startedAt,
      'ended_at': startedAt + 30,
      'last_active': startedAt + 30,
      'last_assistant_preview': p,
      'profile': 'default',
    };

    test('a local no-agent run that completes notifies once', () async {
      dashboard.jobs = [serverJob(execution: '106299698a484a3a8bb64c91')];
      await cronTick();
      expect(shows, isEmpty, reason: 'first snapshot is the baseline');
      dashboard.jobs = [serverJob(execution: '97db659df0114af9bcc0e63a')];
      await cronTick();
      expect(shows, hasLength(1));
      await cronTick();
      expect(shows, hasLength(1), reason: 'same execution never repeats');
    });

    test('a brand-new job whose first run completes notifies', () async {
      dashboard.jobs = [];
      await cronTick();
      dashboard.jobs = [serverJob(execution: 'e-first')];
      await cronTick();
      expect(shows, hasLength(1));
    });

    test('a silent run delivered to a chat target stays silent', () async {
      dashboard.jobs = [
        serverJob(execution: 'e1', deliver: 'bot-chat:atlas'),
      ];
      await cronTick();
      dashboard.jobs = [
        serverJob(execution: 'e2', deliver: 'bot-chat:atlas'),
      ];
      await cronTick();
      expect(shows, isEmpty);
    });

    test('a result delivered to a chat target notifies', () async {
      dashboard.jobs = [serverJob(execution: 'e1', deliver: 'telegram')];
      await cronTick();
      dashboard.jobs = [
        serverJob(execution: 'e2', deliver: 'telegram', outcome: 'delivered'),
      ];
      await cronTick();
      expect(shows, hasLength(1));
    });

    test('a local agent run binds its session by time window', () async {
      // 2026-09-26T20:34:20+01:00 == 1790451260 epoch seconds.
      dashboard.jobs = [serverJob(execution: 'e1', noAgent: false)];
      await cronTick();
      dashboard.jobs = [
        serverJob(
          execution: 'e2',
          noAgent: false,
          claimed: '2026-09-26T21:00:00+01:00',
          finished: '2026-09-26T21:04:00+01:00',
        ),
      ];
      dashboard.sessions = [
        cronSession('cron_job-1_20260926_210005', 1790452805, 'Report ready'),
      ];
      await cronTick();
      expect(shows, hasLength(1));
      final args = shows.single.arguments as Map;
      expect(args['body'], contains('Report ready'));
    });

    test(
      'a local agent run whose session says [SILENT] stays silent',
      () async {
        dashboard.jobs = [serverJob(execution: 'e1', noAgent: false)];
        await cronTick();
        dashboard.jobs = [
          serverJob(
            execution: 'e2',
            noAgent: false,
            claimed: '2026-09-26T21:00:00+01:00',
            finished: '2026-09-26T21:04:00+01:00',
          ),
        ];
        dashboard.sessions = [
          cronSession('cron_job-1_20260926_210005', 1790452805, '[SILENT]'),
        ];
        await cronTick();
        expect(shows, isEmpty);
      },
    );

    test(
      'a local agent run waits for its session instead of guessing',
      () async {
        dashboard.jobs = [serverJob(execution: 'e1', noAgent: false)];
        await cronTick();
        dashboard.jobs = [
          serverJob(
            execution: 'e2',
            noAgent: false,
            claimed: '2026-09-26T21:00:00+01:00',
            finished: '2026-09-26T21:04:00+01:00',
          ),
        ];
        await cronTick();
        expect(shows, isEmpty, reason: 'session not listed yet');
        dashboard.sessions = [
          cronSession('cron_job-1_20260926_210005', 1790452805, 'Report ready'),
        ];
        await cronTick();
        expect(shows, hasLength(1), reason: 'retried once the session appears');
      },
    );

    test('"only if it fails": success silent, failure notifies', () async {
      await mutes().setCronPolicy(
        connId: _connId,
        profile: 'default',
        jobId: 'job-1',
        policy: CronNotifyPolicy.failuresOnly,
      );
      dashboard.jobs = [serverJob(execution: 'e1')];
      await cronTick();
      dashboard.jobs = [serverJob(execution: 'e2')];
      await cronTick();
      expect(shows, isEmpty);
      dashboard.jobs = [
        serverJob(execution: 'e3', status: 'failed', outcome: null),
      ];
      await cronTick();
      expect(shows, hasLength(1));
    });
  });

  group('kanban', () {
    Map<String, dynamic> task(String status) => {
      'id': 'task-1',
      'title': 'Write report',
      'status': status,
    };

    test('baseline: done notifies by default when never configured', () async {
      expect(
        prefs.containsKey(NotificationMuteStore.kanbanDoneDefaultKey),
        isFalse,
      );
      dashboard.kanban = [task('running')];
      await kanbanTick();
      dashboard.kanban = [task('done')];
      await kanbanTick();
      expect(shows, hasLength(1));
    });

    test(
      'an explicit global OFF keeps done silent; blocked still notifies',
      () async {
        await mutes().setKanbanDoneDefault(false);
        dashboard.kanban = [task('running')];
        await kanbanTick();
        dashboard.kanban = [task('done')];
        await kanbanTick();
        expect(shows, isEmpty);
        dashboard.kanban = [task('blocked')];
        await kanbanTick();
        expect(shows, hasLength(1));
      },
    );

    test('a per-task OFF wins over the default', () async {
      await mutes().setKanbanNotifyDone(
        connId: _connId,
        taskId: 'task-1',
        value: false,
      );
      dashboard.kanban = [task('running')];
      await kanbanTick();
      dashboard.kanban = [task('done')];
      await kanbanTick();
      expect(shows, isEmpty);
    });

    test('muted task never notifies (real listener path)', () async {
      await mutes().setKanbanMuted(
        connId: _connId,
        taskId: 'task-1',
        muted: true,
      );
      dashboard.kanban = [task('running')];
      await kanbanTick();
      dashboard.kanban = [task('blocked')];
      await kanbanTick();
      expect(shows, isEmpty);
    });

    test('opt-in "notify when done" per task', () async {
      await mutes().setKanbanNotifyDone(
        connId: _connId,
        taskId: 'task-1',
        value: true,
      );
      dashboard.kanban = [task('running')];
      await kanbanTick();
      dashboard.kanban = [task('done')];
      await kanbanTick();
      expect(shows, hasLength(1));
    });

    test('global done default applies to tasks without a choice', () async {
      await mutes().setKanbanDoneDefault(true);
      dashboard.kanban = [task('running')];
      await kanbanTick();
      dashboard.kanban = [task('done')];
      await kanbanTick();
      expect(shows, hasLength(1));
    });
  });
}
