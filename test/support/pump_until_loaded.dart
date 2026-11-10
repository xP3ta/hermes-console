import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/console_loader.dart';

/// `pumpAndSettle` that also waits for the Console loader to go away.
///
/// The loader animates continuously (it schedules a frame on every tick), so
/// a bare `pumpAndSettle` keeps stepping fake time (100 ms per pump) for as
/// long as a screen is loading. This keeps pumping in the same 100 ms steps
/// until no loader is on screen (bounded), then settles.
Future<void> pumpUntilLoaded(
  WidgetTester tester, {
  Duration step = const Duration(milliseconds: 100),
  int maxSteps = 100,
}) async {
  await tester.pump();
  for (var i = 0; i < maxSteps; i++) {
    if (find.byType(ConsoleLoader).evaluate().isEmpty) break;
    await tester.pump(step);
  }
  await tester.pumpAndSettle();
}
