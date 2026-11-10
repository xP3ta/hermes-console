import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async =>
              call.method == 'readAll' ? <String, String>{} : null,
        );
  });

  Future<ConnectionManager> managerWith(
    List<String> ids, {
    Map<String, Object> extra = const {},
  }) async {
    SharedPreferences.setMockInitialValues({
      if (ids.isNotEmpty)
        'saved_connections': [
          for (final id in ids)
            jsonEncode({
              'id': id,
              'label': id,
              'host': '192.168.1.50',
              'port': 8642,
            }),
        ],
      ...extra,
    });
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    addTearDown(manager.dispose);
    return manager;
  }

  test('one connection that is not the default is the active one', () async {
    final m = await managerWith(['solo']);
    expect(m.defaultConnectionId, isNull);
    expect(m.resolveActiveConnectionId(), 'solo');
    // The notifier is seeded at creation, not only by applyDefaultOnLaunch.
    expect(m.activeConnectionId.value, 'solo');
    expect(m.resolveActiveConnection()?.id, 'solo');
  });

  test('several connections: the last used wins, then the default', () async {
    final withLast = await managerWith(
      ['a', 'b', 'c'],
      extra: {
        ConnectionManager.lastConnKey: 'b',
        ConnectionManager.defaultConnKey: 'c',
      },
    );
    expect(withLast.resolveActiveConnectionId(), 'b');

    final onlyDefault = await managerWith(
      ['a', 'b', 'c'],
      extra: {ConnectionManager.defaultConnKey: 'c'},
    );
    expect(onlyDefault.resolveActiveConnectionId(), 'c');
  });

  test('an invalid lastConnKey is ignored', () async {
    final fallsToDefault = await managerWith(
      ['a', 'b'],
      extra: {
        ConnectionManager.lastConnKey: 'ghost',
        ConnectionManager.defaultConnKey: 'b',
      },
    );
    expect(fallsToDefault.resolveActiveConnectionId(), 'b');

    final fallsToOnly = await managerWith(
      ['a'],
      extra: {ConnectionManager.lastConnKey: 'ghost'},
    );
    expect(fallsToOnly.resolveActiveConnectionId(), 'a');
  });

  test('several connections and nothing chosen: null, not a guess', () async {
    final m = await managerWith(['a', 'b']);
    expect(m.resolveActiveConnectionId(), isNull);
    expect(m.activeConnectionId.value, isNull);
  });

  test('no connections: null', () async {
    final m = await managerWith([]);
    expect(m.resolveActiveConnectionId(), isNull);
    expect(m.resolveActiveConnection(), isNull);
  });

  test('switching instance updates the resolution and the notifier', () async {
    final m = await managerWith(['a', 'b'], extra: {
      ConnectionManager.defaultConnKey: 'a',
    });
    expect(m.resolveActiveConnectionId(), 'a');
    var notified = 0;
    m.activeConnectionId.addListener(() => notified++);
    await m.setActiveConnection('b');
    expect(m.resolveActiveConnectionId(), 'b');
    expect(notified, 1);
  });

  test('a live value pointing at a deleted instance is not returned', () async {
    final m = await managerWith(['a', 'b']);
    await m.setActiveConnection('b');
    await m.deleteConnection('b');
    expect(m.resolveActiveConnectionId(), 'a');
  });
}
