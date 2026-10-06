import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/generated_image_service.dart';
import 'package:http/http.dart' as http;

void main() {
  group('GeneratedImageService.segments — detector (spec 030)', () {
    const real =
        '/home/demo/.hermes/cache/images/openai_codex_gpt-image-2-medium_20260705_203332_4155a10b.png';

    test('ruta real de SERVER en una frase', () {
      final segs = GeneratedImageService.segments(
        'Hecho. Ruta exacta del archivo generado:\n\n$real',
      );
      expect(segs.whereType<ImageSegment>().length, 1);
      final img = segs.whereType<ImageSegment>().single;
      expect(
        img.basename,
        'openai_codex_gpt-image-2-medium_20260705_203332_4155a10b.png',
      );
      // El texto previo se conserva íntegro.
      expect((segs.first as TextSegment).text, contains('Ruta exacta'));
    });

    test('envuelta en backticks: se tragan las envolturas', () {
      final segs = GeneratedImageService.segments('La imagen: `$real` lista.');
      expect(segs.whereType<ImageSegment>().length, 1);
      final texts = segs.whereType<TextSegment>().map((s) => s.text).join('|');
      expect(texts, isNot(contains('`')));
      expect(texts, contains('lista.'));
    });

    test('envuelta en paréntesis', () {
      final segs = GeneratedImageService.segments(
        'Guardada ($real) en el server.',
      );
      expect(segs.whereType<ImageSegment>().length, 1);
      final texts = segs.whereType<TextSegment>().map((s) => s.text).join('|');
      expect(texts, isNot(contains('(')));
    });

    test('varias imágenes en un mensaje, en orden', () {
      const b = '/home/u/.hermes/cache/images/fal_flux_x.webp';
      final segs = GeneratedImageService.segments('Primera $real y luego $b.');
      final imgs = segs.whereType<ImageSegment>().toList();
      expect(imgs.length, 2);
      expect(imgs.first.basename, endsWith('.png'));
      expect(imgs.last.basename, 'fal_flux_x.webp');
    });

    test('home con ~ y /root también matchean', () {
      expect(
        GeneratedImageService.segments(
          '~/.hermes/cache/images/a.png',
        ).whereType<ImageSegment>().length,
        1,
      );
      expect(
        GeneratedImageService.segments(
          '/root/.hermes/cache/images/a.jpg',
        ).whereType<ImageSegment>().length,
        1,
      );
    });

    test('extensión no permitida NO matchea', () {
      final segs = GeneratedImageService.segments(
        '/home/u/.hermes/cache/images/notas.txt',
      );
      expect(segs.whereType<ImageSegment>(), isEmpty);
      expect(segs.single, isA<TextSegment>());
    });

    test('intento de traversal NO produce ImageSegment con ..', () {
      final segs = GeneratedImageService.segments(
        '/home/u/.hermes/cache/images/../../.env y '
        '/home/u/.hermes/cache/images/sub/dir.png',
      );
      for (final img in segs.whereType<ImageSegment>()) {
        expect(img.basename.contains('..'), isFalse);
        expect(img.basename.contains('/'), isFalse);
      }
    });

    test('texto sin rutas → un único TextSegment con el texto íntegro', () {
      const t = 'Hola, no hay imágenes aquí. ~/.hermes/cache/otro/a.png';
      final segs = GeneratedImageService.segments(t);
      expect(segs.length, 1);
      expect((segs.single as TextSegment).text, t);
    });

    test('US3: las URLs http(s) NO matchean (siguen el camino markdown)', () {
      final segs = GeneratedImageService.segments(
        'Mira https://cdn.example.com/imagen.png y '
        'http://host/.hermes/cache/images/a.png',
      );
      expect(segs.whereType<ImageSegment>(), isEmpty);
    });
  });

  group('imageReferencesFromResult — resultado estructurado (spec 068)', () {
    const host = '/home/hermes/.hermes/cache/images/generated.png';
    const fallback = '/home/hermes/.hermes/cache/images/fallback.webp';
    const visible = '/home/hermes/.hermes/cache/images/visible.jpg';

    test('acepta un Map y un JSON string equivalentes', () {
      final fromMap = GeneratedImageService.imageReferencesFromResult({
        'success': true,
        'host_image': host,
      });
      final fromJson = GeneratedImageService.imageReferencesFromResult(
        jsonEncode({'success': true, 'host_image': host}),
      );

      expect(fromMap, hasLength(1));
      expect(fromJson, hasLength(1));
      expect(fromMap.single.source, host);
      expect(fromJson.single.source, host);
      expect(fromMap.single.basename, 'generated.png');
      expect(fromJson.single.basename, 'generated.png');
    });

    test('host_image gana a image como fuente de display', () {
      final refs = GeneratedImageService.imageReferencesFromResult({
        'success': true,
        'host_image': host,
        'image': fallback,
      });

      expect(refs, hasLength(1));
      expect(refs.single.source, host);
      expect(refs.single.basename, 'generated.png');
    });

    test('acepta HTTPS firmada, conserva query y elimina fragmento', () {
      final refs = GeneratedImageService.imageReferencesFromResult({
        'success': true,
        'image': 'https://cdn.example/image.png?token=secret#preview',
      });

      expect(refs, hasLength(1));
      expect(refs.single.kind, GeneratedImageSourceKind.https);
      expect(refs.single.source, 'https://cdn.example/image.png?token=secret');
      expect(refs.single.basename, isNull);
    });

    test('rechaza HTTP y HTTPS con userinfo', () {
      for (final source in [
        'http://cdn.example/image.png',
        'https://user:pass@cdn.example/image.png',
      ]) {
        expect(
          GeneratedImageService.imageReferencesFromResult({
            'success': true,
            'image': source,
          }),
          isEmpty,
        );
      }
    });

    test('host_image inválido cae a image HTTPS válida', () {
      final refs = GeneratedImageService.imageReferencesFromResult({
        'success': true,
        'host_image': '/tmp/no-admitida.png',
        'image': 'https://cdn.example/fallback.webp',
      });

      expect(refs, hasLength(1));
      expect(refs.single.kind, GeneratedImageSourceKind.https);
      expect(refs.single.source, 'https://cdn.example/fallback.webp');
    });

    test('success false no crea una referencia', () {
      final refs = GeneratedImageService.imageReferencesFromResult({
        'success': false,
        'host_image': host,
      });

      expect(refs, isEmpty);
    });

    test('echoSources incluye los tres campos y elimina duplicados', () {
      final refs = GeneratedImageService.imageReferencesFromResult({
        'success': true,
        'host_image': host,
        'image': fallback,
        'agent_visible_image': visible,
      });

      expect(refs, hasLength(1));
      expect(refs.single.echoSources, [host, fallback, visible]);
    });

    test('una fuente fuera de cache no crea una referencia', () {
      final refs = GeneratedImageService.imageReferencesFromResult({
        'success': true,
        'host_image': '/tmp/generated.png',
      });

      expect(refs, isEmpty);
    });

    test('campos de display duplicados producen una sola referencia', () {
      final refs = GeneratedImageService.imageReferencesFromResult({
        'success': true,
        'host_image': host,
        'image': host,
      });

      expect(refs, hasLength(1));
      expect(refs.single.source, host);
      expect(refs.single.echoSources, [host]);
    });

    test('stripImageEchoes retira solo ecos y conserva la prosa legítima', () {
      final text =
          'Hecho. Ruta generada:\n$host\nPuedes pedirme otra variante.';

      final stripped = GeneratedImageService.stripImageEchoes(
        text,
        echoSources: const [host],
      );

      expect(stripped, isNot(contains(host)));
      expect(stripped, contains('Hecho. Ruta generada:'));
      expect(stripped, contains('Puedes pedirme otra variante.'));
    });
  });

  group('ensureDownloaded — caché local idempotente', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('genimg_test');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('descarga una vez y reutiliza el archivo local', () async {
      var calls = 0;
      Future<Uint8List> fetch(String name) async {
        calls++;
        return Uint8List.fromList([
          0x89,
          0x50,
          0x4e,
          0x47,
          0x0d,
          0x0a,
          0x1a,
          0x0a,
          1,
        ]);
      }

      final f1 = await GeneratedImageService.ensureDownloaded(
        'conn-a',
        'a.png',
        fetch: fetch,
        baseDir: tmp,
      );
      final f2 = await GeneratedImageService.ensureDownloaded(
        'conn-a',
        'a.png',
        fetch: fetch,
        baseDir: tmp,
      );
      expect(calls, 1);
      expect(f1.path, f2.path);
      expect(f1.readAsBytesSync().take(8), [
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
      ]);
      expect(f1.path, contains('generated_images'));
    });

    test('la ruta incluye conexión y digest', () async {
      final a = await GeneratedImageService.localFileFor(
        'conn-a',
        'x.webp',
        digest: 'digest-a',
        baseDir: tmp,
      );
      final b = await GeneratedImageService.localFileFor(
        'conn-b',
        'x.webp',
        digest: 'digest-a',
        baseDir: tmp,
      );
      expect(a.path, isNot(b.path));
      final again = await GeneratedImageService.localFileFor(
        'conn-a',
        'x.webp',
        digest: 'digest-a',
        baseDir: tmp,
      );
      expect(a.path, again.path);
    });

    test('la descarga fallida no deja archivo a medias', () async {
      Future<Uint8List> fetch(String name) async => throw Exception('red');
      await expectLater(
        GeneratedImageService.ensureDownloaded(
          'conn-a',
          'b.png',
          fetch: fetch,
          baseDir: tmp,
        ),
        throwsException,
      );
      final dir = await GeneratedImageService.imagesDir(baseDir: tmp);
      expect(dir.listSync().whereType<File>(), isEmpty);
    });
  });

  group('ensureHttpsDownloaded — red y caché privadas', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('genimg_https_test');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('acepta PNG/JPEG/WebP válidos', () async {
      for (final entry in <(String, List<int>)>[
        ('image/png', _pngBytes),
        ('image/jpeg', _jpegBytes),
        ('image/webp', _webpBytes),
      ]) {
        final client = _HandlerClient(
          (_) async => _response(entry.$2, contentType: entry.$1),
        );
        final file = await GeneratedImageService.ensureHttpsDownloaded(
          'conn-${entry.$1}',
          'https://cdn.example/generated?sig=value',
          client: client,
          baseDir: tmp,
        );
        expect(await file.readAsBytes(), entry.$2);
      }
    });

    test('no filtra query/token en filename y reutiliza caché', () async {
      var calls = 0;
      final client = _HandlerClient((_) async {
        calls++;
        return _response(_pngBytes, contentType: 'image/png');
      });
      const source =
          'https://private.example/generated/name.png?token=very-secret';

      final first = await GeneratedImageService.ensureHttpsDownloaded(
        'conn-a',
        source,
        client: client,
        baseDir: tmp,
      );
      final second = await GeneratedImageService.ensureHttpsDownloaded(
        'conn-a',
        source,
        client: client,
        baseDir: tmp,
      );

      expect(calls, 1);
      expect(second.path, first.path);
      expect(first.uri.pathSegments.last, isNot(contains('private')));
      expect(first.uri.pathSegments.last, isNot(contains('token')));
      expect(first.uri.pathSegments.last, isNot(contains('secret')));
      expect(first.uri.pathSegments.last, isNot(contains('name.png')));
    });

    test('sigue redirects HTTPS y vuelve a validar el destino', () async {
      final requests = <Uri>[];
      final client = _HandlerClient((request) async {
        requests.add(request.url);
        if (requests.length == 1) {
          return http.StreamedResponse(
            const Stream<List<int>>.empty(),
            HttpStatus.found,
            headers: const {'location': '/final.png?sig=ok'},
          );
        }
        return _response(_pngBytes, contentType: 'image/png');
      });

      await GeneratedImageService.ensureHttpsDownloaded(
        'conn-redirect',
        'https://cdn.example/start',
        client: client,
        baseDir: tmp,
      );

      expect(requests, [
        Uri.parse('https://cdn.example/start'),
        Uri.parse('https://cdn.example/final.png?sig=ok'),
      ]);
    });

    test('rechaza redirect a HTTP o con userinfo', () async {
      for (final location in [
        'http://cdn.example/final.png',
        'https://user:pass@cdn.example/final.png',
      ]) {
        final client = _HandlerClient(
          (_) async => http.StreamedResponse(
            const Stream<List<int>>.empty(),
            HttpStatus.found,
            headers: {'location': location},
          ),
        );
        await expectLater(
          GeneratedImageService.ensureHttpsDownloaded(
            'conn-${location.hashCode}',
            'https://cdn.example/start',
            client: client,
            baseDir: tmp,
          ),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('rechaza tamaño declarado o transmitido sobre 20 MiB', () async {
      final declared = _HandlerClient(
        (_) async => http.StreamedResponse(
          Stream<List<int>>.value(_pngBytes),
          HttpStatus.ok,
          contentLength: GeneratedImageService.maxDownloadBytes + 1,
          headers: const {'content-type': 'image/png'},
        ),
      );
      await expectLater(
        GeneratedImageService.ensureHttpsDownloaded(
          'conn-declared',
          'https://cdn.example/declared.png',
          client: declared,
          baseDir: tmp,
        ),
        throwsA(isA<FormatException>()),
      );

      final overflow = Uint8List(GeneratedImageService.maxDownloadBytes);
      final streamed = _HandlerClient(
        (_) async => http.StreamedResponse(
          Stream<List<int>>.fromIterable([_pngBytes, overflow]),
          HttpStatus.ok,
          headers: const {'content-type': 'image/png'},
        ),
      );
      await expectLater(
        GeneratedImageService.ensureHttpsDownloaded(
          'conn-streamed',
          'https://cdn.example/streamed.png',
          client: streamed,
          baseDir: tmp,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('rechaza MIME, magic bytes y coincidencia inconsistentes', () async {
      for (final response in [
        _response(_pngBytes, contentType: 'text/plain'),
        _response(const [1, 2, 3, 4], contentType: 'image/png'),
        _response(_jpegBytes, contentType: 'image/png'),
      ]) {
        final client = _HandlerClient((_) async => response);
        await expectLater(
          GeneratedImageService.ensureHttpsDownloaded(
            'conn-${response.hashCode}',
            'https://cdn.example/invalid',
            client: client,
            baseDir: tmp,
          ),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('aplica timeout de conexión y de lectura inyectables', () async {
      final slowConnect = _HandlerClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return _response(_pngBytes, contentType: 'image/png');
      });
      await expectLater(
        GeneratedImageService.ensureHttpsDownloaded(
          'conn-connect-timeout',
          'https://cdn.example/slow-connect',
          client: slowConnect,
          baseDir: tmp,
          connectTimeout: const Duration(milliseconds: 1),
        ),
        throwsA(isA<TimeoutException>()),
      );

      final slowRead = _HandlerClient(
        (_) async => http.StreamedResponse(
          Stream<List<int>>.periodic(
            const Duration(milliseconds: 50),
            (_) => _pngBytes,
          ).take(1),
          HttpStatus.ok,
          headers: const {'content-type': 'image/png'},
        ),
      );
      await expectLater(
        GeneratedImageService.ensureHttpsDownloaded(
          'conn-read-timeout',
          'https://cdn.example/slow-read',
          client: slowRead,
          baseDir: tmp,
          readTimeout: const Duration(milliseconds: 1),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}

const List<int> _pngBytes = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1];
const List<int> _jpegBytes = [0xff, 0xd8, 0xff, 1];
const List<int> _webpBytes = [
  0x52,
  0x49,
  0x46,
  0x46,
  0,
  0,
  0,
  0,
  0x57,
  0x45,
  0x42,
  0x50,
];

http.StreamedResponse _response(
  List<int> bytes, {
  required String contentType,
}) => http.StreamedResponse(
  Stream<List<int>>.value(bytes),
  HttpStatus.ok,
  contentLength: bytes.length,
  headers: {'content-type': contentType},
);

final class _HandlerClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  handler;

  _HandlerClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}
