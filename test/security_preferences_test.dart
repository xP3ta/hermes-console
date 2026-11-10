import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/screen_security.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ocultación de notificaciones: activa por defecto y persiste la elección', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final notifications = NotificationService(prefs);

    // Nobody chose: the text of a notice is not on the lock screen, a watch
    // or any notification listener (audit A6).
    expect(notifications.hideSensitiveContent, isTrue);
    await notifications.setHideSensitiveContent(false);
    expect(notifications.hideSensitiveContent, isFalse);
    expect(NotificationService(prefs).hideSensitiveContent, isFalse);
    await notifications.setHideSensitiveContent(true);
    expect(NotificationService(prefs).hideSensitiveContent, isTrue);
  });

  test(
    'protección de capturas persiste y aplica FLAG_SECURE por canal',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final calls = <MethodCall>[];
      const channel = MethodChannel('hermes/security');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final security = ScreenSecurityService(prefs);
      expect(security.enabled, isFalse);
      await security.setEnabled(true);

      expect(security.enabled, isTrue);
      expect(calls.single.method, 'setSecureScreen');
      expect(calls.single.arguments, isTrue);
    },
  );
}
