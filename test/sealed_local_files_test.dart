// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/cold_start_tail_cipher.dart';
import 'package:hermes_android/core/services/sealed_local_files.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_sealed_files.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final secure = <String, String>{};
  final writes = <String>[];

  setUp(() {
    secure.clear();
    writes.clear();
    SharedPreferences.setMockInitialValues({});
    TurnOutboxStore.resetSerializationForTesting();
    for (final family in SealedLocalFiles.families) {
      MemorySealedFileIo.of(family).files.clear();
    }
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          // Yield, like the platform: concurrent first uses interleave.
          await Future<void>.delayed(Duration.zero);
          return secure[key];
        case 'write':
          writes.add(key!);
          secure[key] = args['value'] as String;
          return null;
        case 'delete':
          secure.remove(key);
          return null;
        case 'readAll':
          return Map<String, String>.from(secure);
      }
      return null;
    });
  });

  tearDown(() {
    MemorySealedFileIo.install();
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(pathProvider, null);
  });

  test('two stores writing their first file together get one key, and '
      'both files open with it', () async {
    final drafts = SealedLocalFiles(SealedLocalFiles.drafts);
    final outbox = SealedLocalFiles(SealedLocalFiles.outbox);

    await Future.wait([
      drafts.write(const SealedName('draft-key', ['c', 'p', 's']), 'borrador'),
      outbox.write(const SealedName('outbox-key'), 'outbox'),
    ]);

    expect(writes.where((key) => key == SealedLocalFiles.keyKey), hasLength(1));
    TurnOutboxStore.resetSerializationForTesting();
    expect(
      await drafts.read(const SealedName('draft-key', ['c', 'p', 's'])),
      'borrador',
    );
    expect(await outbox.read(const SealedName('outbox-key')), 'outbox');
  });

  for (final delete in [false, true]) {
    test('a draft migration cannot undo a concurrent '
        '${delete ? 'delete' : 'save'}', () async {
      const name = SealedName('legacy-draft', ['c', 'p', 's']);
      final store = SealedLocalFiles(SealedLocalFiles.drafts);
      secure[name.key] = 'old text';
      final entered = Completer<void>();
      final release = Completer<void>();
      MemorySealedFileIo.of(SealedLocalFiles.drafts).beforeWrite = (_) async {
        if (entered.isCompleted) return;
        entered.complete();
        await release.future;
      };

      final migrating = store.read(name);
      await entered.future.timeout(const Duration(seconds: 5));
      final editing = delete
          ? store.delete(name)
          : store.write(name, 'new text');
      // The fake's key read yields once. Let an independent write or delete
      // reach storage while the migration still has its old snapshot.
      await Future<void>.delayed(Duration.zero);
      release.complete();
      await Future.wait([migrating, editing]);
      TurnOutboxStore.resetSerializationForTesting();

      expect(await store.read(name), delete ? isNull : 'new text');
      expect(secure.containsKey(name.key), isFalse);
    });
  }

  test('a file name tells nothing of the chat, the connection or the '
      'profile, and its bytes nothing of the text', () async {
    const connection = 'conn-very-private';
    const session = 'session-very-private';
    final store = ChatDraftStore(await SharedPreferences.getInstance());
    await store.save(
      connection,
      session,
      'texto muy privado',
      const [],
      profile: 'work',
    );

    final files = MemorySealedFileIo.of(SealedLocalFiles.drafts).files;
    final name = files.keys.single;
    final key = ChatDraftStore.keyForTesting(
      connection,
      session,
      profile: 'work',
    );
    for (final clear in [
      connection,
      session,
      'work',
      ...key.split('.'),
      base64Url.encode(utf8.encode(connection)).replaceAll('=', ''),
    ]) {
      expect(name, isNot(contains(clear)), reason: clear);
    }
    expect(name, matches(RegExp(r'^([0-9a-f]{16}\.){4}ct$')));
    expect(
      latin1.decode(files.values.single),
      allOf(isNot(contains('privado')), isNot(contains(connection))),
    );
    // Sealed for its name: the same bytes under another name do not open.
    final bytes = files.values.single;
    final cipher = ColdStartTailCipher(
      base64Decode(secure[SealedLocalFiles.keyKey]!),
    );
    expect(await cipher.open(name, bytes), isNotNull);
    expect(await cipher.open('x$name', bytes), isNull);
  });

  test('a scope selects the files of a connection, of one profile, or of '
      'one chat in every profile, unfinished writes included', () async {
    final files = SealedLocalFiles(SealedLocalFiles.transcripts);
    Future<void> put(String c, String p, String s) =>
        files.write(SealedName('$c/$p/$s', [c, p, s]), '$c $p $s');
    await put('c1', 'p1', 's1');
    await put('c1', 'p2', 's1');
    await put('c1', 'p1', 's2');
    await put('c2', 'p1', 's1');
    final memory = MemorySealedFileIo.of(SealedLocalFiles.transcripts);
    final unfinished = '${memory.files.keys.first}.part';
    memory.files[unfinished] = Uint8List(3);

    Future<Set<String>> keys(List<String?> scope) async =>
        (await files.readScope(scope)).values.keys.toSet();

    expect(await keys(['c1']), {'c1/p1/s1', 'c1/p2/s1', 'c1/p1/s2'});
    expect(await keys(['c1', 'p1']), {'c1/p1/s1', 'c1/p1/s2'});
    expect(await keys(['c1', null, 's1']), {'c1/p1/s1', 'c1/p2/s1'});
    expect(await keys(const []), hasLength(4));
    expect((await files.readScope(const [])).partial, [unfinished]);

    expect(await files.deleteScope(['c1', null, 's1']), greaterThan(1));
    expect(await keys(const []), {'c1/p1/s2', 'c2/p1/s1'});
  });

  test('in the app the files live under the app-private support directory, '
      'which no backup and no device transfer copies', () async {
    final support = Directory.systemTemp.createTempSync('support-dir-');
    addTearDown(() => support.deleteSync(recursive: true));
    messenger.setMockMethodCallHandler(pathProvider, (call) async {
      expect(call.method, 'getApplicationSupportDirectory');
      return support.path;
    });
    SealedLocalFiles.ioForTesting = null;

    await SealedLocalFiles(
      SealedLocalFiles.drafts,
    ).write(const SealedName('draft-key', ['c', 'p', 's']), 'borrador');

    final written = Directory(
      '${support.path}/${SealedLocalFiles.rootName}/drafts',
    ).listSync().whereType<File>();
    expect(written, hasLength(1));

    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest, contains('android:allowBackup="false"'));
    expect(manifest, contains('android:fullBackupContent="false"'));
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
    final rules = File(
      'android/app/src/main/res/xml/data_extraction_rules.xml',
    ).readAsStringSync();
    for (final section in ['cloud-backup', 'device-transfer']) {
      final body = RegExp(
        '<$section[^>]*>(.*?)</$section>',
        dotAll: true,
      ).firstMatch(rules)?.group(1);
      expect(body, isNotNull, reason: section);
      expect(
        body,
        contains('<exclude domain="file" path="." />'),
        reason: section,
      );
    }
  });
}
