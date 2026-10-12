import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('visibleSession notifies when the visible chat changes', () async {
    SharedPreferences.setMockInitialValues(const {});
    final notifications = NotificationService(
      await SharedPreferences.getInstance(),
    );
    final seen = <String?>[];
    notifications.visibleSession.addListener(
      () => seen.add(notifications.visibleSession.value),
    );
    notifications.visibleSessionId = 'chat-1';
    notifications.visibleSessionId = 'chat-1';
    notifications.visibleSessionId = null;
    expect(seen, ['chat-1', null]);
  });

  test('visibleSessionId keeps reading and writing the same value', () async {
    SharedPreferences.setMockInitialValues(const {});
    final notifications = NotificationService(
      await SharedPreferences.getInstance(),
    );
    expect(notifications.visibleSessionId, isNull);
    notifications.visibleSessionId = 'chat-2';
    expect(notifications.visibleSessionId, 'chat-2');
    expect(notifications.visibleSession.value, 'chat-2');
  });
}
