// Markdown polish: the list of sources as data (no widgets), the table and
// the sources of a live reply as they arrive, and the open address a live
// text holds back. What a live prefix shows is checked at every length: the
// state in between never holds raw pipes nor «[n] https://…».
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/chat_inline_refs.dart';
import 'package:hermes_android/core/utils/streaming_normalizer.dart';
import 'package:hermes_android/core/widgets/markdown_table.dart';

const String _efe =
    'https://efe.com/espana/2026-11-01/heridos-urda-toledo-ingresados-accidente';
const String _pais =
    'https://elpais.com/espana/2026-11-01/la-jueza-pide-acelerar-las-labores-'
    'de-busqueda-mas-operarios-y-que-se-trabaje-de-noche.html';
const String _rtve =
    'https://www.rtve.es/noticias/20261101/accidente-tren-directo-ultima-hora-'
    'heridos/17295258.shtml';

SourcesSegment _sources(List<AnswerSegment> segments) =>
    segments.whereType<SourcesSegment>().single;

String _markdownOf(List<AnswerSegment> segments) =>
    segments.whereType<MarkdownSegment>().map((s) => s.text).join('\n');

void main() {
  group('the list of sources, in the three shapes of the capture', () {
    test('one entry per line', () {
      const text =
          'Cuerpo [1].\n\n## Sources\n\n'
          '[1] $_efe — EFE: 31 heridos y 56 fallecidos identificados en Urda\n'
          '[2] $_pais — El País: la jueza pide acelerar la búsqueda\n'
          '[3] $_rtve — RTVE: accidente de tren en directo';
      final segments = splitAnswerTables(text);
      final list = _sources(segments).entries;
      expect(list.map((e) => e.number), [1, 2, 3]);
      expect(list.map((e) => e.url), [_efe, _pais, _rtve]);
      expect(list.map((e) => e.domain), ['efe.com', 'elpais.com', 'rtve.es']);
      expect(
        list.first.description,
        'EFE: 31 heridos y 56 fallecidos identificados en Urda',
      );
      // The heading stays Markdown; the entries are no longer in it.
      expect(_markdownOf(segments), contains('## Sources'));
      expect(_markdownOf(segments), isNot(contains('https://')));
    });

    test('everything run together in one paragraph', () {
      const text =
          'Sources\n\n'
          '[1] $_efe — EFE: 31 heridos y 56 fallecidos identificados en Urda '
          '[2] $_pais — El País: la jueza pide acelerar la búsqueda en Urda '
          '[3] $_rtve — RTVE: accidente de tren en directo, 1 nov 2026';
      final list = _sources(splitAnswerTables(text)).entries;
      expect(list.map((e) => e.number), [1, 2, 3]);
      expect(list.map((e) => e.url), [_efe, _pais, _rtve]);
      expect(
        list[1].description,
        'El País: la jueza pide acelerar la búsqueda en Urda',
      );
      expect(
        list[2].description,
        'RTVE: accidente de tren en directo, 1 nov 2026',
      );
    });

    test(
      'one entry per line under a ### heading, a bold one or «Fuentes:»',
      () {
        for (final heading in [
          '### Sources',
          '**Fuentes**',
          'Fuentes:',
          '#### Referencias',
        ]) {
          final segments = splitAnswerTables(
            'Texto.\n\n$heading\n\n[1] $_efe — EFE\n[2] $_pais — País',
          );
          expect(_sources(segments).entries, hasLength(2), reason: heading);
        }
      },
    );

    test('numbered and bulleted lines, links with text, no description', () {
      final segments = splitAnswerTables(
        'Fuentes\n\n'
        '- [1] [EFE: Urda]($_efe) — resumen\n'
        '2. $_pais\n'
        '3) [RTVE]($_rtve)',
      );
      final list = _sources(segments).entries;
      expect(list.map((e) => e.number), [1, 2, 3]);
      expect(list[0].description, 'EFE: Urda — resumen');
      expect(list[0].url, _efe);
      // Without a description the row reads the slug of the address.
      expect(list[1].description, isEmpty);
      expect(
        list[1].title,
        'La jueza pide acelerar las labores de busqueda'
        ' mas operarios y que se trabaje de noche',
      );
      expect(list[2].title, 'RTVE');
    });

    test('a slug title and the domain of an address', () {
      expect(
        chatUrlSlugTitle(_efe),
        'Heridos urda toledo ingresados accidente',
      );
      expect(chatUrlSlugTitle('https://a.com/x/12345'), 'X');
      expect(chatUrlSlugTitle('https://www.a.com/'), 'a.com');
      expect(chatUrlDomain('https://www.rtve.es/a'), 'rtve.es');
      expect(chatUrlChipLabel('https://www.a.com/b/c/'), 'a.com/b/c');
    });

    test('what is not a sources list is left alone', () {
      // A sentence that starts with the word is not a heading.
      expect(
        splitAnswerTables('Fuentes policiales dicen\n[1] $_efe — x').length,
        1,
      );
      // Reference definitions keep resolving as Markdown.
      expect(splitAnswerTables('Fuentes\n\n[1]: $_efe\n[2]: $_pais').length, 1);
      // A table of text or a code block is not touched.
      expect(
        splitAnswerTables(
          '```\nSources\n[1] $_efe — a\n[2] $_pais — b\n```',
        ).whereType<SourcesSegment>(),
        isEmpty,
      );
      // A lone entry without a heading stays text.
      expect(
        splitAnswerTables('[1] $_efe — a').whereType<SourcesSegment>(),
        isEmpty,
      );
    });

    test(
      'two entries in a row without a heading, when the text is finished',
      () {
        final segments = splitAnswerTables('[1] $_efe — a\n[2] $_pais — b');
        expect(_sources(segments).entries, hasLength(2));
      },
    );

    test('text after the list stays Markdown', () {
      final segments = splitAnswerTables(
        'Fuentes\n\n[1] $_efe — a\n[2] $_pais — b\n\nGracias por leerme.',
      );
      expect(_sources(segments).entries, hasLength(2));
      expect(_markdownOf(segments), contains('Gracias por leerme.'));
    });

    test('pills and rows agree on number to address, also run together', () {
      final urls = chatCitationSources(
        'Sources\n\n[1] $_efe — EFE [2] $_pais — País [3] $_rtve — RTVE',
      );
      expect(urls[1], _efe);
      expect(urls[2], _pais);
      expect(urls[3], _rtve);
    });
  });

  group('a live reply never shows raw structure', () {
    const text =
        'Intro con citas [1] y [2].\n\n'
        '| Col A | Col B |\n'
        '|---|---|\n'
        '| uno | dos |\n'
        '| tres | cuatro |\n\n'
        'Mira https://example.com/a/b/c?x=1 y sigue [texto](https://example.org/doc) fin.\n\n'
        '## Sources\n\n'
        '[1] $_efe — EFE: 31 heridos\n'
        '[2] $_pais — El País: la jueza\n';
    final rawRow = RegExp(r'^\s*\|', multiLine: true);
    final rawSource = RegExp(r'\[\d{1,3}\]\s*h?t?t?p?s?:?/?/?');
    final openUrl = RegExp(r'(?:^|\s)https?://\S*$');
    final openLink = RegExp(r'\]\(https?://[^)]*$');

    test('at every length: no pipes, no «[n] https», no open address', () {
      var lastCount = 0;
      var sawSkeleton = false;
      var sawTable = false;
      for (var n = 1; n <= text.length; n++) {
        final prefix = text.substring(0, n);
        final normalized = normalizeStreamingMarkdown(
          prefix,
          isStreaming: true,
        );
        final segments = splitAnswerTables(normalized, live: true);
        final markdown = _markdownOf(segments);
        expect(rawRow.hasMatch(markdown), isFalse, reason: 'at $n: $markdown');
        expect(openLink.hasMatch(markdown), isFalse, reason: 'at $n');
        expect(openUrl.hasMatch(markdown), isFalse, reason: 'at $n');
        // «[1]» in the body is a citation; a source number followed by an
        // address, even half written, is not allowed in the text.
        final afterBody = markdown.split('## Sources');
        if (afterBody.length > 1) {
          expect(
            rawSource.hasMatch(afterBody[1].trimLeft()),
            isFalse,
            reason: 'at $n: ${afterBody[1]}',
          );
        }
        sawSkeleton |= segments.any((s) => s is TableSkeletonSegment);
        sawTable |= segments.any((s) => s is TableSegment);
        // The rows never go back: an entry shown stays, with a whole address.
        final shown = segments.whereType<SourcesSegment>().fold<int>(
          0,
          (sum, s) => sum + s.entries.length,
        );
        expect(shown, greaterThanOrEqualTo(lastCount), reason: 'at $n');
        lastCount = shown;
        for (final s in segments.whereType<SourcesSegment>()) {
          for (final e in s.entries) {
            expect([_efe, _pais], contains(e.url), reason: 'at $n');
          }
        }
        // A live table keeps what is whole: never a half row.
        for (final t in segments.whereType<TableSegment>()) {
          for (final row in t.rows) {
            expect(row.length, 2, reason: 'at $n');
            expect(row.any((c) => c.contains('|')), isFalse);
          }
        }
      }
      expect(sawSkeleton, isTrue, reason: 'the header alone is held back');
      expect(sawTable, isTrue);
      expect(lastCount, 2);
    });

    test('the header alone is a skeleton, header and separator a table', () {
      expect(
        splitAnswerTables('Antes.\n\n| a | b |', live: true).last,
        isA<TableSkeletonSegment>(),
      );
      expect(
        splitAnswerTables('Antes.\n\n| a | b |\n|', live: true).last,
        isA<TableSkeletonSegment>(),
      );
      final table =
          splitAnswerTables('Antes.\n\n| a | b |\n|--', live: true).last
              as TableSegment;
      expect(table.rows, [
        ['a', 'b'],
      ]);
      expect(table.live, isTrue);
    });

    test('rows come one by one: the half row waits for its line break', () {
      List<List<String>> rows(String t) =>
          (splitAnswerTables(t, live: true).last as TableSegment).rows;
      expect(rows('| a | b |\n|--|--|\n| 1 | 2'), hasLength(1));
      expect(rows('| a | b |\n|--|--|\n| 1 | 2 |\n'), hasLength(2));
      expect(rows('| a | b |\n|--|--|\n| 1 | 2 |\n| 3'), hasLength(2));
    });

    test('a finished reply keeps the old rule for an incomplete table', () {
      final segments = splitAnswerTables('| a | b |\n|--|--|');
      expect(segments.single, isA<MarkdownSegment>());
    });

    test('a table or sources inside a code fence are code', () {
      const code = '```\n| a | b |\n|--|--|\n| 1 | 2 |\n```';
      expect(splitAnswerTables(code).single, isA<MarkdownSegment>());
      expect(
        splitAnswerTables('$code\n\n| c | d |', live: true).last,
        isA<TableSkeletonSegment>(),
      );
    });

    test('sources held while the heading waits for its first entry', () {
      for (final tail in [
        '',
        '\n',
        '\n\n[',
        '\n\n[1',
        '\n\n[1] ht',
        '\n\n1. ',
      ]) {
        final segments = splitAnswerTables('Hola.\n\nSources$tail', live: true);
        expect(segments.whereType<SourcesSegment>(), isEmpty, reason: tail);
        expect(_markdownOf(segments), contains('Sources'));
        expect(_markdownOf(segments), isNot(contains('[1')));
      }
      // The first row needs its address closed and a word after it.
      expect(
        splitAnswerTables(
          'Sources\n\n[1] $_efe',
          live: true,
        ).whereType<SourcesSegment>(),
        isEmpty,
      );
      expect(
        splitAnswerTables(
          'Sources\n\n[1] $_efe — E',
          live: true,
        ).whereType<SourcesSegment>().single.entries.single.description,
        'E',
      );
      // Once its line is closed the row needs no more.
      expect(
        _sources(
          splitAnswerTables('Sources\n\n[1] $_efe\n', live: true),
        ).entries,
        hasLength(1),
      );
    });

    test('peelLiveSources cuts the list off and keeps the text', () {
      expect(peelLiveSources('Solo texto con http://a.b'), isNull);
      final peeled = peelLiveSources(
        'Cuerpo.\n\n## Sources\n\n[1] $_efe — EFE\n[2] https://el',
      )!;
      expect(peeled.entries.map((e) => e.number), [1]);
      expect(peeled.before, startsWith('Cuerpo.'));
      expect(peeled.before, endsWith('## Sources\n'));
      expect(peeled.before, isNot(contains('[')));
    });
  });

  group('an address still being written is held back', () {
    test('the open address of the tail is cut, a closed one is not', () {
      String live(String t) => normalizeStreamingMarkdown(t, isStreaming: true);
      expect(live('Mira https://ef'), 'Mira ');
      expect(live('Mira (https://ef'), 'Mira (');
      expect(live('Mira https://efe.com/a '), 'Mira https://efe.com/a ');
      // The Markdown link target has its own repair.
      expect(live('Mira [texto](https://ef'), isNot(contains('https')));
      // A finished text is shown as it came.
      expect(
        normalizeStreamingMarkdown('Mira https://ef', isStreaming: false),
        'Mira https://ef',
      );
    });

    test('a closed block that ends with an address keeps it', () {
      expect(
        normalizeStableStreamingPrefix('Ver https://efe.com/a\n\n'),
        'Ver https://efe.com/a\n\n',
      );
    });
  });

  group('bare addresses in running text', () {
    final pattern = RegExp(chatBareUrlPattern);
    List<String> found(String t) => [
      for (final m in pattern.allMatches(t)) m[0]!,
    ];

    test('are found whole, without the punctuation that closes the line', () {
      expect(found('Mira https://a.com/x/y.'), ['https://a.com/x/y']);
      expect(found('(ver https://a.com/x), y http://b.org/p?q=1&r=2;'), [
        'https://a.com/x',
        'http://b.org/p?q=1&r=2',
      ]);
      expect(found('wiki https://es.wikipedia.org/wiki/Foo_(bar) fin'), [
        'https://es.wikipedia.org/wiki/Foo_(bar)',
      ]);
    });

    test('a link target, an autolink and a longer word are not', () {
      expect(found('[a](https://a.com/x)'), isEmpty);
      expect(found('<https://a.com/x>'), isEmpty);
      expect(found('xhttps://a.com'), isEmpty);
      expect(chatMayHaveBareUrls('https://a.com/x'), isFalse);
      expect(chatMayHaveBareUrls('Ver https://a.com/x'), isTrue);
      expect(chatMayHaveBareUrls('sin enlaces'), isFalse);
    });
  });
}
