part of '../relative_time.dart';

class _RelativeDe extends _RelativeTimeGrammar {
  const _RelativeDe();

  @override
  String format(Duration age, DateTime date) {
    if (age.isNegative || age.inMinutes < 1) return 'gerade eben';
    if (age.inHours < 1) {
      final minutes = age.inMinutes;
      return minutes == 1 ? 'vor 1 Minute' : 'vor $minutes Minuten';
    }
    if (age.inDays < 1) {
      final hours = age.inHours;
      return hours == 1 ? 'vor 1 Stunde' : 'vor $hours Stunden';
    }
    if (age.inDays < 7) {
      final days = age.inDays;
      return days == 1 ? 'vor 1 Tag' : 'vor $days Tagen';
    }
    return '${date.day}.${date.month}.';
  }
}
