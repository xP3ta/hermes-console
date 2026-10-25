part of '../relative_time.dart';

class _RelativeEs extends _RelativeTimeGrammar {
  const _RelativeEs();

  @override
  String format(Duration age, DateTime date) {
    if (age.isNegative || age.inMinutes < 1) return 'ahora';
    if (age.inHours < 1) return '${age.inMinutes} min';
    if (age.inDays < 1) return '${age.inHours} h';
    if (age.inDays < 7) return '${age.inDays} d';
    return '${date.day}/${date.month}';
  }
}
