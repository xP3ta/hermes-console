import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/local_transcript_store.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

import 'support/in_memory_compression_restore_storage.dart';

const _maxLocalTranscriptMessages = 1000;
const _maxLocalTranscriptEncodedBytes = 2 * 1024 * 1024;

String _scope(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');

String _v2TranscriptKey(
  String connectionId,
  String sessionId, {
  String profile = 'default',
}) =>
    'local_transcript_v2.${_scope(connectionId)}.${_scope(profile)}.$sessionId';

String _hexTranscriptScope(String value) => value.codeUnits
    .map((unit) => unit.toRadixString(16).padLeft(4, '0'))
    .join();

String _transcriptKey(
  String connectionId,
  String sessionId, {
  String profile = 'default',
}) =>
    'hermes.transcript.v3.${_hexTranscriptScope(connectionId)}.${_hexTranscriptScope(profile.isEmpty ? 'default' : profile)}.${_hexTranscriptScope(sessionId)}';

const _legacyTranscriptSession =
    'mob-1000-00000000-0000-0000-0000-000000000001';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};

  setUp(() {
    LocalConversationCleanupFence.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    secureStore.clear();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                secureStore[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                return secureStore[args['key'] as String];
              case 'delete':
                secureStore.remove(args['key'] as String);
                return null;
              case 'readAll':
                return Map<String, String>.from(secureStore);
              case 'containsKey':
                return secureStore.containsKey(args['key'] as String);
            }
            return null;
          },
        );
  });

  test('load waits for a save admitted before its persistence dependency', () async {
    final store = ChatDraftStore(await SharedPreferences.getInstance());
    final gate = Completer<bool>();
    final saved = store.save('connection', 'session', 'Last keystroke', const [], afterSave: gate.future);
    var loaded = false;
    final read = store.load('connection', 'session').then((draft) { loaded = true; return draft; });
    await Future<void>.delayed(Duration.zero);
    expect(loaded, isFalse);
    gate.complete(true);
    expect(await saved, isTrue);
    expect((await read).text, 'Last keystroke');
  });

  test('room reply draft preserves its thread and remains out of recovery lists', () async {
    final store = ChatDraftStore(await SharedPreferences.getInstance());
    await store.save('connection', 'mob-room-fixture', 'Reply\ntext', const [], profile: 'builder', replyThreadId: 'thread-one');
    final draft = await store.load('connection', 'mob-room-fixture', profile: 'builder');
    expect(draft.text, 'Reply\ntext');
    expect(draft.replyThreadId, 'thread-one');
    expect(await store.listForConnection('connection'), isEmpty);
    expect((await store.load('connection', 'mob-room-fixture', profile: 'other')).text, isEmpty);
  });

  test(
    'canonical draft scope: promotion keeps connection and profile fences',
    () async {
      final store = ChatDraftStore(await SharedPreferences.getInstance());
      final owner = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'canonical-a',
        profile: 'work',
        sessionId: 'mob-origin',
      );
      LocalConversationCleanupFence.rehydrate(owner);
      LocalConversationCleanupFence.authorizeCreatedSession(owner, 'canonical');
      await store.save(
        'canonical-a',
        'canonical',
        'owned',
        const [],
        profile: 'work',
        lifecycle: owner,
      );
      await store.save(
        'canonical-a',
        'canonical',
        'other profile',
        const [],
        profile: 'personal',
      );
      await store.save(
        'canonical-b',
        'canonical',
        'other connection',
        const [],
        profile: 'work',
      );
      for (final scope in [
        ('canonical-b', 'work'),
        ('canonical-a', 'personal'),
      ]) {
        await expectLater(
          store.save(
            scope.$1,
            'canonical',
            'wrong',
            const [],
            profile: scope.$2,
            lifecycle: owner,
          ),
          throwsA(isA<LocalConversationWriteRejected>()),
        );
      }
      await store.save(
        'canonical-a',
        'canonical',
        '',
        const [],
        profile: 'work',
        lifecycle: owner,
      );
      final reopened = ChatDraftStore(await SharedPreferences.getInstance());
      expect(
        (await reopened.load('canonical-a', 'canonical', profile: 'work')).text,
        isEmpty,
      );
      expect(
        (await reopened.load(
          'canonical-a',
          'canonical',
          profile: 'personal',
        )).text,
        'other profile',
      );
      expect(
        (await reopened.load('canonical-b', 'canonical', profile: 'work')).text,
        'other connection',
      );
    },
  );

  test(
    'canonical draft scope: revoked producer cannot promote save or clear',
    () async {
      final store = ChatDraftStore(await SharedPreferences.getInstance());
      final owner = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'canonical-a',
        profile: 'work',
        sessionId: 'mob-origin',
      );
      LocalConversationCleanupFence.rehydrate(owner);
      LocalConversationCleanupFence.authorizeCreatedSession(owner, 'canonical');
      await store.save(
        'canonical-a',
        'canonical',
        'original',
        const [],
        profile: 'work',
        lifecycle: owner,
      );
      LocalConversationCleanupFence.endLifecycle(owner);
      expect(
        () => LocalConversationCleanupFence.authorizeCreatedSession(
          owner,
          'alien',
        ),
        throwsA(isA<LocalConversationWriteRejected>()),
      );
      for (final text in ['', 'stale']) {
        await expectLater(
          store.save(
            'canonical-a',
            'canonical',
            text,
            const [],
            profile: 'work',
            lifecycle: owner,
          ),
          throwsA(isA<LocalConversationWriteRejected>()),
        );
      }
      expect(
        (await store.load('canonical-a', 'canonical', profile: 'work')).text,
        'original',
      );
      final replacement = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'canonical-a',
        profile: 'work',
        sessionId: 'canonical',
      );
      LocalConversationCleanupFence.rehydrate(replacement);
      await store.save(
        'canonical-a',
        'canonical',
        'replacement',
        const [],
        profile: 'work',
        lifecycle: replacement,
      );
      expect(
        (await store.load('canonical-a', 'canonical', profile: 'work')).text,
        'replacement',
      );
    },
  );

  test('canonical draft scope: destination owner cannot be stolen', () async {
    final store = ChatDraftStore(await SharedPreferences.getInstance());
    final origin = LocalConversationCleanupFence.beginLifecycle(
      connectionId: 'canonical-a',
      profile: 'work',
      sessionId: 'mob-origin',
    );
    final neighbor = LocalConversationCleanupFence.beginLifecycle(
      connectionId: 'canonical-a',
      profile: 'work',
      sessionId: 'canonical',
    );
    LocalConversationCleanupFence.rehydrate(origin);
    LocalConversationCleanupFence.rehydrate(neighbor);
    await store.save(
      'canonical-a',
      'canonical',
      'neighbor',
      const [],
      profile: 'work',
      lifecycle: neighbor,
    );
    expect(
      () => LocalConversationCleanupFence.authorizeCreatedSession(
        origin,
        'canonical',
      ),
      throwsA(isA<LocalConversationWriteRejected>()),
    );
    await expectLater(
      store.save(
        'canonical-a',
        'canonical',
        'wrong',
        const [],
        profile: 'work',
        lifecycle: origin,
      ),
      throwsA(isA<LocalConversationWriteRejected>()),
    );
    expect(
      (await store.load('canonical-a', 'canonical', profile: 'work')).text,
      'neighbor',
    );
  });

  test('guarda, restaura y limpia el borrador por sesión', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = ChatDraftStore(prefs);
    final file = File(
      '${Directory.systemTemp.path}/hermes-draft-${DateTime.now().microsecondsSinceEpoch}.txt',
    );
    await file.writeAsString('fixture');
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });
    final attachment = AttachmentDraft(
      type: AttachmentType.document,
      name: 'fixture.txt',
      mimeType: 'text/plain',
      sizeBytes: 7,
      localPath: file.path,
    );

    await store.save('conn-a', 'session-a', 'mensaje a medias', [attachment]);
    final restored = await store.load('conn-a', 'session-a');

    expect(restored.text, 'mensaje a medias');
    expect(restored.attachments.single.name, 'fixture.txt');
    expect((await store.load('conn-a', 'session-b')).text, isEmpty);
    expect(
      prefs.getKeys().where((key) => key.startsWith('chat_draft_')),
      isEmpty,
    );
    expect(secureStore.keys.single, startsWith('chat_draft_v3.'));

    await store.clear('conn-a', 'session-a');
    expect((await store.load('conn-a', 'session-a')).text, isEmpty);
  });

  test(
    'cold restart restores text from secure storage with fresh prefs',
    () async {
      final firstPrefs = await SharedPreferences.getInstance();
      await ChatDraftStore(firstPrefs).save(
        'cold-connection',
        'cold-session',
        'Draft after process death',
        const [],
      );

      SharedPreferences.setMockInitialValues({});
      final reopened = ChatDraftStore(await SharedPreferences.getInstance());

      expect(
        (await reopened.load('cold-connection', 'cold-session')).text,
        'Draft after process death',
      );
    },
  );

  test('android-share provisional draft round-trips text and attachments and '
      'survives promotion to the canonical id', () async {
    final store = ChatDraftStore(await SharedPreferences.getInstance());
    final file = File(
      '${Directory.systemTemp.path}/hermes-share-draft-'
      '${DateTime.now().microsecondsSinceEpoch}.txt',
    );
    await file.writeAsString('shared');
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });
    final attachment = AttachmentDraft(
      type: AttachmentType.document,
      name: 'compartido.txt',
      mimeType: 'text/plain',
      sizeBytes: 6,
      localPath: file.path,
    );
    const provisional = 'mob-1000-share-provisional';
    const canonical = 'stored-share-canonical';

    await store.save('conn-share', provisional, 'texto compartido', [
      attachment,
    ]);
    final reopened = await store.load('conn-share', provisional);
    expect(reopened.text, 'texto compartido');
    expect(reopened.attachments.single.name, 'compartido.txt');

    // Promoción: el composer pasa a guardar bajo el id canónico y solo después
    // vacía el provisional (copy-before-cleanup).
    await store.save(
      'conn-share',
      canonical,
      reopened.text,
      reopened.attachments,
    );
    await store.save('conn-share', provisional, '', const []);

    final promoted = await store.load('conn-share', canonical);
    expect(promoted.text, 'texto compartido');
    expect(promoted.attachments.single.name, 'compartido.txt');
    expect((await store.load('conn-share', provisional)).text, isEmpty);
    final entries = await store.listForConnection('conn-share');
    expect(entries.map((entry) => entry.sessionId), [canonical]);
  });

  test('aísla drafts de profiles con el mismo session id', () async {
    final store = ChatDraftStore(await SharedPreferences.getInstance());
    await store.save(
      'conn-shared',
      'session-shared',
      'draft A',
      const [],
      profile: 'profile-a',
    );
    await store.save(
      'conn-shared',
      'session-shared',
      'draft B',
      const [],
      profile: 'profile-b',
    );

    expect(
      (await store.load(
        'conn-shared',
        'session-shared',
        profile: 'profile-a',
      )).text,
      'draft A',
    );
    expect(
      (await store.load(
        'conn-shared',
        'session-shared',
        profile: 'profile-b',
      )).text,
      'draft B',
    );
    await store.clear('conn-shared', 'session-shared', profile: 'profile-a');
    expect(
      (await store.load(
        'conn-shared',
        'session-shared',
        profile: 'profile-b',
      )).text,
      'draft B',
    );
  });

  test('cleanup de perfil borra sus drafts y conserva vecinos', () async {
    final store = ChatDraftStore(await SharedPreferences.getInstance());
    await store.save('conn-a', 'shared', 'A1', const [], profile: 'profile-a');
    await store.save('conn-a', 'other', 'A2', const [], profile: 'profile-a');
    await store.save('conn-a', 'shared', 'B', const [], profile: 'profile-b');
    await store.save(
      'conn-b',
      'shared',
      'A neighbor',
      const [],
      profile: 'profile-a',
    );

    expect(await store.deleteForProfile('conn-a', 'profile-a'), 2);

    expect(
      (await store.load('conn-a', 'shared', profile: 'profile-a')).text,
      isEmpty,
    );
    expect(
      (await store.load('conn-a', 'other', profile: 'profile-a')).text,
      isEmpty,
    );
    expect(
      (await store.load('conn-a', 'shared', profile: 'profile-b')).text,
      'B',
    );
    expect(
      (await store.load('conn-b', 'shared', profile: 'profile-a')).text,
      'A neighbor',
    );
  });

  test(
    'cleanup default borra solo v3 atribuible y conserva legacy sin owner',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final store = ChatDraftStore(prefs);
      final raw = jsonEncode({
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'text': 'legacy',
        'attachments': const <Object>[],
      });
      await store.save('conn-a', 'current', 'default', const []);
      await store.save(
        'conn-a',
        'current',
        'manager',
        const [],
        profile: 'manager',
      );
      secureStore['chat_draft_v2_conn-a_unscoped'] = raw;
      secureStore['chat_draft_v2_conn-a_mob-bot-canonical'] = raw;
      await prefs.setString('chat_draft_v1_conn-a_plaintext', raw);

      expect(await store.deleteForProfile('conn-a', ''), 1);

      expect(secureStore.containsKey('chat_draft_v2_conn-a_unscoped'), isTrue);
      expect(
        secureStore.containsKey('chat_draft_v2_conn-a_mob-bot-canonical'),
        isTrue,
      );
      expect(prefs.containsKey('chat_draft_v1_conn-a_plaintext'), isTrue);
      expect(
        (await store.load('conn-a', 'current', profile: 'manager')).text,
        'manager',
      );
    },
  );

  test('cleanup de perfil no borra legacy ambiguo de otra conexión', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = ChatDraftStore(prefs);
    final raw = jsonEncode({
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'text': 'foreign legacy',
      'attachments': const <Object>[],
    });
    await store.save('conn', 'owned', 'owned v3', const []);
    const v2Foreign = 'chat_draft_v2_conn_a_session';
    const v1Foreign = 'chat_draft_v1_conn_a_session';
    secureStore[v2Foreign] = raw;
    await prefs.setString(v1Foreign, raw);

    final removed = await store.deleteForProfile('conn', 'default');

    expect(removed, 1);
    expect(secureStore[v2Foreign], raw);
    expect(prefs.getString(v1Foreign), raw);
  });

  test(
    'clear posterior gana aunque un autosave anterior siga escribiendo',
    () async {
      final writeStarted = Completer<void>();
      final releaseWrite = Completer<void>();
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
              final args =
                  (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
              switch (call.method) {
                case 'write':
                  final value = args['value'] as String;
                  if (value.contains('autosave anterior')) {
                    if (!writeStarted.isCompleted) writeStarted.complete();
                    await releaseWrite.future;
                  }
                  secureStore[args['key'] as String] = value;
                  return null;
                case 'read':
                  return secureStore[args['key'] as String];
                case 'delete':
                  secureStore.remove(args['key'] as String);
                  return null;
                case 'readAll':
                  return Map<String, String>.from(secureStore);
                case 'containsKey':
                  return secureStore.containsKey(args['key'] as String);
              }
              return null;
            },
          );
      final store = ChatDraftStore(await SharedPreferences.getInstance());

      final staleSave = store.save(
        'conn-ordered',
        'session-ordered',
        'autosave anterior',
        const [],
      );
      await writeStarted.future;
      final acknowledgedClear = store.clear('conn-ordered', 'session-ordered');
      await Future<void>.delayed(Duration.zero);
      releaseWrite.complete();
      await staleSave;
      await acknowledgedClear;

      expect(
        (await store.load('conn-ordered', 'session-ordered')).text,
        isEmpty,
      );
      expect(
        secureStore.containsKey(
          ChatDraftStore.keyForTesting('conn-ordered', 'session-ordered'),
        ),
        isFalse,
      );
    },
  );

  test('clearForSession removes every owner but preserves neighbors', () async {
    final store = ChatDraftStore(await SharedPreferences.getInstance());
    await store.save(
      'conn-shared',
      'session-shared',
      'draft A',
      const [],
      profile: 'profile-a',
    );
    await store.save(
      'conn-shared',
      'session-shared',
      'draft B',
      const [],
      profile: 'profile-b',
    );
    await store.save(
      'conn-shared',
      'session-neighbor',
      'keep me',
      const [],
      profile: 'profile-a',
    );

    await store.clearForSession('conn-shared', 'session-shared');

    expect(
      (await store.load(
        'conn-shared',
        'session-shared',
        profile: 'profile-a',
      )).text,
      isEmpty,
    );
    expect(
      (await store.load(
        'conn-shared',
        'session-shared',
        profile: 'profile-b',
      )).text,
      isEmpty,
    );
    expect(
      (await store.load(
        'conn-shared',
        'session-neighbor',
        profile: 'profile-a',
      )).text,
      'keep me',
    );
  });

  test('roundtrip conserva identidad, FSM, error y owner remoto', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = ChatDraftStore(prefs);
    final file = File(
      '${Directory.systemTemp.path}/hermes-draft-fsm-${DateTime.now().microsecondsSinceEpoch}.pdf',
    );
    await file.writeAsBytes([1, 2, 3]);
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });
    final attachment = AttachmentDraft(
      localId: 'attachment-fsm',
      type: AttachmentType.document,
      name: 'fsm.pdf',
      mimeType: 'application/pdf',
      sizeBytes: 3,
      localPath: file.path,
      uploadState: AttachmentUploadState.error,
      attempt: 2,
      errorKind: AttachmentErrorKind.transport,
      remoteRef: '@file:.hermes/fsm.pdf',
      remoteSessionId: 'runtime-a',
      remoteTransport: AttachmentRemoteTransport.desktop,
    );

    await store.save('conn-a', 'session-fsm', 'texto', [attachment]);
    final restored = (await store.load(
      'conn-a',
      'session-fsm',
    )).attachments.single;

    expect(restored.localId, 'attachment-fsm');
    expect(restored.uploadState, AttachmentUploadState.error);
    expect(restored.attempt, 2);
    expect(restored.errorKind, AttachmentErrorKind.transport);
    expect(restored.remoteRef, '@file:.hermes/fsm.pdf');
    expect(restored.remoteSessionId, 'runtime-a');
    expect(restored.remoteTransport, AttachmentRemoteTransport.desktop);
  });

  test(
    'solo limpia la copia privada cuando desaparece el último owner',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final cleaned = <String>[];
      final store = ChatDraftStore(
        prefs,
        deletePrivateCopy: (attachment) async {
          cleaned.add(attachment.localId);
          return true;
        },
      );
      final file = File(
        '${Directory.systemTemp.path}/hermes-shared-${DateTime.now().microsecondsSinceEpoch}.pdf',
      );
      await file.writeAsBytes([1]);
      addTearDown(() async {
        if (await file.exists()) await file.delete();
      });
      final shared = AttachmentDraft(
        localId: 'shared-owner',
        type: AttachmentType.document,
        name: 'shared.pdf',
        mimeType: 'application/pdf',
        sizeBytes: 1,
        localPath: file.path,
      );
      await store.save('conn-a', 'session-a', 'a', [shared]);
      await store.save('conn-a', 'session-b', 'b', [shared]);

      await store.clear('conn-a', 'session-a');
      expect(cleaned, isEmpty);
      await store.clear('conn-a', 'session-b');
      expect(cleaned, ['shared-owner']);
    },
  );

  test('un tombstone de outbox no conserva la copia retirada', () async {
    final prefs = await SharedPreferences.getInstance();
    final cleaned = <String>[];
    final store = ChatDraftStore(
      prefs,
      deletePrivateCopy: (attachment) async {
        cleaned.add(attachment.localId);
        return true;
      },
    );
    const attachment = AttachmentDraft(
      localId: 'removed-cross-store',
      type: AttachmentType.document,
      name: 'removed.pdf',
      mimeType: 'application/pdf',
      sizeBytes: 1,
      localPath: '/private/removed-cross-store.pdf',
    );
    await store.save('conn-a', 'session-a', '', const [attachment]);
    secureStore['chat_turn_outbox_v1'] = jsonEncode({
      'turn': {
        'attachments': [
          attachment
              .copyWith(uploadState: AttachmentUploadState.removed)
              .toJson(),
        ],
      },
    });

    await store.clear('conn-a', 'session-a');

    expect(cleaned, ['removed-cross-store']);
  });

  test(
    'REGRESSION_LIVE_OUTBOX_RACE: un save ya invocado conserva la copia cuando '
    'clear se intercala antes de que persista',
    () async {
      TurnOutboxStore.resetSerializationForTesting();
      final outboxWriteStarted = Completer<void>();
      final releaseOutboxWrite = Completer<void>();
      final draftKeyDeleted = Completer<void>();
      final draftCopyDeleted = Completer<void>();
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
              final args =
                  (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
              switch (call.method) {
                case 'write':
                  final value = args['value'] as String;
                  if (!outboxWriteStarted.isCompleted &&
                      args['key'] == 'chat_turn_outbox_v1' &&
                      value.contains('turn-adversarial-live-race')) {
                    outboxWriteStarted.complete();
                    await releaseOutboxWrite.future;
                  }
                  secureStore[args['key'] as String] = value;
                  return null;
                case 'read':
                  return secureStore[args['key'] as String];
                case 'delete':
                  final key = args['key'] as String;
                  secureStore.remove(key);
                  if (key.startsWith('chat_draft_v3.')) {
                    draftKeyDeleted.complete();
                  }
                  return null;
                case 'readAll':
                  return Map<String, String>.from(secureStore);
              }
              return null;
            },
          );
      final prefs = await SharedPreferences.getInstance();
      final drafts = ChatDraftStore(
        prefs,
        deletePrivateCopy: (item) async {
          final managed = File(item.localPath);
          if (await managed.exists()) await managed.delete();
          draftCopyDeleted.complete();
          return true;
        },
      );
      final outbox = TurnOutboxStore();
      final file = File(
        '${Directory.systemTemp.path}/adversarial-live-race-${DateTime.now().microsecondsSinceEpoch}.txt',
      );
      await file.writeAsString('privado');
      addTearDown(() async {
        if (await file.exists()) await file.delete();
      });
      final attachment = AttachmentDraft(
        localId: 'adversarial-live-race',
        type: AttachmentType.document,
        name: 'adversarial-live-race.txt',
        mimeType: 'text/plain',
        sizeBytes: 7,
        localPath: file.path,
      );
      await drafts.save('conn-a', 'session-a', 'borrador', [attachment]);
      final now = DateTime.now().millisecondsSinceEpoch;
      final saving = outbox.save(
        PreparedTurn(
          connectionId: 'conn-a',
          sessionId: 'session-a',
          clientTurnId: 'turn-adversarial-live-race',
          createdAtMs: now,
          updatedAtMs: now,
          text: 'mensaje queued',
          attachments: [attachment],
          model: 'modelo',
          profile: 'default',
          queued: true,
        ),
      );
      await outboxWriteStarted.future;

      final clearing = drafts.clear('conn-a', 'session-a');
      await draftKeyDeleted.future;
      // Drenaje determinista y acotado del event loop, con el write de la
      // outbox todavía bloqueado. Si no existiera el coordinador de ownership,
      // el clear tendría vía libre para que su readAll de inventario alcanzara
      // el borrado de la copia privada antes de liberar el write.
      for (
        var round = 0;
        round < 64 && !draftCopyDeleted.isCompleted;
        round++
      ) {
        await pumpEventQueue(times: 1);
      }
      expect(draftCopyDeleted.isCompleted, isFalse);

      releaseOutboxWrite.complete();
      await saving;
      await clearing;
      final restored = await outbox.loadForChat(
        'conn-a',
        'session-a',
        profile: 'default',
      );
      expect(restored, isNotNull);
      expect(restored!.attachments.single.localPath, file.path);
      expect(await file.exists(), isTrue);
    },
  );

  test('save de draft admitido antes de clear no puede resucitarlo', () async {
    final drafts = ChatDraftStore(await SharedPreferences.getInstance());
    final release = Completer<void>();
    final blocker = LocalConversationCleanupFence.write(
      connectionId: 'other',
      operation: () => release.future,
    );
    final saving = drafts.save(
      'ordered',
      'session',
      'contenido borrado',
      const [],
      profile: 'profile',
    );
    await drafts.clear('ordered', 'session', profile: 'profile');
    release.complete();
    await blocker;
    await saving;
    expect(
      (await drafts.load('ordered', 'session', profile: 'profile')).text,
      isEmpty,
    );
  });

  test('diferencial draft conserva orden con IO transcript ajeno', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            if (call.method == 'read' &&
                (args['key'] as String).startsWith('hermes.transcript.v3.')) {
              if (!entered.isCompleted) entered.complete();
              await release.future;
            }
            switch (call.method) {
              case 'write':
                secureStore[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                return secureStore[args['key'] as String];
              case 'delete':
                secureStore.remove(args['key'] as String);
                return null;
              case 'readAll':
                return Map<String, String>.from(secureStore);
            }
            return null;
          },
        );
    final drafts = ChatDraftStore(await SharedPreferences.getInstance());
    final transcript = LocalTranscriptStore.saveFromNewestFirst(
      'unrelated',
      'session',
      const [
        {'role': 'assistant', 'content': 'unrelated'},
      ],
    );
    await entered.future;
    final saving = drafts.save(
      'ordered',
      'session',
      'contenido borrado',
      const [],
      profile: 'profile',
    );
    await drafts.clear('ordered', 'session', profile: 'profile');
    release.complete();
    await transcript;
    await saving;
    expect(
      (await drafts.load('ordered', 'session', profile: 'profile')).text,
      isEmpty,
    );
  });

  test('owner pendiente ya admitido conserva el adjunto compartido', () async {
    TurnOutboxStore.resetSerializationForTesting();
    final prefs = await SharedPreferences.getInstance();
    final deletedCopies = <String>[];
    final drafts = ChatDraftStore(
      prefs,
      deletePrivateCopy: (item) async {
        deletedCopies.add(item.localId);
        return true;
      },
    );
    final outbox = TurnOutboxStore();
    final file = File(
      '${Directory.systemTemp.path}/pending-shared-owner-${DateTime.now().microsecondsSinceEpoch}.txt',
    );
    await file.writeAsString('private');
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });
    final attachment = AttachmentDraft(
      localId: 'pending-shared-owner',
      type: AttachmentType.document,
      name: 'pending.txt',
      mimeType: 'text/plain',
      sizeBytes: 7,
      localPath: file.path,
    );
    await drafts.save('conn-a', 'session-a', 'borrador', [attachment]);
    final release = Completer<void>();
    final blocker = LocalConversationCleanupFence.write(
      connectionId: 'other',
      operation: () => release.future,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    final saving = outbox.save(
      PreparedTurn(
        connectionId: 'conn-a',
        sessionId: 'session-a',
        clientTurnId: 'turn-pending-shared-owner',
        createdAtMs: now,
        updatedAtMs: now,
        text: 'mensaje queued',
        attachments: [attachment],
        model: 'modelo',
        profile: 'default',
        queued: true,
      ),
    );
    final clearing = drafts.clear('conn-a', 'session-a');
    await pumpEventQueue(times: 8);

    expect(deletedCopies, isEmpty);
    release.complete();
    await blocker;
    await saving;
    await clearing;
    expect(deletedCopies, isEmpty);
    expect(
      (await outbox.loadForChat(
        'conn-a',
        'session-a',
        profile: 'default',
      ))?.attachments.single.localId,
      'pending-shared-owner',
    );
  });

  test(
    'REGRESSION_LIVE_OUTBOX_ATTACHMENT: limpiar el draft no borra la copia viva '
    'de un turno queued de la outbox',
    () async {
      TurnOutboxStore.resetSerializationForTesting();
      final prefs = await SharedPreferences.getInstance();
      final store = ChatDraftStore(
        prefs,
        deletePrivateCopy: (item) async {
          final managed = File(item.localPath);
          if (await managed.exists()) await managed.delete();
          return true;
        },
      );
      final outbox = TurnOutboxStore();
      final file = File(
        '${Directory.systemTemp.path}/adversarial-live-outbox-${DateTime.now().microsecondsSinceEpoch}.txt',
      );
      await file.writeAsString('privado');
      addTearDown(() async {
        if (await file.exists()) await file.delete();
      });
      final attachment = AttachmentDraft(
        localId: 'adversarial-live-shared',
        type: AttachmentType.document,
        name: 'adversarial-live.txt',
        mimeType: 'text/plain',
        sizeBytes: 7,
        localPath: file.path,
      );
      await store.save('conn-a', 'session-a', 'borrador a medias', [
        attachment,
      ]);
      final now = DateTime.now().millisecondsSinceEpoch;
      await outbox.save(
        PreparedTurn(
          connectionId: 'conn-a',
          sessionId: 'session-a',
          clientTurnId: 'turn-adversarial-live',
          createdAtMs: now,
          updatedAtMs: now,
          text: 'mensaje queued',
          attachments: [attachment],
          model: 'modelo',
          profile: 'default',
          queued: true,
        ),
      );

      await store.clear('conn-a', 'session-a');

      expect(await file.exists(), isTrue);
      final restored = await outbox.loadForChat(
        'conn-a',
        'session-a',
        profile: 'default',
      );
      expect(restored, isNotNull);
      expect(restored!.attachments.single.localId, 'adversarial-live-shared');
      expect(restored.attachments.single.localPath, file.path);
    },
  );

  test('REGRESSION_LIVE_OUTBOX_ATTACHMENT: un tombstone removed de la outbox no '
      'retiene la copia privada', () async {
    TurnOutboxStore.resetSerializationForTesting();
    final prefs = await SharedPreferences.getInstance();
    final cleaned = <String>[];
    final store = ChatDraftStore(
      prefs,
      deletePrivateCopy: (item) async {
        cleaned.add(item.localId);
        final managed = File(item.localPath);
        if (await managed.exists()) await managed.delete();
        return true;
      },
    );
    final outbox = TurnOutboxStore();
    final file = File(
      '${Directory.systemTemp.path}/adversarial-tombstone-${DateTime.now().microsecondsSinceEpoch}.txt',
    );
    await file.writeAsString('privado');
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });
    final live = AttachmentDraft(
      localId: 'adversarial-tombstone-draft',
      type: AttachmentType.document,
      name: 'adversarial-tombstone.txt',
      mimeType: 'text/plain',
      sizeBytes: 7,
      localPath: file.path,
    );
    await store.save('conn-a', 'session-a', '', [live]);
    final now = DateTime.now().millisecondsSinceEpoch;
    await outbox.save(
      PreparedTurn(
        connectionId: 'conn-a',
        sessionId: 'session-a',
        clientTurnId: 'turn-adversarial-tombstone',
        createdAtMs: now,
        updatedAtMs: now,
        text: 'mensaje queued',
        attachments: [
          live.copyWith(uploadState: AttachmentUploadState.removed),
        ],
        model: 'modelo',
        profile: 'default',
        queued: true,
      ),
    );

    await store.clear('conn-a', 'session-a');

    expect(cleaned, ['adversarial-tombstone-draft']);
    expect(await file.exists(), isFalse);
  });

  test('REGRESSION_LIVE_OUTBOX_ATTACHMENT: readAll ilegible cierra en falso y no '
      'borra la copia privada', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = ChatDraftStore(
      prefs,
      deletePrivateCopy: (item) async {
        final managed = File(item.localPath);
        if (await managed.exists()) await managed.delete();
        return true;
      },
    );
    final file = File(
      '${Directory.systemTemp.path}/adversarial-failclosed-${DateTime.now().microsecondsSinceEpoch}.txt',
    );
    await file.writeAsString('privado');
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });
    final attachment = AttachmentDraft(
      localId: 'adversarial-failclosed',
      type: AttachmentType.document,
      name: 'adversarial-failclosed.txt',
      mimeType: 'text/plain',
      sizeBytes: 7,
      localPath: file.path,
    );
    await store.save('conn-a', 'session-a', 'borrador', [attachment]);
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                secureStore[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                return secureStore[args['key'] as String];
              case 'delete':
                secureStore.remove(args['key'] as String);
                return null;
              case 'readAll':
                throw PlatformException(code: 'read_all_unavailable');
            }
            return null;
          },
        );

    await store.clear('conn-a', 'session-a');

    expect(await file.exists(), isTrue);
  });

  test('indexa un chat nuevo para poder reabrirlo desde las listas', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = ChatDraftStore(prefs);
    await store.save(
      'conn-new',
      'mobile-new-session',
      'Texto todavía sin enviar',
      const [],
    );

    final entries = await store.listForConnection('conn-new');

    expect(entries, hasLength(1));
    expect(entries.single.sessionId, 'mobile-new-session');
    expect(entries.single.draft.text, 'Texto todavía sin enviar');
    final session = entries.single.toSession(fallbackTitle: 'Nuevo chat');
    expect(session.source, 'mobile-draft');
    expect(session.isDraftOnly, isTrue);
    expect(session.hasLocalDraft, isTrue);
    expect(session.title, 'Texto todavía sin enviar');
    expect(session.preview, 'Texto todavía sin enviar');
  });

  test(
    'el índice genérico omite drafts V3 de Bot y Room sin borrarlos',
    () async {
      final store = ChatDraftStore(await SharedPreferences.getInstance());
      await store.save(
        'conn-owned',
        'mobile-normal',
        'borrador de conversación',
        const [],
        profile: 'default',
      );
      await store.save(
        'conn-owned',
        'mob-room-room-7',
        '@builder revisa el estado',
        const [],
        profile: 'manager',
      );
      await store.save(
        'conn-owned',
        'mob-bot-research',
        'continúa el análisis',
        const [],
        profile: 'research',
      );
      await store.save(
        'conn-owned',
        'session-owned-by-room',
        'owner de sala',
        const [],
        profile: 'mob-room-room-7',
      );
      await store.save(
        'conn-owned',
        'session-owned-by-bot',
        'owner de bot',
        const [],
        profile: 'mob-bot-research',
      );

      final entries = await store.listForConnection('conn-owned');

      expect(entries.map((entry) => entry.sessionId), ['mobile-normal']);
      final dedicatedDrafts = <(String, String, String)>[
        ('mob-room-room-7', 'manager', '@builder revisa el estado'),
        ('mob-bot-research', 'research', 'continúa el análisis'),
        ('session-owned-by-room', 'mob-room-room-7', 'owner de sala'),
        ('session-owned-by-bot', 'mob-bot-research', 'owner de bot'),
      ];
      for (final (sessionId, owner, text) in dedicatedDrafts) {
        final key = ChatDraftStore.keyForTesting(
          'conn-owned',
          sessionId,
          profile: owner,
        );
        expect(secureStore.containsKey(key), isTrue);
        expect(
          (await store.load('conn-owned', sessionId, profile: owner)).text,
          text,
        );
      }
    },
  );

  test('list y load omiten v2 ambiguo sin migrarlo al owner default', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    const legacyKey = 'chat_draft_v2_conn-legacy_mobile-legacy';
    secureStore[legacyKey] = jsonEncode({
      'savedAt': now,
      'text': 'Borrador anterior a perfiles',
      'attachments': const <Object>[],
    });
    final store = ChatDraftStore(await SharedPreferences.getInstance());

    expect(await store.listForConnection('conn-legacy'), isEmpty);
    expect(secureStore.containsKey(legacyKey), isTrue);

    final restored = await store.load('conn-legacy', 'mobile-legacy');

    expect(restored.text, isEmpty);
    expect(
      secureStore[ChatDraftStore.keyForTesting('conn-legacy', 'mobile-legacy')],
      isNull,
    );
    expect(secureStore.containsKey(legacyKey), isTrue);
  });

  test('el listado no atribuye claves v2 ambiguas a otra conexión', () async {
    final raw = jsonEncode({
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'text': 'draft de conn_a',
      'attachments': const <Object>[],
    });
    const ambiguousKey = 'chat_draft_v2_conn_a_session';
    secureStore[ambiguousKey] = raw;
    final store = ChatDraftStore(await SharedPreferences.getInstance());

    final entries = await store.listForConnection('conn');

    expect(entries, isEmpty);
    expect(secureStore[ambiguousKey], raw);
    expect(
      secureStore[ChatDraftStore.keyForTesting('conn', 'a_session')],
      isNull,
    );
  });

  test(
    'el listado elimina claves v3 malformadas sin exponer su draft',
    () async {
      final malformedKey =
          '${ChatDraftStore.keyForTesting('conn-legacy', 'session-a')}.extra';
      secureStore[malformedKey] = jsonEncode({
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'text': 'no debe reaparecer',
        'attachments': const <Object>[],
      });
      final store = ChatDraftStore(await SharedPreferences.getInstance());

      expect(await store.listForConnection('conn-legacy'), isEmpty);
      expect(secureStore.containsKey(malformedKey), isFalse);
    },
  );

  test('Rooms y Bots no reclaman v2 ambiguo por prefijo de sesión', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    secureStore['chat_draft_v2_conn-legacy_mob-room-room-1'] = jsonEncode({
      'savedAt': now,
      'text': '@infra revisa backups',
      'attachments': const <Object>[],
    });
    secureStore['chat_draft_v2_conn-legacy_mob-bot-research'] = jsonEncode({
      'savedAt': now,
      'text': 'continúa la investigación',
      'attachments': const <Object>[],
    });
    final store = ChatDraftStore(await SharedPreferences.getInstance());

    expect(await store.listForConnection('conn-legacy'), isEmpty);
    expect(
      secureStore.containsKey('chat_draft_v2_conn-legacy_mob-room-room-1'),
      isTrue,
    );
    expect(
      secureStore.containsKey('chat_draft_v2_conn-legacy_mob-bot-research'),
      isTrue,
    );

    final room = await store.load(
      'conn-legacy',
      'mob-room-room-1',
      profile: 'manager',
      claimUnscopedLegacy: true,
    );
    final bot = await store.load(
      'conn-legacy',
      'mob-bot-research',
      profile: 'research',
      claimUnscopedLegacy: true,
    );

    expect(room.text, isEmpty);
    expect(bot.text, isEmpty);
    expect(
      secureStore[ChatDraftStore.keyForTesting(
        'conn-legacy',
        'mob-room-room-1',
        profile: 'manager',
      )],
      isNull,
    );
    expect(
      secureStore[ChatDraftStore.keyForTesting(
        'conn-legacy',
        'mob-bot-research',
        profile: 'research',
      )],
      isNull,
    );
  });

  test('load no migra ni elimina un borrador legacy ambiguo', () async {
    SharedPreferences.setMockInitialValues({
      'chat_draft_v1_conn-a_session-a': jsonEncode({
        'text': 'legacy sensible',
        'attachments': const [],
      }),
    });
    final prefs = await SharedPreferences.getInstance();
    final store = ChatDraftStore(prefs);

    final restored = await store.load('conn-a', 'session-a');

    expect(restored.text, isEmpty);
    expect(prefs.getString('chat_draft_v1_conn-a_session-a'), isNotNull);
    expect(
      secureStore[ChatDraftStore.keyForTesting('conn-a', 'session-a')],
      isNull,
    );
  });

  test(
    'perfil no propietario no reclama plaintext legacy sin autorización',
    () async {
      final raw = jsonEncode({
        'text': 'legacy sensible',
        'attachments': const [],
      });
      SharedPreferences.setMockInitialValues({
        'chat_draft_v1_conn-a_session-a': raw,
      });
      final prefs = await SharedPreferences.getInstance();
      final store = ChatDraftStore(prefs);

      final restored = await store.load(
        'conn-a',
        'session-a',
        profile: 'manager',
        claimUnscopedLegacy: false,
      );

      expect(restored.text, isEmpty);
      expect(prefs.getString('chat_draft_v1_conn-a_session-a'), raw);
      expect(
        secureStore[ChatDraftStore.keyForTesting(
          'conn-a',
          'session-a',
          profile: 'manager',
        )],
        isNull,
      );
    },
  );

  test(
    'save de perfil no propietario conserva plaintext legacy sin autorización',
    () async {
      final raw = jsonEncode({
        'text': 'legacy sensible',
        'attachments': const [],
      });
      SharedPreferences.setMockInitialValues({
        'chat_draft_v1_conn-a_session-a': raw,
      });
      final prefs = await SharedPreferences.getInstance();
      final store = ChatDraftStore(prefs);

      await store.save(
        'conn-a',
        'session-a',
        'draft manager',
        const [],
        profile: 'manager',
      );

      expect(prefs.getString('chat_draft_v1_conn-a_session-a'), raw);
      expect(
        (await store.load('conn-a', 'session-a', profile: 'manager')).text,
        'draft manager',
      );
    },
  );

  test(
    'clear de perfil no propietario conserva plaintext legacy sin autorización',
    () async {
      final raw = jsonEncode({
        'text': 'legacy sensible',
        'attachments': const [],
      });
      SharedPreferences.setMockInitialValues({
        'chat_draft_v1_conn-a_session-a': raw,
      });
      final prefs = await SharedPreferences.getInstance();
      final store = ChatDraftStore(prefs);

      await store.clear(
        'conn-a',
        'session-a',
        profile: 'manager',
        includeUnscoped: false,
      );

      expect(prefs.getString('chat_draft_v1_conn-a_session-a'), raw);
    },
  );

  test(
    'load no reclama v1 ambiguo aunque el perfil default lo solicite',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode({
        'text': 'draft de otra conexión',
        'attachments': const [],
      });
      await prefs.setString('chat_draft_v1_conn_a_session', raw);

      final draft = await ChatDraftStore(prefs).load(
        'conn',
        'a_session',
        profile: 'default',
        claimUnscopedLegacy: true,
      );

      expect(draft.text, isEmpty);
      expect(draft.attachments, isEmpty);
      expect(prefs.getString('chat_draft_v1_conn_a_session'), raw);
    },
  );

  test(
    'load no reclama v2 ambiguo aunque el perfil default lo solicite',
    () async {
      final raw = jsonEncode({
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'text': 'draft cifrado de otra conexión',
        'attachments': const [],
      });
      secureStore['chat_draft_v2_conn_a_session'] = raw;

      final draft = await ChatDraftStore(await SharedPreferences.getInstance())
          .load(
            'conn',
            'a_session',
            profile: 'default',
            claimUnscopedLegacy: true,
          );

      expect(draft.text, isEmpty);
      expect(draft.attachments, isEmpty);
      expect(secureStore['chat_draft_v2_conn_a_session'], raw);
    },
  );

  test('save v3 conserva v1 y v2 ambiguos de otra conexión', () async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode({
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'text': 'foreign',
      'attachments': const [],
    });
    const legacyKey = 'chat_draft_v1_conn_a_session';
    const unscopedKey = 'chat_draft_v2_conn_a_session';
    await prefs.setString(legacyKey, raw);
    secureStore[unscopedKey] = raw;

    await ChatDraftStore(prefs).save('conn', 'a_session', 'nuevo v3', const []);

    expect(prefs.getString(legacyKey), raw);
    expect(secureStore[unscopedKey], raw);
  });

  test('clear v3 conserva v1 y v2 ambiguos de otra conexión', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = ChatDraftStore(prefs);
    final raw = jsonEncode({
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'text': 'foreign',
      'attachments': const [],
    });
    const legacyKey = 'chat_draft_v1_conn_a_session';
    const unscopedKey = 'chat_draft_v2_conn_a_session';
    await prefs.setString(legacyKey, raw);
    secureStore[unscopedKey] = raw;
    await store.save('conn', 'a_session', 'propio v3', const []);

    await store.clear(
      'conn',
      'a_session',
      profile: 'default',
      includeUnscoped: true,
    );

    expect((await store.load('conn', 'a_session')).text, isEmpty);
    expect(prefs.getString(legacyKey), raw);
    expect(secureStore[unscopedKey], raw);
  });

  test('clearForSession conserva v1 y v2 ambiguos de otra conexión', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = ChatDraftStore(prefs);
    final raw = jsonEncode({
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'text': 'foreign',
      'attachments': const [],
    });
    const legacyKey = 'chat_draft_v1_conn_a_session';
    const unscopedKey = 'chat_draft_v2_conn_a_session';
    await prefs.setString(legacyKey, raw);
    secureStore[unscopedKey] = raw;
    await store.save(
      'conn',
      'a_session',
      'propio v3 manager',
      const [],
      profile: 'manager',
    );

    await store.clearForSession('conn', 'a_session');

    expect(
      (await store.load('conn', 'a_session', profile: 'manager')).text,
      isEmpty,
    );
    expect(prefs.getString(legacyKey), raw);
    expect(secureStore[unscopedKey], raw);
  });

  test('cleanup manager conserva drafts dedicados de Room y Bot', () async {
    final store = ChatDraftStore(await SharedPreferences.getInstance());
    await store.save(
      'conn-dedicated',
      'normal-session',
      'normal',
      const [],
      profile: 'manager',
    );
    await store.save(
      'conn-dedicated',
      'mob-room-room-1',
      'room',
      const [],
      profile: 'manager',
    );
    await store.save(
      'conn-dedicated',
      'mob-bot-bot-1',
      'bot',
      const [],
      profile: 'manager',
    );

    final removed = await store.deleteForProfile('conn-dedicated', 'manager');

    expect(removed, 1);
    expect(
      (await store.load(
        'conn-dedicated',
        'normal-session',
        profile: 'manager',
      )).text,
      isEmpty,
    );
    expect(
      (await store.load(
        'conn-dedicated',
        'mob-room-room-1',
        profile: 'manager',
      )).text,
      'room',
    );
    expect(
      (await store.load(
        'conn-dedicated',
        'mob-bot-bot-1',
        profile: 'manager',
      )).text,
      'bot',
    );
  });

  test('cleanup v3 conserva adjunto referenciado por v1 retenido', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = ChatDraftStore(
      prefs,
      deletePrivateCopy: (item) async {
        final managed = File(item.localPath);
        if (await managed.exists()) await managed.delete();
        return true;
      },
    );
    final file = File(
      '${Directory.systemTemp.path}/hermes-draft-shared-${DateTime.now().microsecondsSinceEpoch}.txt',
    );
    await file.writeAsString('private');
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });
    final attachment = AttachmentDraft(
      type: AttachmentType.document,
      name: 'shared.txt',
      mimeType: 'text/plain',
      sizeBytes: 7,
      localPath: file.path,
    );
    await prefs.setString(
      'chat_draft_v1_foreign_conn_session',
      jsonEncode({
        'text': 'foreign',
        'attachments': [attachment.toJson()],
      }),
    );
    await store.save('owned-conn', 'owned-session', 'owned', [
      attachment,
    ], profile: 'manager');

    await store.deleteForProfile('owned-conn', 'manager');

    expect(await file.exists(), isTrue);
  });

  test('descarta rutas de adjunto que Android ya eliminó', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = ChatDraftStore(prefs);
    await store.save('conn-a', 'session-a', 'texto', const [
      AttachmentDraft(
        type: AttachmentType.image,
        name: 'ausente.png',
        mimeType: 'image/png',
        sizeBytes: 12,
        localPath: '/ruta/que/no/existe.png',
      ),
    ]);

    final restored = await store.load('conn-a', 'session-a');
    expect(restored.text, 'texto');
    expect(restored.attachments, isEmpty);
  });

  test(
    'borra solo drafts v3 atribuibles a la conexión y conserva legacy ambiguo',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final store = ChatDraftStore(prefs);
      await store.save('conn-a', 'session-a', 'a1', const []);
      await store.save('conn-a', 'session-b', 'a2', const []);
      await store.save('conn-b', 'session-a', 'b1', const []);
      await prefs.setString('chat_draft_v1_conn-a_legacy', 'legacy');

      final removed = await store.deleteForConnection('conn-a');

      expect(removed, 2);
      expect(
        secureStore.keys.where(
          (key) =>
              key.startsWith('chat_draft_v3.') &&
              key != ChatDraftStore.keyForTesting('conn-b', 'session-a'),
        ),
        isEmpty,
      );
      expect(
        secureStore[ChatDraftStore.keyForTesting('conn-b', 'session-a')],
        isNotNull,
      );
      expect(prefs.getString('chat_draft_v1_conn-a_legacy'), 'legacy');
    },
  );

  test(
    'bulk delete no borra claves legacy ambiguas de otra conexión',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final store = ChatDraftStore(prefs);
      final raw = jsonEncode({
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'text': 'draft de conn_a',
        'attachments': const <Object>[],
      });
      await store.save('conn', 'owned', 'owned v3', const []);
      const v2Foreign = 'chat_draft_v2_conn_a_session';
      const v1Foreign = 'chat_draft_v1_conn_a_session';
      secureStore[v2Foreign] = raw;
      await prefs.setString(v1Foreign, raw);

      final removed = await store.deleteForConnection('conn');

      expect(removed, 1);
      expect(
        secureStore[ChatDraftStore.keyForTesting('conn', 'owned')],
        isNull,
      );
      expect(secureStore[v2Foreign], raw);
      expect(prefs.getString(v1Foreign), raw);
    },
  );

  test('transcript corrupto no filtra contenido privado en logs', () async {
    final key = _transcriptKey('conn-log', 'session-private');
    const sentinel = 'PRIVATE_TRANSCRIPT_SENTINEL';
    secureStore[key] = sentinel;
    final logs = <String>[];
    final previousDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) logs.add(message);
    };
    addTearDown(() => debugPrint = previousDebugPrint);

    final sessions = await LocalTranscriptStore.listForConnection('conn-log');

    expect(sessions, isEmpty);
    expect(secureStore[key], sentinel);
    expect(logs.join('\n'), isNot(contains(sentinel)));
  });

  test('listado de transcripts aplica los mismos límites seguros', () async {
    secureStore[_transcriptKey(
      'conn-list',
      _legacyTranscriptSession,
    )] = jsonEncode([
      for (var index = 1; index <= 1050; index++)
        {
          'role': index.isOdd ? 'user' : 'assistant',
          'content': 'mensaje listado $index',
          'trace': 'PRIVATE_TRACE',
        },
    ]);

    final sessions = await LocalTranscriptStore.listForConnection('conn-list');

    expect(sessions, hasLength(1));
    expect(sessions.single.messageCount, _maxLocalTranscriptMessages);
    expect(sessions.single.preview, contains('mensaje listado 1050'));
    expect(sessions.single.preview, isNot(contains('PRIVATE_TRACE')));
  });

  test(
    'transcript local limita tamaño conservando los mensajes recientes',
    () async {
      final newestFirst = <Map<String, dynamic>>[
        for (var index = 1050; index >= 1; index--)
          {
            'role': index.isOdd ? 'user' : 'assistant',
            'content': 'mensaje $index',
          },
      ];

      await LocalTranscriptStore.saveFromNewestFirst(
        'conn-a',
        'session-bounded',
        newestFirst,
      );
      final restored = await LocalTranscriptStore.load(
        'conn-a',
        'session-bounded',
      );

      expect(restored, hasLength(_maxLocalTranscriptMessages));
      expect(restored.first['content'], 'mensaje 51');
      expect(restored.last['content'], 'mensaje 1050');
      expect(
        utf8
            .encode(secureStore[_transcriptKey('conn-a', 'session-bounded')]!)
            .length,
        lessThanOrEqualTo(_maxLocalTranscriptEncodedBytes),
      );
    },
  );

  test('transcript local conserva más de 500 mensajes al reabrir', () async {
    final newestFirst = <Map<String, dynamic>>[
      for (var index = 501; index >= 1; index--)
        {
          'role': index.isOdd ? 'user' : 'assistant',
          'content': 'mensaje $index',
        },
    ];

    await LocalTranscriptStore.saveFromNewestFirst(
      'conn-count',
      'session-count',
      newestFirst,
    );
    final firstOpen = await LocalTranscriptStore.loadSnapshot(
      'conn-count',
      'session-count',
    );
    await LocalTranscriptStore.saveFromNewestFirst(
      'conn-count',
      'session-count',
      firstOpen.messages.reversed.toList(growable: false),
    );
    final reopened = await LocalTranscriptStore.loadSnapshot(
      'conn-count',
      'session-count',
    );

    expect(firstOpen.olderHistoryTruncated, isFalse);
    expect(reopened.olderHistoryTruncated, isFalse);
    expect(reopened.messages, hasLength(501));
    expect(reopened.messages.first['content'], 'mensaje 1');
    expect(reopened.messages.last['content'], 'mensaje 501');

    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'conn-count',
        label: 'Local',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'test-key',
        kind: InstanceKind.localhost,
        onDeviceLoopback: true,
      ),
      sessionId: 'session-count',
      sessionTitle: 'Historial local largo',
      notifications: null,
      onTerminal: () {},
    );
    addTearDown(chat.dispose);
    await chat.loadMessages();

    expect(chat.messages, hasLength(501));
    expect(chat.messages.first['content'], 'mensaje 501');
    expect(chat.messages.last['content'], 'mensaje 1');
    expect(chat.transcriptExtentForTesting, 'complete');
    expect(chat.hasEarlierMessages, isFalse);

    final envelope =
        jsonDecode(secureStore[_transcriptKey('conn-count', 'session-count')]!)
            as Map<String, dynamic>;
    expect(envelope['older_history_truncated'], isFalse);
  });

  test('transcript local registra recorte por cantidad al reabrir', () async {
    final newestFirst = <Map<String, dynamic>>[
      for (var index = 1050; index >= 1; index--)
        {
          'role': index.isOdd ? 'user' : 'assistant',
          'content': 'mensaje $index',
        },
    ];

    await LocalTranscriptStore.saveFromNewestFirst(
      'conn-count-cap',
      'session-count-cap',
      newestFirst,
    );
    final firstOpen = await LocalTranscriptStore.loadSnapshot(
      'conn-count-cap',
      'session-count-cap',
    );
    await LocalTranscriptStore.saveFromNewestFirst(
      'conn-count-cap',
      'session-count-cap',
      firstOpen.messages.reversed.toList(growable: false),
    );
    final reopened = await LocalTranscriptStore.loadSnapshot(
      'conn-count-cap',
      'session-count-cap',
    );

    expect(firstOpen.olderHistoryTruncated, isTrue);
    expect(reopened.olderHistoryTruncated, isTrue);
    expect(reopened.messages, hasLength(_maxLocalTranscriptMessages));
    expect(reopened.messages.first['content'], 'mensaje 51');
    expect(reopened.messages.last['content'], 'mensaje 1050');
    final envelope =
        jsonDecode(
              secureStore[_transcriptKey(
                'conn-count-cap',
                'session-count-cap',
              )]!,
            )
            as Map<String, dynamic>;
    expect(envelope['older_history_truncated'], isTrue);
  });

  test(
    'reapertura sobre el límite expone aviso y cargar anteriores',
    () async {
      await LocalTranscriptStore.saveFromNewestFirst(
        'conn-truncated',
        'session-truncated',
        [
          for (var index = 1001; index >= 1; index--)
            {
              'role': index.isOdd ? 'user' : 'assistant',
              'content': 'mensaje $index',
            },
        ],
      );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: SavedConnection(
          id: 'conn-truncated',
          label: 'Local',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'test-key',
          kind: InstanceKind.localhost,
          onDeviceLoopback: true,
        ),
        sessionId: 'session-truncated',
        sessionTitle: 'Historial local',
        notifications: null,
        onTerminal: () {},
      );
      addTearDown(chat.dispose);

      await chat.loadMessages();

      expect(chat.messages, hasLength(_maxLocalTranscriptMessages));
      expect(chat.messages.first['content'], 'mensaje 1001');
      expect(chat.messages.last['content'], 'mensaje 2');
      expect(chat.localTranscriptOlderHistoryTruncated, isTrue);
      expect(chat.transcriptExtentForTesting, 'partial');
      expect(chat.needsTranscriptTailHydrationForTesting, isTrue);
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test('transcript local registra recorte por bytes al reabrir', () async {
    final newestFirst = <Map<String, dynamic>>[
      for (var index = 8; index >= 1; index--)
        {
          'role': index.isOdd ? 'user' : 'assistant',
          'content': 'mensaje-$index:${'x' * 350000}',
        },
    ];

    await LocalTranscriptStore.saveFromNewestFirst(
      'conn-bytes',
      'session-bytes',
      newestFirst,
    );
    final firstOpen = await LocalTranscriptStore.loadSnapshot(
      'conn-bytes',
      'session-bytes',
    );
    final reopened = await LocalTranscriptStore.loadSnapshot(
      'conn-bytes',
      'session-bytes',
    );

    expect(firstOpen.olderHistoryTruncated, isTrue);
    expect(reopened.olderHistoryTruncated, isTrue);
    expect(reopened.messages.length, lessThan(8));
    expect(reopened.messages.last['content'], startsWith('mensaje-8:'));
    expect(
      utf8
          .encode(secureStore[_transcriptKey('conn-bytes', 'session-bytes')]!)
          .length,
      lessThanOrEqualTo(_maxLocalTranscriptEncodedBytes),
    );
  });

  test('1000 message transcript encode measurement stays under 2 MiB', () async {
    final newestFirst = <Map<String, dynamic>>[
      for (var index = 1000; index >= 1; index--)
        {
          'role': index.isOdd ? 'user' : 'assistant',
          'content': 'mensaje-$index:${'x' * 1800}',
        },
    ];
    final stopwatch = Stopwatch()..start();

    final snapshot = await LocalTranscriptStore.saveFromNewestFirst(
      'conn-measure',
      'session-measure',
      newestFirst,
    );
    stopwatch.stop();
    final encodedBytes = utf8
        .encode(
          secureStore[_transcriptKey('conn-measure', 'session-measure')]!,
        )
        .length;
    debugPrint(
      'local transcript encode measurement: $encodedBytes bytes in '
      '${stopwatch.elapsedMicroseconds} us',
    );

    expect(snapshot.messages, hasLength(_maxLocalTranscriptMessages));
    expect(snapshot.olderHistoryTruncated, isFalse);
    expect(encodedBytes, lessThanOrEqualTo(_maxLocalTranscriptEncodedBytes));
  });

  test(
    'transcript legacy corrupto no migra ni destruye recuperación',
    () async {
      const key = 'local_transcript_conn-a_session-corrupt';
      SharedPreferences.setMockInitialValues({key: 'not-json'});
      final prefs = await SharedPreferences.getInstance();

      final restored = await LocalTranscriptStore.load(
        'conn-a',
        'session-corrupt',
      );

      expect(restored, isEmpty);
      expect(prefs.getString(key), 'not-json');
      expect(secureStore[key], isNull);
    },
  );

  test('local transcript keeps reply and reasoning in separate fields', () async {
    const commentary = 'CACHE_COMMENTARY_REASONING';
    const analysis = 'CACHE_ANALYSIS_REASONING';
    const inlineMarker = 'PRIVATE_CACHE_INLINE_TEXT';
    const reasoningOnly = 'CACHE_REASONING_ONLY';
    await LocalTranscriptStore.saveFromNewestFirst(
      'conn-codex',
      'session-sidecar',
      const [
        {
          'role': 'assistant',
          'content': '',
          'codex_message_items': [
            {
              'type': 'message',
              'role': 'assistant',
              'phase': 'commentary',
              'content': [
                {'type': 'output_text', 'text': commentary},
              ],
            },
            {
              'type': 'message',
              'role': 'assistant',
              'phase': 'analysis',
              'content': [
                {'type': 'output_text', 'text': analysis},
              ],
            },
            {
              'type': 'message',
              'role': 'assistant',
              'phase': 'final_answer',
              'content': [
                {
                  'type': 'output_text',
                  'text': '<think>$inlineMarker</think>Respuesta en caché.',
                },
              ],
            },
          ],
        },
        {
          'role': 'assistant',
          'content': '',
          'codex_message_items': [
            {
              'type': 'message',
              'role': 'assistant',
              'phase': 'analysis',
              'content': [
                {'type': 'output_text', 'text': reasoningOnly},
              ],
            },
          ],
          'tool_calls': [
            {
              'id': 'call-private',
              'function': {'name': 'shell', 'arguments': '{}'},
            },
          ],
        },
      ],
    );

    final restored = await LocalTranscriptStore.load(
      'conn-codex',
      'session-sidecar',
    );

    expect(restored, [
      {'role': 'assistant', 'content': '', 'reasoning': reasoningOnly},
      {
        'role': 'assistant',
        'content': 'Respuesta en caché.',
        'reasoning': '$commentary\n\n$analysis',
      },
    ]);
    final raw = secureStore[_transcriptKey('conn-codex', 'session-sidecar')]!;
    expect(raw, contains(commentary));
    expect(raw, contains(analysis));
    expect(raw, contains(reasoningOnly));
    expect(raw, isNot(contains(inlineMarker)));
    expect(raw, isNot(contains('codex_message_items')));
  });

  test(
    'transcript local descarta classifiers y reasoning antes de guardar',
    () async {
      await LocalTranscriptStore.saveFromNewestFirst(
        'conn-private',
        'session-classified',
        const [
          {
            'role': 'assistant',
            'content': '<think>PRIVATE_INLINE</think>Respuesta pública.',
          },
          {
            'role': 'assistant',
            'content': 'PRIVATE_ANALYSIS',
            'channel': 'analysis',
          },
          {
            'role': 'user',
            'content': 'PRIVATE_HIDDEN',
            'display_kind': 'hidden',
          },
          {'role': 'user', 'content': 'Pregunta pública'},
        ],
      );

      final raw =
          secureStore[_transcriptKey('conn-private', 'session-classified')]!;
      final restored = await LocalTranscriptStore.load(
        'conn-private',
        'session-classified',
      );

      expect(raw, isNot(contains('PRIVATE_')));
      expect(restored, [
        {'role': 'user', 'content': 'Pregunta pública'},
        {'role': 'assistant', 'content': 'Respuesta pública.'},
      ]);
    },
  );

  test(
    'transcript local conserva solo metadata segura de delegación',
    () async {
      const marker = '[ASYNC DELEGATION BATCH COMPLETE — deleg_c0ffee12]';
      await LocalTranscriptStore.saveFromNewestFirst(
        'conn-a',
        'session-delegation',
        [
          {
            'role': 'user',
            'content': marker,
            'display_kind': 'async_delegation_complete',
            'display_metadata': {
              'delegation_id': 'deleg_c0ffee12',
              'task_count': 2,
              'completed_count': 2,
              'failed_count': 0,
              'duration_seconds': 8,
              'subagent_ids': ['sa-safe-one', 'sa-safe-two'],
              'goal': 'prompt privado',
              'model': 'modelo privado',
              'path': '/home/private',
            },
          },
        ],
      );

      final restored = await LocalTranscriptStore.load(
        'conn-a',
        'session-delegation',
      );

      expect(restored, hasLength(1));
      expect(restored.single, {
        'role': 'user',
        'content': marker,
        'display_kind': 'async_delegation_complete',
        'display_metadata': {
          'delegation_id': 'deleg_c0ffee12',
          'task_count': 2,
          'completed_count': 2,
          'failed_count': 0,
          'duration_seconds': 8,
          'subagent_ids': ['sa-safe-one', 'sa-safe-two'],
        },
      });
    },
  );

  test(
    'transcript local conserva el aviso durable de proceso en segundo plano',
    () async {
      const carrier =
          '[IMPORTANT: Background process proc_0123456789ab exited (exit code 0).\n'
          'Command: node verify.mjs\n'
          'Output:\n'
          'verificacion completada\n'
          ']';
      await LocalTranscriptStore.saveFromNewestFirst(
        'conn-a',
        'session-process-complete',
        [
          {
            'role': 'user',
            'content': carrier,
            'display_kind': 'process_complete',
            'display_metadata': {
              'display_text': 'Background Process Finished: node verify.mjs',
              'goal': 'prompt privado',
              'path': '/home/private',
            },
          },
        ],
      );

      final restored = await LocalTranscriptStore.load(
        'conn-a',
        'session-process-complete',
      );

      expect(restored, hasLength(1));
      expect(restored.single, {
        'role': 'user',
        'content': carrier,
        'display_kind': 'process_complete',
        'display_metadata': {
          'display_text': 'Background Process Finished: node verify.mjs',
        },
      });
    },
  );

  test(
    'transcript local descarta una clasificación editorial en rol assistant',
    () async {
      await LocalTranscriptStore.saveFromNewestFirst(
        'conn-a',
        'session-editorial-assistant',
        [
          {
            'role': 'assistant',
            'content': 'PRIVATE_EDITORIAL_ASSISTANT',
            'display_kind': 'process_complete',
          },
          {
            'role': 'assistant',
            'content': 'PRIVATE_EDITORIAL_DELEGATION',
            'display_kind': 'async_delegation_complete',
          },
          {'role': 'user', 'content': 'Pregunta pública'},
        ],
      );

      final restored = await LocalTranscriptStore.load(
        'conn-a',
        'session-editorial-assistant',
      );

      expect(restored, [
        {'role': 'user', 'content': 'Pregunta pública'},
      ]);
    },
  );

  test(
    'transcripts quedan aislados por perfil y cleanup conserva vecinos',
    () async {
      const defaultTranscript = [
        {'role': 'assistant', 'content': 'respuesta default'},
        {'role': 'user', 'content': 'pregunta default'},
      ];
      const managerTranscript = [
        {'role': 'assistant', 'content': 'respuesta manager'},
        {'role': 'user', 'content': 'pregunta manager'},
      ];

      await LocalTranscriptStore.saveFromNewestFirst(
        'conn-a',
        'shared-session',
        defaultTranscript,
        profile: 'default',
      );
      await LocalTranscriptStore.saveFromNewestFirst(
        'conn-a',
        'shared-session',
        managerTranscript,
        profile: 'manager',
      );

      final removed = await LocalTranscriptStore.deleteForProfile(
        'conn-a',
        'manager',
      );

      expect(removed, 1);
      expect(
        await LocalTranscriptStore.load(
          'conn-a',
          'shared-session',
          profile: 'manager',
        ),
        isEmpty,
      );
      expect(
        await LocalTranscriptStore.load(
          'conn-a',
          'shared-session',
          profile: 'default',
        ),
        [
          {'role': 'user', 'content': 'pregunta default'},
          {'role': 'assistant', 'content': 'respuesta default'},
        ],
      );
    },
  );

  test(
    'cleanup default de transcript omite legacy ambiguo y conserva otros owners',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await LocalTranscriptStore.saveFromNewestFirst(
        'conn-a',
        'default-session',
        const [
          {'role': 'assistant', 'content': 'default'},
        ],
      );
      await LocalTranscriptStore.saveFromNewestFirst(
        'conn-a',
        'manager-session',
        const [
          {'role': 'assistant', 'content': 'manager'},
        ],
        profile: 'manager',
      );
      await prefs.setString(
        'local_transcript_conn-a_$_legacyTranscriptSession',
        jsonEncode(const [
          {'role': 'assistant', 'content': 'legacy'},
        ]),
      );

      expect(await LocalTranscriptStore.deleteForProfile('conn-a', ''), 1);

      expect(
        await LocalTranscriptStore.load(
          'conn-a',
          'manager-session',
          profile: 'manager',
        ),
        isNotEmpty,
      );
      expect(
        prefs.containsKey('local_transcript_conn-a_$_legacyTranscriptSession'),
        isTrue,
      );
    },
  );

  test('listado local incluye transcripts no-default con su perfil', () async {
    await LocalTranscriptStore.saveFromNewestFirst(
      'conn-a',
      'session-manager',
      const [
        {'role': 'assistant', 'content': 'respuesta manager'},
        {'role': 'user', 'content': 'pregunta manager'},
      ],
      profile: 'manager',
    );

    final sessions = await LocalTranscriptStore.listForConnection('conn-a');

    expect(sessions, hasLength(1));
    expect(sessions.single.id, 'session-manager');
    expect(sessions.single.profile, 'manager');
  });

  test('borra solo los transcripts locales de la conexión indicada', () async {
    final prefs = await SharedPreferences.getInstance();
    const transcript = [
      {'role': 'user', 'content': 'hola'},
      {'role': 'assistant', 'content': 'respuesta'},
    ];
    await LocalTranscriptStore.saveFromNewestFirst(
      'conn-a',
      'session-a',
      transcript.reversed.toList(),
    );
    await LocalTranscriptStore.saveFromNewestFirst(
      'conn-a',
      'session-b',
      transcript.reversed.toList(),
    );
    await LocalTranscriptStore.saveFromNewestFirst(
      'conn-a',
      'session-manager',
      transcript.reversed.toList(),
      profile: 'manager',
    );
    await LocalTranscriptStore.saveFromNewestFirst(
      'conn-b',
      'session-a',
      transcript.reversed.toList(),
    );
    final historicalV2 = _v2TranscriptKey('conn-a', 'historical-v2');
    await prefs.setString(
      'local_transcript_conn-a_$_legacyTranscriptSession',
      '[]',
    );
    await prefs.setString(historicalV2, '[]');

    final removed = await LocalTranscriptStore.deleteForConnection('conn-a');

    expect(removed, 3);
    expect(
      secureStore.keys.where(
        (key) => key.startsWith('local_transcript_conn-a_'),
      ),
      isEmpty,
    );
    expect(
      secureStore.keys.where(
        (key) => key.startsWith(
          'hermes.transcript.v3.${_hexTranscriptScope('conn-a')}.',
        ),
      ),
      isEmpty,
    );
    expect(secureStore[_transcriptKey('conn-b', 'session-a')], isNotNull);
    expect(
      prefs.getString('local_transcript_conn-a_$_legacyTranscriptSession'),
      isNotNull,
    );
    expect(prefs.getString(historicalV2), '[]');
  });
}
