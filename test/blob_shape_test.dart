import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/characters/blob_shape.dart';
import 'package:hermes_android/core/characters/studio_catalog.dart';

List<double> _radii(
  BotForm form, {
  double range = 0.5,
  double strength = 0.5,
  String seed = 'ana',
}) => BlobShape.radii(form: form, range: range, strength: strength, seed: seed);

double _distance(List<double> a, List<double> b) {
  var total = 0.0;
  for (var i = 0; i < a.length; i++) {
    total += (a[i] - b[i]).abs();
  }
  return total / a.length;
}

void main() {
  test('the same seed gives the exact same body, a different one differs', () {
    for (final form in BotForm.values) {
      expect(_radii(form), _radii(form), reason: form.name);
      expect(
        _distance(_radii(form, seed: 'ana'), _radii(form, seed: 'bruno')),
        greaterThan(0.05),
        reason: form.name,
      );
    }
    expect(
      BlobShape.radii(
        form: BotForm.round,
        range: .5,
        strength: .5,
        seed: 'x',
      ).length,
      BlobShape.samples,
    );
  });

  test('the five forms are different bodies', () {
    for (final a in BotForm.values) {
      for (final b in BotForm.values) {
        if (a == b) continue;
        expect(
          _distance(_radii(a, strength: 0), _radii(b, strength: 0)),
          greaterThan(0.3),
          reason: '${a.name} vs ${b.name}',
        );
      }
    }
  });

  test('strength zero leaves a round body round and more bends it', () {
    final plain = _radii(BotForm.round, strength: 0);
    expect(plain.every((r) => (r - plain.first).abs() < 1e-9), isTrue);
    var last = 0.0;
    for (final s in [0.0, 0.25, 0.5, 0.75, 1.0]) {
      final spread = _spread(_radii(BotForm.round, strength: s));
      expect(spread, greaterThanOrEqualTo(last - 1e-9));
      last = spread;
    }
    expect(last, greaterThan(1));
  });

  test('range and strength morph continuously, with no jumps', () {
    for (final form in BotForm.values) {
      var previous = _radii(form, range: 0);
      for (var i = 1; i <= 100; i++) {
        final next = _radii(form, range: i / 100);
        expect(_distance(previous, next), lessThan(0.6), reason: form.name);
        previous = next;
      }
      previous = _radii(form, strength: 0);
      for (var i = 1; i <= 100; i++) {
        final next = _radii(form, strength: i / 100);
        expect(_distance(previous, next), lessThan(0.6), reason: form.name);
        previous = next;
      }
    }
  });

  test('range changes the outline, not just its size', () {
    expect(
      _distance(
        _radii(BotForm.organic, range: 0),
        _radii(BotForm.organic, range: 1),
      ),
      greaterThan(0.3),
    );
  });

  test('every body stays inside the canvas for any slider value', () {
    for (final form in BotForm.values) {
      for (final seed in ['a', 'ana', 'zz9', 'quiet-fox']) {
        for (final range in [0.0, 0.3, 0.7, 1.0]) {
          for (final strength in [0.0, 0.5, 1.0]) {
            final rs = _radii(
              form,
              range: range,
              strength: strength,
              seed: seed,
            );
            for (final r in rs) {
              expect(r, greaterThan(15));
              expect(r, lessThanOrEqualTo(BlobShape.maxRadius + 1e-9));
              expect(r.isFinite, isTrue);
            }
          }
        }
      }
    }
  });

  test('out-of-range and NaN inputs are treated as bounded', () {
    final a = _radii(BotForm.cloud, range: 9, strength: -9);
    final b = _radii(BotForm.cloud, range: 1, strength: 0);
    expect(a, b);
    final nan = _radii(BotForm.cloud, range: double.nan, strength: double.nan);
    expect(nan.every((r) => r.isFinite), isTrue);
  });

  test('the body path is cached and the fur is deterministic', () {
    final one = BlobShape.body(
      form: BotForm.boxy,
      range: .4,
      strength: .6,
      seed: 'ana',
    );
    final two = BlobShape.body(
      form: BotForm.boxy,
      range: .4,
      strength: .6,
      seed: 'ana',
    );
    expect(identical(one, two), isTrue);
    final bounds = one.getBounds();
    expect(bounds.left, greaterThan(0));
    expect(bounds.right, lessThan(100));
    final fur = BlobShape.fur(
      form: BotForm.boxy,
      range: .4,
      strength: .6,
      seed: 'ana',
    );
    expect(
      fur.getBounds(),
      BlobShape.fur(
        form: BotForm.boxy,
        range: .4,
        strength: .6,
        seed: 'ana',
      ).getBounds(),
    );
    expect(fur.getBounds().width, greaterThan(20));
  });
}

double _spread(List<double> rs) => rs.reduce(math.max) - rs.reduce(math.min);
