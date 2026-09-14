import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/local_transcript_store.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

LocalConversationLifecycle owner({
  String connection = 'c',
  String profile = 'p',
}) => LocalConversationCleanupFence.beginLifecycle(
  connectionId: connection,
  profile: profile,
  sessionId: 's',
);
const rows = <Map<String, dynamic>>[
  {'role': 'assistant', 'content': 'pre-cleanup stale content'},
];
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secure = <String, String>{};
  setUp(() {
    LocalConversationCleanupFence.resetForTesting();
    TurnOutboxStore.resetSerializationForTesting();
    SharedPreferences.setMockInitialValues({});
    secure.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
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
  for (final connectionCleanup in [false, true]) {
    test(
      'overlapping ${connectionCleanup ? "connection" : "profile"} cleanup must keep rehydrate closed',
      () async {
        final entered1 = Completer<void>(), release1 = Completer<void>();
        final entered2 = Completer<void>(), release2 = Completer<void>();
        Future<void> cleanup(Future<void> Function() op) => connectionCleanup
            ? LocalConversationCleanupFence.cleanupConnection(
                connectionId: 'c',
                operation: op,
              )
            : LocalConversationCleanupFence.cleanupProfile(
                connectionId: 'c',
                profile: 'p',
                operation: op,
              );
        final first = cleanup(() async {
          entered1.complete();
          await release1.future;
        });
        await entered1.future;
        final second = cleanup(() async {
          entered2.complete();
          await release2.future;
        });
        release1.complete();
        await first;
        await entered2.future;
        final life = owner();
        final admitted = LocalConversationCleanupFence.rehydrate(life);
        final write = LocalTranscriptStore.saveFromNewestFirst(
          'c',
          's',
          rows,
          profile: 'p',
          lifecycle: life,
        ).then<Object?>((_) => null, onError: (Object e) => e);
        release2.complete();
        await second;
        final result = await write;
        expect(admitted, isFalse);
        expect(result, isA<LocalConversationWriteRejected>());
        expect(secure, isEmpty);
      },
    );
  }
  test('disposed queued write must not execute', () async {
    await LocalTranscriptStore.deleteForProfile('c', 'p');
    final release = Completer<void>();
    final blocker = LocalConversationCleanupFence.write(
      connectionId: 'other',
      operation: () => release.future,
    );
    final life = owner();
    var wrote = false;
    final queued = LocalConversationCleanupFence.write(
      lifecycle: life,
      operation: () async {
        wrote = true;
      },
    ).then<Object?>((_) => null, onError: (Object e) => e);
    LocalConversationCleanupFence.endLifecycle(life);
    release.complete();
    await blocker;
    final result = await queued;
    expect(wrote, isFalse);
    expect(result, isA<LocalConversationWriteRejected>());
  });
  test(
    'late implicit transcript callback cannot borrow replacement owner',
    () async {
      final stale = owner();
      LocalConversationCleanupFence.rehydrate(stale);
      Future<void> lateCallback() async {
        await LocalTranscriptStore.saveFromNewestFirst(
          'c',
          's',
          rows,
          profile: 'p',
        );
      }

      await LocalTranscriptStore.deleteForProfile('c', 'p');
      LocalConversationCleanupFence.endLifecycle(stale);
      final current = owner();
      expect(LocalConversationCleanupFence.rehydrate(current), isTrue);
      final result = await lateCallback().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      expect(result, isA<LocalConversationWriteRejected>());
      expect(secure, isEmpty);
    },
  );
  test(
    'lifecycle cannot authorize a different cleaned storage scope',
    () async {
      final victim = owner(connection: 'victim');
      LocalConversationCleanupFence.rehydrate(victim);
      await LocalTranscriptStore.deleteForConnection('victim');
      final other = owner(connection: 'other');
      LocalConversationCleanupFence.rehydrate(other);
      final result = await LocalTranscriptStore.saveFromNewestFirst(
        'victim',
        's',
        rows,
        profile: 'p',
        lifecycle: other,
      ).then<Object?>((_) => null, onError: (Object e) => e);
      expect(result, isA<LocalConversationWriteRejected>());
    },
  );
  test('nested connection to profile cleanup must finish', () async {
    final result =
        await LocalConversationCleanupFence.cleanupConnection(
              connectionId: 'c',
              operation: () => LocalTranscriptStore.deleteForProfile('c', 'p'),
            )
            .timeout(const Duration(milliseconds: 300))
            .then<Object?>((n) => n, onError: (Object e) => e);
    expect(result, 0);
  });
  test('draft save admission cannot be overtaken by clear', () async {
    final drafts = ChatDraftStore(await SharedPreferences.getInstance());
    final release = Completer<void>();
    final blocker = LocalConversationCleanupFence.write(
      connectionId: 'other',
      operation: () => release.future,
    );
    final save = drafts.save(
      'c',
      's',
      'must not resurrect',
      const [],
      profile: 'p',
    );
    await drafts.clear('c', 's', profile: 'p');
    release.complete();
    await blocker;
    await save;
    final text = (await drafts.load('c', 's', profile: 'p')).text;
    expect(text, isEmpty);
  });
  test('outbox save admission cannot be overtaken by deleteForChat', () async {
    final store = TurnOutboxStore();
    final release = Completer<void>();
    final blocker = LocalConversationCleanupFence.write(
      connectionId: 'other',
      operation: () => release.future,
    );
    final turn = PreparedTurn(
      connectionId: 'c',
      sessionId: 's',
      clientTurnId: 't',
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      text: 'must not resurrect',
      attachments: const [],
      model: 'm',
      profile: 'p',
      state: PreparedTurnState.prepared,
    );
    final save = store.save(turn);
    await store.deleteForChat('c', 's', profile: 'p');
    release.complete();
    await blocker;
    await save;
    final restored = await store.loadForChat('c', 's', profile: 'p');
    expect(restored, isNull);
  });
  test(
    'fence identities must remain injective for opaque scope strings',
    () async {
      final first = owner(connection: 'c', profile: 'x\u001fp');
      final second = owner(connection: 'c\u001fx', profile: 'p');
      final firstValid = LocalConversationCleanupFence.rehydrate(first);
      final secondValid = LocalConversationCleanupFence.rehydrate(second);
      expect(firstValid, isTrue);
      expect(secondValid, isTrue);
    },
  );
  test('canonical whitespace profile orchestrator must finish', () async {
    final drafts = ChatDraftStore(await SharedPreferences.getInstance());
    final result =
        await clearProfileLocalConversationState(
              connectionId: 'c',
              profile: ' p ',
              clearDrafts: ({required profile}) =>
                  drafts.deleteForProfile('c', profile),
              clearTranscripts: ({required profile}) =>
                  LocalTranscriptStore.deleteForProfile('c', profile),
              clearOutbox: ({required profile}) =>
                  TurnOutboxStore().deleteForProfile('c', profile),
            )
            .timeout(const Duration(milliseconds: 300))
            .then<Object?>((s) => s, onError: (Object e) => e);
    expect(result, isA<LocalConversationClearSummary>());
  });
}
