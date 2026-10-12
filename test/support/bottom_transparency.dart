import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// pm1215 (owner, QA 9494): the area behind a floating composer is as
/// transparent as the area under the floating header. Pixel helpers that
/// read what the screen really paints (widget fields can lie about it).

/// One RGBA frame of the whole view at 1 logical px per pixel.
class ViewPixels {
  ViewPixels._(this.width, this.height, this._rgba);

  final int width;
  final int height;
  final ByteData _rgba;

  static Future<ViewPixels> capture(WidgetTester tester) async {
    final view = tester.binding.renderViews.first;
    final layer = view.debugLayer! as OffsetLayer;
    final size = view.size;
    final dpr = tester.view.devicePixelRatio;
    // Engine image readback needs the real async zone. Callers install the
    // few platform mocks their app bootstrap may resume while this zone runs.
    final data = await tester.runAsync(() async {
      final image = await layer.toImage(
        Offset.zero & (size * dpr),
        pixelRatio: 1 / dpr,
      );
      final bytes = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      final out = (image.width, image.height, bytes!);
      image.dispose();
      return out;
    });
    return ViewPixels._(data!.$1, data.$2, data.$3);
  }

  Color at(int x, int y) {
    final i = (y * width + x) * 4;
    return Color.fromARGB(
      _rgba.getUint8(i + 3),
      _rgba.getUint8(i),
      _rgba.getUint8(i + 1),
      _rgba.getUint8(i + 2),
    );
  }

  Iterable<(int, int)> _cells(Rect r, {List<Rect> skip = const []}) sync* {
    final l = math.max(0, r.left.ceil());
    final t = math.max(0, r.top.ceil());
    final rr = math.min(width, r.right.floor());
    final b = math.min(height, r.bottom.floor());
    for (var y = t; y < b; y++) {
      for (var x = l; x < rr; x++) {
        final p = Offset(x + 0.5, y + 0.5);
        if (skip.any((s) => s.contains(p))) continue;
        yield (x, y);
      }
    }
  }

  /// Largest per-channel distance from [bg] inside [r] (ink strength).
  int maxInk(Rect r, Color bg, {List<Rect> skip = const []}) {
    var best = 0;
    for (final (x, y) in _cells(r, skip: skip)) {
      best = math.max(best, _dist(at(x, y), bg));
    }
    return best;
  }

  /// Pixels inside [r] that differ from [other] by more than [threshold].
  int changedFrom(
    ViewPixels other,
    Rect r, {
    List<Rect> skip = const [],
    int threshold = 24,
  }) {
    var n = 0;
    for (final (x, y) in _cells(r, skip: skip)) {
      if (_dist(at(x, y), other.at(x, y)) > threshold) n++;
    }
    return n;
  }

  /// Pixels inside [r] that are not [bg] (± [tolerance]).
  int notBackground(
    Rect r,
    Color bg, {
    List<Rect> skip = const [],
    int tolerance = 6,
  }) {
    var n = 0;
    for (final (x, y) in _cells(r, skip: skip)) {
      if (_dist(at(x, y), bg) > tolerance) n++;
    }
    return n;
  }

  static int _dist(Color a, Color b) {
    int c(double v) => (v * 255).round();
    return [
      (c(a.r) - c(b.r)).abs(),
      (c(a.g) - c(b.g)).abs(),
      (c(a.b) - c(b.b)).abs(),
    ].reduce(math.max);
  }
}
