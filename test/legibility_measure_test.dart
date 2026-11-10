// Prints the legibility table (text tokens over the material of the boxes,
// 42 presets). It asserts nothing: legibility_test.dart holds the thresholds.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';

import 'support/legibility_probe.dart';

void main() {
  test('legibility table', () {
    expect(AppTheme.presets.length, 42);
    for (final line in legibilityMarkdown('measure')) {
      // ignore: avoid_print
      print('LEGIB|$line');
    }
    final cases = measureLegibility()
      ..sort((a, b) => a.ratio.compareTo(b.ratio));
    for (final c in cases.take(40)) {
      // ignore: avoid_print
      print('LEGIBWORST|$c');
    }
    for (final s in measureSteps()) {
      // ignore: avoid_print
      print(
        'LEGIBSTEP|${s.preset}|${s.dark}|${s.group.toStringAsFixed(3)}'
        '|${s.card.toStringAsFixed(3)}|${s.glow.toStringAsFixed(3)}',
      );
    }
  });
}
