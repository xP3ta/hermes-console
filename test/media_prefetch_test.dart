import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/generated_media_service.dart';
import 'package:hermes_android/core/services/media_dimensions.dart';
import 'package:hermes_android/core/services/media_prefetcher.dart';

/// PNG signature + IHDR header only: enough for the header probe.
Uint8List pngHeader(int width, int height) {
  final bytes = BytesBuilder();
  bytes.add(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  bytes.add(const [0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
  bytes.add(_be32(width));
  bytes.add(_be32(height));
  bytes.add(const [8, 6, 0, 0, 0, 0, 0, 0, 0]);
  return bytes.toBytes();
}

List<int> _be32(int v) => [
  (v >> 24) & 0xff,
  (v >> 16) & 0xff,
  (v >> 8) & 0xff,
  v & 0xff,
];

Uint8List jpegHeader(int width, int height) => Uint8List.fromList([
  0xff, 0xd8, // SOI
  0xff, 0xe0, 0x00, 0x10, // APP0, length 16
  ...List<int>.filled(14, 0),
  0xff, 0xc0, 0x00, 0x11, 0x08, // SOF0, length 17, precision 8
  (height >> 8) & 0xff, height & 0xff,
  (width >> 8) & 0xff, width & 0xff,
  0x03, ...List<int>.filled(9, 0),
]);

Uint8List gifHeader(int width, int height) => Uint8List.fromList([
  ...'GIF89a'.codeUnits,
  width & 0xff,
  (width >> 8) & 0xff,
  height & 0xff,
  (height >> 8) & 0xff,
  0,
  0,
  0,
]);

Uint8List webpVp8xHeader(int width, int height) {
  final w = width - 1;
  final h = height - 1;
  return Uint8List.fromList([
    ...'RIFF'.codeUnits,
    0,
    0,
    0,
    0,
    ...'WEBP'.codeUnits,
    ...'VP8X'.codeUnits,
    10,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    w & 0xff,
    (w >> 8) & 0xff,
    (w >> 16) & 0xff,
    h & 0xff,
    (h >> 8) & 0xff,
    (h >> 16) & 0xff,
  ]);
}

GeneratedMediaReference imageRef(String path, {int? sizeBytes}) =>
    GeneratedMediaReference(
      source: path,
      kind: GeneratedMediaKind.image,
      sourceKind: GeneratedMediaSourceKind.serverPath,
      displayName: path.split('/').last,
      mimeType: 'image/png',
      sizeBytes: sizeBytes,
    );

void main() {
  group('image header probe', () {
    test('reads PNG, JPEG, GIF and WebP dimensions from the first bytes', () {
      expect(
        imageDimensionsFromHeader(pngHeader(1024, 512)),
        const Size(1024, 512),
      );
      expect(
        imageDimensionsFromHeader(jpegHeader(640, 480)),
        const Size(640, 480),
      );
      expect(
        imageDimensionsFromHeader(gifHeader(300, 200)),
        const Size(300, 200),
      );
      expect(
        imageDimensionsFromHeader(webpVp8xHeader(1920, 1080)),
        const Size(1920, 1080),
      );
      expect(imageDimensionsFromHeader(Uint8List.fromList([1, 2, 3])), isNull);
    });

    test(
      'box keeps the aspect ratio at the bubble width, 16:9 when unknown',
      () {
        expect(
          generatedImageBoxSize(const Size(1024, 512)),
          const Size(232, 116),
        );
        expect(
          generatedImageBoxSize(const Size(512, 1024)),
          const Size(232, 232),
        );
        expect(generatedImageBoxSize(null), const Size(232, 232 * 9 / 16));
        expect(
          generatedImageBoxSize(const Size(1000, 1000), maxWidth: 200),
          const Size(200, 200),
        );
      },
    );
  });

  group('MediaPrefetcher', () {
    late ValueNotifier<bool> locked;
    late List<File> decoded;
    late MediaPrefetcher prefetcher;
    late Directory temp;

    setUp(() {
      locked = ValueNotifier<bool>(false);
      decoded = <File>[];
      temp = Directory.systemTemp.createTempSync('media-prefetch-');
      MediaDimensionsCache.clearForTesting();
      prefetcher = MediaPrefetcher(
        locked: locked,
        warmDecode: (file) async => decoded.add(file),
      );
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    File pngFile(String name, int w, int h) {
      final file = File('${temp.path}/$name');
      file.writeAsBytesSync(pngHeader(w, h));
      return file;
    }

    test('runs at most two fetches at a time', () async {
      var active = 0;
      var peak = 0;
      final gates = <Completer<void>>[];
      for (var i = 0; i < 5; i++) {
        final gate = Completer<void>();
        gates.add(gate);
        prefetcher.prefetch(
          key: 'k$i',
          reference: imageRef('/srv/out/$i.png'),
          load: () async {
            active++;
            if (active > peak) peak = active;
            await gate.future;
            active--;
            return pngFile('$i.png', 10, 10);
          },
        );
      }
      await pumpEventQueue();
      expect(active, 2);
      final pendings = [for (var i = 0; i < 5; i++) prefetcher.pending('k$i')!];
      for (final gate in gates) {
        gate.complete();
        await pumpEventQueue();
      }
      await Future.wait(pendings);
      expect(peak, 2);
      expect(prefetcher.readyFile('k4'), isNotNull);
    });

    test(
      'dedupes a key and exposes the pending fetch for the row to join',
      () async {
        var calls = 0;
        final gate = Completer<void>();
        Future<File> load() async {
          calls++;
          await gate.future;
          return pngFile('a.png', 800, 400);
        }

        expect(
          prefetcher.prefetch(
            key: 'a',
            reference: imageRef('/srv/a.png'),
            load: load,
          ),
          isTrue,
        );
        prefetcher.prefetch(
          key: 'a',
          reference: imageRef('/srv/a.png'),
          load: load,
        );
        final pending = prefetcher.pending('a');
        expect(pending, isNotNull);
        gate.complete();
        final file = await pending!;
        expect(file, isNotNull);
        expect(calls, 1);
        expect(prefetcher.readyFile('a')?.path, file!.path);
        await pumpEventQueue();
        // Dimensions and the decoded bitmap are ready before any row exists.
        expect(MediaDimensionsCache.lookup('a'), const Size(800, 400));
        expect(MediaDimensionsCache.lookup(file.path), const Size(800, 400));
        expect(decoded.map((f) => f.path), [file.path]);
      },
    );

    test('never fetches or decodes while App Lock is locked', () async {
      locked.value = true;
      var calls = 0;
      prefetcher.prefetch(
        key: 'locked',
        reference: imageRef('/srv/locked.png'),
        load: () async {
          calls++;
          return pngFile('locked.png', 10, 20);
        },
      );
      await pumpEventQueue();
      expect(calls, 0);
      expect(decoded, isEmpty);
      expect(prefetcher.readyFile('locked'), isNull);

      final pending = prefetcher.pending('locked')!;
      locked.value = false;
      await pending;
      await pumpEventQueue();
      expect(calls, 1);
      expect(decoded, hasLength(1));
    });

    test('a lock that lands mid-fetch skips the decode until unlock', () async {
      final gate = Completer<void>();
      prefetcher.prefetch(
        key: 'mid',
        reference: imageRef('/srv/mid.png'),
        load: () async {
          await gate.future;
          return pngFile('mid.png', 10, 20);
        },
      );
      await pumpEventQueue();
      final pending = prefetcher.pending('mid')!;
      locked.value = true;
      gate.complete();
      for (var i = 0; i < 20 && prefetcher.readyFile('mid') == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(prefetcher.readyFile('mid'), isNotNull);
      expect(decoded, isEmpty);
      locked.value = false;
      await pending;
      await pumpEventQueue();
      expect(decoded, hasLength(1));
    });

    test(
      'skips media over the automatic size cap and non-server sources',
      () async {
        var calls = 0;
        Future<File> load() async {
          calls++;
          return pngFile('big.png', 1, 1);
        }

        expect(
          prefetcher.prefetch(
            key: 'big',
            reference: imageRef(
              '/srv/big.png',
              sizeBytes: GeneratedMediaService.maxAutoImageBytes + 1,
            ),
            load: load,
          ),
          isFalse,
        );
        expect(
          prefetcher.prefetch(
            key: 'https',
            reference: const GeneratedMediaReference(
              source: 'https://cdn.example/x.png',
              kind: GeneratedMediaKind.image,
              sourceKind: GeneratedMediaSourceKind.https,
            ),
            load: load,
          ),
          isFalse,
        );
        await pumpEventQueue();
        expect(calls, 0);
      },
    );
  });

  group('GeneratedMediaService disk cache', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('media-disk-'));
    tearDown(() {
      GeneratedMediaService.maxCacheBytesForTesting = null;
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test(
      'a later synchronous lookup finds the cached copy with no fetch',
      () async {
        final reference = imageRef('/srv/out/cat.png');
        var fetches = 0;
        final file = await GeneratedMediaService.ensureDownloaded(
          'conn\u0000default',
          reference,
          fetchServerPath: (_) async {
            fetches++;
            return pngHeader(64, 32);
          },
          baseDir: temp,
        );
        final hit = GeneratedMediaService.cachedFileSync(
          'conn\u0000default',
          reference,
          baseDir: temp,
        );
        expect(hit?.path, file.path);
        expect(fetches, 1);
        expect(
          GeneratedMediaService.cachedFileSync(
            'other\u0000default',
            reference,
            baseDir: temp,
          ),
          isNull,
        );
      },
    );

    test('evicts the least recently used files beyond the byte cap', () async {
      // Room for two ~1 KB entries.
      GeneratedMediaService.maxCacheBytesForTesting = 2500;
      final payload = Uint8List.fromList([
        ...pngHeader(8, 8),
        ...List<int>.filled(1000, 7),
      ]);
      final files = <File>[];
      for (var i = 0; i < 3; i++) {
        files.add(
          await GeneratedMediaService.ensureDownloaded(
            'conn',
            imageRef('/srv/out/$i.png'),
            fetchServerPath: (_) async => payload,
            baseDir: temp,
          ),
        );
        // Distinct mtimes so the LRU order is deterministic.
        files.last.setLastModifiedSync(
          DateTime(2026, 1, 1).add(Duration(minutes: i)),
        );
      }
      await GeneratedMediaService.ensureDownloaded(
        'conn',
        imageRef('/srv/out/3.png'),
        fetchServerPath: (_) async => payload,
        baseDir: temp,
      );
      expect(files[0].existsSync(), isFalse);
      expect(files[1].existsSync(), isFalse);
      expect(files[2].existsSync(), isTrue);
    });
  });

  test('default decode warmer keys the bitmap like the thumbnail', () {
    final file = File('/tmp/x.png');
    expect(
      generatedImageThumbnailProvider(file),
      ResizeImage(FileImage(file), width: generatedImageDecodeWidth),
    );
  });
}
