// Port of Hermes Desktop `apps/desktop/src/lib/time.ts::calendarBucket`: the
// human day ends at 04:00 local, then today → yesterday → this week → last
// week → this month → month → month + year.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/calendar_bucket.dart';

double _at(int y, int m, int d, [int h = 12, int min = 0]) =>
    DateTime(y, m, d, h, min).millisecondsSinceEpoch / 1000;

CalendarBucket _bucket(
  double seconds,
  DateTime now, {
  int weekStartsOn = DateTime.monday,
}) => calendarBucket(seconds, now, weekStartsOn: weekStartsOn).bucket;

void main() {
  // Wednesday 14 October 2026.
  final wed = DateTime(2026, 10, 14, 10, 0);

  test('the human day rolls over at 04:00', () {
    expect(dayRolloverHour, 4);
  });

  group('days', () {
    test('earlier the same day is today', () {
      expect(_bucket(_at(2026, 10, 14, 8), wed), CalendarBucket.today);
      expect(_bucket(_at(2026, 10, 14, 4), wed), CalendarBucket.today);
    });

    test('a time in the future is today', () {
      expect(_bucket(_at(2026, 10, 15, 9), wed), CalendarBucket.today);
    });

    test('the day before is yesterday', () {
      expect(_bucket(_at(2026, 10, 13, 10), wed), CalendarBucket.yesterday);
      expect(_bucket(_at(2026, 10, 13, 4), wed), CalendarBucket.yesterday);
    });

    test('the second last day is not yesterday', () {
      expect(_bucket(_at(2026, 10, 12, 23), wed), CalendarBucket.thisWeek);
    });
  });

  group('rollover at 04:00', () {
    test('02:00 seen from 05:00 is still the previous human day', () {
      final now = DateTime(2026, 10, 14, 5, 0);
      expect(_bucket(_at(2026, 10, 14, 2), now), CalendarBucket.yesterday);
    });

    test('04:00 sharp already belongs to the new day', () {
      final now = DateTime(2026, 10, 14, 5, 0);
      expect(_bucket(_at(2026, 10, 14, 4), now), CalendarBucket.today);
      expect(_bucket(_at(2026, 10, 14, 3, 59), now), CalendarBucket.yesterday);
    });

    test('02:00 seen from 03:00 shares the human day with now: today', () {
      final now = DateTime(2026, 10, 14, 3, 0);
      expect(_bucket(_at(2026, 10, 14, 2), now), CalendarBucket.today);
    });

    test('23:00 the evening before, seen at 03:00, is still today', () {
      final now = DateTime(2026, 10, 14, 3, 0);
      expect(_bucket(_at(2026, 10, 13, 23), now), CalendarBucket.today);
      expect(_bucket(_at(2026, 10, 13, 3, 59), now), CalendarBucket.yesterday);
    });

    test('the rollover crosses a month boundary', () {
      final now = DateTime(2026, 11, 1, 2, 0);
      expect(_bucket(_at(2026, 10, 31, 10), now), CalendarBucket.today);
      expect(_bucket(_at(2026, 10, 30, 10), now), CalendarBucket.yesterday);
    });

    test('the rollover crosses a year boundary', () {
      final now = DateTime(2027, 1, 1, 3, 0);
      expect(_bucket(_at(2026, 12, 31, 9), now), CalendarBucket.today);
    });
  });

  group('weeks follow the first day of the week', () {
    test(
      'Monday start: Monday is this week, the Sunday before is last week',
      () {
        expect(_bucket(_at(2026, 10, 12), wed), CalendarBucket.thisWeek);
        expect(_bucket(_at(2026, 10, 11), wed), CalendarBucket.lastWeek);
        expect(_bucket(_at(2026, 10, 5), wed), CalendarBucket.lastWeek);
      },
    );

    test('older than last week in the same month is this month', () {
      expect(_bucket(_at(2026, 10, 4), wed), CalendarBucket.thisMonth);
      expect(_bucket(_at(2026, 10, 1), wed), CalendarBucket.thisMonth);
    });

    test('Sunday start moves the boundary a day', () {
      expect(
        _bucket(_at(2026, 10, 11), wed, weekStartsOn: DateTime.sunday),
        CalendarBucket.thisWeek,
      );
      expect(
        _bucket(_at(2026, 10, 10), wed, weekStartsOn: DateTime.sunday),
        CalendarBucket.lastWeek,
      );
      expect(
        _bucket(_at(2026, 10, 4), wed, weekStartsOn: DateTime.sunday),
        CalendarBucket.lastWeek,
      );
      expect(
        _bucket(_at(2026, 10, 3), wed, weekStartsOn: DateTime.sunday),
        CalendarBucket.thisMonth,
      );
    });

    test('Saturday start', () {
      expect(
        _bucket(_at(2026, 10, 10), wed, weekStartsOn: DateTime.saturday),
        CalendarBucket.thisWeek,
      );
      expect(
        _bucket(_at(2026, 10, 9), wed, weekStartsOn: DateTime.saturday),
        CalendarBucket.lastWeek,
      );
    });

    test('a week that spans two months still counts as this week', () {
      // Thursday 1 October 2026: the week started on Monday 28 September.
      final now = DateTime(2026, 10, 1, 10, 0);
      expect(_bucket(_at(2026, 9, 29), now), CalendarBucket.thisWeek);
      expect(_bucket(_at(2026, 9, 25), now), CalendarBucket.lastWeek);
    });

    test('the week changes across a year boundary', () {
      // Saturday 2 January 2027; Monday start: the week began on 28 December.
      final now = DateTime(2027, 1, 2, 10, 0);
      expect(_bucket(_at(2026, 12, 31), now), CalendarBucket.thisWeek);
      expect(_bucket(_at(2026, 12, 21), now), CalendarBucket.lastWeek);
      expect(_bucket(_at(2026, 12, 14), now), CalendarBucket.monthYear);
    });
  });

  group('months and years', () {
    test('an earlier month of the same year is named by month', () {
      final key = calendarBucket(_at(2026, 9, 20), wed);
      expect(key.bucket, CalendarBucket.month);
      expect((key.year, key.month), (2026, 9));
    });

    test('another year is named by month and year', () {
      final key = calendarBucket(_at(2025, 12, 20), wed);
      expect(key.bucket, CalendarBucket.monthYear);
      expect((key.year, key.month), (2025, 12));
    });

    test('different months are different sections', () {
      expect(
        calendarBucket(_at(2026, 9, 20), wed),
        isNot(calendarBucket(_at(2026, 8, 20), wed)),
      );
      expect(
        calendarBucket(_at(2026, 9, 20), wed),
        calendarBucket(_at(2026, 9, 2), wed),
      );
    });

    test('January looks back to December of the previous year', () {
      final now = DateTime(2027, 1, 20, 10, 0);
      final key = calendarBucket(_at(2026, 12, 5), now);
      expect(key.bucket, CalendarBucket.monthYear);
      expect((key.year, key.month), (2026, 12));
    });

    test('this month, last week and today carry no month', () {
      expect(calendarBucket(_at(2026, 10, 14, 8), wed).year, isNull);
      expect(calendarBucket(_at(2026, 10, 2), wed).month, isNull);
    });
  });

  group('wall-clock arithmetic', () {
    // The rule works on local calendar fields, never on 24 h spans, so a day
    // with 23 or 25 hours (DST) still has a single human day.
    test('shifting by the rollover never skips or repeats a calendar day', () {
      var day = DateTime(2026, 3, 20, 12);
      for (var i = 0; i < 20; i++) {
        final now = day.add(const Duration(days: 1));
        final diff = calendarBucket(
          DateTime(day.year, day.month, day.day, 12).millisecondsSinceEpoch /
              1000,
          DateTime(now.year, now.month, now.day, 12),
        );
        expect(diff.bucket, CalendarBucket.yesterday, reason: '$day');
        day = now;
      }
    });
  });
}
