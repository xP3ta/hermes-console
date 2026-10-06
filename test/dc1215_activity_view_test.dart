import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/session_activity.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/activity_panel.dart';
import 'package:hermes_android/core/widgets/activity_side_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// dc1215: the activity view in the Dots style. One floating card (or the
// tablet side panel) with «En curso» (the current step, delegated subagents
// and background processes) and «Antes» (finished steps of this turn), a
// per-row Stop only where the app can already stop that item, and the
// bottom actions «Añadir contexto», «Cambiar rumbo» and «Parar todo», each
// shown only when its existing capability is there.

final DateTime _t0 = DateTime(2026, 9, 21, 12);

final SubagentActivityScope _scope = SubagentActivityScope(
  connectionId: 'c',
  parentSessionId: 'p',
  runtimeSessionId: 'r',
  turnEpoch: 1,
);

SubagentActivity _sub({
  String id = 'child-1',
  SubagentActivityPhase phase = SubagentActivityPhase.running,
  String goal = 'Tests de geometría',
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

ActivityStep _step(
  String label, {
  String? detail,
  ActivityStepStatus status = ActivityStepStatus.done,
  Duration? duration = const Duration(milliseconds: 700),
  DateTime? startedAt,
}) => ActivityStep(
  id: 'id-$label-${detail ?? ''}',
  kind: ActivityStepKind.tool,
  label: label,
  status: status,
  detail: detail,
  startedAt: startedAt,
  duration: duration,
);

const SessionActivityProcess _proc = SessionActivityProcess(
  id: 'proc-1',
  command: 'flutter test',
  notifyOnComplete: false,
  startedAt: null,
);

ActivitySnapshot _everything({String? liveReasoning}) => ActivitySnapshot(
  turnActive: true,
  turnStartedAt: _t0,
  current: _step(
    'terminal',
    detail: 'date',
    status: ActivityStepStatus.running,
    duration: null,
    startedAt: _t0,
  ),
  done: [_step('read_file', detail: 'a.dart')],
  processes: const [_proc],
  subagents: [
    _sub(),
    _sub(
      id: 'child-old',
      phase: SubagentActivityPhase.completed,
      goal: 'Revisar l10n',
    ),
  ],
  liveReasoning: liveReasoning,
);

class _Calls {
  final List<String> log = [];
}

ActivityPanelActions _allActions(
  _Calls calls, {
  FocusNode? composer,
  bool canStopTurn = true,
  bool canStopProcesses = true,
  bool canStopSubagents = true,
  bool canStopAll = true,
  bool compose = true,
}) => ActivityPanelActions(
  canStopTurn: canStopTurn,
  stopTurn: () async => calls.log.add('turn'),
  canStopProcesses: canStopProcesses,
  stopProcess: (id) async => calls.log.add('process:$id'),
  canStopSubagent: (activity) => canStopSubagents,
  stopSubagent: (activity) async =>
      calls.log.add('subagent:${activity.key.stableId}'),
  canStopAll: canStopAll,
  stopAll: () async => calls.log.add('all'),
  addContext: compose
      ? () {
          calls.log.add('context');
          composer?.requestFocus();
        }
      : null,
  changeCourse: compose
      ? () {
          calls.log.add('course');
          composer?.requestFocus();
        }
      : null,
);

class _Host extends StatefulWidget {
  const _Host({
    required this.initial,
    required this.actions,
    required this.composer,
  });

  final ActivitySnapshot initial;
  final ActivityPanelActions actions;
  final FocusNode composer;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late ActivitySnapshot snapshot = widget.initial;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ActivitySidePanelHost(
      child: Column(
        children: [
          const Expanded(child: SizedBox.expand()),
          ActivityPillHost(
            snapshot: snapshot,
            actions: widget.actions,
            clock: () => _t0.add(const Duration(seconds: 10)),
            revealAfter: Duration.zero,
          ),
          SizedBox(
            key: const ValueKey('composer'),
            height: 56,
            child: TextField(focusNode: widget.composer),
          ),
        ],
      ),
    ),
  );
}

Future<FocusNode> _pump(
  WidgetTester tester,
  ActivitySnapshot snapshot,
  ActivityPanelActions Function(FocusNode composer) actions, {
  Size size = const Size(390, 844),
  double textScale = 1,
  Locale locale = const Locale('es'),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final composer = FocusNode();
  addTearDown(composer.dispose);
  // A fresh tree per pump: the host keeps its snapshot in its state.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        Strings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      builder: (context, home) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: true,
          textScaler: TextScaler.linear(textScale),
        ),
        child: home!,
      ),
      home: _Host(
        initial: snapshot,
        actions: actions(composer),
        composer: composer,
      ),
    ),
  );
  await tester.pump();
  return composer;
}

Finder get _pill => find.byKey(const ValueKey('activity-pill'));
Finder get _panel => find.byKey(const ValueKey('activity-panel'));
Finder get _side => find.byKey(const ValueKey('activity-side-panel'));
Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _open(WidgetTester tester) async {
  await tester.tap(_pill);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _press(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.pump();
  await tester.tap(_key(key));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

String _rowText(WidgetTester tester, Finder row) => find
    .descendant(of: row, matching: find.byType(RichText))
    .evaluate()
    .map((e) => (e.widget as RichText).text.toPlainText())
    .join('\n');

void main() {
  group('sections', () {
    testWidgets('«En curso» holds the step, delegated work and processes; '
        '«Antes» the finished steps', (tester) async {
      final calls = _Calls();
      await _pump(tester, _everything(), (c) => _allActions(calls));
      await _open(tester);

      final now = _key('activity-now-title');
      final before = _key('activity-done-title');
      expect(tester.widget<Text>(now).data, 'En curso');
      expect(tester.widget<Text>(before).data, 'Antes');

      final nowRow = _key('activity-now-row');
      expect(_rowText(tester, nowRow), contains('terminal · date'));
      expect(_rowText(tester, nowRow), contains('Ejecutando'));
      final doneRow = _key('activity-done-id-read_file-a.dart');
      expect(_rowText(tester, doneRow), contains('read_file · a.dart'));
      expect(_rowText(tester, doneRow), contains('Hecho'));
      expect(_rowText(tester, doneRow), contains('0,7 s'));

      // The live subagent and the process sit in «En curso»; the finished
      // subagent in «Antes».
      final nowTop = tester.getTopLeft(now).dy;
      final beforeTop = tester.getTopLeft(before).dy;
      for (final key in [
        'activity-subagent-child-1',
        'activity-process-proc-1',
      ]) {
        final y = tester.getTopLeft(_key(key)).dy;
        expect(y, greaterThan(nowTop), reason: key);
        expect(y, lessThan(beforeTop), reason: key);
      }
      expect(
        tester.getTopLeft(_key('activity-subagent-child-old')).dy,
        greaterThan(beforeTop),
      );

      // Every row leads with a 40dp icon tile.
      final tiles = find.byKey(const ValueKey('activity-row-tile'));
      expect(tiles, findsAtLeastNWidgets(5));
      for (final tile in tiles.evaluate()) {
        expect(tester.getSize(find.byWidget(tile.widget)), const Size(40, 40));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('the live reasoning tail sits under the current row', (
      tester,
    ) async {
      await _pump(
        tester,
        _everything(liveReasoning: 'Leo el diff primero'),
        (c) => _allActions(_Calls()),
      );
      await _open(tester);
      final tail = _key('activity-now-reasoning');
      expect(tail, findsOneWidget);
      expect(
        tester.getTopLeft(tail).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(_key('activity-now-row')).dy),
      );
      expect(
        tester.getBottomLeft(tail).dy,
        lessThanOrEqualTo(
          tester.getTopLeft(_key('activity-subagent-child-1')).dy,
        ),
      );
    });
  });

  group('per-row stop', () {
    testWidgets('no Stop where the app cannot stop the item', (tester) async {
      final calls = _Calls();
      await _pump(
        tester,
        _everything(),
        (c) => _allActions(
          calls,
          canStopTurn: false,
          canStopProcesses: false,
          canStopSubagents: false,
        ),
      );
      await _open(tester);
      expect(_key('activity-now-stop'), findsNothing);
      expect(_key('background-process-stop-proc-1'), findsNothing);
      expect(_key('activity-subagent-stop-child-1'), findsNothing);
      expect(_key('activity-subagent-stop-child-old'), findsNothing);
    });

    testWidgets('each Stop calls the existing method for its item', (
      tester,
    ) async {
      final calls = _Calls();
      await _pump(tester, _everything(), (c) => _allActions(calls));
      await _open(tester);
      // A finished subagent never offers Stop.
      expect(_key('activity-subagent-stop-child-old'), findsNothing);
      // Round 48dp target with a square glyph.
      final stop = _key('activity-now-stop');
      expect(tester.getSize(stop).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(stop).height, greaterThanOrEqualTo(48));
      expect(
        find.descendant(of: stop, matching: find.byIcon(Icons.stop_rounded)),
        findsOneWidget,
      );
      await _press(tester, 'activity-now-stop');
      await _press(tester, 'activity-subagent-stop-child-1');
      await _press(tester, 'background-process-stop-proc-1');
      expect(calls.log, ['turn', 'subagent:child-1', 'process:proc-1']);
    });

    testWidgets('no turn Stop while the turn waits for the user', (
      tester,
    ) async {
      await _pump(
        tester,
        ActivitySnapshot(
          turnActive: true,
          turnStartedAt: _t0,
          waitingForUser: true,
        ),
        (c) => _allActions(_Calls()),
      );
      await _open(tester);
      expect(_key('activity-now-row'), findsOneWidget);
      expect(_key('activity-now-stop'), findsNothing);
    });
  });

  group('bottom actions', () {
    testWidgets('hidden when the chat supports none of them', (tester) async {
      await _pump(tester, _everything(), (c) => ActivityPanelActions.none);
      await _open(tester);
      expect(_key('activity-actions'), findsNothing);
      expect(_key('activity-action-add-context'), findsNothing);
      expect(_key('activity-action-change-course'), findsNothing);
      expect(_key('activity-action-stop-all'), findsNothing);
    });

    testWidgets('«Parar todo» calls the existing interrupt', (tester) async {
      final calls = _Calls();
      await _pump(tester, _everything(), (c) => _allActions(calls));
      await _open(tester);
      expect(find.text('Parar todo'), findsOneWidget);
      await _press(tester, 'activity-action-stop-all');
      expect(calls.log, ['all']);
    });

    testWidgets('«Parar todo» hidden when nothing can be stopped', (
      tester,
    ) async {
      await _pump(
        tester,
        _everything(),
        (c) => _allActions(_Calls(), canStopAll: false),
      );
      await _open(tester);
      expect(_key('activity-action-stop-all'), findsNothing);
      expect(_key('activity-action-add-context'), findsOneWidget);
    });

    testWidgets('«Añadir contexto» closes the card and focuses the composer', (
      tester,
    ) async {
      final calls = _Calls();
      final composer = await _pump(
        tester,
        _everything(),
        (c) => _allActions(calls, composer: c),
      );
      await _open(tester);
      expect(composer.hasFocus, isFalse);
      await _press(tester, 'activity-action-add-context');
      expect(_panel, findsNothing);
      expect(calls.log, ['context']);
      expect(composer.hasFocus, isTrue);
    });

    testWidgets('«Cambiar rumbo» only while a turn runs', (tester) async {
      final calls = _Calls();
      final composer = await _pump(
        tester,
        _everything(),
        (c) => _allActions(calls, composer: c),
      );
      await _open(tester);
      await _press(tester, 'activity-action-change-course');
      expect(_panel, findsNothing);
      expect(calls.log, ['course']);
      expect(composer.hasFocus, isTrue);

      // Only background work: there is no turn to steer.
      await _pump(
        tester,
        const ActivitySnapshot(processes: [_proc]),
        (c) => _allActions(_Calls(), composer: c),
      );
      await _open(tester);
      expect(_key('activity-action-change-course'), findsNothing);
      expect(_key('activity-action-add-context'), findsOneWidget);
    });

    testWidgets('composer actions hidden without a writable composer', (
      tester,
    ) async {
      await _pump(
        tester,
        _everything(),
        (c) => _allActions(_Calls(), compose: false),
      );
      await _open(tester);
      expect(_key('activity-action-add-context'), findsNothing);
      expect(_key('activity-action-change-course'), findsNothing);
      expect(_key('activity-action-stop-all'), findsOneWidget);
    });
  });

  group('closing', () {
    testWidgets('the round close button never reopens the keyboard', (
      tester,
    ) async {
      final composer = await _pump(
        tester,
        _everything(),
        (c) => _allActions(_Calls(), composer: c),
      );
      // Focused composer with the keyboard hidden (no view insets).
      composer.requestFocus();
      await tester.pump();
      expect(composer.hasFocus, isTrue);
      await _open(tester);
      final close = _key('activity-panel-close');
      expect(tester.getSize(close).width, greaterThanOrEqualTo(48));
      await tester.tap(close);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_panel, findsNothing);
      expect(composer.hasFocus, isFalse);
    });
  });

  group('accessibility', () {
    for (final locale in const [Locale('es'), Locale('en')]) {
      testWidgets('text scale 2.0 at 360x800 fits (${locale.languageCode})', (
        tester,
      ) async {
        await _pump(
          tester,
          _everything(liveReasoning: 'Leo el diff'),
          (c) => _allActions(_Calls(), composer: c),
          size: const Size(360, 800),
          textScale: 2,
          locale: locale,
        );
        await _open(tester);
        expect(tester.takeException(), isNull);
        for (final key in [
          'activity-action-add-context',
          'activity-action-change-course',
          'activity-action-stop-all',
        ]) {
          await tester.ensureVisible(_key(key));
          await tester.pump();
          expect(tester.getSize(_key(key)).height, greaterThanOrEqualTo(48));
          final rect = tester.getRect(_key(key));
          expect(rect.left, greaterThanOrEqualTo(0), reason: key);
          expect(rect.right, lessThanOrEqualTo(360), reason: key);
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('large text: the actions scroll with the rows instead of '
        'eating the card', (tester) async {
      Finder inScroll(String key) => find.descendant(
        of: find.descendant(
          of: _panel,
          matching: find.byType(SingleChildScrollView),
        ),
        matching: _key(key),
      );
      await _pump(tester, _everything(), (c) => _allActions(_Calls()));
      await _open(tester);
      expect(_key('activity-actions'), findsOneWidget);
      expect(inScroll('activity-actions'), findsNothing);

      await _pump(
        tester,
        _everything(),
        (c) => _allActions(_Calls()),
        size: const Size(360, 800),
        textScale: 2,
      );
      await _open(tester);
      expect(inScroll('activity-actions'), findsOneWidget);
    });

    testWidgets('stop buttons say what they stop', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, _everything(), (c) => _allActions(_Calls()));
      await _open(tester);
      expect(
        find.bySemanticsLabel(RegExp(r'^Parar .*terminal')),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  testWidgets('no reasoning yet: no hint row, the panel just shows steps', (
    tester,
  ) async {
    await _pump(
      tester,
      ActivitySnapshot(
        turnActive: true,
        turnStartedAt: _t0,
        current: _step('terminal', status: ActivityStepStatus.running),
      ),
      (c) => _allActions(_Calls()),
    );
    await _open(tester);
    expect(_key('activity-now-row'), findsOneWidget);
    expect(_key('activity-now-reasoning-hint'), findsNothing);
    expect(_key('activity-now-reasoning'), findsNothing);
    expect(find.textContaining('razonamiento'), findsNothing);
  });

  group('tablet side panel', () {
    testWidgets('same rows, stops and actions beside the chat', (tester) async {
      final calls = _Calls();
      await _pump(
        tester,
        _everything(),
        (c) => _allActions(calls, composer: c),
        size: const Size(1280, 800),
      );
      await _open(tester);
      expect(_side, findsOneWidget);
      expect(_panel, findsNothing);
      expect(
        find.descendant(of: _side, matching: _key('activity-now-row')),
        findsOneWidget,
      );
      await _press(tester, 'activity-subagent-stop-child-1');
      await _press(tester, 'activity-action-stop-all');
      expect(calls.log, ['subagent:child-1', 'all']);
      // The side panel is not modal: «Añadir contexto» focuses the composer
      // and the panel may stay.
      await _press(tester, 'activity-action-add-context');
      expect(calls.log.last, 'context');
    });
  });
}
