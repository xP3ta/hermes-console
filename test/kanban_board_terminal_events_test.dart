// Kanban background notifications follow the board the user picked and the
// terminal event kinds Desktop notifies (plugins/kanban/completion-notify.ts),
// through the REAL delivery path, in the existing tick.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/kanban_watch_board.dart';
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
  apiKey: 'test-key',
  dashboardUrl: 'http://192.168.1.40:9119',
);

/// One board as `GET plugins/kanban/board` and `GET plugins/kanban/tasks/<id>`
/// serve it.
class _Board {
  int latestEventId = 0;
  List<Map<String, dynamic>> tasks = [];
  Map<String, List<Map<String, dynamic>>> events = {};
}

class _FakeDashboard extends DashboardClient {
  _FakeDashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'x');

  /// Key '' is the server's current board (no `board` parameter).
  final Map<String, _Board> boards = {'': _Board()};
  final List<String> requests = [];

  _Board board([String slug = '']) => boards.putIfAbsent(slug, _Board.new);

  @override
  Future<Map<String, dynamic>> apiGet(
    String endpoint, {
    bool retried = false,
  }) async {
    requests.add(endpoint);
    final uri = Uri.parse(endpoint);
    final slug = uri.queryParameters['board'] ?? '';
    if (uri.path == 'plugins/kanban/board') {
      final b = board(slug);
      return {
        'columns': [
          {'name': 'all', 'tasks': b.tasks},
        ],
        'latest_event_id': b.latestEventId,
      };
    }
    if (uri.path.startsWith('plugins/kanban/tasks/')) {
      final id = Uri.decodeComponent(uri.pathSegments.last);
      return {
        'task': {'id': id},
        'events': board(slug).events[id] ?? const [],
      };
    }
    return const {};
  }

  int get taskReads =>
      requests.where((r) => r.startsWith('plugins/kanban/tasks/')).length;
}

Map<String, dynamic> _task(
  String status, {
  int failures = 0,
  String id = 't_1',
}) => {
  'id': id,
  'title': 'Write report',
  'status': status,
  'consecutive_failures': failures,
};

Map<String, dynamic> _event(int id, String kind) => {
  'id': id,
  'task_id': 't_1',
  'kind': kind,
  'payload': const <String, dynamic>{},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  sqflite.databaseFactory = databaseFactoryFfi;

  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> shows;
  late _FakeDashboard dashboard;
  late SharedPreferences prefs;
  late NotificationService notif;
  late BackgroundAutomationDiscovery discovery;

  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('kanban-events-');
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    NotificationService.setAutomationNotificationsEnabledForTest(true);
    shows = [];
    SharedPreferences.setMockInitialValues({
      'app_locale': 'en',
      'notif_perm_requested': true,
      'notif_background_listen': true,
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

  Future<void> tick() =>
      discovery.discoverKanbanTransitions(notif, prefs, [_connection()]);
  List<String> titles() => [
    for (final call in shows) '${(call.arguments as Map)['title']}',
  ];

  test(
    'the board picked in Tasks is the one watched, in the same tick',
    () async {
      await KanbanWatchBoard.write(prefs, _connId, 'ops');
      final ops = dashboard.board('ops')
        ..latestEventId = 4
        ..tasks = [_task('running')];
      // The server's current board has its own task that must not be read.
      dashboard.board().tasks = [
        {'id': 't_other', 'title': 'Other', 'status': 'running'},
      ];
      await tick();
      expect(dashboard.requests, ['plugins/kanban/board?board=ops']);

      ops
        ..latestEventId = 5
        ..tasks = [_task('blocked')];
      dashboard.requests.clear();
      await tick();
      expect(titles(), ['Kanban task blocked']);
      expect(dashboard.requests.first, 'plugins/kanban/board?board=ops');
    },
  );

  test('without a picked board the server current board keeps its old '
      'request and scope', () async {
    dashboard.board().tasks = [_task('running')];
    await tick();
    expect(dashboard.requests, ['plugins/kanban/board']);
    dashboard.board().tasks = [_task('done')];
    await tick();
    expect(titles(), ['Kanban task completed']);
  });

  test('a crash that left the task retrying notifies once', () async {
    final b = dashboard.board()
      ..latestEventId = 10
      ..tasks = [_task('running')];
    await tick();
    expect(dashboard.taskReads, 0, reason: 'first look only baselines');

    b
      ..latestEventId = 12
      ..tasks = [_task('running', failures: 1)]
      ..events = {
        't_1': [
          _event(9, 'crashed'),
          _event(11, 'crashed'),
          _event(12, 'spawned'),
        ],
      };
    await tick();
    expect(titles(), ['Kanban task hit a problem — retrying']);

    // The same events seen again (next tick, cursor not advanced): silent.
    await tick();
    b.latestEventId = 13;
    b.tasks = [_task('running', failures: 1)];
    await tick();
    expect(titles(), hasLength(1));
  });

  test('a timeout notifies with its own wording', () async {
    final b = dashboard.board()
      ..latestEventId = 3
      ..tasks = [_task('running')];
    await tick();
    b
      ..latestEventId = 4
      ..tasks = [_task('ready', failures: 1)]
      ..events = {
        't_1': [_event(4, 'timed_out')],
      };
    await tick();
    expect(titles(), ['Kanban task took too long — retrying']);
  });

  test('giving up says so instead of a plain blocked notice', () async {
    final b = dashboard.board()
      ..latestEventId = 20
      ..tasks = [_task('running', failures: 2)];
    await tick();
    b
      ..latestEventId = 22
      ..tasks = [_task('blocked', failures: 3)]
      ..events = {
        't_1': [_event(21, 'timed_out'), _event(22, 'gave_up')],
      };
    await tick();
    expect(
      titles(),
      unorderedEquals([
        'Kanban task stopped',
        'Kanban task took too long — retrying',
      ]),
    );
  });

  test('a block loop routed to triage asks for a decision', () async {
    final b = dashboard.board()
      ..latestEventId = 30
      ..tasks = [_task('blocked')];
    await tick();
    b
      ..latestEventId = 31
      ..tasks = [_task('triage')]
      ..events = {
        't_1': [_event(31, 'block_loop_detected')],
      };
    await tick();
    expect(titles(), ['Kanban task sent to triage — needs a decision']);
  });

  test(
    'task details are read only when the board event cursor moved',
    () async {
      final b = dashboard.board()
        ..latestEventId = 7
        ..tasks = [_task('running')];
      await tick();
      // A higher failure count with the cursor unchanged reads nothing.
      b.tasks = [_task('running', failures: 1)];
      await tick();
      await tick();
      expect(dashboard.taskReads, 0);
      expect(
        dashboard.requests.where((r) => r.startsWith('plugins/kanban/board')),
        hasLength(3),
      );
    },
  );

  test(
    'switching boards baselines the new board without its history',
    () async {
      await KanbanWatchBoard.write(prefs, _connId, 'ops');
      dashboard.board('ops')
        ..latestEventId = 50
        ..tasks = [_task('running', failures: 3)]
        ..events = {
          't_1': [_event(49, 'crashed')],
        };
      await tick();
      await KanbanWatchBoard.write(prefs, _connId, 'research');
      dashboard.board('research')
        ..latestEventId = 80
        ..tasks = [_task('blocked', failures: 5, id: 't_2')];
      await tick();
      expect(shows, isEmpty);
      expect(dashboard.taskReads, 0);
    },
  );

  test('a muted task gets no retry notices', () async {
    final b = dashboard.board()
      ..latestEventId = 1
      ..tasks = [_task('running')];
    await tick();
    await NotificationMuteStore(
      prefs,
    ).setKanbanMuted(connId: _connId, taskId: 't_1', muted: true);
    b
      ..latestEventId = 2
      ..tasks = [_task('running', failures: 1)]
      ..events = {
        't_1': [_event(2, 'crashed')],
      };
    await tick();
    expect(shows, isEmpty);
  });
}
