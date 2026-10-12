import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/page.dart';

Future<void> revealEditorControl(WidgetTester tester, Finder control) async {
  if (control.evaluate().isEmpty) {
    // Use the page's vertical list, never a text field's own scrollable.
    final list = find
        .descendant(
          of: find.byType(HermesPage).last,
          matching: find.byType(ListView),
        )
        .first;
    final scrollable = find
        .descendant(of: list, matching: find.byType(Scrollable))
        .first;
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(
      control,
      160,
      scrollable: scrollable,
      maxScrolls: 100,
    );
  }
  // Keep controls clear of both the floating header and sticky Save button.
  await Scrollable.ensureVisible(tester.element(control), alignment: 0.35);
  await tester.pumpAndSettle();
}

Future<void> openEditorAdvanced(WidgetTester tester) async {
  final row = find.byKey(const ValueKey('instance-advanced'));
  await revealEditorControl(tester, row);
  if (find
      .descendant(of: row, matching: find.byIcon(Icons.expand_less))
      .evaluate()
      .isEmpty) {
    await tester.tap(row);
    await tester.pumpAndSettle();
  }
}
