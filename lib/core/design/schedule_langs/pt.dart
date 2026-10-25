part of '../schedule_humanizer.dart';

class _Pt extends _ScheduleLang {
  const _Pt();

  static const _days = [
    'domingo', 'segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado', //
  ];
  static const _daysPlural = [
    'domingos', 'segundas', 'terças', 'quartas', 'quintas', 'sextas', //
    'sábados',
  ];
  static const _months = [
    '', 'janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', //
    'agosto', 'setembro', 'outubro', 'novembro', 'dezembro',
  ];

  /// Segunda a sexta são femininas; sábado e domingo, masculinos.
  static bool _femDay(int cronDow) => cronDow >= 1 && cronDow <= 5;

  @override
  String get custom => 'Horário personalizado';

  @override
  String everyDuration(int minutes) {
    if (minutes == 1) return 'A cada minuto';
    if (minutes < 60) return 'A cada $minutes min';
    if (minutes == 60) return 'A cada hora';
    if (minutes % 1440 == 0) {
      final d = minutes ~/ 1440;
      return d == 1 ? 'Todos os dias' : 'A cada $d dias';
    }
    if (minutes % 60 == 0) return 'A cada ${minutes ~/ 60} horas';
    return 'A cada ${minutes ~/ 60} h ${minutes % 60} min';
  }

  @override
  String everyHourAt(int minute) =>
      minute == 0 ? 'A cada hora' : 'A cada hora, no minuto $minute';

  @override
  String everyHourAtMinutes(List<int> minutes) =>
      'A cada hora, nos minutos ${joinAnd([for (final m in minutes) '$m'])}';

  @override
  String onceIn(int minutes) {
    // Casos exactos: el recorte genérico de everyDuration no sirve para
    // 'Todos os dias' ('…s días') ni para unidades sin numeral
    // ('daqui a minuto'). El resto sigue 'A cada X …' → 'X …'.
    if (minutes == 1) return 'Uma vez, daqui a 1 min';
    if (minutes == 60) return 'Uma vez, daqui a 1 hora';
    if (minutes == 1440) return 'Uma vez, daqui a 1 dia';
    return 'Uma vez, daqui a ${everyDuration(minutes).substring(7)}';
  }

  @override
  String once(DateTime when, DateTime now) {
    final year = when.year == now.year ? '' : ' de ${when.year}';
    return 'Uma vez, em ${when.day} de ${_months[when.month]}$year '
        '${_at([(when.hour, when.minute)])}';
  }

  String _at(List<(int, int)> times) {
    final labels = [for (final t in times) _ScheduleLang.time(t.$1, t.$2)];
    return 'às ${joinAnd(labels)}';
  }

  @override
  String atTimes(_Days days, List<(int, int)> times) =>
      '${days.prefix ?? 'Todos os dias'} ${_at(times)}';

  @override
  String freq(String freq, String? window, _Days days) =>
      [freq, ?window, ?days.suffix].join(', ');

  @override
  String fromTo((int, int) a, (int, int) b) =>
      'das ${_ScheduleLang.time(a.$1, a.$2)} às ${_ScheduleLang.time(b.$1, b.$2)}';

  @override
  String startingAt(int hour, int minute) =>
      'a partir das ${_ScheduleLang.time(hour, minute)}';

  @override
  String joinAnd(List<String> items) {
    if (items.length <= 1) return items.join();
    return '${items.sublist(0, items.length - 1).join(', ')} e ${items.last}';
  }

  String _monthList(List<int> months) {
    final runs = _runs(months);
    if (runs.length == 1 && months.length >= 3) {
      return 'de ${_months[runs.single.$1]} a ${_months[runs.single.$2]}';
    }
    return 'em ${joinAnd([for (final m in months) _months[m]])}';
  }

  @override
  _Days monthsOnly(List<int> months) {
    final list = _monthList(months);
    return _Days('Todos os dias, $list,', list);
  }

  @override
  _Days weekdays(List<int> cronDows, List<int>? months) {
    final monthSuffix = months == null ? '' : ', ${_monthList(months)}';
    final ordered = _ScheduleLang.mondayFirst(cronDows);
    String prefix;
    String suffix;
    if (ordered.length == 5 && ordered.first == 1 && ordered.last == 5) {
      prefix = 'Dias úteis';
      suffix = 'em dias úteis';
    } else if (ordered.length == 2 && ordered.first == 6 && ordered.last == 0) {
      prefix = 'Fins de semana';
      suffix = 'nos fins de semana';
    } else if (ordered.length == 1) {
      final article = _femDay(ordered.single) ? 'Todas as' : 'Todos os';
      final articleLow = _femDay(ordered.single) ? 'nas' : 'nos';
      prefix = '$article ${_daysPlural[ordered.single]}';
      suffix = '$articleLow ${_daysPlural[ordered.single]}';
    } else if (ordered.length >= 3 && _ScheduleLang.contiguousWeek(ordered)) {
      prefix = 'De ${_days[ordered.first]} a ${_days[ordered.last]}';
      suffix = 'de ${_days[ordered.first]} a ${_days[ordered.last]}';
    } else {
      final names = joinAnd([for (final d in ordered) _daysPlural[d]]);
      prefix = '${names[0].toUpperCase()}${names.substring(1)}';
      suffix = 'em $names';
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
      final date = 'no dia ${doms.single} de ${_months[months.single]}';
      return _Days('Dia ${doms.single} de ${_months[months.single]}', date);
    }
    String phrase;
    if (doms == null) {
      phrase = 'no último dia de cada mês';
    } else if (doms.length == 1) {
      phrase = 'no dia ${doms.single} de cada mês';
    } else {
      final runs = _runs(doms);
      phrase = runs.length == 1 && doms.length >= 3
          ? 'do dia ${doms.first} ao ${doms.last} de cada mês'
          : 'nos dias ${joinAnd([for (final d in doms) '$d'])} de cada mês';
    }
    final monthSuffix = months == null ? '' : ', ${_monthList(months)}';
    final prefix = '${phrase[0].toUpperCase()}${phrase.substring(1)}';
    return _Days(
      monthSuffix.isEmpty ? prefix : '$prefix$monthSuffix,',
      '$phrase$monthSuffix',
    );
  }
}
