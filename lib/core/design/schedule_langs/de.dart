part of '../schedule_humanizer.dart';

class _De extends _ScheduleLang {
  const _De();

  static const _days = [
    'sonntags', 'montags', 'dienstags', 'mittwochs', 'donnerstags', //
    'freitags', 'samstags',
  ];
  static const _months = [
    '', 'Januar', 'Februar', 'März', 'April', 'Mai', 'Juni', 'Juli', //
    'August', 'September', 'Oktober', 'November', 'Dezember',
  ];

  String _capitalized(String text) =>
      '${text[0].toUpperCase()}${text.substring(1)}';

  @override
  String get custom => 'Benutzerdefinierter Zeitplan';

  @override
  String everyDuration(int minutes) {
    if (minutes == 1) return 'Jede Minute';
    if (minutes < 60) return 'Alle $minutes Minuten';
    if (minutes == 60) return 'Jede Stunde';
    if (minutes % 1440 == 0) {
      final days = minutes ~/ 1440;
      return days == 1 ? 'Jeden Tag' : 'Alle $days Tage';
    }
    if (minutes % 60 == 0) return 'Alle ${minutes ~/ 60} Stunden';
    return 'Alle ${minutes ~/ 60} Std. ${minutes % 60} Min.';
  }

  @override
  String everyHourAt(int minute) =>
      minute == 0 ? 'Jede Stunde' : 'Jede Stunde zur Minute $minute';

  @override
  String everyHourAtMinutes(List<int> minutes) =>
      'Jede Stunde zu den Minuten ${joinAnd([for (final m in minutes) '$m'])}';

  @override
  String onceIn(int minutes) {
    String duration;
    if (minutes == 1) {
      duration = 'einer Minute';
    } else if (minutes < 60) {
      duration = '$minutes Minuten';
    } else if (minutes == 60) {
      duration = 'einer Stunde';
    } else if (minutes % 1440 == 0) {
      final days = minutes ~/ 1440;
      duration = days == 1 ? 'einem Tag' : '$days Tagen';
    } else if (minutes % 60 == 0) {
      duration = '${minutes ~/ 60} Stunden';
    } else {
      duration = '${minutes ~/ 60} Std. ${minutes % 60} Min.';
    }
    return 'Einmal in $duration';
  }

  @override
  String once(DateTime when, DateTime now) {
    final year = when.year == now.year ? '' : ' ${when.year}';
    return 'Einmal am ${when.day}. ${_months[when.month]}$year '
        'um ${_ScheduleLang.time(when.hour, when.minute)} Uhr';
  }

  @override
  String atTimes(_Days days, List<(int, int)> times) {
    final labels = [for (final t in times) _ScheduleLang.time(t.$1, t.$2)];
    return '${days.prefix ?? 'Jeden Tag'} um ${joinAnd(labels)} Uhr';
  }

  @override
  String freq(String freq, String? window, _Days days) =>
      [freq, ?window, ?days.suffix].join(' ');

  @override
  String fromTo((int, int) a, (int, int) b) =>
      'von ${_ScheduleLang.time(a.$1, a.$2)} bis ${_ScheduleLang.time(b.$1, b.$2)} Uhr';

  @override
  String startingAt(int hour, int minute) =>
      'ab ${_ScheduleLang.time(hour, minute)} Uhr';

  @override
  String joinAnd(List<String> items) {
    if (items.length <= 1) return items.join();
    return '${items.sublist(0, items.length - 1).join(', ')} und ${items.last}';
  }

  String _monthList(List<int> months) {
    final runs = _runs(months);
    if (runs.length == 1 && months.length >= 3) {
      return 'von ${_months[runs.single.$1]} bis ${_months[runs.single.$2]}';
    }
    return 'im ${joinAnd([for (final m in months) _months[m]])}';
  }

  @override
  _Days monthsOnly(List<int> months) {
    final list = _monthList(months);
    return _Days('Jeden Tag $list', list);
  }

  @override
  _Days weekdays(List<int> cronDows, List<int>? months) {
    final monthSuffix = months == null ? '' : ' ${_monthList(months)}';
    final ordered = _ScheduleLang.mondayFirst(cronDows);
    String phrase;
    if (ordered.length == 5 && ordered.first == 1 && ordered.last == 5) {
      // Avoid "werktags", which can include Saturday in German.
      phrase = 'montags bis freitags';
    } else if (ordered.length == 2 && ordered.first == 6 && ordered.last == 0) {
      phrase = 'am Wochenende';
    } else if (ordered.length == 1) {
      phrase = _days[ordered.single];
    } else if (ordered.length >= 3 && _ScheduleLang.contiguousWeek(ordered)) {
      phrase = '${_days[ordered.first]} bis ${_days[ordered.last]}';
    } else {
      phrase = joinAnd([for (final d in ordered) _days[d]]);
    }
    return _Days('${_capitalized(phrase)}$monthSuffix', '$phrase$monthSuffix');
  }

  @override
  _Days monthDays(List<int>? doms, List<int>? months) {
    if (doms != null &&
        doms.length == 1 &&
        months != null &&
        months.length == 1) {
      final date = 'am ${doms.single}. ${_months[months.single]}';
      return _Days(_capitalized(date), date);
    }
    // Restricted months replace "jedes Monats" rather than qualifying it.
    final period = months == null
        ? 'jedes Monats'
        : 'im ${joinAnd([for (final m in months) _months[m]])}';
    String phrase;
    if (doms == null) {
      phrase = 'am letzten Tag $period';
    } else if (doms.length == 1) {
      phrase = 'am ${doms.single}. $period';
    } else {
      final runs = _runs(doms);
      phrase = runs.length == 1 && doms.length >= 3
          ? 'vom ${doms.first}. bis zum ${doms.last}. $period'
          : 'am ${joinAnd([for (final d in doms) '$d.'])} $period';
    }
    return _Days(_capitalized(phrase), phrase);
  }
}
