// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/app_error_log.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/app_lock_sensitive_read_fence.dart';
import 'package:hermes_android/core/services/cache_settings.dart';
import 'package:hermes_android/core/services/cold_start_store.dart';
import 'package:hermes_android/core/services/cold_start_tail_cipher.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cs1215_cold_start_store_test.dart' show MemoryColdStartStorage;

Uint8List _bytes(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

String _hexOf(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

/// How [ColdStartStore.tailKey] writes an id: what a file name must not
/// carry either.
String _idHex(String value) => value.codeUnits
    .map((unit) => unit.toRadixString(16).padLeft(4, '0'))
    .join();

List<Map<String, dynamic>> _rows(String tag, int count, {int size = 10}) => [
  for (var i = count; i >= 1; i--)
    {
      'id': i,
      'role': i.isOdd ? 'user' : 'assistant',
      'content': '$tag-$i ${'x' * size}',
    },
];

/// A file read can be held, to act while it is in flight.
class _HeldFileStorage extends MemoryColdStartStorage {
  final fileReads = <String>[];
  Completer<void>? hold;
  final entered = Completer<void>();

  @override
  Future<Uint8List?> readFile(String name) async {
    fileReads.add(name);
    final gate = hold;
    if (gate != null) {
      hold = null;
      entered.complete();
      await gate.future;
    }
    return super.readFile(name);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final secure = <String, String>{};
  var readAllCalls = 0;
  String? failRead;
  String? failDelete;
  late Directory dir;

  setUp(() {
    secure.clear();
    readAllCalls = 0;
    failRead = null;
    failDelete = null;
    SecureStorageDiagnostics.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('cold-start-files');
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          if (key == failRead) {
            throw PlatformException(code: 'Exception encountered');
          }
          return secure[key];
        case 'write':
          secure[key!] = args['value'] as String;
          return null;
        case 'delete':
          if (key == failDelete) {
            failDelete = null;
            throw PlatformException(code: 'Exception encountered');
          }
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
    messenger.setMockMethodCallHandler(channel, null);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// A process of the app: secure storage (the channel) and its files.
  ColdStartStore store({CacheSettings? settings}) => ColdStartStore(
    storage: SecureColdStartStorage(directory: () async => dir),
    settings: settings,
  );

  List<File> files() => dir.listSync().whereType<File>().toList();

  Set<String> names() => {
    for (final file in files()) file.uri.pathSegments.last,
  };

  Future<void> save(
    ColdStartStore into,
    String id, {
    String connectionId = 'c',
    String profile = 'default',
    int rows = 3,
    int size = 10,
  }) => into.saveTail(
    connectionId: connectionId,
    profile: profile,
    storedSessionId: id,
    routeSessionId: id,
    aliases: {id},
    newestFirst: _rows(id, rows, size: size),
  );

  test('the cipher is ChaCha20-Poly1305: the RFC 8439 test vector', () {
    // RFC 8439 section 2.8.2 (the AEAD construction, 96-bit nonce), as any
    // other implementation computes it.
    final key = Uint8List.fromList([for (var i = 0x80; i < 0xa0; i++) i]);
    final nonce = _bytes('070000004041424344454647');
    final aad = _bytes('50515253c0c1c2c3c4c5c6c7');
    final plain = Uint8List.fromList(
      utf8.encode(
        "Ladies and Gentlemen of the class of '99: If I could offer you "
        'only one tip for the future, sunscreen would be it.',
      ),
    );
    Uint8List run(bool encrypt, Uint8List input, {Uint8List? data}) =>
        ColdStartTailCipher.aead(
          encrypt: encrypt,
          key: key,
          nonce: nonce,
          associatedData: data ?? aad,
          input: input,
        );

    final sealed = run(true, plain);

    expect(
      _hexOf(sealed),
      'd31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6'
      '3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b36'
      '92ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc'
      '3ff4def08e4b7a9de576d26586cec64b6116'
      '1ae10b594f09e26a7e902ecbd0600691',
    );
    expect(run(false, sealed), plain);
    // Altered (content or tag), truncated, or under other associated data:
    // it does not open.
    final last = sealed.length - 1;
    for (final damaged in [
      Uint8List.fromList(sealed)..[0] ^= 1,
      Uint8List.fromList(sealed)..[last] ^= 1,
      Uint8List.sublistView(sealed, 0, last),
      Uint8List.sublistView(sealed, 0, 10),
    ]) {
      expect(() => run(false, damaged), throwsA(anything));
    }
    expect(
      () => run(false, sealed, data: _bytes('50515253c0c1c2c3c4c5c6c8')),
      throwsA(anything),
    );
  });

  test('a tail round-trips through a sealed file that shows nothing in '
      'clear', () async {
    await store().saveTail(
      connectionId: 'conn-private',
      profile: 'default',
      storedSessionId: 'session-private',
      routeSessionId: 'session-private',
      aliases: {'session-private'},
      newestFirst: [
        {'id': 1, 'role': 'assistant', 'content': 'secreto-del-chat'},
      ],
    );

    final tails = await store().loadTails();

    expect(tails.single.storedSessionId, 'session-private');
    expect(tails.single.newestFirst.single['content'], 'secreto-del-chat');
    final file = files().single;
    final name = file.uri.pathSegments.last;
    final onDisk = latin1.decode(file.readAsBytesSync());
    for (final private in [
      'secreto-del-chat',
      'conn-private',
      'session-private',
      _idHex('session-private'),
      _idHex('conn-private'),
    ]) {
      expect(onDisk, isNot(contains(private)), reason: private);
      expect(name, isNot(contains(private)), reason: private);
    }
    for (final value in secure.values) {
      expect(value, isNot(contains('secreto-del-chat')));
    }
    expect(base64Decode(secure[ColdStartStore.fileKeyKey]!), hasLength(32));
    expect(readAllCalls, 0);
  });

  test('an altered, truncated or swapped file is a miss and is '
      'deleted', () async {
    final damages = <Uint8List Function(Uint8List)>[
      (bytes) => Uint8List.fromList(bytes)..[bytes.length - 1] ^= 1,
      (bytes) => Uint8List.sublistView(bytes, 0, bytes.length - 5),
    ];
    for (final damage in damages) {
      await save(store(), 'a');
      final file = files().single;
      file.writeAsBytesSync(damage(file.readAsBytesSync()));

      expect(await store().loadTails(), isEmpty);
      expect(files(), isEmpty);
      final index = jsonDecode(secure[ColdStartStore.indexKey]!) as Map;
      expect(index['tails'], isEmpty);
    }

    // Another tail's bytes under this tail's name do not open either.
    final writer = store();
    await save(writer, 'a');
    final first = names().single;
    await save(writer, 'b');
    final second = names().difference({first}).single;
    File('${dir.path}/$second').writeAsBytesSync(
      File('${dir.path}/$first').readAsBytesSync(),
    );

    final tails = await store().loadTails();

    expect(tails.map((tail) => tail.storedSessionId), ['a']);
    expect(names(), {first});
  });

  test('a write killed before its rename leaves the previous tail and the '
      'unfinished file is deleted', () async {
    await save(store(), 'a', rows: 2);
    final name = names().single;
    // The next save of that chat died after writing its unfinished file.
    File(
      '${dir.path}/$name${SecureColdStartStorage.partialSuffix}',
    ).writeAsBytesSync(List.filled(64, 7));

    final tails = await store().loadTails();

    expect(tails.single.newestFirst, hasLength(2));
    expect(names(), {name});
  });

  test('a first write killed before its rename shows nothing', () async {
    await save(store(), 'a');
    final file = files().single;
    // Complete bytes, but never renamed: they are not the tail.
    file.renameSync('${file.path}${SecureColdStartStorage.partialSuffix}');

    expect(await store().loadTails(), isEmpty);
    expect(files(), isEmpty);
  });

  /// What an older version left: the index and the tails themselves in
  /// secure storage, [ids] of [size] characters each.
  void olderVersion(List<String> ids, {int size = 900 * 1024}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    secure[ColdStartStore.indexKey] = jsonEncode({
      'v': 1,
      'routes': {
        'c': ColdStartRoute(
          kind: ColdStartRouteKind.chat,
          connectionId: 'c',
          profile: 'default',
          sessionId: ids.first,
          savedAtMs: now,
        ).toJson(),
      },
      'tails': [
        for (final id in ids)
          {
            'k': ColdStartStore.tailKey('c', 'default', id),
            'c': 'c',
            'p': 'default',
            's': id,
            'a': [id],
            'b': size,
            't': now,
          },
      ],
    });
    for (final id in ids) {
      secure[ColdStartStore.tailKey('c', 'default', id)] = 'x' * size;
    }
  }

  Iterable<String> secureTails() =>
      secure.keys.where((key) => key.startsWith('cold_start_tail_v1.'));

  test('an upgrade deletes the tails secure storage held, by name, and no '
      'large value enters it again', () async {
    olderVersion(['a', 'b']);
    secure['api_key_c'] = 'unrelated';

    final upgraded = store();
    expect(await upgraded.loadTails(), isEmpty);

    expect(secureTails(), isEmpty);
    expect(secure['api_key_c'], 'unrelated');
    expect((await upgraded.routeFor('c'))?.sessionId, 'a');
    // The cache refills as chats are opened: about 1 MiB, in a file.
    await save(upgraded, 'a', rows: 120, size: 8000);
    expect((await store().loadTails()).single.storedSessionId, 'a');
    expect(files().single.lengthSync(), greaterThan(512 * 1024));
    expect(readAllCalls, 0);
    for (final entry in secure.entries) {
      if (!entry.key.startsWith('cold_start')) continue;
      expect(entry.value.length, lessThan(4096), reason: entry.key);
    }
  });

  test('an upgrade cut short finishes on the next launch', () async {
    olderVersion(['a', 'b', 'c'], size: 64);
    failDelete = ColdStartStore.tailKey('c', 'default', 'b');

    expect(await store().loadTails(), isEmpty);
    expect(secureTails(), isNotEmpty);

    expect(await store().loadTails(), isEmpty);
    expect(secureTails(), isEmpty);
    expect(readAllCalls, 0);
  });

  test('every cleanup removes the files of its scope and keeps the '
      'others', () async {
    Future<ColdStartStore> seeded() async {
      final seeded = store();
      for (final (connectionId, profile, id) in [
        ('c1', 'default', 'a'),
        ('c1', 'work', 'b'),
        ('c2', 'default', 'c'),
      ]) {
        await save(seeded, id, connectionId: connectionId, profile: profile);
      }
      expect(files(), hasLength(3));
      return seeded;
    }

    Future<Set<String>> kept() async => {
      for (final tail in await store().loadTails()) tail.storedSessionId,
    };

    final cleaner = await seeded();
    await cleaner.forgetSession(
      connectionId: 'c1',
      profile: 'default',
      sessionId: 'a',
    );
    expect(files(), hasLength(2));
    expect(await kept(), {'b', 'c'});
    await cleaner.forgetScope('c1', profile: 'work');
    expect(files(), hasLength(1));
    expect(await kept(), {'c'});
    await cleaner.forgetScope('c2');
    expect(files(), isEmpty);

    // Settings, Cache: Messages off or Clear.
    await (await seeded()).clearMessages();
    expect(files(), isEmpty);
    expect(secure.containsKey(ColdStartStore.fileKeyKey), isFalse);

    // Credentials wiped.
    await (await seeded()).clearAll();
    expect(files(), isEmpty);
    expect(secure.keys.where((key) => key.startsWith('cold_start')), isEmpty);
  });

  test('the caps hold on disk: the chats the user keeps, 1 MiB '
      'each', () async {
    final settings = CacheSettings(await SharedPreferences.getInstance());
    await settings.setMaxChats(10);
    final limited = store(settings: settings);
    for (var i = 0; i < 12; i++) {
      await save(limited, 's$i');
    }
    expect(files(), hasLength(10));

    await save(limited, 'big', rows: 120, size: 20000);
    final big = (await store(settings: settings).loadTails()).first;
    expect(big.storedSessionId, 'big');
    expect(big.newestFirst.length, lessThan(120));
    final largest = files()
        .map((file) => file.lengthSync())
        .reduce((a, b) => a > b ? a : b);
    expect(largest, lessThanOrEqualTo(ColdStartStore.maxEntryBytes + 1024));
  });

  test('a lost key deletes the files, starts empty and is in the '
      'diagnostics', () async {
    final writer = store();
    await save(writer, 'a');
    await save(writer, 'b');
    // Secure storage wiped (or the app data restored without it).
    secure.remove(ColdStartStore.fileKeyKey);

    final relaunched = store();
    expect(await relaunched.loadTails(), isEmpty);

    expect(files(), isEmpty);
    expect(
      SecureStorageDiagnostics.recent.map((f) => (f.operation, f.errorType)),
      contains((SecureStorageOperation.coldStartKey, 'ColdStartKeyLost')),
    );
    await save(relaunched, 'c');
    expect((await store().loadTails()).single.storedSessionId, 'c');
  });

  test('an unreadable key does the same', () async {
    await save(store(), 'a');
    failRead = ColdStartStore.fileKeyKey;

    expect(await store().loadTails(), isEmpty);

    expect(files(), isEmpty);
    expect(
      SecureStorageDiagnostics.recent.map((f) => (f.operation, f.errorType)),
      contains((SecureStorageOperation.coldStartKey, 'PlatformException')),
    );
  });

  test('App Lock: nothing is read while it is closed, and closing it during '
      'a read stops the reads', () async {
    SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
    final prefs = await SharedPreferences.getInstance();
    final lock = AppLockService(prefs)..unlock();
    final storage = _HeldFileStorage();
    final writer = ColdStartStore(storage: storage);
    await save(writer, 'a');
    await save(writer, 'b');

    lock.lockNow();
    await expectLater(
      ColdStartStore(storage: storage).loadTails(),
      throwsA(isA<SensitiveReadUnavailable>()),
    );
    expect(storage.fileReads, isEmpty);

    lock.unlock();
    final gate = Completer<void>();
    storage.hold = gate;
    final reading = ColdStartStore(storage: storage).loadTails();
    await storage.entered.future;
    lock.lockNow();
    gate.complete();

    await expectLater(reading, throwsA(isA<SensitiveReadUnavailable>()));
    expect(storage.fileReads, hasLength(1));
  });
}
