// Natural-language description of every schedule shape Hermes accepts
// (`cron/jobs.py::parse_schedule`): recurring intervals ("every 60m", "30m",
// "2h", "every hour"), natural phrases ("every monday 9am", "weekdays at
// 9am"), 5-field cron (with names, lists, ranges, steps, `L`, macros) and
// one-shot ISO timestamps. The raw syntax is never returned: a shape that
// cannot be described becomes "Custom schedule" and callers add the next
// run time.
import '../../l10n/app_localizations.dart';

/// Parsed 5-field cron. Weekdays use cron numbering 0 = Sunday … 6.
class CronFields {
  final List<int> minutes;
  final List<int> hours;
  final List<int> doms;
  final List<int> months;
  final List<int> dows;
  final bool domStar;
  final bool dowStar;
  final bool monthStar;

  /// Day-of-month `L`: the last day of the month.
  final bool lastDom;

  const CronFields({
    required this.minutes,
    required this.hours,
    required this.doms,
    required this.months,
    required this.dows,
    required this.domStar,
    required this.dowStar,
    required this.monthStar,
    this.lastDom = false,
  });

  static const _macros = {
    '@yearly': '0 0 1 1 *',
    '@annually': '0 0 1 1 *',
    '@monthly': '0 0 1 * *',
    '@weekly': '0 0 * * 0',
    '@daily': '0 0 * * *',
    '@midnight': '0 0 * * *',
    '@hourly': '0 * * * *',
  };

  static const _monthNames = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6, //
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };
  static const _dowNames = {
    'sun': 0, 'mon': 1, 'tue': 2, 'wed': 3, 'thu': 4, 'fri': 5, 'sat': 6, //
  };

  /// Parses [expression] (5 fields, a 6th seconds field of `0`, or a macro).
  /// Returns null for anything croniter would treat differently from a
  /// plain set of values (`#`, `W`, `nL`, …).
  static CronFields? parse(String expression) {
    var text = expression.trim().toLowerCase();
    text = _macros[text] ?? text;
    final parts = text.split(RegExp(r'\s+'));
    if (parts.length == 6 && parts[5] == '0') parts.removeLast();
    if (parts.length != 5) return null;
    final minutes = _field(parts[0], 0, 59);
    final hours = _field(parts[1], 0, 23);
    final lastDom = parts[2] == 'l';
    final doms = lastDom ? <int>[] : _field(parts[2], 1, 31);
    final months = _field(parts[3], 1, 12, names: _monthNames);
    final dowsRaw = _field(parts[4], 0, 7, names: _dowNames);
    if (minutes == null ||
        hours == null ||
        doms == null ||
        months == null ||
        dowsRaw == null) {
      return null;
    }
    final dows = {for (final d in dowsRaw) d == 7 ? 0 : d}.toList()..sort();
    bool star(String f) => f == '*' || f == '?';
    return CronFields(
      minutes: minutes,
      hours: hours,
      doms: doms,
      months: months,
      dows: dows,
      domStar: star(parts[2]),
      dowStar: star(parts[4]) || dows.length == 7,
      monthStar: star(parts[3]) || months.length == 12,
      lastDom: lastDom,
    );
  }

  static List<int>? _field(
    String field,
    int min,
    int max, {
    Map<String, int> names = const {},
  }) {
    final out = <int>{};
    int? value(String token) {
      if (names.containsKey(token)) return names[token];
      if (!RegExp(r'^\d{1,2}$').hasMatch(token)) return null;
      final n = int.parse(token);
      return n < min || n > max ? null : n;
    }

    for (final part in field.split(',')) {
      if (part.isEmpty) return null;
      final slash = part.split('/');
      if (slash.length > 2) return null;
      var step = 1;
      if (slash.length == 2) {
        final parsed = int.tryParse(slash[1]);
        if (parsed == null || parsed < 1) return null;
        step = parsed;
      }
      final base = slash[0];
      int lo;
      int hi;
      if (base == '*' || base == '?') {
        lo = min;
        hi = max;
      } else if (base.contains('-')) {
        final range = base.split('-');
        if (range.length != 2) return null;
        final a = value(range[0]);
        final b = value(range[1]);
        if (a == null || b == null || a > b) return null;
        lo = a;
        hi = b;
      } else {
        final a = value(base);
        if (a == null) return null;
        lo = a;
        // "a/step" runs from a to the field maximum.
        hi = slash.length == 2 ? max : a;
      }
      for (var v = lo; v <= hi; v += step) {
        out.add(v);
      }
    }
    if (out.isEmpty) return null;
    return out.toList()..sort();
  }

  bool _dayMatches(DateTime day) {
    if (!monthStar && !months.contains(day.month)) return false;
    final lastDay = DateTime(day.year, day.month + 1, 0).day;
    final domOk = lastDom ? day.day == lastDay : doms.contains(day.day);
    final dowOk = dows.contains(day.weekday % 7);
    final domRestricted = lastDom || !domStar;
    // croniter's default (day_or): both restricted → either matches.
    if (domRestricted && !dowStar) return domOk || dowOk;
    if (domRestricted) return domOk;
    if (!dowStar) return dowOk;
    return true;
  }

  /// Next run strictly after [from] (minute resolution), within ~5 years.
  DateTime? nextRun(DateTime from) {
    final start = DateTime(
      from.year,
      from.month,
      from.day,
      from.hour,
      from.minute,
    ).add(const Duration(minutes: 1));
    for (var i = 0; i < 366 * 5; i++) {
      final day = DateTime(start.year, start.month, start.day + i);
      if (!_dayMatches(day)) continue;
      for (final h in hours) {
        for (final m in minutes) {
          final candidate = DateTime(day.year, day.month, day.day, h, m);
          if (!candidate.isBefore(start)) return candidate;
        }
      }
    }
    return null;
  }
}

/// Hermes-native recurring interval ("every 60m", "30m", "2h", "every
/// hour", "1d") in minutes, or null. Mirrors `parse_duration`.
int? hermesIntervalMinutes(String raw) {
  var text = raw.trim().toLowerCase();
  if (text.startsWith('every ')) text = text.substring(6).trim();
  final match = RegExp(
    r'^(\d*)\s*(m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)$',
  ).firstMatch(text);
  if (match == null) return null;
  final value = match.group(1)!.isEmpty ? 1 : int.parse(match.group(1)!);
  if (value < 1) return null;
  return switch (match.group(2)![0]) {
    'h' => value * 60,
    'd' => value * 1440,
    _ => value,
  };
}

const _weekdayToCron = {
  'sunday': '0', 'sun': '0', 'monday': '1', 'mon': '1', //
  'tuesday': '2', 'tue': '2', 'tues': '2', 'wednesday': '3', 'wed': '3',
  'weds': '3', 'thursday': '4', 'thu': '4', 'thur': '4', 'thurs': '4',
  'friday': '5', 'fri': '5', 'saturday': '6', 'sat': '6',
};
const _dayspecToCron = {
  'day': '*', 'daily': '*', 'everyday': '*', 'weekday': '1-5', //
  'weekdays': '1-5', 'weekend': '0,6', 'weekends': '0,6',
};

/// Port of `_natural_every_to_cron`: "every monday 9am", "weekdays at 9am",
/// "every day at 18:30" → cron, or null.
String? hermesNaturalToCron(String raw) {
  var text = raw.trim().toLowerCase();
  if (text.startsWith('every ')) text = text.substring(6).trim();
  final tokens = text.replaceAll(',', ' ').split(RegExp(r'\s+'));
  if (tokens.isEmpty || tokens.first.isEmpty) return null;
  var dow = _dayspecToCron[tokens.first];
  var idx = 1;
  if (dow == null) {
    final days = <String>[];
    idx = tokens.length;
    for (var i = 0; i < tokens.length; i++) {
      if (tokens[i] == 'and') continue;
      final mapped = _weekdayToCron[tokens[i]];
      if (mapped == null) {
        idx = i;
        break;
      }
      if (!days.contains(mapped)) days.add(mapped);
    }
    if (days.isEmpty) return null;
    dow = days.join(',');
  }
  var timeTokens = tokens.sublist(idx);
  if (timeTokens.isNotEmpty && timeTokens.first == 'at') {
    timeTokens = timeTokens.sublist(1);
  }
  if (timeTokens.isEmpty) return null;
  final t = timeTokens.join();
  int hour;
  int minute;
  if (t == 'noon' || t == 'midday') {
    hour = 12;
    minute = 0;
  } else if (t == 'midnight') {
    hour = 0;
    minute = 0;
  } else {
    final m = RegExp(r'^(\d{1,2})(?::(\d{2}))?(am|pm)?$').firstMatch(t);
    if (m == null) return null;
    hour = int.parse(m.group(1)!);
    minute = int.parse(m.group(2) ?? '0');
    final meridiem = m.group(3);
    if (meridiem != null) {
      if (hour < 1 || hour > 12) return null;
      hour = hour % 12 + (meridiem == 'pm' ? 12 : 0);
    }
    if (hour > 23 || minute > 59) return null;
  }
  return '$minute $hour * * $dow';
}

/// One-shot timestamp (`2026-02-03T14:00:00`), or null.
DateTime? hermesOnceAt(String raw) {
  final text = raw.trim();
  if (!text.contains('T') && !RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(text)) {
    return null;
  }
  return DateTime.tryParse(text)?.toLocal();
}

/// Cron expression equivalent of [raw] when it is cron or a natural phrase.
CronFields? hermesCronFields(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  if (hermesIntervalMinutes(text) != null) return null;
  final natural = hermesNaturalToCron(text);
  return CronFields.parse(natural ?? text);
}

/// Next run of any schedule string computable on the client (cron and
/// natural phrases; once → its time if in the future). Intervals depend on
/// the last run, so they return null.
DateTime? hermesScheduleNextRun(String raw, DateTime from) {
  final once = hermesOnceAt(raw);
  if (once != null) return once.isAfter(from) ? once : null;
  return hermesCronFields(raw)?.nextRun(from);
}

/// Human description of any Hermes schedule string, in the locale of [s].
/// Never returns cron or interval syntax.
String describeHermesSchedule(Strings s, String raw, {DateTime? now}) {
  final l = _ScheduleLang.of(s);
  final text = raw.trim();
  if (text.isEmpty) return l.custom;
  final interval = hermesIntervalMinutes(text);
  if (interval != null) return l.everyDuration(interval);
  final lower = text.toLowerCase();
  if (lower.startsWith('in ')) {
    final minutes = hermesIntervalMinutes(lower.substring(3));
    if (minutes != null) return l.onceIn(minutes);
  }
  final once = hermesOnceAt(text);
  if (once != null) return l.once(once, now ?? DateTime.now());
  final fields = hermesCronFields(text);
  if (fields == null) return l.custom;
  return _humanizeCron(l, fields) ?? l.custom;
}

/// Whether [raw] has a natural description (i.e. it is not "custom").
bool hermesScheduleIsDescribable(Strings s, String raw) =>
    describeHermesSchedule(s, raw) != _ScheduleLang.of(s).custom;

// ── cron → words ────────────────────────────────────────────────────────────

/// (start, step) when [values] is exactly {start, start+step, …} filling the
/// cycle [period] evenly (step divides period, start < step).
(int, int)? _cycleStep(List<int> values, int period) {
  if (values.length < 2) return null;
  final step = values[1] - values[0];
  if (step <= 0 || period % step != 0 || values.first >= step) return null;
  for (var i = 1; i < values.length; i++) {
    if (values[i] - values[i - 1] != step) return null;
  }
  if (values.last + step < period) return null;
  return (values.first, step);
}

/// Arithmetic progression (any length ≥ 2) → step, or null.
int? _progression(List<int> values) {
  if (values.length < 2) return null;
  final step = values[1] - values[0];
  for (var i = 1; i < values.length; i++) {
    if (values[i] - values[i - 1] != step) return null;
  }
  return step;
}

/// Contiguous runs, e.g. [7,8,9,14,15] → [(7,9),(14,15)].
List<(int, int)> _runs(List<int> values) {
  final out = <(int, int)>[];
  var i = 0;
  while (i < values.length) {
    var j = i;
    while (j + 1 < values.length && values[j + 1] == values[j] + 1) {
      j++;
    }
    out.add((values[i], values[j]));
    i = j + 1;
  }
  return out;
}

String? _humanizeCron(_ScheduleLang l, CronFields f) {
  final days = _dayClause(l, f);
  if (days == null) return null;
  final m = f.minutes;
  final h = f.hours;
  final allHours = h.length == 24;

  // Point-in-time schedules: a handful of clock times.
  if (m.length * h.length <= 6 &&
      !(m.length == 1 && allHours) &&
      (h.length == 1 || _cycleStep(m, 60) == null)) {
    final hourStep = m.length == 1 ? _progression(h) : null;
    // A long regular run of hours reads better as a window below.
    if (!(hourStep != null && h.length >= 3)) {
      final times = [
        for (final hour in h)
          for (final minute in m) (hour, minute),
      ];
      return l.atTimes(days, times);
    }
  }

  // Every minute / every N minutes, optionally inside hour windows.
  final minuteCycle = m.length == 60 ? (0, 1) : _cycleStep(m, 60);
  if (minuteCycle != null) {
    final freq = l.everyDuration(minuteCycle.$2);
    if (allHours) return l.freq(freq, null, days);
    // Exact first and last run: "from 14:00 to 17:55".
    final windows = [
      for (final r in _runs(h)) l.fromTo((r.$1, m.first), (r.$2, m.last)),
    ];
    return l.freq(freq, l.joinAnd(windows), days);
  }

  if (m.length == 1) {
    final minute = m.single;
    if (allHours) {
      return l.freq(l.everyHourAt(minute), null, days);
    }
    final hourCycle = _cycleStep(h, 24);
    if (hourCycle != null) {
      final (start, step) = hourCycle;
      final from = start == 0 && minute == 0
          ? null
          : l.startingAt(start, minute);
      return l.freq(l.everyDuration(step * 60), from, days);
    }
    final step = _progression(h);
    if (step != null && h.length >= 3) {
      return l.freq(
        l.everyDuration(step * 60),
        l.fromTo((h.first, minute), (h.last, minute)),
        days,
      );
    }
    final runs = _runs(h);
    if (runs.every((r) => r.$2 > r.$1)) {
      final windows = [
        for (final r in runs) l.fromTo((r.$1, minute), (r.$2, minute)),
      ];
      return l.freq(l.everyDuration(60), l.joinAnd(windows), days);
    }
    return null;
  }

  // Several fixed minutes every hour ("0,45 * * * *").
  if (allHours && m.length <= 4) {
    return l.freq(l.everyHourAtMinutes(m), null, days);
  }
  return null;
}

/// Day/month part of a schedule in two grammatical forms.
class _Days {
  /// Sentence start, e.g. "Laborables" / "Weekdays"; null when every day.
  final String? prefix;

  /// Trailing qualifier, e.g. "de lunes a viernes" / "on weekdays".
  final String? suffix;

  const _Days(this.prefix, this.suffix);
}

_Days? _dayClause(_ScheduleLang l, CronFields f) {
  final domRestricted = f.lastDom || !f.domStar;
  if (domRestricted && !f.dowStar) return null; // croniter OR: too odd.
  final months = f.monthStar ? null : f.months;
  if (!domRestricted && f.dowStar) {
    if (months == null) return const _Days(null, null);
    return l.monthsOnly(months);
  }
  if (!f.dowStar) return l.weekdays(f.dows, months);
  return l.monthDays(f.lastDom ? null : f.doms, months);
}

// ── language tables ────────────────────────────────────────────────────────

abstract class _ScheduleLang {
  static _ScheduleLang of(Strings s) =>
      s.localeName.startsWith('en') ? const _En() : const _Es();

  const _ScheduleLang();

  String get custom;
  String everyDuration(int minutes);
  String everyHourAt(int minute);
  String everyHourAtMinutes(List<int> minutes);
  String onceIn(int minutes);
  String once(DateTime when, DateTime now);
  String atTimes(_Days days, List<(int, int)> times);
  String freq(String freq, String? window, _Days days);
  String fromTo((int, int) a, (int, int) b);
  String startingAt(int hour, int minute);
  String joinAnd(List<String> items);
  _Days monthsOnly(List<int> months);
  _Days weekdays(List<int> cronDows, List<int>? months);
  _Days monthDays(List<int>? doms, List<int>? months);

  static String time(int hour, int minute) =>
      '$hour:${minute.toString().padLeft(2, '0')}';

  /// Mon-first order of cron weekdays (Sunday last).
  static List<int> mondayFirst(List<int> dows) =>
      [...dows]..sort((a, b) => (a == 0 ? 7 : a).compareTo(b == 0 ? 7 : b));

  static bool contiguousWeek(List<int> ordered) {
    final iso = ordered.map((d) => d == 0 ? 7 : d).toList();
    for (var i = 1; i < iso.length; i++) {
      if (iso[i] != iso[i - 1] + 1) return false;
    }
    return true;
  }
}

class _Es extends _ScheduleLang {
  const _Es();

  static const _days = [
    'domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', //
  ];
  static const _daysPlural = [
    'domingos',
    'lunes',
    'martes',
    'miércoles',
    'jueves',
    'viernes',
    'sábados',
  ];
  static const _months = [
    '', 'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', //
    'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
  ];

  @override
  String get custom => 'Horario personalizado';

  @override
  String everyDuration(int minutes) {
    if (minutes == 1) return 'Cada minuto';
    if (minutes < 60) return 'Cada $minutes min';
    if (minutes == 60) return 'Cada hora';
    if (minutes % 1440 == 0) {
      final d = minutes ~/ 1440;
      return d == 1 ? 'Cada día' : 'Cada $d días';
    }
    if (minutes % 60 == 0) return 'Cada ${minutes ~/ 60} horas';
    return 'Cada ${minutes ~/ 60} h ${minutes % 60} min';
  }

  @override
  String everyHourAt(int minute) =>
      minute == 0 ? 'Cada hora' : 'Cada hora, en el minuto $minute';

  @override
  String everyHourAtMinutes(List<int> minutes) =>
      'Cada hora, en los minutos ${joinAnd([for (final m in minutes) '$m'])}';

  @override
  String onceIn(int minutes) =>
      'Una vez, dentro de ${everyDuration(minutes).substring(5)}';

  @override
  String once(DateTime when, DateTime now) {
    final year = when.year == now.year ? '' : ' de ${when.year}';
    return 'Una vez, el ${when.day} de ${_months[when.month]}$year '
        '${_at([(when.hour, when.minute)])}';
  }

  String _at(List<(int, int)> times) {
    final labels = [for (final t in times) _ScheduleLang.time(t.$1, t.$2)];
    final article = times.length == 1 && times.single.$1 == 1
        ? 'a la'
        : 'a las';
    return '$article ${joinAnd(labels)}';
  }

  @override
  String atTimes(_Days days, List<(int, int)> times) =>
      '${days.prefix ?? 'Cada día'} ${_at(times)}';

  @override
  String freq(String freq, String? window, _Days days) =>
      [freq, ?window, ?days.suffix].join(', ');

  @override
  String fromTo((int, int) a, (int, int) b) =>
      'de ${_ScheduleLang.time(a.$1, a.$2)} a ${_ScheduleLang.time(b.$1, b.$2)}';

  @override
  String startingAt(int hour, int minute) =>
      'desde ${hour == 1 ? 'la' : 'las'} ${_ScheduleLang.time(hour, minute)}';

  @override
  String joinAnd(List<String> items) {
    if (items.length <= 1) return items.join();
    return '${items.sublist(0, items.length - 1).join(', ')} y ${items.last}';
  }

  String _monthList(List<int> months) {
    final runs = _runs(months);
    if (runs.length == 1 && months.length >= 3) {
      return 'de ${_months[runs.single.$1]} a ${_months[runs.single.$2]}';
    }
    return 'en ${joinAnd([for (final m in months) _months[m]])}';
  }

  @override
  _Days monthsOnly(List<int> months) {
    final list = _monthList(months);
    return _Days('Cada día, $list,', list);
  }

  @override
  _Days weekdays(List<int> cronDows, List<int>? months) {
    final monthSuffix = months == null ? '' : ', ${_monthList(months)}';
    final ordered = _ScheduleLang.mondayFirst(cronDows);
    String prefix;
    String suffix;
    if (ordered.length == 5 && ordered.first == 1 && ordered.last == 5) {
      prefix = 'Laborables';
      suffix = 'laborables';
    } else if (ordered.length == 2 && ordered.first == 6 && ordered.last == 0) {
      prefix = 'Fines de semana';
      suffix = 'los fines de semana';
    } else if (ordered.length == 1) {
      prefix = 'Los ${_daysPlural[ordered.single]}';
      suffix = 'los ${_daysPlural[ordered.single]}';
    } else if (ordered.length >= 3 && _ScheduleLang.contiguousWeek(ordered)) {
      prefix = 'De ${_days[ordered.first]} a ${_days[ordered.last]}';
      suffix = 'de ${_days[ordered.first]} a ${_days[ordered.last]}';
    } else {
      final names = joinAnd([for (final d in ordered) _daysPlural[d]]);
      prefix = 'Los $names';
      suffix = 'los $names';
    }
    return _Days(
      monthSuffix.isEmpty ? prefix : '$prefix$monthSuffix,',
      '$suffix$monthSuffix',
    );
  }

  @override
  _Days monthDays(List<int>? doms, List<int>? months) {
    if (doms != null &&
        doms.length == 1 &&
        months != null &&
        months.length == 1) {
      final date = 'el ${doms.single} de ${_months[months.single]}';
      return _Days('El ${doms.single} de ${_months[months.single]}', date);
    }
    String phrase;
    if (doms == null) {
      phrase = 'el último día de cada mes';
    } else if (doms.length == 1) {
      phrase = 'el día ${doms.single} de cada mes';
    } else {
      final runs = _runs(doms);
      phrase = runs.length == 1 && doms.length >= 3
          ? 'del día ${doms.first} al ${doms.last} de cada mes'
          : 'los días ${joinAnd([for (final d in doms) '$d'])} de cada mes';
    }
    final monthSuffix = months == null ? '' : ', ${_monthList(months)}';
    final prefix = '${phrase[0].toUpperCase()}${phrase.substring(1)}';
    return _Days(
      monthSuffix.isEmpty ? prefix : '$prefix$monthSuffix,',
      '$phrase$monthSuffix',
    );
  }
}

class _En extends _ScheduleLang {
  const _En();

  static const _days = [
    'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', //
    'Saturday',
  ];
  static const _months = [
    '', 'January', 'February', 'March', 'April', 'May', 'June', 'July', //
    'August', 'September', 'October', 'November', 'December',
  ];

  @override
  String get custom => 'Custom schedule';

  @override
  String everyDuration(int minutes) {
    if (minutes == 1) return 'Every minute';
    if (minutes < 60) return 'Every $minutes min';
    if (minutes == 60) return 'Every hour';
    if (minutes % 1440 == 0) {
      final d = minutes ~/ 1440;
      return d == 1 ? 'Every day' : 'Every $d days';
    }
    if (minutes % 60 == 0) return 'Every ${minutes ~/ 60} hours';
    return 'Every ${minutes ~/ 60} h ${minutes % 60} min';
  }

  String _minuteMark(int minute) => ':${minute.toString().padLeft(2, '0')}';

  @override
  String everyHourAt(int minute) =>
      minute == 0 ? 'Every hour' : 'Every hour at ${_minuteMark(minute)}';

  @override
  String everyHourAtMinutes(List<int> minutes) =>
      'Every hour at ${joinAnd([for (final m in minutes) _minuteMark(m)])}';

  @override
  String onceIn(int minutes) =>
      'Once, in ${everyDuration(minutes).substring(6)}';

  @override
  String once(DateTime when, DateTime now) {
    final year = when.year == now.year ? '' : ', ${when.year}';
    return 'Once on ${_months[when.month]} ${when.day}$year '
        'at ${_ScheduleLang.time(when.hour, when.minute)}';
  }

  @override
  String atTimes(_Days days, List<(int, int)> times) {
    final labels = [for (final t in times) _ScheduleLang.time(t.$1, t.$2)];
    return '${days.prefix ?? 'Every day'} at ${joinAnd(labels)}';
  }

  @override
  String freq(String freq, String? window, _Days days) =>
      [freq, ?window, ?days.suffix].join(' ');

  @override
  String fromTo((int, int) a, (int, int) b) =>
      'from ${_ScheduleLang.time(a.$1, a.$2)} to ${_ScheduleLang.time(b.$1, b.$2)}';

  @override
  String startingAt(int hour, int minute) =>
      'starting at ${_ScheduleLang.time(hour, minute)}';

  @override
  String joinAnd(List<String> items) {
    if (items.length <= 1) return items.join();
    return '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';
  }

  String _monthList(List<int> months, {String lead = 'in'}) {
    final runs = _runs(months);
    if (runs.length == 1 && months.length >= 3) {
      return 'from ${_months[runs.single.$1]} to ${_months[runs.single.$2]}';
    }
    return '$lead ${joinAnd([for (final m in months) _months[m]])}';
  }

  @override
  _Days monthsOnly(List<int> months) {
    final list = _monthList(months);
    return _Days('Every day $list', list);
  }

  @override
  _Days weekdays(List<int> cronDows, List<int>? months) {
    final monthSuffix = months == null ? '' : ' ${_monthList(months)}';
    final ordered = _ScheduleLang.mondayFirst(cronDows);
    String prefix;
    String suffix;
    if (ordered.length == 5 && ordered.first == 1 && ordered.last == 5) {
      prefix = 'Weekdays';
      suffix = 'on weekdays';
    } else if (ordered.length == 2 && ordered.first == 6 && ordered.last == 0) {
      prefix = 'Weekends';
      suffix = 'on weekends';
    } else if (ordered.length == 1) {
      prefix = 'Every ${_days[ordered.single]}';
      suffix = 'on ${_days[ordered.single]}s';
    } else if (ordered.length >= 3 && _ScheduleLang.contiguousWeek(ordered)) {
      prefix = '${_days[ordered.first]} to ${_days[ordered.last]}';
      suffix = '${_days[ordered.first]} to ${_days[ordered.last]}';
    } else {
      final names = joinAnd([for (final d in ordered) _days[d]]);
      prefix = names;
      suffix = 'on $names';
    }
    return _Days('$prefix$monthSuffix', '$suffix$monthSuffix');
  }

  String _ordinalDay(int d) => '$d';

  @override
  _Days monthDays(List<int>? doms, List<int>? months) {
    if (doms != null &&
        doms.length == 1 &&
        months != null &&
        months.length == 1) {
      final date = 'on ${_months[months.single]} ${doms.single}';
      return _Days('On ${_months[months.single]} ${doms.single}', date);
    }
    String phrase;
    if (doms == null) {
      phrase = 'on the last day of every month';
    } else if (doms.length == 1) {
      phrase = 'on day ${_ordinalDay(doms.single)} of every month';
    } else {
      final runs = _runs(doms);
      phrase = runs.length == 1 && doms.length >= 3
          ? 'on days ${doms.first} to ${doms.last} of every month'
          : 'on days ${joinAnd([for (final d in doms) '$d'])} of every month';
    }
    final monthSuffix = months == null ? '' : ' ${_monthList(months)}';
    final prefix = '${phrase[0].toUpperCase()}${phrase.substring(1)}';
    return _Days('$prefix$monthSuffix', '$phrase$monthSuffix');
  }
}
