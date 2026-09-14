import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';

void main() {
  test('malformed legacy tool envelope never logs its private payload', () {
    final previous = debugPrint;
    final lines = <String>[];
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    try {
      ChatEventInfo.classify({
        'role': 'assistant',
        'content': '{"command":"PRIVATE_TOOL_ARG","exit_code":not-json}',
      });
    } finally {
      debugPrint = previous;
    }
    expect(lines.join('\n'), isNot(contains('PRIVATE_TOOL_ARG')));
  });
}
