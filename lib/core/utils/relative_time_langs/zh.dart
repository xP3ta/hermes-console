part of '../relative_time.dart';

class _RelativeZh extends _RelativeTimeGrammar {
  const _RelativeZh();

  @override
  String format(Duration age, DateTime date) {
    if (age.isNegative || age.inMinutes < 1) return '刚刚';
    if (age.inHours < 1) return '${age.inMinutes}分钟前';
    if (age.inDays < 1) return '${age.inHours}小时前';
    if (age.inDays < 7) return '${age.inDays}天前';
    return '${date.month}月${date.day}日';
  }
}
