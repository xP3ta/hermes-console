import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/state/attention.dart';
import 'package:hermes_android/core/bots/state/bot_chat_target.dart';
import 'package:hermes_android/core/bots/state/bot_presence.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';

import '../support/spec070_fixtures.dart';

DateTime at(double seconds) =>
    DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());

AgentProfile profileNamed(String name) =>
    spec070Profiles().singleWhere((p) => p.name == name);

HostedGroupLogPage fullLog() {
  final first = spec070LogPage('groups_log_page1');
  return HostedGroupLogPage.append(first, spec070LogPage('groups_log_page2'));
}

HostedGroupsSnapshot roomSnapshot({RoomDriverStatus? status}) =>
    HostedGroupsSnapshot(
      capabilities: spec070Capabilities(),
      rooms: [spec070Room()],
      logs: [fullLog()],
      driverStatuses: {'room-devs': status ?? spec070DriverStatus()},
    );

void main() {
  group('BotPresence', () {
    test('fresh worker_session (<=150s) means working', () {
      final astra = profileNamed('astra');
      expect(
        BotPresence.derive(profile: astra, now: at(1790000580 + 150)),
        BotPresence.working,
      );
      expect(
        BotPresence.derive(profile: astra, now: at(1790000580 + 151)),
        BotPresence.idle,
      );
    });

    test(
      'recent Bot Chat writes alone never mean active (no 90s heuristic)',
      () {
        final hermes = profileNamed('default');
        // canonical_session.last_active is 1790000060: 10s ago.
        expect(
          BotPresence.derive(profile: hermes, now: at(1790000070)),
          BotPresence.idle,
        );
      },
    );

    test('live session status from session.active_list', () {
      final hermes = profileNamed('default');
      final live = spec070ActiveSessions().sessions;
      expect(
        BotPresence.derive(
          profile: hermes,
          now: at(1790000600),
          liveSessions: live,
        ),
        BotPresence.working,
        reason: 'tip session is "working"',
      );
      DesktopActiveSession session(String status) => DesktopActiveSession(
        runtimeSessionId: 'rt',
        storedSessionId: '20260920_100000_tip001',
        current: false,
        status: status,
      );
      expect(
        BotPresence.derive(
          profile: hermes,
          now: at(0),
          liveSessions: [session('waiting')],
        ),
        BotPresence.attention,
      );
      expect(
        BotPresence.derive(
          profile: hermes,
          now: at(0),
          liveSessions: [session('starting')],
        ),
        BotPresence.thinking,
      );
      // A live session of another profile never lends status.
      expect(
        BotPresence.derive(
          profile: profileNamed('radar'),
          now: at(0),
          liveSessions: [session('working')],
        ),
        BotPresence.idle,
      );
    });

    test('room driver: pending approval of this member means attention', () {
      final snapshot = roomSnapshot();
      final astra = profileNamed('astra');
      expect(
        BotPresence.derive(
          profile: astra,
          now: at(0),
          roomSeats: BotRoomSeat.forProfile('astra', snapshot),
        ),
        BotPresence.attention,
      );
    });

    test('room driver working + open turn means working', () {
      final snapshot = roomSnapshot(
        status: const RoomDriverStatus(
          running: true,
          working: true,
          blocked: false,
        ),
      );
      final seats = BotRoomSeat.forProfile('astra', snapshot);
      expect(seats.single.running, isTrue, reason: 'turn-start-astra-2 open');
      expect(
        BotPresence.derive(
          profile: profileNamed('astra'),
          now: at(0),
          roomSeats: seats,
        ),
        BotPresence.working,
      );
      // radar's turn failed: not working.
      expect(BotRoomSeat.forProfile('radar', snapshot).single.running, isFalse);
    });

    test('idle driver never makes a bot working', () {
      final snapshot = roomSnapshot(status: RoomDriverStatus.unknown);
      expect(
        BotPresence.derive(
          profile: profileNamed('radar'),
          now: at(0),
          roomSeats: BotRoomSeat.forProfile('radar', snapshot),
        ),
        BotPresence.idle,
      );
    });
  });

  group('Attention', () {
    test('aggregates approvals, retries and @user mentions', () {
      final attention = RoomAttention.derive(
        room: spec070Room(),
        driverStatus: spec070DriverStatus(),
        log: fullLog(),
      );
      final kinds = attention.items.map((i) => i.kind).toList();
      expect(kinds, contains(AttentionKind.approval));
      expect(kinds, contains(AttentionKind.retry));
      expect(kinds, contains(AttentionKind.mention));
      // radar's failed turn is already offered as a retry: one item only.
      expect(attention.ofKind(AttentionKind.failedTurn), isEmpty);
      expect(
        attention.ofKind(AttentionKind.mention).single.eventId,
        'msg-astra-1',
      );
      expect(
        attention.ofKind(AttentionKind.approval).single.approval?.requestId,
        'apr-1',
      );
    });

    test('failed turn without server retry is its own item', () {
      final attention = RoomAttention.derive(
        room: spec070Room(),
        driverStatus: const RoomDriverStatus(
          running: false,
          working: false,
          blocked: false,
        ),
        log: fullLog(),
      );
      final failed = attention.ofKind(AttentionKind.failedTurn).single;
      expect(failed.taskId, 'task-radar-1');
      expect(failed.memberId, 'member-radar');
    });

    test('a later user message in the thread answers mentions', () {
      final log = fullLog();
      final reply = HostedGroupLogPage.fromJson(
        {
          'events': [
            {
              'room_id': 'room-devs',
              'seq': 9,
              'event_id': 'user:reply',
              'kind': 'message.user',
              'actor': {'kind': 'user', 'id': 'desktop'},
              'authority_epoch': 2,
              'payload': {'text': 'Friday', 'thread_id': 'thread-1'},
              'created_at': 1790000400.0,
              'idempotent': false,
            },
          ],
          'cursor': 9,
          'latest_seq': 9,
          'has_more': false,
          'authority': {'gateway_id': 'gw-home-1', 'epoch': 2},
        },
        expectedRoomId: 'room-devs',
        sinceSeq: 8,
      );
      final attention = RoomAttention.derive(
        room: spec070Room(),
        log: HostedGroupLogPage.append(log, reply),
      );
      expect(attention.needsUser, isFalse);
    });

    test('summary projects items onto bots by authority seat', () {
      final snapshot = roomSnapshot();
      final summary = AttentionSummary.fromSnapshot(snapshot);
      expect(summary.total, 3);
      final astra = summary.forProfile('astra', snapshot);
      expect(
        astra.map((i) => i.kind),
        unorderedEquals([AttentionKind.approval, AttentionKind.mention]),
      );
      expect(summary.forProfile('nobody', snapshot), isEmpty);
    });
  });

  group('BotChatTarget', () {
    test('uses canonical_session tip and preview', () {
      final target = BotChatTarget.resolve(
        profileNamed('default'),
        now: at(1790000600),
      );
      expect(target.source, BotChatTargetSource.canonical);
      expect(target.sessionId, '20260920_100000_tip001');
      expect(target.preview, 'Deployed the fix to staging.');
      expect(target.chatSource, 'bot-mode-canonical');
      expect(target.lastActivityAt, at(1790000060));
    });

    test('ignores the legacy ui_meta chat pin', () {
      final profile = AgentProfile.fromJson({
        'name': 'legacy',
        'ui_meta': {
          'hermes-bots': {'chat': '20260101_000000_pin001'},
        },
      });
      final target = BotChatTarget.resolve(profile);
      expect(target.exists, isFalse);
      expect(target.source, BotChatTargetSource.create);
      expect(target.chatSource, 'mobile-bot');
    });

    test('row time and working-on come from a fresh worker_session', () {
      final target = BotChatTarget.resolve(
        profileNamed('astra'),
        now: at(1790000600),
      );
      expect(target.lastActivityAt, at(1790000580));
      expect(target.workingOn, 'Refactor gateway pool');
      final stale = BotChatTarget.resolve(
        profileNamed('astra'),
        now: at(1790009999),
      );
      expect(stale.lastActivityAt, at(1790000100));
      expect(stale.workingOn, isNull);
    });

    test('title lookup (session.list) resolves when canonical is absent', () {
      final row = AgentProfileSessionSummary.tryParse(
        (spec070Result('session_list_title')['sessions'] as List).single,
      );
      final target = BotChatTarget.resolve(
        profileNamed('radar'),
        titleLookup: row,
      );
      expect(target.sessionId, '20260910_080000_radar2');
      expect(target.preview, 'Scan done');
    });
  });
}
