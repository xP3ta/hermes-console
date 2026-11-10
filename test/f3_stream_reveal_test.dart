// F3 of the fluidity plan (REPORT-AUDITORIA-FLUIDEZ §2.3.2-3, §2.4): the
// live reply is revealed by words at the pace it has had since 1.2, on the
// screen's frames. Measured: no word cut by a step, never behind by more
// than the drain, monotonic, and the final text is the text.
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/stream_reveal.dart';

/// Every end the reveal stops at, from nothing to the whole [content], all
/// of it arriving at once (the floor is taken then, as the chat does).
List<int> _ends(String content) {
  final ends = <int>[];
  final floor = StreamReveal.floorFor(content.length);
  var revealed = 0;
  while (revealed < content.length) {
    final next = StreamReveal.next(content, revealed, floor: floor);
    expect(next, greaterThan(revealed), reason: 'it always moves');
    ends.add(next);
    revealed = next;
  }
  return ends;
}

bool _endsAWord(String content, int end) {
  if (end >= content.length) return true;
  final next = content.substring(end).characters.first;
  return next.trim().isEmpty || '.,;:!?…)'.contains(next);
}

void main() {
  const prose =
      'El tercer artículo cuenta cómo guardar en disco cada mensaje '
      'pendiente antes de vaciar el campo, para que sobreviva a un cierre '
      'de la app, y cómo reintentar en orden sin duplicar nada.';

  test('no step cuts a word', () {
    final ends = _ends(prose);
    expect(ends.last, prose.length);
    for (final end in ends) {
      expect(_endsAWord(prose, end), isTrue, reason: prose.substring(0, end));
    }
  });

  test('the pace of always: at least six graphemes a step', () {
    final first = StreamReveal.next(prose, 0);
    expect(
      prose.substring(0, first).characters.length,
      greaterThanOrEqualTo(StreamReveal.minGraphemes),
    );
  });

  test('a burst of 3000 characters is all shown within 1 s', () {
    final burst = List.filled(375, 'palabra').join(' ');
    expect(burst.length, greaterThan(2990));
    final steps = _ends(burst).length;
    expect(steps, lessThanOrEqualTo(StreamReveal.maxLagSteps));
    expect(
      steps * StreamReveal.step.inMilliseconds,
      lessThanOrEqualTo(1000),
    );
    // Without the floor (the pace before F3) it took more than a second.
    var revealed = 0;
    var before = 0;
    while (revealed < burst.length) {
      revealed = StreamReveal.next(burst, revealed);
      before++;
    }
    expect(before * StreamReveal.step.inMilliseconds, greaterThan(1000));
  });

  test('a word longer than twelve graphemes is cut so the pace holds', () {
    // A hash of 200 letters: the step's share (200 / 8 = 25) and at most
    // twelve more to look for the word's end, then it is cut.
    final hash = 'f' * 200;
    expect(
      StreamReveal.next(hash, 0),
      200 ~/ StreamReveal.drainSteps + StreamReveal.maxWordOverrun,
    );
  });

  test('never splits a grapheme', () {
    const emoji = 'Hola 👩‍👩‍👧‍👦 familia 🇪🇸 y más texto que sigue';
    // Every place a grapheme may end (REVIEW-T2-A: joining the characters
    // of what is shown proves nothing; a lone surrogate joins back too).
    final boundaries = <int>{0};
    var at = 0;
    for (final grapheme in emoji.characters) {
      at += grapheme.length;
      boundaries.add(at);
    }
    for (final end in _ends(emoji)) {
      expect(boundaries, contains(end), reason: emoji.substring(0, end));
    }
  });

  test('what the network cut is shown as it arrived', () {
    // The rest of the word comes with the next delta: nothing is held back.
    expect(StreamReveal.next('Hola mund', 5), 'Hola mund'.length);
  });
}
