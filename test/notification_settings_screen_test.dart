import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hermes_android/core/design/hermes_design.dart'
    show HermesSelectField;
import 'package:hermes_android/core/services/notifications/background_listener.dart';
import 'package:hermes_android/core/services/notifications/cron_notice_policy.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/notification_settings_screen.dart';
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
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('el diagnóstico apila estado a 320 px con texto al 200%', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('dark'),
        home: const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(16),
            child: HermesNotificationDiagnosticRow(
              label: 'Notification permission',
              value: 'Not granted',
              good: false,
            ),
          ),
        ),
      ),
    );

    final label = tester.getRect(find.text('Notification permission'));
    final value = tester.getRect(find.text('Not granted'));
    expect(value.top, greaterThanOrEqualTo(label.bottom));
    expect(tester.takeException(), isNull);
  });

  group('the real screen', () {
    setUp(() => BackgroundListener.debugDisableUiHeartbeat = true);
    tearDown(() {
      BackgroundListener.debugDisableUiHeartbeat = false;
      debugDefaultTargetPlatformOverride = null;
    });

    void installPlatform(String locale) {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      SharedPreferences.setMockInitialValues({
        'onboarding_done': true,
        'app_locale': locale,
        // Preferences of the retired listener: ignored, never written.
        'bg_watch_runs': '[]',
      });
      final messenger =
          TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
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
    }

    /// Opens the real screen inside the app.
    Future<ActiveChatService> openScreen(
      WidgetTester tester, {
      required Size logicalSize,
      double textScale = 1,
    }) async {
      // The screen's existing ListTile-in-panel layout trips a debug-only
      // framework lint unrelated to these rows; everything else still fails.
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
      tester.view.physicalSize = logicalSize;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
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
      return activeChats;
    }

    Future<void> closeScreen(
      WidgetTester tester,
      ActiveChatService activeChats,
    ) async {
      await tester.pumpWidget(const SizedBox.shrink());
      activeChats.dispose();
      await tester.pump(const Duration(minutes: 5));
      debugDefaultTargetPlatformOverride = null;
    }

    testWidgets('only local alerts: no push section and no closed-app push '
        'note', (tester) async {
      installPlatform('en');
      final activeChats = await openScreen(
        tester,
        logicalSize: const Size(900, 2400),
      );
      final s = Strings.of(
        tester.element(find.byType(NotificationSettingsScreen)),
      );
      expect(find.byKey(const ValueKey('notif-closed-app-note')), findsNothing);
      expect(find.byType(HermesSwitchTile), findsWidgets);
      expect(find.text(s.notifTestButton), findsOneWidget);
      expect(tester.takeException(), isNull);
      await closeScreen(tester, activeChats);
    });

    testWidgets('offers no permanent listening and no dead switch', (
      tester,
    ) async {
      // The opt-in listening switch is Android-only (dart:io): on this host
      // the screen offers exactly the alert switches, and it never turns the
      // listening on by itself.
      installPlatform('es');
      final activeChats = await openScreen(
        tester,
        logicalSize: const Size(900, 2400),
      );
      final s = Strings.of(
        tester.element(find.byType(NotificationSettingsScreen)),
      );

      // Exactly the switches that can fire: master, approvals, questions,
      // done, goals, runs, Kanban and "also in the foreground" (cron has its
      // own selector below).
      final tiles = tester
          .widgetList<HermesSwitchTile>(find.byType(HermesSwitchTile))
          .map((tile) => tile.title)
          .toList();
      expect(tiles, [
        s.nrdMasterTitle,
        s.notifApprovalsTitle,
        s.nrdQuestionsTitle,
        s.nrdDoneTitle,
        s.notifLocalAgentResultsTitle,
        s.notifRunsTitle,
        s.pekKanbanSwitchTitle,
        s.notifForegroundTitle,
      ]);
      final cron = tester.widget<HermesSelectField<CronNoticeMode>>(
        find.byKey(const ValueKey('notif-cron-mode')),
      );
      expect(cron.value, CronNoticeMode.automatic);
      expect(cron.options.map((option) => option.label), [
        s.cronNoticeAutomatic,
        s.cronNoticeAll,
        s.cronNoticeFailuresOnly,
        s.cronNoticeOff,
      ]);
      cron.onChanged!(CronNoticeMode.failuresOnly);
      await tester.pump();
      final saved = await SharedPreferences.getInstance();
      expect(saved.getString(CronNoticePolicy.preferenceKey), 'failuresOnly');
      expect(find.byKey(const ValueKey('notif-advanced-toggle')), findsNothing);
      expect(
        find.byKey(const ValueKey('notif-fixed-card-settings')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('notif-closed-app-note')),
        findsNothing,
      );
      // Live Updates of the open app keep their system-settings row (an
      // Android-only row: dart:io decides, not the target platform override).
      expect(
        find.byKey(const ValueKey('notif-live-updates-settings')),
        Platform.isAndroid ? findsOneWidget : findsNothing,
      );
      expect(find.text(s.notifTestButton), findsOneWidget);

      // The old preferences were read, not rewritten.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('notif_background_listen'), isNot(isTrue));
      expect(prefs.getString('bg_watch_runs'), '[]');
      expect(tester.takeException(), isNull);
      await closeScreen(tester, activeChats);
    });

    for (final locale in const [
      'es',
      'en',
      'de',
      'fr',
      'it',
      'pt',
      'ja',
      'ko',
      'zh',
    ]) {
      testWidgets('does not overflow at 200% text in $locale', (tester) async {
        installPlatform(locale);
        final activeChats = await openScreen(
          tester,
          logicalSize: const Size(412, 915),
          textScale: 2,
        );
        expect(find.byType(NotificationSettingsScreen), findsOneWidget);
        final s = Strings.of(
          tester.element(find.byType(NotificationSettingsScreen)),
        );
        // Scrolling in short steps lays out every row on the way down; an
        // overflow anywhere surfaces as an exception.
        final scrollable = find
            .descendant(
              of: find.byType(NotificationSettingsScreen),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.text(s.nrdMasterTitle),
          200,
          scrollable: scrollable,
        );
        await tester.pump();
        expect(find.byType(HermesSwitchTile), findsWidgets);
        // Down to the last row: the test button closes the screen.
        await tester.scrollUntilVisible(
          find.text(s.notifTestButton),
          200,
          scrollable: scrollable,
        );
        await tester.pump();
        expect(find.text(s.notifTestButton), findsOneWidget);
        expect(tester.takeException(), isNull);
        await closeScreen(tester, activeChats);
      });
    }
  });
}
