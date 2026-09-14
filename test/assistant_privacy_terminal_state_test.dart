import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/assistant_content.dart';

void main() {
  test('typed classic close cannot release a mismatched private tail', () {
    const raw = '<think>PRIVATE</thinking>PRIVATE_TAIL</think>PUBLIC';
    expect(finalizedPublicAssistantText(raw), 'PUBLIC');
    expect(streamingPublicAssistantText(raw), 'PUBLIC');
  });

  test('nested harmony think releases only after the outer close', () {
    const raw =
        '<|think|>PRIVATE<|think|>INNER<|/think|>PRIVATE_TAIL<|/think|>PUBLIC';
    for (var offset = 0; offset <= raw.length; offset++) {
      expect(
        streamingPublicAssistantText(raw.substring(0, offset)),
        isNot(contains('PRIVATE')),
      );
    }
    expect(finalizedPublicAssistantText(raw), 'PUBLIC');
  });

  test('completed literal is exact while streaming candidate is retained', () {
    const raw = 'PUBLIC <｜start｜>not an envelope';
    expect(streamingPublicAssistantText(raw), 'PUBLIC');
    final completed = finalizedPublicAssistantText(raw);
    expect(completed.codeUnits, raw.codeUnits);
    expect(utf8.encode(completed), utf8.encode(raw));
  });

  test('completed private-open envelope never releases its body', () {
    const raw = '<|channel|>analysis<|message|>PRIVATE_TAIL';
    expect(finalizedPublicAssistantText(raw), isNot(contains('PRIVATE_TAIL')));
    expect(streamingPublicAssistantText(raw), isNot(contains('PRIVATE_TAIL')));
  });
}
