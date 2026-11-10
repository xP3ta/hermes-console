// Wave 8 (audit 1.4.0 §2.2): the pinned prompt lives in a fixed 44 dp band
// under the header (`chat_screen.dart` `_pinnedBandHeight`). The audit
// worked out ~41 dp for the chip at 200 % text: this keeps it measured, so
// a later change to the chip cannot push it out of its band unseen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_pinned_prompt_header.dart';

/// `_pinnedBandHeight` of the chat screen.
const double _band = 44;

void main() {
  for (final scale in const [1.0, 1.5, 2.0]) {
    testWidgets('at ×$scale the chip fits its band without overflow', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.fromId('console-light'),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  height: _band,
                  child: Center(
                    child: ChatPinnedPromptHeader(
                      youLabel: 'You',
                      text: 'How is the build going on the Fold today?',
                      attachmentCount: 1,
                      semanticLabel: 'Your message',
                      hideLabel: 'Hide',
                      onTap: () {},
                      onHide: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      final chip = tester.getSize(find.byType(ChatPinnedPromptHeader));
      expect(chip.height, lessThanOrEqualTo(_band));
    });
  }
}
