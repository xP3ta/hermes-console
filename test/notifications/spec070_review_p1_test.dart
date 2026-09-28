// Spec 070 review P1 fixes: notification actions, lock-screen, Live Update
// expiry and listener battery policy.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/bot_mode_repository.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardClient, DashboardWebSocketAuth;
import 'package:hermes_android/core/services/notifications/background_listener.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/bot_mode_background.dart';
import 'package:hermes_android/core/services/notifications/notification_action_drain.dart';
import 'package:hermes_android/core/services/notifications/notification_action_ops.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:hermes_android/core/services/notifications/room_watcher.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bots/room/room_fixtures.dart';

const en = NotifL10n(false);

class _FixtureDashboard extends DashboardClient {
  _FixtureDashboard()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 'fixture');
}

/// Official Hermes gateway shapes (`tui_gateway/methods_prompt.py`): no
/// `client_turn_id`, `prompt.submit` answers `{status: "streaming"}`.
class _OfficialGateway {
  late final HttpServer server;
  final frames = <Map<String, dynamic>>[];
  Map<String, dynamic> approvalResult = {'resolved': 1};

  List<Map<String, dynamic>> calls(String method) => [
    for (final f in frames)
      if (f['method'] == method) f,
  ];

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'gateway.ready',
            'payload': {'heartbeat': false},
          },
        }),
      );
      socket.listen((raw) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        frames.add(frame);
        final params =
            (frame['params'] as Map?)?.cast<String, dynamic>() ?? const {};
        final Map<String, dynamic> result = switch (frame['method']) {
          'gateway.capabilities' => {'per_session_exclusive_submit': true},
          'session.active_list' => {'sessions': <Object>[]},
          'session.resume' => {
            'session_id': 'runtime-bot',
            'stored_session_id': params['session_id'],
            'session_key': params['session_id'],
            'created': false,
            'messages': <Object>[],
          },
          'prompt.submit' => {'status': 'streaming'},
          'approval.respond' => approvalResult,
          _ => <String, dynamic>{},
        };
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
        );
      });
    });
  }

  SavedConnection get connection => SavedConnection(
    id: 'c-official',
    label: 'Official',
    host: '127.0.0.1',
    port: server.port,
    apiKey: '',
    dashboardUrl: 'http://127.0.0.1:${server.port}',
  );

  GatewayNotificationActionOps ops({bool idempotency = false}) =>
      GatewayNotificationActionOps(
        resolveConnection: (_) => connection,
        turnIdempotency: (_) async => idempotency,
        chatApproval: (_, _) async => false,
        clientFactory: (c) => TuiGatewayClient(
          c,
          dashboard: _FixtureDashboard(),
          heartbeatInterval: const Duration(hours: 1),
          heartbeatDeadline: const Duration(hours: 2),
        ),
      );
}

PendingNotificationAction reply(
  NotificationActionPayload p, {
  String uid = 'u1',
  String text = 'thanks',
  bool reclaimed = false,
  bool expired = false,
}) => PendingNotificationAction(
  uid: uid,
  action: 'reply',
  payload: p,
  notificationId: 7,
  tag: 'tag',
  text: text,
  reclaimed: reclaimed,
  expired: expired,
);

const botChat = NotificationActionPayload(
  route: NotificationActionRoute.botChat,
  connId: 'c-official',
  profile: 'builder',
  sessionId: 'stored-bot-chat',
);

SavedConnection conn(String id, {bool readOnly = false}) =>
    SavedConnection.fromMap({
      'id': id,
      'label': 'Home $id',
      'host': '192.168.1.20',
      'port': 8642,
      'apiKey': '',
      'useHttps': false,
      'read_only': readOnly,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P1-1 Bot Chat inline reply on the official gateway', () {
    late _OfficialGateway gateway;
    setUp(() async {
      gateway = _OfficialGateway();
      await gateway.start();
    });
    tearDown(() => gateway.server.close(force: true));

    test('{status: streaming} is success, no client_turn_id, one turn', () async {
      final sink = _Sink();
      final router = NotificationActionRouter(
        ops: gateway.ops(),
        sink: sink,
        t: en,
      );
      expect(await router.handle(reply(botChat)), ActionOutcome.done);
      expect(sink.confirms, ['Sent']);
      final submits = gateway.calls('prompt.submit');
      expect(submits, hasLength(1));
      final params = submits.single['params'] as Map;
      expect(params['text'], 'thanks');
      expect(params.containsKey('client_turn_id'), isFalse);
      expect(params['session_id'], 'runtime-bot');

      // The same tap re-delivered after a crash is never submitted again.
      expect(
        await router.handle(reply(botChat, reclaimed: true)),
        ActionOutcome.ignored,
      );
      expect(gateway.calls('prompt.submit'), hasLength(1));
    });

    test('a reclaimed Bot Chat reply of a dead executor is not resent', () async {
      final sink = _Sink();
      final router = NotificationActionRouter(
        ops: gateway.ops(),
        sink: sink,
        t: en,
      );
      expect(
        await router.handle(reply(botChat, uid: 'z', reclaimed: true)),
        ActionOutcome.maybeDone,
      );
      expect(gateway.calls('prompt.submit'), isEmpty);
      expect(sink.confirms, ['Sent · open Hermes to check']);
    });

    test('ambiguous transport after send is not a retryable failure', () async {
      final ops = _Ops()..error = const AmbiguousDeliveryError('timeout');
      final sink = _Sink();
      final router = NotificationActionRouter(ops: ops, sink: sink, t: en);
      expect(await router.handle(reply(botChat)), ActionOutcome.maybeDone);
      expect(sink.confirms, ['Sent · open Hermes to check']);
      ops.error = null;
      // Dedupe survives: a second delivery of the same uid does nothing.
      expect(await router.handle(reply(botChat)), ActionOutcome.ignored);
      expect(ops.calls, isEmpty);
    });

    test('ambiguity classification', () {
      expect(isAmbiguousSubmitFailure(TimeoutException('x')), isTrue);
      expect(
        isAmbiguousSubmitFailure(
          const TuiGatewayRpcError(
            'prompt.submit',
            'Hermes returned an invalid idempotent acknowledgement',
          ),
        ),
        isTrue,
      );
      expect(
        isAmbiguousSubmitFailure(
          const TuiGatewayRpcError('prompt.submit', 'session busy', code: 4009),
        ),
        isFalse,
      );
    });

    test('chat approval without an attached chat answers by durable id', () async {
      final sink = _Sink();
      final router = NotificationActionRouter(
        ops: gateway.ops(),
        sink: sink,
        t: en,
      );
      final outcome = await router.handle(
        const PendingNotificationAction(
          uid: 'a1',
          action: 'approve',
          payload: NotificationActionPayload(
            route: NotificationActionRoute.chat,
            connId: 'c-official',
            profile: 'builder',
            sessionId: 'stored-bot-chat',
            requestId: 'req-9',
          ),
          notificationId: 3,
        ),
      );
      expect(outcome, ActionOutcome.done);
      final respond = gateway.calls('approval.respond').single['params'] as Map;
      expect(respond['session_id'], 'stored-bot-chat');
      expect(respond['request_id'], 'req-9');
      expect(respond['choice'], 'once');
      expect(sink.confirms, ['Approved']);
    });

    test('resolved 0 means answered elsewhere, not a failure', () async {
      gateway.approvalResult = {'resolved': 0};
      final sink = _Sink();
      final router = NotificationActionRouter(
        ops: gateway.ops(),
        sink: sink,
        t: en,
      );
      final outcome = await router.handle(
        const PendingNotificationAction(
          uid: 'a2',
          action: 'deny',
          payload: NotificationActionPayload(
            route: NotificationActionRoute.chat,
            connId: 'c-official',
            sessionId: 'stored-bot-chat',
            requestId: 'req-9',
          ),
          notificationId: 3,
        ),
      );
      expect(outcome, ActionOutcome.alreadyAnswered);
    });
  });

  group('P1-2 drain: never lose a reply, never run twice', () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test('failed reply moves to the composer, card says open to retry', () async {
      final inbox = _Inbox([reply(botChat, text: 'ship it')]);
      final ops = _Ops()..error = StateError('connection unavailable');
      final sink = _Sink();
      final rescue = _Rescue();
      final drainer = NotificationActionDrainer(
        inbox: inbox,
        routes: allNotificationActionRoutes,
        rescue: rescue,
        router: NotificationActionRouter(ops: ops, sink: sink, t: en),
      );
      await drainer.drain();
      expect(rescue.kept, ['builder:ship it']);
      expect(sink.confirms, ['Couldn’t send · open to retry']);
      expect(sink.timeouts.single, 0, reason: 'persistent until acted on');
      expect(inbox.acked, ['u1']);
    });

    test('an expired tap is never executed and its text is kept', () async {
      final inbox = _Inbox([reply(botChat, text: 'late', expired: true)]);
      final ops = _Ops();
      final rescue = _Rescue();
      await NotificationActionDrainer(
        inbox: inbox,
        routes: allNotificationActionRoutes,
        rescue: rescue,
        router: NotificationActionRouter(ops: ops, sink: _Sink(), t: en),
      ).drain();
      expect(ops.calls, isEmpty);
      expect(rescue.kept, ['builder:late']);
      expect(inbox.acked, ['u1']);
    });

    test('ack only after the call; a crash leaves the tap claimable', () async {
      final inbox = _Inbox([reply(botChat)]);
      final ops = _Ops()..hang = Completer<void>();
      final drainer = NotificationActionDrainer(
        inbox: inbox,
        routes: allNotificationActionRoutes,
        router: NotificationActionRouter(ops: ops, sink: _Sink(), t: en),
      );
      unawaited(drainer.drain());
      await pumpEventQueue();
      expect(inbox.acked, isEmpty);
      ops.hang!.complete();
      await pumpEventQueue();
      expect(inbox.acked, ['u1']);
    });

    test('dedupe persists across drains and engines', () async {
      final ops = _Ops();
      NotificationActionRouter router() => NotificationActionRouter(
        ops: ops,
        sink: _Sink(),
        t: en,
        dedupe: PrefsActionDedupeStore(prefs),
      );
      final approval = PendingNotificationAction(
        uid: 'x1',
        action: 'approve',
        payload: roomApprovalPayload(),
        notificationId: 1,
      );
      expect(await router().handle(approval), ActionOutcome.done);
      final second = PendingNotificationAction(
        uid: 'x2',
        action: 'approve',
        payload: roomApprovalPayload(),
        notificationId: 1,
      );
      expect(await router().handle(second), ActionOutcome.ignored);
      expect(ops.calls, ['roomApprove:once']);
    });

    test('room approvals never offer or send Always', () {
      final always = NotificationActionRouter.choiceFor(
        'always',
        roomApprovalPayload(choices: const ['always', 'deny']),
      );
      expect(always, isNull);
      final args = const RichNotificationBuilder(en).approval(
        tag: 't',
        conversationId: 'c',
        conversationTitle: 'R',
        isGroup: true,
        botKey: 'b',
        botName: 'b',
        action: roomApprovalPayload(),
        open: _open,
        offered: const ['always', 'deny'],
        nowMs: 1,
        allowAlways: false,
      );
      expect(
        [for (final a in args['actions'] as List) (a as Map)['id']],
        ['deny', 'open'],
      );
    });

    test('DraftReplyRescue writes the encrypted composer draft once', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final store = ChatDraftStore(prefs);
      final rescue = DraftReplyRescue(prefs, store: store);
      await rescue.keep(botChat, 'ship it');
      await rescue.keep(botChat, 'ship it');
      final draft = await store.load(
        'c-official',
        'mob-bot-builder',
        profile: 'builder',
      );
      expect(draft.text, 'ship it');
      expect(prefs.getKeys().any((k) => prefs.get(k).toString().contains('ship it')),
          isFalse, reason: 'never in clear prefs');
    });

    test('room reply rescue uses the Room screen draft key', () {
      const p = NotificationActionPayload(
        route: NotificationActionRoute.room,
        connId: 'c1',
        roomId: roomId,
        authorityId: gatewayId,
      );
      final address = replyDraftAddress(p, activeProfile: '')!;
      expect(
        address.sessionId,
        'mob-room-${base64Url.encode(utf8.encode(jsonEncode([gatewayId, roomId])))}',
      );
      expect(address.profile, 'default');
      expect(
        replyDraftAddress(botChat, activeProfile: 'x')!.sessionId,
        'mob-bot-builder',
      );
      final back = NotificationActionPayload.tryParse(p.encode())!;
      expect(back.authorityId, gatewayId);
    });

    test('native side: headless drain, encrypted inbox, expiry notice', () {
      final kt = File(
        'android/app/src/main/kotlin/com/hermesagent/hermes_android/HermesRichNotifications.kt',
      ).readAsStringSync();
      final worker = File(
        'android/app/src/main/kotlin/com/hermesagent/hermes_android/HermesActionDrainWorker.kt',
      ).readAsStringSync();
      expect(kt, contains('HermesActionDrainScheduler.drainNow(context)'));
      expect(kt, contains('HermesActionDrainScheduler.scheduleExpirySweep'));
      expect(kt, contains('AES/GCM/NoPadding'));
      expect(kt, isNot(contains('.put("text", text')));
      expect(kt, contains('fun ack('));
      expect(worker, contains('hermesNotificationActionDrain'));
      expect(worker, contains('expireUnexecuted(context, all = true)'));
    });
  });

  group('P1-3 lock screen widgets', () {
    RoomWatchView workingRoom() => RoomWatchView(
      room: buildRoom(latestSeq: 3),
      driverStatus: driver(working: true, pending: [approvalAction()]),
      state: const RoomWatchState(working: true, openMembers: {'m-builder'}),
      lastMemberId: 'm-review',
      lastText: 'secret plan',
    );

    test('hidden content: no command, no last message, no worker title', () {
      final profile = AgentProfile.fromJson({
        'name': 'builder',
        'worker_session': {
          'id': 'w',
          'source': 'kanban',
          'title': 'rotate prod keys',
          'last_active': DateTime(2026).millisecondsSinceEpoch / 1000,
        },
      });
      final snapshot = buildBotModeWidgetSnapshot(
        connection: conn('c1'),
        connected: true,
        profiles: [profile],
        liveSessions: const <DesktopActiveSession>[],
        rooms: [workingRoom()],
        facePaths: const {},
        t: en,
        now: DateTime(2026),
        hideSensitive: true,
      );
      final encoded = snapshot.encode();
      expect(encoded, isNot(contains('gh pr ready')));
      expect(encoded, isNot(contains('secret plan')));
      expect(encoded, isNot(contains('rotate prod keys')));
      expect(snapshot.approvals.single.text, 'Needs your OK');
    });

    test('read-only connection: no Approve/Deny and no Stop', () {
      final snapshot = buildBotModeWidgetSnapshot(
        connection: conn('c1', readOnly: true),
        connected: true,
        profiles: const [],
        liveSessions: const [],
        rooms: [workingRoom()],
        facePaths: const {},
        t: en,
        now: DateTime(2026),
      );
      expect(snapshot.approvals.single.canApprove, isFalse);
      expect(snapshot.room!.stopPayload, isNull);
    });

    test('Bots widget opens the canonical chat, never the legacy pin', () {
      final profile = AgentProfile.fromJson({
        'name': 'builder',
        'ui_meta': {
          'hermes-bots': {'chat': 'legacy-pin'},
        },
        'last_session': {'id': 'recent', 'title': 'x'},
        'canonical_session': {
          'id': 'canon',
          'resolved_id': 'canon--tip',
          'title': 'Bot Chat',
        },
      });
      final snapshot = buildBotModeWidgetSnapshot(
        connection: conn('c1'),
        connected: true,
        profiles: [profile],
        liveSessions: const [],
        rooms: const [],
        facePaths: const {},
        t: en,
        now: DateTime(2026),
      );
      expect(snapshot.bots.single.openPayload, contains('canon--tip'));
      expect(snapshot.bots.single.openPayload, isNot(contains('legacy-pin')));
      expect(snapshot.bots.single.openPayload, isNot(contains('recent')));
    });

    test('actionable widgets are home-screen only; receiver refuses on keyguard', () {
      String xml(String name) =>
          File('android/app/src/main/res/xml/$name.xml').readAsStringSync();
      for (final name in [
        'botw_needs_you_info',
        'botw_room_info',
        'botw_bots_info',
      ]) {
        expect(xml(name), contains('widgetCategory="home_screen"'), reason: name);
      }
      final receiver = File(
        'android/app/src/main/kotlin/com/hermesagent/hermes_android/HermesRichNotifications.kt',
      ).readAsStringSync();
      expect(
        receiver,
        contains(
          'if (source == "widget" && (keyguard == null || keyguard.isKeyguardLocked)) return',
        ),
      );
      final widgets = File(
        'android/app/src/main/kotlin/com/hermesagent/hermes_android/HermesBotModeWidgets.kt',
      ).readAsStringSync();
      expect(widgets, contains('redactedForKeyguard()'));
      expect(widgets, contains('WIDGET_CATEGORY_HOME_SCREEN'));
    });
  });

  group('P1-4/5 Live Update', () {
    test('expires on its own, public version hides names, Stop optional', () {
      final args = const RichNotificationBuilder(en).liveUpdate(
        tag: 't',
        conversationId: 'c',
        title: 'Secret Room',
        members: const [(name: 'builder', state: 'working')],
        workingName: 'builder',
        open: _open,
        stopAction: const NotificationActionPayload(
          route: NotificationActionRoute.room,
          connId: 'c1',
          roomId: 'r',
        ),
      );
      expect(args['timeoutMs'], 90000);
      expect(args['publicTitle'], 'Working…');
      expect('${args['publicTitle']}${args['publicText']}',
          isNot(contains('Secret Room')));
      final readOnly = const RichNotificationBuilder(en).liveUpdate(
        tag: 't',
        conversationId: 'c',
        title: 'R',
        members: const [],
        open: _open,
        stopAction: null,
      );
      expect(readOnly.containsKey('stopLabel'), isFalse);
      expect(readOnly.containsKey('actionPayload'), isFalse);
    });

    test('native Stop requires authentication; notification is private', () {
      final kt = File(
        'android/app/src/main/kotlin/com/hermesagent/hermes_android/HermesRichNotifications.kt',
      ).readAsStringSync();
      final live = kt.substring(
        kt.indexOf('fun postLiveUpdate('),
        kt.indexOf('/** Replaces a card in place with a short confirmation'),
      );
      expect(live, contains('if (Build.VERSION.SDK_INT >= 31) stop.setAuthenticationRequired(true)'));
      expect(live, contains('builder.setTimeoutAfter('));
      expect(live, contains('setPublicVersion('));
      expect(live, isNot(contains('VISIBILITY_PUBLIC')));
    });

    group('monitor lifecycle', () {
      late SharedPreferences prefs;
      late Directory dir;
      setUp(() async {
        SharedPreferences.setMockInitialValues({'last_connection_id': 'a'});
        prefs = await SharedPreferences.getInstance();
        dir = await Directory.systemTemp.createTemp('faces');
      });
      tearDown(() => dir.delete(recursive: true));

      Future<(BotModeBackgroundMonitor, _Sink, _RoomsGateway, void Function(Duration))>
      setUpMonitor() async {
        var now = DateTime(2026, 9, 26, 12);
        final sink = _Sink();
        final gateway = _RoomsGateway()..working = true;
        final monitor = BotModeBackgroundMonitor(
          sink: sink,
          faces: BotFaceBitmapCache(directory: () async => dir),
          now: () => now,
          publish: (_) async {},
          gatewayFor: (_) => gateway,
        );
        return (monitor, sink, gateway, (Duration d) => now = now.add(d));
      }

      Future<bool> tick(BotModeBackgroundMonitor m, List<SavedConnection> t) =>
          m.tick(prefs: prefs, targets: t, notificationsEnabled: true);

      test('switching connection withdraws the old Live Update', () async {
        final (monitor, sink, _, advance) = await setUpMonitor();
        final targets = [conn('a'), conn('b')];
        expect(await tick(monitor, targets), isTrue);
        advance(const Duration(seconds: 30));
        await tick(monitor, targets);
        final tagA = RichNotificationIds.roomTag('a', roomId);
        expect(sink.liveTags, contains(tagA));
        await prefs.setString('last_connection_id', 'b');
        await tick(monitor, targets);
        expect(sink.cancelled, contains(tagA));
      });

      test('listener stop and gateway loss withdraw it too', () async {
        final (monitor, sink, gateway, advance) = await setUpMonitor();
        final targets = [conn('a')];
        final tagA = RichNotificationIds.roomTag('a', roomId);
        await tick(monitor, targets);
        advance(const Duration(seconds: 30));
        await tick(monitor, targets);
        expect(sink.liveTags, contains(tagA));
        gateway.fail = true;
        advance(const Duration(seconds: 30));
        await tick(monitor, targets);
        expect(sink.cancelled, isEmpty, reason: 'one failure is tolerated');
        advance(const Duration(minutes: 3));
        await tick(monitor, targets);
        expect(sink.cancelled, contains(tagA));

        gateway.fail = false;
        sink.cancelled.clear();
        advance(const Duration(minutes: 20));
        await tick(monitor, targets);
        advance(const Duration(seconds: 30));
        await tick(monitor, targets);
        await monitor.close();
        expect(sink.cancelled, contains(tagA));
      });

      test('a room that leaves groups.list loses its Live Update', () async {
        final (monitor, sink, gateway, advance) = await setUpMonitor();
        final targets = [conn('a')];
        await tick(monitor, targets);
        advance(const Duration(seconds: 30));
        await tick(monitor, targets);
        gateway.rooms = false;
        advance(const Duration(seconds: 30));
        await tick(monitor, targets);
        expect(sink.cancelled, contains(RichNotificationIds.roomTag('a', roomId)));
      });
    });
  });

  group('Bot Mode rooms through the real listener tick', () {
    late SharedPreferences prefs;
    late Directory dir;
    setUp(() async {
      SharedPreferences.setMockInitialValues({'last_connection_id': 'a'});
      prefs = await SharedPreferences.getInstance();
      dir = await Directory.systemTemp.createTemp('faces');
    });
    tearDown(() => dir.delete(recursive: true));

    test('approval and round-finished are posted once each', () async {
      var now = DateTime(2026, 9, 26, 12);
      final sink = _Sink();
      final gateway = _RoundGateway();
      final monitor = BotModeBackgroundMonitor(
        sink: sink,
        faces: BotFaceBitmapCache(directory: () async => dir),
        now: () => now,
        publish: (_) async {},
        gatewayFor: (_) => gateway,
      );
      Future<void> tick() async {
        await monitor.tick(
          prefs: prefs,
          targets: [conn('a')],
          notificationsEnabled: true,
        );
        now = now.add(const Duration(seconds: 30));
      }

      // Baseline: an idle room with history never alerts.
      final seq = EventSeq();
      gateway.events = [
        seq.user('old'),
        seq.member('m-builder', 'builder', 'old', 'd0'),
      ];
      await tick();
      expect(sink.conversations, isEmpty);

      // A round starts and a member asks for approval.
      gateway.events = [...gateway.events, seq.user('ship it')];
      gateway.working = true;
      gateway.pending = [approvalAction()];
      await tick();
      expect(sink.conversations, hasLength(1), reason: 'approval card');
      await tick();
      expect(sink.conversations, hasLength(1), reason: 'never re-announced');

      // Approved elsewhere; members reply; the round finishes.
      gateway.pending = const [];
      gateway.events = [
        ...gateway.events,
        seq.member('m-lead', 'lead', 'Done, PR is ready', 'd1'),
      ];
      await tick();
      gateway.working = false;
      await tick();
      expect(sink.conversations, hasLength(2), reason: 'round summary');
      await tick();
      expect(sink.conversations, hasLength(2));
      await monitor.close();
    });
  });

  group('P1-6 battery and network', () {
    test('a room send kicks the listener: envelope and fast cadence', () {
      expect(
        BackgroundListener.roomKickFromData(BackgroundListener.roomKickData()),
        isTrue,
      );
      expect(BackgroundListener.roomKickFromData({'kind': 'other'}), isFalse);
      expect(BackgroundListener.roomKickFromData('x'), isFalse);
      final policy = BotModeTickPolicy();
      final now = DateTime(2026, 9, 27, 12);
      // An empty room list backs off for minutes...
      policy.record(
        now: now,
        ok: true,
        rooms: 0,
        working: false,
        pendingApprovals: false,
      );
      expect(policy.shouldConnect(now.add(const Duration(seconds: 5))), isFalse);
      // ...but a send from this device reads rooms at once, at 30 s.
      policy.kick();
      expect(policy.shouldConnect(now.add(const Duration(seconds: 5))), isTrue);
      expect(policy.cadence, BotModeCadence.active);
    });

    test('listener cadence: 180 s base, 60 s cron, 30 s active rooms', () {
      expect(
        listenerIdleIntervalMs(
          roomsActive: false,
          watchesCron: false,
          watchesKanban: false,
        ),
        180000,
      );
      expect(
        listenerIdleIntervalMs(
          roomsActive: false,
          watchesCron: true,
          watchesKanban: false,
        ),
        60000,
      );
      expect(
        listenerIdleIntervalMs(
          roomsActive: true,
          watchesCron: false,
          watchesKanban: false,
        ),
        30000,
      );
    });

    late SharedPreferences prefs;
    late Directory dir;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      dir = await Directory.systemTemp.createTemp('faces');
    });
    tearDown(() => dir.delete(recursive: true));

    test('no rooms: no room RPCs until the backoff elapses', () async {
      var now = DateTime(2026, 9, 26, 12);
      final gateway = _RoomsGateway()..rooms = false;
      final monitor = BotModeBackgroundMonitor(
        sink: _Sink(),
        faces: BotFaceBitmapCache(directory: () async => dir),
        now: () => now,
        publish: (_) async {},
        gatewayFor: (_) => gateway,
      );
      Future<bool> tick() => monitor.tick(
        prefs: prefs,
        targets: [conn('a')],
        notificationsEnabled: true,
      );
      expect(await tick(), isFalse);
      expect(gateway.listCalls, 1);
      for (var i = 0; i < 4; i++) {
        now = now.add(const Duration(minutes: 1));
        await tick();
      }
      expect(gateway.listCalls, 1, reason: 'cached empty list for 5 min');
      now = now.add(const Duration(minutes: 1));
      await tick();
      expect(gateway.listCalls, 2);
      now = now.add(const Duration(minutes: 6));
      await tick();
      expect(gateway.listCalls, 2, reason: 'backoff grew to 10 min');
    });

    test('30 s only while working or waiting for an approval', () async {
      final policy = BotModeTickPolicy();
      final now = DateTime(2026);
      policy.record(now: now, ok: true, rooms: 2, working: false, pendingApprovals: false);
      expect(policy.cadence, BotModeCadence.idle);
      policy.record(now: now, ok: true, rooms: 2, working: false, pendingApprovals: true);
      expect(policy.cadence, BotModeCadence.active);
      policy.record(now: now, ok: false, rooms: 0, working: true, pendingApprovals: true);
      expect(policy.cadence, BotModeCadence.idle);
    });

    test('one lease for the listener lifetime: 10 ticks, 1 client', () async {
      final gateway = _RoomsGateway();
      final clientsSeen = <int>{};
      var created = 0;
      var now = DateTime(2026, 9, 26, 12);
      final pool = SharedGatewayPool.forTesting(
        factory: (c) {
          created++;
          return TuiGatewayClient(c);
        },
      );
      final monitor = BotModeBackgroundMonitor(
        sink: _Sink(),
        faces: BotFaceBitmapCache(directory: () async => dir),
        publish: (_) async {},
        pool: pool,
        now: () => now,
        gatewayFor: (client) {
          clientsSeen.add(identityHashCode(client));
          return gateway;
        },
      );
      for (var i = 0; i < 10; i++) {
        await monitor.tick(
          prefs: prefs,
          targets: [conn('pool-a')],
          notificationsEnabled: true,
        );
        now = now.add(const Duration(seconds: 60));
      }
      expect(created, 1, reason: 'no handshake + ticket per tick');
      expect(clientsSeen, hasLength(1));
      expect(
        pool.leaseCount,
        1,
        reason: 'the listener holds ONE lease between ticks, not per tick',
      );
      await monitor.close();
      expect(pool.leaseCount, 0, reason: 'listener stop releases the lease');
      await pool.closeAll();
    });
  });

  group('P2 room log paging', () {
    test('a long backlog resumes from the cursor, never skips', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final gateway = _PagedGateway();
      final seen = <RoomNotice>[];
      final watcher = RoomWatcher(
        connId: 'c1',
        prefs: prefs,
        presenter: _Presenter(seen),
        claim: (_, _, _) async => true,
        pageLimit: 2,
        maxPagesPerTick: 1,
      );
      await watcher.tick(gateway);
      final seq = EventSeq();
      gateway.events = [
        for (var i = 0; i < 5; i++)
          seq.member('m-builder', 'builder', '@user ping $i', 'd'),
      ];
      await watcher.tick(gateway);
      await watcher.tick(gateway);
      await watcher.tick(gateway);
      expect(gateway.since, [0, 2, 4]);
      expect(seen.whereType<RoomMentionNotice>(), hasLength(5));
    });
  });
}

const _open = NotificationOpen(
  connId: 'c1',
  sessionId: 'room-1',
  surface: NotificationChatSurface.room,
  roomId: 'room-1',
);

NotificationActionPayload roomApprovalPayload({
  List<String> choices = const ['once', 'deny'],
}) => NotificationActionPayload(
  route: NotificationActionRoute.room,
  connId: 'c1',
  roomId: 'room-1',
  requestId: 'apr-1',
  taskId: 'task-1',
  memberId: 'm-lead',
  executionGeneration: 1,
  choices: choices,
);

final class _Ops implements NotificationActionOps {
  final calls = <String>[];
  Object? error;
  Completer<void>? hang;

  Future<void> _record(String call) async {
    if (hang != null) await hang!.future;
    if (error != null) throw error!;
    calls.add(call);
  }

  @override
  Future<void> roomApprove(NotificationActionPayload p, String choice) =>
      _record('roomApprove:$choice');
  @override
  Future<void> roomStop(NotificationActionPayload p) => _record('roomStop');
  @override
  Future<void> roomSend(NotificationActionPayload p, String text, String id) =>
      _record('roomSend:$text:$id');
  @override
  Future<void> runApprove(NotificationActionPayload p, String choice) =>
      _record('runApprove:$choice');
  @override
  Future<void> chatApprove(NotificationActionPayload p, String choice) =>
      _record('chatApprove:$choice');
  @override
  Future<void> botChatReply(NotificationActionPayload p, String text, String id) =>
      _record('botChatReply:$text:$id');
  @override
  Future<void> cronTrigger(NotificationActionPayload p) =>
      _record('cronTrigger:${p.taskId}');
}

final class _Sink implements RichNotificationSink {
  final conversations = <Map<String, Object?>>[];
  final confirms = <String>[];
  final timeouts = <int>[];
  final liveTags = <String>[];
  final cancelled = <String>[];
  @override
  Future<void> cancel({required int id, String? tag}) async {
    if (id == RichNotificationIds.live && tag != null) cancelled.add(tag);
  }

  @override
  Future<void> confirm({
    required int id,
    String? tag,
    String? title,
    required String text,
    int timeoutMs = 4000,
    bool onlyIfActive = false,
  }) async {
    confirms.add(text);
    timeouts.add(timeoutMs);
  }

  @override
  Future<bool> postConversation(Map<String, Object?> args) async {
    conversations.add(args);
    return true;
  }
  @override
  Future<void> postLiveUpdate(Map<String, Object?> args) async =>
      liveTags.add(args['tag']! as String);
}

final class _Inbox implements NotificationActionInbox {
  _Inbox(this._pending);
  List<PendingNotificationAction> _pending;
  final acked = <String>[];

  @override
  Future<List<PendingNotificationAction>> takePendingActions(
    Set<NotificationActionRoute> routes,
  ) async {
    final out = _pending;
    _pending = const [];
    return out;
  }

  @override
  Future<void> ackActions(Iterable<String> uids) async => acked.addAll(uids);

  @override
  void listen(void Function() onActions) {}
}

final class _Rescue implements ReplyRescue {
  final kept = <String>[];
  @override
  Future<void> keep(NotificationActionPayload payload, String text) async =>
      kept.add('${payload.profile ?? payload.roomId}:$text');
}

final class _Presenter implements RoomNoticePresenter {
  _Presenter(this.out);
  final List<RoomNotice> out;
  @override
  Future<void> present(String c, HostedGroupRoom r, List<RoomNotice> n) async =>
      out.addAll(n);
}

GroupsCapabilities _caps() => GroupsCapabilities.tryParse({
  'protocol_version': 1,
  'driver': true,
  'max_log_limit': 500,
  'methods': [for (final m in GroupMethod.values) m.wire],
}, connectionId: 'c1', generation: 1)!;

final class _RoomsGateway implements BotModeGateway {
  bool fail = false;
  bool working = false;
  bool rooms = true;
  int listCalls = 0;

  @override
  Future<GroupsCapabilities> groupCapabilities() async {
    if (fail) throw StateError('offline');
    return _caps();
  }

  @override
  Future<List<HostedGroupRoom>> listGroups({required int generation}) async {
    listCalls++;
    return rooms ? [buildRoom()] : const [];
  }

  @override
  Future<({HostedGroupRoom room, RoomDriverStatus? driverStatus})> groupState(
    String roomId, {
    required int generation,
  }) async => (room: buildRoom(), driverStatus: driver(working: working));

  @override
  Future<List<AgentProfile>> listProfiles() async => const [];
  @override
  Future<DesktopActiveSessionList> listActiveSessions() async =>
      const DesktopActiveSessionList();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Room that works, asks for an approval, then finishes a round.
final class _RoundGateway implements BotModeGateway {
  bool working = false;
  List<Map<String, dynamic>> pending = const [];
  List<Map<String, dynamic>> events = [];

  int get latest => events.isEmpty ? 0 : events.last['seq'] as int;

  @override
  Future<GroupsCapabilities> groupCapabilities() async => _caps();
  @override
  Future<List<HostedGroupRoom>> listGroups({required int generation}) async => [
    buildRoom(latestSeq: latest),
  ];
  @override
  Future<({HostedGroupRoom room, RoomDriverStatus? driverStatus})> groupState(
    String roomId, {
    required int generation,
  }) async => (
    room: buildRoom(latestSeq: latest),
    driverStatus: driver(working: working, pending: pending),
  );
  @override
  Future<HostedGroupLogPage> groupLog(
    String roomId, {
    required int sinceSeq,
    required int limit,
    required int generation,
  }) async {
    final page = events.where((e) => (e['seq'] as int) > sinceSeq).toList();
    return HostedGroupLogPage.fromJson(
      {
        'events': page,
        'cursor': latest,
        'latest_seq': latest,
        'has_more': false,
        'authority': {'gateway_id': gatewayId, 'epoch': 2},
      },
      expectedRoomId: roomId,
      sinceSeq: sinceSeq,
    );
  }

  @override
  Future<List<AgentProfile>> listProfiles() async => const [];
  @override
  Future<DesktopActiveSessionList> listActiveSessions() async =>
      const DesktopActiveSessionList();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _PagedGateway implements BotModeGateway {
  List<Map<String, dynamic>> events = [];
  final since = <int>[];

  int get latest => events.isEmpty ? 0 : events.last['seq'] as int;

  @override
  Future<GroupsCapabilities> groupCapabilities() async => _caps();
  @override
  Future<List<HostedGroupRoom>> listGroups({required int generation}) async =>
      [buildRoom(latestSeq: latest)];
  @override
  Future<({HostedGroupRoom room, RoomDriverStatus? driverStatus})> groupState(
    String roomId, {
    required int generation,
  }) async => (room: buildRoom(latestSeq: latest), driverStatus: driver());

  @override
  Future<HostedGroupLogPage> groupLog(
    String roomId, {
    required int sinceSeq,
    required int limit,
    required int generation,
  }) async {
    since.add(sinceSeq);
    final page = events
        .where((e) => (e['seq'] as int) > sinceSeq)
        .take(limit)
        .toList();
    final cursor = page.isEmpty ? sinceSeq : page.last['seq'] as int;
    return HostedGroupLogPage.fromJson(
      {
        'events': page,
        'cursor': cursor,
        'latest_seq': latest,
        'has_more': cursor < latest,
        'authority': {'gateway_id': gatewayId, 'epoch': 2},
      },
      expectedRoomId: roomId,
      sinceSeq: sinceSeq,
    );
  }

  @override
  Future<List<AgentProfile>> listProfiles() async => const [];
  @override
  Future<DesktopActiveSessionList> listActiveSessions() async =>
      const DesktopActiveSessionList();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
