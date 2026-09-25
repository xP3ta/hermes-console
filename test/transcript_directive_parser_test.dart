import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/transcript_directive_parser.dart';

void main() {
  group('parseTranscriptDirective', () {
    test('parses a whole-paragraph directive with double-quoted attrs', () {
      final directive = parseTranscriptDirective(
        '::preview{file="/tmp/out/image.png"}',
      );

      expect(directive, isNotNull);
      expect(directive!.name, 'preview');
      expect(directive.attrs, {'file': '/tmp/out/image.png'});
      expect(directive.source, '::preview{file="/tmp/out/image.png"}');
    });

    test('accepts single-quoted attrs and lowercases keys', () {
      final directive = parseTranscriptDirective(
        "  ::preview{File='/tmp/a b.html' height=\"480\"}  ",
      );

      expect(directive, isNotNull);
      expect(directive!.attrs, {'file': '/tmp/a b.html', 'height': '480'});
    });

    test('parses a bare directive without attrs', () {
      final directive = parseTranscriptDirective('::divider');

      expect(directive, isNotNull);
      expect(directive!.name, 'divider');
      expect(directive.attrs, isEmpty);
    });

    test('prose containing :: is never a directive', () {
      expect(parseTranscriptDirective('Usa std::vector en C++'), isNull);
      expect(parseTranscriptDirective('std::vector<int> v;'), isNull);
      expect(
        parseTranscriptDirective('Mira ::preview{file="/tmp/x.png"}'),
        isNull,
      );
      expect(
        parseTranscriptDirective('::preview{file="/tmp/x.png"} listo'),
        isNull,
      );
    });

    test('rejects multi-line, uppercase names and unbalanced braces', () {
      expect(
        parseTranscriptDirective('::preview{file="/a.png"}\n::preview'),
        isNull,
      );
      expect(parseTranscriptDirective('::Preview{file="/a.png"}'), isNull);
      expect(parseTranscriptDirective('::preview{file="/a.png"'), isNull);
      expect(parseTranscriptDirective('::preview{a={b}}'), isNull);
      expect(parseTranscriptDirective('::'), isNull);
      expect(parseTranscriptDirective(''), isNull);
    });

    test('caps name and attribute lengths like Desktop', () {
      final longName = '::${'a' * 65}';
      expect(parseTranscriptDirective(longName), isNull);
      expect(parseTranscriptDirective('::${'a' * 64}'), isNotNull);

      final longAttrs = '::preview{file="${'x' * 1030}"}';
      expect(parseTranscriptDirective(longAttrs), isNull);
    });

    test('unknown directive names still parse; the caller decides', () {
      final directive = parseTranscriptDirective('::foo{a="b"}');

      expect(directive, isNotNull);
      expect(directive!.name, 'foo');
      expect(directive.attrs, {'a': 'b'});
    });
  });
}
