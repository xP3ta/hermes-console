import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';

void main() {
  AttachmentDraft attachment({
    String localId = 'attachment-a',
    AttachmentUploadState uploadState = AttachmentUploadState.pending,
    int attempt = 0,
    String? remoteRef,
    String? remoteSessionId,
    AttachmentRemoteTransport? remoteTransport,
    AttachmentErrorKind? errorKind,
  }) => AttachmentDraft(
    localId: localId,
    type: AttachmentType.document,
    name: 'informe.pdf',
    mimeType: 'application/pdf',
    sizeBytes: 42,
    localPath: '/private/informe.pdf',
    uploadState: uploadState,
    attempt: attempt,
    remoteRef: remoteRef,
    remoteSessionId: remoteSessionId,
    remoteTransport: remoteTransport,
    errorKind: errorKind,
  );

  PreparedTurn turn(List<AttachmentDraft> attachments) => PreparedTurn(
    connectionId: 'connection-a',
    sessionId: 'session-a',
    clientTurnId: 'turn-a',
    createdAtMs: 1000,
    updatedAtMs: 1001,
    text: 'revisa el informe',
    attachments: attachments,
    model: 'hermes-agent',
    profile: 'default',
  );

  test('migra schema 1 asignando identidad estable y estado pendiente', () {
    final legacy = {
      'schema_version': 1,
      'connection_id': 'connection-a',
      'session_id': 'session-a',
      'client_turn_id': 'turn-a',
      'created_at_ms': 1000,
      'updated_at_ms': 1001,
      'text': 'revisa el informe',
      'attachments': [
        {
          'type': 'document',
          'name': 'informe.pdf',
          'mime_type': 'application/pdf',
          'size_bytes': 42,
          'local_path': '/private/informe.pdf',
        },
      ],
      'model': 'hermes-agent',
      'profile': 'default',
      'transport': 'unknown',
      'state': 'prepared',
    };
    final restored = PreparedTurn.fromJson(legacy);

    final item = restored.attachments.single;
    expect(item.localId, isNotEmpty);
    expect(item.uploadState, AttachmentUploadState.pending);
    expect(item.attempt, 0);
    expect(restored.toJson()['schema_version'], 5);
    expect(
      AttachmentDraft.fromJson(item.toJson()).localId,
      item.localId,
      reason: 'la migración debe producir una identidad determinista',
    );
    expect(
      PreparedTurn.fromJson(legacy).attachments.single.localId,
      item.localId,
    );
  });

  test('schema 1 distingue chips idénticos por su índice y rechaza futuro', () {
    final legacy = {
      'schema_version': 1,
      'connection_id': 'connection-a',
      'session_id': 'session-a',
      'client_turn_id': 'turn-a',
      'created_at_ms': 1000,
      'updated_at_ms': 1001,
      'text': '',
      'attachments': [
        {
          'type': 'document',
          'name': 'igual.pdf',
          'mime_type': 'application/pdf',
          'size_bytes': 42,
          'local_path': '/private/igual.pdf',
        },
        {
          'type': 'document',
          'name': 'igual.pdf',
          'mime_type': 'application/pdf',
          'size_bytes': 42,
          'local_path': '/private/igual.pdf',
        },
      ],
      'model': 'hermes-agent',
      'profile': 'default',
      'transport': 'unknown',
      'state': 'prepared',
    };

    final ids = PreparedTurn.fromJson(
      legacy,
    ).attachments.map((item) => item.localId).toList();
    expect(ids.toSet(), hasLength(2));
    expect(
      () => PreparedTurn.fromJson({...legacy, 'schema_version': 6}),
      throwsFormatException,
    );
  });

  test('roundtrip conserva FSM, attempt, referencia y owner del runtime', () {
    final original = turn([
      attachment(
        uploadState: AttachmentUploadState.error,
        attempt: 3,
        remoteRef: '@file:.hermes/informe.pdf',
        remoteSessionId: 'runtime-a',
        remoteTransport: AttachmentRemoteTransport.desktop,
        errorKind: AttachmentErrorKind.transport,
      ),
    ]);

    final restored = PreparedTurn.fromJson(original.toJson());
    final item = restored.attachments.single;

    expect(item.localId, 'attachment-a');
    expect(item.uploadState, AttachmentUploadState.error);
    expect(item.attempt, 3);
    expect(item.remoteRef, '@file:.hermes/informe.pdf');
    expect(item.remoteSessionId, 'runtime-a');
    expect(item.remoteTransport, AttachmentRemoteTransport.desktop);
    expect(item.errorKind, AttachmentErrorKind.transport);
  });

  test('roundtrip conserva payloads preparados para REST y Desktop', () {
    final original = PreparedTurn(
      connectionId: 'connection-a',
      sessionId: 'session-a',
      clientTurnId: 'turn-payloads',
      createdAtMs: 1000,
      updatedAtMs: 1001,
      text: 'resumen visible',
      fullText: 'resumen visible\n⟦adjunto⟧\ncontenido privado',
      desktopText: 'resumen visible\n@file:.hermes/informe.pdf',
      attachments: [attachment()],
      model: 'hermes-agent',
      profile: 'research',
      queued: true,
    );

    final restored = PreparedTurn.fromJson(original.toJson());

    expect(restored.fullText, original.fullText);
    expect(restored.desktopText, original.desktopText);
    expect(restored.queued, isTrue);
    expect(restored.text, 'resumen visible');
    expect(restored.toJson()['schema_version'], 5);
  });

  test('schema 2 migra fullText desde text y deja desktopText ausente', () {
    final legacy = turn(const []).toJson()
      ..['schema_version'] = 2
      ..remove('full_text')
      ..remove('desktop_text');

    final restored = PreparedTurn.fromJson(legacy);

    expect(restored.fullText, restored.text);
    expect(restored.desktopText, isNull);
  });

  test(
    'copyWith reemplaza adjuntos y matchesBatch usa identidad inmutable',
    () {
      final original = turn([attachment()]);
      final progressed = attachment(
        uploadState: AttachmentUploadState.attached,
        attempt: 1,
        remoteRef: '@file:.hermes/informe.pdf',
        remoteSessionId: 'runtime-a',
        remoteTransport: AttachmentRemoteTransport.desktop,
      );
      final copied = original.copyWith(attachments: [progressed]);

      expect(
        copied.attachments.single.uploadState,
        AttachmentUploadState.attached,
      );
      expect(
        copied.matchesBatch(
          text: original.text,
          attachments: [attachment(uploadState: AttachmentUploadState.pending)],
          model: original.model,
          profile: original.profile,
        ),
        isTrue,
        reason: 'el progreso mutable no crea otro turno ni repite el RPC',
      );
      expect(
        copied.matchesBatch(
          text: original.text,
          attachments: [attachment(localId: 'attachment-b')],
          model: original.model,
          profile: original.profile,
        ),
        isFalse,
      );
    },
  );

  test('attempt fence rechaza callback viejo y removed es terminal', () {
    final uploading = attachment(
      uploadState: AttachmentUploadState.uploading,
      attempt: 2,
    );
    expect(
      uploading.acceptsCallback(localId: 'attachment-a', attempt: 2),
      isTrue,
    );
    expect(
      uploading.acceptsCallback(localId: 'attachment-a', attempt: 1),
      isFalse,
    );

    final removed = uploading.copyWith(
      uploadState: AttachmentUploadState.removed,
    );
    expect(
      removed.acceptsCallback(localId: 'attachment-a', attempt: 2),
      isFalse,
    );
    expect(removed.canTransitionTo(AttachmentUploadState.pending), isFalse);
  });

  test('una referencia attached se invalida al cambiar de runtime', () {
    final attached = attachment(
      uploadState: AttachmentUploadState.attached,
      attempt: 1,
      remoteRef: '@file:.hermes/informe.pdf',
      remoteSessionId: 'runtime-a',
      remoteTransport: AttachmentRemoteTransport.desktop,
    );

    expect(
      attached.resetForRemoteOwner(
        remoteSessionId: 'runtime-a',
        transport: AttachmentRemoteTransport.desktop,
      ),
      same(attached),
    );
    final rebound = attached.resetForRemoteOwner(
      remoteSessionId: 'runtime-b',
      transport: AttachmentRemoteTransport.desktop,
    );
    expect(rebound.uploadState, AttachmentUploadState.pending);
    expect(rebound.remoteRef, isNull);
    expect(rebound.remoteSessionId, isNull);
    expect(rebound.remoteTransport, isNull);
    expect(rebound.canTransitionTo(AttachmentUploadState.uploading), isTrue);
  });

  test('retry_boundary sobrevive a process death y falla cerrado', () {
    PreparedTurn turn(PreparedTurnRetryBoundary? boundary) => PreparedTurn(
      connectionId: 'c',
      sessionId: 's',
      clientTurnId: 't',
      createdAtMs: 1,
      updatedAtMs: 1,
      text: 'hola',
      attachments: const [],
      model: 'm',
      profile: '',
      retryBoundary: boundary,
    );
    for (final boundary in [
      PreparedTurnRetryBoundary.identity(messageId: 'u-1', rowId: 7),
      const PreparedTurnRetryBoundary.empty(),
      const PreparedTurnRetryBoundary.knownMissing(),
      const PreparedTurnRetryBoundary.unknown(),
    ]) {
      final restored = PreparedTurn.fromJson(turn(boundary).toJson());
      expect(restored.retryBoundary?.kind, boundary.kind);
      expect(restored.retryBoundary?.messageId, boundary.messageId);
      expect(restored.retryBoundary?.rowId, boundary.rowId);
    }
    expect(PreparedTurn.fromJson(turn(null).toJson()).retryBoundary, isNull);
    // Sin coordenada válida no hay identidad.
    expect(
      PreparedTurnRetryBoundary.identity(messageId: '', rowId: 0).kind,
      PreparedTurnRetryBoundaryKind.unknown,
    );
    final corrupt = turn(null).toJson()..['retry_boundary'] = 'x';
    expect(
      PreparedTurn.fromJson(corrupt).retryBoundary?.kind,
      PreparedTurnRetryBoundaryKind.unknown,
    );
    // copyWith conserva la frontera al cambiar de estado.
    final ambiguous = turn(
      const PreparedTurnRetryBoundary.empty(),
    ).copyWith(state: PreparedTurnState.ambiguous);
    expect(ambiguous.retryBoundary?.kind, PreparedTurnRetryBoundaryKind.empty);
  });

  test('la clave creada viaja en retry_boundary y es solo de '
      'knownMissing', () {
    PreparedTurn turn(PreparedTurnRetryBoundary? boundary) => PreparedTurn(
      connectionId: 'c',
      sessionId: 'mob-a5',
      clientTurnId: 't',
      createdAtMs: 1,
      updatedAtMs: 1,
      text: 'hola',
      attachments: const [],
      model: 'm',
      profile: '',
      retryBoundary: boundary,
    );
    final created = const PreparedTurnRetryBoundary.knownMissing()
        .withCreatedSessionId('20260925_101010_abcdef');
    final restored = PreparedTurn.fromJson(turn(created).toJson());
    expect(
      restored.retryBoundary?.kind,
      PreparedTurnRetryBoundaryKind.knownMissing,
    );
    expect(restored.retryBoundary?.createdSessionId, '20260925_101010_abcdef');
    // No se sobrescribe con otra clave ni se aplica a otras fronteras.
    expect(
      created.withCreatedSessionId('otra').createdSessionId,
      '20260925_101010_abcdef',
    );
    expect(
      const PreparedTurnRetryBoundary.empty()
          .withCreatedSessionId('x')
          .createdSessionId,
      isNull,
    );
    // Clave corrupta → knownMissing sin clave (el retry falla cerrado).
    final corrupt = turn(null).toJson()
      ..['retry_boundary'] = {'kind': 'knownMissing', 'created_session_id': 7};
    final degraded = PreparedTurn.fromJson(corrupt).retryBoundary;
    expect(degraded?.kind, PreparedTurnRetryBoundaryKind.knownMissing);
    expect(degraded?.createdSessionId, isNull);
  });
}
