import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/state/attention.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';

import 'room_fixtures.dart';

/// Server shapes: `driver_status.pending_actions` lists a `retry` for every
/// task in `indeterminate` or `deferred`; only a deferral is published to the
/// room log (`turn.deferred`, with the member id).
void main() {
  RoomDriverStatus status({
    bool running = true,
    Map<String, int> counts = const {},
    List<String> retries = const [],
  }) => driver(
    running: running,
    blocked: true,
    counts: counts,
    pending: [
      for (final t in retries) {'kind': 'retry', 'task_id': t},
    ],
  );

  group('roomRecoveringRetryTasks', () {
    test('an unpublished retry covered by the indeterminate count', () {
      final seq = EventSeq();
      final log = buildLog([seq.user('@builder look')]);
      expect(
        roomRecoveringRetryTasks(
          status(counts: {'indeterminate': 1}, retries: ['t-int']),
          log.events,
        ),
        {'t-int'},
      );
    });

    test('a published deferral is never recovering', () {
      final seq = EventSeq();
      final u = seq.user('@builder look');
      final log = buildLog([
        u,
        seq.deferred('m-builder', u['event_id'] as String, task: 't-def'),
      ]);
      expect(
        roomRecoveringRetryTasks(
          status(
            counts: {'indeterminate': 1, 'deferred': 1},
            retries: ['t-def'],
          ),
          log.events,
        ),
        isEmpty,
      );
    });

    // Every terminal kind the server publishes for a driver task
    // (`hosted_room_discussion.py::_TERMINAL_FIELDS`) is a verdict: once it
    // is in the log the retry is no longer being re-checked, even while the
    // indeterminate count still covers it.
    for (final kind in terminalKinds.keys) {
      test('a published $kind is never recovering', () {
        final seq = EventSeq();
        final u = seq.user('@builder look');
        final terminal = terminalKinds[kind]!(
          seq,
          'm-builder',
          u['event_id'] as String,
          't-done',
        );
        expect(terminal['kind'], kind);
        final log = buildLog([u, terminal]);
        final driver = status(
          counts: {'indeterminate': 1},
          retries: ['t-done'],
        );
        // Control: without the terminal event the same retry is recovering.
        expect(roomRecoveringRetryTasks(driver, buildLog([u]).events), {
          't-done',
        });
        expect(roomRecoveringRetryTasks(driver, log.events), isEmpty);
        expect(
          [
            for (final i in RoomAttention.derive(
              room: buildRoom(),
              driverStatus: driver,
              log: log,
            ).ofKind(AttentionKind.retry))
              i.taskId,
          ],
          ['t-done'],
        );
      });
    }

    test('no indeterminate count, stopped driver or ambiguity: none', () {
      final events = buildLog([EventSeq().user('hi')]).events;
      expect(roomRecoveringRetryTasks(status(retries: ['t']), events), isEmpty);
      expect(
        roomRecoveringRetryTasks(
          status(running: false, counts: {'indeterminate': 1}, retries: ['t']),
          events,
        ),
        isEmpty,
      );
      expect(
        roomRecoveringRetryTasks(
          status(counts: {'indeterminate': 1}, retries: ['a', 'b']),
          events,
        ),
        isEmpty,
      );
      expect(roomRecoveringRetryTasks(null, events), isEmpty);
    });
  });

  group('room attention', () {
    test('an interrupted reply being re-checked does not need the user', () {
      final seq = EventSeq();
      final attention = RoomAttention.derive(
        room: buildRoom(),
        driverStatus: status(counts: {'indeterminate': 1}, retries: ['t-int']),
        log: buildLog([seq.user('@builder look')]),
      );
      expect(attention.ofKind(AttentionKind.retry), isEmpty);
    });

    test('a published deferral still needs the user', () {
      final seq = EventSeq();
      final u = seq.user('@builder look');
      final attention = RoomAttention.derive(
        room: buildRoom(),
        driverStatus: status(counts: {'deferred': 1}, retries: ['t-def']),
        log: buildLog([
          u,
          seq.deferred('m-builder', u['event_id'] as String, task: 't-def'),
        ]),
      );
      expect(
        [for (final i in attention.ofKind(AttentionKind.retry)) i.taskId],
        ['t-def'],
      );
    });
  });
}
