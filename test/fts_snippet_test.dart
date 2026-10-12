import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/utils/fts_snippet.dart';
import 'package:hermes_android/core/utils/home_recent_sessions.dart';

String _render(List<FtsSnippetSpan> spans) => spans.join();

Session _hit(String snippet) => Session(
  id: 's1',
  title: 'QA',
  model: 'm',
  source: 'cli',
  messageCount: 2,
  isActive: false,
  preview: stripFtsMarkers(snippet),
  startedAt: 1,
  searchSnippet: snippet,
);

void main() {
  group('parseFtsSnippet', () {
    test('a marked term becomes a highlighted run without markers', () {
      expect(parseFtsSnippet('QA >>>9484<<< ping'), const [
        FtsSnippetSpan('QA '),
        FtsSnippetSpan('9484', highlighted: true),
        FtsSnippetSpan(' ping'),
      ]);
    });

    test('several terms, and text with no marker', () {
      expect(
        _render(parseFtsSnippet('>>>alpha<<< then >>>beta<<<')),
        '[alpha] then [beta]',
      );
      expect(parseFtsSnippet('plain text'), const [
        FtsSnippetSpan('plain text'),
      ]);
      expect(parseFtsSnippet(''), isEmpty);
    });

    test('unbalanced markers are dropped, never shown', () {
      expect(_render(parseFtsSnippet('cut >>>tail')), 'cut tail');
      expect(_render(parseFtsSnippet('head<<< rest')), 'head rest');
      expect(_render(parseFtsSnippet('a <<<b>>> c')), 'a b c');
      expect(_render(parseFtsSnippet('>>>x<<< and >>>y')), '[x] and y');
    });

    test('nested pairs highlight as one run', () {
      expect(_render(parseFtsSnippet('>>>a >>>b<<< c<<< d')), '[a b c] d');
    });

    test('markers inside code are handled like any other', () {
      expect(
        _render(parseFtsSnippet('run `>>>grep<<< -n` now')),
        'run `[grep] -n` now',
      );
      // A literal REPL prompt with no closing marker stays plain text.
      expect(_render(parseFtsSnippet('>>> print(1)')), ' print(1)');
    });
  });

  group('sessionSearchHighlights', () {
    test('the highlighted text is exactly the plain preview', () {
      for (final snippet in [
        'QA >>>9484<<< ping',
        '...Report "PR #>>>67834<<< still in draft..."',
        '>>>9484<<< at the start\nof a line',
        '**bold** and `>>>code<<<` here',
        '> quoted >>>term<<<',
      ]) {
        final hit = _hit(snippet);
        final spans = sessionSearchHighlights(hit);
        expect(spans, isNotNull, reason: snippet);
        final text = spans!.map((s) => s.text).join();
        expect(text, sessionListPreview(hit), reason: snippet);
        expect(text, isNot(contains('>>>')));
        expect(text, isNot(contains('<<<')));
        expect(text, isNot(contains('\uE000')));
        expect(spans.where((s) => s.highlighted), isNotEmpty, reason: snippet);
      }
    });

    test('no highlight for rows without a marked snippet', () {
      expect(sessionSearchHighlights(_hit('plain')), isNull);
      expect(sessionSearchHighlights(_hit('cut >>>tail')), isNull);
    });
  });
}
