import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/frame_stream_reveal.dart';

void main() {
  test('cached tail boundaries remain valid after long-prefix compaction', () {
    final reveal = FrameStreamReveal()..observe('x' * 3000, Duration.zero);
    reveal.advance(const Duration(milliseconds: 100));
    reveal.observe('x' * 3010, const Duration(milliseconds: 110));
    final ends = reveal.tailBoundaries(24);
    expect(ends, hasLength(25));
    expect(ends.last, reveal.end);
    expect(ends.first, reveal.end - 24);
    expect(reveal.tailStart(24), ends.first);
  });

  test('a long burst drains within one second at 30, 60 and 120 Hz', () {
    final text = List.filled(500, 'palabra').join(' ');
    for (final hz in [30, 60, 120]) {
      final reveal = FrameStreamReveal()..observe(text, Duration.zero);
      final frame = Duration(microseconds: 1000000 ~/ hz);
      var elapsed = Duration.zero;
      while (!reveal.caughtUp && elapsed < const Duration(seconds: 1)) {
        final previous = reveal.end;
        reveal.advance(frame);
        expect(reveal.end, greaterThanOrEqualTo(previous));
        elapsed += frame;
      }
      expect(reveal.end, text.length, reason: '$hz Hz');
    }
  });

  test('a steady stream keeps pace with arrival at every refresh rate', () {
    for (final hz in [30, 60, 120]) {
      final reveal = FrameStreamReveal();
      final frame = Duration(microseconds: 1000000 ~/ hz);
      var now = Duration.zero;
      var source = '';
      var nextArrival = Duration.zero;
      for (var index = 0; index < hz * 3; index++) {
        now += frame;
        if (now >= nextArrival) {
          source += 'abcdefghij';
          reveal.observe(source, now);
          nextArrival += const Duration(milliseconds: 33);
        }
        reveal.advance(frame);
        // Even at 300 characters/s, the visible tail stays comfortably
        // inside the old one-second latency ceiling.
        expect(source.length - reveal.end, lessThan(60), reason: '$hz Hz');
      }
      expect(reveal.end, greaterThan(source.length - 20));
    }
  });

  test('long frame catches up without replaying missed animation frames', () {
    final reveal = FrameStreamReveal()..observe('word ' * 600, Duration.zero);
    reveal.advance(const Duration(milliseconds: 500));
    expect(reveal.caughtUp, isTrue);
  });

  test('frames stop only on complete graphemes', () {
    const text = 'Hola 👩‍👩‍👧‍👦 familia 🇪🇸 á y más texto';
    final boundaries = <int>{0};
    var end = 0;
    for (final character in text.characters) {
      end += character.length;
      boundaries.add(end);
    }
    final reveal = FrameStreamReveal()..observe(text, Duration.zero);
    while (!reveal.caughtUp) {
      reveal.advance(const Duration(milliseconds: 8));
      expect(boundaries, contains(reveal.end));
    }
  });

  test('an emoji completed by a later delta never exposes a split cluster', () {
    final reveal = FrameStreamReveal()
      ..observe('👩', Duration.zero)
      ..finish();
    reveal.observe('👩‍👩‍👧‍👦', const Duration(milliseconds: 33));
    expect(reveal.end, '👩‍👩‍👧‍👦'.length);
    expect(reveal.caughtUp, isTrue);
    expect(reveal.pendingGraphemes, 0);
    reveal.observe('👩‍👩‍👧‍👦 familia', const Duration(milliseconds: 66));
    reveal.advance(const Duration(milliseconds: 8));
    expect(reveal.end, greaterThanOrEqualTo('👩‍👩‍👧‍👦'.length));
  });

  test('authoritative corrections and shorter segment resets are retained', () {
    final reveal = FrameStreamReveal()
      ..observe('old answer', Duration.zero)
      ..finish();
    reveal.observe('new', const Duration(milliseconds: 33));
    expect(reveal.source, 'new');
    expect(reveal.end, lessThanOrEqualTo(3));
    reveal.finish();
    expect(reveal.end, 3);
    reveal.reset();
    expect(reveal.source, isEmpty);
    expect(reveal.end, 0);
    expect(reveal.caughtUp, isTrue);
  });

  test(
    'a correction cannot leave the visible offset inside a surrogate pair',
    () {
      final reveal = FrameStreamReveal()
        ..observe('a', Duration.zero)
        ..finish();
      reveal.observe('👩 family', const Duration(milliseconds: 33));
      expect(reveal.end, '👩'.length);
      reveal.advance(const Duration(milliseconds: 8));
      expect(reveal.end, greaterThanOrEqualTo('👩'.length));
    },
  );

  test('finish shows all text and idle time cannot bank a later burst', () {
    final reveal = FrameStreamReveal()
      ..observe('first', Duration.zero)
      ..finish();
    for (var index = 0; index < 20; index++) {
      reveal.advance(const Duration(seconds: 1));
    }
    reveal.observe('first${'x' * 3000}', const Duration(seconds: 20));
    reveal.advance(const Duration(milliseconds: 8));
    expect(reveal.end, lessThan(reveal.source.length));
    reveal.finish();
    expect(reveal.caughtUp, isTrue);
  });
}
