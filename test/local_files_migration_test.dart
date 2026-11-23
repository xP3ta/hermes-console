// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/android_share_inbox.dart';
import 'package:hermes_android/core/services/app_error_log.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/app_lock_sensitive_read_fence.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/cold_start_store.dart';
import 'package:hermes_android/core/services/cold_start_tail_cipher.dart';
import 'package:hermes_android/core/services/local_transcript_store.dart';
import 'package:hermes_android/core/services/sealed_local_files.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_sealed_files.dart';

/// A process killed in the middle of a file write or deletion.
final class _ProcessDeath implements Exception {
  const _ProcessDeath();
}

/// Where a process dies while it writes or deletes a file.
enum _Death {
  /// Before anything is on disk.
  beforeWrite,

  /// The temporary file is complete; it was never renamed.
  afterTemporary,

  /// Renamed over the file: before it is read back, before the entry it
  /// came from is deleted.
  afterRename,

  /// On deleting a file.
  onDelete,
}

enum _Hold { read, names, written }

/// The sealed files on a real disk (the production file writer), with the
/// reads observed and a process death where a test puts it.
final class _Disk {
  _Disk(this.root);

  final Directory root;

  /// Every file read: family, file name, bytes.
  final reads = <(String, String, int)>[];

  _Death? death;
  String? deathFamily;

  /// The next operation at [holdAt] in [holdFamily] waits once.
  String? holdFamily;
  _Hold holdAt = _Hold.read;
  Completer<void>? hold;
  Completer<void>? entered;

  Future<void> waitAt(String family, _Hold point) async {
    final gate = hold;
    if (gate == null || family != holdFamily || point != holdAt) return;
    hold = null;
    entered!.complete();
    await gate.future;
  }

  Directory dirOf(String family) => Directory('${root.path}/$family');

  List<String> files(String family) {
    final dir = dirOf(family);
    if (!dir.existsSync()) return [];
    return [
      for (final file in dir.listSync().whereType<File>())
        file.uri.pathSegments.last,
    ]..sort();
  }

  File file(String family, String name) => File('${dirOf(family).path}/$name');

  bool _dies(String family, _Death at) {
    if (death != at || deathFamily != family) return false;
    death = null;
    return true;
  }
}

final class _DiskIo implements SealedFileIo {
  _DiskIo(this.disk, this.family)
    : _files = SecureColdStartStorage(
        directory: () async => disk.dirOf(family),
      );

  final _Disk disk;
  final String family;
  final SecureColdStartStorage _files;

  @override
  Future<Uint8List?> readFile(String name) async {
    await disk.waitAt(family, _Hold.read);
    final bytes = await _files.readFile(name);
    if (bytes != null) disk.reads.add((family, name, bytes.length));
    return bytes;
  }

  @override
  Future<void> writeFile(String name, Uint8List bytes) async {
    if (disk._dies(family, _Death.beforeWrite)) throw const _ProcessDeath();
    if (disk._dies(family, _Death.afterTemporary)) {
      await disk.dirOf(family).create(recursive: true);
      await disk
          .file(family, '$name${SecureColdStartStorage.partialSuffix}')
          .writeAsBytes(bytes, flush: true);
      throw const _ProcessDeath();
    }
    await _files.writeFile(name, bytes);
    if (disk._dies(family, _Death.afterRename)) throw const _ProcessDeath();
    await disk.waitAt(family, _Hold.written);
  }

  @override
  Future<void> deleteFile(String name) async {
    if (disk._dies(family, _Death.onDelete)) throw const _ProcessDeath();
    await _files.deleteFile(name);
  }

  @override
  Future<List<String>> fileNames() async {
    final names = await _files.fileNames();
    await disk.waitAt(family, _Hold.names);
    return names;
  }
}

String _draft(String text) => jsonEncode({
  'savedAt': DateTime.now().millisecondsSinceEpoch,
  'text': text,
  'attachments': const <Object>[],
});

PreparedTurn _turn(
  String id, {
  String connection = 'c1',
  String session = 's1',
  String text = 'texto del turno',
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return PreparedTurn(
    connectionId: connection,
    sessionId: session,
    clientTurnId: id,
    createdAtMs: now,
    updatedAtMs: now,
    text: text,
    attachments: const [],
    model: 'm',
    profile: 'default',
  );
}

Session _row(String id) => Session(
  id: id,
  title: 'titulo $id',
  model: 'm',
  source: 'cli',
  messageCount: 2,
  isActive: false,
  preview: 'vista $id',
  startedAt: 1790000000,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final secure = <String, String>{};
  // Every secure-storage call, as "method key".
  final calls = <String>[];
  late _Disk disk;
  late SharedPreferences prefs;

  /// A new process: what the old one learned in memory is gone; secure
  /// storage and the files stay.
  void newProcess() {
    TurnOutboxStore.resetSerializationForTesting();
    LocalConversationCleanupFence.resetForTesting();
    disk.reads.clear();
    calls.clear();
  }

  int readAlls() => calls.where((call) => call == 'readAll ').length;

  setUp(() async {
    secure.clear();
    calls.clear();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    LocalConversationCleanupFence.resetForTesting();
    TurnOutboxStore.resetSerializationForTesting();
    SecureStorageDiagnostics.resetForTesting();
    disk = _Disk(Directory.systemTemp.createTempSync('local-files-'));
    SealedLocalFiles.ioForTesting = (family, _) => _DiskIo(disk, family);
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
      final key = args['key'] as String?;
      calls.add('${call.method} ${key ?? ''}');
      switch (call.method) {
        case 'read':
          return secure[key];
        case 'write':
          secure[key!] = args['value'] as String;
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
    if (disk.root.existsSync()) disk.root.deleteSync(recursive: true);
  });

  bool recorded(SecureStorageOperation operation, String type) =>
      SecureStorageDiagnostics.recent.any(
        (failure) =>
            failure.operation == operation && failure.errorType == type,
      );

  group('drafts', () {
    final key = ChatDraftStore.keyForTesting('c1', 's1');

    test('a draft an older version kept in secure storage is moved into a '
        'sealed file on its first read, and only then deleted', () async {
      secure[key] = _draft('borrador de antes');

      final first = await ChatDraftStore(prefs).load('c1', 's1');

      expect(first.text, 'borrador de antes');
      expect(secure.containsKey(key), isFalse);
      final files = disk.files(SealedLocalFiles.drafts);
      expect(files, hasLength(1));
      final bytes = disk.file(SealedLocalFiles.drafts, files.single);
      expect(latin1.decode(bytes.readAsBytesSync()), isNot(contains('antes')));
      // The order: the entry was deleted after the file was written.
      final writeAt = calls.indexOf('write ${SealedLocalFiles.keyKey}');
      expect(writeAt, isNonNegative);
      expect(calls.lastIndexOf('delete $key'), greaterThan(writeAt));

      newProcess();
      expect(
        (await ChatDraftStore(prefs).load('c1', 's1')).text,
        'borrador de antes',
      );
      expect(calls, isNot(contains('read $key')));
    });

    for (final death in [
      _Death.beforeWrite,
      _Death.afterTemporary,
      _Death.afterRename,
    ]) {
      test('a process that dies while it moves a draft ($death) loses '
          'nothing and leaves one copy after the next start', () async {
        secure[key] = _draft('lo único que escribí');
        disk
          ..death = death
          ..deathFamily = SealedLocalFiles.drafts;

        // The entry is still the copy: the draft is there.
        expect(
          (await ChatDraftStore(prefs).load('c1', 's1')).text,
          'lo único que escribí',
        );
        expect(secure.containsKey(key), isTrue);
        expect(
          recorded(SecureStorageOperation.localFilesMove, '_ProcessDeath'),
          isTrue,
        );

        newProcess();
        expect(
          (await ChatDraftStore(prefs).load('c1', 's1')).text,
          'lo único que escribí',
        );
        // One copy: the file; no entry, no unfinished write.
        expect(secure.containsKey(key), isFalse);
        expect(disk.files(SealedLocalFiles.drafts), hasLength(1));
        expect(disk.files(SealedLocalFiles.drafts).single, endsWith('.ct'));

        newProcess();
        expect(
          (await ChatDraftStore(prefs).load('c1', 's1')).text,
          'lo único que escribí',
        );
      });
    }

    test('a deletion that dies between the entry and the file never brings '
        'back an older draft', () async {
      // An older version's draft whose move died after its rename, then a
      // newer save that died before deleting the entry: the entry still
      // holds the older text, the file the newer one.
      await ChatDraftStore(prefs).save('c1', 's1', 'texto nuevo', const []);
      secure[key] = _draft('texto viejo');
      newProcess();
      disk
        ..death = _Death.onDelete
        ..deathFamily = SealedLocalFiles.drafts;

      // Remove the connection: it dies before the file is deleted.
      await expectLater(
        ChatDraftStore(prefs).deleteForConnection('c1'),
        throwsA(isA<_ProcessDeath>()),
      );

      newProcess();
      final after = (await ChatDraftStore(prefs).load('c1', 's1')).text;
      expect(after, isNot('texto viejo'));
      expect(secure.containsKey(key), isFalse);
      // The deletion runs again to its end.
      expect(await ChatDraftStore(prefs).deleteForConnection('c1'), 1);
      expect(disk.files(SealedLocalFiles.drafts), isEmpty);
      expect((await ChatDraftStore(prefs).load('c1', 's1')).text, isEmpty);
    });

    test('a draft file that does not open is an unreadable draft: deleted, '
        'with its breadcrumb', () async {
      await ChatDraftStore(prefs).save('c1', 's1', 'privado', const []);
      final name = disk.files(SealedLocalFiles.drafts).single;
      final file = disk.file(SealedLocalFiles.drafts, name);
      final bytes = file.readAsBytesSync();
      bytes[bytes.length - 1] ^= 0x01;
      file.writeAsBytesSync(bytes);
      newProcess();

      expect((await ChatDraftStore(prefs).load('c1', 's1')).text, isEmpty);

      expect(disk.files(SealedLocalFiles.drafts), isEmpty);
      expect(
        recorded(SecureStorageOperation.draftLoad, 'SealedFileUnreadable'),
        isTrue,
      );
    });

    test('a lost file key drops the files sealed with it, with a breadcrumb; '
        'the drafts start empty', () async {
      final store = ChatDraftStore(prefs);
      await store.save('c1', 's1', 'antes del borrado', const []);
      expect(disk.files(SealedLocalFiles.drafts), hasLength(1));
      // Android wiped the Keystore-backed storage; the files stayed.
      secure.clear();
      newProcess();

      expect((await ChatDraftStore(prefs).load('c1', 's1')).text, isEmpty);
      await ChatDraftStore(prefs).save('c1', 's2', 'después', const []);

      expect(disk.files(SealedLocalFiles.drafts), hasLength(1));
      expect(
        recorded(SecureStorageOperation.localFilesKey, 'SealedFileUnreadable'),
        isTrue,
      );
      expect((await ChatDraftStore(prefs).load('c1', 's2')).text, 'después');
    });

    test('a key that cannot be read is never replaced: nothing is deleted '
        'or written', () async {
      await ChatDraftStore(prefs).save('c1', 's1', 'guardado', const []);
      final files = disk.files(SealedLocalFiles.drafts);
      newProcess();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        throw PlatformException(code: 'Exception encountered');
      });

      await expectLater(
        ChatDraftStore(prefs).save('c1', 's2', 'otro', const []),
        throwsA(isA<PlatformException>()),
      );

      expect(calls, isNot(contains('write')));
      expect(calls, isNot(contains('delete')));
      expect(disk.files(SealedLocalFiles.drafts), files);
    });

    test('delete local data, remove connection and per-chat delete remove '
        'the files exactly as they removed entries; no file is left '
        'behind', () async {
      final store = ChatDraftStore(prefs);
      await store.save('c1', 's1', 'p1 s1', const [], profile: 'p1');
      await store.save('c1', 's1', 'p2 s1', const [], profile: 'p2');
      await store.save('c1', 's2', 'p1 s2', const [], profile: 'p1');
      await store.save('c1', 'mob-bot-x', 'bot', const [], profile: 'p1');
      await store.save('c2', 's1', 'otra conexión', const [], profile: 'p1');
      // An entry an older version left for that chat, never opened since.
      final legacy = ChatDraftStore.keyForTesting('c1', 's1', profile: 'p3');
      secure[legacy] = _draft('p3 s1, de antes');
      expect(disk.files(SealedLocalFiles.drafts), hasLength(5));

      /// A save of [text] a process death cuts after its temporary file.
      Future<void> diesWhileSaving(String s, String p, String text) async {
        disk
          ..death = _Death.afterTemporary
          ..deathFamily = SealedLocalFiles.drafts;
        await expectLater(
          store.save('c1', s, text, const [], profile: p),
          throwsA(isA<_ProcessDeath>()),
        );
        newProcess();
      }

      // The first save of that chat in another profile, cut short: only
      // its unfinished write holds the text.
      await diesWhileSaving('s1', 'p4', 'p4 s1, a medias');
      expect(disk.files(SealedLocalFiles.drafts), hasLength(6));

      // A chat deleted on the server: every profile's draft of it.
      await store.clearForSession('c1', 's1');
      expect(disk.files(SealedLocalFiles.drafts), hasLength(3));
      expect(secure.containsKey(legacy), isFalse);
      expect((await store.load('c1', 's1', profile: 'p1')).text, isEmpty);
      expect((await store.load('c1', 's1', profile: 'p2')).text, isEmpty);

      // A newer save of a chat of that profile, cut short.
      await diesWhileSaving('s2', 'p1', 'p1 s2, más nuevo');
      expect(disk.files(SealedLocalFiles.drafts), hasLength(4));

      // Delete local data of a profile: its chats; Bot Chat keeps its own.
      expect(await store.deleteForProfile('c1', 'p1'), 1);
      expect(disk.files(SealedLocalFiles.drafts), hasLength(2));
      expect(
        (await store.load('c1', 'mob-bot-x', profile: 'p1')).text,
        'bot',
      );

      // A write a process death interrupted, in the removed connection.
      await diesWhileSaving('s9', 'p9', 'a medias');
      expect(disk.files(SealedLocalFiles.drafts), hasLength(3));

      // Remove the connection.
      expect(await store.deleteForConnection('c1'), 1);
      final left = disk.files(SealedLocalFiles.drafts);
      expect(left, hasLength(1));
      expect(
        (await store.load('c2', 's1', profile: 'p1')).text,
        'otra conexión',
      );
    });

    test('App Lock closing during a draft file read stops it: no further '
        'file or entry is read', () async {
      SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
      prefs = await SharedPreferences.getInstance();
      final lock = AppLockService(prefs)..unlock();
      addTearDown(lock.releaseDisclosure);
      await ChatDraftStore(prefs).save('c1', 's1', 'sensible', const []);
      await ChatDraftStore(prefs).save('c1', 's2', 'vecino', const []);
      newProcess();
      disk
        ..holdFamily = SealedLocalFiles.drafts
        ..hold = Completer<void>()
        ..entered = Completer<void>();
      final release = disk.hold!;

      final listing = ChatDraftStore(prefs).listForConnection('c1');
      final assertion = expectLater(
        listing,
        throwsA(isA<SensitiveReadUnavailable>()),
      );
      await disk.entered!.future.timeout(const Duration(seconds: 5));
      lock.lockNow();
      final callsAtRevocation = calls.length;
      release.complete();
      await assertion;

      expect(disk.reads, hasLength(1));
      expect(calls.skip(callsAtRevocation), isEmpty);
    });

    for (final point in [_Hold.names, _Hold.written]) {
      test('App Lock closing while draft storage is at $point starts no '
          'further sensitive read', () async {
        SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
        prefs = await SharedPreferences.getInstance();
        final lock = AppLockService(prefs)..unlock();
        addTearDown(lock.releaseDisclosure);
        final store = ChatDraftStore(prefs);
        if (point == _Hold.names) {
          await store.save('c1', 's1', 'sensible', const []);
        } else {
          secure[key] = _draft('sensible');
        }
        newProcess();
        disk
          ..holdFamily = SealedLocalFiles.drafts
          ..holdAt = point
          ..hold = Completer<void>()
          ..entered = Completer<void>();
        final release = disk.hold!;
        final assertion = expectLater(
          point == _Hold.names
              ? store.listForConnection('c1')
              : store.load('c1', 's1'),
          throwsA(isA<SensitiveReadUnavailable>()),
        );
        await disk.entered!.future.timeout(const Duration(seconds: 5));
        lock.lockNow();
        final callsAtRevocation = calls.length;
        release.complete();
        await assertion;

        expect(disk.reads, isEmpty);
        expect(calls.skip(callsAtRevocation), isEmpty);
        if (point == _Hold.written) expect(secure[key], isNotNull);
        lock.unlock();
        expect((await store.load('c1', 's1')).text, 'sensible');
      });
    }

    test('opening one chat among 200 opens that chat\'s draft file only; '
        'Home reads its connection\'s drafts, never all of secure '
        'storage', () async {
      final store = ChatDraftStore(prefs);
      for (var i = 0; i < 200; i++) {
        final text = 'borrador $i ${'x' * 200}';
        await store.save('c1', 'chat-$i', text, const []);
      }
      for (var i = 0; i < 20; i++) {
        await store.save('c2', 'chat-$i', 'otra $i', const []);
      }
      // Home's first list after the update indexes what an older version
      // stored: once; file-backed drafts are never added to that index.
      expect(await store.listForConnection('c1'), hasLength(200));
      expect(secure[AttachmentOwnershipCoordinator.draftIndexKey], '[]');
      newProcess();

      final opened = await ChatDraftStore(prefs).load('c1', 'chat-137');

      expect(opened.text, startsWith('borrador 137 '));
      expect(disk.reads, hasLength(1));
      final (family, name, bytes) = disk.reads.single;
      expect(family, SealedLocalFiles.drafts);
      expect(bytes, disk.file(family, name).lengthSync());
      expect(bytes, lessThan(1024));
      expect(readAlls(), 0);
      expect(
        calls.where((call) => call.startsWith('read ')),
        ['read ${SealedLocalFiles.keyKey}'],
      );

      disk.reads.clear();
      calls.clear();
      final home = await ChatDraftStore(prefs).listForConnection('c1');
      expect(home, hasLength(200));
      expect(disk.reads, hasLength(200));
      expect(readAlls(), 0);
    });

    test('the draft index keeps only legacy secure-storage entries and '
        'shrinks as v3 drafts move into files', () async {
      final legacyV3 = ChatDraftStore.keyForTesting('c1', 'legacy-v3');
      const legacyV2 = 'chat_draft_v2_c1_legacy';
      secure[legacyV3] = _draft('from older version');
      secure[legacyV2] = _draft('v2 draft');
      final store = ChatDraftStore(prefs);
      await store.save('c1', 'file-backed', 'saved to file', const []);

      final listed = await store.listForConnection('c1');
      expect(
        listed.map((entry) => entry.sessionId).toSet(),
        {'legacy-v3', 'file-backed'},
      );
      expect(secure.containsKey(legacyV3), isFalse);
      expect(
        jsonDecode(secure[AttachmentOwnershipCoordinator.draftIndexKey]!),
        [legacyV2],
      );
    });

    test('deleteForProfile removes unfinished normal-chat writes and '
        'corrupt partials while preserving bot and room unfinished '
        'writes', () async {
      final store = ChatDraftStore(prefs);
      await store.save('c1', 's-norm', 'normal', const [], profile: 'p1');
      await store.save('c1', 'mob-bot-x', 'bot', const [], profile: 'p1');
      await store.save('c1', 'mob-room-x', 'room', const [], profile: 'p1');

      Future<void> dies(String s, String text) async {
        disk
          ..death = _Death.afterTemporary
          ..deathFamily = SealedLocalFiles.drafts;
        await expectLater(
          store.save('c1', s, text, const [], profile: 'p1'),
          throwsA(isA<_ProcessDeath>()),
        );
        newProcess();
      }

      await dies('s-only-part', 'normal unfinished');
      await dies('mob-bot-x', 'bot unfinished');
      await dies('mob-room-x', 'room unfinished');
      // A corrupt .part in the same profile cannot open and is removed.
      final normName = await SealedLocalFiles(
        SealedLocalFiles.drafts,
      ).fileNameOf(
        AttachmentOwnershipCoordinator.draftName(
          ChatDraftStore.keyForTesting('c1', 'corrupt-chat', profile: 'p1'),
        ),
      );
      disk
          .file(
            SealedLocalFiles.drafts,
            '$normName${SecureColdStartStorage.partialSuffix}',
          )
          .writeAsBytesSync([1, 2, 3]);

      expect(await store.deleteForProfile('c1', 'p1'), 1);
      final left = disk.files(SealedLocalFiles.drafts);
      // Bot and room keep both their finished files and their .part files.
      expect(left, hasLength(4));
      expect(
        left.where((f) => f.endsWith(SecureColdStartStorage.partialSuffix)),
        hasLength(2),
      );
      expect(
        (await store.load('c1', 'mob-bot-x', profile: 'p1')).text,
        'bot',
      );
      expect(
        (await store.load('c1', 'mob-room-x', profile: 'p1')).text,
        'room',
      );
    });
  });

  group('outbox', () {
    const key = 'chat_turn_outbox_v1';

    for (final death in [
      null,
      _Death.beforeWrite,
      _Death.afterTemporary,
      _Death.afterRename,
    ]) {
      test('an outbox an older version kept in secure storage is moved into '
          'its file${death == null ? '' : ', even when the process dies '
                    '($death)'}; the turn is never lost', () async {
        final turn = _turn('t1', text: 'lo que mandé sin respuesta');
        secure[key] = jsonEncode({turn.storageId: turn.toJson()});
        disk
          ..death = death
          ..deathFamily = SealedLocalFiles.outbox;

        final first = await TurnOutboxStore().loadAllForChat(
          'c1',
          's1',
          profile: 'default',
        );
        expect(first.single.text, 'lo que mandé sin respuesta');
        expect(secure.containsKey(key), death != null);

        newProcess();
        final second = await TurnOutboxStore().loadAllForChat(
          'c1',
          's1',
          profile: 'default',
        );
        expect(second.single.clientTurnId, 't1');
        expect(secure.containsKey(key), isFalse);
        expect(disk.files(SealedLocalFiles.outbox), hasLength(1));
        expect(
          latin1.decode(
            disk
                .file(
                  SealedLocalFiles.outbox,
                  disk.files(SealedLocalFiles.outbox).single,
                )
                .readAsBytesSync(),
          ),
          isNot(contains('sin respuesta')),
        );
      });
    }

    test('an outbox file that does not open is never read as empty nor '
        'overwritten, and leaves its breadcrumb', () async {
      await TurnOutboxStore().save(_turn('t1'));
      final name = disk.files(SealedLocalFiles.outbox).single;
      final file = disk.file(SealedLocalFiles.outbox, name);
      final bytes = file.readAsBytesSync();
      bytes[20] ^= 0x01;
      file.writeAsBytesSync(bytes);
      newProcess();

      await expectLater(
        TurnOutboxStore().loadAllForChat('c1', 's1', profile: 'default'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        TurnOutboxStore().save(_turn('t2')),
        throwsA(isA<StateError>()),
      );

      expect(file.readAsBytesSync(), bytes);
      expect(
        recorded(SecureStorageOperation.outboxRead, 'SealedFileUnreadable'),
        isTrue,
      );
    });

    test('removing a connection, a profile\'s data or a chat removes its '
        'turns; the file goes with the last one', () async {
      final store = TurnOutboxStore();
      await store.save(_turn('t1'));
      await store.save(_turn('t2', session: 's2'));
      await store.save(_turn('t3', connection: 'c2'));

      expect(await store.deleteForChat('c1', 's1', profile: 'default'), 1);
      expect(await store.deleteForProfile('c1', 'default'), 1);
      expect(disk.files(SealedLocalFiles.outbox), hasLength(1));
      expect(await store.deleteForConnection('c2'), 1);

      expect(disk.files(SealedLocalFiles.outbox), isEmpty);
      expect(secure.containsKey(key), isFalse);
    });
  });

  group('transcripts', () {
    String hex(String value) => value.codeUnits
        .map((unit) => unit.toRadixString(16).padLeft(4, '0'))
        .join();
    String key(String connection, String session) =>
        'hermes.transcript.v3.${hex(connection)}.${hex('default')}.'
        '${hex(session)}';

    test('a transcript an older version kept in secure storage is moved '
        'into its file on its first read', () async {
      secure[key('c1', 's1')] = jsonEncode({
        'version': 1,
        'older_history_truncated': false,
        'messages': [
          {'role': 'assistant', 'content': 'respuesta guardada'},
        ],
      });

      final first = await LocalTranscriptStore.loadSnapshot('c1', 's1');

      expect(first.messages.single['content'], 'respuesta guardada');
      expect(secure.containsKey(key('c1', 's1')), isFalse);
      expect(disk.files(SealedLocalFiles.transcripts), hasLength(1));
      newProcess();
      expect(
        (await LocalTranscriptStore.loadSnapshot('c1', 's1')).messages,
        hasLength(1),
      );
    });

    test('the launch sweep moves every older transcript into its file '
        'without its chat being opened, one value at a time', () async {
      for (var i = 0; i < 5; i++) {
        secure[key('c1', 'old-$i')] = jsonEncode({
          'version': 1,
          'older_history_truncated': false,
          'messages': [
            {'role': 'assistant', 'content': 'antigua $i'},
          ],
        });
      }
      // Not a transcript the store can use: left where it is, as a read does.
      secure[key('c1', 'broken')] = '{not json';
      secure['unrelated_secret'] = 'kept';
      calls.clear();

      final moved = await LocalTranscriptStore.migrateLegacyEntries(
        pause: Duration.zero,
      );

      expect(moved, 5);
      expect(disk.files(SealedLocalFiles.transcripts), hasLength(5));
      expect(
        secure.keys.where((k) => k.startsWith('hermes.transcript.v3.')),
        [key('c1', 'broken')],
      );
      expect(secure['unrelated_secret'], 'kept');
      // Values are read one by one, never the unrelated ones.
      expect(calls, isNot(contains('read unrelated_secret')));
      expect(prefs.getBool(LocalTranscriptStore.legacySweepDoneKey), isTrue);
      newProcess();
      expect(
        (await LocalTranscriptStore.loadSnapshot('c1', 'old-3'))
            .messages
            .single['content'],
        'antigua 3',
      );

      // A finished pass is not repeated.
      calls.clear();
      expect(
        await LocalTranscriptStore.migrateLegacyEntries(pause: Duration.zero),
        0,
      );
      expect(calls, isEmpty);
    });

    test('a sweep that is told to stop leaves the rest for the next launch', (
    ) async {
      for (var i = 0; i < 4; i++) {
        secure[key('c1', 'old-$i')] = jsonEncode({
          'version': 1,
          'older_history_truncated': false,
          'messages': [
            {'role': 'assistant', 'content': 'antigua $i'},
          ],
        });
      }
      var asked = 0;
      await LocalTranscriptStore.migrateLegacyEntries(
        pause: Duration.zero,
        mayContinue: () => ++asked <= 2,
      );
      expect(disk.files(SealedLocalFiles.transcripts), hasLength(2));
      expect(prefs.getBool(LocalTranscriptStore.legacySweepDoneKey), isNull);

      await LocalTranscriptStore.migrateLegacyEntries(pause: Duration.zero);
      expect(disk.files(SealedLocalFiles.transcripts), hasLength(4));
      expect(
        secure.keys.where((k) => k.startsWith('hermes.transcript.v3.')),
        isEmpty,
      );
    });

    test('large local history retains its truncation flag with the '
        'production cipher isolate after reopening', () async {
      final previous = ColdStartTailCipher.debugOnCallingIsolate;
      ColdStartTailCipher.debugOnCallingIsolate = false;
      addTearDown(() {
        ColdStartTailCipher.debugOnCallingIsolate = previous;
      });
      final text = 'x' * (ColdStartTailCipher.offMainBytes + 1);
      await LocalTranscriptStore.saveFromNewestFirst('c1', 'large', [
        for (var i = 1001; i >= 1; i--)
          {'role': 'assistant', 'content': i == 1001 ? text : 'message $i'},
      ]);
      newProcess();
      final opened = await LocalTranscriptStore.loadSnapshot('c1', 'large');

      expect(opened.olderHistoryTruncated, isTrue);
      expect(opened.messages, hasLength(1000));
      expect(opened.messages.first['content'], 'message 2');
      expect(opened.messages.last['content'], text);
      expect(
        disk.reads.single.$3,
        greaterThan(ColdStartTailCipher.offMainBytes),
      );

      await LocalTranscriptStore.saveFromNewestFirst('c1', 'large', [
        {'role': 'assistant', 'content': 'newest'},
      ]);
      final refreshed = await LocalTranscriptStore.loadSnapshot('c1', 'large');
      expect(refreshed.olderHistoryTruncated, isTrue);
      expect(refreshed.messages.single['content'], 'newest');
    });

    test('opening one chat among 200 reads one transcript file; profile and '
        'connection cleanups leave no file behind', () async {
      for (var i = 0; i < 200; i++) {
        await LocalTranscriptStore.saveFromNewestFirst('c1', 'chat-$i', [
          {'role': 'assistant', 'content': 'respuesta $i'},
        ]);
      }
      await LocalTranscriptStore.saveFromNewestFirst('c1', 'otro', [
        {'role': 'assistant', 'content': 'de otro perfil'},
      ], profile: 'p2');
      await LocalTranscriptStore.saveFromNewestFirst('c2', 'chat-1', [
        {'role': 'assistant', 'content': 'otra conexión'},
      ]);
      newProcess();

      final opened = await LocalTranscriptStore.loadSnapshot('c1', 'chat-42');

      expect(opened.messages.single['content'], 'respuesta 42');
      expect(disk.reads, hasLength(1));
      expect(readAlls(), 0);

      expect(await LocalTranscriptStore.deleteForProfile('c1', ''), 200);
      expect(disk.files(SealedLocalFiles.transcripts), hasLength(2));
      expect(await LocalTranscriptStore.deleteForConnection('c1'), 1);
      expect(disk.files(SealedLocalFiles.transcripts), hasLength(1));
      expect(
        (await LocalTranscriptStore.loadSnapshot('c2', 'chat-1')).messages,
        hasLength(1),
      );
    });
  });

  group('chat lists', () {
    test('a Home recents snapshot an older version kept in secure storage '
        'is moved into a file; clearing the lists, a connection or '
        'everything removes the files', () async {
      ColdStartStore store() => ColdStartStore(
        storage: SecureColdStartStorage(
          directory: () async => disk.dirOf('tails'),
        ),
      );
      final writer = ColdStartStore(storage: _EntryOnlyStorage(secure));
      await writer.saveRecents(
        connectionId: 'c1',
        profile: 'default',
        sessions: [_row('a'), _row('b')],
      );
      final legacy = ColdStartStore.recentsKey('c1', 'default');
      expect(secure.containsKey(legacy), isTrue);
      newProcess();

      final loaded = await store().loadRecents(
        connectionId: 'c1',
        profile: 'default',
      );

      expect(loaded!.map((s) => s.id), ['a', 'b']);
      expect(secure.containsKey(legacy), isFalse);
      expect(disk.files(SealedLocalFiles.lists), hasLength(1));
      expect(
        latin1.decode(
          disk
              .file(
                SealedLocalFiles.lists,
                disk.files(SealedLocalFiles.lists).single,
              )
              .readAsBytesSync(),
        ),
        isNot(contains('titulo')),
      );

      final s = store();
      await s.saveList(
        connectionId: 'c1',
        profile: 'default',
        sessions: [_row('a')],
      );
      await s.saveRecents(
        connectionId: 'c2',
        profile: 'default',
        sessions: [_row('c')],
      );
      expect(disk.files(SealedLocalFiles.lists), hasLength(3));
      await s.forgetScope('c1');
      expect(disk.files(SealedLocalFiles.lists), hasLength(1));
      await s.saveRecents(
        connectionId: 'c1',
        profile: 'default',
        sessions: [_row('a')],
      );
      await s.clearLists();
      expect(disk.files(SealedLocalFiles.lists), isEmpty);
      await s.saveRecents(
        connectionId: 'c1',
        profile: 'default',
        sessions: [_row('a')],
      );
      await s.clearAll();
      expect(disk.files(SealedLocalFiles.lists), isEmpty);
    });
  });

  group('the rest', () {
    test('the Stop tombstones an older version kept are moved into their '
        'file; an unparsable one is left untouched', () async {
      const key = 'cancelled_turn_tombstones_v2';
      final writer = CancelledTurnTombstoneStore(
        read: () async => secure[key],
        write: (value) async => secure[key] = value,
      );
      await writer.add(
        connectionId: 'c1',
        profile: 'default',
        sessionId: 's1',
        tombstone: const CancelledTurnTombstone(
          content: 'texto detenido',
          firstUser: true,
        ),
      );
      expect(secure.containsKey(key), isTrue);

      final store = CancelledTurnTombstoneStore.secure();
      await store.initialize();

      expect(
        store
            .load(connectionId: 'c1', profile: 'default', sessionId: 's1')
            .single
            .content,
        'texto detenido',
      );
      expect(secure.containsKey(key), isFalse);
      expect(disk.files(SealedLocalFiles.tombstones), hasLength(1));

      // A corrupt entry of a version that never moved it.
      disk.dirOf(SealedLocalFiles.tombstones).deleteSync(recursive: true);
      secure[key] = '{corrupt';
      newProcess();
      await expectLater(
        CancelledTurnTombstoneStore.secure().initialize(),
        throwsFormatException,
      );
      expect(secure[key], '{corrupt');
    });

    test('a share waiting to become a draft is moved into its file and '
        'leaves with its acknowledgement', () async {
      const key = 'android_share_inbox_v1';
      const content = AndroidSharedContent(
        id: 'share-1',
        text: 'texto compartido',
        attachments: [],
      );
      secure[key] = jsonEncode([content.toJson()]);
      final inbox = AndroidShareInbox(channel: const MethodChannel('x/share'));

      expect((await inbox.initialize())?.text, 'texto compartido');
      expect(secure.containsKey(key), isFalse);
      expect(disk.files(SealedLocalFiles.shareInbox), hasLength(1));

      await inbox.acknowledge('share-1');
      expect(disk.files(SealedLocalFiles.shareInbox), isEmpty);
      await inbox.dispose();
    });
  });
}

/// How an older version stored the chat lists: secure-storage entries.
final class _EntryOnlyStorage implements ColdStartStorage {
  _EntryOnlyStorage(this.values);

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<Iterable<String>> keys() async => values.keys.toList();

  @override
  Future<Uint8List?> readFile(String name) async => null;

  @override
  Future<void> writeFile(String name, Uint8List bytes) async {}

  @override
  Future<void> deleteFile(String name) async {}

  @override
  Future<List<String>> fileNames() async => const [];
}
