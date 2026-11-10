import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/scan/scan_image_ops.dart';
import 'package:hermes_android/core/scan/scan_platform.dart';

const _tl = ScanPoint(0, 0);

ScanRgba _solid(int w, int h, int r, int g, int b) {
  final px = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    px[i * 4] = r;
    px[i * 4 + 1] = g;
    px[i * 4 + 2] = b;
    px[i * 4 + 3] = 255;
  }
  return ScanRgba(w, h, px);
}

bool _inside(List<ScanPoint> q, double x, double y) {
  var sign = 0;
  for (var i = 0; i < q.length; i++) {
    final a = q[i];
    final b = q[(i + 1) % q.length];
    final cross = (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x);
    final s = cross >= 0 ? 1 : -1;
    if (sign == 0) sign = s;
    if (s != sign) return false;
  }
  return true;
}

/// Black photo with a white skewed page inside [quad].
ScanRgba _photoOfPage(int w, int h, List<ScanPoint> quad) {
  final image = _solid(w, h, 0, 0, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (_inside(quad, x + 0.5, y + 0.5)) {
        final i = (y * w + x) * 4;
        image.pixels[i] = 255;
        image.pixels[i + 1] = 255;
        image.pixels[i + 2] = 255;
      }
    }
  }
  return image;
}

ScanBitmap _gradient(int w, int h) {
  final data = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 3;
      data[i] = (x * 255 ~/ math.max(1, w - 1));
      data[i + 1] = (y * 255 ~/ math.max(1, h - 1));
      data[i + 2] = 128;
    }
  }
  return ScanBitmap(w, h, ScanPixelFormat.rgb, data);
}

/// Parses a PNG: checks every chunk CRC and returns header fields plus the
/// unfiltered pixel rows.
({int width, int height, int depth, int colorType, Uint8List rows}) _readPng(
  Uint8List png,
) {
  expect(png.sublist(0, 8), [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  final view = ByteData.sublistView(png);
  var offset = 8;
  var width = 0, height = 0, depth = 0, colorType = 0;
  final idat = BytesBuilder();
  var sawEnd = false;
  while (offset < png.length) {
    final length = view.getUint32(offset);
    final type = ascii.decode(png.sublist(offset + 4, offset + 8));
    final data = png.sublist(offset + 8, offset + 8 + length);
    final crc = view.getUint32(offset + 8 + length);
    expect(
      crc32(png.sublist(offset + 4, offset + 8 + length)),
      crc,
      reason: type,
    );
    if (type == 'IHDR') {
      final h = ByteData.sublistView(Uint8List.fromList(data));
      width = h.getUint32(0);
      height = h.getUint32(4);
      depth = data[8];
      colorType = data[9];
    } else if (type == 'IDAT') {
      idat.add(data);
    } else if (type == 'IEND') {
      sawEnd = true;
    }
    offset += 12 + length;
  }
  expect(sawEnd, isTrue);
  expect(offset, png.length);
  final raw = Uint8List.fromList(zlib.decode(idat.toBytes()));
  final bits = depth * (colorType == 2 ? 3 : 1);
  final rowBytes = (width * bits + 7) >> 3;
  expect(raw.length, (rowBytes + 1) * height);
  final rows = Uint8List(rowBytes * height);
  for (var y = 0; y < height; y++) {
    expect(raw[y * (rowBytes + 1)], 2, reason: 'Up filter');
    for (var i = 0; i < rowBytes; i++) {
      final above = y == 0 ? 0 : rows[(y - 1) * rowBytes + i];
      rows[y * rowBytes + i] = (raw[y * (rowBytes + 1) + 1 + i] + above) & 0xff;
    }
  }
  return (
    width: width,
    height: height,
    depth: depth,
    colorType: colorType,
    rows: rows,
  );
}

void main() {
  group('homography', () {
    test('sends each source corner to its target', () {
      const from = [
        _tl,
        ScanPoint(100, 0),
        ScanPoint(100, 200),
        ScanPoint(0, 200),
      ];
      const to = [
        ScanPoint(12, 8),
        ScanPoint(310, 30),
        ScanPoint(280, 420),
        ScanPoint(5, 380),
      ];
      final h = Homography.fromQuads(from, to)!;
      for (var i = 0; i < 4; i++) {
        final p = h.apply(from[i].x, from[i].y);
        expect(p.x, closeTo(to[i].x, 1e-6));
        expect(p.y, closeTo(to[i].y, 1e-6));
      }
      expect(h.m[8], 1);
    });

    test('identity quads give the identity map', () {
      const quad = [_tl, ScanPoint(50, 0), ScanPoint(50, 40), ScanPoint(0, 40)];
      final h = Homography.fromQuads(quad, quad)!;
      final p = h.apply(17, 23);
      expect(p.x, closeTo(17, 1e-9));
      expect(p.y, closeTo(23, 1e-9));
    });

    test('an interior point follows the perspective, not a bilinear blend', () {
      // A trapezoid: the top edge is half as wide as the bottom one.
      const from = [
        _tl,
        ScanPoint(100, 0),
        ScanPoint(100, 100),
        ScanPoint(0, 100),
      ];
      const to = [
        ScanPoint(25, 0),
        ScanPoint(75, 0),
        ScanPoint(100, 100),
        ScanPoint(0, 100),
      ];
      final h = Homography.fromQuads(from, to)!;
      // Horizontal midline of the source stays centred at x = 50 ...
      final mid = h.apply(50, 50);
      expect(mid.x, closeTo(50, 1e-6));
      // ... and, by projective foreshortening, the far (narrow) half is
      // compressed: the midpoint lands at 100 * 50 / 150, not at 50.
      expect(mid.y, closeTo(33.3333, 1e-3));
    });

    test('degenerate quads have no homography', () {
      const collinear = [
        _tl,
        ScanPoint(10, 0),
        ScanPoint(20, 0),
        ScanPoint(30, 0),
      ];
      const quad = [_tl, ScanPoint(10, 0), ScanPoint(10, 10), ScanPoint(0, 10)];
      expect(Homography.fromQuads(quad, collinear), isNull);
      expect(Homography.fromQuads(collinear, quad), isNull);
      expect(Homography.fromQuads(quad.sublist(0, 3), quad), isNull);
    });
  });

  group('quad helpers', () {
    test('orderCorners ignores the order the corners were given in', () {
      const tl = ScanPoint(10, 12);
      const tr = ScanPoint(90, 8);
      const br = ScanPoint(95, 70);
      const bl = ScanPoint(4, 66);
      for (final shuffled in [
        [br, tl, bl, tr],
        [bl, br, tr, tl],
        [tr, bl, tl, br],
      ]) {
        expect(orderCorners(shuffled), [tl, tr, br, bl]);
      }
    });

    test('convexity and area', () {
      const square = [
        _tl,
        ScanPoint(10, 0),
        ScanPoint(10, 10),
        ScanPoint(0, 10),
      ];
      expect(isConvexQuad(square), isTrue);
      expect(quadArea(square), 100);
      const bowtie = [
        _tl,
        ScanPoint(10, 10),
        ScanPoint(10, 0),
        ScanPoint(0, 10),
      ];
      expect(isConvexQuad(bowtie), isFalse);
      const dent = [_tl, ScanPoint(10, 0), ScanPoint(2, 2), ScanPoint(0, 10)];
      expect(isConvexQuad(dent), isFalse);
      const flat = [_tl, ScanPoint(5, 0), ScanPoint(10, 0), ScanPoint(0, 10)];
      expect(isConvexQuad(flat), isFalse);
    });

    test('output size uses the longer opposite edges and respects the cap', () {
      const q = [
        _tl,
        ScanPoint(300, 0),
        ScanPoint(280, 400),
        ScanPoint(0, 380),
      ];
      final size = scanOutputSize(q, 2000);
      expect(size.width, 300);
      expect(size.height, closeTo(400, 1));
      final capped = scanOutputSize(q, 200);
      expect(math.max(capped.width, capped.height), 200);
      expect(capped.width / capped.height, closeTo(300 / 400, 0.02));
    });
  });

  group('warp', () {
    test('a full-frame quad reproduces the photo', () {
      final src = _solid(40, 30, 0, 0, 0);
      for (var y = 0; y < 30; y++) {
        for (var x = 0; x < 40; x++) {
          final i = (y * 40 + x) * 4;
          src.pixels[i] = x * 6;
          src.pixels[i + 1] = y * 8;
          src.pixels[i + 2] = 99;
        }
      }
      final out = warpPerspective(
        src,
        const [_tl, ScanPoint(40, 0), ScanPoint(40, 30), ScanPoint(0, 30)],
        40,
        30,
      )!;
      for (var y = 0; y < 30; y++) {
        for (var x = 0; x < 40; x++) {
          final i = (y * 40 + x) * 3;
          expect(out.data[i], src.pixels[(y * 40 + x) * 4], reason: '$x,$y');
          expect(out.data[i + 1], src.pixels[(y * 40 + x) * 4 + 1]);
        }
      }
    });

    test('an axis-aligned sub-quad crops exactly that region', () {
      final src = _solid(60, 60, 0, 0, 0);
      for (var y = 20; y < 40; y++) {
        for (var x = 10; x < 50; x++) {
          src.pixels[(y * 60 + x) * 4] = 200;
        }
      }
      final out = warpPerspective(
        src,
        const [
          ScanPoint(10, 20),
          ScanPoint(50, 20),
          ScanPoint(50, 40),
          ScanPoint(10, 40),
        ],
        40,
        20,
      )!;
      expect(out.data.every((v) => v == 200 || v == 0), isTrue);
      // Red channel is 200 everywhere, the other two stay 0.
      for (var i = 0; i < 40 * 20; i++) {
        expect(out.data[i * 3], 200);
        expect(out.data[i * 3 + 1], 0);
      }
    });

    test('a skewed page becomes a flat white rectangle', () {
      const page = [
        ScanPoint(30, 14),
        ScanPoint(170, 30),
        ScanPoint(150, 160),
        ScanPoint(12, 130),
      ];
      final photo = _photoOfPage(200, 180, page);
      final size = scanOutputSize(page, 2000);
      final out = warpPerspective(photo, page, size.width, size.height)!;
      // The inner 90% of the corrected page is entirely paper.
      final mx = (out.width * 0.05).ceil();
      final my = (out.height * 0.05).ceil();
      for (var y = my; y < out.height - my; y++) {
        for (var x = mx; x < out.width - mx; x++) {
          expect(
            out.data[(y * out.width + x) * 3],
            greaterThan(240),
            reason: '$x,$y',
          );
        }
      }
    });

    test('a degenerate quad cannot be warped', () {
      final src = _solid(10, 10, 1, 2, 3);
      expect(
        warpPerspective(
          src,
          const [_tl, ScanPoint(5, 5), ScanPoint(10, 10), ScanPoint(2, 2)],
          10,
          10,
        ),
        isNull,
      );
    });

    test('rotation by quarter turns moves pixels and swaps the size', () {
      final b = ScanBitmap(
        3,
        2,
        ScanPixelFormat.gray,
        Uint8List.fromList([1, 2, 3, 4, 5, 6]),
      );
      final cw = rotateQuarterTurns(b, 1);
      expect((cw.width, cw.height), (2, 3));
      expect(cw.data, [4, 1, 5, 2, 6, 3]);
      expect(rotateQuarterTurns(b, 2).data, [6, 5, 4, 3, 2, 1]);
      expect(rotateQuarterTurns(b, 3).data, [3, 6, 2, 5, 1, 4]);
      expect(identical(rotateQuarterTurns(b, 4), b), isTrue);
      expect(rotateQuarterTurns(rotateQuarterTurns(b, 1), 3).data, b.data);
    });

    test('scaleBitmap keeps format and flat colour', () {
      final b = ScanBitmap(
        8,
        8,
        ScanPixelFormat.rgb,
        Uint8List.fromList(List.filled(8 * 8 * 3, 77)),
      );
      final s = scaleBitmap(b, 3, 5);
      expect((s.width, s.height, s.format), (3, 5, ScanPixelFormat.rgb));
      expect(s.data.every((v) => v == 77), isTrue);
    });
  });

  group('filters', () {
    // A page with a strong left-to-right shadow and a dark line of "text".
    ScanBitmap shadowedPage() {
      const w = 160, h = 120;
      final d = Uint8List(w * h * 3);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          var v = 235 - x * 100 ~/ w; // 235 -> ~135
          if (y >= 58 && y < 62 && x >= 20 && x < 140) v = v ~/ 4;
          final i = (y * w + x) * 3;
          d[i] = d[i + 1] = d[i + 2] = v;
        }
      }
      return ScanBitmap(w, h, ScanPixelFormat.rgb, d);
    }

    test('original keeps the pixels, grayscale drops to one channel', () {
      final src = _gradient(10, 10);
      expect(identical(applyScanFilter(src, ScanFilter.original), src), isTrue);
      final gray = applyScanFilter(src, ScanFilter.grayscale);
      expect(gray.format, ScanPixelFormat.gray);
      expect(gray.data.length, 100);
    });

    test('contrast flattens the shadow and keeps the ink dark', () {
      final out = applyScanFilter(shadowedPage(), ScanFilter.contrast);
      expect(out.format, ScanPixelFormat.gray);
      int at(int x, int y) => out.data[y * out.width + x];
      // Paper at both ends of the shadow is near white.
      expect(at(5, 20), greaterThan(225));
      expect(at(150, 20), greaterThan(225));
      // The line stays far darker than the paper.
      expect(at(80, 60), lessThan(120));
    });

    test(
      'black and white is strictly two-level and separates ink from paper',
      () {
        final out = applyScanFilter(shadowedPage(), ScanFilter.blackWhite);
        expect(out.format, ScanPixelFormat.bilevel);
        expect(out.data.every((v) => v == 0 || v == 255), isTrue);
        expect(out.data[20 * out.width + 5], 255);
        expect(out.data[20 * out.width + 150], 255);
        expect(out.data[60 * out.width + 80], 0);
      },
    );

    test('a blank sheet stays blank in black and white', () {
      final blank = ScanBitmap(
        50,
        50,
        ScanPixelFormat.rgb,
        Uint8List.fromList(List.filled(50 * 50 * 3, 180)),
      );
      final out = applyScanFilter(blank, ScanFilter.blackWhite);
      expect(out.data.every((v) => v == 255), isTrue);
    });
  });

  group('PNG', () {
    test('RGB round-trips through a CRC-valid file', () {
      final src = _gradient(37, 23);
      final png = _readPng(encodePng(src));
      expect((png.width, png.height, png.depth, png.colorType), (37, 23, 8, 2));
      expect(png.rows, src.data);
    });

    test('gray round-trips', () {
      final applied = applyScanFilter(_gradient(20, 20), ScanFilter.grayscale);
      final png = _readPng(encodePng(applied));
      expect((png.depth, png.colorType), (8, 0));
      expect(png.rows, applied.data);
    });

    test('bilevel packs eight pixels per byte, white = 1', () {
      final data = Uint8List(10 * 2);
      for (var i = 0; i < data.length; i++) {
        data[i] = i.isEven ? 255 : 0;
      }
      final png = _readPng(
        encodePng(ScanBitmap(10, 2, ScanPixelFormat.bilevel, data)),
      );
      expect((png.width, png.height, png.depth, png.colorType), (10, 2, 1, 0));
      // Row of 10 pixels = 2 bytes: 1010 1010 | 10 + padding.
      expect(png.rows, [0xaa, 0x80, 0xaa, 0x80]);
    });

    test('encodePngWithin shrinks a heavy page until it fits', () {
      final random = math.Random(7);
      final noise = ScanBitmap(
        600,
        600,
        ScanPixelFormat.rgb,
        Uint8List.fromList(
          List.generate(600 * 600 * 3, (_) => random.nextInt(256)),
        ),
      );
      final png = encodePngWithin(noise, 200 * 1024);
      expect(png.length, lessThanOrEqualTo(200 * 1024));
      expect(_readPng(png).width, lessThan(600));
      // A page that already fits is left alone.
      expect(_readPng(encodePngWithin(_gradient(30, 30), 1 << 20)).width, 30);
    });
  });

  group('PDF', () {
    test('has a valid cross-reference table and one page per bitmap', () {
      final pages = [
        _gradient(30, 40),
        applyScanFilter(_gradient(50, 20), ScanFilter.blackWhite),
        applyScanFilter(_gradient(20, 20), ScanFilter.grayscale),
      ];
      final bytes = buildPdf(pages);
      final text = latin1.decode(bytes);
      expect(text, startsWith('%PDF-1.4'));
      expect(text.trimRight(), endsWith('%%EOF'));
      expect(text, contains('/Count 3'));
      expect(text, contains('/DeviceRGB'));
      expect(text, contains('/BitsPerComponent 1'));
      expect(text, contains('/MediaBox [0 0 595 793]')); // 595 * 40 / 30

      final startxref = int.parse(
        RegExp(r'startxref\n(\d+)\n').firstMatch(text)!.group(1)!,
      );
      expect(text.substring(startxref, startxref + 4), 'xref');
      final entries = RegExp(r'(\d{10}) 00000 n \n').allMatches(text).toList();
      expect(entries.length, 2 + 3 * 3);
      for (var i = 0; i < entries.length; i++) {
        final offset = int.parse(entries[i].group(1)!);
        expect(
          text.substring(offset).startsWith('${i + 1} 0 obj'),
          isTrue,
          reason: 'object ${i + 1}',
        );
      }
      expect(text, contains('/Size ${entries.length + 1}'));
    });

    test('image stream length matches and inflates to the raw pixels', () {
      final page = _gradient(16, 8);
      final bytes = buildPdf([page]);
      final text = latin1.decode(bytes);
      final match = RegExp(r'/Length (\d+) >>\nstream\n').allMatches(text).last;
      final length = int.parse(match.group(1)!);
      final start = match.end;
      expect(
        text.substring(start + length, start + length + 10),
        startsWith('\nendstream'),
      );
      expect(zlib.decode(bytes.sublist(start, start + length)), page.data);
    });

    test('buildPdfWithin shrinks pages to fit the budget', () {
      final random = math.Random(3);
      final noise = ScanBitmap(
        500,
        500,
        ScanPixelFormat.rgb,
        Uint8List.fromList(
          List.generate(500 * 500 * 3, (_) => random.nextInt(256)),
        ),
      );
      final pdf = buildPdfWithin([noise], 300 * 1024);
      expect(pdf.length, lessThanOrEqualTo(300 * 1024));
    });
  });

  group('isolate jobs', () {
    final page = [
      const ScanPoint(20, 10),
      const ScanPoint(150, 20),
      const ScanPoint(140, 120),
      const ScanPoint(10, 110),
    ];

    test('the whole pipeline runs through a real isolate', () async {
      final photo = _photoOfPage(180, 140, page);
      final warped = await scanWarpOn(
        runScanOnIsolate,
        ScanWarpRequest(photo, page, 2000, 60),
      );
      expect(warped, isNotNull);
      expect(warped!.preview.width, lessThanOrEqualTo(60));
      expect(warped.preview.height, lessThanOrEqualTo(60));
      expect(warped.full.width, greaterThan(warped.preview.width));

      final preview = await scanPreviewOn(
        runScanOnIsolate,
        ScanRenderRequest(warped.preview, ScanFilter.contrast, 1),
      );
      expect(_readPng(preview).width, warped.preview.height);

      final images = await scanExportOn(
        runScanOnIsolate,
        ScanExportRequest(
          [
            ScanRenderRequest(warped.full, ScanFilter.blackWhite, 0),
            ScanRenderRequest(warped.full, ScanFilter.original, 2),
          ],
          false,
          5 << 20,
        ),
      );
      expect(images, hasLength(2));
      expect(_readPng(images[0]).depth, 1);
      expect(_readPng(images[1]).colorType, 2);

      final pdf = await scanExportOn(
        runScanOnIsolate,
        ScanExportRequest(
          [ScanRenderRequest(warped.full, ScanFilter.grayscale, 0)],
          true,
          5 << 20,
        ),
      );
      expect(latin1.decode(pdf.single).startsWith('%PDF-1.4'), isTrue);
    });

    test(
      'the inline runner gives the same answer as the isolate one',
      () async {
        final photo = _photoOfPage(180, 140, page);
        final request = ScanWarpRequest(photo, page, 2000, 60);
        final a = await scanWarpOn(runScanInline, request);
        final b = await scanWarpOn(runScanOnIsolate, request);
        expect(a!.full.data, b!.full.data);
      },
    );
  });
}
