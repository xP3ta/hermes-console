import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/schedule_humanizer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  const languages = ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh'];
  test('each schedule language owns its complete grammar contract', () {
    final contract = File('lib/core/design/schedule_humanizer.dart')
        .readAsStringSync();
    final declarations = RegExp(
      r'^  (?:String|_Days) (?:get )?(\w+)(?:\(|;)',
      multiLine: true,
    ).allMatches(contract).map((m) => m[1]!).toSet();
    expect(declarations, containsAll(['custom', 'onceIn', 'weekdays', 'monthDays']));
    for (final lang in languages) {
      final grammar = File('lib/core/design/schedule_langs/$lang.dart')
          .readAsStringSync();
      for (final member in declarations) {
        expect(RegExp('\\b$member\\b').hasMatch(grammar), isTrue,
            reason: '$lang.$member');
      }
    }
  });
  for (final lang in languages) {
    test('$lang intervals, weekday windows and date grammar', () {
      final strings = lookupStrings(Locale(lang));
      final now = DateTime(2026, 7, 26, 21);
      String describe(String raw) =>
          describeHermesSchedule(strings, raw, now: now);
      final (minute, day, days, window, custom) = switch (lang) {
        'es' => ('Cada minuto', 'Cada día', 'Cada 2 días',
          'Cada 5 min, de 14:00 a 17:55, laborables', 'Horario personalizado'),
        'pt' => ('A cada minuto', 'Todos os dias', 'A cada 2 dias',
          'A cada 5 min, das 14:00 às 17:55, em dias úteis', 'Horário personalizado'),
        _ => ('Every minute', 'Every day', 'Every 2 days',
          'Every 5 min from 14:00 to 17:55 on weekdays', 'Custom schedule'),
      };
      expect(describe('every 1m'), minute);
      expect(describe('1d'), day);
      expect(describe('2d'), days);
      expect(describe('*/5 14-17 * * 1-5'), window);
      expect(describe('not a schedule'), custom);
      // Complete date, weekday and month clauses stay editable in each grammar.
      for (final raw in ['0 9 * * 1', '0 9 * * 6', '0 9 * * 0,6',
        '0 1,14 * * 1,3,5', '0 9 L * *', '0 9 1 1 *',
        '0 9 1,3,5 * *', '2026-08-01T09:00:00', '2027-08-01T09:00:00',
        'in 1m', 'in 60m', 'in 24h', 'in 90m']) {
        final text = describe(raw);
        expect(text, isNotEmpty, reason: raw);
        expect(text, isNot(custom), reason: raw);
        if (!['es', 'pt'].contains(lang)) {
          expect(text, describeHermesSchedule(lookupStrings(const Locale('en')), raw, now: now), reason: raw);
        }
      }
      if (lang == 'pt') {
        // Same expressions and literal expectations as cron_human_schedule_test.
        expect(describe('in 1m'), 'Uma vez, daqui a 1 min');
        expect(describe('in 60m'), 'Uma vez, daqui a 1 hora');
        expect(describe('in 24h'), 'Uma vez, daqui a 1 dia');
        expect(describe('in 90m'), 'Uma vez, daqui a 1 h 30 min');
        expect(describe('in 2h'), 'Uma vez, daqui a 2 horas');
      }
    });
  }
}
