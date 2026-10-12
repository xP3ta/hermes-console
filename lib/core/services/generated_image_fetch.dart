import 'dart:typed_data';

import 'generated_image_service.dart';
import 'generated_media_service.dart';

/// Resolves a validated image basename under authenticated official profile
/// metadata, then reads that exact host-local target through Dashboard FS.
/// The profile query does not rebase tilde paths; no global media fallback is
/// safe for an isolated owner. SSH workspace identity is not established by
/// host profile metadata and is explicitly unsupported.
class GeneratedImageFetch {
  GeneratedImageFetch._();

  static final RegExp basenameRe = RegExp(
    r'^[A-Za-z0-9_-][A-Za-z0-9._-]{0,199}\.(?:png|jpe?g|webp)$',
    caseSensitive: false,
  );

  static const Set<String> _imageMimeTypes = {
    'image/png',
    'image/jpeg',
    'image/webp',
  };

  /// Server path for [basename]; throws [ArgumentError] for anything that is
  /// not a plain image file name (separators, traversal, other extensions).
  static String serverPath(String basename) {
    if (!basenameRe.hasMatch(basename)) {
      throw ArgumentError('invalid generated image name');
    }
    return '~/.hermes/cache/images/$basename';
  }

  static Future<Uint8List> fetch(
    String basename, {
    required Future<Map<String, dynamic>> Function(String endpoint) apiGet,
    String? profile,
    int maxBytes = GeneratedImageService.maxDownloadBytes,
  }) async {
    final path = await resolvePath(basename, apiGet: apiGet, profile: profile);
    return readPath(path, apiGet: apiGet, profile: profile, maxBytes: maxBytes);
  }

  static Future<String> resolvePath(
    String basename, {
    required Future<Map<String, dynamic>> Function(String endpoint) apiGet,
    String? profile,
  }) async {
    if (!GeneratedMediaService.isSafeGeneratedImageSource(basename)) {
      throw ArgumentError('unsafe generated image source');
    }
    final plainName = basenameRe.hasMatch(basename);
    final sourceMatch = GeneratedImageService.pathRe.firstMatch(basename);
    if (!plainName &&
        (sourceMatch == null ||
            sourceMatch.start != 0 ||
            sourceMatch.end != basename.length)) {
      throw ArgumentError('invalid generated image source');
    }
    final owner = profile == null || profile.isEmpty ? 'default' : profile;
    final metadata = await apiGet('profiles');
    final entries = metadata['profiles'];
    final matches = entries is List
        ? entries
              .whereType<Map>()
              .where((entry) => entry['name'] == owner)
              .toList()
        : const <Map>[];
    if (matches.length != 1) {
      throw UnsupportedError('generated image profile root unavailable');
    }
    final root = matches.single['path'];
    if (root is! String ||
        !root.startsWith('/') ||
        root == '/' ||
        root.contains('\\') ||
        root.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
        root
            .split('/')
            .skip(1)
            .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw UnsupportedError('generated image profile root invalid');
    }
    final config = await apiGet(
      'config?profile=${Uri.encodeQueryComponent(owner)}',
    );
    final terminal = config['terminal'];
    if (terminal is! Map || (terminal['backend'] ?? 'local') != 'local') {
      throw UnsupportedError(
        'generated images require an official host-local profile; SSH workspace identity unavailable',
      );
    }
    if (plainName) return '$root/cache/images/$basename';
    if (basename.startsWith('~/.hermes/cache/images/')) {
      return '$root/cache/images/${sourceMatch!.group(1)}';
    }
    if (basename != '$root/cache/images/${sourceMatch!.group(1)}' &&
        basename != '$root/cache/generated/images/${sourceMatch.group(1)}') {
      throw ArgumentError('generated image source outside owner root');
    }
    return basename;
  }

  static Future<Uint8List> readPath(
    String target, {
    required Future<Map<String, dynamic>> Function(String endpoint) apiGet,
    String? profile,
    int maxBytes = GeneratedImageService.maxDownloadBytes,
    bool Function()? isCurrent,
  }) async {
    if (!GeneratedMediaService.isSafeGeneratedImageSource(target) ||
        !target.startsWith('/')) {
      throw ArgumentError('unsafe generated image target');
    }
    final owner = profile == null || profile.isEmpty ? 'default' : profile;
    final path = Uri.encodeQueryComponent(target);
    final scoped = '&profile=${Uri.encodeQueryComponent(owner)}';
    final dataUrl = (await apiGet(
      'fs/read-data-url?path=$path$scoped',
    ))['dataUrl'];
    if (isCurrent != null && !isCurrent()) {
      throw StateError('generated image owner revoked');
    }
    final bytes = decodeImageDataUrl(dataUrl, maxBytes: maxBytes);
    await GeneratedImageService.validateImageBytes(
      bytes,
      mime: UriData.parse(dataUrl as String).mimeType,
    );
    return bytes;
  }

  /// Decodes a base64 `data:image/...` URL, refusing other media types,
  /// empty payloads and anything over [maxBytes].
  static Uint8List decodeImageDataUrl(Object? raw, {required int maxBytes}) {
    if (raw is! String || !raw.startsWith('data:')) {
      throw const FormatException('generated image: not a data URL');
    }
    // base64 inflates by 4/3: refuse oversized payloads before decoding.
    if (raw.length > maxBytes * 4 ~/ 3 + 128) {
      throw const FormatException('generated image too large');
    }
    final UriData data;
    try {
      data = UriData.parse(raw);
    } on FormatException {
      throw const FormatException('generated image: malformed data URL');
    }
    if (!data.isBase64 ||
        !_imageMimeTypes.contains(data.mimeType.toLowerCase())) {
      throw const FormatException('generated image: unsupported type');
    }
    final bytes = data.contentAsBytes();
    if (bytes.isEmpty) {
      throw const FormatException('generated image: empty');
    }
    if (bytes.length > maxBytes) {
      throw const FormatException('generated image too large');
    }
    return bytes;
  }
}
