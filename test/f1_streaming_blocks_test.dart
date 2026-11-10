// F1 of the fluidity plan (REPORT-AUDITORIA-FLUIDEZ §2.3.6-8, §2.4): the
// closed prefix of a live answer is a list of blocks projected once each,
// and the code still being written is drawn plain, whole, and highlighted
// once its fence closes. Work counted, not milliseconds.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/chat_stream_trace.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/streaming_normalizer.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/core/widgets/chat/streaming_markdown_blocks.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: Scaffold(
    body: SingleChildScrollView(child: SizedBox(width: 360, child: child)),
  ),
);

String _paragraphs(int n, String tag) => [
  for (var i = 0; i < n; i++) 'Párrafo $i de $tag, ya cerrado.',
].join('\n\n');

void main() {
  group('blocks of the prefix', () {
    test('one block per top-level block, and they add up to the text', () {
      const text =
          'Uno.\n\nDos, con **negrita**.\n\n```dart\nfinal a = 1;\n\n'
          'final b = 2;\n```\n\nTres.';
      final blocks = streamingMarkdownBlocks(text);
      expect(blocks.join(), text);
      expect(blocks, hasLength(4), reason: 'the blank line in code is code');
      expect(blocks[2], startsWith('```dart'));
    });

    test('the code of a fence still open, and null once it closes', () {
      expect(
        streamingOpenFenceCode('Mira:\n\n```python\nprint(1)\nprint('),
        'print(1)\nprint(',
      );
      expect(
        streamingOpenFenceCode('Mira:\n\n```python\nprint(1)\n```\n'),
        isNull,
      );
      expect(streamingOpenFenceCode('~~~~\na\n~~~\nb'), 'a\n~~~\nb');
      expect(streamingOpenFenceCode('Solo texto.'), isNull);
    });

    testWidgets('closing a paragraph projects one block, not the prefix', (
      tester,
    ) async {
      var projected = 0;
      Widget blocks(String data) => _app(
        StreamingMarkdownBlocks(
          data: data,
          markdown: (data) => ChatMarkdownBlock(data: data),
          onProjected: () => projected++,
        ),
      );
      final three = '${_paragraphs(3, 'A')}\n\n';
      await tester.pumpWidget(blocks(three));
      expect(projected, 3);
      final block0 = find.byKey(const ValueKey(('streaming-block', 0)));
      final first = tester.widget(block0);
      // The same prefix rebuilt (a tail token): nothing projected.
      await tester.pumpWidget(blocks(three));
      expect(projected, 3);
      // One more paragraph closes: one block more.
      await tester.pumpWidget(blocks('$three${_paragraphs(1, 'B')}\n\n'));
      expect(projected, 4);
      expect(
        tester.widget(block0),
        same(first),
        reason: 'a block already drawn keeps its widget',
      );
      // Each block repaints on its own.
      for (var index = 0; index < 4; index++) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey(('streaming-block', index))),
            matching: find.byType(RepaintBoundary),
          ),
          findsWidgets,
        );
      }
      expect(find.textContaining('Párrafo 0 de B'), findsOneWidget);
    });

    testWidgets('an equivalent localized theme keeps the closed prefix', (
      tester,
    ) async {
      var projected = 0;
      ThemeData? effectiveTheme;
      final base = AppTheme.hermesRedDark;
      const themeKey = ValueKey('prefix-theme-regression');
      Widget blocks(ThemeData theme) => _app(
        Theme(
          key: themeKey,
          data: theme,
          child: Builder(
            builder: (context) {
              effectiveTheme = Theme.of(context);
              return StreamingMarkdownBlocks(
                data: 'Un prefijo cerrado.\n\n',
                markdown: (data) => ChatMarkdownBlock(data: data),
                onProjected: () => projected++,
              );
            },
          ),
        ),
      );

      await tester.pumpWidget(blocks(base));
      expect(projected, 1);
      final block0 = find.byKey(const ValueKey(('streaming-block', 0)));
      final firstBlock = tester.widget(block0);
      final firstState = tester.state(find.byType(StreamingMarkdownBlocks));
      final firstTheme = effectiveTheme!;

      // The SDK's FIFO stores five base/geometry identity pairs. Six fresh
      // pairs evict the localized result, without changing the mounted theme.
      for (var index = 0; index < 6; index++) {
        ThemeData.localize(base.copyWith(), base.typography.englishLike);
      }
      await tester.pumpWidget(blocks(base));
      expect(tester.widget<Theme>(find.byKey(themeKey)).data, same(base));
      expect(effectiveTheme, isNot(same(firstTheme)));
      expect(effectiveTheme, equals(firstTheme));
      expect(
        tester.state(find.byType(StreamingMarkdownBlocks)),
        same(firstState),
      );
      expect(projected, 1);
      expect(tester.widget(block0), same(firstBlock));

      final body = base.textTheme.bodyMedium!;
      final changed = base.copyWith(
        textTheme: base.textTheme.copyWith(
          bodyMedium: body.copyWith(fontSize: (body.fontSize ?? 14) + 2),
        ),
      );
      await tester.pumpWidget(blocks(changed));
      expect(effectiveTheme, isNot(equals(firstTheme)));
      expect(
        tester.state(find.byType(StreamingMarkdownBlocks)),
        same(firstState),
      );
      expect(projected, 2);
      expect(tester.widget(block0), isNot(same(firstBlock)));
      expect(tester.takeException(), isNull);
    });
  });

  // REVIEW-T2-A C2: what keeps the reader's anchor (#1215) and the switch
  // to the finished reply still is that the height does not change. The
  // column of blocks must be as tall as the single body it replaces.
  group('as tall as one body', () {
    test('a loose list and what is indented under it stay one group', () {
      const text = '1. uno\n\n2. dos\n\n   sigue el dos.\n\nFin.\n\n';
      expect(streamingMarkdownGroups(text), [
        '1. uno\n\n2. dos\n\n   sigue el dos.\n\n',
        'Fin.\n\n',
      ]);
    });

    test('a prefix with a link reference is one group', () {
      const text =
          'Lee [la guía][g].\n\nOtro.\n\n[g]: https://example.invalid\n\n';
      expect(streamingMarkdownGroups(text), [text]);
    });

    test('paragraphs are a group each, and the groups add up', () {
      final text = '${_paragraphs(3, 'G')}\n\n';
      final groups = streamingMarkdownGroups(text);
      expect(groups, hasLength(3));
      expect(groups.join(), text);
    });

    const cases = {
      'prose':
          'Uno, una frase que ocupa algo más de una línea en el móvil.'
          '\n\nDos.\n\nTres, la última del prefijo.',
      'headings':
          '# Título\n\nUn párrafo bajo el título.\n\n## Otro\n\n'
          'Y otro párrafo.',
      'tight list': '- uno\n- dos\n- tres\n\nTexto después de la lista.',
      'loose list':
          '1. uno\n\n2. dos, con más texto para que ocupe dos '
          'líneas en un móvil estrecho.\n\n3. tres\n\n   sigue el tres.'
          '\n\nFin.',
      'code': 'Mira:\n\n```dart\nfinal a = 1;\n\nfinal b = 2;\n```\n\nY ya.',
      'reference':
          'Lee [la guía][g] antes.\n\nOtro párrafo.\n\n'
          '[g]: https://example.invalid/guia',
    };
    for (final MapEntry(:key, :value) in cases.entries) {
      testWidgets(key, (tester) async {
        final prefix = '$value\n\n';
        await tester.pumpWidget(
          _app(
            StreamingMarkdownBlocks(
              data: prefix,
              markdown: (data) => ChatMarkdownBlock(data: data),
            ),
          ),
        );
        final split = tester
            .getSize(find.byType(StreamingMarkdownBlocks))
            .height;
        await tester.pumpWidget(
          _app(ChatMarkdownBlock(data: normalizeStableStreamingPrefix(prefix))),
        );
        final whole = tester.getSize(find.byType(ChatMarkdownBlock)).height;
        expect(split, closeTo(whole, 0.5), reason: key);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('code being written', () {
    setUp(ChatStreamTrace.debugReset);

    String code(String tag, int lines) =>
        [for (var i = 0; i < lines; i++) 'valor_$tag$i = $i'].join('\n');

    testWidgets('plain and whole while its fence is open', (tester) async {
      final body = code('abierto', 30);
      await tester.pumpWidget(
        _app(
          ChatMarkdownBlock(data: '```python\n$body\n```', liveCode: '$body\n'),
        ),
      );
      expect(
        ChatStreamTrace.debugCount(ChatStreamPoint.highlight),
        0,
        reason: 'no highlight.parse for code still being written',
      );
      final text = tester.widget<Text>(
        find.byKey(const ValueKey('chat-code-text')),
      );
      expect(
        text.textSpan!.toPlainText(),
        contains('valor_abierto29 = 29'),
        reason: 'not folded at 18 lines: the new lines are seen',
      );
    });

    testWidgets('highlighted once its fence has closed', (tester) async {
      final body = code('cerrado', 3);
      await tester.pumpWidget(
        _app(ChatMarkdownBlock(data: '```python\n$body\n```')),
      );
      expect(ChatStreamTrace.debugCount(ChatStreamPoint.highlight), 1);
    });

    testWidgets('a closed block that starts the live one is not live', (
      tester,
    ) async {
      // REVIEW-T2-A: `valor_corto0 = 0` is a prefix of the live code; it is
      // closed, so it is highlighted (and the live one is not).
      final closed = code('corto', 1);
      final open = '$closed + 1\nmas = 2';
      await tester.pumpWidget(
        _app(
          ChatMarkdownBlock(
            data: '```python\n$closed\n```\n\n```python\n$open\n```',
            liveCode: open,
          ),
        ),
      );
      expect(ChatStreamTrace.debugCount(ChatStreamPoint.highlight), 1);
    });

    testWidgets('an earlier closed block keeps its colour', (tester) async {
      final closed = code('previo', 2);
      final open = code('nuevo', 2);
      await tester.pumpWidget(
        _app(
          ChatMarkdownBlock(
            data: '```python\n$closed\n```\n\n```python\n$open\n```',
            liveCode: open,
          ),
        ),
      );
      expect(ChatStreamTrace.debugCount(ChatStreamPoint.highlight), 1);
    });
  });
}
