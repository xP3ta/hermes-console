import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/bot_mode_repository.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/notifications/room_watcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bots/room/room_fixtures.dart';

List<HostedGroupEvent> events(List<Map<String, dynamic>> raw) =>
    buildLog(raw).events;

void main() {
  group('decideRoomNotices', () {
    test('first sight surfaces only pending approvals, never history', () {
      final seq = EventSeq();
      final log = [
        seq.user('hi'),
        seq.member('m-builder', 'builder', 'hey @user look', 'd1'),
      ];
      final r = decideRoomNotices(
        previous: null,
        driverStatus: driver(pending: [approvalAction()]),
        newEvents: events(log),
        latestSeq: 2,
        level: RoomNotificationLevel.all,
        nowMs: 1,
      );
      expect(r.notices.single, isA<RoomApprovalNotice>());
      expect(r.next.cursor, 2);
      expect(r.next.pendingRequestIds, {'apr-1'});
    });

    test('leaving "all" mid-round still ends the live update', () {
      for (final level in [
        RoomNotificationLevel.mentions,
        RoomNotificationLevel.muted,
      ]) {
        final r = decideRoomNotices(
          previous: RoomWatchState(working: true, workingSinceMs: 1),
          driverStatus: driver(working: true),
          newEvents: const [],
          latestSeq: 1,
          level: level,
          nowMs: 2,
        );
        final live = r.notices.whereType<RoomLiveNotice>().toList();
        expect(live, hasLength(1), reason: '$level');
        expect(live.single.working, isFalse, reason: '$level');
        // Withdrawn once: the next pass at the same level stays silent.
        final again = decideRoomNotices(
          previous: r.next,
          driverStatus: driver(working: true),
          newEvents: const [],
          latestSeq: 1,
          level: level,
          nowMs: 3,
        );
        expect(again.notices.whereType<RoomLiveNotice>(), isEmpty);
      }
    });

    test('a room never live at another level stays silent', () {
      final r = decideRoomNotices(
        previous: const RoomWatchState(),
        driverStatus: driver(working: true),
        newEvents: const [],
        latestSeq: 1,
        level: RoomNotificationLevel.mentions,
        nowMs: 2,
      );
      expect(r.notices.whereType<RoomLiveNotice>(), isEmpty);
    });

    test('muted rooms only surface approvals', () {
      final seq = EventSeq();
      final r = decideRoomNotices(
        previous: const RoomWatchState(working: true),
        driverStatus: driver(pending: [approvalAction()], blocked: true),
        newEvents: events([
          seq.member('m-builder', 'builder', '@user please check', 'd1'),
          seq.failed('m-review', 'd1'),
        ]),
        latestSeq: 2,
        level: RoomNotificationLevel.muted,
        nowMs: 1,
      );
      expect(r.notices.map((n) => n.runtimeType), [RoomApprovalNotice]);
    });

    test('mentions level: @user, failure and block, no round summary', () {
      final seq = EventSeq();
      final r = decideRoomNotices(
        previous: const RoomWatchState(working: true),
        driverStatus: driver(blocked: true),
        newEvents: events([
          seq.member(
            'm-builder',
            'builder',
            'Done. @user can you merge?',
            'd1',
          ),
          seq.failed('m-review', 'd1'),
        ]),
        latestSeq: 2,
        level: RoomNotificationLevel.mentions,
        nowMs: 1,
      );
      final types = r.notices.map((n) => n.runtimeType).toList();
      expect(types, contains(RoomMentionNotice));
      expect(types, contains(RoomMemberFailedNotice));
      expect(types, contains(RoomBlockedNotice));
      expect(types, isNot(contains(RoomRoundFinishedNotice)));
      expect(types, isNot(contains(RoomLiveNotice)));
    });

    test('all level: working → idle yields a round summary of repliers', () {
      final seq = EventSeq();
      final r = decideRoomNotices(
        previous: const RoomWatchState(working: true, workingSinceMs: 5),
        driverStatus: driver(working: false),
        newEvents: events([
          seq.member('m-builder', 'builder', 'built', 'd1'),
          seq.member('m-review', 'review', 'looks fine', 'd1'),
        ]),
        latestSeq: 2,
        level: RoomNotificationLevel.all,
        nowMs: 10,
      );
      final round = r.notices.whereType<RoomRoundFinishedNotice>().single;
      expect(round.repliedMemberIds, ['m-builder', 'm-review']);
      expect(round.dedupeKey, 'round:d:d1');
      // The Live Update is ended (working: false) in the same pass.
      expect(r.notices.whereType<RoomLiveNotice>().single.working, isFalse);
      expect(r.next.repliers, isEmpty);
    });

    test('live update names the member whose turn started', () {
      final seq = EventSeq();
      final r = decideRoomNotices(
        previous: const RoomWatchState(),
        driverStatus: driver(working: true),
        newEvents: events([
          seq.user('go'),
          seq.started('m-builder', 'd1', round: 1),
        ]),
        latestSeq: 2,
        level: RoomNotificationLevel.all,
        nowMs: 42,
      );
      final live = r.notices.whereType<RoomLiveNotice>().single;
      expect(live.working, isTrue);
      expect(live.workingMemberId, 'm-builder');
      expect(live.round, 2);
      expect(live.startedAtMs, 42);
      expect(r.next.openMembers, {'m-builder'});
    });

    test('live update carries each reply time from the round start', () {
      final seq = EventSeq();
      final first = decideRoomNotices(
        previous: const RoomWatchState(),
        driverStatus: driver(working: true),
        newEvents: events([
          seq.user('@radar then @atlas', atSeconds: 1790000100),
          seq.started('m-radar', 'd1'),
          seq.member('m-radar', 'radar', 'verses', 'd1', atSeconds: 1790000141),
        ]),
        latestSeq: 3,
        level: RoomNotificationLevel.all,
        nowMs: 5,
      );
      expect(first.notices.whereType<RoomLiveNotice>().single.repliedAfterMs, {
        'm-radar': 41000,
      });
      // Survives the persisted state across listener passes.
      final restored = RoomWatchState.fromJson(
        jsonDecode(jsonEncode(first.next.toJson())),
      );
      final second = decideRoomNotices(
        previous: restored,
        driverStatus: driver(working: true),
        newEvents: buildLog([
          seq.started('m-atlas', 'd1'),
          seq.member(
            'm-atlas',
            'atlas',
            'summary',
            'd1',
            atSeconds: 1790000158,
          ),
        ], sinceSeq: 3).events,
        latestSeq: 5,
        level: RoomNotificationLevel.all,
        nowMs: 6,
      );
      expect(second.notices.whereType<RoomLiveNotice>().single.repliedAfterMs, {
        'm-radar': 41000,
        'm-atlas': 58000,
      });
      // A new user message starts a new round clock.
      final third = decideRoomNotices(
        previous: second.next,
        driverStatus: driver(working: true),
        newEvents: buildLog([
          seq.user('again', atSeconds: 1790000300),
        ], sinceSeq: 5).events,
        latestSeq: 6,
        level: RoomNotificationLevel.all,
        nowMs: 7,
      );
      expect(
        third.notices.whereType<RoomLiveNotice>().single.repliedAfterMs,
        isEmpty,
      );
    });

    test('an approval answered elsewhere clears its card', () {
      final r = decideRoomNotices(
        previous: const RoomWatchState(pendingRequestIds: {'apr-1'}),
        driverStatus: driver(),
        newEvents: const [],
        latestSeq: 0,
        level: RoomNotificationLevel.all,
        nowMs: 1,
      );
      expect(
        r.notices.whereType<RoomApprovalClearedNotice>().single.requestId,
        'apr-1',
      );
    });

    test('a known approval is not re-announced', () {
      final r = decideRoomNotices(
        previous: const RoomWatchState(pendingRequestIds: {'apr-1'}),
        driverStatus: driver(pending: [approvalAction()]),
        newEvents: const [],
        latestSeq: 0,
        level: RoomNotificationLevel.all,
        nowMs: 1,
      );
      expect(r.notices, isEmpty);
    });

    test('state survives JSON round trip', () {
      const state = RoomWatchState(
        cursor: 9,
        working: true,
        repliers: ['a'],
        pendingRequestIds: {'r'},
        openMembers: {'m'},
        round: 2,
        workingSinceMs: 3,
      );
      final back = RoomWatchState.fromJson(
        jsonDecode(jsonEncode(state.toJson())),
      );
      expect(back.cursor, 9);
      expect(back.openMembers, {'m'});
      expect(back.pendingRequestIds, {'r'});
      expect(back.round, 2);
    });
  });

  group('round finished from the log (between two ticks)', () {
    // The real log shape: no turn.started, the gateway's verdict closes it.
    List<Map<String, dynamic>> shortRound(EventSeq seq) => [
      seq.user('@console-radar poem, then @atlas summary'),
      seq.member('m-radar', 'radar', 'Verses about **Teide**', 'user:d1'),
      seq.settled('m-radar', 'user:d1'),
      seq.member('m-builder', 'builder', 'One line summary', 'user:d1'),
      seq.settled('m-builder', 'user:d1'),
      seq.activity('user:d1'),
    ];

    test('idle → idle with a whole round: one summary with member lines', () {
      final seq = EventSeq();
      final r = decideRoomNotices(
        previous: const RoomWatchState(),
        driverStatus: driver(working: false),
        newEvents: events(shortRound(seq)),
        latestSeq: 6,
        level: RoomNotificationLevel.all,
        nowMs: 1790000200000,
      );
      final rounds = r.notices.whereType<RoomRoundFinishedNotice>().toList();
      expect(rounds, hasLength(1));
      final round = rounds.single;
      expect(round.repliedMemberIds, ['m-radar', 'm-builder']);
      expect(round.dedupeKey, 'round:d:user:d1');
      expect(round.replies.map((e) => e.memberId), ['m-radar', 'm-builder']);
      expect(round.replies.first.text, 'Verses about **Teide**');
      expect(r.next.repliers, isEmpty, reason: 'repliers reset once announced');
      expect(r.next.live, isFalse);
      final again = decideRoomNotices(
        previous: r.next,
        driverStatus: driver(working: false),
        newEvents: const [],
        latestSeq: 6,
        level: RoomNotificationLevel.all,
        nowMs: 1790000300000,
      );
      expect(again.notices, isEmpty);
    });

    test('mentions and muted levels never get the round summary', () {
      for (final level in [
        RoomNotificationLevel.mentions,
        RoomNotificationLevel.muted,
      ]) {
        final seq = EventSeq();
        final r = decideRoomNotices(
          previous: const RoomWatchState(),
          driverStatus: driver(),
          newEvents: events(shortRound(seq)),
          latestSeq: 6,
          level: level,
          nowMs: 1,
        );
        expect(r.notices, isEmpty, reason: '$level');
        expect(r.next.repliers, isEmpty);
      }
    });

    test('a user message starts the Live Update before the driver works', () {
      final seq = EventSeq();
      final r = decideRoomNotices(
        previous: const RoomWatchState(cursor: 0),
        driverStatus: driver(working: false),
        newEvents: events([seq.user('go')]),
        latestSeq: 1,
        level: RoomNotificationLevel.all,
        nowMs: 1790000200000,
      );
      final live = r.notices.whereType<RoomLiveNotice>().single;
      expect(live.working, isTrue);
      expect(r.next.live, isTrue, reason: 'keeps the fast cadence');
      expect(r.notices.whereType<RoomRoundFinishedNotice>(), isEmpty);
    });

    test('addressed @handles name the Bot before its turn is logged', () {
      final seq = EventSeq();
      final first = decideRoomNotices(
        previous: const RoomWatchState(cursor: 0),
        driverStatus: driver(working: false),
        newEvents: events([
          seq.user('@console-radar escribe 4 versos y luego @atlas resume'),
        ]),
        latestSeq: 1,
        level: RoomNotificationLevel.all,
        nowMs: 1790000200000,
      );
      final live = first.notices.whereType<RoomLiveNotice>().single;
      expect(live.addressedHandles, ['console-radar', 'atlas']);
      expect(addressedHandlesIn('hola @user y @Radar, mail a@b.c'), ['radar']);
      // Survives the tick round-trip and is cleared when the round ends.
      final restored = RoomWatchState.fromJson(
        jsonDecode(jsonEncode(first.next.toJson())),
      );
      expect(restored.addressed, ['console-radar', 'atlas']);
      final end = decideRoomNotices(
        previous: restored,
        driverStatus: driver(working: false),
        newEvents: buildLog([
          seq.member('m-radar', 'radar', 'versos', 'user:d1'),
          seq.settled('m-radar', 'user:d1'),
          seq.activity('user:d1'),
        ], sinceSeq: 1).events,
        latestSeq: 4,
        level: RoomNotificationLevel.all,
        nowMs: 1790000260000,
      );
      expect(end.notices.whereType<RoomRoundFinishedNotice>(), hasLength(1));
      expect(end.next.addressed, isEmpty);
    });

    test('long round observed working: Live Update, then finished', () {
      final seq = EventSeq();
      final first = decideRoomNotices(
        previous: const RoomWatchState(),
        driverStatus: driver(working: true),
        newEvents: events([
          seq.user('go'),
          seq.member('m-radar', 'radar', 'part one', 'user:d1'),
          seq.settled('m-radar', 'user:d1'),
        ]),
        latestSeq: 3,
        level: RoomNotificationLevel.all,
        nowMs: 1790000200000,
      );
      expect(first.notices.whereType<RoomLiveNotice>().single.working, isTrue);
      expect(first.notices.whereType<RoomRoundFinishedNotice>(), isEmpty);
      final second = decideRoomNotices(
        previous: first.next,
        driverStatus: driver(working: false),
        newEvents: buildLog([
          seq.member('m-builder', 'builder', 'part two', 'user:d1'),
          seq.settled('m-builder', 'user:d1'),
          seq.activity('user:d1'),
        ], sinceSeq: 3).events,
        latestSeq: 6,
        level: RoomNotificationLevel.all,
        nowMs: 1790000260000,
      );
      final round = second.notices.whereType<RoomRoundFinishedNotice>().single;
      expect(round.repliedMemberIds, ['m-radar', 'm-builder']);
      expect(round.backfillFromSeq, 0, reason: 'radar replied last tick');
      expect(round.backfillToSeq, 3);
      expect(
        second.notices.whereType<RoomLiveNotice>().single.working,
        isFalse,
      );
      expect(second.next.live, isFalse);
    });

    test('idle between two members does not end the round early', () {
      final seq = EventSeq();
      final first = decideRoomNotices(
        previous: const RoomWatchState(),
        driverStatus: driver(working: false),
        newEvents: events([
          seq.user('go'),
          seq.member('m-radar', 'radar', 'part one', 'user:d1'),
          seq.settled('m-radar', 'user:d1'),
        ]),
        latestSeq: 3,
        level: RoomNotificationLevel.all,
        nowMs: 1790000200000,
      );
      expect(first.notices.whereType<RoomRoundFinishedNotice>(), isEmpty);
      expect(first.next.repliers, ['m-radar']);
    });

    test('stale repliers from the old state are dropped, not announced', () {
      final r = decideRoomNotices(
        previous: const RoomWatchState(cursor: 12, repliers: ['a', 'b']),
        driverStatus: driver(),
        newEvents: const [],
        latestSeq: 12,
        level: RoomNotificationLevel.all,
        nowMs: 1,
      );
      expect(r.notices, isEmpty);
      expect(r.next.repliers, isEmpty);
    });

    test('an older gateway without room.activity: two quiet idle passes', () {
      final seq = EventSeq();
      final first = decideRoomNotices(
        previous: const RoomWatchState(),
        driverStatus: driver(),
        newEvents: events([
          seq.user('go'),
          seq.member('m-radar', 'radar', 'done', 'user:d1'),
          seq.settled('m-radar', 'user:d1'),
        ]),
        latestSeq: 3,
        level: RoomNotificationLevel.all,
        nowMs: 1790000200000,
      );
      expect(first.notices.whereType<RoomRoundFinishedNotice>(), isEmpty);
      final second = decideRoomNotices(
        previous: first.next,
        driverStatus: driver(),
        newEvents: const [],
        latestSeq: 3,
        level: RoomNotificationLevel.all,
        nowMs: 1790000230000,
      );
      final round = second.notices.whereType<RoomRoundFinishedNotice>().single;
      expect(round.dedupeKey, 'round:d:user:d1');
      final late = decideRoomNotices(
        previous: second.next,
        driverStatus: driver(),
        newEvents: buildLog([seq.activity('user:d1')], sinceSeq: 3).events,
        latestSeq: 4,
        level: RoomNotificationLevel.all,
        nowMs: 1790000260000,
      );
      expect(late.notices.whereType<RoomRoundFinishedNotice>(), isEmpty);
    });
  });

  group('RoomWatcher', () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test(
      'reads the log only past the cursor and dedupes via the claim',
      () async {
        final gateway = _FakeGateway();
        final presented = <RoomNotice>[];
        final claimed = <String>{};
        final watcher = RoomWatcher(
          connId: 'c1',
          prefs: prefs,
          presenter: _Presenter(presented),
          claim: (c, r, k) async => claimed.add('$c/$r/$k'),
        );
        gateway.pending = [approvalAction()];
        expect(await watcher.tick(gateway), isTrue);
        expect(gateway.logSince, isEmpty, reason: 'first sight baselines');
        expect(presented.whereType<RoomApprovalNotice>(), hasLength(1));

        // Second process/instance sees the same approval: ledger blocks it.
        final other = RoomWatcher(
          connId: 'c1',
          prefs: prefs,
          presenter: _Presenter(presented),
          claim: (c, r, k) async => claimed.add('$c/$r/$k'),
        );
        await prefs.remove(RoomWatcher.storageKey);
        await other.tick(gateway);
        expect(presented.whereType<RoomApprovalNotice>(), hasLength(1));

        final seq = EventSeq();
        gateway.events = [
          seq.user('x'),
          seq.member('m-builder', 'builder', '@user hi', 'd'),
        ];
        gateway.latest = 2;
        await other.tick(gateway);
        expect(gateway.logSince, [0]);
        expect(presented.whereType<RoomMentionNotice>(), hasLength(1));
      },
    );

    test('short round between ticks: one card with every line, deduped '
        'across restarts', () async {
      final gateway = _FakeGateway();
      final presented = <RoomNotice>[];
      final ledger = <String>{};
      RoomWatcher make() => RoomWatcher(
        connId: 'c1',
        prefs: prefs,
        presenter: _Presenter(presented),
        claim: (c, r, k) async => ledger.add('$c/$r/$k'),
      );
      final watcher = make();
      await watcher.tick(gateway); // baseline
      final seq = EventSeq();
      gateway.events = [
        seq.user('go'),
        seq.member('m-radar', 'radar', 'four verses', 'user:d1'),
        seq.settled('m-radar', 'user:d1'),
        seq.member('m-builder', 'builder', 'one line', 'user:d1'),
        seq.settled('m-builder', 'user:d1'),
        seq.activity('user:d1'),
      ];
      gateway.latest = 6;
      await watcher.tick(gateway);
      final round = presented.whereType<RoomRoundFinishedNotice>().single;
      expect(round.replies.map((r) => r.text), ['four verses', 'one line']);
      final stored =
          jsonDecode(prefs.getString(RoomWatcher.storageKey)!) as Map;
      expect((stored.values.single as Map)['repliers'], isEmpty);

      // Crash before the cursor was persisted: a new process re-reads the
      // same round; the ledger keeps it to one card.
      final raw = Map<String, Object?>.from(stored);
      raw[raw.keys.single] = {...(raw.values.single as Map), 'cursor': 0};
      await prefs.setString(RoomWatcher.storageKey, jsonEncode(raw));
      await make().tick(gateway);
      expect(presented.whereType<RoomRoundFinishedNotice>(), hasLength(1));
    });

    test('a round split across ticks reads earlier replies back', () async {
      final gateway = _FakeGateway()..working = true;
      final presented = <RoomNotice>[];
      final watcher = RoomWatcher(
        connId: 'c1',
        prefs: prefs,
        presenter: _Presenter(presented),
        claim: (_, _, _) async => true,
      );
      await watcher.tick(gateway);
      final seq = EventSeq();
      gateway.events = [
        seq.user('go'),
        seq.member('m-radar', 'radar', 'four verses', 'user:d1'),
        seq.settled('m-radar', 'user:d1'),
      ];
      gateway.latest = 3;
      await watcher.tick(gateway);
      expect(watcher.anyWorking, isTrue);
      expect(presented.whereType<RoomLiveNotice>().last.working, isTrue);
      gateway.events = [
        ...gateway.events,
        seq.member('m-builder', 'builder', 'one line', 'user:d1'),
        seq.settled('m-builder', 'user:d1'),
        seq.activity('user:d1'),
      ];
      gateway.latest = 6;
      gateway.working = false;
      await watcher.tick(gateway);
      final round = presented.whereType<RoomRoundFinishedNotice>().single;
      expect(round.replies.map((r) => r.memberId), ['m-radar', 'm-builder']);
      expect(presented.whereType<RoomLiveNotice>().last.working, isFalse);
      expect(watcher.anyWorking, isFalse);
    });

    test(
      'a round whose user message predates the cursor still lists every reply',
      () async {
        final gateway = _FakeGateway()..working = true;
        final presented = <RoomNotice>[];
        final watcher = RoomWatcher(
          connId: 'c1',
          prefs: prefs,
          presenter: _Presenter(presented),
          claim: (_, _, _) async => true,
        );
        final seq = EventSeq();
        // First sight lands just after the user message: it is history.
        gateway.events = [seq.user('@radar verses then @builder sum up')];
        gateway.latest = 1;
        await watcher.tick(gateway);
        gateway.events = [
          ...gateway.events,
          seq.member('m-radar', 'radar', 'four verses', 'user:d1'),
          seq.settled('m-radar', 'user:d1'),
        ];
        gateway.latest = 3;
        await watcher.tick(gateway);
        gateway.events = [
          ...gateway.events,
          seq.member('m-builder', 'builder', 'one line', 'user:d1'),
          seq.settled('m-builder', 'user:d1'),
          seq.activity('user:d1'),
        ];
        gateway.latest = 6;
        gateway.working = false;
        await watcher.tick(gateway);
        final round = presented.whereType<RoomRoundFinishedNotice>().single;
        expect(round.replies.map((r) => r.memberId), ['m-radar', 'm-builder']);
      },
    );

    test('respects the per-room level written by the Room screen', () async {
      final gateway = _FakeGateway();
      final presented = <RoomNotice>[];
      final watcher = RoomWatcher(
        connId: 'c1',
        prefs: prefs,
        presenter: _Presenter(presented),
        claim: (_, _, _) async => true,
      );
      await watcher.tick(gateway);
      await SharedPreferencesRoomPrefs(
        prefs,
      ).setNotificationLevel('$gatewayId:$roomId', RoomNotificationLevel.muted);
      final seq = EventSeq();
      gateway.events = [seq.member('m-builder', 'builder', '@user hi', 'd')];
      gateway.latest = 1;
      await watcher.tick(gateway);
      expect(presented, isEmpty);
    });

    test('failures back off exponentially up to the ceiling', () async {
      var now = DateTime(2026, 9, 26, 12);
      final gateway = _FakeGateway()..fail = true;
      final watcher = RoomWatcher(
        connId: 'c1',
        prefs: prefs,
        presenter: _Presenter([]),
        claim: (_, _, _) async => true,
        now: () => now,
      );
      expect(await watcher.tick(gateway), isFalse);
      expect(watcher.retryAfter, const Duration(minutes: 1));
      expect(
        await watcher.tick(gateway),
        isFalse,
        reason: 'skipped by backoff',
      );
      expect(gateway.calls, 1);
      now = now.add(const Duration(minutes: 1));
      await watcher.tick(gateway);
      expect(watcher.retryAfter, const Duration(minutes: 2));
      for (var i = 0; i < 6; i++) {
        now = now.add(const Duration(hours: 1));
        await watcher.tick(gateway);
      }
      expect(watcher.retryAfter, const Duration(minutes: 15));
      gateway.fail = false;
      now = now.add(const Duration(hours: 1));
      expect(await watcher.tick(gateway), isTrue);
      expect(watcher.retryAfter, isNull);
    });
  });
}

final class _Presenter implements RoomNoticePresenter {
  _Presenter(this.out);
  final List<RoomNotice> out;
  @override
  Future<void> present(
    String connId,
    HostedGroupRoom room,
    List<RoomNotice> notices,
  ) async => out.addAll(notices);
}

final class _FakeGateway implements BotModeGateway {
  bool fail = false;
  int calls = 0;
  int latest = 0;
  List<Map<String, dynamic>> events = [];
  List<Map<String, dynamic>> pending = [];
  bool working = false;
  final logSince = <int>[];

  @override
  Future<GroupsCapabilities> groupCapabilities() async {
    calls++;
    if (fail) throw StateError('offline');
    return GroupsCapabilities.tryParse(
      {
        'protocol_version': 1,
        'driver': true,
        'max_log_limit': 500,
        'methods': [for (final m in GroupMethod.values) m.wire],
      },
      connectionId: 'c1',
      generation: 1,
    )!;
  }

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
    driverStatus: driver(pending: pending, working: working),
  );

  @override
  Future<HostedGroupLogPage> groupLog(
    String roomId, {
    required int sinceSeq,
    required int limit,
    required int generation,
  }) async {
    logSince.add(sinceSeq);
    return buildLog(
      events.where((e) => (e['seq'] as int) > sinceSeq).toList(),
      sinceSeq: sinceSeq,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<List<AgentProfile>> listProfiles() async => const [];
  @override
  Future<DesktopActiveSessionList> listActiveSessions() async =>
      const DesktopActiveSessionList();
}
