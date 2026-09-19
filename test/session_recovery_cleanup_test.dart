import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secure = <String, String>{};

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secure.clear();
    TurnOutboxStore.resetSerializationForTesting();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                secure[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                return secure[args['key'] as String];
              case 'delete':
                secure.remove(args['key'] as String);
                return null;
              case 'readAll':
                return Map<String, String>.from(secure);
            }
            return null;
          },
        );
  });

  Future<void> seedRecovery() async {
    final prefs = await SharedPreferences.getInstance();
    await ChatDraftStore(
      prefs,
    ).save('conn-cleanup', 'session-cleanup', 'privado', const []);
    final now = DateTime.now().millisecondsSinceEpoch;
    await TurnOutboxStore().save(
      PreparedTurn(
        connectionId: 'conn-cleanup',
        sessionId: 'session-cleanup',
        clientTurnId: 'turn-cleanup',
        createdAtMs: now,
        updatedAtMs: now,
        text: 'privado',
        attachments: const [],
        model: 'modelo',
        profile: '',
      ),
    );
  }

  ApiClient clientWithDeleted(bool deleted) => ApiClient(
    baseUrl: 'https://example.invalid',
    apiKey: 'test-only',
    connectionId: 'conn-cleanup',
    httpClient: MockClient(
      (_) async => http.Response(jsonEncode({'deleted': deleted}), 200),
    ),
  );

  test(
    'missing or mistyped delete evidence preserves local recovery',
    () async {
      await seedRecovery();
      for (final body in ['{}', '{"deleted":null}', '{"deleted":"true"}']) {
        final client = ApiClient(
          baseUrl: 'https://example.invalid',
          apiKey: 'test-only',
          connectionId: 'conn-cleanup',
          httpClient: MockClient((_) async => http.Response(body, 200)),
        );
        expect(await client.deleteSession('session-cleanup'), isFalse);
        client.close();
      }
      final prefs = await SharedPreferences.getInstance();
      expect(
        (await ChatDraftStore(
          prefs,
        ).load('conn-cleanup', 'session-cleanup')).text,
        'privado',
      );
    },
  );

  test('confirmación remota limpia draft y outbox locales', () async {
    await seedRecovery();
    final client = clientWithDeleted(true);

    expect(await client.deleteSession('session-cleanup'), isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(
      (await ChatDraftStore(
        prefs,
      ).load('conn-cleanup', 'session-cleanup')).text,
      isEmpty,
    );
    expect(
      await TurnOutboxStore().loadForChat('conn-cleanup', 'session-cleanup'),
      isNull,
    );
    client.close();
  });

  test(
    'named-profile delete clears only the exact duplicate session owner',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final drafts = ChatDraftStore(prefs);
      final outbox = TurnOutboxStore();
      await drafts.save(
        'conn-cleanup',
        'shared-session',
        'delete profile A',
        const [],
        profile: 'profile-a',
      );
      await drafts.save(
        'conn-cleanup',
        'shared-session',
        'keep profile B',
        const [],
        profile: 'profile-b',
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final owner in const ['profile-a', 'profile-b']) {
        await outbox.save(
          PreparedTurn(
            connectionId: 'conn-cleanup',
            sessionId: 'shared-session',
            clientTurnId: 'turn-$owner',
            createdAtMs: now,
            updatedAtMs: now,
            text: owner,
            attachments: const [],
            model: 'modelo',
            profile: owner,
          ),
        );
      }
      final client = clientWithDeleted(true);

      expect(
        await client.deleteSession('shared-session', profile: 'profile-a'),
        isTrue,
      );

      expect(
        (await drafts.load(
          'conn-cleanup',
          'shared-session',
          profile: 'profile-a',
        )).text,
        isEmpty,
      );
      expect(
        (await drafts.load(
          'conn-cleanup',
          'shared-session',
          profile: 'profile-b',
        )).text,
        'keep profile B',
      );
      expect(
        await outbox.loadForChat(
          'conn-cleanup',
          'shared-session',
          profile: 'profile-a',
        ),
        isNull,
      );
      expect(
        await outbox.loadForChat(
          'conn-cleanup',
          'shared-session',
          profile: 'profile-b',
        ),
        isNotNull,
      );
      client.close();
    },
  );

  test('rechazo remoto conserva la recuperación local', () async {
    await seedRecovery();
    final client = clientWithDeleted(false);

    expect(await client.deleteSession('session-cleanup'), isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(
      (await ChatDraftStore(
        prefs,
      ).load('conn-cleanup', 'session-cleanup')).text,
      'privado',
    );
    expect(
      await TurnOutboxStore().loadForChat('conn-cleanup', 'session-cleanup'),
      isNotNull,
    );
    client.close();
  });

  test('404 remoto se trata como borrado idempotente y limpia local', () async {
    await seedRecovery();
    final client = ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'test-only',
      connectionId: 'conn-cleanup',
      httpClient: MockClient((_) async => http.Response('not found', 404)),
    );

    expect(await client.deleteSession('session-cleanup'), isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(
      (await ChatDraftStore(
        prefs,
      ).load('conn-cleanup', 'session-cleanup')).text,
      isEmpty,
    );
    expect(
      await TurnOutboxStore().loadForChat('conn-cleanup', 'session-cleanup'),
      isNull,
    );
    client.close();
  });

  test(
    'un cuerpo de delete no parseable no se asume borrado y conserva la recuperación local',
    () async {
      // Bug real: un 200 con un cuerpo que no es el JSON esperado (proxy o
      // gateway a medio reiniciar) se daba por "borrado" sin evidencia,
      // anunciando éxito con la fila todavía viva en el servidor.
      await seedRecovery();
      final client = ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: 'test-only',
        connectionId: 'conn-cleanup',
        httpClient: MockClient((_) async => http.Response('<html>', 200)),
      );

      expect(await client.deleteSession('session-cleanup'), isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(
        (await ChatDraftStore(
          prefs,
        ).load('conn-cleanup', 'session-cleanup')).text,
        isNotEmpty,
      );
      expect(
        await TurnOutboxStore().loadForChat('conn-cleanup', 'session-cleanup'),
        isNotNull,
      );
      client.close();
    },
  );

  test('borrar conexión limpia toda su recuperación sin tocar otra', () async {
    SharedPreferences.setMockInitialValues({
      'saved_connections': [
        jsonEncode({
          'id': 'conn-cleanup',
          'label': 'Eliminar',
          'host': 'example.invalid',
          'port': 443,
          'use_https': true,
        }),
        jsonEncode({
          'id': 'conn-keep',
          'label': 'Conservar',
          'host': 'keep.invalid',
          'port': 443,
          'use_https': true,
        }),
      ],
    });
    final prefs = await SharedPreferences.getInstance();
    final drafts = ChatDraftStore(prefs);
    final outbox = TurnOutboxStore();
    await drafts.save('conn-cleanup', 'session-cleanup', 'privado', const []);
    await drafts.save('conn-keep', 'session-keep', 'conservar', const []);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final entry in const [
      ('conn-cleanup', 'session-cleanup', 'turn-cleanup'),
      ('conn-keep', 'session-keep', 'turn-keep'),
    ]) {
      await outbox.save(
        PreparedTurn(
          connectionId: entry.$1,
          sessionId: entry.$2,
          clientTurnId: entry.$3,
          createdAtMs: now,
          updatedAtMs: now,
          text: 'privado',
          attachments: const [],
          model: 'modelo',
          profile: '',
        ),
      );
    }

    final manager = await ConnectionManager.create(prefs);
    await manager.deleteConnection('conn-cleanup');

    expect(
      (await drafts.load('conn-cleanup', 'session-cleanup')).text,
      isEmpty,
    );
    expect(await outbox.loadForChat('conn-cleanup', 'session-cleanup'), isNull);
    expect((await drafts.load('conn-keep', 'session-keep')).text, 'conservar');
    expect(await outbox.loadForChat('conn-keep', 'session-keep'), isNotNull);
    expect(manager.getConnections().map((item) => item.id), ['conn-keep']);
  });
}
