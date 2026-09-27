import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_premium_ui.dart'
    show HermesSegment, HermesSegmentedControl;
import 'content.dart';
import 'list.dart';
import 'modal.dart';
import 'schedule_humanizer.dart';
import 'schedule_model.dart';
import 'tokens.dart';

/// Opens the schedule builder page (mock screen 2) and returns the chosen
/// cron expression, or null when cancelled.
Future<String?> showHermesScheduleBuilder(
  BuildContext context, {
  required String initialCron,
  DateTime Function()? now,
}) => Navigator.of(context).push<String>(
  MaterialPageRoute<String>(
    fullscreenDialog: true,
    builder: (_) => HermesScheduleBuilder(initialCron: initialCron, now: now),
  ),
);

/// Android Material 3 time picker, themed with the Hermes tokens, 24 h.
Future<TimeOfDay?> showHermesTimePicker(
  BuildContext context,
  TimeOfDay initial,
) {
  final colors = Theme.of(context).hermes;
  return showTimePicker(
    context: context,
    initialTime: initial,
    initialEntryMode: TimePickerEntryMode.dial,
    builder: (context, child) {
      final theme = Theme.of(context);
      return MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: Theme(
          data: theme.copyWith(
            timePickerTheme: TimePickerThemeData(
              backgroundColor: colors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(HermesRadius.dialog),
              ),
              hourMinuteShape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              hourMinuteColor: WidgetStateColor.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? colors.accent.withValues(alpha: .16)
                    : colors.surfaceVariant,
              ),
              hourMinuteTextColor: WidgetStateColor.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? colors.accentText
                    : colors.textPrimary,
              ),
              dialBackgroundColor: colors.surfaceVariant,
              dialHandColor: colors.accent,
              dialTextColor: WidgetStateColor.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? colors.onAccent
                    : colors.textPrimary,
              ),
              entryModeIconColor: colors.textSecondary,
              helpTextStyle: HermesType.caption.copyWith(
                color: colors.textSecondary,
              ),
              cancelButtonStyle: TextButton.styleFrom(
                foregroundColor: colors.textPrimary,
                minimumSize: const Size(48, 48),
              ),
              confirmButtonStyle: TextButton.styleFrom(
                foregroundColor: colors.accentText,
                minimumSize: const Size(48, 48),
              ),
            ),
          ),
          child: child!,
        ),
      );
    },
  );
}

/// Human label of any Hermes schedule, for rows and headers. Never the raw
/// cron or interval syntax.
String hermesScheduleSummary(Strings s, String cron) =>
    describeHermesSchedule(s, cron);

String hermesFormatNextRun(Strings s, DateTime when, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final time = '${when.hour}:${when.minute.toString().padLeft(2, '0')}';
  final sameDay =
      when.year == ref.year && when.month == ref.month && when.day == ref.day;
  if (sameDay) return time;
  return '${HermesSchedule.weekdayAbbr(s, when.weekday)} ${when.day}, $time';
}

/// Schedule builder (spec 080): mode segment, day chips, themed time picker,
/// interval presets, day of month, live summary + next run, raw cron only
/// under "Advanced" with validation.
class HermesScheduleBuilder extends StatefulWidget {
  final String initialCron;
  final DateTime Function()? now;

  const HermesScheduleBuilder({super.key, required this.initialCron, this.now});

  @override
  State<HermesScheduleBuilder> createState() => _HermesScheduleBuilderState();
}

class _HermesScheduleBuilderState extends State<HermesScheduleBuilder> {
  late HermesSchedule _schedule;
  late final TextEditingController _cron;
  late bool _advanced;

  /// Last structured schedule, so switching modes keeps the chosen time.
  late HermesSchedule _lastStructured;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialCron.trim().isEmpty
        ? '0 9 * * *'
        : widget.initialCron;
    _schedule = HermesSchedule.parse(initial);
    _lastStructured = _schedule.mode == HermesScheduleMode.custom
        ? const HermesSchedule.daily()
        : _schedule;
    _cron = TextEditingController(text: _schedule.toCron());
    // The raw syntax is only ever shown when the user asks for it.
    _advanced = false;
  }

  @override
  void dispose() {
    _cron.dispose();
    super.dispose();
  }

  void _set(HermesSchedule next) {
    setState(() {
      _schedule = next;
      if (next.mode != HermesScheduleMode.custom) _lastStructured = next;
      final cron = next.toCron();
      if (_cron.text != cron) _cron.text = cron;
    });
  }

  void _setMode(HermesScheduleMode mode) {
    final base = _lastStructured;
    final next = switch (mode) {
      HermesScheduleMode.daily => HermesSchedule.daily(
        hour: base.hour,
        minute: base.minute,
      ),
      HermesScheduleMode.days => HermesSchedule.days(
        base.mode == HermesScheduleMode.days
            ? base.weekdays
            : const {1, 2, 3, 4, 5},
        hour: base.hour,
        minute: base.minute,
      ),
      HermesScheduleMode.interval =>
        base.mode == HermesScheduleMode.interval
            ? base
            : HermesSchedule.interval(
                60,
                weekdays: base.mode == HermesScheduleMode.days
                    ? base.weekdays
                    : HermesSchedule.allDays,
              ),
      HermesScheduleMode.month => HermesSchedule.month(
        base.mode == HermesScheduleMode.month ? base.dayOfMonth : 1,
        hour: base.hour,
        minute: base.minute,
      ),
      HermesScheduleMode.custom => HermesSchedule.custom(_cron.text.trim()),
    };
    _set(next);
  }

  void _onCronEdited(String value) {
    final parsed = HermesSchedule.parse(value);
    setState(() {
      _schedule = parsed.mode == HermesScheduleMode.custom
          ? HermesSchedule.custom(value.trim())
          : parsed;
      if (parsed.mode != HermesScheduleMode.custom) _lastStructured = parsed;
    });
  }

  Future<void> _pickTime() async {
    final picked = await showHermesTimePicker(
      context,
      TimeOfDay(hour: _schedule.hour, minute: _schedule.minute),
    );
    if (picked == null || !mounted) return;
    _set(_schedule.copyWith(hour: picked.hour, minute: picked.minute));
  }

  Future<void> _pickDayOfMonth(BuildContext rowContext) async {
    final s = Strings.of(context);
    final picked = await showHermesOptions<int>(
      context: context,
      title: s.schDayOfMonth,
      selected: _schedule.dayOfMonth,
      originRect: hermesOriginOf(rowContext),
      surfaceKey: const ValueKey('schedule-day-of-month-surface'),
      searchThreshold: 99,
      options: [
        for (var d = 1; d <= 28; d++)
          HermesOption(key: ValueKey('schedule-dom-$d'), value: d, label: '$d'),
      ],
    );
    if (picked != null) _set(_schedule.copyWith(dayOfMonth: picked));
  }

  void _toggleDay(int day) {
    final days = {..._schedule.weekdays};
    if (!days.remove(day)) days.add(day);
    _set(_schedule.copyWith(weekdays: days));
  }

  void _setInterval(int minutes) {
    final next = _schedule.copyWith(
      intervalMinutes: minutes,
      minute: minutes >= 60 ? _schedule.minute : 0,
    );
    // Limits need a clock cron; drop them for an interval cron cannot hold.
    _set(
      next.canLimit
          ? next
          : next.copyWith(
              windowStart: () => null,
              windowEnd: () => null,
              weekdays: HermesSchedule.allDays,
            ),
    );
  }

  void _toggleWindow(bool on) {
    _set(
      on
          ? _schedule.copyWith(windowStart: () => 9, windowEnd: () => 17)
          : _schedule.copyWith(windowStart: () => null, windowEnd: () => null),
    );
  }

  /// Picks a window edge. The end is shown as the LAST run time ("until
  /// 17:55" for every 5 min), the same time the summary reads.
  Future<void> _pickWindowEdge(
    BuildContext rowContext, {
    required bool end,
  }) async {
    final s = Strings.of(context);
    final start = _schedule.windowStart ?? 9;
    final last = _schedule.windowEnd ?? 17;
    final picked = await showHermesOptions<int>(
      context: context,
      title: end ? s.schWindowTo : s.schWindowFrom,
      selected: end ? last : start,
      originRect: hermesOriginOf(rowContext),
      surfaceKey: ValueKey('schedule-window-${end ? 'end' : 'start'}-surface'),
      searchThreshold: 99,
      options: [
        for (var h = end ? start : 0; h <= (end ? 23 : last); h++)
          HermesOption(
            key: ValueKey('schedule-window-${end ? 'end' : 'start'}-$h'),
            value: h,
            label: end ? _endLabel(h) : _hourLabel(h),
          ),
      ],
    );
    if (picked == null) return;
    _set(
      end
          ? _schedule.copyWith(windowEnd: () => picked)
          : _schedule.copyWith(windowStart: () => picked),
    );
  }

  String _endLabel(int end) {
    final (h, m) = _schedule.lastRunInWindow(end);
    return '$h:${m.toString().padLeft(2, '0')}';
  }

  static String _hourLabel(int hour) => '$hour:00';

  void _submit() {
    if (!_schedule.isValid) return;
    Navigator.of(context).pop(_schedule.toCron());
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final mode = _schedule.mode;
    final valid = _schedule.isValid;
    final next = valid
        ? _schedule.nextRun((widget.now ?? DateTime.now)())
        : null;
    final summary =
        (mode == HermesScheduleMode.days ||
                mode == HermesScheduleMode.interval) &&
            _schedule.weekdays.isEmpty
        ? s.schPickDays
        : _schedule.describe(s);
    final summaryLine = next == null
        ? summary
        : '$summary · ${s.schNextRun(hermesFormatNextRun(s, next, now: (widget.now ?? DateTime.now)()))}';

    // A custom schedule selects no mode (it is none of them).
    final segmentMode = mode;

    return Scaffold(
      appBar: HermesAppBar(
        centerTitle: false,
        leading: IconButton(
          key: const ValueKey('schedule-cancel'),
          tooltip: s.commonCancel,
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(s.schTitle),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton.filled(
              key: const ValueKey('schedule-apply'),
              tooltip: s.schApply,
              style: IconButton.styleFrom(
                backgroundColor: colors.accent,
                foregroundColor: colors.onAccent,
                disabledBackgroundColor: colors.surfaceVariant,
              ),
              onPressed: valid ? _submit : null,
              icon: const Icon(Icons.check_rounded),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          key: const ValueKey('schedule-builder'),
          padding: const EdgeInsets.fromLTRB(
            HermesSpace.pageH,
            HermesSpace.pageTop,
            HermesSpace.pageH,
            HermesSpace.pageBottom,
          ),
          children: [
            HermesListGroup(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  child: _ModeSegments(value: segmentMode, onChanged: _setMode),
                ),
                if (segmentMode == HermesScheduleMode.days)
                  _DayChips(
                    selected: _schedule.mode == HermesScheduleMode.days
                        ? _schedule.weekdays
                        : _lastStructured.weekdays,
                    onToggle: _toggleDay,
                  ),
                if (segmentMode == HermesScheduleMode.interval)
                  _IntervalPresets(
                    value: _schedule.intervalMinutes,
                    onChanged: _setInterval,
                  ),
                if (segmentMode == HermesScheduleMode.month)
                  Builder(
                    builder: (rowContext) => HermesSelectRow(
                      key: const ValueKey('schedule-day-of-month'),
                      title: s.schDayOfMonth,
                      value: '${_schedule.dayOfMonth}',
                      onTap: () => _pickDayOfMonth(rowContext),
                    ),
                  ),
              ],
            ),
            if (mode == HermesScheduleMode.interval && _schedule.canLimit) ...[
              HermesSectionHeader(s.schLimits),
              HermesListGroup(
                dividerIndent: HermesSpace.rowH,
                children: [
                  HermesToggleRow(
                    key: const ValueKey('schedule-window'),
                    switchKey: const ValueKey('schedule-window-switch'),
                    title: s.schWindowToggle,
                    value: _schedule.hasWindow,
                    onChanged: _toggleWindow,
                  ),
                  if (_schedule.hasWindow) ...[
                    Builder(
                      builder: (rowContext) => HermesSelectRow(
                        key: const ValueKey('schedule-window-start'),
                        title: s.schWindowFrom,
                        value: _hourLabel(_schedule.windowStart!),
                        onTap: () => _pickWindowEdge(rowContext, end: false),
                      ),
                    ),
                    Builder(
                      builder: (rowContext) => HermesSelectRow(
                        key: const ValueKey('schedule-window-end'),
                        title: s.schWindowTo,
                        value: _endLabel(_schedule.windowEnd!),
                        onTap: () => _pickWindowEdge(rowContext, end: true),
                      ),
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _DayChips(
                      selected: _schedule.weekdays,
                      onToggle: _toggleDay,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: HermesSpace.x3),
              _Summary(text: summaryLine, error: !valid, grouped: false),
            ] else if (_schedule.usesTime) ...[
              HermesSectionHeader(s.schTime),
              HermesListGroup(
                children: [
                  _Clock(
                    hour: _schedule.hour,
                    minute: _schedule.minute,
                    onTap: _pickTime,
                    label: s.schTime,
                  ),
                  _Summary(text: summaryLine, error: !valid),
                ],
              ),
            ] else ...[
              const SizedBox(height: HermesSpace.x3),
              _Summary(text: summaryLine, error: !valid, grouped: false),
            ],
            HermesSectionHeader(s.schPresets),
            HermesListGroup(
              dividerIndent: HermesSpace.rowH,
              children: [
                HermesListRow(
                  key: const ValueKey('schedule-preset-morning'),
                  title: s.schPresetMorning,
                  showChevron: false,
                  onTap: () =>
                      _set(const HermesSchedule.daily(hour: 8, minute: 0)),
                ),
                HermesListRow(
                  key: const ValueKey('schedule-preset-weekdays'),
                  title: s.schPresetWeekdays,
                  showChevron: false,
                  onTap: () =>
                      _set(const HermesSchedule.days({1, 2, 3, 4, 5}, hour: 9)),
                ),
                HermesListRow(
                  key: const ValueKey('schedule-preset-hourly'),
                  title: s.schPresetHourly,
                  showChevron: false,
                  onTap: () => _set(const HermesSchedule.interval(60)),
                ),
                HermesListRow(
                  key: const ValueKey('schedule-advanced'),
                  title: s.schAdvanced,
                  subtitle: s.schAdvancedSub,
                  trailing: Icon(
                    _advanced
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 20,
                    color: colors.textDisabled,
                  ),
                  onTap: () => setState(() => _advanced = !_advanced),
                ),
                if (_advanced) ...[
                  if (mode == HermesScheduleMode.custom)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
                      child: Text(
                        s.schCustomHint,
                        key: const ValueKey('schedule-custom-hint'),
                        style: HermesType.support.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
                    child: TextField(
                      key: const ValueKey('schedule-cron-field'),
                      controller: _cron,
                      onChanged: _onCronEdited,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                      ),
                      decoration: InputDecoration(
                        hintText: '30 18 * * 1-5',
                        errorText:
                            _schedule.mode == HermesScheduleMode.custom &&
                                !HermesSchedule.isValidSchedule(_cron.text)
                            ? s.schCronInvalid
                            : null,
                        errorMaxLines: 3,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Mode segment. At large text scales the four modes wrap to a 2×2 grid
/// instead of scrolling sideways (which would hide options).
class _ModeSegments extends StatelessWidget {
  final HermesScheduleMode value;
  final ValueChanged<HermesScheduleMode> onChanged;

  const _ModeSegments({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    HermesSegment<HermesScheduleMode> seg(
      HermesScheduleMode mode,
      String label,
      String key,
    ) => HermesSegment(
      key: ValueKey('schedule-mode-$key'),
      value: mode,
      label: label,
      horizontalPadding: 6,
    );
    final all = [
      seg(HermesScheduleMode.daily, s.schModeDaily, 'daily'),
      seg(HermesScheduleMode.days, s.schModeDays, 'days'),
      seg(HermesScheduleMode.interval, s.schModeInterval, 'interval'),
      seg(HermesScheduleMode.month, s.schModeMonth, 'month'),
    ];
    final large = MediaQuery.textScalerOf(context).scale(1) > 1.35;
    if (!large) {
      return HermesSegmentedControl<HermesScheduleMode>(
        key: const ValueKey('schedule-mode'),
        value: value,
        onChanged: onChanged,
        segments: all,
      );
    }
    return Column(
      key: const ValueKey('schedule-mode'),
      children: [
        HermesSegmentedControl<HermesScheduleMode>(
          value: value,
          onChanged: onChanged,
          segments: all.sublist(0, 2),
        ),
        const SizedBox(height: 6),
        HermesSegmentedControl<HermesScheduleMode>(
          value: value,
          onChanged: onChanged,
          segments: all.sublist(2),
        ),
      ],
    );
  }
}

class _Clock extends StatelessWidget {
  final int hour;
  final int minute;
  final VoidCallback onTap;
  final String label;

  const _Clock({
    required this.hour,
    required this.minute,
    required this.onTap,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final time = HermesSchedule.formatTime24(hour, minute);
    Widget box(String text, bool on) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      decoration: BoxDecoration(
        color: on
            ? colors.accent.withValues(alpha: .16)
            : colors.surfaceVariant.withValues(alpha: .7),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 44,
          fontWeight: FontWeight.w600,
          letterSpacing: -1,
          color: on ? colors.accentText : colors.textPrimary,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
    return Semantics(
      button: true,
      label: '$label $time',
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('schedule-time'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                box(time.substring(0, 2), true),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    ':',
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w600,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
                box(time.substring(3), false),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  final String text;
  final bool error;
  final bool grouped;

  const _Summary({required this.text, this.error = false, this.grouped = true});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: grouped
          ? const EdgeInsets.fromLTRB(14, 4, 14, 14)
          : const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        text,
        key: const ValueKey('schedule-summary'),
        textAlign: grouped ? TextAlign.center : TextAlign.start,
        style: HermesType.support.copyWith(
          color: error ? colors.error : colors.textSecondary,
        ),
      ),
    );
  }
}

class _DayChips extends StatelessWidget {
  final Set<int> selected;
  final ValueChanged<int> onToggle;

  const _DayChips({required this.selected, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      child: Row(
        children: [
          for (var day = 1; day <= 7; day++)
            Expanded(
              child: Semantics(
                button: true,
                selected: selected.contains(day),
                label: HermesSchedule.weekdayAbbr(s, day),
                excludeSemantics: true,
                child: InkResponse(
                  key: ValueKey('schedule-day-$day'),
                  onTap: () => onToggle(day),
                  radius: 24,
                  child: SizedBox(
                    height: 48,
                    child: Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        width: 38,
                        height: 38,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: selected.contains(day)
                              ? colors.accent
                              : colors.surfaceVariant.withValues(alpha: .8),
                        ),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            HermesSchedule.weekdayShort(s, day),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: selected.contains(day)
                                  ? colors.onAccent
                                  : colors.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _IntervalPresets extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;

  const _IntervalPresets({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final minutes in {
            ...HermesSchedule.intervalPresets,
            value,
          }.toList()..sort())
            Semantics(
              button: true,
              selected: minutes == value,
              child: InkWell(
                key: ValueKey('schedule-interval-$minutes'),
                borderRadius: BorderRadius.circular(HermesRadius.tag),
                onTap: () => onChanged(minutes),
                child: Container(
                  constraints: const BoxConstraints(
                    minHeight: 40,
                    minWidth: 64,
                  ),
                  // No `alignment`: it would make each chip fill the row.
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(HermesRadius.tag),
                    color: minutes == value
                        ? colors.accent
                        : colors.surfaceVariant.withValues(alpha: .8),
                  ),
                  child: Text(
                    minutes < 60
                        ? s.schMinutesShort(minutes)
                        : minutes % 60 == 0
                        ? s.schHoursShort(minutes ~/ 60)
                        : '${s.schHoursShort(minutes ~/ 60)} ${s.schMinutesShort(minutes % 60)}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: minutes == value
                          ? colors.onAccent
                          : colors.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
