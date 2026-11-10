import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/turn_activity_pill.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/core/widgets/subagent_activity_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// The approved v4 video: the live row shows a step counter and a chevron
// that points down when folded (no clock); the header's sheet is titled by
// what it holds and for how long, and numbers its children.

final _start = DateTime(2026, 11, 6);
final _scope = SubagentActivityScope(
  connectionId: 'test',
  parentSessionId: 'parent',
  runtimeSessionId: 'runtime',
  turnEpoch: 1,
);

SubagentActivity _agent(
  String id, {
  SubagentActivityPhase phase = SubagentActivityPhase.running,
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
    goalPreview: 'Revisar $id',
    startedAt: _start,
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
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

Widget _delegates(
  List<SubagentActivity> agents,
  DateTime now, {
  bool owner = true,
}) => Align(
  alignment: Alignment.bottomCenter,
  child: SubagentActivityCard(
    capsule: true,
    capsulePadding: const EdgeInsets.symmetric(horizontal: 16),
    activities: agents,
    now: now,
    turnSnapshot: ActivitySnapshot(turnActive: true, turnStartedAt: _start),
    onStop: owner ? () {} : null,
    canSteer: owner ? (_) => false : null,
  ),
);

double _turns(WidgetTester tester) => tester
    .widget<AnimatedRotation>(
      find.descendant(
        of: find.byType(TurnInlineActivity),
        matching: find.byType(AnimatedRotation),
      ),
    )
    .turns;

/// What the live card says to a screen reader (its text is «Trabajando»).
String _spoken(WidgetTester tester) => tester
    .widget<Semantics>(find.byKey(const ValueKey('chat-inline-activity')))
    .properties
    .label!;

void main() {
  testWidgets('live row: card with the clock, the tool count and a folded chevron', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        TurnInlineActivity(
          label: 'Ejecutando date',
          live: true,
          steps: 3,
          open: false,
          startedAt: _start,
          clock: () => _start.add(const Duration(seconds: 12)),
          onTap: () {},
        ),
      ),
    );
    expect(find.text('Ejecutando date'), findsOneWidget);
    // The live look (9 nov 2026) supersedes the v4 video here: the card
    // shows «m:ss · N herramientas» always, not only the count.
    expect(find.text('3 herramientas'), findsOneWidget);
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('chat-inline-activity-clock')),
          )
          .data,
      '0:12',
    );
    expect(_turns(tester), 0, reason: 'folded chevron points down');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('open row flips the chevron up', (tester) async {
    await tester.pumpWidget(
      _host(
        TurnInlineActivity(
          label: 'Ejecutando date',
          live: true,
          steps: 1,
          open: true,
          onTap: () {},
        ),
      ),
    );
    expect(_turns(tester), .5);
    await tester.pumpWidget(const SizedBox());
  });

  for (final lang in ['es', 'en', 'de', 'fr', 'it', 'ja', 'ko', 'pt', 'zh']) {
    testWidgets('header sheet is titled by what it holds ($lang)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _delegates([
            _agent('a'),
            _agent('b'),
          ], _start.add(const Duration(seconds: 4))),
          lang: lang,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('delegates-capsule')));
      await tester.pumpAndSettle();
      final live = Strings.of(
        tester.element(find.byKey(const ValueKey('subagent-panel'))),
      ).chatDelegatesSheetLive('0:04');
      expect(find.text(live), findsOneWidget);
      expect(live, contains('0:04'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('children are numbered and the title says Delegado when done', (
    tester,
  ) async {
    // The pill waits for acknowledgement when a task failed, so the sheet can
    // be opened once no task is live any more.
    final live = [_agent('a'), _agent('b')];
    final done = [
      _agent('a', phase: SubagentActivityPhase.failed, seconds: 6),
      _agent('b', phase: SubagentActivityPhase.failed, seconds: 5),
    ];
    final now = _start.add(const Duration(seconds: 7));
    await tester.pumpWidget(_host(_delegates(live, now, owner: false)));
    await tester.pumpWidget(_host(_delegates(done, now, owner: false)));
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.byKey(const ValueKey('delegates-capsule')));
    await tester.pumpAndSettle();
    expect(find.text('Delegado · 0:06'), findsOneWidget);
    expect(find.text('Subagente 1'), findsOneWidget);
    expect(find.text('Subagente 2'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a single child keeps the plain name', (tester) async {
    await tester.pumpWidget(
      _host(
        _delegates([
          _agent('a'),
        ], _start.add(const Duration(seconds: 4)), owner: false),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('delegates-capsule')));
    await tester.pumpAndSettle();
    expect(find.text('Subagente'), findsOneWidget);
    expect(find.text('Subagente 1'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the live card shows the turn clock folded and open', (tester) async {
    Widget row(bool open) => _host(
      TurnInlineActivity(
        label: 'Pensando…',
        live: true,
        steps: 0,
        open: open,
        startedAt: _start,
        clock: () => _start.add(const Duration(seconds: 50)),
        onTap: () {},
      ),
    );
    await tester.pumpWidget(row(false));
    final clock = find.byKey(const ValueKey('chat-inline-activity-clock'));
    expect(clock, findsOneWidget);
    await tester.pumpWidget(row(true));
    expect(clock, findsOneWidget);
    expect(tester.widget<Text>(clock).data, '0:50');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the live row names the whole command', (tester) async {
    Widget turn(String command) => _host(
      LiveTurnScope(
        inlineActivity: true,
        status: LiveTurnStatus(
          active: true,
          startedAt: _start,
          step: ActivityStep(
            id: 't1',
            kind: ActivityStepKind.tool,
            label: 'terminal',
            status: ActivityStepStatus.running,
            detail: command,
          ),
        ),
        clock: () => _start.add(const Duration(seconds: 3)),
        child: ThinkingTraceCard(
          active: true,
          stepCards: true,
          events: [
            ChatTraceEvent(
              id: 't1',
              label: 'terminal',
              status: 'running',
              detail: command,
            ),
          ],
          headerBuilder: (_, summary, details) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [summary, details],
          ),
        ),
      ),
    );
    await tester.pumpWidget(turn('uname -a'));
    expect(_spoken(tester), contains('Ejecutando uname -a'));
    await tester.pumpWidget(turn('ls /tmp'));
    expect(_spoken(tester), contains('Ejecutando ls /tmp'));
    // A command that names a secret falls back to the executable alone.
    await tester.pumpWidget(
      turn('curl -H "Authorization: Bearer sk-live-1" https://x.io'),
    );
    expect(_spoken(tester), contains('Ejecutando curl'));
    expect(find.textContaining('sk-live'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sheet rows describe each task under its name', (tester) async {
    await tester.pumpWidget(
      _host(
        _delegates([
          _agent('a'),
          _agent('b'),
        ], _start.add(const Duration(seconds: 4)), owner: false),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('delegates-capsule')));
    await tester.pumpAndSettle();
    expect(find.text('Subagente 1'), findsOneWidget);
    expect(find.text('Revisar a'), findsOneWidget);
    expect(find.text('Revisar b'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('subagent-row-description-a')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a goal that names a secret gets no description', (tester) async {
    final secretive = SubagentActivity(
      key: SubagentActivityKey(
        scope: _scope,
        identityKind: SubagentIdentityKind.subagent,
        stableId: 's',
      ),
      source: SubagentActivitySource.native,
      phase: SubagentActivityPhase.running,
      subagentId: 's',
      details: SubagentActivityDetails(
        goalPreview: 'Entrar con el token sk-live-12345678',
        startedAt: _start,
      ),
    );
    await tester.pumpWidget(
      _host(
        _delegates([
          secretive,
        ], _start.add(const Duration(seconds: 4)), owner: false),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('delegates-capsule')));
    await tester.pumpAndSettle();
    expect(find.textContaining('sk-live'), findsNothing);
    expect(
      find.byKey(const ValueKey('subagent-row-description-s')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the delegating row is plural-aware', (tester) async {
    await tester.pumpWidget(_host(const SizedBox()));
    final s = Strings.of(tester.element(find.byType(Scaffold)));
    expect(s.chatLiveDelegating(1), 'Delegando 1 tarea');
    expect(s.chatLiveDelegating(2), 'Delegando 2 tareas');
    await tester.pumpWidget(const SizedBox());
  });
}
