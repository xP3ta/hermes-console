import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/lock_screen.dart';
import 'package:hermes_android/core/services/app_lock.dart';
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

/// Encrypted storage whose next Home recents read waits for [release],
/// like a slow Keystore decrypt.
final class _GatedRecentsStorage extends MemoryColdStartStorage {
  Completer<void>? gate;
  int recentsReads = 0;

  void holdNextRecentsRead() => gate = Completer<void>();

  void release() => gate?.complete();

  @override
  Future<String?> read(String key) async {
    if (key.startsWith('cold_start_recents_v1.')) {
      recentsReads += 1;
      final held = gate;
      if (held != null) {
        await held.future;
        gate = null;
      }
    }
    return super.read(key);
  }
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
    AppLockService? lock,
  }) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        locale: const Locale('en'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        builder: lock == null
            ? null
            : (context, child) => AppLockGate(
                lock: lock,
                navigatorKey: navigatorKey,
                child: child!,
              ),
        home: HomeDashboardScreen(
          appLockOverride: lock,
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

  /// An App Lock that is on (and therefore locked at launch).
  Future<AppLockService> appLock(WidgetTester tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('app_lock_enabled', true);
    final lock = AppLockService(prefs);
    await tester.pump();
    return lock;
  }

  /// Cached rows anywhere in the tree, under the lock screen included.
  Finder cachedRow() => find.text('Plan de la semana', skipOffstage: false);

  testWidgets('a locked cold start paints no cached recents; unlocking '
      'paints them without a second network read', (tester) async {
    final storage = _GatedRecentsStorage();
    final connManager = await manager(tester);
    await previousRun(tester, connManager, storage);

    final lock = await appLock(tester);
    expect(lock.locked.value, isTrue);
    final reads = storage.recentsReads;
    final gateway = _Gateway(hang: true);
    final chats = process(storage);
    var ready = false;
    await pumpHome(
      tester,
      manager: connManager,
      chats: chats,
      gateway: gateway,
      lock: lock,
      onReady: () => ready = true,
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(cachedRow(), findsNothing);
    expect(storage.recentsReads, reads, reason: 'nothing decrypted locked');
    expect(ready, isFalse);
    expect(gateway.answered, 0);
    final requests = gateway.paths.length;
    expect(requests, isNonZero, reason: 'the refresh runs under the lock');

    lock.unlock();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(cachedRow(), findsOneWidget);
    expect(find.text('Notas del viaje'), findsOneWidget);
    expect(ready, isTrue, reason: 'the splash leaves over the cached rows');
    expect(gateway.paths.length, requests, reason: 'no duplicate request');
    await endProcess(tester, chats);
  });

  testWidgets('App Lock engaged while the snapshot is decrypting: the rows '
      'are discarded, then painted after unlock', (tester) async {
    final storage = _GatedRecentsStorage();
    final connManager = await manager(tester);
    await previousRun(tester, connManager, storage);

    final lock = await appLock(tester);
    lock.unlock();
    storage.holdNextRecentsRead();
    final reads = storage.recentsReads;
    final gateway = _Gateway(hang: true);
    final chats = process(storage);
    var ready = false;
    await pumpHome(
      tester,
      manager: connManager,
      chats: chats,
      gateway: gateway,
      lock: lock,
      onReady: () => ready = true,
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(storage.recentsReads, reads + 1, reason: 'the read is pending');
    expect(cachedRow(), findsNothing);

    lock.lockNow();
    await tester.pump();
    storage.release();
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(cachedRow(), findsNothing, reason: 'nothing painted under lock');
    expect(ready, isFalse);
    final requests = gateway.paths.length;

    lock.unlock();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(cachedRow(), findsOneWidget);
    expect(ready, isTrue);
    expect(gateway.paths.length, requests, reason: 'no duplicate request');
    await endProcess(tester, chats);
  });

  testWidgets('a list that lands under App Lock is not replaced by the '
      'cached recents on unlock', (tester) async {
    final storage = _GatedRecentsStorage();
    final connManager = await manager(tester);
    await previousRun(tester, connManager, storage);
    // The snapshot holds an older title than the server now lists.
    final key = storage.values.keys.singleWhere(
      (k) => k.startsWith('cold_start_recents_v1.'),
    );
    storage.values[key] = storage.values[key]!.replaceAll(
      'Plan de la semana',
      'Plan viejo',
    );

    final lock = await appLock(tester);
    final reads = storage.recentsReads;
    final chats = process(storage);
    var ready = false;
    await pumpHome(
      tester,
      manager: connManager,
      chats: chats,
      gateway: _Gateway(),
      lock: lock,
      onReady: () => ready = true,
    );
    for (var i = 0; i < 40 && !ready; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(ready, isTrue);
    lock.unlock();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(cachedRow(), findsOneWidget);
    expect(find.text('Plan viejo', skipOffstage: false), findsNothing);
    expect(storage.recentsReads, reads, reason: 'the list made it moot');
    await endProcess(tester, chats);
  });

  testWidgets('leaving Home while locked drops the unlock retry', (
    tester,
  ) async {
    final storage = _GatedRecentsStorage();
    final connManager = await manager(tester);
    await previousRun(tester, connManager, storage);

    final lock = await appLock(tester);
    final chats = process(storage);
    await pumpHome(
      tester,
      manager: connManager,
      chats: chats,
      gateway: _Gateway(hang: true),
      onReady: () {},
      lock: lock,
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await endProcess(tester, chats);
    // Home and the gate are gone: nobody may still listen to the lock.
    // ignore: invalid_use_of_protected_member
    expect(lock.locked.hasListeners, isFalse);
  });
}
