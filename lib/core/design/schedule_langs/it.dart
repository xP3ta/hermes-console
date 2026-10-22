part of '../schedule_humanizer.dart';

class _It extends _ScheduleLang {
  const _It();

  static const _days = [
    'domenica', 'lunedì', 'martedì', 'mercoledì', 'giovedì', 'venerdì',
    'sabato',
  ];
  static const _months = [
    '', 'gennaio', 'febbraio', 'marzo', 'aprile', 'maggio', 'giugno',
    'luglio', 'agosto', 'settembre', 'ottobre', 'novembre', 'dicembre',
  ];

  static String _day(int d) => '${d == 0 ? 'la' : 'il'} ${_days[d]}';
  static String _dateDay(int d) => d == 1 ? '1º' : '$d';
  static String _capital(String s) => '${s[0].toUpperCase()}${s.substring(1)}';
  static String _at(int hour, int minute) =>
      '${hour == 1 ? 'all’' : 'alle '}${_ScheduleLang.time(hour, minute)}';

  @override
  String get custom => 'Programmazione personalizzata';

  @override
  String everyDuration(int minutes) {
    if (minutes == 1) return 'Ogni minuto';
    if (minutes < 60) return 'Ogni $minutes min';
    if (minutes == 60) return 'Ogni ora';
    if (minutes % 1440 == 0) {
      final d = minutes ~/ 1440;
      return d == 1 ? 'Ogni giorno' : 'Ogni $d giorni';
    }
    if (minutes % 60 == 0) return 'Ogni ${minutes ~/ 60} ore';
    return 'Ogni ${minutes ~/ 60} h ${minutes % 60} min';
  }

  @override
  String everyHourAt(int minute) =>
      minute == 0 ? 'Ogni ora' : 'Ogni ora, al minuto $minute';

  @override
  String everyHourAtMinutes(List<int> minutes) =>
      'Ogni ora, ai minuti ${joinAnd([for (final m in minutes) '$m'])}';

  @override
  String onceIn(int minutes) {
    String duration;
    if (minutes < 60) {
      duration = minutes == 1 ? '1 minuto' : '$minutes minuti';
    } else if (minutes % 1440 == 0) {
      final days = minutes ~/ 1440;
      duration = days == 1 ? '1 giorno' : '$days giorni';
    } else if (minutes % 60 == 0) {
      final hours = minutes ~/ 60;
      duration = hours == 1 ? '1 ora' : '$hours ore';
    } else {
      duration = '${minutes ~/ 60} h ${minutes % 60} min';
    }
    return 'Una volta, tra $duration';
  }

  @override
  String once(DateTime when, DateTime now) {
    final year = when.year == now.year ? '' : ' ${when.year}';
    return 'Una volta, il ${_dateDay(when.day)} ${_months[when.month]}$year '
        '${_at(when.hour, when.minute)}';
  }

  @override
  String atTimes(_Days days, List<(int, int)> times) =>
      '${days.prefix ?? 'Ogni giorno'} '
      '${joinAnd([for (final t in times) _at(t.$1, t.$2)])}';

  @override
  String freq(String freq, String? window, _Days days) =>
      [freq, ?window, ?days.suffix].join(', ');

  @override
  String fromTo((int, int) a, (int, int) b) =>
      '${a.$1 == 1 ? 'dall’' : 'dalle '}${_ScheduleLang.time(a.$1, a.$2)} '
      '${_at(b.$1, b.$2)}';

  @override
  String startingAt(int hour, int minute) =>
      'a partire ${hour == 1 ? 'dall’' : 'dalle '}'
      '${_ScheduleLang.time(hour, minute)}';

  @override
  String joinAnd(List<String> items) {
    if (items.length <= 1) return items.join();
    return '${items.sublist(0, items.length - 1).join(', ')} e ${items.last}';
  }

  String _monthList(List<int> months) {
    final runs = _runs(months);
    if (runs.length == 1 && months.length >= 3) {
      final last = _months[runs.single.$2];
      return 'da ${_months[runs.single.$1]} ${last.startsWith('a') ? 'ad' : 'a'} $last';
    }
    return 'nei mesi di ${joinAnd([for (final m in months) _months[m]])}';
  }

  @override
  _Days monthsOnly(List<int> months) {
    final list = _monthList(months);
    return _Days('Ogni giorno $list', list);
  }

  @override
  _Days weekdays(List<int> cronDows, List<int>? months) {
    final monthSuffix = months == null ? '' : ' ${_monthList(months)}';
    final ordered = _ScheduleLang.mondayFirst(cronDows);
    String phrase;
    if (ordered.length >= 3 && _ScheduleLang.contiguousWeek(ordered)) {
      phrase = '${ordered.first == 0 ? 'dalla' : 'dal'} ${_days[ordered.first]} '
          '${ordered.last == 0 ? 'alla' : 'al'} ${_days[ordered.last]}';
    } else {
      phrase = joinAnd([for (final d in ordered) _day(d)]);
    }
    return _Days('${_capital(phrase)}$monthSuffix', '$phrase$monthSuffix');
  }

  @override
  _Days monthDays(List<int>? doms, List<int>? months) {
    if (doms != null &&
        doms.length == 1 &&
        months != null &&
        months.length == 1) {
      final date = 'il ${_dateDay(doms.single)} ${_months[months.single]}';
      return _Days(_capital(date), date);
    }
    String phrase;
    if (doms == null) {
      phrase = 'l’ultimo giorno';
    } else if (doms.length == 1) {
      phrase = 'il giorno ${doms.single}';
    } else {
      final runs = _runs(doms);
      phrase = runs.length == 1 && doms.length >= 3
          ? 'dal giorno ${doms.first} al ${doms.last}'
          : 'i giorni ${joinAnd([for (final d in doms) '$d'])}';
    }
    final String period;
    if (months == null) {
      period = 'di ogni mese';
    } else if (_runs(months).length == 1 && months.length >= 3) {
      period = 'di ogni mese ${_monthList(months)}';
    } else {
      period = 'dei mesi di ${joinAnd([for (final m in months) _months[m]])}';
    }
    return _Days('${_capital(phrase)} $period', '$phrase $period');
  }
}
