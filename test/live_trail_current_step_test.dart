import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// QA 9489: while a turn runs, the line under «Hermes · Trabajando…» showed
// every skill and tool used so far («✦ hyperframes · ✦ creative/hyperframes
// · terminal…»), growing with each step until it was ellipsized. It must
// show only the current step, replacing the previous one.

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

List<String> _lines(WidgetTester tester) => [
  for (final element
      in find.byKey(const ValueKey('tool-run-summary')).evaluate())
    (element.widget as Text).textSpan!.toPlainText(),
];

void main() {
  testWidgets('running turn: the line shows only the latest step', (
    tester,
  ) async {
    // The skill icon renders as a U+FFFC placeholder in the plain text.
    const expected = [
      '\uFFFChyperframes',
      '\uFFFChyperframes',
      'terminal',
      'mcp__x',
    ];
    for (var i = 0; i < _sequence.length; i++) {
      await tester.pumpWidget(
        _host(_trace(_sequence.take(i + 1).toList(), active: true)),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('thinking-trace-live-in-pill')),
        findsOneWidget,
      );
      expect(_lines(tester), [expected[i]], reason: 'after step ${i + 1}');
      expect(
        find.byKey(const ValueKey('tool-run-skill-icon')),
        (i < 2) ? findsOneWidget : findsNothing,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('running turn: the row height never grows with more steps', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_trace(_sequence.take(1).toList(), active: true)),
    );
    await tester.pumpAndSettle();
    final first = tester.getSize(
      find.byKey(const ValueKey('thinking-trace-tools')),
    );
    await tester.pumpWidget(_host(_trace(_sequence, active: true)));
    await tester.pumpAndSettle();
    final last = tester.getSize(
      find.byKey(const ValueKey('thinking-trace-tools')),
    );
    expect(last.height, first.height);
    expect(_lines(tester).single, isNot(contains(' · ')));
  });

  testWidgets('running turn: a running call is not named on the line', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _trace([
          ..._sequence.take(3),
          _step('4', 'PRIVATE_TOOL', status: 'running'),
        ], active: true),
      ),
    );
    await tester.pumpAndSettle();
    // The running step is the activity pill's to name.
    expect(_lines(tester), ['terminal']);
    expect(find.textContaining('PRIVATE_TOOL'), findsNothing);
  });

  testWidgets('the step change cross-fades, and is instant without motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_trace(_sequence.take(3).toList(), active: true)),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(_host(_trace(_sequence, active: true)));
    await tester.pump(const Duration(milliseconds: 60));
    // Mid fade: the old step leaves while the new one arrives.
    expect(_lines(tester), unorderedEquals(['terminal', 'mcp__x']));
    await tester.pumpAndSettle();
    expect(_lines(tester), ['mcp__x']);

    await tester.pumpWidget(
      _host(
        _trace(_sequence.take(3).toList(), active: true),
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(_trace(_sequence, active: true), disableAnimations: true),
    );
    await tester.pump();
    expect(_lines(tester), ['mcp__x']);
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

  testWidgets('finished turn keeps its one-line summary, skills merged', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_trace(_sequence, active: false)));
    await tester.pumpAndSettle();
    expect(find.text('Pensó durante 1:12'), findsOneWidget);
    expect(_lines(tester), ['\uFFFChyperframes ×2 · terminal · mcp__x']);
    expect(find.byKey(const ValueKey('tool-run-skill-icon')), findsOneWidget);
  });
}
