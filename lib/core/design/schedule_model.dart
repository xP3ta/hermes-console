import '../../l10n/app_localizations.dart';
import 'schedule_humanizer.dart';

/// Modes of the schedule builder (spec 080, mock screen 2).
enum HermesScheduleMode { daily, days, interval, month, custom }

/// Bidirectional model of a Hermes schedule for the shapes a person sets by
/// hand: a daily time, some weekdays at a time, a repeating interval
/// (optionally only inside an hour window and on some weekdays) and a day of
/// the month. Anything else round-trips untouched as [custom].
///
/// Weekdays use ISO numbering 1 = Monday … 7 = Sunday.
class HermesSchedule {
  final HermesScheduleMode mode;
  final int hour;
  final int minute;
  final Set<int> weekdays;

  /// Interval in minutes: 1–59 (`*/n` minutes) or whole hours.
  final int intervalMinutes;

  /// Interval window: first and LAST hour (inclusive) the interval runs in,
  /// or null for all day.
  final int? windowStart;
  final int? windowEnd;

  /// The interval came from (and goes back to) Hermes' native interval
  /// (`every 60m`), which counts from the last run instead of the clock.
  final bool native;

  final int dayOfMonth;

  /// Raw schedule for [HermesScheduleMode.custom].
  final String raw;

  static const allDays = {1, 2, 3, 4, 5, 6, 7};

  const HermesSchedule._({
    required this.mode,
    this.hour = 9,
    this.minute = 0,
    this.weekdays = const {1, 2, 3, 4, 5},
    this.intervalMinutes = 60,
    this.windowStart,
    this.windowEnd,
    this.native = false,
    this.dayOfMonth = 1,
    this.raw = '',
  });

  const HermesSchedule.daily({int hour = 9, int minute = 0})
    : this._(mode: HermesScheduleMode.daily, hour: hour, minute: minute);

  const HermesSchedule.days(Set<int> weekdays, {int hour = 9, int minute = 0})
    : this._(
        mode: HermesScheduleMode.days,
        hour: hour,
        minute: minute,
        weekdays: weekdays,
      );

  const HermesSchedule.interval(
    int minutes, {
    int minute = 0,
    int? windowStart,
    int? windowEnd,
    Set<int> weekdays = allDays,
    bool native = false,
  }) : this._(
         mode: HermesScheduleMode.interval,
         intervalMinutes: minutes,
         minute: minute,
         windowStart: windowStart,
         windowEnd: windowEnd,
         weekdays: weekdays,
         native: native,
       );

  const HermesSchedule.month(int day, {int hour = 9, int minute = 0})
    : this._(
        mode: HermesScheduleMode.month,
        dayOfMonth: day,
        hour: hour,
        minute: minute,
      );

  const HermesSchedule.custom(String raw)
    : this._(mode: HermesScheduleMode.custom, raw: raw);

  static const intervalPresets = <int>[5, 15, 30, 60, 120, 360, 720];

  bool get hasWindow => windowStart != null && windowEnd != null;

  /// Clock time of the LAST run inside a window that ends in hour [end]
  /// (inclusive): the value the builder shows next to "Until", so it always
  /// matches the summary ("from 14:00 to 17:55").
  (int, int) lastRunInWindow(int end) {
    final start = windowStart ?? 0;
    if (intervalMinutes < 60) {
      return (end, 60 - intervalMinutes);
    }
    final hours = intervalMinutes ~/ 60;
    final lastHour = end < start
        ? end
        : start + ((end - start) ~/ hours) * hours;
    return (lastHour, minute);
  }

  /// Whether a clock-aligned cron can express [intervalMinutes].
  static bool cronExpressible(int minutes) =>
      (minutes >= 1 && minutes < 60) ||
      (minutes >= 60 && minutes % 60 == 0 && minutes <= 23 * 60);

  /// Window and weekday limits need a cron; a native interval cannot hold
  /// them.
  bool get canLimit => cronExpressible(intervalMinutes);

  HermesSchedule copyWith({
    HermesScheduleMode? mode,
    int? hour,
    int? minute,
    Set<int>? weekdays,
    int? intervalMinutes,
    int? Function()? windowStart,
    int? Function()? windowEnd,
    bool? native,
    int? dayOfMonth,
    String? raw,
  }) => HermesSchedule._(
    mode: mode ?? this.mode,
    hour: hour ?? this.hour,
    minute: minute ?? this.minute,
    weekdays: weekdays ?? this.weekdays,
    intervalMinutes: intervalMinutes ?? this.intervalMinutes,
    windowStart: windowStart != null ? windowStart() : this.windowStart,
    windowEnd: windowEnd != null ? windowEnd() : this.windowEnd,
    native: native ?? this.native,
    dayOfMonth: dayOfMonth ?? this.dayOfMonth,
    raw: raw ?? this.raw,
  );

  /// Parses any Hermes schedule string. Never throws; unknown shapes become
  /// [custom].
  static HermesSchedule parse(String expression) {
    final normalized = expression.trim().replaceAll(RegExp(r'\s+'), ' ');
    final nativeMinutes = hermesIntervalMinutes(normalized);
    if (nativeMinutes != null) {
      return HermesSchedule.interval(nativeMinutes, native: true);
    }
    final natural = hermesNaturalToCron(normalized);
    final cron = natural ?? normalized;
    final parsed = _parseCron(cron, normalized);
    if (parsed.mode == HermesScheduleMode.custom) return parsed;
    // Safety net: the structured form must fire at exactly the same times.
    final a = CronFields.parse(cron);
    final b = CronFields.parse(parsed.toCron());
    if (a == null || b == null || !_sameFires(a, b)) {
      return HermesSchedule.custom(normalized);
    }
    return parsed;
  }

  static bool _sameFires(CronFields a, CronFields b) {
    bool eq(List<int> x, List<int> y) =>
        x.length == y.length && x.toSet().containsAll(y);
    return eq(a.minutes, b.minutes) &&
        eq(a.hours, b.hours) &&
        a.domStar == b.domStar &&
        eq(a.doms, b.doms) &&
        a.dowStar == b.dowStar &&
        (a.dowStar || eq(a.dows, b.dows)) &&
        a.monthStar == b.monthStar;
  }

  static HermesSchedule _parseCron(String cron, String normalized) {
    final parts = cron.split(' ');
    if (parts.length != 5 || cron.startsWith('@')) {
      return HermesSchedule.custom(normalized);
    }
    final f = CronFields.parse(cron);
    if (f == null || !f.monthStar || f.lastDom) {
      return HermesSchedule.custom(normalized);
    }
    final m = f.minutes;
    final h = f.hours;
    final weekdays = f.dowStar
        ? allDays
        : {for (final d in f.dows) d == 0 ? 7 : d};

    // Day of month: one day, one time.
    if (!f.domStar) {
      if (f.dowStar && f.doms.length == 1 && m.length == 1 && h.length == 1) {
        return HermesSchedule.month(
          f.doms.single,
          hour: h.single,
          minute: m.single,
        );
      }
      return HermesSchedule.custom(normalized);
    }

    if (m.length == 1 && h.length == 1) {
      if (weekdays.length == 7) {
        return HermesSchedule.daily(hour: h.single, minute: m.single);
      }
      return HermesSchedule.days(weekdays, hour: h.single, minute: m.single);
    }

    // Every n minutes (from :00), all day or inside ONE hour window.
    final minuteStep = _stepFromZero(m, 60);
    if (minuteStep != null && minuteStep < 60 && m.length > 1) {
      final window = _window(h);
      if (window == null && h.length != 24) {
        return HermesSchedule.custom(normalized);
      }
      return HermesSchedule.interval(
        minuteStep,
        windowStart: window?.$1,
        windowEnd: window?.$2,
        weekdays: weekdays,
      );
    }
    if (m.length == 1) {
      final minute = m.single;
      if (h.length == 24) {
        return HermesSchedule.interval(60, minute: minute, weekdays: weekdays);
      }
      final hourStep = _stepFromZero(h, 24);
      if (hourStep != null && hourStep > 1) {
        return HermesSchedule.interval(
          hourStep * 60,
          minute: minute,
          weekdays: weekdays,
        );
      }
      // Hourly (or every k hours) inside a window: a-b or a-b/k. Two
      // unrelated hours ("9,18") stay a list of times.
      if (h.length >= 3 || (h.length == 2 && h[1] == h[0] + 1)) {
        final step = h[1] - h[0];
        var regular = true;
        for (var i = 1; i < h.length; i++) {
          if (h[i] - h[i - 1] != step) regular = false;
        }
        if (regular) {
          return HermesSchedule.interval(
            step * 60,
            minute: minute,
            windowStart: h.first,
            windowEnd: h.last,
            weekdays: weekdays,
          );
        }
      }
    }
    return HermesSchedule.custom(normalized);
  }

  /// `*/step` semantics: 0, step, 2·step … up to the field end.
  static int? _stepFromZero(List<int> values, int period) {
    if (values.length < 2 || values.first != 0) return null;
    final step = values[1];
    for (var i = 1; i < values.length; i++) {
      if (values[i] - values[i - 1] != step) return null;
    }
    // Only even cycles: "*/7" wraps from :56 to :00 and is not "every 7".
    return period % step == 0 && values.last + step == period ? step : null;
  }

  /// One contiguous run of hours → (first, last).
  static (int, int)? _window(List<int> hours) {
    if (hours.length == 24) return null;
    for (var i = 1; i < hours.length; i++) {
      if (hours[i] != hours[i - 1] + 1) return null;
    }
    return (hours.first, hours.last);
  }

  /// The Hermes schedule string: cron, or the native interval
  /// (`every 60m`) when the job already used one.
  String toCron() {
    switch (mode) {
      case HermesScheduleMode.daily:
        return '$minute $hour * * *';
      case HermesScheduleMode.days:
        return '$minute $hour * * ${_formatWeekdays(weekdays)}';
      case HermesScheduleMode.month:
        return '$minute $hour $dayOfMonth * *';
      case HermesScheduleMode.custom:
        return raw;
      case HermesScheduleMode.interval:
        final limited = hasWindow || weekdays.length != 7;
        if (!canLimit || (native && !limited)) {
          return 'every ${intervalMinutes}m';
        }
        final dow = weekdays.length == 7 ? '*' : _formatWeekdays(weekdays);
        final window = hasWindow
            ? (windowStart == windowEnd
                  ? '$windowStart'
                  : '$windowStart-$windowEnd')
            : null;
        if (intervalMinutes < 60) {
          return '*/$intervalMinutes ${window ?? '*'} * * $dow';
        }
        final hours = intervalMinutes ~/ 60;
        final hourField = window == null
            ? (hours == 1 ? '*' : '*/$hours')
            : (hours == 1 || windowStart == windowEnd
                  ? window
                  : '$window/$hours');
        return '$minute $hourField * * $dow';
    }
  }

  bool get isValid => switch (mode) {
    HermesScheduleMode.days => weekdays.isNotEmpty,
    HermesScheduleMode.interval =>
      weekdays.isNotEmpty && (!hasWindow || windowStart! <= windowEnd!),
    HermesScheduleMode.custom => isValidSchedule(raw),
    _ => true,
  };

  bool get usesTime =>
      mode == HermesScheduleMode.daily ||
      mode == HermesScheduleMode.days ||
      mode == HermesScheduleMode.month;

  /// Human summary, e.g. "Weekdays at 18:30". Never the raw syntax.
  String describe(Strings s) => describeHermesSchedule(s, toCron());

  /// Next run strictly after [from] (local time), or null when unknown (a
  /// native interval counts from the last run).
  DateTime? nextRun(DateTime from) => hermesScheduleNextRun(toCron(), from);

  @override
  bool operator ==(Object other) =>
      other is HermesSchedule && other.toCron() == toCron();

  @override
  int get hashCode => toCron().hashCode;

  @override
  String toString() => 'HermesSchedule(${toCron()})';

  // ── helpers ──────────────────────────────────────────────────────────────

  static String formatTime24(int hour, int minute) =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  static String weekdayAbbr(Strings s, int day) => switch (day) {
    1 => s.schDayMonAbbr,
    2 => s.schDayTueAbbr,
    3 => s.schDayWedAbbr,
    4 => s.schDayThuAbbr,
    5 => s.schDayFriAbbr,
    6 => s.schDaySatAbbr,
    _ => s.schDaySunAbbr,
  };

  static String weekdayShort(Strings s, int day) => switch (day) {
    1 => s.schDayMonShort,
    2 => s.schDayTueShort,
    3 => s.schDayWedShort,
    4 => s.schDayThuShort,
    5 => s.schDayFriShort,
    6 => s.schDaySatShort,
    _ => s.schDaySunShort,
  };

  static String _formatWeekdays(Set<int> days) {
    // To cron numbering (0 = Sunday), sorted, contiguous runs as ranges.
    final cron = days.map((d) => d == 7 ? 0 : d).toList()..sort();
    final runs = <String>[];
    var i = 0;
    while (i < cron.length) {
      var j = i;
      while (j + 1 < cron.length && cron[j + 1] == cron[j] + 1) {
        j++;
      }
      runs.add(
        j - i >= 2 ? '${cron[i]}-${cron[j]}' : cron.sublist(i, j + 1).join(','),
      );
      i = j + 1;
    }
    return runs.join(',');
  }

  static final RegExp _field = RegExp(
    r'^(\*|\?|[0-9A-Za-z]+(-[0-9A-Za-z]+)?)(/\d+)?(,(\*|[0-9A-Za-z]+(-[0-9A-Za-z]+)?)(/\d+)?)*$',
  );

  /// Structural validation of a 5-field cron expression.
  static bool isValidCron(String expression) {
    final parts = expression.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) return false;
    return parts.every(_field.hasMatch);
  }

  /// Any schedule Hermes' `parse_schedule` accepts: cron, native interval,
  /// natural phrase, `in 30m` or an ISO timestamp.
  static bool isValidSchedule(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return false;
    final lower = text.toLowerCase();
    return isValidCron(text) ||
        hermesIntervalMinutes(text) != null ||
        hermesNaturalToCron(text) != null ||
        (lower.startsWith('in ') &&
            hermesIntervalMinutes(lower.substring(3)) != null) ||
        hermesOnceAt(text) != null;
  }
}
