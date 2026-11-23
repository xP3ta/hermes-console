import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/review_notice_row.dart';
import 'package:hermes_android/core/widgets/chat/turn_activity_pill.dart';
import 'package:hermes_android/core/widgets/chat/turn_memory_pill.dart';
import 'package:hermes_android/core/widgets/chat/turn_receipt_pill.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// The notice of the report, as Hermes sends it in Spanish and in English.
const _es =
    "Revisión de automejora: Skill 'html-mockup-iteration' parchada · "
    "Skill 'html-mockup-iteration' parchada "
    '(references/mobile-prototype-verification.md)';
const _en =
    "Self-improvement review: Skill 'html-mockup-iteration' patched · "
    "Skill 'html-mockup-iteration' patched "
    '(references/mobile-prototype-verification.md)';

ChatTraceEvent _memoryEvent() {
  final call = MemoryWrite.fromArgs('memory', const {
    'action': 'add',
    'target': 'memory',
    'content': 'x',
  });
  return ChatTraceEvent(
    id: 'm',
    label: 'memory',
    status: 'completed',
    memory: MemoryWrite.settle(call, const {'success': true}),
  );
}

Widget _host(
  Widget child, {
  double width = 411,
  double scale = 1,
  Locale locale = const Locale('es'),
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: SizedBox(width: width, child: child),
    ),
  ),
);

final _pill = find.byKey(const ValueKey('review-notice-pill'));
final _memoryPill = find.byKey(const ValueKey('turn-memory-pill'));

Text _label(WidgetTester tester, Finder pill) =>
    tester.widget<Text>(find.descendant(of: pill, matching: find.byType(Text)));

void main() {
  group('what the review reported', () {
    test('a bare action repeated with its file is said once', () {
      final summary = ReviewSummary.parse(_es);
      expect(summary.heading, 'Revisión de automejora');
      expect(summary.actions, [
        "Skill 'html-mockup-iteration' parchada "
            '(references/mobile-prototype-verification.md)',
      ]);
      expect(
        summary.line,
        "Revisión de automejora: Skill 'html-mockup-iteration' parchada "
        '(references/mobile-prototype-verification.md)',
      );
    });

    test('the same action twice is said once', () {
      final summary = ReviewSummary.parse(
        'Self-improvement review: Memory updated · Memory updated',
      );
      expect(summary.actions, ['Memory updated']);
    });

    test('different actions are all kept, in order', () {
      final summary = ReviewSummary.parse(
        "Self-improvement review: Memory updated · Skill 'a' patched · "
        "Skill 'b' patched (x.md) · Skill 'a' patched (y.md)",
      );
      expect(summary.actions, [
        'Memory updated',
        "Skill 'b' patched (x.md)",
        "Skill 'a' patched (y.md)",
      ]);
    });

    test('two files of the same skill are both kept', () {
      final summary = ReviewSummary.parse(
        "Review: Skill 'a' patched (x.md) · Skill 'a' patched (y.md)",
      );
      expect(summary.actions, hasLength(2));
    });

    test('a longer name is not taken for a detail of a shorter one', () {
      final summary = ReviewSummary.parse(
        "Review: Skill 'a' patched · Skill 'a' patched twice",
      );
      expect(summary.actions, hasLength(2));
    });

    test('a line without a heading keeps everything it says', () {
      final summary = ReviewSummary.parse('Memory updated · Profile updated');
      expect(summary.heading, isEmpty);
      expect(summary.actions, ['Memory updated', 'Profile updated']);
      expect(summary.line, 'Memory updated · Profile updated');
    });

    test('a single short notice is left as it is', () {
      final summary = ReviewSummary.parse(
        'Self-improvement review: Memory updated',
      );
      expect(summary.line, 'Self-improvement review: Memory updated');
    });
  });

  for (final (name, text, locale) in [
    ('ES', _es, const Locale('es')),
    ('EN', _en, const Locale('en')),
  ]) {
    testWidgets('$name: one line, said once, cut with an ellipsis', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TurnMemoryPill(events: [_memoryEvent()]),
              ReviewNoticeRow(text: text),
            ],
          ),
          locale: locale,
        ),
      );
      await tester.pumpAndSettle();

      final label = _label(tester, _pill);
      expect(label.maxLines, 1);
      expect(label.overflow, TextOverflow.ellipsis);
      // The skill is named once.
      expect("'html-mockup-iteration'".allMatches(label.data!).length, 1);
      expect(label.data, contains('mobile-prototype-verification.md'));
      // The same quiet look as the memory receipt: size, weight, colour,
      // icon size and height.
      final memory = _label(tester, _memoryPill);
      expect(label.style, memory.style);
      expect(tester.getSize(_pill).height, tester.getSize(_memoryPill).height);
      final icons = tester
          .widgetList<Icon>(
            find.descendant(of: _pill, matching: find.byType(Icon)),
          )
          .toList();
      final memoryIcons = tester
          .widgetList<Icon>(
            find.descendant(of: _memoryPill, matching: find.byType(Icon)),
          )
          .toList();
      expect(icons.map((icon) => icon.size), memoryIcons.map((i) => i.size));
      expect(icons.map((icon) => icon.color), memoryIcons.map((i) => i.color));
      // It is cut, not wrapped and not overflowing.
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.descendant(of: _pill, matching: find.byType(Text)),
          matching: find.byType(RichText),
        ),
      );
      expect(paragraph.didExceedMaxLines, isTrue);
      expect(tester.getSize(_pill).width, lessThanOrEqualTo(411));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the row and the memory receipt start at the same edge', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TurnMemoryPill(events: [_memoryEvent()]),
            ),
            const ReviewNoticeRow(text: _es),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(_pill).dx, tester.getTopLeft(_memoryPill).dx);
  });

  testWidgets('a short notice is whole and as wide as its text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const ReviewNoticeRow(text: 'Self-improvement review: Memory updated'),
        width: 900,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Self-improvement review: Memory updated'),
      findsOneWidget,
    );
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.descendant(of: _pill, matching: find.byType(Text)),
        matching: find.byType(RichText),
      ),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(tester.getSize(_pill).width, lessThan(900 - 24));
  });

  for (final (width, scale) in [
    (320.0, 1.0),
    (320.0, 1.3),
    (320.0, 2.0),
    (411.0, 2.0),
    (200.0, 1.0),
  ]) {
    testWidgets('width $width at x$scale: still one line, nothing overflows', (
      tester,
    ) async {
      const reference = ValueKey('one-line-reference');
      await tester.pumpWidget(
        _host(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // A receipt whose label surely fits on one line.
              TurnReceiptPill(
                inkKey: reference,
                icon: Icons.check,
                label: 'x',
                onTap: () {},
              ),
              const ReviewNoticeRow(text: _es),
            ],
          ),
          width: width,
          scale: scale,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(_pill).height,
        tester.getSize(find.byKey(reference)).height,
      );
      if (scale == 1.0) {
        expect(tester.getSize(_pill).height, TurnReceiptPill.height);
      }
      expect(tester.getSize(_pill).width, lessThanOrEqualTo(width));
    });
  }

  testWidgets('memory, turn summary and review notice are one family', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TurnMemoryPill(events: [_memoryEvent()]),
            TurnInlineActivity(
              label: 'Trabajó · 6 comandos · Usó 51 herramientas',
              shortLabel: 'Trabajó · 6 cmd · 51 herr.',
              live: false,
              steps: 57,
              open: false,
              onTap: () {},
            ),
            const ReviewNoticeRow(text: 'Revisión de automejora: Memoria'),
          ],
        ),
        width: 900,
      ),
    );
    await tester.pumpAndSettle();
    final turn = find.byKey(const ValueKey('chat-inline-activity-surface'));
    final rows = [_memoryPill, turn, _pill];
    final styles = [
      for (final row in rows)
        tester
            .widget<Text>(find.descendant(of: row, matching: find.byType(Text)))
            .style,
    ];
    expect(styles[1], styles[0]);
    expect(styles[2], styles[0]);
    for (final row in rows) {
      expect(tester.getSize(row).height, TurnReceiptPill.height);
      final icons = tester
          .widgetList<Icon>(
            find.descendant(of: row, matching: find.byType(Icon)),
          )
          .toList();
      expect(icons, hasLength(2), reason: 'an icon and a chevron');
      expect(icons.map((icon) => icon.size).toSet(), hasLength(1));
      expect(icons.map((icon) => icon.color).toSet(), {styles[0]!.color});
    }
    // The memory receipt sits 12 in from the answer's edge in the chat; the
    // review row brings its own 12.
    expect(tester.getTopLeft(turn).dx, tester.getTopLeft(_memoryPill).dx);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tap opens everything it says, each action once', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const ReviewNoticeRow(
          text:
              "Revisión de automejora: Memoria actualizada · "
              "Skill 'html-mockup-iteration' parchada · "
              "Skill 'html-mockup-iteration' parchada "
              '(references/mobile-prototype-verification.md)',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(_pill);
    await tester.pumpAndSettle();

    final sheet = find.byKey(const ValueKey('review-notice-detail'));
    expect(sheet, findsOneWidget);
    expect(
      find.descendant(of: sheet, matching: find.text('Revisión de automejora')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text('Memoria actualizada')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: sheet,
        matching: find.text(
          "Skill 'html-mockup-iteration' parchada "
          '(references/mobile-prototype-verification.md)',
        ),
      ),
      findsOneWidget,
    );
    expect(find.byType(SelectableText), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a screen reader hears the whole line as one button', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(const ReviewNoticeRow(text: _es)));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(_pill),
      isSemantics(
        isButton: true,
        hasTapAction: true,
        label:
            "Revisión de automejora: Skill 'html-mockup-iteration' parchada "
            '(references/mobile-prototype-verification.md)',
      ),
    );
    handle.dispose();
  });

  testWidgets('a long press copies the line as Hermes sent it', (tester) async {
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
    await tester.pumpWidget(_host(const ReviewNoticeRow(text: _es)));
    await tester.pumpAndSettle();
    await tester.longPress(_pill);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(copied, _es);
  });
}
