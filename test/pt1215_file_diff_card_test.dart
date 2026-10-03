// pt1215: file-edit diff tool cards (Desktop `tool/fallback.tsx`
// FileDiffPanel + `countDiffLineStats`). Wire shapes copy Hermes
// `tui_gateway/tool_progress.py` (`inline_diff` = CLI-rendered diff with the
// `┊ review diff` header and ANSI colour) and `tools/file_operations.py`
// (`patch` result carries its own `diff`).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/tool_output.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/unified_diff.dart';
import 'package:hermes_android/core/widgets/chat/tool_output_cards.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _e = '\x1B';
const _inlineDiff =
    '┊ review diff\n'
    '$_e[38;2;180;180;255ma/lib/foo.dart → b/lib/foo.dart$_e[0m\n'
    '$_e[38;2;120;120;120m@@ -1,3 +1,4 @@$_e[0m\n'
    '$_e[2m keep$_e[0m\n'
    '$_e[38;2;255;255;255;48;2;120;20;20m-old line$_e[0m\n'
    '$_e[38;2;255;255;255;48;2;20;90;20m+new line$_e[0m\n'
    '$_e[38;2;255;255;255;48;2;20;90;20m+another$_e[0m';

Map<String, dynamic> _complete({
  String id = 'call-1',
  String name = 'patch',
  String? inlineDiff = _inlineDiff,
  Object? result = const {'success': true},
}) => {
  'tool_id': id,
  'name': name,
  'args': {'path': 'lib/foo.dart'},
  'inline_diff': ?inlineDiff,
  'result': result,
};

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

void main() {
  group('inline diff model', () {
    test('cleans the CLI rendering and counts +/- like Desktop', () {
      final record = ToolOutputRecord.fromCompletePayload(_complete())!;
      expect(record.files, hasLength(1));
      final file = record.files.single;
      expect(file.path, 'lib/foo.dart');
      expect(file.name, 'foo.dart');
      expect(file.stats.added, 2);
      expect(file.stats.removed, 1);
      expect(file.diff, isNot(contains(_e)));
      expect(file.diff, isNot(contains('review diff')));
      final lines = parseDiffLines(file.diff);
      expect(lines.first.kind, DiffLineKind.hunk);
      expect(lines.where((l) => l.kind == DiffLineKind.add), hasLength(2));
    });

    test('splits a multi-file patch into one section per file', () {
      const diff =
          '--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-x\n+y\n'
          '--- a/dir/b.txt\n+++ b/dir/b.txt\n@@ -0,0 +1,2 @@\n+1\n+2\n';
      final files = splitFileDiffs(diff);
      expect(files.map((f) => f.path), ['a.txt', 'dir/b.txt']);
      expect(files.last.stats.added, 2);
      expect(files.last.stats.removed, 0);
    });

    test('durable patch rows reuse the result diff; failures show none', () {
      final row = {
        'role': 'tool',
        'tool_name': 'patch',
        'tool_call_id': 'call-9',
        'content': jsonEncode({
          'success': true,
          'diff': '--- a/x.py\n+++ b/x.py\n@@ -1 +1 @@\n-a\n+b\n',
        }),
      };
      final index = indexDurableToolOutputs([
        {
          'role': 'assistant',
          '_activity_tool_results': [row],
        },
      ], toolResultsKey: '_activity_tool_results');
      expect(index['call-9']!.files.single.path, 'x.py');

      final failed = ToolOutputRecord.fromCompletePayload(
        _complete(result: {'success': false, 'error': 'no match'}),
      );
      expect(failed, isNull);
      // No diff on the wire → nothing (no dead card).
      expect(
        ToolOutputRecord.fromCompletePayload(_complete(inlineDiff: null)),
        isNull,
      );
    });

    test('the ledger keys by tool id and stays bounded', () {
      final ledger = ToolOutputLedger(capacity: 2);
      for (final id in ['a', 'b', 'c']) {
        ledger.recordComplete(_complete(id: id));
      }
      expect(ledger['a'], isNull);
      expect(ledger['c'], isNotNull);
      ledger.recordComplete({'tool_id': 'd', 'name': 'read_file'});
      expect(ledger['d'], isNull);
    });
  });

  testWidgets('a diff card is folded to name and counts; tap unfolds it', (
    tester,
  ) async {
    final file = ToolOutputRecord.fromCompletePayload(
      _complete(),
    )!.files.single;
    await tester.pumpWidget(_host(FileDiffCard(file: file)));
    expect(find.text('foo.dart'), findsOneWidget);
    expect(find.text('+2'), findsOneWidget);
    expect(find.text('−1'), findsOneWidget);
    expect(find.byType(FileDiffBody), findsNothing);

    await tester.tap(find.text('foo.dart'));
    await tester.pump();
    expect(find.byType(FileDiffBody), findsOneWidget);
    expect(find.text('+new line'), findsOneWidget);
    expect(find.text('-old line'), findsOneWidget);
    expect(find.text(' keep'), findsOneWidget);
  });

  testWidgets('long diffs cap their lines behind «show more»', (tester) async {
    final body = StringBuffer('@@ -1,0 +1,200 @@\n');
    for (var i = 0; i < 200; i++) {
      body.writeln('+line $i');
    }
    final file = FileDiff('big.txt', body.toString().trim());
    await tester.pumpWidget(
      _host(SingleChildScrollView(child: FileDiffCard(file: file))),
    );
    await tester.tap(find.text('big.txt'));
    await tester.pump();
    expect(find.text('+line ${fileDiffPageLines - 2}'), findsOneWidget);
    expect(find.text('+line 150'), findsNothing);
    final remaining = 201 - fileDiffPageLines;
    expect(find.text('Show $remaining more lines'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('file-diff-show-more')),
    );
    await tester.tap(find.byKey(const ValueKey('file-diff-show-more')));
    await tester.pump();
    expect(find.text('+line 150'), findsOneWidget);
    expect(find.byKey(const ValueKey('file-diff-show-more')), findsNothing);
  });

  testWidgets('scroll guard: 50 diff cards build no diff body until opened', (
    tester,
  ) async {
    final record = ToolOutputRecord.fromCompletePayload(_complete())!;
    await tester.pumpWidget(
      _host(
        ListView.builder(
          itemCount: 50,
          itemBuilder: (context, index) => FileDiffCard(
            key: ValueKey(index),
            file: FileDiff('f$index.dart', record.files.single.diff),
          ),
        ),
      ),
    );
    expect(find.byType(FileDiffCard), findsWidgets);
    expect(find.byType(FileDiffBody), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pump();
    expect(find.byType(FileDiffBody), findsNothing);
    await tester.tap(find.byType(FileDiffCard).hitTestable().first);
    await tester.pump();
    expect(find.byType(FileDiffBody), findsOneWidget);
  });

  testWidgets('the unfolded trace shows the diff under its step only', (
    tester,
  ) async {
    final record = ToolOutputRecord.fromCompletePayload(_complete())!;
    await tester.pumpWidget(
      _host(
        SingleChildScrollView(
          child: ThinkingTraceCard(
            events: [
              ChatTraceEvent(
                id: 'call-1',
                label: 'patch',
                status: 'completed',
                output: record,
              ),
              ChatTraceEvent(
                id: 'call-2',
                label: 'read_file',
                status: 'completed',
              ),
            ],
            active: false,
          ),
        ),
      ),
    );
    expect(find.byType(FileDiffCard), findsNothing);
    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();
    expect(find.byType(FileDiffCard), findsOneWidget);
    expect(find.byType(FileDiffBody), findsNothing);
  });
}
