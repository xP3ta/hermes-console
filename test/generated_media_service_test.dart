import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/generated_media_service.dart';

void main() {
  group('GeneratedMediaService.parseSegments', () {
    test('extracts successful producer tool results only', () {
      final local = GeneratedMediaService.referencesFromToolResult(
        'video_generate',
        '{"success":true,"video":"/home/hermes/.hermes/cache/videos/clip.mp4"}',
      );
      final remote = GeneratedMediaService.referencesFromToolResult(
        'video_generate',
        const {
          'success': true,
          'video': 'https://cdn.example/generated.webm?download=1#fragment',
        },
      );
      final image = GeneratedMediaService.referencesFromToolResult(
        'image_generate',
        const {
          'success': true,
          'host_image': '/home/hermes/.hermes/cache/images/host.png',
          'image': '/workspace/sandbox.png',
          'agent_visible_image': '/container/private.png',
        },
      );
      final failed = GeneratedMediaService.referencesFromToolResult(
        'video_generate',
        const {'success': false, 'video': '/home/hermes/failed.mp4'},
      );
      final unrelated = GeneratedMediaService.referencesFromToolResult(
        'terminal',
        const {'success': true, 'video': '/home/hermes/not-a-producer.mp4'},
      );

      expect(local, hasLength(1));
      expect(local.single.kind, GeneratedMediaKind.video);
      expect(local.single.sourceKind, GeneratedMediaSourceKind.serverPath);
      expect(remote, hasLength(1));
      expect(remote.single.sourceKind, GeneratedMediaSourceKind.https);
      expect(remote.single.source, isNot(contains('#')));
      expect(image, hasLength(1));
      expect(image.single.kind, GeneratedMediaKind.image);
      expect(image.single.source, endsWith('/host.png'));
      expect(failed, isEmpty);
      expect(unrelated, isEmpty);
    });

    test('extracts standalone generated image and video MEDIA directives', () {
      final segments = GeneratedMediaService.parseSegments(
        'Antes\nMEDIA:/home/hermes/render/final frame.png\n'
        'MEDIA:"/home/hermes/render/final clip.mp4"\nDespués',
      );

      expect(segments, hasLength(5));
      expect((segments[0] as GeneratedMediaTextSegment).text, 'Antes\n');
      final image = (segments[1] as GeneratedMediaFileSegment).reference;
      expect(image.kind, GeneratedMediaKind.image);
      expect(image.source, '/home/hermes/render/final frame.png');
      expect((segments[2] as GeneratedMediaTextSegment).text, '\n');
      final video = (segments[3] as GeneratedMediaFileSegment).reference;
      expect(video.kind, GeneratedMediaKind.video);
      expect(video.source, '/home/hermes/render/final clip.mp4');
      expect((segments[4] as GeneratedMediaTextSegment).text, '\nDespués');
    });

    test(
      'supports HTTPS MEDIA links but rejects insecure and unknown media',
      () {
        final segments = GeneratedMediaService.parseSegments(
          'MEDIA:https://example.test/output.webm?download=1\n'
          'MEDIA:http://example.test/private.mp4\n'
          'MEDIA:/home/hermes/private.env',
        );

        expect(segments.whereType<GeneratedMediaFileSegment>(), hasLength(1));
        final media = segments
            .whereType<GeneratedMediaFileSegment>()
            .single
            .reference;
        expect(media.kind, GeneratedMediaKind.video);
        expect(media.sourceKind, GeneratedMediaSourceKind.https);
        final text = segments
            .whereType<GeneratedMediaTextSegment>()
            .map((e) => e.text)
            .join();
        expect(text, isNot(contains('MEDIA:http://example.test/private.mp4')));
        expect(text, isNot(contains('MEDIA:/home/hermes/private.env')));
      },
    );

    test('does not execute MEDIA examples inside fenced code', () {
      final segments = GeneratedMediaService.parseSegments(
        '```text\nMEDIA:/home/hermes/output.mp4\n```',
      );
      expect(segments.whereType<GeneratedMediaFileSegment>(), isEmpty);
      expect(
        (segments.single as GeneratedMediaTextSegment).text,
        contains('MEDIA:'),
      );
    });

    test('a different fence marker cannot close the active fence', () {
      final segments = GeneratedMediaService.parseSegments(
        '```text\n~~~\nMEDIA:/home/hermes/hidden.mp4\n```\n'
        'MEDIA:/home/hermes/visible.mp4',
      );
      final media = segments.whereType<GeneratedMediaFileSegment>().toList();
      expect(media, hasLength(1));
      expect(media.single.reference.source, '/home/hermes/visible.mp4');
    });

    test('rejects traversal, ambiguous and encoded traversal server paths', () {
      for (final source in <String>[
        '/home/hermes/../private.mp4',
        '/home/hermes//private.mp4',
        '/home/hermes/%2e%2e/private.mp4',
        '/home/hermes/private.mp4?token=secret',
        '/home/hermes/private.mp4#fragment',
      ]) {
        final segments = GeneratedMediaService.parseSegments('MEDIA:$source');
        expect(
          segments.whereType<GeneratedMediaFileSegment>(),
          isEmpty,
          reason: source,
        );
      }
    });

    test(
      'stripDirectives preserves prose and withholds paths and signed URLs',
      () {
        const path = '/home/hermes/workspace/private.mp4';
        const url = 'https://media.example/private.webp?token=secret';
        final stripped = GeneratedMediaService.stripDirectives(
          'Antes\nMEDIA:$path\nMEDIA:$url\nDespués',
        );
        expect(stripped, contains('Antes'));
        expect(stripped, contains('Después'));
        expect(stripped, isNot(contains(path)));
        expect(stripped, isNot(contains('token=secret')));
      },
    );

    test('preserves repeated references as separate legitimate media', () {
      final segments = GeneratedMediaService.parseSegments(
        'MEDIA:/home/hermes/a.png\nMEDIA:/home/hermes/a.png',
      );
      expect(segments.whereType<GeneratedMediaFileSegment>(), hasLength(2));
    });

    test('preserves document, audio, and unknown safe files', () {
      final document = GeneratedMediaService.parseSegments(
        'MEDIA:/workspace/report.txt',
      );
      final audio = GeneratedMediaService.parseSegments(
        'MEDIA:/workspace/voice.flac',
      );
      final unknown = GeneratedMediaService.parseSegments(
        'MEDIA:/workspace/result.custom',
      );

      expect(document.whereType<GeneratedMediaFileSegment>(), hasLength(1));
      expect(
        document.whereType<GeneratedMediaFileSegment>().single.reference.kind.name,
        'file',
      );
      expect(audio.whereType<GeneratedMediaFileSegment>(), hasLength(1));
      expect(
        audio.whereType<GeneratedMediaFileSegment>().single.reference.kind.name,
        'audio',
      );
      expect(unknown.whereType<GeneratedMediaFileSegment>(), hasLength(1));
      expect(
        unknown.whereType<GeneratedMediaFileSegment>().single.reference.kind.name,
        'file',
      );
    });

    test('keeps prose around a document directive', () {
      final segments = GeneratedMediaService.parseSegments(
        'Your report is ready.\nMEDIA:/workspace/report.pdf\nOpen it below.',
      );

      expect(segments.whereType<GeneratedMediaFileSegment>(), hasLength(1));
      final text = segments
          .whereType<GeneratedMediaTextSegment>()
          .map((segment) => segment.text)
          .join();
      expect(text, contains('Your report is ready.'));
      expect(text, contains('Open it below.'));
      expect(text, isNot(contains('/workspace/report.pdf')));
    });

    test('unsafe directives stay non-fetching and never reveal their source', () {
      const unsafe = <String>[
        'MEDIA:https://user:password@example.test/report.pdf',
        'MEDIA:file:///workspace/report.pdf',
        'MEDIA:/workspace/../private/report.pdf',
        'MEDIA:/workspace/key.properties',
        'MEDIA:/workspace/.env',
        'MEDIA:/workspace/%2Eenv',
      ];

      for (final directive in unsafe) {
        final segments = GeneratedMediaService.parseSegments(directive);
        expect(
          segments.whereType<GeneratedMediaFileSegment>(),
          isEmpty,
          reason: directive,
        );
        expect(
          GeneratedMediaService.stripDirectives(directive),
          isNot(contains(directive.substring('MEDIA:'.length))),
          reason: directive,
        );
      }
    });

    test('rejects credential, key, history, and sensitive-directory paths', () {
      const blocked = <String>[
        '/home/user/.netrc',
        '/home/user/.NPMRC',
        '/home/user/.pgpass',
        '/home/user/.git-credentials',
        '/home/user/.ssh/id_rsa',
        '/home/user/.ssh/id_dsa',
        '/home/user/.ssh/id_ecdsa',
        '/home/user/.ssh/id_ed25519',
        '/home/user/.ssh/id_custom',
        '/home/user/.ssh/authorized_keys',
        '/home/user/.ssh/config',
        '/home/user/.ssh/.private-note',
        '/home/user/.ssh/.public.pub',
        '/home/user/.gnupg/private-keys-v1.d/key',
        '/home/user/.aws/credentials',
        '/home/user/.aws/config',
        '/home/user/.docker/config.json',
        '/home/user/.kube/config',
        '/home/user/.azure/accessTokens.json',
        '/home/user/.gcloud/credentials.db',
        '/home/user/.config/gcloud/credentials.db',
        '/home/user/.bash_history',
        '/home/user/.zsh_history',
        '/home/user/.python_history',
        '/home/user/.psql_history',
        '/workspace/client.pem',
        '/workspace/client.key',
        '/workspace/client.p12',
        '/workspace/client.pfx',
        '/workspace/client.jks',
        '/workspace/client.keystore',
        '/workspace/tunnel.ovpn',
        '/proc/self/environ',
        '/sys/kernel/security/lsm',
        '/dev/mapper/control',
      ];

      for (final source in blocked) {
        expect(
          GeneratedMediaService.referenceFromSource(source),
          isNull,
          reason: source,
        );
      }
    });

    test('allows public SSH metadata and ordinary generated media', () {
      const allowed = <String>[
        '/home/user/.ssh/known_hosts',
        '/home/user/.ssh/id_ed25519.pub',
        '/workspace/proc/report.txt',
        '/workspace/render.png',
        '/workspace/photo.jpg',
        '/workspace/audio.wav',
        '/workspace/video.mp4',
        '/workspace/report.pdf',
        '/workspace/notes.txt',
        '/workspace/data.json',
      ];

      for (final source in allowed) {
        final reference = GeneratedMediaService.referenceFromSource(source);
        expect(reference, isNotNull, reason: source);
        expect(
          GeneratedMediaService.allowsAutoLoad(reference!),
          isTrue,
          reason: source,
        );
      }
    });

    test('executable and installer files require explicit download', () {
      for (final extension in const ['.apk', '.exe', '.msi', '.dmg', '.sh']) {
        final reference = GeneratedMediaService.referenceFromSource(
          '/workspace/payload$extension',
        );
        expect(reference, isNotNull, reason: extension);
        final safeReference = reference!;
        expect(
          GeneratedMediaService.allowsAutoLoad(safeReference),
          isFalse,
          reason: extension,
        );
        expect(
          GeneratedMediaService.isTextLike(safeReference),
          isFalse,
          reason: extension,
        );
      }
    });
  });

  group('GeneratedMediaService.validateBytes', () {
    test('accepts MP4 and WebM signatures for video', () {
      final mp4 = Uint8List.fromList(<int>[
        0,
        0,
        0,
        24,
        0x66,
        0x74,
        0x79,
        0x70,
        0x69,
        0x73,
        0x6f,
        0x6d,
      ]);
      final webm = Uint8List.fromList(<int>[
        0x1a,
        0x45,
        0xdf,
        0xa3,
        0,
        0,
        0,
        0,
      ]);
      expect(
        GeneratedMediaService.validateBytes(mp4, GeneratedMediaKind.video),
        isTrue,
      );
      expect(
        GeneratedMediaService.validateBytes(webm, GeneratedMediaKind.video),
        isTrue,
      );
    });

    test('rejects arbitrary bytes labelled as video', () {
      expect(
        GeneratedMediaService.validateBytes(
          Uint8List.fromList('not a video'.codeUnits),
          GeneratedMediaKind.video,
        ),
        isFalse,
      );
    });
  });

  group('GeneratedMediaService.ensureDownloaded', () {
    late Directory temporary;

    setUp(() {
      temporary = Directory.systemTemp.createTempSync('generated_media_test');
    });

    tearDown(() {
      temporary.deleteSync(recursive: true);
    });

    test(
      'fetches an authenticated server path once and reuses private cache',
      () async {
        const reference = GeneratedMediaReference(
          source: '/home/hermes/workspace/generated.mp4',
          kind: GeneratedMediaKind.video,
          sourceKind: GeneratedMediaSourceKind.serverPath,
        );
        var calls = 0;
        Future<void> fetch(String path, File destination) async {
          calls++;
          expect(path, reference.source);
          await destination.writeAsBytes(<int>[
            0,
            0,
            0,
            24,
            0x66,
            0x74,
            0x79,
            0x70,
            0x69,
            0x73,
            0x6f,
            0x6d,
          ]);
        }

        final first = await GeneratedMediaService.ensureDownloaded(
          'connection-a',
          reference,
          fetchServerPathToFile: fetch,
          baseDir: temporary,
        );
        final second = await GeneratedMediaService.ensureDownloaded(
          'connection-a',
          reference,
          fetchServerPathToFile: fetch,
          baseDir: temporary,
        );

        expect(calls, 1);
        expect(second.path, first.path);
        expect(first.path, contains('generated_media'));
        expect(first.path, isNot(contains('/home/hermes/workspace')));
        expect(await first.exists(), isTrue);
      },
    );

    test(
      'invalid server bytes fail closed and leave no cached media',
      () async {
        const reference = GeneratedMediaReference(
          source: '/home/hermes/workspace/fake.mp4',
          kind: GeneratedMediaKind.video,
          sourceKind: GeneratedMediaSourceKind.serverPath,
        );
        await expectLater(
          GeneratedMediaService.ensureDownloaded(
            'connection-b',
            reference,
            fetchServerPath: (_) async =>
                Uint8List.fromList('not media'.codeUnits),
            baseDir: temporary,
          ),
          throwsA(isA<FormatException>()),
        );
        final cached = temporary
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => !file.path.contains('.tmp-'));
        expect(cached, isEmpty);
      },
    );

    test('generic file bytes are promoted atomically and retain safe suffix', () async {
      const reference = GeneratedMediaReference(
        source: '/workspace/private/report.txt',
        kind: GeneratedMediaKind.file,
        sourceKind: GeneratedMediaSourceKind.serverPath,
        displayName: 'report.txt',
        mimeType: 'text/plain',
      );

      final file = await GeneratedMediaService.ensureDownloaded(
        'connection-file',
        reference,
        fetchServerPath: (_) async => Uint8List.fromList(utf8.encode('report')),
        baseDir: temporary,
      );

      expect(file.path, endsWith('.txt'));
      expect(await file.readAsString(), 'report');
      expect(file.path, isNot(contains('/workspace/private')));
      expect(
        temporary
            .listSync(recursive: true)
            .whereType<File>()
            .where((entry) => entry.path.contains('.tmp-')),
        isEmpty,
      );
    });

    test('generic file download can retry after a cleaned failure', () async {
      const reference = GeneratedMediaReference(
        source: '/workspace/private/retry.pdf',
        kind: GeneratedMediaKind.file,
        sourceKind: GeneratedMediaSourceKind.serverPath,
        displayName: 'retry.pdf',
        mimeType: 'application/pdf',
      );
      var calls = 0;

      Future<void> fetch(String _, File destination) async {
        calls++;
        await destination.writeAsString('partial');
        if (calls == 1) throw const FileSystemException('cancelled');
        await destination.writeAsBytes(<int>[0x25, 0x50, 0x44, 0x46, 0x2d]);
      }

      await expectLater(
        GeneratedMediaService.ensureDownloaded(
          'connection-retry',
          reference,
          fetchServerPathToFile: fetch,
          baseDir: temporary,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        temporary.listSync(recursive: true).whereType<File>(),
        isEmpty,
      );

      final file = await GeneratedMediaService.ensureDownloaded(
        'connection-retry',
        reference,
        fetchServerPathToFile: fetch,
        baseDir: temporary,
      );
      expect(calls, 2);
      expect(await file.readAsBytes(), <int>[0x25, 0x50, 0x44, 0x46, 0x2d]);
    });

    test('streaming file fetch reports progress through the service', () async {
      const reference = GeneratedMediaReference(
        source: '/workspace/private/progress.txt',
        kind: GeneratedMediaKind.file,
        sourceKind: GeneratedMediaSourceKind.serverPath,
        displayName: 'progress.txt',
        mimeType: 'text/plain',
      );
      final progress = <(int, int?)>[];

      await GeneratedMediaService.ensureDownloaded(
        'connection-progress',
        reference,
        fetchServerPathToFileWithProgress:
            (
              String _,
              File destination,
              void Function(int, int?) onProgress,
              bool Function() isCancelled,
            ) async {
              expect(isCancelled(), isFalse);
              await destination.writeAsString('report');
              onProgress(6, 6);
            },
        onProgress: (int received, int? total) {
          progress.add((received, total));
        },
        isCancelled: () => false,
        baseDir: temporary,
      );

      expect(progress, <(int, int?)>[(6, 6)]);
    });

    test('cancelled streaming file fetch leaves no temporary file', () async {
      const reference = GeneratedMediaReference(
        source: '/workspace/private/cancel.txt',
        kind: GeneratedMediaKind.file,
        sourceKind: GeneratedMediaSourceKind.serverPath,
        displayName: 'cancel.txt',
        mimeType: 'text/plain',
      );
      var cancelled = false;

      await expectLater(
        GeneratedMediaService.ensureDownloaded(
          'connection-cancel',
          reference,
          fetchServerPathToFileWithProgress:
              (
                String _,
                File destination,
                void Function(int, int?) onProgress,
                bool Function() isCancelled,
              ) async {
                await destination.writeAsString('partial');
                onProgress(7, 14);
                cancelled = true;
                if (isCancelled()) {
                  throw StateError('cancelled');
                }
              },
          onProgress: (int _, int? _) {},
          isCancelled: () => cancelled,
          baseDir: temporary,
        ),
        throwsA(isA<StateError>()),
      );

      expect(temporary.listSync(recursive: true).whereType<File>(), isEmpty);
    });

    test(
      'parallel identical-content files keep distinct cache entries',
      () async {
        const bytes = <int>[
          0x52,
          0x49,
          0x46,
          0x46,
          0,
          0,
          0,
          0,
          0x57,
          0x41,
          0x56,
          0x45,
        ];
        var fetches = 0;
        final bothStarted = Completer<void>();

        Future<Uint8List> fetch(String _) async {
          fetches++;
          if (fetches == 2) bothStarted.complete();
          await bothStarted.future;
          return Uint8List.fromList(bytes);
        }

        const references = [
          GeneratedMediaReference(
            source: '/workspace/qa_tono2.wav',
            kind: GeneratedMediaKind.audio,
            sourceKind: GeneratedMediaSourceKind.serverPath,
            displayName: 'qa_tono2.wav',
            mimeType: 'audio/wav',
            sizeBytes: 12,
          ),
          GeneratedMediaReference(
            source: '/workspace/qa_tono3.wav',
            kind: GeneratedMediaKind.audio,
            sourceKind: GeneratedMediaSourceKind.serverPath,
            displayName: 'qa_tono3.wav',
            mimeType: 'audio/wav',
            sizeBytes: 12,
          ),
        ];
        final files = await Future.wait([
          for (final reference in references)
            GeneratedMediaService.ensureDownloaded(
              'connection-identical-content',
              reference,
              fetchServerPath: fetch,
              baseDir: temporary,
            ),
        ]);

        expect(fetches, 2);
        expect(files[0].path, isNot(files[1].path));
        expect(await files[0].readAsBytes(), bytes);
        expect(await files[1].readAsBytes(), bytes);
      },
    );

    test('cache identity includes known size and modification time', () async {
      const source = '/workspace/report.txt';
      var fetches = 0;

      Future<Uint8List> fetch(String _) async {
        fetches++;
        return Uint8List.fromList(utf8.encode('version $fetches'));
      }

      final first = await GeneratedMediaService.ensureDownloaded(
        'connection-cache-identity',
        GeneratedMediaReference(
          source: source,
          kind: GeneratedMediaKind.file,
          sourceKind: GeneratedMediaSourceKind.serverPath,
          displayName: 'report.txt',
          mimeType: 'text/plain',
          sizeBytes: 9,
          modifiedAt: DateTime.utc(2026, 9, 20),
        ),
        fetchServerPath: fetch,
        baseDir: temporary,
      );
      final second = await GeneratedMediaService.ensureDownloaded(
        'connection-cache-identity',
        GeneratedMediaReference(
          source: source,
          kind: GeneratedMediaKind.file,
          sourceKind: GeneratedMediaSourceKind.serverPath,
          displayName: 'report.txt',
          mimeType: 'text/plain',
          sizeBytes: 9,
          modifiedAt: DateTime.utc(2026, 9, 21),
        ),
        fetchServerPath: fetch,
        baseDir: temporary,
      );

      expect(fetches, 2);
      expect(first.path, isNot(second.path));
    });
  });

  test('auto-load coordinator allows at most two concurrent loads', () async {
    var active = 0;
    var maximum = 0;
    final started = <Completer<void>>[
      Completer<void>(),
      Completer<void>(),
      Completer<void>(),
    ];
    final releases = <Completer<void>>[
      Completer<void>(),
      Completer<void>(),
      Completer<void>(),
    ];

    Future<void> load(int index) async {
      active++;
      maximum = active > maximum ? active : maximum;
      started[index].complete();
      await releases[index].future;
      active--;
    }

    final futures = <Future<void>>[
      for (var index = 0; index < 3; index++)
        GeneratedMediaService.runAutoLoad(() => load(index)),
    ];
    await Future.wait([started[0].future, started[1].future]);
    expect(started[2].isCompleted, isFalse);
    expect(maximum, 2);

    releases[0].complete();
    await started[2].future;
    expect(maximum, 2);
    releases[1].complete();
    releases[2].complete();
    await Future.wait(futures);
  });

  test('cancelled queued auto-load does not starve the next waiter', () async {
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final firstRelease = Completer<void>();
    final secondRelease = Completer<void>();
    final visibleStarted = Completer<void>();
    final visibleRelease = Completer<void>();
    final cancellation = GeneratedMediaAutoLoadCancellation();

    final first = GeneratedMediaService.runAutoLoad(() async {
      firstStarted.complete();
      await firstRelease.future;
    });
    final second = GeneratedMediaService.runAutoLoad(() async {
      secondStarted.complete();
      await secondRelease.future;
    });
    await Future.wait([firstStarted.future, secondStarted.future]);

    final Future<void> cancelledFuture =
        GeneratedMediaService.runAutoLoad<void>(
          () async => fail('cancelled queued load must never start'),
          cancellation: cancellation,
        );
    final cancelledExpectation = expectLater(
      cancelledFuture,
      throwsA(isA<GeneratedMediaDownloadCancelled>()),
    );
    final visible = GeneratedMediaService.runAutoLoad(() async {
      visibleStarted.complete();
      await visibleRelease.future;
    });

    addTearDown(() async {
      if (!firstRelease.isCompleted) firstRelease.complete();
      if (!secondRelease.isCompleted) secondRelease.complete();
      if (!visibleRelease.isCompleted) visibleRelease.complete();
      await first.catchError((_) {});
      await second.catchError((_) {});
      await cancelledFuture.catchError((_) {});
      await visible.catchError((_) {});
    });

    cancellation.cancel();
    await cancelledExpectation;
    firstRelease.complete();
    await visibleStarted.future.timeout(const Duration(milliseconds: 200));

    secondRelease.complete();
    visibleRelease.complete();
    await Future.wait([first, second, visible]);
  });
}
