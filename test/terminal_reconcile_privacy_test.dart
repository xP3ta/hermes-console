import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/compression_restore_store.dart';

class _MemoryCompressionFenceStorage implements CompressionRestoreStorage {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    this.value = value;
  }
}

void main() {
  test('terminal REST reconcile projects the public transcript only', () async {
    final client = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'POST' && path == '/v1/runs') {
        return http.Response(jsonEncode({'run_id': 'run_1'}), 200);
      }
      if (request.method == 'GET' && path == '/v1/runs/run_1/events') {
        return http.Response(
          'data: ${jsonEncode({'event': 'run.completed', 'output': 'PUBLIC_FINAL'})}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      if (request.method == 'GET' && path == '/api/sessions/sess-1/messages') {
        return http.Response(
          jsonEncode({
            'data': [
              {
                'role': 'user',
                'content': 'PUBLIC_PROMPT',
                'arbitrary_private_metadata': 'PRIVATE_USER_METADATA',
              },
              {
                'role': 'assistant',
                'content': '',
                'tool_calls': [
                  {
                    'id': 'call-1',
                    'function': {
                      'name': 'shell',
                      'arguments': '{"token":"PRIVATE_TOOL_ARGS"}',
                    },
                  },
                ],
                'reasoning': 'PRIVATE_REASONING',
              },
              {
                'role': 'tool',
                'tool_call_id': 'call-1',
                'content': 'PRIVATE_TOOL_RESULT',
                'arbitrary_private_metadata': 'PRIVATE_TOOL_METADATA',
              },
              {
                'role': 'assistant',
                'content': 'PUBLIC_FINAL',
                'analysis': 'PRIVATE_ANALYSIS',
                'arbitrary_private_metadata': 'PRIVATE_ASSISTANT_METADATA',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('not found', 404);
    });

    final service = ActiveChatService(
      compressionRestoreStore: CompressionRestoreStore(
        storage: _MemoryCompressionFenceStorage(),
      ),
    );
    addTearDown(service.dispose);
    final chat = service.attach(
      connection: SavedConnection(
        id: 'probe-conn',
        label: 'Probe',
        host: 'hermes.local',
        port: 8642,
        apiKey: 'probe-key',
      ),
      sessionId: 'sess-1',
      sessionTitle: 'Probe',
      api: ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'probe-key',
        httpClient: client,
      ),
    );
    chat.smoothStreaming = false;

    final done = chat.changes.firstWhere((e) => e == ActiveChatEvent.done);
    expect(
      await chat.send(
        fullText: 'PUBLIC_PROMPT',
        model: 'probe',
        history: const [],
      ),
      isTrue,
    );
    await done.timeout(const Duration(seconds: 5));

    final published = jsonEncode(chat.messages);
    expect(published, contains('PUBLIC_PROMPT'));
    expect(published, contains('PUBLIC_FINAL'));
    for (final forbidden in const [
      'PRIVATE_USER_METADATA',
      'PRIVATE_TOOL_ARGS',
      'PRIVATE_REASONING',
      'PRIVATE_TOOL_RESULT',
      'PRIVATE_TOOL_METADATA',
      'PRIVATE_ANALYSIS',
      'PRIVATE_ASSISTANT_METADATA',
    ]) {
      expect(published, isNot(contains(forbidden)), reason: published);
    }
  });

  test(
    'terminal fallback publishes only the public answer while REST is 404',
    () async {
      const private = 'PRIVATE_TERMINAL_REASONING_/home/owner/session.jsonl';
      const public = 'PUBLIC_FINAL';
      final client = MockClient((request) async {
        if (request.method == 'POST' && request.url.path == '/v1/runs') {
          return http.Response(jsonEncode({'run_id': 'run-private'}), 200);
        }
        if (request.method == 'GET' &&
            request.url.path == '/v1/runs/run-private/events') {
          return http.Response(
            'data: ${jsonEncode({'event': 'run.completed', 'output': '<think>$private</think>$public'})}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        if (request.method == 'GET' &&
            request.url.path == '/api/sessions/sess-private/messages') {
          return http.Response('not ready', 404);
        }
        return http.Response('not found', 404);
      });

      final service = ActiveChatService(
        compressionRestoreStore: CompressionRestoreStore(
          storage: _MemoryCompressionFenceStorage(),
        ),
      );
      addTearDown(service.dispose);
      final chat = service.attach(
        connection: SavedConnection(
          id: 'privacy-probe',
          label: 'Privacy probe',
          host: 'hermes.local',
          port: 8642,
          apiKey: 'probe-key',
        ),
        sessionId: 'sess-private',
        sessionTitle: 'Privacy probe',
        api: ApiClient(
          baseUrl: 'http://hermes.local:8642',
          apiKey: 'probe-key',
          httpClient: client,
        ),
      );
      chat.smoothStreaming = false;

      final done = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.done,
      );
      expect(
        await chat.send(
          fullText: 'PUBLIC_PROMPT',
          model: 'probe',
          history: const [],
        ),
        isTrue,
      );
      await done.timeout(const Duration(seconds: 5));

      final publicSurfaces = {
        'messages': jsonEncode(chat.messages),
        'narration': chat.assistantNarrationContent,
        'assistantContent': chat.assistantContent,
      };
      expect(publicSurfaces.toString(), isNot(contains(private)));
      expect(chat.assistantContent, public);
    },
  );
}
