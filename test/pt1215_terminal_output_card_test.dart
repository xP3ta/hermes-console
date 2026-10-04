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
        expect(ansiPaletteColor(8, c), c.textDisabled);
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

  testWidgets('short output has nothing to unfold', (tester) async {
    await tester.pumpWidget(_host(const TerminalOutputCard(output: 'a\nb')));
    expect(find.text('Output'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsNothing);
    expect(find.text('exit 0'), findsNothing);
  });
}
