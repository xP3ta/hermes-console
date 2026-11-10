// Look & Feel inside the real app: what an existing install paints (its
// preset and mode, as «tema de la lista»), what a Look & Feel install paints
// on its first frame, the switch between the two and the restart.
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
import 'package:hermes_android/core/theme/look_feel.dart';
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

  Future<HermesApp> app(SharedPreferences prefs) async {
    final manager = await ConnectionManager.create(prefs);
    final secure = SecureStorage();
    return HermesApp(
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
    );
  }

  Future<SharedPreferences> boot(
    WidgetTester tester,
    Map<String, Object> values,
  ) async {
    SharedPreferences.setMockInitialValues({
      'onboarding_done': true,
      ...values,
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(await app(prefs));
    return prefs;
  }

  MaterialApp materialApp(WidgetTester tester) =>
      tester.widget<MaterialApp>(find.byType(MaterialApp).first);

  HermesAppState state(WidgetTester tester) =>
      tester.state<HermesAppState>(find.byType(HermesApp));

  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> shutdown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('migration: an install with a preset keeps painting it', (
    tester,
  ) async {
    await boot(tester, {
      ThemeProfileStore.activeProfileKey: 'dracula',
      ThemeProfileStore.legacyThemeKey: 'dracula',
    });
    final dracula = AppTheme.presetById('dracula').colors;
    final look = state(tester).lookFeel.settings;
    expect(look.source, LookFeelSource.list);
    expect(look.appearance, LookAppearance.dark);
    expect(materialApp(tester).theme?.hermes.background, dracula.background);
    expect(materialApp(tester).theme?.hermes.accent, dracula.accent);
    await settle(tester);
    await shutdown(tester);
  });

  testWidgets('frame 1 of a Look & Feel install paints its derived theme', (
    tester,
  ) async {
    await boot(tester, {
      'lfl_source': 'derived',
      'lfl_appearance': 'dark',
      'lfl_accent': 'blue',
      'lfl_dark_background': 'midnight',
      // The preset it had before is still stored, and is not what paints.
      ThemeProfileStore.activeProfileKey: 'dracula',
    });
    final derived = LookFeel.preset(
      state(tester).lookFeel.settings,
      Brightness.dark,
    ).colors;
    final app = materialApp(tester);
    expect(app.theme?.brightness, Brightness.dark);
    expect(app.darkTheme, isNull);
    expect(app.theme?.hermes.background, derived.background);
    expect(app.theme?.hermes.accent, derived.accent);
    expect(
      app.theme?.hermes.background,
      LookFeel.darkSwatch(LookDarkBackground.midnight).$1,
    );
    await settle(tester);
    await shutdown(tester);
  });

  testWidgets('«Sistema» gives Material a light theme and a dark one', (
    tester,
  ) async {
    await boot(tester, {'lfl_source': 'derived'});
    final app = materialApp(tester);
    expect(app.theme?.brightness, Brightness.light);
    expect(app.darkTheme?.brightness, Brightness.dark);
    await settle(tester);
    await shutdown(tester);
  });

  testWidgets('a theme of the list takes over, Look & Feel takes it back', (
    tester,
  ) async {
    final prefs = await boot(tester, {
      'lfl_source': 'derived',
      'lfl_appearance': 'dark',
      'lfl_accent': 'green',
    });
    final root = state(tester);

    await tester.runAsync(() => root.setThemeId('dracula'));
    await tester.pump();
    final dracula = AppTheme.presetById('dracula').colors;
    expect(root.lookFeel.settings.source, LookFeelSource.list);
    expect(root.lookFeel.settings.accentId, 'green');
    expect(materialApp(tester).theme?.hermes.accent, dracula.accent);
    expect(prefs.getString('lfl_source'), 'list');

    // Adjusting Look & Feel puts the derivation in force again.
    await tester.runAsync(() => root.lookFeel.setAccent('rose'));
    await tester.pump();
    expect(root.lookFeel.settings.derived, isTrue);
    final derived = LookFeel.preset(root.lookFeel.settings, Brightness.dark);
    expect(materialApp(tester).theme?.hermes.accent, derived.colors.accent);
    expect(materialApp(tester).theme?.hermes.accent, isNot(dracula.accent));
    await settle(tester);
    await shutdown(tester);
  });

  testWidgets('restart: a new instance with the same prefs paints the same', (
    tester,
  ) async {
    final prefs = await boot(tester, {});
    await tester.runAsync(() async {
      final look = state(tester).lookFeel;
      await look.setAppearance(LookAppearance.light);
      await look.setLightBackground(LookLightBackground.white);
      await look.setCustomAccent(const Color(0xFF336699));
    });
    await tester.pump();
    final before = materialApp(tester).theme!.hermes;
    await settle(tester);
    await shutdown(tester);

    await tester.pumpWidget(await app(prefs));
    final after = materialApp(tester).theme!.hermes;
    expect(after.background, before.background);
    expect(after.accent, before.accent);
    expect(after.background, Colors.white);
    expect(state(tester).lookFeel.settings.accentId, lookAccentCustomId);
    await settle(tester);
    await shutdown(tester);
  });
}
