part of '../schedule_humanizer.dart';

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
