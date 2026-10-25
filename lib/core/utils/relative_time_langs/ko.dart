part of '../relative_time.dart';

class _RelativeKo extends _RelativeTimeGrammar {
  const _RelativeKo();

  @override
  String format(Duration age, DateTime date) {
    if (age.isNegative || age.inMinutes < 1) return '방금';
    if (age.inHours < 1) return '${age.inMinutes}분 전';
    if (age.inDays < 1) return '${age.inHours}시간 전';
    if (age.inDays < 7) return '${age.inDays}일 전';
    return '${date.month}월 ${date.day}일';
  }
}
