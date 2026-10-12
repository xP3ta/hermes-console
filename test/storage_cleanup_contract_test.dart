import 'dart:async';

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/local_transcript_store.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

import 'support/in_memory_compression_restore_storage.dart';
import 'support/official_resume_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secure = <String, String>{};
  Future<void> Function(MethodCall)? hook;
  setUp(() {
    LocalConversationCleanupFence.resetForTesting();
    TurnOutboxStore.resetSerializationForTesting();
    SharedPreferences.setMockInitialValues({});
    secure.clear();
    hook = null;
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
              case 'delete':
                secure.remove(args['key']);
            }
            return null;
          },
        );
  });

  test(
    'B2 official reattach preserves remote history across local cleanup',
    () => HttpOverrides.runZoned(() async {
      final server = await OfficialResumeServer.start();
      addTearDown(server.close);
      final service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      addTearDown(service.dispose);
      final connection = SavedConnection(
        id: 'c',
        label: 'fixture',
        host: '127.0.0.1',
        port: server.server.port,
        dashboardUrl: 'http://127.0.0.1:${server.server.port}',
        apiKey: 'fixture',
        kind: InstanceKind.localhost,
        onDeviceLoopback: true,
        localChatMode: LocalChatMode.agent,
      );
      LocalConversationLifecycle life() =>
          LocalConversationCleanupFence.beginLifecycle(
            connectionId: 'c',
            profile: 'default',
            sessionId: 's',
          );
      ActiveChat attach(LocalConversationLifecycle owner) => service.attach(
        connection: connection,
        sessionId: 's',
        sessionTitle: 'fixture',
        sessionProfile: 'default',
        localConversationLifecycle: owner,
        disableForegroundKeepAlive: true,
      );
      final firstOwner = life();
      final chat = attach(firstOwner);
      expect(
        await chat.send(fullText: 'first', model: 'm', history: const []),
        isTrue,
      );
      await server.completeTurn(chat, 'first');
      LocalConversationCleanupFence.endLifecycle(firstOwner);
      final secondOwner = life();
      expect(identical(attach(secondOwner), chat), isTrue);
      expect(
        await chat.send(fullText: 'second', model: 'm', history: const []),
        isTrue,
      );
      await server.completeTurn(chat, 'second');
      await chat.loadMessages(profile: 'default', passiveOnly: true);
      expect(chat.messages.reversed.map((row) => row['content']), [
        'first',
        'reply:first',
        'second',
        'reply:second',
      ]);
      expect(
        await LocalTranscriptStore.load('c', 's', profile: 'default'),
        isEmpty,
      );
      await LocalTranscriptStore.deleteForProfile('c', 'default');
      LocalConversationCleanupFence.endLifecycle(secondOwner);
      final thirdOwner = life();
      expect(LocalConversationCleanupFence.rehydrate(thirdOwner), isTrue);
      expect(identical(attach(thirdOwner), chat), isTrue);
      expect(
        await chat.send(fullText: 'third', model: 'm', history: const []),
        isTrue,
      );
      await server.completeTurn(chat, 'third');
      await chat.loadMessages(profile: 'default', passiveOnly: true);
      expect(chat.messages.reversed.map((row) => row['content']), [
        'first',
        'reply:first',
        'second',
        'reply:second',
        'third',
        'reply:third',
      ]);
      expect(
        await LocalTranscriptStore.load('c', 's', profile: 'default'),
        isEmpty,
      );
      expect(server.acceptedReplies, 3);
      // Three terminal proofs plus the two explicit read-only reloads.
      expect(server.historyReads, hasLength(5));
      expect(server.paths.where((p) => p.contains('bridge')), isEmpty);
      expect(
        server.frames.where((f) => (f['method'] as String).contains('delete')),
        isEmpty,
      );
    }, createHttpClient: RealFixtureHttp().createHttpClient),
  );

  test('B1 rejected empty save cannot supersede a second producer', () async {
    final drafts = ChatDraftStore(await SharedPreferences.getInstance());
    final old = LocalConversationCleanupFence.beginLifecycle(
      connectionId: 'c',
      profile: 'p',
      sessionId: 's',
    );
    final fresh = LocalConversationCleanupFence.beginLifecycle(
      connectionId: 'c',
      profile: 'p',
      sessionId: 's',
    );
    final release = Completer<void>();
    final blocked = LocalConversationCleanupFence.write(
      connectionId: 'other',
      operation: () => release.future,
    );
    final saving = drafts.save(
      'c',
      's',
      'fresh',
      const [],
      profile: 'p',
      lifecycle: fresh,
    );
    await expectLater(
      drafts.save('c', 's', '', const [], profile: 'p', lifecycle: old),
      throwsA(isA<LocalConversationWriteRejected>()),
    );
    release.complete();
    await blocked;
    await saving;
    expect((await drafts.load('c', 's', profile: 'p')).text, 'fresh');
  });

  for (final store in ['outbox', 'transcript']) {
    test('B1 draft session clear preserves admitted $store producer', () async {
      final drafts = ChatDraftStore(await SharedPreferences.getInstance());
      final release = Completer<void>();
      final blocked = LocalConversationCleanupFence.write(
        connectionId: 'other',
        operation: () => release.future,
      );
      final saving = store == 'outbox'
          ? TurnOutboxStore().save(
              PreparedTurn(
                connectionId: 'c',
                sessionId: 's',
                clientTurnId: 't',
                createdAtMs: DateTime.now().millisecondsSinceEpoch,
                updatedAtMs: DateTime.now().millisecondsSinceEpoch,
                text: 'retained',
                attachments: const [],
                model: 'm',
                profile: 'p',
              ),
            )
          : LocalTranscriptStore.saveFromNewestFirst('c', 's', const [
              {'role': 'user', 'content': 'retained'},
            ], profile: 'p');
      await drafts.clearForSession('c', 's');
      release.complete();
      await blocked;
      await saving;
      if (store == 'outbox') {
        expect(
          (await TurnOutboxStore().loadForChat('c', 's', profile: 'p'))?.text,
          'retained',
        );
      } else {
        expect(
          (await LocalTranscriptStore.load(
            'c',
            's',
            profile: 'p',
          )).map((row) => row['content']),
          ['retained'],
        );
      }
    });
  }

  for (final ownerKind in ['producer', 'pending', 'durable']) {
    test(
      'B1 shared physical copy survives distinct localId $ownerKind owner',
      () async {
        final dir = await Directory.systemTemp.createTemp('cleanup-fix2-');
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/shared.txt')
          ..writeAsStringSync('fixture');
        AttachmentDraft attachment(String id) => AttachmentDraft(
          localId: id,
          type: AttachmentType.document,
          name: 'shared.txt',
          mimeType: 'text/plain',
          sizeBytes: 7,
          localPath: file.path,
        );
        final source = attachment('source');
        final shared = attachment('different-owner');
        var deletes = 0;
        final drafts = ChatDraftStore(
          await SharedPreferences.getInstance(),
          deletePrivateCopy: (item) async {
            deletes++;
            if (file.existsSync()) await file.delete();
            return true;
          },
        );
        await drafts.save('c', 'source', '', [source], profile: 'p');
        int? token;
        if (ownerKind == 'producer') {
          token = AttachmentOwnershipCoordinator.retainProducer([shared]);
        } else if (ownerKind == 'pending') {
          token = AttachmentOwnershipCoordinator.reservePendingOwner([shared]);
        } else {
          await drafts.save('other', 'shared', '', [shared], profile: 'q');
        }
        await drafts.clear('c', 'source', profile: 'p');
        expect(deletes, 0);
        expect(file.existsSync(), isTrue);
        if (ownerKind == 'producer') {
          await AttachmentOwnershipCoordinator.releaseProducer(
            token,
            drafts.retireAttachments,
          );
        } else if (ownerKind == 'pending') {
          await AttachmentOwnershipCoordinator.withdrawPendingOwner(
            token,
            drafts.retireAttachments,
          );
        } else {
          await drafts.clear('other', 'shared', profile: 'q');
        }
        expect(file.existsSync(), isFalse);
        expect(deletes, 1);
      },
    );
  }

  test(
    'B5 declared foreign resource cannot borrow an operation authority',
    () async {
      final lifecycle = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'other',
        profile: 'p',
        sessionId: 's',
      );
      final victim = LocalConversationResourceKey(
        connectionId: 'victim',
        profile: 'p',
        sessionId: 's',
        physicalKey: 'victim-key',
      );
      var writes = 0;
      await expectLater(
        Future<void>.sync(() async {
          final operation = LocalConversationCleanupFence.admitOperation(
            connectionId: 'other',
            profile: 'p',
            sessionId: 's',
            lifecycle: lifecycle,
            kind: LocalConversationOperationKind.save,
            resources: [victim],
          );
          await LocalConversationCleanupFence.commitEffect(
            operation: operation,
            resource: victim,
            mutation: () async {
              writes++;
            },
          );
        }),
        throwsA(isA<LocalConversationWriteRejected>()),
      );
      expect(writes, 0);
    },
  );

  test('B4 producer exact clear remains revocable before handoff', () async {
    final lifecycle = LocalConversationCleanupFence.beginLifecycle(
      connectionId: 'c',
      profile: 'p',
      sessionId: 's',
    );
    final resource = LocalConversationResourceKey(
      connectionId: 'c',
      profile: 'p',
      sessionId: 's',
      physicalKey: 'key',
    );
    final operation = LocalConversationCleanupFence.admitOperation(
      connectionId: 'c',
      profile: 'p',
      sessionId: 's',
      lifecycle: lifecycle,
      kind: LocalConversationOperationKind.clearExact,
      resources: [resource],
    );
    LocalConversationCleanupFence.endLifecycle(lifecycle);
    var deletes = 0;
    await expectLater(
      LocalConversationCleanupFence.commitEffect(
        operation: operation,
        resource: resource,
        mutation: () async {
          deletes++;
        },
      ),
      throwsA(isA<LocalConversationWriteRejected>()),
    );
    expect(deletes, 0);
  });

  for (final profile in ['default', 'worker']) {
    test(
      'B2 official revoked resume retires only its overlay $profile',
      () => HttpOverrides.runZoned(() async {
        final server = await OfficialResumeServer.start();
        addTearDown(server.close);
        server.holdResume = true;
        final lifecycle = LocalConversationCleanupFence.beginLifecycle(
          connectionId: 'c',
          profile: profile,
          sessionId: 's',
        );
        final chat = ActiveChat(
          connection: SavedConnection(
            id: 'c',
            label: 'fixture',
            host: '127.0.0.1',
            port: server.server.port,
            dashboardUrl: 'http://127.0.0.1:${server.server.port}',
            apiKey: 'fixture',
            kind: InstanceKind.localhost,
            onDeviceLoopback: true,
            localChatMode: LocalChatMode.agent,
          ),
          sessionId: 's',
          sessionTitle: 'fixture',
          sessionProfile: profile,
          localConversationLifecycle: lifecycle,
          notifications: null,
          onTerminal: () {},
          compressionRestoreStore: testCompressionRestoreStore(),
        );
        addTearDown(chat.dispose);
        final sending = chat
            .send(
              fullText: 'revoked-overlay',
              model: 'm',
              history: const [],
              profile: profile,
            )
            .then<Object?>(
              (result) => result,
              onError: (Object error) => error,
            );
        await server.resumeEntered.future.timeout(const Duration(seconds: 3));
        final cleanup = LocalTranscriptStore.deleteForProfile('c', profile);
        LocalConversationCleanupFence.endLifecycle(lifecycle);
        server.resumeRelease.complete();
        expect(
          await sending.timeout(const Duration(seconds: 6)),
          anyOf(isFalse, isA<LocalConversationWriteRejected>()),
        );
        await cleanup;
        expect(
          server.frames.where((f) => f['method'] == 'prompt.submit'),
          isEmpty,
        );
        expect(server.acceptedReplies, 0);
        expect(secure, isEmpty);
        expect(
          chat.messages.where((row) => row['content'] == 'revoked-overlay'),
          isEmpty,
        );
        expect(chat.state, ChatPipelineState.failed);
        expect(chat.isStreaming, isFalse);
      }, createHttpClient: RealFixtureHttp().createHttpClient),
    );

    test(
      'B2 official same owner preserves server history without local writer $profile',
      () => HttpOverrides.runZoned(() async {
        final server = await OfficialResumeServer.start();
        addTearDown(server.close);
        final lifecycle = LocalConversationCleanupFence.beginLifecycle(
          connectionId: 'c',
          profile: profile,
          sessionId: 's',
        );
        final chat = ActiveChat(
          connection: SavedConnection(
            id: 'c',
            label: 'fixture',
            host: '127.0.0.1',
            port: server.server.port,
            dashboardUrl: 'http://127.0.0.1:${server.server.port}',
            apiKey: 'fixture',
            kind: InstanceKind.localhost,
            onDeviceLoopback: true,
            localChatMode: LocalChatMode.agent,
          ),
          sessionId: 's',
          sessionTitle: 'fixture',
          sessionProfile: profile,
          localConversationLifecycle: lifecycle,
          notifications: null,
          onTerminal: () {},
          compressionRestoreStore: testCompressionRestoreStore(),
        );
        addTearDown(chat.dispose);
        expect(
          await chat.send(
            fullText: 'first',
            model: 'm',
            history: const [],
            profile: profile,
          ),
          isTrue,
        );
        await server.completeTurn(chat, 'first');
        await chat.loadMessages(profile: profile, passiveOnly: true);
        expect(chat.messages.reversed.map((row) => row['content']), [
          'first',
          'reply:first',
        ]);
        expect(
          await LocalTranscriptStore.load('c', 's', profile: profile),
          isEmpty,
        );
        expect(
          await chat.send(
            fullText: 'second',
            model: 'm',
            history: const [],
            profile: profile,
          ),
          isTrue,
        );
        await server.completeTurn(chat, 'second');
        await chat.loadMessages(profile: profile, passiveOnly: true);
        expect(chat.messages.reversed.map((row) => row['content']), [
          'first',
          'reply:first',
          'second',
          'reply:second',
        ]);
        expect(server.acceptedReplies, 2);
        expect(
          server.frames.where((f) => f['method'] == 'session.resume'),
          hasLength(1),
        );
        // Two terminal proofs plus the two explicit read-only reloads.
        expect(server.historyReads, hasLength(4));
        expect(
          server.historyReads.every(
            (uri) =>
                uri.path ==
                (profile == 'default'
                    ? '/api/sessions/s/messages'
                    : '/p/$profile/api/sessions/s/messages'),
          ),
          isTrue,
        );
        await LocalTranscriptStore.deleteForProfile('c', profile);
        await expectLater(
          chat.send(
            fullText: 'revoked',
            model: 'm',
            history: const [],
            profile: profile,
          ),
          throwsA(isA<LocalConversationWriteRejected>()),
        );
        expect(server.acceptedReplies, 2);
        expect(
          await LocalTranscriptStore.load('c', 's', profile: profile),
          isEmpty,
        );
        expect(server.paths.where((p) => p.contains('bridge')), isEmpty);
      }, createHttpClient: RealFixtureHttp().createHttpClient),
    );
  }
}
