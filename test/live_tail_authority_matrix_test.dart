import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';

DesktopSessionSnapshot snap(
  Map<String, dynamic> json, {
  String stored = 'stored-authority',
}) => DesktopSessionSnapshot.fromJson(
  json,
  requestedStoredSessionId: stored,
  created: false,
  method: 'session.resume',
);

Map<String, dynamic> row(
  String id,
  String role,
  String content, {
  Object? timestamp = 100,
  bool steer = false,
  Object? toolCalls,
  String? callId,
}) => <String, dynamic>{
  'message_id': id,
  'role': role,
  'content': content,
  'timestamp': ?timestamp,
  if (steer) '_steer': true,
  'tool_calls': ?toolCalls,
  'tool_call_id': ?callId,
};

DesktopSessionProjection project({
  String runtime = 'runtime-authority',
  String prompt = 'same prompt',
  Object? turnStartedAt = 100,
  List<Object?> corrections = const [],
  List<Object?>? correctionOffsets,
  String assistant = 'live partial',
  String? error,
  String? status,
  bool streaming = true,
  List<Map<String, dynamic>> chronological = const [],
  List<Map<String, dynamic>> previousChronological = const [],
  bool bridgeOwnedLiveUser = false,
  String? queued,
}) {
  return const DesktopSessionReconciler().project(
    snap({
      'session_id': runtime,
      'session_key': 'stored-authority',
      'turn_started_at': ?turnStartedAt,
      'inflight': {
        'user': prompt,
        'assistant': assistant,
        'corrections': corrections,
        'correction_offsets': ?correctionOffsets,
        'streaming': streaming,
        'error': ?error,
        'status': ?status,
        if (error != null) 'recoverable': true,
      },
      if (queued != null) 'queued': {'user': queued},
      'running': true,
    }),
    fallbackNewestFirst: chronological.reversed.toList(growable: false),
    previousNewestFirst: previousChronological.reversed.toList(growable: false),
    bridgeOwnedLiveUser: bridgeOwnedLiveUser,
    retainMediaEvidence: true,
  );
}

int userCount(DesktopSessionProjection projection, String text) => projection
    .messagesNewestFirst
    .where((message) => message['role'] == 'user' && message['content'] == text)
    .length;

int roleCount(DesktopSessionProjection projection, String role) => projection
    .messagesNewestFirst
    .where((message) => message['role'] == role)
    .length;

Iterable<Map<String, dynamic>> syntheticUsers(
  DesktopSessionProjection projection,
) => projection.messagesNewestFirst.where(
  (message) =>
      message['role'] == 'user' &&
      message['_desktopSnapshotKind'] == 'inflight',
);

const toolCall = [
  {
    'id': 'call-1',
    'type': 'function',
    'function': {'name': 'probe', 'arguments': '{}'},
  },
];

void main() {
  group('live-tail authority matrix', () {
    test('historical equal prompt behind a final boundary keeps inflight', () {
      final result = project(
        previousChronological: [
          row('old-user', 'user', 'same prompt'),
          row('old-answer', 'assistant', 'old final'),
        ],
        chronological: [
          row('old-user', 'user', 'same prompt'),
          row('old-answer', 'assistant', 'old final'),
        ],
      );

      expect(userCount(result, 'same prompt'), 2);
      expect(syntheticUsers(result), hasLength(1));
    });

    test('current durable user after a final boundary suppresses inflight', () {
      final result = project(
        previousChronological: [
          row('old-user', 'user', 'same prompt'),
          row('old-answer', 'assistant', 'old final'),
        ],
        chronological: [
          row('old-user', 'user', 'same prompt'),
          row('old-answer', 'assistant', 'old final'),
          row('current-user', 'user', 'same prompt'),
        ],
      );

      expect(userCount(result, 'same prompt'), 2);
      expect(syntheticUsers(result), isEmpty);
    });

    test('tool-call assistant does not close the current durable turn', () {
      final result = project(
        previousChronological: [
          row('old-user', 'user', 'old prompt', timestamp: 99),
          row('old-answer', 'assistant', 'old final', timestamp: 99),
        ],
        chronological: [
          row('old-user', 'user', 'old prompt', timestamp: 99),
          row('old-answer', 'assistant', 'old final', timestamp: 99),
          row('current-user', 'user', 'same prompt'),
          row('tool-call-assistant', 'assistant', '', toolCalls: toolCall),
          row('tool-result', 'tool', 'result'),
        ],
      );

      expect(userCount(result, 'same prompt'), 1);
      expect(syntheticUsers(result), isEmpty);
      expect(roleCount(result, 'tool'), 1);
    });

    test('conflicting tool linkage cannot close the current durable turn', () {
      final result = project(
        previousChronological: [
          row('old-user', 'user', 'old prompt', timestamp: 99),
          row('old-answer', 'assistant', 'old final', timestamp: 99),
        ],
        chronological: [
          row('old-user', 'user', 'old prompt', timestamp: 99),
          row('old-answer', 'assistant', 'old final', timestamp: 99),
          row('current-user', 'user', 'same prompt'),
          row('tool-call-assistant', 'assistant', '', toolCalls: toolCall),
          row('tool-result', 'tool', 'result', callId: 'B'),
        ],
      );

      expect(userCount(result, 'same prompt'), 1);
      expect(syntheticUsers(result), isEmpty);
      expect(roleCount(result, 'tool'), 1);
    });

    test('assistant error closes the historical turn', () {
      final result = project(
        previousChronological: [
          row('old-user', 'user', 'same prompt'),
          row('old-error', 'assistant_error', 'failed'),
        ],
        chronological: [
          row('old-user', 'user', 'same prompt'),
          row('old-error', 'assistant_error', 'failed'),
        ],
      );

      expect(userCount(result, 'same prompt'), 2);
      expect(syntheticUsers(result), hasLength(1));
    });

    test(
      'assistant error with tool calls still closes the historical turn',
      () {
        const toolCall = <Map<String, Object?>>[
          <String, Object?>{
            'id': 'call-failed',
            'function': <String, Object?>{'name': 'shell', 'arguments': '{}'},
          },
        ];
        final result = project(
          previousChronological: [row('anchor', 'assistant', 'older final')],
          chronological: [
            row('anchor', 'assistant', 'older final'),
            row('failed-user', 'user', 'same prompt'),
            row(
              'failed-terminal',
              'assistant_error',
              'failed',
              toolCalls: toolCall,
            ),
          ],
        );

        expect(userCount(result, 'same prompt'), 2);
        expect(syntheticUsers(result), hasLength(1));
      },
    );

    test(
      'current durable user after a final boundary ignores malformed time',
      () {
        final result = project(
          previousChronological: [
            row('old-user', 'user', 'old', timestamp: 90),
            row('old-answer', 'assistant', 'done', timestamp: 90),
          ],
          chronological: [
            row('old-user', 'user', 'old', timestamp: 90),
            row('old-answer', 'assistant', 'done', timestamp: 90),
            row('current-user', 'user', 'same prompt', timestamp: null),
          ],
        );

        expect(userCount(result, 'same prompt'), 1);
        expect(syntheticUsers(result), isEmpty);
      },
    );

    test('unbounded cancelled equal prompt fails closed', () {
      final result = project(
        chronological: [row('cancelled-user', 'user', 'same prompt')],
      );

      expect(userCount(result, 'same prompt'), 2);
      expect(syntheticUsers(result), hasLength(1));
    });

    test('cancelled prompt after an older final does not suppress resend', () {
      final result = project(
        previousChronological: [
          row('older-user', 'user', 'older question', timestamp: 90),
          row('older-final', 'assistant', 'older answer', timestamp: 91),
          row('cancelled-user', 'user', 'same prompt', timestamp: 100),
        ],
        chronological: [
          row('older-user', 'user', 'older question', timestamp: 90),
          row('older-final', 'assistant', 'older answer', timestamp: 91),
          row('cancelled-user', 'user', 'same prompt', timestamp: 100),
        ],
      );

      expect(userCount(result, 'same prompt'), 2);
      expect(syntheticUsers(result), hasLength(1));
    });

    test('later durable self-anchor suppresses the second live refresh', () {
      final result = project(
        previousChronological: [
          row('older-user', 'user', 'older question', timestamp: 90),
          row('older-final', 'assistant', 'older answer', timestamp: 91),
          row('current-user', 'user', 'same prompt', timestamp: 105),
        ],
        chronological: [
          row('older-user', 'user', 'older question', timestamp: 90),
          row('older-final', 'assistant', 'older answer', timestamp: 91),
          row('current-user', 'user', 'same prompt', timestamp: 105),
        ],
      );

      expect(userCount(result, 'same prompt'), 1);
      expect(syntheticUsers(result), isEmpty);
    });

    test('duplicated previous anchor fails closed', () {
      final result = project(
        previousChronological: [row('anchor', 'assistant', 'old final')],
        chronological: [
          row('anchor', 'assistant', 'old final'),
          row('anchor', 'assistant', 'duplicate final'),
          row('current-user', 'user', 'same prompt'),
        ],
      );

      expect(userCount(result, 'same prompt'), 2);
      expect(syntheticUsers(result), hasLength(1));
    });

    test('contradictory previous anchor aliases fail closed', () {
      final previous = <String, dynamic>{
        'message_id': 'anchor',
        'row_id': 7,
        'role': 'assistant',
        'content': 'old final',
      };
      final contradictory = <String, dynamic>{
        'message_id': 'anchor',
        'row_id': 8,
        'role': 'assistant',
        'content': 'old final',
      };
      final result = project(
        previousChronological: [previous],
        chronological: [
          contradictory,
          row('current-user', 'user', 'same prompt'),
        ],
      );

      expect(userCount(result, 'same prompt'), 2);
      expect(syntheticUsers(result), hasLength(1));
    });

    test('missing previous anchor fails closed', () {
      final result = project(
        previousChronological: [
          row('missing-anchor', 'assistant', 'old final'),
        ],
        chronological: [
          row('different-anchor', 'assistant', 'old final'),
          row('current-user', 'user', 'same prompt'),
        ],
      );

      expect(userCount(result, 'same prompt'), 2);
      expect(syntheticUsers(result), hasLength(1));
    });

    test('id-less optimistic survivor blocks an older durable anchor', () {
      final optimistic = <String, dynamic>{
        'role': 'user',
        'content': 'same prompt',
        '_optimistic': true,
        '_localOperationId': 'old-operation',
      };
      final result = project(
        previousChronological: [
          row('old-answer', 'assistant', 'old final'),
          optimistic,
        ],
        chronological: [
          row('old-answer', 'assistant', 'old final'),
          row('late-durable-user', 'user', 'same prompt'),
        ],
      );

      expect(userCount(result, 'same prompt'), 2);
      expect(syntheticUsers(result), hasLength(1));
    });

    test('id-less inflight user blocks an older durable anchor', () {
      final previousInflight = <String, dynamic>{
        'role': 'user',
        'content': 'same prompt',
        '_desktopSnapshotKind': 'inflight',
        '_desktopSnapshotKey': 'user-inflight-old-runtime',
      };
      final result = project(
        previousChronological: [
          row('old-answer', 'assistant', 'old final'),
          previousInflight,
        ],
        chronological: [
          row('old-answer', 'assistant', 'old final'),
          row('late-durable-user', 'user', 'same prompt'),
        ],
      );

      expect(userCount(result, 'same prompt'), 2);
      expect(syntheticUsers(result), hasLength(1));
    });

    test('owned live-user bridge may cross the current synthetic user', () {
      final previousInflight = <String, dynamic>{
        'role': 'user',
        'content': 'same prompt',
        '_desktopSnapshotKind': 'inflight',
        '_desktopSnapshotKey': 'user-inflight-owned-runtime',
      };
      final result = project(
        bridgeOwnedLiveUser: true,
        previousChronological: [
          row('old-answer', 'assistant', 'old final'),
          previousInflight,
        ],
        chronological: [
          row('old-answer', 'assistant', 'old final'),
          row('current-user', 'user', 'same prompt'),
        ],
      );

      expect(userCount(result, 'same prompt'), 1);
      expect(syntheticUsers(result), isEmpty);
    });

    test('first-turn equal durable prompt without proof fails closed', () {
      final result = project(
        chronological: [row('first-user', 'user', 'same prompt')],
      );

      expect(userCount(result, 'same prompt'), 2);
      expect(syntheticUsers(result), hasLength(1));
    });

    test('local steer survivors are replaced by the fresh inflight vector', () {
      final result = project(
        corrections: const ['correction A', 'correction B'],
        previousChronological: [
          row('old-user', 'user', 'old', timestamp: 90),
          row('old-answer', 'assistant', 'done', timestamp: 90),
        ],
        chronological: [
          row('old-user', 'user', 'old', timestamp: 90),
          row('old-answer', 'assistant', 'done', timestamp: 90),
          row('current-user', 'user', 'same prompt'),
          row('local-a', 'user', 'correction A', steer: true),
          row('tool-a', 'tool', 'tool A'),
          row('local-b', 'user', 'correction B', steer: true),
          row('tool-b', 'tool', 'tool B'),
        ],
      );

      expect(userCount(result, 'same prompt'), 1);
      expect(userCount(result, 'correction A'), 1);
      expect(userCount(result, 'correction B'), 1);
      expect(roleCount(result, 'tool'), 2);
    });

    test('partial local correction prefix emits only the missing suffix', () {
      final result = project(
        corrections: const ['correction A', 'correction B'],
        previousChronological: [
          row('old-user', 'user', 'old', timestamp: 90),
          row('old-answer', 'assistant', 'done', timestamp: 90),
        ],
        chronological: [
          row('old-user', 'user', 'old', timestamp: 90),
          row('old-answer', 'assistant', 'done', timestamp: 90),
          row('current-user', 'user', 'same prompt'),
          row('local-a', 'user', 'correction A', steer: true),
        ],
      );

      expect(userCount(result, 'correction A'), 1);
      expect(userCount(result, 'correction B'), 1);
    });

    test('equal corrections preserve positional multiplicity', () {
      final result = project(
        corrections: const ['repeat correction', 'repeat correction'],
        previousChronological: [
          row('old-answer', 'assistant', 'done', timestamp: 90),
        ],
        chronological: [
          row('old-answer', 'assistant', 'done', timestamp: 90),
          row('current-user', 'user', 'same prompt'),
          row('local-one', 'user', 'repeat correction', steer: true),
        ],
      );

      expect(userCount(result, 'repeat correction'), 2);
    });

    test('correction equal to prompt preserves two causal user inputs', () {
      final result = project(
        corrections: const ['same prompt'],
        previousChronological: [
          row('old-answer', 'assistant', 'done', timestamp: 90),
        ],
        chronological: [
          row('old-answer', 'assistant', 'done', timestamp: 90),
          row('current-user', 'user', 'same prompt'),
          row('local-correction', 'user', 'same prompt', steer: true),
        ],
      );

      expect(userCount(result, 'same prompt'), 2);
    });

    test(
      'reordered local corrections fail closed without deleting either source',
      () {
        final result = project(
          corrections: const ['correction A', 'correction B'],
          previousChronological: [
            row('old-answer', 'assistant', 'done', timestamp: 90),
          ],
          chronological: [
            row('old-answer', 'assistant', 'done', timestamp: 90),
            row('current-user', 'user', 'same prompt'),
            row('local-b', 'user', 'correction B', steer: true),
            row('local-a', 'user', 'correction A', steer: true),
          ],
        );

        expect(userCount(result, 'correction A'), 2);
        expect(userCount(result, 'correction B'), 2);
      },
    );

    test('same-runtime synthetic replay is idempotent', () {
      final source = snap({
        'session_id': 'runtime-replay',
        'session_key': 'stored-authority',
        'inflight': {
          'user': 'prompt replay',
          'assistant': 'partial replay',
          'corrections': ['correction replay'],
          'streaming': true,
        },
        'running': true,
      });
      const reconciler = DesktopSessionReconciler();
      final first = reconciler.project(source, retainMediaEvidence: true);
      final second = reconciler.project(
        source,
        fallbackNewestFirst: first.messagesNewestFirst,
        retainMediaEvidence: true,
      );

      expect(second.messagesNewestFirst, first.messagesNewestFirst);
    });

    test(
      'authoritative runtime replacement retires old synthetic live rows',
      () {
        final first = project(
          runtime: 'runtime-old',
          prompt: 'prompt old',
          corrections: const ['correction old'],
          turnStartedAt: null,
        );
        final second = const DesktopSessionReconciler().project(
          snap({
            'session_id': 'runtime-new',
            'session_key': 'stored-authority',
            'inflight': {
              'user': 'prompt new',
              'assistant': 'partial new',
              'corrections': ['correction new'],
              'streaming': true,
            },
            'running': true,
          }),
          fallbackNewestFirst: first.messagesNewestFirst,
          retainMediaEvidence: true,
        );

        expect(userCount(second, 'prompt old'), 0);
        expect(userCount(second, 'prompt new'), 1);
        expect(userCount(second, 'correction old'), 0);
        expect(userCount(second, 'correction new'), 1);
      },
    );

    test('offset path uses the same correction authority plan', () {
      final result = project(
        corrections: const ['redirect now'],
        correctionOffsets: const [7],
        assistant: 'Before.After.',
        previousChronological: [
          row('old-answer', 'assistant', 'done', timestamp: 90),
        ],
        chronological: [
          row('old-answer', 'assistant', 'done', timestamp: 90),
          row('current-user', 'user', 'same prompt'),
          row('local-correction', 'user', 'redirect now', steer: true),
          row('tool-result', 'tool', 'result'),
        ],
      );

      expect(userCount(result, 'same prompt'), 1);
      expect(userCount(result, 'redirect now'), 1);
      expect(roleCount(result, 'tool'), 1);
    });

    test('recoverable error keeps one live correction and one error', () {
      final result = project(
        corrections: const ['recover this'],
        assistant: 'partial before drop',
        error: 'connection reset',
        status: 'error',
        streaming: false,
        previousChronological: [
          row('old-answer', 'assistant', 'done', timestamp: 90),
        ],
        chronological: [
          row('old-answer', 'assistant', 'done', timestamp: 90),
          row('current-user', 'user', 'same prompt'),
          row('local-correction', 'user', 'recover this', steer: true),
        ],
      );

      expect(userCount(result, 'same prompt'), 1);
      expect(userCount(result, 'recover this'), 1);
      expect(roleCount(result, 'assistant_error'), 1);
    });

    test('queued equal text remains a separate singleton', () {
      final result = project(
        queued: 'same prompt',
        previousChronological: [
          row('old-answer', 'assistant', 'done', timestamp: 90),
        ],
        chronological: [
          row('old-answer', 'assistant', 'done', timestamp: 90),
          row('current-user', 'user', 'same prompt'),
        ],
      );

      expect(userCount(result, 'same prompt'), 1);
      expect(result.queuedUser, 'same prompt');
      expect(result.queuedSyntheticId, isNotEmpty);
    });
  });
}
