import 'dart:async';

// Transitive via flutter_test; not added to pubspec to keep the lockfile.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/ssh_reconnect.dart';

/// Scripted attempts: each call takes the next outcome (the last repeats)
/// and records the fake time it ran at.
class _Script {
  _Script(this.outcomes);

  final List<SshReconnectOutcome> outcomes;
  final List<Duration> calledAt = [];
  int get calls => calledAt.length;

  SshAutoReconnect build(
    FakeAsync async, {
    Duration maxBackground = SshAutoReconnect.defaultMaxBackground,
  }) {
    final start = DateTime(2026, 10, 26, 12);
    return SshAutoReconnect(
      attempt: () async {
        calledAt.add(async.elapsed);
        return outcomes[calledAt.length - 1 < outcomes.length
            ? calledAt.length - 1
            : outcomes.length - 1];
      },
      maxBackground: maxBackground,
      clock: () => start.add(async.elapsed),
    );
  }
}

const _retry = SshReconnectOutcome.retry;
const _connected = SshReconnectOutcome.connected;
const _stop = SshReconnectOutcome.stop;

void main() {
  test('backs off 1, 2, 4, 8 and 15 s, then goes offline for good', () {
    fakeAsync((async) {
      final script = _Script([_retry]);
      final reconnect = script.build(async);
      reconnect.start();
      expect(reconnect.status.value, SshReconnectStatus.waiting);

      async.elapse(const Duration(minutes: 10));

      expect(script.calledAt, const [
        Duration(seconds: 1),
        Duration(seconds: 3),
        Duration(seconds: 7),
        Duration(seconds: 15),
        Duration(seconds: 30),
      ]);
      expect(reconnect.attempts, 5);
      expect(reconnect.status.value, SshReconnectStatus.offline);
      expect(async.pendingTimers, isEmpty);
      reconnect.dispose();
    });
  });

  test('a success shows Reconnected, then clears after the notice', () {
    fakeAsync((async) {
      final script = _Script([_retry, _connected]);
      final reconnect = script.build(async);
      reconnect.start();

      async.elapse(const Duration(seconds: 3));
      expect(script.calls, 2);
      expect(reconnect.status.value, SshReconnectStatus.reconnected);
      expect(reconnect.isActive, isFalse);

      async.elapse(SshAutoReconnect.defaultNoticeDuration);
      expect(reconnect.status.value, SshReconnectStatus.idle);
      expect(async.pendingTimers, isEmpty);
      reconnect.dispose();
    });
  });

  test('a failure no retry can fix stops at once', () {
    fakeAsync((async) {
      final script = _Script([_stop]);
      final reconnect = script.build(async);
      reconnect.start();

      async.elapse(const Duration(minutes: 5));
      expect(script.calls, 1);
      expect(reconnect.status.value, SshReconnectStatus.offline);
      expect(async.pendingTimers, isEmpty);
      reconnect.dispose();
    });
  });

  test('dispose cancels the pending attempt', () {
    fakeAsync((async) {
      final script = _Script([_retry]);
      final reconnect = script.build(async);
      reconnect.start();
      expect(async.pendingTimers, hasLength(1));

      reconnect.dispose();
      async.elapse(const Duration(minutes: 5));
      expect(script.calls, 0);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('dispose during an attempt ignores its result', () {
    fakeAsync((async) {
      final pending = Completer<SshReconnectOutcome>();
      var calls = 0;
      final reconnect = SshAutoReconnect(
        attempt: () {
          calls++;
          return pending.future;
        },
      );
      reconnect.start();
      async.elapse(const Duration(seconds: 1));
      expect(calls, 1);
      expect(reconnect.status.value, SshReconnectStatus.reconnecting);

      reconnect.dispose();
      pending.complete(_retry);
      async.elapse(const Duration(minutes: 5));
      expect(calls, 1);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('stop() (closed on purpose) cancels without a message', () {
    fakeAsync((async) {
      final script = _Script([_retry]);
      final reconnect = script.build(async);
      reconnect.start();
      async.elapse(const Duration(seconds: 1));
      expect(script.calls, 1);

      reconnect.stop();
      expect(reconnect.status.value, SshReconnectStatus.idle);
      async.elapse(const Duration(minutes: 5));
      expect(script.calls, 1);
      expect(async.pendingTimers, isEmpty);
      reconnect.dispose();
    });
  });

  test('nothing runs in the background; a short absence carries on', () {
    fakeAsync((async) {
      final script = _Script([_retry]);
      final reconnect = script.build(async);
      reconnect.start();
      async.elapse(const Duration(seconds: 1));
      expect(script.calls, 1);

      reconnect.pause();
      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(seconds: 90));
      expect(script.calls, 1);

      reconnect.resume();
      async.elapse(const Duration(minutes: 5));
      // The attempts left from the same run, not a fresh budget.
      expect(script.calls, 5);
      expect(reconnect.status.value, SshReconnectStatus.offline);
      reconnect.dispose();
    });
  });

  test('a long absence in the background gives up', () {
    fakeAsync((async) {
      final script = _Script([_retry]);
      final reconnect = script.build(async);
      reconnect.start();
      reconnect.pause();
      async.elapse(
        SshAutoReconnect.defaultMaxBackground + const Duration(seconds: 1),
      );
      reconnect.resume();

      expect(reconnect.status.value, SshReconnectStatus.offline);
      async.elapse(const Duration(minutes: 5));
      expect(script.calls, 0);
      expect(async.pendingTimers, isEmpty);
      reconnect.dispose();
    });
  });

  test('a drop while in the background waits for the foreground', () {
    fakeAsync((async) {
      final script = _Script([_connected]);
      final reconnect = script.build(async);
      reconnect.pause();
      reconnect.start();
      async.elapse(const Duration(seconds: 30));
      expect(script.calls, 0);
      expect(async.pendingTimers, isEmpty);

      reconnect.resume();
      async.elapse(const Duration(seconds: 1));
      expect(script.calls, 1);
      expect(reconnect.status.value, SshReconnectStatus.reconnected);
      reconnect.dispose();
    });
  });

  test('a flapping connection does not get a fresh budget each time', () {
    fakeAsync((async) {
      final script = _Script([_connected]);
      final reconnect = script.build(async);
      // Drops again 20 s after every reconnect: five reconnects in total.
      for (var i = 0; i < 8; i++) {
        reconnect.start();
        async.elapse(const Duration(seconds: 20));
      }
      expect(script.calls, 5);
      expect(reconnect.status.value, SshReconnectStatus.offline);
      reconnect.dispose();
    });
  });

  test('a connection that stayed up gets a fresh budget', () {
    fakeAsync((async) {
      final script = _Script([_connected]);
      final reconnect = script.build(async);
      for (var i = 0; i < 8; i++) {
        reconnect.start();
        async.elapse(
          SshAutoReconnect.defaultStableAfter + const Duration(seconds: 20),
        );
      }
      expect(script.calls, 8);
      reconnect.dispose();
    });
  });

  // Review P1-3: pause() used to drop the attempt in flight, so a
  // connection made while away ended up shown as offline on return.
  test('an attempt in flight when the app leaves still counts', () {
    fakeAsync((async) {
      final pending = Completer<SshReconnectOutcome>();
      var calls = 0;
      final start = DateTime(2026, 10, 26, 12);
      final reconnect = SshAutoReconnect(
        attempt: () {
          calls++;
          return pending.future;
        },
        clock: () => start.add(async.elapsed),
      );
      final seen = <SshReconnectStatus>[];
      reconnect.status.addListener(() => seen.add(reconnect.status.value));
      reconnect.start();
      async.elapse(const Duration(seconds: 1));
      expect(reconnect.status.value, SshReconnectStatus.reconnecting);

      reconnect.pause();
      pending.complete(_connected);
      async.flushMicrotasks();
      expect(reconnect.status.value, SshReconnectStatus.reconnected);

      async.elapse(const Duration(minutes: 3));
      reconnect.resume();
      expect(reconnect.status.value, SshReconnectStatus.idle);
      expect(seen, isNot(contains(SshReconnectStatus.offline)));
      expect(calls, 1);
      expect(async.pendingTimers, isEmpty);
      reconnect.dispose();
    });
  });

  test('a failed attempt in flight waits for the foreground to retry', () {
    fakeAsync((async) {
      final pending = Completer<SshReconnectOutcome>();
      var calls = 0;
      final start = DateTime(2026, 10, 26, 12);
      final reconnect = SshAutoReconnect(
        attempt: () {
          calls++;
          return calls == 1 ? pending.future : Future.value(_connected);
        },
        clock: () => start.add(async.elapsed),
      );
      reconnect.start();
      async.elapse(const Duration(seconds: 1));
      reconnect.pause();
      pending.complete(_retry);
      async.flushMicrotasks();
      // No timer in the background.
      expect(async.pendingTimers, isEmpty);
      expect(reconnect.status.value, SshReconnectStatus.waiting);
      async.elapse(const Duration(seconds: 30));
      expect(calls, 1);

      reconnect.resume();
      async.elapse(const Duration(seconds: 2));
      expect(calls, 2);
      expect(reconnect.status.value, SshReconnectStatus.reconnected);
      reconnect.dispose();
    });
  });
}
