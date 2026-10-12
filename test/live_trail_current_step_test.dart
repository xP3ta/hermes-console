import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// QA 9489: while a turn runs, the line under «Hermes · Trabajando…» showed
// every skill and tool used so far («✦ hyperframes · ✦ creative/hyperframes
// · terminal…»), growing with each step until it was ellipsized. It must
// show only the current step, replacing the previous one.
//
// ct1215: the step in hand is now a row of the turn («Ejecutó · ls  0,9 s»)
// in plain words; the rule stands.

Widget _host(Widget child, {bool disableAnimations = false}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 380, child: child),
      ),
    ),
  ),
);

ChatTraceEvent _step(
  String id,
  String tool, {
  Map<String, Object?> args = const {},
  String status = 'completed',
  ChatTraceEventKind kind = ChatTraceEventKind.tool,
}) => ChatTraceEvent(
  id: id,
  label: tool,
  status: status,
  kind: kind,
  detail: activityToolDetail(tool, args),
  duration: const Duration(milliseconds: 900),
);

final _sequence = <ChatTraceEvent>[
  _step('1', 'skill_view', args: {'name': 'hyperframes'}),
  _step('2', 'skill_view', args: {'name': 'creative/hyperframes'}),
  _step('3', 'terminal', args: {'command': 'ls'}),
  _step('4', 'mcp__x'),
];

Widget _trace(List<ChatTraceEvent> events, {required bool active}) =>
    ThinkingTraceCard(
      events: events,
      active: active,
      liveInPill: true,
      duration: active ? null : const Duration(seconds: 72),
      headerBuilder: (context, summary, details) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(width: 50),
              Expanded(child: summary),
            ],
          ),
          details,
        ],
      ),
    );

/// The tool rows the live turn shows, as plain text.
List<String> _rows(WidgetTester tester) => [
  for (final element in find.byType(TurnToolRow).evaluate())
    // The row's own line; its duration is a second text.
    tester
        .widgetList<Text>(
          find.descendant(
            of: find.byElementPredicate((e) => e == element),
            matching: find.byType(Text),
          ),
        )
        .first
        .textSpan!
        .toPlainText(),
];

void main() {
  // QA 9489, kept by ct1215: a live turn names one step, the one in hand,
  // and replaces it in place.
  testWidgets('running turn: one row, the latest step', (tester) async {
    const expected = [
      'Skill cargada · hyperframes',
      'Skill cargada · creative/hyperframes',
      'Ejecutó · ls',
      'X',
    ];
    for (var i = 0; i < _sequence.length; i++) {
      await tester.pumpWidget(
        _host(_trace(_sequence.take(i + 1).toList(), active: true)),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('thinking-trace-live')), findsOneWidget);
      expect(_rows(tester), [expected[i]], reason: 'after step ${i + 1}');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('running turn: the lines never grow with more steps', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_trace(_sequence.skip(2).take(1).toList(), active: true)),
    );
    await tester.pump();
    final first = tester.getSize(
      find.byKey(const ValueKey('thinking-trace-live')),
    );
    await tester.pumpWidget(
      _host(
        _trace([
          _sequence[0],
          _sequence[1],
          _sequence[3],
          _sequence[2],
        ], active: true),
      ),
    );
    await tester.pump();
    final last = tester.getSize(
      find.byKey(const ValueKey('thinking-trace-live')),
    );
    expect(find.byType(TurnToolRow), findsOneWidget);
    expect(last.height, first.height);
  });

  testWidgets('running turn: the running call is the row, with its timer', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _trace([
          ..._sequence.take(3),
          ChatTraceEvent(
            id: '4',
            label: 'terminal',
            status: 'running',
            detail: 'pytest',
            startedAt: DateTime.now().subtract(const Duration(seconds: 7)),
          ),
        ], active: true),
      ),
    );
    await tester.pump();
    expect(_rows(tester), ['Ejecutando · pytest']);
    expect(find.text('0:07'), findsOneWidget);
  });

  testWidgets('the step change is in place, with or without motion', (
    tester,
  ) async {
    for (final still in [false, true]) {
      await tester.pumpWidget(
        _host(
          _trace(_sequence.take(3).toList(), active: true),
          disableAnimations: still,
        ),
      );
      await tester.pump();
      await tester.pumpWidget(
        _host(_trace(_sequence, active: true), disableAnimations: still),
      );
      await tester.pump();
      expect(_rows(tester), ['X']);
    }
  });
  group('skills are deduplicated by name without category', () {
    test('skill_view by name and by category/name count once', () {
      final items = summarizeToolRun([
        for (final e in _sequence)
          (
            label: e.label,
            skill: e.kind == ChatTraceEventKind.skill,
            detail: e.detail,
            running: false,
          ),
      ]);
      expect(
        [for (final i in items) (i.label, i.count, i.skill)],
        [
          ('hyperframes', 2, true),
          ('terminal', 1, false),
          ('mcp__x', 1, false),
        ],
      );
    });

    test('gateway-marked skills with a category merge too', () {
      final items = summarizeToolRun([
        (
          label: 'creative/hyperframes',
          skill: true,
          detail: null,
          running: false,
        ),
        (label: 'hyperframes', skill: true, detail: null, running: false),
      ]);
      expect(items.single.label, 'hyperframes');
      expect(items.single.count, 2);
    });

    test('a plain tool with a slash is left alone', () {
      final items = summarizeToolRun([
        (label: 'ns/tool', skill: false, detail: null, running: false),
      ]);
      expect(items.single.label, 'ns/tool');
    });
  });

  testWidgets('finished turn folds into one line, skills merged', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_trace(_sequence, active: false)));
    await tester.pump();
    expect(
      find.text('Pensó durante 1:12 · hyperframes · 1 comando · 1 herramienta'),
      findsOneWidget,
    );
    expect(find.byType(TurnToolRow), findsNothing);
  });
}
