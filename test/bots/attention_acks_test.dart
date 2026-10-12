import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/state/attention.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/spec070_fixtures.dart';

HostedGroupLogPage _fullLog() => HostedGroupLogPage.append(
  spec070LogPage('groups_log_page1'),
  spec070LogPage('groups_log_page2'),
);

const _idle = RoomDriverStatus(running: false, working: false, blocked: false);

HostedGroupsSnapshot _snapshot({RoomDriverStatus? status}) =>
    HostedGroupsSnapshot(
      capabilities: spec070Capabilities(),
      rooms: [spec070Room()],
      logs: [_fullLog()],
      driverStatuses: {'room-devs': status ?? spec070DriverStatus()},
    );

void main() {
  // Fixture: astra @user mention at seq 3, radar turn.failed (task-radar-1)
  // at seq 6, driver offers approval apr-1 (astra) and a retry of radar.
  group('Needs you only while there is something to do', () {
    test('opening the room acknowledges mentions and failures seen', () {
      final attention = RoomAttention.derive(
        room: spec070Room(),
        driverStatus: _idle,
        log: _fullLog(),
        acks: const RoomAttentionAcks(seenSeq: 8),
      );
      expect(attention.needsUser, isFalse);
    });

    test('a seen failure also settles the retry the driver offers', () {
      final attention = RoomAttention.derive(
        room: spec070Room(),
        driverStatus: spec070DriverStatus(),
        log: _fullLog(),
        acks: const RoomAttentionAcks(seenSeq: 8),
      );
      expect(attention.items.map((i) => i.kind), [AttentionKind.approval]);
    });

    test('anything newer than what was seen still raises it', () {
      final attention = RoomAttention.derive(
        room: spec070Room(),
        driverStatus: _idle,
        log: _fullLog(),
        acks: const RoomAttentionAcks(seenSeq: 4),
      );
      expect(attention.ofKind(AttentionKind.mention), isEmpty);
      expect(
        attention.ofKind(AttentionKind.failedTurn).single.taskId,
        'task-radar-1',
      );
    });

    test('a dismissed failure card stops raising it everywhere', () {
      final attention = RoomAttention.derive(
        room: spec070Room(),
        driverStatus: spec070DriverStatus(),
        log: _fullLog(),
        acks: const RoomAttentionAcks(dismissedTasks: {'task-radar-1'}),
      );
      expect(attention.ofKind(AttentionKind.retry), isEmpty);
      expect(attention.ofKind(AttentionKind.failedTurn), isEmpty);
    });

    test('a pending approval stays until it is answered, seen or not', () {
      final attention = RoomAttention.derive(
        room: spec070Room(),
        driverStatus: spec070DriverStatus(),
        log: _fullLog(),
        acks: const RoomAttentionAcks(
          seenSeq: 99,
          dismissedTasks: {'task-radar-1'},
        ),
      );
      expect(attention.items.map((i) => i.kind), [AttentionKind.approval]);
    });

    test('no acks keeps the previous behaviour', () {
      final attention = RoomAttention.derive(
        room: spec070Room(),
        driverStatus: spec070DriverStatus(),
        log: _fullLog(),
      );
      expect(attention.items.map((i) => i.kind).toSet(), {
        AttentionKind.approval,
        AttentionKind.retry,
        AttentionKind.mention,
      });
    });

    test('bots follow their room: seen room, no amber face', () {
      final snapshot = _snapshot(status: _idle);
      final summary = AttentionSummary.fromSnapshot(
        snapshot,
        acks: (room) => const RoomAttentionAcks(seenSeq: 8),
      );
      expect(summary.forProfile('astra', snapshot), isEmpty);
      expect(summary.forProfile('radar', snapshot), isEmpty);
      expect(summary.room('room-devs')?.count ?? 0, 0);
    });
  });

  group('Room prefs are the one source of acknowledgements', () {
    test('seen and dismissed read back synchronously, and notify', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = SharedPreferencesRoomPrefs(
        await SharedPreferences.getInstance(),
      );
      final room = spec070Room();
      final key = roomPrefsKey(room);
      var changes = 0;
      void bump() => changes++;
      RoomLocalPrefs.changes.addListener(bump);
      addTearDown(() => RoomLocalPrefs.changes.removeListener(bump));

      expect(prefs.acksFor(room).seenSeq, isNull);
      await prefs.setLastSeenSeq(key, 8);
      await prefs.setDismissedTasks(key, {'task-radar-1'});
      final acks = prefs.acksFor(room);
      expect(acks.seenSeq, 8);
      expect(acks.dismissedTasks, {'task-radar-1'});
      expect(changes, 2);
    });
  });
}
