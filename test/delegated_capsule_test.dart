import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/delegated_child_cards.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/core/widgets/subagent_activity_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// Design B: the header stays identity only; delegated work is a capsule above
// the composer («Delegado a N subagentes · m:ss · k/N ›») that opens an
// anchored sheet over itself, and each child has a card under the live row.

final _start = DateTime(2026, 11, 7);
final _scope = SubagentActivityScope(
  connectionId: 'test',
  parentSessionId: 'parent',
  runtimeSessionId: 'runtime',
  turnEpoch: 1,
);

SubagentActivity _agent(
  String id, {
  SubagentActivityPhase phase = SubagentActivityPhase.running,
  String? goal = 'Contar .md en ~/.hermes/skills',
  String? tool,
  String? toolPreview,
  String? summary,
  String? detail,
  SubagentTaskProgress? progress,
  double? seconds,
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
    goalPreview: goal,
    startedAt: _start,
    activeToolName: tool,
    activeToolPreview: toolPreview,
    summaryPreview: summary,
    detailPreview: detail,
    progress: progress,
    durationSeconds: seconds,
    completedAt: seconds == null
        ? null
        : _start.add(Duration(seconds: seconds.round())),
  ),
);

Widget _host(Widget child, {String lang = 'es', double scale = 1}) =>
    MaterialApp(
      locale: Locale(lang),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromMode(AppThemeMode.dark),
      builder: (context, body) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: true,
          textScaler: TextScaler.linear(scale),
        ),
        child: body!,
      ),
      home: Scaffold(body: child),
    );

Widget _capsule(
  List<SubagentActivity> agents, {
  DateTime? now,
  bool unconfirmed = false,
  VoidCallback? stop,
}) => Align(
  alignment: Alignment.bottomCenter,
  child: SubagentActivityCard(
    capsule: true,
    capsulePadding: const EdgeInsets.symmetric(horizontal: 16),
    activities: agents,
    now: now ?? _start.add(const Duration(seconds: 4)),
    unconfirmed: unconfirmed,
    turnSnapshot: ActivitySnapshot(turnActive: true, turnStartedAt: _start),
    onStop: stop,
    canSteer: (_) => false,
  ),
);

Finder get _cap => find.byKey(const ValueKey('delegates-capsule'));
Finder get _capText => find.byKey(const ValueKey('delegates-capsule-text'));

void main() {
  group('the capsule above the composer', () {
    testWidgets('draws nothing at rest', (tester) async {
      await tester.pumpWidget(_host(_capsule(const [])));
      expect(_cap, findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('while delegating: count, clock and k/N; 48 dp target, a 36 dp '
        'capsule', (tester) async {
      await tester.pumpWidget(
        _host(
          _capsule([
            _agent('a'),
            _agent('b', phase: SubagentActivityPhase.completed, seconds: 3),
          ]),
        ),
      );
      expect(
        tester.widget<Text>(_capText).data,
        'Delegado a 2 subagentes · 0:04 · 1/2',
      );
      expect(tester.getSize(_cap).height, 48);
      final visual = find.ancestor(
        of: _capText,
        matching: find.byWidgetPredicate((w) => w is SizedBox && w.height == 36),
      );
      expect(visual, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('finishing well: ✓ N terminaron for ~3 s, then it leaves', (
      tester,
    ) async {
      final running = [_agent('a'), _agent('b')];
      final done = [
        _agent('a', phase: SubagentActivityPhase.completed, seconds: 5),
        _agent('b', phase: SubagentActivityPhase.completed, seconds: 6),
      ];
      final now = _start.add(const Duration(seconds: 6));
      await tester.pumpWidget(_host(_capsule(running, now: now)));
      await tester.pumpWidget(_host(_capsule(done, now: now)));
      expect(find.textContaining('✓ 2 subagentes terminaron'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 2800));
      expect(_cap, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      expect(_cap, findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failure stays until the sheet is opened and closed', (
      tester,
    ) async {
      final now = _start.add(const Duration(seconds: 6));
      await tester.pumpWidget(
        _host(_capsule([_agent('a'), _agent('b')], now: now)),
      );
      await tester.pumpWidget(
        _host(
          _capsule([
            _agent('a', phase: SubagentActivityPhase.failed, seconds: 2),
            _agent('b', phase: SubagentActivityPhase.completed, seconds: 5),
          ], now: now),
        ),
      );
      await tester.pump(const Duration(seconds: 10));
      expect(find.textContaining('Falló'), findsOneWidget);
      await tester.tap(_cap);
      await tester.pumpAndSettle();
      Navigator.of(
        tester.element(find.byKey(const ValueKey('subagent-panel'))),
      ).pop();
      await tester.pumpAndSettle();
      expect(_cap, findsNothing, reason: 'acknowledged by closing the sheet');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('unconfirmed work is never shown as progress', (tester) async {
      await tester.pumpWidget(
        _host(
          _capsule([
            _agent('a', phase: SubagentActivityPhase.unknown),
          ]),
        ),
      );
      final text = tester.widget<Text>(_capText).data!;
      expect(text, isNot(contains('Delegado a')));
      expect(text, isNot(contains('/')));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the sheet opens over the capsule, Stop is for children only, '
        'the queue stays out', (tester) async {
      var stops = 0;
      await tester.pumpWidget(
        _host(_capsule([_agent('a'), _agent('b')], stop: () => stops++)),
      );
      final capsuleTop = tester.getTopLeft(_cap).dy;
      await tester.tap(_cap);
      await tester.pumpAndSettle();
      final panel = find.byKey(const ValueKey('subagent-panel'));
      expect(panel, findsOneWidget);
      expect(
        tester.getBottomLeft(panel).dy,
        lessThanOrEqualTo(capsuleTop + 8),
        reason: 'the sheet sits above the capsule',
      );
      expect(find.text('En segundo plano · 0:04'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('delegates-stop')));
      await tester.pump();
      expect(stops, 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('it follows the width live and never overflows (2x text, 320)', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final size in const [
        Size(390, 844),
        Size(844, 390),
        Size(320, 640),
        Size(720, 780),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          _host(_capsule([_agent('a'), _agent('b')]), scale: 2),
        );
        await tester.pump();
        expect(tester.getSize(_cap).width, closeTo(size.width - 32, 1));
        expect(tester.takeException(), isNull, reason: '$size');
      }
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('subagent cards in the chat', () {
    Widget cards(List<SubagentActivity> agents) => _host(
      SingleChildScrollView(
        child: DelegatedChildCards(
          subagents: agents,
          clock: () => _start.add(const Duration(seconds: 4)),
        ),
      ),
    );

    testWidgets('a working child: name and clock, goal, real tool line', (
      tester,
    ) async {
      await tester.pumpWidget(
        cards([
          _agent(
            'a',
            tool: 'read_file',
            toolPreview: '/home/u/skills/main.dart',
            progress: const SubagentTaskProgress(taskIndex: 1, taskCount: 4),
          ),
          _agent('b', goal: 'Ejecutar uname -a'),
        ]),
      );
      expect(find.text('Subagente 1 · 0:04'), findsOneWidget);
      expect(find.text('Subagente 2 · 0:04'), findsOneWidget);
      expect(find.text('Contar .md en ~/.hermes/skills'), findsOneWidget);
      expect(find.text('Ejecutar uname -a'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('delegated-child-status-a')))
            .data,
        contains('main.dart'),
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no data: «sin datos» and an indeterminate bar', (tester) async {
      await tester.pumpWidget(cards([_agent('a')]));
      expect(find.text('sin datos'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('delegated-child-progress-a')),
      );
      // Reduced motion in this host: static, never an invented fraction.
      expect(bar.value, 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a finished child folds to one line with its result', (
      tester,
    ) async {
      await tester.pumpWidget(
        cards([
          _agent(
            'a',
            phase: SubagentActivityPhase.completed,
            summary: '412 archivos .md',
            seconds: 3,
          ),
        ]),
      );
      expect(find.text('Subagente 1 · 412 archivos .md'), findsOneWidget);
      expect(find.text('Contar .md en ~/.hermes/skills'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failed child keeps its card with the public error', (
      tester,
    ) async {
      await tester.pumpWidget(
        cards([
          _agent(
            'a',
            phase: SubagentActivityPhase.failed,
            summary: 'No tiene credenciales disponibles',
            seconds: 2,
          ),
        ]),
      );
      expect(find.text('No tiene credenciales disponibles'), findsOneWidget);
      expect(find.text('Contar .md en ~/.hermes/skills'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('secrets in the goal, tool input or result never show', (
      tester,
    ) async {
      await tester.pumpWidget(
        cards([
          _agent(
            'a',
            goal: 'Entrar con el token sk-live-12345678',
            tool: 'terminal',
            toolPreview: 'curl -H "Authorization: Bearer sk-live-1" https://x.io',
          ),
          _agent(
            'b',
            phase: SubagentActivityPhase.completed,
            summary: 'clave sk-live-87654321 usada',
            seconds: 1,
          ),
        ]),
      );
      expect(find.textContaining('sk-live'), findsNothing);
      expect(find.textContaining('Bearer'), findsNothing);
      expect(
        find.byKey(const ValueKey('delegated-child-goal-a')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('unconfirmed child never claims progress', (tester) async {
      await tester.pumpWidget(
        cards([_agent('a', phase: SubagentActivityPhase.unknown)]),
      );
      expect(find.textContaining('sin datos'), findsNothing);
      expect(find.text('Sin confirmar'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('under the live row only while the turn is live', (
      tester,
    ) async {
      Widget turn(bool active) => _host(
        LiveTurnScope(
          inlineActivity: true,
          status: LiveTurnStatus(
            active: active,
            startedAt: _start,
            subagents: [_agent('a'), _agent('b')],
          ),
          clock: () => _start.add(const Duration(seconds: 4)),
          child: ThinkingTraceCard(
            active: active,
            stepCards: true,
            events: const [],
            headerBuilder: (_, summary, details) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [summary, details],
            ),
          ),
        ),
      );
      await tester.pumpWidget(turn(true));
      expect(find.byKey(const ValueKey('delegated-child-cards')), findsOneWidget);
      expect(find.text('Subagente 1 · 0:04'), findsOneWidget);
      await tester.pumpWidget(turn(false));
      expect(find.byKey(const ValueKey('delegated-child-cards')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
