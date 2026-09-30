import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/main.dart';
import 'package:hermes_android/core/screens/ssh_screen.dart';
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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import 'support/in_memory_compression_restore_storage.dart';

/// Session service that already holds a live terminal for one instance,
/// without opening a real SSH connection.
class _LiveSessionService extends SshSessionService {
  _LiveSessionService(super.ssh);

  SshTerminalSession? live;
  final List<String> closed = [];

  @override
  SshTerminalSession? of(String connectionId) =>
      live?.connectionId == connectionId ? live : super.of(connectionId);

  @override
  void close(String connectionId) {
    closed.add(connectionId);
    final session = live;
    if (session != null && session.connectionId == connectionId) {
      session.phase.value = SshSessionPhase.closed;
      live = null;
    }
    super.close(connectionId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
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
            return null;
          case 'delete':
            secure.remove(args['key']);
            return null;
          case 'readAll':
            return Map<String, String>.from(secure);
          case 'containsKey':
            return secure.containsKey(args['key']);
          case 'deleteAll':
            secure.clear();
            return null;
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
  });

  testWidgets(
    'removing SSH closes the live terminal so it cannot be reattached',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      final connection = SavedConnection(
        id: 'ssh-remote',
        label: 'Remote',
        host: 'example.invalid',
        port: 443,
        apiKey: '',
        useHttps: true,
      );
      await manager.upsertConnection(connection);
      final secure = SecureStorage();
      final ssh = SshManager(secure, manager);
      await ssh.saveConfig(
        connection.id,
        host: 'example.invalid',
        port: 22,
        username: 'demo',
        method: SshAuthMethod.password,
        password: 'not-a-real-secret',
      );
      final sessions = _LiveSessionService(ssh)
        ..live = (SshTerminalSession(connection.id, Terminal())
          ..phase.value = SshSessionPhase.ready);
      final activeChats = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      addTearDown(activeChats.dispose);

      await tester.pumpWidget(
        HermesApp(
          connManager: manager,
          appLock: AppLockService(prefs),
          approvalPolicy: ApprovalPolicyService(prefs),
          fontSize: FontSizeService(prefs),
          bridgeManager: BridgeManager(secure, manager),
          sshManager: ssh,
          sftpTransfers: SftpTransferService(ssh, NotificationService(prefs)),
          sshSessions: sessions,
          notifications: NotificationService(prefs),
          activeChats: activeChats,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 500));
      Navigator.of(tester.element(find.byType(Navigator).first)).push(
        MaterialPageRoute<void>(
          builder: (_) => SshScreen(connection: connection),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(sessions.of(connection.id)?.isLive, isTrue);

      final removeTile = find.text('Remove SSH');
      await tester.scrollUntilVisible(removeTile, 200);
      await tester.tap(removeTile);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.text('Remove'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(await ssh.loadConfig(connection.id), isNull);
      expect(sessions.closed, [connection.id]);
      expect(sessions.of(connection.id), isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
