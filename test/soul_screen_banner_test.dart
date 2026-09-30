import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/main.dart';
import 'package:hermes_android/core/screens/soul_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

/// Bridge that is never reachable, without touching the network.
class _UnreachableBridgeManager extends BridgeManager {
  _UnreachableBridgeManager(super.secure, super.connections);

  @override
  Future<BridgeState> probe(String connectionId) async => const BridgeState(
    status: BridgeStatus.unreachable,
    url: 'https://bridge.invalid',
    urlIsDerived: true,
    hasToken: false,
    caps: BridgeCapabilities.offline,
  );
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

  Future<void> pumpApp(WidgetTester tester, Widget Function() screen) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final secure = SecureStorage();
    final activeChats = ActiveChatService(
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    addTearDown(activeChats.dispose);
    final ssh = SshManager(secure, manager);
    await tester.pumpWidget(
      HermesApp(
        connManager: manager,
        appLock: AppLockService(prefs),
        approvalPolicy: ApprovalPolicyService(prefs),
        fontSize: FontSizeService(prefs),
        bridgeManager: _UnreachableBridgeManager(secure, manager),
        sshManager: ssh,
        sftpTransfers: SftpTransferService(ssh, NotificationService(prefs)),
        sshSessions: SshSessionService(ssh),
        notifications: NotificationService(prefs),
        activeChats: activeChats,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 500));
    final context = tester.element(find.byType(Navigator).first);
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => screen()));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets(
    'with a connection and no bridge, SOUL does not claim it cannot be read '
    'or applied over HTTP while offering Reload/Apply',
    (tester) async {
      final connection = SavedConnection(
        id: 'soul-remote',
        label: 'Remote',
        host: 'example.invalid',
        port: 443,
        apiKey: '',
        useHttps: true,
      );
      await pumpApp(tester, () => SoulScreen(connection: connection));

      expect(find.byType(SoulScreen), findsOneWidget);
      expect(find.text('Apply'), findsOneWidget);
      expect(find.textContaining('/api/soul'), findsNothing);
      expect(find.textContaining('via CLI'), findsNothing);
    },
  );

  testWidgets('without a connection, the local-draft note is still shown', (
    tester,
  ) async {
    await pumpApp(tester, () => const SoulScreen());

    expect(find.byType(SoulScreen), findsOneWidget);
    expect(find.text('Apply'), findsNothing);
    expect(find.textContaining('/api/soul'), findsOneWidget);
  });
}
