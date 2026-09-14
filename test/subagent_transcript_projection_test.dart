import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:hermes_android/core/services/subagent_activity_reducer.dart';
import 'package:hermes_android/core/services/subagent_transcript_projection.dart';

void main() {
  final scope = SubagentActivityScope(
    connectionId: 'conn-1',
    profile: 'default',
    parentSessionId: 'stored-1',
    runtimeSessionId: 'runtime-2',
    turnEpoch: 7,
  );

  test('rehydrates dispatched delegate_task from the current durable turn', () {
    final messagesNewestFirst = <Map<String, dynamic>>[
      {
        'message_id': 'message-3',
        'role': 'tool',
        'tool_call_id': 'call-1',
        'tool_name': 'delegate_task',
        'content': jsonEncode({
          'status': 'dispatched',
          'delegation_id': 'deleg_deadbeef',
          'subagent_ids': ['sa-0-deadbeef'],
        }),
      },
      {
        'message_id': 'message-2',
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'call-1',
            'function': {'name': 'delegate_task', 'arguments': '{}'},
          },
        ],
      },
      {'message_id': 'message-1', 'role': 'user', 'content': 'Haz la prueba.'},
    ];

    final projection = projectSubagentsFromTranscript(
      messagesNewestFirst: messagesNewestFirst,
      scope: scope,
    );

    expect(projection.turnAnchor, 'canonical:message-1');
    expect(projection.state, isNotNull);
    expect(projection.state!.activities, hasLength(1));
    final activity = projection.state!.activities.single;
    expect(activity.phase, SubagentActivityPhase.unknown);
    expect(activity.delegationId, 'deleg_deadbeef');
    expect(activity.subagentId, 'sa-0-deadbeef');
    expect(activity.legacyToolCallId, 'call-1');
  });

  test('projects one read-only completion card for each durable turn', () {
    final projected = projectHistoricalSubagentCompletions(
      messagesNewestFirst: [
        {
          'message_id': 'new-marker',
          'role': 'user',
          'content': '[ASYNC DELEGATION BATCH COMPLETE — deleg_a1b2c3d4]',
          'display_kind': 'async_delegation_complete',
          'display_metadata': {
            'delegation_id': 'deleg_a1b2c3d4',
            'task_count': 2,
            'completed_count': 2,
            'failed_count': 0,
          },
        },
        {
          'message_id': 'new-result',
          'role': 'tool',
          'tool_call_id': 'call-new',
          'tool_name': 'delegate_task',
          'content': jsonEncode({
            'status': 'dispatched',
            'delegation_id': 'deleg_a1b2c3d4',
            'subagent_ids': ['sa-new-one', 'sa-new-two'],
          }),
        },
        {
          'message_id': 'new-assistant',
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call-new',
              'function': {
                'name': 'delegate_task',
                'arguments': '{"goal":"private-new-goal"}',
              },
            },
          ],
        },
        {'message_id': 'new-user', 'role': 'user', 'content': 'Turno nuevo'},
        {
          'message_id': 'old-marker',
          'role': 'user',
          'content': '[ASYNC DELEGATION BATCH COMPLETE — deleg_deadbeef]',
          'display_kind': 'async_delegation_complete',
          'display_metadata': {
            'delegation_id': 'deleg_deadbeef',
            'task_count': 1,
            'completed_count': 1,
            'failed_count': 0,
          },
        },
        {
          'message_id': 'old-result',
          'role': 'tool',
          'tool_call_id': 'call-old',
          'tool_name': 'delegate_task',
          'content': jsonEncode({
            'status': 'dispatched',
            'delegation_id': 'deleg_deadbeef',
            'subagent_ids': ['sa-old-one'],
          }),
        },
        {
          'message_id': 'old-assistant',
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call-old',
              'function': {
                'name': 'delegate_task',
                'arguments': '{"goal":"private-old-goal"}',
              },
            },
          ],
        },
        {'message_id': 'old-user', 'role': 'user', 'content': 'Turno antiguo'},
      ],
    );

    final cards = projected
        .map(historicalSubagentCompletionOf)
        .whereType<SubagentCompletionCardData>()
        .toList(growable: false);
    expect(cards.map((card) => card.delegationId), [
      'deleg_a1b2c3d4',
      'deleg_deadbeef',
    ]);
    expect(cards.first.subagentIds, ['sa-new-one', 'sa-new-two']);
    expect(cards.last.subagentIds, ['sa-old-one']);
  });

  test('reprojecting a completion marker is idempotent', () {
    final input = <Map<String, dynamic>>[
      {
        'message_id': 'stable-marker',
        'role': 'user',
        'content': '[ASYNC DELEGATION BATCH COMPLETE — deleg_11223344]',
        'display_kind': 'async_delegation_complete',
        'display_metadata': {
          'delegation_id': 'deleg_11223344',
          'task_count': 1,
          'completed_count': 1,
          'failed_count': 0,
          'subagent_ids': ['sa-stable-one'],
        },
      },
    ];

    final first = projectHistoricalSubagentCompletions(
      messagesNewestFirst: input,
    );
    final second = projectHistoricalSubagentCompletions(
      messagesNewestFirst: first,
    );

    expect(second, same(first));
    expect(second.single, same(first.single));
    expect(historicalSubagentCompletionOf(second.single)?.subagentIds, [
      'sa-stable-one',
    ]);
  });

  test('ignores historical delegate_task invocation without a result', () {
    final projection = projectSubagentsFromTranscript(
      messagesNewestFirst: [
        {
          'message_id': 'arguments-only-assistant',
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call-arguments-only',
              'function': {
                'name': 'delegate_task',
                'arguments': '{"goal":"private historical prompt"}',
              },
            },
          ],
        },
        {
          'message_id': 'arguments-only-user',
          'role': 'user',
          'content': 'Haz la prueba.',
        },
      ],
      scope: scope,
    );

    expect(projection.state, isNull);
  });

  test('rehydrates failed delegate_task dispatch as terminal', () {
    final projection = projectSubagentsFromTranscript(
      messagesNewestFirst: [
        {
          'message_id': 'failed-result',
          'role': 'tool',
          'tool_call_id': 'call-failed',
          'tool_name': 'delegate_task',
          'content': jsonEncode({
            'status': 'error',
            'error': 'worker unavailable',
          }),
        },
        {
          'message_id': 'failed-call',
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call-failed',
              'function': {'name': 'delegate_task', 'arguments': '{}'},
            },
          ],
        },
        {
          'message_id': 'failed-user',
          'role': 'user',
          'content': 'Delega la revisión.',
        },
      ],
      scope: scope,
    );

    expect(projection.state?.activities, hasLength(1));
    expect(
      projection.state?.activities.single.phase,
      SubagentActivityPhase.failed,
    );
  });

  test(
    'rehydrates every dispatched child from a multi-subagent delegate_task',
    () {
      final messagesNewestFirst = <Map<String, dynamic>>[
        {
          'message_id': 'message-3',
          'role': 'tool',
          'tool_call_id': 'call-many',
          'tool_name': 'delegate_task',
          'content': jsonEncode({
            'status': 'dispatched',
            'delegation_id': 'deleg_many',
            'subagent_ids': ['sa-alpha', 'sa-beta', 'sa-gamma'],
          }),
        },
        {
          'message_id': 'message-2',
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call-many',
              'function': {'name': 'delegate_task', 'arguments': '{}'},
            },
          ],
        },
        {'message_id': 'message-1', 'role': 'user', 'content': 'Haz tres.'},
      ];

      final projection = projectSubagentsFromTranscript(
        messagesNewestFirst: messagesNewestFirst,
        scope: scope,
      );

      expect(projection.state?.activities, hasLength(3));
      expect(
        projection.state?.activities.map((activity) => activity.subagentId),
        containsAll(['sa-alpha', 'sa-beta', 'sa-gamma']),
      );
      expect(
        projection.state?.activities.map((activity) => activity.phase),
        everyElement(SubagentActivityPhase.unknown),
      );
    },
  );

  test('ignores malformed multi-child ids without crashing recovery', () {
    final messagesNewestFirst = <Map<String, dynamic>>[
      {
        'message_id': 'malformed-result',
        'role': 'tool',
        'tool_call_id': 'call-malformed',
        'tool_name': 'delegate_task',
        'content': jsonEncode({
          'status': 'dispatched',
          'delegation_id': 'deleg_malformed',
          'subagent_ids': ['', 'not valid id', 'x' * 181],
        }),
      },
      {
        'message_id': 'malformed-assistant',
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'call-malformed',
            'function': {'name': 'delegate_task', 'arguments': '{}'},
          },
        ],
      },
      {'message_id': 'malformed-user', 'role': 'user', 'content': 'Haz tres.'},
    ];

    expect(
      () => projectSubagentsFromTranscript(
        messagesNewestFirst: messagesNewestFirst,
        scope: scope,
      ),
      returnsNormally,
    );
  });

  test(
    'legacy batch completion without delegation id closes its only durable batch',
    () {
      final messagesNewestFirst = <Map<String, dynamic>>[
        {
          'message_id': 'legacy-completion',
          'role': 'user',
          'display_kind': 'async_delegation_complete',
          'display_metadata': jsonEncode({
            'task_count': 3,
            'completed_count': 3,
            'failed_count': 0,
          }),
          'content': '[ASYNC DELEGATION BATCH COMPLETE — deleg_12345678]',
        },
        {
          'message_id': 'legacy-result',
          'role': 'tool',
          'tool_call_id': 'call-legacy',
          'tool_name': 'delegate_task',
          'content': jsonEncode({
            'status': 'dispatched',
            'delegation_id': 'deleg_12345678',
            'subagent_ids': [
              'sa-legacy-one',
              'sa-legacy-two',
              'sa-legacy-three',
            ],
          }),
        },
        {
          'message_id': 'legacy-assistant',
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call-legacy',
              'function': {'name': 'delegate_task', 'arguments': '{}'},
            },
          ],
        },
        {'message_id': 'legacy-user', 'role': 'user', 'content': 'Haz tres.'},
      ];

      final projection = projectSubagentsFromTranscript(
        messagesNewestFirst: messagesNewestFirst,
        scope: scope,
      );

      expect(projection.state?.activities, hasLength(3));
      expect(
        projection.state?.activities.map((activity) => activity.phase),
        everyElement(SubagentActivityPhase.completed),
      );
    },
  );

  test('partial batch failure never attributes the failure to every child', () {
    final messagesNewestFirst = <Map<String, dynamic>>[
      {
        'message_id': 'partial-completion',
        'role': 'user',
        'display_kind': 'async_delegation_complete',
        'display_metadata': jsonEncode({
          'delegation_id': 'deleg_partial',
          'task_count': 3,
          'completed_count': 2,
          'failed_count': 1,
        }),
        'content': '[ASYNC DELEGATION BATCH COMPLETE — deleg_partial]',
      },
      {
        'message_id': 'partial-result',
        'role': 'tool',
        'tool_call_id': 'call-partial',
        'tool_name': 'delegate_task',
        'content': jsonEncode({
          'status': 'dispatched',
          'delegation_id': 'deleg_partial',
          'subagent_ids': [
            'sa-partial-one',
            'sa-partial-two',
            'sa-partial-three',
          ],
        }),
      },
      {
        'message_id': 'partial-assistant',
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'call-partial',
            'function': {'name': 'delegate_task', 'arguments': '{}'},
          },
        ],
      },
      {'message_id': 'partial-user', 'role': 'user', 'content': 'Haz tres.'},
    ];

    final projection = projectSubagentsFromTranscript(
      messagesNewestFirst: messagesNewestFirst,
      scope: scope,
    );

    expect(projection.state?.activities, hasLength(3));
    expect(
      projection.state?.activities.map((activity) => activity.phase),
      everyElement(SubagentActivityPhase.unknown),
    );
  });

  test(
    'partial success aggregate never attributes completion to every child',
    () {
      final messagesNewestFirst = <Map<String, dynamic>>[
        {
          'message_id': 'partial-success-completion',
          'role': 'user',
          'display_kind': 'async_delegation_complete',
          'display_metadata': jsonEncode({
            'delegation_id': 'deleg_partial_success',
            'task_count': 3,
            'completed_count': 2,
            'failed_count': 0,
          }),
          'content':
              '[ASYNC DELEGATION BATCH COMPLETE — deleg_partial_success]',
        },
        {
          'message_id': 'partial-success-result',
          'role': 'tool',
          'tool_call_id': 'call-partial-success',
          'tool_name': 'delegate_task',
          'content': jsonEncode({
            'status': 'dispatched',
            'delegation_id': 'deleg_partial_success',
            'subagent_ids': [
              'sa-partial-success-one',
              'sa-partial-success-two',
              'sa-partial-success-three',
            ],
          }),
        },
        {
          'message_id': 'partial-success-assistant',
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call-partial-success',
              'function': {'name': 'delegate_task', 'arguments': '{}'},
            },
          ],
        },
        {
          'message_id': 'partial-success-user',
          'role': 'user',
          'content': 'Haz tres.',
        },
      ];

      final projection = projectSubagentsFromTranscript(
        messagesNewestFirst: messagesNewestFirst,
        scope: scope,
      );

      expect(projection.state?.activities, hasLength(3));
      expect(
        projection.state?.activities.map((activity) => activity.phase),
        everyElement(SubagentActivityPhase.unknown),
      );
    },
  );

  test('homogeneous aggregate failure attributes failure to every child', () {
    final messagesNewestFirst = <Map<String, dynamic>>[
      {
        'message_id': 'all-failed-completion',
        'role': 'user',
        'display_kind': 'async_delegation_complete',
        'display_metadata': jsonEncode({
          'delegation_id': 'deleg_all_failed',
          'task_count': 2,
          'completed_count': 0,
          'failed_count': 2,
        }),
        'content': '[ASYNC DELEGATION BATCH COMPLETE — deleg_all_failed]',
      },
      {
        'message_id': 'all-failed-result',
        'role': 'tool',
        'tool_call_id': 'call-all-failed',
        'tool_name': 'delegate_task',
        'content': jsonEncode({
          'status': 'dispatched',
          'delegation_id': 'deleg_all_failed',
          'subagent_ids': ['sa-all-failed-one', 'sa-all-failed-two'],
        }),
      },
      {
        'message_id': 'all-failed-assistant',
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'call-all-failed',
            'function': {'name': 'delegate_task', 'arguments': '{}'},
          },
        ],
      },
      {'message_id': 'all-failed-user', 'role': 'user', 'content': 'Haz dos.'},
    ];

    final projection = projectSubagentsFromTranscript(
      messagesNewestFirst: messagesNewestFirst,
      scope: scope,
    );

    expect(projection.state?.activities, hasLength(2));
    expect(
      projection.state?.activities.map((activity) => activity.phase),
      everyElement(SubagentActivityPhase.failed),
    );
  });

  test('async completion closes every child in the durable delegation', () {
    final messagesNewestFirst = <Map<String, dynamic>>[
      {
        'message_id': 'message-4',
        'role': 'user',
        'display_kind': 'async_delegation_complete',
        'display_metadata': jsonEncode({
          'delegation_id': 'deleg_many_complete',
          'task_count': 3,
          'completed_count': 3,
          'failed_count': 0,
        }),
        'content': '[ASYNC DELEGATION BATCH COMPLETE — deleg_many_complete]',
      },
      {
        'message_id': 'message-3',
        'role': 'tool',
        'tool_call_id': 'call-many-complete',
        'tool_name': 'delegate_task',
        'content': jsonEncode({
          'status': 'dispatched',
          'delegation_id': 'deleg_many_complete',
          'subagent_ids': ['sa-one', 'sa-two', 'sa-three'],
        }),
      },
      {
        'message_id': 'message-2',
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'call-many-complete',
            'function': {'name': 'delegate_task', 'arguments': '{}'},
          },
        ],
      },
      {'message_id': 'message-1', 'role': 'user', 'content': 'Haz tres.'},
    ];

    final projection = projectSubagentsFromTranscript(
      messagesNewestFirst: messagesNewestFirst,
      scope: scope,
    );

    expect(projection.state?.activities, hasLength(3));
    expect(
      projection.state?.activities.map((activity) => activity.phase),
      everyElement(SubagentActivityPhase.completed),
    );
  });

  test('async completion closes the matching durable delegation once', () {
    final messagesNewestFirst = <Map<String, dynamic>>[
      {
        'message_id': 'message-4',
        'role': 'user',
        'display_kind': 'async_delegation_complete',
        'display_metadata': jsonEncode({
          'delegation_id': 'deleg_deadbeef',
          'task_count': 1,
          'completed_count': 1,
          'failed_count': 0,
          'duration_seconds': 12.5,
        }),
        'content': '[ASYNC DELEGATION BATCH COMPLETE — deleg_deadbeef]',
      },
      {
        'message_id': 'message-3',
        'role': 'tool',
        'tool_call_id': 'call-1',
        'tool_name': 'delegate_task',
        'content': jsonEncode({
          'status': 'dispatched',
          'delegation_id': 'deleg_deadbeef',
          'subagent_ids': ['sa-0-deadbeef'],
        }),
      },
      {
        'message_id': 'message-2',
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'call-1',
            'function': {'name': 'delegate_task', 'arguments': '{}'},
          },
        ],
      },
      {'message_id': 'message-1', 'role': 'user', 'content': 'Haz la prueba.'},
    ];

    final projection = projectSubagentsFromTranscript(
      messagesNewestFirst: messagesNewestFirst,
      scope: scope,
    );

    expect(projection.state, isNotNull);
    expect(projection.state!.activities, hasLength(1));
    final activity = projection.state!.activities.single;
    expect(activity.phase, SubagentActivityPhase.completed);
    expect(activity.delegationId, 'deleg_deadbeef');
  });

  test(
    'rehydrates a Desktop snapshot through exact _desktopMessageId aliases',
    () {
      final messagesNewestFirst = <Map<String, dynamic>>[
        {
          '_desktopMessageId': 'desktop-completion',
          'role': 'user',
          'display_kind': 'async_delegation_complete',
          'display_metadata': jsonEncode({
            'delegation_id': 'deleg_cafebabe',
            'task_count': 1,
            'completed_count': 1,
            'failed_count': 0,
          }),
          'content': '[ASYNC DELEGATION BATCH COMPLETE — deleg_cafebabe]',
        },
        {
          '_desktopMessageId': 'desktop-result',
          'role': 'tool',
          'tool_call_id': 'call-desktop',
          'tool_name': 'delegate_task',
          'content': jsonEncode({
            'status': 'dispatched',
            'delegation_id': 'deleg_cafebabe',
            'subagent_ids': ['sa-0-cafebabe'],
          }),
        },
        {
          '_desktopMessageId': 'desktop-assistant',
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call-desktop',
              'function': {'name': 'delegate_task', 'arguments': '{}'},
            },
          ],
        },
        {
          '_desktopMessageId': '  desktop-user-exact  ',
          'role': 'user',
          'content': 'Recupera el subagente Desktop.',
        },
      ];

      final projection = projectSubagentsFromTranscript(
        messagesNewestFirst: messagesNewestFirst,
        scope: scope,
      );

      expect(projection.turnAnchor, 'canonical:  desktop-user-exact  ');
      expect(projection.state, isNotNull);
      expect(projection.state!.activities, hasLength(1));
      final activity = projection.state!.activities.single;
      expect(activity.phase, SubagentActivityPhase.completed);
      expect(activity.delegationId, 'deleg_cafebabe');
      expect(activity.subagentId, 'sa-0-cafebabe');
    },
  );

  test(
    'reconciler Desktop conserva delegation_id y cierra running end-to-end',
    () {
      DesktopSessionMessage row(Map<String, dynamic> value) =>
          DesktopSessionMessage.tryParse(value)!;
      final snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-e2e-subagent',
        storedSessionId: 'stored-1',
        created: false,
        messagesProvided: true,
        messageCount: 4,
        messages: [
          row({
            'message_id': 'e2e-user',
            'role': 'user',
            'content': 'Delega la prueba.',
          }),
          row({
            'message_id': 'e2e-assistant',
            'role': 'assistant',
            'content': '',
            'tool_calls': [
              {
                'id': 'call-e2e',
                'function': {'name': 'delegate_task', 'arguments': '{}'},
              },
            ],
          }),
          row({
            'message_id': 'e2e-tool',
            'role': 'tool',
            'tool_call_id': 'call-e2e',
            'tool_name': 'delegate_task',
            'content': jsonEncode({
              'status': 'dispatched',
              'delegation_id': 'deleg_e2e',
              'subagent_ids': ['sa-e2e'],
            }),
          }),
          row({
            'message_id': 'e2e-completion',
            'role': 'user',
            'content': '[ASYNC DELEGATION BATCH COMPLETE — deleg_e2e]',
            'display_kind': 'async_delegation_complete',
            'display_metadata': {
              'delegation_id': 'deleg_e2e',
              'task_count': 1,
              'completed_count': 1,
              'failed_count': 0,
              'duration_seconds': 3,
              'private_path': '/home/private-user',
            },
          }),
        ],
      );

      final transcript = const DesktopSessionReconciler()
          .project(snapshot)
          .messagesNewestFirst;
      final completion = transcript.firstWhere(
        (message) => message['_desktopMessageId'] == 'e2e-completion',
      );
      expect(completion['display_metadata'], {
        'task_count': 1,
        'completed_count': 1,
        'failed_count': 0,
        'duration_seconds': 3,
        'delegation_id': 'deleg_e2e',
      });

      final projection = projectSubagentsFromTranscript(
        messagesNewestFirst: transcript,
        scope: scope,
      );

      expect(projection.state, isNotNull);
      expect(
        projection.state!.activities.single.phase,
        SubagentActivityPhase.completed,
      );
      expect(projection.state!.activities.single.delegationId, 'deleg_e2e');
    },
  );

  test('durable recovery preserves native activity before anchor binding', () {
    final nativeEvent = SubagentActivityEvent.tryParseNative(
      type: 'subagent.start',
      scope: scope,
      payload: const {
        'subagent_id': 'native-live',
        'delegation_id': 'deleg_native01',
        'status': 'running',
      },
    )!;
    final current = SubagentActivityReducer.reduce(
      SubagentActivityState.empty(scope),
      nativeEvent,
    );
    final messagesNewestFirst = <Map<String, dynamic>>[
      {
        '_desktopMessageId': 'desktop-result-recovered',
        'role': 'tool',
        'tool_call_id': 'call-recovered',
        'tool_name': 'delegate_task',
        'content': jsonEncode({
          'status': 'dispatched',
          'delegation_id': 'deleg_deadbeef',
          'subagent_ids': ['sa-0-deadbeef'],
        }),
      },
      {
        '_desktopMessageId': 'desktop-assistant-recovered',
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'call-recovered',
            'function': {'name': 'delegate_task', 'arguments': '{}'},
          },
        ],
      },
      {
        '_desktopMessageId': 'desktop-user-recovered',
        'role': 'user',
        'content': 'Recupera todo el turno.',
      },
    ];

    final projection = projectSubagentsFromTranscript(
      messagesNewestFirst: messagesNewestFirst,
      scope: scope,
      current: current,
      currentTurnAnchor: null,
    );

    expect(projection.turnAnchor, 'canonical:desktop-user-recovered');
    expect(projection.state, isNotNull);
    expect(
      projection.state!.activities.map((activity) => activity.subagentId),
      containsAll(['native-live', 'sa-0-deadbeef']),
    );
  });

  test('durable completion is not stale against a native revision clock', () {
    final nativeEvent = SubagentActivityEvent.tryParseNative(
      type: 'subagent.start',
      scope: scope,
      payload: const {
        'subagent_id': 'sa-high-revision',
        'delegation_id': 'deleg_deadbeef',
        'status': 'running',
        'event_revision': 100,
      },
    )!;
    final current = SubagentActivityReducer.reduce(
      SubagentActivityState.empty(scope),
      nativeEvent,
    );
    final projection = projectSubagentsFromTranscript(
      messagesNewestFirst: [
        {
          'id': 'completion-high-revision',
          'role': 'user',
          'display_kind': 'async_delegation_complete',
          'display_metadata': jsonEncode({
            'delegation_id': 'deleg_deadbeef',
            'task_count': 1,
            'completed_count': 1,
            'failed_count': 0,
          }),
          'content': '[ASYNC DELEGATION BATCH COMPLETE — deleg_deadbeef]',
        },
        {
          'id': 'user-high-revision',
          'role': 'user',
          'content': 'Delega y completa.',
        },
      ],
      scope: scope,
      current: current,
      currentTurnAnchor: 'canonical:user-high-revision',
    );

    expect(projection.state, isNotNull);
    expect(
      projection.state!.activities.single.phase,
      SubagentActivityPhase.completed,
    );
    expect(projection.state!.activities.single.eventRevision, 100);
  });

  test('a replacement transcript keeps a still-live child across turns', () {
    final start = SubagentActivityEvent.tryParseNative(
      type: 'subagent.start',
      scope: scope,
      payload: const {
        'subagent_id': 'cross-turn-child',
        'delegation_id': 'deleg_cross_turn',
        'status': 'running',
      },
    )!;
    final current = SubagentActivityReducer.reduce(
      SubagentActivityState.empty(scope),
      start,
    );
    final followUpScope = SubagentActivityScope(
      connectionId: 'conn-1',
      profile: 'default',
      parentSessionId: 'stored-1',
      runtimeSessionId: 'runtime-2',
      turnEpoch: 8,
    );

    final projection = projectSubagentsFromTranscript(
      messagesNewestFirst: const [
        {
          'role': 'user',
          'content': 'A normal follow-up',
          '_optimistic': true,
          'platform_message_id': 'follow-up-user',
        },
        {
          'message_id': 'original-user',
          'role': 'user',
          'content': 'Delegate this work',
        },
      ],
      scope: followUpScope,
      current: current,
      currentTurnAnchor: 'canonical:original-user',
    );

    expect(projection.turnAnchor, 'platform:follow-up-user');
    expect(projection.state, same(current));
    expect(projection.state!.activities, hasLength(1));
    expect(
      projection.state!.activities.single.phase,
      SubagentActivityPhase.running,
    );
  });

  test('row id no acredita el turno de un canonical id homónimo', () {
    final previousEvent = SubagentActivityEvent.tryParseNative(
      type: 'subagent.start',
      scope: scope,
      payload: const {
        'subagent_id': 'previous-turn-child',
        'delegation_id': 'deleg_previous',
        'status': 'running',
      },
    )!;
    final previousState = SubagentActivityReducer.reduce(
      SubagentActivityState.empty(scope),
      previousEvent,
    );

    final previousProjection = projectSubagentsFromTranscript(
      messagesNewestFirst: const [
        {
          '_desktopMessageId': '42',
          'role': 'user',
          'content': 'Turno que sí lanzó el subagente.',
        },
      ],
      scope: scope,
      current: previousState,
      currentTurnAnchor: null,
    );
    final projection = projectSubagentsFromTranscript(
      messagesNewestFirst: const [
        {'_desktopRowId': 42, 'role': 'user', 'content': 'Este es otro turno.'},
      ],
      scope: scope,
      current: previousProjection.state,
      currentTurnAnchor: previousProjection.turnAnchor,
    );

    expect(previousProjection.turnAnchor, 'canonical:42');
    expect(projection.turnAnchor, 'row:42');
    expect(projection.state, isNull);
  });

  test('REST id numérico comparte el ancla tipada de Desktop row_id', () {
    final desktop = projectSubagentsFromTranscript(
      messagesNewestFirst: const [
        {'_desktopRowId': 74, 'role': 'user', 'content': 'Turno durable.'},
      ],
      scope: scope,
    );
    final rest = projectSubagentsFromTranscript(
      messagesNewestFirst: const [
        {'id': 74, 'role': 'user', 'content': 'Turno durable.'},
      ],
      scope: scope,
      current: desktop.state,
      currentTurnAnchor: desktop.turnAnchor,
    );

    expect(desktop.turnAnchor, 'row:74');
    expect(rest.turnAnchor, 'row:74');
  });

  test(
    'identidad Desktop enriquecida conserva el turno al pasar a REST row',
    () {
      final current = SubagentActivityState.empty(scope);
      final desktop = projectSubagentsFromTranscript(
        messagesNewestFirst: const [
          {
            '_desktopMessageId': 'message-74',
            '_desktopRowId': 74,
            'role': 'user',
            'content': 'Turno durable enriquecido.',
          },
        ],
        scope: scope,
        current: current,
      );
      final rest = projectSubagentsFromTranscript(
        messagesNewestFirst: const [
          {'id': 74, 'role': 'user', 'content': 'Turno durable enriquecido.'},
        ],
        scope: scope,
        current: desktop.state,
        currentTurnAnchor: desktop.turnAnchor,
      );

      expect(rest.turnAnchor, 'row:74');
      expect(rest.state, same(desktop.state));
    },
  );
}
