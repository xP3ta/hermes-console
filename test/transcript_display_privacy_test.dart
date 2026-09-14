import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('normalizeTranscriptMessageForDisplay privacy boundary', () {
    test(
      'drops missing invalid and explicitly private roles or classifiers',
      () {
        expect(
          normalizeTranscriptMessageForDisplay(const {
            'content': 'PRIVATE_MISSING',
          }),
          isNull,
        );
        expect(
          normalizeTranscriptMessageForDisplay(const {
            'role': 'alien',
            'content': 'PRIVATE_INVALID',
          }),
          isNull,
        );
        expect(
          normalizeTranscriptMessageForDisplay(const {
            'role': 'assistant',
            'content': 'PRIVATE_ANALYSIS',
            'channel': 'analysis',
          }),
          isNull,
        );
        expect(
          normalizeTranscriptMessageForDisplay(const {
            'role': 'user',
            'content': 'PRIVATE_DISPLAY_HIDDEN',
            'display_kind': 'hidden',
          }),
          isNull,
        );
        expect(
          normalizeTranscriptMessageForDisplay(const {
            'role': 'assistant',
            'content': 'PRIVATE_HIDDEN',
            'hidden': true,
          }),
          isNull,
        );
      },
    );

    test('keeps only public identity content and timestamp fields', () {
      final normalized = normalizeTranscriptMessageForDisplay(const {
        'id': 7,
        'message_id': 'msg-7',
        'row_id': 7,
        'role': 'assistant',
        'content': '<think>PRIVATE_INLINE</think>Respuesta pública.',
        'timestamp': 123.5,
        'reasoning': 'PRIVATE_REASONING',
        'reasoning_content': 'PRIVATE_REASONING_CONTENT',
        'reasoning_details': [
          {'text': 'PRIVATE_TRACE'},
        ],
        'trace': 'PRIVATE_TRACE',
        'owner_pid': 991,
        'path': '/home/private',
        'tool_arguments': {'secret': true},
        'display_kind': 'unknown-private-kind',
        'display_metadata': {'goal': 'PRIVATE_GOAL'},
      });

      expect(normalized, {
        'id': 7,
        'message_id': 'msg-7',
        'row_id': 7,
        'role': 'assistant',
        'content': 'Respuesta pública.',
        'timestamp': 123.5,
      });
    });

    test('keeps only sanitized metadata for a known editorial marker', () {
      final normalized = normalizeTranscriptMessageForDisplay(const {
        'message_id': 'marker-1',
        'role': 'user',
        'content': '[ASYNC DELEGATION BATCH COMPLETE — deleg_deadbeef]',
        'display_kind': 'async_delegation_complete',
        'display_metadata': {
          'delegation_id': 'deleg_deadbeef',
          'task_count': 1,
          'completed_count': 1,
          'failed_count': 0,
          'subagent_ids': ['sa-safe'],
          'goal': 'PRIVATE_GOAL',
          'path': '/home/private',
        },
      });

      expect(normalized, {
        'message_id': 'marker-1',
        'role': 'user',
        'content': '[ASYNC DELEGATION BATCH COMPLETE — deleg_deadbeef]',
        'display_kind': 'async_delegation_complete',
        'display_metadata': {
          'delegation_id': 'deleg_deadbeef',
          'task_count': 1,
          'completed_count': 1,
          'failed_count': 0,
          'subagent_ids': ['sa-safe'],
        },
      });
    });

    test(
      'central display projection drops private reconciliation identity',
      () {
        final snapshot = DesktopSessionSnapshot.fromJson(
          const {
            'session_id': 'runtime-private',
            'session_key': 'stored-private',
            'messages': [
              {
                'id': 'PRIVATE_MESSAGE_ID',
                'row_id': 77,
                'role': 'assistant',
                'content': 'PUBLIC_NARRATION',
              },
            ],
          },
          requestedStoredSessionId: 'stored-private',
          created: false,
          method: 'session.resume',
        );
        final internal = const DesktopSessionReconciler()
            .project(snapshot)
            .messagesNewestFirst
            .single;
        final public = normalizeTranscriptMessageForDisplay(
          internal,
          retainProjectionState: true,
        )!;

        for (final key in const [
          '_desktopSnapshotKey',
          '_desktopSnapshotKind',
          '_desktopMessageOrdinal',
          '_desktopRowId',
          '_desktopMessageId',
        ]) {
          expect(
            public,
            isNot(contains(key)),
            reason: '$key leaked in $public',
          );
        }
        expect(public['content'], 'PUBLIC_NARRATION');
      },
    );
  });

  test(
    'ActiveChat keeps reconciliation identity private and map identity stable',
    () {
      final service = ActiveChatService();
      addTearDown(service.dispose);
      final chat = service.attach(
        connection: SavedConnection(
          id: 'private-state-probe',
          label: 'Private state probe',
          host: 'hermes.local',
          port: 8642,
          apiKey: 'probe-key',
        ),
        sessionId: 'private-state-session',
        sessionTitle: 'Private state probe',
        api: ApiClient(
          baseUrl: 'http://hermes.local:8642',
          apiKey: 'probe-key',
          httpClient: MockClient((_) async => http.Response('not found', 404)),
        ),
      );
      final internalMessage = <String, dynamic>{
        'role': 'assistant',
        'content': 'PUBLIC_NARRATION',
        '_desktopSnapshotKey': 'PRIVATE_SNAPSHOT_KEY',
        '_desktopSnapshotKind': 'persisted',
        '_desktopMessageOrdinal': 7,
        '_desktopRowId': 77,
        '_desktopMessageId': 'PRIVATE_MESSAGE_ID',
        '_localTerminalProjectionId': 'PRIVATE_TERMINAL_ID',
        '_localTerminalAnchorMessageId': 'PRIVATE_TERMINAL_ANCHOR',
        '_localTerminalAnchorRowId': 70,
        '_localTerminalOrdinalAfterAnchor': 1,
        '_localTerminalAbsoluteUserOrdinal': 8,
        '_localTranscriptProjectionId': 'PRIVATE_LOCAL_PROJECTION',
        '_localTranscriptPairId': 'PRIVATE_LOCAL_PAIR',
      };

      chat.replaceInternalMessagesForTesting([internalMessage]);

      expect(chat.internalMessagesForTesting.single, same(internalMessage));
      final publicMessages = chat.messages;
      expect(publicMessages.single, isNot(same(internalMessage)));
      expect(publicMessages.single['content'], 'PUBLIC_NARRATION');
      final encoded = jsonEncode(publicMessages);
      for (final forbidden in const [
        '_desktopSnapshotKey',
        '_desktopSnapshotKind',
        '_desktopMessageOrdinal',
        '_desktopRowId',
        '_desktopMessageId',
        '_localTerminalProjectionId',
        '_localTerminalAnchorMessageId',
        '_localTerminalAnchorRowId',
        '_localTerminalOrdinalAfterAnchor',
        '_localTerminalAbsoluteUserOrdinal',
        '_localTranscriptProjectionId',
        '_localTranscriptPairId',
      ]) {
        expect(encoded, isNot(contains(forbidden)), reason: encoded);
      }
      expect(
        () => publicMessages.add({'role': 'user', 'content': 'mutation'}),
        throwsUnsupportedError,
      );
      expect(
        () => publicMessages.single['_desktopSnapshotKey'] = 'mutation',
        throwsUnsupportedError,
      );
    },
  );
}
