import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/transcript_search.dart';

Map<String, dynamic> _msg(String role, String content, {Object? id}) => {
  'role': role,
  'content': content,
  'id': ?id,
};

void main() {
  group('TranscriptSearchIndex.search', () {
    test('empty or blank query yields no matches', () {
      final index = TranscriptSearchIndex();
      final messages = [_msg('user', 'hola mundo')];
      expect(index.search(messages, ''), isEmpty);
      expect(index.search(messages, '   '), isEmpty);
    });

    test('ignores case and diacritics in both directions', () {
      final index = TranscriptSearchIndex();
      final messages = [
        _msg('assistant', 'Tomé un CAFÉ en la estación'),
        _msg('user', 'cafe y camion'),
      ];

      final byPlain = index.search(messages, 'cafe');
      expect(byPlain.map((m) => m.messageIndex), [0, 1]);
      expect(
        messages[0]['content'].toString().substring(
          byPlain.first.start,
          byPlain.first.end,
        ),
        'CAFÉ',
      );

      final byAccent = index.search(messages, 'Estación');
      expect(byAccent, hasLength(1));
      expect(index.search(messages, 'CAMIÓN'), hasLength(1));
    });

    test('decomposed accents map back to the original span', () {
      final index = TranscriptSearchIndex();
      const decomposed = 'Canci\u006F\u0301n final';
      final hits = index.search([_msg('user', decomposed)], 'cancion');
      expect(hits, hasLength(1));
      expect(
        decomposed.substring(hits.single.start, hits.single.end),
        'Canci\u006F\u0301n',
      );
    });

    test('returns every hit in a message, bottom-to-top order', () {
      final index = TranscriptSearchIndex();
      final messages = [
        _msg('assistant', 'uno gato dos gato tres'),
        _msg('user', 'gato viejo'),
      ];
      final hits = index.search(messages, 'gato');
      expect(hits, const [
        TranscriptMatch(messageIndex: 0, start: 13, end: 17),
        TranscriptMatch(messageIndex: 0, start: 4, end: 8),
        TranscriptMatch(messageIndex: 1, start: 0, end: 4),
      ]);
    });

    test('only user and assistant text participates', () {
      final index = TranscriptSearchIndex();
      final messages = [
        _msg('tool', 'secreto'),
        _msg('system', 'secreto'),
        {'role': 'assistant', 'content': 'secreto', '_pipeline': true},
        _msg('user', 'secreto'),
      ];
      final hits = index.search(messages, 'secreto');
      expect(hits.map((m) => m.messageIndex), [3]);
    });

    test('memoizes normalized text per message id until content changes', () {
      final index = TranscriptSearchIndex();
      final messages = [
        _msg('user', 'alfa beta', id: 1),
        _msg('assistant', 'gamma', id: 2),
      ];
      index.search(messages, 'a');
      expect(index.normalizationCount, 2);
      index.search(messages, 'al');
      index.search(messages, 'alf');
      expect(index.normalizationCount, 2);

      final edited = [_msg('user', 'alfa beta editado', id: 1), messages[1]];
      expect(index.search(edited, 'editado'), hasLength(1));
      expect(index.normalizationCount, 3);
    });
  });
}
