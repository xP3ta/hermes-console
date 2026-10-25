import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/relative_time.dart';

import '../support/i18n131_grammar_expectations.dart';

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
      final current = lang == 'es' ? 'ahora' : lang == 'pt' ? 'agora' : 'just now';
      final compact = lang == 'es' || lang == 'pt';
      final samples = phase3bRelativeTimes[lang] ?? <int, String>{
        -300: current, 20: current, 59: current,
        60: compact ? '1 min' : '1m ago',
        2160: compact ? '36 min' : '36m ago',
        3540: compact ? '59 min' : '59m ago',
        3600: compact ? '1 h' : '1h ago',
        7200: compact ? '2 h' : '2h ago',
        82800: compact ? '23 h' : '23h ago',
        86400: compact ? '1 d' : '1d ago',
        172800: compact ? '2 d' : '2d ago',
        518400: compact ? '6 d' : '6d ago',
        604800: '19/7',
      };
      for (final entry in samples.entries) {
        expect(relativeTime(stamp(Duration(seconds: entry.key)),
            languageCode: lang, now: now), entry.value, reason: '$lang:${entry.key}');
      }
      expect(relativeTime(0, languageCode: lang, now: now), isEmpty);
      expect(relativeTime(double.nan, languageCode: lang, now: now), isEmpty);
      expect(relativeTime(double.infinity, languageCode: lang, now: now), isEmpty);
      expect(relativeTime(-1, languageCode: lang, now: now), isEmpty);
      final milliseconds = now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch;
      expect(relativeTime(milliseconds.toDouble(), languageCode: lang, now: now), samples[7200]);
    });
  }
  test('regional and unknown codes use Portuguese and English respectively', () {
    expect(relativeTime(stamp(const Duration(minutes: 36)), languageCode: 'pt_PT', now: now), '36 min');
    expect(relativeTime(stamp(const Duration(minutes: 36)), languageCode: 'xx', now: now), '36m ago');
  });
}
