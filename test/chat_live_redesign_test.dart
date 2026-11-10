import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/screens/turn_activity_memory.dart';
import 'package:hermes_android/core/services/session_reconciler.dart'
    show assistantActivityTraceKey;
import 'package:hermes_android/core/models/session_activity.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_pinned_prompt_header.dart';
import 'package:hermes_android/core/widgets/chat/chat_queue_chip.dart';
import 'package:hermes_android/core/widgets/chat/tool_steps_summary.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/core/widgets/subagent_activity_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

final _start = DateTime(2026, 11, 6);
final _now = _start.add(const Duration(seconds: 18));
final _scope = SubagentActivityScope(
  connectionId: 'test',
  parentSessionId: 'parent',
  runtimeSessionId: 'runtime',
  turnEpoch: 1,
);

SubagentActivity _agent(
  String id, {
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
  details: SubagentActivityDetails(
    goalPreview: 'Revisar $id',
    startedAt: _start,
    progress: const SubagentTaskProgress(taskIndex: 1, taskCount: 4),
  ),
);

const _process = SessionActivityProcess(
  id: 'p1',
  command: 'sleep 60',
  notifyOnComplete: true,
  startedAt: null,
);

Widget _host(
  Widget child, {
  bool reduced = true,
  double scale = 1,
  String lang = 'es',
  bool rtl = false,
  bool light = false,
}) => MaterialApp(
  locale: Locale(lang),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromMode(light ? AppThemeMode.light : AppThemeMode.dark),
  builder: (context, body) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: reduced,
      textScaler: TextScaler.linear(scale),
    ),
    child: Directionality(
      textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
      child: body!,
    ),
  ),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

ChatTraceEvent _tool(int i, {bool running = false}) => ChatTraceEvent(
  id: 't$i',
  label: 'terminal',
  status: running ? 'running' : 'completed',
  detail: i == 0 ? 'date' : 'uname -a',
);

Widget _turn({
  bool active = true,
  String? headline,
  ActivityStep? step,
  List<ChatTraceEvent> events = const [],
  Duration? duration,
  ActivitySnapshot? snapshot,
}) => LiveTurnScope(
  inlineActivity: true,
  status: snapshot == null
      ? LiveTurnStatus(
          active: active,
          startedAt: _start,
          headline: headline,
          step: step,
        )
      : LiveTurnStatus.of(snapshot),
  clock: () => _now,
  child: ThinkingTraceCard(
    active: active,
    stepCards: true,
    events: events,
    duration: duration,
    headerBuilder: (_, summary, details) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('xPeta'),
        summary,
        details,
        const Text('Respuesta', key: ValueKey('reply-anchor')),
      ],
    ),
  ),
);

Widget _delegates({
  List<SubagentActivity> agents = const [],
  List<SessionActivityProcess> processes = const [],
  VoidCallback? stop,
}) => SizedBox(
  height: 520,
  child: Align(
  alignment: Alignment.bottomCenter,
  child: SubagentActivityCard(
    capsule: true,
    capsulePadding: const EdgeInsets.symmetric(horizontal: 16),
    activities: agents,
    now: _now,
    turnSnapshot: ActivitySnapshot(
      turnActive: true,
      turnStartedAt: _start,
      processes: processes,
    ),
    onStop: stop,
    queuedCount: 1,
    queueSectionBuilder: (_) => const Text('QUEUE MUST STAY BELOW'),
    canSteer: (_) => false,
  ),
),
);

Widget _jump(VoidCallback tap) => ChatPinnedPromptHeader(
  youLabel: 'Tú',
  text: 'Prueba de interfaz',
  attachmentCount: 0,
  semanticLabel: 'Saltar a mi mensaje',
  hideLabel: 'Ocultar',
  onTap: tap,
  onHide: () {},
);

void main() {
  setUp(StepsBarMemory.reset);

  testWidgets(
    'inline phase replaces one row, counts steps and expands on tap',
    (tester) async {
      await tester.pumpWidget(
        _host(_turn(headline: 'Pensando…'), reduced: false),
      );
      final row = find.byKey(const ValueKey('chat-inline-activity'));
      expect(row, findsOneWidget);
      // The live look (9 nov): while tools run, the window of actions
      // hangs under the card, so the reply rests lower than with no step.
      // What must not move it is a change of PHASE: it is measured on the
      // first phase and every other one must keep it.
      Offset? resting;
      for (final (phase, snapshot) in [
        (
          'Trabajando',
          ActivitySnapshot(
            turnActive: true,
            current: const ActivityStep(
              id: 'running',
              kind: ActivityStepKind.tool,
              label: 'terminal',
              detail: 'date',
              status: ActivityStepStatus.running,
            ),
          ),
        ),
        (
          'Delegando 2 tareas',
          ActivitySnapshot(
            turnActive: true,
            current: const ActivityStep(
              id: 'delegation',
              kind: ActivityStepKind.tool,
              label: 'delegate_task',
              status: ActivityStepStatus.running,
            ),
            subagents: [_agent('a'), _agent('b')],
          ),
        ),
        (
          'Esperando a los subagentes',
          ActivitySnapshot(
            turnActive: true,
            subagents: [_agent('a'), _agent('b')],
          ),
        ),
        (
          'Escribiendo',
          const ActivitySnapshot(turnActive: true, headline: 'Respondiendo…'),
        ),
      ]) {
        await tester.pumpWidget(
          _host(
            _turn(snapshot: snapshot, events: [_tool(0), _tool(1)]),
            reduced: false,
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(row, findsOneWidget);
        // Design B: delegated children add their own cards under the row, and
        // nothing else moves the reply.
        final cards = find.byKey(const ValueKey('delegated-child-cards'));
        final cardsHeight = cards.evaluate().isEmpty
            ? 0.0
            : tester.getSize(cards).height;
        final anchor =
            tester.getTopLeft(find.byKey(const ValueKey('reply-anchor'))) -
            Offset(0, cardsHeight);
        resting ??= anchor;
        expect(anchor, resting);
        expect(find.text(phase), findsOneWidget);
        expect(find.byKey(const ValueKey('turn-step-card-t0')), findsNothing);
        expect(find.byKey(const ValueKey('live-turn-window')), findsOneWidget);
        expect(find.text('2 herramientas'), findsOneWidget);
      }
      expect(tester.getSize(row).height, 48);
      await tester.tap(row);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final middle = tester
          .getTopLeft(find.byKey(const ValueKey('reply-anchor')))
          .dy;
      await tester.pump(const Duration(milliseconds: 400));
      // Opened, the whole list takes the window's place.
      expect(middle, isNot(resting!.dy));
      expect(find.byKey(const ValueKey('live-turn-window')), findsNothing);
      expect(find.byKey(const ValueKey('turn-step-card-t0')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'capsule shows only delegated agents and processes, never main turn or queue',
    (tester) async {
      await tester.pumpWidget(_host(_delegates()));
      expect(
        find.byKey(const ValueKey('delegates-capsule')),
        findsNothing,
        reason: 'main turn and queue do not draw the capsule',
      );
      await tester.pumpWidget(
        _host(
          _delegates(agents: [_agent('a'), _agent('b')], processes: [_process]),
        ),
      );
      final capsule = find.byKey(const ValueKey('delegates-capsule'));
      expect(capsule, findsOneWidget);
      expect(tester.getSize(capsule).height, 48);
      expect(find.textContaining('2 subagentes'), findsOneWidget);
      expect(find.textContaining('1 proceso'), findsOneWidget);
      expect(find.text('QUEUE MUST STAY BELOW'), findsNothing);
      expect(
        find.text('Parar'),
        findsNothing,
        reason: 'controls are in the sheet',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'delegates unfold from the capsule, expose progress and stop, and exclude queue',
    (tester) async {
      var stops = 0;
      await tester.pumpWidget(
        _host(
          _delegates(
            agents: [_agent('a')],
            processes: [_process],
            stop: () => stops++,
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('delegates-capsule')));
      await tester.pumpAndSettle();
      final panel = find.byKey(const ValueKey('subagent-panel'));
      expect(panel, findsOneWidget);
      expect(
        tester.getBottomLeft(panel).dy,
        lessThanOrEqualTo(
          tester
                  .getTopLeft(find.byKey(const ValueKey('delegates-capsule')))
                  .dy +
              8,
        ),
        reason: 'sheet is anchored above the capsule',
      );
      expect(find.text('QUEUE MUST STAY BELOW'), findsNothing);
      expect(
        find.byKey(const ValueKey('delegate-row-progress-a')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('delegates-stop')));
      await tester.pump();
      expect(stops, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'queue is a small glass chip with independent open and remove targets',
    (tester) async {
      var opened = 0;
      var removed = 0;
      await tester.pumpWidget(
        _host(
          ChatQueueChip(
            text: 'Y después resúmelo',
            onOpen: () => opened++,
            onRemove: () => removed++,
          ),
        ),
      );
      final chip = find.byKey(const ValueKey('chat-queue-chip'));
      expect(chip, findsOneWidget);
      expect(tester.getSize(chip).height, 48);
      expect(
        tester.getSize(find.byKey(const ValueKey('chat-queue-glass'))).height,
        28,
      );
      await tester.tap(find.byKey(const ValueKey('chat-queue-open')));
      await tester.tap(find.byKey(const ValueKey('chat-queue-remove')));
      expect(opened, 1);
      expect(removed, 1);
      expect(
        tester.getSize(find.byKey(const ValueKey('chat-queue-remove'))).width,
        greaterThanOrEqualTo(48),
      );
    },
  );

  testWidgets(
    'jump is round at rest and briefly reveals the prompt when tapped',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(_host(_jump(() => taps++), reduced: false));
      final button = find.byKey(const ValueKey('chat-jump-to-prompt'));
      expect(button, findsOneWidget);
      expect(tester.getSize(button), const Size(48, 48));
      expect(find.textContaining('Prueba de interfaz'), findsNothing);
      expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
      await tester.tap(button);
      await tester.pump(const Duration(milliseconds: 300));
      expect(taps, 1);
      expect(find.textContaining('Prueba de interfaz'), findsOneWidget);
      expect(tester.getSize(button).width, greaterThan(48));
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(tester.getSize(button), const Size(48, 48));
    },
  );

  testWidgets(
    'finished turn keeps one descriptive summary and its step disclosure',
    (tester) async {
      final events = [_tool(0), _tool(1), _tool(2)];
      await tester.pumpWidget(
        _host(
          _turn(
            events: events,
            snapshot: ActivitySnapshot(
              turnActive: true,
              subagents: [_agent('a'), _agent('b')],
            ),
          ),
        ),
      );
      // The children's cards leave the live flow with the turn.
      final cardsHeight = tester
          .getSize(find.byKey(const ValueKey('delegated-child-cards')))
          .height;
      final before =
          tester.getTopLeft(find.byKey(const ValueKey('reply-anchor'))) -
          Offset(0, cardsHeight);
      await tester.pumpWidget(
        _host(
          _turn(
            active: false,
            events: events,
            duration: const Duration(seconds: 18),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('chat-inline-activity')),
        findsOneWidget,
      );
      expect(
        find.text('Trabajó 18 s · 3 comandos · 2 subagentes'),
        findsOneWidget,
      );
      // The live window leaves with the turn: the reply rises to the line.
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('reply-anchor'))).dy,
        lessThanOrEqualTo(before.dy),
      );
      await tester.tap(find.byKey(const ValueKey('chat-inline-activity')));
      await tester.pump();
      expect(find.byKey(const ValueKey('turn-step-card-t2')), findsOneWidget);
    },
  );

  testWidgets(
    'successful delegates briefly show ready then restore identity; failures wait for acknowledgement',
    (tester) async {
      await tester.pumpWidget(_host(_delegates(agents: [_agent('a')])));
      await tester.pumpWidget(
        _host(
          _delegates(
            agents: [_agent('a', phase: SubagentActivityPhase.completed)],
          ),
        ),
      );
      expect(find.textContaining('1 subagente terminó'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 3100));
      expect(find.byKey(const ValueKey('delegates-capsule')), findsNothing);
      await tester.pumpWidget(_host(_delegates(agents: [_agent('b')])));
      await tester.pumpWidget(
        _host(
          _delegates(
            agents: [_agent('b', phase: SubagentActivityPhase.failed)],
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 5));
      expect(find.textContaining('Falló'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('delegates-capsule')));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byKey(const ValueKey('subagent-panel'))))
          .pop();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('delegates-capsule')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'unknown delegates keep public uncertainty without live progress or a false completion',
    (tester) async {
      await tester.pumpWidget(
        _host(
          _delegates(
            agents: [_agent('a', phase: SubagentActivityPhase.unknown)],
          ),
          reduced: false,
        ),
      );
      expect(find.textContaining('Sin confirmar'), findsOneWidget);
      expect(find.textContaining('Delegado a'), findsNothing);
      expect(find.textContaining('0/1'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      expect(find.textContaining('listo'), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('inline row and jump expose descriptive accessible tap actions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              _turn(headline: 'Ejecutando date'),
              _jump(() {}),
            ],
          ),
        ),
      );
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('chat-inline-activity')))
            .label,
        contains('Ejecutando date'),
      );
      expect(
        find.bySemanticsLabel('Saltar a mi mensaje: Tú · Prueba de interfaz'),
        findsOneWidget,
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('reduce motion leaves live text and delegated effects static', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        Column(
          children: [
            _turn(events: [_tool(0, running: true)]),
            _delegates(agents: [_agent('a')]),
          ],
        ),
      ),
    );
    expect(find.byKey(const ValueKey('chat-inline-activity')), findsOneWidget);
    expect(find.byType(ShaderMask), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('observed child counts survive a sparse history read and never transfer to a new turn', () {
    final memory = TurnActivityMemory();
    memory.observeDelegates(1, 2);
    memory.observeDelegates(1, 1);
    final rich = memory.withDelegates({
      'id': 'answer-1',
      'role': 'assistant',
      'content': 'Respuesta',
      assistantActivityTraceKey: [
        {
          'id': 't1',
          'kind': 'tool',
          'label': 'terminal',
          'status': 'completed',
        },
      ],
    }, 1);
    memory.settle(rich);
    final reread = memory.settle({
      'id': 'answer-1',
      'role': 'assistant',
      'content': 'Respuesta',
    });
    expect(reread[TurnActivityMemory.delegatedCountKey], 2);
    expect(
      memory
          .withDelegates({'id': 'answer-2'}, 2)
          .containsKey(TurnActivityMemory.delegatedCountKey),
      isFalse,
    );
  });

  testWidgets(
    'chat controls fit widths, scale, direction, themes and nine locales',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      for (final size in [
        const Size(320, 640),
        const Size(360, 780),
        const Size(412, 915),
        const Size(780, 360),
        const Size(673, 841),
        const Size(840, 673),
        const Size(1280, 800),
      ]) {
        tester.view.physicalSize = size;
        for (final scale in [1.0, 1.3, 2.0]) {
          for (final locale in Strings.supportedLocales) {
            for (final rtl in [false, true]) {
              for (final light in [false, true]) {
                await tester.pumpWidget(
                  _host(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _delegates(
                          agents: [_agent('a'), _agent('b')],
                          processes: [_process],
                        ),
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: _jump(() {}),
                        ),
                        _turn(
                          headline: 'Ejecutando un comando largo',
                          events: [_tool(0)],
                        ),
                        ChatQueueChip(
                          text:
                              'Una entrada muy larga para comprobar el espacio disponible ' *
                              3,
                          onOpen: () {},
                          onRemove: () {},
                        ),
                      ],
                    ),
                    scale: scale,
                    lang: locale.languageCode,
                    rtl: rtl,
                    light: light,
                  ),
                );
                expect(
                  find.byKey(const ValueKey('chat-inline-activity')),
                  findsOneWidget,
                );
                expect(
                  tester.takeException(),
                  isNull,
                  reason: '$size $scale $locale rtl=$rtl light=$light',
                );
                if (scale == 2.0) {
                  await tester.tap(
                    find.byKey(const ValueKey('chat-jump-to-prompt')),
                  );
                  await tester.pump();
                  expect(
                    tester.takeException(),
                    isNull,
                    reason:
                        'expanded jump: $size $locale rtl=$rtl light=$light',
                  );
                  await tester.ensureVisible(
                    find.byKey(const ValueKey('delegates-capsule')),
                  );
                  await tester.pump();
                  await tester.tap(
                    find.byKey(const ValueKey('delegates-capsule')),
                  );
                  await tester.pump();
                  await tester.pump(const Duration(milliseconds: 400));
                  final panel = find.byKey(const ValueKey('subagent-panel'));
                  expect(panel, findsOneWidget);
                  final rect = tester.getRect(panel);
                  expect(rect.left, greaterThanOrEqualTo(0));
                  expect(rect.right, lessThanOrEqualTo(size.width));
                  expect(rect.bottom, lessThanOrEqualTo(size.height));
                  expect(
                    tester.takeException(),
                    isNull,
                    reason:
                        'delegate sheet: $size $locale rtl=$rtl light=$light',
                  );
                  Navigator.of(tester.element(panel)).pop();
                  await tester.pump();
                }
              }
            }
          }
        }
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
}
