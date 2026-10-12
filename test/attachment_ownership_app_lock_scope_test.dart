// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    TurnOutboxStore.resetSerializationForTesting();
  });

  test(
    'shared attachment ownership inventory refuses a new bulk handoff under App Lock',
    () async {
      SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
      var bulkHandoffs = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'readAll') {
          bulkHandoffs++;
          return <String, String>{};
        }
        return null;
      });
      final prefs = await SharedPreferences.getInstance();
      final lock = AppLockService(prefs);
      expect(lock.locked.value, isTrue);
      // This owner is shared with TurnOutboxStore and can be entered without
      // constructing ChatDraftStore. No outbox persistence or transport fake.
      final references =
          await AttachmentOwnershipCoordinator.loadDurableReferences(
            const FlutterSecureStorage(),
            preferences: prefs,
          );
      expect(
        bulkHandoffs,
        0,
        reason: 'a draft-only wrapper leaves the shared ownership reader open',
      );
      expect(
        references,
        isNull,
        reason:
            'denial is unavailable ownership evidence, not an empty inventory',
      );
    },
  );

  test(
    'shared inventory does not decode a pre-lock response after lock-unlock ABA',
    () async {
      SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
      final entered = Completer<void>();
      final release = Completer<void>();
      final key = ChatDraftStore.keyForTesting(
        'synthetic-conn',
        'mob-synthetic',
      );
      final values = <String, String>{
        key: jsonEncode({
          'text': 'SYNTHETIC_PRIVATE_OWNERSHIP_MARKER',
          'attachments': [],
        }),
      };
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'readAll') {
          entered.complete();
          await release.future;
          return values;
        }
        return null;
      });
      final prefs = await SharedPreferences.getInstance();
      final lock = AppLockService(prefs)..unlock();
      final flight = AttachmentOwnershipCoordinator.loadDurableReferences(
        const FlutterSecureStorage(),
        preferences: prefs,
      );
      await entered.future;
      lock.lockNow();
      lock.unlock();
      release.complete();
      expect(
        await flight,
        isNull,
        reason: 'unlock cannot renew the authority of an older read',
      );
    },
  );

  test(
    'owning outbox cleanup cannot bulk-read drafts under App Lock independently of ChatDraftStore',
    () async {
      SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
      final values = <String, String>{};
      var bulkHandoffsLocked = 0;
      AppLockService? lock;
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = (call.arguments as Map?) ?? const {};
        switch (call.method) {
          case 'read':
            return values[args['key']];
          case 'write':
            values[args['key'] as String] = args['value'] as String;
            return null;
          case 'delete':
            values.remove(args['key']);
            return null;
          case 'readAll':
            if (lock?.locked.value == true) bulkHandoffsLocked++;
            return Map<String, String>.of(values);
        }
        return null;
      });
      final prefs = await SharedPreferences.getInstance();
      final owningLock = AppLockService(prefs)..unlock();
      lock = owningLock;
      final store = TurnOutboxStore(deletePrivateCopy: (_) async => false);
      final now = DateTime.now().millisecondsSinceEpoch;
      final turn = PreparedTurn(
        connectionId: 'synthetic-conn',
        sessionId: 'synthetic-session',
        clientTurnId: 'synthetic-turn',
        createdAtMs: now,
        updatedAtMs: now,
        text: 'SYNTHETIC_OUTBOX_CONTROL',
        model: 'synthetic-model',
        profile: 'default',
        attachments: const [
          AttachmentDraft(
            localId: 'synthetic-attachment',
            type: AttachmentType.document,
            name: 'synthetic.txt',
            mimeType: 'text/plain',
            sizeBytes: 1,
            localPath: '/synthetic/not-a-real-private-copy',
            uploadState: AttachmentUploadState.attached,
            remoteRef: 'synthetic-ref',
            remoteSessionId: 'synthetic-runtime',
          ),
        ],
      );
      await store.save(turn);
      values[ChatDraftStore.keyForTesting('synthetic-other', 'mob-private')] =
          jsonEncode({'text': 'SYNTHETIC_NEIGHBOR_DRAFT', 'attachments': []});
      owningLock.lockNow();
      await store.deleteForChat(
        'synthetic-conn',
        'synthetic-session',
        profile: 'default',
      );
      expect(
        bulkHandoffsLocked,
        0,
        reason:
            'the actual outbox owner enters the shared inventory without a draft-store wrapper',
      );
    },
  );

  test(
    'current unlocked shared inventory retains the actual durable draft evidence',
    () async {
      SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
      final key = ChatDraftStore.keyForTesting(
        'synthetic-conn',
        'mob-synthetic',
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'readAll') {
          return <String, String>{
            key: jsonEncode({
              'text': 'SYNTHETIC_PUBLIC_CONTROL',
              'attachments': [],
            }),
          };
        }
        return null;
      });
      final prefs = await SharedPreferences.getInstance();
      AppLockService(prefs).unlock();
      final references =
          await AttachmentOwnershipCoordinator.loadDurableReferences(
            const FlutterSecureStorage(),
            preferences: prefs,
          );
      expect(references, hasLength(1));
      expect((references!.single as Map)['text'], 'SYNTHETIC_PUBLIC_CONTROL');
    },
  );
}
