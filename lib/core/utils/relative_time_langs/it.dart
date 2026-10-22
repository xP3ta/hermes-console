part of '../relative_time.dart';

// English grammar stub for Phase 3b.
class _RelativeIt extends _RelativeTimeGrammar {
  const _RelativeIt();

  @override
  String format(Duration age, DateTime date) {
    if (age.isNegative || age.inMinutes < 1) return 'just now';
    if (age.inHours < 1) return '${age.inMinutes}m ago';
    if (age.inDays < 1) return '${age.inHours}h ago';
    if (age.inDays < 7) return '${age.inDays}d ago';
    return '${date.day}/${date.month}';
  }
}
