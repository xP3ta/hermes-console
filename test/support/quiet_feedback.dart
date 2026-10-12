import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/hermes_notice.dart';

/// Asserts that [message] was routine feedback under the quiet-UI policy: it
/// is not drawn as a notice, but screen readers still hear it.
///
/// [contains] matches a fragment of the announcement instead of all of it.
void expectRoutineFeedback(
  WidgetTester tester,
  String message, {
  bool contains = false,
}) {
  expect(
    find.descendant(
      of: find.byType(HermesNoticeCard),
      matching: contains ? find.textContaining(message) : find.text(message),
    ),
    findsNothing,
    reason: 'routine feedback must not be drawn: "$message"',
  );
  final announced = tester.takeAnnouncements().map((a) => a.message).toList();
  expect(
    announced.any((m) => contains ? m.contains(message) : m == message),
    isTrue,
    reason:
        'routine feedback must still be announced: "$message" not in '
        '$announced',
  );
}
