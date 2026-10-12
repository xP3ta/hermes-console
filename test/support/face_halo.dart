import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/hermes_bot_face.dart';

/// Pixel probe for the QA 9494 "black halo around the faces" report.
///
/// The faces' own pixels come from the face painter rendered alone (over
/// black and over white: what differs is transparent), so the probe never
/// trusts the widget under test to say where a face ends. Every other pixel
/// in a band around each face must be exactly what is behind it (the pill,
/// the card, the page): a ring, a backing disc or a shadow fails.
const double haloScale = 4;
const haloShotKey = ValueKey('halo-shot');

class Shot {
  Shot(this.rgba, this.width);
  final Uint8List rgba;
  final int width;

  Color at(int px, int py) {
    final o = (py * width + px) * 4;
    return Color.fromARGB(255, rgba[o], rgba[o + 1], rgba[o + 2]);
  }
}

Future<Shot> grabShot(WidgetTester tester, {String? saveAs}) async {
  final boundary =
      tester.renderObject(find.byKey(haloShotKey)) as RenderRepaintBoundary;
  late Shot shot;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: haloScale);
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    shot = Shot(raw!.buffer.asUint8List(), image.width);
    final dir = Platform.environment['Q95_SHOTS'];
    if (saveAs != null && dir != null && dir.isNotEmpty) {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(dir).createSync(recursive: true);
      File('$dir/$saveAs.png').writeAsBytesSync(png!.buffer.asUint8List());
    }
    image.dispose();
  });
  return shot;
}

/// CIE76 ΔE between two sRGB colours.
double deltaE(Color a, Color b) {
  List<double> lab(Color c) {
    double lin(double v) =>
        v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4) * 1.0;
    final r = lin(c.r), g = lin(c.g), bl = lin(c.b);
    final x = (r * 0.4124 + g * 0.3576 + bl * 0.1805) / 0.95047;
    final y = r * 0.2126 + g * 0.7152 + bl * 0.0722;
    final z = (r * 0.0193 + g * 0.1192 + bl * 0.9505) / 1.08883;
    double f(double t) =>
        t > 0.008856 ? math.pow(t, 1 / 3) * 1.0 : 7.787 * t + 16 / 116;
    return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))];
  }

  final la = lab(a), lb = lab(b);
  return math.sqrt(
    math.pow(la[0] - lb[0], 2) +
        math.pow(la[1] - lb[1], 2) +
        math.pow(la[2] - lb[2], 2),
  );
}

/// A state dot expected on screen: its fill must be [color] (± [tolerance]).
class ExpectedDot {
  const ExpectedDot(this.finder, this.color, {this.tolerance = 6});
  final Finder finder;
  final Color color;
  final double tolerance;
}

class HaloReport {
  int checked = 0;
  int bad = 0;
  double worst = 0;
  int dotChecked = 0;
  int dotBad = 0;
  Color? worstColor;

  @override
  String toString() =>
      'bad $bad/$checked around faces (worst ΔE ${worst.toStringAsFixed(1)} '
      '$worstColor), dot fill bad $dotBad/$dotChecked';
}

/// Call with the scene pumped (under [haloShotKey]). [behind] gives what
/// should show at a logical point when no face is there. Re-pumps the tree
/// to render the masks, so call it last.
Future<HaloReport> probeHalo(
  WidgetTester tester, {
  required Finder faces,
  required Color Function(int px, int py) behind,
  required ThemeData theme,
  List<ExpectedDot> dots = const [],
  double band = 3,
  String? saveAs,
}) async {
  final scene = await grabShot(tester, saveAs: saveAs);
  final faceWidgets = <(Rect, HermesBotFace)>[
    for (final e in faces.evaluate())
      (
        tester.getRect(find.byWidget(e.widget)),
        e.widget as HermesBotFace,
      ),
  ];
  expect(faceWidgets, isNotEmpty, reason: 'no face found');
  final dotRects = [
    for (final d in dots) (tester.getRect(d.finder), d.color, d.tolerance),
  ];
  // Masks: each face alone over black and over white.
  final masks = <List<double>>[];
  for (final (rect, face) in faceWidgets) {
    final shots = <Shot>[];
    for (final bg in const [Color(0xFF000000), Color(0xFFFFFFFF)]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: haloShotKey,
              // The backdrop inside the boundary: toImage only sees it.
              child: ColoredBox(
                color: bg,
                child: SizedBox.fromSize(size: rect.size, child: face),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      shots.add(await grabShot(tester));
    }
    final w = shots[0].width;
    final h = shots[0].rgba.length ~/ 4 ~/ w;
    masks.add([
      for (var i = 0; i < w * h; i++)
        1 -
            (shots[1].rgba[i * 4] - shots[0].rgba[i * 4]).abs() / 255.0,
    ]);
  }

  bool covered(Offset p) {
    for (var f = 0; f < faceWidgets.length; f++) {
      final rect = faceWidgets[f].$1;
      final w = (rect.width * haloScale).round();
      final h = (rect.height * haloScale).round();
      final lx = ((p.dx - rect.left) * haloScale).floor();
      final ly = ((p.dy - rect.top) * haloScale).floor();
      for (var dy = -2; dy <= 2; dy++) {
        for (var dx = -2; dx <= 2; dx++) {
          final x = lx + dx, y = ly + dy;
          if (x < 0 || y < 0 || x >= w || y >= h) continue;
          if (masks[f][y * w + x] > 0.02) return true;
        }
      }
    }
    return false;
  }

  final report = HaloReport();
  final sceneH = scene.rgba.length ~/ 4 ~/ scene.width;
  final region = <Rect>[
    for (final (r, _) in faceWidgets) r.inflate(band),
    for (final (r, _, _) in dotRects) r.inflate(band),
  ];
  final seen = <int>{};
  for (final r in region) {
    for (var py = math.max(0, (r.top * haloScale).floor());
        py < math.min(sceneH, (r.bottom * haloScale).ceil());
        py++) {
      for (var px = math.max(0, (r.left * haloScale).floor());
          px < math.min(scene.width, (r.right * haloScale).ceil());
          px++) {
        if (!seen.add(py * scene.width + px)) continue;
        final p = Offset((px + .5) / haloScale, (py + .5) / haloScale);
        var inDot = false;
        for (final (dr, color, tol) in dotRects) {
          final d = (p - dr.center).distance;
          final radius = dr.shortestSide / 2;
          if (d <= radius - .6) {
            inDot = true;
            report.dotChecked++;
            if (deltaE(scene.at(px, py), color) > tol) report.dotBad++;
          } else if (d <= radius + .6) {
            inDot = true;
          }
        }
        if (inDot || covered(p)) continue;
        report.checked++;
        final got = scene.at(px, py);
        final e = deltaE(got, behind(px, py));
        if (e > 3) {
          report.bad++;
          if (e > report.worst) {
            report.worst = e;
            report.worstColor = got;
          }
        }
      }
    }
  }
  return report;
}
