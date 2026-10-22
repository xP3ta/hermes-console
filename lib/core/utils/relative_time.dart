import 'dart:ui' show Locale;

import '../../l10n/app_localizations.dart';
import '../services/notifications/notification_strings.dart'
    show resolveNotificationLang;
import 'session_timestamp.dart';

/// Returns a human-readable relative timestamp for a Unix-seconds value.
///
/// Accepts timestamps in seconds or milliseconds. Invalid and decades-old
/// values never return "just now"; future dates preserve the established
/// "just now" behavior.
///
/// Examples: "just now", "5m ago", "3h ago", "2d ago", "14/6".
String relativeTime(double ts, {String languageCode = 'en', DateTime? now}) {
  final canonicalTs = normalizeEpochTimestamp(ts) ?? 0;
  if (canonicalTs <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch((canonicalTs * 1000).toInt());
  final diff = (now ?? DateTime.now()).difference(dt);
  final strings = lookupStrings(Locale(resolveNotificationLang(languageCode)));
  if (diff.isNegative || diff.inMinutes < 1) {
    return strings.i18n131RelativeNow;
  }
  if (diff.inHours < 1) {
    return strings.i18n131RelativeMinutes(diff.inMinutes);
  }
  if (diff.inDays < 1) {
    return strings.i18n131RelativeHours(diff.inHours);
  }
  if (diff.inDays < 7) {
    return strings.i18n131RelativeDays(diff.inDays);
  }
  return '${dt.day}/${dt.month}';
}
