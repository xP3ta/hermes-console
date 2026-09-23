import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/services/attachment_uploader.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/services/local_transcript_store.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/compression_restore_store.dart';

import 'session_authority_probe_test.dart' as helpers;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secure = <String, String>{};
  final mutations = <String>[];
  Future<void> Function(MethodCall)? hook;
  late Directory files;
  late ChatDraftStore drafts;
  late SharedPreferences prefs;
  Future<bool> erase(AttachmentDraft a) =>
      AttachmentUploader.deletePrivateDraftCopy(a, baseDir: files);
  setUp(() async {
    LocalConversationCleanupFence.resetForTesting();
    TurnOutboxStore.resetSerializationForTesting();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    secure.clear();
    mutations.clear();
    hook = null;
    files = await Directory.systemTemp.createTemp('adversarial-fix3-private-');
    drafts = ChatDraftStore(
      prefs,
      mutationNamespaceForTesting: files.path,
      deletePrivateCopy: erase,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            if (call.method == 'write' || call.method == 'delete') {
              mutations.add(call.method);
            }
            await hook?.call(call);
            final args = (call.arguments as Map).cast<String, dynamic>();
            switch (call.method) {
              case 'read':
                return secure[args['key']];
              case 'readAll':
                return Map<String, String>.of(secure);
              case 'write':
                secure[args['key']] = args['value'];
                return null;
              case 'delete':
                secure.remove(args['key']);
                return null;
            }
            return null;
          },
        );
  });
  tearDown(() async {
    await files.delete(recursive: true);
  });
  Future<AttachmentDraft> item([String id = 'owned']) async {
    final dir = await Directory('${files.path}/attachment_drafts').create();
    final file = File('${dir.path}/${id}_private.txt');
    await file.writeAsString('synthetic private');
    return AttachmentDraft(
      localId: id,
      type: AttachmentType.document,
      name: 'private.txt',
      mimeType: 'text/plain',
      sizeBytes: 17,
      localPath: file.path,
    );
  }

  for (final phase in ['read', 'write']) {
    test('B1 clearForSession orders after draft in $phase', () async {
      final entered = Completer<void>(), release = Completer<void>();
      var held = false;
      hook = (call) async {
        if (call.method == phase && !held) {
          held = true;
          entered.complete();
          await release.future;
        }
      };
      final saving = helpers.result(
        drafts.save('c', 's', 'resurrected', const [], profile: 'p'),
      );
      await entered.future;
      final clearing = drafts.clearForSession('c', 's');
      await pumpEventQueue(times: 10);
      release.complete();
      await clearing;
      await saving;
      final text = (await drafts.load('c', 's', profile: 'p')).text;
      expect(text, isEmpty);
    });
  }
  test(
    'B4 empty draft save rechecks dispose after read before delete',
    () async {
      await drafts.save('c', 's', 'keep existing', const [], profile: 'p');
      mutations.clear();
      final life = helpers.life();
      final entered = Completer<void>(), release = Completer<void>();
      var held = false;
      hook = (call) async {
        if (call.method == 'read' && !held) {
          held = true;
          entered.complete();
          await release.future;
        }
      };
      final saving = helpers.result(
        drafts.save('c', 's', '', const [], profile: 'p', lifecycle: life),
      );
      await entered.future;
      expect(mutations, isEmpty);
      LocalConversationCleanupFence.endLifecycle(life);
      release.complete();
      final outcome = await saving;
      final text = (await drafts.load('c', 's', profile: 'p')).text;
      expect(
        mutations,
        isEmpty,
        reason: 'No delete handed to storage when lifecycle revoked',
      );
      expect(outcome, isA<LocalConversationWriteRejected>());
      expect(text, 'keep existing');
    },
  );
  for (final kind in ['draft', 'outbox']) {
    test(
      'B1 failed first $kind save retains live producer private copy for retry',
      () async {
        final a = await item();
        final life = helpers.life();
        final store = TurnOutboxStore(
          lifecycle: life,
          deletePrivateCopy: erase,
        );
        var injected = false;
        hook = (call) async {
          if (call.method == 'write' && !injected) {
            injected = true;
            throw PlatformException(code: 'transient-write-failure');
          }
        };
        Future<void> save() => kind == 'draft'
            ? drafts.save(
                'c',
                's',
                'retryable',
                [a],
                profile: 'p',
                lifecycle: life,
              )
            : store.save(helpers.turn(attachments: [a]));
        final outcome = await helpers.result(save());
        final stillCurrent = identical(
          LocalConversationCleanupFence.currentLifecycle(
            connectionId: 'c',
            profile: 'p',
            sessionId: 's',
          ),
          life,
        );
        final existsAfterFailure = await File(a.localPath).exists();
        expect(outcome, isA<PlatformException>());
        expect(stillCurrent, isTrue);
        expect(secure, isEmpty);
        hook = null;
        await save();
        final attachments = kind == 'draft'
            ? (await drafts.load('c', 's', profile: 'p')).attachments
            : (await store.loadForChat('c', 's', profile: 'p'))!.attachments;
        expect(
          existsAfterFailure,
          isTrue,
          reason:
              'Live producer retains attachment and no clear/delete was requested',
        );
        expect(attachments, hasLength(1));
      },
    );
  }
  for (final kind in ['transcript', 'draft', 'outbox']) {
    test('B4 delivered $kind write succeeds despite later dispose', () async {
      final a = await item();
      final life = helpers.life();
      final entered = Completer<void>(), release = Completer<void>();
      var held = false;
      hook = (call) async {
        if (call.method == 'write' && !held) {
          held = true;
          entered.complete();
          await release.future;
        }
      };
      final store = TurnOutboxStore(lifecycle: life, deletePrivateCopy: erase);
      final saving = helpers.result(
        kind == 'transcript'
            ? LocalTranscriptStore.saveFromNewestFirst(
                'c',
                's',
                helpers.rows,
                profile: 'p',
                lifecycle: life,
              )
            : kind == 'draft'
            ? drafts.save(
                'c',
                's',
                'delivered',
                [a],
                profile: 'p',
                lifecycle: life,
              )
            : store.save(helpers.turn(attachments: [a])),
      );
      await entered.future;
      expect(mutations, ['write']);
      LocalConversationCleanupFence.endLifecycle(life);
      release.complete();
      expect(await saving, isNull);
      expect(secure, hasLength(1));
      if (kind != 'transcript') {
        expect(await File(a.localPath).exists(), isTrue);
      }
    });
  }
  for (final failure in [false, true]) {
    test(
      'B1 deferred cleanup reverse draft ${failure ? 'failure' : 'cancel'} removes real private copy',
      () async {
        final a = await item();
        final life = helpers.life();
        final outbox = TurnOutboxStore(deletePrivateCopy: erase);
        final t = helpers.turn(attachments: [a]);
        await outbox.save(t);
        final release = Completer<void>();
        final blocker = LocalConversationCleanupFence.write(
          connectionId: 'other',
          operation: () => release.future,
        );
        final saving = helpers.result(
          drafts.save('c', 's', 'pending', [a], profile: 'p', lifecycle: life),
        );
        await outbox.delete(t);
        expect(await File(a.localPath).exists(), isTrue);
        if (failure) {
          hook = (call) async {
            if (call.method == 'write') {
              throw PlatformException(code: 'injected');
            }
          };
        } else {
          LocalConversationCleanupFence.endLifecycle(life);
        }
        release.complete();
        await blocker;
        expect(
          await saving,
          failure
              ? isA<PlatformException>()
              : isA<LocalConversationWriteRejected>(),
        );
        expect(secure, isEmpty);
        expect(AttachmentOwnershipCoordinator.hasPendingOwner(a), isFalse);
        expect(await File(a.localPath).exists(), isFalse);
      },
    );
  }
  test(
    'B1 withdrawing one cancelled owner preserves second pending and durable owner',
    () async {
      final a = await item();
      await drafts.save('c', 's', 'original', [a], profile: 'p');
      final lifeA = helpers.life(s: 'a'), lifeB = helpers.life(s: 'b');
      final outboxA = TurnOutboxStore(
        lifecycle: lifeA,
        deletePrivateCopy: erase,
      );
      final outboxB = TurnOutboxStore(
        lifecycle: lifeB,
        deletePrivateCopy: erase,
      );
      final release = Completer<void>();
      final blocker = LocalConversationCleanupFence.write(
        connectionId: 'other',
        operation: () => release.future,
      );
      final savingA = helpers.result(
        outboxA.save(helpers.turn(s: 'a', attachments: [a])),
      );
      final savingB = helpers.result(
        outboxB.save(helpers.turn(s: 'b', attachments: [a])),
      );
      await drafts.clear('c', 's', profile: 'p');
      LocalConversationCleanupFence.endLifecycle(lifeA);
      release.complete();
      await blocker;
      expect(await savingA, isA<LocalConversationWriteRejected>());
      expect(await savingB, isNull);
      expect(await File(a.localPath).exists(), isTrue);
      expect(
        (await outboxB.loadForChat('c', 'b', profile: 'p'))!.attachments,
        hasLength(1),
      );
      await outboxB.delete(helpers.turn(s: 'b', attachments: [a]));
      expect(await File(a.localPath).exists(), isFalse);
    },
  );
  test(
    'B1 failed outbox save does not erase copy still referenced by legacy prefs',
    () async {
      final a = await item();
      final raw = jsonEncode({
        'text': 'legacy retained',
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'attachments': [a.toJson()],
      });
      await prefs.setString('chat_draft_v1_legacy_session', raw);
      hook = (call) async {
        if (call.method == 'write') throw PlatformException(code: 'injected');
      };
      final outcome = await helpers.result(
        TurnOutboxStore(
          deletePrivateCopy: erase,
        ).save(helpers.turn(attachments: [a])),
      );
      expect(outcome, isA<PlatformException>());
      expect(prefs.getString('chat_draft_v1_legacy_session'), raw);
      expect(await File(a.localPath).exists(), isTrue);
    },
  );
  test(
    'B1 clearForSession admitted before save must preserve newer draft',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      var held = false;
      hook = (call) async {
        if (call.method == 'readAll' && !held) {
          held = true;
          entered.complete();
          await release.future;
        }
      };
      final clearing = drafts.clearForSession('c', 's');
      await entered.future;
      await drafts.save('c', 's', 'newer live draft', const [], profile: 'p');
      release.complete();
      await clearing;
      final text = (await drafts.load('c', 's', profile: 'p')).text;
      expect(text, 'newer live draft');
    },
  );
  for (final kind in ['transcript', 'draft', 'outbox']) {
    test(
      'B5 replacement alias owner during $kind read rejects stale write',
      () async {
        final old = helpers.life(s: 'legacy', aliases: ['s']);
        final entered = Completer<void>(), release = Completer<void>();
        var held = false;
        hook = (call) async {
          if (call.method == 'read' && !held) {
            held = true;
            entered.complete();
            await release.future;
          }
        };
        final saving = helpers.result(
          kind == 'transcript'
              ? LocalTranscriptStore.saveFromNewestFirst(
                  'c',
                  's',
                  helpers.rows,
                  profile: 'p',
                  lifecycle: old,
                )
              : kind == 'draft'
              ? drafts.save(
                  'c',
                  's',
                  'stale',
                  const [],
                  profile: 'p',
                  lifecycle: old,
                )
              : TurnOutboxStore(lifecycle: old).save(helpers.turn()),
        );
        await entered.future;
        final fresh = helpers.life(s: 's', aliases: ['legacy']);
        expect(LocalConversationCleanupFence.rehydrate(fresh), isTrue);
        release.complete();
        expect(await saving, isA<LocalConversationWriteRejected>());
        expect(mutations, isEmpty);
        expect(secure, isEmpty);
      },
    );
  }
  test(
    'B2 rejected stale send cannot contaminate next fresh transcript',
    () async {
      final slow = helpers.SlowFenceStorage();
      final service = ActiveChatService(
        compressionRestoreStore: CompressionRestoreStore(storage: slow),
      );
      final connection = SavedConnection(
        id: 'c',
        label: 'synthetic',
        host: '127.0.0.1',
        port: 8642,
        apiKey: '',
        kind: InstanceKind.localhost,
        onDeviceLoopback: true,
      );
      final old = helpers.life(p: 'default');
      final chat = service.attach(
        connection: connection,
        sessionId: 's',
        sessionTitle: 'synthetic',
        sessionProfile: 'default',
        localConversationLifecycle: old,
        disableForegroundKeepAlive: true,
      );
      addTearDown(service.dispose);
      await pumpEventQueue(times: 20);
      slow.entered = Completer<void>();
      slow.release = Completer<void>();
      chat.beforeSendAdmissionForTesting = () async {
        chat.beforeSendAdmissionForTesting = null;
        await slow.read();
      };
      final sending = helpers.result(
        chat.send(
          fullText: 'STALE_BEFORE_CLEANUP',
          model: 'm',
          history: const [],
        ),
      );
      await slow.entered!.future;
      await LocalTranscriptStore.deleteForProfile('c', 'default');
      LocalConversationCleanupFence.endLifecycle(old);
      final fresh = helpers.life(p: 'default');
      expect(LocalConversationCleanupFence.rehydrate(fresh), isTrue);
      expect(
        identical(
          chat,
          service.attach(
            connection: connection,
            sessionId: 's',
            sessionTitle: 'synthetic',
            sessionProfile: 'default',
            localConversationLifecycle: fresh,
            disableForegroundKeepAlive: true,
          ),
        ),
        isTrue,
      );
      // Any storage write disposes the service at that seam, before transport.
      hook = (call) async {
        if (call.method == 'write') chat.dispose();
      };
      slow.release!.complete();
      final firstOutcome = await sending.timeout(const Duration(seconds: 3));
      final before = await LocalTranscriptStore.load(
        'c',
        's',
        profile: 'default',
      );
      expect(firstOutcome, isA<LocalConversationWriteRejected>());
      expect(before, isEmpty);
      await helpers.result(
        chat.send(
          fullText: 'FRESH_AFTER_CLEANUP',
          model: 'm',
          history: const [],
        ),
      );
      final after = await LocalTranscriptStore.load(
        'c',
        's',
        profile: 'default',
      );
      expect(after.map((row) => row['content']), ['FRESH_AFTER_CLEANUP']);
    },
  );
  test(
    'B5 alias-only overlap fences shared destination but preserves disjoint owner',
    () async {
      final a = helpers.life(s: 'a', aliases: ['shared', 'only-a']);
      final b = helpers.life(s: 'b', aliases: ['shared']);
      expect(LocalConversationCleanupFence.rehydrate(a), isTrue);
      expect(LocalConversationCleanupFence.rehydrate(b), isTrue);
      await drafts.save(
        'c',
        'shared',
        'new',
        const [],
        profile: 'p',
        lifecycle: b,
      );
      expect(
        await helpers.result(
          drafts.save(
            'c',
            'shared',
            'old',
            const [],
            profile: 'p',
            lifecycle: a,
          ),
        ),
        isA<LocalConversationWriteRejected>(),
      );
      await drafts.save(
        'c',
        'only-a',
        'survivor',
        const [],
        profile: 'p',
        lifecycle: a,
      );
      expect((await drafts.load('c', 'shared', profile: 'p')).text, 'new');
      expect((await drafts.load('c', 'only-a', profile: 'p')).text, 'survivor');
      LocalConversationCleanupFence.endLifecycle(b);
      expect(
        await helpers.result(
          drafts.save(
            'c',
            'shared',
            'old after end',
            const [],
            profile: 'p',
            lifecycle: a,
          ),
        ),
        isA<LocalConversationWriteRejected>(),
      );
    },
  );
}
