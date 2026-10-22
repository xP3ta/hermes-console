part of '../schedule_humanizer.dart';

class _Ko extends _ScheduleLang {
  const _Ko();

  static const _days = [
    '일요일', '월요일', '화요일', '수요일', '목요일', '금요일', '토요일',
  ];

  @override
  String get custom => '사용자 지정 일정';

  String _duration(int minutes) {
    if (minutes < 60) return '${minutes}분';
    if (minutes % 1440 == 0) return '${minutes ~/ 1440}일';
    if (minutes % 60 == 0) return '${minutes ~/ 60}시간';
    return '${minutes ~/ 60}시간 ${minutes % 60}분';
  }

  @override
  String everyDuration(int minutes) {
    if (minutes == 1) return '매분';
    if (minutes == 60) return '매시간';
    if (minutes == 1440) return '매일';
    return '${_duration(minutes)}마다';
  }

  @override
  String everyHourAt(int minute) => minute == 0 ? '매시간' : '매시간 ${minute}분';

  @override
  String everyHourAtMinutes(List<int> minutes) =>
      '매시간 ${joinAnd([for (final m in minutes) '${m}분'])}';

  @override
  String onceIn(int minutes) => '${_duration(minutes)} 후 한 번';

  @override
  String once(DateTime when, DateTime now) {
    final year = when.year == now.year ? '' : '${when.year}년 ';
    return '$year${when.month}월 ${when.day}일 '
        '${_ScheduleLang.time(when.hour, when.minute)}에 한 번';
  }

  @override
  String atTimes(_Days days, List<(int, int)> times) {
    final labels = [for (final t in times) _ScheduleLang.time(t.$1, t.$2)];
    return '${days.prefix ?? '매일'} ${joinAnd(labels)}';
  }

  @override
  String freq(String freq, String? window, _Days days) =>
      [?days.suffix, ?window, freq].join(' ');

  @override
  String fromTo((int, int) a, (int, int) b) =>
      '${_ScheduleLang.time(a.$1, a.$2)}부터 '
      '${_ScheduleLang.time(b.$1, b.$2)}까지';

  @override
  String startingAt(int hour, int minute) =>
      '${_ScheduleLang.time(hour, minute)}부터';

  @override
  String joinAnd(List<String> items) {
    if (items.length <= 1) return items.join();
    return '${items.sublist(0, items.length - 1).join(', ')} 및 ${items.last}';
  }

  String _monthList(List<int> months) {
    final runs = _runs(months);
    if (runs.length == 1 && months.length >= 3) {
      return '${months.first}월부터 ${months.last}월까지';
    }
    return joinAnd([for (final m in months) '${m}월']);
  }

  @override
  _Days monthsOnly(List<int> months) {
    final list = _monthList(months);
    return _Days('$list 매일', list);
  }

  @override
  _Days weekdays(List<int> cronDows, List<int>? months) {
    final monthPrefix = months == null ? '' : '${_monthList(months)} ';
    final ordered = _ScheduleLang.mondayFirst(cronDows);
    String phrase;
    if (ordered.length == 5 && ordered.first == 1 && ordered.last == 5) {
      phrase = '평일';
    } else if (ordered.length == 2 && ordered.first == 6 && ordered.last == 0) {
      phrase = '주말';
    } else if (ordered.length == 1) {
      phrase = '매주 ${_days[ordered.single]}';
    } else if (ordered.length >= 3 && _ScheduleLang.contiguousWeek(ordered)) {
      phrase = '매주 ${_days[ordered.first]}부터 ${_days[ordered.last]}까지';
    } else {
      phrase = '매주 ${joinAnd([for (final d in ordered) _days[d]])}';
    }
    return _Days('$monthPrefix$phrase', '$monthPrefix$phrase');
  }

  @override
  _Days monthDays(List<int>? doms, List<int>? months) {
    final monthPrefix = months == null ? '매월' : _monthList(months);
    String day;
    if (doms == null) {
      day = '말일';
    } else if (doms.length == 1) {
      day = '${doms.single}일';
    } else {
      final runs = _runs(doms);
      day = runs.length == 1 && doms.length >= 3
          ? '${doms.first}일부터 ${doms.last}일까지'
          : joinAnd([for (final d in doms) '${d}일']);
    }
    final phrase = '$monthPrefix $day';
    return _Days(phrase, phrase);
  }
}
