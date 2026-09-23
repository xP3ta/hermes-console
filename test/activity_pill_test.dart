import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/agent_task_list.dart';
import 'package:hermes_android/core/models/session_activity.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/activity_panel.dart';
import 'package:hermes_android/core/widgets/activity_task_linger.dart';
import 'package:hermes_android/core/widgets/agent_task_widgets.dart'
    show latestAgentTaskStepId;
import 'package:hermes_android/core/widgets/activity_pill.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

final DateTime _t0 = DateTime(2026, 9, 21, 12);

class _Clock {
  _Clock(this.now);
  DateTime now;
  void advance(Duration d) => now = now.add(d);
}

final SubagentActivityScope _scope = SubagentActivityScope(
  connectionId: 'c',
  parentSessionId: 'p',
  runtimeSessionId: 'r',
  turnEpoch: 1,
);

SubagentActivity _sub({
  String id = 'child-1',
  SubagentActivityPhase phase = SubagentActivityPhase.running,
}) => SubagentActivity(
  key: SubagentActivityKey(
    scope: _scope,
    identityKind: SubagentIdentityKind.subagent,
    stableId: id,
  ),
  source: SubagentActivitySource.native,
  phase: phase,
  subagentId: id,
  details: const SubagentActivityDetails(goalPreview: 'goal'),
);

AgentTaskList _tasks(List<(String, AgentTaskStatus)> rows) => AgentTaskList(
  revision: 1,
  items: [
    for (var i = 0; i < rows.length; i++)
      AgentTaskItem(id: 't$i', content: rows[i].$1, status: rows[i].$2),
  ],
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
  notifyOnComplete: true,
  startedAt: null,
);

ActivitySnapshot _everything() => ActivitySnapshot(
  turnActive: true,
  turnStartedAt: _t0,
  current: _step(
    'terminal',
    detail: 'date',
    status: ActivityStepStatus.running,
    duration: null,
    startedAt: _t0,
  ),
  done: [
    _step('read_file', detail: 'a.dart'),
    _step('web_search'),
  ],
  tasks: _tasks([
    ('Leer', AgentTaskStatus.completed),
    ('Editar', AgentTaskStatus.inProgress),
    ('Probar', AgentTaskStatus.pending),
    ('Publicar', AgentTaskStatus.pending),
  ]),
  processes: const [_proc],
  subagents: [_sub()],
);

Widget _app(
  Widget child, {
  ThemeData? theme,
  bool reduceMotion = true,
  double textScale = 1,
  Locale locale = const Locale('es'),
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: const [
    Strings.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: Strings.supportedLocales,
  theme: theme ?? AppTheme.hermesRedDark,
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: reduceMotion,
      textScaler: TextScaler.linear(textScale),
    ),
    child: home!,
  ),
  home: child,
);

/// Réplica de la geometría del chat: transcript con «último mensaje» arriba,
/// pila flotante anclada abajo y un compositor debajo.
class _Harness extends StatefulWidget {
  const _Harness({
    required this.initial,
    required this.clock,
    this.actions,
    super.key,
  });

  final ActivitySnapshot initial;
  final _Clock clock;
  final ActivityPanelActions? actions;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late ActivitySnapshot snapshot = widget.initial;

  void set(ActivitySnapshot next) => setState(() => snapshot = next);

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              const Positioned(
                left: 0,
                right: 0,
                bottom: 120,
                child: SizedBox(
                  key: ValueKey('last-message'),
                  height: 60,
                  child: Text('último mensaje'),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 8,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ActivityTaskLingerHost(
                      snapshot: snapshot,
                      clock: () => widget.clock.now,
                      actions: widget.actions ?? ActivityPanelActions.none,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(
          key: ValueKey('composer'),
          height: 56,
          child: TextField(),
        ),
      ],
    ),
  );
}

Finder get _pill => find.byKey(const ValueKey('activity-pill'));
Finder get _panel => find.byKey(const ValueKey('activity-panel'));
Finder get _frame => find.byKey(const ValueKey('activity-panel-frame'));

Future<GlobalKey<_HarnessState>> _pump(
  WidgetTester tester,
  ActivitySnapshot snapshot, {
  _Clock? clock,
  ActivityPanelActions? actions,
  bool reduceMotion = true,
  double textScale = 1,
  ThemeData? theme,
}) async {
  final key = GlobalKey<_HarnessState>();
  await tester.pumpWidget(
    _app(
      _Harness(
        key: key,
        initial: snapshot,
        clock: clock ?? _Clock(_t0.add(const Duration(seconds: 10))),
        actions: actions,
      ),
      reduceMotion: reduceMotion,
      textScale: textScale,
      theme: theme,
    ),
  );
  await tester.pump();
  return key;
}

Future<void> _openPanel(WidgetTester tester) async {
  await tester.tap(_pill);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('pastilla única', () {
    testWidgets('turno + tareas + fondo + subagentes: UNA sola '
        'pastilla y ninguna de las antiguas', (tester) async {
      await _pump(tester, _everything());
      expect(_pill, findsOneWidget);
      for (final legacy in const [
        'turn-activity-pill',
        'agent-task-pill',
        'chat-background-process-status',
        'subagent-disclosure',
      ]) {
        expect(find.byKey(ValueKey(legacy)), findsNothing, reason: legacy);
      }
      // La acción manda, las tareas van dentro y lo demás se resume.
      expect(find.textContaining('terminal'), findsWidgets);
      expect(find.byKey(const ValueKey('activity-task-chip')), findsOneWidget);
      // La compactación NO vive en la pastilla: tiene su barra sobre el input.
      expect(find.textContaining('Compactando'), findsNothing);
      expect(find.textContaining('Sigo trabajando'), findsNothing);
    });

    testWidgets('acción con detalle, tareas y resumen en una línea', (
      tester,
    ) async {
      final base = _everything();
      await _pump(
        tester,
        ActivitySnapshot(
          turnActive: true,
          turnStartedAt: _t0,
          current: base.current,
          done: base.done,
          tasks: base.tasks,
          processes: const [_proc],
          subagents: [_sub()],
        ),
      );
      final text = tester.widget<Text>(
        find.byKey(const ValueKey('activity-pill-text')),
      );
      expect(text.textSpan!.toPlainText(), 'terminal · date');
      expect(find.text('1/4'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('activity-pill-extras')))
            .data,
        '+1 en segundo plano · +1 subagente',
      );
      // Una línea: la pastilla no supera 60 dp de alto.
      expect(tester.getSize(_pill).height, lessThan(60));
    });

    testWidgets('oculta y sin hueco cuando nada está vivo', (tester) async {
      await _pump(tester, ActivitySnapshot.idle);
      expect(_pill, findsNothing);
      expect(
        tester.getSize(find.byKey(const ValueKey('activity-pill-idle'))),
        Size.zero,
      );
    });

    testWidgets(
      'el panel abierto omite snapshots iguales y actualiza cambios reales',
      (tester) async {
        ActivitySnapshot snapshot(String headline) => ActivitySnapshot(
          turnActive: true,
          turnStartedAt: _t0,
          headline: headline,
          schedules: const [
            SessionActivitySchedule(
              kind: SessionActivityScheduleKind.heartbeat,
              status: 'running',
              interval: Duration(minutes: 5),
              lastRunAt: null,
              nextDueAt: null,
              runCount: 2,
            ),
          ],
        );
        final harness = await _pump(tester, snapshot('Conectando'));
        await _openPanel(tester);

        final panelBody = tester.widget<ActivityPanelBody>(
          find.byType(ActivityPanelBody),
        );
        harness.currentState!.set(snapshot('Conectando'));
        await tester.pump();
        await tester.pump();
        expect(
          identical(
            tester.widget<ActivityPanelBody>(find.byType(ActivityPanelBody)),
            panelBody,
          ),
          isTrue,
          reason: 'un snapshot equivalente no debe reconstruir el panel',
        );

        harness.currentState!.set(snapshot('Respondiendo'));
        await tester.pump();
        await tester.pump();
        expect(
          identical(
            tester.widget<ActivityPanelBody>(find.byType(ActivityPanelBody)),
            panelBody,
          ),
          isFalse,
        );
        expect(find.textContaining('Respondiendo'), findsWidgets);
      },
    );

    testWidgets(
      'la última tarea completada permanece cuatro segundos y luego se oculta',
      (tester) async {
        final harness = await _pump(
          tester,
          ActivitySnapshot(
            turnActive: true,
            turnStartedAt: _t0,
            tasks: _tasks([('Terminar', AgentTaskStatus.inProgress)]),
          ),
        );
        await _openPanel(tester);

        harness.currentState!.set(
          ActivitySnapshot(
            tasks: _tasks([('Terminar', AgentTaskStatus.completed)]),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(const ValueKey('activity-task-check-pop')),
          findsOneWidget,
        );
        expect(find.text('1/1'), findsWidgets);

        await tester.pump(const Duration(seconds: 3));
        expect(
          find.byKey(const ValueKey('activity-task-check-pop')),
          findsOneWidget,
        );

        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 400));
        expect(_pill, findsNothing);
        expect(_panel, findsNothing);
      },
    );

    testWidgets('una lista nueva sustituye el linger sin retrasar su progreso', (
      tester,
    ) async {
      final harness = await _pump(
        tester,
        ActivitySnapshot(
          turnActive: true,
          tasks: _tasks([('Anterior', AgentTaskStatus.inProgress)]),
        ),
      );
      harness.currentState!.set(
        ActivitySnapshot(
          tasks: _tasks([('Anterior', AgentTaskStatus.completed)]),
        ),
      );
      await tester.pump();
      expect(find.text('1/1'), findsOneWidget);

      harness.currentState!.set(
        ActivitySnapshot(
          turnActive: true,
          tasks: _tasks([('Nueva', AgentTaskStatus.inProgress)]),
        ),
      );
      await tester.pump();
      expect(find.text('0/1'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('activity-task-check-pop')),
        findsNothing,
      );
    });

    testWidgets(
      'un turno recién nacido no parpadea; lo demás sí es inmediato',
      (tester) async {
        final clock = _Clock(_t0.add(const Duration(seconds: 1)));
        await _pump(
          tester,
          ActivitySnapshot(turnActive: true, turnStartedAt: _t0),
          clock: clock,
        );
        expect(_pill, findsNothing);
        clock.advance(const Duration(seconds: 2));
        await tester.pump(const Duration(seconds: 2));
        expect(_pill, findsOneWidget);

        await _pump(
          tester,
          const ActivitySnapshot(processes: [_proc]),
          clock: _Clock(_t0),
        );
        expect(_pill, findsOneWidget);
        expect(
          find.textContaining('En segundo plano · flutter test'),
          findsOneWidget,
        );
      },
    );

    testWidgets('«Sigo trabajando» solo sustituye la acción tras el aviso de '
        'inactividad', (tester) async {
      final base = ActivitySnapshot(
        turnActive: true,
        turnStartedAt: _t0,
        current: _step(
          'terminal',
          detail: 'date',
          status: ActivityStepStatus.running,
        ),
      );
      await _pump(tester, base);
      expect(find.textContaining('Sigo trabajando'), findsNothing);
      expect(find.textContaining('terminal'), findsWidgets);
      await _pump(
        tester,
        ActivitySnapshot(
          turnActive: true,
          turnStartedAt: _t0,
          noActivityHint: true,
          current: base.current,
        ),
      );
      expect(find.textContaining('Sigo trabajando'), findsOneWidget);
      expect(find.textContaining('terminal'), findsNothing);
    });

    testWidgets('detalle acotado con elipsis y a escala 2 en 320 dp', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pump(
        tester,
        ActivitySnapshot(
          turnActive: true,
          turnStartedAt: _t0,
          tasks: _tasks([('a', AgentTaskStatus.inProgress)]),
          processes: const [_proc],
          current: _step(
            'una_herramienta_con_un_nombre_larguisimo_para_forzar',
            detail: 'archivo_con_nombre_larguisimo_que_no_cabe.dart',
            status: ActivityStepStatus.running,
          ),
        ),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      final text = tester.widget<Text>(
        find.byKey(const ValueKey('activity-pill-text')),
      );
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(tester.getSize(_pill).width, lessThanOrEqualTo(320));
    });

    testWidgets('cronómetro y detalle salen del MISMO ticker', (tester) async {
      final clock = _Clock(_t0.add(const Duration(seconds: 3)));
      await _pump(
        tester,
        ActivitySnapshot(
          turnActive: true,
          turnStartedAt: _t0,
          processes: [
            SessionActivityProcess(
              id: 'p',
              command: 'flutter test',
              notifyOnComplete: false,
              startedAt: _t0,
            ),
          ],
          current: _step(
            'terminal',
            detail: 'date',
            status: ActivityStepStatus.running,
            duration: null,
            startedAt: _t0,
          ),
        ),
        clock: clock,
      );
      String elapsed() => tester
          .widget<Text>(find.byKey(const ValueKey('activity-pill-elapsed')))
          .data!;
      expect(elapsed(), '0:03');
      // Un solo pump con el reloj avanzado actualiza el cronómetro de la
      // pastilla y el de «Ahora» del panel (mismo `now`), sin otros relojes.
      clock.advance(const Duration(seconds: 12));
      await tester.pump(const Duration(seconds: 1));
      expect(elapsed(), '0:15');
      await _openPanel(tester);
      expect(
        tester
            .widgetList<Text>(
              find.byKey(const ValueKey('activity-now-elapsed')),
            )
            .map((t) => t.data),
        everyElement('0:15'),
      );
      expect(
        tester
            .widgetList<Text>(
              find.byKey(const ValueKey('activity-pill-elapsed')),
            )
            .map((t) => t.data),
        everyElement('0:15'),
      );
    });
  });

  group('panel', () {
    testWidgets('crece desde el rect de la pastilla y queda anclado', (
      tester,
    ) async {
      await _pump(tester, _everything(), reduceMotion: false);
      final pillRect = tester.getRect(_pill);
      await tester.tap(_pill);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      // Primer frame: prácticamente el tamaño de la pastilla, mismo borde
      // inferior y mismo centro.
      final start = tester.getRect(_frame);
      expect((start.width - pillRect.width).abs(), lessThan(30));
      expect((start.bottom - pillRect.bottom).abs(), lessThan(1));
      expect((start.center.dx - pillRect.center.dx).abs(), lessThan(1));
      await tester.pump(const Duration(milliseconds: 400));
      final end = tester.getRect(_frame);
      expect(end.width, greaterThan(pillRect.width + 20));
      expect(end.height, greaterThan(pillRect.height + 60));
      expect((end.bottom - pillRect.bottom).abs(), lessThan(1));
      // La pastilla real queda oculta debajo: no hay dos a la vez.
      expect(
        tester
            .widget<Opacity>(
              find.ancestor(of: _pill, matching: find.byType(Opacity)).first,
            )
            .opacity,
        0,
      );
    });

    testWidgets('secciones con contenido y en orden', (tester) async {
      await _pump(tester, _everything());
      await _openPanel(tester);
      final order = [
        'activity-tasks-title',
        'activity-now-title',
        'activity-done-title',
        'activity-background-title',
        'activity-subagents-title',
      ];
      double? last;
      for (final key in order) {
        final finder = find.byKey(ValueKey(key));
        expect(finder, findsOneWidget, reason: key);
        final y = tester.getTopLeft(finder).dy;
        if (last != null) expect(y, greaterThan(last), reason: key);
        last = y;
      }
      // Sin bucles ni objetivo: sus secciones no existen.
      expect(find.byKey(const ValueKey('activity-loops-title')), findsNothing);
      expect(find.byKey(const ValueKey('activity-goal-title')), findsNothing);
      expect(find.text('terminal · date', findRichText: true), findsWidgets);
      expect(
        find.text('read_file · a.dart', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('0,7 s'), findsWidgets);
    });

    testWidgets('sin tareas ni compactación esas secciones se omiten', (
      tester,
    ) async {
      await _pump(
        tester,
        ActivitySnapshot(
          turnActive: true,
          turnStartedAt: _t0,
          current: _step('terminal', status: ActivityStepStatus.running),
        ),
      );
      await _openPanel(tester);
      expect(find.byKey(const ValueKey('activity-tasks-title')), findsNothing);
      expect(find.byKey(const ValueKey('activity-done-title')), findsNothing);
      expect(find.byKey(const ValueKey('activity-now-title')), findsOneWidget);
    });

    testWidgets('se actualiza en vivo sin cerrarse', (tester) async {
      final harness = await _pump(tester, _everything());
      await _openPanel(tester);
      expect(
        find.byKey(const ValueKey('activity-done-web_search')),
        findsNothing,
      );
      harness.currentState!.set(
        ActivitySnapshot(
          turnActive: true,
          turnStartedAt: _t0,
          current: _step(
            'patch',
            detail: 'main.dart',
            status: ActivityStepStatus.running,
          ),
          done: [
            _step('terminal', detail: 'date'),
            _step('read_file', detail: 'a.dart'),
          ],
          tasks: _tasks([
            ('Leer', AgentTaskStatus.completed),
            ('Editar', AgentTaskStatus.completed),
          ]),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(_panel, findsOneWidget);
      expect(find.textContaining('patch'), findsWidgets);
      expect(
        find.byKey(const ValueKey('activity-done-id-terminal-date')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('activity-task-row-t1')),
        findsOneWidget,
      );
      // El fondo y los subagentes ya no existen.
      expect(
        find.byKey(const ValueKey('activity-background-title')),
        findsNothing,
      );
    });

    testWidgets('check animado al completarse una tarea y estilos de fila', (
      tester,
    ) async {
      final harness = await _pump(
        tester,
        ActivitySnapshot(
          turnActive: true,
          turnStartedAt: _t0,
          tasks: _tasks([
            ('Leer', AgentTaskStatus.inProgress),
            ('Editar', AgentTaskStatus.pending),
            ('Borrar', AgentTaskStatus.cancelled),
          ]),
        ),
        reduceMotion: false,
      );
      await _openPanel(tester);
      expect(
        find.byKey(const ValueKey('activity-task-icon-in-progress')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('activity-task-icon-pending')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('activity-task-icon-cancelled')),
        findsOneWidget,
      );
      harness.currentState!.set(
        ActivitySnapshot(
          turnActive: true,
          turnStartedAt: _t0,
          tasks: _tasks([
            ('Leer', AgentTaskStatus.completed),
            ('Editar', AgentTaskStatus.inProgress),
            ('Borrar', AgentTaskStatus.cancelled),
          ]),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final pop = tester.widget<ScaleTransition>(
        find.byKey(const ValueKey('activity-task-check-pop')),
      );
      expect(pop.scale.value, isNot(1.0), reason: 'a mitad del pop');
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester
            .widget<ScaleTransition>(
              find.byKey(const ValueKey('activity-task-check-pop')),
            )
            .scale
            .value,
        1.0,
      );
      final done = tester.widget<Text>(find.text('Leer'));
      expect(done.style!.decoration, TextDecoration.lineThrough);
      final current = tester.widget<Text>(find.text('Editar'));
      expect(current.style!.fontWeight, FontWeight.w700);
    });

    testWidgets('más de 6 tareas: ventana de 6 y expansor «+N más»', (
      tester,
    ) async {
      await _pump(
        tester,
        ActivitySnapshot(
          turnActive: true,
          turnStartedAt: _t0,
          tasks: _tasks([
            for (var i = 0; i < 9; i++)
              (
                'tarea $i',
                i == 7 ? AgentTaskStatus.inProgress : AgentTaskStatus.pending,
              ),
          ]),
        ),
      );
      await _openPanel(tester);
      expect(find.textContaining('tarea '), findsNWidgets(6));
      // La tarea en curso queda dentro de la ventana.
      expect(find.text('tarea 7'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('activity-tasks-toggle')));
      await tester.pump();
      expect(find.textContaining('tarea '), findsNWidgets(9));
    });

    testWidgets('scroll propio y seguimiento automático del paso en curso', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final many = [for (var i = 0; i < 40; i++) _step('paso$i')];
      ActivitySnapshot snap(int n) => ActivitySnapshot(
        turnActive: true,
        turnStartedAt: _t0,
        current: _step(
          'vivo$n',
          status: ActivityStepStatus.running,
          duration: null,
        ),
        done: many,
        tasks: _tasks([
          for (var i = 0; i < 6; i++) ('T$i', AgentTaskStatus.pending),
        ]),
      );
      final harness = await _pump(tester, snap(0));
      await _openPanel(tester);
      final scroll = find.byType(SingleChildScrollView);
      final controller = tester
          .widget<SingleChildScrollView>(scroll)
          .controller!;
      // El panel no supera el 55 % de la pantalla y hay contenido de sobra.
      expect(tester.getSize(_frame).height, lessThanOrEqualTo(640 * 0.55 + 1));
      expect(controller.position.maxScrollExtent, greaterThan(100));
      // El usuario baja: el seguimiento se detiene.
      await tester.drag(scroll, const Offset(0, -300));
      await tester.pump();
      final userOffset = controller.offset;
      expect(userOffset, greaterThan(0));
      harness.currentState!.set(snap(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.offset, userOffset);
    });

    testWidgets('sin intervención del usuario el panel mantiene a la vista el '
        'paso en curso', (tester) async {
      tester.view.physicalSize = const Size(390, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final snapshot = ActivitySnapshot(
        turnActive: true,
        turnStartedAt: _t0,
        current: _step(
          'vivo',
          status: ActivityStepStatus.running,
          duration: null,
        ),
        tasks: _tasks([
          for (var i = 0; i < 6; i++)
            ('Tarea larga número $i', AgentTaskStatus.pending),
        ]),
      );
      await _pump(tester, snapshot);
      await _openPanel(tester);
      final controller = tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;
      // «Ahora» queda bajo las tareas: nada scrolleó a mano y aun así se ve.
      expect(controller.offset, greaterThan(0));
      final scroll = tester.getRect(find.byType(SingleChildScrollView));
      final now = tester.getRect(
        find.byKey(const ValueKey('activity-now-title')),
      );
      expect(now.bottom, lessThanOrEqualTo(scroll.bottom + 1));
      expect(now.top, greaterThanOrEqualTo(scroll.top - 1));
    });

    testWidgets('descartes: tocar fuera, deslizar hacia abajo y atrás', (
      tester,
    ) async {
      await _pump(tester, _everything());
      await _openPanel(tester);
      expect(_panel, findsOneWidget);
      // Tocar fuera.
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_panel, findsNothing);
      expect(_pill, findsOneWidget);
      // Deslizar hacia abajo desde la cabecera.
      await _openPanel(tester);
      await tester.drag(
        find.byKey(const ValueKey('activity-panel-header')),
        const Offset(0, 120),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_panel, findsNothing);
      // Atrás.
      await _openPanel(tester);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_panel, findsNothing);
      // Tocar la cabecera también lo pliega.
      await _openPanel(tester);
      await tester.tap(find.byKey(const ValueKey('activity-panel-header')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_panel, findsNothing);
    });

    testWidgets('si deja de haber algo vivo, el panel se cierra solo', (
      tester,
    ) async {
      final harness = await _pump(tester, _everything());
      await _openPanel(tester);
      harness.currentState!.set(ActivitySnapshot.idle);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_panel, findsNothing);
      expect(_pill, findsNothing);
    });

    testWidgets('las acciones por elemento siguen cableadas', (tester) async {
      final calls = <String>[];
      const loop = SessionActivitySchedule(
        kind: SessionActivityScheduleKind.loop,
        status: 'active',
        interval: Duration(minutes: 5),
        lastRunAt: null,
        nextDueAt: null,
        runCount: 3,
      );
      await _pump(
        tester,
        ActivitySnapshot(
          processes: const [_proc],
          schedules: const [loop],
          goal: const SessionActivityGoal(title: 'Meta', status: 'active'),
          subagents: [_sub()],
        ),
        actions: ActivityPanelActions(
          canStopProcesses: true,
          stopProcess: (id) async => calls.add('stop:$id'),
          canControlSchedules: true,
          scheduleAction: (s, a) async => calls.add('sched:${a.name}'),
          canControlGoal: true,
          goalAction: (a) async => calls.add(a),
          goalDetails: () => calls.add('goal-details'),
          openSubagent: (a) => calls.add('open:${a?.key.stableId}'),
          dismissSubagents: () => calls.add('dismiss'),
        ),
      );
      await _openPanel(tester);
      Future<void> press(String key) async {
        final finder = find.byKey(ValueKey(key));
        await tester.ensureVisible(finder);
        await tester.pump();
        await tester.tap(finder);
        await tester.pump();
      }

      await press('background-process-stop-proc-1');
      await press('background-loop-pause');
      await press('background-loop-stop');
      await press('background-goal-pause');
      await press('background-goal-details');
      await press('activity-subagent-child-1');
      expect(calls, [
        'stop:proc-1',
        'sched:pause',
        'sched:stop',
        'goal.pause',
        'goal-details',
        'open:child-1',
      ]);
    });

    testWidgets('sin overlap con último mensaje ni compositor; una sola '
        'pastilla con todo activo a la vez', (tester) async {
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pump(tester, _everything());
      final pill = tester.getRect(_pill);
      final composer = tester.getRect(find.byKey(const ValueKey('composer')));
      final message = tester.getRect(
        find.byKey(const ValueKey('last-message')),
      );
      expect(pill.bottom, lessThanOrEqualTo(composer.top));
      expect(pill.overlaps(composer), isFalse);
      // La pila flotante está pensada para que el transcript reserve su alto:
      // el mensaje queda por encima de la pastilla en este montaje.
      expect(message.bottom, lessThanOrEqualTo(pill.top + 1));
      expect(_pill, findsOneWidget);
      expect(find.byType(ActivityPill), findsOneWidget);
      await _openPanel(tester);
      final panel = tester.getRect(_frame);
      expect(panel.bottom, lessThanOrEqualTo(composer.top));
      expect(panel.overlaps(composer), isFalse);
      expect(panel.top, greaterThanOrEqualTo(0));
      // La pastilla ni se duplica ni se dibuja encima: un único ActivityPill
      // (el plegado, oculto) y una única cabecera de panel.
      expect(find.byType(ActivityPill), findsOneWidget);
      expect(
        find.byKey(const ValueKey('activity-panel-header')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('activity-pill-elapsed')),
        findsNWidgets(2),
      );
    });

    testWidgets('escala 2 a 320 dp sin desbordes', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pump(tester, _everything(), textScale: 2);
      await _openPanel(tester);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(_frame).width, lessThanOrEqualTo(320));
    });

    testWidgets('los 26 temas renderizan pastilla y panel', (tester) async {
      expect(AppTheme.presets.length, 26);
      for (final preset in AppTheme.presets) {
        await _pump(tester, _everything(), theme: AppTheme.fromId(preset.id));
        expect(_pill, findsOneWidget, reason: preset.id);
        await _openPanel(tester);
        expect(_panel, findsOneWidget, reason: preset.id);
        expect(tester.takeException(), isNull, reason: preset.id);
        await tester.tapAt(const Offset(5, 5));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }
    });
  });

  group('detalle seguro', () {
    test('comando: solo ejecutable, nunca flags ni secretos', () {
      expect(activityToolDetail('terminal', {'command': 'date'}), 'date');
      expect(
        activityToolDetail('terminal', {
          'command':
              'curl -H "Authorization: Bearer sk-live-123" https://x.io?token=abc',
        }),
        'curl',
      );
      expect(
        activityToolDetail('terminal', {'command': 'API_KEY=abc123 deploy'}),
        isNull,
      );
      expect(
        activityToolDetail('terminal', {'command': '/usr/bin/git status'}),
        'git',
      );
    });

    test('rutas → nombre; URLs → host; consultas acotadas y sin secretos', () {
      expect(
        activityToolDetail('read_file', {'path': '/home/u/proyecto/main.dart'}),
        'main.dart',
      );
      expect(
        activityToolDetail('web', {'url': 'https://example.com/a?token=1'}),
        'example.com',
      );
      expect(
        activityToolDetail('web_search', {'query': 'x' * 200})!.length,
        48,
      );
      expect(
        activityToolDetail('web_search', {'query': 'mi token es abc'}),
        isNull,
      );
      expect(activityToolDetail('x', {'other': 'v'}), isNull);
      expect(activityToolDetail('x', 'no-map'), isNull);
    });

    test('paso normalizado: duración desde timestamp y completed_at', () {
      final step = ActivityStep.fromTrace({
        'kind': 'tool',
        'label': 'terminal',
        'status': 'completed',
        'detail': 'date',
        'timestamp': 1700000000000,
        'completed_at': 1700000000700,
      })!;
      expect(step.duration, const Duration(milliseconds: 700));
      expect(step.detail, 'date');
      expect(step.status, ActivityStepStatus.done);
    });

    test('el trace conserva detalle y fin, y descarta detalle inseguro', () {
      final step = normalizeAssistantActivityStep({
        'kind': 'tool',
        'label': 'terminal',
        'status': 'completed',
        'detail': 'date',
        'timestamp': 10,
        'completed_at': 20,
      })!;
      expect(step['detail'], 'date');
      expect(step['completed_at'], 20);
      final unsafe = normalizeAssistantActivityStep({
        'kind': 'tool',
        'label': 'terminal',
        'detail': 'a\nb',
      })!;
      expect(unsafe.containsKey('detail'), isFalse);
      final tooLong = normalizeAssistantActivityStep({
        'kind': 'tool',
        'label': 'terminal',
        'detail': 'x' * 200,
      })!;
      expect(tooLong.containsKey('detail'), isFalse);
    });

    test(
      'un historial de Desktop reconstruye el detalle seguro de los args',
      () {
        final steps = assistantActivityFromToolCalls([
          {
            'id': 'c1',
            'function': {
              'name': 'terminal',
              'arguments': '{"command":"git status --porcelain"}',
            },
          },
          {
            'id': 'c2',
            'function': {
              'name': 'read_file',
              'arguments': '{"path":"/a/b/c.md"}',
            },
          },
          {
            'id': 'c3',
            'function': {'name': 'x', 'arguments': 'no es json'},
          },
        ], status: 'completed');
        expect(steps.map((s) => s['detail']), ['git', 'c.md', null]);
      },
    );

    test(
      'las herramientas puente nunca son pasos; segundos y ms se leen bien',
      () {
        final split = ActivitySnapshot.splitSteps([
          {'kind': 'tool', 'label': 'tool_call', 'status': 'completed'},
          {'kind': 'tool', 'label': 'tool_describe', 'status': 'completed'},
          {'kind': 'tool', 'label': 'tool_search', 'status': 'running'},
          {
            'kind': 'tool',
            'label': 'terminal',
            'status': 'completed',
            'detail': 'sleep',
            'timestamp': 1000.0,
            'completed_at': 1002.5,
          },
        ]);
        expect(split.current, isNull);
        expect(split.done.map((s) => s.label), ['terminal']);
        // Historial de Desktop: segundos con decimales.
        expect(split.done.single.duration, const Duration(milliseconds: 2500));
        final equal = ActivityStep.fromTrace({
          'kind': 'tool',
          'label': 'x',
          'status': 'completed',
          'timestamp': 5,
          'completed_at': 5,
        })!;
        expect(equal.duration, isNull, reason: 'una duración 0 no se inventa');
      },
    );

    test('el historial de Desktop desenvuelve tool_call y oculta el resto', () {
      final messages = coalesceAssistantTurnsNewestFirst([
        // más nuevo primero
        {
          'role': 'tool',
          'tool_call_id': 'c2',
          'tool_name': 'tool_call',
          'content': '',
          'timestamp': 1013.0,
        },
        {
          'role': 'assistant',
          'content': '',
          'timestamp': 1010.0,
          'tool_calls': [
            {
              'id': 'c2',
              'function': {
                'name': 'tool_call',
                'arguments':
                    '{"calls":[{"name":"todo","arguments":{"todos":[]}}]}',
              },
            },
          ],
        },
        {
          'role': 'tool',
          'tool_call_id': 'c1',
          'tool_name': 'tool_call',
          'content': '',
          'timestamp': 1007.0,
        },
        {
          'role': 'assistant',
          'content': '',
          'timestamp': 1000.0,
          'tool_calls': [
            {
              'id': 'c0',
              'function': {'name': 'tool_search', 'arguments': '{"q":"x"}'},
            },
            {
              'id': 'c1',
              'function': {
                'name': 'tool_call',
                'arguments':
                    '{"calls":[{"name":"terminal","arguments":{"command":"sleep 5 --token=SECRET"}}]}',
              },
            },
          ],
        },
      ]);
      final trace = normalizeAssistantActivityTrace(
        messages.single[assistantActivityTraceKey],
      );
      final split = ActivitySnapshot.splitSteps(trace);
      expect(split.done.map((s) => s.label), ['terminal']);
      final terminal = split.done.single;
      expect(terminal.detail, 'sleep');
      expect(terminal.duration, const Duration(seconds: 7));
      expect(terminal.status, ActivityStepStatus.done);
      expect(trace.toString(), isNot(contains('SECRET')));
      // El `todo` desenvuelto conserva un paso propio: es el dueño de Tareas.
      final todo = trace.firstWhere((step) => step['label'] == 'todo');
      expect(todo['id'], 'c2:0');
      expect(
        latestAgentTaskStepId([
          {'role': 'assistant', assistantActivityTraceKey: trace},
        ]),
        'c2:0',
      );
    });

    test('splitSteps separa vivo/hecho y omite razonamiento y todo_list', () {
      final split = ActivitySnapshot.splitSteps([
        {'kind': 'reasoning', 'text': 'x', 'status': 'completed'},
        {'kind': 'tool', 'label': 'todo_list', 'status': 'completed'},
        {'kind': 'tool', 'label': 'a', 'status': 'completed', 'id': '1'},
        {'kind': 'tool', 'label': 'b', 'status': 'running', 'id': '2'},
      ]);
      expect(split.current!.label, 'b');
      expect(split.done.map((s) => s.label), ['a']);
    });
  });
}
