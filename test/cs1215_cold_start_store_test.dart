import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/cold_start_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

/// In-memory stand-in for the Keystore-backed storage.
class MemoryColdStartStorage implements ColdStartStorage {
  final Map<String, String> values = {};
  int writes = 0;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    writes += 1;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

final _connection = SavedConnection(
  id: 'cold-a',
  label: 'cold-a',
  host: 'example.invalid',
  port: 443,
  apiKey: 'k',
  useHttps: true,
  kind: InstanceKind.vps,
);

List<Map<String, dynamic>> _rows(String tag, int count, {int size = 10}) => [
  for (var i = count; i >= 1; i--)
    {
      'id': i,
      'role': i.isOdd ? 'user' : 'assistant',
      'content': '$tag-$i ${'x' * size}',
    },
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ColdStartStore bounds', () {
    test('keeps the last 8 chats and the newest 120 rows of each', () async {
      final storage = MemoryColdStartStorage();
      final store = ColdStartStore(storage: storage);
      for (var i = 0; i < 10; i++) {
        await store.saveTail(
          connectionId: 'c',
          profile: 'default',
          storedSessionId: 's$i',
          routeSessionId: 's$i',
          aliases: {'s$i'},
          newestFirst: _rows('s$i', 200),
        );
      }
      final tails = await ColdStartStore(storage: storage).loadTails();
      expect(tails.map((t) => t.storedSessionId), [
        for (var i = 9; i >= 2; i--) 's$i',
      ]);
      expect(tails.first.newestFirst, hasLength(ColdStartStore.maxRows));
      // Newest rows, newest first.
      expect(tails.first.newestFirst.first['content'], startsWith('s9-200'));
      // Evicted tails are deleted from storage, not just unindexed.
      expect(
        storage.values.keys.where((k) => k.startsWith('cold_start_tail_v1.')),
        hasLength(8),
      );
    });

    test('total encrypted bytes stay under the budget', () async {
      final storage = MemoryColdStartStorage();
      final store = ColdStartStore(storage: storage);
      for (var i = 0; i < 8; i++) {
        await store.saveTail(
          connectionId: 'c',
          profile: 'default',
          storedSessionId: 'big$i',
          routeSessionId: 'big$i',
          aliases: {'big$i'},
          // ~1 MB per chat once capped.
          newestFirst: _rows('big$i', 120, size: 12000),
        );
      }
      final total = storage.values.entries
          .where((e) => e.key.startsWith('cold_start_tail_v1.'))
          .fold<int>(0, (sum, e) => sum + utf8.encode(e.value).length);
      expect(total, lessThanOrEqualTo(ColdStartStore.maxTotalBytes));
      final tails = await ColdStartStore(storage: storage).loadTails();
      expect(tails.first.storedSessionId, 'big7');
      expect(tails.length, lessThan(8));
    });

    test('an unchanged tail is not rewritten', () async {
      final storage = MemoryColdStartStorage();
      final store = ColdStartStore(storage: storage);
      Future<void> save() => store.saveTail(
        connectionId: 'c',
        profile: 'default',
        storedSessionId: 's',
        routeSessionId: 's',
        aliases: {'s'},
        newestFirst: _rows('s', 4),
      );
      await save();
      final tailWrites = storage.writes;
      await save();
      // Only the index (recency) is rewritten.
      expect(storage.writes, tailWrites + 1);
    });

    test('a corrupt index never blocks and is rebuilt', () async {
      final storage = MemoryColdStartStorage()
        ..values[ColdStartStore.indexKey] = '{corrupt';
      final store = ColdStartStore(storage: storage);
      expect(await store.loadTails(), isEmpty);
      expect(await store.routeFor('c'), isNull);
    });
  });

  group('ColdStartStore cleanup', () {
    Future<ColdStartStore> seeded(MemoryColdStartStorage storage) async {
      final store = ColdStartStore(storage: storage);
      for (final (conn, profile, id) in [
        ('c1', 'default', 'a'),
        ('c1', 'work', 'b'),
        ('c2', 'default', 'c'),
      ]) {
        await store.saveTail(
          connectionId: conn,
          profile: profile,
          storedSessionId: id,
          routeSessionId: 'route-$id',
          aliases: {id, 'route-$id'},
          newestFirst: _rows(id, 2),
        );
      }
      await store.rememberRoute(
        const ColdStartRoute(
          kind: ColdStartRouteKind.chat,
          connectionId: 'c1',
          profile: 'default',
          sessionId: 'a',
        ),
      );
      return store;
    }

    test('a deleted session loses its tail and its route', () async {
      final storage = MemoryColdStartStorage();
      final store = await seeded(storage);
      await store.forgetSession(
        connectionId: 'c1',
        profile: 'default',
        sessionId: 'route-a',
      );
      final fresh = ColdStartStore(storage: storage);
      expect((await fresh.loadTails()).map((t) => t.storedSessionId), [
        'c',
        'b',
      ]);
      expect(await fresh.routeFor('c1'), isNull);
    });

    test('a deleted connection loses everything it owned', () async {
      final storage = MemoryColdStartStorage();
      final store = await seeded(storage);
      await store.forgetScope('c1');
      final fresh = ColdStartStore(storage: storage);
      expect((await fresh.loadTails()).map((t) => t.connectionId), ['c2']);
      expect(await fresh.routeFor('c1'), isNull);
      expect(
        storage.values.keys.where((k) => k.startsWith('cold_start_tail_v1.')),
        hasLength(1),
      );
    });

    test('clearing a profile keeps the other profiles', () async {
      final storage = MemoryColdStartStorage();
      final store = await seeded(storage);
      await store.forgetScope('c1', profile: 'work');
      final fresh = ColdStartStore(storage: storage);
      expect((await fresh.loadTails()).map((t) => t.storedSessionId), [
        'c',
        'a',
      ]);
      expect((await fresh.routeFor('c1'))?.sessionId, 'a');
    });

    test('clearAll leaves nothing behind', () async {
      final storage = MemoryColdStartStorage();
      final store = await seeded(storage);
      await store.clearAll();
      expect(storage.values, isEmpty);
    });
  });

  group('encryption at rest', () {
    test('chat content goes only through flutter_secure_storage, never to '
        'SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final secure = <String, String>{};
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
              final args = (call.arguments as Map?) ?? {};
              switch (call.method) {
                case 'read':
                  return secure[args['key']];
                case 'write':
                  secure[args['key'] as String] = args['value'] as String;
                case 'delete':
                  secure.remove(args['key']);
              }
              return null;
            },
          );
      final store = ColdStartStore();
      await store.saveTail(
        connectionId: 'c',
        profile: 'default',
        storedSessionId: 's',
        routeSessionId: 's',
        aliases: {'s'},
        newestFirst: [
          {'id': 1, 'role': 'assistant', 'content': 'secreto-del-chat'},
        ],
      );
      expect(secure.values.any((v) => v.contains('secreto-del-chat')), isTrue);
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        expect('${prefs.get(key)}', isNot(contains('secreto-del-chat')));
      }
    });
  });

  group('ActiveChatService cold start', () {
    ApiClient unusedApi() => ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'k',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    );

    test('a new process paints the persisted tail of a released chat, marked '
        'as cached, and the server read replaces it', () async {
      final storage = MemoryColdStartStorage();
      final first = ActiveChatService(
        attachDesktopRuntimeOnLoad: false,
        compressionRestoreStore: testCompressionRestoreStore(),
        coldStartStore: ColdStartStore(storage: storage),
      );
      final chat = first.attach(
        connection: _connection,
        sessionId: 'stored-1',
        sessionTitle: 'Chat',
        api: unusedApi(),
        storedMessageLoader: (_, _) async => [
          {'id': 1, 'role': 'user', 'content': 'pregunta guardada'},
          {'id': 2, 'role': 'assistant', 'content': 'respuesta guardada'},
        ],
        disableForegroundKeepAlive: true,
      );
      await chat.loadMessages(expectedMessageCount: 2);
      first.release(_connection.id, 'stored-1');
      await Future<void>.delayed(Duration.zero);
      first.dispose();

      // Process killed; a new one starts with an empty memory cache.
      final second = ActiveChatService(
        attachDesktopRuntimeOnLoad: false,
        compressionRestoreStore: testCompressionRestoreStore(),
        coldStartStore: ColdStartStore(storage: storage),
      );
      addTearDown(second.dispose);
      expect(await second.coldStartTailsReady, 1);
      final network = <List<Map<String, dynamic>>>[];
      final reopened = second.attach(
        connection: _connection,
        sessionId: 'stored-1',
        sessionTitle: 'Chat',
        api: unusedApi(),
        storedMessageLoader: (_, _) async => network.removeAt(0),
        disableForegroundKeepAlive: true,
      );
      expect(reopened.messages.map((m) => m['content']), [
        'respuesta guardada',
        'pregunta guardada',
      ]);
      expect(reopened.showingCachedTranscript, isTrue);
      expect(reopened.messagesLoaded, isFalse);

      network.add([
        {'id': 1, 'role': 'user', 'content': 'pregunta guardada'},
        {'id': 2, 'role': 'assistant', 'content': 'respuesta guardada'},
        {'id': 3, 'role': 'user', 'content': 'nueva desde Desktop'},
        {'id': 4, 'role': 'assistant', 'content': 'respuesta nueva'},
      ]);
      await reopened.loadMessages(expectedMessageCount: 4);
      expect(reopened.showingCachedTranscript, isFalse);
      expect(reopened.messages.map((m) => m['content']), [
        'respuesta nueva',
        'nueva desde Desktop',
        'respuesta guardada',
        'pregunta guardada',
      ]);
    });

    test('a session deleted elsewhere is never painted from the cache after '
        'its deletion was confirmed', () async {
      final storage = MemoryColdStartStorage();
      final store = ColdStartStore(storage: storage);
      await store.saveTail(
        connectionId: _connection.id,
        profile: 'default',
        storedSessionId: 'gone',
        routeSessionId: 'gone',
        aliases: {'gone'},
        newestFirst: _rows('gone', 2),
      );
      final service = ActiveChatService(
        attachDesktopRuntimeOnLoad: false,
        compressionRestoreStore: testCompressionRestoreStore(),
        coldStartStore: ColdStartStore(storage: storage),
      );
      addTearDown(service.dispose);
      await service.coldStartTailsReady;
      await service.clearCancelledTurnsForSession(
        connectionId: _connection.id,
        profile: 'default',
        sessionId: 'gone',
      );
      final reopened = service.attach(
        connection: _connection,
        sessionId: 'gone',
        sessionTitle: 'Chat',
        api: unusedApi(),
        storedMessageLoader: (_, _) async => const [],
        disableForegroundKeepAlive: true,
      );
      expect(reopened.messages, isEmpty);
      expect(await ColdStartStore(storage: storage).loadTails(), isEmpty);
    });

    test('a streaming or unloaded chat is never persisted', () async {
      final storage = MemoryColdStartStorage();
      final service = ActiveChatService(
        attachDesktopRuntimeOnLoad: false,
        compressionRestoreStore: testCompressionRestoreStore(),
        coldStartStore: ColdStartStore(storage: storage),
      );
      addTearDown(service.dispose);
      service.attach(
        connection: _connection,
        sessionId: 'never-loaded',
        sessionTitle: 'Chat',
        api: unusedApi(),
        storedMessageLoader: (_, _) async => const [],
        disableForegroundKeepAlive: true,
      );
      service.persistColdStartTails();
      service.release(_connection.id, 'never-loaded');
      await Future<void>.delayed(Duration.zero);
      expect(await ColdStartStore(storage: storage).loadTails(), isEmpty);
    });
  });
}
