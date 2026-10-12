import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
    expect(number.style?.color, theme.hermes.textTertiary);
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

  /// Natural (unclipped) width of a gutter number versus its laid-out box.
  void expectNumberFits(WidgetTester tester, int i) {
    final paragraph = tester.renderObject<RenderParagraph>(gutter(i));
    final painter = TextPainter(
      text: paragraph.text,
      textDirection: paragraph.textDirection,
      textScaler: paragraph.textScaler,
      strutStyle: paragraph.strutStyle,
      maxLines: 1,
    )..layout();
    final natural = painter.width;
    painter.dispose();
    expect(
      natural,
      lessThanOrEqualTo(paragraph.size.width),
      reason: 'number ${i + 1} is not clipped by the gutter',
    );
    expect(
      tester.getTopRight(gutter(i)).dx + natural - paragraph.size.width,
      lessThanOrEqualTo(tester.getTopLeft(line(i)).dx),
      reason: 'number ${i + 1} does not overlap the code text',
    );
    expect(
      tester.getTopLeft(line(i)).dx,
      greaterThanOrEqualTo(tester.getTopRight(gutter(i)).dx),
      reason: 'code text of line $i starts right of the gutter',
    );
  }

  Future<void> jumpToLine(WidgetTester tester, int index) async {
    final list = tester.widget<ListView>(
      find.byKey(const ValueKey('artifact-viewer-text')),
    );
    final position = list.controller!.position;
    final target = (index * list.itemExtent!).clamp(
      0.0,
      position.maxScrollExtent,
    );
    list.controller!.jumpTo(target);
    await settle(tester);
  }

  testWidgets('a 12-line file sizes the gutter for the two-digit numbers', (
    tester,
  ) async {
    final body = [for (var i = 0; i < 12; i++) 'code $i'].join('\n');
    await tester.pumpWidget(host('twelve.txt', body));
    await settle(tester);

    for (final i in [0, 8, 9, 11]) {
      expectRow(tester, i);
      expectNumberFits(tester, i);
    }
    expect(tester.getSize(gutter(0)).width, tester.getSize(gutter(9)).width);
  });

  testWidgets('a 1,234-line file sizes the gutter for four-digit numbers', (
    tester,
  ) async {
    final body = [for (var i = 0; i < 1234; i++) 'code $i'].join('\n');
    await tester.pumpWidget(host('big.txt', body));
    await settle(tester);

    expectRow(tester, 0);
    expectNumberFits(tester, 0);
    final firstWidth = tester.getSize(gutter(0)).width;
    final firstTextX = tester.getTopLeft(line(0)).dx;

    await jumpToLine(tester, 999);
    expectRow(tester, 999);
    expectNumberFits(tester, 999);
    expect(tester.getSize(gutter(999)).width, firstWidth);
    expect(tester.getTopLeft(line(999)).dx, firstTextX);

    await jumpToLine(tester, 1233);
    expectRow(tester, 1233);
    expectNumberFits(tester, 1233);
    expect(tester.getSize(gutter(1233)).width, firstWidth);
    expect(tester.takeException(), isNull);
  });

  /// Painted width of [text] in the gutter's effective style.
  double paintedWidth(WidgetTester tester, int i, String text) {
    final paragraph = tester.renderObject<RenderParagraph>(gutter(i));
    final painter = TextPainter(
      text: TextSpan(text: text, style: paragraph.text.style),
      textDirection: paragraph.textDirection,
      textScaler: paragraph.textScaler,
      strutStyle: paragraph.strutStyle,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  testWidgets('a 100,000-line gutter is as wide as the painted 100000', (
    tester,
  ) async {
    final big = List.filled(100000, 'row').join('\n');
    await tester.pumpWidget(host('huge.txt', big));
    await settle(tester);

    expect(
      tester.getSize(gutter(0)).width,
      greaterThanOrEqualTo(paintedWidth(tester, 0, '100000')),
    );
  });

  testWidgets('the code text starts one gap right of the gutter', (
    tester,
  ) async {
    final body = [for (var i = 0; i < 12; i++) 'code $i'].join('\n');
    await tester.pumpWidget(host('gap.txt', body));
    await settle(tester);

    for (final i in [0, 11]) {
      expect(
        tester.getTopLeft(line(i)).dx - tester.getTopRight(gutter(i)).dx,
        moreOrLessEquals(12),
        reason: 'line $i keeps the gutter gap',
      );
    }
  });

  testWidgets('horizontal scroll reaches the end of the longest line', (
    tester,
  ) async {
    const marker = 'END_OF_LONG_LINE';
    final longLine = '${'x' * 300}$marker';
    final body = ['short', longLine, 'tail'].join('\n');
    await tester.pumpWidget(host('wide.txt', body));
    await settle(tester);

    final horizontal = find.byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.right,
    );
    expect(horizontal, findsOneWidget);
    final position = tester.state<ScrollableState>(horizontal).position;
    expect(position.maxScrollExtent, greaterThan(0));
    position.jumpTo(position.maxScrollExtent);
    await settle(tester);

    // Right edge of the marker's last glyph, in global coordinates.
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: line(1), matching: find.byType(RichText)),
    );
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(
        baseOffset: longLine.length - 3,
        extentOffset: longLine.length,
      ),
    );
    expect(boxes, isNotEmpty);
    final textEnd = paragraph
        .localToGlobal(Offset(boxes.last.right, boxes.last.top))
        .dx;
    final viewport = tester.getRect(horizontal);
    expect(
      textEnd,
      lessThanOrEqualTo(viewport.right),
      reason: 'the end of $marker is reachable',
    );
    expect(textEnd, greaterThan(viewport.left));
  });
}
