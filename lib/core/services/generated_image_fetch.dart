import 'dart:typed_data';

import 'connection_manager.dart';
import 'generated_image_service.dart';

/// Loads a generated image that the agent cited as
/// `~/.hermes/cache/images/<basename>` through the Dashboard, the way Desktop
/// reads gateway-local media (`apps/desktop/src/lib/media.ts`):
///
/// 1. `GET /api/media?path=` — image allowlist, size cap and the server's
///    media roots (`images`, `screenshots`, `cache`);
/// 2. when the media roots refuse the path (403, e.g. a non-default
///    `HERMES_HOME`), `GET /api/fs/read-data-url?path=&profile=`, the route
///    Desktop uses for remote media.
///
/// Only a validated basename travels: the server path is rebuilt here under
/// the fixed `~/.hermes/cache/images/` root, never taken from message text.
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
    final path = Uri.encodeQueryComponent(serverPath(basename));
    Object? dataUrl;
    try {
      dataUrl = (await apiGet('media?path=$path'))['data_url'];
    } on DashboardHttpException catch (error) {
      if (error.statusCode != 403) rethrow;
      final scoped = profile == null || profile.isEmpty || profile == 'default'
          ? ''
          : '&profile=${Uri.encodeQueryComponent(profile)}';
      dataUrl = (await apiGet('fs/read-data-url?path=$path$scoped'))['dataUrl'];
    }
    return decodeImageDataUrl(dataUrl, maxBytes: maxBytes);
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
