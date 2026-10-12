// SPDX-License-Identifier: MIT
import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
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

  for (final kind in InstanceKind.values) {
    for (final profile in ['default', 'worker']) {
      for (final retirement in [
        'none',
        'owner',
        'cleanup',
        'cleanup ABA',
        'dispose',
        'capability',
      ]) {
        test(
          'official $kind held resume $profile retirement=$retirement',
          () => HttpOverrides.runZoned(() async {
            final server = await OfficialResumeServer.start();
            addTearDown(server.close);
            final lifecycle = LocalConversationCleanupFence.beginLifecycle(
              connectionId: 'c',
              profile: profile,
              sessionId: 's',
            );
            server.holdResume = retirement != 'capability';
            server.holdCapability = retirement == 'capability';
            final chat = ActiveChat(
              connection: SavedConnection(
                id: 'c',
                label: 'fixture',
                host: '127.0.0.1',
                port: server.server.port,
                dashboardUrl: 'http://127.0.0.1:${server.server.port}',
                apiKey: 'fixture',
                kind: kind,
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
                  fullText: 'fixture-submit',
                  model: 'm',
                  history: const [],
                  profile: profile,
                )
                .then<Object?>(
                  (result) => result,
                  onError: (Object error) => error,
                );
            await (retirement == 'capability'
                    ? server.capabilityEntered.future
                    : server.resumeEntered.future)
                .timeout(const Duration(seconds: 3));
            if (retirement == 'owner' || retirement == 'capability') {
              LocalConversationCleanupFence.endLifecycle(lifecycle);
            }
            if (retirement.startsWith('cleanup')) {
              await LocalTranscriptStore.deleteForProfile('c', profile);
              if (retirement == 'cleanup ABA') {
                final replacement =
                    LocalConversationCleanupFence.beginLifecycle(
                      connectionId: 'c',
                      profile: profile,
                      sessionId: 's',
                    );
                expect(
                  LocalConversationCleanupFence.rehydrate(replacement),
                  isTrue,
                );
              }
            }
            if (retirement == 'dispose') chat.dispose();
            if (retirement == 'capability') {
              server.capabilityRelease.complete();
            } else {
              server.resumeRelease.complete();
            }
            final outcome = await sending.timeout(const Duration(seconds: 6));
            if (retirement == 'none') {
              expect(outcome, isTrue);
              server.expectFirstSubmit(chat, profile, 'fixture-submit');
            } else {
              expect(
                server.frames.where((f) => f['method'] == 'prompt.submit'),
                isEmpty,
              );
              expect(server.acceptedReplies, 0);
              expect(
                outcome,
                anyOf(isFalse, isA<LocalConversationWriteRejected>()),
              );
              if (retirement != 'dispose') {
                expect(
                  chat.messages.where((r) => r['content'] == 'fixture-submit'),
                  isEmpty,
                );
                expect(chat.state, ChatPipelineState.failed);
                expect(chat.isStreaming, isFalse);
              }
            }
            expect(
              secure.keys.where((k) => k.startsWith('hermes.transcript.v3.')),
              isEmpty,
            );
          }, createHttpClient: RealFixtureHttp().createHttpClient),
        );
      }

      test(
        'official $kind replacement owner cannot renew old resume $profile',
        () => HttpOverrides.runZoned(() async {
          final server = await OfficialResumeServer.start();
          addTearDown(server.close);
          server.holdResume = true;
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
            kind: kind,
            onDeviceLoopback: true,
            localChatMode: LocalChatMode.agent,
          );
          LocalConversationLifecycle life() =>
              LocalConversationCleanupFence.beginLifecycle(
                connectionId: 'c',
                profile: profile,
                sessionId: 's',
              );
          ActiveChat attach(LocalConversationLifecycle owner) => service.attach(
            connection: connection,
            sessionId: 's',
            sessionTitle: 'fixture',
            sessionProfile: profile,
            localConversationLifecycle: owner,
            disableForegroundKeepAlive: true,
          );
          final oldOwner = life();
          final chat = attach(oldOwner);
          final listener = chat.changes.listen((_) {});
          addTearDown(listener.cancel);
          final sending = chat.send(
            fullText: 'obsolete',
            model: 'm',
            history: const [],
            profile: profile,
          );
          await server.resumeEntered.future.timeout(const Duration(seconds: 3));
          LocalConversationCleanupFence.endLifecycle(oldOwner);
          final replacement = life();
          expect(identical(attach(replacement), chat), isTrue);
          final successor = chat.send(
            fullText: 'successor',
            model: 'm',
            history: const [],
            profile: profile,
          );
          server.resumeRelease.complete();
          expect(await sending.timeout(const Duration(seconds: 6)), isFalse);
          expect(await successor.timeout(const Duration(seconds: 6)), isTrue);
          expect(
            chat.messages.where((r) => r['content'] == 'obsolete'),
            isEmpty,
          );
          expect(chat.state, ChatPipelineState.waiting);
          expect(chat.isStreaming, isTrue);
          final submits = server.frames
              .where((f) => f['method'] == 'prompt.submit')
              .toList();
          expect(submits, hasLength(1));
          expect(submits.single['params'], containsPair('text', 'successor'));
          expect(server.acceptedReplies, 1);
        }, createHttpClient: RealFixtureHttp().createHttpClient),
      );

      for (final boundary in ['admission', 'pre-submit', 'accepted']) {
        test(
          'official $kind authority boundary $boundary $profile',
          () => HttpOverrides.runZoned(() async {
            final server = await OfficialResumeServer.start();
            addTearDown(server.close);
            server.holdAccepted = boundary == 'accepted';
            final owner = LocalConversationCleanupFence.beginLifecycle(
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
                kind: kind,
                onDeviceLoopback: true,
                localChatMode: LocalChatMode.agent,
              ),
              sessionId: 's',
              sessionTitle: 'fixture',
              sessionProfile: profile,
              localConversationLifecycle: owner,
              notifications: null,
              onTerminal: () {},
              compressionRestoreStore: testCompressionRestoreStore(),
            );
            addTearDown(chat.dispose);
            final entered = Completer<void>();
            final release = Completer<void>();
            Future<void> wait() async {
              entered.complete();
              await release.future;
            }

            if (boundary == 'admission') {
              chat.beforeSendAdmissionForTesting = wait;
            }
            final sending = chat
                .send(
                  fullText: 'boundary-fixture',
                  model: 'm',
                  history: const [],
                  profile: profile,
                  beforeDesktopPromptSubmit: boundary == 'pre-submit'
                      ? (_) => wait()
                      : null,
                )
                .then<Object?>(
                  (value) => value,
                  onError: (Object error) => error,
                );
            await (boundary == 'accepted'
                    ? server.acceptedEntered.future
                    : entered.future)
                .timeout(const Duration(seconds: 5));
            LocalConversationCleanupFence.endLifecycle(owner);
            if (boundary == 'accepted') {
              server.acceptedRelease.complete();
            } else {
              release.complete();
            }
            final outcome = await sending.timeout(const Duration(seconds: 6));
            final submits = server.frames.where(
              (f) => f['method'] == 'prompt.submit',
            );
            if (boundary == 'accepted') {
              expect(outcome, isTrue);
              expect(submits, hasLength(1));
              expect(server.acceptedReplies, 1);
              expect(server.history.map((row) => row['content']), [
                'boundary-fixture',
                'reply:boundary-fixture',
              ]);
              expect(
                chat.messages.where(
                  (row) => row['content'] == 'boundary-fixture',
                ),
                hasLength(1),
              );
              expect(
                server.frames.where(
                  (f) => (f['method'] as String).contains('delete'),
                ),
                isEmpty,
              );
            } else {
              expect(
                outcome,
                anyOf(isFalse, isA<LocalConversationWriteRejected>()),
              );
              expect(submits, isEmpty);
              expect(server.acceptedReplies, 0);
            }
          }, createHttpClient: RealFixtureHttp().createHttpClient),
        );
      }

      if (kind != InstanceKind.localhost) {
        test(
          'official $kind ownerless remote remains admitted $profile',
          () => HttpOverrides.runZoned(() async {
            final server = await OfficialResumeServer.start();
            addTearDown(server.close);
            final chat = ActiveChat(
              connection: SavedConnection(
                id: 'c',
                label: 'fixture',
                host: '127.0.0.1',
                port: server.server.port,
                dashboardUrl: 'http://127.0.0.1:${server.server.port}',
                apiKey: 'fixture',
                kind: kind,
              ),
              sessionId: 's',
              sessionTitle: 'fixture',
              sessionProfile: profile,
              notifications: null,
              onTerminal: () {},
              compressionRestoreStore: testCompressionRestoreStore(),
            );
            addTearDown(chat.dispose);
            expect(
              await chat.send(
                fullText: 'ownerless-control',
                model: 'm',
                history: const [],
                profile: profile,
              ),
              isTrue,
            );
            server.expectFirstSubmit(chat, profile, 'ownerless-control');
          }, createHttpClient: RealFixtureHttp().createHttpClient),
        );
      }
    }
  }
}
