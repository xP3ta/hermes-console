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
          seq.member('m-builder', 'builder', 'Done. @user can you merge?', 'd1'),
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
      expect(round.dedupeKey, 'round:2');
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
      final back = RoomWatchState.fromJson(jsonDecode(jsonEncode(state.toJson())));
      expect(back.cursor, 9);
      expect(back.openMembers, {'m'});
      expect(back.pendingRequestIds, {'r'});
      expect(back.round, 2);
    });
  });

  group('RoomWatcher', () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test('reads the log only past the cursor and dedupes via the claim', () async {
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
      gateway.events = [seq.user('x'), seq.member('m-builder', 'builder', '@user hi', 'd')];
      gateway.latest = 2;
      await other.tick(gateway);
      expect(gateway.logSince, [0]);
      expect(presented.whereType<RoomMentionNotice>(), hasLength(1));
    });

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
      await SharedPreferencesRoomPrefs(prefs).setNotificationLevel(
        '$gatewayId:$roomId',
        RoomNotificationLevel.muted,
      );
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
      expect(await watcher.tick(gateway), isFalse, reason: 'skipped by backoff');
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
  Future<void> present(String connId, HostedGroupRoom room, List<RoomNotice> notices) async =>
      out.addAll(notices);
}

final class _FakeGateway implements BotModeGateway {
  bool fail = false;
  int calls = 0;
  int latest = 0;
  List<Map<String, dynamic>> events = [];
  List<Map<String, dynamic>> pending = [];
  final logSince = <int>[];

  @override
  Future<GroupsCapabilities> groupCapabilities() async {
    calls++;
    if (fail) throw StateError('offline');
    return GroupsCapabilities.tryParse({
      'protocol_version': 1,
      'driver': true,
      'max_log_limit': 500,
      'methods': [for (final m in GroupMethod.values) m.wire],
    }, connectionId: 'c1', generation: 1)!;
  }

  @override
  Future<List<HostedGroupRoom>> listGroups({required int generation}) async =>
      [buildRoom(latestSeq: latest)];

  @override
  Future<({HostedGroupRoom room, RoomDriverStatus? driverStatus})> groupState(
    String roomId, {
    required int generation,
  }) async => (room: buildRoom(latestSeq: latest), driverStatus: driver(pending: pending));

  @override
  Future<HostedGroupLogPage> groupLog(
    String roomId, {
    required int sinceSeq,
    required int limit,
    required int generation,
  }) async {
    logSince.add(sinceSeq);
    return buildLog(events.where((e) => (e['seq'] as int) > sinceSeq).toList());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<List<AgentProfile>> listProfiles() async => const [];
  @override
  Future<DesktopActiveSessionList> listActiveSessions() async =>
      const DesktopActiveSessionList();
}
