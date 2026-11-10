// The turn as ONE light line. Everything already done (thoughts and tools, in
// order) folds into «Trabajó 12 s · 5 pasos ›» (a turn that only thought is
// «Pensó 2 s ›»), opened by a tap into «Pensó 3 s ›» rows and the tools'
// timeline (round mark, bold verb, a chip with the target, the time). What is
// in hand sits under that line: «Pensando» with the brain beating, or the step
// turning. Open or closed is remembered by the first step's id. Attachments
// and outcomes stay visible.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/tool_steps_summary.dart';
import 'package:hermes_android/core/widgets/chat/turn_step_cards.dart';
import 'package:hermes_android/core/widgets/chat/live_motion.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host(
  List<TurnStepCardEntry> entries, {
  bool live = false,
  Duration? duration,
  double width = 412,
  double textScale = 1,
  bool reduceMotion = false,
  Key? key,
}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: reduceMotion,
    ),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 40, 16, 40),
        child: SizedBox(
          width: width - 28,
          child: TurnStepCards(
            key: key,
            entries: entries,
            live: live,
            duration: duration,
          ),
        ),
      ),
    ),
  ),
);

TurnStepCardEntry _tool(
  String id, {
  String title = 'Ejecutó',
  String? detail = 'cp maqueta.html /tmp',
  String toolName = 'terminal',
  bool running = false,
  bool failed = false,
  String? durationText,
  Widget? attachment,
}) => TurnStepCardEntry(
  id: id,
  kind: TurnStepCardKind.tool,
  title: title,
  detail: detail,
  toolName: toolName,
  running: running,
  failed: failed,
  durationText: durationText,
  semanticsLabel: '$title, $detail',
  opened: Text('salida $id', key: ValueKey('out-$id')),
  attachment: attachment,
);

TurnStepCardEntry _thought(
  String id, {
  bool running = false,
  String? text,
  String? durationText,
  Duration? duration,
}) => TurnStepCardEntry(
  id: id,
  kind: TurnStepCardKind.thought,
  title: 'Pensó',
  semanticsLabel: 'Pensó',
  running: running,
  text: text,
  durationText: durationText,
  duration: duration,
  opened: Text('idea $id', key: ValueKey('idea-$id')),
);

TurnStepCardEntry _outcome() => const TurnStepCardEntry(
  id: 'outcome',
  kind: TurnStepCardKind.outcome,
  title: 'Detenido',
  icon: Icons.stop_circle_outlined,
  semanticsLabel: 'Detenido',
);

Finder _line() => find.byKey(const ValueKey('turn-line-label'));
Finder _group() => find.byKey(const ValueKey('turn-line-group'));
Finder _thoughtLabel() => find.byKey(const ValueKey('turn-thought-label'));
String _label(WidgetTester tester) => tester.widget<Text>(_line()).data!;

void main() {
  setUp(StepsBarMemory.reset);

  for (final count in [1, 3, 30]) {
    testWidgets('a run of $count tools is one closed line', (tester) async {
      await tester.pumpWidget(
        _host([for (var i = 0; i < count; i++) _tool('t$i')]),
      );
      await tester.pumpAndSettle();
      expect(_line(), findsOneWidget);
      expect(
        _label(tester),
        count == 1
            ? 'Trabajó · Ejecutó 1 comando'
            : 'Trabajó · Ejecutó $count comandos',
      );
      expect(_group(), findsNothing);
      expect(find.text('Ejecutó'), findsNothing);
      // Went well: a green check, not a brain.
      expect(find.byKey(const ValueKey('turn-line-mark')), findsOneWidget);
      expect(find.byType(LiveBrain), findsNothing);
    });
  }

  testWidgets('a thought and the tools around it are ONE line, in order', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([
        _thought(
          'a',
          duration: const Duration(seconds: 3),
          durationText: '3 s',
        ),
        _tool('b'),
        _thought('c'),
        _tool('d', title: 'Leyó'),
      ]),
    );
    expect(_thoughtLabel(), findsNothing);
    expect(_line(), findsOneWidget);
    expect(_label(tester), 'Trabajó · Ejecutó 2 comandos');
    await tester.tap(_line());
    await tester.pumpAndSettle();
    expect(_group(), findsOneWidget);
    final ys = [
      for (final key in [
        'turn-inner-thought-a',
        'turn-step-card-b',
        'turn-inner-thought-c',
        'turn-step-card-d',
      ])
        tester.getTopLeft(find.byKey(ValueKey(key))).dy,
    ];
    expect(ys, orderedEquals([...ys]..sort()));
    expect(ys.toSet().length, 4);
    expect(find.text('Pensó 3 s'), findsOneWidget);
    expect(find.text('Pensó'), findsOneWidget);
    // Each tool row is one line of text.
    expect(
      tester.getSize(find.byKey(const ValueKey('turn-step-card-b'))).height,
      lessThanOrEqualTo(48),
    );
  });

  testWidgets('a step row opens its own detail', (tester) async {
    await tester.pumpWidget(_host([_thought('a'), _tool('b')]));
    await tester.tap(_line());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('out-b')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('turn-step-card-b')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('out-b')), findsOneWidget);
    expect(find.byKey(const ValueKey('idea-a')), findsNothing);
  });

  testWidgets('a live step row: mark, verb, safe target and time', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([
        _tool('a', durationText: '0,9 s', detail: 'rtve.es'),
        _tool('b', failed: true, detail: 'efe.com'),
        _tool('c', running: true, detail: 'noticias hoy'),
      ], live: true),
    );
    await tester.pump(const Duration(milliseconds: 500));
    // The two recent results remain beside the current action.
    expect(_line(), findsNothing);
    expect(find.text('0,9 s'), findsOneWidget);
    expect(find.text('rtve.es'), findsOneWidget);
    expect(find.text('Fallido'), findsOneWidget);
    for (final id in ['a', 'b', 'c']) {
      expect(find.byKey(ValueKey('turn-step-mark-$id')), findsOneWidget);
    }
    final verb = tester.widget<Text>(find.text('Ejecutó').first);
    expect(verb.style!.fontWeight, FontWeight.w500);
    // The mark sits before the verb, the time after it.
    final mark = tester.getRect(find.byKey(const ValueKey('turn-step-mark-a')));
    final time = tester.getRect(find.text('0,9 s'));
    expect(
      mark.right,
      lessThan(tester.getRect(find.text('Ejecutó').first).left),
    );
    expect(time.left, greaterThan(tester.getRect(find.text('rtve.es')).right));
    await tester.pumpWidget(
      _host([
        _tool('a', durationText: '0,9 s', detail: 'rtve.es'),
        _tool('b', failed: true, detail: 'efe.com'),
        _tool('c', detail: 'noticias hoy'),
      ], reduceMotion: true),
    );
    await tester.pumpAndSettle();
    await tester.tap(_line());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('turn-step-card-a')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('out-a')), findsOneWidget);
    expect(find.text('Fallido'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('Ejecutó').first).style!.fontWeight,
      FontWeight.w700,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('live: recent results and the current action stay visible', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([
        _thought('a'),
        _tool('b'),
        _tool(
          'c',
          title: 'Leyó',
          detail: 'main.dart',
          toolName: 'read_file',
          running: true,
        ),
      ], live: true),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(_line(), findsNothing);
    expect(find.byKey(const ValueKey('turn-step-card-b')), findsOneWidget);
    expect(find.byKey(const ValueKey('turn-step-card-c')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('turn-step-card-b'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('turn-step-card-c'))).dy,
      ),
    );
    expect(
      tester.binding.transientCallbackCount,
      greaterThan(0),
      reason: 'the one shared clock runs while a step is in hand',
    );
  });

  testWidgets(
    'a thought being written is ONE closed row, as tall as «Trabajó», '
    'with no fragment of its text and no second «Pensando»',
    (tester) async {
      await tester.pumpWidget(_host([_tool('w')], reduceMotion: true));
      await tester.pumpAndSettle();
      final worked = tester.getRect(find.byKey(const ValueKey('turn-line-w')));
      final workedStyle = tester.widget<Text>(_line()).style!;
      await tester.pumpWidget(
        _host([
          _tool('w'),
          _thought(
            'a',
            running: true,
            text:
                'Primero leo los cambios de la rama; luego reparto tests y '
                'notas entre agentes.',
          ),
        ], live: true),
      );
      await tester.pump(const Duration(milliseconds: 500));
      // The header's pill says «Pensando»: the row says what it holds.
      expect(tester.widget<Text>(_thoughtLabel()).data, 'Pensamiento');
      expect(find.text('Pensando'), findsNothing);
      expect(find.byType(LiveBrain), findsOneWidget);
      // No italic fragment of the thought under it, folded.
      expect(find.byKey(const ValueKey('turn-thought-tail')), findsNothing);
      expect(find.textContaining('Primero leo'), findsNothing);
      expect(find.byKey(const ValueKey('idea-a')), findsNothing);
      expect(find.byKey(const ValueKey('turn-step-opened-a')), findsNothing);
      // The same height, ink and weight as the folded «Trabajó · N pasos ›».
      final row = tester.getRect(find.byKey(const ValueKey('turn-thought-a')));
      expect(row.height, worked.height);
      expect(row.height, TurnStepCards.lineHeight);
      final rowStyle = tester.widget<Text>(_thoughtLabel()).style!;
      expect(rowStyle.fontSize, workedStyle.fontSize);
      expect(rowStyle.fontWeight, workedStyle.fontWeight);
      expect(rowStyle.fontStyle, isNot(FontStyle.italic));
      // It opens on a tap into the thought, and folds back.
      await tester.tap(_thoughtLabel());
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('idea-a')), findsOneWidget);
      await tester.tap(_thoughtLabel());
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('idea-a')), findsNothing);
    },
  );

  testWidgets('a thought that is over folds to «Pensó 2 s ›»: brain still and '
      'dim, never a check', (tester) async {
    await tester.pumpWidget(
      _host([_thought('a', durationText: '2 s')], reduceMotion: true),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(_thoughtLabel()).data, 'Pensó 2 s');
    expect(find.byType(LiveBrain), findsOneWidget);
    expect(tester.widget<LiveBrain>(find.byType(LiveBrain)).quiet, isTrue);
    expect(find.byType(LiveResultMark), findsNothing);
    expect(find.byKey(const ValueKey('idea-a')), findsNothing);
    await tester.tap(_thoughtLabel());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('idea-a')), findsOneWidget);
  });

  testWidgets(
    'live turns into worked: the timeline folds, then opens on a tap',
    (tester) async {
      await tester.pumpWidget(
        _host([_tool('a', running: true)], live: true, key: const Key('k')),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(_group(), findsOneWidget);
      await tester.pumpWidget(
        _host(
          [_tool('a'), _tool('b')],
          duration: const Duration(seconds: 12),
          key: const Key('k'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(_label(tester), 'Trabajó 0:12 · Ejecutó 2 comandos');
      expect(_group(), findsNothing);
      await tester.tap(_line());
      await tester.pumpAndSettle();
      expect(_group(), findsOneWidget);
    },
  );

  testWidgets('open state is remembered by the first step after a rebuild', (
    tester,
  ) async {
    final entries = [_tool('first'), _tool('second')];
    await tester.pumpWidget(_host(entries));
    await tester.tap(_line());
    await tester.pumpAndSettle();
    expect(StepsBarMemory.recorded('first'), isTrue);
    // Rebuilt from scratch (another list view, a reconnect).
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_host([...entries, _tool('third')]));
    await tester.pumpAndSettle();
    expect(_group(), findsOneWidget);
    await tester.tap(_line());
    await tester.pumpAndSettle();
    expect(_group(), findsNothing);
    expect(StepsBarMemory.recorded('first'), isFalse);
  });

  testWidgets('a card that asks for an answer stays visible under a closed '
      'line, and an outcome keeps its card', (tester) async {
    await tester.pumpWidget(
      _host([
        _tool(
          'ask',
          attachment: const SizedBox(
            key: ValueKey('approval-card'),
            width: double.infinity,
            height: 60,
          ),
        ),
        _tool('b'),
        _outcome(),
      ]),
    );
    await tester.pumpAndSettle();
    expect(_group(), findsNothing);
    expect(find.byKey(const ValueKey('approval-card')), findsOneWidget);
    expect(find.text('Detenido'), findsOneWidget);
    expect(_line(), findsOneWidget);
  });

  testWidgets('reduced motion: no ticker at all, the live timeline is still', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        [
          _thought('t', running: true, text: 'pienso'),
          _tool('a', running: true),
        ],
        live: true,
        reduceMotion: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    expect(find.byKey(const ValueKey('turn-thought-sheen')), findsOneWidget);
    expect(_group(), findsOneWidget);
  });

  testWidgets('large text on a narrow window does not overflow', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        [
          for (var i = 0; i < 6; i++)
            _tool('t$i', detail: 'un comando larguísimo ' * 6),
        ],
        width: 240,
        textScale: 2,
        live: true,
        reduceMotion: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_line(), findsNothing);
    expect(_group(), findsOneWidget);
    expect(find.byKey(const ValueKey('turn-step-card-t0')), findsNothing);
    for (final id in ['t3', 't4', 't5']) {
      expect(find.byKey(ValueKey('turn-step-card-$id')), findsOneWidget);
    }
    await tester.pumpWidget(
      _host(
        [
          for (var i = 0; i < 6; i++)
            _tool('t$i', detail: 'un comando larguísimo ' * 6),
        ],
        width: 240,
        textScale: 2,
        reduceMotion: true,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(_line());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (var i = 0; i < 6; i++) {
      expect(find.byKey(ValueKey('turn-step-card-t$i')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('turn-step-card-t5')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('out-t5')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a turn that only thought is one «Pensó 4 s ›» line', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([
        _thought('a', duration: const Duration(seconds: 3)),
        _thought('b', duration: const Duration(seconds: 1)),
      ]),
    );
    await tester.pumpAndSettle();
    expect(_line(), findsNothing);
    expect(_thoughtLabel(), findsOneWidget);
    expect(tester.widget<Text>(_thoughtLabel()).data, 'Pensó 0:04');
  });

  testWidgets('a thought without a known time says «Pensó ›»', (tester) async {
    await tester.pumpWidget(_host([_thought('a')]));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(_thoughtLabel()).data, 'Pensó');
    expect(find.text('Pensamiento'), findsNothing);
  });

  testWidgets('a failed step turns the folded line red with a cross', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([_thought('a'), _tool('b'), _tool('c', failed: true)]),
    );
    await tester.pumpAndSettle();
    expect(_label(tester), 'Trabajó · Ejecutó 2 comandos · 1 falló');
    expect(
      tester.widget<LiveResultMark>(find.byType(LiveResultMark)).ok,
      isFalse,
    );
  });

  testWidgets('a thought being written stays folded: no open quote, even if '
      'the reader\'s setting asked for it open', (tester) async {
    await tester.pumpWidget(
      _host([
        TurnStepCardEntry(
          id: 'a',
          kind: TurnStepCardKind.thought,
          title: 'Pensando',
          semanticsLabel: 'Pensando',
          running: true,
          initiallyOpen: true,
          text: '**Checking router DNS**\nProbando la ruta.',
          opened: const Text('cita completa', key: ValueKey('quote-a')),
        ),
      ], live: true),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('quote-a')), findsNothing);
    // Folded: no fragment of the thought, only the row.
    expect(find.textContaining('*'), findsNothing);
    expect(find.textContaining('Checking router DNS'), findsNothing);
    expect(find.byKey(const ValueKey('turn-thought-label')), findsOneWidget);
  });

  testWidgets('the folded line is compact and has no standing fill', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([_thought('a'), _tool('b')], reduceMotion: true),
    );
    await tester.pumpAndSettle();
    final line = find.byKey(const ValueKey('turn-line-a'));
    expect(
      tester.getSize(line).height,
      lessThanOrEqualTo(TurnStepCards.lineHeight),
    );
    for (final box in tester.widgetList<DecoratedBox>(
      find.descendant(of: line, matching: find.byType(DecoratedBox)),
    )) {
      final decoration = box.decoration;
      if (decoration is BoxDecoration) {
        expect(decoration.color, isNull);
      }
    }
    for (final material in tester.widgetList<Material>(
      find.descendant(of: line, matching: find.byType(Material)),
    )) {
      expect(material.color ?? Colors.transparent, Colors.transparent);
    }
  });
}
