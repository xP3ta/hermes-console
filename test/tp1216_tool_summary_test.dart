import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host(Widget child, {Locale locale = const Locale('es')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 380, child: child),
    ),
  ),
);

ChatTraceEvent _call(
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

List<ChatTraceEvent> _sixCalls({bool running = false}) => [
  _call('1', 'skill_view', args: {'name': 'github-pr-workflow'}),
  _call('2', 'terminal', args: {'command': 'git status'}),
  _call('3', 'read_file', args: {'path': 'docs/a.md'}),
  _call('4', 'terminal', args: {'command': 'flutter analyze'}),
  _call('5', 'read_file', args: {'path': 'docs/b.md'}),
  _call(
    '6',
    'terminal',
    args: {'command': 'flutter test'},
    status: running ? 'running' : 'completed',
  ),
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

String _summaryText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('tool-run-summary'))).data!;

void main() {
  group('summarizeToolRun', () {
    test('counts per tool, skills first and identified by name', () {
      final items = summarizeToolRun(
        _sixCalls().map(
          (e) => (
            label: e.label,
            skill: e.kind == ChatTraceEventKind.skill,
            detail: e.detail,
            running: false,
          ),
        ),
      );
      expect(
        [for (final i in items) (i.label, i.count, i.skill)],
        [
          ('github-pr-workflow', 1, true),
          ('terminal', 3, false),
          ('read_file', 2, false),
        ],
      );
    });

    test('a skill_view without a known name stays a plain tool', () {
      final items = summarizeToolRun([
        (label: 'skill_view', skill: false, detail: null, running: false),
      ]);
      expect(items.single.label, 'skill_view');
      expect(items.single.skill, isFalse);
    });

    test('gateway-marked skills keep their own label', () {
      final items = summarizeToolRun([
        (label: 'research-notes', skill: true, detail: null, running: true),
        (label: 'tool_search', skill: false, detail: null, running: false),
      ]);
      expect(items.single.label, 'research-notes');
      expect(items.single.skill, isTrue);
      expect(items.single.running, isTrue);
    });

    test('skill_view detail names the skill and resource, nothing else', () {
      expect(
        activityToolDetail('skill_view', {'name': 'github-pr-workflow'}),
        'github-pr-workflow',
      );
      expect(
        activityToolDetail('skill_view', {
          'name': 'github-pr-workflow',
          'file_path': 'references/api.md',
        }),
        'github-pr-workflow → api.md',
      );
      expect(
        activityToolDetail('skill_view', {'name': 'my-api-token'}),
        isNull,
      );
    });
  });

  // ct1215: the finished turn folds into one line that counts what it did
  // by kind, in Desktop's words and order; skills go by name.
  testWidgets('finished run: one folded line with counts and the skill', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_trace(_sixCalls(), active: false)));
    const label =
        'Pensó durante 1:12 · github-pr-workflow · '
        '2 archivos explorados · 3 comandos';
    expect(find.text(label), findsOneWidget);
    // No tool id reaches the folded line.
    expect(find.textContaining('read_file'), findsNothing);
    expect(find.textContaining('terminal'), findsNothing);
    // Accessible as a button that says whether it is open.
    final node = tester.getSemantics(
      find.byKey(const ValueKey('thinking-trace-summary')),
    );
    expect(node.label, label);
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.flagsCollection.isExpanded, Tristate.isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the folded line opens the run, oldest first', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_trace(_sixCalls(), active: false)));
    await tester.tap(find.byKey(const ValueKey('thinking-trace-summary')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('thinking-trace-steps')), findsOneWidget);
    expect(
      find.text('Skill cargada · github-pr-workflow', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.text('Ejecutó · flutter test', findRichText: true),
      findsOneWidget,
    );
    final first = tester.getTopLeft(
      find.byKey(const ValueKey('thinking-trace-step-1')),
    );
    final last = tester.getTopLeft(
      find.byKey(const ValueKey('thinking-trace-step-6')),
    );
    expect(first.dy, lessThan(last.dy));
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('thinking-trace-summary')))
          .flagsCollection
          .isExpanded,
      Tristate.isTrue,
    );
    // A second tap folds it again.
    await tester.tap(find.byKey(const ValueKey('thinking-trace-summary')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('thinking-trace-steps')), findsNothing);
  });

  testWidgets('running run: only the tool in hand is a row', (tester) async {
    await tester.pumpWidget(
      _host(_trace(_sixCalls(running: true), active: true)),
    );
    // QA 9489: the run never piles up while it is live.
    expect(find.byType(TurnToolRow), findsOneWidget);
    expect(
      find.text('Ejecutando · flutter test', findRichText: true),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('thinking-trace-summary')), findsNothing);
  });

  testWidgets('a call without a result never reaches the folded line', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _trace([
          _call('x', 'PRIVATE_TOOL', status: 'running'),
          _call('y', 'terminal'),
        ], active: false),
      ),
    );
    expect(find.text('Pensó durante 1:12 · 1 comando'), findsOneWidget);
    expect(find.textContaining('PRIVATE_TOOL'), findsNothing);
  });

  testWidgets('many kinds of tools wrap in two lines, never overflow', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _trace([
          for (final tool in const [
            'terminal',
            'read_file',
            'write_file',
            'search_files',
            'web_search',
            'web_extract',
            'patch',
          ])
            _call(tool, tool),
        ], active: false),
      ),
    );
    expect(
      find.text(
        'Pensó durante 1:12 · 2 archivos editados · 2 archivos explorados · '
        '1 búsqueda · 1 página leída · 1 comando',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a reasoning-only trace counts no tools', (tester) async {
    await tester.pumpWidget(
      _host(
        _trace([
          ChatTraceEvent(
            id: 'r',
            label: 'Razonamiento',
            status: 'completed',
            kind: ChatTraceEventKind.reasoning,
            preview: 'texto',
          ),
        ], active: false),
      ),
    );
    expect(find.text('Pensó durante 1:12'), findsOneWidget);
  });
  group('legacy ToolActivityGroup (tool messages without a unified trace)', () {
    Map<String, dynamic> call(String id, String name, [String args = '{}']) => {
      'role': 'assistant',
      'content': '',
      'tool_calls': [
        {
          'id': id,
          'type': 'function',
          'function': {'name': name, 'arguments': args},
        },
      ],
    };
    Map<String, dynamic> result(String id, String name) => {
      'role': 'tool',
      'tool_call_id': id,
      'tool_name': name,
      'content': '{"ok": true}',
    };

    testWidgets('the collapsed header counts calls, not call+result pairs', (
      tester,
    ) async {
      final events = [
        call('a', 'skill_view', '{"name": "github-pr-workflow"}'),
        result('a', 'skill_view'),
        call('b', 'terminal'),
        result('b', 'terminal'),
        call('c', 'terminal'),
        result('c', 'terminal'),
        call('d', 'read_file'),
        result('d', 'read_file'),
      ].map(ChatEventInfo.classify).toList();
      await tester.pumpWidget(_host(ToolActivityGroup(events: events)));
      // ct1215: the same words as a turn's folded line, never a tool id.
      expect(
        _summaryText(tester),
        'github-pr-workflow · 1 archivo explorado · 2 comandos',
      );
      expect(find.text('8 pasos'), findsOneWidget);
    });

    testWidgets('opened, every step is named in words, never by its id', (
      tester,
    ) async {
      final events = [
        call('a', 'skill_view', '{"name": "github-pr-workflow"}'),
        result('a', 'skill_view'),
        call('b', 'terminal'),
        result('b', 'terminal'),
        call('c', 'tool_search'),
        result('c', 'tool_search'),
        call('e', 'mcp__linear__list_issues'),
        call('f', 'some_new_tool'),
      ].map(ChatEventInfo.classify).toList();
      await tester.pumpWidget(_host(ToolActivityGroup(events: events)));
      await tester.tap(find.byKey(const ValueKey('tool-run-summary')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Skill cargada · github-pr-workflow'), findsOneWidget);
      // A call and its result are two rows of the old history.
      expect(find.text('Skill cargada'), findsOneWidget);
      expect(find.text('Comando ejecutado'), findsNWidgets(2));
      expect(find.text('Linear · list issues'), findsOneWidget);
      // Unknown to Console: its name in plain words.
      expect(find.text('Some New Tool'), findsOneWidget);
      // Hermes' own bridge tools are not named.
      expect(find.text('herramienta'), findsNWidgets(2));
      for (final id in const [
        'skill_view',
        'terminal',
        'tool_search',
        'mcp__',
        'some_new_tool',
      ]) {
        expect(find.textContaining(id), findsNothing, reason: id);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('without names it still says "actividad"', (tester) async {
      final events = [
        ChatEventInfo.classify({'role': 'tool', 'content': 'ok'}),
      ];
      await tester.pumpWidget(_host(ToolActivityGroup(events: events)));
      expect(find.text('actividad'), findsOneWidget);
      expect(find.byKey(const ValueKey('tool-run-summary')), findsNothing);
    });
  });
}
