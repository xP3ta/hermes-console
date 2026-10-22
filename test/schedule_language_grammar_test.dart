import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/schedule_humanizer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/l10n/app_localizations_en.dart';
import 'package:hermes_android/l10n/app_localizations_pt.dart';

void main() {
  const cases = <(String, String, String)>[
    // Typical working-hours jobs.
    (
      '*/5 14-17 * * 1-5',
      'Cada 5 min, de 14:00 a 17:55, laborables',
      'Every 5 min from 14:00 to 17:55 on weekdays',
    ),
    (
      '*/5 7-9 * * 1-5',
      'Cada 5 min, de 7:00 a 9:55, laborables',
      'Every 5 min from 7:00 to 9:55 on weekdays',
    ),
    ('every 60m', 'Cada hora', 'Every hour'),
    // Requested examples.
    ('0 9 * * *', 'Cada día a las 9:00', 'Every day at 9:00'),
    ('30 18 * * 1-5', 'Laborables a las 18:30', 'Weekdays at 18:30'),
    ('0 */2 * * *', 'Cada 2 horas', 'Every 2 hours'),
    (
      '0 9 1 * *',
      'El día 1 de cada mes a las 9:00',
      'On day 1 of every month at 9:00',
    ),
    // Hermes native intervals and durations.
    ('30m', 'Cada 30 min', 'Every 30 min'),
    ('every 30m', 'Cada 30 min', 'Every 30 min'),
    ('2h', 'Cada 2 horas', 'Every 2 hours'),
    ('every 2h', 'Cada 2 horas', 'Every 2 hours'),
    ('every hour', 'Cada hora', 'Every hour'),
    ('every 90m', 'Cada 1 h 30 min', 'Every 1 h 30 min'),
    ('1d', 'Cada día', 'Every day'),
    ('every 3 days', 'Cada 3 días', 'Every 3 days'),
    ('every 1m', 'Cada minuto', 'Every minute'),
    ('in 30m', 'Una vez, dentro de 30 min', 'Once, in 30 min'),
    // Natural phrases Hermes turns into cron.
    ('every monday 9am', 'Los lunes a las 9:00', 'Every Monday at 9:00'),
    ('weekdays at 9am', 'Laborables a las 9:00', 'Weekdays at 9:00'),
    ('every day at 18:30', 'Cada día a las 18:30', 'Every day at 18:30'),
    (
      'every monday, wednesday at 7pm',
      'Los lunes y miércoles a las 19:00',
      'Monday and Wednesday at 19:00',
    ),
    // Minute steps and windows.
    ('* * * * *', 'Cada minuto', 'Every minute'),
    ('*/15 * * * *', 'Cada 15 min', 'Every 15 min'),
    (
      '*/10 9-17 * * *',
      'Cada 10 min, de 9:00 a 17:50',
      'Every 10 min from 9:00 to 17:50',
    ),
    (
      '*/30 8-9,14-15 * * 1-5',
      'Cada 30 min, de 8:00 a 9:30 y de 14:00 a 15:30, laborables',
      'Every 30 min from 8:00 to 9:30 and from 14:00 to 15:30 on weekdays',
    ),
    (
      '*/20 * * * 6,0',
      'Cada 20 min, los fines de semana',
      'Every 20 min on weekends',
    ),
    // Hourly shapes.
    ('0 * * * *', 'Cada hora', 'Every hour'),
    ('15 * * * *', 'Cada hora, en el minuto 15', 'Every hour at :15'),
    ('0,30 * * * *', 'Cada 30 min', 'Every 30 min'),
    (
      '0,45 * * * *',
      'Cada hora, en los minutos 0 y 45',
      'Every hour at :00 and :45',
    ),
    ('0 */6 * * *', 'Cada 6 horas', 'Every 6 hours'),
    (
      '30 1/3 * * *',
      'Cada 3 horas, desde la 1:30',
      'Every 3 hours starting at 1:30',
    ),
    (
      '0 9-17 * * 1-5',
      'Cada hora, de 9:00 a 17:00, laborables',
      'Every hour from 9:00 to 17:00 on weekdays',
    ),
    (
      '0 8-20/4 * * *',
      'Cada 4 horas, de 8:00 a 20:00',
      'Every 4 hours from 8:00 to 20:00',
    ),
    // Point-in-time lists.
    (
      '0 9,18 * * *',
      'Cada día a las 9:00 y 18:00',
      'Every day at 9:00 and 18:00',
    ),
    ('0 1 * * *', 'Cada día a la 1:00', 'Every day at 1:00'),
    (
      '0,30 9 * * 1',
      'Los lunes a las 9:00 y 9:30',
      'Every Monday at 9:00 and 9:30',
    ),
    ('0 10 * * 0,6', 'Fines de semana a las 10:00', 'Weekends at 10:00'),
    ('0 10 * * sat,sun', 'Fines de semana a las 10:00', 'Weekends at 10:00'),
    ('0 20 * * 5', 'Los viernes a las 20:00', 'Every Friday at 20:00'),
    ('0 20 * * 7', 'Los domingos a las 20:00', 'Every Sunday at 20:00'),
    (
      '0 9 * * 1,3,5',
      'Los lunes, miércoles y viernes a las 9:00',
      'Monday, Wednesday and Friday at 9:00',
    ),
    (
      '0 9 * * 1-3',
      'De lunes a miércoles a las 9:00',
      'Monday to Wednesday at 9:00',
    ),
    (
      '0 8 * * 0-2',
      'Los lunes, martes y domingos a las 8:00',
      'Monday, Tuesday and Sunday at 8:00',
    ),
    ('0 9 * * mon-fri', 'Laborables a las 9:00', 'Weekdays at 9:00'),
    // Month days and months.
    (
      '15 8 12 * *',
      'El día 12 de cada mes a las 8:15',
      'On day 12 of every month at 8:15',
    ),
    (
      '0 9 1,15 * *',
      'Los días 1 y 15 de cada mes a las 9:00',
      'On days 1 and 15 of every month at 9:00',
    ),
    (
      '0 9 1-7 * *',
      'Del día 1 al 7 de cada mes a las 9:00',
      'On days 1 to 7 of every month at 9:00',
    ),
    (
      '0 18 L * *',
      'El último día de cada mes a las 18:00',
      'On the last day of every month at 18:00',
    ),
    ('0 0 1 1 *', 'El 1 de enero a las 0:00', 'On January 1 at 0:00'),
    ('@yearly', 'El 1 de enero a las 0:00', 'On January 1 at 0:00'),
    ('@daily', 'Cada día a las 0:00', 'Every day at 0:00'),
    ('@hourly', 'Cada hora', 'Every hour'),
    (
      '0 9 * 6-8 1-5',
      'Laborables, de junio a agosto, a las 9:00',
      'Weekdays from June to August at 9:00',
    ),
    (
      '0 9 * 1,7 *',
      'Cada día, en enero y julio, a las 9:00',
      'Every day in January and July at 9:00',
    ),
    // croniter's optional sixth (seconds) field.
    ('30 18 * * 1-5 0', 'Laborables a las 18:30', 'Weekdays at 18:30'),
  ];

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
  for (final lang in ['es', 'en', 'de', 'fr', 'it', 'ja', 'ko', 'zh']) {
    test('$lang preserves the complete existing schedule fixture table', () {
      final strings = lookupStrings(Locale(lang));
      final now = DateTime(2026, 9, 26, 21, 40);
      for (final (raw, spanish, english) in cases) {
        expect(describeHermesSchedule(strings, raw, now: now),
            lang == 'es' ? spanish : english, reason: raw);
      }
    });
  }
  test('Portuguese weekday gender and month grammar remain intact', () {
    final strings = lookupStrings(const Locale('pt'));
    const cases = {
      '0 9 * * 1': 'Todas as segundas às 9:00',
      '0 9 * * 6': 'Todos os sábados às 9:00',
      '0 9 * * 0,6': 'Fins de semana às 9:00',
      '0 1 * * *': 'Todos os dias às 1:00',
      '0 9 1 1 *': 'Dia 1 de janeiro às 9:00',
      '0 18 L * *': 'No último dia de cada mês às 18:00',
    };
    for (final entry in cases.entries) {
      expect(describeHermesSchedule(strings, entry.key), entry.value);
    }
  });
  test('schedule regional codes resolve by language and unknown uses English', () {
    expect(describeHermesSchedule(StringsPt('pt_PT'), 'every 60m'), 'A cada hora');
    expect(describeHermesSchedule(StringsEn('xx'), 'every 60m'), 'Every hour');
  });

}
