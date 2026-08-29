import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secure = <String, String>{};

  setUp(() {
    secure.clear();
    TurnOutboxStore.resetSerializationForTesting();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
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
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return PreparedTurn(
      connectionId: connection,
      sessionId: session,
      clientTurnId: id,
      createdAtMs: updatedAtMs ?? now,
      updatedAtMs: updatedAtMs ?? now,
      text: text,
      attachments: attachments,
      model: 'modelo',
      profile: profile,
      state: state,
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
    await store.save(turn(id: 'q2', text: 'segundo', updatedAtMs: base + 2));
    await store.save(turn(id: 'q1', text: 'primero', updatedAtMs: base + 1));
    await store.save(
      turn(
        id: 'ambiguous',
        text: 'incierto',
        updatedAtMs: base + 3,
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

  test('descarta adjunto ausente sin perder el texto', () async {
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
    expect(restored?.attachments, isEmpty);
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
    await store.save(turn(id: 'old', updatedAtMs: old, attachments: [shared]));
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

  test('poda pendientes caducados y payload corrupto falla cerrado', () async {
    final store = TurnOutboxStore();
    final old = DateTime.now()
        .subtract(const Duration(days: 31))
        .millisecondsSinceEpoch;
    await store.save(turn(updatedAtMs: old));
    expect(await store.prune(), 1);
    expect(await store.loadForChat('c1', 's1'), isNull);

    secure['chat_turn_outbox_v1'] = '{no-json';
    expect(await store.loadForChat('c1', 's1'), isNull);
  });

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
