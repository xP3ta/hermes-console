// The summary that closes a turn («Worked · 6 commands · Used 51 tools»)
// was allowed two lines: beside the reply's actions on a phone it wrapped
// into a tall, wide capsule that dwarfed the «Δ 1 file» chip right above
// it. It is one line now, as tall as that chip. When the whole line does
// not fit beside the actions, the actions take a row of their own and the
// line the whole width; short of room even then it tightens its size, then
// abbreviates its counts (same order, same numbers), and only then ends in
// an ellipsis. Nothing is removed from what it says aloud, and the tap is
// the same.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/floating.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/hermes_tokens.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/core/widgets/chat/turn_activity_pill.dart';
import 'package:hermes_android/core/widgets/chat/turn_receipt_pill.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host(
  Widget child, {
  required double width,
  double scale = 1,
  String locale = 'es',
}) => MaterialApp(
  locale: Locale(locale),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromMode(AppThemeMode.dark),
  builder: (context, body) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(disableAnimations: true, textScaler: TextScaler.linear(scale)),
    child: body!,
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        child: SingleChildScrollView(child: child),
      ),
    ),
  ),
);

const _full = 'Trabajó · 6 comandos · Usó 51 herramientas';
const _short = 'Trabajó · 6 cmd · 51 herr.';

final _text = find.byKey(const ValueKey('chat-inline-activity-text'));
final _surface = find.byKey(const ValueKey('chat-inline-activity-surface'));

Widget _pill({
  String label = _full,
  String? short = _short,
  VoidCallback? onTap,
}) => TurnInlineActivity(
  label: label,
  shortLabel: short,
  spokenLabel: label,
  live: false,
  steps: 57,
  open: false,
  onTap: onTap ?? () {},
);

/// One line: less tall than two lines of its own size could be.
Future<void> _expectOneLine(WidgetTester tester) async {
  final shown = tester.widget<Text>(_text);
  expect(shown.maxLines, 1);
  final scale = MediaQuery.textScalerOf(tester.element(_text)).scale(1);
  expect(
    tester.getSize(_text).height,
    lessThan(shown.style!.fontSize! * scale * 1.9),
  );
}

void main() {
  testWidgets('with room it is the whole line at its size, in a row as '
      'quiet as the memory receipt', (tester) async {
    await tester.pumpWidget(_host(_pill(), width: 900));
    final shown = tester.widget<Text>(_text);
    expect(shown.data, _full);
    expect(shown.style?.fontSize, HermesType.supportSize);
    expect(tester.getSize(_surface).height, TurnInlineActivity.capsuleHeight);
    expect(
      TurnInlineActivity.capsuleHeight,
      TurnReceiptPill.height,
      reason: 'the memory receipt',
    );
    // The row is the whole widget: nothing taller is drawn or reserved.
    expect(
      tester.getSize(find.byType(TurnInlineActivity)).height,
      TurnReceiptPill.height,
    );
    expect(find.byType(HermesFloatingSurface), findsNothing);
    await _expectOneLine(tester);
  });

  testWidgets('narrower and narrower: tighter, then its counts abbreviated, '
      'then an ellipsis; one line and no overflow at every width', (
    tester,
  ) async {
    // 0 whole at 12.5, 1 whole at 12, 2 abbreviated, 3 abbreviated and cut.
    final seen = <int>[];
    for (var width = 900.0; width >= 70; width -= 10) {
      await tester.pumpWidget(_host(_pill(), width: width));
      expect(tester.takeException(), isNull, reason: 'width $width');
      await _expectOneLine(tester);
      expect(
        tester.getSize(_surface).height,
        TurnInlineActivity.capsuleHeight,
        reason: 'width $width',
      );
      expect(tester.getSize(_surface).width, lessThanOrEqualTo(width));
      final shown = tester.widget<Text>(_text);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: _text, matching: find.byType(RichText)),
      );
      final cut = paragraph.didExceedMaxLines;
      final stage = shown.data == _short
          ? (cut ? 3 : 2)
          : shown.style?.fontSize == HermesType.supportSize
          ? 0
          : 1;
      expect(shown.data, anyOf(_full, _short));
      // The whole line is never cut: it is abbreviated first.
      if (shown.data == _full) expect(cut, isFalse, reason: 'width $width');
      if (stage == 2 || stage == 1) {
        expect(shown.style?.fontSize, TurnInlineActivity.tightFontSize);
      }
      if (seen.isEmpty || seen.last != stage) seen.add(stage);
    }
    expect(seen, [0, 1, 2, 3], reason: 'each step once, in that order');
  });

  testWidgets('a line with nothing to abbreviate goes from tight to the '
      'ellipsis', (tester) async {
    await tester.pumpWidget(
      _host(
        _pill(label: 'Trabajó 1 min 58 s · 6 comandos', short: null),
        width: 150,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(tester.widget<Text>(_text).data, 'Trabajó 1 min 58 s · 6 comandos');
    await _expectOneLine(tester);
  });

  for (final scale in [1.3, 1.6, 2.0]) {
    for (final width in [200.0, 320.0, 411.0]) {
      testWidgets('text x$scale in $width: still one line, no overflow', (
        tester,
      ) async {
        await tester.pumpWidget(_host(_pill(), width: width, scale: scale));
        expect(tester.takeException(), isNull);
        await _expectOneLine(tester);
        expect(tester.getSize(_surface).width, lessThanOrEqualTo(width));
        // Bigger text makes a taller capsule, by one line and no more.
        await tester.pumpWidget(
          _host(
            _pill(label: 'X', short: null),
            width: width,
            scale: scale,
          ),
        );
        final oneWord = tester.getSize(_surface).height;
        await tester.pumpWidget(_host(_pill(), width: width, scale: scale));
        expect(tester.getSize(_surface).height, lessThanOrEqualTo(oneWord));
      });
    }
  }

  testWidgets('the tap is the same and the spoken label keeps every word', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(_host(_pill(onTap: () => taps++), width: 160));
    final handle = tester.ensureSemantics();
    await tester.tap(find.byType(TurnInlineActivity));
    expect(taps, 1);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('chat-inline-activity'))),
      matchesSemantics(
        label: '$_full, ${Strings.of(tester.element(_text)).chatLiveSteps(57)}',
        isButton: true,
        hasTapAction: true,
        hasExpandedState: true,
        onTapHint: Strings.of(tester.element(_text)).stepsBarWorkedShow,
      ),
    );
    handle.dispose();
  });

  // The real row: the summary a finished turn builds beside the reply's
  // three actions, in both languages.
  Widget row(String locale, double width, double scale) {
    final events = [
      for (var i = 0; i < 6; i++)
        ChatTraceEvent(
          id: 'c$i',
          label: 'terminal',
          status: 'completed',
          detail: 'ls $i',
        ),
      for (var i = 0; i < 51; i++)
        ChatTraceEvent(
          id: 'o$i',
          label: i.isEven ? 'browser_snapshot' : 'vision_analyze',
          status: 'completed',
          detail: 'x$i',
        ),
    ];
    return _host(
      LiveTurnScope(
        inlineActivity: true,
        status: LiveTurnStatus.idle,
        clock: () => DateTime(2026, 11, 22),
        child: ThinkingTraceCard(
          active: false,
          stepCards: true,
          events: events,
          headerBuilder: (_, summary, details) => TurnActivityFooter(
            summary: summary,
            details: details,
            actions: List.generate(
              3,
              (_) => const SizedBox.square(dimension: HermesSpace.tap),
            ),
          ),
        ),
      ),
      width: width,
      scale: scale,
      locale: locale,
    );
  }

  final actions = find.byKey(const ValueKey('assistant-footer-actions'));
  final summary = find.byKey(const ValueKey('chat-inline-activity'));

  for (final locale in ['es', 'en']) {
    testWidgets('$locale: on a phone the whole line is read: the actions '
        'take their own row above it instead of squeezing it', (tester) async {
      // Room for the whole line, not for the line and the actions (the
      // test font is wider than the app's: on a 411 dp phone this is the
      // 379 dp of a reply).
      // 600: the line is 584 wide in Spanish and 494 in English here, and
      // the three actions 144.
      await tester.pumpWidget(row(locale, 600, 1));
      expect(tester.takeException(), isNull);
      final s = Strings.of(tester.element(_text));
      final whole = [
        s.turnLineWorked,
        s.chatLiveCommands(6),
        s.turnLineUsedTools(51),
      ].join(' · ');
      final shown = tester.widget<Text>(_text);
      expect(shown.data, whole);
      expect(shown.style?.fontSize, HermesType.supportSize);
      await _expectOneLine(tester);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: _text, matching: find.byType(RichText)),
      );
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(
        tester.getRect(actions).bottom,
        lessThanOrEqualTo(tester.getRect(summary).top),
      );
      expect(tester.getRect(actions).left, tester.getRect(summary).left);
      expect(tester.getSize(_surface).height, TurnInlineActivity.capsuleHeight);
    });

    testWidgets('$locale: with room for both, the summary and the actions '
        'share a row', (tester) async {
      await tester.pumpWidget(row(locale, 900, 1));
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(_surface).right,
        lessThan(tester.getRect(actions).left),
      );
      expect(
        tester.getRect(actions).center.dy,
        closeTo(tester.getRect(summary).center.dy, 0.01),
      );
      expect(
        tester.widget<Text>(_text).style?.fontSize,
        HermesType.supportSize,
      );
    });

    for (final (width, scale) in [
      (288.0, 1.0),
      (288.0, 1.3),
      (288.0, 2.0),
      (379.0, 1.3),
      (379.0, 2.0),
    ]) {
      testWidgets('$locale $width x$scale: one line; the counts are '
          'abbreviated before anything is cut', (tester) async {
        await tester.pumpWidget(row(locale, width, scale));
        expect(tester.takeException(), isNull);
        final s = Strings.of(tester.element(_text));
        final whole = [
          s.turnLineWorked,
          s.chatLiveCommands(6),
          s.turnLineUsedTools(51),
        ].join(' · ');
        final abbreviated = [
          s.turnLineWorked,
          s.turnLineCommandsShort(6),
          s.turnLineToolsShort(51),
        ].join(' · ');
        await _expectOneLine(tester);
        final shown = tester.widget<Text>(_text).data;
        expect(shown, anyOf(whole, abbreviated));
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: _text, matching: find.byType(RichText)),
        );
        if (shown == whole) expect(paragraph.didExceedMaxLines, isFalse);
        // The spoken label is always the whole line.
        final spoken = tester.getSemantics(summary).label;
        expect(spoken, startsWith(whole));
      });
    }
  }

  test('the abbreviated counts exist in the nine languages', () {
    for (final locale in Strings.supportedLocales) {
      final s = lookupStrings(locale);
      expect(s.turnLineCommandsShort(6), contains('6'));
      expect(s.turnLineToolsShort(51), contains('51'));
      expect(
        s.turnLineToolsShort(51).length,
        lessThan(s.turnLineUsedTools(51).length),
        reason: locale.languageCode,
      );
    }
  });
}
