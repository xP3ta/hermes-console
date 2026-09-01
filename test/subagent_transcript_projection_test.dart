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
    expect(activity.phase, SubagentActivityPhase.running);
    expect(activity.delegationId, 'deleg_deadbeef');
    expect(activity.subagentId, 'sa-0-deadbeef');
    expect(activity.legacyToolCallId, 'call-1');
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
