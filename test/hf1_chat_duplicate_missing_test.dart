import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';
import 'support/recording_desktop_gateway.dart';

class _Gateway extends RecordingDesktopGateway {
  DesktopSessionSnapshot? snapshot;

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async =>
      snapshot ??
      await super.resumeExisting(
        storedSessionId,
        profile: profile,
        omitMessages: omitMessages,
        deferHistory: deferHistory,
      );
}

/// The existing transcript fake's latest-offset contract, with distinct
/// durable identities/timestamps and no invented total/has_more fields.
class _Store {
  final rows = <Map<String, dynamic>>[];
  final reads = <Uri>[];
  int status = 200;
  bool legacy = false;

  void addTurn(String prompt, String answer) {
    final timestamp = DateTime.now().millisecondsSinceEpoch / 1000 - 0.25;
    for (final entry in [
      (role: 'user', text: prompt),
      (role: 'assistant', text: answer),
    ]) {
      final id = rows.length + 1;
      rows.add({
        'id': id,
        'message_id': 'durable-$id',
        'role': entry.role,
        'content': entry.text,
        'timestamp': timestamp + id / 1000,
      });
    }
  }

  http.Client client() => MockClient((request) async {
    if (!request.url.path.endsWith('/messages')) {
      return http.Response('{}', 200);
    }
    reads.add(request.url);
    if (status != 200) return http.Response('unavailable', status);
    if (legacy) {
      return http.Response(
        jsonEncode({'messages': rows}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    final limit = int.parse(request.url.queryParameters['limit'] ?? '120');
    final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
    final end = math.max(0, rows.length - offset);
    final page = rows.sublist(math.max(0, end - limit), end);
    return http.Response(
      jsonEncode({
        'session_id': 'session-live',
        'messages': page,
        'pagination': {
          'limit': limit,
          'offset': offset,
          'order': 'latest',
          'returned': page.length,
        },
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

ActiveChat _chat(_Store store, _Gateway gateway, {bool fresh = false}) {
  final chat = ActiveChat(
    connection: SavedConnection(
      id: 'hf1-test',
      label: 'HF1 test',
      host: 'example.invalid',
      port: 443,
      apiKey: 'test-only',
      useHttps: true,
      kind: InstanceKind.vps,
    ),
    sessionId: fresh ? 'mobile-draft' : 'session-live',
    sessionTitle: 'Transcript regression',
    notifications: null,
    onTerminal: () {},
    api: ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'test-only',
      httpClient: store.client(),
    ),
    desktopGateway: gateway,
    allowUnownedDesktopSnapshotForTesting: true,
    compressionRestoreStore: testCompressionRestoreStore(),
  );
  addTearDown(chat.dispose);
  return chat;
}

Future<void> _turn(
  ActiveChat chat,
  _Gateway gateway,
  _Store store,
  String prompt,
  String answer,
) async {
  expect(
    await chat.send(
      fullText: prompt,
      model: 'hermes-agent',
      history: chat.buildHistory(),
    ),
    isTrue,
  );
  store.addTurn(prompt, answer);
  final done = chat.changes
      .firstWhere((event) => event == ActiveChatEvent.done)
      .timeout(const Duration(seconds: 5));
  gateway.emit('message.complete', {'text': answer});
  await done;
  // done publishes the terminal text before its asynchronous REST repair.
  await Future<void>.delayed(Duration.zero);
  expect(chat.state, ChatPipelineState.completed);
}

List<String> _contents(ActiveChat chat) => [
  for (final row in chat.messages.reversed) '${row['role']}: ${row['content']}',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'HF1 two new-chat turns are replaced by their durable rows once',
    () async {
      final store = _Store();
      final gateway = _Gateway();
      final chat = _chat(store, gateway, fresh: true)
        ..markStoredSessionMissing();
      await _turn(chat, gateway, store, 'Hello', 'Hello back');
      expect(_contents(chat), ['user: Hello', 'assistant: Hello back']);
      await _turn(chat, gateway, store, 'New message', 'New reply');
      await chat.reconcileAfterResume();
      expect(_contents(chat), [
        'user: Hello',
        'assistant: Hello back',
        'user: New message',
        'assistant: New reply',
      ]);
      expect(chat.messages.map((row) => row['message_id']).toSet(), {
        'durable-1',
        'durable-2',
        'durable-3',
        'durable-4',
      });
      expect(chat.hasEarlierMessages, isFalse);
      expect(chat.earlierMessagesLoadFailed, isFalse);
    },
  );

  test(
    'HF1 identical legitimate prompts and replies remain separate turns',
    () async {
      final store = _Store();
      final gateway = _Gateway();
      final chat = _chat(store, gateway, fresh: true)
        ..markStoredSessionMissing();
      await _turn(chat, gateway, store, 'Same prompt', 'Same reply');
      await _turn(chat, gateway, store, 'Same prompt', 'Same reply');
      expect(_contents(chat), [
        'user: Same prompt',
        'assistant: Same reply',
        'user: Same prompt',
        'assistant: Same reply',
      ]);
      await chat.reconcileAfterResume();
      expect(_contents(chat), [
        'user: Same prompt',
        'assistant: Same reply',
        'user: Same prompt',
        'assistant: Same reply',
      ]);
      expect(chat.messages.map((row) => row['message_id']).toSet(), {
        'durable-1',
        'durable-2',
        'durable-3',
        'durable-4',
      });
    },
  );

  test(
    'HF1 a continued short transcript does not offer nonexistent earlier history',
    () async {
      final store = _Store()..addTurn('External prompt', 'External reply');
      final gateway = _Gateway()
        ..snapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-live',
          storedSessionId: 'session-live',
          created: false,
          messagesProvided: false,
          messageCount: 2,
        );
      final chat = _chat(store, gateway);
      await chat.loadMessages(expectedMessageCount: 2);
      await _turn(chat, gateway, store, 'New message', 'New reply');
      expect(_contents(chat), [
        'user: External prompt',
        'assistant: External reply',
        'user: New message',
        'assistant: New reply',
      ]);
      expect(chat.hasEarlierMessages, isFalse);
      store.status = 404;
      final reads = store.reads.length;
      expect(await chat.loadEarlierMessages(), isFalse);
      expect(store.reads, hasLength(reads));
      expect(chat.earlierMessagesLoadFailed, isFalse);
    },
  );

  for (final delayedFirstTurnOnly in [true, false]) {
    test('HF1 late persistence across two new turns reconciles once '
        '(first only: $delayedFirstTurnOnly)', () async {
      final store = _Store()..status = 404;
      final gateway = _Gateway();
      final chat = _chat(store, gateway, fresh: true)
        ..markStoredSessionMissing();
      await _turn(chat, gateway, store, 'Hello', 'Hello back');
      if (delayedFirstTurnOnly) store.status = 200;
      await _turn(chat, gateway, store, 'New message', 'New reply');
      store.status = 200;
      // Exercise the same page-graft repair used by the earlier-history UI.
      if (chat.hasEarlierMessages) await chat.loadEarlierMessages();
      await chat.reconcileAfterResume();
      expect(_contents(chat), [
        'user: Hello',
        'assistant: Hello back',
        'user: New message',
        'assistant: New reply',
      ]);
      expect(chat.messages.map((row) => row['message_id']).toSet(), {
        'durable-1',
        'durable-2',
        'durable-3',
        'durable-4',
      });
      expect(chat.hasEarlierMessages, isFalse);
      expect(chat.earlierMessagesLoadFailed, isFalse);
    });
  }

  test(
    'HF1 a complete resume retires an already repaired earlier-page error',
    () async {
      final store = _Store();
      for (var turn = 0; turn < 120; turn++) {
        store.addTurn('Stored prompt $turn', 'Stored reply $turn');
      }
      final gateway = _Gateway()
        ..snapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-live',
          storedSessionId: 'session-live',
          created: false,
          messagesProvided: false,
          messageCount: 240,
        );
      final chat = _chat(store, gateway);
      await chat.loadMessages(expectedMessageCount: 240);
      expect(chat.messages, hasLength(120));
      expect(chat.hasEarlierMessages, isTrue);
      store.status = 503;
      expect(await chat.loadEarlierMessages(), isFalse);
      expect(chat.earlierMessagesLoadFailed, isTrue);
      store.status = 200;
      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-live',
        storedSessionId: 'session-live',
        created: false,
        messagesProvided: true,
        messageCount: 240,
        messages: store.rows
            .map((row) => DesktopSessionMessage.tryParse(row)!)
            .toList(),
      );
      await chat.loadMessages(expectedMessageCount: 240);
      expect(chat.messages, hasLength(240));
      expect(chat.hasEarlierMessages, isFalse);
      expect(chat.earlierMessagesLoadFailed, isFalse);
    },
  );

  test(
    'HF1 real earlier pages remain reachable and a partial refresh keeps their error',
    () async {
      final store = _Store();
      for (var turn = 0; turn < 120; turn++) {
        store.addTurn('Stored prompt $turn', 'Stored reply $turn');
      }
      final gateway = _Gateway()
        ..snapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-live',
          storedSessionId: 'session-live',
          created: false,
          messagesProvided: false,
          messageCount: 240,
        );
      final chat = _chat(store, gateway);
      await chat.loadMessages(expectedMessageCount: 240);
      store.status = 503;
      expect(await chat.loadEarlierMessages(), isFalse);
      store.status = 200;
      await chat.reconcileAfterResume();
      expect(chat.hasEarlierMessages, isTrue);
      expect(chat.earlierMessagesLoadFailed, isTrue);
      expect(chat.messages, hasLength(120));
      for (var page = 0; page < 5 && chat.hasEarlierMessages; page++) {
        await chat.loadEarlierMessages();
      }
      expect(chat.messages, hasLength(240));
      expect(chat.hasEarlierMessages, isFalse);
      expect(chat.earlierMessagesLoadFailed, isFalse);
      expect(
        store.reads.map((uri) => uri.queryParameters['offset']),
        containsAllInOrder(['0', '0', '120', '240']),
      );
      expect(
        chat.messages.map((row) => row['message_id']).toSet(),
        hasLength(240),
      );
    },
  );

  test(
    'HF1 a complete REST repair clears an earlier failure instead of keeping Messages missing',
    () async {
      final store = _Store();
      for (var turn = 0; turn < 120; turn++) {
        store.addTurn('Stored prompt $turn', 'Stored reply $turn');
      }
      final gateway = _Gateway()
        ..snapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-live',
          storedSessionId: 'session-live',
          created: false,
          messagesProvided: false,
          messageCount: 240,
        );
      final chat = _chat(store, gateway);
      await chat.loadMessages(expectedMessageCount: 240);
      store.status = 503;
      expect(await chat.loadEarlierMessages(), isFalse);
      expect(chat.earlierMessagesLoadFailed, isTrue);
      store
        ..status = 200
        ..legacy = true;
      await chat.reconcileAfterResume();
      expect(chat.messages, hasLength(240));
      expect(chat.hasEarlierMessages, isFalse);
      expect(chat.earlierMessagesLoadFailed, isFalse);
    },
  );
}
