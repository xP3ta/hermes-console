import 'dart:math' as math;
import 'dart:ui' show Offset, Path;

import 'studio_catalog.dart';

/// The continuous body of a studio character, in a 100 x 100 box centred on
/// (50, 50).
///
/// The outline is a radius per angle: the base form (a circle, a squircle, a
/// wide rounded rectangle, a scalloped cloud...) times a seeded deformation.
/// The deformation mixes a few harmonics; **range** slides which harmonics
/// are heard (few broad lobes at 0, many fine ones at 1) and **strength**
/// sets how far they push. Both are continuous: dragging a slider morphs the
/// outline without jumps. Everything is a pure function of its arguments,
/// so the same seed always gives the same body.
abstract final class BlobShape {
  /// Points sampled around the outline.
  static const int samples = 96;

  /// The body never reaches past this radius (the box is 50).
  static const double maxRadius = 46;

  static const double _centre = 50;
  static const int _lowest = 2;
  static const int _highest = 7;

  /// Radius at each of the [samples] angles.
  static List<double> radii({
    required BotForm form,
    required double range,
    required double strength,
    required String seed,
  }) {
    final r = range.isNaN ? 0.5 : range.clamp(0.0, 1.0).toDouble();
    final s = strength.isNaN ? 0.5 : strength.clamp(0.0, 1.0).toDouble();
    final rng = _Rng(_hash('$seed|${form.name}'));
    final amplitudes = <double>[];
    final phases = <double>[];
    for (var k = _lowest; k <= _highest; k++) {
      final magnitude = 0.4 + 0.6 * rng.next();
      amplitudes.add(rng.next() < 0.5 ? -magnitude : magnitude);
      phases.add(rng.next() * 2 * math.pi);
    }
    // The harmonic the range points at; its neighbours fade in and out.
    final centre = _lowest + r * (_highest - _lowest);
    var norm = 0.0;
    final weights = <double>[];
    for (var k = _lowest; k <= _highest; k++) {
      final w = math.max(0.0, 1 - (k - centre).abs() / 2);
      weights.add(w);
      norm += w * amplitudes[k - _lowest].abs();
    }
    final wobble = switch (form) {
      BotForm.organic => 0.45,
      _ => 0.0,
    };
    final push = (wobble + s * 0.78).clamp(0.0, 1.2) * 0.18;
    final out = List<double>.filled(samples, 0);
    var widest = 0.0;
    for (var i = 0; i < samples; i++) {
      final theta = 2 * math.pi * i / samples;
      var mix = 0.0;
      for (var k = _lowest; k <= _highest; k++) {
        final index = k - _lowest;
        mix +=
            weights[index] *
            amplitudes[index] *
            math.cos(k * theta + phases[index]);
      }
      final deform = norm == 0 ? 0.0 : mix / norm;
      final radius = _base(form, theta) * (1 + push * deform);
      out[i] = radius;
      if (radius > widest) widest = radius;
    }
    if (widest > maxRadius) {
      final shrink = maxRadius / widest;
      for (var i = 0; i < samples; i++) {
        out[i] = out[i] * shrink;
      }
    }
    return out;
  }

  static double _base(BotForm form, double theta) {
    final c = math.cos(theta).abs();
    final s = math.sin(theta).abs();
    switch (form) {
      case BotForm.round:
        return 36;
      case BotForm.organic:
        return 35 + 2 * math.cos(2 * theta + 0.6);
      case BotForm.boxy:
        return _superellipse(c, s, 33, 33, 4);
      case BotForm.rectangle:
        return _superellipse(c, s, 40, 29, 6);
      case BotForm.cloud:
        return 31 + 6.5 * math.sin(3.5 * theta).abs();
    }
  }

  static double _superellipse(
    double c,
    double s,
    double a,
    double b,
    double n,
  ) {
    final d = math.pow(c / a, n) + math.pow(s / b, n);
    return math.pow(d, -1 / n).toDouble();
  }

  /// The outline points of [radii], clockwise from the right.
  static List<Offset> points(List<double> radii) => [
    for (var i = 0; i < radii.length; i++)
      Offset(
        _centre + radii[i] * math.cos(2 * math.pi * i / radii.length),
        _centre + radii[i] * math.sin(2 * math.pi * i / radii.length),
      ),
  ];

  /// A closed smooth path through [pts] (Catmull-Rom as cubic segments).
  static Path smoothPath(List<Offset> pts) {
    final n = pts.length;
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (var i = 0; i < n; i++) {
      final p0 = pts[(i - 1 + n) % n];
      final p1 = pts[i];
      final p2 = pts[(i + 1) % n];
      final p3 = pts[(i + 2) % n];
      path.cubicTo(
        p1.dx + (p2.dx - p0.dx) / 6,
        p1.dy + (p2.dy - p0.dy) / 6,
        p2.dx - (p3.dx - p1.dx) / 6,
        p2.dy - (p3.dy - p1.dy) / 6,
        p2.dx,
        p2.dy,
      );
    }
    return path..close();
  }

  static final Map<String, Path> _bodyCache = {};
  static final Map<String, Path> _furCache = {};
  static const int _cacheLimit = 48;

  static String _key(
    BotForm form,
    double range,
    double strength,
    String seed,
  ) =>
      '${form.name}|${range.toStringAsFixed(4)}|'
      '${strength.toStringAsFixed(4)}|$seed';

  /// The body outline. Cached (a few dozen shapes): dragging a slider asks
  /// for a new one per frame, a roster of faces asks for the same ones.
  static Path body({
    required BotForm form,
    required double range,
    required double strength,
    required String seed,
  }) {
    final key = _key(form, range, strength, seed);
    final hit = _bodyCache[key];
    if (hit != null) return hit;
    final path = smoothPath(
      points(radii(form: form, range: range, strength: strength, seed: seed)),
    );
    if (_bodyCache.length >= _cacheLimit) {
      _bodyCache.remove(_bodyCache.keys.first);
    }
    return _bodyCache[key] = path;
  }

  /// Short strokes just inside the outline: a fur texture, painted clipped
  /// to the body with a faint ink.
  static Path fur({
    required BotForm form,
    required double range,
    required double strength,
    required String seed,
  }) {
    final key = _key(form, range, strength, seed);
    final hit = _furCache[key];
    if (hit != null) return hit;
    final rs = radii(form: form, range: range, strength: strength, seed: seed);
    final rng = _Rng(_hash('fur|$seed'));
    final path = Path();
    const strokes = 90;
    for (var i = 0; i < strokes; i++) {
      final theta = rng.next() * 2 * math.pi;
      final at = theta / (2 * math.pi) * rs.length;
      final lower = at.floor() % rs.length;
      final upper = (lower + 1) % rs.length;
      final edge = rs[lower] + (rs[upper] - rs[lower]) * (at - at.floor());
      final depth = 0.62 + 0.34 * rng.next();
      final length = 2.6 + 2.4 * rng.next();
      final lean = (rng.next() - 0.5) * 0.7;
      final start = Offset(
        _centre + edge * depth * math.cos(theta),
        _centre + edge * depth * math.sin(theta),
      );
      final direction = theta + math.pi + lean;
      path
        ..moveTo(start.dx, start.dy)
        ..lineTo(
          start.dx + length * math.cos(direction),
          start.dy + length * math.sin(direction),
        );
    }
    if (_furCache.length >= _cacheLimit) {
      _furCache.remove(_furCache.keys.first);
    }
    return _furCache[key] = path;
  }

  static int _hash(String text) {
    var h = 0x811c9dc5;
    for (final unit in text.codeUnits) {
      h = ((h ^ unit) * 0x01000193) & 0xffffffff;
    }
    return h == 0 ? 1 : h;
  }
}

/// A tiny xorshift generator: the same seed gives the same numbers on every
/// device, which `dart:math`'s Random does not promise across versions.
final class _Rng {
  int _state;

  _Rng(this._state);

  double next() {
    var x = _state;
    x ^= (x << 13) & 0xffffffff;
    x ^= x >> 17;
    x ^= (x << 5) & 0xffffffff;
    _state = x & 0xffffffff;
    return _state / 0x100000000;
  }
}
