import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/schedule_humanizer.dart';
import 'package:hermes_android/core/design/schedule_model.dart';
import 'package:hermes_android/l10n/app_localizations_en.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';

/// Matches anything that looks like cron / interval syntax.
final _raw = RegExp(r'\*|/\d|\d-\d|\bevery \d+m\b|^\d+[mhd]$|@\w+');

void main() {
  final en = StringsEn();
  final es = StringsEs();
  final now = DateTime(2026, 9, 26, 21, 40); // Saturday

  // (schedule, Spanish, English)
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

  group('describeHermesSchedule', () {
    for (final (raw, esText, enText) in cases) {
      test('"$raw"', () {
        expect(describeHermesSchedule(es, raw, now: now), esText);
        expect(describeHermesSchedule(en, raw, now: now), enText);
      });
    }

    test('one-shot timestamps', () {
      expect(
        describeHermesSchedule(es, '2026-10-03T14:00:00', now: now),
        'Una vez, el 3 de octubre a las 14:00',
      );
      expect(
        describeHermesSchedule(en, '2027-02-03T09:30:00', now: now),
        'Once on February 3, 2027 at 9:30',
      );
    });

    test('unrepresentable shapes say "custom" without syntax', () {
      for (final raw in const [
        '5 4 * * sun#2',
        '0 9 1-7 * 1', // croniter OR between month day and weekday
        '1,7,13,44 2,5,9,22 * * *',
        'garbage',
        '',
      ]) {
        expect(
          describeHermesSchedule(es, raw),
          'Horario personalizado',
          reason: raw,
        );
        expect(describeHermesSchedule(en, raw), 'Custom schedule', reason: raw);
      }
    });

    test('no description ever contains raw syntax', () {
      for (final (raw, _, _) in cases) {
        for (final s in [es, en]) {
          final text = describeHermesSchedule(s, raw, now: now);
          expect(_raw.hasMatch(text), isFalse, reason: '$raw → $text');
        }
      }
    });
  });

  group('next run', () {
    test('real jobs', () {
      // Saturday 21:40 → Monday.
      expect(
        hermesScheduleNextRun('*/5 14-17 * * 1-5', now),
        DateTime(2026, 9, 28, 14),
      );
      expect(
        hermesScheduleNextRun('*/5 7-9 * * 1-5', now),
        DateTime(2026, 9, 28, 7),
      );
      expect(
        hermesScheduleNextRun(
          '*/5 14-17 * * 1-5',
          DateTime(2026, 9, 28, 17, 52),
        ),
        DateTime(2026, 9, 28, 17, 55),
      );
      expect(
        hermesScheduleNextRun(
          '*/5 14-17 * * 1-5',
          DateTime(2026, 9, 28, 17, 55),
        ),
        DateTime(2026, 9, 29, 14),
      );
      expect(hermesScheduleNextRun('every 60m', now), isNull);
    });

    test('last day of month and yearly', () {
      expect(
        hermesScheduleNextRun('0 18 L * *', now),
        DateTime(2026, 9, 30, 18),
      );
      expect(hermesScheduleNextRun('@yearly', now), DateTime(2027));
    });
  });

  group('Hermes parser parity', () {
    test('interval durations mirror parse_duration', () {
      expect(hermesIntervalMinutes('every 60m'), 60);
      expect(hermesIntervalMinutes('30m'), 30);
      expect(hermesIntervalMinutes('2h'), 120);
      expect(hermesIntervalMinutes('1d'), 1440);
      expect(hermesIntervalMinutes('hour'), 60);
      expect(hermesIntervalMinutes('every 45 minutes'), 45);
      expect(hermesIntervalMinutes('0 9 * * *'), isNull);
      expect(hermesIntervalMinutes('every monday 9am'), isNull);
    });

    test('natural phrases mirror _natural_every_to_cron', () {
      expect(hermesNaturalToCron('every monday 9am'), '0 9 * * 1');
      expect(hermesNaturalToCron('weekdays at 9am'), '0 9 * * 1-5');
      expect(hermesNaturalToCron('every day at noon'), '0 12 * * *');
      expect(hermesNaturalToCron('every weekend 10:30'), '30 10 * * 0,6');
      expect(hermesNaturalToCron('every 30m'), isNull);
    });

    test('model validation accepts every Hermes shape', () {
      for (final raw in const [
        '0 9 * * *',
        'every 60m',
        '30m',
        'weekdays at 9am',
        'in 2h',
        '2026-10-03T14:00:00',
      ]) {
        expect(HermesSchedule.isValidSchedule(raw), isTrue, reason: raw);
      }
      expect(HermesSchedule.isValidSchedule('nope'), isFalse);
    });
  });
}
