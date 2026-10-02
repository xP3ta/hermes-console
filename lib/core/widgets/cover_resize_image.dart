import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Decodes [imageProvider] just large enough to fill a [target]×[target]
/// physical-pixel box with [BoxFit.cover]: the shorter side decodes to
/// [target] and the aspect ratio is kept, so a thumbnail stays sharp while a
/// 12 MP photo no longer decodes to ~48 MB. Never upscales.
///
/// `cacheWidth` alone would decode a landscape photo with a short side below
/// the box and `cover` would then upscale it (blur); setting both sides
/// would distort it. The resized image has its own cache key, so a
/// full-screen viewer of the same file still decodes at full size.
@immutable
final class CoverResizeImage extends ImageProvider<CoverResizeImageKey> {
  final ImageProvider<Object> imageProvider;
  final int target;

  const CoverResizeImage(this.imageProvider, {required this.target})
    : assert(target > 0);

  /// Decoded side lengths that cover [target] for an image of
  /// [width]×[height], clamped to the intrinsic size.
  @visibleForTesting
  static ({int width, int height}) coverSize(
    int width,
    int height,
    int target,
  ) {
    if (width <= 0 || height <= 0) return (width: width, height: height);
    final scale = math.max(target / width, target / height);
    if (scale >= 1) return (width: width, height: height);
    return (
      width: math.max(target, (width * scale).ceil()),
      height: math.max(target, (height * scale).ceil()),
    );
  }

  @override
  Future<CoverResizeImageKey> obtainKey(ImageConfiguration configuration) {
    return imageProvider
        .obtainKey(configuration)
        .then((key) => CoverResizeImageKey._(key, target));
  }

  @override
  ImageStreamCompleter loadImage(
    CoverResizeImageKey key,
    ImageDecoderCallback decode,
  ) {
    Future<ui.Codec> decodeCover(
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) {
      assert(getTargetSize == null);
      return decode(
        buffer,
        getTargetSize: (intrinsicWidth, intrinsicHeight) {
          final size = coverSize(intrinsicWidth, intrinsicHeight, target);
          return ui.TargetImageSize(width: size.width, height: size.height);
        },
      );
    }

    return imageProvider.loadImage(key._providerKey, decodeCover);
  }

  @override
  bool operator ==(Object other) =>
      other is CoverResizeImage &&
      other.imageProvider == imageProvider &&
      other.target == target;

  @override
  int get hashCode => Object.hash(imageProvider, target);
}

@immutable
final class CoverResizeImageKey {
  final Object _providerKey;
  final int _target;

  const CoverResizeImageKey._(this._providerKey, this._target);

  @override
  bool operator ==(Object other) =>
      other is CoverResizeImageKey &&
      other._providerKey == _providerKey &&
      other._target == _target;

  @override
  int get hashCode => Object.hash(_providerKey, _target);
}
