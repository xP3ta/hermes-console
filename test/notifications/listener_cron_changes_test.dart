// SPDX-License-Identifier: GPL-3.0-only
// With «Listen in background» on and an idle server, every listener tick
// (60-180 s) listed `cron/jobs` and the last 50 cron sessions of every
// profile. Hermes Desktop reads its cron list on `cron.changed` once
// `gateway.ready` announces `change_events`, and keeps a timer only as a
// backstop while on screen (apps/desktop/src/app/contrib/hooks/
// use-background-sync.ts). The listener now does the same over the gateway
// socket it already keeps open. These tests count the Dashboard reads over
// idle ticks, against a real loopback gateway socket.
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/notifications/background_listener.dart';
import 'package:hermes_android/core/services/notifications/notification_delivery_store.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'listener_idle_support.dart';

/// The Dashboard routes of the cron pass: `cron/jobs` and the cron sessions.
class _CronDashboard extends DashboardClient {
  _CronDashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'x');

  List<Map<String, dynamic>> jobs = [];
  int jobReads = 0;
  int sessionReads = 0;

  @override
  Future<Map<String, dynamic>> apiGet(
    String endpoint, {
    bool retried = false,
  }) async {
    if (endpoint.startsWith('cron/jobs')) {
      jobReads++;
      return {'jobs': jobs};
    }
    sessionReads++;
    return {'sessions': const []};
  }
}

Map<String, dynamic> _job(String execution, String status) => {
  'id': 'job-1',
  'name': 'Nightly report',
  'latest_execution': {'id': execution, 'status': status},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  sqflite.databaseFactory = databaseFactoryFfi;

  group('cron follows cron.changed on the socket the listener keeps', () {
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    late List<String> shown;
    late SharedPreferences prefs;
    late NotificationService notif;
    late _CronDashboard dashboard;
    late LoopbackGateway gateway;
    late TuiGatewayClient client;
    TuiGatewayClient? kept;

    BackgroundAutomationDiscovery discovery() => BackgroundAutomationDiscovery(
      dashboardClients: BackgroundDashboardClientCache(
        create: (_) => dashboard,
      ),
      discoveryBackoff: BackgroundDiscoveryBackoff(),
      sendToMain: (_) {},
      keptGateway: (_) => kept,
    );

    setUp(() async {
      final dir = await Directory.systemTemp.createTemp('listener-idle-');
      addTearDown(() => dir.delete(recursive: true));
      HttpOverrides.global = null;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      NotificationService.setAutomationNotificationsEnabledForTest(true);
      shown = [];
      SharedPreferences.setMockInitialValues({
        'app_locale': 'en',
        'notif_perm_requested': true,
        'notif_background_listen': true,
        'notif_hide_sensitive_content': false,
        'notif_cron_results': true,
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'show') {
          shown.add('${(call.arguments as Map)['title']}');
        }
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
      dashboard = _CronDashboard()..jobs = [_job('e1', 'completed')];
      gateway = LoopbackGateway();
      await gateway.start();
      client = gateway.client();
      addTearDown(client.close);
      kept = client;
    });

    tearDown(() async {
      await notif.closeDelivery();
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
      NotificationService.setAutomationNotificationsEnabledForTest(false);
    });

    Future<void> tick(BackgroundAutomationDiscovery d) async {
      await d.discoverCronRuns(notif, prefs, [gateway.connection]);
      await settleLoopback();
    }

    test('ten idle ticks after the first read list nothing: no jobs, no '
        'sessions', () async {
      await client.connect();
      final asked = gateway.methods.length;
      final d = discovery();
      await tick(d);
      expect(dashboard.jobReads, 1);
      expect(dashboard.sessionReads, 1);
      for (var i = 0; i < 10; i++) {
        await tick(d);
      }
      expect(dashboard.jobReads, 1, reason: '0 cron/jobs per idle tick');
      expect(dashboard.sessionReads, 1, reason: '0 session lists per tick');
      expect(gateway.methods, hasLength(asked), reason: 'it only listens');
    });

    test('cron.changed lists once and the failed run is notified; the ticks '
        'after it are idle again', () async {
      await client.connect();
      final d = discovery();
      await tick(d);
      dashboard.jobs = [_job('e2', 'failed')];
      await tick(d);
      expect(dashboard.jobReads, 1, reason: 'no signal yet');
      expect(shown, isEmpty);

      gateway.broadcast('cron.changed');
      await settleLoopback();
      await tick(d);
      expect(dashboard.jobReads, 2);
      expect(shown, ['Scheduled task failed']);
      await tick(d);
      await tick(d);
      expect(dashboard.jobReads, 2);
      expect(shown, hasLength(1));
    });

    test('a run in flight is listed on every tick until it ends', () async {
      await client.connect();
      dashboard.jobs = [_job('e1', 'running')];
      final d = discovery();
      await tick(d);
      await tick(d);
      await tick(d);
      expect(dashboard.jobReads, 3);
      dashboard.jobs = [_job('e1', 'failed')];
      await tick(d);
      expect(dashboard.jobReads, 4);
      expect(shown, ['Scheduled task failed']);
      await tick(d);
      expect(dashboard.jobReads, 4);
    });

    test('a cron.changed lost while the socket was down is made up for after '
        'the redial', () async {
      await client.connect();
      final d = discovery();
      await tick(d);
      await gateway.drop();
      await settleLoopback();
      // The run fails while the socket is down: its broadcast is gone.
      dashboard.jobs = [_job('e2', 'failed')];
      await client.connectForeground();
      await settleLoopback();
      expect(client.isConnected, isTrue);
      await tick(d);
      expect(dashboard.jobReads, 2);
      expect(shown, ['Scheduled task failed']);
      await tick(d);
      expect(dashboard.jobReads, 2);
    });

    test('a socket that is down lists on every tick', () async {
      await client.connect();
      final d = discovery();
      await tick(d);
      await gateway.drop();
      await settleLoopback();
      await tick(d);
      await tick(d);
      expect(dashboard.jobReads, 3);
    });

    test('a routine of another profile, which moves no cron.changed, is '
        'listed on every tick', () async {
      await client.connect();
      dashboard.jobs = [
        _job('e1', 'completed'),
        {..._job('e7', 'completed'), 'id': 'job-7', 'profile': 'radar'},
      ];
      final d = discovery();
      for (var i = 0; i < 3; i++) {
        await tick(d);
      }
      expect(dashboard.jobReads, 3);
      dashboard.jobs = [
        _job('e1', 'completed'),
        {..._job('e8', 'failed'), 'id': 'job-7', 'profile': 'radar'},
      ];
      await tick(d);
      expect(dashboard.jobReads, 4);
      expect(shown, ['Scheduled task failed']);
    });

    test('a routine of another profile that has never run still keeps the '
        'listing read on every tick, so its first results are not skipped',
        () async {
      await client.connect();
      // No `latest_execution`, no `last_run_at`: the job has no execution
      // to show yet.
      const neverRan = {'id': 'job-7', 'name': 'Radar', 'profile': 'radar'};
      dashboard.jobs = [_job('e1', 'completed'), neverRan];
      final d = discovery();
      for (var i = 0; i < 3; i++) {
        await tick(d);
      }
      expect(dashboard.jobReads, 3);
      // Its first run fails; no `cron.changed` arrives for that profile.
      dashboard.jobs = [
        _job('e1', 'completed'),
        {..._job('e8', 'failed'), 'id': 'job-7', 'profile': 'radar'},
      ];
      await tick(d);
      expect(dashboard.jobReads, 4);
      expect(shown, ['Scheduled task failed']);
    });

    test('a server without change events lists on every tick, as '
        'before', () async {
      gateway.changeEvents = false;
      await client.connect();
      final d = discovery();
      for (var i = 0; i < 4; i++) {
        await tick(d);
      }
      expect(dashboard.jobReads, 4);
    });

    test('without a kept socket every tick lists, as before', () async {
      kept = null;
      final d = discovery();
      for (var i = 0; i < 4; i++) {
        await tick(d);
      }
      expect(dashboard.jobReads, 4);
    });

    test('the backstop lists again after thirty idle minutes', () async {
      await client.connect();
      var now = DateTime(2026, 11, 20, 9);
      await withClock(Clock(() => now), () async {
        final d = discovery();
        await tick(d);
        for (var i = 0; i < 9; i++) {
          now = now.add(const Duration(minutes: 3));
          await tick(d);
        }
        expect(dashboard.jobReads, 1, reason: '27 idle minutes, one read');
        now = now.add(const Duration(minutes: 3));
        await tick(d);
        expect(dashboard.jobReads, 2);
      });
    });
  });

}
