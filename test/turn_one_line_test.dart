// the owner, APK 9800: a turn of thinking and tools piled eight folded lines of its
// own, some with a standing fill. Under the agent's name everything before the
// reply is ONE compact folded line; the thoughts («Pensó 3 s») and the tools
// are inside, in order.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/live_motion.dart';
import 'package:hermes_android/core/widgets/chat/tool_steps_summary.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host(Widget child, {bool reduceMotion = false}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(padding: const EdgeInsets.all(12), child: child),
    ),
  ),
);

final _t0 = DateTime(2026, 10, 31, 21, 14);

ChatTraceEvent _thought(int cycle, {String? text, bool running = false}) =>
    ChatTraceEvent(
      id: 'r$cycle',
      label: 'Razonamiento',
      status: running ? 'running' : 'completed',
      kind: ChatTraceEventKind.reasoning,
      preview: text ?? '**Checking router DNS $cycle**\nLeo la config $cycle.',
      // No duration from the gateway: it is the gap up to the next step.
      startedAt: _t0.add(Duration(seconds: cycle * 20)),
    );

ChatTraceEvent _tool(
  int cycle,
  int n, {
  String status = 'completed',
  bool running = false,
}) => ChatTraceEvent(
  id: 't$cycle$n',
  label: 'terminal',
  status: running ? 'running' : status,
  detail: 'ping $cycle$n',
  startedAt: _t0.add(Duration(seconds: cycle * 20 + 5 + n)),
  duration: running ? null : const Duration(milliseconds: 900),
);

Widget _turn(List<ChatTraceEvent> events, {required bool active}) =>
    ThinkingTraceCard(
      events: events,
      active: active,
      liveInPill: false,
      stepCards: true,
      duration: active ? null : const Duration(seconds: 95),
      headerBuilder: (context, summary, details) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [const Text('xPeta'), details],
      ),
    );

List<ChatTraceEvent> _fourCycles() => [
  for (var cycle = 1; cycle <= 4; cycle++) ...[
    _thought(cycle),
    for (var n = 1; n <= cycle; n++) _tool(cycle, n),
  ],
];

final _lineLabel = find.byKey(const ValueKey('turn-line-label'));
final _thoughtLabel = find.byKey(const ValueKey('turn-thought-label'));

void main() {
  setUp(StepsBarMemory.reset);

  testWidgets('4 cycles think -> tools: exactly ONE folded row, compact, with '
      'no standing fill', (tester) async {
    await tester.pumpWidget(_host(_turn(_fourCycles(), active: false)));
    await tester.pumpAndSettle();
    expect(_lineLabel, findsOneWidget);
    expect(_thoughtLabel, findsNothing);
    expect(find.text('Pensamiento'), findsNothing);
    expect(find.textContaining('Ejecutó 10 comandos'), findsOneWidget);
    expect(find.textContaining('Trabajó'), findsOneWidget);
    final line = find.byKey(const ValueKey('turn-line-r1'));
    expect(tester.getSize(line).height, lessThanOrEqualTo(44));
    for (final box in tester.widgetList<DecoratedBox>(
      find.descendant(of: line, matching: find.byType(DecoratedBox)),
    )) {
      final decoration = box.decoration;
      if (decoration is BoxDecoration) expect(decoration.color, isNull);
    }
    for (final material in tester.widgetList<Material>(
      find.descendant(of: line, matching: find.byType(Material)),
    )) {
      expect(material.color ?? Colors.transparent, Colors.transparent);
    }
    // No hover or focus fill stays on the row: only a press tints it.
    final ink = tester.widget<InkWell>(
      find.descendant(of: line, matching: find.byType(InkWell)).first,
    );
    expect(
      ink.overlayColor!.resolve({WidgetState.focused, WidgetState.hovered}),
      Colors.transparent,
    );
    expect(
      ink.overlayColor!.resolve({WidgetState.pressed}),
      isNot(Colors.transparent),
    );
  });

  testWidgets('opened: the four thoughts with their time and the ten tools, '
      'in the real order; no markdown marks', (tester) async {
    await tester.pumpWidget(_host(_turn(_fourCycles(), active: false)));
    await tester.pumpAndSettle();
    await tester.tap(_lineLabel);
    await tester.pumpAndSettle();
    // No time from the gateway: the gap up to the step that followed.
    expect(find.text('Pensó 6 s'), findsNWidgets(4));
    final ys = [
      tester.getTopLeft(find.byKey(const ValueKey('turn-inner-thought-r1'))).dy,
      tester.getTopLeft(find.byKey(const ValueKey('turn-step-card-t11'))).dy,
      tester.getTopLeft(find.byKey(const ValueKey('turn-inner-thought-r2'))).dy,
      tester.getTopLeft(find.byKey(const ValueKey('turn-step-card-t21'))).dy,
      tester.getTopLeft(find.byKey(const ValueKey('turn-inner-thought-r4'))).dy,
      tester.getTopLeft(find.byKey(const ValueKey('turn-step-card-t44'))).dy,
    ];
    expect(ys, orderedEquals([...ys]..sort()));
    await tester.tap(find.byKey(const ValueKey('turn-inner-thought-label-r1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Checking router DNS 1'), findsOneWidget);
    expect(find.textContaining('**'), findsNothing);
  });

  testWidgets('a turn that only thought is ONE «Pensó 20 s ›» line', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _turn([
          _thought(1).copyForTest(duration: const Duration(seconds: 20)),
        ], active: false),
      ),
    );
    await tester.pumpAndSettle();
    expect(_lineLabel, findsNothing);
    expect(tester.widget<Text>(_thoughtLabel).data, 'Pensó 1:35');
  });

  testWidgets('a failed tool anywhere puts the red cross on the one line', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _turn([
          _thought(1),
          _tool(1, 1),
          _thought(2),
          _tool(2, 1, status: 'failed'),
          _tool(2, 2),
        ], active: false),
      ),
    );
    await tester.pumpAndSettle();
    expect(_lineLabel, findsOneWidget);
    expect(
      tester.widget<LiveResultMark>(find.byType(LiveResultMark)).ok,
      isFalse,
    );
  });

  testWidgets('live: the line holds what is done, a folded «Pensamiento» '
      'sits under it: no fragment of the thought, no second «Pensando»', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _turn([
          _thought(1),
          _tool(1, 1),
          _thought(2, text: '**Checking router DNS**', running: true),
        ], active: true),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(_lineLabel, findsNothing);
    expect(find.byKey(const ValueKey('turn-step-card-t11')), findsOneWidget);
    expect(tester.widget<Text>(_thoughtLabel).data, 'Pensamiento');
    expect(find.text('Pensando'), findsNothing);
    expect(
      find.textContaining('Checking router', findRichText: true),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('turn-reasoning')), findsNothing);
    // Opened, the thought reads clean: no asterisks.
    await tester.tap(_thoughtLabel);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('**', findRichText: true), findsNothing);
    expect(
      find.textContaining('Checking router DNS', findRichText: true),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('turn-step-card-t11'))).dy,
      lessThan(tester.getTopLeft(_thoughtLabel).dy),
    );
  });

  testWidgets('reduced motion: no ticker, one line, opens in one frame', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_turn(_fourCycles(), active: false), reduceMotion: true),
    );
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    await tester.tap(_lineLabel);
    await tester.pump();
    expect(find.byKey(const ValueKey('turn-line-group')), findsOneWidget);
    expect(_lineLabel, findsOneWidget);
  });
}

extension on ChatTraceEvent {
  ChatTraceEvent copyForTest({Duration? duration}) => ChatTraceEvent(
    id: id,
    label: label,
    status: status,
    kind: kind,
    preview: preview,
    startedAt: startedAt,
    duration: duration,
  );
}
