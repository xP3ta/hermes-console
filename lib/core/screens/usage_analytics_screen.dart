// Usage: the server's usage analytics, read only.
//
// Totals (tokens, sessions, cost when the server gives one), the days of the
// period as simple bars and the models by tokens. The period is 7, 30 or 90
// days. Nothing here changes anything on the server, and the per-session
// usage of the chat is a different thing that this screen does not touch.
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/content.dart' show HermesEmptyStateView;
import '../design/edges.dart' show HermesControlsScroll;
import '../design/tokens.dart';
import '../services/connection_manager.dart';
import '../theme/app_theme.dart';
import '../usage/usage_analytics.dart';
import '../utils/api_error.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_pill.dart' show TuiLoader;
import '../widgets/hermes_ui.dart' show HermesCard, HermesGroup;

class UsageAnalyticsScreen extends StatefulWidget {
  const UsageAnalyticsScreen({
    required this.connection,
    required this.profile,
    @visibleForTesting this.clientOverride,
    super.key,
  });

  final SavedConnection connection;

  /// The profile whose usage is read; empty or `default` is the server's own.
  final String profile;

  /// Test seam: replaces the Dashboard client.
  final DashboardClient? clientOverride;

  @override
  State<UsageAnalyticsScreen> createState() => _UsageAnalyticsScreenState();
}

class _UsageAnalyticsScreenState extends State<UsageAnalyticsScreen> {
  late final DashboardClient _client;
  int _days = 30;
  UsageAnalytics? _data;
  Object? _error;
  bool _loading = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _client = widget.clientOverride ?? DashboardClient.lazy(widget.connection);
    _load();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await fetchUsageAnalytics(
        _client,
        days: _days,
        profile: widget.profile,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error;
        _data = null;
        _loading = false;
      });
    }
  }

  void _pickPeriod(int days) {
    if (days == _days) return;
    setState(() => _days = days);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: HermesAppBar(title: Text(s.kluUsageTitle)),
      body: HermesControlsScroll(
        refreshColor: colors.accent,
        onRefresh: _load,
        controls: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HermesSpace.pageH,
              HermesSpace.x2,
              HermesSpace.pageH,
              0,
            ),
            child: _PeriodPicker(selected: _days, onSelected: _pickPeriod),
          ),
        ],
        slivers: [_body(context)],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final s = Strings.of(context);
    if (_loading) {
      return HermesControlsScroll.fill(
        Center(child: TuiLoader(label: s.kluUsageLoading)),
      );
    }
    final error = _error;
    if (error != null) {
      final missing =
          error is DashboardHttpException && error.statusCode == 404;
      return HermesControlsScroll.fill(
        Center(
          child: HermesEmptyStateView(
            icon: Icons.error_outline_rounded,
            title: missing ? s.kluUsageUnsupported : s.kluUsageLoadError,
            body: missing ? null : localizedApiError(s, error),
          ),
        ),
      );
    }
    final data = _data;
    if (data == null || data.isEmpty) {
      return HermesControlsScroll.fill(
        Center(
          child: HermesEmptyStateView(
            icon: Icons.bar_chart_rounded,
            title: s.kluUsageEmpty,
          ),
        ),
      );
    }
    return HermesControlsScroll.children(
      [
        _Totals(totals: data.totals),
        if (data.days.length > 1) ...[
          _SectionLabel(s.kluUsageDaily),
          _DailyBars(days: data.days),
        ],
        if (data.models.isNotEmpty) ...[
          _SectionLabel(s.kluUsageByModel),
          _ModelBars(models: data.models),
        ],
      ],
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.pageH,
        HermesSpace.x3,
        HermesSpace.pageH,
        HermesSpace.pageBottom,
      ),
    );
  }
}

class _PeriodPicker extends StatelessWidget {
  const _PeriodPicker({required this.selected, required this.onSelected});

  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Row(
      children: [
        for (final days in kUsagePeriods)
          Expanded(
            child: Semantics(
              button: true,
              selected: selected == days,
              label: s.kluUsagePeriod(days),
              excludeSemantics: true,
              onTap: () => onSelected(days),
              child: InkWell(
                key: ValueKey('usage-period-$days'),
                borderRadius: BorderRadius.circular(HermesRadius.control),
                onTap: () => onSelected(days),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Center(
                    child: Text(
                      s.kluUsagePeriod(days),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: HermesType.textSize,
                        fontWeight: selected == days
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: selected == days
                            ? colors.accentText
                            : colors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.x2,
        HermesSpace.sectionTop,
        HermesSpace.x2,
        HermesSpace.sectionBottom,
      ),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: TextStyle(
            fontSize: HermesType.captionSize,
            fontWeight: FontWeight.w600,
            color: colors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.totals});

  final UsageTotals totals;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final cost = totals.cost;
    return Wrap(
      key: const ValueKey('usage-totals'),
      spacing: HermesSpace.x2,
      runSpacing: HermesSpace.x2,
      children: [
        _Stat(
          label: s.kluUsageTokens,
          value: formatCompactCount(totals.tokens),
        ),
        _Stat(
          label: s.kluUsageInput,
          value: formatCompactCount(totals.inputTokens),
        ),
        _Stat(
          label: s.kluUsageOutput,
          value: formatCompactCount(totals.outputTokens),
        ),
        _Stat(label: s.kluUsageSessions, value: '${totals.sessions}'),
        if (cost > 0)
          _Stat(
            label: totals.costIsEstimate
                ? s.kluUsageCostEstimated
                : s.kluUsageCost,
            value: formatUsageCost(cost),
          ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final width =
        (MediaQuery.sizeOf(context).width -
            2 * HermesSpace.pageH -
            HermesSpace.x2) /
        2;
    return SizedBox(
      width: width,
      child: Semantics(
        container: true,
        label: '$label: $value',
        excludeSemantics: true,
        child: HermesCard(
          padding: const EdgeInsets.symmetric(
            horizontal: HermesSpace.x4,
            vertical: HermesSpace.x3,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: HermesType.captionSize,
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: HermesType.title.copyWith(color: colors.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One bar per day, tallest day full height. A summary for assistive tech
/// replaces the individual bars.
class _DailyBars extends StatelessWidget {
  const _DailyBars({required this.days});

  final List<UsageDay> days;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final peak = days.fold<int>(0, (m, d) => d.tokens > m ? d.tokens : m);
    return HermesGroup(
      children: [
        Semantics(
          container: true,
          label:
              '${s.kluUsageDaily}: ${days.first.day} - ${days.last.day}, '
              '${formatCompactCount(peak)}',
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.all(HermesSpace.x4),
            child: SizedBox(
              key: const ValueKey('usage-daily'),
              height: 72,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final day in days)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: HermesSpace.x1 / 8,
                        ),
                        child: FractionallySizedBox(
                          heightFactor: peak == 0
                              ? 0.02
                              : (day.tokens / peak).clamp(0.02, 1.0),
                          alignment: Alignment.bottomCenter,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.accent,
                              borderRadius: BorderRadius.circular(
                                HermesRadius.chip / 4,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The models by tokens, each with a bar scaled to the busiest one.
class _ModelBars extends StatelessWidget {
  const _ModelBars({required this.models});

  /// More than this and the list is a wall; the rest is the long tail.
  static const int shown = 12;

  final List<UsageModelRow> models;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final rows = models.take(shown).toList();
    final peak = rows.fold<int>(0, (m, r) => r.tokens > m ? r.tokens : m);
    return HermesGroup(
      children: [
        for (final row in rows)
          Semantics(
            container: true,
            label:
                '${row.model}: ${formatCompactCount(row.tokens)}, '
                '${s.kluUsageSessionsCount(row.sessions)}',
            excludeSemantics: true,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: HermesSpace.x4,
                  vertical: HermesSpace.x3,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            row.model,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: HermesType.textSize,
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          formatCompactCount(row.tokens),
                          style: TextStyle(
                            fontSize: HermesType.valueSize,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(
                        HermesRadius.chip / 2,
                      ),
                      child: SizedBox(
                        height: 6,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: ColoredBox(
                                color: colors.surfaceVariant.withValues(
                                  alpha: 0.6,
                                ),
                              ),
                            ),
                            FractionallySizedBox(
                              widthFactor: peak == 0
                                  ? 0
                                  : (row.tokens / peak).clamp(0.0, 1.0),
                              child: ColoredBox(color: colors.accent),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      s.kluUsageSessionsCount(row.sessions),
                      style: TextStyle(
                        fontSize: HermesType.captionSize,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
