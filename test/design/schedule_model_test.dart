import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/schedule_model.dart';
import 'package:hermes_android/l10n/app_localizations_en.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';

void main() {
  final en = StringsEn();
  final es = StringsEs();

  group('parse → describe uses the REAL time (the 09:00 bug)', () {
    test('30 18 * * * is "Every day at 18:30", not 09:00', () {
      final s = HermesSchedule.parse('30 18 * * *');
      expect(s.mode, HermesScheduleMode.daily);
      expect(s.hour, 18);
      expect(s.minute, 30);
      expect(s.describe(en), 'Every day at 18:30');
      expect(s.describe(es), 'Cada día a las 18:30');
    });

    test('weekdays keep their hour', () {
      final s = HermesSchedule.parse('45 7 * * 1-5');
      expect(s.describe(en), 'Weekdays at 7:45');
      expect(s.describe(es), 'Laborables a las 7:45');
    });

    test('weekly keeps its day (not always Monday)', () {
      final s = HermesSchedule.parse('0 20 * * 5');
      expect(s.mode, HermesScheduleMode.days);
      expect(s.weekdays, {5});
      expect(s.describe(en), 'Every Friday at 20:00');
    });

    test('weekends and Sunday as 0 or 7', () {
      expect(
        HermesSchedule.parse('0 10 * * 0,6').describe(en),
        'Weekends at 10:00',
      );
      expect(HermesSchedule.parse('0 10 * * 6,7').weekdays, {6, 7});
      expect(HermesSchedule.parse('0 10 * * sat,sun').weekdays, {6, 7});
    });

    test('monthly keeps its day and time', () {
      final s = HermesSchedule.parse('15 8 12 * *');
      expect(s.mode, HermesScheduleMode.month);
      expect(s.describe(en), 'On day 12 of every month at 8:15');
    });

    test('intervals', () {
      expect(HermesSchedule.parse('*/15 * * * *').describe(en), 'Every 15 min');
      expect(HermesSchedule.parse('0 * * * *').describe(en), 'Every hour');
      expect(HermesSchedule.parse('0 */6 * * *').describe(en), 'Every 6 hours');
      expect(HermesSchedule.parse('0 */6 * * *').describe(es), 'Cada 6 horas');
    });

    test('unknown shapes stay custom and round-trip untouched', () {
      for (final raw in const [
        '0 9 1-7 * 1',
        '0 9 * 1 *',
        '0 9,18 * * *',
        '@daily',
        '5 4 * * sun#2',
      ]) {
        final s = HermesSchedule.parse(raw);
        expect(s.mode, HermesScheduleMode.custom, reason: raw);
        expect(s.toCron(), raw, reason: raw);
      }
    });
  });

  group('model → cron', () {
    test('round trip of every builder mode', () {
      const cases = <String>[
        '30 18 * * *',
        '0 9 * * 1-5',
        '0 9 * * 1,3,5',
        '0 10 * * 0,6',
        '0 8 * * 0-2',
        '*/5 * * * *',
        '0 * * * *',
        '20 * * * *',
        '0 */2 * * *',
        '0 9 1 * *',
        '30 23 28 * *',
      ];
      for (final expr in cases) {
        expect(HermesSchedule.parse(expr).toCron(), expr, reason: expr);
      }
    });

    test('days are emitted compactly', () {
      expect(
        const HermesSchedule.days(
          {1, 2, 3, 4, 5},
          hour: 18,
          minute: 30,
        ).toCron(),
        '30 18 * * 1-5',
      );
      expect(
        const HermesSchedule.days({6, 7}, hour: 9).toCron(),
        '0 9 * * 0,6',
      );
      expect(
        const HermesSchedule.days({7, 1, 2, 3}, hour: 9).toCron(),
        '0 9 * * 0-3',
      );
    });

    test('all seven days collapse to daily', () {
      expect(
        HermesSchedule.parse('0 9 * * 0-6').mode,
        HermesScheduleMode.daily,
      );
    });

    test('validation', () {
      expect(const HermesSchedule.days({}).isValid, isFalse);
      expect(const HermesSchedule.custom('0 9 * *').isValid, isFalse);
      expect(const HermesSchedule.custom('0 9 * * 1').isValid, isTrue);
      expect(HermesSchedule.isValidCron('*/15 9-17 * * 1-5'), isTrue);
      expect(HermesSchedule.isValidCron('hello world'), isFalse);
    });
  });

  group('builder round trip (real jobs and examples)', () {
    // (schedule, mode, emitted string)
    const cases = <(String, HermesScheduleMode, String)>[
      ('*/5 14-17 * * 1-5', HermesScheduleMode.interval, '*/5 14-17 * * 1-5'),
      ('*/5 7-9 * * 1-5', HermesScheduleMode.interval, '*/5 7-9 * * 1-5'),
      ('every 60m', HermesScheduleMode.interval, 'every 60m'),
      ('30m', HermesScheduleMode.interval, 'every 30m'),
      ('every 2h', HermesScheduleMode.interval, 'every 120m'),
      ('0 9 * * *', HermesScheduleMode.daily, '0 9 * * *'),
      ('30 18 * * 1-5', HermesScheduleMode.days, '30 18 * * 1-5'),
      ('0 */2 * * *', HermesScheduleMode.interval, '0 */2 * * *'),
      ('0 9 1 * *', HermesScheduleMode.month, '0 9 1 * *'),
      ('*/10 9-17 * * *', HermesScheduleMode.interval, '*/10 9-17 * * *'),
      ('0 9-17 * * 1-5', HermesScheduleMode.interval, '0 9-17 * * 1-5'),
      ('0 8-20/4 * * *', HermesScheduleMode.interval, '0 8-20/4 * * *'),
      ('*/20 * * * 0,6', HermesScheduleMode.interval, '*/20 * * * 0,6'),
      ('every monday 9am', HermesScheduleMode.days, '0 9 * * 1'),
      ('weekdays at 9am', HermesScheduleMode.days, '0 9 * * 1-5'),
    ];
    for (final (raw, mode, out) in cases) {
      test('"$raw"', () {
        final s = HermesSchedule.parse(raw);
        expect(s.mode, mode, reason: raw);
        expect(s.toCron(), out, reason: raw);
        // The emitted string parses back to the same schedule.
        expect(HermesSchedule.parse(out), s, reason: raw);
        expect(HermesSchedule.parse(out).describe(es), s.describe(es));
      });
    }

    test('the window fields are filled from the real job', () {
      final s = HermesSchedule.parse('*/5 14-17 * * 1-5');
      expect(s.intervalMinutes, 5);
      expect(s.windowStart, 14);
      expect(s.windowEnd, 17);
      expect(s.weekdays, {1, 2, 3, 4, 5});
      expect(s.native, isFalse);
    });

    test('a native interval stays native until it gets limits', () {
      final s = HermesSchedule.parse('every 60m');
      expect(s.native, isTrue);
      expect(s.toCron(), 'every 60m');
      expect(
        s.copyWith(windowStart: () => 9, windowEnd: () => 17).toCron(),
        '0 9-17 * * *',
      );
      expect(s.copyWith(weekdays: {1, 2, 3, 4, 5}).toCron(), '0 * * * 1-5');
      // Hermes accepts "every 90m" but no clock cron can hold it.
      expect(
        const HermesSchedule.interval(90, native: true).toCron(),
        'every 90m',
      );
    });

    test('shapes that would change meaning stay custom', () {
      for (final raw in const [
        '*/7 * * * *', // 0,7,…,56 then 0: not a steady 7 min
        '*/5 9-11,14-16 * * *', // two windows
        '5-59/5 * * * *',
        '0 9 * * 1#2',
      ]) {
        final s = HermesSchedule.parse(raw);
        expect(s.mode, HermesScheduleMode.custom, reason: raw);
        expect(s.toCron(), raw, reason: raw);
      }
    });
  });

  group('next run', () {
    final from = DateTime(2026, 9, 26, 21, 40); // Saturday

    test('daily later today or tomorrow', () {
      expect(
        const HermesSchedule.daily(hour: 22, minute: 0).nextRun(from),
        DateTime(2026, 9, 26, 22),
      );
      expect(
        const HermesSchedule.daily(hour: 18, minute: 30).nextRun(from),
        DateTime(2026, 9, 27, 18, 30),
      );
    });

    test('weekdays skip the weekend', () {
      expect(
        const HermesSchedule.days(
          {1, 2, 3, 4, 5},
          hour: 18,
          minute: 30,
        ).nextRun(from),
        DateTime(2026, 9, 28, 18, 30),
      );
    });

    test('intervals', () {
      expect(
        const HermesSchedule.interval(15).nextRun(from),
        DateTime(2026, 9, 26, 21, 45),
      );
      expect(
        const HermesSchedule.interval(120).nextRun(from),
        DateTime(2026, 9, 26, 22),
      );
    });

    test('month', () {
      expect(
        const HermesSchedule.month(1, hour: 9).nextRun(from),
        DateTime(2026, 10, 1, 9),
      );
    });
  });

  group('window end shown by the builder matches the summary', () {
    for (final schedule in const [
      HermesSchedule.interval(5, windowStart: 14, windowEnd: 17),
      HermesSchedule.interval(15, windowStart: 8, windowEnd: 20),
      HermesSchedule.interval(60, windowStart: 9, windowEnd: 17),
      HermesSchedule.interval(120, windowStart: 9, windowEnd: 16),
      HermesSchedule.interval(120, minute: 30, windowStart: 9, windowEnd: 17),
    ]) {
      test(schedule.toCron(), () {
        final (h, m) = schedule.lastRunInWindow(schedule.windowEnd!);
        final label = '$h:${m.toString().padLeft(2, '0')}';
        expect(schedule.describe(en), contains('to $label'));
        expect(schedule.describe(es), contains('a $label'));
      });
    }
  });
}
