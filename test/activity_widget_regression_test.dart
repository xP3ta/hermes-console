import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/main.dart';
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
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final secure = <String, String>{};
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
                return null;
              case 'delete':
                secure.remove(args['key']);
                return null;
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

  for (final literal in [
    'PUBLIC plain text',
    'PUBLIC <｜start｜>not an envelope',
  ]) {
    testWidgets('FRESH B4 real terminal widget preserves $literal', (
      tester,
    ) async {
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      final secure = SecureStorage();
      final activeChats = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      addTearDown(activeChats.dispose);
      final connection = SavedConnection(
        id: 'fresh-widget',
        label: 'Fresh',
        host: 'example.invalid',
        port: 443,
        apiKey: 'fixture',
        useHttps: true,
      );
      const session = Session(
        id: 'fresh-widget-session',
        title: 'Fresh',
        model: 'hermes-agent',
        source: 'mobile',
        messageCount: 2,
        isActive: true,
        preview: '',
        startedAt: 0,
      );
      final chat = activeChats.attach(
        connection: connection,
        sessionId: session.id,
        sessionTitle: session.title,
        api: ApiClient(
          baseUrl: 'https://example.invalid',
          apiKey: 'fixture',
          httpClient: MockClient((_) async => http.Response('not found', 404)),
        ),
        disableForegroundKeepAlive: true,
      );
      chat.replaceInternalMessagesForTesting([
        {'role': 'assistant', 'content': literal, 'id': 2},
        {'role': 'user', 'content': 'PUBLIC_HUMAN_NEIGHBOR', 'id': 1},
      ]);
      chat.messagesLoaded = true;
      chat.state = ChatPipelineState.completed;
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
            NotificationService(prefs),
          ),
          sshSessions: SshSessionService(SshManager(secure, manager)),
          notifications: NotificationService(prefs),
          activeChats: activeChats,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 500));
      final context = tester.element(find.byType(Navigator).first);
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatScreen(connection: connection, session: session),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final markdown = tester
          .widgetList<MarkdownBody>(find.byType(MarkdownBody))
          .map((w) => w.data)
          .toList();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(chat.messages.first['content'], literal);
      expect(
        markdown.any((m) => m.contains(literal)),
        isTrue,
        reason: 'Actual rendered markdown: $markdown',
      );
    });
  }
}
