import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/chat/tool_steps_summary.dart';
import 'package:hermes_android/core/widgets/chat/turn_step_cards.dart';

import 'support/turn_summary_host.dart';

void main() {
  setUp(StepsBarMemory.reset);
  for (final lang in ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh']) {
    testWidgets('$lang: 320 dp at 2x, live and folded/open, no wide boxes', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Widget host(bool live) => turnSummaryHost(
        Padding(
          padding: const EdgeInsets.all(12),
          child: TurnStepCards(
            entries: [
              for (var i = 0; i < 5; i++)
                summaryEntry(i, running: live && i == 4),
            ],
            live: live,
            duration: live ? null : const Duration(seconds: 134),
          ),
        ),
        scale: 2,
        lang: lang,
      );
      await tester.pumpWidget(host(true));
      expect(tester.takeException(), isNull);
      expect(find.byType(DecoratedBox), findsNothing);
      await tester.pumpWidget(host(false));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('turn-line-label')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (var i = 0; i < 5; i++) {
        final row = tester.getRect(
          find.byKey(ValueKey('turn-step-card-tool-$i')),
        );
        expect(row.left, greaterThanOrEqualTo(0));
        expect(row.right, lessThanOrEqualTo(320));
      }
      expect(tester.binding.transientCallbackCount, 0);
    });
  }
}
