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
import 'package:hermes_android/core/services/chat_draft_store.dart';
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
  _Gateway();

  final bool hang = false;
  final int healthStatus = 200;
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

int readAllCalls = 0;
int readAllCompleted = 0;
int readsAdmittedLocked = 0;
AppLockService? observedLock;
Completer<void>? draftReadGate;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUp(() {
    readAllCalls = 0;
    readAllCompleted = 0;
    readsAdmittedLocked = 0;
    observedLock = null;
    draftReadGate = null;
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
              readAllCalls += 1;
              if (observedLock?.locked.value == true) readsAdmittedLocked++;
              final gate = draftReadGate;
              if (gate != null) await gate.future;
              readAllCompleted++;
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

  Future<AppLockService> appLock(WidgetTester tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('app_lock_enabled', true);
    final lock = AppLockService(prefs);
    observedLock = lock;
    await tester.pump();
    return lock;
  }

  Future<void> settleHome(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> seedDraft(WidgetTester tester, ConnectionManager manager) async {
    final prefs = await SharedPreferences.getInstance();
    // Fixture is created under a real unlocked issuer, before cold-start issuer replacement.
    AppLockService(prefs).unlock();
    await tester.runAsync(
      () => ChatDraftStore(prefs).save(
        manager.getConnections().single.id,
        'mob-lock-probe',
        'SYNTHETIC_DRAFT_LOCK_MARKER',
        const [],
      ),
    );
  }

  for (final scenario in [
    'unlocked baseline',
    'cold locked',
    'relock resume',
    'pending read',
    'unlock recovery',
  ]) {
    testWidgets('Home App Lock draft admission: $scenario', (tester) async {
      final manager_ = await manager(tester);
      await seedDraft(tester, manager_);
      final lock = await appLock(tester);
      if (scenario != 'cold locked' && scenario != 'unlock recovery') {
        lock.unlock();
      }
      final chats = process(MemoryColdStartStorage());
      if (scenario == 'pending read') draftReadGate = Completer<void>();
      var ready = false;
      await pumpHome(
        tester,
        manager: manager_,
        chats: chats,
        gateway: _Gateway(),
        lock: lock,
        onReady: () => ready = true,
      );
      await settleHome(tester);
      if (scenario == 'pending read') {
        expect(
          readAllCalls,
          1,
          reason: 'must intercept actual Home storage admission',
        );
        lock.lockNow();
        await tester.pump();
        await tester.runAsync(() async {
          draftReadGate!.complete();
          draftReadGate = null;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        await settleHome(tester);
        expect(
          readAllCompleted,
          1,
          reason: 'storage reply must reach consumer',
        );
        expect(
          ready,
          isTrue,
          reason: 'status refresh must finish before inspecting projection',
        );
      } else if (scenario == 'relock resume') {
        lock.lockNow();
        await tester.pump();
        readsAdmittedLocked = 0;
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await settleHome(tester);
      } else if (scenario == 'unlock recovery') {
        lock.unlock();
        await settleHome(tester);
      }
      final admitted = readsAdmittedLocked;
      final promoted = find
          .text('SYNTHETIC_DRAFT_LOCK_MARKER', skipOffstage: false)
          .evaluate()
          .length;
      final visible = find
          .text('SYNTHETIC_DRAFT_LOCK_MARKER')
          .evaluate()
          .length;
      final lockState = lock.locked.value;
      var readsAfterUnlock = readAllCalls;
      if (scenario == 'pending read') {
        lock.unlock();
        await settleHome(tester);
        readsAfterUnlock = readAllCalls;
        expect(find.text('SYNTHETIC_DRAFT_LOCK_MARKER'), findsOneWidget);
      }
      await endProcess(tester, chats);
      if (scenario == 'cold locked' || scenario == 'relock resume') {
        expect(lockState, isTrue);
        expect(
          admitted,
          0,
          reason: 'Home admitted secure readAll while App Lock locked',
        );
      } else if (scenario == 'pending read') {
        expect(
          promoted,
          0,
          reason: 'renderer must hide private draft while locked',
        );
        expect(
          readsAfterUnlock,
          greaterThan(1),
          reason:
              'unlock must re-read after revoking a pre-lock pending result, not expose its retained projection',
        );
      } else {
        expect(
          visible,
          1,
          reason: 'one recoverable draft, no missing or duplicated row',
        );
        final prefs = await SharedPreferences.getInstance();
        final durable = await tester.runAsync(
          () => ChatDraftStore(
            prefs,
          ).load(manager_.getConnections().single.id, 'mob-lock-probe'),
        );
        expect(durable!.text, 'SYNTHETIC_DRAFT_LOCK_MARKER');
      }
    });
  }
}
