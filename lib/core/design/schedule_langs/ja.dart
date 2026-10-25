part of '../schedule_humanizer.dart';

class _Ja extends _ScheduleLang {
  const _Ja();

  static const _days = ['日曜日', '月曜日', '火曜日', '水曜日', '木曜日', '金曜日', '土曜日'];

  @override
  String get custom => 'カスタムスケジュール';

  String _duration(int minutes) {
    if (minutes < 60) return '$minutes分';
    if (minutes % 1440 == 0) return '${minutes ~/ 1440}日';
    if (minutes % 60 == 0) return '${minutes ~/ 60}時間';
    return '${minutes ~/ 60}時間${minutes % 60}分';
  }

  @override
  String everyDuration(int minutes) => '${_duration(minutes)}ごと';

  @override
  String everyHourAt(int minute) => minute == 0 ? '1時間ごと' : '毎時$minute分';

  @override
  String everyHourAtMinutes(List<int> minutes) =>
      '毎時${joinAnd([for (final m in minutes) '$m分'])}';

  @override
  String onceIn(int minutes) => '${_duration(minutes)}後に1回';

  @override
  String once(DateTime when, DateTime now) {
    final year = when.year == now.year ? '' : '${when.year}年';
    return '$year${when.month}月${when.day}日の'
        '${_ScheduleLang.time(when.hour, when.minute)}に1回';
  }

  @override
  String atTimes(_Days days, List<(int, int)> times) {
    final labels = [for (final t in times) _ScheduleLang.time(t.$1, t.$2)];
    return '${days.prefix ?? '毎日'}の${joinAnd(labels)}';
  }

  @override
  String freq(String freq, String? window, _Days days) =>
      '${days.suffix == null ? '' : '${days.suffix}、'}'
      '${window == null ? '' : '$window、'}$freq';

  @override
  String fromTo((int, int) a, (int, int) b) =>
      '${_ScheduleLang.time(a.$1, a.$2)}から${_ScheduleLang.time(b.$1, b.$2)}まで';

  @override
  String startingAt(int hour, int minute) =>
      '${_ScheduleLang.time(hour, minute)}から';

  @override
  String joinAnd(List<String> items) => items.join('・');

  String _monthList(List<int> months) {
    final runs = _runs(months);
    if (runs.length == 1 && months.length >= 3) {
      return '${months.first}月から${months.last}月';
    }
    return joinAnd([for (final m in months) '$m月']);
  }

  @override
  _Days monthsOnly(List<int> months) {
    final list = _monthList(months);
    return _Days('$listの毎日', '$listの毎日');
  }

  @override
  _Days weekdays(List<int> cronDows, List<int>? months) {
    final ordered = _ScheduleLang.mondayFirst(cronDows);
    String phrase;
    if (ordered.length == 5 && ordered.first == 1 && ordered.last == 5) {
      // Cron weekdays include public holidays; avoid the ambiguous Japanese 平日.
      phrase = '毎週月曜日から金曜日';
    } else if (ordered.length == 2 && ordered.first == 6 && ordered.last == 0) {
      phrase = '毎週土曜日・日曜日';
    } else if (ordered.length >= 3 && _ScheduleLang.contiguousWeek(ordered)) {
      phrase = '毎週${_days[ordered.first]}から${_days[ordered.last]}';
    } else {
      phrase = '毎週${joinAnd([for (final d in ordered) _days[d]])}';
    }
    final full = months == null ? phrase : '${_monthList(months)}の$phrase';
    return _Days(full, full);
  }

  @override
  _Days monthDays(List<int>? doms, List<int>? months) {
    final month = months == null ? '毎月' : _monthList(months);
    String day;
    if (doms == null) {
      day = '末日';
    } else if (doms.length == 1) {
      day = '${doms.single}日';
    } else if (_runs(doms).length == 1 && doms.length >= 3) {
      day = '${doms.first}日から${doms.last}日';
    } else {
      day = joinAnd([for (final d in doms) '$d日']);
    }
    final phrase = '$month${months == null || months.length == 1 ? '' : 'の'}$day';
    return _Days(phrase, phrase);
  }
}
