import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // Use the shipped UI font, not flutter_test's square Ahem glyphs.
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/Inter.ttf'))).load();
  });

  for (final streaming in [false, true]) {
    testWidgets(
      'normal and nested lists retain compact layout streaming=$streaming',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.fromId('dark'),
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: Scaffold(
              body: SizedBox(
                width: 320,
                child: AssistantMarkdownView(
                  isStreaming: streaming,
                  data:
                      '1. First\n2. Second\n\n- Bullet\n  - Nested\n\n```text\n999999. not a list\n```',
                ),
              ),
            ),
          ),
        );
        for (final body in tester.widgetList<MarkdownBody>(
          find.byType(MarkdownBody),
        )) {
          expect(body.styleSheet!.listIndent, 16);
          expect(
            body.styleSheet!.listBulletPadding,
            const EdgeInsets.only(right: 6),
          );
        }
        for (final label in ['First', 'Second', 'Bullet', 'Nested']) {
          expect(find.text(label, findRichText: true), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'implicit numbering and nested ordinals are measured streaming=$streaming',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.fromId('dark'),
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: SizedBox(
                    width: 320,
                    child: AssistantMarkdownView(
                      isStreaming: streaming,
                      data:
                          '${List.filled(105, '1. Item').join('\n')}\n\n- Nested\n  110. A\n  1. B\n  1. C',
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        // CommonMark ignores subsequent source ordinals and increments from start.
        for (final label in [
          '10.',
          '99.',
          '100.',
          '105.',
          '110.',
          '111.',
          '112.',
        ]) {
          final marker = find.byWidgetPredicate(
            (w) => w is RichText && w.text.toPlainText() == label,
          );
          expect(marker, findsOneWidget);
          final paragraph = tester.renderObject<RenderParagraph>(marker);
          final glyphs = paragraph.getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: label.length),
          );
          expect(glyphs.map((box) => box.top).toSet(), hasLength(1));
          expect(
            glyphs.last.right,
            lessThanOrEqualTo(paragraph.size.width + 0.01),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final scale in [1.0, 1.5, 2.0, 3.0]) {
    for (final start in [1, 10, 98, 110, 998]) {
      testWidgets('Pixel8973 ordered markers start=$start scale=$scale', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.fromId('dark'),
            locale: const Locale('es'),
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: SizedBox(
                    width: 320,
                    child: AssistantMarkdownView(
                      data: List.generate(
                        3,
                        (i) => '${start + i}. Item ${i + 1}',
                      ).join('\n'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 3; i++) {
          final label = '${start + i}.';
          final marker = find.byWidgetPredicate(
            (w) => w is RichText && w.text.toPlainText() == label,
          );
          expect(marker, findsOneWidget);
          final paragraph = tester.renderObject<RenderParagraph>(marker);
          final glyphs = paragraph.getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: label.length),
          );
          expect(
            glyphs.map((box) => box.top).toSet(),
            hasLength(1),
            reason: '$label must not wrap',
          );
          for (final box in glyphs) {
            expect(box.left, greaterThanOrEqualTo(-0.01));
            expect(
              box.right,
              lessThanOrEqualTo(paragraph.size.width + 0.01),
              reason: '$label must not clip/overflow',
            );
            expect(box.bottom, lessThanOrEqualTo(paragraph.size.height + 0.01));
          }
          expect(paragraph.didExceedMaxLines, isFalse);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
