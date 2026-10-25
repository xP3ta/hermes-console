import '../services/notifications/notification_strings.dart'
    show resolveNotificationLang;
import 'session_timestamp.dart';

part 'relative_time_langs/es.dart';
part 'relative_time_langs/en.dart';
part 'relative_time_langs/pt.dart';
part 'relative_time_langs/de.dart';
part 'relative_time_langs/fr.dart';
part 'relative_time_langs/it.dart';
part 'relative_time_langs/ja.dart';
part 'relative_time_langs/ko.dart';
part 'relative_time_langs/zh.dart';

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
  final grammar = _relativeTimeGrammars[resolveNotificationLang(languageCode)]!;
  return grammar.format(diff, dt);
}

abstract class _RelativeTimeGrammar {
  const _RelativeTimeGrammar();

  String format(Duration age, DateTime date);
}

const _relativeTimeGrammars = <String, _RelativeTimeGrammar>{
  'es': _RelativeEs(),
  'en': _RelativeEn(),
  'pt': _RelativePt(),
  'de': _RelativeDe(),
  'fr': _RelativeFr(),
  'it': _RelativeIt(),
  'ja': _RelativeJa(),
  'ko': _RelativeKo(),
  'zh': _RelativeZh(),
};
