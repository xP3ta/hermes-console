import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/session_artifact.dart';
import 'package:hermes_android/core/services/artifact_index.dart';

DesktopSessionMessage _message(Map<String, dynamic> json) =>
    DesktopSessionMessage.tryParse(json)!;

ArtifactIndexScope _scope({
  String connection = 'connection-a',
  String session = 'logical-session-a',
}) => ArtifactIndexScope(connectionId: connection, logicalSessionId: session);

ArtifactAuthorizationPolicy _policy({
  int revision = 0,
  Iterable<String> paths = const ['/managed'],
  Iterable<String> schemes = const ['hermes', 'https'],
  Iterable<String> hosts = const ['gateway.private'],
}) => ArtifactAuthorizationPolicy(
  revision: revision,
  allowedManagedPathPrefixes: paths,
  allowedManagedUriSchemes: schemes,
  allowedManagedHosts: hosts,
);

ArtifactTranscriptEntry _entry(
  DesktopSessionMessage message, {
  required int ordinal,
  int revision = 0,
  String? id,
}) => ArtifactTranscriptEntry(
  message: message,
  messageOrdinal: ordinal,
  messageRevision: revision,
  stableMessageId: id,
);

final class _ThrowingTranscript extends Iterable<ArtifactTranscriptEntry> {
  @override
  Iterator<ArtifactTranscriptEntry> get iterator =>
      throw StateError('unchanged transcript was scanned');
}

void main() {
  test(
    'conserva ID y contenedores estructurados top-level de forma acotada',
    () {
      final message = _message({
        'role': 'assistant',
        'message_id': 'message-top-level',
        'content': 'texto que no se indexa',
        'attachments': [
          {
            'attachment_id': 'attachment-top-level',
            'type': 'file',
            'name': 'report.txt',
          },
        ],
        'unrelated_payload': {'secret': 'discarded'},
      });

      expect(message.stableId, 'message-top-level');
      expect(message.artifactContainers.keys, ['attachments']);
      expect(message.raw, isNot(contains('message_id')));
      expect(message.raw, isNot(contains('unrelated_payload')));

      final snapshot = ArtifactIndex.resolve(
        scope: _scope(),
        transcriptRevision: 1,
        transcript: [_entry(message, ordinal: 0)],
        policy: _policy(),
      );

      expect(snapshot.artifacts.single.id, 'attachment-top-level');
      expect(
        snapshot.artifacts.single.primarySource.messageId,
        'message-top-level',
      );
    },
  );

  test('conserva juntas las coordenadas tipadas de la fuente', () {
    final message = _message({
      'role': 'assistant',
      'message_id': 'message-row-artifact',
      'row_id': 74,
      'content': 'resultado',
      'attachments': [
        {'attachment_id': 'attachment-row', 'name': 'row.txt'},
      ],
    });

    final snapshot = ArtifactIndex.resolve(
      scope: _scope(),
      transcriptRevision: 1,
      transcript: [_entry(message, ordinal: 5)],
      policy: _policy(),
    );

    expect(
      snapshot.artifacts.single.primarySource.messageId,
      'message-row-artifact',
    );
    expect(snapshot.artifacts.single.primarySource.rowId, 74);
  });

  test('row id mantiene estable el artefacto aunque cambie el ordinal', () {
    final message = _message({
      'role': 'assistant',
      'row_id': 74,
      'content': [
        {'type': 'file', 'name': 'stable-row.txt'},
      ],
    });

    final before = ArtifactIndex.resolve(
      scope: _scope(),
      transcriptRevision: 1,
      transcript: [_entry(message, ordinal: 0)],
      policy: _policy(),
    );
    final after = ArtifactIndex.resolve(
      scope: _scope(),
      transcriptRevision: 2,
      transcript: [_entry(message, ordinal: 99, revision: 1)],
      policy: _policy(),
    );

    expect(after.artifacts.single.id, before.artifacts.single.id);
  });

  test('indexa un adjunto estructurado y nunca escanea el texto', () {
    final message = _message({
      'role': 'user',
      'message_id': 'message-1',
      'content': [
        {
          'type': 'text',
          'text':
              'No autorizar /private/fake.txt ni https://evil.example/file.pdf',
        },
        {
          'attachment_id': 'attachment-1',
          'type': 'attachment',
          'name': '../../photo.png',
          'mime_type': 'image/png',
          'size_bytes': 2048,
          'managed_path': '/managed/images/photo.png',
          'remote': true,
          'availability': 'ready',
          'created_at': '2026-07-20T12:00:00Z',
        },
      ],
    });

    final entry = _entry(message, ordinal: 4, id: 'message-1');
    expect(entry.message.content.toString(), isNot(contains('No autorizar')));
    expect(entry.message.content.toString(), isNot(contains('evil.example')));

    final snapshot = ArtifactIndex.resolve(
      scope: _scope(),
      transcriptRevision: 1,
      transcript: [entry],
      policy: _policy(),
    );

    expect(snapshot.artifacts, hasLength(1));
    final artifact = snapshot.artifacts.single;
    expect(artifact.id, 'attachment-1');
    expect(artifact.serverId, 'attachment-1');
    expect(artifact.kind, SessionArtifactKind.image);
    expect(artifact.displayName, 'photo.png');
    expect(artifact.mimeType, 'image/png');
    expect(artifact.sizeBytes, 2048);
    expect(artifact.managedReference, '/managed/images/photo.png');
    expect(artifact.remote, isTrue);
    expect(artifact.availability, SessionArtifactAvailability.ready);
    expect(artifact.createdAt, DateTime.utc(2026, 7, 20, 12));
    expect(
      artifact.primarySource,
      const SessionArtifactSource(messageId: 'message-1', messageOrdinal: 4),
    );
  });

  test('ignora Markdown, URLs, rutas y JSON serializado como texto', () {
    final assistant = _message({
      'role': 'assistant',
      'content':
          '![fake](/managed/fake.png) [file](https://gateway.private/a.pdf)',
      'tool_calls': [
        {
          'name': 'write_file',
          'arguments': {'path': '/managed/from-tool-arguments.txt'},
        },
      ],
    });
    final tool = _message({
      'role': 'tool',
      'content': '{"type":"file","managed_path":"/managed/fake-result.txt"}',
      'context': 'wrote /managed/commentary.txt',
    });

    final snapshot = ArtifactIndex.resolve(
      scope: _scope(),
      transcriptRevision: 1,
      transcript: [_entry(assistant, ordinal: 0), _entry(tool, ordinal: 1)],
      policy: _policy(),
    );

    expect(snapshot.artifacts, isEmpty);
    expect(snapshot.buildStats.inspectedMessages, 2);
    expect(snapshot.buildStats.candidateCount, 0);
  });

  test('acepta solo tool results estructurados con tipo explícito', () {
    final typed = _message({
      'role': 'tool',
      'content': {
        'type': 'file',
        'artifact_id': 'tool-file-1',
        'name': 'report.pdf',
        'mime_type': 'application/pdf',
        'managed_path': '/managed/results/report.pdf',
      },
    });
    final untyped = _message({
      'role': 'tool',
      'content': {
        'output_path': '/managed/results/not-authorized.pdf',
        'name': 'not-authorized.pdf',
      },
    });
    final typedRawResult = _message({
      'role': 'tool',
      'content': 'safe summary',
      'context': {
        'type': 'image',
        'artifact_id': 'tool-image-1',
        'name': 'chart.png',
        'managed_path': '/managed/results/chart.png',
      },
    });
    final typedEnvelope = _message({
      'role': 'tool',
      'content': {
        'type': 'tool_result',
        'result': {
          'type': 'document',
          'artifact_id': 'tool-document-1',
          'name': 'notes.md',
          'managed_path': '/managed/results/notes.md',
        },
      },
    });

    final snapshot = ArtifactIndex.resolve(
      scope: _scope(),
      transcriptRevision: 1,
      transcript: [
        _entry(typed, ordinal: 0),
        _entry(untyped, ordinal: 1),
        _entry(typedRawResult, ordinal: 2),
        _entry(typedEnvelope, ordinal: 3),
      ],
      policy: _policy(),
    );

    expect(snapshot.artifacts.map((item) => item.id), [
      'tool-file-1',
      'tool-image-1',
      'tool-document-1',
    ]);
    expect(snapshot.artifacts.first.kind, SessionArtifactKind.file);
    expect(snapshot.artifacts[1].kind, SessionArtifactKind.image);
    expect(snapshot.artifacts.last.kind, SessionArtifactKind.document);
  });

  test('normaliza generated images solo bajo política administrada', () {
    final message = _message({
      'role': 'assistant',
      'content': [
        {
          'type': 'generated_image',
          'id': 'generated-1',
          'name': 'render.png',
          'managed_uri': 'hermes://artifacts/generated-1',
        },
        {
          'type': 'generated_image',
          'id': 'generated-2',
          'name': 'signed.png',
          'managed_url':
              'https://gateway.private/artifacts/generated-2?token=secret',
        },
      ],
    });

    final snapshot = ArtifactIndex.resolve(
      scope: _scope(),
      transcriptRevision: 1,
      transcript: [_entry(message, ordinal: 0)],
      policy: _policy(hosts: const ['artifacts', 'gateway.private']),
    );

    expect(snapshot.artifacts, hasLength(2));
    expect(snapshot.artifacts[0].kind, SessionArtifactKind.generated);
    expect(
      snapshot.artifacts[0].managedReference,
      'hermes://artifacts/generated-1',
    );
    expect(snapshot.artifacts[1].managedReference, isNull);
    expect(snapshot.toString(), isNot(contains('token=secret')));
  });

  test('deduplica server ID conservando todas las fuentes', () {
    DesktopSessionMessage withAttachment(String messageId) => _message({
      'role': 'assistant',
      'message_id': messageId,
      'content': [
        {
          'attachment_id': 'shared-artifact',
          'type': 'document',
          'name': 'shared.pdf',
        },
      ],
    });

    final snapshot = ArtifactIndex.resolve(
      scope: _scope(),
      transcriptRevision: 1,
      transcript: [
        _entry(withAttachment('message-a'), ordinal: 2, id: 'message-a'),
        _entry(withAttachment('message-b'), ordinal: 5, id: 'message-b'),
      ],
      policy: _policy(),
    );

    expect(snapshot.artifacts, hasLength(1));
    expect(snapshot.artifacts.single.sources, [
      const SessionArtifactSource(messageId: 'message-a', messageOrdinal: 2),
      const SessionArtifactSource(messageId: 'message-b', messageOrdinal: 5),
    ]);
  });

  test('deduplica referencia administrada sin ID y conserva fuentes', () {
    DesktopSessionMessage withManagedReference(String messageId) => _message({
      'role': 'assistant',
      'message_id': messageId,
      'content': [
        {
          'type': 'document',
          'name': 'shared.pdf',
          'mime_type': 'application/pdf',
          'managed_uri': 'hermes:artifacts/shared.pdf',
        },
      ],
    });

    final snapshot = ArtifactIndex.resolve(
      scope: _scope(),
      transcriptRevision: 1,
      transcript: [
        _entry(withManagedReference('message-a'), ordinal: 2, id: 'message-a'),
        _entry(withManagedReference('message-b'), ordinal: 5, id: 'message-b'),
      ],
      policy: _policy(),
    );

    expect(snapshot.artifacts, hasLength(1));
    expect(snapshot.artifacts.single.sources, [
      const SessionArtifactSource(messageId: 'message-a', messageOrdinal: 2),
      const SessionArtifactSource(messageId: 'message-b', messageOrdinal: 5),
    ]);
  });

  test('una ruta mutable sin ID permanece separada por fuente', () {
    DesktopSessionMessage version(String messageId, int size) => _message({
      'role': 'assistant',
      'message_id': messageId,
      'content': [
        {
          'type': 'file',
          'name': 'mutable.txt',
          'size_bytes': size,
          'managed_path': '/managed/mutable.txt',
        },
      ],
    });

    final snapshot = ArtifactIndex.resolve(
      scope: _scope(),
      transcriptRevision: 1,
      transcript: [
        _entry(version('message-a', 10), ordinal: 1, id: 'message-a'),
        _entry(version('message-b', 20), ordinal: 4, id: 'message-b'),
      ],
      policy: _policy(),
    );

    expect(snapshot.artifacts, hasLength(2));
    expect(snapshot.artifacts.map((artifact) => artifact.sizeBytes), [10, 20]);
  });

  test('una repetición posterior actualiza estado y completa metadatos', () {
    DesktopSessionMessage version({
      required String messageId,
      required String availability,
      String? name,
      String? mimeType,
    }) => _message({
      'role': 'assistant',
      'message_id': messageId,
      'content': [
        {
          'artifact_id': 'changing-artifact',
          'type': 'artifact',
          'name': ?name,
          'mime_type': ?mimeType,
          'availability': availability,
        },
      ],
    });

    final snapshot = ArtifactIndex.resolve(
      scope: _scope(),
      transcriptRevision: 1,
      transcript: [
        _entry(
          version(messageId: 'message-a', availability: 'ready'),
          ordinal: 1,
          id: 'message-a',
        ),
        _entry(
          version(
            messageId: 'message-b',
            availability: 'expired',
            name: 'final-report.pdf',
            mimeType: 'application/pdf',
          ),
          ordinal: 5,
          id: 'message-b',
        ),
      ],
      policy: _policy(),
    );

    final artifact = snapshot.artifacts.single;
    expect(artifact.sources, hasLength(2));
    expect(artifact.availability, SessionArtifactAvailability.expired);
    expect(artifact.displayName, 'final-report.pdf');
    expect(artifact.mimeType, 'application/pdf');
    expect(artifact.kind, SessionArtifactKind.document);
  });

  test('mismo nombre sin ID permanece separado por mensaje', () {
    DesktopSessionMessage attachment() => _message({
      'role': 'assistant',
      'content': [
        {'type': 'file', 'name': 'same.txt', 'mime_type': 'text/plain'},
      ],
    });

    final snapshot = ArtifactIndex.resolve(
      scope: _scope(),
      transcriptRevision: 1,
      transcript: [
        _entry(attachment(), ordinal: 0, id: 'message-a'),
        _entry(attachment(), ordinal: 1, id: 'message-b'),
      ],
      policy: _policy(),
    );

    expect(snapshot.artifacts, hasLength(2));
    expect(snapshot.artifacts[0].displayName, 'same.txt');
    expect(snapshot.artifacts[1].displayName, 'same.txt');
    expect(snapshot.artifacts[0].id, isNot(snapshot.artifacts[1].id));
  });

  test('acota nombre, MIME, tamaño y rechaza traversal administrado', () {
    final longName = '${'x' * 220}.txt';
    final message = _message({
      'role': 'assistant',
      'content': [
        {
          'type': 'artifact',
          'name': '../../$longName',
          'mime_type': 'not a mime',
          'size_bytes': 1 << 50,
          'managed_path': '/managed/../private/secret.txt',
          'availability': 'expired',
        },
      ],
    });

    final snapshot = ArtifactIndex.resolve(
      scope: _scope(),
      transcriptRevision: 1,
      transcript: [_entry(message, ordinal: 0)],
      policy: _policy(),
    );

    final artifact = snapshot.artifacts.single;
    expect(artifact.kind, SessionArtifactKind.unknown);
    expect(artifact.displayName.runes.length, 160);
    expect(artifact.displayName, isNot(contains('/')));
    expect(artifact.mimeType, isNull);
    expect(artifact.sizeBytes, isNull);
    expect(artifact.managedReference, isNull);
    expect(artifact.availability, SessionArtifactAvailability.expired);
  });

  test('reabrir la misma revisión no itera ni reconstruye', () {
    final message = _message({
      'role': 'assistant',
      'content': [
        {'attachment_id': 'cached-1', 'type': 'file', 'name': 'cached.txt'},
      ],
    });
    final first = ArtifactIndex.resolve(
      scope: _scope(),
      transcriptRevision: 7,
      transcript: [_entry(message, ordinal: 0)],
      policy: _policy(),
    );

    final reopened = ArtifactIndex.resolve(
      previous: first,
      scope: _scope(),
      transcriptRevision: 7,
      transcript: _ThrowingTranscript(),
      policy: _policy(),
    );

    expect(identical(reopened, first), isTrue);
    expect(reopened.buildStats.inspectedMessages, 1);
  });

  test('revisión nueva reutiliza mensajes intactos e inspecciona cambios', () {
    DesktopSessionMessage artifact(String id, String name) => _message({
      'role': 'assistant',
      'content': [
        {'attachment_id': id, 'type': 'file', 'name': name},
      ],
    });

    final a = artifact('artifact-a', 'a.txt');
    final b = artifact('artifact-b', 'b.txt');
    final first = ArtifactIndex.resolve(
      scope: _scope(),
      transcriptRevision: 1,
      transcript: [
        _entry(a, ordinal: 0, revision: 0, id: 'message-a'),
        _entry(b, ordinal: 1, revision: 0, id: 'message-b'),
      ],
      policy: _policy(),
    );

    final second = ArtifactIndex.resolve(
      previous: first,
      scope: _scope(),
      transcriptRevision: 2,
      transcript: [
        _entry(a, ordinal: 0, revision: 0, id: 'message-a'),
        _entry(
          artifact('artifact-b2', 'b2.txt'),
          ordinal: 1,
          revision: 1,
          id: 'message-b',
        ),
        _entry(
          artifact('artifact-c', 'c.txt'),
          ordinal: 2,
          revision: 0,
          id: 'message-c',
        ),
      ],
      policy: _policy(),
    );

    expect(second.buildStats.reusedMessages, 1);
    expect(second.buildStats.inspectedMessages, 2);
    expect(second.artifacts.map((item) => item.id), [
      'artifact-a',
      'artifact-b2',
      'artifact-c',
    ]);
  });

  test('policy, connection o transcript replacement invalidan la caché', () {
    final message = _message({
      'role': 'assistant',
      'content': [
        {
          'attachment_id': 'artifact-1',
          'type': 'file',
          'name': 'one.txt',
          'managed_path': '/managed/one.txt',
        },
      ],
    });
    final entry = _entry(message, ordinal: 0, id: 'message-a');
    final first = ArtifactIndex.resolve(
      scope: _scope(),
      transcriptRevision: 3,
      transcript: [entry],
      policy: _policy(revision: 0),
    );

    final policyChanged = ArtifactIndex.resolve(
      previous: first,
      scope: _scope(),
      transcriptRevision: 3,
      transcript: [entry],
      policy: _policy(revision: 1, paths: const []),
    );
    expect(policyChanged.buildStats.inspectedMessages, 1);
    expect(policyChanged.buildStats.reusedMessages, 0);
    expect(policyChanged.artifacts.single.managedReference, isNull);

    final connectionChanged = ArtifactIndex.resolve(
      previous: policyChanged,
      scope: _scope(connection: 'connection-b'),
      transcriptRevision: 3,
      transcript: [entry],
      policy: _policy(revision: 1, paths: const []),
    );
    expect(connectionChanged.buildStats.inspectedMessages, 1);

    final replacement = ArtifactIndex.resolve(
      previous: connectionChanged,
      scope: _scope(connection: 'connection-b'),
      transcriptRevision: 1,
      transcript: [entry],
      policy: _policy(revision: 1, paths: const []),
    );
    expect(replacement.buildStats.inspectedMessages, 1);
    expect(replacement.buildStats.reusedMessages, 0);
  });

  test('ordena determinísticamente por ordinal, no por orden de entrada', () {
    DesktopSessionMessage artifact(String id) => _message({
      'role': 'assistant',
      'content': [
        {'attachment_id': id, 'type': 'file', 'name': '$id.txt'},
      ],
    });

    final snapshot = ArtifactIndex.resolve(
      scope: _scope(),
      transcriptRevision: 1,
      transcript: [
        _entry(artifact('third'), ordinal: 3),
        _entry(artifact('first'), ordinal: 1),
        _entry(artifact('second'), ordinal: 2),
      ],
      policy: _policy(),
    );

    expect(snapshot.artifacts.map((item) => item.id), [
      'first',
      'second',
      'third',
    ]);
  });
}
