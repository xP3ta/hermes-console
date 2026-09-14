import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/transcript_privacy_state.dart';
import 'package:hermes_android/core/services/local_transcript_store.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, String> secure;
  Future<void> Function(MethodCall call)? storageHook;

  setUp(() {
    LocalConversationCleanupFence.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    secure = <String, String>{};
    storageHook = null;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map?) ?? const {};
            await storageHook?.call(call);
            switch (call.method) {
              case 'read':
                return secure[args['key']];
              case 'write':
                secure[args['key'] as String] = args['value'] as String;
              case 'delete':
                secure.remove(args['key']);
              case 'readAll':
                return Map<String, String>.of(secure);
            }
            return null;
          },
        );
  });

  TranscriptPrivacyCheckpoint checkpoint({int revision = 1}) =>
      TranscriptPrivacyCheckpoint(
        connectionId: 'conn',
        profile: 'default',
        storedSessionId: 'stored',
        revision: revision,
        coverage: TranscriptPrivacyCoverage.partial,
        suppressedWindow: true,
        facts: [TranscriptPrivacyObservation(rowId: 2, negative: true)],
      );

  test('evidence-only empty receipt survives encrypted reopen', () async {
    await LocalTranscriptStore.savePrivacyCheckpoint(
      'conn',
      'stored',
      checkpoint(),
    );
    final reopened = await LocalTranscriptStore.loadSnapshot('conn', 'stored');
    expect(reopened.messages, isEmpty);
    expect(reopened.privacyCheckpoint?.suppressedWindow, isTrue);
    expect(reopened.privacyCheckpoint?.facts.single.rowId, 2);
    expect(jsonEncode(secure), isNot(contains('PRIVATE_BODY')));
  });

  test('scope mismatch fails closed without writing', () async {
    await expectLater(
      LocalTranscriptStore.savePrivacyCheckpoint(
        'other',
        'stored',
        checkpoint(),
      ),
      throwsFormatException,
    );
    expect(secure, isEmpty);
  });

  test('older completion cannot replace a newer checkpoint', () async {
    await LocalTranscriptStore.savePrivacyCheckpoint(
      'conn',
      'stored',
      checkpoint(revision: 3),
    );
    await LocalTranscriptStore.savePrivacyCheckpoint(
      'conn',
      'stored',
      checkpoint(revision: 2),
    );
    final reopened = await LocalTranscriptStore.loadSnapshot('conn', 'stored');
    expect(reopened.privacyCheckpoint?.revision, 3);
  });

  test('checkpoint storage failure preserves the prior transcript', () async {
    await LocalTranscriptStore.saveFromNewestFirst('conn', 'stored', const [
      {'role': 'assistant', 'content': 'public history'},
    ], profile: 'default');
    storageHook = (call) async {
      if (call.method != 'write') return;
      final args = (call.arguments as Map?) ?? const {};
      if ((args['value'] as String).contains('privacy_checkpoint')) {
        throw StateError('checkpoint write failed');
      }
    };

    await expectLater(
      LocalTranscriptStore.savePrivacyCheckpoint(
        'conn',
        'stored',
        checkpoint(),
        profile: 'default',
      ),
      throwsA(isA<PlatformException>()),
    );

    final reopened = await LocalTranscriptStore.loadSnapshot('conn', 'stored');
    expect(reopened.messages.single['content'], 'public history');
    expect(reopened.privacyCheckpoint, isNull);
  });

  test(
    'checkpoint admission fails closed while profile cleanup is active',
    () async {
      final cleanupEntered = Completer<void>();
      final releaseCleanup = Completer<void>();
      final cleanup = LocalConversationCleanupFence.cleanupProfile<void>(
        connectionId: 'conn',
        profile: 'default',
        operation: () async {
          cleanupEntered.complete();
          await releaseCleanup.future;
        },
      );
      await cleanupEntered.future;

      await expectLater(
        LocalTranscriptStore.savePrivacyCheckpoint(
          'conn',
          'stored',
          checkpoint(),
          profile: 'default',
        ),
        throwsA(isA<LocalConversationWriteRejected>()),
      );

      releaseCleanup.complete();
      await cleanup;
      expect(secure, isEmpty);
    },
  );

  test(
    'ending a lifecycle does not erase an already delivered checkpoint',
    () async {
      final lifecycle = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'conn',
        profile: 'default',
        sessionId: 'stored',
      );
      await LocalTranscriptStore.saveFromNewestFirst(
        'conn',
        'stored',
        const [
          {'role': 'assistant', 'content': 'public history'},
        ],
        profile: 'default',
        lifecycle: lifecycle,
      );

      final checkpointWriteEntered = Completer<void>();
      final releaseCheckpointWrite = Completer<void>();
      storageHook = (call) async {
        if (call.method != 'write') return;
        final args = (call.arguments as Map?) ?? const {};
        if (!(args['value'] as String).contains('privacy_checkpoint')) return;
        checkpointWriteEntered.complete();
        await releaseCheckpointWrite.future;
      };

      final checkpointSave = LocalTranscriptStore.savePrivacyCheckpoint(
        'conn',
        'stored',
        checkpoint(),
        profile: 'default',
        lifecycle: lifecycle,
      );
      await checkpointWriteEntered.future;
      LocalConversationCleanupFence.endLifecycle(lifecycle);
      releaseCheckpointWrite.complete();
      await checkpointSave;

      final reopened = await LocalTranscriptStore.loadSnapshot(
        'conn',
        'stored',
      );
      expect(reopened.messages.single['content'], 'public history');
      expect(reopened.privacyCheckpoint?.revision, 1);
    },
  );

  test(
    'profile cleanup cannot be undone by an already delivered checkpoint write',
    () async {
      await LocalTranscriptStore.saveFromNewestFirst('conn', 'stored', const [
        {'role': 'assistant', 'content': 'public history'},
      ], profile: 'default');
      await LocalTranscriptStore.saveFromNewestFirst('conn', 'neighbor', const [
        {'role': 'assistant', 'content': 'neighbor history'},
      ], profile: 'other');

      final checkpointWriteEntered = Completer<void>();
      final releaseCheckpointWrite = Completer<void>();
      storageHook = (call) async {
        if (call.method != 'write') return;
        final args = (call.arguments as Map?) ?? const {};
        if (!(args['value'] as String).contains('privacy_checkpoint')) return;
        checkpointWriteEntered.complete();
        await releaseCheckpointWrite.future;
      };

      final checkpointSave = LocalTranscriptStore.savePrivacyCheckpoint(
        'conn',
        'stored',
        checkpoint(),
        profile: 'default',
      );
      await checkpointWriteEntered.future;

      expect(await LocalTranscriptStore.deleteForProfile('conn', 'default'), 1);
      expect(await LocalTranscriptStore.load('conn', 'stored'), isEmpty);

      releaseCheckpointWrite.complete();
      await checkpointSave;

      expect(await LocalTranscriptStore.load('conn', 'stored'), isEmpty);
      expect(
        await LocalTranscriptStore.load('conn', 'neighbor', profile: 'other'),
        [
          {'role': 'assistant', 'content': 'neighbor history'},
        ],
      );
    },
  );
}
