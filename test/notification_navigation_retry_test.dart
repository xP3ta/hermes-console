import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/new_session_launch_coordinator.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/run_registry.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _Harness {
  const _Harness({
    required this.state,
    required this.navigator,
    required this.connection,
    required this.registry,
    required this.activeChats,
    required this.notifications,
    required this.appLock,
  });

  final HermesAppState state;
  final NavigatorState navigator;
  final SavedConnection connection;
  final RunRegistry registry;
  final ActiveChatService activeChats;
  final NotificationService notifications;
  final AppLockService appLock;
}

Future<_Harness> _pumpHarness(
  WidgetTester tester, {
  Future<void>? missionControlBarrier,
  bool appLockEnabled = false,
  Future<Session?> Function(SavedConnection, String, String)? externalLookup,
}) async {
  final connection = SavedConnection(
    id: 'notification-race-connection',
    label: 'Notification race fixture',
    host: '192.168.255.254',
    port: 8642,
    apiKey: 'test-key',
    kind: InstanceKind.vps,
    onDeviceLoopback: true,
  );
  SharedPreferences.setMockInitialValues({
    'onboarding_done': true,
    'app_lock_enabled': appLockEnabled,
  });
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  await prefs.setStringList('saved_connections', [
    jsonEncode(connection.toMap()),
  ]);
  manager.activeConnectionId.value = connection.id;
  final notifications = NotificationService(prefs);
  final activeChats = ActiveChatService(
    notifications: notifications,
    policy: ApprovalPolicyService(prefs),
    prefs: prefs,
  );
  final secure = SecureStorage();
  final appLock = AppLockService(prefs);
  await tester.pumpWidget(
    HermesApp(
      connManager: manager,
      appLock: appLock,
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
      runDetailBuilderForTesting: (_, record) =>
          Scaffold(body: Text(record.runId)),
      missionControlBarrierForTesting: missionControlBarrier,
      externalSessionLookupForTesting: externalLookup,
    ),
  );
  await tester.pump();
  return _Harness(
    state: tester.state<HermesAppState>(find.byType(HermesApp)),
    navigator: tester.state<NavigatorState>(find.byType(Navigator).first),
    connection: connection,
    registry: await RunRegistry.load(prefs, connection.id),
    activeChats: activeChats,
    notifications: notifications,
    appLock: appLock,
  );
}

NotificationOpen _runOpen(String runId) => NotificationOpen(
  connId: 'notification-race-connection',
  profile: 'default',
  runId: runId,
);

RunRecord _run(String runId) => RunRecord(
  runId: runId,
  prompt: runId,
  createdAt: 1,
  lastStatus: 'running',
  connId: 'notification-race-connection',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a hydration retry keeps its original fence after user opens a draft',
    (tester) async {
      const marker = 'NEW_SESSION_DRAFT_MUST_STAY_VISIBLE';
      final harness = await _pumpHarness(tester);
      addTearDown(harness.activeChats.dispose);

      expect(
        await harness.state.debugOpenNotification(_runOpen('stale-run')),
        NavigationDeliveryOutcome.deferred,
      );
      await tester.pump(const Duration(milliseconds: 20));
      harness.navigator.push<void>(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'new-draft:authoritative'),
          builder: (_) => const Scaffold(body: Text(marker)),
        ),
      );
      await tester.pump();
      await harness.registry.add(_run('stale-run'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(find.text(marker), findsOneWidget);
      expect(find.text('stale-run'), findsNothing);
    },
  );

  testWidgets(
    'concurrent hydration retries preserve latest notification authority',
    (tester) async {
      final harness = await _pumpHarness(tester);
      addTearDown(harness.activeChats.dispose);

      expect(
        await harness.state.debugOpenNotification(_runOpen('older-run')),
        NavigationDeliveryOutcome.deferred,
      );
      await tester.pump(const Duration(milliseconds: 40));
      expect(
        await harness.state.debugOpenNotification(_runOpen('latest-run')),
        NavigationDeliveryOutcome.deferred,
      );
      await harness.registry.add(_run('latest-run'));
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pump();
      expect(find.text('latest-run'), findsWidgets);

      await harness.registry.add(_run('older-run'));
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pump();

      expect(find.text('latest-run'), findsWidgets);
      expect(find.text('older-run'), findsNothing);
    },
  );

  testWidgets(
    'unlock retries Mission Control only after the lock route settles',
    (tester) async {
      final harness = await _pumpHarness(tester, appLockEnabled: true);
      addTearDown(harness.activeChats.dispose);
      await tester.pump(const Duration(milliseconds: 250));
      const open = NotificationOpen(
        connId: 'notification-race-connection',
        sessionId: 'locked-bot-session',
        profile: 'default',
        surface: NotificationChatSurface.bot,
      );

      expect(
        await harness.notifications.deliverOpenForTesting(open),
        NavigationDeliveryOutcome.deferred,
      );
      expect(harness.notifications.hasPendingOpenForTesting, isTrue);
      expect(find.byType(MissionControlScreen), findsNothing);

      harness.appLock.unlock();
      expect(find.byType(MissionControlScreen), findsNothing);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(harness.notifications.hasPendingOpenForTesting, isFalse);
      expect(find.byType(MissionControlScreen), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(MissionControlScreen), findsOneWidget);
      expect(harness.notifications.hasPendingOpenForTesting, isFalse);
    },
  );

  testWidgets('post-unlock handoff does not hijack a newer user route', (
    tester,
  ) async {
    const marker = 'NEWER_ROUTE_AFTER_UNLOCK';
    final harness = await _pumpHarness(tester, appLockEnabled: true);
    addTearDown(harness.activeChats.dispose);
    await tester.pump(const Duration(milliseconds: 250));
    const open = NotificationOpen(
      connId: 'notification-race-connection',
      sessionId: 'locked-bot-session',
      profile: 'default',
      surface: NotificationChatSurface.bot,
    );

    expect(
      await harness.notifications.deliverOpenForTesting(open),
      NavigationDeliveryOutcome.deferred,
    );
    harness.appLock.unlock();
    harness.navigator.push<void>(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'user:newer-after-unlock'),
        builder: (_) => const Scaffold(body: Text(marker)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(find.text(marker), findsOneWidget);
    expect(find.byType(MissionControlScreen), findsNothing);
    expect(harness.notifications.hasPendingOpenForTesting, isTrue);
  });

  testWidgets(
    'profile-less notification retains a stale open until one committed retry',
    (tester) async {
      final lookupStarted = Completer<void>();
      final releaseLookup = Completer<void>();
      var lookups = 0;
      final harness = await _pumpHarness(
        tester,
        externalLookup: (_, sessionId, _) async {
          lookups++;
          expect(sessionId, 'legacy-session');
          if (lookups == 1) {
            lookupStarted.complete();
            await releaseLookup.future;
          }
          return const Session(
            id: 'legacy-session',
            title: 'Legacy destination',
            model: '',
            source: 'desktop',
            messageCount: 1,
            isActive: true,
            preview: 'legacy',
            startedAt: 1,
          );
        },
      );
      addTearDown(harness.activeChats.dispose);
      const open = NotificationOpen(
        connId: 'notification-race-connection',
        sessionId: 'legacy-session',
      );

      final firstDelivery = Future<Object?>.sync(
        () => harness.notifications.deliverOpenForTesting(open),
      );
      await lookupStarted.future;
      harness.navigator.push<void>(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'user:newer-during-lookup'),
          builder: (_) => const Scaffold(body: Text('NEWER_USER_ROUTE')),
        ),
      );
      await tester.pump();
      releaseLookup.complete();
      await tester.pump();

      expect(await firstDelivery, NavigationDeliveryOutcome.deferred);
      expect(harness.notifications.hasPendingOpenForTesting, isTrue);
      expect(find.text('NEWER_USER_ROUTE'), findsOneWidget);
      expect(find.byType(ChatScreen), findsNothing);

      harness.navigator.pop();
      await tester.pump();
      final retry = harness.notifications.retryPendingOpen();
      await tester.pump();
      expect(await retry, NavigationDeliveryOutcome.delivered);
      await tester.pump(const Duration(milliseconds: 350));
      expect(harness.notifications.hasPendingOpenForTesting, isFalse);
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(lookups, 2);

      expect(
        await harness.notifications.retryPendingOpen(),
        NavigationDeliveryOutcome.deferred,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(lookups, 2);
    },
  );

  testWidgets(
    'Mission Control notification stays pending until its route really commits',
    (tester) async {
      final releaseCommit = Completer<void>();
      final harness = await _pumpHarness(
        tester,
        missionControlBarrier: releaseCommit.future,
      );
      addTearDown(harness.activeChats.dispose);
      const open = NotificationOpen(
        connId: 'notification-race-connection',
        sessionId: 'bot-session',
        profile: 'default',
        surface: NotificationChatSurface.bot,
      );

      final firstDelivery = harness.notifications.deliverOpenForTesting(open);
      harness.state.debugInvalidateNavigation();
      releaseCommit.complete();
      await tester.pump();
      expect(await firstDelivery, NavigationDeliveryOutcome.deferred);
      expect(harness.notifications.hasPendingOpenForTesting, isTrue);

      final retry = harness.notifications.retryPendingOpen();
      await tester.pump();
      expect(await retry, NavigationDeliveryOutcome.delivered);
      expect(harness.notifications.hasPendingOpenForTesting, isFalse);

      expect(
        await harness.notifications.retryPendingOpen(),
        NavigationDeliveryOutcome.deferred,
      );
      await tester.pump();
      expect(harness.notifications.hasPendingOpenForTesting, isFalse);
    },
  );
}
