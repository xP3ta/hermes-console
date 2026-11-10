import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/models/subagent_steps.dart';
import 'package:hermes_android/core/screens/subagent_detail_screen.dart';
import 'package:hermes_android/core/services/subagent_group_visibility.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/subagent_activity_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/inter_font.dart';

final SubagentActivityScope _scope = SubagentActivityScope(
  connectionId: 'connection-v2',
  parentSessionId: 'parent-v2',
  runtimeSessionId: 'runtime-v2',
  turnEpoch: 1,
);

const String _longGoal =
    'Busca y redacta en español un briefing de las noticias de España de AYER '
    '(no de hoy). Primero ancla la hora con date en el servidor y después '
    'busca en varias fuentes distintas.';

SubagentActivity _agent({
  String id = 'child-v2',
  SubagentActivityPhase phase = SubagentActivityPhase.thinking,
  String goal = _longGoal,
  String? thought,
  String? summary,
  String? tool,
  String? toolTarget,
}) => SubagentActivity(
  key: SubagentActivityKey(
    scope: _scope,
    identityKind: SubagentIdentityKind.subagent,
    stableId: id,
  ),
  source: SubagentActivitySource.native,
  phase: phase,
  subagentId: id,
  childSessionId: 'child-session-$id',
  details: SubagentActivityDetails(
    goalPreview: goal,
    detailPreview: thought,
    summaryPreview: summary,
    activeToolName: tool,
    activeToolPreview: toolTarget,
    startedAt: DateTime.utc(2026, 11, 1, 12),
  ),
);

Widget _host(Widget child, {bool reduceMotion = false, double textScale = 1}) =>
    MaterialApp(
      locale: const Locale('es'),
      theme: AppTheme.fromId('dark'),
      localizationsDelegates: const [
        Strings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: Strings.supportedLocales,
      builder: (context, app) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduceMotion,
          textScaler: TextScaler.linear(textScale),
        ),
        child: app!,
      ),
      home: Scaffold(body: SafeArea(child: child)),
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// The page is a lazy list: bring [target] into the built part first.
Future<void> _reveal(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    300,
    scrollable: find.byType(Scrollable).first,
  );
}

final DateTime _t0 = DateTime.utc(2026, 11, 1, 12, 0, 10);

/// The card the chat builds, owner-wired (it reveals goals), with a clock
/// that does not run.
Widget _card(
  List<SubagentActivity> activities, {
  bool hidden = false,
  SubagentActivityController? controller,
  bool owner = true,
}) => SubagentActivityCard(
  activities: activities,
  now: _t0,
  hidden: hidden,
  controller: controller,
  canSteer: owner ? (_) => true : null,
  canInterrupt: (_) => true,
  parentTitle: 'Chat de prueba',
);

void main() {
  setUpAll(loadInterFont);

  group('SubagentGroupVisibility', () {
    test('closed only when every agent of the group was closed', () {
      final store = SubagentGroupVisibility();
      expect(store.isClosed('chat', ['a']), isFalse);
      store.close('chat', ['a']);
      expect(store.isClosed('chat', ['a']), isTrue);
      // A new agent shows the group again by itself.
      expect(store.isClosed('chat', ['a', 'b']), isFalse);
      // Per conversation; an empty roster is never closed.
      expect(store.isClosed('other', ['a']), isFalse);
      expect(store.isClosed('chat', const []), isFalse);
      store.reopen('chat');
      expect(store.isClosed('chat', ['a']), isFalse);
    });

    test('per agent: an agent closed stays closed, a new one does not', () {
      final store = SubagentGroupVisibility();
      final a = _agent(id: 'a');
      store.close('chat', ['a'], activities: [a]);
      expect(store.isAgentClosed('chat', 'a'), isTrue);
      expect(store.isAgentClosed('chat', 'b'), isFalse);
      expect(store.isAgentClosed('other', 'a'), isFalse);
      // What it last was is kept, to open it again from the menu.
      expect(store.closedActivities('chat'), [a]);
      store.close('chat', ['b'], activities: [_agent(id: 'b')]);
      expect(store.closedActivities('chat'), hasLength(2));
    });

    test('the ids survive a restart; the snapshots do not', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final first = SubagentGroupVisibility(prefs);
      first.close('chat', ['a'], activities: [_agent(id: 'a')]);
      await Future<void>.delayed(Duration.zero);
      final restarted = SubagentGroupVisibility(prefs);
      expect(restarted.isAgentClosed('chat', 'a'), isTrue);
      expect(restarted.isAgentClosed('chat', 'b'), isFalse);
      expect(restarted.closedActivities('chat'), isEmpty);
      restarted.reopen('chat');
      expect(
        SubagentGroupVisibility(prefs).isAgentClosed('chat', 'a'),
        isFalse,
      );
    });

    test('a damaged stored value is the same as none', () async {
      SharedPreferences.setMockInitialValues({
        SubagentGroupVisibility.prefsKey: '{not json',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(
        SubagentGroupVisibility(prefs).isAgentClosed('chat', 'a'),
        isFalse,
      );
    });

    test('bounded: the oldest conversations are forgotten first', () {
      final store = SubagentGroupVisibility();
      for (var i = 0; i < 80; i++) {
        store.close('chat-$i', ['a']);
      }
      expect(store.isClosed('chat-0', ['a']), isFalse);
      expect(store.isClosed('chat-79', ['a']), isTrue);
    });
  });

  group('SubagentStepLog', () {
    final base = DateTime.utc(2026, 11, 1, 12);

    test('records each change of work with its duration', () {
      final log = SubagentStepLog();
      final key = _agent().key;
      expect(log.observe(_agent(), base), isTrue);
      // The same work again is not a new step.
      expect(
        log.observe(_agent(), base.add(const Duration(seconds: 2))),
        isFalse,
      );
      expect(
        log.observe(
          _agent(
            phase: SubagentActivityPhase.tool,
            tool: 'read_file',
            toolTarget: 'notas.txt\nsegunda línea',
          ),
          base.add(const Duration(seconds: 5)),
        ),
        isTrue,
      );
      final steps = log.stepsOf(key);
      expect(steps, hasLength(2));
      expect(steps.first.phase, SubagentActivityPhase.thinking);
      expect(
        steps.first.durationAt(base.add(const Duration(minutes: 1))),
        const Duration(seconds: 5),
      );
      expect(steps.last.tool, 'read_file');
      expect(steps.last.target, 'notas.txt', reason: 'one line only');
      expect(steps.last.isOpen, isTrue);
      // The end closes the step in hand and adds none.
      expect(
        log.observe(
          _agent(phase: SubagentActivityPhase.completed),
          base.add(const Duration(seconds: 9)),
        ),
        isTrue,
      );
      expect(log.stepsOf(key), hasLength(2));
      expect(log.stepsOf(key).last.isOpen, isFalse);
    });

    test('is bounded per agent', () {
      final log = SubagentStepLog();
      final key = _agent().key;
      for (var i = 0; i < 100; i++) {
        log.observe(
          _agent(phase: SubagentActivityPhase.tool, tool: 'tool_$i'),
          base.add(Duration(seconds: i)),
        );
      }
      expect(log.stepsOf(key), hasLength(SubagentStepLog.maxSteps));
      expect(log.stepsOf(key).last.tool, 'tool_99');
    });

    test('an unknown phase is not a step', () {
      final log = SubagentStepLog();
      expect(
        log.observe(_agent(phase: SubagentActivityPhase.unknown), base),
        isFalse,
      );
      expect(log.isEmpty, isTrue);
    });
  });

  group('the group in the chat', () {
    testWidgets('hidden renders nothing yet the controller still opens it', (
      tester,
    ) async {
      final controller = SubagentActivityController();
      await tester.pumpWidget(
        _host(_card([_agent()], hidden: true, controller: controller)),
      );
      expect(find.byKey(const ValueKey('subagent-work-pill')), findsNothing);
      expect(
        find.byKey(const ValueKey('subagent-card-hidden')),
        findsOneWidget,
      );
      controller.open();
      await _settle(tester);
      expect(find.byKey(const ValueKey('subagent-panel')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('subagent-row-child-v2')));
      await _settle(tester);
      expect(find.byType(SubagentDetailScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('closed agents leave the group but stay reachable', (
      tester,
    ) async {
      final controller = SubagentActivityController();
      final a = _agent(id: 'a');
      final b = _agent(id: 'b');
      final old = _agent(id: 'old', phase: SubagentActivityPhase.completed);
      Widget build({Set<String> closed = const {}}) => _host(
        SubagentActivityCard(
          activities: [a, b],
          now: _t0,
          controller: controller,
          closedIds: closed,
          reopenable: [
            old,
            a,
            _agent(id: 'unconfirmed-old', phase: SubagentActivityPhase.unknown),
          ],
          canSteer: (_) => true,
          canInterrupt: (_) => true,
        ),
      );
      await tester.pumpWidget(build());
      expect(find.text('1/4'), findsOneWidget);
      expect(controller.counts.value, const SubagentGroupCount(1, 4));
      // Closing a row preserves the shared four-row presentation roster.
      await tester.pumpWidget(build(closed: {'a'}));
      expect(find.text('1/4'), findsOneWidget);
      expect(controller.counts.value, const SubagentGroupCount(1, 4));
      await tester.tap(find.byKey(const ValueKey('subagent-work-chevron')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('subagent-row-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('subagent-row-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('subagent-row-old')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subagent-row-unconfirmed-old')),
        findsOneWidget,
      );
      // Every one closed: nothing in the chat, the controller still lists
      // all four (the turn's two and the two from earlier turns).
      Navigator.of(
        tester.element(find.byKey(const ValueKey('subagent-panel'))),
      ).pop();
      await _settle(tester);
      await tester.pumpWidget(build(closed: {'a', 'b'}));
      expect(find.byKey(const ValueKey('subagent-work-pill')), findsNothing);
      expect(
        find.byKey(const ValueKey('subagent-card-hidden')),
        findsOneWidget,
      );
      controller.open();
      await _settle(tester);
      expect(find.byKey(const ValueKey('subagent-panel')), findsOneWidget);
      for (final id in ['a', 'b', 'old', 'unconfirmed-old']) {
        expect(
          find.byKey(ValueKey('subagent-row-$id'), skipOffstage: false),
          findsOneWidget,
          reason: id,
        );
      }
    });

    testWidgets('several agents reopen as a list, each with its detail', (
      tester,
    ) async {
      final controller = SubagentActivityController();
      await tester.pumpWidget(
        _host(
          _card(
            [
              _agent(id: 'a'),
              _agent(id: 'b', phase: SubagentActivityPhase.failed),
            ],
            hidden: true,
            controller: controller,
          ),
        ),
      );
      controller.open();
      await _settle(tester);
      expect(find.byKey(const ValueKey('subagent-panel')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('subagent-row-b')));
      await _settle(tester);
      expect(find.byType(SubagentDetailScreen), findsOneWidget);
    });

    testWidgets('the row says the tool, never its arguments', (tester) async {
      await tester.pumpWidget(
        _host(
          _card([
            _agent(
              phase: SubagentActivityPhase.tool,
              tool: 'web_fetch',
              toolTarget:
                  'https://elpais.com/economia/2026-10-31/una-url-larga',
            ),
          ]),
        ),
      );
      expect(find.textContaining('https://'), findsNothing);
      expect(find.textContaining('Esperando a 1 subagente'), findsOneWidget);
    });
  });

  group('the detail of a subagent', () {
    Future<void> openDetail(
      WidgetTester tester,
      List<SubagentActivity> activities, {
      bool owner = true,
      bool reduceMotion = false,
      double textScale = 1,
      SubagentStopRequester? onStop,
    }) async {
      final controller = SubagentActivityController();
      await tester.pumpWidget(
        _host(
          SubagentActivityCard(
            activities: activities,
            now: _t0,
            controller: controller,
            canSteer: owner ? (_) => true : null,
            canInterrupt: (_) => true,
            onStopRequested: onStop ?? (_) async => true,
            parentTitle: 'Chat de prueba',
          ),
          reduceMotion: reduceMotion,
          textScale: textScale,
        ),
      );
      controller.open(activities.first);
      await _settle(tester);
      expect(find.byType(SubagentDetailScreen), findsOneWidget);
    }

    testWidgets('while it works: assignment, thinking and a partial result', (
      tester,
    ) async {
      await openDetail(tester, [
        _agent(
          thought:
              '**Plan**\n- primero ancla la hora con `date`\n- luego busca',
          summary: '## Avance\nTres fuentes leídas',
        ),
      ]);
      // The whole assignment, as the agent was given it.
      expect(
        find.byKey(const ValueKey('subagent-detail-task')),
        findsOneWidget,
      );
      expect(find.text('ENCARGO'), findsOneWidget);
      expect(find.textContaining('ancla la hora con date'), findsWidgets);
      // The state, with its clock.
      expect(find.bySemanticsLabel(RegExp('Pensando')), findsWidgets);
      expect(
        find.byKey(const ValueKey('subagent-detail-stop')),
        findsOneWidget,
      );
      // Partial result, rendered (no raw marks).
      await _reveal(
        tester,
        find.byKey(const ValueKey('subagent-detail-result')),
      );
      expect(find.text('RESULTADO PARCIAL'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subagent-detail-result')),
        findsOneWidget,
      );
      expect(find.textContaining('##', findRichText: true), findsNothing);
      expect(
        find.textContaining('Tres fuentes leídas', findRichText: true),
        findsOneWidget,
      );
      // Thinking waits in a fold, and reads as prose when opened.
      expect(
        find.byKey(const ValueKey('subagent-detail-thought')),
        findsNothing,
      );
      await _reveal(
        tester,
        find.byKey(const ValueKey('subagent-detail-thought-toggle')),
      );
      await tester.tap(
        find.byKey(const ValueKey('subagent-detail-thought-toggle')),
      );
      await tester.pump();
      final thought = tester.widget<Text>(
        find.byKey(const ValueKey('subagent-detail-thought')),
      );
      expect(thought.data, isNot(contains('**')));
      expect(thought.data, isNot(contains('`')));
      expect(thought.data, contains('Plan'));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'the steps seen so far, with a note that says what is missing',
      (tester) async {
        final controller = SubagentActivityController();
        Widget build(List<SubagentActivity> activities) => _host(
          SubagentActivityCard(
            activities: activities,
            now: _t0,
            controller: controller,
            canSteer: (_) => true,
            canInterrupt: (_) => true,
          ),
        );
        await tester.pumpWidget(build([_agent()]));
        await tester.pumpWidget(
          build([
            _agent(
              phase: SubagentActivityPhase.tool,
              tool: 'web_fetch',
              toolTarget: 'https://efe.com/espana',
            ),
          ]),
        );
        controller.open(_agent());
        await _settle(tester);
        await _reveal(
          tester,
          find.byKey(const ValueKey('subagent-detail-step-1')),
        );
        expect(find.text('PASOS'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('subagent-detail-steps')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('subagent-detail-step-0')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('subagent-detail-step-1')),
          findsOneWidget,
        );
        expect(find.text('Usando web_fetch'), findsWidgets);
        expect(find.text('https://efe.com/espana'), findsOneWidget);
        // Two known steps only: it says the list may be incomplete.
        expect(
          find.textContaining('Solo se muestran los pasos'),
          findsOneWidget,
        );
      },
    );

    testWidgets('failed: it can be read, and says it did not finish', (
      tester,
    ) async {
      await openDetail(tester, [
        _agent(
          phase: SubagentActivityPhase.failed,
          summary: 'Encontré **dos** fuentes antes de fallar.',
        ),
      ]);
      await _reveal(
        tester,
        find.byKey(const ValueKey('subagent-detail-result')),
      );
      expect(find.text('RESULTADO'), findsOneWidget);
      expect(find.textContaining('No terminó'), findsOneWidget);
      expect(find.textContaining('dos', findRichText: true), findsWidgets);
      expect(find.byKey(const ValueKey('subagent-detail-stop')), findsNothing);
      expect(find.bySemanticsLabel(RegExp('Falló|Se detuvo')), findsWidgets);
    });

    testWidgets('stopped: the same, never claiming success', (tester) async {
      await openDetail(tester, [
        _agent(phase: SubagentActivityPhase.cancelled, summary: 'Parcial'),
      ]);
      await _reveal(
        tester,
        find.byKey(const ValueKey('subagent-detail-result')),
      );
      expect(find.textContaining('No terminó'), findsOneWidget);
      expect(
        find.textContaining('Parcial', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('not the owner surface: no assignment, thinking or partial', (
      tester,
    ) async {
      await openDetail(tester, [
        _agent(thought: 'PRIVATE_THOUGHT', summary: 'PRIVATE_PARTIAL'),
      ], owner: false);
      expect(find.byKey(const ValueKey('subagent-detail-task')), findsNothing);
      expect(
        find.byKey(const ValueKey('subagent-detail-thought-toggle')),
        findsNothing,
      );
      expect(find.textContaining('PRIVATE_', findRichText: true), findsNothing);
      expect(find.text('RESULTADO PARCIAL'), findsNothing);
    });

    testWidgets('reduce motion and 2x text: no overflow, still readable', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.reset);
      await openDetail(
        tester,
        [_agent(thought: 'pensando ' * 80, summary: 'resultado parcial ' * 30)],
        reduceMotion: true,
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('subagent-detail-task')),
        findsOneWidget,
      );
    });
  });
}
