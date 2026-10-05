import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_viewer_screen.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  final theme = AppTheme.fromMode(AppThemeMode.dark);

  Widget host(String name, String body) => MaterialApp(
    theme: theme,
    locale: const Locale('es'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: ArtifactViewerScreen(
      name: name,
      mimeType: 'text/plain',
      loadBytes: () async => Uint8List.fromList(utf8.encode(body)),
    ),
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Finder gutter(int i) => find.byKey(ValueKey('artifact-viewer-gutter-$i'));
  Finder line(int i) => find.byKey(ValueKey('artifact-viewer-line-$i'));

  void expectRow(WidgetTester tester, int i) {
    expect(tester.widget<Text>(gutter(i)).data, '${i + 1}');
    expect(
      tester.getTopLeft(gutter(i)).dy,
      tester.getTopLeft(line(i)).dy,
      reason: 'number ${i + 1} sits on the row of line $i',
    );
  }

  testWidgets('every line shows its number in a muted mono gutter', (
    tester,
  ) async {
    final body = [for (var i = 0; i < 12; i++) 'row ${'abc' * i}'].join('\n');
    await tester.pumpWidget(host('notes.txt', body));
    await settle(tester);

    for (var i = 0; i < 12; i++) {
      expectRow(tester, i);
    }
    final number = tester.widget<Text>(gutter(9));
    expect(number.style?.fontFamily, 'monospace');
    expect(number.style?.color, theme.hermes.textDisabled);
    // Fixed width: one- and two-digit numbers end at the same x.
    expect(tester.getTopRight(gutter(0)).dx, tester.getTopRight(gutter(11)).dx);
    // Text columns line up regardless of the number's width.
    expect(tester.getTopLeft(line(0)).dx, tester.getTopLeft(line(11)).dx);
  });

  testWidgets('selecting and copying the text excludes line numbers', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
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
    await tester.pumpWidget(host('words.txt', 'alpha\nbeta\ngamma'));
    await settle(tester);

    final region = tester.state<SelectableRegionState>(
      find.byType(SelectableRegion),
    );
    region.selectAll();
    // ignore: deprecated_member_use
    region.copySelection(SelectionChangedCause.keyboard);
    await settle(tester);
    expect(copied, isNotNull);
    expect(copied, contains('alpha'));
    expect(copied, contains('gamma'));
    expect(copied, isNot(matches(RegExp(r'\d'))));
  });

  testWidgets('search jump lands on the numbered row of the match', (
    tester,
  ) async {
    final log = [
      for (var i = 0; i < 400; i++)
        i % 100 == 7 ? 'linea ERROR fallo' : 'linea ok',
    ].join('\n');
    await tester.pumpWidget(host('server.log', log));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('artifact-viewer-search')));
    await settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('artifact-viewer-search-field')),
      'error',
    );
    await settle(tester);
    for (var step = 0; step < 2; step++) {
      await tester.tap(
        find.byKey(const ValueKey('artifact-viewer-search-next')),
      );
      await settle(tester);
    }
    // Third match: line index 207, number 208, on screen and aligned.
    expect(line(207), findsOneWidget);
    expectRow(tester, 207);
    expect(
      tester.widget<Text>(line(207)).textSpan!.toPlainText(),
      'linea ERROR fallo',
    );
  });

  testWidgets('a very long file builds only the visible numbered rows', (
    tester,
  ) async {
    final big = List.filled(100000, 'row').join('\n');
    await tester.pumpWidget(host('huge.txt', big));
    await settle(tester);

    final built = find.byWidgetPredicate((w) {
      final key = w.key;
      return key is ValueKey<String> &&
          key.value.startsWith('artifact-viewer-gutter-');
    });
    expect(built.evaluate().length, inInclusiveRange(1, 200));
    expect(gutter(99999), findsNothing);
    expectRow(tester, 0);

    // The six-digit last number fits the gutter without overflow.
    final list = tester.widget<ListView>(
      find.byKey(const ValueKey('artifact-viewer-text')),
    );
    list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expectRow(tester, 99999);
    expect(
      tester.getTopRight(gutter(99999)).dx,
      lessThanOrEqualTo(tester.getTopLeft(line(99999)).dx),
    );
  });
}
