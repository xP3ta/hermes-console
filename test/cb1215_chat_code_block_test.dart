// cb1215: code inside a chat answer never loses its columns, and the block
// reads like an editor: full width, one header row, monospace with a fixed
// line box, restrained colours from the theme and long blocks collapsed.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Future<void> _loadFont(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

void main() {
  setUpAll(() async {
    // Real glyph advances. The bundled monospace font; Inter as the body
    // font (proportional, like on a phone); and a fixture registered as the
    // system `monospace` family: ASCII at 600 units but box-drawing at full
    // width (1000). That mirrors Android, where Droid Sans Mono has no
    // box-drawing glyphs and they come from the full-width CJK fallback, which
    // is how trees and diagrams lost their columns. The fixture is a subset
    // of JetBrains Mono (SIL OFL 1.1, see assets/fonts/OFL.txt).
    await _loadFont('JetBrainsMono', 'assets/fonts/JetBrainsMono.ttf');
    await _loadFont('Inter', 'assets/fonts/Inter.ttf');
    final fixture = File('test/fixtures/fonts/android_mono_fallback.ttf');
    final loader = FontLoader('monospace')
      ..addFont(Future.value(ByteData.sublistView(fixture.readAsBytesSync())));
    await loader.load();
  });

  void useSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget chat(
    String md, {
    ThemeData? theme,
    double maxWidth = 340,
    double textScale = 1,
  }) => MaterialApp(
    theme: theme ?? AppTheme.hermesRedDark,
    locale: const Locale('en'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: SingleChildScrollView(
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: ChatMarkdownBody(
                  key: const ValueKey('answer'),
                  data: md,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  void mockClipboard(WidgetTester tester, void Function(String?) onCopy) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          onCopy((call.arguments as Map)['text'] as String?);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  /// The paragraph that paints the code (not the gutter, not the header).
  Finder codeParagraph(String marker) => find.byWidgetPredicate(
    (w) => w is RichText && w.text.toPlainText().contains(marker),
  );

  RenderParagraph paragraphOf(WidgetTester tester, String marker) =>
      tester.renderObject<RenderParagraph>(codeParagraph(marker));

  /// Global x of the caret before column [col] of every line.
  List<double> columnX(WidgetTester tester, String marker, int col) {
    final rp = paragraphOf(tester, marker);
    final text = rp.text.toPlainText();
    final xs = <double>[];
    var start = 0;
    for (final line in text.split('\n')) {
      if (line.length >= col) {
        final caret = rp.getOffsetForCaret(
          TextPosition(offset: start + col),
          Rect.zero,
        );
        xs.add(rp.localToGlobal(caret).dx);
      }
      start += line.length + 1;
    }
    return xs;
  }

  /// Height of every line box, from the selection boxes of each line.
  List<double> lineHeights(RenderParagraph rp) {
    final text = rp.text.toPlainText();
    final heights = <double>[];
    var start = 0;
    for (final line in text.split('\n')) {
      final boxes = rp.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + line.length),
        boxHeightStyle: BoxHeightStyle.max,
      );
      if (boxes.isNotEmpty) {
        heights.add(boxes.map((b) => b.bottom - b.top).reduce(math.max));
      }
      start += line.length + 1;
    }
    return heights;
  }

  void expectAligned(List<double> xs) {
    expect(xs.length, greaterThan(1));
    for (final x in xs) {
      expect(x, closeTo(xs.first, 0.5), reason: 'column x per line: $xs');
    }
  }

  group('alignment', () {
    testWidgets('tabs expand to 4-column stops and copy keeps the tabs', (
      tester,
    ) async {
      useSize(tester, const Size(390, 844));
      String? copied;
      mockClipboard(tester, (t) => copied = t);
      const code = 'a\tb\nabc\tb\n\tb';
      await tester.pumpWidget(chat('```go\n$code\n```'));
      await settle(tester);
      final shown = paragraphOf(tester, 'abc').text.toPlainText();
      expect(shown, isNot(contains('\t')));
      expect(shown.split('\n'), ['a   b', 'abc b', '    b']);
      expectAligned(columnX(tester, 'abc', 4));

      await tester.tap(find.byTooltip('Copy code'));
      await settle(tester);
      expect(copied, code);
    });

    testWidgets('a box-drawing tree keeps its columns', (tester) async {
      useSize(tester, const Size(390, 844));
      const tree =
          'src/\n'
          '├── main.dart\n'
          '│   └── app.dart\n'
          '└── lib/\n'
          '    └── x.dart';
      await tester.pumpWidget(chat('```\n$tree\n```'));
      await settle(tester);
      for (final col in [1, 4, 8]) {
        expectAligned(columnX(tester, 'main.dart', col));
      }
    });

    testWidgets('a bare tree without double spaces is still code', (
      tester,
    ) async {
      useSize(tester, const Size(390, 844));
      // No line has two spaces in a row, so only the box-drawing glyphs tell
      // this fence apart from prose.
      await tester.pumpWidget(chat('```\n.\n├─ lib\n│ └─ a\n└─ test\n```'));
      await settle(tester);
      expectAligned(columnX(tester, '├─ lib', 2));
    });

    testWidgets('an ASCII table keeps every border in its column', (
      tester,
    ) async {
      useSize(tester, const Size(390, 844));
      const table =
          '+------+-----+\n'
          '| name | qty |\n'
          '+======+=====+\n'
          '| iiii | 1   |\n'
          '| WWWW | 22  |\n'
          '+------+-----+';
      await tester.pumpWidget(chat('```text\n$table\n```'));
      await settle(tester);
      expectAligned(columnX(tester, 'WWWW', 7));
      expectAligned(columnX(tester, 'WWWW', 13));
    });

    testWidgets('lines with emoji or CJK keep the same line height', (
      tester,
    ) async {
      useSize(tester, const Size(390, 844));
      await tester.pumpWidget(
        chat('```text\nplain line\n✓ done 😀\n中文 注释\n─── end\n```'),
      );
      await settle(tester);
      final rp = paragraphOf(tester, 'plain line');
      final heights = lineHeights(rp);
      expect(heights, hasLength(4));
      for (final h in heights) {
        expect(h, closeTo(heights.first, 0.01), reason: '$heights');
      }
      // Fallback glyphs (emoji, CJK) come from other fonts with other
      // metrics; only a forced strut keeps every line box identical.
      expect(rp.strutStyle?.forceStrutHeight, isTrue);
    });

    testWidgets('a 300-char line scrolls inside; the answer keeps its width', (
      tester,
    ) async {
      useSize(tester, const Size(390, 844));
      await tester.pumpWidget(chat('Short intro.\n\n```js\nx = 1;\n```'));
      await settle(tester);
      final shortWidth = tester.getSize(find.byKey(const ValueKey('answer')));
      final shortBlock = tester.getRect(
        find.byKey(const ValueKey('chat-code-block')),
      );

      final long = List.filled(300, 'w').join();
      await tester.pumpWidget(chat('Short intro.\n\n```js\n$long\n```'));
      await settle(tester);
      expect(tester.takeException(), isNull);
      final answer = tester.getRect(find.byKey(const ValueKey('answer')));
      expect(answer.size, shortWidth);
      expect(answer.width, 340);
      final block = tester.getRect(
        find.byKey(const ValueKey('chat-code-block')),
      );
      // Full width whatever the content: short code does not shrink it and a
      // long line does not push it.
      expect(block.width, closeTo(answer.width, 0.5));
      expect(shortBlock.width, closeTo(answer.width, 0.5));
      final scroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const ValueKey('chat-code-block')),
          matching: find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.right,
          ),
        ),
      );
      expect(scroll.position.maxScrollExtent, greaterThan(1000));
    });
  });

  group('design', () {
    testWidgets('header shows the language; copy copies the exact text', (
      tester,
    ) async {
      useSize(tester, const Size(390, 844));
      String? copied;
      mockClipboard(tester, (t) => copied = t);
      const code = 'def f(x):\n\treturn x  \n';
      await tester.pumpWidget(chat('```python\n${code}x\n```'));
      await settle(tester);
      expect(find.text('python'), findsOneWidget);
      final header = tester.getRect(find.text('python'));
      final codeTop = tester.getRect(codeParagraph('def f')).top;
      expect(header.bottom, lessThanOrEqualTo(codeTop));
      await tester.tap(find.byTooltip('Copy code'));
      await settle(tester);
      expect(copied, '${code}x');
    });

    testWidgets('block is a 12dp rounded surface of the theme', (tester) async {
      useSize(tester, const Size(390, 844));
      await tester.pumpWidget(chat('```dart\nfinal a = 1;\n```'));
      await settle(tester);
      final clip = tester.widget<ClipRRect>(
        find
            .descendant(
              of: find.byKey(const ValueKey('chat-code-block')),
              matching: find.byType(ClipRRect),
            )
            .first,
      );
      expect(clip.borderRadius, BorderRadius.circular(12));
      final style = paragraphOf(tester, 'final a').text.style!;
      expect(style.fontFamily, 'JetBrainsMono');
      expect(style.fontSize, 13);
      expect(style.height, 1.45);
    });

    testWidgets('more than 5 lines get a gutter aligned with each line', (
      tester,
    ) async {
      useSize(tester, const Size(390, 844));
      final lines = [for (var i = 1; i <= 7; i++) 'line $i'];
      await tester.pumpWidget(chat('```js\n${lines.join('\n')}\n```'));
      await settle(tester);
      final gutter = find.byKey(const ValueKey('chat-code-gutter'));
      expect(gutter, findsOneWidget);
      final g = tester.renderObject<RenderParagraph>(
        find.descendant(of: gutter, matching: find.byType(RichText)),
      );
      expect(g.text.toPlainText().split('\n'), [
        for (var i = 1; i <= 7; i++) '$i',
      ]);
      final code = paragraphOf(tester, 'line 1');
      final gText = g.text.toPlainText();
      final cText = code.text.toPlainText();
      var gs = 0, cs = 0;
      for (var i = 0; i < 7; i++) {
        final gy = g
            .localToGlobal(
              g.getOffsetForCaret(TextPosition(offset: gs), Rect.zero),
            )
            .dy;
        final cy = code
            .localToGlobal(
              code.getOffsetForCaret(TextPosition(offset: cs), Rect.zero),
            )
            .dy;
        expect(gy, closeTo(cy, 0.5), reason: 'line ${i + 1}');
        gs = gText.indexOf('\n', gs) + 1;
        cs = cText.indexOf('\n', cs) + 1;
      }

      await tester.pumpWidget(chat('```js\na\nb\nc\nd\ne\n```'));
      await settle(tester);
      expect(gutter, findsNothing);
    });

    testWidgets('long blocks collapse to 18 lines and expand on demand', (
      tester,
    ) async {
      useSize(tester, const Size(390, 844));
      String? copied;
      mockClipboard(tester, (t) => copied = t);
      final code = [for (var i = 1; i <= 30; i++) 'row $i;'].join('\n');
      await tester.pumpWidget(chat('```c\n$code\n```'));
      await settle(tester);
      String shown() => paragraphOf(tester, 'row 1;').text.toPlainText();
      expect(shown(), contains('row 18;'));
      expect(shown(), isNot(contains('row 19;')));
      expect(find.text('Show all 30 lines'), findsOneWidget);

      await tester.tap(find.byTooltip('Copy code'));
      await settle(tester);
      expect(copied, code);

      await tester.tap(find.text('Show all 30 lines'));
      await settle(tester);
      expect(shown(), contains('row 30;'));
      expect(find.text('Show less'), findsOneWidget);
      await tester.tap(find.text('Show less'));
      await settle(tester);
      expect(shown(), isNot(contains('row 19;')));
    });

    testWidgets('text scale 2.0 on a narrow phone does not overflow', (
      tester,
    ) async {
      useSize(tester, const Size(320, 700));
      final code = [for (var i = 1; i <= 8; i++) 'const v$i = $i;'].join('\n');
      await tester.pumpWidget(
        chat('```typescriptreact\n$code\n```', maxWidth: 300, textScale: 2),
      );
      await settle(tester);
      expect(tester.takeException(), isNull);
      // Gutter and code scale together, so their lines stay paired.
      final g = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byKey(const ValueKey('chat-code-gutter')),
          matching: find.byType(RichText),
        ),
      );
      final body = paragraphOf(tester, 'const v1');
      expect(g.textScaler, body.textScaler);
      expect(body.textScaler.scale(10), 20);
    });

    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
    }

    testWidgets('syntax colours come from the theme and stay readable', (
      tester,
    ) async {
      useSize(tester, const Size(390, 844));
      for (final theme in [AppTheme.hermesRedLight, AppTheme.hermesRedDark]) {
        await tester.pumpWidget(
          chat(
            '```python\n# note\ndef f(x):\n    return "s" + 1\n```',
            theme: theme,
          ),
        );
        await settle(tester);
        // Let the theme transition finish: colours are judged at rest.
        await tester.pump(const Duration(seconds: 1));
        final colors = theme.hermes;
        final root = paragraphOf(tester, 'def f').text as TextSpan;
        final seen = <Color>{};
        void walk(InlineSpan s, Color inherited) {
          final c = s.style?.color ?? inherited;
          if (s is TextSpan) {
            if ((s.text ?? '').trim().isNotEmpty) seen.add(c);
            for (final ch in s.children ?? const <InlineSpan>[]) {
              walk(ch, c);
            }
          }
        }

        walk(root, root.style!.color!);
        expect(seen.length, greaterThan(1), reason: 'highlighting applied');
        expect(seen.length, lessThanOrEqualTo(4), reason: 'restrained');
        for (final c in seen) {
          expect(
            contrast(c, colors.surfaceVariant),
            greaterThanOrEqualTo(3),
            reason: '$c on ${colors.surfaceVariant}',
          );
        }
      }
    });

    testWidgets('inline code is a subtle pill without a line-height jump', (
      tester,
    ) async {
      useSize(tester, const Size(390, 844));
      await tester.pumpWidget(chat('Run `flutter test` now.'));
      await settle(tester);
      final withCode = paragraphOf(tester, 'Run');
      TextSpan? pill;
      void walk(InlineSpan s) {
        if (s is TextSpan) {
          if (s.text == 'flutter test') pill = s;
          s.children?.forEach(walk);
        }
      }

      walk(withCode.text);
      expect(pill, isNotNull);
      expect(pill!.style!.fontFamily, 'JetBrainsMono');
      final bg = pill!.style!.backgroundColor;
      expect(bg, isNotNull);
      expect(bg!.a, greaterThan(0));
      final h1 = withCode.size.height;

      await tester.pumpWidget(chat('Run flutter test now.'));
      await settle(tester);
      expect(paragraphOf(tester, 'Run').size.height, closeTo(h1, 0.01));
    });
  });
}
