import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_task_list.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/live_turn_tokens.dart';
import 'package:hermes_android/core/widgets/chat/live_turn_window.dart';
import 'package:hermes_android/core/widgets/chat/turn_step_cards.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// The live turn's look approved on 9 nov 2026 (mock turno3.html, with
// the reinforced connector): the «Trabajando» card, a window of at most four
// actions hanging from it, the reasoning fragment, the tasks card. Only the
// look is pinned here: nothing about what a step is or when a turn ends.

final _start = DateTime(2026, 11, 9);
final _now = _start.add(const Duration(seconds: 75));

const _names = ['terminal', 'read_file', 'skill_view', 'web_search'];

Widget _host(Widget child, {bool reduced = true, double scale = 1}) =>
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromMode(AppThemeMode.dark),
      builder: (context, body) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduced,
          textScaler: TextScaler.linear(scale),
        ),
        child: body!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 380, child: SingleChildScrollView(child: child)),
        ),
      ),
    );

/// [done] finished tools of alternating names (never two alike in a row, so
/// nothing folds) and, when [running], one more in hand.
List<ChatTraceEvent> _events(int done, {bool running = true}) => [
  for (var i = 0; i < done; i++)
    ChatTraceEvent(
      id: 't$i',
      label: _names[i % _names.length],
      status: 'completed',
      detail: 'objetivo $i',
      duration: const Duration(milliseconds: 1500),
    ),
  if (running)
    ChatTraceEvent(
      id: 't$done',
      label: _names[done % _names.length],
      status: 'running',
      detail: 'en curso',
      startedAt: _start.add(const Duration(seconds: 70)),
    ),
];

Widget _turn(List<ChatTraceEvent> events, {AgentTaskList? tasks}) =>
    LiveTurnScope(
      inlineActivity: true,
      status: LiveTurnStatus(
        active: true,
        startedAt: _start,
        headline: 'Pensando…',
        tasks: tasks,
      ),
      clock: () => _now,
      child: ThinkingTraceCard(
        active: true,
        stepCards: true,
        events: events,
        headerBuilder: (_, summary, details) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [summary, details],
        ),
      ),
    );

Finder _keyed(String prefix) => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith(prefix),
);

AgentTaskList _plan(int done, int total, {bool current = true}) => AgentTaskList(
  revision: 1,
  items: [
    for (var i = 0; i < total; i++)
      AgentTaskItem(
        id: '${i + 1}',
        content: 'Tarea ${i + 1}',
        status: i < done
            ? AgentTaskStatus.completed
            : i == done && current
            ? AgentTaskStatus.inProgress
            : AgentTaskStatus.pending,
      ),
  ],
);

void main() {
  group('the window of actions', () {
    testWidgets('ten tools show at most four rows, never a fifth', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_turn(_events(10))));
      await tester.pump(const Duration(seconds: 1));
      expect(_keyed('live-turn-row-'), findsNWidgets(HermesLiveTurn.windowRows));
      // The newest four: t7 (done) .. t10 (in hand); t0..t6 are gone.
      expect(find.byKey(const ValueKey('live-turn-row-t10')), findsOneWidget);
      expect(find.byKey(const ValueKey('live-turn-row-t7')), findsOneWidget);
      expect(find.byKey(const ValueKey('live-turn-row-t6')), findsNothing);
    });

    testWidgets('the window does not grow as tools keep coming', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_turn(_events(2))));
      for (var n = 3; n <= 14; n++) {
        await tester.pumpWidget(_host(_turn(_events(n))));
        await tester.pump(const Duration(seconds: 1));
        expect(
          _keyed('live-turn-row-').evaluate().length,
          lessThanOrEqualTo(HermesLiveTurn.windowRows),
          reason: 'with $n tools',
        );
      }
    });

    testWidgets('with animations on, the old row leaves and the new enters', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_turn(_events(3)), reduced: false));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(_host(_turn(_events(4)), reduced: false));
      await tester.pump(const Duration(milliseconds: 100));
      // Mid-flight the leaving row may still be painted; once over, not.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_keyed('live-turn-row-'), findsNWidgets(HermesLiveTurn.windowRows));
      expect(find.byKey(const ValueKey('live-turn-row-t0')), findsNothing);
      expect(find.byKey(const ValueKey('live-turn-row-t4')), findsOneWidget);
    });

    testWidgets('one elbow per row, and one corner (the last row)', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_turn(_events(1))));
      await tester.pump(const Duration(seconds: 1));
      expect(_keyed('live-turn-elbow-'), findsNWidgets(2));
      await tester.pumpWidget(_host(_turn(_events(8))));
      await tester.pump(const Duration(seconds: 1));
      expect(_keyed('live-turn-elbow-'), findsNWidgets(4));
      final painters = tester
          .widgetList<CustomPaint>(_keyed('live-turn-elbow-'))
          .map((paint) => paint.painter.toString())
          .toList();
      expect(painters, hasLength(4));
    });

    testWidgets('a done row is a ring with its check inside, not a disc', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_turn(_events(3))));
      await tester.pump(const Duration(seconds: 1));
      // three done rows with a ring-check, the one in hand with a spinner
      expect(find.byKey(const ValueKey('live-ring-check')), findsNWidgets(3));
      expect(find.byKey(const ValueKey('live-ring-spinner')), findsWidgets);
      expect(find.byIcon(Icons.check_circle), findsNothing);
      expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
    });

    testWidgets('each row has the glyph of its kind of tool', (tester) async {
      await tester.pumpWidget(_host(_turn(_events(3))));
      await tester.pump(const Duration(seconds: 1));
      // terminal, read_file, skill_view done; web_search in hand.
      expect(
        find.byKey(const ValueKey('live-turn-glyph-terminal')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('live-turn-glyph-file')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('live-turn-glyph-skill')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('live-turn-glyph-other')),
        findsOneWidget,
      );
    });

    testWidgets('rows are 30 dp tall with 5 dp between them', (tester) async {
      await tester.pumpWidget(_host(_turn(_events(3))));
      await tester.pump(const Duration(seconds: 1));
      final first = tester.getRect(
        find.descendant(
          of: find.byKey(const ValueKey('live-turn-row-t0')),
          matching: find.byType(DecoratedBox),
        ).first,
      );
      final second = tester.getRect(
        find.descendant(
          of: find.byKey(const ValueKey('live-turn-row-t1')),
          matching: find.byType(DecoratedBox),
        ).first,
      );
      expect(first.height, HermesLiveTurn.rowHeight);
      expect(second.top - first.bottom, HermesLiveTurn.rowGap);
    });

    test('consecutive steps of one tool fold into one row «×N»', () {
      TurnStepCardEntry step(String id, {bool running = false}) =>
          TurnStepCardEntry(
            id: id,
            kind: TurnStepCardKind.tool,
            title: 'Ejecutó',
            detail: 'cmd $id',
            toolName: 'terminal',
            running: running,
            semanticsLabel: id,
          );
      final rows = liveTurnRows([
        for (var i = 0; i < 20; i++) step('c$i'),
        TurnStepCardEntry(
          id: 'f',
          kind: TurnStepCardKind.tool,
          title: 'Leyó',
          toolName: 'read_file',
          semanticsLabel: 'f',
        ),
      ]);
      expect(rows, hasLength(2));
      expect(rows.first.count, 20);
      expect(rows.first.name, 'Ejecutó ×20');
      expect(rows.first.detail, 'cmd c19');
      expect(rows.first.id, 'c0');
    });

    test('a failed step is never folded into a run', () {
      TurnStepCardEntry step(String id, {bool failed = false}) =>
          TurnStepCardEntry(
            id: id,
            kind: TurnStepCardKind.tool,
            title: 'Ejecutó',
            toolName: 'terminal',
            failed: failed,
            semanticsLabel: id,
          );
      final rows = liveTurnRows([step('a'), step('b', failed: true), step('c')]);
      expect(rows, hasLength(3));
    });
  });

  group('the «Trabajando» card', () {
    testWidgets('says Trabajando, the clock and the tool count, folded', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_turn(_events(4))));
      await tester.pump(const Duration(seconds: 1));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('chat-inline-activity-text')))
            .data,
        'Trabajando',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('chat-inline-activity-clock')))
            .data,
        '1:15',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('chat-inline-activity-count')))
            .data,
        '5 herramientas',
      );
      expect(find.byKey(const ValueKey('live-turn-card')), findsOneWidget);
    });

    testWidgets('a tap opens the whole list and the window steps aside', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_turn(_events(8))));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('live-turn-window')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chat-inline-activity')));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('live-turn-window')), findsNothing);
      expect(find.byKey(const ValueKey('turn-step-cards')), findsOneWidget);
    });
  });

  group('the reasoning', () {
    test('is small and quiet: 12.5 sp, a notch under the 15 sp reply', () {
      expect(TurnType.reasoning, 12.5);
    });

    test('a thought that repeats the answer being written is not shown', () {
      const said = 'Lo miro antes de contestar: dónde está el código.';
      expect(LiveReasoningSnippet.repeatsAnswer(said, said), isTrue);
      expect(LiveReasoningSnippet.repeatsAnswer('$said ', said), isTrue);
      expect(LiveReasoningSnippet.repeatsAnswer(said, '$said Y más.'), isTrue);
      expect(LiveReasoningSnippet.repeatsAnswer('$said Y más.', said), isTrue);
      expect(LiveReasoningSnippet.repeatsAnswer(said, ''), isFalse);
      expect(LiveReasoningSnippet.repeatsAnswer('', said), isFalse);
      expect(LiveReasoningSnippet.repeatsAnswer('Otra idea', said), isFalse);
    });

    test('the fragment is the tail of the last line, without Markdown', () {
      expect(
        LiveReasoningSnippet.fragment('**Plan**\n\nRevisar la `rama` actual\n'),
        'Revisar la rama actual',
      );
      final long = 'palabra ' * 40;
      final fragment = LiveReasoningSnippet.fragment('x\n$long');
      expect(fragment.startsWith('…'), isTrue);
      expect(fragment.length, lessThanOrEqualTo(HermesLiveTurn.thoughtChars + 1));
    });

    testWidgets('live fragment: italic, 12.5 sp, no bar, with a cursor', (
      tester,
    ) async {
      final events = [
        ChatTraceEvent(
          id: 'r',
          label: 'Razonamiento',
          status: 'running',
          kind: ChatTraceEventKind.reasoning,
          preview: '**Reviso el relay**\nMiro la configuración del relay aislado',
        ),
        ..._events(1),
      ];
      await tester.pumpWidget(_host(_turn(events)));
      await tester.pump(const Duration(seconds: 1));
      final finder = find.descendant(
        of: find.byKey(const ValueKey('live-turn-fragment')),
        matching: find.byType(RichText),
      );
      final text = tester.widget<RichText>(finder.first);
      expect(text.text.toPlainText(), contains('Miro la configuración'));
      expect(text.text.style!.fontSize, 12.5);
      expect(text.text.style!.fontStyle, FontStyle.italic);
      expect(text.text.style!.fontWeight, isNot(FontWeight.w700));
      expect(text.maxLines, 2);
      expect(find.byKey(const ValueKey('live-turn-cursor')), findsOneWidget);
    });
  });

  group('the tasks card', () {
    Future<void> pumpTasks(WidgetTester tester, AgentTaskList tasks) async {
      await tester.pumpWidget(_host(TurnTasksLive(tasks: tasks)));
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('shows the last done, the one in hand and the next two', (
      tester,
    ) async {
      await pumpTasks(tester, _plan(4, 9));
      expect(find.byKey(const ValueKey('turn-task-4')), findsOneWidget);
      expect(find.byKey(const ValueKey('turn-task-5')), findsOneWidget);
      expect(find.byKey(const ValueKey('turn-task-6')), findsOneWidget);
      expect(find.byKey(const ValueKey('turn-task-7')), findsOneWidget);
      expect(find.byKey(const ValueKey('turn-task-8')), findsNothing);
      expect(find.byKey(const ValueKey('turn-task-1')), findsNothing);
      expect(find.text('Tareas 4/9'), findsOneWidget);
      expect(find.text('3 anteriores completadas'), findsOneWidget);
    });

    testWidgets('«n anteriores completadas» opens the earlier ones', (
      tester,
    ) async {
      await pumpTasks(tester, _plan(4, 9));
      await tester.tap(find.byKey(const ValueKey('turn-tasks-done-toggle')));
      await tester.pump(const Duration(seconds: 1));
      for (final id in ['1', '2', '3', '4']) {
        expect(find.byKey(ValueKey('turn-task-$id')), findsOneWidget);
      }
    });

    testWidgets('advancing the plan moves the window', (tester) async {
      await pumpTasks(tester, _plan(4, 9));
      await pumpTasks(tester, _plan(5, 9));
      expect(find.byKey(const ValueKey('turn-task-5')), findsOneWidget);
      expect(find.byKey(const ValueKey('turn-task-6')), findsOneWidget);
      expect(find.byKey(const ValueKey('turn-task-8')), findsOneWidget);
      expect(find.byKey(const ValueKey('turn-task-4')), findsNothing);
      expect(find.text('4 anteriores completadas'), findsOneWidget);
    });

    testWidgets('nothing done yet: no fold line; all done: only the last', (
      tester,
    ) async {
      await pumpTasks(tester, _plan(0, 3));
      expect(find.byKey(const ValueKey('turn-tasks-done-toggle')), findsNothing);
      expect(find.byKey(const ValueKey('turn-task-1')), findsOneWidget);
      await pumpTasks(tester, _plan(3, 3, current: false));
      expect(find.byKey(const ValueKey('turn-task-3')), findsOneWidget);
      expect(find.byKey(const ValueKey('turn-task-2')), findsNothing);
      expect(find.text('2 anteriores completadas'), findsOneWidget);
    });

    testWidgets('with reduced animations the change is immediate', (
      tester,
    ) async {
      await tester.pumpWidget(_host(TurnTasksLive(tasks: _plan(4, 9))));
      await tester.pumpWidget(_host(TurnTasksLive(tasks: _plan(5, 9))));
      await tester.pump();
      expect(find.byKey(const ValueKey('turn-task-4')), findsNothing);
      expect(find.byKey(const ValueKey('turn-task-8')), findsOneWidget);
    });
  });

  testWidgets('a settled turn keeps its one line, with ring and check', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        LiveTurnScope(
          inlineActivity: true,
          status: LiveTurnStatus.idle,
          clock: () => _now,
          child: ThinkingTraceCard(
            active: false,
            stepCards: true,
            events: _events(3, running: false),
            duration: const Duration(seconds: 75),
            headerBuilder: (_, summary, details) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [summary, details],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('live-turn-window')), findsNothing);
    expect(find.byKey(const ValueKey('live-ring-check')), findsOneWidget);
  });
}
