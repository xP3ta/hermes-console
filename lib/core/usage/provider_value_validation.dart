/// Accept only complete calendar dates emitted by the usage serializers.
/// DateTime.parse alone normalizes impossible days, so compare components.
String? validatedRenewalDate(Object? raw) {
  if (raw is! String) return null;
  final text = raw.trim();
  final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text);
  final named = RegExp(
    r'^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (\d{1,2}), (\d{4})$',
  ).firstMatch(text);
  int year;
  int month;
  int day;
  if (iso != null) {
    year = int.parse(iso.group(1)!);
    month = int.parse(iso.group(2)!);
    day = int.parse(iso.group(3)!);
  } else if (named != null) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    year = int.parse(named.group(3)!);
    month = months.indexOf(named.group(1)!) + 1;
    day = int.parse(named.group(2)!);
  } else {
    return null;
  }
  if (year < 1 || month < 1 || month > 12 || day < 1 || day > 31) return null;
  final date = DateTime.utc(year, month, day);
  if (date.year != year || date.month != month || date.day != day) return null;
  return text;
}

/// A reset suffix is optional, but if present it must be a real date/time.
/// Time-zone text is discarded, not rendered or interpolated.
bool validResetTimestamp(String? raw) {
  if (raw == null) return true;
  final match = RegExp(
    r'^(\d{4}-\d{2}-\d{2}) (\d{2}):(\d{2})(?: [A-Z]{1,5})?$',
  ).firstMatch(raw);
  return match != null &&
      validatedRenewalDate(match.group(1)) != null &&
      int.parse(match.group(2)!) < 24 &&
      int.parse(match.group(3)!) < 60;
}

final _url = RegExp(
  r'(?:[a-z][a-z0-9+.-]*://|www\.)\S+|\b[\w.-]+\.(?:com|net|org|io|ai|dev|app|co)(?:/\S*)?',
  caseSensitive: false,
);
final _uuid = RegExp(
  r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b',
  caseSensitive: false,
);
final _prefixedId = RegExp(
  r'\b(?:org|user|acct|account|team|proj|project|ws|cus|sub|key|sk)[-_][A-Za-z0-9_-]{4,}\b',
  caseSensitive: false,
);
// Any long token that mixes letters and digits (hex ids, opaque keys).
final _opaque = RegExp(
  r'\b(?=[A-Za-z0-9_-]*\d)(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{12,}\b',
);
final _email = RegExp(r'\b[\w.+-]+@[\w-]+\.[\w.-]+\b');
final _label = RegExp(r'^[A-Za-z][A-Za-z ]{0,30}:\s*');

/// [text] without URLs, e-mails or ids (and without a leading «Label:»),
/// or null when nothing readable is left.
String? scrubProviderText(String text) {
  var t = text
      .replaceAll(_email, ' ')
      .replaceAll(_url, ' ')
      .replaceAll(_uuid, ' ')
      .replaceAll(_prefixedId, ' ')
      .replaceAll(_opaque, ' ')
      .replaceFirst(_label, '');
  t = t
      .replaceAllMapped(RegExp(r'\s+([,.;:])'), (m) => m.group(1)!)
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .replaceAll(RegExp(r'[,;:\s]+$'), '')
      .trim();
  final letters = RegExp(r'[A-Za-z]').allMatches(t).length;
  return letters < 3 ? null : t;
}

/// Dollar display values must contain only a bounded, valid decimal amount.
String? validatedMoney(Object? raw) {
  if (raw is! String) return null;
  final text = raw.trim();
  if (!RegExp(
    r'^\$(?:\d{1,12}|\d{1,3}(?:,\d{3}){1,3})(?:\.\d{1,2})?$',
  ).hasMatch(text)) {
    return null;
  }
  return text;
}
