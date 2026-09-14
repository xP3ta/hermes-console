import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/services/local_transcript_store.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_compression_fence_store.dart';

const rows = <Map<String, dynamic>>[
  {'role': 'assistant', 'content': 'stale'},
];
LocalConversationLifecycle life({
  String c = 'c',
  String p = 'p',
  String s = 's',
  List<String> aliases = const [],
}) => LocalConversationCleanupFence.beginLifecycle(
  connectionId: c,
  profile: p,
  sessionId: s,
  sessionAliases: aliases,
);
Future<Object?> result(Future<dynamic> f) =>
    f.then<Object?>((_) => null, onError: (Object e) => e);
PreparedTurn turn({
  String c = 'c',
  String p = 'p',
  String s = 's',
  String t = 't',
  List<AttachmentDraft> attachments = const [],
}) => PreparedTurn(
  connectionId: c,
  profile: p,
  sessionId: s,
  clientTurnId: t,
  text: t,
  createdAtMs: DateTime.now().millisecondsSinceEpoch,
  updatedAtMs: DateTime.now().millisecondsSinceEpoch,
  attachments: attachments,
  model: 'm',
  queued: true,
);

class SlowFenceStorage implements DesktopCompressionFenceStorage {
  Completer<void>? release;
  Completer<void>? entered;
  @override
  Future<String?> read() async {
    if (release != null) {
      if (!entered!.isCompleted) entered!.complete();
      await release!.future;
    }
    return null;
  }

  @override
  Future<void> write(String value) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secure = <String, String>{};
  Future<void> Function(MethodCall)? hook;
  late Directory files;
  late ChatDraftStore drafts;
  setUp(() async {
    LocalConversationCleanupFence.resetForTesting();
    TurnOutboxStore.resetSerializationForTesting();
    SharedPreferences.setMockInitialValues({});
    secure.clear();
    hook = null;
    files = await Directory.systemTemp.createTemp('adversarial-fix2-probe-');
    drafts = ChatDraftStore(
      await SharedPreferences.getInstance(),
      mutationNamespaceForTesting: files.path,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
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
  Future<AttachmentDraft> attachment() async {
    final file = File('${files.path}/private.txt');
    await file.writeAsString('synthetic private');
    return AttachmentDraft(
      localId: 'shared',
      type: AttachmentType.document,
      name: 'private.txt',
      mimeType: 'text/plain',
      sizeBytes: 17,
      localPath: file.path,
    );
  }

  test('B1 delete exact turn must not cancel another queued turn', () async {
    final store = TurnOutboxStore();
    final old = turn(t: 'old'), fresh = turn(t: 'fresh');
    await store.save(old);
    final release = Completer<void>();
    final blocker = LocalConversationCleanupFence.write(
      connectionId: 'unrelated',
      operation: () => release.future,
    );
    final saving = store.save(fresh);
    await store.delete(old);
    release.complete();
    await blocker;
    await saving;
    final saved = await store.loadAllForChat('c', 's', profile: 'p');
    expect(saved.map((t) => t.clientTurnId), ['fresh']);
  });

  test('B1 clearForSession must cancel an earlier pending draft', () async {
    final release = Completer<void>();
    final blocker = LocalConversationCleanupFence.write(
      connectionId: 'unrelated',
      operation: () => release.future,
    );
    final saving = drafts.save('c', 's', 'stale', const [], profile: 'p');
    await drafts.clearForSession('c', 's');
    release.complete();
    await blocker;
    await saving;
    expect((await drafts.load('c', 's', profile: 'p')).text, isEmpty);
  });

  test(
    'B1 pending draft preserves attachment while outbox is deleted',
    () async {
      final item = await attachment();
      final deleted = <String>[];
      final store = TurnOutboxStore(
        deletePrivateCopy: (a) async {
          deleted.add(a.localId);
          await File(a.localPath).delete();
          return true;
        },
      );
      final old = turn(attachments: [item]);
      await store.save(old);
      final release = Completer<void>();
      final blocker = LocalConversationCleanupFence.write(
        connectionId: 'unrelated',
        operation: () => release.future,
      );
      final saving = drafts.save('c', 's', 'fresh draft', [item], profile: 'p');
      await store.delete(old);
      release.complete();
      await blocker;
      await saving;
      final loaded = await drafts.load('c', 's', profile: 'p');
      expect(deleted, isEmpty);
      expect(loaded.attachments, hasLength(1));
    },
  );

  for (final kind in ['transcript', 'draft', 'outbox']) {
    test(
      'B4 dispose while $kind is in read phase revokes later write',
      () async {
        final owner = life();
        final entered = Completer<void>(), release = Completer<void>();
        var held = false;
        hook = (call) async {
          if (call.method == 'read' && !held) {
            held = true;
            entered.complete();
            await release.future;
          }
        };
        final future = kind == 'transcript'
            ? LocalTranscriptStore.saveFromNewestFirst(
                'c',
                's',
                rows,
                profile: 'p',
                lifecycle: owner,
              )
            : kind == 'draft'
            ? drafts.save(
                'c',
                's',
                'stale',
                const [],
                profile: 'p',
                lifecycle: owner,
              )
            : TurnOutboxStore(lifecycle: owner).save(turn());
        final done = result(future);
        await entered.future;
        LocalConversationCleanupFence.endLifecycle(owner);
        release.complete();
        final outcome = await done;
        expect(outcome, isA<LocalConversationWriteRejected>());
        expect(
          secure,
          isEmpty,
          reason: 'No mutating storage call started before dispose',
        );
      },
    );
  }

  for (final reversed in [false, true]) {
    test(
      'B5 crossed alias owners revoke the previous destination owner reverse=$reversed',
      () async {
        final firstId = reversed ? 'canonical' : 'legacy';
        final secondId = reversed ? 'legacy' : 'canonical';
        final prior = life(s: 'prior');
        await drafts.deleteForProfile('c', 'p');
        LocalConversationCleanupFence.endLifecycle(prior);
        final old = life(s: firstId, aliases: [secondId]);
        expect(LocalConversationCleanupFence.rehydrate(old), isTrue);
        final fresh = life(s: secondId, aliases: [firstId]);
        expect(LocalConversationCleanupFence.rehydrate(fresh), isTrue);
        await drafts.save(
          'c',
          'canonical',
          'fresh',
          const [],
          profile: 'p',
          lifecycle: fresh,
        );
        final outcome = await result(
          drafts.save(
            'c',
            'canonical',
            'stale',
            const [],
            profile: 'p',
            lifecycle: old,
          ),
        );
        final loaded = await drafts.load('c', 'canonical', profile: 'p');
        expect(loaded.text, 'fresh');
        expect(outcome, isA<LocalConversationWriteRejected>());
      },
    );
  }

  test(
    'B2 real ActiveChat admission before cleanup cannot borrow reattach lifecycle',
    () async {
      final slow = SlowFenceStorage();
      final service = ActiveChatService(
        compressionFenceStore: DesktopCompressionFenceStore(storage: slow),
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
      final old = life(p: 'default');
      final chat = service.attach(
        connection: connection,
        sessionId: 's',
        sessionTitle: 'test',
        sessionProfile: 'default',
        localConversationLifecycle: old,
        disableForegroundKeepAlive: true,
      );
      addTearDown(service.dispose);
      await pumpEventQueue(times: 20);
      slow.entered = Completer<void>();
      slow.release = Completer<void>();
      final sending = result(
        chat.send(
          fullText: 'admitted before cleanup',
          model: 'm',
          history: const [],
        ),
      );
      await slow.entered!.future;
      await LocalTranscriptStore.deleteForProfile('c', 'default');
      LocalConversationCleanupFence.endLifecycle(old);
      final fresh = life(p: 'default');
      expect(LocalConversationCleanupFence.rehydrate(fresh), isTrue);
      expect(
        identical(
          chat,
          service.attach(
            connection: connection,
            sessionId: 's',
            sessionTitle: 'test',
            sessionProfile: 'default',
            localConversationLifecycle: fresh,
            disableForegroundKeepAlive: true,
          ),
        ),
        isTrue,
      );
      // Stop at the secure write seam, before any Bridge or network operation.
      hook = (call) async {
        if (call.method == 'write') chat.dispose();
      };
      slow.release!.complete();
      await sending.timeout(const Duration(seconds: 3));
      final stored = await LocalTranscriptStore.load(
        'c',
        's',
        profile: 'default',
      );
      expect(stored, isEmpty);
    },
  );

  test(
    'B4 dispose also revokes outbox queued behind inner ownership queue',
    () async {
      final owner = life();
      final release = Completer<void>();
      final blocker = AttachmentOwnershipCoordinator.serialize(
        () => release.future,
      );
      final saving = result(TurnOutboxStore(lifecycle: owner).save(turn()));
      await pumpEventQueue(times: 5);
      LocalConversationCleanupFence.endLifecycle(owner);
      release.complete();
      await blocker;
      await saving;
      expect(secure, isEmpty);
    },
  );

  for (final failSave in [false, true]) {
    test(
      'B1 last pending owner ${failSave ? 'failure' : 'cancellation'} leaves no orphan private copy',
      () async {
        final item = await attachment();
        drafts = ChatDraftStore(
          await SharedPreferences.getInstance(),
          mutationNamespaceForTesting: files.path,
          deletePrivateCopy: (a) async {
            await File(a.localPath).delete();
            return true;
          },
        );
        await drafts.save('c', 's', 'draft', [item], profile: 'p');
        final owner = life();
        final release = Completer<void>();
        final blocker = LocalConversationCleanupFence.write(
          connectionId: 'unrelated',
          operation: () => release.future,
        );
        final saving = result(
          TurnOutboxStore(lifecycle: owner).save(turn(attachments: [item])),
        );
        await drafts.clear('c', 's', profile: 'p');
        expect(await File(item.localPath).exists(), isTrue);
        if (failSave) {
          hook = (call) async {
            if (call.method == 'write') {
              throw PlatformException(code: 'injected');
            }
          };
        } else {
          LocalConversationCleanupFence.endLifecycle(owner);
        }
        release.complete();
        await blocker;
        final outcome = await saving;
        expect(
          outcome,
          failSave
              ? isA<PlatformException>()
              : isA<LocalConversationWriteRejected>(),
        );
        expect(AttachmentOwnershipCoordinator.hasPendingOwner(item), isFalse);
        expect(secure, isEmpty);
        expect(await File(item.localPath).exists(), isFalse);
      },
    );
  }

  test(
    'B3 mixed overlapping cleanups stay closed after first failure',
    () async {
      final entered1 = Completer<void>(), release1 = Completer<void>();
      final entered2 = Completer<void>(), release2 = Completer<void>();
      final first = result(
        LocalConversationCleanupFence.cleanupProfile(
          connectionId: 'c',
          profile: 'p',
          operation: () async {
            entered1.complete();
            await release1.future;
            throw StateError('injected');
          },
        ),
      );
      await entered1.future;
      final second = LocalConversationCleanupFence.cleanupConnection(
        connectionId: 'c',
        operation: () async {
          entered2.complete();
          await release2.future;
        },
      );
      release1.complete();
      expect(await first, isA<StateError>());
      await entered2.future;
      final owner = life();
      expect(LocalConversationCleanupFence.rehydrate(owner), isFalse);
      expect(
        await result(
          LocalTranscriptStore.saveFromNewestFirst(
            'c',
            's',
            rows,
            profile: 'p',
            lifecycle: owner,
          ),
        ),
        isA<LocalConversationWriteRejected>(),
      );
      release2.complete();
      await second;
      expect(LocalConversationCleanupFence.rehydrate(owner), isTrue);
    },
  );

  test(
    'B2 token callback captured before cleanup rejects after replacement',
    () async {
      final old = life();
      Future<dynamic> callback() => LocalTranscriptStore.saveFromNewestFirst(
        'c',
        's',
        rows,
        profile: 'p',
        lifecycle: old,
      );
      await LocalTranscriptStore.deleteForProfile('c', 'p');
      final fresh = life();
      expect(LocalConversationCleanupFence.rehydrate(fresh), isTrue);
      expect(await result(callback()), isA<LocalConversationWriteRejected>());
      expect(secure, isEmpty);
    },
  );

  test(
    'B2 admitted queued write is rejected by cleanup and unrelated writer survives',
    () async {
      final release = Completer<void>();
      final blocker = LocalConversationCleanupFence.write(
        connectionId: 'unrelated',
        operation: () => release.future,
      );
      final stale = result(
        LocalTranscriptStore.saveFromNewestFirst(
          'c',
          's',
          rows,
          profile: 'p',
          lifecycle: life(),
        ),
      );
      final cleanup = LocalTranscriptStore.deleteForProfile('c', 'p');
      final neighbor = LocalTranscriptStore.saveFromNewestFirst(
        'neighbor',
        's',
        rows,
        profile: 'p',
      );
      release.complete();
      await blocker;
      expect(await stale, isA<LocalConversationWriteRejected>());
      await cleanup;
      await neighbor;
      expect(await LocalTranscriptStore.load('c', 's', profile: 'p'), isEmpty);
      expect(
        await LocalTranscriptStore.load('neighbor', 's', profile: 'p'),
        hasLength(1),
      );
    },
  );

  test(
    'B6 covered recursive cleanup and throwing child release global queue',
    () async {
      final events = <String>[];
      final outcome = await result(
        LocalConversationCleanupFence.cleanupConnection<void>(
          connectionId: 'c',
          operation: () async {
            await LocalConversationCleanupFence.cleanupConnection<void>(
              connectionId: 'c',
              operation: () async {
                await LocalConversationCleanupFence.cleanupProfile<void>(
                  connectionId: 'c',
                  profile: 'p',
                  operation: () async {
                    await LocalTranscriptStore.deleteForProfile('c', 'p');
                    events.add('inner');
                    throw StateError('child failure');
                  },
                );
              },
            );
          },
        ),
      );
      expect(outcome, isA<StateError>());
      await LocalTranscriptStore.saveFromNewestFirst('neighbor', 's', rows);
      expect(events, ['inner']);
      expect(secure, hasLength(1));
    },
  );

  test(
    'B6 inherited expired cleanup zone cannot bypass a new cleanup',
    () async {
      final lateTrigger = Completer<void>();
      final finished = Completer<void>();
      await LocalConversationCleanupFence.cleanupProfile(
        connectionId: 'c',
        profile: 'p',
        operation: () async {
          unawaited(() async {
            await lateTrigger.future;
            await LocalTranscriptStore.deleteForProfile('c', 'p');
            finished.complete();
          }());
        },
      );
      final release = Completer<void>();
      final blocker = LocalConversationCleanupFence.write(
        connectionId: 'unrelated',
        operation: () => release.future,
      );
      lateTrigger.complete();
      await pumpEventQueue(times: 10);
      expect(finished.isCompleted, isFalse);
      release.complete();
      await blocker;
      await finished.future;
    },
  );

  test(
    'B7 opaque tuple cross product survives exact connection cleanup',
    () async {
      final scopes = [
        (c: 'c', p: 'x\u001fp'),
        (c: 'c\u001fx', p: 'p'),
        (c: 'c\u0000', p: '*'),
        (c: 'c', p: ' p '),
        (c: 'c.', p: '😀'),
        (c: 'c', p: 'p'),
      ];
      final owners = [for (final scope in scopes) life(c: scope.c, p: scope.p)];
      for (var i = 0; i < scopes.length; i++) {
        expect(LocalConversationCleanupFence.rehydrate(owners[i]), isTrue);
        await LocalTranscriptStore.saveFromNewestFirst(
          scopes[i].c,
          's',
          rows,
          profile: scopes[i].p,
          lifecycle: owners[i],
        );
      }
      expect(secure, hasLength(scopes.length));
      await LocalTranscriptStore.deleteForConnection('c');
      for (var i = 0; i < scopes.length; i++) {
        expect(
          await LocalTranscriptStore.load(
            scopes[i].c,
            's',
            profile: scopes[i].p,
          ),
          scopes[i].c == 'c' ? isEmpty : hasLength(1),
        );
      }
    },
  );
}
