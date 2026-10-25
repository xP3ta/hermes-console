part of '../relative_time.dart';

class _RelativeFr extends _RelativeTimeGrammar {
  const _RelativeFr();

  @override
  String format(Duration age, DateTime date) {
    if (age.isNegative || age.inMinutes < 1) return 'à l’instant';
    if (age.inHours < 1) return 'il y a ${age.inMinutes} min';
    if (age.inDays < 1) return 'il y a ${age.inHours} h';
    if (age.inDays < 7) return 'il y a ${age.inDays} j';
    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}';
  }
}
