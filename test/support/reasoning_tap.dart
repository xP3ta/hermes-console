import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/hermes_reasoning_pill.dart';
import 'package:hermes_android/core/widgets/reasoning_squares_track.dart';

/// Taps the step of [value] on the reasoning slider inside [scope].
///
/// The names under the track are written only where they fit (a phone shows
/// the ends and the active level), so a test picks a level on the track, the
/// way a thumb does, not by its name.
Future<void> tapReasoningValue(
  WidgetTester tester,
  Finder scope,
  String value,
) async {
  final pill = tester.widget<HermesReasoningPill>(
    find.descendant(
      of: scope,
      matching: find.byType(HermesReasoningPill),
      matchRoot: true,
    ),
  );
  final index = pill.levels.indexWhere((l) => l.value == value);
  expect(index, isNonNegative, reason: 'no level "$value" in the pill');
  final rect = tester.getRect(
    find.descendant(
      of: scope,
      matching: find.byType(ReasoningSquaresTrack),
      matchRoot: true,
    ),
  );
  final usable = rect.width - 2 * kReasoningTrackInset;
  final steps = pill.levels.length;
  await tester.tapAt(
    Offset(
      rect.left +
          kReasoningTrackInset +
          usable * index / (steps <= 1 ? 1 : steps - 1),
      rect.center.dy,
    ),
  );
}
