part of '../schedule_humanizer.dart';

// English grammar stub for Phase 3b.
class _Ja extends _ScheduleLang {
  const _Ja();

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
