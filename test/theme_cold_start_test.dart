// Cold start with the id of a theme removed in 1.2.15 saved as the active
// profile: the very first frame already paints the survivor (no flash of
// the default Amber before the theme store finishes loading).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_profile_store.dart';
import 'package:hermes_android/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    for (final name in const [
      'plugins.it_nomads.com/flutter_secure_storage',
      'dexterous.com/flutter/local_notifications',
      'flutter_foreground_task/methods',
      'flutter_foreground_task/background',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    final support = Directory.systemTemp.createTempSync('theme-cold-start-');
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(pathProvider, (_) async => support.path);
    addTearDown(() {
      messenger.setMockMethodCallHandler(pathProvider, null);
      if (support.existsSync()) support.deleteSync(recursive: true);
    });
  });

  testWidgets('frame 1 paints the survivor of a removed theme', (tester) async {
    SharedPreferences.setMockInitialValues({
      'onboarding_done': true,
      ThemeProfileStore.activeProfileKey: 'crimson',
      ThemeProfileStore.legacyThemeKey: 'crimson',
    });
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final secure = SecureStorage();

    await tester.pumpWidget(
      HermesApp(
        connManager: manager,
        appLock: AppLockService(prefs),
        approvalPolicy: ApprovalPolicyService(prefs),
        fontSize: FontSizeService(prefs),

        sshManager: SshManager(secure, manager),
        sftpTransfers: SftpTransferService(
          SshManager(secure, manager),
          NotificationService(prefs),
        ),
        sshSessions: SshSessionService(SshManager(secure, manager)),
        notifications: NotificationService(prefs),
        activeChats: ActiveChatService(),
      ),
    );

    // First frame, before the store load has had a chance to run.
    final bordeaux = AppTheme.presetById('bordeaux').colors;
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp).first);
    expect(
      tester.state<HermesAppState>(find.byType(HermesApp)).themeId.value,
      'bordeaux',
    );
    expect(app.theme?.hermes.background, bordeaux.background);
    expect(app.theme?.hermes.accent, bordeaux.accent);

    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 500));
    expect(prefs.getString(ThemeProfileStore.activeProfileKey), 'bordeaux');
    expect(prefs.getString(ThemeProfileStore.legacyThemeKey), 'bordeaux');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
