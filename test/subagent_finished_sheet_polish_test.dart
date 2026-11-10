// The finished-subagent surfaces, side by side with the official app (lanes
// S2/S5 of REPORT-OFICIAL-VS-CONSOLE): «✓ N subagentes terminados» above the
// composer instead of «Sin confirmar» once the server said every child
// ended; each sheet row with its goal, «Terminado · 0:35 · modelo» and no
// «Parar»; «Duración» (not «Terminó») for the time it took, with an outline
// icon on every row of «Qué ha hecho»; and the event turn without a fake
// «Trabajó 0 s».
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart'
    show HermesListRow;
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/screens/subagent_detail_screen.dart';
import 'package:hermes_android/core/services/subagent_finished_record.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_live_icon.dart';
import 'package:hermes_android/core/widgets/chat/tool_steps_summary.dart';
import 'package:hermes_android/core/widgets/subagent_activity_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

final _start = DateTime.utc(2026, 11, 7, 17, 19);
final _scope = SubagentActivityScope(
  connectionId: 'test',
  parentSessionId: 'parent',
  runtimeSessionId: 'runtime',
  turnEpoch: 1,
);

/// A child as it reaches the chat after a resume: its outcome from the
/// server, but no goal, no model and no timing of its own.
SubagentActivity _bare(
  String id, {
  SubagentActivityPhase phase = SubagentActivityPhase.completed,
}) => SubagentActivity(
  key: SubagentActivityKey(
    scope: _scope,
    identityKind: SubagentIdentityKind.subagent,
    stableId: id,
  ),
  source: SubagentActivitySource.native,
  phase: phase,
  subagentId: id,
  details: const SubagentActivityDetails(),
);

SubagentActivity _running(String id) => SubagentActivity(
  key: SubagentActivityKey(
    scope: _scope,
    identityKind: SubagentIdentityKind.subagent,
    stableId: id,
  ),
  source: SubagentActivitySource.native,
  phase: SubagentActivityPhase.running,
  subagentId: id,
  details: SubagentActivityDetails(
    goalPreview: 'Contar archivos',
    startedAt: _start,
  ),
);

const _goal =
    'Ejecuta exactamente el bucle de seis pasos y dime la salida\n'
    'Segunda línea que no va en la fila';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromMode(AppThemeMode.dark),
  builder: (context, body) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: body!,
  ),
  home: Scaffold(body: child),
);

Widget _capsule(
  List<SubagentActivity> agents, {
  bool unconfirmed = true,
  VoidCallback? stop,
  SubagentFinishedRecordLoader? load,
}) => Align(
  alignment: Alignment.bottomCenter,
  child: SubagentActivityCard(
    capsule: true,
    capsulePadding: const EdgeInsets.symmetric(horizontal: 16),
    activities: agents,
    now: _start.add(const Duration(seconds: 40)),
    unconfirmed: unconfirmed,
    turnSnapshot: const ActivitySnapshot(),
    onStop: stop,
    canSteer: (_) => false,
    loadFinishedRecord: load,
  ),
);

Finder get _cap => find.byKey(const ValueKey('delegates-capsule'));
Finder get _capText => find.byKey(const ValueKey('delegates-capsule-text'));

Future<SubagentFinishedRecord> _record(SubagentActivity _) async =>
    const SubagentFinishedRecord(
      source: SubagentRecordSource.parent,
      goal: _goal,
      model: 'claude-opus-5-5',
      durationSeconds: 35,
    );

void main() {
  group('the capsule once every child ended', () {
    testWidgets('a stale roster of completed children reads «✓ N subagentes '
        'terminados», never «Sin confirmar»', (tester) async {
      await tester.pumpWidget(_host(_capsule([_bare('a'), _bare('b')])));
      expect(_cap, findsOneWidget);
      expect(
        tester.widget<Text>(_capText).data,
        '✓ 2 subagentes terminados',
      );
      expect(find.text('Sin confirmar'), findsNothing);
      // It stays (as the doubt did): the official «✓ 1 subagent finished».
      await tester.pump(const Duration(seconds: 10));
      expect(_capText, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('one child of unknown state still says «Sin confirmar»', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _capsule([
            _bare('a'),
            _bare('b', phase: SubagentActivityPhase.unknown),
          ]),
        ),
      );
      expect(tester.widget<Text>(_capText).data, 'Sin confirmar');
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the sheet of finished children', () {
    testWidgets('each row has its goal, «Terminado · 0:35 · modelo»; no '
        '«Parar» when every child ended', (tester) async {
      var stops = 0;
      final loaded = <String>[];
      await tester.pumpWidget(
        _host(
          _capsule(
            [_bare('a'), _bare('b')],
            stop: () => stops++,
            load: (activity) {
              loaded.add(activity.key.stableId);
              return _record(activity);
            },
          ),
        ),
      );
      await tester.tap(_cap);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('subagent-panel')), findsOneWidget);
      expect(loaded, unorderedEquals(['a', 'b']));
      for (final id in ['a', 'b']) {
        final title = tester.widget<Text>(
          find.byKey(ValueKey('subagent-row-title-$id')),
        );
        expect(
          title.data,
          'Ejecuta exactamente el bucle de seis pasos y dime la salida',
        );
        expect(title.maxLines, isNotNull);
        expect(title.overflow, TextOverflow.ellipsis);
        final status = find.byKey(ValueKey('subagent-row-status-$id'));
        expect(
          find.descendant(
            of: status,
            matching: find.textContaining(
              '0:35 · claude-opus-5-5',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: status,
            matching: find.textContaining('Terminado'),
          ),
          findsOneWidget,
        );
      }
      expect(find.text('Subagente'), findsNothing);
      expect(find.textContaining('Segunda línea'), findsNothing);
      expect(find.byKey(const ValueKey('delegates-stop')), findsNothing);
      expect(find.text('Parar'), findsNothing);
      expect(find.text('Sin confirmar'), findsNothing);
      expect(stops, 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('«Parar» stays while a child still works', (tester) async {
      var stops = 0;
      await tester.pumpWidget(
        _host(
          _capsule(
            [_bare('a'), _running('b')],
            unconfirmed: false,
            stop: () => stops++,
            load: _record,
          ),
        ),
      );
      await tester.tap(_cap);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delegates-stop')));
      await tester.pump();
      expect(stops, 1);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('«Qué ha hecho» of a finished child', () {
    testWidgets('«Duración 0:04», and every row carries an outline icon', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 3000);
      addTearDown(tester.view.reset);
      final activity = SubagentActivity(
        key: SubagentActivityKey(
          scope: _scope,
          identityKind: SubagentIdentityKind.subagent,
          stableId: 'done',
        ),
        source: SubagentActivitySource.native,
        phase: SubagentActivityPhase.completed,
        subagentId: 'done',
        details: SubagentActivityDetails(
          goalPreview: 'Contar archivos',
          startedAt: _start,
          completedAt: _start.add(const Duration(seconds: 4)),
          durationSeconds: 4,
          toolCount: 2,
          filesReadCount: 1,
        ),
      );
      final roster = ValueNotifier<List<SubagentActivity>>([activity]);
      addTearDown(roster.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: SubagentDetailScreen(
            roster: roster,
            activityKey: activity.key,
            parentTitle: 'Chat de prueba',
            clock: () => _start.add(const Duration(minutes: 1)),
          ),
        ),
      );
      await tester.pump();
      final timeline = find.byKey(const ValueKey('subagent-detail-timeline'));
      expect(timeline, findsOneWidget);
      final current = tester.widget<HermesListRow>(
        find.byKey(const ValueKey('subagent-detail-current-step')),
      );
      expect(current.title, 'Duración');
      expect(current.value, '0:04');
      final rows = find.descendant(
        of: timeline,
        matching: find.byType(HermesListRow),
      );
      final titles = [
        for (final row in tester.widgetList<HermesListRow>(rows)) row.title,
      ];
      expect(titles, contains('Empezó'));
      expect(titles, contains('Terminó'));
      expect(titles.where((t) => t == 'Terminó'), hasLength(1));
      expect(titles.length, greaterThanOrEqualTo(4));
      for (var i = 0; i < titles.length; i++) {
        expect(
          find.descendant(
            of: rows.at(i),
            matching: find.byType(ChatLiveIcon),
          ),
          findsOneWidget,
          reason: '«${titles[i]}» has its icon',
        );
      }
    });
  });

  group('the event turn (async_delegation_complete)', () {
    final es = lookupStrings(const Locale('es'));
    final en = lookupStrings(const Locale('en'));
    const none = <TurnSummaryAction>[];

    test('no tools, no real time: «✓ N subagentes terminados»', () {
      expect(
        inlineTurnSummary(es, none, duration: Duration.zero, agentCount: 2),
        '✓ 2 subagentes terminados',
      );
      expect(
        inlineTurnSummary(es, none, agentCount: 1),
        '✓ 1 subagente terminado',
      );
      expect(
        inlineTurnSummary(
          en,
          none,
          duration: const Duration(milliseconds: 400),
          agentCount: 1,
        ),
        '✓ 1 subagent finished',
      );
    });

    test('a real duration keeps «Trabajó 49 s · N subagentes»', () {
      expect(
        inlineTurnSummary(
          es,
          none,
          duration: const Duration(seconds: 49),
          agentCount: 1,
        ),
        'Trabajó 49 s · 1 subagente',
      );
    });

    test('tools and no real time: «Trabajó» without «0 s»', () {
      final label = inlineTurnSummary(
        es,
        const [(tool: 'terminal', target: null, failed: false, duration: null)],
        duration: Duration.zero,
        agentCount: 2,
      );
      expect(label, isNot(contains('0 s')));
      expect(label, startsWith('Trabajó · '));
    });
  });
}
