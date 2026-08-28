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
  final spanish = languageCode.toLowerCase().startsWith('es');
  if (diff.isNegative || diff.inMinutes < 1) {
    return spanish ? 'ahora' : 'just now';
  }
  if (diff.inHours < 1) {
    return spanish ? '${diff.inMinutes} min' : '${diff.inMinutes}m ago';
  }
  if (diff.inDays < 1) {
    return spanish ? '${diff.inHours} h' : '${diff.inHours}h ago';
  }
  if (diff.inDays < 7) {
    return spanish ? '${diff.inDays} d' : '${diff.inDays}d ago';
  }
  return '${dt.day}/${dt.month}';
}
