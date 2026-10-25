part of '../relative_time.dart';

class _RelativeJa extends _RelativeTimeGrammar {
  const _RelativeJa();

  @override
  String format(Duration age, DateTime date) {
    if (age.isNegative || age.inMinutes < 1) return 'たった今';
    if (age.inHours < 1) return '${age.inMinutes}分前';
    if (age.inDays < 1) return '${age.inHours}時間前';
    if (age.inDays < 7) return '${age.inDays}日前';
    return '${date.month}月${date.day}日';
  }
}
