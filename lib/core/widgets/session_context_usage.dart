import 'package:hermes_android/core/design/hicons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/compaction_progress.dart';
import '../models/desktop_context_breakdown.dart';
import '../models/desktop_session_snapshot.dart';
import '../models/session.dart';
import '../design/tokens.dart' show HermesRadius, HermesType;
import '../theme/app_theme.dart';
import 'activity_pill.dart' show ActivityTicker, formatTurnElapsed;
import 'chat_status_pill.dart' show contextLevelColor;
import 'compaction_dock.dart';
import 'provider_logo.dart';

typedef SessionContextBreakdownLoader =
    Future<DesktopContextBreakdown?> Function();

/// The one UI projection shared by the chat trigger and its detail sheet.
///
/// Hermes remains authoritative: live values come from `session.info.usage`
/// and an opened sheet may replace them with `session.context_breakdown`.
/// Cumulative session tokens are deliberately not treated as current-window
/// occupancy when Hermes does not publish a real context window.
@immutable
class SessionContextMetrics {
  const SessionContextMetrics({
    this.contextUsed,
    this.contextMax,
    this.percent,
    this.cumulativeTotal,
    this.inputTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    this.cacheHitPercent,
    this.observedFirstTokenLatencyMs,
  });

  static const unknown = SessionContextMetrics();

  final int? contextUsed;
  final int? contextMax;
  final int? percent;
  final int? cumulativeTotal;
  final int? inputTokens;
  final int? cacheReadTokens;
  final int? cacheWriteTokens;

  /// The prompt-cache hit rate Hermes computed for the session (0-100), when
  /// its live usage says it; Desktop shows the same figure in its status bar
  /// (`lib/statusbar.tsx` `cacheHitLabel`).
  final int? cacheHitPercent;

  /// Tiempo observado por Android desde `ActiveChat.send()` hasta el primer
  /// contenido real. No se presenta como latencia pura del modelo.
  final int? observedFirstTokenLatencyMs;

  bool get hasWindow =>
      contextUsed != null && contextMax != null && contextMax! > 0;

  double? get cacheReadPercent {
    final read = cacheReadTokens;
    final input = inputTokens;
    if (read == null || input == null) return null;
    final prompt = input + read + (cacheWriteTokens ?? 0);
    return prompt <= 0 ? null : (read / prompt) * 100;
  }

  factory SessionContextMetrics.fromUsage(
    DesktopUsageStats? usage, {
    Session? sessionFallback,
    int? observedFirstTokenLatencyMs,
  }) {
    final used = usage?.contextUsed;
    final max = usage?.contextMax;
    final hasSessionUsage =
        sessionFallback != null &&
        (sessionFallback.inputTokens > 0 ||
            sessionFallback.outputTokens > 0 ||
            sessionFallback.cacheReadTokens != null ||
            sessionFallback.cacheWriteTokens != null);
    final livePublishesCache =
        usage?.cacheReadTokens != null || usage?.cacheWriteTokens != null;
    final useSessionPromptUsage = hasSessionUsage && !livePublishesCache;
    final common = (
      cumulativeTotal:
          usage?.total ??
          (hasSessionUsage ? sessionFallback.totalTokens : null),
      inputTokens: useSessionPromptUsage
          ? sessionFallback.inputTokens
          : usage?.input ??
                (hasSessionUsage ? sessionFallback.inputTokens : null),
      cacheReadTokens: livePublishesCache
          ? usage?.cacheReadTokens
          : sessionFallback?.cacheReadTokens,
      cacheWriteTokens: livePublishesCache
          ? usage?.cacheWriteTokens
          : sessionFallback?.cacheWriteTokens,
      cacheHitPercent: usage?.cacheHitPercent,
      observedFirstTokenLatencyMs: observedFirstTokenLatencyMs,
    );
    if (used == null || max == null || max <= 0) {
      return SessionContextMetrics(
        cumulativeTotal: common.cumulativeTotal,
        inputTokens: common.inputTokens,
        cacheReadTokens: common.cacheReadTokens,
        cacheWriteTokens: common.cacheWriteTokens,
        cacheHitPercent: common.cacheHitPercent,
        observedFirstTokenLatencyMs: common.observedFirstTokenLatencyMs,
      );
    }
    return SessionContextMetrics(
      contextUsed: used,
      contextMax: max,
      percent: _boundedContextPercent(
        supplied: usage?.contextPercent,
        used: used,
        max: max,
      ),
      cumulativeTotal: common.cumulativeTotal,
      inputTokens: common.inputTokens,
      cacheReadTokens: common.cacheReadTokens,
      cacheWriteTokens: common.cacheWriteTokens,
      cacheHitPercent: common.cacheHitPercent,
      observedFirstTokenLatencyMs: common.observedFirstTokenLatencyMs,
    );
  }

  factory SessionContextMetrics.fromSession(
    Session session, {
    int? observedFirstTokenLatencyMs,
  }) => SessionContextMetrics(
    cumulativeTotal: session.totalTokens,
    inputTokens: session.inputTokens,
    cacheReadTokens: session.cacheReadTokens,
    cacheWriteTokens: session.cacheWriteTokens,
    observedFirstTokenLatencyMs: observedFirstTokenLatencyMs,
  );

  /// Desktop prefers an on-demand breakdown while its panel is open. A
  /// response without a real window keeps the live summary instead of turning
  /// a known value into a fabricated zero-window gauge.
  factory SessionContextMetrics.fromBreakdown(
    DesktopContextBreakdown breakdown, {
    SessionContextMetrics fallback = unknown,
  }) {
    if (breakdown.contextMax <= 0) return fallback;
    return SessionContextMetrics(
      contextUsed: breakdown.contextUsed,
      contextMax: breakdown.contextMax,
      percent: _boundedContextPercent(
        supplied: breakdown.contextPercent.toDouble(),
        used: breakdown.contextUsed,
        max: breakdown.contextMax,
      ),
      cumulativeTotal: fallback.cumulativeTotal,
      inputTokens: fallback.inputTokens,
      cacheReadTokens: fallback.cacheReadTokens,
      cacheWriteTokens: fallback.cacheWriteTokens,
      cacheHitPercent: fallback.cacheHitPercent,
      observedFirstTokenLatencyMs: fallback.observedFirstTokenLatencyMs,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionContextMetrics &&
          contextUsed == other.contextUsed &&
          contextMax == other.contextMax &&
          percent == other.percent &&
          cumulativeTotal == other.cumulativeTotal &&
          inputTokens == other.inputTokens &&
          cacheReadTokens == other.cacheReadTokens &&
          cacheWriteTokens == other.cacheWriteTokens &&
          cacheHitPercent == other.cacheHitPercent &&
          observedFirstTokenLatencyMs == other.observedFirstTokenLatencyMs;

  @override
  int get hashCode => Object.hash(
    contextUsed,
    contextMax,
    percent,
    cumulativeTotal,
    inputTokens,
    cacheReadTokens,
    cacheWriteTokens,
    cacheHitPercent,
    observedFirstTokenLatencyMs,
  );
}

int _boundedContextPercent({
  required double? supplied,
  required int used,
  required int max,
}) {
  final raw = supplied != null && supplied.isFinite
      ? supplied
      : (used / max) * 100;
  return raw.round().clamp(0, 100).toInt();
}

String? _cumulativeTokenLabel(SessionContextMetrics metrics) {
  final cumulative = metrics.cumulativeTotal;
  return cumulative == null
      ? null
      : '${compactSessionContextTokens(cumulative)} tok';
}

/// Short text of the context trigger: `45%`, else cumulative tokens, else `—`.
String sessionContextTriggerText(SessionContextMetrics metrics) {
  final percent = metrics.percent;
  if (percent != null) return '$percent%';
  return _cumulativeTokenLabel(metrics) ?? '—';
}

String _contextTriggerSemanticValue(
  Strings strings,
  SessionContextMetrics metrics,
) {
  final percent = metrics.percent;
  if (percent != null) return strings.chaContextUsagePercent(percent);
  return _cumulativeTokenLabel(metrics) ?? strings.chaContextWindowUnavailable;
}

/// Accessible label of the context trigger (description + best value).
String sessionContextTriggerSemanticsLabel(
  Strings strings,
  SessionContextMetrics metrics,
) {
  final value = _contextTriggerSemanticValue(strings, metrics);
  return '${strings.chaContextUsageOpen}, $value';
}

/// Compact AI-Elements-inspired trigger. Only this subtree listens to live
/// context changes, so a new percentage does not rebuild the transcript.
class SessionContextTrigger extends StatelessWidget {
  const SessionContextTrigger({
    required this.metrics,
    required this.onPressed,
    super.key,
  });

  final ValueListenable<SessionContextMetrics> metrics;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SessionContextMetrics>(
      valueListenable: metrics,
      builder: (context, value, _) {
        final strings = Strings.of(context);
        final percent = value.percent;
        return Semantics(
          button: true,
          onTap: onPressed,
          label: sessionContextTriggerSemanticsLabel(strings, value),
          excludeSemantics: true,
          child: Tooltip(
            message: strings.chaContextUsageOpen,
            child: InkResponse(
              key: const ValueKey('desktop-context-usage-status'),
              onTap: onPressed,
              radius: 26,
              containedInkWell: true,
              highlightShape: BoxShape.rectangle,
              customBorder: const StadiumBorder(),
              child: SizedBox(
                width: 62,
                height: 48,
                child: Center(
                  child: Container(
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).hermes.surfaceVariant.withValues(alpha: 0.52),
                      borderRadius: BorderRadius.circular(17),
                      border: Border.all(
                        color: Theme.of(
                          context,
                        ).hermes.divider.withValues(alpha: 0.66),
                      ),
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SessionContextRing(
                            percent: percent,
                            size: 18,
                            strokeWidth: 2.1,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            sessionContextTriggerText(value),
                            style: TextStyle(
                              color: Theme.of(context).hermes.textPrimary,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class SessionContextRing extends StatelessWidget {
  const SessionContextRing({
    required this.percent,
    this.size = 24,
    this.strokeWidth = 2.4,
    this.color,
    super.key,
  });

  final int? percent;
  final double size;
  final double strokeWidth;

  /// Arc colour; the theme accent when null.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: CircularProgressIndicator(
          value: (percent ?? 0) / 100,
          strokeWidth: strokeWidth,
          strokeCap: StrokeCap.round,
          color: color ?? colors.accentText,
          backgroundColor: colors.divider.withValues(alpha: 0.72),
        ),
      ),
    );
  }
}

/// Body of the «Uso de contexto» sheet: the mobile counterpart of Hermes
/// Desktop's ContextUsagePanel.
///
/// It performs exactly one breakdown request per opening and stays a snapshot
/// while open, matching Desktop; it never polls during streaming. The
/// breakdown only appears when Hermes publishes it; otherwise the honest
/// notice explains why.
class SessionContextSheetBody extends StatefulWidget {
  const SessionContextSheetBody({
    required this.metrics,
    required this.loadBreakdown,
    required this.onMetricsSnapshot,
    this.onCompact,
    this.compaction,
    this.clock,
    this.model,
    this.provider,
    this.onOpenAllUsage,
    super.key,
  });

  /// Opens the server-wide usage screen; null hides the link.
  final VoidCallback? onOpenAllUsage;

  /// The session's model and provider, for the «Modelo» section; null hides
  /// the row.
  final String? model;
  final String? provider;

  final ValueListenable<SessionContextMetrics> metrics;
  final SessionContextBreakdownLoader loadBreakdown;
  final ValueChanged<SessionContextMetrics> onMetricsSnapshot;

  /// Runs the chat's existing `/compress`; null hides «Compactar».
  final VoidCallback? onCompact;

  /// Compaction running or just finished; its full facts head the sheet.
  final ValueListenable<CompactionProgress?>? compaction;
  final DateTime Function()? clock;

  @override
  State<SessionContextSheetBody> createState() =>
      _SessionContextSheetBodyState();
}

class _SessionContextSheetBodyState extends State<SessionContextSheetBody> {
  DesktopContextBreakdown? _breakdown;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadOnce();
  }

  Future<void> _loadOnce() async {
    try {
      final breakdown = await widget.loadBreakdown();
      if (!mounted) return;
      _breakdown = breakdown;
      if (breakdown != null) {
        widget.onMetricsSnapshot(
          SessionContextMetrics.fromBreakdown(
            breakdown,
            fallback: widget.metrics.value,
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      _error = error;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: const ValueKey('desktop-context-usage-popover'),
      child: ValueListenableBuilder<SessionContextMetrics>(
        valueListenable: widget.metrics,
        builder: (context, liveMetrics, _) {
          final metrics = _breakdown == null
              ? liveMetrics
              : SessionContextMetrics.fromBreakdown(
                  _breakdown!,
                  fallback: liveMetrics,
                );
          Widget contents(CompactionProgress? progress) => _PanelContents(
            metrics: metrics,
            breakdown: _breakdown,
            loading: _loading,
            error: _error,
            onCompact: widget.onCompact,
            compaction: progress,
            clock: widget.clock,
            model: widget.model,
            provider: widget.provider,
            onOpenAllUsage: widget.onOpenAllUsage,
          );
          final compaction = widget.compaction;
          if (compaction == null) return contents(null);
          return ValueListenableBuilder<CompactionProgress?>(
            valueListenable: compaction,
            builder: (context, progress, _) => contents(progress),
          );
        },
      ),
    );
  }
}

class _PanelContents extends StatelessWidget {
  const _PanelContents({
    required this.metrics,
    required this.breakdown,
    required this.loading,
    required this.error,
    required this.onCompact,
    this.compaction,
    this.clock,
    this.model,
    this.provider,
    this.onOpenAllUsage,
  });

  final VoidCallback? onOpenAllUsage;
  final String? model;
  final String? provider;
  final SessionContextMetrics metrics;
  final DesktopContextBreakdown? breakdown;
  final bool loading;
  final Object? error;
  final VoidCallback? onCompact;
  final CompactionProgress? compaction;
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final compaction = this.compaction;
    final categories = breakdown?.categories ?? const [];
    final busy = compaction != null && !compaction.isFinished;
    final modelName = (model ?? '').trim();
    final providerName = (provider ?? '').trim();
    // Three soft panels with air between them (the owner, 2026-11-18): the
    // context with its figure and bar, the model as one line with its mark,
    // the session's figures as small tiles. Few words: a figure Hermes has
    // not published is a dash, not a sentence.
    // The small «compress» button of the context panel.
    Widget compress() =>
      Material(
        color: colors.textPrimary.withValues(alpha: 0.08),
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('context-compress-now'),
          onTap: busy ? null : onCompact,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 9,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  HIcons.compress_rounded,
                  size: 16,
                  color: busy
                      ? colors.textTertiary
                      : colors.accentText,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    busy
                        ? strings.sp1215CompactBusy
                        : strings.sp1215Compact,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: busy
                          ? colors.textTertiary
                          : colors.accentText,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (compaction != null) ...[
          _CompactionPanelRow(compaction: compaction, clock: clock),
          const SizedBox(height: 12),
        ],
        _SoftPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onCompact == null)
                _ContextOverview(metrics: metrics)
              else if (MediaQuery.textScalerOf(context).scale(1) > 1.3)
                // Large text: the figure keeps the full width and the button
                // goes under it, instead of squeezing the figure to nothing.
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ContextOverview(metrics: metrics),
                    const SizedBox(height: 12),
                    compress(),
                  ],
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: _ContextOverview(metrics: metrics)),
                    const SizedBox(width: 12),
                    compress(),
                  ],
                ),
              if (categories.isNotEmpty) ...[
                const SizedBox(height: 14),
                SessionContextBreakdown(
                  categories: categories,
                  window: metrics.contextMax,
                ),
              ] else if (loading) ...[
                const SizedBox(height: 12),
                _ContextNotice(
                  icon: HIcons.hourglass_top_rounded,
                  text: strings.chaContextUsageLoading,
                ),
              ] else if (error != null) ...[
                const SizedBox(height: 12),
                _ContextNotice(
                  icon: HIcons.sync_problem_rounded,
                  text: strings.chaContextUsageError,
                ),
              ],
            ],
          ),
        ),
        if (modelName.isNotEmpty || providerName.isNotEmpty) ...[
          const SizedBox(height: 12),
          _SoftPanel(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.textPrimary.withValues(alpha: 0.08),
                  ),
                  child: SizedBox.square(
                    dimension: 38,
                    child: Center(
                      child: ProviderLogo(
                        provider: providerName.isEmpty ? null : providerName,
                        model: modelName.isEmpty ? null : modelName,
                        size: 20,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (modelName.isNotEmpty)
                        Text(
                          modelName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: colors.textPrimary,
                          ),
                        ),
                      if (providerName.isNotEmpty)
                        Text(
                          providerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: colors.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        SessionContextPerformance(metrics: metrics),
        if (onOpenAllUsage != null) ...[
          const SizedBox(height: 12),
          Material(
            color: colors.textPrimary.withValues(alpha: 0.055),
            borderRadius: BorderRadius.circular(HermesRadius.card),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('session-usage-see-all'),
              onTap: onOpenAllUsage,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Icon(
                      HIcons.bar_chart_rounded,
                      size: 20,
                      color: colors.accentText,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        strings.kluUsageSeeAll,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    Icon(
                      HIcons.chevron_right_rounded,
                      size: 20,
                      color: colors.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A soft rounded panel: no rim, a quiet fill.
class _SoftPanel extends StatelessWidget {
  const _SoftPanel({
    required this.child,
    this.padding = const EdgeInsets.all(18),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.textPrimary.withValues(alpha: 0.055),
        borderRadius: BorderRadius.circular(HermesRadius.card),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// The compaction's full facts at the top of the context panel: the same
/// outcome text the old floating pill showed («Compactado · 34 → 12
/// mensajes · …») or «Compactando · 22 msj · ~21.5k tok» with the measured
/// clock. Only what Hermes published; no estimate.
class _CompactionPanelRow extends StatelessWidget {
  const _CompactionPanelRow({required this.compaction, this.clock});

  final CompactionProgress compaction;
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final lang = Localizations.localeOf(context).languageCode;
    final finished = compaction.isFinished;
    return Container(
      key: const ValueKey('context-panel-compaction'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider.withValues(alpha: 0.7)),
      ),
      child: ActivityTicker(
        active: !finished,
        clock: clock,
        builder: (context, now) => Row(
          children: [
            CompactionGlyph(compaction: compaction),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                compactionStatusText(strings, compaction, lang),
                key: const ValueKey('context-panel-compaction-text'),
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
            ),
            if (!finished) ...[
              const SizedBox(width: 8),
              ExcludeSemantics(
                child: Text(
                  formatTurnElapsed(compaction.elapsed(now)),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Proyección reutilizable de rendimiento y caché. Tanto el chat como Detalles
/// de sesión reciben estos valores desde [SessionContextMetrics], evitando dos
/// fórmulas o tratamientos distintos de los campos ausentes.
class SessionContextPerformance extends StatelessWidget {
  const SessionContextPerformance({required this.metrics, super.key});

  final SessionContextMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final cumulative = metrics.cumulativeTotal;
    final read = metrics.cacheReadTokens;
    final write = metrics.cacheWriteTokens;
    final latency = metrics.observedFirstTokenLatencyMs;
    // Hermes' own rate when it sent one, else the share of the read tokens.
    final cacheHit = metrics.cacheHitPercent;
    final cachePercent = metrics.cacheReadPercent;
    String ttft(int ms) =>
        ms >= 1000 ? '${(ms / 1000).toStringAsFixed(1)} s' : '$ms ms';
    final tiles = <(IconData, String, String)>[
      (
        HIcons.forum_outlined,
        cumulative == null ? '—' : compactSessionContextTokens(cumulative),
        strings.kluUsageTokens,
      ),
      (HIcons.bolt_rounded, latency == null ? '—' : ttft(latency), 'TTFT'),
      (
        HIcons.arrow_downward_rounded,
        read == null ? '—' : compactSessionContextTokens(read),
        strings.chaContextCacheRead,
      ),
      (
        HIcons.arrow_upward_rounded,
        write == null ? '—' : compactSessionContextTokens(write),
        strings.chaContextCacheWrite,
      ),
      if (cacheHit != null || cachePercent != null)
        (
          HIcons.bar_chart_rounded,
          cacheHit != null
              ? '$cacheHit %'
              : '${cachePercent!.toStringAsFixed(1)} %',
          strings.sesMetricCachePercent,
        ),
    ];
    return Semantics(
      container: true,
      child: LayoutBuilder(
        key: const ValueKey('session-context-performance'),
        builder: (context, constraints) {
          const gap = 10.0;
          final width = (constraints.maxWidth - gap) / 2;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final (icon, value, label) in tiles)
                SizedBox(
                  width: width,
                  child: Semantics(
                    container: true,
                    label: '$label: $value',
                    excludeSemantics: true,
                    child: _SoftPanel(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(icon, size: 18, color: colors.accentText),
                          const SizedBox(height: 8),
                          Text(
                            value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 20,
                              height: 1.15,
                              fontWeight: FontWeight.w700,
                              color: colors.textPrimary,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
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
        },
      ),
    );
  }
}

class _ContextOverview extends StatelessWidget {
  const _ContextOverview({required this.metrics});

  final SessionContextMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final used = metrics.contextUsed;
    final max = metrics.contextMax;
    final percent = metrics.percent;
    final known =
        metrics.hasWindow && used != null && max != null && percent != null;
    final level = contextLevelColor(percent, colors);
    final summary = known
        ? '${strings.chaContextUsageSummary(compactSessionContextTokens(used), compactSessionContextTokens(max))}. '
              '${strings.chaContextUsagePercent(percent)}'
        : strings.chaContextWindowUnavailable;
    if (!known) {
      // Not published yet: a dash where the figure goes, the sentence only
      // for assistive tech.
      return Semantics(
        container: true,
        label: summary,
        excludeSemantics: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '—',
              style: TextStyle(
                fontSize: HermesType.figureSize,
                fontWeight: FontWeight.w700,
                color: colors.textTertiary,
              ),
            ),
            Text(
              strings.plv1215Unavailable,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
            ),
          ],
        ),
      );
    }
    // «68K de 500K tokens» with the figure large, the share at the end.
    // Figures, not words: «67.7k / 500k».
    final figure = compactSessionContextTokens(used);
    final rest = ' / ${compactSessionContextTokens(max)}';
    return Semantics(
      container: true,
      label: summary,
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          // Large text on a narrow sheet: the figure shrinks to fit rather
          // than push the share off the panel.
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    figure,
                    key: const ValueKey('context-sheet-ring'),
                    style: TextStyle(
                      fontSize: HermesType.figureSize,
                      fontWeight: FontWeight.w700,
                      color: colors.textPrimary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    rest,
                    maxLines: 1,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '$percent%',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: level,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class SessionContextBreakdown extends StatelessWidget {
  const SessionContextBreakdown({
    required this.categories,
    this.window,
    super.key,
  });

  final List<DesktopContextUsageCategory> categories;

  /// The context window; the bar then shows how much of it is taken, as the
  /// official app's does.
  final int? window;

  @override
  Widget build(BuildContext context) {
    final total = categories.fold<int>(0, (sum, item) => sum + item.tokens);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SegmentedContextBar(
          categories: categories,
          total: window != null && window! > total ? window! : total,
        ),
        const SizedBox(height: 14),
        for (var index = 0; index < categories.length; index++) ...[
          _ContextCategoryRow(
            category: categories[index],
            color: _categoryColor(context, categories[index].id, index),
          ),
          if (index != categories.length - 1) const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _SegmentedContextBar extends StatelessWidget {
  const _SegmentedContextBar({required this.categories, required this.total});

  final List<DesktopContextUsageCategory> categories;
  final int total;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return ExcludeSemantics(
      child: Container(
        key: const ValueKey('session-context-segmented-bar'),
        height: 7,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: colors.divider.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(99),
        ),
        child: total <= 0
            ? null
            : LayoutBuilder(
                builder: (context, constraints) {
                  var left = 0.0;
                  final segments = <Widget>[];
                  for (var index = 0; index < categories.length; index++) {
                    final category = categories[index];
                    final width =
                        constraints.maxWidth * category.tokens / total;
                    segments.add(
                      Positioned(
                        left: left,
                        width: width < 1 ? 1 : width,
                        top: 0,
                        bottom: 0,
                        child: ColoredBox(
                          color: _categoryColor(context, category.id, index),
                        ),
                      ),
                    );
                    left += width;
                  }
                  return Stack(children: segments);
                },
              ),
      ),
    );
  }
}

class _ContextCategoryRow extends StatelessWidget {
  const _ContextCategoryRow({required this.category, required this.color});

  final DesktopContextUsageCategory category;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final label = _categoryLabel(Strings.of(context), category);
    final value = compactSessionContextTokens(category.tokens);
    return MergeSemantics(
      child: Semantics(
        label: '$label, $value',
        excludeSemantics: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stack =
                constraints.maxWidth < 300 ||
                MediaQuery.textScalerOf(context).scale(12) >= 19;
            final marker = Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            );
            final labelWidget = Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.textPrimary),
            );
            final valueWidget = Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            );
            if (stack) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: marker,
                      ),
                      const SizedBox(width: 9),
                      Expanded(child: labelWidget),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Padding(
                    padding: const EdgeInsets.only(left: 18),
                    child: valueWidget,
                  ),
                ],
              );
            }
            return Row(
              children: [
                marker,
                const SizedBox(width: 9),
                Expanded(child: labelWidget),
                const SizedBox(width: 12),
                valueWidget,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ContextNotice extends StatelessWidget {
  const _ContextNotice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      container: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: colors.textSecondary),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _categoryLabel(Strings strings, DesktopContextUsageCategory category) =>
    switch (category.id) {
      'system_prompt' => strings.chaContextCategorySystem,
      'tool_definitions' => strings.chaContextCategoryTools,
      'rules' => strings.chaContextCategoryRules,
      'skills' => strings.chaContextCategorySkills,
      'mcp' => strings.chaContextCategoryMcp,
      'subagent_definitions' => strings.chaContextCategorySubagents,
      'memory' => strings.chaContextCategoryMemory,
      'conversation' => strings.chaContextCategoryConversation,
      _ => category.label,
    };

Color _categoryColor(BuildContext context, String id, int index) {
  final colors = Theme.of(context).hermes;
  return switch (id) {
    'system_prompt' => colors.accentText,
    'tool_definitions' => colors.secondary,
    'rules' => colors.warning,
    'skills' => colors.success,
    'mcp' => Color.lerp(colors.accentText, colors.secondary, 0.5)!,
    'subagent_definitions' => Color.lerp(colors.warning, colors.error, 0.35)!,
    'memory' => Color.lerp(colors.success, colors.accentText, 0.45)!,
    'conversation' => colors.textSecondary,
    _ => [
      colors.accentText,
      colors.secondary,
      colors.success,
      colors.warning,
      colors.textSecondary,
    ][index % 5],
  };
}

/// Matches Hermes Desktop's shared compact-number formatter.
@visibleForTesting
String compactSessionContextTokens(int value) => formatCompactTokens(value);
