// Usage: the server's usage analytics, read only.
//
// Layout: Cost / Tokens / Limits on top, the period under it, one large
// figure over the days of the period, then the models and the totals. The
// figures are the server's own (`GET /api/analytics/usage`); the limits are
// the plan limits Console already reads for the model sheet. Nothing here
// changes anything on the server.
import 'package:flutter/cupertino.dart'
    show CupertinoSlidingSegmentedControl;
import 'package:hermes_android/core/design/hicons.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../l10n/app_localizations.dart';
import '../design/content.dart' show HermesEmptyStateView;
import '../design/edges.dart' show HermesControlsScroll;
import '../design/tokens.dart';
import '../models/account_usage_limits.dart';
import '../services/connection_manager.dart';
import '../theme/app_theme.dart';
import '../usage/usage_analytics.dart';
import '../utils/api_error.dart';
import '../usage/plan_limits_view.dart';
import '../widgets/account_limits_section.dart' show AccountCreditBars;
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_pill.dart' show TuiLoader;
import '../widgets/provider_logo.dart';

enum _UsageTab { cost, tokens, limits }

class UsageAnalyticsScreen extends StatefulWidget {
  const UsageAnalyticsScreen({
    required this.connection,
    required this.profile,
    this.loadLimits,
    this.preferredProvider,
    @visibleForTesting this.clientOverride,
    super.key,
  });

  final SavedConnection connection;

  /// The profile whose usage is read; empty or `default` is the server's own.
  final String profile;

  /// Reads the plan limits; null hides the «Límites» tab.
  final Future<AccountUsageLimits?> Function()? loadLimits;
  final String? preferredProvider;

  /// Test seam: replaces the Dashboard client.
  final DashboardClient? clientOverride;

  @override
  State<UsageAnalyticsScreen> createState() => _UsageAnalyticsScreenState();
}

class _UsageAnalyticsScreenState extends State<UsageAnalyticsScreen> {
  late final DashboardClient _client;
  int _days = 30;
  _UsageTab _tab = _UsageTab.tokens;
  UsageAnalytics? _data;
  Object? _error;
  bool _loading = true;
  int _generation = 0;
  Future<AccountUsageLimits?>? _limits;

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

  Future<void> _refresh() async {
    if (_tab == _UsageTab.limits) {
      setState(() => _limits = widget.loadLimits?.call());
      await _limits;
      return;
    }
    await _load();
  }

  void _pickPeriod(int days) {
    if (days == _days) return;
    setState(() => _days = days);
    _load();
  }

  void _pickTab(_UsageTab tab) {
    if (tab == _tab) return;
    setState(() {
      _tab = tab;
      if (tab == _UsageTab.limits) _limits ??= widget.loadLimits?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final tabs = [
      _UsageTab.cost,
      _UsageTab.tokens,
      if (widget.loadLimits != null) _UsageTab.limits,
    ];
    return Scaffold(
      appBar: HermesAppBar(title: Text(s.kluUsageTitle)),
      body: HermesControlsScroll(
        refreshColor: colors.accent,
        onRefresh: _refresh,
        controls: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HermesSpace.pageH,
              HermesSpace.x2,
              HermesSpace.pageH,
              0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                _Segments<_UsageTab>(
                  key: const ValueKey('usage-tabs'),
                  values: tabs,
                  selected: _tab,
                  label: (tab) => switch (tab) {
                    _UsageTab.cost => s.kluUsageCost,
                    _UsageTab.tokens => s.kluUsageTokens,
                    _UsageTab.limits => s.kluUsageLimits,
                  },
                  onSelected: _pickTab,
                ),
                if (_tab != _UsageTab.limits) ...[
                  const SizedBox(height: HermesSpace.x2),
                  _Segments<int>(
                    key: const ValueKey('usage-periods'),
                    values: kUsagePeriods,
                    selected: _days,
                    label: (days) =>
                        days == 1 ? s.kluUsagePeriodDay : s.i18n131SpanDays(days),
                    semantics: (days) => s.kluUsagePeriod(days),
                    onSelected: _pickPeriod,
                  ),
                ],
              ],
            ),
          ),
        ],
        slivers: [
          _tab == _UsageTab.limits ? _limitsBody(context) : _body(context),
        ],
      ),
    );
  }

  Widget _limitsBody(BuildContext context) {
    final s = Strings.of(context);
    return HermesControlsScroll.children(
      [
        FutureBuilder<AccountUsageLimits?>(
          future: _limits,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return Padding(
                padding: const EdgeInsets.only(top: 48),
                child: Center(child: TuiLoader(label: s.kluUsageLoading)),
              );
            }
            final limits = snapshot.data;
            if (limits == null || limits.isEmpty) {
              return Padding(
                padding: const EdgeInsets.only(top: 48),
                child: HermesEmptyStateView(
                  icon: HIcons.bar_chart_rounded,
                  title: s.sp1215LimitNoData,
                ),
              );
            }
            return _LimitsView(
              key: const ValueKey('usage-limits'),
              limits: limits,
              preferredProvider: widget.preferredProvider,
            );
          },
        ),
      ],
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.pageH,
        HermesSpace.x3,
        HermesSpace.pageH,
        HermesSpace.pageBottom,
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
            icon: HIcons.error_outline_rounded,
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
            icon: HIcons.bar_chart_rounded,
            title: s.kluUsageEmpty,
          ),
        ),
      );
    }
    final cost = _tab == _UsageTab.cost;
    return HermesControlsScroll.children(
      [
        _Hero(data: data, cost: cost),
        if (data.models.isNotEmpty) ...[
          _SectionLabel(s.memProvidersSection),
          _ProviderRows(models: data.models, cost: cost),
          _SectionLabel(s.kluUsageByModel),
          _ModelRows(models: data.models, cost: cost),
        ],
        _SectionLabel(s.kluUsageTitle),
        _Totals(totals: data.totals),
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

/// A row of choices in one capsule, the chosen one on a raised thumb.
class _Segments<T extends Object> extends StatelessWidget {
  const _Segments({
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
    this.semantics,
    super.key,
  });

  final List<T> values;
  final T selected;
  final String Function(T value) label;
  final String Function(T value)? semantics;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return CupertinoSlidingSegmentedControl<T>(
      groupValue: selected,
      backgroundColor: colors.textPrimary.withValues(alpha: 0.07),
      thumbColor: colors.textPrimary.withValues(alpha: 0.16),
      onValueChanged: (value) {
        if (value != null) onSelected(value);
      },
      children: {
        for (final value in values)
          value: Semantics(
            label: semantics?.call(value),
            button: true,
            selected: value == selected,
            child: Padding(
              key: ValueKey('usage-segment-$value'),
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Text(
                label(value),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: HermesType.textSize,
                  fontWeight: value == selected
                      ? FontWeight.w700
                      : FontWeight.w500,
                  color: value == selected
                      ? colors.textPrimary
                      : colors.textSecondary,
                ),
              ),
            ),
          ),
      },
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

/// A soft rounded panel: no rim, a quiet fill, generous air.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.child,
    this.padding = const EdgeInsets.all(20),
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.textPrimary.withValues(alpha: 0.055),
        borderRadius: BorderRadius.circular(26),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// A provider's mark on a round badge.
class _Badge extends StatelessWidget {
  const _Badge({this.provider, this.model});

  final String? provider;
  final String? model;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colors.textPrimary.withValues(alpha: 0.08),
      ),
      child: SizedBox.square(
        dimension: 38,
        child: Center(
          child: ProviderLogo(
            provider: provider,
            model: model,
            size: 20,
            color: colors.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// A capsule share bar.
class _Share extends StatelessWidget {
  const _Share({required this.fraction, required this.color});

  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 6,
        child: Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(
                color: colors.textPrimary.withValues(alpha: 0.08),
              ),
            ),
            FractionallySizedBox(
              widthFactor: fraction.clamp(0.0, 1.0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _shortDay(BuildContext context, String day) {
  final parsed = DateTime.tryParse(day);
  if (parsed == null) return day;
  return DateFormat.MMMd(
    Localizations.localeOf(context).toLanguageTag(),
  ).format(parsed);
}

String _shareText(double share) =>
    share > 0 && share < 0.1 ? '<0.1 %' : '${share.toStringAsFixed(1)} %';

/// The period at a glance: one large figure over the days of the period.
/// The chart answers to the finger: touching or dragging over a day shows
/// that day's figure and date in place of the period's; lifting leaves it
/// chosen, touching it again returns to the period. Two guide lines carry
/// the scale (the busiest day and half of it).
class _Hero extends StatefulWidget {
  const _Hero({required this.data, required this.cost});

  final UsageAnalytics data;
  final bool cost;

  @override
  State<_Hero> createState() => _HeroState();
}

class _HeroState extends State<_Hero> {
  int? _picked;

  @override
  void didUpdateWidget(_Hero old) {
    super.didUpdateWidget(old);
    if (old.data != widget.data) _picked = null;
  }

  String _format(double value) => widget.cost
      ? formatUsageCost(value)
      : formatCompactCount(value.round());

  void _pick(double dx, double width, int count, {bool toggle = false}) {
    if (count == 0 || width <= 0) return;
    final index = (dx / width * count).floor().clamp(0, count - 1);
    setState(() => _picked = toggle && _picked == index ? null : index);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final totals = widget.data.totals;
    final cost = widget.cost;
    final days = widget.data.days;
    final values = [
      for (final day in days) cost ? day.cost : day.tokens.toDouble(),
    ];
    final peak = values.fold<double>(0, (m, v) => v > m ? v : m);
    final picked = _picked != null && _picked! < days.length ? _picked : null;
    final label = picked != null
        ? _shortDay(context, days[picked].day)
        : cost
        ? (totals.costIsEstimate ? s.kluUsageCostEstimated : s.kluUsageCost)
        : s.kluUsageTokens;
    final figure = picked != null
        ? _format(values[picked])
        : cost
        ? formatUsageCost(totals.cost)
        : formatCompactCount(totals.tokens);
    final caption = TextStyle(
      fontSize: HermesType.captionSize,
      color: colors.textSecondary,
    );
    final guide = colors.textPrimary.withValues(alpha: 0.10);
    Widget guideLine(String text) => Row(
      children: [
        Expanded(child: Container(height: 1, color: guide)),
        const SizedBox(width: 8),
        Text(text, style: caption),
      ],
    );
    return _Panel(
      key: const ValueKey('usage-totals'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: caption.copyWith(
              color: picked != null ? colors.accentText : null,
              fontWeight: picked != null ? FontWeight.w600 : null,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            figure,
            style: TextStyle(
              fontSize: 40,
              height: 1.1,
              letterSpacing: -0.8,
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            picked != null
                ? (cost ? s.kluUsageCost : s.kluUsageTokens)
                : s.kluUsageSessionsCount(totals.sessions),
            style: caption,
          ),
          if (days.length > 1 && peak > 0) ...[
            const SizedBox(height: 18),
            guideLine(_format(peak)),
            SizedBox(
              key: const ValueKey('usage-daily'),
              height: 150,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // The bars stop short of the scale's figures at the end.
                  const scale = 44.0;
                  final width = constraints.maxWidth - scale;
                  return Stack(
                    children: [
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 75 - 8,
                        child: guideLine(_format(peak / 2)),
                      ),
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: width,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (d) => _pick(
                            d.localPosition.dx,
                            width,
                            days.length,
                            toggle: true,
                          ),
                          onHorizontalDragStart: (d) =>
                              _pick(d.localPosition.dx, width, days.length),
                          onHorizontalDragUpdate: (d) =>
                              _pick(d.localPosition.dx, width, days.length),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              for (var i = 0; i < values.length; i++)
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.bottomCenter,
                                    child: FractionallySizedBox(
                                      heightFactor: (values[i] / peak).clamp(
                                        0.025,
                                        1.0,
                                      ),
                                      widthFactor: 0.62,
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: picked == null
                                              ? colors.accent.withValues(
                                                  alpha: 0.85,
                                                )
                                              : picked == i
                                              ? colors.accent
                                              : colors.accent.withValues(
                                                  alpha: 0.28,
                                                ),
                                          borderRadius:
                                              const BorderRadius.vertical(
                                                top: Radius.circular(
                                                  HermesRadius.chip,
                                                ),
                                                bottom: Radius.circular(2),
                                              ),
                                        ),
                                        child: const SizedBox.expand(),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            Container(height: 1, color: guide),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(right: 44),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      _shortDay(context, days.first.day),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: caption,
                    ),
                  ),
                  // With large text the middle date has no room: the ends
                  // are enough to read the span.
                  if (days.length > 4 &&
                      MediaQuery.textScalerOf(context).scale(1) <= 1.3)
                    Text(
                      _shortDay(context, days[days.length ~/ 2].day),
                      style: caption,
                    ),
                  Flexible(
                    child: Text(
                      _shortDay(context, days.last.day),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: caption,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The plan limits, one panel per account: whose it is on top with its mark,
/// then each window on its own (name, what is left, a bar that empties as it
/// is used, when it resets). Accounts with nothing to show share one quiet
/// panel at the end.
class _LimitsView extends StatelessWidget {
  const _LimitsView({required this.limits, this.preferredProvider, super.key});

  final AccountUsageLimits limits;
  final String? preferredProvider;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final view = planLimitsView(
      limits,
      s,
      languageCode: Localizations.localeOf(context).languageCode,
      preferredProvider: preferredProvider?.trim().toLowerCase(),
    );
    final groups = <({String? title, List<PlanLimitRow> rows})>[];
    for (final row in view.rows) {
      if (row.heading) {
        groups.add((title: row.label, rows: <PlanLimitRow>[]));
      } else {
        if (groups.isEmpty) groups.add((title: null, rows: <PlanLimitRow>[]));
        groups.last.rows.add(row);
      }
    }
    bool quiet(({String? title, List<PlanLimitRow> rows}) g) =>
        g.rows.isEmpty ||
        g.rows.every(
          (r) => r.usedPercent == null && r.value == null && r.detail == null,
        );
    final live = [for (final g in groups) if (!quiet(g)) g];
    final idle = [for (final g in groups) if (quiet(g) && g.title != null) g];
    final caption = TextStyle(
      fontSize: HermesType.captionSize,
      color: colors.textSecondary,
    );
    Widget header(String title, {String? provider}) => Row(
      children: [
        _Badge(provider: provider ?? title),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: HermesType.textSize,
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
        ),
      ],
    );
    Widget window(PlanLimitRow row) {
      final used = row.usedPercent;
      final tone = used == null
          ? colors.textPrimary
          : used >= 100
          ? colors.error
          : used >= 80
          ? colors.warning
          : colors.success;
      return Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text(
                    row.label,
                    style: TextStyle(
                      fontSize: HermesType.textSize,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
                if (row.value case final value?)
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: tone,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
            if (used != null) ...[
              const SizedBox(height: 8),
              // What is left, as Hermes fills its own bars.
              ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: SizedBox(
                  height: 10,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: ColoredBox(
                          color: colors.textPrimary.withValues(alpha: 0.08),
                        ),
                      ),
                      FractionallySizedBox(
                        widthFactor: (1 - used / 100).clamp(0.0, 1.0),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: tone,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (row.detail case final detail?) ...[
              const SizedBox(height: 6),
              Text(detail, style: caption),
            ],
          ],
        ),
      );
    }

    // The `usage.bars` credits (Nous' billing view) are no window line:
    // their bars, in a panel of their own, where the model sheet put them.
    final credits = limits.bars.isEmpty && limits.renews == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(bottom: HermesSpace.x3),
            child: _Panel(
              key: const ValueKey('usage-limits-credits'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  header(
                    s.plv1215Credits,
                    provider: limits.creditsIdentity?.provider,
                  ),
                  const SizedBox(height: HermesSpace.x4),
                  AccountCreditBars(limits: limits),
                ],
              ),
            ),
          );
    final creditsFirst = AccountCreditBars.leads(limits, preferredProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (creditsFirst && credits != null) credits,
        for (final group in live)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Opacity(
              opacity: group.rows.any((r) => r.inUse) ? 1 : 0.62,
              child: _Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (group.title case final title?) header(title),
                    for (final row in group.rows) window(row),
                  ],
                ),
              ),
            ),
          ),
        if (!creditsFirst && credits != null) credits,
        for (final note in view.notes)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            child: Text(
              note,
              style: caption.copyWith(color: colors.warning),
            ),
          ),
        if (idle.isNotEmpty)
          Opacity(
            opacity: 0.62,
            child: _Panel(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final group in idle)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          _Badge(provider: group.title),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  group.title!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: HermesType.textSize,
                                    color: colors.textPrimary,
                                  ),
                                ),
                                Text(
                                  group.rows.isEmpty
                                      ? s.msvProviderNoUsage
                                      : group.rows.first.label,
                                  style: caption,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// The period's totals as a grid of small rounded tiles, each with its mark.
class _Totals extends StatelessWidget {
  const _Totals({required this.totals});

  final UsageTotals totals;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final cost = totals.cost;
    return Wrap(
      spacing: HermesSpace.x2,
      runSpacing: HermesSpace.x2,
      children: [
        _Stat(
          icon: HIcons.arrow_downward_rounded,
          label: s.kluUsageInput,
          value: formatCompactCount(totals.inputTokens),
        ),
        _Stat(
          icon: HIcons.arrow_upward_rounded,
          label: s.kluUsageOutput,
          value: formatCompactCount(totals.outputTokens),
        ),
        if (totals.cacheReadTokens > 0)
          _Stat(
            icon: HIcons.bolt_rounded,
            label: s.chaContextCacheRead,
            value: formatCompactCount(totals.cacheReadTokens),
          ),
        _Stat(
          icon: HIcons.forum_outlined,
          label: s.kluUsageSessions,
          value: '${totals.sessions}',
        ),
        if (cost > 0)
          _Stat(
            icon: HIcons.bar_chart_rounded,
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
  const _Stat({required this.icon, required this.label, required this.value});

  final IconData icon;
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
        child: _Panel(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: colors.accentText),
              const SizedBox(height: 10),
              Text(
                value,
                style: TextStyle(
                  fontSize: 22,
                  height: 1.15,
                  letterSpacing: -0.3,
                  fontWeight: FontWeight.w700,
                  color: colors.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: HermesType.captionSize,
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One line of a list panel: a provider badge, a name with a quiet detail
/// under it, the amount at the end and the share as a capsule bar below.
class _UsageRow extends StatelessWidget {
  const _UsageRow({
    required this.badge,
    required this.name,
    required this.detail,
    required this.amount,
    required this.fraction,
    required this.color,
  });

  final Widget badge;
  final String name;
  final String detail;
  final String amount;
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      container: true,
      label: '$name: $amount, $detail',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            badge,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: HermesType.textSize,
                            fontWeight: FontWeight.w600,
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        amount,
                        style: TextStyle(
                          fontSize: HermesType.textSize,
                          fontWeight: FontWeight.w600,
                          color: colors.textPrimary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _Share(fraction: fraction, color: color),
                  const SizedBox(height: 6),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: HermesType.captionSize,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The period by company: each model counted under the company its name
/// belongs to (the server's answer groups by model only).
class _ProviderRows extends StatelessWidget {
  const _ProviderRows({required this.models, required this.cost});

  final List<UsageModelRow> models;
  final bool cost;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final groups = <String, ({String model, int tokens, double cost, int sessions})>{};
    for (final row in models) {
      final label = resolveProviderLogo(model: row.model).label;
      final before = groups[label];
      groups[label] = (
        model: before?.model ?? row.model,
        tokens: (before?.tokens ?? 0) + row.tokens,
        cost: (before?.cost ?? 0) + row.estimatedCost,
        sessions: (before?.sessions ?? 0) + row.sessions,
      );
    }
    final entries = groups.entries.toList()
      ..sort((a, b) => b.value.tokens.compareTo(a.value.tokens));
    final total = entries.fold<int>(0, (sum, e) => sum + e.value.tokens);
    return _Panel(
      key: const ValueKey('usage-providers'),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final entry in entries.take(6))
            _UsageRow(
              badge: _Badge(model: entry.value.model),
              name: entry.key,
              detail: [
                _shareText(total <= 0 ? 0 : entry.value.tokens * 100 / total),
                if (cost)
                  formatCompactCount(entry.value.tokens)
                else if (entry.value.cost > 0)
                  formatUsageCost(entry.value.cost),
                s.kluUsageSessionsCount(entry.value.sessions),
              ].join(' · '),
              amount: cost
                  ? (entry.value.cost > 0
                        ? formatUsageCost(entry.value.cost)
                        : '—')
                  : formatCompactCount(entry.value.tokens),
              fraction: total <= 0 ? 0 : entry.value.tokens / total,
              color: colors.accent,
            ),
        ],
      ),
    );
  }
}

/// The models of the period, busiest first.
class _ModelRows extends StatelessWidget {
  const _ModelRows({required this.models, required this.cost});

  /// More than this and the list is a wall; the rest is the long tail.
  static const int shown = 12;

  final List<UsageModelRow> models;
  final bool cost;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final total = models.fold<int>(0, (sum, row) => sum + row.tokens);
    return _Panel(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in models.take(shown))
            _UsageRow(
              badge: _Badge(model: row.model),
              name: row.model,
              detail: [
                _shareText(total <= 0 ? 0 : row.tokens * 100 / total),
                if (cost)
                  formatCompactCount(row.tokens)
                else if (row.estimatedCost > 0)
                  formatUsageCost(row.estimatedCost),
                s.kluUsageSessionsCount(row.sessions),
              ].join(' · '),
              amount: cost
                  ? (row.estimatedCost > 0
                        ? formatUsageCost(row.estimatedCost)
                        : '—')
                  : formatCompactCount(row.tokens),
              fraction: total <= 0 ? 0 : row.tokens / total,
              color: colors.accent.withValues(alpha: 0.7),
            ),
        ],
      ),
    );
  }
}
