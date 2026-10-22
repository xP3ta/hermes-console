part of '../relative_time.dart';

class _RelativeIt extends _RelativeTimeGrammar {
  const _RelativeIt();

  @override
  String format(Duration age, DateTime date) {
    if (age.isNegative || age.inMinutes < 1) return 'adesso';
    if (age.inHours < 1) {
      return age.inMinutes == 1 ? '1 minuto fa' : '${age.inMinutes} minuti fa';
    }
    if (age.inDays < 1) {
      return age.inHours == 1 ? '1 ora fa' : '${age.inHours} ore fa';
    }
    if (age.inDays < 7) {
      return age.inDays == 1 ? '1 giorno fa' : '${age.inDays} giorni fa';
    }
    return '${date.day}/${date.month}';
  }
}
