import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../models/calendar_bucket.dart';

/// Section title of [key]: the fixed names (Today, Yesterday, This week, Last
/// week, This month) or the month in the device language, with the year when
/// it is not the current one.
String calendarBucketLabel(Strings s, CalendarBucketKey key, Locale locale) {
  switch (key.bucket) {
    case CalendarBucket.today:
      return s.sesDateToday;
    case CalendarBucket.yesterday:
      return s.sesDateYesterday;
    case CalendarBucket.thisWeek:
      return s.se1215DateThisWeek;
    case CalendarBucket.lastWeek:
      return s.se1215DateLastWeek;
    case CalendarBucket.thisMonth:
      return s.se1215DateThisMonth;
    case CalendarBucket.month:
    case CalendarBucket.monthYear:
      final tag = locale.toLanguageTag();
      final date = DateTime(key.year ?? 1970, key.month ?? 1);
      final text = key.bucket == CalendarBucket.month
          ? DateFormat.MMMM(tag).format(date)
          : DateFormat.yMMMM(tag).format(date);
      return text.isEmpty
          ? text
          : '${text.substring(0, 1).toUpperCase()}${text.substring(1)}';
  }
}
