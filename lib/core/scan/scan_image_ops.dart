/// Pure-Dart image maths of the document scanner (no Flutter, no network).
///
/// Everything here works on plain typed data so a whole page can be processed
/// inside an isolate: perspective correction (homography + bilinear
/// resampling), the enhancement filters, a minimal PNG encoder and a minimal
/// PDF writer. Nothing leaves the device and no package is needed.
library;

import 'dart:async' show FutureOr;
import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:math' as math;
import 'dart:typed_data';

/// A point in pixel (or normalised) coordinates.
class ScanPoint {
  const ScanPoint(this.x, this.y);

  final double x;
  final double y;

  @override
  bool operator ==(Object other) =>
      other is ScanPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'ScanPoint($x, $y)';
}

/// Projective transform of the plane, stored row-major with `m[8] == 1`.
class Homography {
  const Homography(this.m);

  final List<double> m;

  /// The transform that sends each point of [from] to the matching [to]
  /// (four pairs, direct linear transform). `null` when the quads are
  /// degenerate (three collinear corners, repeated corners...).
  static Homography? fromQuads(List<ScanPoint> from, List<ScanPoint> to) {
    if (from.length != 4 || to.length != 4) return null;
    // Unknowns h0..h7; two equations per pair.
    final a = List.generate(8, (_) => List<double>.filled(9, 0));
    for (var i = 0; i < 4; i++) {
      final x = from[i].x;
      final y = from[i].y;
      final u = to[i].x;
      final v = to[i].y;
      a[2 * i]
        ..[0] = x
        ..[1] = y
        ..[2] = 1
        ..[6] = -u * x
        ..[7] = -u * y
        ..[8] = u;
      a[2 * i + 1]
        ..[3] = x
        ..[4] = y
        ..[5] = 1
        ..[6] = -v * x
        ..[7] = -v * y
        ..[8] = v;
    }
    // Gaussian elimination with partial pivoting.
    for (var col = 0; col < 8; col++) {
      var pivot = col;
      for (var row = col + 1; row < 8; row++) {
        if (a[row][col].abs() > a[pivot][col].abs()) pivot = row;
      }
      if (a[pivot][col].abs() < 1e-9) return null;
      final swap = a[col];
      a[col] = a[pivot];
      a[pivot] = swap;
      for (var row = 0; row < 8; row++) {
        if (row == col) continue;
        final factor = a[row][col] / a[col][col];
        if (factor == 0) continue;
        for (var k = col; k < 9; k++) {
          a[row][k] -= factor * a[col][k];
        }
      }
    }
    final h = [for (var i = 0; i < 8; i++) a[i][8] / a[i][i], 1.0];
    if (h.any((value) => value.isNaN || value.isInfinite)) return null;
    // A solution can exist and still collapse the plane onto a line (all four
    // corners collinear on one side): rows of H then become dependent.
    double rowNorm(int r) =>
        math.sqrt(h[r] * h[r] + h[r + 1] * h[r + 1] + h[r + 2] * h[r + 2]);
    final det =
        h[0] * (h[4] * h[8] - h[5] * h[7]) -
        h[1] * (h[3] * h[8] - h[5] * h[6]) +
        h[2] * (h[3] * h[7] - h[4] * h[6]);
    if (det.abs() < 1e-9 * rowNorm(0) * rowNorm(3) * rowNorm(6)) return null;
    return Homography(h);
  }

  ScanPoint apply(double x, double y) {
    final w = m[6] * x + m[7] * y + m[8];
    return ScanPoint(
      (m[0] * x + m[1] * y + m[2]) / w,
      (m[3] * x + m[4] * y + m[5]) / w,
    );
  }
}

/// Orders four corners as top-left, top-right, bottom-right, bottom-left,
/// whatever order the user dragged them in.
List<ScanPoint> orderCorners(List<ScanPoint> points) {
  assert(points.length == 4);
  ScanPoint pick(double Function(ScanPoint) score, {required bool max}) {
    var best = points.first;
    for (final p in points) {
      if (max ? score(p) > score(best) : score(p) < score(best)) best = p;
    }
    return best;
  }

  return [
    pick((p) => p.x + p.y, max: false),
    pick((p) => p.y - p.x, max: false),
    pick((p) => p.x + p.y, max: true),
    pick((p) => p.y - p.x, max: true),
  ];
}

/// Area of a polygon (shoelace), always positive.
double quadArea(List<ScanPoint> q) {
  var sum = 0.0;
  for (var i = 0; i < q.length; i++) {
    final a = q[i];
    final b = q[(i + 1) % q.length];
    sum += a.x * b.y - b.x * a.y;
  }
  return sum.abs() / 2;
}

/// True when the (ordered) quad is strictly convex: every turn goes the same
/// way, so the perspective warp has no fold.
bool isConvexQuad(List<ScanPoint> q) {
  if (q.length != 4) return false;
  var sign = 0;
  for (var i = 0; i < 4; i++) {
    final a = q[i];
    final b = q[(i + 1) % 4];
    final c = q[(i + 2) % 4];
    final cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
    if (cross.abs() < 1e-9) return false;
    final s = cross > 0 ? 1 : -1;
    if (sign == 0) {
      sign = s;
    } else if (s != sign) {
      return false;
    }
  }
  return true;
}

/// Size of the corrected page: the longer of each pair of opposite edges,
/// scaled down so the long side is at most [maxSide].
({int width, int height}) scanOutputSize(List<ScanPoint> q, int maxSide) {
  double dist(ScanPoint a, ScanPoint b) =>
      math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));
  var w = math.max(dist(q[0], q[1]), dist(q[3], q[2]));
  var h = math.max(dist(q[0], q[3]), dist(q[1], q[2]));
  final longSide = math.max(w, h);
  if (longSide > maxSide) {
    final k = maxSide / longSide;
    w *= k;
    h *= k;
  }
  return (width: math.max(1, w.round()), height: math.max(1, h.round()));
}

/// RGBA pixels as decoded from a photo.
class ScanRgba {
  ScanRgba(this.width, this.height, this.pixels)
    : assert(pixels.length == width * height * 4);

  final int width;
  final int height;
  final Uint8List pixels;
}

enum ScanPixelFormat { rgb, gray, bilevel }

/// A processed page: [rgb] is 3 bytes per pixel; [gray] and [bilevel] are one
/// byte per pixel ([bilevel] only holds 0 or 255).
class ScanBitmap {
  ScanBitmap(this.width, this.height, this.format, this.data)
    : assert(
        data.length == width * height * (format == ScanPixelFormat.rgb ? 3 : 1),
      );

  final int width;
  final int height;
  final ScanPixelFormat format;
  final Uint8List data;

  int get channels => format == ScanPixelFormat.rgb ? 3 : 1;
}

/// Maps every pixel of a [outW] x [outH] page back into [src] through the
/// homography of [quad] (top-left, top-right, bottom-right, bottom-left, in
/// source pixels) and samples it bilinearly. `null` for a degenerate quad.
ScanBitmap? warpPerspective(
  ScanRgba src,
  List<ScanPoint> quad,
  int outW,
  int outH,
) {
  final h = Homography.fromQuads([
    const ScanPoint(0, 0),
    ScanPoint(outW.toDouble(), 0),
    ScanPoint(outW.toDouble(), outH.toDouble()),
    ScanPoint(0, outH.toDouble()),
  ], quad);
  if (h == null) return null;
  final m = h.m;
  final sw = src.width;
  final sh = src.height;
  final px = src.pixels;
  final maxX = (sw - 1).toDouble();
  final maxY = (sh - 1).toDouble();
  final out = Uint8List(outW * outH * 3);
  var o = 0;
  for (var y = 0; y < outH; y++) {
    final yc = y + 0.5;
    // Numerators and denominator at the centre of the first pixel of the row.
    var nx = m[1] * yc + m[2] + m[0] * 0.5;
    var ny = m[4] * yc + m[5] + m[3] * 0.5;
    var dn = m[7] * yc + 1 + m[6] * 0.5;
    for (var x = 0; x < outW; x++) {
      final inv = 1 / (dn.abs() < 1e-12 ? 1e-12 : dn);
      var sx = nx * inv - 0.5;
      var sy = ny * inv - 0.5;
      if (sx < 0 || sx.isNaN) sx = 0;
      if (sy < 0 || sy.isNaN) sy = 0;
      if (sx > maxX) sx = maxX;
      if (sy > maxY) sy = maxY;
      final x0 = sx.floor();
      final y0 = sy.floor();
      final x1 = x0 + 1 < sw ? x0 + 1 : x0;
      final y1 = y0 + 1 < sh ? y0 + 1 : y0;
      final fx = sx - x0;
      final fy = sy - y0;
      final w00 = (1 - fx) * (1 - fy);
      final w10 = fx * (1 - fy);
      final w01 = (1 - fx) * fy;
      final w11 = fx * fy;
      final i00 = (y0 * sw + x0) * 4;
      final i10 = (y0 * sw + x1) * 4;
      final i01 = (y1 * sw + x0) * 4;
      final i11 = (y1 * sw + x1) * 4;
      for (var c = 0; c < 3; c++) {
        out[o++] =
            (px[i00 + c] * w00 +
                    px[i10 + c] * w10 +
                    px[i01 + c] * w01 +
                    px[i11 + c] * w11 +
                    0.5)
                .toInt();
      }
      nx += m[0];
      ny += m[3];
      dn += m[6];
    }
  }
  return ScanBitmap(outW, outH, ScanPixelFormat.rgb, out);
}

/// Bilinear resize of any bitmap.
ScanBitmap scaleBitmap(ScanBitmap src, int newW, int newH) {
  final c = src.channels;
  final out = Uint8List(newW * newH * c);
  final sx = src.width / newW;
  final sy = src.height / newH;
  final d = src.data;
  var o = 0;
  for (var y = 0; y < newH; y++) {
    final fy0 = math.max(0.0, math.min((y + 0.5) * sy - 0.5, src.height - 1.0));
    final y0 = fy0.floor();
    final y1 = math.min(y0 + 1, src.height - 1);
    final wy = fy0 - y0;
    for (var x = 0; x < newW; x++) {
      final fx0 = math.max(
        0.0,
        math.min((x + 0.5) * sx - 0.5, src.width - 1.0),
      );
      final x0 = fx0.floor();
      final x1 = math.min(x0 + 1, src.width - 1);
      final wx = fx0 - x0;
      for (var k = 0; k < c; k++) {
        final a = d[(y0 * src.width + x0) * c + k];
        final b = d[(y0 * src.width + x1) * c + k];
        final e = d[(y1 * src.width + x0) * c + k];
        final f = d[(y1 * src.width + x1) * c + k];
        final top = a + (b - a) * wx;
        final bottom = e + (f - e) * wx;
        out[o++] = (top + (bottom - top) * wy + 0.5).toInt();
      }
    }
  }
  return ScanBitmap(newW, newH, src.format, out);
}

/// Clockwise quarter turns (0..3, any int is reduced).
ScanBitmap rotateQuarterTurns(ScanBitmap src, int turns) {
  final t = turns % 4;
  if (t == 0) return src;
  final c = src.channels;
  final w = src.width;
  final h = src.height;
  final swap = t.isOdd;
  final nw = swap ? h : w;
  final nh = swap ? w : h;
  final out = Uint8List(nw * nh * c);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final int dx;
      final int dy;
      switch (t) {
        case 1:
          dx = h - 1 - y;
          dy = x;
        case 2:
          dx = w - 1 - x;
          dy = h - 1 - y;
        default:
          dx = y;
          dy = w - 1 - x;
      }
      final s = (y * w + x) * c;
      final d = (dy * nw + dx) * c;
      for (var k = 0; k < c; k++) {
        out[d + k] = src.data[s + k];
      }
    }
  }
  return ScanBitmap(nw, nh, src.format, out);
}

enum ScanFilter { original, grayscale, contrast, blackWhite }

Uint8List _luma(ScanBitmap src) {
  if (src.format != ScanPixelFormat.rgb) return src.data;
  final n = src.width * src.height;
  final gray = Uint8List(n);
  final d = src.data;
  for (var i = 0, j = 0; i < n; i++, j += 3) {
    gray[i] = (d[j] * 77 + d[j + 1] * 151 + d[j + 2] * 28) >> 8;
  }
  return gray;
}

/// Mean of the (2r+1) square window around every pixel, through an integral
/// image: O(n) whatever the radius.
Uint8List _boxMean(Uint8List gray, int w, int h, int r) {
  final stride = w + 1;
  final integral = Int32List(stride * (h + 1));
  for (var y = 0; y < h; y++) {
    var rowSum = 0;
    for (var x = 0; x < w; x++) {
      rowSum += gray[y * w + x];
      integral[(y + 1) * stride + x + 1] =
          integral[y * stride + x + 1] + rowSum;
    }
  }
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final y0 = math.max(0, y - r);
    final y1 = math.min(h, y + r + 1);
    for (var x = 0; x < w; x++) {
      final x0 = math.max(0, x - r);
      final x1 = math.min(w, x + r + 1);
      final sum =
          integral[y1 * stride + x1] -
          integral[y0 * stride + x1] -
          integral[y1 * stride + x0] +
          integral[y0 * stride + x0];
      out[y * w + x] = sum ~/ ((x1 - x0) * (y1 - y0));
    }
  }
  return out;
}

int _windowRadius(int w, int h) => math.max(8, math.min(w, h) ~/ 16);

/// Applies [filter] to an RGB page.
ScanBitmap applyScanFilter(ScanBitmap src, ScanFilter filter) {
  final w = src.width;
  final h = src.height;
  switch (filter) {
    case ScanFilter.original:
      return src;
    case ScanFilter.grayscale:
      return ScanBitmap(w, h, ScanPixelFormat.gray, _luma(src));
    case ScanFilter.contrast:
      return _contrast(src);
    case ScanFilter.blackWhite:
      return _blackWhite(src);
  }
}

ScanBitmap _contrast(ScanBitmap src) {
  final w = src.width;
  final h = src.height;
  final gray = _luma(src);
  final background = _boxMean(gray, w, h, _windowRadius(w, h));
  final flat = Uint8List(w * h);
  final histogram = List<int>.filled(256, 0);
  for (var i = 0; i < flat.length; i++) {
    final bg = background[i] < 1 ? 1 : background[i];
    final v = math.min(255, gray[i] * 255 ~/ bg);
    flat[i] = v;
    histogram[v]++;
  }
  // Black point at the 1st percentile; paper (near the white point)
  // saturates to pure white.
  var seen = 0;
  var low = 0;
  final target = flat.length ~/ 100;
  while (low < 255 && seen + histogram[low] <= target) {
    seen += histogram[low];
    low++;
  }
  const high = 235;
  if (high - low > 16) {
    for (var i = 0; i < flat.length; i++) {
      final v = (flat[i] - low) * 255 ~/ (high - low);
      flat[i] = v < 0 ? 0 : (v > 255 ? 255 : v);
    }
  }
  return ScanBitmap(w, h, ScanPixelFormat.gray, flat);
}

ScanBitmap _blackWhite(ScanBitmap src) {
  final w = src.width;
  final h = src.height;
  final gray = _luma(src);
  final background = _boxMean(gray, w, h, _windowRadius(w, h));
  final out = Uint8List(w * h);
  for (var i = 0; i < out.length; i++) {
    // Ink is anything clearly darker than its own neighbourhood.
    out[i] = gray[i] * 100 < background[i] * 88 ? 0 : 255;
  }
  return ScanBitmap(w, h, ScanPixelFormat.bilevel, out);
}

// ---------------------------------------------------------------------------
// PNG
// ---------------------------------------------------------------------------

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();

int crc32(List<int> bytes, [int crc = 0]) {
  var c = crc ^ 0xffffffff;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return (c ^ 0xffffffff) & 0xffffffff;
}

/// Pixel rows exactly as stored in a PNG or PDF image: bytes per pixel as in
/// the format, bilevel packed eight pixels to a byte (1 = white).
Uint8List _packedRows(ScanBitmap b) {
  if (b.format != ScanPixelFormat.bilevel) return b.data;
  final rowBytes = (b.width + 7) >> 3;
  final out = Uint8List(rowBytes * b.height);
  for (var y = 0; y < b.height; y++) {
    for (var x = 0; x < b.width; x++) {
      if (b.data[y * b.width + x] >= 128) {
        out[y * rowBytes + (x >> 3)] |= 0x80 >> (x & 7);
      }
    }
  }
  return out;
}

int _rowBytes(ScanBitmap b) => switch (b.format) {
  ScanPixelFormat.rgb => b.width * 3,
  ScanPixelFormat.gray => b.width,
  ScanPixelFormat.bilevel => (b.width + 7) >> 3,
};

Uint8List encodePng(ScanBitmap bitmap) {
  final rows = _packedRows(bitmap);
  final rowBytes = _rowBytes(bitmap);
  // "Up" filter: scans of paper repeat vertically, which deflates much better.
  final filtered = Uint8List((rowBytes + 1) * bitmap.height);
  for (var y = 0; y < bitmap.height; y++) {
    final dst = y * (rowBytes + 1);
    filtered[dst] = 2;
    for (var i = 0; i < rowBytes; i++) {
      final cur = rows[y * rowBytes + i];
      final above = y == 0 ? 0 : rows[(y - 1) * rowBytes + i];
      filtered[dst + 1 + i] = (cur - above) & 0xff;
    }
  }
  final out = BytesBuilder(copy: false)
    ..add(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  void chunk(String type, List<int> data) {
    final typeBytes = ascii.encode(type);
    out
      ..add(_u32(data.length))
      ..add(typeBytes)
      ..add(data)
      ..add(_u32(crc32(data, crc32(typeBytes))));
  }

  final header = BytesBuilder()
    ..add(_u32(bitmap.width))
    ..add(_u32(bitmap.height))
    ..addByte(bitmap.format == ScanPixelFormat.bilevel ? 1 : 8)
    ..addByte(bitmap.format == ScanPixelFormat.rgb ? 2 : 0)
    ..add(const [0, 0, 0]);
  chunk('IHDR', header.toBytes());
  chunk('IDAT', zlib.encode(filtered));
  chunk('IEND', const []);
  return out.toBytes();
}

Uint8List _u32(int v) => Uint8List.fromList([
  (v >> 24) & 0xff,
  (v >> 16) & 0xff,
  (v >> 8) & 0xff,
  v & 0xff,
]);

/// Encodes [bitmap] as PNG, shrinking it by a quarter at a time until it fits
/// in [maxBytes] (a colour photo of a page can be several MB).
Uint8List encodePngWithin(ScanBitmap bitmap, int maxBytes) {
  var current = bitmap;
  var png = encodePng(current);
  while (png.length > maxBytes &&
      math.min(current.width, current.height) > 240) {
    current = scaleBitmap(
      current,
      math.max(1, current.width * 3 ~/ 4),
      math.max(1, current.height * 3 ~/ 4),
    );
    png = encodePng(current);
  }
  return png;
}

// ---------------------------------------------------------------------------
// PDF
// ---------------------------------------------------------------------------

/// A minimal PDF: one page per bitmap, the image Flate-compressed and
/// stretched over an A4-wide page of the same aspect ratio.
Uint8List buildPdf(List<ScanBitmap> pages) {
  const pageWidth = 595;
  final out = BytesBuilder(copy: false);
  final offsets = <int>[];
  var length = 0;
  void write(List<int> bytes) {
    out.add(bytes);
    length += bytes.length;
  }

  void writeText(String text) => write(latin1.encode(text));
  void begin(int id) {
    offsets.add(length);
    writeText('$id 0 obj\n');
  }

  writeText('%PDF-1.4\n');
  write(const [0x25, 0xe2, 0xe3, 0xcf, 0xd3, 0x0a]);
  begin(1);
  writeText('<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');
  begin(2);
  final kids = [for (var i = 0; i < pages.length; i++) '${3 + 3 * i} 0 R'];
  writeText(
    '<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${pages.length} >>\n'
    'endobj\n',
  );
  for (var i = 0; i < pages.length; i++) {
    final b = pages[i];
    final pageId = 3 + 3 * i;
    final pageHeight = math.max(1, (pageWidth * b.height / b.width).round());
    begin(pageId);
    writeText(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $pageWidth $pageHeight] '
      '/Resources << /XObject << /Im0 ${pageId + 2} 0 R >> >> '
      '/Contents ${pageId + 1} 0 R >>\nendobj\n',
    );
    final content = latin1.encode(
      'q $pageWidth 0 0 $pageHeight 0 0 cm /Im0 Do Q',
    );
    begin(pageId + 1);
    writeText('<< /Length ${content.length} >>\nstream\n');
    write(content);
    writeText('\nendstream\nendobj\n');
    final data = zlib.encode(_packedRows(b));
    final space = b.format == ScanPixelFormat.rgb
        ? '/DeviceRGB'
        : '/DeviceGray';
    final depth = b.format == ScanPixelFormat.bilevel ? 1 : 8;
    begin(pageId + 2);
    writeText(
      '<< /Type /XObject /Subtype /Image /Width ${b.width} /Height ${b.height} '
      '/ColorSpace $space /BitsPerComponent $depth /Filter /FlateDecode '
      '/Length ${data.length} >>\nstream\n',
    );
    write(data);
    writeText('\nendstream\nendobj\n');
  }
  final xrefAt = length;
  final count = offsets.length + 1;
  final xref = StringBuffer('xref\n0 $count\n0000000000 65535 f \n');
  for (final offset in offsets) {
    xref.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  writeText(xref.toString());
  writeText(
    'trailer\n<< /Size $count /Root 1 0 R >>\nstartxref\n$xrefAt\n%%EOF\n',
  );
  return out.toBytes();
}

/// Builds a PDF no larger than [maxBytes], shrinking every page by a quarter
/// at a time if needed.
Uint8List buildPdfWithin(List<ScanBitmap> pages, int maxBytes) {
  var current = pages;
  var pdf = buildPdf(current);
  var guard = 0;
  while (pdf.length > maxBytes && guard++ < 6) {
    current = [
      for (final b in current)
        scaleBitmap(
          b,
          math.max(1, b.width * 3 ~/ 4),
          math.max(1, b.height * 3 ~/ 4),
        ),
    ];
    pdf = buildPdf(current);
  }
  return pdf;
}

// ---------------------------------------------------------------------------
// Isolate jobs: plain request objects, top-level entry points.
// ---------------------------------------------------------------------------

class ScanWarpRequest {
  const ScanWarpRequest(
    this.source,
    this.quad,
    this.fullMaxSide,
    this.previewMaxSide,
  );

  final ScanRgba source;

  /// Top-left, top-right, bottom-right, bottom-left in source pixels.
  final List<ScanPoint> quad;
  final int fullMaxSide;
  final int previewMaxSide;
}

class ScanWarpResult {
  const ScanWarpResult(this.full, this.preview);

  final ScanBitmap full;
  final ScanBitmap preview;
}

/// Corrects the perspective once for the export size and once for the preview.
/// `null` when the quad cannot be warped.
ScanWarpResult? runScanWarp(ScanWarpRequest request) {
  final full = scanOutputSize(request.quad, request.fullMaxSide);
  final fullBitmap = warpPerspective(
    request.source,
    request.quad,
    full.width,
    full.height,
  );
  if (fullBitmap == null) return null;
  final small = scanOutputSize(request.quad, request.previewMaxSide);
  final preview = small.width >= full.width
      ? fullBitmap
      : warpPerspective(
          request.source,
          request.quad,
          small.width,
          small.height,
        );
  if (preview == null) return null;
  return ScanWarpResult(fullBitmap, preview);
}

/// One page to render: the corrected bitmap with its filter and rotation.
class ScanRenderRequest {
  const ScanRenderRequest(this.bitmap, this.filter, this.turns);

  final ScanBitmap bitmap;
  final ScanFilter filter;
  final int turns;
}

ScanBitmap renderScanPage(ScanRenderRequest r) =>
    rotateQuarterTurns(applyScanFilter(r.bitmap, r.filter), r.turns);

/// PNG of a page for the preview.
Uint8List renderScanPreviewPng(ScanRenderRequest r) =>
    encodePng(renderScanPage(r));

class ScanExportRequest {
  const ScanExportRequest(this.pages, this.pdf, this.maxBytesPerFile);

  final List<ScanRenderRequest> pages;
  final bool pdf;
  final int maxBytesPerFile;
}

/// One PNG per page, or a single PDF with all of them.
List<Uint8List> runScanExport(ScanExportRequest request) {
  final rendered = [for (final page in request.pages) renderScanPage(page)];
  if (request.pdf) {
    return [buildPdfWithin(rendered, request.maxBytesPerFile)];
  }
  return [
    for (final bitmap in rendered)
      encodePngWithin(bitmap, request.maxBytesPerFile),
  ];
}

/// Runs a computation somewhere else (an isolate in the app, inline in
/// tests). The computation must only capture sendable values.
typedef ScanRunner = Future<R> Function<R>(FutureOr<R> Function() computation);

// The helpers below are top-level on purpose: their closures capture only the
// request, never a State, so the isolate can copy them.
Future<ScanWarpResult?> scanWarpOn(ScanRunner run, ScanWarpRequest request) =>
    run(() => runScanWarp(request));

Future<Uint8List> scanPreviewOn(ScanRunner run, ScanRenderRequest request) =>
    run(() => renderScanPreviewPng(request));

Future<List<Uint8List>> scanExportOn(
  ScanRunner run,
  ScanExportRequest request,
) => run(() => runScanExport(request));
