// How «Artefactos» fetches an item, as Hermes Desktop does
// (`downloadGatewayMediaFile` → `/api/fs/download?path=…&session_id=…`), and
// the reason it gives when it cannot.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/artifact_media.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/generated_media_service.dart';

final _connection = SavedConnection(
  id: 'fetch-test',
  label: 'Fetch QA',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-only',
);

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
  '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

ArtifactFetchProblem? _problemOf(String value) {
  try {
    artifactReferenceOrThrow(value);
    return null;
  } on ArtifactFetchFailure catch (failure) {
    return failure.problem;
  }
}

void main() {
  late Directory cache;
  setUp(() => cache = Directory.systemTemp.createTempSync('artifact-fetch-'));
  tearDown(() => cache.deleteSync(recursive: true));

  group('what the app fetches (Desktop path forms)', () {
    test('paths in every form Desktop sends to the gateway', () {
      for (final value in [
        '/home/u/out/informe.pdf',
        'screen-ready.png',
        './out/plot.png',
        '../shared/notes.md',
        '~/proyectos/q3/ventas.csv',
        'file:///tmp/a%20b/foto.jpg',
        r'C:\Users\u\out\report.docx',
      ]) {
        final reference = GeneratedMediaService.artifactReference(value);
        expect(reference, isNotNull, reason: value);
        expect(reference!.source, value);
        expect(reference.sourceKind, GeneratedMediaSourceKind.serverPath);
      }
      expect(
        GeneratedMediaService.artifactReference('screen-ready.png')!.kind,
        GeneratedMediaKind.image,
      );
    });

    test('https as the chat takes it; the rest says why not', () {
      final logo = GeneratedMediaService.artifactReference(
        'https://github.com/hermes/console/raw/main/logo.png',
      );
      expect(logo?.sourceKind, GeneratedMediaSourceKind.https);
      expect(logo?.kind, GeneratedMediaKind.image);
      expect(
        _problemOf('http://example.com/a.png'),
        ArtifactFetchProblem.insecure,
      );
      for (final value in [
        'ftp://example.com/a.png',
        'https://example.com/a.png?token=secret',
        '/home/u/.env',
        '~/.ssh/id_ed25519',
        'data:image/png;base64,AAAA',
      ]) {
        expect(
          _problemOf(value),
          ArtifactFetchProblem.unsupported,
          reason: value,
        );
      }
    });
  });

  group('fetchArtifactMedia', () {
    Future<File> fetch(
      String value, {
      String? sessionId,
      required Future<void> Function(Uri request, File destination) server,
    }) => fetchArtifactMedia(
      connection: _connection,
      owner: ArtifactOwner(profile: 'work', sessionId: sessionId),
      reference: artifactReferenceOrThrow(value),
      fetchServerPath: server,
      baseDir: cache,
    );

    test('a relative path goes with its conversation, as Desktop', () async {
      final requests = <Uri>[];
      final file = await fetch(
        'screen-ready.png',
        sessionId: 'sess-1',
        server: (request, destination) async {
          requests.add(request);
          await destination.writeAsBytes(_png);
        },
      );
      expect(requests.single.path, 'fs/download');
      expect(requests.single.queryParameters, {
        'path': 'screen-ready.png',
        'session_id': 'sess-1',
      });
      expect(await file.readAsBytes(), _png);
    });

    test('a relative path without a conversation is not asked', () async {
      final requests = <Uri>[];
      await expectLater(
        fetch(
          'screen-ready.png',
          server: (request, _) async => requests.add(request),
        ),
        throwsA(
          isA<ArtifactFetchFailure>().having(
            (f) => f.problem,
            'problem',
            ArtifactFetchProblem.noFolder,
          ),
        ),
      );
      expect(requests, isEmpty);
    });

    test('~ and absolute paths need no conversation', () async {
      final requests = <Uri>[];
      for (final value in ['~/out/a.png', '/srv/out/b.png']) {
        await fetch(
          value,
          server: (request, destination) async {
            requests.add(request);
            await destination.writeAsBytes(_png);
          },
        );
      }
      expect(requests.map((r) => r.queryParameters), [
        {'path': '~/out/a.png'},
        {'path': '/srv/out/b.png'},
      ]);
    });

    test('the server\'s answer becomes the reason', () async {
      final cases = <Object, ArtifactFetchProblem>{
        const DashboardHttpException(404): ArtifactFetchProblem.notFound,
        const DashboardNotAFileException(): ArtifactFetchProblem.notFound,
        const DashboardHttpException(403): ArtifactFetchProblem.denied,
        const DashboardHttpException(413): ArtifactFetchProblem.tooLarge,
        const DashboardHttpException(
          400,
          body: '{"detail":"Session working directory is unavailable"}',
        ): ArtifactFetchProblem.noFolder,
        const DashboardHttpException(400): ArtifactFetchProblem.unsupported,
        // R5C C-V1: Hermes down or failing says so, not «Sin vista previa».
        const DashboardHttpException(502): ArtifactFetchProblem.unreachable,
        const DashboardHttpException(503): ArtifactFetchProblem.unreachable,
        const DashboardHttpException(504): ArtifactFetchProblem.timedOut,
        const SocketException('refused'): ArtifactFetchProblem.unreachable,
        TimeoutException('slow'): ArtifactFetchProblem.timedOut,
        const FormatException('generated media signature is invalid'):
            ArtifactFetchProblem.notImage,
        StateError('Dashboard download exceeds 26214400 bytes'):
            ArtifactFetchProblem.tooLarge,
      };
      var n = 0;
      for (final MapEntry(key: error, value: problem) in cases.entries) {
        await expectLater(
          fetch(
            'out/missing-${n++}.png',
            sessionId: 'sess-1',
            server: (_, _) async => throw error,
          ),
          throwsA(
            isA<ArtifactFetchFailure>().having(
              (f) => f.problem,
              'problem',
              problem,
            ),
          ),
          reason: '$error',
        );
      }
    });

    test('a blank conversation id is not sent', () async {
      final requests = <Uri>[];
      await fetch(
        '/srv/out/b.png',
        sessionId: '  ',
        server: (request, destination) async {
          requests.add(request);
          await destination.writeAsBytes(_png);
        },
      );
      expect(requests.single.queryParameters, {'path': '/srv/out/b.png'});
    });

    test('the same relative name in two conversations is two files', () async {
      final asked = <String?>[];
      for (final session in ['a', 'b']) {
        await fetch(
          'plot.png',
          sessionId: session,
          server: (request, destination) async {
            asked.add(request.queryParameters['session_id']);
            await destination.writeAsBytes(_png);
          },
        );
      }
      expect(asked, ['a', 'b']);
    });
  });

  group('artifactFetchProblemOf', () {
    test('a picture from another host that is too large says so', () {
      // R5C C-V2: the media cache throws HttpException for it.
      expect(
        artifactFetchProblemOf(
          const HttpException('generated media is too large'),
          https: true,
        ),
        ArtifactFetchProblem.tooLarge,
      );
      expect(
        artifactFetchProblemOf(
          const HttpException('media download failed (404)'),
          https: true,
        ),
        ArtifactFetchProblem.remote,
      );
    });

    test('a broken connection is Hermes out of reach, or the host', () {
      expect(
        artifactFetchProblemOf(const SocketException('x'), https: false),
        ArtifactFetchProblem.unreachable,
      );
      expect(
        artifactFetchProblemOf(const SocketException('x'), https: true),
        ArtifactFetchProblem.remote,
      );
      expect(
        artifactFetchProblemOf(TimeoutException('x'), https: true),
        ArtifactFetchProblem.timedOut,
      );
    });
  });
}
