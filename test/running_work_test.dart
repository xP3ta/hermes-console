import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/session_activity.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/running_work.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';

import 'support/design_shots.dart' show loadDesignFonts;

// «En marcha»: what a conversation still has alive outside its turn
// (background processes, subagents, loops, the goal), as ONE widget that
// knows nothing of where it is shown.

final DateTime _t0 = DateTime(2026, 10, 12, 9);

final SubagentActivityScope _scope = SubagentActivityScope(
  connectionId: 'c',
  parentSessionId: 'p',
  runtimeSessionId: 'r',
  turnEpoch: 1,
);

SubagentActivity _sub(
  String id, {
  SubagentActivityPhase phase = SubagentActivityPhase.running,
  String goal = 'Revisar las copias del servidor',
}) => SubagentActivity(
  key: SubagentActivityKey(
    scope: _scope,
    identityKind: SubagentIdentityKind.subagent,
    stableId: id,
  ),
  source: SubagentActivitySource.native,
  phase: phase,
  subagentId: id,
  details: SubagentActivityDetails(goalPreview: goal),
);

SessionActivityProcess _process(
  String id, {
  String command = 'flutter test --coverage',
  List<String> watch = const [],
}) => SessionActivityProcess(
  id: id,
  command: command,
  notifyOnComplete: true,
  startedAt: _t0,
  watchPatterns: watch,
);

final _loop = SessionActivitySchedule(
  kind: SessionActivityScheduleKind.loop,
  status: 'active',
  interval: const Duration(minutes: 15),
  lastRunAt: _t0.subtract(const Duration(minutes: 5)),
  nextDueAt: _t0.add(const Duration(minutes: 10)),
  runCount: 3,
);

const _goal = SessionActivityGoal(
  title: 'Dejar la versión lista para publicar',
  status: 'active',
);

ActivitySnapshot _everything() => ActivitySnapshot(
  subagents: [_sub('a')],
  processes: [_process('p1')],
  schedules: [_loop],
  goal: _goal,
);

Future<ValueNotifier<ActivitySnapshot>> _pump(
  WidgetTester tester,
  ActivitySnapshot snapshot, {
  RunningWorkActions actions = RunningWorkActions.none,
  Size size = const Size(390, 844),
  double textScale = 1,
  ThemeData? theme,
  bool title = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final notifier = ValueNotifier(snapshot);
  addTearDown(notifier.dispose);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: const [
        Strings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: Strings.supportedLocales,
      theme: theme ?? AppTheme.hermesRedDark,
      builder: (context, home) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: home!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: RunningWork(
            snapshot: notifier,
            actions: actions,
            title: title,
            clock: () => _t0.add(const Duration(seconds: 75)),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return notifier;
}

Finder _key(String name) => find.byKey(ValueKey(name));

Finder _in(String row, String text) => find.descendant(
  of: _key(row),
  matching: find.textContaining(text, findRichText: true),
);

Iterable<RenderParagraph> _paragraphs(WidgetTester tester) => find
    .descendant(of: find.byType(RunningWork), matching: find.byType(RichText))
    .evaluate()
    .map((element) => element.renderObject! as RenderParagraph);

void main() {
  testWidgets('with nothing alive it draws nothing', (tester) async {
    final snapshot = await _pump(tester, ActivitySnapshot.idle);
    expect(_key('running-work'), findsNothing);
    expect(tester.getSize(find.byType(RunningWork)), Size.zero);
    // A turn on its own is the transcript's to tell, not this section's.
    snapshot.value = ActivitySnapshot(turnActive: true, turnStartedAt: _t0);
    await tester.pump();
    expect(_key('running-work'), findsNothing);
    expect(_key('running-work-title'), findsNothing);
  });

  testWidgets('one row for each thing alive: its icon, its kind in words and '
      'its one action', (tester) async {
    final opened = <SubagentActivity?>[];
    final stopped = <String>[];
    var goalOpened = 0;
    var goalPaused = 0;
    await _pump(
      tester,
      _everything(),
      actions: RunningWorkActions(
        openSubagent: opened.add,
        stopProcess: (process) => stopped.add(process.id),
        goalDetails: () => goalOpened++,
        pauseGoal: () => goalPaused++,
        resumeGoal: () => fail('an active goal is not resumed'),
      ),
    );
    expect(_key('running-work-title'), findsOneWidget);
    // What runs comes first: processes, subagents, then loops and the goal.
    const rows = [
      'running-process-p1',
      'running-subagent-a',
      'running-loop-0',
      'running-goal',
    ];
    final tops = [for (final row in rows) tester.getTopLeft(_key(row)).dy];
    expect(tops, [...tops]..sort());

    // Each says what it is, in words, with how it is going.
    expect(find.text('flutter test --coverage'), findsOneWidget);
    expect(_in('running-process-p1', 'Segundo plano · 1:15'), findsOneWidget);
    expect(find.text('Revisar las copias del servidor'), findsOneWidget);
    expect(_in('running-subagent-a', 'Subagente · '), findsOneWidget);
    expect(find.text('Bucle recurrente'), findsOneWidget);
    expect(_in('running-loop-0', 'Cada 15 min'), findsOneWidget);
    expect(find.text('Dejar la versión lista para publicar'), findsOneWidget);
    expect(_in('running-goal', 'Objetivo · activo'), findsOneWidget);

    // Icons anyone recognises, the ones these things have elsewhere in the
    // app, each with its kind as its label.
    Icon icon(String row) => tester.widget<Icon>(
      find.descendant(of: _key(row), matching: find.byType(Icon)),
    );
    expect(icon('running-process-p1').icon, Icons.terminal_rounded);
    expect(icon('running-process-p1').semanticLabel, 'Segundo plano');
    expect(icon('running-subagent-a').icon, Icons.smart_toy_outlined);
    expect(icon('running-subagent-a').semanticLabel, 'Subagente');
    expect(icon('running-loop-0').icon, Icons.schedule_rounded);
    expect(icon('running-loop-0').semanticLabel, 'Bucle recurrente');
    expect(icon('running-goal').icon, Icons.flag_outlined);
    expect(icon('running-goal').semanticLabel, 'Objetivo');

    // One named action per row, and it does what it says.
    expect(_in('running-process-p1', 'Detener'), findsOneWidget);
    await tester.tap(_key('running-process-stop-p1'));
    expect(stopped, ['p1']);
    expect(_in('running-subagent-a', 'Ver'), findsOneWidget);
    await tester.tap(_key('running-subagent-open-a'));
    expect(opened.single?.subagentId, 'a');
    // The whole row opens it too.
    await tester.tap(find.text('Revisar las copias del servidor'));
    expect(opened, hasLength(2));
    expect(_in('running-goal', 'Pausar'), findsOneWidget);
    await tester.tap(_key('running-goal-action'));
    expect(goalPaused, 1);
    expect(goalOpened, 0);
    // The goal's row opens the goal, where it is cleared.
    await tester.tap(find.text('Dejar la versión lista para publicar'));
    expect(goalOpened, 1);
    for (final row in rows) {
      expect(
        find.descendant(of: _key(row), matching: find.byType(TextButton)),
        row == 'running-loop-0' ? findsNothing : findsOneWidget,
        reason: row,
      );
    }
    // A loop has nothing to open: no button.
    expect(
      find.descendant(
        of: _key('running-loop-0'),
        matching: find.byType(TextButton),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a paused goal offers to resume it', (tester) async {
    var resumed = 0;
    await _pump(
      tester,
      const ActivitySnapshot(
        goal: SessionActivityGoal(title: 'Publicar', status: 'paused'),
      ),
      actions: RunningWorkActions(
        pauseGoal: () => fail('a paused goal is not paused'),
        resumeGoal: () => resumed++,
      ),
    );
    expect(_in('running-goal', 'Objetivo · pausado'), findsOneWidget);
    expect(_in('running-goal', 'Reanudar'), findsOneWidget);
    await tester.tap(_key('running-goal-action'));
    expect(resumed, 1);
  });

  testWidgets('an action that is not possible is not offered', (tester) async {
    await _pump(tester, _everything());
    expect(find.byType(TextButton), findsNothing);
    for (final label in ['Detener', 'Ver', 'Pausar', 'Reanudar']) {
      expect(find.text(label), findsNothing);
    }
  });

  testWidgets('subagents that ended go last, until they are cleared', (
    tester,
  ) async {
    var cleared = 0;
    final snapshot = await _pump(
      tester,
      ActivitySnapshot(
        subagents: [
          _sub('b', phase: SubagentActivityPhase.completed),
          _sub('a'),
        ],
        goal: _goal,
      ),
      actions: RunningWorkActions(dismissSubagents: () => cleared++),
    );
    final tops = [
      for (final row in [
        'running-subagent-a',
        'running-goal',
        'running-subagent-b',
      ])
        tester.getTopLeft(_key(row)).dy,
    ];
    expect(tops, [...tops]..sort());
    // Nothing to clear while one still works.
    expect(_key('running-subagents-dismiss'), findsNothing);
    snapshot.value = ActivitySnapshot(
      subagents: [
        _sub('a', phase: SubagentActivityPhase.failed),
        _sub('b', phase: SubagentActivityPhase.completed),
      ],
    );
    await tester.pump();
    await tester.tap(_key('running-subagents-dismiss'));
    expect(cleared, 1);
  });

  testWidgets('what could not be read again says so on its own rows', (
    tester,
  ) async {
    await _pump(
      tester,
      ActivitySnapshot(
        processes: [_process('p1')],
        subagents: [_sub('a')],
        subagentsStale: true,
      ),
    );
    // A stale roster of subagents does not put the process in doubt.
    expect(_in('running-subagent-a', 'Último estado conocido'), findsOneWidget);
    expect(_in('running-process-p1', 'Último estado conocido'), findsNothing);
  });

  testWidgets('it follows what is alive and leaves when nothing is', (
    tester,
  ) async {
    final snapshot = await _pump(
      tester,
      ActivitySnapshot(processes: [_process('p1')]),
    );
    expect(_key('running-process-p1'), findsOneWidget);
    snapshot.value = ActivitySnapshot(
      processes: [
        _process('p1'),
        _process('p2', command: 'npm run build'),
      ],
    );
    await tester.pump();
    expect(_key('running-process-p2'), findsOneWidget);
    snapshot.value = ActivitySnapshot.idle;
    await tester.pump();
    expect(_key('running-work'), findsNothing);
    expect(tester.getSize(find.byType(RunningWork)), Size.zero);
  });

  testWidgets('subagents known only by their number have their row', (
    tester,
  ) async {
    await _pump(tester, const ActivitySnapshot(subagentGenericCount: 2));
    expect(_key('running-subagents-count'), findsOneWidget);
    expect(find.textContaining('2 subagentes'), findsOneWidget);
  });

  test('how many are alive', () {
    expect(RunningWork.aliveCount(ActivitySnapshot.idle), 0);
    expect(
      RunningWork.aliveCount(
        ActivitySnapshot(turnActive: true, turnStartedAt: _t0),
      ),
      0,
    );
    expect(RunningWork.aliveCount(_everything()), 4);
    // Subagents that ended are not running; those known by number are.
    expect(
      RunningWork.aliveCount(
        ActivitySnapshot(
          subagents: [
            _sub('a'),
            _sub('b', phase: SubagentActivityPhase.completed),
          ],
        ),
      ),
      1,
    );
    expect(
      RunningWork.aliveCount(const ActivitySnapshot(subagentGenericCount: 3)),
      3,
    );
  });

  testWidgets('320 dp at twice the text size: no overflow, the action stays', (
    tester,
  ) async {
    await _pump(
      tester,
      _everything(),
      size: const Size(320, 640),
      textScale: 2,
      actions: RunningWorkActions(
        openSubagent: (_) {},
        stopProcess: (_) {},
        goalDetails: () {},
        pauseGoal: () {},
      ),
    );
    expect(tester.takeException(), isNull);
    final stop = _key('running-process-stop-p1');
    await tester.ensureVisible(stop);
    await tester.pump();
    final rect = tester.getRect(stop);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a screen reader hears each row once, with what it does', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      _everything(),
      actions: RunningWorkActions(
        openSubagent: (_) {},
        stopProcess: (_) {},
        goalDetails: () {},
        pauseGoal: () {},
      ),
    );
    SemanticsData words(String row) => tester
        .getSemantics(
          find.descendant(of: _key(row), matching: find.byType(MergeSemantics)),
        )
        .getSemanticsData();
    // What a row says is one node: its kind, its name, how it is going.
    final process = words('running-process-p1');
    expect(process.label, contains('Segundo plano'));
    expect(process.label, contains('flutter test --coverage'));
    expect(process.label, isNot(contains('Detener')));
    expect(process.hasAction(SemanticsAction.tap), isFalse);
    // Its action is a button of its own, named with what it stops.
    final stop = tester.getSemantics(_key('running-process-stop-p1'));
    expect(stop.label, 'Detener, flutter test --coverage');
    expect(stop.flagsCollection.isButton, isTrue);
    expect(stop.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    // A row that opens something says so; its button is still its own.
    final goal = words('running-goal');
    expect(goal.label, contains('Dejar la versión lista para publicar'));
    expect(goal.label, contains('Objetivo'));
    expect(goal.hasAction(SemanticsAction.tap), isTrue);
    expect(
      tester.getSemantics(_key('running-goal-action')).label,
      'Pausar, Objetivo',
    );
    handle.dispose();
  });

  testWidgets('every theme draws it', (tester) async {
    for (final preset in AppTheme.presets) {
      await _pump(tester, _everything(), theme: AppTheme.fromId(preset.id));
      expect(_key('running-work'), findsOneWidget, reason: preset.id);
      expect(tester.takeException(), isNull, reason: preset.id);
    }
  });

  group('what changed in it', () {
    final s = StringsEs();
    RunningWorkChange? change(
      ActivitySnapshot? before,
      ActivitySnapshot after,
    ) => RunningWorkChange.between(before, after, s);

    test('the first look at a conversation is not news', () {
      expect(change(null, ActivitySnapshot.idle), isNull);
      expect(change(null, _everything()), isNull);
    });

    test('a process starts and ends', () {
      final running = ActivitySnapshot(processes: [_process('p')]);
      final started = change(ActivitySnapshot.idle, running)!;
      expect(started.line(s), 'Proceso empezó');
      expect(started.name, 'flutter test --coverage');
      final ended = change(running, ActivitySnapshot.idle)!;
      expect(ended.line(s), 'Proceso terminó');
      expect(ended.name, 'flutter test --coverage');
      expect(change(running, running), isNull);
    });

    test('a subagent starts, ends and fails', () {
      final working = ActivitySnapshot(subagents: [_sub('a')]);
      expect(
        change(ActivitySnapshot.idle, working)!.line(s),
        'Subagente empezó',
      );
      expect(
        change(
          working,
          ActivitySnapshot(
            subagents: [_sub('a', phase: SubagentActivityPhase.completed)],
          ),
        )!.line(s),
        'Subagente terminó',
      );
      final failed = change(
        working,
        ActivitySnapshot(
          subagents: [_sub('a', phase: SubagentActivityPhase.failed)],
        ),
      )!;
      expect(failed.event, RunningWorkEvent.failed);
      expect(failed.line(s), 'Subagente falló');
      expect(failed.name, 'Revisar las copias del servidor');
      // A step of its work is not news.
      expect(
        change(
          working,
          ActivitySnapshot(
            subagents: [_sub('a', phase: SubagentActivityPhase.tool)],
          ),
        ),
        isNull,
      );
      // Known only by their number.
      expect(
        change(
          ActivitySnapshot.idle,
          const ActivitySnapshot(subagentGenericCount: 1),
        )!.line(s),
        'Subagente empezó',
      );
    });

    test('a loop and the goal start and end', () {
      final looping = ActivitySnapshot(schedules: [_loop]);
      expect(change(ActivitySnapshot.idle, looping)!.line(s), 'Bucle empezó');
      expect(change(looping, ActivitySnapshot.idle)!.line(s), 'Bucle terminó');
      const withGoal = ActivitySnapshot(goal: _goal);
      final set = change(ActivitySnapshot.idle, withGoal)!;
      expect(set.line(s), 'Objetivo empezó');
      expect(set.name, 'Dejar la versión lista para publicar');
      expect(
        change(withGoal, ActivitySnapshot.idle)!.line(s),
        'Objetivo terminó',
      );
    });

    test('a failure is said before an end, an end before a start', () {
      final before = ActivitySnapshot(
        subagents: [_sub('a')],
        processes: [_process('p')],
      );
      final after = ActivitySnapshot(
        subagents: [
          _sub('a', phase: SubagentActivityPhase.failed),
          _sub('b'),
        ],
      );
      expect(change(before, after)!.event, RunningWorkEvent.failed);
      final ended = change(
        before,
        ActivitySnapshot(subagents: [_sub('a'), _sub('b')]),
      )!;
      expect(ended.line(s), 'Proceso terminó');
    });
  });

  // Last: it loads the app's real fonts, which stay loaded.
  testWidgets('rows are read at body size, with room, and nothing is cut at '
      '390 dp', (tester) async {
    await loadDesignFonts();
    await _pump(
      tester,
      title: false,
      ActivitySnapshot(
        subagents: [
          _sub(
            'a',
            goal:
                'Revisar las copias de seguridad del servidor de casa y decir '
                'cuáles fallaron esta semana',
          ),
        ],
        processes: [
          _process(
            'p1',
            command: 'restic backup /srv --verbose --exclude-caches',
            watch: ['error', 'fatal'],
          ),
        ],
        schedules: [_loop],
        goal: _goal,
      ),
      actions: RunningWorkActions(
        openSubagent: (_) {},
        stopProcess: (_) {},
        goalDetails: () {},
        pauseGoal: () {},
      ),
    );
    for (final paragraph in _paragraphs(tester)) {
      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason: paragraph.text.toPlainText(),
      );
      // Nothing smaller than a footnote of the reply.
      expect(
        paragraph.text.style!.fontSize,
        greaterThanOrEqualTo(13),
        reason: paragraph.text.toPlainText(),
      );
    }
    final title = tester.renderObject<RenderParagraph>(
      find.text('Dejar la versión lista para publicar'),
    );
    expect(title.text.style!.fontSize, greaterThanOrEqualTo(15));
    for (final row in [
      'running-process-p1',
      'running-subagent-a',
      'running-loop-0',
      'running-goal',
    ]) {
      final rect = tester.getRect(_key(row));
      expect(rect.height, greaterThanOrEqualTo(66), reason: row);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(390));
      // Its icon is drawn large enough to be told apart.
      final icon = tester.widget<Icon>(
        find.descendant(of: _key(row), matching: find.byType(Icon)),
      );
      expect(icon.size, inInclusiveRange(20, 24));
    }
    for (final action in [
      'running-subagent-open-a',
      'running-process-stop-p1',
      'running-goal-action',
    ]) {
      final size = tester.getSize(_key(action));
      expect(size.height, greaterThanOrEqualTo(48), reason: action);
      expect(size.width, greaterThanOrEqualTo(48), reason: action);
    }
    expect(tester.takeException(), isNull);
  });
}
