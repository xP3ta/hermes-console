// CHAT-FLUIDO 1: the turn's live timers read like Hermes Desktop's
// (`components/chat/activity-timer.ts`, `formatElapsed`).
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/activity_pill.dart';

void main() {
  test('seconds under a minute, then m:ss', () {
    expect(formatActivityElapsed(Duration.zero), '0s');
    expect(formatActivityElapsed(const Duration(seconds: 7)), '7s');
    expect(formatActivityElapsed(const Duration(seconds: 59)), '59s');
    expect(formatActivityElapsed(const Duration(seconds: 60)), '1:00');
    expect(formatActivityElapsed(const Duration(seconds: 68)), '1:08');
  });

  test('an hour stays in minutes, as in Desktop', () {
    const hourAndMore = Duration(minutes: 75, seconds: 3);
    expect(formatActivityElapsed(hourAndMore), '75:03');
  });

  test('a clock running behind reads 0s', () {
    expect(formatActivityElapsed(const Duration(seconds: -3)), '0s');
  });
}
