import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/home/home_now.dart';

final _now = DateTime(2026, 10, 6, 16, 30);

HomeChatItem _chat(
  String key, {
  int minutesAgo = 30,
  bool unread = false,
  bool working = false,
  DateTime? since,
  String? preview,
}) => HomeChatItem(
  key: key,
  title: 'Chat $key',
  preview: preview ?? 'preview $key',
  at: _now.subtract(Duration(minutes: minutesAgo)),
  unread: unread,
  working: working,
  workingSince: since,
  ref: key,
);

HomeApprovalItem _approval(String key, {String? sessionKey, String? roomKey}) =>
    HomeApprovalItem(
      key: key,
      sessionKey: sessionKey,
      roomKey: roomKey,
      where: 'where $key',
      command: 'git push',
      canAllow: true,
      canDeny: true,
      ref: key,
    );

HomeTeamBot _bot(String name, HomeTeamState state) =>
    HomeTeamBot(profileName: name, displayName: name, state: state);

HomeRoomNews _room(String key, int count, {int minutesAgo = 5}) => HomeRoomNews(
  key: key,
  title: 'Room $key',
  count: count,
  at: _now.subtract(Duration(minutes: minutesAgo)),
  ref: key,
);

HomeAutomation _job(
  String name, {
  bool failed = false,
  Duration? nextIn,
  bool enabled = true,
}) => HomeAutomation(
  key: name,
  name: name,
  failed: failed,
  enabled: enabled,
  nextRun: nextIn == null ? null : _now.add(nextIn),
  ref: name,
);

HomeNow _derive({
  List<HomeApprovalItem> approvals = const [],
  List<HomeChatItem> chats = const [],
  List<HomeRoomNews> rooms = const [],
  List<HomeTeamBot> team = const [],
  List<HomeAutomation>? automations,
}) => HomeNow.derive(
  approvals: approvals,
  chats: chats,
  rooms: rooms,
  team: team,
  automations: automations,
  now: _now,
);

void main() {
  group('hero priority', () {
    // Each row: which inputs exist → which hero wins.
    final cases =
        <
          ({
            String name,
            bool approval,
            bool working,
            bool unread,
            bool recent,
            Type hero,
          })
        >[
          (
            name: 'everything',
            approval: true,
            working: true,
            unread: true,
            recent: true,
            hero: HomeHeroNeedsYou,
          ),
          (
            name: 'approval only',
            approval: true,
            working: false,
            unread: false,
            recent: false,
            hero: HomeHeroNeedsYou,
          ),
          (
            name: 'working beats finished',
            approval: false,
            working: true,
            unread: true,
            recent: true,
            hero: HomeHeroWorking,
          ),
          (
            name: 'working alone',
            approval: false,
            working: true,
            unread: false,
            recent: false,
            hero: HomeHeroWorking,
          ),
          (
            name: 'finished beats calm',
            approval: false,
            working: false,
            unread: true,
            recent: true,
            hero: HomeHeroFinished,
          ),
          (
            name: 'calm with a recent chat',
            approval: false,
            working: false,
            unread: false,
            recent: true,
            hero: HomeHeroCalm,
          ),
          (
            name: 'nothing at all',
            approval: false,
            working: false,
            unread: false,
            recent: false,
            hero: HomeHeroCalm,
          ),
        ];
    for (final c in cases) {
      test(c.name, () {
        final now = _derive(
          approvals: [if (c.approval) _approval('a1', sessionKey: 'w')],
          chats: [
            if (c.working) _chat('w', minutesAgo: 1, working: true),
            if (c.unread) _chat('u', minutesAgo: 3, unread: true),
            if (c.recent) _chat('r', minutesAgo: 9),
          ],
        );
        expect(now.hero.runtimeType, c.hero);
      });
    }

    test('the first approval leads; the others wait behind it', () {
      final now = _derive(approvals: [_approval('a1'), _approval('a2')]);
      final hero = now.hero as HomeHeroNeedsYou;
      expect(hero.approval.key, 'a1');
      expect(hero.waiting, 1);
    });

    test('the most recent working chat is the one shown', () {
      final now = _derive(
        chats: [
          _chat('new', minutesAgo: 1, working: true),
          _chat('old', minutesAgo: 20, working: true),
        ],
      );
      expect((now.hero as HomeHeroWorking).chat.key, 'new');
    });

    test('finished picks the newest unread chat that is not working', () {
      final now = _derive(
        chats: [
          _chat('u1', minutesAgo: 2, unread: true),
          _chat('u2', minutesAgo: 8, unread: true),
        ],
      );
      expect((now.hero as HomeHeroFinished).chat.key, 'u1');
    });
  });

  group('calm starters', () {
    test('continue the last chat when it is from the last hours', () {
      final now = _derive(chats: [_chat('r', minutesAgo: 60)]);
      final hero = now.hero as HomeHeroCalm;
      expect(hero.starters.single, isA<HomeStarterContinue>());
      expect((hero.starters.single as HomeStarterContinue).chat.key, 'r');
    });

    test('an old last chat is not offered (never a generic starter)', () {
      final now = _derive(chats: [_chat('r', minutesAgo: 60 * 30)]);
      expect((now.hero as HomeHeroCalm).starters, isEmpty);
    });

    test('a failed automation is offered for review', () {
      final now = _derive(automations: [_job('backup', failed: true)]);
      final starter = (now.hero as HomeHeroCalm).starters.single;
      expect(starter, isA<HomeStarterReview>());
      expect((starter as HomeStarterReview).automation.name, 'backup');
    });

    test('at most three starters', () {
      final now = _derive(
        chats: [_chat('r', minutesAgo: 5)],
        automations: [
          _job('a', failed: true),
          _job('b', failed: true),
          _job('c', failed: true),
        ],
      );
      expect((now.hero as HomeHeroCalm).starters, hasLength(3));
    });
  });

  group('status sentence', () {
    test('calm', () {
      expect(_derive().status.kind, HomeStatusKind.calm);
    });

    test('Hermes working names the chat', () {
      final status = _derive(chats: [_chat('w', working: true)]).status;
      expect(status.kind, HomeStatusKind.working);
      expect(status.chatTitle, 'Chat w');
    });

    test('needs you wins over working', () {
      final status = _derive(
        approvals: [_approval('a')],
        chats: [_chat('w', working: true)],
      ).status;
      expect(status.kind, HomeStatusKind.needsYou);
    });

    test('finished names the chat', () {
      final status = _derive(chats: [_chat('u', unread: true)]).status;
      expect(status.kind, HomeStatusKind.finished);
      expect(status.chatTitle, 'Chat u');
    });

    test('only the team works: the sentence is the team, no extra row', () {
      final now = _derive(
        team: [
          _bot('Forja', HomeTeamState.working),
          _bot('Radar', HomeTeamState.working),
        ],
      );
      expect(now.status.kind, HomeStatusKind.team);
      expect(now.showTeamRow, isFalse);
      expect(now.team.map((b) => b.displayName), ['Forja', 'Radar']);
    });

    test('Hermes and the team work: sentence for Hermes, faces row below', () {
      final now = _derive(
        chats: [_chat('w', working: true)],
        team: [_bot('Forja', HomeTeamState.working)],
      );
      expect(now.status.kind, HomeStatusKind.working);
      expect(now.showTeamRow, isTrue);
    });

    test('waiting bots come before working ones', () {
      final now = _derive(
        team: [
          _bot('Forja', HomeTeamState.working),
          _bot('Radar', HomeTeamState.waiting),
        ],
      );
      expect(now.team.map((b) => b.displayName), ['Radar', 'Forja']);
    });
  });

  group('retomar', () {
    test('at most three rows', () {
      final now = _derive(
        chats: [
          for (var i = 0; i < 6; i++) _chat('c$i', minutesAgo: 60 * 30 + i),
        ],
      );
      expect(now.retomar, hasLength(3));
    });

    test('excludes the chat the hero shows (working)', () {
      final now = _derive(
        chats: [
          _chat('w', minutesAgo: 1, working: true),
          _chat('a', minutesAgo: 60 * 30),
        ],
      );
      expect(now.retomar.map((r) => r.key), ['chat:a']);
    });

    test('excludes the chat the hero shows (finished)', () {
      final now = _derive(
        chats: [
          _chat('u', minutesAgo: 1, unread: true),
          _chat('a', minutesAgo: 60 * 30),
        ],
      );
      expect(now.retomar.map((r) => r.key), ['chat:a']);
    });

    test(
      'excludes the chat of the approval and the room of a room approval',
      () {
        final now = _derive(
          approvals: [_approval('a1', sessionKey: 'x', roomKey: 'r1')],
          chats: [
            _chat('x', minutesAgo: 60 * 30),
            _chat('y', minutesAgo: 60 * 31),
          ],
          rooms: [_room('r1', 2), _room('r2', 3)],
        );
        expect(now.retomar.map((r) => r.key), ['room:r2', 'chat:y']);
      },
    );

    test('excludes the calm starter chat', () {
      final now = _derive(
        chats: [
          _chat('r', minutesAgo: 5),
          _chat('s', minutesAgo: 60 * 30),
        ],
      );
      expect(now.retomar.map((r) => r.key), ['chat:s']);
    });

    test('rooms with news come first and count as rows', () {
      final now = _derive(
        chats: [
          _chat('a', minutesAgo: 60 * 30),
          _chat('b', minutesAgo: 60 * 31),
          _chat('c', minutesAgo: 60 * 32),
        ],
        rooms: [_room('devs', 3), _room('quiet', 0)],
      );
      expect(now.retomar.map((r) => r.key), ['room:devs', 'chat:a', 'chat:b']);
      final room = now.retomar.first as HomeRetomarRoom;
      expect(room.room.count, 3);
    });
  });

  group('próximo', () {
    test('hidden without automations', () {
      expect(_derive().proximo, isNull);
      expect(_derive(automations: const []).proximo, isNull);
    });

    test('the next scheduled run', () {
      final now = _derive(
        automations: [
          _job('later', nextIn: const Duration(hours: 5)),
          _job('soon', nextIn: const Duration(hours: 2)),
          _job('off', nextIn: const Duration(minutes: 5), enabled: false),
        ],
      );
      expect(now.proximo!.automation.name, 'soon');
      expect(now.proximo!.failed, isFalse);
    });

    test('a failed automation shows in red', () {
      final now = _derive(
        automations: [
          _job('soon', nextIn: const Duration(hours: 2)),
          _job('broken', failed: true),
        ],
        chats: [_chat('w', working: true)],
      );
      expect(now.proximo!.automation.name, 'broken');
      expect(now.proximo!.failed, isTrue);
    });

    test('a failure already offered as a calm starter is not repeated', () {
      final now = _derive(
        automations: [
          _job('soon', nextIn: const Duration(hours: 2)),
          _job('broken', failed: true),
        ],
      );
      expect(now.hero, isA<HomeHeroCalm>());
      expect(now.proximo!.automation.name, 'soon');
    });

    test('hidden while the hero needs you', () {
      final now = _derive(
        approvals: [_approval('a')],
        automations: [_job('soon', nextIn: const Duration(hours: 2))],
      );
      expect(now.proximo, isNull);
    });

    test('a past next run is not "next"', () {
      final now = _derive(
        automations: [_job('stale', nextIn: const Duration(hours: -2))],
      );
      expect(now.proximo, isNull);
    });
  });
}
