// A reloaded chat keeps only a text card for its finished subagents; their
// rows are rebuilt from the dispatch and completion messages in the parent
// transcript (real shapes captured from a Hermes 0.22 session).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/screens/subagent_detail_screen.dart';
import 'package:hermes_android/core/services/historical_delegation_rows.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/subagent_activity_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/inter_font.dart';

const _delegationId = 'deleg_fe60aadc';

final _scope = SubagentActivityScope(
  connectionId: 'c',
  parentSessionId: 'p',
  runtimeSessionId: 'r',
  turnEpoch: 1,
);

Map<String, dynamic> _dispatch() => {
  'role': 'tool',
  'tool_name': 'delegate_task',
  'content': jsonEncode({
    'status': 'dispatched',
    'mode': 'background',
    'count': 2,
    'delegation_id': _delegationId,
    'goals': [
      'Prueba de delegación A. Analiza esta afirmación: «Si un servidor responde a ping, su aplicación web funciona».',
      'Prueba de delegación B. Explica la diferencia entre una copia de seguridad y alta disponibilidad.',
    ],
    'subagent_ids': ['sa-0-fd1b1751', 'sa-1-4b70c0cc'],
    'live_transcripts': ['/private/task-0.log', '/private/task-1.log'],
  }),
};

const _completionText =
    '[ASYNC DELEGATION BATCH COMPLETE — $_delegationId]\n'
    'A background fan-out unit you dispatched earlier — 2 subagent(s) — has '
    'finished; its consolidated results are below.\n\n'
    'Dispatched: 2026-11-07 21:13:07 (6s ago)\n'
    'Role: leaf   Model: claude-opus-5-5   Total duration: 6.93s\n\n'
    '--- ✓ TASK 1/2: Prueba de delegación A. Analiza esta afirmación: «Si un servidor responde a ping, su aplicación web funciona».  (status=completed, api_calls=1, 4.62s) ---\n'
    '**Veredicto:** la afirmación es falsa.\n'
    '**Contraejemplo:** Nginx caído.\n'
    'Full live transcript (complete tool/assistant trace): /private/task-0.log\n\n'
    '--- ✗ TASK 2/2: Prueba de delegación B. Explica la diferencia entre una copia de seguridad y alta disponibilidad.  (status=failed, api_calls=2, 6.1s) ---\n'
    'Billing or credits exhausted.\n'
    'Full live transcript (complete tool/assistant trace): /private/task-1.log\n';

Map<String, dynamic> _completion() => {
  'role': 'user',
  'content': _completionText,
  'timestamp': 1794085994.0,
  'display_kind': 'async_delegation_complete',
  'display_metadata': jsonEncode({
    'delegation_id': _delegationId,
    'task_count': 2,
    'completed_count': 1,
    'failed_count': 1,
    'duration_seconds': 6.93,
  }),
};

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('es'),
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: const [
    Strings.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(body: SafeArea(child: child)),
);

void main() {
  setUpAll(loadInterFont);

  group('parse', () {
    test('rebuilds both tasks with goal, status, model, duration and result', () {
      final batch = historicalDelegationFromMessages([
        _completion(),
        _dispatch(),
      ], _delegationId)!;
      expect(batch.model, 'claude-opus-5-5');
      expect(batch.totalDurationSeconds, 6.93);
      expect(batch.subagentIds, ['sa-0-fd1b1751', 'sa-1-4b70c0cc']);
      expect(batch.tasks, hasLength(2));
      expect(batch.tasks[0].status, 'completed');
      expect(batch.tasks[0].apiCalls, 1);
      expect(batch.tasks[0].durationSeconds, 4.62);
      expect(batch.tasks[0].goal, startsWith('Prueba de delegación A.'));
      expect(batch.tasks[0].result, contains('Contraejemplo'));
      // The pointer to the server-side trace is not part of the result.
      expect(batch.tasks[0].result, isNot(contains('/private')));
      expect(batch.tasks[1].status, 'failed');
      expect(batch.tasks[1].result, 'Billing or credits exhausted.');
    });

    test('an absurd timestamp reads as unknown, never throws', () {
      for (final ts in [1e300, 9e15]) {
        final batch = historicalDelegationFromMessages([
          {..._completion(), 'timestamp': ts},
          _dispatch(),
        ], _delegationId)!;
        expect(batch.completedAt, isNull, reason: '$ts');
      }
    });

    test(
      'rows are terminal, carry the dispatched ids and clip nothing it should keep',
      () {
        final batch = historicalDelegationFromMessages([
          _completion(),
          _dispatch(),
        ], _delegationId)!;
        final rows = historicalDelegationRows(
          batch,
          _scope,
          childSessionIds: {0: 'child-session-a'},
        );
        expect(rows.map((r) => r.phase), [
          SubagentActivityPhase.completed,
          SubagentActivityPhase.failed,
        ]);
        expect(rows.every((r) => r.isTerminal), isTrue);
        expect(rows[0].subagentId, 'sa-0-fd1b1751');
        expect(rows[0].childSessionId, 'child-session-a');
        expect(rows[1].childSessionId, isNull);
        expect(rows[0].details.model, 'claude-opus-5-5');
        expect(rows[0].details.durationSeconds, 4.62);
        expect(rows[0].details.usage?.apiCalls, 1);
        expect(rows[0].resultPreview, contains('Veredicto'));
        expect(rows[1].resultPreview, 'Billing or credits exhausted.');
        expect(rows.map((r) => r.key.stableId).toSet(), hasLength(2));
      },
    );

    test('no completion message, or one that cannot be read, yields nothing', () {
      expect(
        historicalDelegationFromMessages([_dispatch()], _delegationId),
        isNull,
      );
      final broken = {..._completion(), 'content': '[ASYNC DELEGATION BATCH COMPLETE — $_delegationId]\nnothing parseable'};
      expect(
        historicalDelegationFromMessages([broken, _dispatch()], _delegationId),
        isNull,
      );
      expect(
        historicalDelegationFromMessages([_completion()], 'deleg_00000000'),
        isNull,
      );
    });

    test('search words keep letters and digits only', () {
      expect(
        searchWordsOf('Prueba de delegación A. Analiza «esta» afirmación: "x"'),
        'Prueba de delegación Analiza esta afirmación',
      );
      expect(searchWordsOf('«» … --'), isEmpty);
    });
  });

  group('card and sheet', () {
    testWidgets('the completion card is a tappable pill only with onTap', (
      tester,
    ) async {
      var taps = 0;
      final data = SubagentCompletionCardData(
        completionKey: 'k',
        delegationId: _delegationId,
        taskCount: 2,
        completedCount: 2,
        failedCount: 0,
        durationSeconds: 6,
      );
      await tester.pumpWidget(_host(SubagentCompletionCard(data: data)));
      expect(find.byKey(const ValueKey('subagent-completion-open')), findsNothing);
      await tester.pumpWidget(
        _host(SubagentCompletionCard(data: data, onTap: () => taps++)),
      );
      await tester.tap(find.byKey(const ValueKey('subagent-completion-open')));
      expect(taps, 1);
      await tester.pumpWidget(
        _host(SubagentCompletionCard(data: data, onTap: () => taps++, busy: true)),
      );
      await tester.tap(find.byKey(const ValueKey('subagent-completion-open')));
      expect(taps, 1);
    });

    testWidgets('the rows open the list and a detail with the stored data', (
      tester,
    ) async {
      final batch = historicalDelegationFromMessages([
        _completion(),
        _dispatch(),
      ], _delegationId)!;
      final rows = historicalDelegationRows(batch, _scope);
      final controller = SubagentActivityController();
      await tester.pumpWidget(
        _host(
          SubagentActivityCard(
            hidden: true,
            controller: controller,
            activities: rows,
            canSteer: (_) => false,
            canInterrupt: (_) => false,
            canTail: (_) => false,
          ),
        ),
      );
      controller.open();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('subagent-panel')), findsOneWidget);
      expect(
        find.byKey(ValueKey('subagent-row-${rows[0].key.stableId}')),
        findsOneWidget,
      );
      expect(find.textContaining('claude-opus-5-5'), findsWidgets);
      await tester.tap(
        find.byKey(ValueKey('subagent-row-${rows[0].key.stableId}')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SubagentDetailScreen), findsOneWidget);
      // The detail is a lazy list: scroll to the stored result.
      await tester.scrollUntilVisible(
        find.textContaining('Contraejemplo', findRichText: true),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.textContaining('Contraejemplo', findRichText: true),
        findsWidgets,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
