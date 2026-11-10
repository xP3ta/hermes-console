// QA 9709 (ORDEN-Q9-CHAT 3, the owner): thinking is a brain, not the head with
// a question mark of Icons.psychology_alt_rounded. Material has none and the
// project carries no symbol font, so it is one drawn symbol, [ThinkingGlyph],
// shared by the thought's line, the activity pill, the trace's state icon
// and the saved memory.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/thinking_glyph.dart';

void main() {
  test('one shared symbol: no head with a question mark is left', () {
    final users = <String>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      final source = entity.readAsStringSync();
      if (!path.endsWith('thinking_glyph.dart')) {
        expect(
          source.contains('Icons.psychology_alt_rounded'),
          isFalse,
          reason: '$path still draws the head with a question mark',
        );
      }
      if (source.contains('ThinkingGlyph(')) users.add(path);
    }
    expect(
      users,
      containsAll(<String>[
        'lib/core/widgets/chat_turn_activity.dart',
        'lib/core/widgets/activity_pill.dart',
        'lib/core/widgets/chat_event_cards.dart',
      ]),
    );
  });

  // Ink on the page of each theme: dark on light, light on dark.
  const pairs = [
    (name: 'light', page: Color(0xFFFFFFFF), ink: Color(0xFF3A3A44)),
    (name: 'dark', page: Color(0xFF1E1E28), ink: Color(0xFFE0E0E8)),
  ];
  for (final pair in pairs) {
    for (final size in const [14.0, 18.0]) {
      testWidgets('drawn whole inside its ${size.toInt()} dp box, '
          '${pair.name}', (tester) async {
        final boundary = GlobalKey();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: RepaintBoundary(
                key: boundary,
                child: ColoredBox(
                  color: pair.page,
                  child: ThinkingGlyph(size: size, color: pair.ink),
                ),
              ),
            ),
          ),
        );
        expect(
          tester.getSize(find.byType(ThinkingGlyph)),
          Size.square(size),
        );
        final render = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(boundary),
        );
        const ratio = 3.0;
        final pixels = await tester.runAsync(() async {
          final image = await render.toImage(pixelRatio: ratio);
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final width = image.width;
          image.dispose();
          return (data: data!, width: width);
        });
        final data = pixels!.data;
        final width = pixels.width;
        int channel(int x, int y) => data.getUint8((y * width + x) * 4 + 1);
        final page = (pair.page.g * 255).round();
        final ink = (pair.ink.g * 255).round();
        bool inked(int x, int y) =>
            (channel(x, y) - page).abs() > (ink - page).abs() / 2;
        // The corners stay page: nothing runs out of the box.
        for (final (x, y) in [
          (0, 0),
          (width - 1, 0),
          (0, width - 1),
          (width - 1, width - 1),
        ]) {
          expect(inked(x, y), isFalse, reason: 'corner ($x, $y)');
        }
        // The line between the hemispheres runs through the middle.
        expect(inked(width ~/ 2, width ~/ 2), isTrue);
        // A glyph, not a blot nor a speck: about a third of the box.
        var count = 0;
        for (var y = 0; y < width; y++) {
          for (var x = 0; x < width; x++) {
            if (inked(x, y)) count++;
          }
        }
        expect(count / (width * width), inInclusiveRange(0.12, 0.6));
      });
    }
  }

  testWidgets('like an Icon: the theme\'s size, and said only when '
      'labelled', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: IconTheme(
          data: IconThemeData(size: 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ThinkingGlyph(key: ValueKey('silent')),
              ThinkingGlyph(key: ValueKey('said'), semanticLabel: 'Pensando'),
            ],
          ),
        ),
      ),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('silent'))),
      const Size.square(18),
    );
    expect(find.bySemanticsLabel('Pensando'), findsOneWidget);
    semantics.dispose();
  });
}
