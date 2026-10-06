// pt1215: terminal output cards with ANSI colour (Desktop `ansi-text.tsx`,
// `lib/ansi.ts`, `@hermes/shared/ansi`). Hermes' terminal tool result is
// `{"output": …, "exit_code": …, "error": null}`.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/tool_output.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/ansi_text.dart';
import 'package:hermes_android/core/widgets/chat/tool_output_cards.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _e = '\x1B';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

String _plain(WidgetTester tester, Finder finder) {
  final widget = tester.widget(finder);
  if (widget is RichText) return widget.text.toPlainText();
  return (widget as Text).data ?? widget.textSpan!.toPlainText();
}

void main() {
  group('ANSI parser', () {
    test('keeps SGR colour and bold, drops every other escape', () {
      final segments = parseAnsi(
        '$_e]8;;https://x$_e\\link$_e]8;;$_e\\ '
        '$_e[1;31mERR$_e[0m $_e[2K$_e[32mok$_e[39m done\r',
      );
      expect(segments.map((s) => s.text).join(), 'link ERR ok done');
      final err = segments.firstWhere((s) => s.text == 'ERR');
      expect(err.bold, isTrue);
      expect(err.fg, 1);
      expect(segments.firstWhere((s) => s.text == 'ok').fg, 2);
      expect(segments.last.fg, isNull);
      expect(stripAnsi('$_e[38;5;208morange$_e[0m'), 'orange');
    });

    test('bright colours map to the upper palette', () {
      expect(parseAnsi('$_e[94mblue').single.fg, 12);
    });

    test('every palette slot is a theme colour, in light and dark', () {
      for (final theme in [AppTheme.hermesRedDark, AppTheme.hermesRedLight]) {
        final c = theme.hermes;
        expect(
          [for (var i = 0; i < 8; i++) ansiPaletteColor(i, c)],
          [
            c.textSecondary,
            c.error,
            c.success,
            c.warning,
            c.accent,
            c.secondary,
            Color.lerp(c.accent, c.success, 0.5),
            c.textSecondary,
          ],
        );
        expect(ansiPaletteColor(8, c), c.textTertiary);
        expect(ansiPaletteColor(12, c), c.accent);
        expect(ansiPaletteColor(15, c), c.textPrimary);
        expect(ansiPaletteColor(null, c), isNull);
      }
    });
  });

  group('terminal records', () {
    test('live tool.complete keeps output and exit code', () {
      final record = ToolOutputRecord.fromCompletePayload({
        'tool_id': 't1',
        'name': 'terminal',
        'args': {'command': 'make'},
        'result': {'output': '$_e[31mboom$_e[0m\nend', 'exit_code': 2},
      })!;
      expect(record.hasOutput, isTrue);
      expect(record.exitCode, 2);
      expect(record.output, contains('boom'));
      expect(record.hasDiff, isFalse);
    });

    test('durable rows decode the JSON result; empty output is nothing', () {
      final index = indexDurableToolOutputs([
        {
          'role': 'tool',
          'tool_name': 'terminal',
          'tool_call_id': 't2',
          'content': jsonEncode({'output': 'hello', 'exit_code': 0}),
        },
        {
          'role': 'tool',
          'tool_name': 'terminal',
          'tool_call_id': 't3',
          'content': jsonEncode({'output': '', 'exit_code': 0}),
        },
      ], toolResultsKey: '_activity_tool_results');
      expect(index['t2']!.output, 'hello');
      expect(index['t3'], isNull);
    });
  });

  testWidgets('folded output shows its last lines; tap shows all of it', (
    tester,
  ) async {
    final lines = [for (var i = 1; i <= 10; i++) 'line $i'];
    lines[9] = '$_e[31mline 10$_e[0m';
    await tester.pumpWidget(
      _host(TerminalOutputCard(output: lines.join('\n'), exitCode: 1)),
    );
    final tail = find.descendant(
      of: find.byKey(const ValueKey('terminal-output-tail')),
      matching: find.byType(RichText),
    );
    expect(_plain(tester, tail.first), 'line 7\nline 8\nline 9\nline 10');
    expect(find.text('Show all (10 lines)'), findsOneWidget);
    expect(find.text('exit 1'), findsOneWidget);

    // The red line is painted with the theme's error colour.
    final rich = tester.widget<RichText>(tail.first);
    final colors = AppTheme.hermesRedDark.hermes;
    final red = <Color?>[];
    rich.text.visitChildren((span) {
      if (span is TextSpan && span.text == 'line 10') {
        red.add(span.style?.color);
      }
      return true;
    });
    expect(red, [colors.error]);

    await tester.tap(find.byKey(const ValueKey('terminal-output-row')));
    await tester.pump();
    final full = find.descendant(
      of: find.byKey(const ValueKey('terminal-output-full')),
      matching: find.byType(RichText),
    );
    expect(_plain(tester, full.first), startsWith('line 1\nline 2'));
    expect(find.text('Output'), findsOneWidget);
  });

  group('tail keeps the ANSI state set before its first line', () {
    Map<String, ({Color? color, bool bold})> styles(TextSpan root) {
      final out = <String, ({Color? color, bool bold})>{};
      void visit(InlineSpan span, TextStyle inherited) {
        if (span is! TextSpan) return;
        final style = inherited.merge(span.style);
        final text = span.text;
        if (text != null) {
          for (final line in text.split('\n')) {
            if (line.isEmpty) continue;
            out[line] = (
              color: style.color,
              bold: style.fontWeight == FontWeight.w700,
            );
          }
        }
        for (final child in span.children ?? const <InlineSpan>[]) {
          visit(child, style);
        }
      }

      visit(root, const TextStyle());
      return out;
    }

    Future<Map<String, ({Color? color, bool bold})>> foldedTail(
      WidgetTester tester,
      String output,
    ) async {
      await tester.pumpWidget(_host(TerminalOutputCard(output: output)));
      final tail = find.descendant(
        of: find.byKey(const ValueKey('terminal-output-tail')),
        matching: find.byType(RichText),
      );
      return styles(tester.widget<RichText>(tail.first).text as TextSpan);
    }

    testWidgets('a colour opened above the tail still paints it', (
      tester,
    ) async {
      final colors = AppTheme.hermesRedDark.hermes;
      final shown = await foldedTail(
        tester,
        '$_e[1;31mFAIL a\nFAIL b\nFAIL c\nFAIL d\nFAIL e\nFAIL f$_e[0m',
      );
      expect(shown.keys, ['FAIL c', 'FAIL d', 'FAIL e', 'FAIL f']);
      for (final style in shown.values) {
        expect(style.color, colors.error);
        expect(style.bold, isTrue);
      }
    });

    final colors = AppTheme.hermesRedDark.hermes;
    for (final (name, output, color, bold) in [
      (
        'latest of each attribute (both in one sequence)',
        '$_e[1m$_e[31mx\n$_e[32;22my\nz\na\nb\nc',
        colors.success,
        false,
      ),
      (
        'an older bold does not override a newer reset of it',
        '$_e[31mr\n$_e[1mx\n$_e[22my\nz\na\nb\nc',
        colors.error,
        false,
      ),
      (
        'an older colour does not override a newer one',
        '$_e[1mx\n$_e[31my\n$_e[32mw\nz\na\nb\nc',
        colors.success,
        true,
      ),
    ]) {
      testWidgets('only the latest carries over: $name', (tester) async {
        final shown = await foldedTail(tester, output);
        expect(shown.keys, ['z', 'a', 'b', 'c']);
        for (final style in shown.values) {
          expect(style.color, color);
          expect(style.bold, bold);
        }
      });
    }

    testWidgets('a reset above the tail leaves it plain', (tester) async {
      final shown = await foldedTail(
        tester,
        '$_e[31mred$_e[0m\nplain 1\nplain 2\nplain 3\nplain 4',
      );
      expect(shown.keys, ['plain 1', 'plain 2', 'plain 3', 'plain 4']);
      for (final style in shown.values) {
        expect(style.color, AppTheme.hermesRedDark.hermes.textSecondary);
        expect(style.bold, isFalse);
      }
    });
  });

  group('an output ending in a newline has no extra blank line', () {
    // Real commands end their output with '\n' (or '\r\n'); the line it
    // closes is not one more line to count, fold or show.
    String lines(int n, String eol) =>
        [for (var i = 1; i <= n; i++) 'line $i$eol'].join();

    Future<void> pumpRecord(WidgetTester tester, ToolOutputRecord? record) =>
        tester.pumpWidget(_host(toolOutputCard(record)!));

    String tailText(WidgetTester tester) => _plain(
      tester,
      find
          .descendant(
            of: find.byKey(const ValueKey('terminal-output-tail')),
            matching: find.byType(RichText),
          )
          .first,
    );

    for (final eol in ['\n', '\r\n']) {
      final name = eol == '\n' ? 'LF' : 'CRLF';

      testWidgets('live, folded: $name', (tester) async {
        await pumpRecord(
          tester,
          ToolOutputRecord.fromCompletePayload({
            'tool_id': 't1',
            'name': 'terminal',
            'args': {'command': 'seq'},
            'result': {'output': lines(10, eol), 'exit_code': 0},
          }),
        );
        expect(tailText(tester), 'line 7\nline 8\nline 9\nline 10');
        expect(find.text('Show all (10 lines)'), findsOneWidget);
      });

      testWidgets('durable, exactly the preview: $name', (tester) async {
        final index = indexDurableToolOutputs([
          {
            'role': 'tool',
            'tool_name': 'terminal',
            'tool_call_id': 't2',
            'content': jsonEncode({
              'output': lines(terminalPreviewLines, eol),
              'exit_code': 0,
            }),
          },
        ], toolResultsKey: '_activity_tool_results');
        await pumpRecord(tester, index['t2']);
        expect(tailText(tester), 'line 1\nline 2\nline 3\nline 4');
        expect(find.text('Output'), findsOneWidget);
        expect(find.byIcon(Icons.expand_more), findsNothing);
      });
    }
  });

  testWidgets('short output has nothing to unfold', (tester) async {
    await tester.pumpWidget(_host(const TerminalOutputCard(output: 'a\nb')));
    expect(find.text('Output'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsNothing);
    expect(find.text('exit 0'), findsNothing);
  });
}
