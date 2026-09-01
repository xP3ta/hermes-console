import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/services/subagent_activity_reducer.dart';

SubagentActivityScope _scope({
  String connection = 'connection-a',
  String parent = 'parent-a',
  String runtime = 'runtime-a',
  int epoch = 1,
}) => SubagentActivityScope(
  connectionId: connection,
  parentSessionId: parent,
  runtimeSessionId: runtime,
  turnEpoch: epoch,
);

SubagentActivityEvent _native(
  String type,
  SubagentActivityScope scope,
  Map<String, Object?> payload, {
  int? revision,
  String? eventId,
}) => SubagentActivityEvent.tryParseNative(
  type: type,
  scope: scope,
  payload: payload,
  eventRevision: revision,
  eventId: eventId,
)!;

SubagentActivityEvent _legacy(
  String type,
  SubagentActivityScope scope,
  String callId, {
  Map<String, Object?> payload = const {},
  int? revision,
  String? eventId,
}) => SubagentActivityEvent.tryParseLegacyDelegateTool(
  type: type,
  scope: scope,
  payload: payload,
  toolName: 'delegate_task',
  toolCallId: callId,
  eventRevision: revision,
  eventId: eventId,
)!;

String _repeat(String value, int count) => List.filled(count, value).join();

void main() {
  group('native Hermes 0.19 parsing', () {
    test('recognizes the six event types and their normalized phases', () {
      final scope = _scope();
      const expected =
          <String, (SubagentActivityEventKind, SubagentActivityPhase)>{
            'subagent.spawn_requested': (
              SubagentActivityEventKind.spawnRequested,
              SubagentActivityPhase.requested,
            ),
            'subagent.start': (
              SubagentActivityEventKind.start,
              SubagentActivityPhase.running,
            ),
            'subagent.thinking': (
              SubagentActivityEventKind.thinking,
              SubagentActivityPhase.thinking,
            ),
            'subagent.tool': (
              SubagentActivityEventKind.tool,
              SubagentActivityPhase.tool,
            ),
            'subagent.progress': (
              SubagentActivityEventKind.progress,
              SubagentActivityPhase.running,
            ),
            'subagent.complete': (
              SubagentActivityEventKind.complete,
              SubagentActivityPhase.completed,
            ),
          };

      for (final item in expected.entries) {
        final event = _native(item.key, scope, const {'subagent_id': 'child'});
        expect(event.kind, item.value.$1);
        expect(event.phase, item.value.$2);
      }
      expect(
        SubagentActivityEvent.tryParseNative(
          type: 'subagent.unknown',
          scope: scope,
          payload: const {},
        ),
        isNull,
      );
    });

    test('uses only valid paired task progress and clamps display values', () {
      final scope = _scope();
      final valid = _native('subagent.progress', scope, const {
        'subagent_id': 'child-a',
        'task_index': 99,
        'task_count': 3,
      });
      final missingTotal = _native('subagent.progress', scope, const {
        'subagent_id': 'child-b',
        'task_index': 1,
      });
      final invalidTotal = _native('subagent.progress', scope, const {
        'subagent_id': 'child-c',
        'task_index': 1,
        'task_count': 0,
      });

      expect(valid.details.progress?.taskIndex, 99);
      expect(valid.details.progress?.taskCount, 3);
      expect(valid.details.progress?.displayTaskIndex, 3);
      expect(valid.details.progress?.displayFraction, 1);
      expect(missingTotal.details.progress, isNull);
      expect(invalidTotal.details.progress, isNull);
    });
  });

  group('SubagentActivityReducer', () {
    test('keeps two native children as independent stable rows', () {
      final scope = _scope();
      var state = SubagentActivityState.empty(scope);
      state = SubagentActivityReducer.reduce(
        state,
        _native('subagent.start', scope, const {'subagent_id': 'child-a'}),
      );
      state = SubagentActivityReducer.reduce(
        state,
        _native('subagent.start', scope, const {'subagent_id': 'child-b'}),
      );
      state = SubagentActivityReducer.reduce(
        state,
        _native('subagent.thinking', scope, const {'subagent_id': 'child-a'}),
      );

      expect(state.entries, hasLength(2));
      expect(
        state.activities
            .singleWhere((activity) => activity.subagentId == 'child-a')
            .phase,
        SubagentActivityPhase.thinking,
      );
      expect(
        state.activities
            .singleWhere((activity) => activity.subagentId == 'child-b')
            .phase,
        SubagentActivityPhase.running,
      );
    });

    test('complete without start reconstructs one absorbing terminal row', () {
      final scope = _scope();
      var state = SubagentActivityReducer.reduce(
        SubagentActivityState.empty(scope),
        _native(
          'subagent.complete',
          scope,
          const {'subagent_id': 'child-a', 'status': 'failed'},
          revision: 10,
          eventId: 'complete-10',
        ),
      );
      final completed = state;

      for (final type in const [
        'subagent.spawn_requested',
        'subagent.start',
        'subagent.thinking',
        'subagent.tool',
        'subagent.progress',
      ]) {
        state = SubagentActivityReducer.reduce(
          state,
          _native(
            type,
            scope,
            const {'subagent_id': 'child-a', 'status': 'running'},
            revision: 11,
            eventId: 'late-$type',
          ),
        );
      }

      expect(identical(completed, state), isTrue);
      expect(state.entries, hasLength(1));
      expect(state.activities.single.phase, SubagentActivityPhase.failed);
    });

    test('newer repeated complete enriches usage without duplicating row', () {
      final scope = _scope();
      var state = SubagentActivityReducer.reduce(
        SubagentActivityState.empty(scope),
        _native(
          'subagent.complete',
          scope,
          const {'subagent_id': 'child-a', 'input_tokens': 12},
          revision: 5,
          eventId: 'complete-5',
        ),
      );
      state = SubagentActivityReducer.reduce(
        state,
        _native(
          'subagent.complete',
          scope,
          const {
            'subagent_id': 'child-a',
            'summary': 'Resumen confirmado',
            'output_tokens': 7,
            'duration_seconds': 2.5,
          },
          revision: 6,
          eventId: 'complete-6',
        ),
      );

      final activity = state.activities.single;
      expect(state.entries, hasLength(1));
      expect(activity.phase, SubagentActivityPhase.completed);
      expect(activity.resultPreview, 'Resumen confirmado');
      expect(activity.usage?.inputTokens, 12);
      expect(activity.usage?.outputTokens, 7);
      expect(activity.details.durationSeconds, 2.5);
      expect(activity.eventRevision, 6);
    });

    test('same revision and same event id are idempotent', () {
      final scope = _scope();
      final initial = SubagentActivityReducer.reduce(
        SubagentActivityState.empty(scope),
        _native(
          'subagent.tool',
          scope,
          const {'subagent_id': 'child-a', 'tool_name': 'search'},
          revision: 3,
          eventId: 'event-3',
        ),
      );
      final sameRevision = SubagentActivityReducer.reduce(
        initial,
        _native(
          'subagent.tool',
          scope,
          const {'subagent_id': 'child-a', 'tool_name': 'stale-change'},
          revision: 3,
          eventId: 'another-id-same-revision',
        ),
      );
      final replay = SubagentActivityReducer.reduce(
        sameRevision,
        _native(
          'subagent.tool',
          scope,
          const {'subagent_id': 'child-a', 'tool_name': 'search'},
          revision: 4,
          eventId: 'event-3',
        ),
      );

      expect(identical(initial, sameRevision), isTrue);
      expect(identical(sameRevision, replay), isTrue);
      expect(initial.activities.single.details.activeToolName, 'search');
    });

    test('progress enriches metrics without erasing latest tool phase', () {
      final scope = _scope();
      var state = SubagentActivityReducer.reduce(
        SubagentActivityState.empty(scope),
        _native('subagent.tool', scope, const {
          'subagent_id': 'child-a',
          'tool_name': 'browser',
        }, revision: 1),
      );
      state = SubagentActivityReducer.reduce(
        state,
        _native('subagent.progress', scope, const {
          'subagent_id': 'child-a',
          'task_index': 2,
          'task_count': 4,
          'tool_count': 3,
        }, revision: 2),
      );

      final activity = state.activities.single;
      expect(activity.phase, SubagentActivityPhase.tool);
      expect(activity.details.activeToolName, 'browser');
      expect(activity.progress?.taskIndex, 2);
      expect(activity.details.toolCount, 3);
    });

    test('scope mismatch cannot mutate a focused or parked reducer', () {
      final focusedScope = _scope();
      final wrongScopes = [
        _scope(connection: 'connection-b'),
        _scope(parent: 'parent-b'),
        _scope(runtime: 'runtime-b'),
        _scope(epoch: 2),
      ];
      final empty = SubagentActivityState.empty(focusedScope);

      for (final wrongScope in wrongScopes) {
        final unchanged = SubagentActivityReducer.reduce(
          empty,
          _native('subagent.start', wrongScope, const {
            'subagent_id': 'same-child-id',
          }),
        );
        expect(identical(empty, unchanged), isTrue);
      }
    });

    test(
      'confirmed durable alias explicitly rebases the exact event scope',
      () {
        final runtimeOne = _scope(runtime: 'runtime-1', epoch: 7);
        final runtimeTwo = _scope(runtime: 'runtime-2', epoch: 7);
        var state = SubagentActivityReducer.reduce(
          SubagentActivityState.empty(runtimeOne),
          _native('subagent.start', runtimeOne, const {
            'subagent_id': 'child-a',
            'goal': 'preserved',
            'event_id': 'start-a',
            'event_revision': 1,
          }),
        );

        state = state.rebaseScope(runtimeTwo);
        expect(state.scope, runtimeTwo);
        expect(state.activities.single.key.scope, runtimeTwo);
        expect(state.activities.single.goalPreview, 'preserved');

        final stale = SubagentActivityReducer.reduce(
          state,
          _native('subagent.progress', runtimeOne, const {
            'subagent_id': 'child-a',
            'event_revision': 2,
          }),
        );
        expect(identical(stale, state), isTrue);

        final completed = SubagentActivityReducer.reduce(
          state,
          _native('subagent.complete', runtimeTwo, const {
            'subagent_id': 'child-a',
            'event_id': 'complete-a',
            'event_revision': 2,
            'status': 'completed',
          }),
        );
        expect(
          completed.activities.single.phase,
          SubagentActivityPhase.completed,
        );
      },
    );

    test('rebase rejects a different durable lineage', () {
      final state = SubagentActivityState.empty(_scope(runtime: 'runtime-1'));
      expect(
        () => state.rebaseScope(
          _scope(parent: 'foreign-parent', runtime: 'runtime-2'),
        ),
        throwsStateError,
      );
    });

    test('missing or overlong identity never creates a durable row', () {
      final scope = _scope();
      final empty = SubagentActivityState.empty(scope);
      final anonymous = _native('subagent.spawn_requested', scope, const {
        'goal': 'No stable identity',
      });
      final overlong = _native('subagent.start', scope, {
        'subagent_id': _repeat(
          'x',
          SubagentPayloadLimits.opaqueIdCharacters + 1,
        ),
      });

      expect(anonymous.hasStableIdentity, isFalse);
      expect(overlong.hasStableIdentity, isFalse);
      expect(
        identical(empty, SubagentActivityReducer.reduce(empty, anonymous)),
        isTrue,
      );
      expect(
        identical(empty, SubagentActivityReducer.reduce(empty, overlong)),
        isTrue,
      );
    });
  });

  group('legacy delegate_task fallback', () {
    test('projects only basic running and terminal state by tool-call id', () {
      final scope = _scope();
      var state = SubagentActivityReducer.reduce(
        SubagentActivityState.empty(scope),
        _legacy('tool.start', scope, 'call-a'),
      );
      expect(state.activities.single.phase, SubagentActivityPhase.running);

      state = SubagentActivityReducer.reduce(
        state,
        _legacy(
          'tool.complete',
          scope,
          'call-a',
          payload: const {'success': false, 'summary': 'Falló de forma segura'},
        ),
      );

      final activity = state.activities.single;
      expect(activity.phase, SubagentActivityPhase.failed);
      expect(activity.source, SubagentActivitySource.legacyDelegateTask);
      expect(activity.key.identityKind, SubagentIdentityKind.legacyToolCall);
      expect(activity.resultPreview, 'Falló de forma segura');
    });

    test('ignores native-only payload fields and never invents transcript', () {
      final scope = _scope();
      final state = SubagentActivityReducer.reduce(
        SubagentActivityState.empty(scope),
        _legacy(
          'tool.complete',
          scope,
          'call-a',
          payload: const {
            'summary': 'Resumen básico',
            'subagent_id': 'must-not-become-native',
            'child_session_id': 'must-not-become-transcript',
            'depth': 3,
            'task_index': 2,
            'task_count': 4,
            'input_tokens': 100,
            'files_written': ['/managed/private.txt'],
            'output_tail': 'must-not-be-retained',
          },
        ),
      );

      final activity = state.activities.single;
      expect(activity.subagentId, isNull);
      expect(activity.childSessionId, isNull);
      expect(activity.canResumeChildTranscript, isFalse);
      expect(activity.details.depth, isNull);
      expect(activity.progress, isNull);
      expect(activity.usage, isNull);
      expect(activity.details.filesWrittenCount, isNull);
      expect(activity.details.outputTailPreview, isNull);
      expect(activity.resultPreview, 'Resumen básico');
    });

    test('native event explicitly linked by call id upgrades one row', () {
      final scope = _scope();
      var state = SubagentActivityReducer.reduce(
        SubagentActivityState.empty(scope),
        _legacy('tool.start', scope, 'call-a'),
      );
      state = SubagentActivityReducer.reduce(
        state,
        _native('subagent.start', scope, const {
          'subagent_id': 'native-child',
          'child_session_id': 'durable-child-session',
          'tool_call_id': 'call-a',
        }),
      );

      final upgraded = state.activities.single;
      expect(state.entries, hasLength(1));
      expect(upgraded.source, SubagentActivitySource.native);
      expect(upgraded.key.identityKind, SubagentIdentityKind.subagent);
      expect(upgraded.subagentId, 'native-child');
      expect(upgraded.canResumeChildTranscript, isTrue);

      final afterLegacyComplete = SubagentActivityReducer.reduce(
        state,
        _legacy('tool.complete', scope, 'call-a'),
      );
      expect(identical(state, afterLegacyComplete), isTrue);
      expect(afterLegacyComplete.activities.single.phase.isTerminal, isFalse);
    });

    test('same text never merges two unrelated legacy tool calls', () {
      final scope = _scope();
      var state = SubagentActivityState.empty(scope);
      for (final callId in const ['call-a', 'call-b']) {
        state = SubagentActivityReducer.reduce(
          state,
          _legacy(
            'tool.complete',
            scope,
            callId,
            payload: const {'summary': 'El mismo resumen'},
          ),
        );
      }

      expect(state.entries, hasLength(2));
    });

    test('does not accept other tools or event types', () {
      final scope = _scope();
      expect(
        SubagentActivityEvent.tryParseLegacyDelegateTool(
          type: 'tool.start',
          scope: scope,
          payload: const {},
          toolName: 'browser',
          toolCallId: 'call-a',
        ),
        isNull,
      );
      expect(
        SubagentActivityEvent.tryParseLegacyDelegateTool(
          type: 'tool.delta',
          scope: scope,
          payload: const {},
          toolName: 'delegate_task',
          toolCallId: 'call-a',
        ),
        isNull,
      );
    });
  });

  group('bounded and non-diagnostic payloads', () {
    test(
      'bounds text/list payloads and retains file metadata as counts only',
      () {
        final scope = _scope();
        final longGoal = _repeat(
          '🧭',
          SubagentPayloadLimits.goalCharacters + 20,
        );
        final longResult = _repeat(
          '📦',
          SubagentPayloadLimits.resultCharacters + 20,
        );
        final longTool = _repeat(
          't',
          SubagentPayloadLimits.toolNameCharacters + 20,
        );
        final toolsets = List<String>.generate(
          SubagentPayloadLimits.toolsetCount + 5,
          (index) => 'toolset-$index-${_repeat('x', 200)}',
        );
        final event = _native('subagent.complete', scope, {
          'subagent_id': 'child-a',
          'goal': longGoal,
          'summary': longResult,
          'output_tail': longResult,
          'tool_name': longTool,
          'tool_preview': longResult,
          'toolsets': toolsets,
          'files_read': const ['/private/read-a', '/private/read-b'],
          'files_written': const {'count': 4, 'path': '/private/write'},
        });
        final state = SubagentActivityReducer.reduce(
          SubagentActivityState.empty(scope),
          event,
        );
        final details = state.activities.single.details;

        expect(
          details.goalPreview?.runes.length,
          SubagentPayloadLimits.goalCharacters,
        );
        expect(
          details.summaryPreview?.runes.length,
          SubagentPayloadLimits.resultCharacters,
        );
        expect(
          details.outputTailPreview?.runes.length,
          SubagentPayloadLimits.resultCharacters,
        );
        expect(
          details.activeToolName?.runes.length,
          SubagentPayloadLimits.toolNameCharacters,
        );
        expect(
          details.activeToolPreview?.runes.length,
          SubagentPayloadLimits.toolPreviewCharacters,
        );
        expect(details.toolsets, hasLength(SubagentPayloadLimits.toolsetCount));
        expect(
          details.toolsets.every(
            (name) =>
                name.runes.length <= SubagentPayloadLimits.toolsetCharacters,
          ),
          isTrue,
        );
        expect(details.filesReadCount, 2);
        expect(details.filesWrittenCount, 4);
      },
    );

    test('does not print or stringify untrusted payload text', () {
      const sensitive = 'payload-that-must-not-enter-diagnostics';
      final scope = _scope();
      final printed = <String>[];
      late SubagentActivityEvent event;
      late SubagentActivityState state;

      runZoned(
        () {
          event = _native('subagent.complete', scope, const {
            'subagent_id': 'child-a',
            'goal': sensitive,
            'summary': sensitive,
            'output_tail': sensitive,
            'tool_preview': sensitive,
            'unknown_secret': sensitive,
          });
          state = SubagentActivityReducer.reduce(
            SubagentActivityState.empty(scope),
            event,
          );
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );

      expect(printed, isEmpty);
      expect(event.toString(), isNot(contains(sensitive)));
      expect(state.activities.single.toString(), isNot(contains(sensitive)));
      expect(state.toString(), isNot(contains(sensitive)));
      expect(state.activities.single.goalPreview, sensitive);
    });
  });

  test('scope rejects malformed identities before reduction', () {
    expect(
      () => SubagentActivityScope(
        connectionId: ' ',
        parentSessionId: 'parent',
        runtimeSessionId: 'runtime',
        turnEpoch: 0,
      ),
      throwsFormatException,
    );
    expect(
      () => SubagentActivityScope(
        connectionId: 'connection',
        parentSessionId: 'parent',
        runtimeSessionId: 'runtime',
        turnEpoch: -1,
      ),
      throwsFormatException,
    );
  });
}
