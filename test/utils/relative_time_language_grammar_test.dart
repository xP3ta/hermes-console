import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/relative_time.dart';

void main() {
  // Same clock and timestamp construction as relative_time_test.dart.
  final now = DateTime(2026, 7, 26, 21);
  double stamp(Duration age) => now.subtract(age).millisecondsSinceEpoch / 1000;
  const languages = ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh'];
  test('every language has its own relative-time grammar file', () {
    for (final lang in languages) {
      final source = File('lib/core/utils/relative_time_langs/$lang.dart')
          .readAsStringSync();
      expect(source, contains('String format(Duration age, DateTime date)'));
    }
  });
  for (final lang in languages) {
    test('$lang unit boundaries, dates, invalid values and future values', () {
      final (current, minute, hour, day) = switch (lang) {
        'es' => ('ahora', '36 min', '2 h', '2 d'),
        'pt' => ('agora', '36 min', '2 h', '2 d'),
        _ => ('just now', '36m ago', '2h ago', '2d ago'),
      };
      String describe(Duration age) =>
          relativeTime(stamp(age), languageCode: lang, now: now);
      expect(describe(const Duration(seconds: 20)), current);
      expect(describe(const Duration(seconds: 59)), current);
      expect(describe(const Duration(minutes: 36)), minute);
      expect(describe(const Duration(hours: 2)), hour);
      expect(describe(const Duration(days: 2)), day);
      final compact = lang == 'es' || lang == 'pt';
      expect(describe(const Duration(minutes: 1)), compact ? '1 min' : '1m ago');
      expect(describe(const Duration(minutes: 59)), compact ? '59 min' : '59m ago');
      expect(describe(const Duration(hours: 1)), compact ? '1 h' : '1h ago');
      expect(describe(const Duration(hours: 23)), compact ? '23 h' : '23h ago');
      expect(describe(const Duration(days: 1)), compact ? '1 d' : '1d ago');
      expect(describe(const Duration(days: 6)), compact ? '6 d' : '6d ago');
      expect(describe(const Duration(days: 7)), '19/7');
      expect(describe(const Duration(minutes: -5)), current);
      expect(relativeTime(0, languageCode: lang, now: now), isEmpty);
      expect(relativeTime(double.nan, languageCode: lang, now: now), isEmpty);
      expect(relativeTime(double.infinity, languageCode: lang, now: now), isEmpty);
      expect(relativeTime(-1, languageCode: lang, now: now), isEmpty);
      final milliseconds = now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch;
      expect(relativeTime(milliseconds.toDouble(), languageCode: lang, now: now), hour);
    });
  }
  test('regional and unknown codes use Portuguese and English respectively', () {
    expect(relativeTime(stamp(const Duration(minutes: 36)), languageCode: 'pt_PT', now: now), '36 min');
    expect(relativeTime(stamp(const Duration(minutes: 36)), languageCode: 'xx', now: now), '36m ago');
  });
}
