import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/agent_task_list.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/activity_panel.dart';
import 'package:hermes_android/core/widgets/activity_pill.dart';
import 'package:hermes_android/core/widgets/activity_sections.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// fh1215: the task counter on the activity pill never lingers as «5/5»:
// it flashes «✓ 5 tareas» for about two seconds and goes; partial progress
// keeps «3/5»; an idle turn shows no counter. The activity panel lists the
// tasks first, with the one in progress highlighted and a long run of
// completed ones folded into «N completadas».

Widget _app(Widget child, {ThemeData? theme}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: theme ?? AppTheme.hermesRedDark,
  home: Scaffold(
    body: Align(alignment: Alignment.topCenter, child: child),
  ),
);

AgentTaskList _tasks(List<AgentTaskStatus> states) => AgentTaskList(
  revision: 1,
  items: [
    for (var i = 0; i < states.length; i++)
      AgentTaskItem(id: 't$i', content: 'Tarea número $i', status: states[i]),
  ],
);

const _done = AgentTaskStatus.completed;
const _doing = AgentTaskStatus.inProgress;
const _todo = AgentTaskStatus.pending;

Future<Strings> _strings(WidgetTester tester) async {
  late Strings strings;
  await tester.pumpWidget(
    _app(
      Builder(
        builder: (context) {
          strings = Strings.of(context);
          return const SizedBox();
        },
      ),
    ),
  );
  return strings;
}

Widget _chip(int done, int total) => ActivityTaskChip(
  key: const ValueKey('chip-under-test'),
  done: done,
  total: total,
  fraction: total == 0 ? 0 : done / total,
);

void main() {
  group('pill task counter', () {
    testWidgets('partial progress keeps «3/5» for good', (tester) async {
      await tester.pumpWidget(_app(_chip(3, 5)));
      expect(find.text('3/5'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('3/5'), findsOneWidget);
      expect(find.byKey(const ValueKey('activity-task-chip')), findsOneWidget);
    });

    testWidgets('all done: «✓ 5 tareas» for ~2 s, then no counter at all', (
      tester,
    ) async {
      await tester.pumpWidget(_app(_chip(4, 5)));
      expect(find.text('4/5'), findsOneWidget);
      await tester.pumpWidget(_app(_chip(5, 5)));
      expect(find.text('✓ 5 tareas'), findsOneWidget);
      expect(find.text('5/5'), findsNothing);
      await tester.pump(const Duration(milliseconds: 1900));
      expect(find.text('✓ 5 tareas'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('✓ 5 tareas'), findsNothing);
      expect(find.text('5/5'), findsNothing);
      final chip = tester.getSize(
        find.byKey(const ValueKey('chip-under-test')),
      );
      expect(chip, Size.zero, reason: 'no gap left behind');
      // Still done a minute later: nothing comes back.
      await tester.pump(const Duration(minutes: 1));
      expect(find.textContaining('5'), findsNothing);
    });

    testWidgets('new open work after the flash brings the counter back', (
      tester,
    ) async {
      await tester.pumpWidget(_app(_chip(2, 2)));
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('✓ 2 tareas'), findsNothing);
      await tester.pumpWidget(_app(_chip(2, 3)));
      expect(find.text('2/3'), findsOneWidget);
      await tester.pumpWidget(_app(_chip(3, 3)));
      expect(find.text('✓ 3 tareas'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('✓ 3 tareas'), findsNothing);
    });

    testWidgets('one task reads singular', (tester) async {
      await tester.pumpWidget(_app(_chip(1, 1)));
      expect(find.text('✓ 1 tarea'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('in the header pill the flash ends with the bare line', (
      tester,
    ) async {
      final strings = await _strings(tester);
      final now = DateTime(2026, 10, 6, 12);
      ActivityPillModel model(List<AgentTaskStatus> states) =>
          buildActivityPillModel(
            ActivitySnapshot(
              turnActive: true,
              turnStartedAt: now.subtract(const Duration(seconds: 30)),
              tasks: _tasks(states),
            ),
            strings,
            now: now,
          )!;
      Widget pill(ActivityPillModel m) =>
          ActivityPill(model: m, now: now, onTap: () {}, inHeader: true);
      await tester.pumpWidget(_app(pill(model([_done, _doing, _todo]))));
      expect(find.text('1/3'), findsOneWidget);
      await tester.pumpWidget(_app(pill(model([_done, _done, _done]))));
      expect(find.text('✓ 3 tareas'), findsOneWidget);
      final withFlash = tester.getSize(
        find.byKey(const ValueKey('activity-pill')),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('✓ 3 tareas'), findsNothing);
      expect(find.text('3/3'), findsNothing);
      expect(
        tester.getSize(find.byKey(const ValueKey('activity-pill'))).width,
        lessThan(withFlash.width),
      );
      expect(
        find.byKey(const ValueKey('activity-pill-elapsed')),
        findsOneWidget,
      );
    });

    testWidgets('a narrow header pill drops the extras first; the timer '
        'stays whole', (tester) async {
      final now = DateTime(2026, 10, 6, 12);
      final model = ActivityPillModel(
        glyph: ActivityGlyph.tool,
        action: 'terminal',
        detail: 'flutter test',
        extras: '+1 en segundo plano',
        timerStart: now.subtract(const Duration(seconds: 44)),
        semanticsLabel: 'terminal, flutter test, +1 en segundo plano',
      );
      Widget sized(double width) => SizedBox(
        width: width,
        child: Center(
          child: ActivityPill(
            model: model,
            now: now,
            onTap: () {},
            inHeader: true,
          ),
        ),
      );
      final extras = find.byKey(const ValueKey('activity-pill-extras'));
      final timer = find.byKey(const ValueKey('activity-pill-elapsed'));
      await tester.pumpWidget(_app(sized(420)));
      expect(extras, findsOneWidget);
      await tester.pumpWidget(_app(sized(236)));
      expect(extras, findsNothing);
      expect(timer, findsOneWidget);
      expect(find.text('0:44'), findsOneWidget);
      expect(
        tester.getRect(timer).right,
        lessThanOrEqualTo(
          tester.getRect(find.byKey(const ValueKey('activity-pill'))).right,
        ),
      );
      expect(model.semanticsLabel, contains('+1 en segundo plano'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('model: partial counts, finished announces no counter, idle '
        'carries none', (tester) async {
      final strings = await _strings(tester);
      final now = DateTime(2026, 10, 6, 12);
      final partial = buildActivityPillModel(
        ActivitySnapshot(
          turnActive: true,
          turnStartedAt: now,
          tasks: _tasks([_done, _done, _done, _doing, _todo]),
        ),
        strings,
        now: now,
      )!;
      expect(partial.tasksDone, 3);
      expect(partial.tasksTotal, 5);
      expect(partial.semanticsLabel, contains(strings.liveTasksShort(3, 5)));

      final finishedLive = buildActivityPillModel(
        ActivitySnapshot(
          turnActive: true,
          turnStartedAt: now,
          tasks: _tasks([_done, _done]),
        ),
        strings,
        now: now,
      )!;
      expect(finishedLive.hasTasks, isTrue, reason: 'the chip flashes');
      expect(
        finishedLive.semanticsLabel,
        isNot(contains(strings.liveTasksShort(2, 2))),
      );

      // The turn ended: the short «Todo completado» linger has no counter.
      final idle = buildActivityPillModel(
        ActivitySnapshot(tasksActive: true, tasks: _tasks([_done, _done])),
        strings,
        now: now,
      )!;
      expect(idle.action, strings.agentTasksAllDone);
      expect(idle.hasTasks, isFalse);
      expect(idle.semanticsLabel, isNot(contains('2/2')));
    });
  });

  group('panel task list', () {
    Widget section(AgentTaskList tasks, {ThemeData? theme}) => _app(
      SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ActivityTasksSection(tasks: tasks),
        ),
      ),
      theme: theme,
    );

    Finder row(int i) => find.byKey(ValueKey('activity-task-row-t$i'));

    testWidgets('more than 3 done fold into «N completadas»; the open work '
        'stays on top; a tap unfolds and folds again', (tester) async {
      await tester.pumpWidget(
        section(_tasks([_done, _done, _done, _done, _doing, _todo, _todo])),
      );
      final toggle = find.byKey(const ValueKey('activity-tasks-done-toggle'));
      expect(toggle, findsOneWidget);
      expect(find.text('4 completadas'), findsOneWidget);
      for (var i = 0; i < 4; i++) {
        expect(row(i), findsNothing, reason: 'done row $i folded');
      }
      for (var i = 4; i < 7; i++) {
        expect(row(i), findsOneWidget);
      }
      expect(
        tester.getRect(toggle).bottom,
        lessThanOrEqualTo(tester.getRect(row(4)).top + 0.5),
      );
      expect(tester.getSize(toggle).height, greaterThanOrEqualTo(40));

      await tester.tap(toggle);
      await tester.pump();
      for (var i = 0; i < 7; i++) {
        expect(row(i), findsOneWidget);
      }
      expect(find.text('Ocultar completadas'), findsOneWidget);
      await tester.tap(toggle);
      await tester.pump();
      expect(row(0), findsNothing);
      expect(find.text('4 completadas'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('3 done or fewer stay in place, no fold', (tester) async {
      await tester.pumpWidget(section(_tasks([_done, _done, _done, _doing])));
      expect(
        find.byKey(const ValueKey('activity-tasks-done-toggle')),
        findsNothing,
      );
      for (var i = 0; i < 4; i++) {
        expect(row(i), findsOneWidget);
      }
    });

    Color? bandOf(WidgetTester tester, int i) {
      final band = find.descendant(
        of: row(i),
        matching: find.byKey(const ValueKey('activity-task-band')),
      );
      return (tester.widget<DecoratedBox>(band).decoration as BoxDecoration)
          .color;
    }

    testWidgets('only the task in progress is highlighted', (tester) async {
      await tester.pumpWidget(section(_tasks([_done, _doing, _todo])));
      expect(bandOf(tester, 1)!.a, greaterThan(0));
      expect(bandOf(tester, 0)!.a, 0);
      expect(bandOf(tester, 2)!.a, 0);
      await tester.pumpWidget(section(_tasks([_done, _done, _doing])));
      expect(bandOf(tester, 1)!.a, 0);
      expect(bandOf(tester, 2)!.a, greaterThan(0));
    });

    for (final mode in AppThemeMode.values) {
      testWidgets('readable in the ${mode.name} theme', (tester) async {
        final theme = AppTheme.fromMode(mode);
        await tester.pumpWidget(
          section(
            _tasks([_done, _done, _done, _done, _doing, _todo]),
            theme: theme,
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        final colors = theme.hermes;
        final bandColor = Color.alphaBlend(
          bandOf(tester, 4)!,
          colors.background,
        );
        final current = tester.widget<Text>(find.text('Tarea número 4'));
        expect(
          ThemeContrast.ratio(current.style!.color!, bandColor),
          greaterThanOrEqualTo(4.5),
        );
        final fold = tester.widget<Text>(find.text('4 completadas'));
        expect(
          ThemeContrast.ratio(
            Color.alphaBlend(fold.style!.color!, colors.background),
            colors.background,
          ),
          greaterThanOrEqualTo(3),
        );
      });
    }

    testWidgets('in the panel the tasks come first, before the current step', (
      tester,
    ) async {
      final now = DateTime(2026, 10, 6, 12);
      await tester.pumpWidget(
        _app(
          SingleChildScrollView(
            child: ActivityPanelBody(
              snapshot: ActivitySnapshot(
                turnActive: true,
                turnStartedAt: now,
                tasks: _tasks([_done, _doing, _todo]),
                current: ActivityStep(
                  id: 'step-1',
                  kind: ActivityStepKind.tool,
                  label: 'terminal',
                  detail: 'flutter test',
                  status: ActivityStepStatus.running,
                  startedAt: now,
                ),
              ),
              actions: ActivityPanelActions.none,
              now: now,
            ),
          ),
        ),
      );
      final tasks = tester.getRect(
        find.byKey(const ValueKey('activity-tasks-section')),
      );
      final step = tester.getRect(find.textContaining('terminal').first);
      expect(tasks.bottom, lessThanOrEqualTo(step.top));
      expect(tester.takeException(), isNull);
    });
  });
}
