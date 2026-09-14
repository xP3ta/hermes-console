import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

enum GeneratedMediaKind { image, video }

enum GeneratedMediaSourceKind { serverPath, https }

class GeneratedMediaReference {
  final String source;
  final GeneratedMediaKind kind;
  final GeneratedMediaSourceKind sourceKind;

  const GeneratedMediaReference({
    required this.source,
    required this.kind,
    required this.sourceKind,
  });
}

sealed class GeneratedMediaSegment {
  const GeneratedMediaSegment();
}

class GeneratedMediaTextSegment extends GeneratedMediaSegment {
  final String text;
  const GeneratedMediaTextSegment(this.text);
}

class GeneratedMediaFileSegment extends GeneratedMediaSegment {
  final GeneratedMediaReference reference;
  const GeneratedMediaFileSegment(this.reference);
}

/// Detects Hermes' canonical `MEDIA:<path-or-url>` directives and keeps their
/// bytes in app-private storage. Server paths are fetched by the authenticated
/// Dashboard client supplied by the caller; they are never exposed as public
/// URLs or Android external-storage paths.
class GeneratedMediaService {
  static const int maxImageBytes = 25 * 1024 * 1024;
  static const int maxVideoBytes = 100 * 1024 * 1024;
  static const int _maxCacheBytes = 512 * 1024 * 1024;
  static const int _maxRedirects = 3;

  static const Set<String> _imageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
  };
  static const Set<String> _videoExtensions = {
    '.mp4',
    '.webm',
    '.mov',
    '.mkv',
    '.avi',
  };

  static final Map<String, Future<File>> _inFlight = {};

  static List<GeneratedMediaSegment> parseSegments(String content) {
    if (content.isEmpty || !content.contains('MEDIA:')) {
      return <GeneratedMediaSegment>[GeneratedMediaTextSegment(content)];
    }

    final segments = <GeneratedMediaSegment>[];
    final lines = content.split('\n');
    final text = StringBuffer();
    String? fenceMarker;
    var fenceWidth = 0;

    void flushText() {
      if (text.isEmpty) return;
      segments.add(GeneratedMediaTextSegment(text.toString()));
      text.clear();
    }

    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final hasNewline = index < lines.length - 1;
      final trimmed = line.trimLeft();
      final fence = RegExp(r'^(`{3,}|~{3,})').firstMatch(trimmed)?.group(1);
      if (fence != null &&
          (fenceMarker == null ||
              (fence[0] == fenceMarker && fence.length >= fenceWidth))) {
        if (fenceMarker == null) {
          fenceMarker = fence[0];
          fenceWidth = fence.length;
        } else {
          fenceMarker = null;
          fenceWidth = 0;
        }
        text.write(line);
        if (hasNewline) text.write('\n');
        continue;
      }

      final reference = fenceMarker != null ? null : _parseDirective(line);
      if (reference == null) {
        // Outside a code fence, MEDIA is a control directive rather than prose.
        // Drop malformed/unsupported directives so local paths, signed URLs or
        // traversal attempts never leak through Markdown, clipboard or TTS.
        if (fenceMarker == null && line.trimLeft().startsWith('MEDIA:')) {
          if (hasNewline) text.write('\n');
          continue;
        }
        text.write(line);
        if (hasNewline) text.write('\n');
        continue;
      }

      flushText();
      segments.add(GeneratedMediaFileSegment(reference));
      if (hasNewline) text.write('\n');
    }
    flushText();
    return segments.isEmpty
        ? <GeneratedMediaSegment>[GeneratedMediaTextSegment(content)]
        : segments;
  }

  static GeneratedMediaReference? referenceFromSource(String rawSource) {
    final source = rawSource.trim();
    if (source.isEmpty) return null;
    return _parseDirective('MEDIA:$source');
  }

  /// Extracts only successful first-party producer results. `agent_visible_image`
  /// is deliberately never fetched: it may be a sandbox-only path.
  static List<GeneratedMediaReference> referencesFromToolResult(
    String? toolName,
    Object? rawResult,
  ) {
    final normalizedName = toolName?.trim().toLowerCase();
    if (normalizedName != 'image_generate' &&
        normalizedName != 'video_generate') {
      return const [];
    }
    Object? decoded = rawResult;
    if (decoded is String) {
      try {
        decoded = jsonDecode(decoded);
      } catch (_) {
        return const [];
      }
    }
    if (decoded is! Map || decoded['success'] != true) return const [];

    final fields = normalizedName == 'image_generate'
        ? const ['host_image', 'image']
        : const ['video'];
    for (final field in fields) {
      final value = decoded[field];
      if (value is! String) continue;
      final reference = referenceFromSource(value);
      if (reference == null) continue;
      final expectedKind = normalizedName == 'image_generate'
          ? GeneratedMediaKind.image
          : GeneratedMediaKind.video;
      if (reference.kind == expectedKind) {
        return List<GeneratedMediaReference>.unmodifiable([reference]);
      }
    }
    return const [];
  }

  static GeneratedMediaReference? _parseDirective(String line) {
    final match = RegExp(r'^\s*MEDIA:\s*(.*?)\s*$').firstMatch(line);
    if (match == null) return null;
    var source = (match.group(1) ?? '').trim();
    if (source.length >= 2 &&
        ((source.startsWith('"') && source.endsWith('"')) ||
            (source.startsWith("'") && source.endsWith("'")))) {
      source = source.substring(1, source.length - 1).trim();
    }
    if (source.isEmpty || source.contains('\u0000')) return null;

    final uri = Uri.tryParse(source);
    final sourceKind = uri != null && uri.scheme.toLowerCase() == 'https'
        ? GeneratedMediaSourceKind.https
        : GeneratedMediaSourceKind.serverPath;
    if (uri != null &&
        uri.hasScheme &&
        sourceKind != GeneratedMediaSourceKind.https) {
      // Explicitly reject http:, file:, data: and custom schemes.
      return null;
    }
    if (sourceKind == GeneratedMediaSourceKind.https) {
      if (uri == null ||
          !uri.hasAuthority ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        return null;
      }
      source = uri.removeFragment().toString();
    }
    if (sourceKind == GeneratedMediaSourceKind.serverPath &&
        !_isSafeServerPath(source)) {
      return null;
    }

    final path = sourceKind == GeneratedMediaSourceKind.https
        ? uri!.path
        : source;
    final lower = path.toLowerCase();
    final image = _imageExtensions.any(lower.endsWith);
    final video = _videoExtensions.any(lower.endsWith);
    if (!image && !video) return null;
    return GeneratedMediaReference(
      source: source,
      kind: image ? GeneratedMediaKind.image : GeneratedMediaKind.video,
      sourceKind: sourceKind,
    );
  }

  static bool _isSafeServerPath(String source) {
    if (source.length > 2048 ||
        !source.startsWith('/') ||
        source.startsWith('//') ||
        source.contains('\\') ||
        source.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
        source.contains('?') ||
        source.contains('#')) {
      return false;
    }
    for (final raw in source.split('/').skip(1)) {
      if (raw.isEmpty || raw == '.' || raw == '..') return false;
      String decoded;
      try {
        decoded = Uri.decodeComponent(raw);
      } on FormatException {
        return false;
      }
      if (decoded.isEmpty ||
          decoded == '.' ||
          decoded == '..' ||
          decoded.contains('/') ||
          decoded.contains('\\') ||
          decoded.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        return false;
      }
    }
    return true;
  }

  /// Text suitable for copy, read-aloud and notification previews: prose is
  /// preserved while server-local paths and signed media URLs stay private.
  static String stripDirectives(String content) => parseSegments(content)
      .whereType<GeneratedMediaTextSegment>()
      .map((segment) => segment.text)
      .join();

  static Future<File> ensureDownloaded(
    String connectionId,
    GeneratedMediaReference reference, {
    Future<Uint8List> Function(String path)? fetchServerPath,
    Future<void> Function(String path, File destination)? fetchServerPathToFile,
    Directory? baseDir,
  }) {
    if (reference.sourceKind == GeneratedMediaSourceKind.serverPath &&
        fetchServerPath == null &&
        fetchServerPathToFile == null) {
      throw ArgumentError('A server-path fetcher is required');
    }
    final key =
        '${baseDir?.path ?? 'app'}\u0000$connectionId\u0000${reference.source}';
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final future = _ensureDownloaded(
      connectionId,
      reference,
      fetchServerPath: fetchServerPath,
      fetchServerPathToFile: fetchServerPathToFile,
      baseDir: baseDir,
    );
    _inFlight[key] = future;
    unawaited(
      future.then<void>(
        (_) {
          _inFlight.remove(key);
        },
        onError: (Object _, StackTrace _) {
          _inFlight.remove(key);
        },
      ),
    );
    return future;
  }

  static Future<File> _ensureDownloaded(
    String connectionId,
    GeneratedMediaReference reference, {
    Future<Uint8List> Function(String path)? fetchServerPath,
    Future<void> Function(String path, File destination)? fetchServerPathToFile,
    Directory? baseDir,
  }) async {
    final root = baseDir ?? await getApplicationSupportDirectory();
    final connectionHash = sha256.convert(utf8.encode(connectionId)).toString();
    final sourceHash = sha256.convert(utf8.encode(reference.source)).toString();
    final suffix = _extensionFor(reference.source, reference.kind);
    final directory = Directory('${root.path}/generated_media/$connectionHash');
    await directory.create(recursive: true);
    final target = File('${directory.path}/$sourceHash$suffix');

    if (await target.exists()) {
      try {
        final length = await target.length();
        if (length > 0 && length <= _maxBytes(reference.kind)) {
          final probe = await _readPrefix(target, 32);
          if (validateBytes(probe, reference.kind)) {
            await target.setLastModified(DateTime.now());
            return target;
          }
        }
      } catch (_) {
        // A concurrent prune may have removed the cache entry. Re-download.
      }
      if (await target.exists()) {
        await target.delete().catchError((_) => target);
      }
    }

    final temporary = File(
      '${target.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      if (reference.sourceKind == GeneratedMediaSourceKind.serverPath &&
          fetchServerPathToFile != null) {
        await fetchServerPathToFile(reference.source, temporary);
      } else if (reference.sourceKind == GeneratedMediaSourceKind.serverPath) {
        final bytes = await fetchServerPath!(reference.source);
        if (bytes.isEmpty || bytes.length > _maxBytes(reference.kind)) {
          throw const FormatException('generated media exceeds its size limit');
        }
        await temporary.writeAsBytes(bytes, flush: true);
      } else {
        await _downloadHttpsToFile(reference.source, reference.kind, temporary);
      }

      final length = await temporary.length();
      if (length <= 0 || length > _maxBytes(reference.kind)) {
        throw const FormatException('generated media exceeds its size limit');
      }
      final probe = await _readPrefix(temporary, 32);
      if (!validateBytes(probe, reference.kind)) {
        throw const FormatException('generated media signature is invalid');
      }
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) {
        await temporary.delete().catchError((_) => temporary);
      }
    }
    await _pruneCache(Directory('${root.path}/generated_media'));
    return target;
  }

  static int _maxBytes(GeneratedMediaKind kind) =>
      kind == GeneratedMediaKind.image ? maxImageBytes : maxVideoBytes;

  static String _extensionFor(String source, GeneratedMediaKind kind) {
    final uri = Uri.tryParse(source);
    final path = uri != null && uri.hasScheme ? uri.path : source;
    final dot = path.lastIndexOf('.');
    if (dot >= 0) {
      final extension = path.substring(dot).toLowerCase();
      final allowed = kind == GeneratedMediaKind.image
          ? _imageExtensions
          : _videoExtensions;
      if (allowed.contains(extension)) return extension;
    }
    return kind == GeneratedMediaKind.image ? '.img' : '.video';
  }

  static Future<Uint8List> _readPrefix(File file, int count) async {
    final handle = await file.open();
    try {
      return Uint8List.fromList(await handle.read(count));
    } finally {
      await handle.close();
    }
  }

  static bool validateBytes(Uint8List bytes, GeneratedMediaKind kind) {
    if (kind == GeneratedMediaKind.image) {
      if (bytes.length >= 8 &&
          bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4e &&
          bytes[3] == 0x47 &&
          bytes[4] == 0x0d &&
          bytes[5] == 0x0a &&
          bytes[6] == 0x1a &&
          bytes[7] == 0x0a) {
        return true;
      }
      if (bytes.length >= 3 &&
          bytes[0] == 0xff &&
          bytes[1] == 0xd8 &&
          bytes[2] == 0xff) {
        return true;
      }
      if (bytes.length >= 6) {
        final signature = String.fromCharCodes(bytes.sublist(0, 6));
        if (signature == 'GIF87a' || signature == 'GIF89a') return true;
      }
      if (bytes.length >= 12 &&
          String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
          String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
        return true;
      }
      return bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4d;
    }

    if (bytes.length >= 12 &&
        String.fromCharCodes(bytes.sublist(4, 8)) == 'ftyp') {
      return true;
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x1a &&
        bytes[1] == 0x45 &&
        bytes[2] == 0xdf &&
        bytes[3] == 0xa3) {
      return true;
    }
    return bytes.length >= 12 &&
        String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(bytes.sublist(8, 12)) == 'AVI ';
  }

  static Future<void> _downloadHttpsToFile(
    String source,
    GeneratedMediaKind kind,
    File target,
  ) async {
    var uri = Uri.parse(source);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      for (var redirect = 0; redirect <= _maxRedirects; redirect++) {
        if (uri.scheme != 'https' ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          throw const FormatException(
            'only credential-free HTTPS media is supported',
          );
        }
        final request = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 20));
        request.followRedirects = false;
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if (response.isRedirect) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await _cancelHttpResponse(response);
          if (location == null || redirect == _maxRedirects) {
            throw const HttpException('invalid media redirect');
          }
          final next = uri.resolve(location);
          if (next.scheme != 'https' || next.origin != uri.origin) {
            throw const HttpException('cross-origin media redirect rejected');
          }
          uri = next;
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await _cancelHttpResponse(response);
          throw HttpException('media download failed (${response.statusCode})');
        }
        final maxBytes = _maxBytes(kind);
        final declared = response.contentLength;
        if (declared > maxBytes) {
          await _cancelHttpResponse(response);
          throw const HttpException('generated media is too large');
        }

        final sink = target.openWrite(mode: FileMode.writeOnly);
        var received = 0;
        try {
          await for (final chunk in response.timeout(
            const Duration(minutes: 2),
          )) {
            received += chunk.length;
            if (received > maxBytes) {
              throw const HttpException('generated media is too large');
            }
            sink.add(chunk);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (received <= 0) {
          throw const HttpException('generated media is empty');
        }
        return;
      }
      throw const HttpException('too many media redirects');
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _cancelHttpResponse(HttpClientResponse response) async {
    final subscription = response.listen((_) {});
    await subscription.cancel();
  }

  static Future<void> _pruneCache(Directory root) async {
    if (!await root.exists()) return;
    final files = <File>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File && !entity.path.contains('.tmp-')) files.add(entity);
    }
    var total = 0;
    final entries = <({File file, int bytes, DateTime modified})>[];
    for (final file in files) {
      try {
        final stat = await file.stat();
        total += stat.size;
        entries.add((file: file, bytes: stat.size, modified: stat.modified));
      } catch (_) {
        // A concurrent cleanup may already have removed it.
      }
    }
    if (total <= _maxCacheBytes) return;
    entries.sort((a, b) => a.modified.compareTo(b.modified));
    for (final entry in entries) {
      if (total <= _maxCacheBytes) break;
      try {
        await entry.file.delete();
        total -= entry.bytes;
      } catch (_) {
        // Best effort cache maintenance.
      }
    }
  }
}
