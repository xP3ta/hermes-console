import 'package:flutter/widgets.dart' show StringCharacters;

/// F3 of the fluidity plan (REPORT-AUDITORIA-FLUIDEZ §2.3.2-3): one step of
/// the live reply's reveal.
///
/// The pace is the one the chat has had since 1.2: at least
/// [minGraphemes] per step and a burst drains by about 1/[drainSteps] of
/// what is pending each step (0.26 s behind a steady stream). That alone
/// leaves the tail of a big burst more than a second behind (3000
/// characters took ~39 steps), so the caller passes a [floor] taken when
/// text arrives ([floorFor]): whatever is pending then is shown within
/// [maxLagSteps] steps, 1 s, the audit's ceiling. Where a step ends is new:
/// at the end of a word, never in the middle of one. A «word» longer than
/// [maxWordOverrun] grapheme clusters (a URL, a hash) is cut so it does not
/// hold the pace back.
///
/// Returns the new end of the revealed text, in UTF-16 units of [content]:
/// always on a grapheme boundary, past [revealed] and never past the end.
abstract final class StreamReveal {
  /// One step of the reveal (30 a second).
  static const Duration step = Duration(milliseconds: 33);

  static const int minGraphemes = 6;
  static const int drainSteps = 8;
  static const int maxWordOverrun = 12;

  /// One second of steps: nothing waits longer than this to be shown.
  static const int maxLagSteps = 30;

  /// The least a step shows so that [pending] is all shown within
  /// [maxLagSteps] steps.
  static int floorFor(int pending) =>
      (pending + maxLagSteps - 1) ~/ maxLagSteps;

  static int next(String content, int revealed, {int floor = 0}) {
    if (revealed >= content.length) return content.length;
    final pending = content.length - revealed;
    var target = pending ~/ drainSteps;
    if (target < minGraphemes) target = minGraphemes;
    if (target < floor) target = floor;
    var end = revealed;
    var taken = 0;
    var overrun = 0;
    final rest = content.substring(revealed).characters.iterator;
    while (rest.moveNext()) {
      final grapheme = rest.current;
      if (taken >= target) {
        // Past the pace: only to finish the word in hand.
        if (_breaks(grapheme)) return end;
        if (++overrun > maxWordOverrun) return end;
      }
      end += grapheme.length;
      taken++;
    }
    // Everything that has arrived. If the network cut a word, the rest of it
    // comes with the next delta; holding the half back would stall the
    // reveal (and keep a ticker running) whenever the stream pauses.
    return end;
  }

  static bool _breaks(String grapheme) =>
      grapheme.trim().isEmpty || _punctuation.contains(grapheme);

  static const Set<String> _punctuation = {
    '.', ',', ';', ':', '!', '?', '¡', '¿', '…', ')', ']', '}', '"', '»',
    '”', '’', '-', '—', '–', '/', '`', '*', '_', '|',
  };
}
