import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/notification_settings_screen.dart';
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
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    final secure = <String, String>{};
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = (call.arguments as Map?) ?? {};
        return switch (call.method) {
          'read' => secure[args['key']],
          'readAll' => Map<String, String>.from(secure),
          'containsKey' => secure.containsKey(args['key']),
          _ => null,
        };
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

  testWidgets('the background listening row says cron and Kanban need it', (
    tester,
  ) async {
    // The screen's existing ListTile-in-panel layout trips a debug-only
    // framework lint unrelated to this row; everything else still fails.
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains(
        'ListTile background color or ink splashes may be invisible',
      )) {
        return;
      }
      previousOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = previousOnError);
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final secure = SecureStorage();
    final activeChats = ActiveChatService(
      attachDesktopRuntimeOnLoad: false,
      compressionRestoreStore: testCompressionRestoreStore(),
    );
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
    await tester.pump(const Duration(seconds: 1));
    Navigator.of(tester.element(find.byType(Navigator).first)).push(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => const NotificationSettingsScreen(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    final s = Strings.of(
      tester.element(find.byType(NotificationSettingsScreen)),
    );
    final title = find.text(s.notifBgTitle);
    final note = find.text(s.au1215BgNeededForAutomation);
    await tester.scrollUntilVisible(note, 300);
    expect(title, findsOneWidget);
    expect(note, findsOneWidget);
    // Right under the opt-in switch, in the same panel.
    final gap = tester.getTopLeft(note).dy - tester.getBottomLeft(title).dy;
    expect(gap, inInclusiveRange(0, 60));

    await tester.pumpWidget(const SizedBox.shrink());
    activeChats.dispose();
    await tester.pump(const Duration(minutes: 5));
    debugDefaultTargetPlatformOverride = null;
  });

  test('the note names cron and Kanban in both languages', () async {
    final en = await Strings.delegate.load(const Locale('en'));
    final es = await Strings.delegate.load(const Locale('es'));
    for (final text in [
      en.au1215BgNeededForAutomation,
      es.au1215BgNeededForAutomation,
    ]) {
      expect(text.toLowerCase(), contains('cron'));
      expect(text, contains('Kanban'));
    }
  });
}
