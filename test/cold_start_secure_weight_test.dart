// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/cold_start_store.dart';

/// What the cold-start cache leaves in secure storage, which the plugin keeps
/// in one file Android loads whole into memory on the first read of any key.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final secure = <String, String>{};
  final reads = <String>[];
  var readAllCalls = 0;
  late Directory folders;

  setUp(() {
    secure.clear();
    reads.clear();
    readAllCalls = 0;
    folders = Directory.systemTemp.createTempSync('cold-start-weight');
    messenger.setMockMethodCallHandler(pathProvider, (_) async => folders.path);
    messenger.setMockMethodCallHandler(secureChannel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          reads.add(key!);
          return secure[key];
        case 'write':
          secure[key!] = args['value'] as String;
          return null;
        case 'delete':
          secure.remove(key);
          return null;
        case 'readAll':
          readAllCalls++;
          return Map<String, String>.from(secure);
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(secureChannel, null);
    messenger.setMockMethodCallHandler(pathProvider, null);
    if (folders.existsSync()) folders.deleteSync(recursive: true);
  });

  test('a chat tail of about 1 MiB leaves no large value in secure '
      'storage', () async {
    final store = ColdStartStore();
    await store.saveTail(
      connectionId: 'c',
      profile: 'default',
      storedSessionId: 's',
      routeSessionId: 's',
      aliases: {'s'},
      newestFirst: [
        for (var i = 120; i >= 1; i--)
          {'id': i, 'role': 'assistant', 'content': 'row $i ${'x' * 8000}'},
      ],
    );

    expect(
      (await ColdStartStore().loadTails()).single.newestFirst.length,
      greaterThan(100),
    );
    for (final entry in secure.entries) {
      if (!entry.key.startsWith('cold_start')) continue;
      expect(entry.value.length, lessThan(4096), reason: entry.key);
    }
    expect(readAllCalls, 0);
  });

  test('the tails an older version kept in secure storage are deleted by '
      'name, never read nor listed', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final keys = <String>[];
    final tails = <Map<String, Object?>>[];
    for (final id in ['a', 'b']) {
      final key = ColdStartStore.tailKey('c', 'default', id);
      keys.add(key);
      secure[key] = jsonEncode({
        'v': 1,
        'c': 'c',
        'p': 'default',
        's': id,
        'r': id,
        'a': [id],
        'rows': [
          {'id': 1, 'role': 'assistant', 'content': 'kept by 1.4 $id'},
        ],
      });
      tails.add({
        'k': key,
        'c': 'c',
        'p': 'default',
        's': id,
        'a': [id],
        'b': secure[key]!.length,
        't': now,
      });
    }
    secure[ColdStartStore.indexKey] = jsonEncode({
      'v': 1,
      'routes': {},
      'tails': tails,
    });

    expect(await ColdStartStore().loadTails(), isEmpty);

    expect(reads.where(keys.contains), isEmpty);
    expect(secure.keys.where(keys.contains), isEmpty);
    expect(readAllCalls, 0);
  });
}
