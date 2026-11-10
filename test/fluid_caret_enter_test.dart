// CHAT-FLUIDO 4: Hermes Desktop's disclosure caret (points right closed,
// down open, 150 ms) with a tap a screen reader can use, and the enter
// animation for blocks that appear in a live turn (once per key, never with
// reduced motion). Mock 138 v2 (the owner, 1.4.0) sets the enter: from 10 dp
// below with a fade, 220 ms in the mock, `HermesMotion.base` here; it was
// Desktop's 180 ms from 6 dp, transform only.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/motion.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host(Widget child, {bool reduceMotion = false}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  ),
);

/// The enter slide's offset under [key]; null when nothing slides.
double? _slide(WidgetTester tester, String key) {
  final slide = find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byKey(const ValueKey('turn-enter-slide')),
  );
  if (slide.evaluate().isEmpty) return null;
  final transform = tester.widget<Transform>(slide.first).transform;
  return transform.getTranslation().y;
}

ChatTraceEvent _tool(String id) => ChatTraceEvent(
  id: id,
  label: 'terminal',
  status: 'running',
  detail: 'pytest $id',
  startedAt: DateTime.now(),
);

Widget _turn(List<ChatTraceEvent> events) => ThinkingTraceCard(
  events: events,
  active: true,
  liveInPill: true,
  headerBuilder: (context, summary, details) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [summary, details],
  ),
);

void main() {
  setUp(TurnEnter.debugForget);

  group('caret', () {
    Widget line({required bool expanded, VoidCallback? onTap}) => _host(
      TurnFoldLine(
        key: const ValueKey('line'),
        label: 'Pensó durante 9s',
        expanded: expanded,
        onTap: onTap ?? () {},
      ),
    );

    AnimatedRotation rotation(WidgetTester tester) =>
        tester.widget<AnimatedRotation>(
          find.descendant(
            of: find.byKey(const ValueKey('line')),
            matching: find.byType(AnimatedRotation),
          ),
        );

    testWidgets('points right closed, down open, in 150 ms', (tester) async {
      await tester.pumpWidget(line(expanded: false));
      expect(rotation(tester).turns, -0.25);
      expect(rotation(tester).duration, const Duration(milliseconds: 150));
      await tester.pumpWidget(line(expanded: true));
      expect(rotation(tester).turns, 0);
    });

    testWidgets('a screen reader can open the line', (tester) async {
      final semantics = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(line(expanded: false, onTap: () => taps++));
      expect(
        tester.getSemantics(find.byKey(const ValueKey('line'))),
        isSemantics(
          label: 'Pensó durante 9s',
          isButton: true,
          hasTapAction: true,
        ),
      );
      final node = tester.getSemantics(find.byKey(const ValueKey('line')));
      node.owner!.performAction(node.id, SemanticsAction.tap);
      expect(taps, 1);
      semantics.dispose();
    });
  });

  group('enter', () {
    Widget block({required bool enabled, String key = 'k'}) => _host(
      TurnEnter(
        key: const ValueKey('block'),
        animationKey: key,
        enabled: enabled,
        child: const SizedBox(height: 20, child: Text('row')),
      ),
    );

    double fade(WidgetTester tester) => tester
        .widget<Opacity>(find.byKey(const ValueKey('turn-enter-fade')))
        .opacity;

    testWidgets('slides up from 10 dp and fades in, in 200 ms', (
      tester,
    ) async {
      expect(TurnEnter.duration, HermesMotion.base);
      await tester.pumpWidget(block(enabled: true));
      expect(_slide(tester, 'block'), closeTo(10, 0.01));
      expect(fade(tester), 0);
      // The slide's ticker starts on the next frame.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_slide(tester, 'block'), inExclusiveRange(0, 10));
      expect(fade(tester), inExclusiveRange(0, 1));
      await tester.pump(const Duration(milliseconds: 110));
      // In: drawn as if it had always been there, no layer of its own.
      expect(_slide(tester, 'block'), isNull);
      expect(find.byKey(const ValueKey('turn-enter-fade')), findsNothing);
      expect(find.text('row'), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('the block keeps its state when the slide ends', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const TurnEnter(
            key: ValueKey('block'),
            animationKey: 'state',
            enabled: true,
            child: TextField(key: ValueKey('field')),
          ),
        ),
      );
      final before = tester.state(find.byKey(const ValueKey('field')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(_slide(tester, 'block'), isNull);
      expect(tester.state(find.byKey(const ValueKey('field'))), same(before));
    });

    testWidgets('not when disabled, nor with reduced motion', (tester) async {
      await tester.pumpWidget(block(enabled: false));
      expect(_slide(tester, 'block'), isNull);
      TurnEnter.debugForget();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        _host(
          const TurnEnter(
            key: ValueKey('block'),
            animationKey: 'still',
            enabled: true,
            child: Text('row'),
          ),
          reduceMotion: true,
        ),
      );
      expect(_slide(tester, 'block'), isNull);
    });

    testWidgets('a key plays once, even when mounted again', (tester) async {
      await tester.pumpWidget(block(enabled: true));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(block(enabled: true));
      expect(_slide(tester, 'block'), isNull);
    });
  });

  testWidgets('a live turn slides in only what appears after it is shown', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_turn([_tool('a')])));
    // Painted with the card: no slide.
    expect(_slide(tester, 'turn-enter-step-a'), isNull);
    await tester.pump();
    await tester.pumpWidget(_host(_turn([_tool('a'), _tool('b')])));
    expect(
      _slide(tester, 'turn-enter-step-b'),
      closeTo(TurnEnter.offset, 0.01),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(_slide(tester, 'turn-enter-step-b'), isNull);
  });
}
