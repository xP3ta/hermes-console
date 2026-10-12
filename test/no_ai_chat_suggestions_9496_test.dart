import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Behavioral regressions reuse the real-app recording gateway harness in
// chat_screen_test.dart. Run both files with --name '9496|rpl1215|cs1215'.
void main() {
  test('9496 chat has no exclusive assistant suggestion callback', () {
    final source = File('lib/core/screens/chat_screen.dart').readAsStringSync();
    expect(
      source.contains('_useAssistantSuggestion'),
      isFalse,
      reason: '_useAssistantSuggestion',
    );
    expect(
      source.contains('onSuggestionSelected'),
      isFalse,
      reason: 'onSuggestionSelected',
    );
    expect(
      source.contains('HermesSuggestions('),
      isFalse,
      reason: 'HermesSuggestions(',
    );
    expect(
      File('lib/core/widgets/hermes_suggestions.dart').existsSync(),
      isFalse,
      reason: 'Remove the exclusive rail, not merely hide its entry point',
    );
  });
}
