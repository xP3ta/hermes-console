import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
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

String _summaryText(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('tool-run-summary')))
    .textSpan!
    .toPlainText();

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

  testWidgets('finished run: one line with counts and the skill marked', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_trace(_sixCalls(), active: false)));
    expect(find.text('Pensó durante 1:12'), findsOneWidget);
    expect(
      _summaryText(tester),
      contains('github-pr-workflow · terminal ×3 · read_file ×2'),
    );
    expect(find.byKey(const ValueKey('tool-run-skill-icon')), findsOneWidget);
    final line = tester.widget<Text>(
      find.byKey(const ValueKey('tool-run-summary')),
    );
    expect(line.maxLines, 1);
    // Accessible summary of the folded header.
    final semantics = tester
        .getSemantics(find.byKey(const ValueKey('thinking-trace-summary')))
        .getSemanticsData()
        .label;
    expect(
      semantics,
      'Pensó durante 1:12. skill github-pr-workflow, '
      'terminal, 3 veces, read_file, 2 veces',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the tool line expands the unchanged detail', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_trace(_sixCalls(), active: false)));
    await tester.tap(find.byKey(const ValueKey('thinking-trace-tools')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('activity-done-section')), findsOneWidget);
    expect(
      find.text('skill_view · github-pr-workflow', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.text('terminal · flutter test', findRichText: true),
      findsOneWidget,
    );
    // Expanded, the list says it all: the summary line steps aside.
    expect(find.byKey(const ValueKey('tool-run-summary')), findsNothing);
  });

  testWidgets('running group: "Trabajando…" plus the latest settled step', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_trace(_sixCalls(running: true), active: true)),
    );
    expect(
      find.byKey(const ValueKey('thinking-trace-live-in-pill')),
      findsOneWidget,
    );
    // The running call is the activity pill's to name; here only the last
    // step that already finished (QA 9489: it replaces, never piles up).
    expect(_summaryText(tester), 'read_file');
  });

  testWidgets('a call without a result never reaches the summary', (
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
    expect(_summaryText(tester), 'terminal');
    expect(find.textContaining('PRIVATE_TOOL'), findsNothing);
  });

  testWidgets('many tools collapse into "+N más"', (tester) async {
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
    expect(_summaryText(tester), endsWith('+2 más'));
  });

  testWidgets('a reasoning-only trace shows no tool line', (tester) async {
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
    expect(find.byKey(const ValueKey('tool-run-summary')), findsNothing);
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
      // The leading U+FFFC is the skill icon's placeholder.
      expect(
        _summaryText(tester),
        '\uFFFCgithub-pr-workflow · terminal ×2 · read_file',
      );
      expect(find.text('8 pasos'), findsOneWidget);
      expect(find.byKey(const ValueKey('tool-run-skill-icon')), findsOneWidget);
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
