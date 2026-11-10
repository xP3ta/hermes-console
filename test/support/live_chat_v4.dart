import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/chat/turn_activity_pill.dart';

Finder get inlineActivity => find.byKey(const ValueKey('chat-inline-activity'));
Finder get inlineLabel =>
    find.byKey(const ValueKey('chat-inline-activity-text'));
Finder get liveInlineActivity => find.descendant(
  of: find.byWidgetPredicate((w) => w is TurnInlineActivity && w.live),
  matching: inlineActivity,
);
Finder get workedInlineLabel => find.descendant(
  of: find.byWidgetPredicate((w) => w is TurnInlineActivity && !w.live),
  matching: inlineLabel,
);

/// Detail-oriented regressions explicitly open v4's outer disclosure, which
/// starts folded. Invoke the same callback as its accessible action so rows
/// outside the readable viewport can be inspected without moving the reader.
/// Tests of pointer geometry and the folded start use the real touch target.
Future<void> openInlineDetails(WidgetTester tester) async {
  final rows = tester
      .widgetList<TurnInlineActivity>(find.byType(TurnInlineActivity))
      .toList();
  var changed = false;
  for (final row in rows) {
    if (!row.open) {
      row.onTap();
      changed = true;
    }
  }
  if (changed) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}
