import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_prompt_index.dart';

Map<String, dynamic> _msg(String role, String content, {Object? rowId}) => {
  'role': role,
  'content': content,
  '_desktopRowId': ?rowId,
};

void main() {
  group('chatPromptPreview', () {
    test('collapses whitespace and trims', () {
      expect(chatPromptPreview('  hola \n\n  mundo\t!  '), 'hola mundo !');
    });

    test('keeps text up to 120 characters untouched', () {
      final text = 'a' * 120;
      expect(chatPromptPreview(text), text);
    });

    test('longer text is cut to 120 characters ending in an ellipsis', () {
      final preview = chatPromptPreview('b' * 400);
      expect(preview.length, 120);
      expect(preview.endsWith('…'), isTrue);
    });

    test('does not split a surrogate pair', () {
      final preview = chatPromptPreview('😀' * 200);
      expect(preview.runes.length, 120);
      expect(preview.endsWith('…'), isTrue);
    });
  });

  group('deriveChatPromptEntries', () {
    test('lists user rows with text, newest first, keeping the message', () {
      final newest = _msg('user', 'tres');
      final middle = _msg('assistant', 'respuesta');
      final oldest = _msg('user', 'uno');
      final entries = deriveChatPromptEntries([newest, middle, oldest]);
      expect(entries.map((e) => e.preview), ['tres', 'uno']);
      expect(identical(entries.first.message, newest), isTrue);
      expect(entries.map((e) => e.messageIndex), [0, 2]);
    });

    test('skips empty, blank and non-string user content', () {
      final entries = deriveChatPromptEntries([
        _msg('user', '   '),
        {'role': 'user', 'content': null},
        {
          'role': 'user',
          'content': [1, 2],
        },
        _msg('tool', 'x'),
        _msg('user', 'real'),
      ]);
      expect(entries.map((e) => e.preview), ['real']);
    });

    test('empty transcript has no entries', () {
      expect(deriveChatPromptEntries(const []), isEmpty);
    });
  });

  group('activeChatPromptIndex', () {
    test('picks the last prompt at or above the viewport top', () {
      expect(activeChatPromptIndex([300, 7, -250, -900]), 1);
    });

    test('slack of 8 px counts as at the top', () {
      expect(activeChatPromptIndex([8, 9]), 0);
    });

    test('falls back to the first rendered prompt', () {
      expect(activeChatPromptIndex([null, 120, 500]), 1);
    });

    test('ignores prompts that are not laid out', () {
      expect(activeChatPromptIndex([null, null, -40]), 2);
    });

    test('nothing attached means no active prompt', () {
      expect(activeChatPromptIndex([null, null]), isNull);
      expect(activeChatPromptIndex(const []), isNull);
    });
  });

  group('chatPromptRowId', () {
    test('reads the durable row id, never the text', () {
      expect(chatPromptRowId(_msg('user', 'x', rowId: 42)), 42);
      expect(chatPromptRowId({'role': 'user', 'row_id': 7}), 7);
      expect(chatPromptRowId({'role': 'user', 'content': '42'}), isNull);
      expect(chatPromptRowId({'role': 'user', 'id': 'abc'}), isNull);
    });
  });
}
