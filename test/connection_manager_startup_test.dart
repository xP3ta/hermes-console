import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

class _GatedRemovePrefs extends InMemorySharedPreferencesStore {
  _GatedRemovePrefs(Map<String, Object> values)
    : super.withData({
        for (final entry in values.entries) 'flutter.${entry.key}': entry.value,
      });

  final pending = <String, Completer<void>>{};

  @override
  Future<bool> remove(String key) async {
    final gate = pending[key] = Completer<void>();
    await gate.future;
    return super.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final values = <String, String>{};
  final pendingReads = <String, Completer<void>>{};
  var gateReads = false;
  String? failRead;

  setUp(() {
    values.clear();
    pendingReads.clear();
    gateReads = false;
    failRead = null;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = (call.arguments as Map).cast<String, dynamic>();
          final key = args['key'] as String?;
          switch (call.method) {
            case 'read':
              if (gateReads) {
                final gate = pendingReads[key!] = Completer<void>();
                await gate.future;
              }
              if (key == failRead) {
                throw PlatformException(code: 'storage-unavailable');
              }
              return values[key];
            case 'readAll':
              return Map<String, String>.of(values);
            case 'write':
              values[key!] = args['value'] as String;
            case 'delete':
              values.remove(key);
          }
          return null;
        });
  });

  String saved(String id, {String? plainKey}) => jsonEncode({
    'id': id,
    'label': id,
    'host': 'example.invalid',
    'port': 443,
    'use_https': true,
    'api_key': ?plainKey,
  });

  Future<void> flushChannel() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('startup reads every saved API key concurrently', () async {
    values
      ..['api_key_a'] = 'key-a'
      ..['api_key_b'] = 'key-b'
      ..['api_key_c'] = 'key-c';
    SharedPreferences.setMockInitialValues({
      'saved_connections': [saved('a'), saved('b'), saved('c')],
    });
    final prefs = await SharedPreferences.getInstance();
    gateReads = true;

    final creating = ConnectionManager.create(prefs);
    await flushChannel();

    expect(pendingReads.keys.toSet(), {'api_key_a', 'api_key_b', 'api_key_c'});
    for (final gate in pendingReads.values) {
      gate.complete();
    }
    final manager = await creating;
    addTearDown(manager.dispose);

    expect(
      {for (final c in manager.getConnections()) c.id: c.apiKey},
      {'a': 'key-a', 'b': 'key-b', 'c': 'key-c'},
    );
  });

  test(
    'a failed key read still aborts startup without rewriting saved metadata',
    () async {
      values['api_key_a'] = 'key-a';
      final original = [
        saved('a'),
        saved('legacy', plainKey: 'legacy-key'),
        saved('c'),
      ];
      SharedPreferences.setMockInitialValues({'saved_connections': original});
      final prefs = await SharedPreferences.getInstance();
      failRead = 'api_key_c';

      await expectLater(
        ConnectionManager.create(prefs),
        throwsA(isA<PlatformException>()),
      );
      expect(prefs.getStringList('saved_connections'), original);

      failRead = null;
      final recovered = await ConnectionManager.create(prefs);
      addTearDown(recovered.dispose);
      expect(
        {for (final c in recovered.getConnections()) c.id: c.apiKey},
        {'a': 'key-a', 'legacy': 'legacy-key', 'c': ''},
      );
      final rewritten = prefs
          .getStringList('saved_connections')!
          .map((row) => jsonDecode(row) as Map<String, dynamic>);
      expect(rewritten.map((row) => row['id']), ['a', 'legacy', 'c']);
      expect(rewritten.any((row) => row.containsKey('api_key')), isFalse);
    },
  );

  test(
    'orphan pruning removes stale keys concurrently, keeping the rest',
    () async {
      final platform = _GatedRemovePrefs({
        'saved_connections': [saved('keep')],
        'capabilities_keep': '{}',
        'capabilities_gone': '{}',
        'runs_gone': '[]',
        'hidden_sessions_gone': <String>['x'],
        'theme_mode': 'oled',
      });
      final previous = SharedPreferencesStorePlatform.instance;
      SharedPreferencesStorePlatform.instance = platform;
      addTearDown(() {
        SharedPreferencesStorePlatform.instance = previous;
        SharedPreferences.resetStatic();
      });
      SharedPreferences.resetStatic();
      final prefs = await SharedPreferences.getInstance();
      final pruning = ConnectionManager.create(prefs);
      await flushChannel();

      expect(platform.pending.keys.toSet(), {
        'flutter.capabilities_gone',
        'flutter.runs_gone',
        'flutter.hidden_sessions_gone',
      });
      for (final gate in platform.pending.values) {
        gate.complete();
      }
      final pruned = await pruning;
      addTearDown(pruned.dispose);

      expect(prefs.getKeys(), {
        'saved_connections',
        'capabilities_keep',
        'theme_mode',
      });
      expect(await pruned.pruneOrphanData(), 0);
    },
  );
}
