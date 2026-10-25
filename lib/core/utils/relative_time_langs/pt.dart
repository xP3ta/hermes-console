part of '../relative_time.dart';

class _RelativePt extends _RelativeTimeGrammar {
  const _RelativePt();

  @override
  String format(Duration age, DateTime date) {
    if (age.isNegative || age.inMinutes < 1) return 'agora';
    if (age.inHours < 1) return '${age.inMinutes} min';
    if (age.inDays < 1) return '${age.inHours} h';
    if (age.inDays < 7) return '${age.inDays} d';
    return '${date.day}/${date.month}';
  }
}
