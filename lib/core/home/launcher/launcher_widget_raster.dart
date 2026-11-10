// From a drawing to a PNG the launcher can hold: the exact pixel size of the
// placed widget, within the memory a RemoteViews may carry.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'launcher_widget_painter.dart';

/// The most pixels one widget picture may have. A RemoteViews is allowed
/// about 1.5 times the screen in bitmap bytes; a 4x4 widget on a dense
/// screen stays far below it, and a picture that would not is drawn at a
/// lower scale (the launcher stretches it back to the cell).
const lwMaxPixels = 1536 * 1024;

class LwRendered {
  const LwRendered({
    required this.png,
    required this.widthPx,
    required this.heightPx,
    required this.scale,
    required this.frame,
  });

  final Uint8List png;
  final int widthPx;
  final int heightPx;

  /// Pixels per dp the picture was drawn at (the density, or less).
  final double scale;
  final LwFrame frame;
}

/// The scale a [sizeDp] widget is drawn at on a [density] screen: the
/// density itself unless that would exceed [lwMaxPixels].
double lwRenderScale(ui.Size sizeDp, double density) {
  final pixels = sizeDp.width * density * sizeDp.height * density;
  if (pixels <= lwMaxPixels) return density;
  // A hair under the cap: rounding the sides up must not cross it.
  final factor = (lwMaxPixels / pixels).clamp(0.0, 1.0) * 0.998;
  return density * _sqrt(factor);
}

double _sqrt(double v) {
  // Newton on a bounded value: enough for a scale factor, no dart:math.
  var x = v;
  for (var i = 0; i < 20; i++) {
    x = (x + v / x) / 2;
  }
  return x;
}

/// Encodes [frame] as a PNG of the widget's size at [density].
Future<LwRendered?> lwRenderPng(
  LwFrame frame, {
  required double density,
}) async {
  final scale = lwRenderScale(frame.sizeDp, density);
  final reduced = scale < density;
  // At the density itself the cell is matched to the pixel; a reduced
  // picture rounds down, so it never exceeds the cap it was reduced for.
  int px(double dp) =>
      (reduced ? (dp * scale).floor() : (dp * scale).round()).clamp(1, 1 << 14);
  final widthPx = px(frame.sizeDp.width);
  final heightPx = px(frame.sizeDp.height);
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.scale(scale);
  canvas.drawPicture(frame.picture);
  final picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(widthPx, heightPx);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return null;
    return LwRendered(
      png: data.buffer.asUint8List(),
      widthPx: widthPx,
      heightPx: heightPx,
      scale: scale,
      frame: frame,
    );
  } finally {
    image?.dispose();
    picture.dispose();
  }
}
