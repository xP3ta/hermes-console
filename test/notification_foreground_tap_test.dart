// A notification tapped while the app is already in the foreground reaches
// Dart through `onNewIntent` → flutter_local_notifications
// `didReceiveNotificationResponse`. These tests drive that exact platform
// callback and assert that every destination a producer can encode opens a
// real screen instead of being retained forever as "deferred".
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/run_registry.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _connId = 'foreground-tap-connection';
const _channel = MethodChannel('dexterous.com/flutter/local_notifications');

final class _Harness {
  const _Harness({
    required this.navigator,
    required this.registry,
    required this.activeChats,
    required this.notifications,
  });

  final NavigatorState navigator;
  final RunRegistry registry;
  final ActiveChatService activeChats;
  final NotificationService notifications;
}

Future<_Harness> _pumpForegroundApp(WidgetTester tester) async {
  final connection = SavedConnection(
    id: _connId,
    label: 'Foreground tap fixture',
    host: '192.168.255.254',
    port: 8642,
    apiKey: 'fixture-key',
    kind: InstanceKind.vps,
    onDeviceLoopback: true,
  );
  SharedPreferences.setMockInitialValues({
    'onboarding_done': true,
    'notif_perm_requested': true,
  });
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  await prefs.setStringList('saved_connections', [
    jsonEncode(connection.toMap()),
  ]);
  manager.activeConnectionId.value = connection.id;
  final notifications = NotificationService(prefs)..appInForeground = true;
  final activeChats = ActiveChatService(
    notifications: notifications,
    policy: ApprovalPolicyService(prefs),
    prefs: prefs,
  );
  final secure = SecureStorage();
  await tester.pumpWidget(
    HermesApp(
      connManager: manager,
      appLock: AppLockService(prefs),
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
          Scaffold(body: Text('RUN_DETAIL:${record.runId}')),
    ),
  );
  await tester.pump();
  // Registers the platform tap callback exactly like the deferred app init
  // (the durable-delivery recovery of `init()` is irrelevant to taps).
  await notifications.permissionGranted();
  await tester.pump();
  return _Harness(
    navigator: tester.state<NavigatorState>(find.byType(Navigator).first),
    registry: await RunRegistry.load(prefs, connection.id),
    activeChats: activeChats,
    notifications: notifications,
  );
}

/// The platform side of a notification tap with the Activity alive
/// (`onNewIntent` → `didReceiveNotificationResponse`).
Future<void> _tapFromTray(WidgetTester tester, NotificationOpen open) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    _channel.name,
    _channel.codec.encodeMethodCall(
      MethodCall('didReceiveNotificationResponse', {
        'notificationId': 7,
        'actionId': null,
        'input': null,
        'payload': open.toPayload(),
        'notificationResponseType': 0,
      }),
    ),
    (_) {},
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    messenger.setMockMethodCallHandler(_channel, (call) async {
      return switch (call.method) {
        'initialize' || 'areNotificationsEnabled' => true,
        'getNotificationAppLaunchDetails' => {
          'notificationLaunchedApp': false,
          'notificationResponse': null,
        },
        'getActiveNotifications' => const <Object?>[],
        _ => null,
      };
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
  });

  testWidgets(
    'foreground tap on a chat approval opens its conversation when the '
    'run owner is a chat runtime, not a Task Center run',
    (tester) async {
      final harness = await _pumpForegroundApp(tester);
      addTearDown(harness.activeChats.dispose);

      // Same payload the chat approval producer encodes: the run owner is the
      // chat's runtime id, which Task Center never registers.
      await _tapFromTray(
        tester,
        const NotificationOpen(
          connId: _connId,
          sessionId: 'chat-with-approval',
          profile: 'default',
          runId: 'chat-runtime-owner',
          requestId: 'approval-1',
        ),
      );

      expect(find.byType(ChatScreen), findsOneWidget);
      expect(harness.notifications.hasPendingOpenForTesting, isFalse);
      await tester.pump(const Duration(seconds: 6));
    },
  );

  testWidgets(
    'foreground tap on a chat run result opens its conversation when the run '
    'is not tracked by Task Center',
    (tester) async {
      final harness = await _pumpForegroundApp(tester);
      addTearDown(harness.activeChats.dispose);

      await _tapFromTray(
        tester,
        const NotificationOpen(
          connId: _connId,
          sessionId: 'chat-with-finished-run',
          profile: 'default',
          runId: 'untracked-run',
        ),
      );

      expect(find.byType(ChatScreen), findsOneWidget);
      expect(harness.notifications.hasPendingOpenForTesting, isFalse);
      await tester.pump(const Duration(seconds: 6));
    },
  );

  testWidgets('a tracked Task Center run still opens its run detail', (
    tester,
  ) async {
    final harness = await _pumpForegroundApp(tester);
    addTearDown(harness.activeChats.dispose);
    await harness.registry.add(
      RunRecord(
        runId: 'tracked-run',
        prompt: 'tracked',
        sessionId: 'tracked-session',
        createdAt: 1,
        lastStatus: 'running',
        connId: _connId,
      ),
    );

    await _tapFromTray(
      tester,
      const NotificationOpen(
        connId: _connId,
        sessionId: 'tracked-session',
        profile: 'default',
        runId: 'tracked-run',
      ),
    );

    expect(find.text('RUN_DETAIL:tracked-run'), findsOneWidget);
    expect(find.byType(ChatScreen), findsNothing);
  });
}
