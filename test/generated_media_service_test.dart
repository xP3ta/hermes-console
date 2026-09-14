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
          'video': 'https://cdn.example/generated.webm?token=secret#fragment',
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
  });
}
