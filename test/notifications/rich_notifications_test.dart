import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';

const en = NotifL10n(false);
const es = NotifL10n(true);

NotificationActionPayload roomApproval({List<String> choices = const ['once', 'deny']}) =>
    NotificationActionPayload(
      route: NotificationActionRoute.room,
      connId: 'c1',
      roomId: 'room-1',
      requestId: 'apr-1',
      taskId: 'task-1',
      memberId: 'm-lead',
      executionGeneration: 1,
      choices: choices,
    );

const open = NotificationOpen(
  connId: 'c1',
  sessionId: 'room-1',
  surface: NotificationChatSurface.room,
  roomId: 'room-1',
);

void main() {
  group('plain copy', () {
    test('strips Markdown and collapses to one bounded line', () {
      expect(
        plainNotificationText('## Done\n\n**Built** `app` and _tested_ it'),
        'Done Built app and tested it',
      );
      final long = plainNotificationText('word ' * 100, max: 40);
      expect(long.length, lessThanOrEqualTo(40));
      expect(long.endsWith('…'), isTrue);
      expect(firstLinePlain('\n\n# Title\nbody'), 'Title');
    });

    test('approval copy quotes the command in both languages', () {
      expect(
        en.approvalNeedsOk('`gh pr ready 51`', null),
        'Needs your OK to run “gh pr ready 51”',
      );
      expect(
        es.approvalNeedsOk('gh pr ready 51', null),
        'Necesita tu OK para ejecutar “gh pr ready 51”',
      );
      expect(en.roundDone(['builder', 'review']),
          'Round done · builder and review replied');
      expect(es.roundDone(['builder']), 'Ronda terminada · builder respondió');
    });
  });

  group('payload', () {
    test('round trips and rejects unsafe ids', () {
      final encoded = roomApproval().encode();
      final back = NotificationActionPayload.tryParse(encoded)!;
      expect(back.isRoomApproval, isTrue);
      expect(back.choices, ['once', 'deny']);
      expect(
        NotificationActionPayload.tryParse(
          encoded.replaceFirst('room-1', 'room 1/../x'),
        ),
        isNull,
      );
      expect(NotificationActionPayload.tryParse('{"v":1,"route":"chat","conn":"c"}'),
          isNull, reason: 'chat route needs session + request');
      expect(encoded, isNot(contains('token')));
    });
  });

  group('builder', () {
    test('approval: verbs first, at most 3, public version hides command', () {
      final args = const RichNotificationBuilder(en).approval(
        tag: 't',
        conversationId: 'room-x',
        conversationTitle: 'Console Devs',
        isGroup: true,
        botKey: 'm-lead',
        botName: 'lead',
        command: 'rm -rf build',
        action: roomApproval(choices: const ['once', 'session', 'always', 'deny']),
        open: open,
        offered: const ['once', 'session', 'always', 'deny'],
        nowMs: 1,
      );
      final actions = [for (final a in args['actions'] as List) (a as Map)['id']];
      expect(actions, ['approve', 'deny', 'open']);
      expect(args['channel'], 'approvals');
      expect(args['alert'], isTrue);
      expect(args['text'], contains('rm -rf build'));
      expect(args['publicTitle'], 'lead needs you');
      expect('${args['publicTitle']}${args['publicText']}',
          isNot(contains('rm -rf')));
    });

    test('approval honours hide-sensitive in the visible card too', () {
      final args = const RichNotificationBuilder(en).approval(
        tag: 't',
        conversationId: 'bot-x',
        conversationTitle: 'builder',
        isGroup: false,
        botKey: 'bot:builder',
        botName: 'builder',
        command: 'cat secrets',
        action: roomApproval(),
        open: open,
        offered: const ['once', 'deny'],
        nowMs: 1,
        hideSensitive: true,
      );
      expect(args.toString(), isNot(contains('cat secrets')));
    });

    test('only offered choices become buttons', () {
      final args = const RichNotificationBuilder(en).approval(
        tag: 't',
        conversationId: 'c',
        conversationTitle: 'r',
        isGroup: true,
        botKey: 'k',
        botName: 'n',
        action: roomApproval(choices: const ['deny']),
        open: open,
        offered: const ['deny'],
        nowMs: 1,
      );
      final actions = [for (final a in args['actions'] as List) (a as Map)['id']];
      expect(actions, ['deny', 'open']);
    });

    test('conversation: reply uses RemoteInput; hidden content drops reply', () {
      const b = RichNotificationBuilder(en);
      final msg = const RichMessage(
        senderKey: 'm1',
        senderName: 'builder',
        text: 'hey @user',
        timeMs: 1,
      );
      final args = b.conversation(
        tag: 't',
        conversationId: 'c',
        conversationTitle: 'Room',
        isGroup: true,
        messages: [msg],
        open: open,
        replyAction: const NotificationActionPayload(
          route: NotificationActionRoute.room,
          connId: 'c1',
          roomId: 'room-1',
        ),
      );
      final reply = (args['actions'] as List).first as Map;
      expect(reply['id'], 'reply');
      expect(reply['remoteInput'], isTrue);
      final hidden = b.conversation(
        tag: 't',
        conversationId: 'c',
        conversationTitle: 'Room',
        isGroup: true,
        messages: [msg],
        open: open,
        replyAction: const NotificationActionPayload(
          route: NotificationActionRoute.room,
          connId: 'c1',
          roomId: 'room-1',
        ),
        hideSensitive: true,
      );
      expect([for (final a in hidden['actions'] as List) (a as Map)['id']], ['open']);
      expect(hidden.toString(), isNot(contains('hey @user')));
    });

    test('live update: segments per member, never empty text, short chip', () {
      final args = const RichNotificationBuilder(en).liveUpdate(
        tag: 't',
        conversationId: 'c',
        title: 'Console Devs',
        members: const [
          (name: 'builder', state: 'done'),
          (name: 'reviewer', state: 'working'),
        ],
        workingName: 'reviewer',
        open: open,
        stopAction: const NotificationActionPayload(
          route: NotificationActionRoute.room,
          connId: 'c1',
          roomId: 'room-1',
        ),
        round: 2,
        startedAtMs: 1000,
      );
      expect(args['segments'], hasLength(2));
      expect(args['text'], 'reviewer is working…');
      expect(args['shortText'], 'reviewe');
      expect(args['subText'], 'Round 2 · 1 of 2 working');
      expect(args['stopLabel'], 'Stop all');
      final idle = const RichNotificationBuilder(en).liveUpdate(
        tag: 't',
        conversationId: 'c',
        title: 'R',
        members: const [],
        open: open,
        stopAction: const NotificationActionPayload(
          route: NotificationActionRoute.room,
          connId: 'c1',
          roomId: 'room-1',
        ),
      );
      expect(idle['text'], 'Thinking…');
    });
  });

  group('NotificationActionRouter', () {
    late _Ops ops;
    late _Sink sink;
    late NotificationActionRouter router;
    setUp(() {
      ops = _Ops();
      sink = _Sink();
      router = NotificationActionRouter(ops: ops, sink: sink, t: en);
    });

    PendingNotificationAction tap(String action, NotificationActionPayload p,
            {String uid = 'u1', String? text}) =>
        PendingNotificationAction(
          uid: uid,
          action: action,
          payload: p,
          notificationId: 7,
          tag: 'tag',
          text: text,
        );

    test('approve performs groups.approve once and confirms in place', () async {
      expect(await router.handle(tap('approve', roomApproval())), ActionOutcome.done);
      expect(ops.calls, ['roomApprove:once']);
      expect(sink.confirms.single, 'Approved');
      // Double tap (two engines, or user) is idempotent.
      expect(await router.handle(tap('approve', roomApproval(), uid: 'u2')),
          ActionOutcome.ignored);
      expect(ops.calls, hasLength(1));
    });

    test('already answered elsewhere counts as success', () async {
      ops.error = Exception('HTTP 409 approval already resolved');
      expect(await router.handle(tap('deny', roomApproval())),
          ActionOutcome.alreadyAnswered);
      expect(sink.confirms.single, 'Already answered');
    });

    test('real failures allow a retry', () async {
      ops.error = Exception('socket closed');
      expect(await router.handle(tap('approve', roomApproval())), ActionOutcome.failed);
      ops.error = null;
      expect(await router.handle(tap('approve', roomApproval(), uid: 'u2')),
          ActionOutcome.done);
    });

    test('a choice the server did not offer is never sent', () async {
      expect(
        await router.handle(tap('always', roomApproval())),
        ActionOutcome.failed,
      );
      expect(ops.calls, isEmpty);
    });

    test('stop and replies route to the room; each reply is distinct', () async {
      const room = NotificationActionPayload(
        route: NotificationActionRoute.room,
        connId: 'c1',
        roomId: 'room-1',
      );
      await router.handle(tap('stop', room));
      await router.handle(tap('reply', room, uid: 'a', text: 'ok'));
      await router.handle(tap('reply', room, uid: 'b', text: 'ok'));
      expect(ops.calls, ['roomStop', 'roomSend:ok:notif-a', 'roomSend:ok:notif-b']);
    });

    test('Bot Chat reply uses prompt.submit with the inbox uid', () async {
      const bot = NotificationActionPayload(
        route: NotificationActionRoute.botChat,
        connId: 'c1',
        profile: 'builder',
        sessionId: 's1',
      );
      await router.handle(tap('reply', bot, uid: 'z', text: 'thanks'));
      expect(ops.calls, ['botChatReply:thanks:notif-z']);
    });

    test('widget taps do not touch notification cards', () async {
      await router.handle(PendingNotificationAction(
        uid: 'w',
        action: 'approve',
        payload: roomApproval(),
        notificationId: 0,
        source: 'widget',
      ));
      expect(ops.calls, ['roomApprove:once']);
      expect(sink.confirms, isEmpty);
    });
  });
}

final class _Ops implements NotificationActionOps {
  final calls = <String>[];
  Object? error;

  Future<void> _record(String call) async {
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
}

final class _Sink implements RichNotificationSink {
  final confirms = <String>[];
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
  }) async => confirms.add(text);
  @override
  Future<bool> postConversation(Map<String, Object?> args) async => true;
  @override
  Future<void> postLiveUpdate(Map<String, Object?> args) async {}
}
