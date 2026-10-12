// The value of a design-system list row ends next to its arrow, whatever
// its length and the title's, at phone widths, at 2× text and right to left.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart';
import 'package:hermes_android/core/theme/app_theme.dart';

import '../support/design_shots.dart';

const _rows = <(String, String)>[
  ('Modelo', 'anthropic · claude-opus-4.1'),
  ('Razonamiento', 'Medio'),
  ('Skills y herramientas', '24'),
  ('Tareas', '3'),
];

Future<void> _pump(
  WidgetTester tester, {
  double width = 390,
  double textScale = 1,
  TextDirection direction = TextDirection.ltr,
  List<(String, String)> rows = _rows,
}) async {
  // Real text metrics: the test font's square glyphs would wrap any title.
  await loadDesignFonts();
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.hermesRedDark,
      home: Directionality(
        textDirection: direction,
        child: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(18),
            child: HermesListGroup(
              children: [
                for (final (title, value) in rows)
                  HermesListRow(
                    key: ValueKey(title),
                    icon: Icons.memory_rounded,
                    title: title,
                    value: value,
                    onTap: () {},
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Finder _arrow(String title) => find.descendant(
  of: find.byKey(ValueKey(title)),
  matching: find.byIcon(Icons.chevron_right_rounded),
);

void main() {
  for (final width in [320.0, 390.0, 412.0]) {
    testWidgets('every value ends at its arrow and the arrows share an edge '
        'at ${width.toInt()} dp', (tester) async {
      await _pump(tester, width: width);
      final arrowEnds = <double>{};
      for (final (title, value) in _rows) {
        final text = tester.getRect(find.text(value));
        final arrow = tester.getRect(_arrow(title));
        expect(
          text.right,
          closeTo(arrow.left, 0.01),
          reason: '$title: value next to arrow',
        );
        arrowEnds.add(arrow.right.roundToDouble());
      }
      expect(arrowEnds, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a short value leaves the title its line; a title is never '
      'narrower than what it needs when the value is short', (tester) async {
    await _pump(tester);
    final oneLine = tester.getSize(find.text('Tareas')).height;
    expect(tester.getSize(find.text('Skills y herramientas')).height, oneLine);
    // The model's name is whole: the short title gave it the room.
    final value = tester.renderObject<RenderParagraph>(
      find.text('anthropic · claude-opus-4.1'),
    );
    expect(value.didExceedMaxLines, isFalse);
  });

  testWidgets('a value too long ends in an ellipsis within its share and '
      'the title keeps its own', (tester) async {
    const title = 'Proveedor del modelo';
    const value = 'antigravity/gemini-3.6-flash-high-thinking-preview-latest';
    await _pump(tester, width: 320, rows: const [(title, value)]);
    final row = tester.getRect(find.byKey(const ValueKey(title)));
    final titleBox = tester.getRect(find.text(title));
    final valueBox = tester.getRect(find.text(value));
    final arrow = tester.getRect(_arrow(title));
    expect(valueBox.right, closeTo(arrow.left, 0.01));
    expect(valueBox.left, greaterThanOrEqualTo(titleBox.right));
    expect(
      tester.renderObject<RenderParagraph>(find.text(value)).didExceedMaxLines,
      isTrue,
    );
    // The title is on screen, with at least a third of the row.
    expect(titleBox.width, greaterThan(row.width * 0.3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('at 2× text nothing overflows and the value still ends at '
      'the arrow', (tester) async {
    await _pump(tester, width: 320, textScale: 2);
    for (final (title, value) in _rows) {
      expect(
        tester.getRect(find.text(value)).right,
        closeTo(tester.getRect(_arrow(title)).left, 0.01),
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('right to left it is mirrored: the value starts at the arrow', (
    tester,
  ) async {
    await _pump(tester, direction: TextDirection.rtl);
    final arrowStarts = <double>{};
    for (final (title, value) in _rows) {
      final text = tester.getRect(find.text(value));
      final arrow = tester.getRect(_arrow(title));
      expect(text.left, closeTo(arrow.right, 0.01), reason: title);
      expect(tester.getRect(find.text(title)).left, greaterThan(text.right));
      arrowStarts.add(arrow.left.roundToDouble());
    }
    expect(arrowStarts, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a row without a value is as it was: the title has the row', (
    tester,
  ) async {
    await _pump(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.hermesRedDark,
        home: Scaffold(
          body: HermesListRow(
            key: const ValueKey('plain'),
            title: 'Memoria',
            onTap: () {},
          ),
        ),
      ),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('plain')),
        matching: find.byType(LayoutBuilder),
      ),
      findsNothing,
    );
    expect(_arrow('plain'), findsOneWidget);
  });
}
