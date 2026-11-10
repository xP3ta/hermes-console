import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/widgets/chat/tool_steps_summary.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

TurnSummaryAction action(
  String tool, {
  bool failed = false,
  int? seconds,
  String? target,
}) => (
  tool: tool,
  target: target,
  failed: failed,
  duration: seconds == null ? null : Duration(seconds: seconds),
);

void main() {
  final es = lookupStrings(const Locale('es'));
  final en = lookupStrings(const Locale('en'));

  test('measured whole-turn time, counts, verbs and count relevance', () {
    final actions = [
      action('terminal'),
      action('web_search'),
      action('read_file', target: 'one.yaml'),
      action('exec_command'),
      action('read_file', target: 'two.yaml'),
      action('read_file', target: 'three.yaml'),
    ];
    expect(
      turnLineSummary(
        es,
        actions,
        duration: const Duration(seconds: 134),
      ).label,
      'Trabajó 2:14 · Leyó 3 archivos · Ejecutó 2 comandos · Buscó en la web',
    );
    expect(
      turnLineSummary(
        en,
        actions,
        duration: const Duration(seconds: 134),
      ).label,
      'Worked 2:14 · Read 3 files · Ran 2 commands · Searched the web',
    );
  });

  test(
    'ties use measured effort, then stable relevance, not arrival order',
    () {
      expect(
        turnLineSummary(es, [
          action('read_file', seconds: 1, target: 'config.yaml'),
          action('terminal', seconds: 12),
          action('apply_patch', seconds: 1, target: 'config.yaml'),
        ]).label,
        'Trabajó · Ejecutó 1 comando · Editó 1 archivo · Leyó 1 archivo',
      );
    },
  );

  test('three action kinds, +N more and a full accessible summary', () {
    final summary = turnLineSummary(es, [
      action('terminal'),
      action('read_file', target: 'config.yaml'),
      action('apply_patch', target: 'config.yaml'),
      action('web_search'),
      action('web_fetch'),
    ]);
    expect(
      summary.label,
      'Trabajó · Editó 1 archivo · Leyó 1 archivo · Ejecutó 1 comando · +2 más',
    );
    expect(
      summary.semanticsLabel,
      'Trabajó · Editó 1 archivo · Leyó 1 archivo · Ejecutó 1 comando · Buscó en la web · Abrió 1 página',
    );
  });

  test('MEDIO-1: reads and edits count distinct safe filenames', () {
    expect(
      turnLineSummary(es, [
        action('read_file', target: 'same.dart'),
        action('read_file', target: 'same.dart'),
        action('read_file', target: 'same.dart'),
      ]).label,
      'Trabajó · Leyó 1 archivo',
    );
    expect(
      turnLineSummary(es, [
        action('edit_file', target: 'one.dart'),
        action('apply_patch', target: 'one.dart'),
        action('write_file', target: 'two.dart'),
      ]).label,
      'Trabajó · Editó 2 archivos',
    );
  });

  test('MEDIO-1: unknown/mixed targets count calls without claiming files', () {
    expect(
      turnLineSummary(es, [action('read_file'), action('read_file')]).label,
      'Trabajó · Leyó 2 veces',
    );
    expect(
      turnLineSummary(es, [
        action('edit_file', target: 'one.dart'),
        action('edit_file'),
      ]).label,
      'Trabajó · Editó 2 veces',
    );
  });

  test('MEDIO-1: code execution is not described as shell commands', () {
    expect(
      turnLineSummary(es, [action('execute_code')]).label,
      'Trabajó · Ejecutó código',
    );
    expect(
      turnLineSummary(es, [
        action('execute_code'),
        action('execute_code'),
        action('terminal'),
      ]).label,
      'Trabajó · Ejecutó código 2 veces · Ejecutó 1 comando',
    );
    expect(
      turnLineSummary(en, [action('execute_code')]).label,
      'Worked · Ran code',
    );
  });

  test('failures and known agents survive truncation; no guessed roster', () {
    final summary = turnLineSummary(
      es,
      [
        action('terminal', failed: true),
        action('terminal'),
        action('delegate_task'),
      ],
      duration: const Duration(seconds: 29),
      agentCount: 2,
    );
    expect(
      summary.label,
      'Trabajó 0:29 · Ejecutó 2 comandos · Delegó 1 tarea · 1 falló · 2 agentes',
    );
    expect(
      turnLineSummary(es, [action('delegate_task')]).label,
      'Trabajó · Delegó 1 tarea',
    );
    expect(
      turnLineSummary(es, [
        action('terminal', failed: true),
        action('terminal', failed: true),
      ]).label,
      contains('2 fallaron'),
    );
  });

  test('only thinking, invalid measurements, zero and hour formatting', () {
    expect(
      turnLineSummary(es, [], duration: const Duration(seconds: 8)).label,
      'Pensó 0:08',
    );
    expect(turnLineSummary(en, []).label, 'Thought');
    for (final invalid in [
      null,
      const Duration(seconds: -1),
      const Duration(days: 1),
    ]) {
      expect(
        turnLineSummary(es, [action('terminal')], duration: invalid).label,
        'Trabajó · Ejecutó 1 comando',
      );
    }
    expect(turnLineDuration(Duration.zero), isNull);
    expect(turnLineDuration(const Duration(milliseconds: 999)), isNull);
    expect(turnLineDuration(const Duration(seconds: 1)), '0:01');
    expect(
      turnLineDuration(const Duration(hours: 2, minutes: 3, seconds: 4)),
      '2:03:04',
    );
  });

  test('plural forms and action coverage across all nine locales', () {
    for (final lang in ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh']) {
      final s = lookupStrings(Locale(lang));
      for (final tool in [
        'read_file',
        'terminal',
        'patch',
        'web_search',
        'web_fetch',
        'search_files',
        'delegate_task',
        'unknown_tool',
      ]) {
        final one = turnLineSummary(s, [action(tool)]).label;
        final many = turnLineSummary(s, [action(tool), action(tool)]).label;
        expect(one, isNot(many), reason: '$lang / $tool');
        expect(many, contains('2'), reason: '$lang / $tool');
        expect(many, isNot(contains('{')), reason: '$lang / $tool');
      }
      expect(s.turnLineAgents(1), contains('1'));
      expect(s.turnLineAgents(2), contains('2'));
      expect(s.turnLineFailed(2), contains('2'));
    }
  });

  test('four concrete repository trace examples', () {
    // turn_one_line_test: four reasoning/tool cycles, ten terminal calls.
    expect(
      turnLineSummary(
        es,
        List.generate(10, (_) => action('terminal')),
        duration: const Duration(seconds: 95),
      ).label,
      'Trabajó 1:35 · Ejecutó 10 comandos',
    );
    // chat_screen_test: reopened trace, date (0.7s), failed config read (12s).
    expect(
      turnLineSummary(es, [
        (
          tool: 'terminal',
          target: null,
          failed: false,
          duration: const Duration(milliseconds: 700),
        ),
        action('read_file', failed: true, seconds: 12, target: 'config.yaml'),
      ]).label,
      'Trabajó · Leyó 1 archivo · Ejecutó 1 comando · 1 falló',
    );
    // subagent_transcript_projection_test: one call dispatches three children.
    // The step trace does not carry that roster: do not claim one agent.
    expect(
      turnLineSummary(es, [action('delegate_task')]).label,
      'Trabajó · Delegó 1 tarea',
    );
    // trace_step_cards_mode_test: a measured eight-second reasoning segment.
    expect(
      turnLineSummary(es, [], duration: const Duration(seconds: 8)).label,
      'Pensó 0:08',
    );
  });

  test('safe targets use the existing projection, never raw arguments', () {
    expect(
      activityToolDetail('terminal', {
        'command':
            'API_KEY=sk-private git status --token=ghp_private /private/account',
      }),
      isNull,
    );
    expect(
      activityToolDetail('read_file', {'path': '/private/customer/deploy.sh'}),
      'deploy.sh',
    );
    expect(
      activityToolDetail('web_fetch', {
        'url': 'https://user:pass@example.com/private?token=secret',
      }),
      'example.com',
    );
    expect(
      activityToolDetail('web_search', {'query': 'Bearer sk-private'}),
      isNull,
    );
    expect(
      activityToolDetail('search_files', {'pattern': 'workers_dev'}),
      isNull,
    );
    final summary = turnLineSummary(es, [
      action('terminal'),
      action('read_file', target: 'config.yaml'),
    ]);
    expect(summary.semanticsLabel, isNot(contains('private')));
    expect(summary.semanticsLabel, isNot(contains('status')));
  });
}
