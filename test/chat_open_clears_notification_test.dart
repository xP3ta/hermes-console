// Opening a chat on the phone clears the reply notifications it already
// has in the tray; a chat seen only while the app is in the background
// keeps them until the user comes back.
import 'dart:async';

import 'package:flutter/foundation.dart';
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
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

final _connection = SavedConnection(
  id: 'notif-open',
  label: 'Notif open',
  host: 'example.invalid',
  port: 443,
  apiKey: 'test-key',
  useHttps: true,
  kind: InstanceKind.vps,
);

const _session = Session(
  id: 'stored-notif-open',
  title: 'Notif open',
  model: 'hermes-agent',
  source: 'api_server',
  messageCount: 2,
  isActive: false,
  preview: '',
  startedAt: 0,
);

const _rows = <Map<String, dynamic>>[
  {'id': 1, 'role': 'user', 'content': 'cached question'},
  {'id': 2, 'role': 'assistant', 'content': 'cached answer'},
];

ActiveChat _attach(
  ActiveChatService service,
  StoredSessionMessageLoader loader,
) => service.attach(
  connection: _connection,
  sessionId: _session.id,
  sessionTitle: _session.title,
  sessionSnapshot: _session,
  api: ApiClient(
    baseUrl: 'https://example.invalid',
    apiKey: 'test-key',
    httpClient: MockClient((_) async => http.Response('unused', 500)),
  ),
  storedMessageLoader: loader,
  attachDesktopRuntimeOnLoad: false,
  disableForegroundKeepAlive: true,
);

/// Chat notifications cancelled (500 is the group summary, refreshed after
/// every cancel).
List<int> _cancelled(List<MethodCall> calls) => [
  for (final c in calls.where((c) => c.method == 'cancel'))
    if ((c.arguments as Map)['id'] != 500) (c.arguments as Map)['id'] as int,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<MethodCall> notificationCalls;

  setUp(() {
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    notificationCalls = [];
    final secure = <String, String>{};
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
    messenger.setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (call) async {
        notificationCalls.add(call);
        return call.method == 'initialize' ? true : null;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_foreground_task/background'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_foreground_task/methods'),
      (call) async => call.method == 'isRunningService' ? false : null,
    );
  });

  Future<(ActiveChatService, NotificationService)> pumpApp(
    WidgetTester tester,
  ) async {
    // The real target: cancels reach the Android plugin channel.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final secure = SecureStorage();
    final notifications = NotificationService(prefs)..enableChatReadSync();
    final ledger = notifications.chatReadSync!;
    ledger.record(
      id: 6100,
      connId: _connection.id,
      profile: null,
      sessionId: _session.id,
    );
    // Another chat, and the same chat on another connection.
    ledger.record(
      id: 6101,
      connId: _connection.id,
      profile: null,
      sessionId: 'another-chat',
    );
    ledger.record(
      id: 6102,
      connId: 'another-connection',
      profile: null,
      sessionId: _session.id,
    );
    final activeChats = ActiveChatService(
      notifications: notifications,
      attachDesktopRuntimeOnLoad: false,
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    final chat = _attach(activeChats, (_, _) async => List.of(_rows));
    await tester.runAsync(() => chat.loadMessages(expectedMessageCount: 2));
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
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 500));
    return (activeChats, notifications);
  }

  void openChat(WidgetTester tester) {
    final context = tester.element(find.byType(Navigator).first);
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) =>
            ChatScreen(connection: _connection, session: _session),
      ),
    );
  }

  Future<void> teardown(WidgetTester tester, ActiveChatService chats) async {
    await tester.pumpWidget(const SizedBox.shrink());
    chats.dispose();
    await tester.pump(const Duration(minutes: 5));
    debugDefaultTargetPlatformOverride = null;
  }

  testWidgets('opening the chat clears only its own notifications', (
    tester,
  ) async {
    final (chats, _) = await pumpApp(tester);
    openChat(tester);
    await tester.pump();
    await tester.pump();
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(_cancelled(notificationCalls), [6100]);
    await teardown(tester, chats);
  });

  testWidgets('a chat on top while the app is in the background keeps its '
      'notification until the user comes back', (tester) async {
    final (chats, notifications) = await pumpApp(tester);
    openChat(tester);
    await tester.pump();
    await tester.pump();
    for (final state in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    notificationCalls.clear();
    // A reply lands while the phone is in the pocket.
    notifications.chatReadSync!.record(
      id: 6100,
      connId: _connection.id,
      profile: null,
      sessionId: _session.id,
    );
    // The screen rebuilds meanwhile (rotation): still on top, not seen.
    tester.view.physicalSize = const Size(2400, 1080);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pump(const Duration(seconds: 5));
    expect(_cancelled(notificationCalls), isEmpty);
    for (final state in const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    await tester.pump();
    expect(_cancelled(notificationCalls), [6100]);
    await teardown(tester, chats);
  });
}
