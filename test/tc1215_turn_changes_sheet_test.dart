// tc1215: review every file a turn changed in one surface (idea from
// Hermex's per-turn «files changed» review; reimplemented, no code reused).
// Data: the turn's finished file-edit tool outputs (patch / write_file /
// edit_file diffs), aggregated per path.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/tool_output.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/unified_diff.dart';
import 'package:hermes_android/core/widgets/chat/tool_output_cards.dart';
import 'package:hermes_android/core/widgets/chat/turn_changes_sheet.dart';
import 'package:hermes_android/core/widgets/projects/project_file_icons.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

ToolOutputRecord _edit(String id, String path, String diff) =>
    ToolOutputRecord(toolId: id, name: 'patch', files: [FileDiff(path, diff)]);

Widget _host(Widget child, {Locale locale = const Locale('es')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: MediaQuery(
    data: const MediaQueryData(size: Size(800, 600), disableAnimations: true),
    child: Scaffold(body: Center(child: child)),
  ),
);

const _known =
    '@@ -10,3 +10,4 @@\n'
    ' keep\n'
    '-final a = 1;\n'
    '+final a = 2;\n'
    '+added();\n'
    ' tail';

List<FileDiff> _threeFiles() => aggregateChangedFiles([
  _edit('1', 'lib/a.dart', _known),
  _edit('2', 'README.md', '@@ -1 +1 @@\n-x\n+y'),
  _edit('3', 'lib/a.dart', '@@ -40,2 +41,2 @@\n-old\n+new\n ctx'),
  _edit('4', 'tool/run.sh', '@@ -0,0 +1,2 @@\n+#!/bin/sh\n+echo'),
]);

Future<void> _openSheet(WidgetTester tester, List<FileDiff> files) async {
  await tester.pumpWidget(_host(TurnChangesChip(files: files)));
  await tester.tap(find.byKey(const ValueKey('turn-changes-chip')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.byKey(const ValueKey('turn-changes-sheet')), findsOneWidget);
}

Color? _rowColor(WidgetTester tester, String key) =>
    tester.widget<ColoredBox>(find.byKey(ValueKey(key))).color;

void main() {
  group('aggregation', () {
    test('two edits of one file merge in order; three files; totals', () {
      final files = _threeFiles();
      expect(files.map((f) => f.path), [
        'lib/a.dart',
        'README.md',
        'tool/run.sh',
      ]);
      final a = files.first;
      expect(a.diff.indexOf('final a = 2;'), lessThan(a.diff.indexOf('+new')));
      expect(a.stats.added, 3);
      expect(a.stats.removed, 2);
      final totals = turnChangeTotals(files);
      expect(totals.added, 6);
      expect(totals.removed, 3);
    });

    test('an identical edit reported twice counts once', () {
      final files = aggregateChangedFiles([
        _edit('1', 'a.txt', '@@ -1 +1 @@\n-x\n+y'),
        _edit('1', 'a.txt', '@@ -1 +1 @@\n-x\n+y'),
        _edit('2', 'a.txt', '@@ -1 +1 @@\n-x\n+y'),
      ]);
      expect(files, hasLength(1));
      expect(files.single.stats.added, 1);
      expect(files.single.stats.removed, 1);
    });
  });

  group('numbered lines', () {
    test('gutter: new numbers, removed lines keep their old number', () {
      final lines = numberDiffLines(_known);
      expect(lines.map((l) => l.kind), [
        DiffLineKind.hunk,
        DiffLineKind.context,
        DiffLineKind.remove,
        DiffLineKind.add,
        DiffLineKind.add,
        DiffLineKind.context,
      ]);
      expect(lines.map((l) => l.gutter), [null, 10, 11, 11, 12, 13]);
      expect(lines[1].text, 'keep');
      expect(lines[2].text, 'final a = 1;');
      expect(lines.first.hunkStart, 10);
      expect(lines.first.hunkEnd, 13);
    });

    test('paired -/+ lines mark only the changed span', () {
      final lines = numberDiffLines(_known);
      expect(lines[2].change, (start: 10, end: 11));
      expect(lines[3].change, (start: 10, end: 11));
      // The unpaired add and context lines carry no highlight.
      expect(lines[4].change, isNull);
      expect(lines[1].change, isNull);
    });

    test('lines with nothing in common are not highlighted', () {
      final lines = numberDiffLines('@@ -1 +1 @@\n-abc\n+xyz');
      expect(lines[1].change, isNull);
      expect(lines[2].change, isNull);
    });
  });

  group('chip', () {
    testWidgets('hidden without file changes', (tester) async {
      await tester.pumpWidget(_host(const TurnChangesChip(files: [])));
      expect(find.byKey(const ValueKey('turn-changes-chip')), findsNothing);
    });

    testWidgets('one compact line: files and totals', (tester) async {
      await tester.pumpWidget(_host(TurnChangesChip(files: _threeFiles())));
      expect(find.text('Δ 3 archivos · +6 −3'), findsOneWidget);
    });

    testWidgets('English', (tester) async {
      await tester.pumpWidget(
        _host(
          TurnChangesChip(files: _threeFiles()),
          locale: const Locale('en'),
        ),
      );
      expect(find.text('Δ 3 files · +6 −3'), findsOneWidget);
    });
  });

  group('sheet', () {
    testWidgets('title, per-file headers with icon and counts, Done', (
      tester,
    ) async {
      await _openSheet(tester, _threeFiles());
      expect(find.text('3 archivos cambiados'), findsOneWidget);
      final header = find.byKey(const ValueKey('turn-changes-file-0'));
      expect(
        find.descendant(of: header, matching: find.text('lib/a.dart')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: header, matching: find.text('+3 −2')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: header,
          matching: find.byIcon(projectFileIcon('a.dart')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('turn-changes-file-1')),
          matching: find.text('+1 −1'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('turn-changes-done')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('turn-changes-sheet')), findsNothing);
    });

    testWidgets('hunk band, gutter, colours and intra-line highlight', (
      tester,
    ) async {
      await _openSheet(tester, [FileDiff('lib/a.dart', _known)]);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('turn-changes-hunk-0-0')),
          matching: find.text('Líneas 10–13'),
        ),
        findsOneWidget,
      );
      final gutters = [
        for (var j = 1; j <= 5; j++)
          tester
              .widget<Text>(find.byKey(ValueKey('turn-changes-gutter-0-$j')))
              .data,
      ];
      expect(gutters, ['10', '11', '11', '12', '13']);

      final colors = AppTheme.hermesRedDark.hermes;
      expect(
        _rowColor(tester, 'turn-changes-line-0-2'),
        colors.error.withValues(alpha: 0.12),
      );
      expect(
        _rowColor(tester, 'turn-changes-line-0-3'),
        colors.success.withValues(alpha: 0.12),
      );
      expect(_rowColor(tester, 'turn-changes-line-0-1'), Colors.transparent);

      List<String> highlighted(String key) {
        final rich = tester.widget<RichText>(
          find
              .descendant(
                of: find.byKey(ValueKey(key)),
                matching: find.byType(RichText),
              )
              .last,
        );
        final out = <String>[];
        rich.text.visitChildren((span) {
          if (span is TextSpan &&
              span.style?.backgroundColor != null &&
              span.text != null) {
            out.add(span.text!);
          }
          return true;
        });
        return out;
      }

      expect(highlighted('turn-changes-line-0-2'), ['1']);
      expect(highlighted('turn-changes-line-0-3'), ['2']);
      expect(highlighted('turn-changes-line-0-4'), isEmpty);
    });

    testWidgets('a single-line hunk says «Línea»', (tester) async {
      await _openSheet(tester, [FileDiff('x', '@@ -3 +3 @@\n-a\n+b')]);
      expect(find.text('Línea 3'), findsOneWidget);
    });

    testWidgets('viewed collapses the file; the header folds too', (
      tester,
    ) async {
      await _openSheet(tester, _threeFiles());
      expect(find.byKey(const ValueKey('turn-changes-line-0-2')), findsOne);
      await tester.tap(find.byKey(const ValueKey('turn-changes-viewed-0')));
      await tester.pump();
      expect(find.byKey(const ValueKey('turn-changes-line-0-2')), findsNothing);
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const ValueKey('turn-changes-viewed-0')),
            )
            .value,
        isTrue,
      );
      // Other files stay open.
      expect(find.byKey(const ValueKey('turn-changes-line-1-1')), findsOne);
      // Tapping the header reopens it; it stays marked as viewed.
      await tester.tap(find.byKey(const ValueKey('turn-changes-file-0')));
      await tester.pump();
      expect(find.byKey(const ValueKey('turn-changes-line-0-2')), findsOne);
    });

    testWidgets('a 5,000-line diff builds only the rows on screen', (
      tester,
    ) async {
      final body = StringBuffer('@@ -1,0 +1,5000 @@');
      for (var i = 0; i < 5000; i++) {
        body.write('\n+line $i');
      }
      await _openSheet(tester, [FileDiff('big.txt', body.toString())]);
      final built = find.byWidgetPredicate((w) {
        final key = w.key;
        return key is ValueKey<String> &&
            key.value.startsWith('turn-changes-line-0-');
      }, skipOffstage: false);
      expect(built.evaluate().length, inInclusiveRange(10, 120));

      await tester.drag(
        find.byKey(const ValueKey('turn-changes-list')),
        const Offset(0, -20000),
      );
      await tester.pump();
      expect(built.evaluate().length, inInclusiveRange(10, 120));
      expect(find.byKey(const ValueKey('turn-changes-line-0-1')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
