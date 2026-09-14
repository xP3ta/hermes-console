import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  for (final liveCalls in [false, true]) {
    for (final calls in [false, true]) {
      for (final result in [false, true]) {
        test(
          'live head identity liveCalls=$liveCalls calls=$calls result=$result',
          () {
            final service = ActiveChatService();
            addTearDown(service.dispose);
            final chat = service.attach(
              connection: SavedConnection(
                id: 'diagnostic',
                label: 'Diagnostic',
                host: 'example.invalid',
                port: 443,
                apiKey: 'test-only',
                useHttps: true,
              ),
              sessionId: 'diagnostic',
              sessionTitle: 'Diagnostic',
              api: ApiClient(
                baseUrl: 'https://example.invalid',
                apiKey: 'test-only',
                httpClient: MockClient(
                  (_) async => http.Response('not found', 404),
                ),
              ),
              disableForegroundKeepAlive: true,
            );
            chat.state = ChatPipelineState.streaming;
            final live = <String, dynamic>{
              'role': 'assistant',
              'content': '',
              '_pipeline': true,
              if (liveCalls)
                'tool_calls': [
                  {
                    'id': 'live-call',
                    'type': 'function',
                    'function': {
                      'name': 'terminal',
                      'arguments': 'PRIVATE_ARGUMENTS',
                    },
                  },
                ],
            };
            final historical = <String, dynamic>{
              'role': 'assistant',
              'content': 'PUBLIC_HISTORY',
              if (calls)
                'tool_calls': [
                  {
                    'id': 'call-diagnostic',
                    'type': 'function',
                    'function': {
                      'name': 'terminal',
                      'arguments': 'PRIVATE_ARGUMENTS',
                    },
                  },
                ],
            };
            chat.replaceInternalMessagesForTesting([
              live,
              {'role': 'user', 'content': 'PUBLIC_CURRENT_PROMPT'},
              if (result)
                {
                  'role': 'tool',
                  'tool_call_id': 'call-diagnostic',
                  'content': 'PRIVATE_RESULT',
                },
              historical,
              {'role': 'user', 'content': 'PUBLIC_OLD_PROMPT'},
            ]);
            final first = chat.messages;
            final second = chat.messages;
            final identityBeforeDelta = identical(first.first, second.first);
            final encoded = jsonEncode(second);
            expect(encoded, isNot(contains('PRIVATE_RESULT')));
            expect(encoded, isNot(contains('PRIVATE_ARGUMENTS')));
            expect(second.where((m) => m['role'] == 'tool'), isEmpty);
            expect(chat.internalMessagesForTesting.first, same(live));

            // Deltas mutate the real internal live row; the next pair of reads
            // must agree on the identity consumed by ChatScreen's host guard.
            live['content'] = 'PUBLIC_DELTA_ONE';
            final deltaFirst = chat.messages;
            final deltaSecond = chat.messages;
            final identityAfterDelta = identical(
              deltaFirst.first,
              deltaSecond.first,
            );
            expect(deltaSecond.first['content'], 'PUBLIC_DELTA_ONE');

            expect(
              identityBeforeDelta,
              isTrue,
              reason:
                  'Two unchanged ActiveChat.messages reads must retain the live head '
                  'for ChatScreen identical(unit, _messages.first); calls=$calls result=$result',
            );
            expect(
              identityAfterDelta,
              isTrue,
              reason:
                  'After a delta, repeated reads must retain the live host identity',
            );
            if (liveCalls) {
              final oldHead = deltaSecond.first;
              (live['tool_calls'] as List).first['function']['name'] =
                  'read_file';
              final changed = chat.messages.first;
              expect(changed, isNot(same(oldHead)));
              expect(
                (oldHead['tool_calls'] as List).first['function']['name'],
                'terminal',
              );
              expect(
                (changed['tool_calls'] as List).first['function']['name'],
                'read_file',
              );
              expect(chat.messages.first, same(changed));
            }
          },
        );
      }
    }
  }
}
