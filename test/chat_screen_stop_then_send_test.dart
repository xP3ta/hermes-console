import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/recent_interrupt_guard.dart';

void main() {
  test('send within three seconds interrupts before submitting', () async {
    var now = DateTime.utc(2026, 9, 21, 12);
    final guard = RecentInterruptGuard(now: () => now);
    final calls = <String>[];

    guard.markInterrupted();
    now = now.add(const Duration(milliseconds: 200));
    await guard.interruptBeforeSend(() async => calls.add('interrupt'));
    calls.add('submit');

    expect(guard.active, isTrue);
    expect(calls, ['interrupt', 'submit']);
  });

  test('send after the cooldown does not issue another interrupt', () async {
    var now = DateTime.utc(2026, 9, 21, 12);
    final guard = RecentInterruptGuard(now: () => now);
    final calls = <String>[];

    guard.markInterrupted();
    now = now.add(const Duration(seconds: 4));
    await guard.interruptBeforeSend(() async => calls.add('interrupt'));
    calls.add('submit');

    expect(guard.active, isFalse);
    expect(calls, ['submit']);
  });
}
