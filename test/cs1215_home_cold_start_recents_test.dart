import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/cold_start_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cs1215_cold_start_store_test.dart' show MemoryColdStartStorage;
import 'support/in_memory_compression_restore_storage.dart';

/// A Gateway for Home: answers at once, or never ([hang]) like a phone
/// whose network is still coming up after a cold start.
final class _Gateway {
  _Gateway({this.hang = false, this.healthStatus = 200});

  final bool hang;
  final int healthStatus;
  final List<String> paths = [];
  int answered = 0;

  http.Client client() => MockClient((request) async {
    paths.add(request.url.path);
    if (hang) return Completer<http.Response>().future;
    answered += 1;
    switch (request.url.path) {
      case '/health':
        return http.Response('{"status":"ok"}', healthStatus);
      case '/api/sessions':
        return http.Response(
          jsonEncode({
            'data': [
              {
                'id': 's-recent',
                'title': 'Plan de la semana',
                'source': 'cli',
                'message_count': 4,
                'preview': 'revisar el despliegue',
                'started_at': 1790000000,
                'last_active': 1790000100,
              },
              {
                'id': 's-older',
                'title': 'Notas del viaje',
                'source': 'cli',
                'message_count': 2,
                'started_at': 1789990000,
                'last_active': 1789990100,
              },
            ],
            'has_more': false,
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
  ActiveChatService process(MemoryColdStartStorage storage) =>
      ActiveChatService(
        attachDesktopRuntimeOnLoad: false,
        compressionRestoreStore: testCompressionRestoreStore(),
        coldStartStore: ColdStartStore(storage: storage),
      );

  Future<void> pumpHome(
    WidgetTester tester, {
    required ConnectionManager manager,
    required ActiveChatService chats,
    required _Gateway gateway,
    required VoidCallback onReady,
    Future<DesktopActiveSessionList> Function()? activity,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: HomeDashboardScreen(
          connManager: manager,
          activeChatsOverride: chats,
          clientFactory: (conn) => ApiClient(
            baseUrl: conn.baseUrl,
            apiKey: conn.apiKey,
            httpClient: gateway.client(),
          ),
          dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
          onInitialLoadComplete: onReady,
          activeSessionListLoader: activity,
        ),
      ),
    );
  }

  Future<void> endProcess(WidgetTester tester, ActiveChatService chats) async {
    await tester.pumpWidget(const SizedBox.shrink());
    chats.dispose();
    await tester.pump(const Duration(seconds: 15));
  }

  /// Previous run: Home read its recents from a healthy server.
  Future<void> previousRun(
    WidgetTester tester,
    ConnectionManager manager,
    MemoryColdStartStorage storage,
  ) async {
    final chats = process(storage);
    var ready = false;
    await pumpHome(
      tester,
      manager: manager,
      chats: chats,
      gateway: _Gateway(),
      onReady: () => ready = true,
    );
    for (var i = 0; i < 40 && !ready; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Plan de la semana'), findsOneWidget);
    // Let the snapshot reach (fake) encrypted storage.
    await tester.pump(const Duration(milliseconds: 200));
    await endProcess(tester, chats);
  }

  testWidgets('a cold start paints the last known recents before any '
      'network request completes', (tester) async {
    final storage = MemoryColdStartStorage();
    final connManager = await manager(tester);
    await previousRun(tester, connManager, storage);

    // Cold start: the network never answers.
    final gateway = _Gateway(hang: true);
    final chats = process(storage);
    int? readyAtMs;
    var elapsed = 0;
    await pumpHome(
      tester,
      manager: connManager,
      chats: chats,
      gateway: gateway,
      onReady: () => readyAtMs ??= elapsed,
    );
    int? paintedAtMs;
    while (elapsed < 2000) {
      await tester.pump(const Duration(milliseconds: 20));
      elapsed += 20;
      if (paintedAtMs == null &&
          find.text('Plan de la semana').evaluate().isNotEmpty) {
        paintedAtMs = elapsed;
      }
    }
    // ignore: avoid_print
    print(
      'cs1215 home: cached recents at ${paintedAtMs}ms, '
      'initial load complete at ${readyAtMs}ms, '
      'network answered ${gateway.answered}',
    );
    expect(gateway.answered, 0);
    expect(gateway.paths, isNotEmpty, reason: 'the refresh still runs');
    expect(paintedAtMs, isNotNull);
    expect(find.text('Notas del viaje'), findsOneWidget);
    expect(readyAtMs, isNotNull, reason: 'the splash may leave');
    expect(find.byKey(const ValueKey('home-initial-loading')), findsNothing);
    await endProcess(tester, chats);
  });

  testWidgets('a server that turns out unreachable keeps the cached recents '
      'instead of an empty Home', (tester) async {
    final storage = MemoryColdStartStorage();
    final connManager = await manager(tester);
    await previousRun(tester, connManager, storage);

    final chats = process(storage);
    var ready = false;
    await pumpHome(
      tester,
      manager: connManager,
      chats: chats,
      gateway: _Gateway(healthStatus: 503),
      onReady: () => ready = true,
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(ready, isTrue);
    expect(find.text('offline · QA'), findsOneWidget);
    expect(find.text('Plan de la semana'), findsOneWidget);
    await endProcess(tester, chats);
  });

  testWidgets('the live activity roster does not hold the first paint', (
    tester,
  ) async {
    final storage = MemoryColdStartStorage();
    final connManager = await manager(tester);
    final chats = process(storage);
    final roster = Completer<DesktopActiveSessionList>();
    var activityAsked = false;
    var ready = false;
    await pumpHome(
      tester,
      manager: connManager,
      chats: chats,
      gateway: _Gateway(),
      activity: () {
        activityAsked = true;
        return roster.future;
      },
      onReady: () => ready = true,
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(activityAsked, isTrue);
    expect(ready, isTrue);
    expect(find.text('Plan de la semana'), findsOneWidget);
    await endProcess(tester, chats);
  });

  testWidgets('without a snapshot Home still waits for its first list '
      '(nothing invented)', (tester) async {
    final storage = MemoryColdStartStorage();
    final connManager = await manager(tester);
    final chats = process(storage);
    var ready = false;
    await pumpHome(
      tester,
      manager: connManager,
      chats: chats,
      gateway: _Gateway(hang: true),
      onReady: () => ready = true,
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(ready, isFalse);
    expect(find.byKey(const ValueKey('home-initial-loading')), findsOneWidget);
    await endProcess(tester, chats);
  });
}
