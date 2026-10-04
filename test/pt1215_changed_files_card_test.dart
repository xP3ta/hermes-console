// pt1215: «N files changed» per turn (Desktop `thread/changed-files.ts`
// `deriveChangedFiles`, `changed-files-card.tsx`).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/tool_output.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/unified_diff.dart';
import 'package:hermes_android/core/widgets/chat/tool_output_cards.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

ToolOutputRecord _edit(String id, String path, String diff) =>
    ToolOutputRecord(toolId: id, name: 'patch', files: [FileDiff(path, diff)]);

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  test('one row per file, first-touched order, edits summed', () {
    final files = aggregateChangedFiles([
      _edit('1', 'b.txt', '@@ -1 +1 @@\n-x\n+y'),
      null,
      const ToolOutputRecord(toolId: 't', name: 'terminal', output: 'ok'),
      _edit('2', 'a.txt', '@@ -0,0 +1 @@\n+new'),
      _edit('3', 'b.txt', '@@ -4 +4,2 @@\n-p\n+q\n+r'),
    ]);
    expect(files.map((f) => f.path), ['b.txt', 'a.txt']);
    expect(files.first.stats.added, 3);
    expect(files.first.stats.removed, 2);
  });

  testWidgets('nothing changed, nothing shown', (tester) async {
    await tester.pumpWidget(_host(const ChangedFilesCard(files: [])));
    expect(find.byKey(const ValueKey('changed-files-card')), findsNothing);
  });

  testWidgets('scroll guard: 50 files stay one row until unfolded', (
    tester,
  ) async {
    final files = [
      for (var i = 0; i < 50; i++) FileDiff('f$i.dart', '@@ -1 +1 @@\n-a\n+b'),
    ];
    await tester.pumpWidget(_host(ChangedFilesCard(files: files)));
    expect(find.text('50 archivos cambiados'), findsOneWidget);
    expect(find.text('+50 −50'), findsOneWidget);
    expect(find.byType(FileDiffCard), findsNothing);

    await tester.tap(find.byKey(const ValueKey('changed-files-row')));
    await tester.pump();
    expect(find.byType(FileDiffCard, skipOffstage: false), findsNWidgets(50));
    expect(find.byType(FileDiffBody, skipOffstage: false), findsNothing);
  });
}
