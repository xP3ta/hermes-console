// A FINISHED subagent opened from its chat showed an empty page («Esta
// conversación todavía no tiene mensajes.»): the row rebuilt from the
// parent transcript carries identity and outcome only. Its page now reads
// what it did from the child's stored conversation, else from the parent's
// record of the task, else says plainly that nothing was kept.
// Message shapes follow a real Hermes 0.22 session (field names only).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/screens/subagent_detail_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart'
    show ProfileTranscriptAccessRequired;
import 'package:hermes_android/core/services/historical_delegation_rows.dart';
import 'package:hermes_android/core/services/subagent_activity_reducer.dart';
import 'package:hermes_android/core/services/subagent_finished_record.dart';
import 'package:hermes_android/core/services/subagent_transcript_projection.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/inter_font.dart';

const _delegationId = 'deleg_f1582108';
const _subagentId = 'sa-0-c10ed865';
const _childId = '20261108_124831_a461e8';
const _goal =
    'Revisa el rollback del relay: comprueba que el despliegue anterior se '
    'restaura sin perder la cola.';
const _parentResult = 'Rollback verificado: la cola se conserva.';

final _scope = SubagentActivityScope(
  connectionId: 'conn',
  profile: 'default',
  parentSessionId: '20261108_114231_39351b',
  runtimeSessionId: 'runtime-1',
  turnEpoch: 3,
);

Map<String, dynamic> _askUser() => {
  'message_id': 'm-1',
  'role': 'user',
  'content': 'Delega la revisión.',
};

Map<String, dynamic> _delegateCall() => {
  'message_id': 'm-2',
  'role': 'assistant',
  'content': '',
  'tool_calls': [
    {
      'id': 'call-deleg',
      'function': {'name': 'delegate_task', 'arguments': '{}'},
    },
  ],
};

Map<String, dynamic> _dispatch() => {
  'message_id': 'm-3',
  'role': 'tool',
  'tool_call_id': 'call-deleg',
  'tool_name': 'delegate_task',
  'content': jsonEncode({
    'status': 'dispatched',
    'mode': 'background',
    'count': 1,
    'delegation_id': _delegationId,
    'goals': [_goal],
    'subagent_ids': [_subagentId],
    'live_transcripts': ['/private/task-0.log'],
    'live_transcripts_hint': 'x',
    'control_hint': 'x',
    'note': 'x',
  }),
};

Map<String, dynamic> _completion() => {
  'message_id': 'm-4',
  'role': 'user',
  'timestamp': 1794142164.0,
  'content':
      '[ASYNC DELEGATION BATCH COMPLETE — $_delegationId]\n'
      'A background fan-out unit you dispatched earlier has finished.\n\n'
      'Role: leaf   Model: claude-opus-5-5   Total duration: 1252.28s\n\n'
      '--- ✓ TASK 1/1: $_goal  (status=completed, api_calls=51, 1252.28s) ---\n'
      '$_parentResult\n'
      'Full live transcript (complete tool/assistant trace): /private/task-0.log\n',
  'display_kind': 'async_delegation_complete',
  'display_metadata': jsonEncode({
    'delegation_id': _delegationId,
    'task_count': 1,
    'completed_count': 1,
    'failed_count': 0,
    'duration_seconds': 1252.28,
  }),
};

/// The parent transcript, oldest first.
List<Map<String, dynamic>> _parent() => [
  _askUser(),
  _delegateCall(),
  _dispatch(),
  _completion(),
];

/// The child's stored conversation: its goal, two steps (one failed), the
/// prose between them and its answer.
List<Map<String, dynamic>> _childMessages({String goal = _goal}) => [
  {'role': 'user', 'content': goal},
  {
    'role': 'assistant',
    'content': '',
    'reasoning': 'private thought',
    'tool_calls': [
      {
        'id': 'c1',
        'function': {
          'name': 'read_file',
          'arguments': jsonEncode({'path': '/srv/relay/rollback.md'}),
        },
      },
    ],
  },
  {
    'role': 'tool',
    'tool_call_id': 'c1',
    'tool_name': 'read_file',
    'content': jsonEncode({'content': 'secret file body'}),
  },
  {
    'role': 'assistant',
    'content': 'Leo el plan y pruebo el rollback.',
    'tool_calls': [
      {
        'id': 'c2',
        'function': {
          'name': 'terminal',
          'arguments': jsonEncode({'command': 'export TOKEN=abc; ./rollback'}),
        },
      },
    ],
  },
  {
    'role': 'tool',
    'tool_call_id': 'c2',
    'tool_name': 'terminal',
    'content': jsonEncode({'output': 'boom', 'exit_code': 1}),
  },
  {'role': 'assistant', 'content': 'Hecho: **rollback probado**.'},
];

/// The row the chat rebuilds from [_parent] (the screenshot's case).
SubagentActivity _projectedRow() {
  final projection = projectSubagentsFromTranscript(
    messagesNewestFirst: _parent().reversed.toList(),
    scope: _scope,
    includeEarlierTurns: true,
  );
  return projection.state!.activities.single;
}

final class _Fakes {
  _Fakes({
    this.loaded,
    this.whole = const [],
    this.resolved = const {},
    this.child,
    this.childError,
  });

  final HistoricalDelegation? loaded;
  final List<Map<String, dynamic>> whole;
  final Map<int, String> resolved;
  final List<Map<String, dynamic>>? child;
  final Object? childError;
  int wholeReads = 0;
  final List<int> pageOffsets = [];
  int childReads = 0;
  int searches = 0;
  final List<String> childIdsRead = [];

  Future<SubagentFinishedRecord> load(SubagentActivity activity) =>
      loadSubagentFinishedRecord(
        activity: activity,
        loadedDelegation: (_) => loaded,
        parentTranscriptPage: (offset, limit) async {
          wholeReads++;
          pageOffsets.add(offset);
          // `order=latest`: offset counts back from the newest row.
          final end = whole.length - offset;
          final start = end - limit < 0 ? 0 : end - limit;
          final rows = end <= 0 ? <Map<String, dynamic>>[] : whole.sublist(start, end);
          return ParentTranscriptPage(
            rows,
            nextOffset: start > 0 ? offset + rows.length : null,
          );
        },
        resolveChildSessions: (delegation) async {
          searches++;
          expect(delegation.tasks, hasLength(1));
          return resolved;
        },
        loadChild: (id) async {
          childReads++;
          childIdsRead.add(id);
          if (childError case final error?) throw error;
          return child ?? const [];
        },
      );
}

void main() {
  setUpAll(loadInterFont);

  test('root cause: the row rebuilt from the parent transcript is '
      'completed with no goal, no result and no child session', () {
    final row = _projectedRow();
    expect(row.phase, SubagentActivityPhase.completed);
    expect(row.subagentId, _subagentId);
    expect(row.delegationId, _delegationId);
    expect(row.goalPreview, isNull);
    expect(row.resultPreview, isNull);
    expect(row.childSessionId, isNull);
    expect(row.canResumeChildTranscript, isFalse);
  });

  group('record source', () {
    late HistoricalDelegation batch;
    setUp(() {
      batch = historicalDelegationFromMessages(_parent(), _delegationId)!;
    });

    test('child found with messages: its goal, steps and answer', () async {
      final fakes = _Fakes(
        loaded: batch,
        resolved: {0: _childId},
        child: _childMessages(),
      );
      final record = await fakes.load(_projectedRow());
      expect(record.source, SubagentRecordSource.child);
      expect(fakes.childIdsRead, [_childId]);
      expect(fakes.wholeReads, 0);
      expect(record.goal, _goal);
      expect(record.result, 'Hecho: **rollback probado**.');
      final tools = [for (final block in record.blocks) ?block.tool];
      expect(tools.map((t) => t.name), ['read_file', 'terminal']);
      expect(tools.map((t) => t.failed), [false, true]);
      // A path is a harmless target; a command never leaves the record.
      expect(tools.first.preview, '/srv/relay/rollback.md');
      expect(tools.last.preview, isNull);
      final prose = record.blocks
          .where((b) => b.tool == null)
          .map((b) => b.text)
          .join();
      expect(prose, 'Leo el plan y pruebo el rollback.');
      expect(
        jsonEncode(record.blocks.map((b) => b.text).toList()),
        isNot(contains('TOKEN')),
      );
      expect(record.apiCalls, 51);
      expect(record.model, 'claude-opus-5-5');
      expect(record.durationSeconds, 1252.28);
    });

    test('child found but empty: the parent\'s record of the task', () async {
      final fakes = _Fakes(loaded: batch, resolved: {0: _childId}, child: []);
      final record = await fakes.load(_projectedRow());
      expect(fakes.childReads, 1);
      expect(record.source, SubagentRecordSource.parent);
      expect(record.goal, _goal);
      expect(record.result, _parentResult);
      expect(record.blocks, isEmpty);
      expect(record.apiCalls, 51);
    });

    test(
      'child under another profile (no access): the parent\'s record',
      () async {
        final fakes = _Fakes(
          loaded: batch,
          resolved: {0: _childId},
          childError: const ProfileTranscriptAccessRequired(),
        );
        final record = await fakes.load(_projectedRow());
        expect(fakes.childReads, 1);
        expect(record.source, SubagentRecordSource.parent);
        expect(record.result, _parentResult);
      },
    );

    test('only the parent\'s tool result: no child id can be found', () async {
      final fakes = _Fakes(loaded: batch);
      final record = await fakes.load(_projectedRow());
      expect(fakes.searches, 1);
      expect(fakes.childReads, 0);
      expect(record.source, SubagentRecordSource.parent);
      expect(record.goal, _goal);
      expect(record.result, _parentResult);
    });

    test('a known child id is read directly, no search', () async {
      final row = _projectedRow();
      final withChild = SubagentActivity(
        key: row.key,
        source: SubagentActivitySource.native,
        phase: row.phase,
        subagentId: row.subagentId,
        delegationId: row.delegationId,
        childSessionId: _childId,
        details: row.details,
      );
      final fakes = _Fakes(loaded: batch, child: _childMessages());
      final record = await fakes.load(withChild);
      expect(fakes.searches, 0);
      expect(record.source, SubagentRecordSource.child);
    });

    test('a sibling found by the goal search is not trusted', () async {
      final fakes = _Fakes(
        loaded: batch,
        resolved: {0: 'sibling'},
        child: _childMessages(goal: 'Otra tarea distinta del relay.'),
      );
      final record = await fakes.load(_projectedRow());
      expect(record.source, SubagentRecordSource.parent);
      expect(record.result, _parentResult);
    });

    test('the batch outside the loaded window is read from the whole '
        'parent transcript, once', () async {
      final fakes = _Fakes(loaded: null, whole: _parent());
      final record = await fakes.load(_projectedRow());
      expect(fakes.wholeReads, 1);
      expect(record.source, SubagentRecordSource.parent);
      expect(record.result, _parentResult);
    });

    test('a long parent is searched page by page, back to the batch only',
        () async {
      Map<String, dynamic> filler(int i) => {
        'id': 10000 + i,
        'role': i.isEven ? 'user' : 'assistant',
        'content': 'relleno $i',
      };
      final near = _Fakes(
        loaded: null,
        whole: [
          for (var i = 0; i < 300; i++) filler(i),
          ..._parent(),
          for (var i = 300; i < 750; i++) filler(i),
        ],
      );
      final found = await near.load(_projectedRow());
      expect(found.source, SubagentRecordSource.parent);
      expect(found.result, _parentResult);
      expect(near.wholeReads, lessThanOrEqualTo(4));
      expect(near.pageOffsets.first, 0);

      final far = _Fakes(
        loaded: null,
        whole: [
          ..._parent(),
          for (var i = 0; i < 5000; i++) filler(i),
        ],
      );
      final record = await far.load(_projectedRow());
      expect(far.wholeReads, ParentDelegationSearch.maxPages);
      expect(record.source, isNot(SubagentRecordSource.parent));
    });

    test('whole parent transcript in the REST shape (no display_kind, no '
        'display_metadata): the batch is found by its sentinel', () async {
      final rest = [
        for (final message in _parent())
          {
            for (final entry in message.entries)
              if (entry.key != 'display_kind' &&
                  entry.key != 'display_metadata')
                entry.key: entry.value,
          },
      ];
      final fakes = _Fakes(loaded: null, whole: rest);
      final record = await fakes.load(_projectedRow());
      expect(fakes.wholeReads, 1);
      expect(record.source, SubagentRecordSource.parent);
      expect(record.goal, _goal);
      expect(record.result, _parentResult);
      expect(record.apiCalls, 51);
    });

    test('nothing anywhere: none, never a throw', () async {
      final fakes = _Fakes(loaded: null, whole: const []);
      final record = await fakes.load(_projectedRow());
      expect(record.source, SubagentRecordSource.none);
      expect(record.isEmpty, isTrue);
    });

    test('live subagent.complete: output_tail tools and summary, no '
        'output previews', () async {
      final event = SubagentActivityEvent.tryParseNative(
        type: 'subagent.complete',
        scope: _scope,
        payload: {
          'subagent_id': 'sa-0-live',
          'goal': 'Tarea en vivo',
          'task_index': 0,
          'task_count': 1,
          'status': 'completed',
          'summary': 'Todo correcto.',
          'output_tail': [
            {'tool': 'read_file', 'preview': 'secret body', 'is_error': false},
            {'tool': 'terminal', 'preview': 'TOKEN=abc', 'is_error': true},
          ],
        },
      )!;
      expect(event.details.outputTailTools, const [
        SubagentTailTool(name: 'read_file'),
        SubagentTailTool(name: 'terminal', failed: true),
      ]);
      final row = SubagentActivityReducer.reduce(
        SubagentActivityState.empty(_scope),
        event,
      ).activities.single;
      final fakes = _Fakes(loaded: null, whole: const []);
      final record = await fakes.load(row);
      expect(record.source, SubagentRecordSource.activity);
      expect(record.goal, 'Tarea en vivo');
      expect(record.result, 'Todo correcto.');
      final tools = record.blocks.map((b) => b.tool!).toList();
      expect(tools.map((t) => (t.name, t.failed)), [
        ('read_file', false),
        ('terminal', true),
      ]);
      expect(tools.every((t) => t.preview == null), isTrue);
    });

    test('a URL target keeps no credentials or query', () {
      final record = subagentRecordFromChildMessages([
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'u',
              'function': {
                'name': 'web_fetch',
                'arguments': jsonEncode({
                  'url': 'https://user:pw@example.com/a/b?token=x#frag',
                }),
              },
            },
          ],
        },
      ])!;
      expect(record.blocks.single.tool!.preview, 'https://example.com/a/b');
    });
  });

  group('goal match (a search may land on a sibling)', () {
    test('the same goal, or a clipped prefix of at least 24 characters', () {
      expect(subagentGoalsMatch('Revisa', 'Revisa'), isTrue);
      expect(subagentGoalsMatch(_goal, _goal.substring(0, 30)), isTrue);
      expect(subagentGoalsMatch(_goal.substring(0, 30), _goal), isTrue);
    });

    test('a short shared prefix is not the same task', () {
      expect(
        subagentGoalsMatch('Revisa el rollback del relay', 'Revisa'),
        isFalse,
      );
      expect(subagentGoalsMatch(_goal, _goal.substring(0, 12)), isFalse);
    });

    test('without one of the goals only an id that came with the activity '
        'is trusted', () {
      expect(subagentGoalsMatch(_goal, ''), isFalse);
      expect(subagentGoalsMatch('', _goal), isFalse);
      expect(subagentGoalsMatch(_goal, '', idFromActivity: true), isTrue);
      expect(subagentGoalsMatch('', '  ', idFromActivity: true), isTrue);
    });

    test('a child found by search for a task without a goal is not shown',
        () async {
      final row = _projectedRow();
      final batch = historicalDelegationFromMessages(_parent(), _delegationId)!;
      final withoutGoal = HistoricalDelegation(
        delegationId: batch.delegationId,
        subagentIds: batch.subagentIds,
        tasks: [
          for (final task in batch.tasks)
            HistoricalDelegationTask(
              index: task.index,
              goal: '',
              status: task.status,
              result: task.result,
            ),
        ],
      );
      final fakes = _Fakes(
        loaded: withoutGoal,
        resolved: {0: 'sibling'},
        child: _childMessages(goal: 'Otra tarea distinta del relay.'),
      );
      final record = await fakes.load(row);
      expect(fakes.childReads, 1);
      expect(record.source, isNot(SubagentRecordSource.child));
    });
  });

  group('public tool target (the finished view\'s filter)', () {
    test('a path or a URL without credentials, query or fragment', () {
      expect(
        subagentPublicTarget('/srv/relay/rollback.md'),
        '/srv/relay/rollback.md',
      );
      expect(subagentPublicTarget('notas.txt\nsegunda línea'), 'notas.txt');
      expect(subagentPublicTarget('./lib/main.dart'), './lib/main.dart');
      expect(
        subagentPublicTarget('https://user:pw@example.com/a/b?token=x#f'),
        'https://example.com/a/b',
      );
    });

    test('a command line or anything else is dropped', () {
      for (final preview in [
        r'for i in 1 2 3; do echo $i; done',
        'git push https://ghp_SECRETO@github.com/x/y.git',
        'curl -H "Authorization: Bearer SECRETO" https://api.x.dev',
        'export OPENAI_API_KEY=sk-SECRETO',
        'ls',
        'sk-SECRETOabcdefghijklmnop',
        '/usr/bin/env TOKEN=SECRETO run',
        '',
        null,
      ]) {
        expect(subagentPublicTarget(preview), isNull, reason: '$preview');
      }
    });

    test('control characters out, long targets clipped', () {
      final long = '/srv/${'a' * 400}.md';
      final clipped = subagentPublicTarget(long)!;
      expect(
        clipped.runes.length,
        lessThanOrEqualTo(SubagentFinishedRecord.maxTargetCharacters + 1),
      );
      expect(clipped, endsWith('…'));
    });
  });

  group('live tool target (the owner\'s live view)', () {
    test('a command line in full, on one line', () {
      const loop = r'for i in 1 2 3; do echo paso $i; sleep 5; done';
      expect(subagentLiveTarget(loop), loop);
      expect(subagentLiveTarget('\n  \n  echo   hola  \nrm -rf /'), 'echo hola');
      expect(
        subagentLiveTarget('/srv/relay/rollback.md'),
        '/srv/relay/rollback.md',
      );
      expect(subagentLiveTarget('make DEBUG=1 build'), 'make DEBUG=1 build');
      expect(subagentLiveTarget(''), isNull);
      expect(subagentLiveTarget('  \n '), isNull);
      expect(subagentLiveTarget(null), isNull);
    });

    test('every secret masked, the rest of the command kept', () {
      final line = subagentLiveTarget(
        'curl --token abc123secret -H "Authorization: Bearer xyz" '
        'https://user:pass@api.example.com/v1?token=t0ps3cret&page=2 '
        'API_KEY=sk-live-abcdef123456',
      )!;
      for (final secret in [
        'abc123secret',
        'xyz',
        'user:pass',
        'pass@',
        't0ps3cret',
        'sk-live',
        'abcdef123456',
      ]) {
        expect(line, isNot(contains(secret)), reason: secret);
      }
      expect(line, startsWith('curl --token •••'));
      expect(line, contains('Authorization: Bearer •••'));
      expect(line, contains('api.example.com/v1?token=•••&page=2'));
      expect(line, contains('API_KEY=•••'));
    });

    test('common secret shapes never show', () {
      const cases = {
        'mysql --password hunter2 -u root': 'hunter2',
        'git push --token=ghp_privatevalue123': 'privatevalue',
        'deploy --secret "s3 cr3t" --api-key=k3y': 'cr3t',
        'export GITHUB_TOKEN=gh0ken': 'gh0ken',
        'aws s3 ls AKIAABCDEFGH1234': 'AKIAABCDEFGH1234',
        'curl -H "x-key: eyJhbGciOiJIUzI1NiJ9.payload.sig" https://x.io':
            'eyJhbGci',
        'echo 0123456789abcdef0123456789abcdef01234567': '0123456789abcdef',
        'echo aGVsbG8gd29ybGQgdGhpcyBpcyBhIHNlY3JldCBrZXkgMTIzNDU2Nzg5MA==':
            'aGVsbG8',
        '-----BEGIN RSA PRIVATE KEY----- MIIEowIBAAKCAQEA': 'MIIE',
        'curl "https://x.io/a?X-Amz-Signature=abc9&v=1"': 'abc9',
        'psql postgres://u:p4ss@db.local/app': 'p4ss',
        'curl -H "Cookie: session=c00kie"': 'c00kie',
        'mail admin@example.com': 'admin@example.com',
        'ping 192.168.1.20': '192.168.1.20',
        // Already cut upstream, in the middle of the secret.
        'curl -H "Authorization: Bearer abcdef…': 'abcdef',
        'login --password hunt…': 'hunt',
      };
      for (final MapEntry(key: command, value: secret) in cases.entries) {
        final line = subagentLiveTarget(command);
        expect(line, isNotNull, reason: command);
        expect(line, isNot(contains(secret)), reason: command);
      }
    });

    test('control characters out, long lines capped with an ellipsis', () {
      expect(subagentLiveTarget('echo\ta\u202eb'), 'echo a b');
      final long = subagentLiveTarget('echo ${'palabra ' * 60}')!;
      expect(long.runes.length, lessThanOrEqualTo(kSubagentLiveTargetMaxChars));
      expect(long, endsWith('…'));
      expect(long, startsWith('echo palabra palabra'));
    });
  });

  group('detail page of a finished subagent', () {
    late ValueNotifier<List<SubagentActivity>> roster;

    Future<void> pumpDetail(
      WidgetTester tester, {
      required SubagentActivity activity,
      SubagentFinishedRecordLoader? loader,
      bool hideGoal = false,
    }) async {
      roster = ValueNotifier([activity]);
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
            parentTitle: 'Chat',
            openLiveWatch: (_) => null,
            routeObserver: RouteObserver<PageRoute<dynamic>>(),
            clock: () => DateTime.utc(2026, 11, 8, 12),
            hideGoal: hideGoal,
            loadFinishedRecord: loader,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    late HistoricalDelegation batch;
    setUp(() {
      batch = historicalDelegationFromMessages(_parent(), _delegationId)!;
    });

    testWidgets('without a record loader it was the empty page', (
      tester,
    ) async {
      await pumpDetail(tester, activity: _projectedRow());
      expect(
        find.text('Esta conversación todavía no tiene mensajes.'),
        findsOneWidget,
      );
    });

    testWidgets('child conversation: Encargo, Qué ha hecho, Resultado', (
      tester,
    ) async {
      var calls = 0;
      final fakes = _Fakes(
        loaded: batch,
        resolved: {0: _childId},
        child: _childMessages(),
      );
      await pumpDetail(
        tester,
        activity: _projectedRow(),
        loader: (activity) {
          calls++;
          return fakes.load(activity);
        },
      );
      expect(find.text('ENCARGO'), findsOneWidget);
      expect(find.text(_goal), findsOneWidget);
      expect(find.text('QUÉ HA HECHO'), findsOneWidget);
      expect(find.text('read_file · Terminado'), findsOneWidget);
      expect(find.text('terminal · Falló'), findsOneWidget);
      expect(find.text('/srv/relay/rollback.md'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('RESULTADO'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('RESULTADO'), findsOneWidget);
      expect(
        find.textContaining('rollback probado', findRichText: true),
        findsWidgets,
      );
      final meta = tester.widget<Text>(
        find.byKey(const ValueKey('subagent-record-meta')),
      );
      expect(meta.data, contains('Llamadas a la API: 51'));
      expect(meta.data, contains('Modelo: claude-opus-5-5'));
      expect(find.byKey(const ValueKey('subagent-record-note')), findsNothing);
      expect(
        find.text('Esta conversación todavía no tiene mensajes.'),
        findsNothing,
      );

      // Roster ticks rebuild the page but never read again.
      roster.value = [_projectedRow()];
      await tester.pumpAndSettle();
      expect(calls, 1);
    });

    testWidgets('parent record only: its result and where it comes from', (
      tester,
    ) async {
      final fakes = _Fakes(loaded: batch);
      await pumpDetail(tester, activity: _projectedRow(), loader: fakes.load);
      expect(find.text('ENCARGO'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subagent-record-note')),
        findsOneWidget,
      );
      expect(find.text('QUÉ HA HECHO'), findsNothing);
      expect(find.text('RESULTADO'), findsOneWidget);
      expect(
        find.textContaining(_parentResult, findRichText: true),
        findsWidgets,
      );
    });

    testWidgets('nothing kept: an honest line, not an empty conversation', (
      tester,
    ) async {
      final fakes = _Fakes(loaded: null, whole: const []);
      await pumpDetail(tester, activity: _projectedRow(), loader: fakes.load);
      expect(
        find.text(
          'Hermes no guardó lo que hizo este subagente: no hay conversación '
          'ni resultado que mostrar.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Esta conversación todavía no tiene mensajes.'),
        findsNothing,
      );
    });

    testWidgets('a non-owner opener never reads the record', (tester) async {
      var calls = 0;
      await pumpDetail(
        tester,
        activity: _projectedRow(),
        hideGoal: true,
        loader: (activity) async {
          calls++;
          return SubagentFinishedRecord.empty;
        },
      );
      expect(calls, 0);
    });
  });
}
