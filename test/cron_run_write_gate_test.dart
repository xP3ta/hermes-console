import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/cron_run_write_gate.dart';
import 'package:hermes_android/core/models/session.dart';

Session _run(Map<String, dynamic> extra) => Session.fromJson({
  'id': 'cron_job1_20261004_101500',
  'source': 'cron',
  'started_at': 1790000000,
  ...extra,
});

void main() {
  final now = DateTime.fromMillisecondsSinceEpoch(1790000600 * 1000);

  test('a run never closed and not owned by the scheduler is view-only', () {
    final run = _run({'ended_at': null, 'scheduler_owned': false});
    expect(run.schedulerOwned, isFalse);
    expect(CronRunWriteGate.isResumable(run, now: now), isFalse);
    expect(CronRunWriteGate.readOnlyFor(run, now: now), isTrue);
  });

  test('a closed run is writable whatever the scheduler says', () {
    final run = _run({'ended_at': 1790000100, 'scheduler_owned': false});
    expect(CronRunWriteGate.readOnlyFor(run, now: now), isFalse);
  });

  test('a run the scheduler owns is writable while open', () {
    final run = _run({'scheduler_owned': true, 'is_active': false});
    expect(CronRunWriteGate.readOnlyFor(run, now: now), isFalse);
  });

  test('scheduler ownership wins over the activity window', () {
    // Inactive-looking but owned (long tool call) stays writable; recently
    // active but no longer owned is a zombie.
    expect(
      CronRunWriteGate.readOnlyFor(
        _run({'scheduler_owned': false, 'is_active': true}),
        now: now,
      ),
      isTrue,
    );
  });

  test('an older backend falls back to its is_active flag', () {
    expect(
      CronRunWriteGate.readOnlyFor(_run({'is_active': true}), now: now),
      isFalse,
    );
    expect(
      CronRunWriteGate.readOnlyFor(_run({'is_active': false}), now: now),
      isTrue,
    );
  });

  test('without any flag the 300 s activity window decides', () {
    final run = _run({'last_active': 1790000600 - 299});
    expect(run.isActivePublished, isFalse);
    expect(CronRunWriteGate.readOnlyFor(run, now: now), isFalse);
    final later = now.add(const Duration(seconds: 2));
    expect(CronRunWriteGate.readOnlyFor(run, now: later), isTrue);
    expect(CronRunWriteGate.readOnlyFor(_run({}), now: now), isTrue);
  });

  test('only cron runs are gated', () {
    expect(CronRunWriteGate.isRunSessionId('cron_a_b_20261004_101500'), isTrue);
    expect(CronRunWriteGate.isRunSessionId('cron_job_20261004'), isFalse);
    expect(CronRunWriteGate.isRunSessionId('20261004_101500_abcdef'), isFalse);
    final chat = Session.fromJson({
      'id': '20261004_101500_abcdef',
      'source': 'api_server',
      'ended_at': null,
    });
    expect(CronRunWriteGate.appliesTo(chat), isFalse);
    expect(CronRunWriteGate.readOnlyFor(chat, now: now), isFalse);
    expect(
      CronRunWriteGate.appliesTo(
        Session.fromJson({'id': 'cron_job1_20261004_101500'}),
      ),
      isTrue,
    );
  });

  test('copyWith keeps the published liveness fields', () {
    final run = _run({'scheduler_owned': true, 'is_active': false});
    final copy = run.copyWith(title: 'renamed');
    expect(copy.schedulerOwned, isTrue);
    expect(copy.isActivePublished, isTrue);
  });
}
