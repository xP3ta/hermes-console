part of '../schedule_humanizer.dart';

class _Zh extends _ScheduleLang {
  const _Zh();

  static const _days = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

  @override
  String get custom => '自定义计划';

  String _duration(int minutes) {
    if (minutes < 60) return '${minutes}分钟';
    if (minutes % 1440 == 0) return '${minutes ~/ 1440}天';
    if (minutes % 60 == 0) return '${minutes ~/ 60}小时';
    return '${minutes ~/ 60}小时${minutes % 60}分钟';
  }

  @override
  String everyDuration(int minutes) {
    if (minutes == 1) return '每分钟';
    if (minutes == 60) return '每小时';
    if (minutes == 1440) return '每天';
    return '每${_duration(minutes)}';
  }

  @override
  String everyHourAt(int minute) =>
      minute == 0 ? '每小时' : '每小时的${minute}分';

  @override
  String everyHourAtMinutes(List<int> minutes) =>
      '每小时的${joinAnd([for (final m in minutes) '${m.toString().padLeft(2, '0')}分'])}';

  @override
  String onceIn(int minutes) => '${_duration(minutes)}后执行一次';

  @override
  String once(DateTime when, DateTime now) {
    final year = when.year == now.year ? '' : '${when.year}年';
    return '$year${when.month}月${when.day}日'
        '${_ScheduleLang.time(when.hour, when.minute)}执行一次';
  }

  @override
  String atTimes(_Days days, List<(int, int)> times) =>
      '${days.prefix ?? '每天'}'
      '${joinAnd([for (final t in times) _ScheduleLang.time(t.$1, t.$2)])}';

  @override
  String freq(String freq, String? window, _Days days) =>
      '${days.suffix ?? ''}${window == null ? '' : '$window，'}$freq';

  @override
  String fromTo((int, int) a, (int, int) b) =>
      '${_ScheduleLang.time(a.$1, a.$2)}至${_ScheduleLang.time(b.$1, b.$2)}';

  @override
  String startingAt(int hour, int minute) =>
      '从${_ScheduleLang.time(hour, minute)}开始';

  @override
  String joinAnd(List<String> items) {
    if (items.length <= 1) return items.join();
    return '${items.sublist(0, items.length - 1).join('、')}和${items.last}';
  }

  String _monthList(List<int> months) {
    final runs = _runs(months);
    if (runs.length == 1 && months.length >= 3) {
      return '每年${runs.single.$1}月至${runs.single.$2}月';
    }
    return '每年${joinAnd([for (final m in months) '${m}月'])}';
  }

  @override
  _Days monthsOnly(List<int> months) {
    final phrase = '${_monthList(months)}每天';
    return _Days(phrase, phrase);
  }

  @override
  _Days weekdays(List<int> cronDows, List<int>? months) {
    final ordered = _ScheduleLang.mondayFirst(cronDows);
    String phrase;
    if (ordered.length == 5 && ordered.first == 1 && ordered.last == 5) {
      phrase = '每周一至周五';
    } else if (ordered.length == 2 && ordered.first == 6 && ordered.last == 0) {
      phrase = '周末';
    } else if (ordered.length == 1) {
      phrase = '每${_days[ordered.single]}';
    } else if (ordered.length >= 3 && _ScheduleLang.contiguousWeek(ordered)) {
      phrase = '每${_days[ordered.first]}至${_days[ordered.last]}';
    } else {
      phrase = '每${joinAnd([for (final d in ordered) _days[d]])}';
    }
    if (months != null) phrase = '${_monthList(months)}的$phrase';
    return _Days(phrase, phrase);
  }

  @override
  _Days monthDays(List<int>? doms, List<int>? months) {
    if (doms != null &&
        doms.length == 1 &&
        months != null &&
        months.length == 1) {
      final phrase = '每年${months.single}月${doms.single}日';
      return _Days(phrase, phrase);
    }
    String dates;
    if (doms == null) {
      dates = '最后一天';
    } else if (doms.length == 1) {
      dates = '${doms.single}日';
    } else {
      final runs = _runs(doms);
      dates = runs.length == 1 && doms.length >= 3
          ? '${doms.first}日至${doms.last}日'
          : joinAnd([for (final d in doms) '${d}日']);
    }
    final phrase = months == null
        ? '每月$dates'
        : '${_monthList(months)}的$dates';
    return _Days(phrase, phrase);
  }
}
