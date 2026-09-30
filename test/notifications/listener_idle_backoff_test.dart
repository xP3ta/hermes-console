// Battery: with the automation opt-in and a watched Cron/Kanban connection the
// foreground listener must not tick every 60 s forever. It backs off to the
// 180 s base after a streak of quiet ticks and returns to 60 s as soon as a
// cron run is in flight, a Kanban task is running or anything changed.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/notifications/background_listener.dart';
import 'package:hermes_android/core/services/notifications/notification_delivery_store.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

SavedConnection _connection() => SavedConnection(
  id: 'demo-node',
  label: 'Hermes Demo',
  host: '192.168.1.40',
  port: 8642,
  apiKey: 'k',
  dashboardUrl: 'http://192.168.1.40:9119',
);

class _FakeDashboard extends DashboardClient {
  _FakeDashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'x');

  List<Map<String, dynamic>> jobs = [];
  List<Map<String, dynamic>> kanban = [];

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
    return {'sessions': const []};
  }
}

Map<String, dynamic> _job(String id, String execution, String status) => {
  'id': id,
  'name': 'Job $id',
  'latest_execution': {'id': execution, 'status': status},
};

Map<String, dynamic> _task(String id, String status) => {
  'id': id,
  'title': 'Task $id',
  'body': '',
  'status': status,
};

void main() {
  group('listenerIdleIntervalMs quiet backoff', () {
    int watched(int quiet) => listenerIdleIntervalMs(
      roomsActive: false,
      watchesCron: true,
      watchesKanban: false,
      quietTicks: quiet,
    );

    test('watched automation starts at 60 s and backs off to 180 s', () {
      expect(watched(0), 60000);
      expect(watched(2), 60000);
      expect(watched(3), 120000);
      expect(watched(5), 120000);
      expect(watched(6), 180000);
      expect(watched(500), 180000);
    });

    test('never slower than the 180 s base, never faster for idle', () {
      expect(
        listenerIdleIntervalMs(
          roomsActive: false,
          watchesCron: false,
          watchesKanban: false,
          quietTicks: 0,
        ),
        180000,
      );
      expect(
        listenerIdleIntervalMs(
          roomsActive: true,
          watchesCron: true,
          watchesKanban: true,
          quietTicks: 99,
        ),
        30000,
      );
    });
  });

  group('discovery activity signal', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfi;
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    late _FakeDashboard dashboard;
    late SharedPreferences prefs;
    late NotificationService notif;
    late BackgroundAutomationDiscovery discovery;

    setUp(() async {
      final dir = await Directory.systemTemp.createTemp('listener-idle-');
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      NotificationService.setAutomationNotificationsEnabledForTest(true);
      SharedPreferences.setMockInitialValues({
        'app_locale': 'en',
        'notif_perm_requested': true,
        'notif_background_listen': true,
        'notif_cron_results': true,
        'notif_kanban_results': true,
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
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
          databasePath: '${dir.path}/delivery.db',
        ),
      )..appInForeground = false;
      await notif.init();
      dashboard = _FakeDashboard();
      discovery = BackgroundAutomationDiscovery(
        dashboardClients: BackgroundDashboardClientCache(
          create: (_) => dashboard,
        ),
        discoveryBackoff: BackgroundDiscoveryBackoff(),
        sendToMain: (_) {},
      );
    });

    tearDown(() async {
      await notif.closeDelivery();
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    Future<bool> tick() async {
      await discovery.discoverCronRuns(notif, prefs, [_connection()]);
      await discovery.discoverKanbanTransitions(notif, prefs, [_connection()]);
      return discovery.takeObservedActivity();
    }

    test(
      'an unchanged finished board is quiet after the first sight',
      () async {
        dashboard.jobs = [_job('job-1', 'e1', 'completed')];
        dashboard.kanban = [_task('t1', 'done')];
        expect(await tick(), isTrue);
        expect(await tick(), isFalse);
        expect(await tick(), isFalse);
      },
    );

    test('a cron run in flight keeps the fast cadence', () async {
      dashboard.jobs = [_job('job-1', 'e1', 'completed')];
      await tick();
      expect(await tick(), isFalse);
      dashboard.jobs = [_job('job-1', 'e2', 'running')];
      expect(await tick(), isTrue);
      expect(await tick(), isTrue);
      dashboard.jobs = [_job('job-1', 'e2', 'completed')];
      expect(await tick(), isTrue);
      expect(await tick(), isFalse);
    });

    test('a running Kanban task or a new task is activity', () async {
      dashboard.kanban = [_task('t1', 'todo')];
      await tick();
      expect(await tick(), isFalse);
      dashboard.kanban = [_task('t1', 'todo'), _task('t2', 'triage')];
      expect(await tick(), isTrue);
      expect(await tick(), isFalse);
      dashboard.kanban = [_task('t1', 'running'), _task('t2', 'triage')];
      expect(await tick(), isTrue);
      expect(await tick(), isTrue);
    });
  });
}
