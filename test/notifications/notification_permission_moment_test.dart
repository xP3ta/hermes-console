// Notifications are not asked for when the app opens. The system dialog
// comes once, the first time there is a Hermes to hear from, and never
// again; the switches in the notification settings ask on their own.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show SizedBox;
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/services/notifications/notification_permission_moment.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/onboarding_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const notifications = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final calls = <String>[];
  final secureStore = <String, String>{};

  setUp(() {
    calls.clear();
    secureStore.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(notifications, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'initialize' ||
        'areNotificationsEnabled' ||
        'requestNotificationsPermission' => true,
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(secure, (call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
      switch (call.method) {
        case 'write':
          secureStore[args['key'] as String] = args['value'] as String;
          return null;
        case 'read':
          return secureStore[args['key'] as String];
        case 'readAll':
          return Map<String, String>.from(secureStore);
        case 'delete':
          secureStore.remove(args['key'] as String);
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(notifications, null);
    messenger.setMockMethodCallHandler(secure, null);
  });

  int asks() => calls
      .where((method) => method == 'requestNotificationsPermission')
      .length;

  SavedConnection conn(String id) => SavedConnection(
    id: id,
    label: 'Casa',
    host: '$id.invalid',
    port: 8642,
    apiKey: 'gateway-key',
    useHttps: true,
  );

  test('opening the app asks for nothing', () async {
    SharedPreferences.setMockInitialValues({'app_locale': 'es'});
    final prefs = await SharedPreferences.getInstance();
    final service = NotificationService(prefs);

    await service.init();

    expect(calls, contains('initialize'));
    expect(asks(), 0);
    expect(prefs.getBool('notif_perm_requested'), isNull);
  });

  test(
    'the ask is the system dialog, once, and only in the foreground',
    () async {
      SharedPreferences.setMockInitialValues({'app_locale': 'es'});
      final prefs = await SharedPreferences.getInstance();
      final service = NotificationService(prefs);
      await service.init();

      service.appInForeground = false;
      await service.requestPermissionWhenUseful();
      expect(asks(), 0, reason: 'no Activity to show the dialog');
      expect(prefs.getBool('notif_perm_requested'), isNull);

      service.appInForeground = true;
      await service.requestPermissionWhenUseful();
      await service.requestPermissionWhenUseful();
      expect(asks(), 1);
      expect(prefs.getBool('notif_perm_requested'), isTrue);

      // An install that was asked by an older version is not asked again.
      final later = NotificationService(prefs);
      await later.init();
      await later.requestPermissionWhenUseful();
      expect(asks(), 1);
    },
  );

  test(
    'the moment is the first connection, not the first-run screens',
    () async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      addTearDown(manager.dispose);
      var requests = 0;
      var firstRun = true;
      final moment = NotificationPermissionMoment(
        connManager: manager,
        request: () async => requests++,
        quiet: () => firstRun,
      );

      // Launch, with no Hermes yet: nothing to ask.
      firstRun = false;
      moment.check();
      expect(requests, 0);

      // Still in the first-run screens when something is saved: not yet.
      firstRun = true;
      await manager.upsertConnection(conn('c1'));
      expect(requests, 0);

      // Past them, the connection that is there is the moment.
      firstRun = false;
      moment.check();
      expect(requests, 1);

      // Saving another one comes through the same door; the service is the
      // one that remembers it already asked.
      await manager.upsertConnection(conn('c2'));
      expect(requests, 2);

      moment.dispose();
      await manager.upsertConnection(conn('c3'));
      moment.check();
      expect(requests, 2);
    },
  );

  testWidgets('re-entering from empty Home defers the ask until Home returns', (
    tester,
  ) async {
    // An older install already completed its intro, but has no connection.
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    addTearDown(manager.dispose);
    var requests = 0;
    var completed = false;
    final moment = NotificationPermissionMoment(
      connManager: manager,
      request: () async => requests++,
      quiet: () => false,
    );
    addTearDown(moment.dispose);
    await tester.pumpWidget(
      onboardingHost(
        OnboardingScreen(
          connManager: manager,
          initialLink: fakeFullPairing,
          diagnostics: OnboardingDiagnostics(),
          onDone: () => completed = true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapOnboarding(tester, 'onboarding-confirm');
    expect(manager.getConnections(), hasLength(1));
    moment.check();
    expect(requests, 0, reason: 'the success screen is still part of O2');
    await tapOnboarding(tester, 'onboarding-done');
    expect(completed, isTrue);
    expect(requests, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(requests, 1);
    // testWidgets checks the invariants before tearDown runs.
    debugDefaultTargetPlatformOverride = null;
  });
}
