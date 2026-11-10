import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';

void main() {
  test(
    'rehydrated activity seconds and live milliseconds have the same origin',
    () {
      final start = DateTime.utc(2026, 11, 3, 12, 31);
      expect(
        activityInstant(start.millisecondsSinceEpoch)!.isAtSameMomentAs(start),
        isTrue,
      );
      expect(
        activityInstant(
          start.millisecondsSinceEpoch / 1000,
        )!.isAtSameMomentAs(start),
        isTrue,
      );
      for (final raw in [0, -1, 1, double.nan, double.infinity]) {
        expect(activityInstant(raw), isNull);
      }
    },
  );

  test('impossible cached turn durations are omitted instead of clamped', () {
    for (final seconds in [-1, 86400, 604800, double.nan, double.infinity]) {
      final message = normalizeTranscriptMessageForDisplay({
        'role': 'assistant',
        'content': 'finished',
        '_activity_duration_seconds': seconds,
      });
      expect(message, isNotNull);
      expect(message!.containsKey('_activity_duration_seconds'), isFalse);
    }
    expect(measuredActivityDuration(const Duration(days: 7)), isNull);
    expect(measuredActivityDuration(const Duration(seconds: -1)), isNull);
    expect(
      measuredActivityDuration(const Duration(minutes: 1)),
      const Duration(minutes: 1),
    );
  });
}
