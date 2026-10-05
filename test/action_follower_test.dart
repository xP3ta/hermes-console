// The one bounded follower of a Dashboard action (`/api/actions/<name>/status`)
// shared by every surface that starts a long server action. Time is a fake
// delay, never the wall clock.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/action_follower.dart';

void main() {
  late List<Duration> delays;
  Future<void> delay(Duration d) async => delays.add(d);

  setUp(() => delays = []);

  Map<String, dynamic> running([List<String> lines = const []]) => {
    'running': true,
    'exit_code': null,
    'lines': lines,
  };

  test(
    'waits one interval before every read and stops at a terminal status',
    () async {
      var reads = 0;
      final follower = ActionFollower(
        read: (name) async {
          reads++;
          return reads < 3
              ? running(['line $reads'])
              : {
                  'running': false,
                  'exit_code': 0,
                  'lines': ['done'],
                };
        },
        delay: delay,
      );
      final outcome = await follower.follow('backup');
      expect(reads, 3);
      expect(delays, List.filled(3, const Duration(milliseconds: 1200)));
      expect(outcome.state, ActionFollowState.finished);
      expect(outcome.succeeded, isTrue);
      expect(outcome.exitCode, 0);
      expect(outcome.lines, ['done']);
    },
  );

  test('a non-zero exit code is a finished, unsuccessful outcome', () async {
    final follower = ActionFollower(
      read: (_) async => {
        'running': false,
        'exit_code': 1,
        'lines': ['nothing was restored'],
      },
      delay: delay,
    );
    final outcome = await follower.follow('import');
    expect(outcome.state, ActionFollowState.finished);
    expect(outcome.succeeded, isFalse);
    expect(outcome.lines, ['nothing was restored']);
  });

  test('every read reports the lines so far', () async {
    var reads = 0;
    final seen = <List<String>>[];
    final follower = ActionFollower(
      read: (_) async {
        reads++;
        return reads == 1
            ? running(['a'])
            : {
                'running': false,
                'exit_code': 0,
                'lines': ['a', 'b'],
              };
      },
      delay: delay,
    );
    await follower.follow('backup', onLines: seen.add);
    expect(seen, [
      ['a'],
      ['a', 'b'],
    ]);
  });

  test('gives up after the read bound and says so', () async {
    var reads = 0;
    final follower = ActionFollower(
      read: (_) async {
        reads++;
        return running();
      },
      maxReads: 240,
      delay: delay,
    );
    final outcome = await follower.follow('backup');
    expect(reads, 240);
    expect(outcome.state, ActionFollowState.timedOut);
    expect(outcome.succeeded, isFalse);
  });

  test('stops without another read once keepGoing turns false', () async {
    var reads = 0;
    var visible = true;
    final follower = ActionFollower(
      read: (_) async {
        reads++;
        visible = false;
        return running();
      },
      delay: delay,
    );
    final outcome = await follower.follow('backup', keepGoing: () => visible);
    expect(reads, 1);
    expect(outcome.state, ActionFollowState.cancelled);
  });

  test('cancelled before the first read sends nothing', () async {
    var reads = 0;
    final follower = ActionFollower(
      read: (_) async {
        reads++;
        return running();
      },
      delay: delay,
    );
    final outcome = await follower.follow('backup', keepGoing: () => false);
    expect(reads, 0);
    expect(outcome.state, ActionFollowState.cancelled);
  });

  test('a read error propagates', () async {
    final follower = ActionFollower(
      read: (_) async => throw StateError('socket drop'),
      delay: delay,
    );
    await expectLater(follower.follow('backup'), throwsStateError);
  });

  test('malformed lines are tolerated', () async {
    final follower = ActionFollower(
      read: (_) async => {'running': false, 'exit_code': 0, 'lines': 'oops'},
      delay: delay,
    );
    final outcome = await follower.follow('backup');
    expect(outcome.lines, isEmpty);
  });
}
