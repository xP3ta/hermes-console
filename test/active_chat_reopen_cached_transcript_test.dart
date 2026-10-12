import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';

final _connection = SavedConnection(
  id: 'reopen-cache',
  label: 'reopen-cache',
  host: 'example.invalid',
  port: 443,
  apiKey: 'test-key',
  useHttps: true,
  kind: InstanceKind.vps,
);

ApiClient _unusedApi() => ApiClient(
  baseUrl: 'https://example.invalid',
  apiKey: 'test-key',
  httpClient: MockClient((_) async => http.Response('unused', 500)),
);

const _rows = <Map<String, dynamic>>[
  {'id': 1, 'role': 'user', 'content': 'pregunta guardada'},
  {'id': 2, 'role': 'assistant', 'content': 'respuesta guardada'},
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ActiveChatService service;

  setUp(() {
    service = ActiveChatService(
      attachDesktopRuntimeOnLoad: false,
      compressionRestoreStore: testCompressionRestoreStore(),
    );
  });

  tearDown(() => service.dispose());

  ActiveChat attach({
    required StoredSessionMessageLoader loader,
    String sessionId = 'stored-reopen',
    String? initialStoredSessionId,
  }) => service.attach(
    connection: _connection,
    sessionId: sessionId,
    sessionTitle: 'Reopen',
    initialStoredSessionId: initialStoredSessionId,
    api: _unusedApi(),
    storedMessageLoader: loader,
    disableForegroundKeepAlive: true,
  );

  Future<void> openAndClose({String sessionId = 'stored-reopen'}) async {
    final first = attach(
      sessionId: sessionId,
      loader: (_, _) async => List.of(_rows),
    );
    await first.loadMessages(expectedMessageCount: 2);
    expect(first.messages, hasLength(2));
    service.release(_connection.id, sessionId);
    expect(service.of(_connection.id, sessionId), isNull);
  }

  test('reopening a released chat shows its last transcript before the '
      'slow network read completes', () async {
    await openAndClose();

    final slowNetwork = Completer<List<Map<String, dynamic>>>();
    final reopened = attach(loader: (_, _) => slowNetwork.future);
    final loading = reopened.loadMessages(expectedMessageCount: 2);
    await Future<void>.delayed(Duration.zero);

    expect(reopened.messages.map((m) => m['content']), [
      'respuesta guardada',
      'pregunta guardada',
    ]);

    slowNetwork.complete([
      ..._rows,
      {'id': 3, 'role': 'user', 'content': 'nueva desde otra superficie'},
      {'id': 4, 'role': 'assistant', 'content': 'respuesta nueva'},
    ]);
    await loading;
    expect(reopened.messages.first['content'], 'respuesta nueva');
    expect(reopened.messages, hasLength(4));
  });

  test('a deleted session is not shown from the reopen cache', () async {
    await openAndClose();
    await service.clearCancelledTurnsForSession(
      connectionId: _connection.id,
      profile: '',
      sessionId: 'stored-reopen',
    );

    final reopened = attach(
      loader: (_, _) => Completer<List<Map<String, dynamic>>>().future,
    );
    expect(reopened.messages, isEmpty);
  });

  test('a different durable identity does not reuse the cached rows', () async {
    await openAndClose();

    final reopened = attach(
      initialStoredSessionId: 'stored-rotated',
      loader: (_, _) => Completer<List<Map<String, dynamic>>>().future,
    );
    expect(reopened.messages, isEmpty);
  });

  Future<void> openAndCloseWith(
    String sessionId,
    List<Map<String, dynamic>> rows,
  ) async {
    final chat = attach(sessionId: sessionId, loader: (_, _) async => rows);
    await chat.loadMessages(expectedMessageCount: rows.length);
    service.release(_connection.id, sessionId);
  }

  bool cachedOnReopen(String sessionId) {
    final reopened = attach(
      sessionId: sessionId,
      loader: (_, _) => Completer<List<Map<String, dynamic>>>().future,
    );
    final cached = reopened.messages.isNotEmpty;
    service.debugDisposeChatForTesting(_connection.id, sessionId);
    return cached;
  }

  test('co1215 the warm cache keeps the last 24 released chats', () async {
    for (var i = 0; i < 25; i++) {
      await openAndCloseWith('chat-$i', List.of(_rows));
    }
    expect(service.reopenTranscriptCountForTesting, 24);
    // Probe newest first: each probe re-caches the probed chat.
    expect(cachedOnReopen('chat-24'), isTrue);
    expect(cachedOnReopen('chat-1'), isTrue);
    expect(cachedOnReopen('chat-0'), isFalse);
  });

  test(
    'co1215 reopening a chat refreshes its recency in the warm cache',
    () async {
      for (var i = 0; i < 24; i++) {
        await openAndCloseWith('chat-$i', List.of(_rows));
      }
      // chat-0 is used again, so chat-1 becomes the least recently used.
      await openAndCloseWith('chat-0', List.of(_rows));
      await openAndCloseWith('chat-24', List.of(_rows));
      expect(service.reopenTranscriptCountForTesting, 24);
      expect(cachedOnReopen('chat-0'), isTrue);
      expect(cachedOnReopen('chat-1'), isFalse);
    },
  );

  test(
    'co1215 the warm cache evicts least recently used chats by bytes',
    () async {
      // ~4 MB per transcript: 200 rows × ~10 KB.
      List<Map<String, dynamic>> heavy(String tag) => [
        for (var i = 1; i <= 200; i++)
          {
            'id': i,
            'role': i.isOdd ? 'user' : 'assistant',
            'content': '$tag ${'x' * 10000}',
          },
      ];
      for (var i = 0; i < 12; i++) {
        await openAndCloseWith('heavy-$i', heavy('h$i'));
      }
      expect(
        service.reopenTranscriptBytesForTesting,
        lessThanOrEqualTo(ActiveChatService.reopenTranscriptCacheMaxBytes),
      );
      expect(service.reopenTranscriptCountForTesting, lessThan(12));
      expect(service.reopenTranscriptCountForTesting, greaterThan(0));
      expect(cachedOnReopen('heavy-11'), isTrue);
      expect(cachedOnReopen('heavy-0'), isFalse);
    },
  );
  test(
    'xr1215 the warm cache weighs nested tool payloads, not only content',
    () async {
      // ~4 MB per transcript lives in tool outputs, which the chat folds
      // into the assistant row as a nested `_activity_tool_results` list.
      // Top-level content is a few bytes, so an estimate that read only
      // `content` would keep all twelve (~48 MB) past the 32 MB budget.
      List<Map<String, dynamic>> nested(String tag) => [
        for (var i = 1; i <= 100; i++) ...[
          {'id': i * 3 - 2, 'role': 'user', 'content': '$tag q$i'},
          {
            'id': i * 3 - 1,
            'role': 'assistant',
            'content': '$tag a$i',
            'tool_calls': [
              {
                'id': 'call-$tag-$i',
                'type': 'function',
                'function': {'name': 'read_file', 'arguments': '{}'},
              },
            ],
          },
          {
            'id': i * 3,
            'role': 'tool',
            'tool_call_id': 'call-$tag-$i',
            'content': '$tag ${'y' * 20000}',
          },
        ],
      ];
      for (var i = 0; i < 12; i++) {
        await openAndCloseWith('nested-$i', nested('n$i'));
      }
      expect(
        service.reopenTranscriptBytesForTesting,
        lessThanOrEqualTo(ActiveChatService.reopenTranscriptCacheMaxBytes),
      );
      // Each retained transcript really holds ~4 MB of nested tool output.
      expect(
        service.reopenTranscriptBytesForTesting,
        greaterThan(service.reopenTranscriptCountForTesting * 3 * 1024 * 1024),
      );
      expect(service.reopenTranscriptCountForTesting, lessThan(12));
      expect(service.reopenTranscriptCountForTesting, greaterThan(0));
      expect(cachedOnReopen('nested-11'), isTrue);
      expect(cachedOnReopen('nested-0'), isFalse);
    },
  );
}
