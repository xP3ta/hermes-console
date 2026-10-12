import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Widest (and tallest) an inline generated image thumbnail is painted.
const double generatedImageMaxExtent = 232;

/// Bitmap width the thumbnail decodes to (2x the box for sharp screens).
/// Prefetch warms the image cache with exactly this key, so the row paints
/// synchronously when it scrolls into view.
const int generatedImageDecodeWidth = 464;

/// How many leading bytes the header probe reads: enough for the PNG/GIF/
/// WebP headers and for a JPEG SOF behind EXIF/ICC segments.
const int imageHeaderProbeBytes = 64 * 1024;

/// The image provider the inline thumbnail paints and the prefetcher warms.
ImageProvider generatedImageThumbnailProvider(File file) =>
    ResizeImage(FileImage(file), width: generatedImageDecodeWidth);

/// Box an inline image occupies: full bubble width ([maxWidth], at most
/// [generatedImageMaxExtent]) and the image's aspect ratio, capped at the
/// same extent. Unknown dimensions reserve a stable 16:9 box.
Size generatedImageBoxSize(
  Size? intrinsic, {
  double maxWidth = generatedImageMaxExtent,
}) {
  final width = math.min(maxWidth, generatedImageMaxExtent);
  if (intrinsic == null || intrinsic.width <= 0 || intrinsic.height <= 0) {
    return Size(width, width * 9 / 16);
  }
  final height = (width * intrinsic.height / intrinsic.width).clamp(
    math.min(48.0, width),
    generatedImageMaxExtent,
  );
  return Size(width, height.toDouble());
}

/// Pixel size of a PNG, JPEG, GIF or WebP from its first bytes, or null.
/// Pure header parsing: nothing is decoded.
Size? imageDimensionsFromHeader(Uint8List b) {
  int be16(int i) => (b[i] << 8) | b[i + 1];
  int le16(int i) => b[i] | (b[i + 1] << 8);
  int be32(int i) =>
      (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
  Size? valid(int w, int h) =>
      w > 0 && h > 0 ? Size(w.toDouble(), h.toDouble()) : null;

  // PNG: signature + IHDR.
  if (b.length >= 24 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4e &&
      b[3] == 0x47 &&
      b[12] == 0x49 &&
      b[13] == 0x48 &&
      b[14] == 0x44 &&
      b[15] == 0x52) {
    return valid(be32(16), be32(20));
  }
  // GIF87a / GIF89a logical screen.
  if (b.length >= 10 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
    return valid(le16(6), le16(8));
  }
  // WebP: RIFF....WEBP + VP8 / VP8L / VP8X chunk.
  if (b.length >= 30 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    final chunk = String.fromCharCodes(b.sublist(12, 16));
    switch (chunk) {
      case 'VP8X':
        return valid(
          1 + (b[24] | (b[25] << 8) | (b[26] << 16)),
          1 + (b[27] | (b[28] << 8) | (b[29] << 16)),
        );
      case 'VP8L':
        final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
        return valid(1 + (bits & 0x3fff), 1 + ((bits >> 14) & 0x3fff));
      case 'VP8 ':
        return valid(le16(26) & 0x3fff, le16(28) & 0x3fff);
    }
    return null;
  }
  // JPEG: walk the segments up to a start-of-frame marker.
  if (b.length >= 4 && b[0] == 0xff && b[1] == 0xd8) {
    var i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xff) return null;
      final marker = b[i + 1];
      if (marker == 0xff) {
        i++;
        continue;
      }
      if (marker == 0xd8 ||
          marker == 0x01 ||
          (marker >= 0xd0 && marker <= 0xd7)) {
        i += 2;
        continue;
      }
      final isSof =
          marker >= 0xc0 &&
          marker <= 0xcf &&
          marker != 0xc4 &&
          marker != 0xc8 &&
          marker != 0xcc;
      if (isSof) return valid(be16(i + 7), be16(i + 5));
      if (marker == 0xd9 || marker == 0xda) return null;
      i += 2 + be16(i + 2);
    }
  }
  return null;
}

/// Header probe of a local file (the verified cache copy). Synchronous so a
/// row can reserve its final box on its first layout; it reads at most
/// [imageHeaderProbeBytes].
Size? readImageDimensionsSync(File file) {
  RandomAccessFile? handle;
  try {
    handle = file.openSync();
    return imageDimensionsFromHeader(handle.readSync(imageHeaderProbeBytes));
  } catch (_) {
    return null;
  } finally {
    try {
      handle?.closeSync();
    } catch (_) {}
  }
}

Future<Size?> readImageDimensions(File file) async {
  RandomAccessFile? handle;
  try {
    handle = await file.open();
    return imageDimensionsFromHeader(await handle.read(imageHeaderProbeBytes));
  } catch (_) {
    return null;
  } finally {
    try {
      await handle?.close();
    } catch (_) {}
  }
}

/// Process-wide memo of known media dimensions, keyed by the ready-memo key
/// of a reference and by the cached file path. Bounded LRU.
abstract final class MediaDimensionsCache {
  static const int _capacity = 512;
  static final Map<String, Size> _sizes = <String, Size>{};

  static Size? lookup(String key) {
    final size = _sizes.remove(key);
    if (size != null) _sizes[key] = size;
    return size;
  }

  static void remember(String key, Size size) {
    _sizes.remove(key);
    _sizes[key] = size;
    while (_sizes.length > _capacity) {
      _sizes.remove(_sizes.keys.first);
    }
  }

  /// Dimensions of a cached file: memo first, then a header probe.
  static Size? ofFileSync(File file) {
    final known = lookup(file.path);
    if (known != null) return known;
    final probed = readImageDimensionsSync(file);
    if (probed != null) remember(file.path, probed);
    return probed;
  }

  static void clear() => _sizes.clear();

  @visibleForTesting
  static void clearForTesting() => _sizes.clear();
}
