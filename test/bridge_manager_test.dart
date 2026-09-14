import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

final values = <String, String>{};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    values.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map).cast<String, dynamic>();
            final key = args['key'] as String?;
            if (call.method == 'read') return values[key];
            if (call.method == 'write') {
              values[key!] = args['value'] as String;
              return null;
            }
            if (call.method == 'delete') {
              values.remove(key);
              return null;
            }
            return null;
          },
        );
  });

  test('manager uses saved bridge URL before HTTPS derived origin', () async {
    final manager = await _connections(
      dashboardUrl: 'https://console.example/base',
    );
    values['bridge_url_c1'] = 'https://bridge.example:9443/custom';
    final bridge = BridgeManager(SecureStorage(), manager);

    final endpoint = await bridge.effectiveUrl('c1');

    expect(endpoint?.url, 'https://bridge.example:9443/custom');
    expect(endpoint?.derived, isFalse);
    manager.dispose();
  });

  test('manager derives HTTPS bridge from external dashboard path', () async {
    final manager = await _connections(
      dashboardUrl: 'https://console.example:8443/base',
    );
    final bridge = BridgeManager(SecureStorage(), manager);

    final endpoint = await bridge.effectiveUrl('c1');

    expect(endpoint?.url, 'https://console.example:8443/base');
    expect(endpoint?.derived, isTrue);
    manager.dispose();
  });
}

Future<ConnectionManager> _connections({String? dashboardUrl}) async {
  final connection = SavedConnection(
    id: 'c1',
    label: 'Remote',
    host: 'console.example',
    port: 443,
    useHttps: true,
    dashboardUrl: dashboardUrl,
    apiKey: '',
  );
  SharedPreferences.setMockInitialValues({
    'saved_connections': [jsonEncode(connection.toMap())],
  });
  values['api_key_c1'] = 'gateway-key';
  return ConnectionManager.create(await SharedPreferences.getInstance());
}
