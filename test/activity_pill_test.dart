import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/agent_task_list.dart';
import 'package:hermes_android/core/models/session_activity.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/activity_task_linger.dart';
import 'package:hermes_android/core/widgets/agent_task_widgets.dart'
    show latestAgentTaskStepId;
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
  const _Harness({required this.initial, required this.clock, super.key});

  final ActivitySnapshot initial;
  final _Clock clock;

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

Future<GlobalKey<_HarnessState>> _pump(
  WidgetTester tester,
  ActivitySnapshot snapshot, {
  _Clock? clock,
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
      ),
      reduceMotion: reduceMotion,
      textScale: textScale,
      theme: theme,
    ),
  );
  await tester.pump();
  return key;
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
      expect(find.textContaining('Ejecutando'), findsWidgets);
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
      expect(text.textSpan!.toPlainText(), 'Ejecutando · date');
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

        harness.currentState!.set(
          ActivitySnapshot(
            tasks: _tasks([('Terminar', AgentTaskStatus.completed)]),
          ),
        );
        await tester.pump();
        await tester.pump();
        // fh1215: the turn is idle, so the linger names the outcome and
        // carries no «1/1» counter.
        expect(find.text('1/1'), findsNothing);
        expect(find.textContaining('Todo completado'), findsWidgets);

        await tester.pump(const Duration(seconds: 3));
        expect(_pill, findsOneWidget);

        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 400));
        expect(_pill, findsNothing);
      },
    );

    testWidgets(
      'una lista nueva sustituye el linger sin retrasar su progreso',
      (tester) async {
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
        // fh1215: the idle linger has no counter.
        expect(find.text('1/1'), findsNothing);
        expect(find.textContaining('Todo completado'), findsOneWidget);

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
      },
    );

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
      expect(find.textContaining('Ejecutando'), findsWidgets);
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
      expect(find.textContaining('Ejecutando'), findsNothing);
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
      // Un solo pump con el reloj avanzado actualiza el cronómetro.
      clock.advance(const Duration(seconds: 12));
      await tester.pump(const Duration(seconds: 1));
      expect(elapsed(), '0:15');
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
