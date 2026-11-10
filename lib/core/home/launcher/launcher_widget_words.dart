// The words of the launcher widgets, in the app's language, and the small
// calendar they need (a time of day, a day word, "in 2 h 14 min").
import 'dart:ui' show Locale;

import 'package:intl/intl.dart';

import '../../../l10n/app_localizations.dart';

class LwWords {
  LwWords(
    this.s, {
    required this.locale,
    required this.use24h,
    required this.nowMs,
  });

  final Strings s;
  final Locale locale;
  final bool use24h;
  final int nowMs;

  String get _tag => locale.toLanguageTag();

  static String _two(int v) => v < 10 ? '0$v' : '$v';

  /// "18:30" (or the language's own 12 h form, "6:30 PM", "午後6:30",
  /// where the device keeps 12 h).
  String time(int atMs) {
    final t = DateTime.fromMillisecondsSinceEpoch(atMs);
    if (use24h) return '${t.hour}:${_two(t.minute)}';
    try {
      return DateFormat.jm(_tag).format(t);
    } catch (_) {
      // Locale data not loaded: the 24 h form is still a time.
      return '${t.hour}:${_two(t.minute)}';
    }
  }

  static DateTime _startOfDay(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return DateTime(t.year, t.month, t.day);
  }

  /// Whole days from today to [atMs]: 0 today, 1 tomorrow, -1 yesterday.
  int dayOffset(int atMs) {
    final then = _startOfDay(atMs).add(const Duration(hours: 12));
    final today = _startOfDay(nowMs).add(const Duration(hours: 12));
    return (then.difference(today).inHours / 24).round();
  }

  /// "Hoy", "Mañana", "Ayer", a weekday within the week, else "25 sept".
  String day(int atMs) {
    final days = dayOffset(atMs);
    if (days == 0) return s.lwpToday;
    if (days == 1) return s.lwpTomorrow;
    if (days == -1) return s.lwpYesterday;
    final t = DateTime.fromMillisecondsSinceEpoch(atMs);
    try {
      final format = days >= -6 && days <= 6
          ? DateFormat.E(_tag)
          : DateFormat.MMMd(_tag);
      return format.format(t).replaceAll('.', '');
    } catch (_) {
      // Locale data not loaded: a plain date is still a date.
      return '${t.day}/${t.month}';
    }
  }

  /// "Hoy · 18:30".
  String dayTime(int atMs) => s.lwpDayTime(day(atMs), time(atMs));

  /// A past moment, short: its time when it was today, else its day.
  String moment(int atMs) => dayOffset(atMs) >= 0 ? time(atMs) : day(atMs);

  /// "en 2 h 14 min", "en 25 min", "en 3 días"; null when [atMs] has passed.
  String? inTime(int atMs) {
    final ms = atMs - nowMs;
    if (ms <= 0) return null;
    final minutes = (ms / 60000).ceil();
    if (minutes < 60) return s.lwpInMinutes(minutes);
    if (minutes < 24 * 60) return s.lwpInHours(minutes ~/ 60, minutes % 60);
    return s.lwpInDays((minutes / (24 * 60)).round());
  }

  /// "hace 2 min", "hace 3 h"; for older moments, the day.
  String ago(int atMs) {
    final ms = nowMs - atMs;
    if (ms < 0) return s.lwpAgoMinutes(0);
    final minutes = ms ~/ 60000;
    if (minutes < 60) return s.lwpAgoMinutes(minutes);
    if (minutes < 24 * 60) return s.lwpAgoHours(minutes ~/ 60);
    return day(atMs);
  }

  /// The phase of a running chat in a word; a tool name is already words.
  String phase(String raw) => switch (raw) {
    'thinking' => s.lwpThinking,
    'streaming' => s.lwpResponding,
    '' => s.lwpWorking,
    _ => raw,
  };
}
