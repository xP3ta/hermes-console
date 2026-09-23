import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/local_transcript_store.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

import 'support/in_memory_compression_restore_storage.dart';

class _LocalBridge extends BridgeClient {
  _LocalBridge() : super(baseUrl: 'http://127.0.0.1:1', token: 'fixture');

  @override
  Stream<String> chatStream(
    String prompt, {
    List<Map<String, dynamic>> history = const [],
    List<String> attachmentPaths = const [],
    Duration timeout = const Duration(minutes: 5),
    String profile = '',
  }) async* {
    yield 'reply:$prompt';
  }

  @override
  void close() {}
}

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
    'B2 reattach preserves confirmed history but cleanup retires it',
    () async {
      final requests = <String>[];
      await http.runWithClient(
        () async {
          final service = ActiveChatService(
            compressionRestoreStore: testCompressionRestoreStore(),
          );
          addTearDown(service.dispose);
          final connection = SavedConnection(
            id: 'c',
            label: 'fixture',
            host: '127.0.0.1',
            port: 1,
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
          final listener = chat.changes.listen((_) {});
          addTearDown(listener.cancel);
          expect(
            await chat.send(fullText: 'first', model: 'm', history: const []),
            isTrue,
            reason: 'requests=$requests messages=${chat.messages}',
          );
          LocalConversationCleanupFence.endLifecycle(firstOwner);
          final secondOwner = life();
          expect(identical(attach(secondOwner), chat), isTrue);
          expect(
            await chat.send(fullText: 'second', model: 'm', history: const []),
            isTrue,
          );
          expect(
            (await LocalTranscriptStore.load(
              'c',
              's',
              profile: 'default',
            )).map((row) => row['content']),
            ['first', 'reply:first', 'second', 'reply:second'],
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
          expect(
            (await LocalTranscriptStore.load(
              'c',
              's',
              profile: 'default',
            )).map((row) => row['content']),
            ['third', 'reply:third'],
          );
        },
        () => MockClient((request) async {
          requests.add('${request.method} ${request.url.path}');
          if (request.url.path == '/bridge/provision') {
            return http.Response('{"token":"fixture"}', 200);
          }
          if (request.url.path == '/bridge/chat/stream') {
            final prompt = (jsonDecode(request.body) as Map)['prompt'];
            return http.Response(
              'data: ${jsonEncode({'delta': 'reply:$prompt'})}\n\ndata: {"done":true}\n\n',
              200,
            );
          }
          return http.Response('{}', 404);
        }),
      );
      expect(
        requests.where((request) => request.startsWith('DELETE ')),
        isEmpty,
      );
    },
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
      'B2 revoked post-read producer retires only its overlay $profile',
      () async {
        final lifecycle = LocalConversationCleanupFence.beginLifecycle(
          connectionId: 'c',
          profile: profile,
          sessionId: 's',
        );
        final entered = Completer<void>();
        final release = Completer<void>();
        hook = (call) async {
          if (call.method == 'read' &&
              (call.arguments['key'] as String).startsWith(
                'hermes.transcript.v3.',
              )) {
            if (!entered.isCompleted) entered.complete();
            await release.future;
          }
        };
        final chat = ActiveChat(
          connection: SavedConnection(
            id: 'c',
            label: 'fixture',
            host: '127.0.0.1',
            port: 1,
            apiKey: '',
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
          bridgeProvisioner: (_, _) async => 'fixture',
          bridgeClientFactory: ({required baseUrl, required token}) =>
              _LocalBridge(),
        );
        addTearDown(chat.dispose);
        final sending = chat
            .send(
              fullText: 'revoked-overlay',
              model: 'm',
              history: const [],
              profile: profile,
            )
            .then<Object?>((_) => null, onError: (Object error) => error);
        await entered.future;
        final cleanup = LocalTranscriptStore.deleteForProfile('c', profile);
        LocalConversationCleanupFence.endLifecycle(lifecycle);
        release.complete();
        expect(await sending, isA<LocalConversationWriteRejected>());
        await cleanup;
        expect(secure, isEmpty);
        expect(
          chat.messages.where((row) => row['content'] == 'revoked-overlay'),
          isEmpty,
        );
      },
    );

    test(
      'B2 second successful producer preserves confirmed history $profile',
      () async {
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
            port: 1,
            apiKey: '',
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
          bridgeProvisioner: (_, _) async => 'fixture',
          bridgeClientFactory: ({required baseUrl, required token}) =>
              _LocalBridge(),
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
        expect(
          (await LocalTranscriptStore.load(
            'c',
            's',
            profile: profile,
          )).map((row) => row['content']),
          ['first', 'reply:first'],
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
        expect(
          (await LocalTranscriptStore.load(
            'c',
            's',
            profile: profile,
          )).map((row) => row['content']),
          ['first', 'reply:first', 'second', 'reply:second'],
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
        expect(
          await LocalTranscriptStore.load('c', 's', profile: profile),
          isEmpty,
        );
      },
    );
  }
}
