import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/room_member_status.dart';
import 'package:hermes_android/core/models/room_summary.dart';

import 'room_member_status_test.dart' show statusEvent, statusRoom, statusNow;

void main() {
  RoomSummary derive(
    List<HostedGroupEvent> events, {
    KanbanBoard? board,
    Map<String, BotLiveStatus> statuses = const {},
    DateTime? now,
  }) => deriveRoomSummary(
    events: events,
    members: statusRoom.members,
    statuses: statuses,
    board: board,
    now: now ?? statusNow,
    localGatewayId: 'gateway',
  );

  test('empty room has no invented evidence', () {
    final summary = derive([]);
    expect(summary.topic, isNull);
    expect(summary.now.rows, isEmpty);
    expect(summary.done.rows, isEmpty);
    expect(summary.pending.rows, isEmpty);
    expect(summary.recent.rows, isEmpty);
  });

  test('one user request addresses exactly two pending members', () {
    final summary = derive([
      statusEvent(1, 'message.user', text: '@forja @default investigate'),
    ]);
    expect(summary.topic, '@forja @default investigate');
    expect(
      summary.pending.rows.map((r) => r.member!.handle),
      unorderedEquals(['forja', 'default']),
    );
    expect(
      summary.pending.rows.every((r) => r.kind == RoomSummaryKind.waiting),
      isTrue,
    );
    final timedOut = derive([
      statusEvent(
        1,
        'message.user',
        at: 800,
        text: '@forja @default investigate',
      ),
    ]);
    expect(
      timedOut.pending.rows.every((r) => r.kind == RoomSummaryKind.silent),
      isTrue,
    );
  });

  test('settled answer is deduplicated, pass completed, failure pending', () {
    final summary = derive([
      statusEvent(1, 'message.user', text: 'Ship the fix'),
      statusEvent(2, 'message.member', text: 'Fixed the parser'),
      statusEvent(
        3,
        'turn.settled',
        payload: {'passed': false, 'message_event_id': 'event-2'},
      ),
      statusEvent(
        4,
        'turn.settled',
        member: 'default',
        payload: {'passed': true},
      ),
      statusEvent(
        5,
        'turn.failed',
        member: 'chief-of-staff',
        payload: {'error': '/private/raw failure'},
      ),
    ]);
    expect(summary.done.rows.map((r) => r.kind), [
      RoomSummaryKind.passed,
      RoomSummaryKind.answered,
    ]);
    expect(summary.done.rows.last.detail, 'Fixed the parser');
    expect(summary.pending.rows.single.kind, RoomSummaryKind.failed);
    expect(summary.pending.rows.single.detail, 'Ship the fix');
    expect(summary.recent.rows.first.kind, RoomSummaryKind.failed);
  });

  test('deferred generation is pending until the same task settles', () {
    final events = [
      statusEvent(1, 'message.user', text: '@forja work'),
      statusEvent(
        2,
        'turn.deferred',
        payload: {
          'execution_generation': 1,
          'member_index': 0,
          'round_index': 0,
          'turn_id': 'turn',
          'reason': 'member_unavailable',
          'seen_through_seq': 1,
        },
      ),
    ];
    expect(derive(events).pending.rows.single.kind, RoomSummaryKind.deferred);
    events.add(statusEvent(3, 'turn.settled', payload: {'passed': true}));
    expect(derive(events).pending.rows, isEmpty);
    expect(derive(events).done.rows.single.kind, RoomSummaryKind.passed);
  });

  test(
    'exact user escalation survives replay and clears only in its thread',
    () {
      final events = [
        statusEvent(1, 'message.user', text: '@forja work'),
        statusEvent(2, 'message.member', text: '@user choose the target'),
      ];
      expect(derive(events).needsYouCount, 1);
      events.add(
        statusEvent(3, 'message.user', text: '@default other', thread: 'other'),
      );
      expect(derive(events).needsYouCount, 1);
      events.add(
        statusEvent(4, 'message.user', text: '@forja the first target'),
      );
      expect(derive(events).needsYouCount, 0);
      expect(
        derive([
          statusEvent(1, 'message.member', text: '@username hello'),
        ]).needsYouCount,
        0,
      );
      expect(
        derive(
          [],
          statuses: {'forja': const BotLiveStatus(RoomPresence.needsYou)},
        ).needsYouCount,
        1,
      );
    },
  );

  test(
    'working detail reuses shared status without adding a pending start',
    () {
      final summary = derive([
        statusEvent(1, 'message.user', text: '@forja work'),
        statusEvent(
          2,
          'turn.started',
          payload: {'description': 'Editing parser'},
        ),
      ]);
      expect(summary.now.rows.single.detail, 'Editing parser');
      expect(summary.pending.rows, isEmpty);
    },
  );

  test(
    'board done is recent and scoped; running work is oriented by title',
    () {
      KanbanTask task(
        String id,
        String state, {
        String assignee = 'forja',
        int? completed,
      }) => KanbanTask(
        id: id,
        title: 'Task $id',
        body: '',
        status: state,
        assignee: assignee,
        completedAt: completed,
      );
      final board = KanbanBoard(
        columns: [
          KanbanColumn(
            name: 'mixed',
            tasks: [
              task('done', 'done', completed: 999),
              task('old', 'done', completed: -700000),
              task('undated', 'done'),
              task('future', 'done', completed: 1100),
              task('foreign', 'done', assignee: 'outside', completed: 999),
              task('running', 'running', assignee: 'default'),
              task('queued', 'ready'),
            ],
          ),
        ],
      );
      final summary = derive([], board: board);
      expect(summary.done.rows.single.id, 'board:done');
      expect(summary.now.rows.single.detail, 'Task running');
      expect(summary.statuses['default']!.presence, RoomPresence.working);
      final otherGateway = deriveRoomSummary(
        events: [],
        members: statusRoom.members,
        board: board,
        now: statusNow,
        localGatewayId: 'another-gateway',
      );
      expect(otherGateway.done.rows, isEmpty);
      expect(otherGateway.now.rows, isEmpty);
    },
  );

  test(
    'all durable history contributes, recent feed capped at 50 newest first',
    () {
      final events = [statusEvent(1, 'message.user', text: '@forja first')];
      for (var i = 2; i < 63; i++) {
        events.add(
          statusEvent(
            i,
            'turn.settled',
            payload: {'task_id': 'task-$i', 'passed': true},
          ),
        );
      }
      events.add(
        statusEvent(63, 'message.user', text: '@default next', thread: 'next'),
      );
      final summary = derive(events.reversed.toList());
      expect(summary.done.rows, hasLength(61));
      expect(summary.done.visible, hasLength(6));
      expect(summary.done.remaining, 55);
      expect(summary.done.rows.first.id, 'turn:forja:task-62');
      expect(summary.recent.rows, hasLength(50));
      expect(summary.recent.rows.first.id, 'event-62');
      expect(summary.recent.rows.last.id, 'event-13');
      expect(summary.topic, '@default next');
    },
  );

  test(
    'late results stay with their request; pending older same-thread work is superseded',
    () {
      final summary = derive([
        statusEvent(1, 'message.user', text: '@forja first'),
        statusEvent(2, 'turn.failed'),
        statusEvent(3, 'message.user', text: '@forja second'),
        statusEvent(
          4,
          'message.member',
          text: 'Old answer',
          discussion: 'event-1',
        ),
      ]);
      expect(summary.done.rows.single.detail, 'Old answer');
      expect(summary.pending.rows.single.id, 'waiting:event-3:forja');
    },
  );

  test(
    'room stop and bounded completion never manufacture successful answers',
    () {
      final summary = derive([
        statusEvent(1, 'message.user', text: '@forja work'),
        statusEvent(2, 'room.stop_requested'),
      ]);
      expect(summary.pending.rows.single.kind, RoomSummaryKind.cancelled);
      expect(summary.done.rows, isEmpty);
      final bounded = derive([
        statusEvent(1, 'message.user', text: '@forja work'),
        statusEvent(2, 'room.activity', payload: {'status': 'bounded'}),
      ]);
      expect(bounded.pending.rows.single.kind, RoomSummaryKind.silent);
      expect(bounded.done.rows, isEmpty);
    },
  );

  test('unavailable and cancelled turns have evidence-backed calm reasons', () {
    final summary = derive([
      statusEvent(1, 'message.user', text: '@forja @default work'),
      statusEvent(
        2,
        'member.unavailable',
        payload: {'reason': 'member_unavailable'},
      ),
      statusEvent(
        3,
        'turn.cancelled',
        member: 'default',
        payload: {'reason': 'superseded_by_newer_user_event'},
      ),
    ]);
    expect(summary.pending.rows.map((r) => r.kind), [
      RoomSummaryKind.cancelled,
      RoomSummaryKind.unavailable,
    ]);
    expect(summary.pending.rows.last.reasonCode, 'member_unavailable');
  });

  test('restart recomputation is identical without runtime state', () {
    List<HostedGroupEvent> log() => [
      statusEvent(1, 'message.user', text: '@forja plan'),
      statusEvent(2, 'message.member', text: 'Delivered plan'),
      statusEvent(
        3,
        'turn.settled',
        payload: {'passed': false, 'message_event_id': 'event-2'},
      ),
    ];
    List<Object?> value(RoomSummary s) => [
      s.topic,
      for (final section in [s.now, s.done, s.pending, s.recent])
        [
          for (final r in section.rows)
            [r.id, r.kind, r.member?.memberId, r.detail, r.at, r.sequence],
        ],
    ];
    expect(value(derive(log())), value(derive(log())));
  });
}
