import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'bridge_version.dart';

/// Detección y descarga de imágenes GENERADAS por el agente (spec 030).
///
/// El toolset `image_gen` de Hermes guarda las imágenes en el directorio de
/// caché del servidor (`~/.hermes/cache/images/...`) y el agente responde
/// citando esa ruta en texto plano. Este servicio:
///  1. segmenta el texto de un mensaje del asistente en trozos de texto e
///     imágenes detectadas (al RENDERIZAR, no al recibir: el historial viejo
///     también gana render);
///  2. descarga los bytes vía `GET /bridge/image` (token del bridge, guard de
///     basename en ambos lados) y los cachea en el almacenamiento privado de
///     la app, idempotente.
///
/// Los resultados estructurados de Desktop también pueden entregar una URL
/// HTTPS. En ese caso se descarga con redirects y límites estrictos y se
/// convierte en un archivo privado antes de llegar al widget.
class GeneratedImageService {
  static const int maxDownloadBytes = 20 * 1024 * 1024;
  static const int maxCacheBytes = 100 * 1024 * 1024;
  static const Duration maxCacheAge = Duration(days: 30);
  static const Duration httpsConnectTimeout = Duration(seconds: 10);
  static const Duration httpsReadTimeout = Duration(seconds: 20);
  static const int maxHttpsRedirects = 5;
  static final Map<String, Future<File>> _inFlight = {};

  /// Ruta de imagen generada del servidor: home del usuario del agente +
  /// `.hermes/cache/images/` + basename con charset estricto y extensión de
  /// imagen. El basename capturado es lo ÚNICO que viaja al bridge.
  static final RegExp pathRe = RegExp(
    r'(?:/home/[A-Za-z0-9._-]+|/root|~)/\.hermes/cache/images/'
    r'([A-Za-z0-9._-]+\.(?:png|jpe?g|webp))',
    caseSensitive: false,
  );

  /// Versión mínima del bridge que sirve `GET /bridge/image`.
  static const String minBridgeVersion = '1.12.0';

  /// True si un bridge con [runningVersion] puede servir imágenes generadas.
  /// Null/vacío (sin bridge o versión desconocida) → false.
  static bool bridgeSupportsImages(String? runningVersion) {
    final v = (runningVersion ?? '').trim();
    if (v.isEmpty) return false;
    return BridgeVersion.compare(v, minBridgeVersion) >= 0;
  }

  /// Segmenta [text] en texto e imágenes generadas, en orden. Sin matches
  /// devuelve un único [TextSegment] con el texto íntegro — el fallo de
  /// detección degrada siempre al comportamiento actual, nunca a algo peor.
  static List<ChatSegment> segments(String text) {
    final out = <ChatSegment>[];
    var cursor = 0;
    for (final m in pathRe.allMatches(text)) {
      var start = m.start;
      var end = m.end;
      // Envolturas comunes alrededor de la ruta (backticks de código inline,
      // paréntesis): se tragan para no dejar restos sueltos en el texto.
      if (start > 0 && end < text.length) {
        final before = text[start - 1];
        final after = text[end];
        if ((before == '`' && after == '`') ||
            (before == '(' && after == ')')) {
          start--;
          end++;
        }
      }
      if (start > cursor) {
        out.add(TextSegment(text.substring(cursor, start)));
      }
      out.add(ImageSegment(m.group(1)!));
      cursor = end;
    }
    if (cursor < text.length) out.add(TextSegment(text.substring(cursor)));
    if (out.isEmpty) out.add(TextSegment(text));
    return out;
  }

  /// Extrae la referencia renderizable de un resultado de `image_generate`.
  ///
  /// Desktop puede entregar el resultado como mapa o como JSON serializado.
  /// Solo [host_image] e [image], por ese orden, pueden ser fuente visual; la
  /// fuente elegida debe ser una ruta exacta admitida por [pathRe] o HTTPS.
  /// [agent_visible_image] se conserva únicamente para retirar ecos de texto.
  static List<GeneratedImageReference> imageReferencesFromResult(
    Object? rawResult,
  ) {
    final result = _decodeImageResult(rawResult);
    if (result == null || result['success'] == false) {
      return const <GeneratedImageReference>[];
    }

    String? source;
    RegExpMatch? match;
    Uri? httpsUri;
    for (final candidate in <String?>[
      _nonEmptyString(result['host_image']),
      _nonEmptyString(result['image']),
    ]) {
      if (candidate == null) continue;
      final candidateMatch = pathRe.firstMatch(candidate);
      if (candidateMatch != null &&
          candidateMatch.start == 0 &&
          candidateMatch.end == candidate.length) {
        source = candidate;
        match = candidateMatch;
        break;
      }
      final candidateUri = _safeHttpsUri(candidate);
      if (candidateUri != null) {
        source = candidateUri.toString();
        httpsUri = candidateUri;
        break;
      }
    }
    if (source == null) return const <GeneratedImageReference>[];
    final localCachePath = match != null;

    final echoSources = <String>[];
    final seen = <String>{};
    for (final value in <Object?>[
      result['host_image'],
      result['image'],
      result['agent_visible_image'],
    ]) {
      final candidate = _nonEmptyString(value);
      if (candidate != null && seen.add(candidate)) echoSources.add(candidate);
    }

    return <GeneratedImageReference>[
      GeneratedImageReference(
        kind: localCachePath
            ? GeneratedImageSourceKind.serverCache
            : GeneratedImageSourceKind.https,
        source: httpsUri?.toString() ?? source,
        basename: localCachePath ? match.group(1)! : null,
        echoSources: echoSources,
      ),
    ];
  }

  /// Retira únicamente apariciones literales de las fuentes estructuradas.
  ///
  /// No reescribe ni normaliza la prosa restante del asistente. Las fuentes
  /// largas se procesan primero para que dos valores solapados no dejen un eco
  /// parcial.
  static String stripImageEchoes(
    String text, {
    required Iterable<String> echoSources,
  }) {
    final sources =
        echoSources
            .map((source) => source.trim())
            .where((source) => source.isNotEmpty)
            .toSet()
            .toList(growable: false)
          ..sort((a, b) => b.length.compareTo(a.length));
    var stripped = text;
    for (final source in sources) {
      stripped = stripped.replaceAll(source, '');
    }
    return stripped;
  }

  static Map<Object?, Object?>? _decodeImageResult(Object? rawResult) {
    Object? decoded = rawResult;
    if (rawResult is String) {
      final value = rawResult.trim();
      if (value.isEmpty || value.length > 64 * 1024) return null;
      try {
        decoded = jsonDecode(value);
      } on FormatException {
        return null;
      }
    }
    if (decoded is! Map) return null;
    return Map<Object?, Object?>.from(decoded);
  }

  static String? _nonEmptyString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty || trimmed.length > 4096 ? null : trimmed;
  }

  static Uri? _safeHttpsUri(String source) {
    final parsed = Uri.tryParse(source);
    if (parsed == null ||
        parsed.scheme.toLowerCase() != 'https' ||
        !parsed.hasAuthority ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty) {
      return null;
    }
    // El fragmento nunca viaja por HTTP. Retirarlo evita crear dos entradas de
    // caché para los mismos bytes sin exponer query params firmados en disco.
    return parsed.hasFragment ? parsed.removeFragment() : parsed;
  }

  /// Directorio local de imágenes generadas descargadas. Hermano de
  /// `sent_images/` (adjuntos del usuario): privado de la app, se borra con
  /// ella; el historial no sale del dispositivo.
  static Future<Directory> imagesDir({Directory? baseDir}) async {
    final base = baseDir ?? await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/generated_images');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Archivo local para [basename]. El basename ya es filesystem-safe por
  /// construcción (charset del detector), así que se usa tal cual: idempotente
  /// y depurable a simple vista.
  static Future<File> localFileFor(
    String connectionId,
    String basename, {
    required String digest,
    Directory? baseDir,
  }) async {
    final dir = await imagesDir(baseDir: baseDir);
    final connectionHash = _shortHash(connectionId);
    return File('${dir.path}/${connectionHash}_${digest}_$basename');
  }

  /// Devuelve el archivo local de [basename], descargándolo con [fetch] solo
  /// si aún no existe (idempotente). Escritura atómica (tmp + rename) para no
  /// dejar archivos a medias si la descarga se corta.
  static Future<File> ensureDownloaded(
    String connectionId,
    String basename, {
    required Future<Uint8List> Function(String basename) fetch,
    Directory? baseDir,
  }) async {
    final key = '$connectionId::$basename';
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final future = _ensureDownloadedOnce(
      connectionId,
      basename,
      fetch: fetch,
      baseDir: baseDir,
    );
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    }
  }

  static Future<File> _ensureDownloadedOnce(
    String connectionId,
    String basename, {
    required Future<Uint8List> Function(String basename) fetch,
    Directory? baseDir,
  }) async {
    final dir = await imagesDir(baseDir: baseDir);
    final connectionHash = _shortHash(connectionId);
    final prefix = '${connectionHash}_';
    final suffix = '_$basename';
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.startsWith(prefix) || !name.endsWith(suffix)) continue;
      try {
        final bytes = await entity
            .openRead(0, 16)
            .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
        if (_imageFormat(bytes) != null) return entity;
      } catch (_) {}
      try {
        await entity.delete();
      } catch (_) {}
    }

    final bytes = await fetch(basename);
    if (bytes.isEmpty || bytes.length > maxDownloadBytes) {
      throw const FormatException('image is empty or too large');
    }
    if (_imageFormat(bytes) == null) {
      throw const FormatException('the downloaded content is not an image');
    }
    final digest = sha256.convert(bytes).toString();
    final file = await localFileFor(
      connectionId,
      basename,
      digest: digest,
      baseDir: baseDir,
    );
    final unique = DateTime.now().microsecondsSinceEpoch;
    final tmp = File('${file.path}.part.$unique');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
    await _evict(dir, keep: file.path);
    return file;
  }

  /// Descarga una fuente HTTPS estructurada a la caché privada. El nombre de
  /// archivo solo contiene hashes: nunca hostname, path, query ni token.
  static Future<File> ensureHttpsDownloaded(
    String connectionId,
    String source, {
    http.Client? client,
    Directory? baseDir,
    Duration connectTimeout = httpsConnectTimeout,
    Duration readTimeout = httpsReadTimeout,
  }) async {
    final uri = _safeHttpsUri(source);
    if (uri == null) {
      throw const FormatException('the HTTPS image source is not valid');
    }
    final sourceHash = sha256.convert(utf8.encode(uri.toString())).toString();
    final key = '${_shortHash(connectionId)}::https::$sourceHash';
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final future = _ensureHttpsDownloadedOnce(
      connectionId,
      uri,
      sourceHash: sourceHash,
      client: client,
      baseDir: baseDir,
      connectTimeout: connectTimeout,
      readTimeout: readTimeout,
    );
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    }
  }

  static Future<File> _ensureHttpsDownloadedOnce(
    String connectionId,
    Uri source, {
    required String sourceHash,
    required http.Client? client,
    required Directory? baseDir,
    required Duration connectTimeout,
    required Duration readTimeout,
  }) async {
    final dir = await imagesDir(baseDir: baseDir);
    final connectionHash = _shortHash(connectionId);
    final prefix = '${connectionHash}_https_${sourceHash}_';
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.startsWith(prefix)) continue;
      try {
        final bytes = await entity
            .openRead(0, 16)
            .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
        if (_imageFormat(bytes) != null) return entity;
      } catch (_) {}
      try {
        await entity.delete();
      } catch (_) {}
    }

    final ownedClient = client == null;
    final downloadClient = client ?? http.Client();
    try {
      final downloaded = await _downloadHttps(
        source,
        client: downloadClient,
        connectTimeout: connectTimeout,
        readTimeout: readTimeout,
      );
      final digest = sha256.convert(downloaded.bytes).toString();
      final file = File(
        '${dir.path}/$prefix$digest.${downloaded.format.extension}',
      );
      final unique = DateTime.now().microsecondsSinceEpoch;
      final tmp = File('${file.path}.part.$unique');
      try {
        await tmp.writeAsBytes(downloaded.bytes, flush: true);
        await tmp.rename(file.path);
      } finally {
        if (await tmp.exists()) await tmp.delete();
      }
      await _evict(dir, keep: file.path);
      return file;
    } finally {
      if (ownedClient) downloadClient.close();
    }
  }

  static Future<({Uint8List bytes, _ImageFormat format})> _downloadHttps(
    Uri initialUri, {
    required http.Client client,
    required Duration connectTimeout,
    required Duration readTimeout,
  }) async {
    var uri = initialUri;
    for (var redirects = 0; ; redirects++) {
      final request = http.Request('GET', uri)..followRedirects = false;
      final response = await client.send(request).timeout(connectTimeout);
      if (_isRedirect(response.statusCode)) {
        if (redirects >= maxHttpsRedirects) {
          throw http.ClientException('demasiadas redirecciones');
        }
        final location = response.headers['location'];
        await response.stream.timeout(readTimeout).drain<void>();
        if (location == null || location.trim().isEmpty) {
          throw http.ClientException('redirect without a target');
        }
        final redirected = _safeHttpsUri(uri.resolve(location).toString());
        if (redirected == null) {
          throw const FormatException('unsafe image redirect');
        }
        uri = redirected;
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.stream.timeout(readTimeout).drain<void>();
        throw http.ClientException(
          'invalid image response (${response.statusCode})',
        );
      }

      final declaredLength = response.contentLength;
      if (declaredLength != null && declaredLength > maxDownloadBytes) {
        await response.stream.timeout(readTimeout).drain<void>();
        throw const FormatException('imagen demasiado grande');
      }
      final expectedFormat = _formatForMime(response.headers['content-type']);
      if (expectedFormat == null) {
        await response.stream.timeout(readTimeout).drain<void>();
        throw const FormatException('tipo de imagen no admitido');
      }

      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(readTimeout)) {
        if (builder.length + chunk.length > maxDownloadBytes) {
          throw const FormatException('imagen demasiado grande');
        }
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      if (bytes.isEmpty) {
        throw const FormatException('empty image');
      }
      final actualFormat = _imageFormat(bytes);
      if (actualFormat == null || actualFormat != expectedFormat) {
        throw const FormatException(
          'the content does not match the image type',
        );
      }
      return (bytes: bytes, format: actualFormat);
    }
  }

  static bool _isRedirect(int status) =>
      status == HttpStatus.movedPermanently ||
      status == HttpStatus.found ||
      status == HttpStatus.seeOther ||
      status == HttpStatus.temporaryRedirect ||
      status == HttpStatus.permanentRedirect;

  static _ImageFormat? _formatForMime(String? value) {
    final mime = value?.split(';').first.trim().toLowerCase();
    return switch (mime) {
      'image/png' => _ImageFormat.png,
      'image/jpeg' => _ImageFormat.jpeg,
      'image/webp' => _ImageFormat.webp,
      _ => null,
    };
  }

  static _ImageFormat? _imageFormat(List<int> bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x0a &&
        bytes[6] == 0x1a &&
        bytes[7] == 0x0a) {
      return _ImageFormat.png;
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return _ImageFormat.jpeg;
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return _ImageFormat.webp;
    }
    return null;
  }

  static String _shortHash(String value) =>
      sha256.convert(utf8.encode(value)).toString().substring(0, 16);

  static Future<void> _evict(Directory dir, {required String keep}) async {
    final now = DateTime.now();
    final files = <(File, FileStat)>[];
    await for (final entity in dir.list()) {
      if (entity is! File || entity.path.contains('.part.')) continue;
      try {
        final stat = await entity.stat();
        if (entity.path != keep &&
            now.difference(stat.modified) > maxCacheAge) {
          await entity.delete();
        } else {
          files.add((entity, stat));
        }
      } catch (_) {}
    }
    files.sort((a, b) => b.$2.modified.compareTo(a.$2.modified));
    var total = 0;
    for (final entry in files) {
      total += entry.$2.size;
      if (total <= maxCacheBytes || entry.$1.path == keep) continue;
      try {
        await entry.$1.delete();
      } catch (_) {}
    }
  }
}

/// Referencia validada de una imagen generada por Hermes Desktop.
class GeneratedImageReference {
  final GeneratedImageSourceKind kind;
  final String source;
  final String? basename;
  final List<String> echoSources;

  const GeneratedImageReference({
    required this.kind,
    required this.source,
    this.basename,
    this.echoSources = const [],
  });
}

enum GeneratedImageSourceKind { serverCache, https }

enum _ImageFormat {
  png('png'),
  jpeg('jpg'),
  webp('webp');

  final String extension;
  const _ImageFormat(this.extension);
}

/// Trozo de un mensaje del asistente tras la segmentación.
sealed class ChatSegment {
  const ChatSegment();
}

class TextSegment extends ChatSegment {
  final String text;
  const TextSegment(this.text);
}

class ImageSegment extends ChatSegment {
  /// Basename del archivo en el servidor (sin directorios; validado).
  final String basename;
  const ImageSegment(this.basename);
}
