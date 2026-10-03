import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/cold_start_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cs1215_cold_start_store_test.dart' show MemoryColdStartStorage;
import 'support/in_memory_compression_restore_storage.dart';

/// Records every tail blob read (each one is a Keystore decryption in
/// production) and optionally charges [readLatency] per read.
class _RecordingColdStartStorage extends MemoryColdStartStorage {
  _RecordingColdStartStorage(MemoryColdStartStorage from, {this.readLatency}) {
    values.addAll(from.values);
  }

  final Duration? readLatency;
  final List<String> tailReads = [];

  @override
  Future<String?> read(String key) async {
    if (key.startsWith('cold_start_tail_v1.')) tailReads.add(key);
    final latency = readLatency;
    if (latency != null) await Future<void>.delayed(latency);
    return super.read(key);
  }
}

const _connId = 'cold-conn';
const _sessionId = 'stored-last';
const _networkLatency = Duration(milliseconds: 1200);

const _durableRows = <Map<String, dynamic>>[
  {'id': 1, 'role': 'user', 'content': 'pregunta anterior'},
  {'id': 2, 'role': 'assistant', 'content': 'respuesta anterior'},
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
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
    });
    final secure = <String, String>{'api_key_$_connId': 'key'};
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
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_foreground_task/methods'),
          (call) async => call.method == 'isRunningService' ? false : null,
        );
  });

  /// Previous process: the user was reading [_sessionId] when Android killed
  /// the app. Its route and tail were persisted (encrypted storage fake).
  Future<MemoryColdStartStorage> previousRun({bool route = true}) async {
    final storage = MemoryColdStartStorage();
    final store = ColdStartStore(storage: storage);
    if (route) {
      await store.rememberRoute(
        const ColdStartRoute(
          kind: ColdStartRouteKind.chat,
          connectionId: _connId,
          profile: 'default',
          sessionId: _sessionId,
          source: 'api_server',
        ),
      );
    }
    await store.saveTail(
      connectionId: _connId,
      profile: 'default',
      storedSessionId: _sessionId,
      routeSessionId: _sessionId,
      aliases: {_sessionId},
      newestFirst: _durableRows.reversed.toList(),
    );
    return storage;
  }

  Future<
    ({
      ActiveChatService chats,
      AppLockService lock,
      NotificationService notifications,
      List<String> reads,
    })
  >
  pumpApp(
    WidgetTester tester, {
    ColdStartStorage? storage,
    Future<List<Map<String, dynamic>>> Function(String id)? network,
    bool locked = false,
    int sessionStatus = 200,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (locked) await prefs.setBool('app_lock_enabled', true);
    final manager = (await tester.runAsync(
      () => ConnectionManager.create(prefs),
    ))!;
    await tester.runAsync(manager.applyDefaultOnLaunch);
    final reads = <String>[];
    final activeChats = ActiveChatService(
      attachDesktopRuntimeOnLoad: false,
      compressionRestoreStore: testCompressionRestoreStore(),
      coldStartStore: storage == null ? null : ColdStartStore(storage: storage),
      defaultApiForTesting: (connection) => ApiClient(
        baseUrl: connection.baseUrl,
        apiKey: 'key',
        httpClient: MockClient(
          (_) async => http.Response(
            sessionStatus == 404 ? '{"error":"not found"}' : '{}',
            sessionStatus,
          ),
        ),
      ),
      defaultStoredMessageLoaderForTesting: (id, _) {
        reads.add(id);
        return network?.call(id) ??
            Future<List<Map<String, dynamic>>>.delayed(
              _networkLatency,
              () => List.of(_durableRows),
            );
      },
    );
    final secure = SecureStorage();
    final lock = AppLockService(prefs);
    final notifications = NotificationService(prefs);
    await tester.pumpWidget(
      HermesApp(
        connManager: manager,
        appLock: lock,
        approvalPolicy: ApprovalPolicyService(prefs),
        fontSize: FontSizeService(prefs),
        bridgeManager: BridgeManager(secure, manager),
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
    return (
      chats: activeChats,
      lock: lock,
      notifications: notifications,
      reads: reads,
    );
  }

  /// Fake-clock ms from app start until [finder] shows, or null.
  Future<int?> msUntil(
    WidgetTester tester,
    Finder finder, {
    Duration limit = const Duration(seconds: 12),
    void Function(int elapsedMs)? onTick,
  }) async {
    const step = Duration(milliseconds: 20);
    var elapsed = 0;
    while (elapsed <= limit.inMilliseconds) {
      if (finder.evaluate().isNotEmpty) return elapsed;
      onTick?.call(elapsed);
      await tester.pump(step);
      elapsed += step.inMilliseconds;
    }
    return null;
  }

  Future<void> tearDownApp(WidgetTester tester, ActiveChatService chats) async {
    await tester.pumpWidget(const SizedBox.shrink());
    chats.dispose();
    await tester.pump(const Duration(minutes: 5));
  }

  final lastChatContent = find.textContaining('respuesta anterior');

  testWidgets('before: a cold start lands on Home and the last chat paints '
      'only after a tap plus the network read', (tester) async {
    // No persisted continuity: the 1.2.15 candidate behaviour.
    final app = await pumpApp(tester);
    var openedAt = -1;
    final ms = await msUntil(
      tester,
      lastChatContent,
      onTick: (elapsed) {
        // Best case for the user: they tap the chat the very frame Home
        // appears.
        if (openedAt >= 0 ||
            find.byType(HomeDashboardScreen).hitTestable().evaluate().isEmpty) {
          return;
        }
        openedAt = elapsed;
        Navigator.of(tester.element(find.byType(Navigator).first)).push(
          PageRouteBuilder<void>(
            transitionDuration: Duration.zero,
            pageBuilder: (_, _, _) => ChatScreen(
              connection: SavedConnection(
                id: _connId,
                label: 'Server',
                host: 'example.invalid',
                port: 443,
                apiKey: 'key',
                useHttps: true,
              ),
              session: const Session(
                id: _sessionId,
                title: '',
                model: '',
                source: 'api_server',
                messageCount: 2,
                isActive: false,
                preview: '',
                startedAt: 0,
              ),
            ),
          ),
        );
      },
    );
    // ignore: avoid_print
    print(
      'cs1215 before: home at ${openedAt}ms, last chat content at '
      '${ms}ms',
    );
    expect(openedAt, greaterThan(0));
    expect(ms, greaterThanOrEqualTo(openedAt + _networkLatency.inMilliseconds));
    await tearDownApp(tester, app.chats);
  });

  testWidgets('after: a cold start reopens the last chat and paints its '
      'cached tail before the network answers, then reconciles', (
    tester,
  ) async {
    final storage = (await tester.runAsync(previousRun))!;
    final network = Completer<List<Map<String, dynamic>>>();
    final app = await pumpApp(
      tester,
      storage: storage,
      network: (_) => network.future,
    );
    final ms = await msUntil(tester, lastChatContent);
    // ignore: avoid_print
    print('cs1215 after: last chat content at ${ms}ms');
    expect(ms, isNotNull);
    expect(find.byType(ChatScreen), findsOneWidget);
    // Marked as cached and never accepted as authoritative.
    expect(
      find.byKey(const ValueKey('chat-cached-transcript')),
      findsOneWidget,
    );
    final chat = app.chats.of(_connId, _sessionId)!;
    expect(chat.showingCachedTranscript, isTrue);
    expect(chat.messagesLoaded, isFalse);
    // The server read started immediately.
    expect(app.reads, [_sessionId]);

    network.complete([
      ..._durableRows,
      {'id': 3, 'role': 'user', 'content': 'escrita en Desktop'},
      {'id': 4, 'role': 'assistant', 'content': 'respuesta del servidor'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('respuesta del servidor'), findsWidgets);
    expect(find.textContaining('respuesta anterior'), findsWidgets);
    expect(find.byKey(const ValueKey('chat-cached-transcript')), findsNothing);
    expect(chat.showingCachedTranscript, isFalse);
    // Reconciled exactly once: no duplicated rows.
    expect(
      chat.messages.where((m) => m['content'] == 'respuesta anterior'),
      hasLength(1),
    );
    await tearDownApp(tester, app.chats);
  });

  testWidgets('with App Lock on, nothing of the chat is built before unlock', (
    tester,
  ) async {
    final storage = (await tester.runAsync(previousRun))!;
    final app = await pumpApp(tester, storage: storage, locked: true);
    // Frame by frame through splash and Home: a single long pump would
    // skip the frames where a premature push would build the chat.
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ChatScreen, skipOffstage: false), findsNothing);
    }
    expect(find.byType(ChatScreen, skipOffstage: false), findsNothing);
    expect(lastChatContent.evaluate(), isEmpty);
    expect(app.reads, isEmpty);

    app.lock.unlock();
    final ms = await msUntil(tester, lastChatContent);
    expect(ms, isNotNull);
    expect(find.byType(ChatScreen), findsOneWidget);
    await tearDownApp(tester, app.chats);
  });

  group('App Lock: no tail is decrypted before unlock', () {
    for (final latency in const [Duration.zero, Duration(milliseconds: 60)]) {
      testWidgets('locked cold start, read latency ${latency.inMilliseconds} '
          'ms', (tester) async {
        final storage = _RecordingColdStartStorage(
          (await tester.runAsync(previousRun))!,
          readLatency: latency,
        );
        final app = await pumpApp(tester, storage: storage, locked: true);
        // Frame by frame through splash, Home and the lock screen.
        for (var i = 0; i < 160; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          expect(storage.tailReads, isEmpty, reason: 'frame $i');
          expect(find.byType(ChatScreen, skipOffstage: false), findsNothing);
        }
        expect(app.reads, isEmpty);

        app.lock.unlock();
        final ms = await msUntil(tester, lastChatContent);
        // ignore: avoid_print
        print(
          'cs1215 app-lock latency=${latency.inMilliseconds}ms: unlock to '
          'cached chat painted in ${ms}ms',
        );
        expect(ms, isNotNull);
        expect(storage.tailReads, isNotEmpty);
        // Painted from the cache, before the network answers.
        expect(
          find.byKey(const ValueKey('chat-cached-transcript')),
          findsOneWidget,
        );
        expect(ms, lessThan(_networkLatency.inMilliseconds));
        await tearDownApp(tester, app.chats);
      });
    }

    testWidgets('without App Lock the first chat frame paints the decrypted '
        'tail, as before', (tester) async {
      final storage = _RecordingColdStartStorage(
        (await tester.runAsync(previousRun))!,
      );
      final app = await pumpApp(tester, storage: storage);
      final ms = await msUntil(tester, lastChatContent);
      // ignore: avoid_print
      print('cs1215 no app-lock: cached chat painted at ${ms}ms');
      expect(ms, isNotNull);
      expect(storage.tailReads, isNotEmpty);
      expect(
        find.byKey(const ValueKey('chat-cached-transcript')),
        findsOneWidget,
      );
      await tearDownApp(tester, app.chats);
    });
  });

  testWidgets('unmounting the shell while App Lock waits drops the unlock '
      'listener and never opens the chat afterwards', (tester) async {
    final storage = (await tester.runAsync(previousRun))!;
    final app = await pumpApp(tester, storage: storage, locked: true);
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    // ignore: invalid_use_of_protected_member
    expect(app.lock.locked.hasListeners, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    // The remembered-route waiter was the only listener left behind.
    // ignore: invalid_use_of_protected_member
    expect(app.lock.locked.hasListeners, isFalse);
    app.lock.unlock();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(app.reads, isEmpty);
    app.chats.dispose();
    await tester.pump(const Duration(minutes: 5));
  });

  testWidgets('a pending notification open wins over the remembered route', (
    tester,
  ) async {
    final storage = (await tester.runAsync(previousRun))!;
    final app = await pumpApp(tester, storage: storage);
    // Tapped while the splash still covers the app (cold start from the
    // notification): the shell defers it until it can navigate.
    unawaited(
      app.notifications.deliverOpenForTesting(
        const NotificationOpen(
          connId: _connId,
          sessionId: 'from-notification',
          profile: 'default',
        ),
      ),
    );
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    final screens = tester
        .widgetList<ChatScreen>(find.byType(ChatScreen, skipOffstage: false))
        .map((s) => s.session.id)
        .toList();
    expect(screens, ['from-notification']);
    expect(app.reads, isNot(contains(_sessionId)));
    await tearDownApp(tester, app.chats);
  });

  testWidgets('a notification tapped while App Lock covers the cold start '
      'wins over the remembered route after unlock', (tester) async {
    final storage = (await tester.runAsync(previousRun))!;
    final app = await pumpApp(tester, storage: storage, locked: true);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    // Deferred by the lock, kept pending for delivery after unlock.
    unawaited(
      app.notifications.deliverOpenForTesting(
        const NotificationOpen(
          connId: _connId,
          sessionId: 'from-notification',
          profile: 'default',
        ),
      ),
    );
    await tester.pump();
    expect(app.notifications.hasPendingOpen, isTrue);
    app.lock.unlock();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    final screens = tester
        .widgetList<ChatScreen>(find.byType(ChatScreen, skipOffstage: false))
        .map((s) => s.session.id)
        .toList();
    expect(screens, ['from-notification']);
    expect(app.reads, isNot(contains(_sessionId)));
    await tearDownApp(tester, app.chats);
  });

  testWidgets('a remembered chat deleted elsewhere returns to Home and its '
      'cache is dropped', (tester) async {
    final storage = (await tester.runAsync(previousRun))!;
    final app = await pumpApp(
      tester,
      storage: storage,
      network: (_) => Future<List<Map<String, dynamic>>>.delayed(
        const Duration(milliseconds: 200),
        () => throw Exception('HTTP 404: session not found'),
      ),
      sessionStatus: 404,
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(find.byType(ChatScreen), findsNothing);
    expect(find.byType(HomeDashboardScreen), findsOneWidget);
    expect(lastChatContent.evaluate(), isEmpty);
    final fresh = ColdStartStore(storage: storage);
    expect((await tester.runAsync(fresh.loadTails))!, isEmpty);
    expect(await tester.runAsync(() => fresh.routeFor(_connId)), isNull);
    await tearDownApp(tester, app.chats);
  });
}
