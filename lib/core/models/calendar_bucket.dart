/// Date sections of a session list, ported 1:1 from Hermes Desktop
/// `apps/desktop/src/lib/time.ts::calendarBucket`.
///
/// The "human" day ends at [dayRolloverHour] local, so a chat from 02:00 still
/// belongs to the evening before. Weeks start on the locale's first day. All
/// arithmetic is on local calendar fields, never on 24 h spans, so a day with
/// 23 or 25 hours (DST) is still one day.
library;

/// Local hour at which the human day rolls over.
const dayRolloverHour = 4;

enum CalendarBucket {
  today,
  yesterday,
  thisWeek,
  lastWeek,
  thisMonth,

  /// An earlier month of the current year.
  month,

  /// A month of another year.
  monthYear,
}

/// A section of the list: [bucket], plus the month for [CalendarBucket.month]
/// and [CalendarBucket.monthYear] so different months stay separate sections.
final class CalendarBucketKey {
  final CalendarBucket bucket;
  final int? year;
  final int? month;

  const CalendarBucketKey(this.bucket, {this.year, this.month});

  @override
  bool operator ==(Object other) =>
      other is CalendarBucketKey &&
      other.bucket == bucket &&
      other.year == year &&
      other.month == month;

  @override
  int get hashCode => Object.hash(bucket, year, month);

  @override
  String toString() => 'CalendarBucketKey($bucket, $year-$month)';
}

/// The local calendar day [dt] belongs to once the day rolls over at
/// [rolloverHour], as a UTC midnight so day arithmetic is exact.
DateTime _humanDay(DateTime dt, int rolloverHour) {
  final shifted = DateTime(dt.year, dt.month, dt.day, dt.hour - rolloverHour);
  return DateTime.utc(shifted.year, shifted.month, shifted.day);
}

/// Section of a row last active at [seconds] (epoch) seen at [now].
/// [weekStartsOn] is a [DateTime.weekday] (Monday by default, as Desktop's
/// fallback).
CalendarBucketKey calendarBucket(
  double seconds,
  DateTime now, {
  int weekStartsOn = DateTime.monday,
  int rolloverHour = dayRolloverHour,
}) {
  final item = _humanDay(
    DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round()),
    rolloverHour,
  );
  final today = _humanDay(now, rolloverHour);
  final days = today.difference(item).inDays;
  if (days <= 0) return const CalendarBucketKey(CalendarBucket.today);
  if (days == 1) return const CalendarBucketKey(CalendarBucket.yesterday);

  final sinceWeekStart = (today.weekday - weekStartsOn + 7) % 7;
  final thisWeekStart = today.subtract(Duration(days: sinceWeekStart));
  if (!item.isBefore(thisWeekStart)) {
    return const CalendarBucketKey(CalendarBucket.thisWeek);
  }
  if (!item.isBefore(thisWeekStart.subtract(const Duration(days: 7)))) {
    return const CalendarBucketKey(CalendarBucket.lastWeek);
  }
  if (item.year == today.year && item.month == today.month) {
    return const CalendarBucketKey(CalendarBucket.thisMonth);
  }
  return CalendarBucketKey(
    item.year == today.year ? CalendarBucket.month : CalendarBucket.monthYear,
    year: item.year,
    month: item.month,
  );
}
