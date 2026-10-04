// A page can force FLAG_SECURE on while it is visible without touching the
// user's global preference; the previous state comes back when the last
// nested page leaves.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/screen_security.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <bool>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('hermes/security'), (
          call,
        ) async {
          if (call.method == 'setSecureScreen')
            calls.add(call.arguments as bool);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('hermes/security'), null);
  });

  Future<ScreenSecurityService> service({required bool preference}) async {
    SharedPreferences.setMockInitialValues({
      ScreenSecurityService.prefKey: preference,
    });
    return ScreenSecurityService(await SharedPreferences.getInstance());
  }

  test(
    'enter forces secure on and leave restores a false preference',
    () async {
      final s = await service(preference: false);
      final lease = await s.pushSecureScope();
      expect(calls.last, isTrue);
      await lease.release();
      expect(calls.last, isFalse);
      expect(s.enabled, isFalse, reason: 'the global preference is untouched');
    },
  );

  test('leave keeps secure on when the preference is on', () async {
    final s = await service(preference: true);
    final lease = await s.pushSecureScope();
    await lease.release();
    expect(calls.last, isTrue);
  });

  test('nested scopes only restore when the last one leaves', () async {
    final s = await service(preference: false);
    final outer = await s.pushSecureScope();
    final inner = await s.pushSecureScope();
    await inner.release();
    expect(calls.last, isTrue, reason: 'outer page still visible');
    await outer.release();
    expect(calls.last, isFalse);
  });

  test('releasing twice never drops another page\'s scope', () async {
    final s = await service(preference: false);
    final a = await s.pushSecureScope();
    final b = await s.pushSecureScope();
    await a.release();
    await a.release();
    expect(calls.last, isTrue);
    await b.release();
    expect(calls.last, isFalse);
  });

  test(
    'turning the preference off mid-scope keeps the page protected',
    () async {
      final s = await service(preference: true);
      final lease = await s.pushSecureScope();
      await s.setEnabled(false);
      expect(calls.last, isTrue);
      await lease.release();
      expect(calls.last, isFalse);
    },
  );
}
