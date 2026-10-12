import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/lock_screen.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/cold_start_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/platform/native_appearance.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/widgets/startup_handoff.dart';
import 'package:hermes_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cs1215_cold_start_store_test.dart' show MemoryColdStartStorage;
import 'support/in_memory_compression_restore_storage.dart';

/// Counts every private read: Home recents snapshots and chat tails (each
/// one a Keystore decryption in production).
class _CountingStorage extends MemoryColdStartStorage {
  final List<String> privateReads = [];

  @override
  Future<String?> read(String key) {
    if (key.startsWith('cold_start_recents_v1.') ||
        key.startsWith('cold_start_tail_v1.')) {
      privateReads.add(key);
    }
    return super.read(key);
  }
}

const _connId = 'ns-conn';
const _launchChannel = MethodChannel('hermes/new_session_launch');

Map<String, Object> _configuredPrefs() => {
  'onboarding_done': true,
  'saved_connections': [
    jsonEncode({
      'id': _connId,
      'label': 'Server',
      'host': 'example.invalid',
      'port': 443,
      'use_https': true,
    }),
  ],
  'default_connection_id': _connId,
};

const _cachedRecent = Session(
  id: 's-recent',
  title: 'Plan de la semana',
  model: '',
  source: 'cli',
  messageCount: 4,
  isActive: false,
  preview: 'revisar el despliegue',
  startedAt: 1790000000,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Object? pendingLaunchAction;

  setUp(() {
    pendingLaunchAction = null;
    final secure = <String, String>{'api_key_$_connId': 'key'};
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
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
          case 'readAll':
            return Map<String, String>.from(secure);
          case 'containsKey':
            return secure.containsKey(args['key']);
        }
        return null;
      },
    );
    for (final name in [
      'dexterous.com/flutter/local_notifications',
      'flutter_foreground_task/background',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_foreground_task/methods'),
      (call) async => call.method == 'isRunningService' ? false : null,
    );
    messenger.setMockMethodCallHandler(_launchChannel, (call) async {
      if (call.method != 'takePendingLaunchAction') return null;
      final action = pendingLaunchAction;
      pendingLaunchAction = null;
      return action;
    });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_launchChannel, null);
  });

  Future<
    ({
      ActiveChatService chats,
      AppLockService lock,
      NotificationService notifications,
    })
  >
  pumpApp(
    WidgetTester tester, {
    required Map<String, Object> prefsValues,
    ColdStartStore? store,
    bool locked = false,
    Future<bool> Function()? notificationLaunch,
  }) async {
    SharedPreferences.setMockInitialValues(prefsValues);
    final prefs = await SharedPreferences.getInstance();
    if (locked) await prefs.setBool('app_lock_enabled', true);
    final manager = (await tester.runAsync(
      () => ConnectionManager.create(prefs),
    ))!;
    await tester.runAsync(manager.applyDefaultOnLaunch);
    final activeChats = ActiveChatService(
      attachDesktopRuntimeOnLoad: false,
      compressionRestoreStore: testCompressionRestoreStore(),
      coldStartStore: store,
      defaultApiForTesting: (connection) => ApiClient(
        baseUrl: connection.baseUrl,
        apiKey: connection.apiKey,
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      ),
      defaultStoredMessageLoaderForTesting: (_, _) =>
          Completer<List<Map<String, dynamic>>>().future,
    );
    final secure = SecureStorage();
    final lock = AppLockService(prefs);
    final notifications = NotificationService(prefs)
      ..launchProbeForTesting = notificationLaunch;
    // Exactly one frame: what the user sees when the native splash leaves.
    await tester.pumpWidget(
      HermesApp(
        connManager: manager,
        appLock: lock,
        approvalPolicy: ApprovalPolicyService(prefs),
        fontSize: FontSizeService(prefs),

        sshManager: SshManager(secure, manager),
        sftpTransfers: SftpTransferService(
          SshManager(secure, manager),
          notifications,
        ),
        sshSessions: SshSessionService(SshManager(secure, manager)),
        notifications: notifications,
        activeChats: activeChats,
      ),
    );
    return (chats: activeChats, lock: lock, notifications: notifications);
  }

  Future<void> tearDownApp(WidgetTester tester, ActiveChatService chats) async {
    await tester.pumpWidget(const SizedBox.shrink());
    chats.dispose();
    await tester.pump(const Duration(minutes: 5));
  }

  /// The previous process saved Home's recents; this process decrypted
  /// them before its first frame (what bootstrap does without App Lock).
  Future<ColdStartStore> primedStore(
    WidgetTester tester,
    MemoryColdStartStorage storage,
  ) async {
    await tester.runAsync(
      () => ColdStartStore(storage: storage).saveRecents(
        connectionId: _connId,
        profile: 'default',
        sessions: const [_cachedRecent],
      ),
    );
    final store = ColdStartStore(storage: storage);
    await tester.runAsync(
      () => store.loadRecents(connectionId: _connId, profile: 'default'),
    );
    return store;
  }

  final home = find.byType(HomeDashboardScreen, skipOffstage: false);
  final cachedRow = find.text('Plan de la semana', skipOffstage: false);

  Map<String, Object?> launchAction(String eventId) => {
    'contract_version': 1,
    'kind': 'new_session',
    'source': 'widget',
    'native_event_id': eventId,
    'requested_instance_id': _connId,
    'received_elapsed_ms': 0,
  };

  testWidgets('unlocked cold start: the first frame is Home with the cached '
      'recents, no intro in front of it', (tester) async {
    final storage = MemoryColdStartStorage();
    final store = await primedStore(tester, storage);
    final app = await pumpApp(
      tester,
      prefsValues: _configuredPrefs(),
      store: store,
    );
    expect(home.hitTestable(), findsOneWidget);
    expect(find.text('Plan de la semana'), findsOneWidget);
    expect(find.text('HERMES'), findsNothing, reason: 'no Flutter intro');
    expect(
      find.byKey(const ValueKey('home-initial-loading')),
      findsNothing,
      reason: 'cached data paints, no loader over it',
    );
    await tearDownApp(tester, app.chats);
  });

  testWidgets('unlocked cold start without a snapshot: Home chrome on the '
      'first frame and an inline placeholder only for the recents', (
    tester,
  ) async {
    final app = await pumpApp(
      tester,
      prefsValues: _configuredPrefs(),
      store: ColdStartStore(storage: MemoryColdStartStorage()),
    );
    expect(home.hitTestable(), findsOneWidget);
    expect(find.text('HERMES'), findsNothing);
    final placeholder = find.byKey(const ValueKey('home-initial-loading'));
    expect(placeholder, findsOneWidget);
    // Inline: the placeholder does not fill the screen.
    final size = tester.getSize(placeholder);
    final screen = tester.getSize(find.byType(HomeDashboardScreen));
    expect(size.height, lessThan(screen.height / 2));
    expect(
      find.byKey(const ValueKey('home-empty-conversations')),
      findsNothing,
    );
    await tearDownApp(tester, app.chats);
  });

  testWidgets('locked cold start: Home is never built and nothing private '
      'is read before unlock; the lock screen is up at once', (tester) async {
    final storage = _CountingStorage();
    final store = ColdStartStore(storage: storage);
    await tester.runAsync(
      () => store.saveRecents(
        connectionId: _connId,
        profile: 'default',
        sessions: const [_cachedRecent],
      ),
    );
    final app = await pumpApp(
      tester,
      prefsValues: _configuredPrefs(),
      store: ColdStartStore(storage: storage),
      locked: true,
    );
    expect(home, findsNothing, reason: 'frame 0');
    expect(cachedRow, findsNothing);
    await tester.pump();
    // Frame 1: the lock route is in and already complete: it fades in with
    // the startup hand-off, not with a second fade of its own.
    expect(find.byType(LockScreen), findsOneWidget);
    final lockRoute = ModalRoute.of(tester.element(find.byType(LockScreen)))!;
    expect(lockRoute.animation!.value, 1);
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(home, findsNothing, reason: 'frame ${i + 2}');
      expect(cachedRow, findsNothing);
      expect(storage.privateReads, isEmpty, reason: 'frame ${i + 2}');
    }

    app.lock.unlock();
    var painted = false;
    for (var i = 0; i < 40 && !painted; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      painted = find.text('Plan de la semana').evaluate().isNotEmpty;
    }
    expect(home.hitTestable(), findsOneWidget);
    expect(painted, isTrue, reason: 'cached recents after unlock');
    expect(storage.privateReads, isNotEmpty);
    await tearDownApp(tester, app.chats);
  });

  testWidgets('a widget launch that arrives with the app locked is '
      'delivered exactly once, after unlock', (tester) async {
    pendingLaunchAction = launchAction('widget-ev-1');
    final app = await pumpApp(
      tester,
      prefsValues: _configuredPrefs(),
      store: ColdStartStore(storage: MemoryColdStartStorage()),
      locked: true,
    );
    final chats = find.byType(ChatScreen, skipOffstage: false);
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(chats, findsNothing, reason: 'locked, frame $i');
    }
    app.lock.unlock();
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(chats, findsOneWidget);
    final delivered = tester.widget<ChatScreen>(chats).session.id;
    // A second lock/unlock cycle does not deliver it again (a second
    // delivery would open a fresh draft, with another id).
    app.lock.lockNow();
    await tester.pump(const Duration(milliseconds: 300));
    app.lock.unlock();
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(chats, findsOneWidget);
    expect(tester.widget<ChatScreen>(chats).session.id, delivered);
    await tearDownApp(tester, app.chats);
  });

  testWidgets('a widget launch on an unlocked cold start opens once, right '
      'after the first frame', (tester) async {
    pendingLaunchAction = launchAction('widget-ev-2');
    final app = await pumpApp(
      tester,
      prefsValues: _configuredPrefs(),
      store: ColdStartStore(storage: MemoryColdStartStorage()),
    );
    final chats = find.byType(ChatScreen, skipOffstage: false);
    int? openedAtMs;
    for (var ms = 0; ms <= 3000; ms += 50) {
      if (openedAtMs == null && chats.evaluate().isNotEmpty) openedAtMs = ms;
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(chats, findsOneWidget);
    expect(openedAtMs, isNotNull);
    expect(openedAtMs, lessThan(1000), reason: 'no intro holds it back');
    await tearDownApp(tester, app.chats);
  });

  testWidgets('a notification tapped while locked opens exactly once after '
      'unlock', (tester) async {
    final app = await pumpApp(
      tester,
      prefsValues: _configuredPrefs(),
      store: ColdStartStore(storage: MemoryColdStartStorage()),
      locked: true,
    );
    await tester.pump(const Duration(milliseconds: 100));
    unawaited(
      app.notifications.deliverOpenForTesting(
        const NotificationOpen(
          connId: _connId,
          sessionId: 'from-notification',
          profile: 'default',
        ),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(ChatScreen, skipOffstage: false), findsNothing);
    }
    expect(app.notifications.hasPendingOpen, isTrue);
    app.lock.unlock();
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    List<String> open() => tester
        .widgetList<ChatScreen>(find.byType(ChatScreen, skipOffstage: false))
        .map((s) => s.session.id)
        .toList();
    expect(open(), ['from-notification']);
    expect(app.notifications.hasPendingOpen, isFalse);
    app.lock.lockNow();
    await tester.pump(const Duration(milliseconds: 300));
    app.lock.unlock();
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(open(), ['from-notification']);
    await tearDownApp(tester, app.chats);
  });

  testWidgets('first run without any connection: the first frame is the '
      'onboarding, never Home', (tester) async {
    final app = await pumpApp(tester, prefsValues: const {});
    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(home, findsNothing);
    expect(find.text('HERMES'), findsNothing, reason: 'no Flutter intro');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      expect(home, findsNothing);
    }
    expect(find.byType(OnboardingScreen), findsOneWidget);
    await tearDownApp(tester, app.chats);
  });

  testWidgets('notification channels are still created after the first '
      'frames, not before', (tester) async {
    final app = await pumpApp(
      tester,
      prefsValues: _configuredPrefs(),
      store: ColdStartStore(storage: MemoryColdStartStorage()),
    );
    await tester.pump(const Duration(milliseconds: 1000));
    expect(app.notifications.initialized, isFalse);
    for (var i = 0; i < 20 && !app.notifications.initialized; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(app.notifications.initialized, isTrue);
    await tearDownApp(tester, app.chats);
  });

  for (final (mode, expected) in [
    ('dark', NativeAppearance.splashBackgroundDark),
    ('light', NativeAppearance.splashBackgroundLight),
  ]) {
    testWidgets('$mode theme: the first frame continues the native splash '
        '(same background, the mark), then Home fades in', (tester) async {
      final app = await pumpApp(
        tester,
        prefsValues: {..._configuredPrefs(), 'theme_mode': mode},
        store: ColdStartStore(storage: MemoryColdStartStorage()),
      );
      final handoff = tester.widget<StartupHandoff>(
        find.byType(StartupHandoff),
      );
      expect(handoff.background, expected);
      final themeBrightness = Theme.of(
        tester.element(find.byType(HomeDashboardScreen)),
      ).brightness;
      expect(
        NativeAppearance.splashBackground(themeBrightness),
        expected,
        reason: 'the native splash Android picks for this theme',
      );
      expect(
        find.byKey(const ValueKey('startup-handoff-mark')),
        findsOneWidget,
      );
      // The hand-off starts ticking on the frame after the first one.
      await tester.pump();
      await tester.pump(
        StartupHandoff.duration + const Duration(milliseconds: 50),
      );
      expect(find.byKey(const ValueKey('startup-handoff-mark')), findsNothing);
      expect(home.hitTestable(), findsOneWidget);
      await tearDownApp(tester, app.chats);
    });
  }

  testWidgets('locked cold start: the lock screen fades in with the same '
      'hand-off', (tester) async {
    final app = await pumpApp(
      tester,
      prefsValues: _configuredPrefs(),
      store: ColdStartStore(storage: MemoryColdStartStorage()),
      locked: true,
    );
    double appOpacity() => tester
        .widget<FadeTransition>(
          find.byKey(const ValueKey('startup-handoff-app-opacity')),
        )
        .opacity
        .value;
    expect(appOpacity(), 0);
    await tester.pump();
    expect(find.byType(LockScreen), findsOneWidget);
    expect(appOpacity(), lessThan(0.2));
    await tester.pump(const Duration(milliseconds: 200));
    final mid = appOpacity();
    expect(mid, greaterThan(0.2));
    expect(mid, lessThan(1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(appOpacity(), 1);
    expect(find.byType(LockScreen), findsOneWidget);
    expect(home, findsNothing);
    await tearDownApp(tester, app.chats);
  });

  testWidgets('a cold start from a notification tap does not open the '
      'remembered chat first', (tester) async {
    final storage = MemoryColdStartStorage();
    await tester.runAsync(() async {
      final store = ColdStartStore(storage: storage);
      await store.rememberRoute(
        const ColdStartRoute(
          kind: ColdStartRouteKind.chat,
          connectionId: _connId,
          profile: 'default',
          sessionId: 'remembered',
          source: 'api_server',
        ),
      );
    });
    final app = await pumpApp(
      tester,
      prefsValues: _configuredPrefs(),
      store: ColdStartStore(storage: storage),
      notificationLaunch: () async => true,
    );
    List<String> open() => tester
        .widgetList<ChatScreen>(find.byType(ChatScreen, skipOffstage: false))
        .map((s) => s.session.id)
        .toList();
    // Notification init is still deferred: the tap is not known yet.
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(open(), isEmpty, reason: 'frame $i');
    }
    unawaited(
      app.notifications.deliverOpenForTesting(
        const NotificationOpen(
          connId: _connId,
          sessionId: 'from-notification',
          profile: 'default',
        ),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(open(), ['from-notification']);
    await tearDownApp(tester, app.chats);
  });

  testWidgets('control: without a notification launch the remembered chat '
      'reopens right after the first frame', (tester) async {
    final storage = MemoryColdStartStorage();
    await tester.runAsync(() async {
      final store = ColdStartStore(storage: storage);
      await store.rememberRoute(
        const ColdStartRoute(
          kind: ColdStartRouteKind.chat,
          connectionId: _connId,
          profile: 'default',
          sessionId: 'remembered',
          source: 'api_server',
        ),
      );
    });
    final app = await pumpApp(
      tester,
      prefsValues: _configuredPrefs(),
      store: ColdStartStore(storage: storage),
      notificationLaunch: () async => false,
    );
    int? openedAt;
    for (var ms = 0; ms <= 2000; ms += 50) {
      final open = find.byType(ChatScreen, skipOffstage: false);
      if (openedAt == null && open.evaluate().isNotEmpty) openedAt = ms;
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(openedAt, isNotNull);
    expect(openedAt, lessThan(1000));
    await tearDownApp(tester, app.chats);
  });
}
