import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/streaming_normalizer.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// Emphasis inside a link's text renders as emphasis, also while the message
// still arrives. The `/` of the address must not make the text look like a
// path glob (its `*` are literal only in paths).

const _url = 'https://www.youtube.com/watch?v=abc123';
const _titled =
    '[▶ **El imperio del fuego (2002) — tráiler subtitulado en español**]($_url)';

Widget _host(String data, {bool streaming = false, bool embeds = false}) =>
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromMode(AppThemeMode.dark),
      home: Scaffold(
        body: SingleChildScrollView(
          child: ChatMarkdownBody(
            data: data,
            isStreaming: streaming,
            selectable: false,
            embeds: embeds,
          ),
        ),
      ),
    );

String _plain(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((r) => r.text.toPlainText())
    .join('\n');

/// The text spans of the rendered body, with their style.
List<TextSpan> _spans(WidgetTester tester) {
  final out = <TextSpan>[];
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    rich.text.visitChildren((span) {
      if (span is TextSpan && (span.text ?? '').isNotEmpty) out.add(span);
      return true;
    });
  }
  return out;
}

bool _bold(TextSpan s) =>
    (s.style?.fontWeight?.value ?? 400) >= FontWeight.w600.value;

void main() {
  group('escapePathGlobs leaves a link text alone', () {
    test('bold around a multi-word link text keeps both markers', () {
      expect(escapePathGlobs(_titled), _titled);
    });

    test('no spaces: [**negrita**](url) is untouched too', () {
      const text = '[**negrita**](https://a.io/b)';
      expect(escapePathGlobs(text), text);
    });

    test('italic, code and a mix inside the text', () {
      for (final text in [
        '[ver *esto ahora*](https://a.io/b)',
        '[ver `código` y **más**](https://a.io/b)',
        '[**negrita** y *cursiva* juntas](https://a.io/b)',
        '[_cursiva con guiones_](https://a.io/b)',
      ]) {
        expect(escapePathGlobs(text), text, reason: text);
      }
    });

    test('streaming states of the link keep the markers', () {
      for (final text in [
        '[▶ **El imperio del fuego**](https://www.you',
        '[▶ **El imperio del fuego**]',
        '[▶ **El imperio del fuego**](',
      ]) {
        expect(escapePathGlobs(text), text, reason: text);
      }
    });
  });

  group('negatives keep their behaviour', () {
    test('a path glob is still escaped', () {
      final out = escapePathGlobs('busca en /home/user/**/*.pdf ahora');
      expect(out, contains(r'\*'));
    });

    test('loose asterisks are left as they were', () {
      expect(escapePathGlobs('2 * 3 * 4'), '2 * 3 * 4');
      expect(escapePathGlobs('a*b'), 'a*b');
    });

    test('asterisks inside the address are never touched', () {
      const text = '[doc](https://a.io/x**y)';
      expect(escapePathGlobs(text), text);
    });

    test('a path in the link TEXT is still a path', () {
      final out = escapePathGlobs('[ver /home/u/**/*.md](https://a.io/b)');
      expect(out, contains(r'\*'));
    });
  });

  group('rendered', () {
    testWidgets('bold inside the link text, no literal asterisks', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_titled));
      final plain = _plain(tester);
      expect(plain, isNot(contains('*')));
      expect(plain, contains('El imperio del fuego (2002)'));
      final bold = _spans(tester).where(
        (s) => (s.text ?? '').contains('El imperio del fuego'),
      );
      expect(bold, isNotEmpty);
      expect(bold.every(_bold), isTrue, reason: 'the text of the link is bold');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('italic and code inside the link text', (tester) async {
      await tester.pumpWidget(
        _host('[ver *esto* y `código` en **negrita**](https://a.io/b)'),
      );
      final plain = _plain(tester);
      expect(plain, isNot(contains('*')));
      expect(plain, isNot(contains('`')));
      expect(plain, contains('esto'));
      expect(plain, contains('código'));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('streaming: no literal markers or backslashes at any prefix', (
      tester,
    ) async {
      final closeAt = _titled.indexOf('español**') + 'español**'.length;
      for (var end = 4; end <= _titled.length; end += 5) {
        final prefix = _titled.substring(0, end);
        await tester.pumpWidget(_host(prefix, streaming: true));
        final plain = _plain(tester);
        expect(plain, isNot(contains(r'\')), reason: prefix);
        if (end >= closeAt) {
          expect(plain, isNot(contains('**')), reason: prefix);
        }
      }
      await tester.pumpWidget(_host(_titled, streaming: true));
      expect(_plain(tester), isNot(contains('*')));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('loose asterisks and an address with asterisks render', (
      tester,
    ) async {
      await tester.pumpWidget(_host('2 * 3 * 4 y [doc](https://a.io/x**y)'));
      final plain = _plain(tester);
      expect(plain, contains('2 * 3 * 4'));
      expect(plain, contains('doc'));
      expect(plain, isNot(contains('https://a.io')));
      await tester.pumpWidget(const SizedBox());
    });
  });
}
