import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/turn_step_cards.dart';
import 'package:hermes_android/core/widgets/chat/turn_step_motion.dart';
import 'package:hermes_android/core/widgets/chat/live_turn_pills.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host(Widget child, {bool reduced = false}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
    child: child!,
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 360, child: child),
    ),
  ),
);

// An outcome card: consecutive steps would share ONE line, outcomes do not.
TurnStepCardEntry _entry(String id) => TurnStepCardEntry(
  id: id,
  kind: TurnStepCardKind.outcome,
  title: 'Salida $id',
  semanticsLabel: 'Salida $id',
);

TurnStepCardEntry _tool(String id) => TurnStepCardEntry(
  id: id,
  kind: TurnStepCardKind.tool,
  title: 'Ejecutó',
  detail: 'paso $id',
  toolName: 'terminal',
  semanticsLabel: 'Ejecutó paso $id',
  opened: Text('salida $id'),
);

Finder _lineLabel() => find.byKey(const ValueKey('turn-line-label'));

ChatTraceEvent _thought(
  String id,
  String text, {
  String status = 'completed',
}) => ChatTraceEvent(
  id: id,
  label: 'Pensamiento',
  status: status,
  preview: text,
  kind: ChatTraceEventKind.reasoning,
);

void main() {
  testWidgets(
    'a tool after a running thought: the finished thought is a row of the one folded line, the tool in hand turns under it',
    (tester) async {
      final thought = _thought(
        'before-tool',
        'Razonamiento anterior completo.',
        status: 'running',
      );
      final tool = ChatTraceEvent(
        id: 'after-thought',
        label: 'terminal',
        status: 'running',
      );
      await tester.pumpWidget(
        _host(
          ThinkingTraceCard(
            events: [thought, tool],
            active: true,
            stepCards: true,
            headerBuilder: (_, summary, details) => details,
          ),
        ),
      );
      // The live timeline turns: never settles.
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        tester
            .widget<Text>(
              find.byKey(
                const ValueKey('turn-inner-thought-label-before-tool'),
              ),
            )
            .data,
        'Pensó',
      );
      expect(
        find.byKey(const ValueKey('turn-step-card-after-thought')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('turn-reasoning')), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('turn-inner-thought-label-before-tool')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('turn-reasoning')), findsOneWidget);
      expect(
        thought.status,
        'running',
        reason: 'presentation does not rewrite the trace',
      );
    },
  );

  for (final pauseTicker in [false, true]) {
    testWidgets(
      'finishing a reorder on ${pauseTicker ? 'TickerMode' : 'reduced motion'} releases removed rows',
      (tester) async {
        Widget rows(List<String> ids, {bool cut = false}) => Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: MediaQueryData(disableAnimations: !pauseTicker && cut),
            child: DefaultTextStyle(
              style: const TextStyle(fontSize: 14),
              child: SizedBox(
                width: 360,
                child: TickerMode(
                  enabled: !pauseTicker || !cut,
                  child: TurnStepMotion(
                    entries: [
                      for (final id in ids)
                        (id: id, child: Text(id, key: ValueKey('motion-$id'))),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpWidget(rows(['A', 'B']));
        await tester.pumpAndSettle();
        await tester.pumpWidget(rows(['B', 'A']));
        await tester.pump(const Duration(milliseconds: 40));
        await tester.pumpWidget(rows(['B', 'A'], cut: true));
        await tester.pumpWidget(rows(['B'], cut: true));
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(const ValueKey('motion-A'), skipOffstage: false),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('motion-B')), findsOneWidget);
        tester.binding.debugAssertNoTransientCallbacks(
          'step motion has been cut',
        );
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('a history line keeps its full first-frame height', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(TurnStepCards(entries: [_tool('a'), _tool('b'), _tool('c')])),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('turn-step-cards'))).height,
      greaterThanOrEqualTo(TurnStepCards.lineHeight),
    );
    expect(tester.takeException(), isNull);
  });

  test(
    'identical/prefix thought snapshots coalesce without losing tools or their source',
    () {
      final prefix =
          'Un razonamiento suficientemente largo para reconocer su continuación. ' *
          2;
      final first = _thought('r1', prefix);
      final tool = ChatTraceEvent(
        id: 't',
        label: 'terminal',
        status: 'completed',
      );
      final last = _thought('r2', '${prefix}Conclusión.', status: 'running');
      final source = [first, tool, last];
      final result = coalesceTurnThoughts(source);
      expect(result, hasLength(2));
      expect(result.first.id, 'r1', reason: 'stable disclosure key');
      expect(result.first.preview, last.preview);
      expect(result.first.status, 'running');
      expect(result.last, same(tool));
      expect(source, hasLength(3), reason: 'authoritative trace unchanged');
      expect(first.preview, prefix);
      expect(
        coalesceTurnThoughts([
          _thought('a', 'Voy a revisar A'),
          _thought('b', 'Voy a revisar B'),
        ]),
        hasLength(2),
      );
    },
  );

  testWidgets(
    'burst steps grow/fade on frames and never create a second body on return',
    (tester) async {
      final entries = ValueNotifier<List<TurnStepCardEntry>>([]);
      addTearDown(entries.dispose);
      await tester.pumpWidget(
        _host(
          ValueListenableBuilder(
            valueListenable: entries,
            builder: (_, value, _) => TurnStepCards(entries: value),
          ),
        ),
      );
      entries.value = [_entry('a'), _entry('b'), _entry('c')];
      await tester.pump();
      final group = find.byKey(const ValueKey('turn-step-cards'));
      final initial = tester.getSize(group).height;
      await tester.pump(const Duration(milliseconds: 80));
      final middle = tester.getSize(group).height;
      expect(middle, greaterThan(initial));
      await tester.pumpAndSettle();
      final settled = tester.getSize(group).height;
      expect(settled, greaterThanOrEqualTo(3 * 32));
      expect(middle, lessThan(settled));
      expect(find.text('Salida b'), findsOneWidget);
      entries.value = [_entry('c'), _entry('a')];
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      entries.value = [_entry('b'), _entry('c'), _entry('a')];
      await tester.pump();
      expect(
        find.text('Salida b'),
        findsOneWidget,
        reason: 'exit interrupted, not cloned',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('turn-step-card-b')), findsOneWidget);
      expect(find.text('Salida b'), findsOneWidget);
    },
  );

  testWidgets('one reasoning owner while live, one opened body when settled', (
    tester,
  ) async {
    final paragraph =
        'Este párrafo tiene una sola copia aunque llegue como dos snapshots. ' *
        2;
    Widget content(bool active) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ThinkingTraceCard(
          active: active,
          stepCards: true,
          liveInPill: true,
          events: [
            _thought('r1', paragraph),
            _thought(
              'r2',
              '$paragraph Fin.',
              status: active ? 'running' : 'completed',
            ),
          ],
          headerBuilder: (_, summary, details) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [summary, details],
          ),
        ),
        if (active)
          LiveTurnPills(
            snapshot: ActivitySnapshot(
              turnActive: true,
              liveReasoning: '$paragraph Fin.',
            ),
            avatar: const SizedBox.square(dimension: 24),
          ),
      ],
    );
    await tester.pumpWidget(_host(content(true), reduced: true));
    expect(find.byKey(const ValueKey('turn-reasoning')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('live-turn-status')));
    await tester.pump();
    expect(find.byKey(const ValueKey('turn-reasoning')), findsOneWidget);
    await tester.pumpWidget(_host(content(false), reduced: true));
    await tester.pump();
    expect(find.byKey(const ValueKey('turn-reasoning')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('turn-thought-label')));
    await tester.pump();
    expect(find.byKey(const ValueKey('turn-reasoning')), findsOneWidget);
  });

  testWidgets(
    'reduced motion inserts/removes a run of steps in one frame, as one line',
    (tester) async {
      final entries = ValueNotifier<List<TurnStepCardEntry>>([]);
      addTearDown(entries.dispose);
      await tester.pumpWidget(
        _host(
          ValueListenableBuilder(
            valueListenable: entries,
            builder: (_, value, _) => TurnStepCards(entries: value),
          ),
          reduced: true,
        ),
      );
      entries.value = [for (var i = 0; i < 8; i++) _tool('$i')];
      await tester.pump();
      expect(find.text('Trabajó · Ejecutó 8 comandos'), findsOneWidget);
      for (var i = 0; i < 8; i++) {
        expect(find.byKey(ValueKey('turn-step-card-$i')), findsNothing);
      }
      entries.value = [];
      await tester.pump();
      await tester.pump();
      expect(_lineLabel(), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
