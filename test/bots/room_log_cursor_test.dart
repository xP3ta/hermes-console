import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/room_log_cursor.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';

import '../support/spec070_fixtures.dart';

void main() {
  group('RoomLogCursor', () {
    test('first pull pages with since_seq until has_more is false', () async {
      final calls = <int>[];
      final cursor = RoomLogCursor(
        roomId: 'room-devs',
        pageLimit: 4,
        load: ({required sinceSeq, required limit}) async {
          calls.add(sinceSeq);
          return spec070LogPage(
            sinceSeq == 0 ? 'groups_log_page1' : 'groups_log_page2',
          );
        },
      );
      final delta = await cursor.pull();
      expect(calls, [0, 4]);
      expect(delta.added.map((e) => e.sequence), [1, 2, 3, 4, 5, 6, 7, 8]);
      expect(delta.reset, isFalse);
      expect(cursor.cursor, 8);
      expect(delta.log.events, hasLength(8));
    });

    test('later pulls only ask for the delta after the cursor', () async {
      final calls = <int>[];
      var phase = 0;
      final cursor = RoomLogCursor(
        roomId: 'room-devs',
        pageLimit: 4,
        load: ({required sinceSeq, required limit}) async {
          calls.add(sinceSeq);
          if (phase == 0) {
            return spec070LogPage(
              sinceSeq == 0 ? 'groups_log_page1' : 'groups_log_page2',
            );
          }
          return spec070LogPage('groups_log_empty');
        },
      );
      await cursor.pull();
      phase = 1;
      calls.clear();
      final delta = await cursor.pull();
      expect(calls, [8]);
      expect(delta.added, isEmpty);
      expect(delta.changed, isFalse);
      expect(delta.log.events, hasLength(8));
    });

    test('concurrent pulls share one flight', () async {
      final gate = Completer<HostedGroupLogPage>();
      var calls = 0;
      final cursor = RoomLogCursor(
        roomId: 'room-devs',
        load: ({required sinceSeq, required limit}) {
          calls++;
          return gate.future;
        },
      );
      final a = cursor.pull();
      final b = cursor.pull();
      gate.complete(spec070LogPage('groups_log_empty'));
      await Future.wait([a, b]);
      expect(calls, 1);
    });

    test('authority rotation resets and re-reads from zero', () async {
      var rotated = false;
      final calls = <int>[];
      final cursor = RoomLogCursor(
        roomId: 'room-devs',
        pageLimit: 4,
        load: ({required sinceSeq, required limit}) async {
          calls.add(sinceSeq);
          final json = spec070Result(
            sinceSeq == 0 ? 'groups_log_page1' : 'groups_log_page2',
          );
          if (rotated) {
            json['authority'] = {'gateway_id': 'gw-home-1', 'epoch': 3};
            for (final e in json['events'] as List) {
              (e as Map)['authority_epoch'] = 3;
            }
          }
          return HostedGroupLogPage.fromJson(
            json,
            expectedRoomId: 'room-devs',
            sinceSeq: sinceSeq,
          );
        },
      );
      await cursor.pull();
      rotated = true;
      calls.clear();
      // Pull from 8 returns page2 shape (seq 5..8) under epoch 3 → invalid
      // continuation; cursor must restart from zero.
      final delta = await cursor.pull();
      expect(delta.reset, isTrue);
      expect(calls.first, 8);
      expect(calls.skip(1), [0, 4]);
      expect(delta.log.authority.epoch, 3);
    });

    test('bounds memory to maxEvents keeping the newest tail', () async {
      final cursor = RoomLogCursor(
        roomId: 'room-devs',
        pageLimit: 4,
        maxEvents: 3,
        load: ({required sinceSeq, required limit}) async => spec070LogPage(
          sinceSeq == 0 ? 'groups_log_page1' : 'groups_log_page2',
        ),
      );
      final delta = await cursor.pull();
      expect(delta.log.events.map((e) => e.sequence), [6, 7, 8]);
      expect(cursor.cursor, 8);
    });
  });

  group('RoomPollBackoff', () {
    test('3s while working, doubling to 15s while idle', () {
      final backoff = RoomPollBackoff();
      expect(backoff.current, const Duration(seconds: 3));
      expect(backoff.next(working: false, changed: false).inSeconds, 6);
      expect(backoff.next(working: false, changed: false).inSeconds, 12);
      expect(backoff.next(working: false, changed: false).inSeconds, 15);
      expect(backoff.next(working: false, changed: false).inSeconds, 15);
      expect(backoff.next(working: true, changed: false).inSeconds, 3);
      backoff.next(working: false, changed: false);
      expect(backoff.next(working: false, changed: true).inSeconds, 3);
    });
  });

  group('RoomLogPoller', () {
    test('only polls while visible and in foreground', () async {
      var ticks = 0;
      final scheduled = <(Duration, void Function())>[];
      final timers = <_ManualTimer>[];
      final poller = RoomLogPoller(
        timer: (delay, callback) {
          scheduled.add((delay, callback));
          final timer = _ManualTimer();
          timers.add(timer);
          return timer;
        },
        tick: () async {
          ticks++;
          return (
            delta: RoomLogDelta(
              added: const [],
              log: spec070LogPage('groups_log_empty'),
              reset: false,
            ),
            working: false,
          );
        },
      );
      Future<void> fireLast() async {
        final (_, callback) = scheduled.last;
        callback();
        await Future<void>.delayed(Duration.zero);
      }

      expect(scheduled, isEmpty, reason: 'not visible yet');
      poller.setVisible(true);
      expect(scheduled.last.$1, Duration.zero);
      await fireLast();
      expect(ticks, 1);
      expect(scheduled.last.$1, const Duration(seconds: 6));
      poller.setForeground(false);
      expect(timers.last.isActive, isFalse);
      expect(poller.isScheduled, isFalse);
      await fireLast();
      expect(ticks, 1, reason: 'a stale timer firing in background is inert');
      poller.setForeground(true);
      await fireLast();
      expect(ticks, 2);
      poller.dispose();
      expect(poller.isScheduled, isFalse);
    });
  });
}

final class _ManualTimer implements Timer {
  bool _active = true;
  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}
