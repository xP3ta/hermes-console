import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/local_transcript_store.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secure = <String, String>{};
  Completer<void>? blockedWriteEntered;
  Completer<void>? releaseBlockedWrite;
  var blockNextOutboxWrite = false;

  setUp(() {
    secure.clear();
    SharedPreferences.setMockInitialValues({});
    LocalConversationCleanupFence.resetForTesting();
    TurnOutboxStore.resetSerializationForTesting();
    blockedWriteEntered = null;
    releaseBlockedWrite = null;
    blockNextOutboxWrite = false;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                if (args['key'] == 'chat_turn_outbox_v1' &&
                    blockNextOutboxWrite) {
                  blockNextOutboxWrite = false;
                  blockedWriteEntered?.complete();
                  await releaseBlockedWrite?.future;
                }
                secure[args['key'] as String] = args['value'] as String;
              case 'read':
                return secure[args['key'] as String];
              case 'delete':
                secure.remove(args['key'] as String);
              case 'readAll':
                return Map<String, String>.from(secure);
            }
            return null;
          },
        );
  });

  PreparedTurn turn({
    String connection = 'c1',
    String session = 's1',
    String id = 't1',
    String text = 'mensaje privado',
    List<AttachmentDraft> attachments = const [],
    PreparedTurnState state = PreparedTurnState.prepared,
    String profile = '',
    int? updatedAtMs,
    int? queueOrder,
    bool queued = false,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return PreparedTurn(
      connectionId: connection,
      sessionId: session,
      clientTurnId: id,
      createdAtMs: updatedAtMs ?? now,
      updatedAtMs: updatedAtMs ?? now,
      queueOrder: queueOrder,
      text: text,
      attachments: attachments,
      model: 'modelo',
      profile: profile,
      state: state,
      queued: queued,
    );
  }

  test('guarda cifrado y aísla por conexión y sesión', () async {
    final store = TurnOutboxStore();
    await Future.wait([
      store.save(turn()),
      store.save(turn(connection: 'c2', id: 't2', text: 'otro')),
    ]);

    expect((await store.loadForChat('c1', 's1'))?.clientTurnId, 't1');
    expect((await store.loadForChat('c2', 's1'))?.clientTurnId, 't2');
    expect(secure.keys, ['chat_turn_outbox_v1']);
    expect(secure.values.single, contains('mensaje privado'));
    // El mapa observado pertenece al mock del plugin; en producción el valor
    // completo vive detrás de flutter_secure_storage/Keystore, no en prefs.
  });

  test('recupera todos los turnos queued del chat en orden FIFO', () async {
    final store = TurnOutboxStore();
    final base = DateTime.now().millisecondsSinceEpoch;
    await store.save(
      turn(
        id: 'q2',
        text: 'segundo',
        updatedAtMs: base,
        queueOrder: 2,
        queued: true,
      ),
    );
    await store.save(
      turn(
        id: 'q1',
        text: 'primero',
        updatedAtMs: base,
        queueOrder: 1,
        queued: true,
      ),
    );
    await store.save(
      turn(
        id: 'ambiguous',
        text: 'incierto',
        updatedAtMs: base,
        queueOrder: 3,
        queued: true,
        state: PreparedTurnState.submitting,
      ),
    );

    final restored = await store.loadAllForChat('c1', 's1', profile: 'default');

    expect(restored.map((item) => item.clientTurnId), [
      'q1',
      'q2',
      'ambiguous',
    ]);
    expect(restored.last.state, PreparedTurnState.ambiguous);
  });

  test('aísla owners que comparten conexión y session id', () async {
    final store = TurnOutboxStore();
    final profileA = turn(profile: 'profile-a', id: 'turn-a', text: 'A');
    final profileB = turn(profile: 'profile-b', id: 'turn-b', text: 'B');
    await store.save(profileA);
    await store.save(profileB);

    expect(
      (await store.loadForChat('c1', 's1', profile: 'profile-a'))?.clientTurnId,
      'turn-a',
    );
    expect(
      (await store.loadForChat('c1', 's1', profile: 'profile-b'))?.clientTurnId,
      'turn-b',
    );
    expect(await store.loadForChat('c1', 's1'), isNull);

    await store.deleteForChat('c1', 's1', profile: 'profile-a');
    expect(await store.loadForChat('c1', 's1', profile: 'profile-a'), isNull);
    expect(
      (await store.loadForChat('c1', 's1', profile: 'profile-b'))?.clientTurnId,
      'turn-b',
    );
  });

  test(
    'REGRESSION_CLEANUP_BARRIER serializa outbox admitida y rechaza callback tardío',
    () async {
      final lifecycle = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'c1',
        profile: 'profile-a',
        sessionId: 's1',
      );
      expect(LocalConversationCleanupFence.rehydrate(lifecycle), isTrue);
      final store = TurnOutboxStore(lifecycle: lifecycle);
      blockedWriteEntered = Completer<void>();
      releaseBlockedWrite = Completer<void>();
      blockNextOutboxWrite = true;

      final admitted = store.save(turn(id: 'admitted', profile: 'profile-a'));
      await blockedWriteEntered!.future;
      final cleanup = store.deleteForProfile('c1', 'profile-a');
      final late = expectLater(
        store.save(turn(id: 'late', profile: 'profile-a')),
        throwsA(isA<LocalConversationWriteRejected>()),
      );

      releaseBlockedWrite!.complete();
      await admitted;
      expect(await cleanup, 1);
      await late;
      expect(await store.loadForChat('c1', 's1', profile: 'profile-a'), isNull);
    },
  );

  test(
    'cleanup de alcance falla cerrado ante outbox global corrupta',
    () async {
      final store = TurnOutboxStore();
      for (final clearScope in <Future<int> Function()>[
        () => store.deleteForChat('c1', 's1', profile: 'profile-a'),
        () => store.deleteForProfile('c1', 'profile-a'),
        () => store.deleteForConnection('c1'),
      ]) {
        secure['chat_turn_outbox_v1'] = '{not-json';
        await expectLater(clearScope(), throwsA(isA<FormatException>()));
        expect(secure['chat_turn_outbox_v1'], '{not-json');
      }
    },
  );

  test('cleanup de perfil borra su outbox y conserva vecinos', () async {
    final store = TurnOutboxStore();
    await store.save(turn(connection: 'c1', id: 'a1', profile: 'profile-a'));
    await store.save(
      turn(connection: 'c1', session: 's2', id: 'a2', profile: 'profile-a'),
    );
    await store.save(turn(connection: 'c1', id: 'b1', profile: 'profile-b'));
    await store.save(turn(connection: 'c2', id: 'a3', profile: 'profile-a'));

    expect(await store.deleteForProfile('c1', 'profile-a'), 2);

    expect(await store.loadForChat('c1', 's1', profile: 'profile-a'), isNull);
    expect(await store.loadForChat('c1', 's2', profile: 'profile-a'), isNull);
    expect(
      (await store.loadForChat('c1', 's1', profile: 'profile-b'))?.clientTurnId,
      'b1',
    );
    expect(
      (await store.loadForChat('c2', 's1', profile: 'profile-a'))?.clientTurnId,
      'a3',
    );
  });

  test(
    'cleanup outbox normaliza owner default y conserva otros perfiles',
    () async {
      final store = TurnOutboxStore();
      await store.save(turn(id: 'default-turn', profile: ''));
      await store.save(turn(id: 'manager-turn', profile: 'manager'));

      expect(await store.deleteForProfile('c1', ''), 1);

      expect(await store.loadForChat('c1', 's1', profile: 'default'), isNull);
      expect(
        (await store.loadForChat('c1', 's1', profile: 'manager'))?.clientTurnId,
        'manager-turn',
      );
    },
  );

  test(
    'default migra owner vacío y conserva identidad al reintentar',
    () async {
      final store = TurnOutboxStore();
      final legacyDefault = turn(profile: '', id: 'legacy-default');
      secure['chat_turn_outbox_v1'] = jsonEncode({
        legacyDefault.legacyStorageId: legacyDefault.toJson(),
      });

      final restored = await store.loadForChat('c1', 's1', profile: 'default');

      expect(restored?.clientTurnId, 'legacy-default');
      expect(restored?.profile, 'default');
      expect(
        restored?.matchesBatch(
          text: legacyDefault.text,
          attachments: legacyDefault.attachments,
          model: legacyDefault.model,
          profile: 'default',
        ),
        isTrue,
      );

      await store.save(
        restored!.copyWith(
          updatedAtMs: restored.updatedAtMs + 1,
          state: PreparedTurnState.prepared,
        ),
      );
      final persisted = jsonDecode(secure['chat_turn_outbox_v1']!) as Map;
      expect(persisted, hasLength(1));
      expect(persisted.keys.single, restored.storageId);
      expect(
        (persisted.values.single as Map)['client_turn_id'],
        'legacy-default',
      );
      expect((persisted.values.single as Map)['profile'], 'default');

      expect(await store.deleteForChat('c1', 's1', profile: 'default'), 1);
      expect(await store.loadForChat('c1', 's1', profile: 'default'), isNull);
    },
  );

  test('clave ajena a la identidad del payload falla cerrado', () async {
    final payload = turn(id: 'identity-mismatch', profile: 'default');
    secure['chat_turn_outbox_v1'] = jsonEncode({
      'not-the-payload-identity': payload.toJson(),
    });

    await expectLater(
      TurnOutboxStore().loadAllForChat('c1', 's1', profile: 'default'),
      throwsA(isA<StateError>()),
    );
  });

  test('colisión canonical y legacy contradictoria falla cerrado', () async {
    final legacy = turn(id: 'collision', profile: '', text: 'legacy');
    final canonical = turn(
      id: 'collision',
      profile: 'default',
      text: 'canonical-contradictory',
    );
    secure['chat_turn_outbox_v1'] = jsonEncode({
      legacy.legacyStorageId: legacy.toJson(),
      canonical.storageId: canonical.toJson(),
    });

    await expectLater(
      TurnOutboxStore().loadAllForChat('c1', 's1', profile: 'default'),
      throwsA(isA<StateError>()),
    );
  });

  test('conserva el estado ambiguo y elimina el terminal', () async {
    final store = TurnOutboxStore();
    await store.save(turn(state: PreparedTurnState.ambiguous));
    expect(
      (await store.loadForChat('c1', 's1'))?.state,
      PreparedTurnState.ambiguous,
    );

    await store.save(turn(state: PreparedTurnState.terminal));
    expect(await store.loadForChat('c1', 's1'), isNull);
  });

  test('process death durante submitting restaura como ambiguo', () async {
    final store = TurnOutboxStore();
    await store.save(turn(state: PreparedTurnState.submitting));

    final restored = await store.loadForChat('c1', 's1');

    expect(restored?.state, PreparedTurnState.ambiguous);
    expect(restored?.clientTurnId, 't1');
  });

  test('solo reutiliza identidad para el mismo lote y configuración', () {
    final original = turn();

    expect(
      original.matchesBatch(
        text: 'mensaje privado',
        attachments: const [],
        model: 'modelo',
        profile: '',
      ),
      isTrue,
    );
    expect(
      original.matchesBatch(
        text: 'mensaje distinto',
        attachments: const [],
        model: 'modelo',
        profile: '',
      ),
      isFalse,
    );
    expect(
      original.matchesBatch(
        text: 'mensaje privado',
        attachments: const [],
        model: 'otro-modelo',
        profile: '',
      ),
      isFalse,
    );
    expect(
      original.matchesBatch(
        text: 'mensaje privado',
        attachments: const [],
        model: 'modelo',
        profile: 'otro-perfil',
      ),
      isFalse,
    );
  });

  test('conserva adjunto ausente como error sin degradar a texto', () async {
    final store = TurnOutboxStore();
    await store.save(
      turn(
        attachments: const [
          AttachmentDraft(
            type: AttachmentType.image,
            name: 'ausente.png',
            mimeType: 'image/png',
            sizeBytes: 4,
            localPath: '/no/existe/ausente.png',
          ),
        ],
      ),
    );

    final restored = await store.loadForChat('c1', 's1');
    expect(restored?.text, 'mensaje privado');
    expect(restored?.attachments, hasLength(1));
    expect(
      restored?.attachments.single.errorKind,
      AttachmentErrorKind.missingFile,
    );
  });

  test('restaura un adjunto existente', () async {
    final file = File(
      '${Directory.systemTemp.path}/hermes-outbox-${DateTime.now().microsecondsSinceEpoch}.png',
    );
    await file.writeAsBytes([1, 2, 3]);
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });
    final store = TurnOutboxStore();
    await store.save(
      turn(
        text: '',
        attachments: [
          AttachmentDraft(
            type: AttachmentType.image,
            name: 'ok.png',
            mimeType: 'image/png',
            sizeBytes: 3,
            localPath: file.path,
          ),
        ],
      ),
    );

    expect((await store.loadForChat('c1', 's1'))?.attachments, hasLength(1));
  });

  test('roundtrip conserva FSM, attempt, ref y owner del adjunto', () async {
    final file = File(
      '${Directory.systemTemp.path}/hermes-outbox-fsm-${DateTime.now().microsecondsSinceEpoch}.pdf',
    );
    await file.writeAsBytes([1, 2, 3]);
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });
    final store = TurnOutboxStore();
    await store.save(
      turn(
        attachments: [
          AttachmentDraft(
            localId: 'attachment-fsm',
            type: AttachmentType.document,
            name: 'fsm.pdf',
            mimeType: 'application/pdf',
            sizeBytes: 3,
            localPath: file.path,
            uploadState: AttachmentUploadState.attached,
            attempt: 2,
            remoteRef: '@file:.hermes/fsm.pdf',
            remoteSessionId: 'runtime-a',
            remoteTransport: AttachmentRemoteTransport.desktop,
          ),
        ],
      ),
    );

    final restored = (await store.loadForChat('c1', 's1'))!.attachments.single;
    expect(restored.localId, 'attachment-fsm');
    expect(restored.uploadState, AttachmentUploadState.attached);
    expect(restored.attempt, 2);
    expect(restored.remoteRef, '@file:.hermes/fsm.pdf');
    expect(restored.remoteSessionId, 'runtime-a');
    expect(restored.remoteTransport, AttachmentRemoteTransport.desktop);
  });

  test(
    'attached remoto sobrevive aunque ya no haga falta la copia local',
    () async {
      final store = TurnOutboxStore();
      await store.save(
        turn(
          attachments: const [
            AttachmentDraft(
              localId: 'attached-no-local',
              type: AttachmentType.document,
              name: 'remote.pdf',
              mimeType: 'application/pdf',
              sizeBytes: 3,
              localPath: '/no/existe/remote.pdf',
              uploadState: AttachmentUploadState.attached,
              attempt: 1,
              remoteRef: '@file:.hermes/remote.pdf',
              remoteSessionId: 'runtime-a',
              remoteTransport: AttachmentRemoteTransport.desktop,
            ),
          ],
        ),
      );

      final restored = await store.loadForChat('c1', 's1');
      expect(restored?.attachments.single.localId, 'attached-no-local');
    },
  );

  test('process death convierte uploading en error interrumpido', () async {
    final file = File(
      '${Directory.systemTemp.path}/hermes-outbox-uploading-${DateTime.now().microsecondsSinceEpoch}.pdf',
    );
    await file.writeAsBytes([1]);
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });
    final store = TurnOutboxStore();
    await store.save(
      turn(
        state: PreparedTurnState.submitting,
        attachments: [
          AttachmentDraft(
            localId: 'uploading-a',
            type: AttachmentType.document,
            name: 'uploading.pdf',
            mimeType: 'application/pdf',
            sizeBytes: 1,
            localPath: file.path,
            uploadState: AttachmentUploadState.uploading,
            attempt: 4,
          ),
        ],
      ),
    );

    final restored = await store.loadForChat('c1', 's1');
    final attachment = restored!.attachments.single;
    expect(restored.state, PreparedTurnState.ambiguous);
    expect(attachment.uploadState, AttachmentUploadState.error);
    expect(attachment.attempt, 4);
    expect(attachment.errorKind, AttachmentErrorKind.interrupted);
  });

  test('prune no limpia una copia todavía referenciada por otro turno', () async {
    final cleaned = <String>[];
    final store = TurnOutboxStore(
      deletePrivateCopy: (attachment) async {
        cleaned.add(attachment.localId);
        return true;
      },
    );
    final file = File(
      '${Directory.systemTemp.path}/hermes-outbox-shared-${DateTime.now().microsecondsSinceEpoch}.pdf',
    );
    await file.writeAsBytes([1]);
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });
    final shared = AttachmentDraft(
      localId: 'shared-outbox',
      type: AttachmentType.document,
      name: 'shared.pdf',
      mimeType: 'application/pdf',
      sizeBytes: 1,
      localPath: file.path,
    );
    final old = DateTime.now()
        .subtract(const Duration(days: 31))
        .millisecondsSinceEpoch;
    final current = turn(id: 'current', attachments: [shared]);
    await store.save(
      turn(
        id: 'old',
        updatedAtMs: old,
        attachments: [shared],
        state: PreparedTurnState.terminal,
      ),
    );
    await store.save(current);

    expect(await store.prune(), 1);
    expect(cleaned, isEmpty);
    await store.delete(current);
    expect(cleaned, ['shared-outbox']);
  });

  test('un tombstone removed deja de ser owner de la copia privada', () async {
    final cleaned = <String>[];
    final store = TurnOutboxStore(
      deletePrivateCopy: (attachment) async {
        cleaned.add(attachment.localId);
        return true;
      },
    );
    const pending = AttachmentDraft(
      localId: 'removed-owner',
      type: AttachmentType.document,
      name: 'removed.pdf',
      mimeType: 'application/pdf',
      sizeBytes: 1,
      localPath: '/private/removed.pdf',
    );
    await store.save(turn(attachments: const [pending]));

    await store.save(
      turn(
        attachments: [
          pending.copyWith(uploadState: AttachmentUploadState.removed),
        ],
      ),
    );

    expect(cleaned, ['removed-owner']);
  });

  test(
    'poda conserva activos antiguos y payload corrupto falla cerrado',
    () async {
      final store = TurnOutboxStore();
      final old = DateTime.now()
          .subtract(const Duration(days: 31))
          .millisecondsSinceEpoch;
      await store.save(turn(updatedAtMs: old));
      expect(await store.prune(), 0);
      expect((await store.loadForChat('c1', 's1'))?.clientTurnId, 't1');

      secure['chat_turn_outbox_v1'] = '{no-json';
      await expectLater(
        store.loadForChat('c1', 's1'),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('limpia por sesión y conexión sin tocar otros lotes', () async {
    final store = TurnOutboxStore();
    await store.save(turn(connection: 'c1', session: 's1', id: 't1'));
    await store.save(turn(connection: 'c1', session: 's2', id: 't2'));
    await store.save(turn(connection: 'c2', session: 's1', id: 't3'));

    expect(await store.deleteForChat('c1', 's1'), 1);
    expect(await store.loadForChat('c1', 's1'), isNull);
    expect((await store.loadForChat('c1', 's2'))?.clientTurnId, 't2');
    expect(await store.deleteForConnection('c1'), 1);
    expect(await store.loadForChat('c1', 's2'), isNull);
    expect((await store.loadForChat('c2', 's1'))?.clientTurnId, 't3');
  });

  test(
    'save outbox admitido antes de deleteForChat no resucita turno',
    () async {
      final store = TurnOutboxStore();
      final release = Completer<void>();
      final blocker = LocalConversationCleanupFence.write(
        connectionId: 'other',
        operation: () => release.future,
      );
      final saving = store.save(
        turn(connection: 'ordered', session: 'session', profile: 'profile'),
      );
      await store.deleteForChat('ordered', 'session', profile: 'profile');
      release.complete();
      await blocker;
      await saving;
      expect(
        await store.loadForChat('ordered', 'session', profile: 'profile'),
        isNull,
      );
    },
  );

  test('diferencial outbox conserva orden con IO transcript ajeno', () async {
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
                secure[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                return secure[args['key'] as String];
              case 'delete':
                secure.remove(args['key'] as String);
                return null;
              case 'readAll':
                return Map<String, String>.from(secure);
            }
            return null;
          },
        );
    final store = TurnOutboxStore();
    final transcript = LocalTranscriptStore.saveFromNewestFirst(
      'unrelated',
      'session',
      const [
        {'role': 'assistant', 'content': 'unrelated'},
      ],
    );
    await entered.future;
    final saving = store.save(
      turn(connection: 'ordered', session: 'session', profile: 'profile'),
    );
    await store.deleteForChat('ordered', 'session', profile: 'profile');
    release.complete();
    await transcript;
    await saving;
    expect(
      await store.loadForChat('ordered', 'session', profile: 'profile'),
      isNull,
    );
  });

  test('diagnóstico de outbox solo devuelve contadores y edad', () async {
    final store = TurnOutboxStore();
    final older = DateTime.now()
        .subtract(const Duration(hours: 3))
        .millisecondsSinceEpoch;
    await store.save(
      turn(
        id: 'client-turn-private',
        text: 'prompt privado',
        state: PreparedTurnState.ambiguous,
        updatedAtMs: older,
      ),
    );
    await store.save(
      turn(
        id: 'client-turn-private-2',
        text: 'otra conversación privada',
        state: PreparedTurnState.prepared,
      ),
    );

    final summary = await store.diagnosticSummary();

    expect(summary.counts[PreparedTurnState.ambiguous], 1);
    expect(summary.counts[PreparedTurnState.prepared], 1);
    expect(summary.oldestPendingUpdatedAtMs, older);
    expect(summary.toString(), isNot(contains('prompt privado')));
    expect(summary.toString(), isNot(contains('client-turn-private')));
  });
}
