// pt1215: tool output cards stay cheap in a long chat. A folded card costs
// the same whatever the size of its diff or output, nothing heavy is built
// until the user unfolds it, and scrolling never rebuilds a card that only
// moved. Rebuilds are counted with the framework's own debug hook, and the
// input scanned by the card derivations (diff parse/stats, terminal line
// count and tail) with DebugToolCardWork, so the bound is on work, not only
// on widgets.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/unified_diff.dart';
import 'package:hermes_android/core/widgets/chat/tool_output_cards.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: Scaffold(body: child),
  ),
);

String _diff(int lines) {
  final out = StringBuffer('@@ -1,$lines +1,$lines @@\n');
  for (var i = 0; i < lines; i++) {
    out.writeln(i.isEven ? '+added line $i' : '-removed line $i');
  }
  return out.toString().trim();
}

String _output(int lines) => [
  for (var i = 0; i < lines; i++) '\x1B[3${i % 8}mline $i\x1B[0m',
].join('\n');

Column _card(int lines) => Column(
  mainAxisSize: MainAxisSize.min,
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    FileDiffCard(file: FileDiff('lib/big.dart', _diff(lines))),
    TerminalOutputCard(output: _output(lines), exitCode: 0),
  ],
);

int _elementsUnder(WidgetTester tester, Finder finder) {
  var count = 0;
  void visit(Element element) {
    count++;
    element.visitChildren(visit);
  }

  tester.element(finder).visitChildren(visit);
  return count;
}

/// Longest text laid out by any paragraph under [finder].
int _longestParagraph(WidgetTester tester, Finder finder) {
  var longest = 0;
  for (final paragraph in tester.renderObjectList<RenderParagraph>(
    find.descendant(of: finder, matching: find.byType(RichText)),
  )) {
    final length = paragraph.text.toPlainText().length;
    if (length > longest) longest = length;
  }
  return longest;
}

void main() {
  testWidgets('a folded card costs the same for 10 or 5000 lines', (
    tester,
  ) async {
    await tester.pumpWidget(_host(SingleChildScrollView(child: _card(10))));
    final small = _elementsUnder(tester, find.byType(Column).first);
    await tester.pumpWidget(_host(const SizedBox()));
    await tester.pumpWidget(_host(SingleChildScrollView(child: _card(5000))));
    final big = _elementsUnder(tester, find.byType(Column).first);
    expect(big, small);
    expect(find.byType(FileDiffBody), findsNothing);
    // Folded: the summary row and a 4-line terminal tail, never the body.
    expect(find.text('+2500 −2500 · big.dart'), findsOneWidget);
    expect(
      _longestParagraph(tester, find.byType(TerminalOutputCard)),
      lessThan(200),
    );
  });

  testWidgets('a folded card scans its payload once, then never again', (
    tester,
  ) async {
    final card = _card(5000);
    final output = (card.children.last as TerminalOutputCard).output;
    DebugToolCardWork.reset();
    await tester.pumpWidget(_host(SingleChildScrollView(child: card)));
    // Folded: no diff parse; one newline count and a tail read from the end.
    expect(DebugToolCardWork.bytes['diff.parse'], isNull);
    expect(DebugToolCardWork.bytes['terminal.lines'], output.length);
    expect(DebugToolCardWork.bytes['terminal.tail'], lessThan(200));
    // Remounting the same payload (a row scrolled back in) scans nothing.
    for (var i = 0; i < 3; i++) {
      await tester.pumpWidget(_host(const SizedBox()));
      DebugToolCardWork.reset();
      await tester.pumpWidget(_host(SingleChildScrollView(child: card)));
      expect(DebugToolCardWork.bytes, isEmpty);
    }
    // The memo is bounded: after many other outputs it is scanned again.
    for (var i = 0; i < 64; i++) {
      await tester.pumpWidget(
        _host(TerminalOutputCard(output: 'other $i\nline', exitCode: 0)),
      );
    }
    DebugToolCardWork.reset();
    await tester.pumpWidget(_host(SingleChildScrollView(child: card)));
    expect(DebugToolCardWork.bytes['terminal.lines'], output.length);
  });

  testWidgets('a 5000-line diff builds one page of lines when unfolded', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        SingleChildScrollView(
          child: FileDiffCard(file: FileDiff('lib/big.dart', _diff(5000))),
        ),
      ),
    );
    expect(find.byType(FileDiffBody), findsNothing);
    await tester.tap(find.byType(FileDiffCard));
    await tester.pump();
    final body = find.byType(FileDiffBody);
    expect(body, findsOneWidget);
    final lines = find.descendant(of: body, matching: find.byType(Text));
    // One page plus the «show more» label.
    expect(lines.evaluate().length, lessThanOrEqualTo(fileDiffPageLines + 1));
    expect(find.text('+added line 0'), findsOneWidget);
    expect(find.text('-removed line 4999'), findsNothing);
  });

  testWidgets('unfolded terminal output stays tail-capped', (tester) async {
    await tester.pumpWidget(
      _host(
        SingleChildScrollView(
          child: TerminalOutputCard(output: _output(5000), exitCode: 0),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('terminal-output-row')));
    await tester.pump();
    final full = find.byKey(const ValueKey('terminal-output-full'));
    final shown = tester
        .renderObjectList<RenderParagraph>(
          find.descendant(of: full, matching: find.byType(RichText)),
        )
        .single
        .text
        .toPlainText();
    expect('\n'.allMatches(shown).length, terminalMaxLines - 1);
    expect(shown, endsWith('line 4999'));
  });

  testWidgets('scrolling a chat of 5000-line cards rebuilds no moved card', (
    tester,
  ) async {
    final rebuilt = <Type, int>{};
    final previous = debugOnRebuildDirtyWidget;
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (!builtOnce) return;
      final type = element.widget.runtimeType;
      rebuilt[type] = (rebuilt[type] ?? 0) + 1;
    };
    final cards = [for (var i = 0; i < 4; i++) _card(5000)];
    await tester.pumpWidget(
      _host(
        ListView.builder(
          addAutomaticKeepAlives: false,
          itemCount: 120,
          itemBuilder: (context, index) => Padding(
            key: ValueKey(index),
            padding: const EdgeInsets.only(bottom: 24),
            child: cards[index % cards.length],
          ),
        ),
      ),
    );
    rebuilt.clear();
    DebugToolCardWork.reset();
    // Small steps: rows only move, so no card may rebuild.
    for (var i = 0; i < 10; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -6));
      await tester.pump();
    }
    expect(
      rebuilt.keys.where(
        (type) =>
            type == FileDiffCard ||
            type == TerminalOutputCard ||
            type == AnsiTextView ||
            type == FileDiffBody,
      ),
      isEmpty,
    );
    // A long fling builds rows as they enter, but never a diff body.
    await tester.fling(find.byType(ListView), const Offset(0, -6000), 4000);
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(FileDiffBody), findsNothing);
      expect(_longestParagraph(tester, find.byType(ListView)), lessThan(200));
    }
    // Rows that enter are payloads already seen: no input is scanned again,
    // so a long output costs nothing per row however far the list scrolls.
    expect(DebugToolCardWork.bytes, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
