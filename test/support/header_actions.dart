import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The "more" button of the floating header (`HermesAppBar`).
final headerMore = find.byKey(const ValueKey('hermes-app-bar-more'));

/// Taps an action of the floating header wherever it lives: [inBar] when the
/// header shows it, else its entry [inMenu] behind the header's "more".
///
/// Pumps fixed steps instead of settling, so it also works on a screen that
/// keeps an animation running.
Future<void> tapHeaderAction(
  WidgetTester tester, {
  required Finder inBar,
  required Finder inMenu,
}) async {
  if (inBar.evaluate().isNotEmpty) {
    await tester.tap(inBar);
    return;
  }
  await tester.tap(headerMore);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(inMenu);
  // The menu leaves, then the action runs.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}
