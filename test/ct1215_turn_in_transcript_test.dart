import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/agent_task_list.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/agent_task_widgets.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/core/widgets/compact_markdown.dart';
import 'package:hermes_android/core/widgets/message_avatar_header.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/design_shots.dart' show loadDesignFonts;

// ct1215 · «C1 — como Desktop»: what Hermes is doing is told inside its turn
// in the transcript. While it works: one status line and, in loose lines,
// the thought being written, the tool in hand and the plan in flight. When
// it ends: at most two quiet lines that open.

final _start = DateTime(2026, 10, 11, 12);

AgentTaskList _plan(List<AgentTaskStatus> statuses) => AgentTaskList(
  revision: 1,
  items: [
    for (final (index, status) in statuses.indexed)
      AgentTaskItem(
        id: '${index + 1}',
        content: 'Tarea ${index + 1} del plan, con un texto algo largo',
        status: status,
      ),
  ],
);

final _fourOfFive = _plan(const [
  AgentTaskStatus.completed,
  AgentTaskStatus.completed,
  AgentTaskStatus.completed,
  AgentTaskStatus.inProgress,
  AgentTaskStatus.pending,
]);

Widget _host(
  Widget child, {
  Locale locale = const Locale('es'),
  double width = 380,
  double textScale = 1,
  bool disableAnimations = false,
  LiveTurnStatus? status,
  Duration elapsed = const Duration(seconds: 7),
  AgentTaskList? ownedTasks,
  String? ownerStepId,
}) {
  Widget body = child;
  if (ownedTasks != null) {
    body = AgentTaskScope(
      tasks: ownedTasks,
      ownerStepId: ownerStepId,
      child: body,
    );
  }
  if (status != null) {
    body = LiveTurnScope(
      status: status,
      clock: () => _start.add(elapsed),
      child: body,
    );
  }
  return MaterialApp(
    locale: locale,
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    theme: AppTheme.hermesRedDark,
    home: MediaQuery(
      data: MediaQueryData(
        size: Size(width, 800),
        textScaler: TextScaler.linear(textScale),
        disableAnimations: disableAnimations,
      ),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: SingleChildScrollView(child: body),
          ),
        ),
      ),
    ),
  );
}

/// The card as the chat places it: the summary under the name (no face in
/// a chat with one speaker), the details below it; [actions] header buttons
/// of 48 dp at the end, as copy and regenerate.
Widget _turn(
  List<ChatTraceEvent> events, {
  required bool active,
  Duration? duration = const Duration(seconds: 9),
  bool stopped = false,
  int actions = 0,
}) => ThinkingTraceCard(
  events: events,
  active: active,
  liveInPill: true,
  stopped: stopped,
  duration: active ? null : duration,
  headerBuilder: (context, summary, details) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      MessageAvatarHeader(
        name: 'Hermes',
        subtitle: summary,
        actions: [
          for (var i = 0; i < actions; i++)
            const SizedBox.square(dimension: 48),
        ],
      ),
      details,
    ],
  ),
);

ChatTraceEvent _thought(String id, String text, {bool running = false}) =>
    ChatTraceEvent(
      id: id,
      label: 'Razonamiento',
      status: running ? 'running' : 'completed',
      kind: ChatTraceEventKind.reasoning,
      preview: text,
    );

ChatTraceEvent _tool(
  String id,
  String tool, {
  String? detail,
  String status = 'completed',
  Duration? duration = const Duration(milliseconds: 1100),
  DateTime? startedAt,
  String? title,
}) => ChatTraceEvent(
  id: id,
  label: tool,
  status: status,
  detail: detail,
  duration: status == 'running' ? null : duration,
  startedAt: startedAt,
  title: title,
);

LiveTurnStatus _live({
  String? headline = 'Pensando…',
  ActivityStep? step,
  bool waitingForUser = false,
  bool noActivityHint = false,
  AgentTaskList? tasks,
}) => LiveTurnStatus(
  active: true,
  startedAt: _start,
  headline: headline,
  step: step,
  waitingForUser: waitingForUser,
  noActivityHint: noActivityHint,
  tasks: tasks,
);

ActivityStep _runningStep(
  String label, {
  ActivityStepKind kind = ActivityStepKind.tool,
  String? title,
}) => ActivityStep(
  id: 'step',
  kind: kind,
  label: label,
  status: ActivityStepStatus.running,
  title: title,
);

/// What the status line says (its timer is tied to the last word with
/// no-break spaces; read here as plain ones).
String _statusText(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('turn-status-text')))
    .textSpan!
    .toPlainText()
    .replaceAll('\u00A0', ' ');

/// Font size the first run of [phrase] is painted with.
double? _paintedSize(WidgetTester tester, String phrase) {
  double? walk(InlineSpan span, double? inherited) {
    if (span is! TextSpan) return null;
    final size = span.style?.fontSize ?? inherited;
    if ((span.text ?? '').contains(phrase)) return size;
    for (final child in span.children ?? const <InlineSpan>[]) {
      final found = walk(child, size);
      if (found != null) return found;
    }
    return null;
  }

  for (final text in tester.widgetList<RichText>(find.byType(RichText))) {
    final found = walk(text.text, null);
    if (found != null) return found;
  }
  return null;
}

void main() {
  group('status line', () {
    testWidgets('state · step in plain words · timer', (tester) async {
      await tester.pumpWidget(
        _host(
          _turn([_tool('t', 'terminal', status: 'running')], active: true),
          status: _live(step: _runningStep('terminal')),
        ),
      );
      expect(_statusText(tester), 'Trabajando · Ejecutando comando · 0:07');
      // If the line wraps, the timer goes down with the last word.
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('turn-status-text')))
            .textSpan!
            .toPlainText(),
        endsWith('comando\u00A0·\u00A00:07'),
      );
      // English, Desktop's own words.
      await tester.pumpWidget(
        _host(
          _turn([_tool('t', 'terminal', status: 'running')], active: true),
          locale: const Locale('en'),
          status: _live(step: _runningStep('terminal')),
        ),
      );
      await tester.pump();
      expect(_statusText(tester), 'Working · Running command · 0:07');
    });

    testWidgets('thinking, replying, waiting for the user, still working', (
      tester,
    ) async {
      Future<String> text(LiveTurnStatus status) async {
        await tester.pumpWidget(
          _host(_turn(const [], active: true), status: status),
        );
        return _statusText(tester);
      }

      expect(await text(_live()), 'Pensando · 0:07');
      expect(
        await text(_live(headline: 'Respondiendo…')),
        'Respondiendo · 0:07',
      );
      expect(
        await text(_live(waitingForUser: true)),
        'Esperando tu respuesta · 0:07',
      );
      expect(await text(_live(noActivityHint: true)), 'Sigo trabajando · 0:07');
    });

    testWidgets('a skill goes by its name, a connector by its own label', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _turn(const [], active: true),
          status: _live(
            step: _runningStep(
              'github-pr-workflow',
              kind: ActivityStepKind.skill,
            ),
          ),
        ),
      );
      expect(_statusText(tester), 'Trabajando · github-pr-workflow · 0:07');
      await tester.pumpWidget(
        _host(
          _turn(const [], active: true),
          status: _live(step: _runningStep('mcp__linear__list_issues')),
        ),
      );
      expect(_statusText(tester), 'Trabajando · Linear · list issues · 0:07');
      // No id with underscores reaches the line.
      expect(_statusText(tester), isNot(contains('_')));
    });

    testWidgets('a polite live region: the state, never the seconds', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _turn(const [], active: true),
          status: _live(step: _runningStep('read_file')),
        ),
      );
      final node = tester.getSemantics(
        find.byKey(const ValueKey('turn-status-line')),
      );
      expect(node.flagsCollection.isLiveRegion, isTrue);
      expect(node.label, 'Trabajando, Leyendo archivo');
      expect(node.label, isNot(contains('0:')));
    });

    testWidgets('the timer counts in place', (tester) async {
      var elapsed = const Duration(seconds: 7);
      Widget build() => _host(
        _turn(const [], active: true),
        status: _live(),
        elapsed: elapsed,
      );
      await tester.pumpWidget(build());
      expect(_statusText(tester), 'Pensando · 0:07');
      elapsed = const Duration(seconds: 68);
      await tester.pumpWidget(build());
      await tester.pump(const Duration(seconds: 1));
      expect(_statusText(tester), 'Pensando · 1:08');
    });
  });

  group('while it works', () {
    testWidgets('thought, tool in hand and plan, in that order, no card', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _turn([
            _thought('r', 'Me pide probar también la lista de tareas.'),
            _tool('a', 'terminal', detail: 'echo'),
            _tool(
              'b',
              'terminal',
              detail: 'df',
              status: 'running',
              startedAt: _start.add(const Duration(seconds: 5)),
            ),
          ], active: true),
          status: _live(step: _runningStep('terminal'), tasks: _fourOfFive),
        ),
      );
      final lines = find.byKey(const ValueKey('thinking-trace-live'));
      final thought = find.byKey(const ValueKey('turn-reasoning'));
      final row = find.byType(TurnToolRow);
      final tasks = find.byKey(const ValueKey('turn-tasks-live'));
      expect(find.descendant(of: lines, matching: thought), findsOneWidget);
      expect(row, findsOneWidget, reason: 'only the tool in hand');
      expect(find.text('Ejecutando · df', findRichText: true), findsOneWidget);
      expect(find.text('0:02'), findsOneWidget);
      expect(
        tester.getTopLeft(thought).dy,
        lessThan(tester.getTopLeft(row).dy),
      );
      expect(tester.getTopLeft(row).dy, lessThan(tester.getTopLeft(tasks).dy));
      // Loose lines: no card, and the thought is a rule on the left with
      // no surface behind it.
      expect(
        find.descendant(of: lines, matching: find.byType(Card)),
        findsNothing,
      );
      final quote =
          tester
                  .widget<DecoratedBox>(
                    find
                        .descendant(
                          of: thought,
                          matching: find.byType(DecoratedBox),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      expect(quote.color, isNull);
      expect((quote.border! as BorderDirectional).start.width, 2);
      expect((quote.border! as BorderDirectional).top, BorderSide.none);
    });

    testWidgets('no face and no slot: every line starts at the name edge', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _turn([
            _thought('r', 'Me pide probar también la lista de tareas.'),
            _tool('b', 'terminal', detail: 'df', status: 'running'),
          ], active: true),
          status: _live(step: _runningStep('terminal'), tasks: _fourOfFive),
        ),
      );
      expect(find.byKey(const ValueKey('assistant-avatar-slot')), findsNothing);
      final edge = tester
          .getTopLeft(find.byKey(const ValueKey('assistant-header-name')))
          .dx;
      for (final line in [
        find.byKey(const ValueKey('turn-status-line')),
        find.byKey(const ValueKey('turn-reasoning')),
        find.byType(TurnToolRow),
        find.byKey(const ValueKey('turn-tasks-live')),
      ]) {
        expect(tester.getTopLeft(line).dx, edge, reason: '$line');
      }
    });

    testWidgets('right to left: the lines start at the right edge', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          Directionality(
            textDirection: TextDirection.rtl,
            child: _turn([
              _thought('r', 'Me pide probar también la lista de tareas.'),
              _tool('b', 'terminal', detail: 'df', status: 'running'),
            ], active: true),
          ),
          status: _live(step: _runningStep('terminal'), tasks: _fourOfFive),
        ),
      );
      expect(tester.takeException(), isNull);
      final lines = tester.getRect(
        find.byKey(const ValueKey('thinking-trace-live')),
      );
      expect(
        tester
            .getRect(find.byKey(const ValueKey('assistant-header-name')))
            .right,
        closeTo(lines.right, 0.5),
      );
      // The tool's icon leads from the right, the thought's rule is there.
      expect(
        tester
            .getRect(
              find.descendant(
                of: find.byType(TurnToolRow),
                matching: find.byType(Icon),
              ),
            )
            .right,
        closeTo(lines.right, 0.5),
      );
      final quote =
          tester
                  .widget<DecoratedBox>(
                    find
                        .descendant(
                          of: find.byKey(const ValueKey('turn-reasoning')),
                          matching: find.byType(DecoratedBox),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      expect((quote.border! as BorderDirectional).start.width, 2);
    });

    testWidgets('the thought is read at the size of the reply', (tester) async {
      await tester.pumpWidget(
        _host(
          _turn([
            _thought('r', 'Monto cinco tareas.', running: true),
          ], active: true),
          status: _live(),
        ),
      );
      expect(_paintedSize(tester, 'Monto cinco'), TurnType.reasoning);
      expect(TurnType.reasoning, greaterThanOrEqualTo(14));
    });

    testWidgets('a long thought is shown whole, from its first word', (
      tester,
    ) async {
      Future<void> pumpThought(String text) => tester.pumpWidget(
        _host(
          _turn([_thought('r', text, running: true)], active: true),
          status: _live(),
        ),
      );
      double height() =>
          tester.getSize(find.byKey(const ValueKey('turn-reasoning'))).height;

      final body = List.filled(60, 'Pienso en cómo probarlo bien.').join(' ');
      await pumpThought('PRIMERA_FRASE. $body');
      final medium = height();
      await pumpThought('PRIMERA_FRASE. $body\n\n$body\n\n$body ULTIMA_FRASE.');
      expect(medium, lessThan(height() + 1));
      expect(height(), 288, reason: 'a long thought stops at the cap');
      expect(
        find.textContaining('PRIMERA_FRASE', findRichText: true),
        findsOneWidget,
        reason: 'it starts at its first word',
      );
      expect(
        find.textContaining('ULTIMA_FRASE', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('more words rebuild only the passage being written', (
      tester,
    ) async {
      Future<void> pumpThought(String text) => tester.pumpWidget(
        _host(
          _turn([_thought('r', text, running: true)], active: true),
          status: _live(),
        ),
      );
      Finder block(int index) =>
          find.byKey(ValueKey('turn-thought-block-$index'));
      CompactMarkdown open() => tester.widget<CompactMarkdown>(
        find.byKey(const ValueKey('turn-thought-open')),
      );

      const first = 'Primero miro qué hay.';
      const second = 'Luego decido el orden.';
      await pumpThought('$first\n\n$second\n\nAhora escribo');
      expect(block(0), findsOneWidget);
      expect(block(1), findsOneWidget);
      expect(open().data, 'Ahora escribo');
      final kept = [tester.widget(block(0)), tester.widget(block(1))];
      final laidOut = [
        for (final index in [0, 1])
          tester.renderObject<RenderParagraph>(
            find.descendant(of: block(index), matching: find.byType(RichText)),
          ),
      ];

      await pumpThought('$first\n\n$second\n\nAhora escribo el plan entero');
      expect(open().data, 'Ahora escribo el plan entero');
      for (final index in [0, 1]) {
        expect(
          identical(tester.widget(block(index)), kept[index]),
          isTrue,
          reason: 'a finished passage keeps its widget: it is not rebuilt',
        );
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: block(index), matching: find.byType(RichText)),
        );
        expect(identical(paragraph, laidOut[index]), isTrue);
        expect(paragraph.debugNeedsLayout, isFalse);
      }

      // One passage that never breaks: what is rebuilt per word stays small.
      final endless = List.filled(
        4000,
        'Pienso en cómo probarlo bien.',
      ).join(' ');
      await pumpThought(endless);
      expect(open().data.length, lessThanOrEqualTo(ThoughtBlocks.sealAfter));
      expect(block(50), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('a growing thought is cut where it will not change again', () {
      String whole(ThoughtBlocks blocks) => [
        for (final block in blocks.sealed) block.text,
        blocks.open,
      ].join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();

      const text =
          '**Plan**\n\nPrimero miro el disco.\nLuego el log.\n\n'
          '- uno\n\n- dos\n\n- tres\n\nDespués:\n\n```sh\ndf -h\n\nls\n```\n\n'
          'Y cierro';
      final blocks = ThoughtBlocks();
      var sealedBefore = <String>[];
      for (var end = 1; end <= text.length; end++) {
        expect(blocks.update(text.substring(0, end)), isFalse);
        final sealed = [for (final block in blocks.sealed) block.text];
        expect(
          sealed.take(sealedBefore.length),
          sealedBefore,
          reason: 'a finished block never changes',
        );
        sealedBefore = sealed;
      }
      expect(sealedBefore, [
        '**Plan**',
        'Primero miro el disco.\nLuego el log.',
        // A list with its items spaced out stays one list.
        '- uno\n\n- dos\n\n- tres',
        'Después:',
        // A blank line inside a code fence does not end the block.
        '```sh\ndf -h\n\nls\n```',
      ]);
      expect(blocks.open, 'Y cierro');
      expect(whole(blocks), text.replaceAll(RegExp(r'\s+'), ' '));

      // The same text again changes nothing; another text starts over.
      expect(blocks.update(text), isFalse);
      expect(blocks.sealed, hasLength(5));
      expect(blocks.update('Otra idea'), isTrue);
      expect(blocks.sealed, isEmpty);
      expect(blocks.open, 'Otra idea');

      // A passage with no break is cut at a sentence, never mid-word.
      final endless = ThoughtBlocks();
      final long = List.filled(300, 'Una frase cualquiera.').join(' ');
      for (var end = 0; end <= long.length; end += 7) {
        endless.update(long.substring(0, end));
        expect(endless.open.length, lessThanOrEqualTo(ThoughtBlocks.sealAfter));
      }
      endless.update(long);
      expect(endless.sealed, isNotEmpty);
      for (final block in endless.sealed) {
        expect(block.tight, isTrue);
        expect(block.text, endsWith('cualquiera.'));
        expect(block.text.length, lessThanOrEqualTo(ThoughtBlocks.sealAfter));
      }
      expect(whole(endless), long);
    });

    testWidgets('the plan: bar, finished ones folded, spinner on the current', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(_turn(const [], active: true), status: _live(tasks: _fourOfFive)),
      );
      expect(find.text('Tareas 3/5'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const ValueKey('turn-tasks-progress')),
            )
            .value,
        closeTo(0.6, 0.001),
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('turn-tasks-progress')))
            .height,
        3,
      );
      expect(find.byKey(const ValueKey('turn-task-1')), findsNothing);
      expect(find.byKey(const ValueKey('turn-task-4')), findsOneWidget);
      expect(find.byKey(const ValueKey('turn-task-5')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('turn-task-4')),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      final toggle = find.byKey(const ValueKey('turn-tasks-done-toggle'));
      expect(tester.getSemantics(toggle).label, '3 completadas');
      expect(tester.getSemantics(toggle).flagsCollection.isButton, isTrue);
      expect(
        tester.getSemantics(toggle).flagsCollection.isExpanded,
        Tristate.isFalse,
      );
      await tester.tap(toggle);
      await tester.pump();
      expect(find.byKey(const ValueKey('turn-task-1')), findsOneWidget);
      expect(
        tester.getSemantics(toggle).flagsCollection.isExpanded,
        Tristate.isTrue,
      );
    });

    testWidgets('with reduced motion nothing spins', (tester) async {
      await tester.pumpWidget(
        _host(
          _turn(const [], active: true),
          status: _live(tasks: _fourOfFive),
          disableAnimations: true,
        ),
      );
      expect(find.byKey(const ValueKey('turn-task-4')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a failed tool is said so, in the error colour', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _turn([
            _tool('t', 'terminal', detail: 'pytest', status: 'failed'),
          ], active: true),
          status: _live(),
        ),
      );
      final row = find.byType(TurnToolRow);
      expect(tester.getSemantics(row).label, contains('falló'));
      expect(
        tester
            .widget<Icon>(find.descendant(of: row, matching: find.byType(Icon)))
            .color,
        AppTheme.hermesRedDark.hermes.error,
      );
    });
  });

  group('when it ends', () {
    final events = [
      _thought('r', 'Me pide probar también la lista de tareas.'),
      _tool(
        'a',
        'terminal',
        detail: 'echo',
        duration: const Duration(milliseconds: 200),
      ),
      _tool('todo', 'todo'),
      _tool(
        'b',
        'terminal',
        detail: 'sleep',
        duration: const Duration(milliseconds: 400),
      ),
      _tool('c', 'terminal', detail: 'df'),
    ];

    testWidgets('two quiet lines, nothing that looks alive', (tester) async {
      await tester.pumpWidget(
        _host(
          _turn(events, active: false),
          ownedTasks: _fourOfFive,
          ownerStepId: 'todo',
        ),
      );
      expect(find.text('Pensó durante 9s · 3 comandos'), findsOneWidget);
      expect(find.text('Tareas 3 de 5 · 2 sin hacer'), findsOneWidget);
      expect(find.byKey(const ValueKey('turn-status-line')), findsNothing);
      expect(find.byKey(const ValueKey('thinking-trace-live')), findsNothing);
      expect(find.byType(TurnToolRow), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      for (final key in ['thinking-trace-summary', 'thinking-trace-tasks']) {
        final node = tester.getSemantics(find.byKey(ValueKey(key)));
        expect(node.flagsCollection.isButton, isTrue, reason: key);
        expect(node.flagsCollection.isExpanded, Tristate.isFalse, reason: key);
      }
    });

    testWidgets('opened: thought, tools with durations, tasks with checks', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _turn(events, active: false),
          ownedTasks: _fourOfFive,
          ownerStepId: 'todo',
        ),
      );
      await tester.tap(find.byKey(const ValueKey('thinking-trace-summary')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('turn-reasoning')), findsOneWidget);
      expect(_paintedSize(tester, 'Me pide probar'), TurnType.reasoning);
      expect(find.byType(TurnToolRow), findsNWidgets(3));
      expect(find.text('Ejecutó · echo', findRichText: true), findsOneWidget);
      expect(find.text('0,2 s'), findsOneWidget);
      expect(find.text('0,4 s'), findsOneWidget);
      expect(find.text('1,1 s'), findsOneWidget);
      // The task-list call is not a row.
      expect(
        find.byKey(const ValueKey('thinking-trace-step-todo')),
        findsNothing,
      );
      // Oldest first, under the folded line.
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('turn-reasoning'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('turn-tool-a'))).dy,
        ),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('turn-tool-a'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('turn-tool-c'))).dy,
        ),
      );

      await tester.tap(find.byKey(const ValueKey('thinking-trace-tasks')));
      await tester.pump(const Duration(milliseconds: 300));
      final history = find.byKey(const ValueKey('turn-tasks-history'));
      expect(history, findsOneWidget);
      expect(
        find.descendant(
          of: history,
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsNWidgets(3),
      );
      expect(
        find.descendant(
          of: history,
          matching: find.textContaining('· sin hacer', findRichText: true),
        ),
        findsNWidgets(2),
      );
      // Nothing is being worked on any more: no spinner on what was current.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('turn-task-4'))).label,
        'Tarea 4 del plan, con un texto algo largo: sin hacer',
      );

      // Each line folds back on its own.
      await tester.tap(find.byKey(const ValueKey('thinking-trace-summary')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(TurnToolRow), findsNothing);
      expect(history, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('thinking-trace-tasks')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(history, findsNothing);
    });

    testWidgets('folded and opened, every line starts at the name edge', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _turn(events, active: false, actions: 2),
          ownedTasks: _fourOfFive,
          ownerStepId: 'todo',
        ),
      );
      expect(find.byKey(const ValueKey('assistant-avatar-slot')), findsNothing);
      final edge = tester
          .getTopLeft(find.byKey(const ValueKey('assistant-header-name')))
          .dx;
      double left(Finder finder) => tester.getTopLeft(finder).dx;
      expect(left(find.byKey(const ValueKey('thinking-trace-summary'))), edge);
      expect(left(find.byKey(const ValueKey('thinking-trace-tasks'))), edge);
      await tester.tap(find.byKey(const ValueKey('thinking-trace-summary')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('thinking-trace-tasks')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(left(find.byKey(const ValueKey('turn-reasoning'))), edge);
      expect(left(find.byType(TurnToolRow).first), edge);
      expect(left(find.byKey(const ValueKey('turn-tasks-history'))), edge);
    });

    testWidgets('a line opens downwards: full width from the first frame', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _turn(events, active: false),
          ownedTasks: _fourOfFive,
          ownerStepId: 'todo',
        ),
      );
      final edge = tester
          .getTopLeft(find.byKey(const ValueKey('assistant-header-name')))
          .dx;
      for (final (line, body) in const [
        ('thinking-trace-summary', 'thinking-trace-steps'),
        ('thinking-trace-tasks', 'turn-tasks-history'),
      ]) {
        await tester.tap(find.byKey(ValueKey(line)));
        // The frame the body appears in, and one in the middle of the fold.
        for (final frame in const [Duration.zero, Duration(milliseconds: 80)]) {
          await tester.pump(frame);
          expect(
            tester.getTopLeft(find.byKey(ValueKey(body))).dx,
            edge,
            reason: '$body slid in from the side',
          );
        }
        await tester.pump(const Duration(milliseconds: 300));
      }
    });

    testWidgets('a finished plan says so in one line', (tester) async {
      await tester.pumpWidget(
        _host(
          _turn(events, active: false),
          ownedTasks: _plan(List.filled(5, AgentTaskStatus.completed)),
          ownerStepId: 'todo',
        ),
      );
      expect(find.text('Tareas 5 de 5'), findsOneWidget);
    });

    testWidgets('a turn that only thought has nothing to count', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(_turn([_thought('r', 'Solo pienso.')], active: false)),
      );
      expect(find.text('Pensó durante 9s'), findsOneWidget);
      expect(find.byKey(const ValueKey('thinking-trace-tasks')), findsNothing);
    });

    testWidgets('a stopped turn says «Detenido» and still opens', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _turn(
            [_tool('t', 'terminal', detail: 'sleep', status: 'running')],
            active: false,
            stopped: true,
          ),
        ),
      );
      expect(find.text('Detenido'), findsOneWidget);
      expect(find.byKey(const ValueKey('turn-status-line')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('thinking-trace-summary')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(TurnToolRow), findsOneWidget);
    });

    testWidgets('a connector keeps the name its gateway gave it', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _turn([
            _tool(
              'm',
              'mcp__linear__list_issues',
              title: 'Linear · list issues',
            ),
          ], active: false),
        ),
      );
      expect(find.text('Pensó durante 9s · 1 herramienta'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('thinking-trace-summary')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('Linear · list issues', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('mcp__', findRichText: true), findsNothing);
    });
  });

  group('small screens and large text', () {
    final busy = [
      _thought(
        'r',
        List.filled(30, 'Un pensamiento largo que ocupa líneas.').join(' '),
        running: true,
      ),
      _tool(
        'a',
        'mcp__googlecalendar__create_recurring_event_with_attendees',
        detail: 'un-nombre-de-recurso-bastante-largo.example.com',
        status: 'running',
        startedAt: _start,
      ),
    ];

    testWidgets('working at 320 dp and 2x text does not overflow', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _turn(busy, active: true),
          width: 320,
          textScale: 2,
          status: _live(
            step: _runningStep(
              'mcp__googlecalendar__create_recurring_event_with_attendees',
            ),
            tasks: _fourOfFive,
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const ValueKey('thinking-trace-live'))).width,
        lessThanOrEqualTo(320),
      );
      // The status keeps to three lines however long the step is.
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('turn-status-text')))
            .maxLines,
        3,
      );
    });

    testWidgets('finished and opened at 320 dp and 2x text does not overflow', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _turn([
            ...busy.map(
              (event) => event.kind == ChatTraceEventKind.reasoning
                  ? _thought(event.id, event.preview)
                  : _tool(event.id, event.label, detail: event.detail),
            ),
            _tool('todo', 'todo'),
            _tool('b', 'web_search', detail: 'una consulta de búsqueda larga'),
            _tool('c', 'write_file', detail: 'notas.md'),
          ], active: false),
          width: 320,
          textScale: 2,
          ownedTasks: _fourOfFive,
          ownerStepId: 'todo',
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('thinking-trace-summary')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('thinking-trace-tasks')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(TurnToolRow), findsNWidgets(3));
      expect(find.byKey(const ValueKey('turn-tasks-history')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // Last in the file: it loads the app's real fonts, which stay loaded.
    // With the test font every glyph is a full square and nothing fits.
    testWidgets('at 320 dp and 2x text the status still shows its timer', (
      tester,
    ) async {
      await loadDesignFonts();
      // No button before the turn has steps, one (copy) while its reply
      // streams. With copy and regenerate both, 320 dp at 2x has no room
      // left for three lines of it.
      for (final actions in [0, 1]) {
        await tester.pumpWidget(
          _host(
            // The chat's own insets around a turn.
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 16),
              child: _turn(
                [_tool('t', 'terminal', status: 'running')],
                active: true,
                actions: actions,
              ),
            ),
            width: 320,
            textScale: 2,
            status: _live(step: _runningStep('terminal')),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.byKey(const ValueKey('turn-status-text')),
            matching: find.byType(RichText),
          ),
        );
        expect(
          paragraph.didExceedMaxLines,
          isFalse,
          reason: 'with $actions header buttons the timer is cut off',
        );
        expect(_statusText(tester), 'Trabajando · Ejecutando comando · 0:07');
      }
    });
  });
}
