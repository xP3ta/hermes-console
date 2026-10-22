part of '../schedule_humanizer.dart';

class _Fr extends _ScheduleLang {
  const _Fr();

  static const _days = [
    'dimanche', 'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi',
  ];
  static const _months = [
    '', 'janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet',
    'août', 'septembre', 'octobre', 'novembre', 'décembre',
  ];

  @override
  String get custom => 'Horaire personnalisé';

  @override
  String everyDuration(int minutes) {
    if (minutes == 1) return 'Toutes les minutes';
    if (minutes < 60) return 'Toutes les $minutes min';
    if (minutes == 60) return 'Toutes les heures';
    if (minutes % 1440 == 0) {
      final days = minutes ~/ 1440;
      return days == 1 ? 'Tous les jours' : 'Tous les $days jours';
    }
    if (minutes % 60 == 0) return 'Toutes les ${minutes ~/ 60} heures';
    return 'Toutes les ${minutes ~/ 60} h ${minutes % 60} min';
  }

  @override
  String everyHourAt(int minute) => minute == 0
      ? 'Toutes les heures'
      : 'Toutes les heures, à la minute $minute';

  @override
  String everyHourAtMinutes(List<int> minutes) =>
      'Toutes les heures, aux minutes ${joinAnd([for (final m in minutes) '$m'])}';

  @override
  String onceIn(int minutes) {
    String delay;
    if (minutes < 60) {
      delay = '$minutes min';
    } else if (minutes % 1440 == 0) {
      final days = minutes ~/ 1440;
      delay = days == 1 ? '1 jour' : '$days jours';
    } else if (minutes % 60 == 0) {
      final hours = minutes ~/ 60;
      delay = hours == 1 ? '1 heure' : '$hours heures';
    } else {
      delay = '${minutes ~/ 60} h ${minutes % 60} min';
    }
    return 'Une fois, dans $delay';
  }

  String _day(int day) => day == 1 ? '1er' : '$day';

  @override
  String once(DateTime when, DateTime now) {
    final year = when.year == now.year ? '' : ' ${when.year}';
    return 'Une fois, le ${_day(when.day)} ${_months[when.month]}$year '
        'à ${_ScheduleLang.time(when.hour, when.minute)}';
  }

  @override
  String atTimes(_Days days, List<(int, int)> times) {
    final labels = [for (final t in times) _ScheduleLang.time(t.$1, t.$2)];
    return '${days.prefix ?? 'Tous les jours'} à ${joinAnd(labels)}';
  }

  @override
  String freq(String freq, String? window, _Days days) =>
      [freq, ?window, ?days.suffix].join(', ');

  @override
  String fromTo((int, int) a, (int, int) b) =>
      'de ${_ScheduleLang.time(a.$1, a.$2)} à ${_ScheduleLang.time(b.$1, b.$2)}';

  @override
  String startingAt(int hour, int minute) =>
      'à partir de ${_ScheduleLang.time(hour, minute)}';

  @override
  String joinAnd(List<String> items) {
    if (items.length <= 1) return items.join();
    return '${items.sublist(0, items.length - 1).join(', ')} et ${items.last}';
  }

  String _monthList(List<int> months) {
    final runs = _runs(months);
    if (runs.length == 1 && months.length >= 3) {
      final first = runs.single.$1;
      final from = {4, 8, 10}.contains(first) ? 'd’' : 'de ';
      return '$from${_months[first]} à ${_months[runs.single.$2]}';
    }
    return 'en ${joinAnd([for (final m in months) _months[m]])}';
  }

  @override
  _Days monthsOnly(List<int> months) {
    final list = _monthList(months);
    return _Days('Tous les jours $list', list);
  }

  @override
  _Days weekdays(List<int> cronDows, List<int>? months) {
    final monthSuffix = months == null ? '' : ' ${_monthList(months)}';
    final ordered = _ScheduleLang.mondayFirst(cronDows);
    String phrase;
    if (ordered.length == 5 && ordered.first == 1 && ordered.last == 5) {
      phrase = 'du lundi au vendredi';
    } else if (ordered.length == 2 && ordered.first == 6 && ordered.last == 0) {
      phrase = 'le week-end';
    } else if (ordered.length == 1) {
      phrase = 'tous les ${_days[ordered.single]}s';
    } else if (ordered.length >= 3 && _ScheduleLang.contiguousWeek(ordered)) {
      phrase = 'du ${_days[ordered.first]} au ${_days[ordered.last]}';
    } else {
      phrase = 'les ${joinAnd([for (final d in ordered) '${_days[d]}s'])}';
    }
    final full = '$phrase$monthSuffix';
    return _Days('${full[0].toUpperCase()}${full.substring(1)}', full);
  }

  @override
  _Days monthDays(List<int>? doms, List<int>? months) {
    if (doms != null &&
        doms.length == 1 &&
        months != null &&
        months.length == 1) {
      final date = 'le ${_day(doms.single)} ${_months[months.single]}';
      return _Days('Le ${_day(doms.single)} ${_months[months.single]}', date);
    }
    final period = months == null
        ? 'de chaque mois'
        : 'de chaque mois, ${_monthList(months)}';
    String phrase;
    if (doms == null) {
      phrase = 'le dernier jour $period';
    } else if (doms.length == 1) {
      phrase = 'le ${_day(doms.single)} $period';
    } else {
      final runs = _runs(doms);
      phrase = runs.length == 1 && doms.length >= 3
          ? 'du ${_day(doms.first)} au ${doms.last} $period'
          : 'les ${joinAnd([for (final d in doms) _day(d)])} $period';
    }
    final prefix = '${phrase[0].toUpperCase()}${phrase.substring(1)}';
    return _Days(months == null ? prefix : '$prefix,', phrase);
  }
}
