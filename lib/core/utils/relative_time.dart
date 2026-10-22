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
  final lang = languageCode.toLowerCase();
  final spanish = lang.startsWith('es');
  // El portugués comparte el formato compacto del español ('36 min', '2 h',
  // '5 d'); solo cambia la palabra inmediata ("agora").
  final compact = spanish || lang.startsWith('pt');
  if (diff.isNegative || diff.inMinutes < 1) {
    if (compact) return spanish ? 'ahora' : 'agora';
    return 'just now';
  }
  if (diff.inHours < 1) {
    return compact ? '${diff.inMinutes} min' : '${diff.inMinutes}m ago';
  }
  if (diff.inDays < 1) {
    return compact ? '${diff.inHours} h' : '${diff.inHours}h ago';
  }
  if (diff.inDays < 7) {
    return compact ? '${diff.inDays} d' : '${diff.inDays}d ago';
  }
  return '${dt.day}/${dt.month}';
}
