// Battery: the UI liveness heartbeat only matters to the listener auto-stop,
// which ignores it while the automation opt-in is on. With the opt-in on the
// minute tick must not cross the platform channel nor write preferences; with
// it off the heartbeat keeps refreshing exactly as before.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/background_listener.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('flutter_foreground_task/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> calls;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call.method);
      return call.method == 'isRunningService' ? true : null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(methods, null));

  test('opt-in on: the tick neither probes the service nor writes', () async {
    SharedPreferences.setMockInitialValues({
      BackgroundListener.prefKey: true,
      BackgroundListener.uiAliveKey: 1,
    });
    await BackgroundListener.runUiHeartbeatTickForTest();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(BackgroundListener.uiAliveKey), 1);
    expect(calls, isNot(contains('isRunningService')));
  });

  test('opt-in off: the tick refreshes the liveness stamp', () async {
    SharedPreferences.setMockInitialValues({
      BackgroundListener.prefKey: false,
      BackgroundListener.uiAliveKey: 1,
    });
    await BackgroundListener.runUiHeartbeatTickForTest();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(BackgroundListener.uiAliveKey), greaterThan(1));
  });

  test('turning the opt-in off stamps liveness at once', () async {
    SharedPreferences.setMockInitialValues({
      BackgroundListener.prefKey: true,
      BackgroundListener.uiAliveKey: 1,
    });
    await BackgroundListener.stopAutomation();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(BackgroundListener.uiAliveKey), greaterThan(1));
  });
}
