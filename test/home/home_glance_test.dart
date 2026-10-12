import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/home/board/home_board_data.dart';
import 'package:hermes_android/core/home/home_now.dart';

final _now = DateTime(2026, 10, 6, 16, 30);

HomeChatItem _chat(
  String key, {
  bool working = false,
  bool unread = false,
  bool asks = false,
  bool failed = false,
  int paused = 0,
  String? step,
  String? agent,
  String? reply,
  Duration ago = Duration.zero,
}) => HomeChatItem(
  key: key,
  title: 'Chat $key',
  preview: '',
  at: _now.subtract(ago),
  ref: key,
  working: working,
  unread: unread,
  waitingForUser: asks,
  failed: failed,
  queuedPaused: paused,
  step: step,
  profileName: agent?.toLowerCase(),
  agentName: agent,
  lastReply: reply,
  workingSince: working ? _now.subtract(const Duration(seconds: 75)) : null,
);

HomeApprovalItem _approval(
  String key, {
  String? session,
  String? actor,
  String? profile,
}) => HomeApprovalItem(
  key: key,
  where: 'w',
  command: 'git push',
  canAllow: true,
  canDeny: true,
  ref: key,
  sessionKey: session,
  actor: actor,
  profileName: profile,
);

HomeGlance _derive({
  List<HomeChatItem> chats = const [],
  List<HomeBoardBot> bots = const [],
  List<HomeBoardRoom> rooms = const [],
  List<HomeApprovalItem> approvals = const [],
  List<HomeAutomation>? automations,
}) => HomeGlance.derive(
  chats: chats,
  bots: bots,
  rooms: rooms,
  approvals: approvals,
  automations: automations,
);

void main() {
  group('Lo siguiente: priority', () {
    test('needs you, then failures, then finished, then replies; running '
        'is kept apart', () {
      final glance = _derive(
        chats: [
          _chat('run', working: true, step: 'terminal'),
          _chat('done', unread: true, agent: 'Argos', reply: 'Listo.'),
          _chat('ask', asks: true),
          _chat('boom', unread: true, failed: true),
          _chat('queue', paused: 2),
          _chat('quiet'),
        ],
        bots: const [
          HomeBoardBot(
            profileName: 'forja',
            displayName: 'Forja',
            state: HomeBotState.working,
            step: 'terminal',
          ),
          HomeBoardBot(
            profileName: 'radar',
            displayName: 'Radar',
            state: HomeBotState.waiting,
          ),
        ],
        rooms: const [
          HomeBoardRoom(key: 'news', title: 'Ops', unread: 2),
          HomeBoardRoom(
            key: 'devs',
            title: 'Console Devs',
            unread: 4,
            mentions: 3,
          ),
          HomeBoardRoom(key: 'fail', title: 'QA', failed: ['Astra']),
          HomeBoardRoom(key: 'busy', title: 'Busy', responding: ['Radar']),
        ],
        approvals: [_approval('ap1', actor: 'Argos', profile: 'argos')],
        automations: [
          HomeAutomation(key: 'j1', name: 'Backup', ref: 'j1', failed: true),
          HomeAutomation(key: 'j2', name: 'Resumen', ref: 'j2'),
        ],
      );
      expect(glance.next.map((i) => i.key), [
        'approval:ap1',
        'question:ask',
        'waiting:radar',
        'queue:queue',
        'failed-chat:boom',
        'failed-room:fail',
        'failed:j1',
        'finished:done',
        'replies:devs',
        'news:news',
      ]);
      expect(glance.next.map((i) => i.tier).toSet().length, 4);
      expect(glance.running.map((i) => i.key), [
        'chat:run',
        'bot:forja',
        'room:busy',
      ]);
      expect(glance.calm, isFalse);
    });

    test('a finished chat names its agent and carries its time and reply', () {
      final glance = _derive(
        chats: [
          _chat(
            'done',
            unread: true,
            agent: 'Argos',
            reply: 'Listo.',
            ago: const Duration(minutes: 5),
          ),
        ],
      );
      final item = glance.next.single;
      expect(item.kind, HomeGlanceKind.finished);
      expect(item.title, 'Argos');
      expect(item.subject, 'Chat done');
      expect(item.detail, 'Listo.');
      expect(item.since, _now.subtract(const Duration(minutes: 5)));
      expect(item.profileName, 'argos');
    });

    test('a failed turn already seen is not next; a seen chat is not next', () {
      final glance = _derive(
        chats: [_chat('seen-fail', failed: true), _chat('seen')],
      );
      expect(glance.next, isEmpty);
      expect(glance.calm, isTrue);
    });

    test('a chat or bot that asks through an approval is listed once', () {
      final glance = _derive(
        chats: [_chat('d', asks: true)],
        bots: const [
          HomeBoardBot(
            profileName: 'argos',
            displayName: 'Argos',
            state: HomeBotState.waiting,
          ),
        ],
        approvals: [
          _approval('ap1', session: 'd'),
          _approval('ap2', actor: 'Argos'),
        ],
      );
      expect(glance.next.map((i) => i.key), ['approval:ap1', 'approval:ap2']);
    });

    test('a room with a failure is not listed again for its replies, and '
        'a room listed as next is not repeated as running', () {
      final glance = _derive(
        rooms: const [
          HomeBoardRoom(
            key: 'devs',
            title: 'Console Devs',
            unread: 2,
            mentions: 1,
            failed: ['Astra'],
            responding: ['Radar'],
          ),
        ],
      );
      expect(glance.next.map((i) => i.key), ['failed-room:devs']);
      expect(glance.running, isEmpty);
    });

    test('mentions count only replies addressed to the user', () {
      final glance = _derive(
        rooms: const [
          HomeBoardRoom(key: 'devs', title: 'Devs', unread: 5, mentions: 2),
        ],
      );
      expect(glance.next.single.kind, HomeGlanceKind.roomReplies);
      expect(glance.next.single.count, 2);
    });
  });

  group('Lo siguiente: caps', () {
    final busy = _derive(
      chats: [
        for (var i = 0; i < 7; i++) _chat('u$i', unread: true),
        _chat('run', working: true),
      ],
    );

    test('small and wide show three rows, large five; the rest is a count', () {
      expect(busy.rows(HomeGlance.capFor(large: false)).length, 3);
      expect(busy.more(HomeGlance.capFor(large: false)), 4);
      expect(busy.rows(HomeGlance.capFor(large: true)).length, 5);
      expect(busy.more(HomeGlance.capFor(large: true)), 2);
      // Running fills only room that is left.
      expect(
        busy.rows(5).map((i) => i.kind),
        everyElement(HomeGlanceKind.finished),
      );
    });

    test('running fills the room actionable rows leave', () {
      final glance = _derive(
        chats: [
          _chat('u', unread: true),
          _chat('r1', working: true),
          _chat('r2', working: true),
          _chat('r3', working: true),
        ],
      );
      expect(glance.rows(3).map((i) => i.key), [
        'finished:u',
        'chat:r1',
        'chat:r2',
      ]);
      expect(glance.more(3), 0);
    });

    test('when calm, running keeps one row for the calm line', () {
      final glance = _derive(
        chats: [
          _chat('r1', working: true),
          _chat('r2', working: true),
          _chat('r3', working: true),
        ],
      );
      expect(glance.calm, isTrue);
      expect(glance.rows(3).map((i) => i.key), ['chat:r1', 'chat:r2']);
    });
  });

  group('next automation (ported from Inicio v3 «Próximo»)', () {
    final jobs = [
      HomeAutomation(
        key: 'past',
        name: 'Past',
        ref: 'p',
        nextRun: _now.subtract(const Duration(minutes: 1)),
      ),
      HomeAutomation(
        key: 'late',
        name: 'Late',
        ref: 'l',
        nextRun: _now.add(const Duration(hours: 5)),
      ),
      HomeAutomation(
        key: 'soon',
        name: 'Soon',
        ref: 's',
        nextRun: _now.add(const Duration(hours: 2)),
      ),
      HomeAutomation(key: 'paused', name: 'Paused', ref: 'x', enabled: false),
    ];

    test('the enabled job that runs soonest; a past run is not next', () {
      expect(HomeBoardData.nextAutomation(jobs, _now)?.key, 'soon');
    });

    test('no cron data: nothing', () {
      expect(HomeBoardData.nextAutomation(null, _now), isNull);
      expect(HomeBoardData.nextAutomation(const [], _now), isNull);
    });

    test('a chosen job is shown even when paused', () {
      expect(
        HomeBoardData.nextAutomation(jobs, _now, jobKey: 'paused')?.key,
        'paused',
      );
      expect(HomeBoardData.nextAutomation(jobs, _now, jobKey: 'gone'), isNull);
    });
  });
}
