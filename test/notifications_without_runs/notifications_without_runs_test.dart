// Notifications and their actions never touch the REST run API (`/v1/runs`).
// Approve and stop use the Dashboard socket methods only, as Desktop does
// (`respondToApprovalAction` in apps/desktop/src/store/native-notifications.ts).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardClient, DashboardWebSocketAuth, SavedConnection;
import 'package:hermes_android/core/services/notifications/background_listener.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/notification_action_ops.dart';
import 'package:hermes_android/core/services/notifications/notification_delivery_store.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:hermes_android/core/services/notifications/session_attention.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/desktop_chat_socket.dart' show HostCounter;

const _legacy =
    '[{"connId":"c1","base":"http://127.0.0.1:8642","runId":"run-1"},'
    '{"connId":"c1","base":"http://127.0.0.1:8642","runId":"run-2"}]';
const _session = NotificationActionRoute.session;

class _Dashboard extends DashboardClient {
  _Dashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');
  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 'fixture');
}

/// Dashboard socket double: `session.active_list` lists one running turn.
class _Gateway {
  late final HttpServer server;
  final frames = <Map<String, dynamic>>[];
  final paths = <String>[];

  Iterable<Map> calls(String m) =>
      frames.where((f) => f['method'] == m).map((f) => f['params'] as Map);

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      paths.add(request.uri.path);
      final socket = await WebSocketTransformer.upgrade(request);
      void send(Map<String, Object?> m) =>
          socket.add(jsonEncode({'jsonrpc': '2.0', ...m}));
      send({
        'method': 'event',
        'params': {
          'type': 'gateway.ready',
          'payload': {'heartbeat': false},
        },
      });
      socket.listen((raw) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        frames.add(frame);
        send({
          'id': frame['id'],
          'result': switch (frame['method']) {
            'session.active_list' => {
              'sessions': [
                {'id': 'rt-1', 'session_key': 'stored-1', 'status': 'working'},
              ],
            },
            'approval.respond' => {'resolved': 1},
            _ => <String, Object?>{},
          },
        });
      });
    });
  }

  NotificationActionRouter get router => NotificationActionRouter(
    sink: _Sink(),
    t: const NotifL10n(false),
    ops: GatewayNotificationActionOps(
      resolveConnection: (_) => SavedConnection(
        id: 'c1',
        label: 'Test',
        host: '127.0.0.1',
        port: server.port,
        apiKey: 'fixture-key',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      chatApproval: (_, _) async => false,
      chatStop: (_) async => false,
      clientFactory: (c) => TuiGatewayClient(
        c,
        dashboard: _Dashboard(),
        heartbeatInterval: const Duration(hours: 1),
        heartbeatDeadline: const Duration(hours: 2),
      ),
    ),
  );
}

final class _Sink implements RichNotificationSink {
  final posts = <Map<String, Object?>>[];
  @override
  Future<void> cancel({required int id, String? tag}) async {}
  @override
  Future<void> confirm({
    required int id,
    String? tag,
    String? title,
    required String text,
    int timeoutMs = 4000,
    bool onlyIfActive = false,
  }) async {}
  @override
  Future<bool> postConversation(Map<String, Object?> args) async {
    posts.add(args);
    return true;
  }

  @override
  Future<void> postLiveUpdate(Map<String, Object?> args) async {}
}

PendingNotificationAction _act(
  String action,
  NotificationActionRoute route, {
  String? sessionId,
  String? runId,
  String? requestId,
}) => PendingNotificationAction(
  uid: 'u-$action',
  action: action,
  notificationId: 1,
  payload: NotificationActionPayload(
    route: route,
    connId: 'c1',
    sessionId: sessionId,
    runId: runId,
    requestId: requestId,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  sqflite.databaseFactory = databaseFactoryFfi;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channels = [
    'plugins.it_nomads.com/flutter_secure_storage',
    'flutter_foreground_task/background',
    'flutter_foreground_task/methods',
    'dexterous.com/flutter/local_notifications',
  ];

  test('no notification file names the REST run API', () {
    final rest = RegExp(
      r'v1/runs|ApiClient\(|resolveRunApproval|stopRun|getRun\(',
    );
    for (final f in Directory(
      'lib/core/services/notifications',
    ).listSync().whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      expect(rest.hasMatch(f.readAsStringSync()), isFalse, reason: f.path);
    }
    final sink = File(
      'lib/core/services/notifications/session_attention.dart',
    ).readAsStringSync();
    expect(RegExp(r'Timer|Socket|WebSocket|http').hasMatch(sink), isFalse);
  });

  group('the service tick', () {
    final foreground = <MethodCall>[];
    final shown = <String>[];

    Future<HostCounter> tickTwice(bool optIn) async {
      SharedPreferences.setMockInitialValues({
        BackgroundListener.prefKey: optIn,
        'bg_watch_runs': _legacy,
      });
      final counter = HostCounter(register: addTearDown);
      await http.runWithClient(() async {
        final tick = backgroundTickForTest();
        await tick();
        await tick();
      }, () => counter);
      return counter;
    }

    setUp(() {
      foreground.clear();
      shown.clear();
      NotificationService.setAutomationNotificationsEnabledForTest(true);
      for (final name in channels) {
        messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
          if (name.endsWith('methods')) foreground.add(call);
          if (call.method == 'show') shown.add(call.method);
          return call.method == 'isRunningService' ? true : null;
        });
      }
    });

    tearDown(() {
      NotificationService.setAutomationNotificationsEnabledForTest(false);
      for (final name in channels) {
        messenger.setMockMethodCallHandler(MethodChannel(name), null);
      }
    });

    test('two old watches: no /v1/runs, list dropped, idle cadence', () async {
      final counter = await tickTwice(true);
      expect(counter.requests, isEmpty);
      expect(await BackgroundWatch.snapshot(), isEmpty);
      expect(shown, isEmpty);
      final updates = foreground
          .where((c) => c.method == 'updateService')
          .map((c) => jsonEncode(c.arguments))
          .join();
      expect(updates, contains('180000'));
      expect(updates, isNot(contains('30000')));
    });

    test('without opt-in the old list goes and the service stops', () async {
      final counter = await tickTwice(false);
      expect(counter.requests, isEmpty);
      expect(await BackgroundWatch.snapshot(), isEmpty);
      expect(foreground.map((c) => c.method), contains('stopService'));
    });
  });

  group('actions without the app', () {
    late _Gateway gateway;
    late HostCounter rest;
    Future<ActionOutcome> handle(PendingNotificationAction a) =>
        http.runWithClient(() => gateway.router.handle(a), () => rest);
    const secure = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    setUp(() async {
      messenger.setMockMethodCallHandler(secure, (_) async => null);
      rest = HostCounter(register: addTearDown);
      await (gateway = _Gateway()).start();
    });
    tearDown(() async {
      messenger.setMockMethodCallHandler(secure, null);
      await gateway.server.close(force: true);
    });

    test('stop with a run id interrupts the exact runtime id', () async {
      final stop = _act('stop', _session, sessionId: 'stored-1', runId: 'r');
      expect(await handle(stop), ActionOutcome.done);
      expect(gateway.calls('session.active_list'), hasLength(1));
      expect(gateway.calls('session.interrupt').single['session_id'], 'rt-1');
      expect(rest.requests, isEmpty);
    });

    test('stop with a run id and no session opens the app', () async {
      final stop = _act('stop', _session, runId: 'run-1');
      expect(await handle(stop), ActionOutcome.failed);
      expect(gateway.frames, isEmpty);
      expect(gateway.paths, isEmpty);
      expect(rest.requests, isEmpty);
    });

    test('an old run action fails (opens the app) without a call', () async {
      const run = NotificationActionRoute.run;
      for (final a in ['approve', 'stop']) {
        final old = _act(
          a,
          run,
          sessionId: 'stored-1',
          runId: 'run-1',
          requestId: 'req-1',
        );
        expect(await handle(old), ActionOutcome.failed);
      }
      expect(gateway.frames, isEmpty);
      expect(gateway.paths, isEmpty);
      expect(rest.requests, isEmpty);
    });

    test('chat approval answers approval.respond by request id', () async {
      const chat = NotificationActionRoute.chat;
      await handle(
        _act('approve', chat, sessionId: 'stored-1', requestId: 'req-1'),
      );
      final sent = gateway.calls('approval.respond').single;
      expect([sent['request_id'], sent['session_id']], ['req-1', 'stored-1']);
      expect(rest.requests, isEmpty);
    });
  });

  group('session attention sink', () {
    late _Sink sink;
    late NotificationService service;
    late Directory dir;
    late _Gateway gateway;
    late NotificationSessionAttentionSink attention;

    setUp(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      messenger.setMockMethodCallHandler(MethodChannel(channels.last), (
        call,
      ) async {
        return switch (call.method) {
          'initialize' || 'areNotificationsEnabled' => true,
          'getNotificationAppLaunchDetails' => {
            'notificationLaunchedApp': false,
            'notificationResponse': null,
          },
          'getActiveNotifications' => const <Object?>[],
          _ => null,
        };
      });
      SharedPreferences.setMockInitialValues({
        'app_locale': 'es',
        'notif_perm_requested': true,
        'notif_background_listen': true,
      });
      dir = await Directory.systemTemp.createTemp('attention-');
      final store = NotificationDeliveryStore(
        databasePath: '${dir.path}/delivery.db',
      );
      service = NotificationService(
        await SharedPreferences.getInstance(),
        deliveryStore: store,
      );
      service
        ..setRichForTesting(
          sink = _Sink(),
          faces: BotFaceBitmapCache(directory: () async => dir),
        )
        ..appInForeground = false;
      attention = NotificationSessionAttentionSink(service);
      await (gateway = _Gateway()).start();
    });

    tearDown(() async {
      await service.closeDelivery();
      await gateway.server.close(force: true);
      messenger.setMockMethodCallHandler(MethodChannel(channels.last), null);
      debugDefaultTargetPlatformOverride = null;
      await dir.delete(recursive: true);
    });

    Future<void> deliver(SessionAttentionKind kind, [String? requestId]) =>
        attention.deliver(
          SessionAttentionSignal(
            kind: kind,
            connId: 'c1',
            profile: 'default',
            storedSessionId: 'stored-1',
            requestId: requestId,
            title: 'Build',
          ),
        );

    List<Object?> actionIds(Map<String, Object?> card) => [
      for (final a in card['actions']! as List) (a as Map)['id'],
    ];

    test(
      'an approval is the in-app card, once, and its button resolves',
      () async {
        await deliver(SessionAttentionKind.approval, 'req-1');
        await deliver(SessionAttentionKind.approval, 'req-1');
        final card = sink.posts.single;
        expect(actionIds(card), ['approve', 'deny', 'open']);
        final p = NotificationActionPayload.tryParse(
          card['actionPayload'] as String,
        )!;
        expect(p.route, NotificationActionRoute.chat);
        expect([p.sessionId, p.requestId], ['stored-1', 'req-1']);
        expect(p.choices, ['once', 'deny']);
        await gateway.router.handle(
          PendingNotificationAction(
            uid: 'u',
            action: 'approve',
            notificationId: 1,
            payload: p,
          ),
        );
        expect(gateway.calls('approval.respond').single['request_id'], 'req-1');
      },
    );

    test('without a request id there are no approval buttons', () async {
      await deliver(SessionAttentionKind.approval);
      expect(
        sink.posts.where((c) => actionIds(c).contains('approve')),
        isEmpty,
      );
    });

    test('done, error and input use the existing cards', () async {
      await deliver(SessionAttentionKind.turnDone);
      await deliver(SessionAttentionKind.turnError);
      await deliver(SessionAttentionKind.input, 'q-1');
      expect(sink.posts, hasLength(3));
      expect(actionIds(sink.posts.last), ['open']);
    });
  });
}
