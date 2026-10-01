import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/app_error_log.dart';
import 'package:hermes_android/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secure = <String, String>{};
  final writes = <String>[];
  String? failReadKey;

  setUp(() {
    AppErrorLog.resetForTesting();
    secure.clear();
    writes.clear();
    failReadKey = null;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = (call.arguments as Map).cast<String, dynamic>();
          final key = args['key'] as String?;
          switch (call.method) {
            case 'read':
              if (key == failReadKey) {
                throw PlatformException(code: 'storage-unavailable');
              }
              return secure[key];
            case 'readAll':
              return Map<String, String>.of(secure);
            case 'write':
              writes.add(key!);
              secure[key] = args['value'] as String;
            case 'delete':
              writes.add('delete:$key');
              secure.remove(key);
          }
          return null;
        });
  });

  Map<String, Object> savedConnection() => {
    'saved_connections': [
      jsonEncode({
        'id': 'conn-a',
        'label': 'Server',
        'host': 'example.invalid',
        'port': 443,
        'use_https': true,
      }),
    ],
    'default_connection_id': 'conn-a',
  };

  test('a corrupt Stop tombstone blob does not block startup and is kept '
      'untouched', () async {
    SharedPreferences.setMockInitialValues(savedConnection());
    secure['cancelled_turn_tombstones_v2'] = '{corrupt';
    secure['api_key_conn-a'] = 'key-a';

    final app = await bootstrapHermesApp();

    expect(app, isA<HermesApp>());
    final hermes = app as HermesApp;
    expect(hermes.connManager.getConnections().single.apiKey, 'key-a');
    expect(hermes.connManager.activeConnectionId.value, 'conn-a');
    expect(secure['cancelled_turn_tombstones_v2'], '{corrupt');
    expect(writes, isEmpty);
    expect(
      AppErrorLog.recent.map((r) => (r.source, r.errorType)),
      contains(('startup', 'FormatException')),
    );
  });

  test('an unreadable activity journal does not block startup', () async {
    SharedPreferences.setMockInitialValues(savedConnection());
    failReadKey = 'global_public_activity_journal_v1';

    final app = await bootstrapHermesApp();

    expect(app, isA<HermesApp>());
    expect((app as HermesApp).activeChats.globalActivity.activities, isEmpty);
  });

  test('a Keystore failure on a saved key still fails closed without '
      'rewriting connection metadata', () async {
    final initial = savedConnection();
    SharedPreferences.setMockInitialValues(initial);
    failReadKey = 'api_key_conn-a';

    await expectLater(bootstrapHermesApp(), throwsA(isA<PlatformException>()));
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getStringList('saved_connections'),
      initial['saved_connections'],
    );
    expect(writes, isEmpty);
  });

  testWidgets('without stored data the app is built with the same defaults', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final app = await tester.runAsync(bootstrapHermesApp);

    expect(app, isA<HermesApp>());
    final hermes = app! as HermesApp;
    expect(hermes.connManager.getConnections(), isEmpty);
    expect(hermes.connManager.activeConnectionId.value, isNull);
    expect(AppErrorLog.recent, isEmpty);
    expect(app, isA<Widget>());
  });
}
