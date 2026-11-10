// Markdown polish, drawn: the list of sources as rows, the bare address as a
// chip, and a live reply that is already in its final form while it arrives.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_inline_chips.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/core/widgets/chat/chat_sources_list.dart';
import 'package:hermes_android/core/widgets/markdown_table.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const String _efe =
    'https://efe.com/espana/2026-11-01/heridos-urda-toledo-ingresados-accidente';
const String _pais =
    'https://elpais.com/espana/2026-11-01/la-jueza-pide-acelerar-las-labores-'
    'de-busqueda-mas-operarios-y-que-se-trabaje-de-noche.html';
const String _rtve =
    'https://www.rtve.es/noticias/20261101/accidente-tren-directo-ultima-hora-'
    'heridos/17295258.shtml';

const String _lines =
    'Murieron cuatro personas.[1] Otro hallazgo.[2][3]\n\n'
    '## Sources\n\n'
    '[1] $_efe — EFE: 31 heridos y 56 fallecidos identificados en Urda\n'
    '[2] $_pais — El País: la jueza pide acelerar la búsqueda en Urda\n'
    '[3] $_rtve — RTVE: accidente de tren en directo, 1 nov 2026';

// The same list, run together in one paragraph as the capture shows it.
const String _runTogether =
    'Murieron cuatro personas.[1] Otro hallazgo.[2][3]\n\n'
    'Sources\n\n'
    '[1] $_efe — EFE: 31 heridos y 56 fallecidos identificados en Urda '
    '[2] $_pais — El País: la jueza pide acelerar la búsqueda en Urda '
    '[3] $_rtve — RTVE: accidente de tren en directo, 1 nov 2026';

Widget _app(
  Widget child, {
  bool dark = true,
  double width = 360,
  double textScale = 1,
}) => MaterialApp(
  theme: dark ? AppTheme.hermesRedDark : AppTheme.hermesRedLight,
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: home!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: child),
      ),
    ),
  ),
);

Future<void> _pump(
  WidgetTester tester,
  String data, {
  bool streaming = false,
  bool dark = true,
  double width = 360,
  double textScale = 1,
  void Function(String? href)? onLinkTap,
}) async {
  await tester.pumpWidget(
    _app(
      ChatMarkdownBody(
        data: data,
        isStreaming: streaming,
        selectable: false,
        onLinkTap: onLinkTap,
      ),
      dark: dark,
      width: width,
      textScale: textScale,
    ),
  );
  await tester.pump();
}

final RegExp _rawSource = RegExp(r'\[\d\]\s');

/// All the text the screen draws, as plain strings.
List<String> _drawn(WidgetTester tester) => [
  for (final rich in tester.widgetList<RichText>(find.byType(RichText)))
    rich.text.toPlainText(),
];

List<String> _mockClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
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
  return copied;
}

void main() {
  group('the list of sources as rows', () {
    for (final (name, data) in [
      ('lines', _lines),
      ('run together', _runTogether),
    ]) {
      testWidgets('$name: one row each, no address in sight', (tester) async {
        await _pump(tester, data);
        expect(find.byType(ChatSourcesList), findsOneWidget);
        expect(find.byType(ChatSourceRow), findsNWidgets(3));
        for (final text in _drawn(tester)) {
          expect(text, isNot(contains('https://')), reason: text);
          expect(_rawSource.hasMatch(text), isFalse, reason: text);
        }
        // The domain in small and the description in the row.
        expect(find.text('efe.com'), findsOneWidget);
        expect(find.text('elpais.com'), findsOneWidget);
        expect(find.text('rtve.es'), findsOneWidget);
        expect(
          find.text('EFE: 31 heridos y 56 fallecidos identificados en Urda'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a tap opens the whole address, a long press copies it', (
      tester,
    ) async {
      final copied = _mockClipboard(tester);
      final opened = <String?>[];
      await _pump(tester, _lines, onLinkTap: opened.add);
      await tester.tap(find.byType(ChatSourceRow).at(1));
      await tester.pump();
      expect(opened, [_pais]);
      await tester.longPress(find.byType(ChatSourceRow).at(2));
      await tester.pump();
      expect(copied, [_rtve]);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('the citation pills still open their source', (tester) async {
      final opened = <String?>[];
      await _pump(tester, _lines, onLinkTap: opened.add);
      expect(find.byType(ChatCitationPill), findsNWidgets(3));
      await tester.tap(find.byType(ChatCitationPill).at(2));
      await tester.pump();
      expect(opened, [_rtve]);
    });

    testWidgets('a row without a description reads the slug', (tester) async {
      await _pump(tester, 'Fuentes\n\n[1] $_efe\n[2] $_pais');
      expect(
        find.text('Heridos urda toledo ingresados accidente'),
        findsOneWidget,
      );
    });

    testWidgets('rows are announced as links, with number and domain', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester, _lines);
      expect(
        find.bySemanticsLabel(RegExp(r'Fuente 1: EFE.*efe\.com')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Fuentes: 3'), findsOneWidget);
      semantics.dispose();
    });

    for (final dark in [true, false]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('${dark ? 'dark' : 'light'} at ×$scale fits', (
          tester,
        ) async {
          await _pump(tester, _lines, dark: dark, width: 240, textScale: scale);
          expect(find.byType(ChatSourceRow), findsNWidgets(3));
          for (final element in find.byType(ChatSourceRow).evaluate()) {
            expect(element.size!.width, lessThanOrEqualTo(240));
            expect(element.size!.height, greaterThanOrEqualTo(48));
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('a bare address in the text', () {
    const long =
        'https://www.example.com/una/ruta/muy/larga/con/muchos/segmentos/y-un-'
        'slug-larguisimo-que-no-cabe-en-ninguna-columna.html?utm_source=a&utm_'
        'medium=b&utm_campaign=c';

    testWidgets(
      'is a chip: domain and path with an ellipsis, not 120 letters',
      (tester) async {
        await _pump(tester, 'Mira esto: $long y sigue el texto.', width: 300);
        expect(find.byType(ChatUrlChip), findsOneWidget);
        final chip = tester.getSize(find.byType(ChatUrlChip));
        expect(chip.width, lessThanOrEqualTo(300));
        // One line of the paragraph around it, not a wall of underlined text.
        expect(chip.height, lessThan(40));
        for (final text in _drawn(tester)) {
          expect(text, isNot(contains('https://')));
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a tap opens the whole address, a long press copies it', (
      tester,
    ) async {
      final copied = _mockClipboard(tester);
      final opened = <String?>[];
      await _pump(tester, 'Mira $long ahora.', onLinkTap: opened.add);
      await tester.tap(find.byType(ChatUrlChip));
      await tester.pump();
      expect(opened, [long]);
      await tester.longPress(find.byType(ChatUrlChip));
      await tester.pump();
      expect(copied, [long]);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a Markdown link keeps its text and its link style', (
      tester,
    ) async {
      final opened = <String?>[];
      await _pump(
        tester,
        '[la guía](https://example.com/guia)',
        onLinkTap: opened.add,
      );
      expect(find.byType(ChatUrlChip), findsNothing);
      await tester.tap(find.text('la guía', findRichText: true));
      expect(opened, ['https://example.com/guia']);
      await _pump(
        tester,
        'Mira [https://a.com/x](https://a.com/x) y más.',
        onLinkTap: opened.add,
      );
      expect(find.byType(ChatUrlChip), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an address alone on its line is not a chip', (tester) async {
      await _pump(tester, 'https://example.com/a');
      expect(find.byType(ChatUrlChip), findsNothing);
      await _pump(tester, 'Mira esto:\n\nhttps://example.com/a\n\nfin');
      expect(find.byType(ChatUrlChip), findsNothing);
    });

    for (final dark in [true, false]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('${dark ? 'dark' : 'light'} at ×$scale does not overflow', (
          tester,
        ) async {
          await _pump(
            tester,
            'Ver $long y $long fin.',
            dark: dark,
            width: 220,
            textScale: scale,
          );
          expect(find.byType(ChatUrlChip), findsNWidgets(2));
          for (final element in find.byType(ChatUrlChip).evaluate()) {
            expect(element.size!.width, lessThanOrEqualTo(220));
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('a reply that arrives', () {
    const table =
        'Antes de la tabla.\n\n'
        '| Modelo | Precio |\n'
        '|---|---|\n'
        '| Uno | 1 |\n'
        '| Dos | 2 |\n'
        '| Tres | 3 |\n';

    testWidgets('the header alone is a frame, not pipes', (tester) async {
      await _pump(tester, 'Antes.\n\n| Modelo | Pre', streaming: true);
      expect(find.byType(ChatTableSkeleton), findsOneWidget);
      expect(find.byType(MarkdownTable), findsNothing);
      for (final text in _drawn(tester)) {
        expect(text, isNot(contains('|')));
      }
    });

    testWidgets('header and separator are already the table, rows grow', (
      tester,
    ) async {
      await _pump(
        tester,
        'Antes.\n\n| Modelo | Precio |\n|---|---|',
        streaming: true,
      );
      expect(find.byType(MarkdownTable), findsOneWidget);
      expect(find.byType(ChatTableSkeleton), findsNothing);
      expect(find.text('Modelo', findRichText: true), findsOneWidget);
      await _pump(
        tester,
        'Antes.\n\n| Modelo | Precio |\n|---|---|\n| Uno | 1 |\n| Do',
        streaming: true,
      );
      expect(find.text('Uno', findRichText: true), findsOneWidget);
      expect(find.text('Do', findRichText: true), findsNothing);
      for (final text in _drawn(tester)) {
        expect(text, isNot(contains('|')));
      }
    });

    testWidgets('the live table keeps its height from the frame to 2 rows', (
      tester,
    ) async {
      double height(String _) =>
          tester.getSize(find.byType(ChatMarkdownBody)).height;

      await _pump(tester, '| Modelo | Precio |', streaming: true);
      final frame = height('');
      await _pump(tester, '| Modelo | Precio |\n|---|---|', streaming: true);
      final header = height('');
      await _pump(
        tester,
        '| Modelo | Precio |\n|---|---|\n| Uno | 1 |\n',
        streaming: true,
      );
      final one = height('');
      await _pump(
        tester,
        '| Modelo | Precio |\n|---|---|\n| Uno | 1 |\n| Dos | 2 |\n',
        streaming: true,
      );
      final two = height('');
      expect((header - frame).abs(), lessThan(8), reason: '$frame $header');
      expect((one - header).abs(), lessThan(8), reason: '$header $one');
      expect((two - one).abs(), lessThan(8), reason: '$one $two');
    });

    testWidgets('the finished table is the one that was growing', (
      tester,
    ) async {
      await _pump(tester, table, streaming: true);
      final live = tester.getSize(find.byType(MarkdownTable));
      await _pump(tester, table);
      expect(find.byType(MarkdownTable), findsOneWidget);
      expect(tester.getSize(find.byType(MarkdownTable)), live);
    });

    testWidgets('sources come as rows once whole, never as «[n] https»', (
      tester,
    ) async {
      for (final data in [
        'Texto.[1]\n\n## Sources\n\n[1] https://efe.com/a/b',
        'Texto.[1]\n\n## Sources\n\n[1] https://efe.com/a/b — EFE: algo',
        'Texto.[1]\n\n## Sources\n\n[1] https://efe.com/a/b — EFE: algo\n[2',
        'Texto.[1]\n\n## Sources\n\n[1] https://efe.com/a/b — EFE: algo\n'
            '[2] https://el',
      ]) {
        await _pump(tester, data, streaming: true);
        for (final text in _drawn(tester)) {
          expect(text, isNot(contains('https://')), reason: data);
          expect(_rawSource.hasMatch(text), isFalse, reason: data);
        }
      }
      await _pump(
        tester,
        'Texto.[1]\n\n## Sources\n\n[1] https://efe.com/a/b — EFE: algo',
        streaming: true,
      );
      expect(find.byType(ChatSourceRow), findsOneWidget);
    });

    testWidgets('a half written link shows only its text', (tester) async {
      for (final data in [
        'Lee [la guía](https://example.com/gu',
        'Mira https://exam',
      ]) {
        await _pump(tester, data, streaming: true);
        for (final text in _drawn(tester)) {
          expect(text, isNot(contains('](')), reason: text);
          expect(text, isNot(contains('https://')), reason: text);
        }
        expect(find.byType(ChatUrlChip), findsNothing);
      }
    });

    testWidgets('growing by pieces never shows the raw structure', (
      tester,
    ) async {
      const full =
          'Mira $_efe ya.[1]\n\n$table\n## Sources\n\n'
          '[1] $_efe — EFE: 31 heridos\n[2] $_pais — El País: la jueza\n';
      for (var n = 40; n <= full.length; n += 7) {
        await _pump(tester, full.substring(0, n), streaming: true);
        for (final text in _drawn(tester)) {
          expect(text, isNot(contains('|')), reason: 'at $n: $text');
          expect(text, isNot(contains('](')), reason: 'at $n: $text');
          expect(text, isNot(contains('https://')), reason: 'at $n: $text');
          expect(_rawSource.hasMatch(text), isFalse, reason: 'at $n');
        }
        expect(tester.takeException(), isNull, reason: 'at $n');
      }
    });
  });
}
