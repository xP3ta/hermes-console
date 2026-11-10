// The Chats list on a cold start: what the last run left on disk is on screen
// before the server answers, and gives way to the server's list when it does.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/cache_settings.dart';
import 'package:hermes_android/core/services/cold_start_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cs1215_cold_start_store_test.dart' show MemoryColdStartStorage;
import 'support/in_memory_compression_restore_storage.dart';
import 'support/test_api_client.dart';

/// A Dashboard that answers at once, or never ([hang]).
final class _Gateway {
  _Gateway({this.hang = false, this.titles = const ['Plan de la semana']});

  final bool hang;
  final List<String> titles;

  http.Client client() => MockClient((request) async {
    if (hang) return Completer<http.Response>().future;
    switch (request.url.path) {
      case '/api/status':
        return http.Response('{"status":"ok"}', 200);
      case '/api/sessions':
        return http.Response(
          jsonEncode({
            'sessions': [
              for (var i = 0; i < titles.length; i++)
                {
                  'id': 's$i-${titles[i].hashCode}',
                  'title': titles[i],
                  'source': 'cli',
                  'message_count': 4,
                  'preview': 'vista $i',
                  'started_at': 1790000000 - i,
                  'last_active': 1790000100 - i,
                },
            ],
            'total': titles.length,
          }),
          200,
        );
    }
    return http.Response('{}', 404);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final secure = <String, String>{};
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
          final args = (call.arguments as Map?) ?? const {};
          switch (call.method) {
            case 'read':
              return secure[args['key']];
            case 'write':
              secure[args['key'] as String] = args['value'] as String;
            case 'delete':
              secure.remove(args['key']);
            case 'readAll':
              return Map<String, String>.from(secure);
            case 'containsKey':
              return secure.containsKey(args['key']);
          }
          return null;
        });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  Future<ConnectionManager> manager(WidgetTester tester) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = (await tester.runAsync(
      () => ConnectionManager.create(prefs),
    ))!;
    await tester.runAsync(
      () => manager.saveConnection(
        'QA',
        '127.0.0.2',
        8642,
        'test-key',
        kind: InstanceKind.vps,
      ),
    );
    await tester.runAsync(
      () => manager.setActiveConnection(manager.getConnections().single.id),
    );
    return manager;
  }

  /// One process: a fresh [ActiveChatService] over the persisted [storage].
  ActiveChatService process(
    MemoryColdStartStorage storage,
    CacheSettings settings,
  ) => ActiveChatService(
    attachDesktopRuntimeOnLoad: false,
    compressionRestoreStore: testCompressionRestoreStore(),
    coldStartStore: ColdStartStore(storage: storage, settings: settings),
  );

  Future<void> pumpList(
    WidgetTester tester, {
    required ConnectionManager manager,
    required ActiveChatService chats,
    required _Gateway gateway,
  }) async {
    final connection = manager.getConnections().single;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: SessionListScreen(
          connection: connection,
          connManager: manager,
          activeChatsOverride: chats,
          clientOverride: testApiClient(
            baseUrl: connection.baseUrl,
            httpClient: gateway.client(),
          ),
        ),
      ),
    );
  }

  Future<void> endProcess(WidgetTester tester, ActiveChatService chats) async {
    await tester.pumpWidget(const SizedBox.shrink());
    chats.dispose();
    await tester.pump(const Duration(seconds: 15));
  }

  /// Previous run: the list was read from a healthy server.
  Future<void> previousRun(
    WidgetTester tester,
    ConnectionManager manager,
    MemoryColdStartStorage storage,
    CacheSettings settings,
  ) async {
    final chats = process(storage, settings);
    await pumpList(
      tester,
      manager: manager,
      chats: chats,
      gateway: _Gateway(titles: const ['Plan de la semana', 'Notas del viaje']),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Plan de la semana'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    await endProcess(tester, chats);
  }

  testWidgets('a cold start paints the last Chats list while the server '
      'does not answer', (tester) async {
    final storage = MemoryColdStartStorage();
    final settings = CacheSettings(await SharedPreferences.getInstance());
    final connManager = await manager(tester);
    await previousRun(tester, connManager, storage, settings);
    expect(
      storage.values.keys.where((k) => k.startsWith('cold_start_list_v1.')),
      hasLength(1),
    );

    final chats = process(storage, settings);
    await pumpList(
      tester,
      manager: connManager,
      chats: chats,
      gateway: _Gateway(hang: true),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(find.text('Plan de la semana'), findsOneWidget);
    expect(find.text('Notas del viaje'), findsOneWidget);
    await endProcess(tester, chats);
  });

  testWidgets('the server list replaces the cold one when it lands', (
    tester,
  ) async {
    final storage = MemoryColdStartStorage();
    final settings = CacheSettings(await SharedPreferences.getInstance());
    final connManager = await manager(tester);
    await previousRun(tester, connManager, storage, settings);

    final chats = process(storage, settings);
    await pumpList(
      tester,
      manager: connManager,
      chats: chats,
      gateway: _Gateway(titles: const ['Chat nuevo']),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Chat nuevo'), findsOneWidget);
    expect(find.text('Plan de la semana'), findsNothing);
    expect(find.text('Notas del viaje'), findsNothing);
    await endProcess(tester, chats);
  });

  testWidgets('with Chat list off nothing is painted before the server', (
    tester,
  ) async {
    final storage = MemoryColdStartStorage();
    final settings = CacheSettings(await SharedPreferences.getInstance());
    final connManager = await manager(tester);
    await previousRun(tester, connManager, storage, settings);

    await settings.setChatList(false);
    final chats = process(storage, settings);
    await pumpList(
      tester,
      manager: connManager,
      chats: chats,
      gateway: _Gateway(hang: true),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(find.text('Plan de la semana'), findsNothing);
    await endProcess(tester, chats);
  });

  testWidgets('with Chat list off a healthy run saves nothing', (tester) async {
    final storage = MemoryColdStartStorage();
    final settings = CacheSettings(await SharedPreferences.getInstance());
    await settings.setChatList(false);
    final connManager = await manager(tester);
    final chats = process(storage, settings);
    await pumpList(
      tester,
      manager: connManager,
      chats: chats,
      gateway: _Gateway(),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Plan de la semana'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      storage.values.keys.where((k) => k.startsWith('cold_start_list_v1.')),
      isEmpty,
    );
    await endProcess(tester, chats);
  });
}
