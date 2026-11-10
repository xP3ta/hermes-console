// A long turn in the transcript: consecutive tool steps are ONE «Trabajó · N
// pasos ›» line and consecutive thoughts ONE «Pensó» line; the tail of the list follows new steps and text only while the reader
// is pinned (or less than a screen away); reduced motion jumps, never eases.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/tool_steps_summary.dart';
import 'package:hermes_android/core/widgets/chat/turn_step_cards.dart';
import 'package:hermes_android/core/widgets/chat/turn_tail_follow.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _app(Widget child, {bool reduceMotion = false, String lang = 'es'}) =>
    MaterialApp(
      locale: Locale(lang),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: Scaffold(body: child),
    );

TurnStepCardEntry _thought(String id, {bool open = false}) => TurnStepCardEntry(
  id: id,
  kind: TurnStepCardKind.thought,
  title: 'Pensó',
  semanticsLabel: 'Pensó',
  initiallyOpen: open,
  opened: Text('razón $id', key: ValueKey('body-$id')),
);

TurnStepCardEntry _tool(String id) => TurnStepCardEntry(
  id: id,
  kind: TurnStepCardKind.tool,
  title: 'Ejecutó',
  detail: 'mkdir $id',
  toolName: 'terminal',
  semanticsLabel: 'Ejecutó, mkdir $id',
  opened: Text('salida $id', key: ValueKey('out-$id')),
);

Finder _line() => find.byKey(const ValueKey('turn-line-label'));
Finder _thoughtLine() => find.byKey(const ValueKey('turn-thought-label'));
Finder _card(String id) => find.byKey(ValueKey('turn-step-card-$id'));

void main() {
  setUp(StepsBarMemory.reset);

  group('consecutive thoughts and tools', () {
    testWidgets('three thoughts in a row are one «Pensó» line that opens '
        'them all', (tester) async {
      await tester.pumpWidget(
        _app(
          TurnStepCards(entries: [_thought('a'), _thought('b'), _thought('c')]),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Pensó 3 veces'), findsOneWidget);
      expect(find.byKey(const ValueKey('body-b')), findsNothing);
      await tester.tap(_thoughtLine());
      await tester.pumpAndSettle();
      for (final id in ['a', 'b', 'c']) {
        expect(find.byKey(ValueKey('body-$id')), findsOneWidget);
      }
    });

    testWidgets('three tools in a row are one line; each opens from it', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(TurnStepCards(entries: [_tool('a'), _tool('b'), _tool('c')])),
      );
      await tester.pumpAndSettle();
      expect(find.text('Trabajó · Ejecutó 3 comandos'), findsOneWidget);
      expect(_card('a'), findsNothing);
      await tester.tap(_line());
      await tester.pumpAndSettle();
      for (final id in ['a', 'b', 'c']) {
        expect(_card(id), findsOneWidget);
      }
      await tester.tap(_card('b'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('out-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('out-a')), findsNothing);
    });

    testWidgets('thoughts and tools alternating are ONE «Trabajó» line; '
        'nothing is stacked', (tester) async {
      await tester.pumpWidget(
        _app(
          TurnStepCards(
            entries: [
              _thought('a'),
              _tool('t'),
              _thought('b'),
              _tool('u'),
              _tool('v'),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_line(), findsOneWidget);
      expect(_thoughtLine(), findsNothing);
      expect(find.text('Trabajó · Ejecutó 3 comandos'), findsOneWidget);
      await tester.tap(_line());
      await tester.pumpAndSettle();
      for (final id in ['t', 'u', 'v']) {
        expect(_card(id), findsOneWidget);
      }
    });

    testWidgets('open state is kept by the first step id and survives a new '
        'step and a rebuild', (tester) async {
      final entries = ValueNotifier([_tool('a'), _tool('b')]);
      addTearDown(entries.dispose);
      Widget host() => _app(
        ValueListenableBuilder(
          valueListenable: entries,
          builder: (_, value, _) => TurnStepCards(entries: value),
        ),
      );
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await tester.tap(_line());
      await tester.pumpAndSettle();
      await tester.tap(_card('b'));
      await tester.pumpAndSettle();
      expect(StepsBarMemory.recorded('a'), isTrue);
      entries.value = [_tool('a'), _tool('b'), _tool('c')];
      await tester.pumpAndSettle();
      expect(find.text('Trabajó · Ejecutó 3 comandos'), findsOneWidget);
      expect(_card('c'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('out-b')),
        findsOneWidget,
        reason: 'the step the reader opened stays open',
      );
      // A fresh mount reads the same remembered state.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(_card('a'), findsOneWidget);
    });

    testWidgets('a live thought the reader wants open shows its text', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(TurnStepCards(entries: [_thought('a', open: true)])),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('body-a')), findsOneWidget);
    });

    testWidgets('reduced motion opens in one frame', (tester) async {
      await tester.pumpWidget(
        _app(
          TurnStepCards(entries: [_tool('a'), _tool('b')]),
          reduceMotion: true,
        ),
      );
      await tester.tap(_line());
      await tester.pump();
      expect(_card('a'), findsOneWidget);
    });

    testWidgets('the label has a plural in every language', (tester) async {
      for (final lang in [
        'es',
        'en',
        'pt',
        'de',
        'fr',
        'it',
        'ja',
        'ko',
        'zh',
      ]) {
        final s = lookupStrings(Locale(lang));
        expect(s.turnLineRan(3), contains('3'), reason: lang);
        expect(s.turnLineRan(30), contains('30'), reason: lang);
        if (!['ja', 'ko', 'zh'].contains(lang)) {
          expect(s.turnLineRan(3), isNot(s.turnLineRan(1)), reason: lang);
        }
        expect(s.turnLineThinking, isNotEmpty, reason: lang);
        expect(s.turnLineWorked, isNotEmpty, reason: lang);
      }
    });
  });

  group('a turn of 30 steps', () {
    testWidgets('a long run of tools stays one line as it grows', (
      tester,
    ) async {
      final entries = ValueNotifier<List<TurnStepCardEntry>>([]);
      addTearDown(entries.dispose);
      await tester.pumpWidget(
        _app(
          SingleChildScrollView(
            child: ValueListenableBuilder(
              valueListenable: entries,
              builder: (_, value, _) => TurnStepCards(entries: value),
            ),
          ),
          reduceMotion: true,
        ),
      );
      final heights = <double>[];
      final all = <TurnStepCardEntry>[];
      for (var i = 0; i < 30; i++) {
        all.addAll([_tool('r${i}a'), _tool('r${i}b'), _tool('t$i')]);
        entries.value = [...all];
        await tester.pump();
        heights.add(tester.getSize(find.byType(TurnStepCards)).height);
      }
      expect(find.text('Trabajó · Ejecutó 90 comandos'), findsOneWidget);
      expect(heights.last, lessThanOrEqualTo(60));
      expect(heights.toSet().length, 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('following the tail', () {
    test('the band is the pinned zone or one screen', () {
      bool near(double px, double view) =>
          withinTurnFollowBand(pixels: px, minExtent: 0, viewport: view);
      expect(near(0, 700), isTrue);
      expect(near(690, 700), isTrue);
      expect(near(701, 700), isFalse);
      expect(near(90, 50), isTrue, reason: 'small viewports keep 100 dp');
      expect(near(101, 50), isFalse);
    });

    // A reversed list like the transcript: offset 0 is the newest row. The
    // stream grows the newest row (steps and text) and then asks to follow.
    Future<ScrollController> mount(
      WidgetTester tester,
      ValueNotifier<double> newest, {
      required bool reduceMotion,
    }) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _app(
          ListView(
            controller: controller,
            reverse: true,
            children: [
              ValueListenableBuilder<double>(
                valueListenable: newest,
                builder: (_, height, _) => SizedBox(height: height),
              ),
              for (var i = 0; i < 20; i++)
                SizedBox(height: 120, child: Text('$i')),
            ],
          ),
          reduceMotion: reduceMotion,
        ),
      );
      return controller;
    }

    testWidgets('pinned reader: 30 steps and growing text never leave the '
        'end', (tester) async {
      final newest = ValueNotifier<double>(60);
      addTearDown(newest.dispose);
      final controller = await mount(tester, newest, reduceMotion: false);
      for (var i = 0; i < 30; i++) {
        newest.value += i.isEven ? 48 : 90; // a step row, then text
        await tester.pump();
        followTurnTail(controller, reduceMotion: false);
        await tester.pumpAndSettle();
        expect(controller.position.pixels, 0, reason: 'step $i');
      }
    });

    testWidgets('a reader one half-screen up is carried; two screens up is '
        'left alone', (tester) async {
      final newest = ValueNotifier<double>(60);
      addTearDown(newest.dispose);
      final controller = await mount(tester, newest, reduceMotion: false);
      final view = controller.position.viewportDimension;
      controller.jumpTo(view / 2);
      await tester.pump();
      newest.value += 48;
      await tester.pump();
      expect(followTurnTail(controller, reduceMotion: false), isTrue);
      await tester.pumpAndSettle();
      expect(controller.position.pixels, 0);

      controller.jumpTo(view * 2);
      await tester.pump();
      newest.value += 48;
      await tester.pump();
      expect(followTurnTail(controller, reduceMotion: false), isFalse);
      await tester.pumpAndSettle();
      expect(controller.position.pixels, view * 2);
    });

    testWidgets('reduced motion jumps in the same frame, no easing', (
      tester,
    ) async {
      final newest = ValueNotifier<double>(60);
      addTearDown(newest.dispose);
      final controller = await mount(tester, newest, reduceMotion: true);
      controller.jumpTo(80);
      await tester.pump();
      expect(followTurnTail(controller, reduceMotion: true), isTrue);
      expect(controller.position.pixels, 0, reason: 'no animation to await');
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('eased follow is an animation, not a jump', (tester) async {
      final newest = ValueNotifier<double>(60);
      addTearDown(newest.dispose);
      final controller = await mount(tester, newest, reduceMotion: false);
      controller.jumpTo(80);
      await tester.pump();
      followTurnTail(controller, reduceMotion: false);
      expect(controller.position.pixels, 80);
      await tester.pump(); // the animation's first tick is its start
      await tester.pump(const Duration(milliseconds: 30));
      expect(controller.position.pixels, inExclusiveRange(0, 80));
      await tester.pumpAndSettle();
      expect(controller.position.pixels, 0);
    });
  });
}
