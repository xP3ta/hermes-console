// SPDX-License-Identifier: GPL-3.0-only
// A user reported 1.7 GiB a day with background listening on. Every tick of
// the foreground-service listener (30–180 s) downloaded the whole Kanban
// board of each watched connection. Desktop follows the board's
// `task_events` instead (apps/desktop/src/plugins/kanban/api.ts: an
// `/events?since=` socket opened at the snapshot's `latest_event_id`) and
// reads the board again when a frame says it moved. These tests count what
// reaches a real loopback Dashboard on each tick.
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/kanban_watch_board.dart';
import 'package:hermes_android/core/services/notifications/background_listener.dart';
import 'package:hermes_android/core/services/notifications/notification_delivery_store.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/remove_test_dir.dart';

const _connId = 'kanban-follow';

Map<String, dynamic> _task(String status) => {
  'id': 't_1',
  'title': 'Write report',
  'status': status,
  'consecutive_failures': 0,
};

/// The Kanban routes of a Dashboard (plugins/kanban/dashboard/plugin_api.py
/// in both server trees): the board with its `latest_event_id`, the task
/// detail, the ticket, and the `/events?since=` socket, which sends
/// `{"events": [...], "cursor": <id>}` for each event past its cursor.
class _Dashboard {
  late HttpServer server;
  String get base => 'http://127.0.0.1:${server.port}';

  /// False: a server without the events route (the upgrade is refused).
  bool eventsRoute = true;

  int latestEventId = 7;
  Map<String, dynamic> task = _task('running');

  /// `METHOD path` of every request that arrived, upgrades included.
  final requests = <String>[];

  /// Bytes of every board body sent.
  int boardBytes = 0;

  final sockets = <WebSocket>[];
  final since = <String?>[];

  int get boardReads =>
      requests.where((r) => r == 'GET /api/plugins/kanban/board').length;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
    });
    server.listen(_handle);
  }

  Future<void> _json(HttpRequest r, Object body, [int status = 200]) async {
    final bytes = utf8.encode(jsonEncode(body));
    if (r.uri.path == '/api/plugins/kanban/board') boardBytes += bytes.length;
    r.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..add(bytes);
    await r.response.close();
  }

  Future<void> _handle(HttpRequest r) async {
    requests.add('${r.method} ${r.uri.path}');
    switch (r.uri.path) {
      case '/api/plugins/kanban/events':
        if (!eventsRoute || !WebSocketTransformer.isUpgradeRequest(r)) {
          return _json(r, {'detail': 'Not Found'}, 404);
        }
        since.add(r.uri.queryParameters['since']);
        sockets.add(await WebSocketTransformer.upgrade(r));
      case '/api/auth/ws-ticket':
        return _json(r, {'ticket': 'test-ticket'});
      case '/api/plugins/kanban/board':
        return _json(r, {
          'columns': [
            {
              'name': 'all',
              'tasks': [task],
            },
          ],
          'latest_event_id': latestEventId,
        });
      default:
        if (r.uri.path.startsWith('/api/plugins/kanban/tasks/')) {
          return _json(r, {'task': task, 'events': const []});
        }
        return _json(r, {'detail': 'Not Found'}, 404);
    }
  }

  /// The task moves: one event, and a frame on every open socket.
  void move(String status) {
    latestEventId += 1;
    task = _task(status);
    final frame = jsonEncode({
      'events': [
        {
          'id': latestEventId,
          'task_id': 't_1',
          'kind': 'status',
          'payload': {'status': status},
        },
      ],
      'cursor': latestEventId,
    });
    for (final socket in sockets) {
      socket.add(frame);
    }
  }

  /// The server closes the sockets (restart, idle proxy).
  Future<void> dropSockets() async {
    for (final socket in sockets) {
      await socket.close();
    }
    sockets.clear();
  }
}

/// Lets frames and closes travel over loopback.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 150));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  sqflite.databaseFactory = databaseFactoryFfi;

  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<String> shown;
  late _Dashboard server;
  late SharedPreferences prefs;
  late NotificationService notif;
  late BackgroundAutomationDiscovery discovery;
  late SavedConnection connection;

  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('kanban-follow-');
    addTearDown(() => removeTestDir(dir));
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
      'notif_kanban_results': true,
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
    server = _Dashboard();
    await server.start();
    connection = SavedConnection(
      id: _connId,
      label: 'Kanban',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'test-key',
      dashboardUrl: server.base,
    );
    final dashboard = DashboardClient(
      host: '127.0.0.1',
      port: server.server.port,
      manualToken: 'test-session-token',
    );
    addTearDown(dashboard.close);
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
    NotificationService.setAutomationNotificationsEnabledForTest(false);
  });

  Future<void> tick() async {
    await discovery.discoverKanbanTransitions(notif, prefs, [connection]);
    await _settle();
  }

  test('ten idle ticks after the first read send no request at all: no '
      'board, no ticket, no socket', () async {
    await tick();
    // The first tick reads the board, then follows its events from there.
    expect(server.requests, [
      'GET /api/plugins/kanban/board',
      'POST /api/auth/ws-ticket',
      'GET /api/plugins/kanban/events',
    ]);
    expect(server.since, ['7']);
    final bytes = server.boardBytes;
    expect(bytes, greaterThan(0));

    for (var i = 0; i < 10; i++) {
      await tick();
    }
    expect(server.requests, hasLength(3), reason: '0 requests per idle tick');
    expect(server.boardBytes, bytes, reason: '0 board bytes per idle tick');
  });

  test('a moved cursor reads the board once, notifies, and the ticks after '
      'it are idle again', () async {
    await tick();
    await tick();
    expect(server.boardReads, 1);

    server.move('blocked');
    await _settle();
    await tick();
    expect(server.boardReads, 2, reason: 'one read for the moved cursor');
    expect(shown, ['Task blocked']);

    final requests = server.requests.length;
    await tick();
    await tick();
    expect(server.requests, hasLength(requests));
    expect(server.boardReads, 2);
  });

  test('a server without the events route reads the board on every tick, '
      'as before, and asks for the route once', () async {
    server.eventsRoute = false;
    for (var i = 0; i < 5; i++) {
      await tick();
    }
    expect(server.boardReads, 5, reason: 'one board read per tick');
    expect(
      server.requests.where((r) => r == 'GET /api/plugins/kanban/events'),
      hasLength(1),
    );
    expect(
      server.requests.where((r) => r == 'POST /api/auth/ws-ticket'),
      hasLength(1),
    );

    server.move('blocked');
    await tick();
    expect(shown, ['Task blocked'], reason: 'notices as before');
  });

  test('a dropped socket costs one read on the next tick, which follows '
      'again from the new cursor', () async {
    await tick();
    server.move('blocked');
    await _settle();
    await server.dropSockets();
    await _settle();

    await tick();
    expect(server.boardReads, 2);
    expect(server.since, ['7', '8'], reason: 'reopened at the read cursor');
    await tick();
    expect(server.boardReads, 2);
  });

  test('with the socket up on a board the phone names, the board is read '
      'again only every thirty minutes with nothing moving', () async {
    // A named board: its socket follows exactly the board the reads ask for.
    await KanbanWatchBoard.write(prefs, _connId, 'main');
    var now = DateTime(2026, 11, 20, 9);
    await withClock(Clock(() => now), () async {
      await tick();
      // Idle ticks of the listener's slowest cadence (180 s).
      for (var i = 0; i < 9; i++) {
        now = now.add(const Duration(minutes: 3));
        await tick();
      }
      expect(server.boardReads, 1, reason: '27 idle minutes, one read');
      now = now.add(const Duration(minutes: 3));
      await tick();
      expect(server.boardReads, 2, reason: 'the backstop at 30 minutes');
      await tick();
      expect(server.boardReads, 2);
      expect(
        server.requests.where((r) => r == 'GET /api/plugins/kanban/events'),
        hasLength(1),
        reason: 'the same socket all along',
      );
    });
  });

  test('with no board named, the server may switch boards under a healthy '
      'socket: the board is read every ten minutes and the socket reopened',
      () async {
    var now = DateTime(2026, 11, 20, 9);
    await withClock(Clock(() => now), () async {
      await tick();
      for (var i = 0; i < 3; i++) {
        now = now.add(const Duration(minutes: 3));
        await tick();
      }
      expect(server.boardReads, 1, reason: 'nine idle minutes, one read');
      // The server's current board is another one now; it blocks a task
      // there. The old socket, pinned to the first board, stays silent.
      server.task = _task('blocked');
      now = now.add(const Duration(minutes: 3));
      await tick();
      expect(server.boardReads, 2, reason: 'read at ten minutes, not thirty');
      expect(shown, isNotEmpty, reason: 'the blocked task is announced');
      expect(
        server.requests.where((r) => r == 'GET /api/plugins/kanban/events'),
        hasLength(2),
        reason: 'pinned again, to the board current now',
      );
    });
  });

  test('a server without the route is asked for it again every ten '
      'minutes, its board read on every tick meanwhile', () async {
    server.eventsRoute = false;
    var now = DateTime(2026, 11, 20, 9);
    await withClock(Clock(() => now), () async {
      await tick();
      now = now.add(const Duration(minutes: 9));
      await tick();
      expect(server.boardReads, 2);
      expect(
        server.requests.where((r) => r == 'GET /api/plugins/kanban/events'),
        hasLength(1),
      );
      now = now.add(const Duration(minutes: 1));
      await tick();
      expect(server.boardReads, 3);
      expect(
        server.requests.where((r) => r == 'GET /api/plugins/kanban/events'),
        hasLength(2),
      );
    });
  });
}
