import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_prompt_index.dart';

Map<String, dynamic> _msg(String role, String content, {Object? rowId}) => {
  'role': role,
  'content': content,
  '_desktopRowId': ?rowId,
};

const String _carrier =
    '[IMPORTANT: Background process proc_0b5fab8a4839 exited '
    '(exit code 1).\nCommand: echo hi\nOutput:\nhi\n]';

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

    test('process-notification carrier rows are not prompts', () {
      final entries = deriveChatPromptEntries([
        _msg(
          'user',
          '[IMPORTANT: Background process proc_0b5fab8a4839 exited '
              '(exit code 1).\nCommand: echo hi\nOutput:\nhi\n]',
        ),
        _msg('user', _carrier),
        _msg('user', 'pregunta real'),
      ]);
      expect(entries.map((e) => e.preview), ['pregunta real']);
      expect(entries.single.messageIndex, 2);
    });

    test('a prompt that only starts like a carrier stays a prompt', () {
      const nearMiss =
          '[IMPORTANT: Background process 7 finished] qué hago ahora?';
      final entries = deriveChatPromptEntries([
        _msg('user', nearMiss),
        _msg('user', '[IMPORTANT: Background process notes] para mí'),
        _msg('user', '[IMPORTANT: Background process design is confusing'),
      ]);
      expect(entries.length, 3);
      expect(stickyPromptIndex([_msg('user', nearMiss)], 0), 0);
    });

    test('rows the screen paints as system chips are skipped', () {
      bool chip(Map<String, dynamic> m) => m['content'] == 'chip';
      final rows = [
        _msg('assistant', 'respuesta'),
        _msg('user', 'chip'),
        _msg('user', 'pregunta real'),
      ];
      expect(
        deriveChatPromptEntries(rows, isSystemRow: chip)
            .map((e) => e.preview),
        ['pregunta real'],
      );
      expect(stickyPromptIndex(rows, 0, isSystemRow: chip), 2);
    });

    test('a carrier row does not open a turn for the sticky prompt', () {
      final rows = [
        _msg('assistant', 'respuesta'),
        _msg('user', _carrier),
        _msg('user', 'pregunta real'),
      ];
      expect(stickyPromptIndex(rows, 0), 2);
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

  group('stickyPromptIndex', () {
    final transcript = [
      _msg('assistant', 'respuesta 2'),
      _msg('assistant', 'tool-free continuation'),
      _msg('user', 'pregunta 2'),
      _msg('assistant', 'respuesta 1'),
      _msg('user', 'pregunta 1'),
    ];

    test('a reply row resolves to the prompt that opened its turn', () {
      expect(stickyPromptIndex(transcript, 0), 2);
      expect(stickyPromptIndex(transcript, 1), 2);
      expect(stickyPromptIndex(transcript, 3), 4);
    });

    test('a prompt row resolves to itself', () {
      expect(stickyPromptIndex(transcript, 2), 2);
    });

    test('a turn without a loaded prompt has none', () {
      expect(stickyPromptIndex([_msg('assistant', 'huérfana')], 0), isNull);
    });

    test('out of range rows have none', () {
      expect(stickyPromptIndex(transcript, -1), isNull);
      expect(stickyPromptIndex(transcript, 5), isNull);
      expect(stickyPromptIndex(const [], 0), isNull);
    });

    test('blank user rows do not open a turn', () {
      final rows = [
        _msg('assistant', 'r'),
        _msg('user', '  '),
        _msg('user', 'p'),
      ];
      expect(stickyPromptIndex(rows, 0), 2);
    });
  });

  group('mergeChatPromptItems', () {
    final newest = _msg('user', 'carga 3', rowId: 30);
    final oldestLoaded = _msg('user', 'carga 2', rowId: 20);
    final loaded = deriveChatPromptEntries([newest, oldestLoaded]);

    test('without remote entries the loaded prompts are the whole list', () {
      final items = mergeChatPromptItems(loaded, const []);
      expect(items.map((i) => i.preview), ['carga 3', 'carga 2']);
      expect(items.every((i) => i.message != null), isTrue);
    });

    test(
      'remote prompts older than the loaded tail follow it, newest first',
      () {
        final items = mergeChatPromptItems(loaded, [
          (rowId: 5, preview: 'cinco'),
          (rowId: 12, preview: 'doce'),
          (rowId: 20, preview: 'carga 2'),
        ]);
        expect(items.map((i) => i.preview), [
          'carga 3',
          'carga 2',
          'doce',
          'cinco',
        ]);
        expect(items.map((i) => i.message == null), [false, false, true, true]);
        expect(items.map((i) => i.rowId), [30, 20, 12, 5]);
      },
    );

    test('a remote row that is already loaded is not listed twice', () {
      final items = mergeChatPromptItems(loaded, [
        (rowId: 30, preview: 'carga 3'),
        (rowId: 20, preview: 'carga 2'),
      ]);
      expect(items, hasLength(2));
    });

    test('identical previews with different row ids are distinct prompts', () {
      final items = mergeChatPromptItems(loaded, [
        (rowId: 12, preview: 'igual'),
        (rowId: 8, preview: 'igual'),
        (rowId: 6, preview: 'carga 2'),
      ]);
      expect(items.map((i) => i.rowId), [30, 20, 12, 8, 6]);
      expect(items.map((i) => i.preview), [
        'carga 3',
        'carga 2',
        'igual',
        'igual',
        'carga 2',
      ]);
    });

    test('remote rows newer than the oldest loaded prompt are ignored', () {
      final items = mergeChatPromptItems(loaded, [
        (rowId: 25, preview: 'intermedio'),
        (rowId: 40, preview: 'futuro'),
      ]);
      expect(items.map((i) => i.preview), ['carga 3', 'carga 2']);
    });

    test('without durable ids on loaded prompts nothing can be deduped', () {
      final bare = deriveChatPromptEntries([_msg('user', 'sin id')]);
      final items = mergeChatPromptItems(bare, [(rowId: 1, preview: 'uno')]);
      expect(items.map((i) => i.preview), ['sin id']);
    });

    test('remote previews are collapsed and bounded like local ones', () {
      final items = mergeChatPromptItems(loaded, [
        (rowId: 1, preview: 'a\n\nb ' + 'c' * 300),
      ]);
      final remote = items.last.preview;
      expect(remote.startsWith('a b '), isTrue);
      expect(remote.length, 120);
    });

    test('an explicit oldest loaded row id anchors remote rows', () {
      final items = mergeChatPromptItems(const [], [
        (rowId: 1, preview: 'uno'),
        (rowId: 50, preview: 'cincuenta'),
      ], oldestLoadedRowId: 40);
      expect(items.map((i) => i.preview), ['uno']);
    });

    test('an empty loaded list has no anchor for remote rows', () {
      final items = mergeChatPromptItems(const [], [
        (rowId: 1, preview: 'uno'),
      ]);
      expect(items, isEmpty);
    });
  });
}
