import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/compression_restore_store.dart';

import 'support/desktop_chat_socket.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(const {}));

  ActiveChat attach(
    DesktopChatSocket socket, {
    required String sessionId,
    required String title,
    required StoredSessionMessageLoader loader,
  }) {
    final service = ActiveChatService(
      compressionRestoreStore: CompressionRestoreStore(
        storage: _MemoryCompressionFenceStorage(),
      ),
    );
    addTearDown(service.dispose);
    addTearDown(socket.close);
    return service.attach(
      connection: SavedConnection(
        id: 'probe-conn',
        label: title,
        host: 'hermes.local',
        port: 8642,
        apiKey: 'fixture',
      ),
      sessionId: sessionId,
      sessionTitle: title,
      desktopGateway: socket,
      storedMessageLoader: loader,
    )..smoothStreaming = false;
  }

  test('terminal transcript reconcile projects no tool arguments, tool results '
      'or unknown metadata', () async {
    final socket = DesktopChatSocket();
    final chat = attach(
      socket,
      sessionId: 'sess-1',
      title: 'Probe',
      loader: (_, _) async => [
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
    );

    final done = chat.changes.firstWhere((e) => e == ActiveChatEvent.done);
    expect(
      await chat.send(
        fullText: 'PUBLIC_PROMPT',
        model: 'probe',
        history: const [],
      ),
      isTrue,
    );
    socket.complete(1, 'PUBLIC_FINAL');
    await done.timeout(const Duration(seconds: 5));

    final published = jsonEncode(chat.messages);
    expect(published, contains('PUBLIC_PROMPT'));
    expect(published, contains('PUBLIC_FINAL'));
    // The Desktop transcript keeps the model's reasoning of the turn (it is
    // shown as the `reasoning` field and the activity trace, as in Desktop);
    // everything else of the stored rows stays out.
    final reasoningRows = chat.messages.where(
      (m) => jsonEncode(m).contains('PRIVATE_REASONING'),
    );
    expect(reasoningRows.map((m) => m['role']), ['assistant']);
    for (final forbidden in const [
      'PRIVATE_USER_METADATA',
      'PRIVATE_TOOL_ARGS',
      'PRIVATE_TOOL_RESULT',
      'PRIVATE_TOOL_METADATA',
      'PRIVATE_ANALYSIS',
      'PRIVATE_ASSISTANT_METADATA',
    ]) {
      expect(published, isNot(contains(forbidden)), reason: published);
    }
  });

  test('terminal answer publishes only the public text while the transcript is '
      'unavailable', () async {
    const private = 'PRIVATE_TERMINAL_REASONING_/home/owner/session.jsonl';
    const public = 'PUBLIC_FINAL';
    final socket = DesktopChatSocket();
    final chat = attach(
      socket,
      sessionId: 'sess-private',
      title: 'Privacy probe',
      loader: (_, _) async => throw StateError('not ready'),
    );

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
    socket.complete(1, '<think>$private</think>$public');
    await done.timeout(const Duration(seconds: 5));

    final publicSurfaces = {
      'messages': jsonEncode(chat.messages),
      'narration': chat.assistantNarrationContent,
      'assistantContent': chat.assistantContent,
    };
    expect(publicSurfaces.toString(), isNot(contains(private)));
    expect(chat.assistantContent, public);
  });
}
