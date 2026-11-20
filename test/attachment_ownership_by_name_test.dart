// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final secure = <String, String>{};
  final reads = <String>[];
  var readAllCalls = 0;
  // A read of this key waits for [releaseRead] once [readEntered] is set.
  String? blockedRead;
  Completer<void>? readEntered;
  Completer<void>? releaseRead;
  late Directory dir;

  // Megabytes in production (a chat's cold-start tail): an attachment
  // cleanup has no business decrypting it.
  const unrelatedTail = 'cold_start_tail_v1.unrelated';
  // The Keystore entry that names the drafts.
  const indexKey = 'chat_draft_index_v1';

  setUp(() {
    secure.clear();
    reads.clear();
    readAllCalls = 0;
    blockedRead = null;
    readEntered = null;
    releaseRead = null;
    SharedPreferences.setMockInitialValues({});
    LocalConversationCleanupFence.resetForTesting();
    TurnOutboxStore.resetSerializationForTesting();
    dir = Directory.systemTemp.createTempSync('ownership-by-name');
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
      switch (call.method) {
        case 'write':
          secure[args['key'] as String] = args['value'] as String;
          return null;
        case 'read':
          final key = args['key'] as String;
          reads.add(key);
          if (key == blockedRead && readEntered != null) {
            blockedRead = null;
            readEntered!.complete();
            await releaseRead!.future;
          }
          return secure[key];
        case 'delete':
          secure.remove(args['key'] as String);
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
    TurnOutboxStore.resetSerializationForTesting();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  AttachmentDraft copy(String name) {
    final file = File('${dir.path}/$name.txt')..writeAsStringSync(name);
    return AttachmentDraft(
      localId: name,
      type: AttachmentType.document,
      name: '$name.txt',
      mimeType: 'text/plain',
      sizeBytes: name.length,
      localPath: file.path,
    );
  }

  Future<bool> deleteCopy(AttachmentDraft item) async {
    final file = File(item.localPath);
    if (!file.existsSync()) return false;
    file.deleteSync();
    return true;
  }

  String draftKey(String session) =>
      ChatDraftStore.keyForTesting('conn-own', session);

  test('with the draft index, a released copy is checked by name, never by '
      'decrypting all of secure storage', () async {
    final prefs = await SharedPreferences.getInstance();
    final drafts = ChatDraftStore(prefs, deletePrivateCopy: deleteCopy);
    final first = copy('first');
    final second = copy('second');
    await drafts.save('conn-own', 'session-a', 'with a file', [first]);
    // Home lists the drafts every few seconds; the first list builds the
    // index of their names.
    expect(await drafts.listForConnection('conn-own'), hasLength(1));
    secure[unrelatedTail] = 'x' * 4096;
    readAllCalls = 0;
    reads.clear();

    // The user swaps the file: the first copy has no owner any more.
    await drafts.save('conn-own', 'session-a', 'with a file', [second]);

    expect(File(first.localPath).existsSync(), isFalse);
    expect(File(second.localPath).existsSync(), isTrue);

    // A send with an attachment goes through several outbox states; each
    // one checks whether the previous state's files are still owned.
    final outbox = TurnOutboxStore(deletePrivateCopy: deleteCopy);
    final now = DateTime.now().millisecondsSinceEpoch;
    final turn = PreparedTurn(
      connectionId: 'conn-own',
      sessionId: 'session-a',
      clientTurnId: 'turn-1',
      createdAtMs: now,
      updatedAtMs: now,
      text: 'with a file',
      model: 'model',
      profile: 'default',
      attachments: [second],
    );
    await outbox.save(turn);
    await outbox.save(turn.copyWith(state: PreparedTurnState.submitting));
    await outbox.save(turn.copyWith(state: PreparedTurnState.accepted));

    expect(File(second.localPath).existsSync(), isTrue);
    expect(readAllCalls, 0);
    expect(reads, isNot(contains(unrelatedTail)));
  });

  test('a draft whose name the index lost still owns its copy', () async {
    final prefs = await SharedPreferences.getInstance();
    final drafts = ChatDraftStore(prefs, deletePrivateCopy: deleteCopy);
    final shared = copy('shared');
    // The Home composer's draft moves to a new chat with the same file.
    await drafts.save('conn-own', 'session-a', 'moving', [shared]);
    await drafts.save('conn-own', 'session-b', 'moving', [shared]);
    await drafts.listForConnection('conn-own');
    // Two index updates raced and the second draft's name was lost.
    secure[indexKey] = jsonEncode([draftKey('session-a')]);
    readAllCalls = 0;

    await drafts.clear('conn-own', 'session-a');

    expect(secure.containsKey(draftKey('session-a')), isFalse);
    expect(File(shared.localPath).existsSync(), isTrue);
    expect(readAllCalls, 0);
  });

  test('with no draft index, a copy another draft uses is kept', () async {
    final prefs = await SharedPreferences.getInstance();
    final drafts = ChatDraftStore(prefs, deletePrivateCopy: deleteCopy);
    final shared = copy('shared');
    await drafts.save('conn-own', 'session-a', 'moving', [shared]);
    await drafts.save('conn-own', 'session-b', 'moving', [shared]);
    expect(secure.containsKey(indexKey), isFalse);
    // A new process: nothing in memory names the drafts either.
    TurnOutboxStore.resetSerializationForTesting();

    await drafts.clear('conn-own', 'session-a');

    expect(File(shared.localPath).existsSync(), isTrue);
    expect(readAllCalls, 1);
  });

  test('the index names legacy v2 drafts; their copies are kept', () async {
    final prefs = await SharedPreferences.getInstance();
    final drafts = ChatDraftStore(prefs, deletePrivateCopy: deleteCopy);
    final shared = copy('shared');
    secure['chat_draft_v2_conn-own_old'] = jsonEncode({
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'text': 'older version',
      'attachments': [shared.toJson()],
    });
    await drafts.save('conn-own', 'session-a', 'current', [shared]);
    await drafts.listForConnection('conn-own');
    TurnOutboxStore.resetSerializationForTesting();
    readAllCalls = 0;

    await drafts.clear('conn-own', 'session-a');

    expect(File(shared.localPath).existsSync(), isTrue);
    expect(readAllCalls, 0);
    expect(reads, contains('chat_draft_v2_conn-own_old'));
  });

  test('an app lock that closes during the reads by name stops them and '
      'proves no ownership', () async {
    SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
    final prefs = await SharedPreferences.getInstance();
    final lock = AppLockService(prefs)..unlock();
    final drafts = ChatDraftStore(prefs, deletePrivateCopy: deleteCopy);
    await drafts.save('conn-own', 'session-a', 'first', const []);
    await drafts.save('conn-own', 'session-b', 'second', const []);
    await drafts.listForConnection('conn-own');
    final names = (jsonDecode(secure[indexKey]!) as List).cast<String>();
    expect(names, hasLength(2));
    TurnOutboxStore.resetSerializationForTesting();
    blockedRead = names.first;
    readEntered = Completer<void>();
    releaseRead = Completer<void>();
    reads.clear();
    readAllCalls = 0;

    final flight = AttachmentOwnershipCoordinator.loadDurableReferences(
      const FlutterSecureStorage(),
      preferences: prefs,
    );
    await readEntered!.future;
    lock.lockNow();
    final readsAtRevocation = reads.length;
    releaseRead!.complete();

    expect(await flight, isNull);
    expect(reads.length, readsAtRevocation);
    expect(reads, isNot(contains(names.last)));
    expect(readAllCalls, 0);
  });
}
