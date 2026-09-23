import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/compaction_progress.dart';
import '../models/desktop_context_breakdown.dart';
import '../models/desktop_session_snapshot.dart';
import '../models/session.dart';
import '../theme/app_theme.dart';

typedef SessionContextBreakdownLoader =
    Future<DesktopContextBreakdown?> Function();

/// Builds an optional extra section appended to the popover's content — used
/// by the chat screen to fold its approval-mode radio list into the same
/// surface the combined context+mode pill opens, instead of a second sheet.
/// [closePopover] dismisses this popover; callers invoke it before applying a
/// selection, mirroring how the standalone mode sheet pops itself first.
typedef SessionContextModeSectionBuilder =
    Widget Function(BuildContext context, VoidCallback closePopover);

Future<void> showSessionContextPopover({
  required BuildContext context,
  required Rect anchorRect,
  required ValueListenable<SessionContextMetrics> metrics,
  required SessionContextBreakdownLoader loadBreakdown,
  required ValueChanged<SessionContextMetrics> onMetricsSnapshot,
  SessionContextModeSectionBuilder? modeSectionBuilder,
}) {
  final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  final navigator = Navigator.of(context);
  return showGeneralDialog<void>(
    context: context,
    useRootNavigator: false,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.22),
    transitionDuration: reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 180),
    pageBuilder: (dialogContext, animation, secondaryAnimation) =>
        _SessionContextPopoverFrame(
          anchorRect: anchorRect,
          metrics: metrics,
          loadBreakdown: loadBreakdown,
          onMetricsSnapshot: onMetricsSnapshot,
          modeSectionBuilder: modeSectionBuilder,
          onClose: navigator.pop,
        ),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      if (reduceMotion) return child;
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          alignment: Alignment.topCenter,
          scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _SessionContextPopoverFrame extends StatelessWidget {
  const _SessionContextPopoverFrame({
    required this.anchorRect,
    required this.metrics,
    required this.loadBreakdown,
    required this.onMetricsSnapshot,
    required this.onClose,
    this.modeSectionBuilder,
  });

  final Rect anchorRect;
  final ValueListenable<SessionContextMetrics> metrics;
  final SessionContextBreakdownLoader loadBreakdown;
  final ValueChanged<SessionContextMetrics> onMetricsSnapshot;
  final VoidCallback onClose;
  final SessionContextModeSectionBuilder? modeSectionBuilder;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final colors = Theme.of(context).hermes;
    const margin = 12.0;
    const gap = 6.0;
    final width = (media.size.width - margin * 2).clamp(288.0, 360.0);
    // Centrado sobre la píldora que lo abre, no anclado por su borde derecho
    // (eso lo hacía abrir sesgado hacia la izquierda en vez de crecer desde
    // el centro de la píldora).
    final left = (anchorRect.center.dx - width / 2)
        .clamp(margin, math.max(margin, media.size.width - width - margin))
        .toDouble();
    final belowTop = anchorRect.bottom + gap;
    final belowHeight =
        media.size.height - media.padding.bottom - belowTop - margin;
    final aboveHeight = anchorRect.top - media.padding.top - margin - gap;
    final placeBelow = belowHeight >= math.min(280.0, aboveHeight);
    final availableHeight = math.max(
      220.0,
      placeBelow ? belowHeight : aboveHeight,
    );
    final maxHeight = math.min(520.0, availableHeight).toDouble();

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: onClose,
          ),
        ),
        Positioned(
          left: left,
          top: placeBelow ? belowTop : null,
          bottom: placeBelow ? null : media.size.height - anchorRect.top + gap,
          width: width,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Material(
              key: const ValueKey('desktop-context-usage-popover-surface'),
              color: colors.surface,
              surfaceTintColor: Colors.transparent,
              elevation: 12,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: colors.divider.withValues(alpha: 0.78)),
              ),
              clipBehavior: Clip.antiAlias,
              child: SessionContextFloatingPanel(
                width: width,
                maxHeight: maxHeight,
                metrics: metrics,
                loadBreakdown: loadBreakdown,
                onMetricsSnapshot: onMetricsSnapshot,
                onClose: onClose,
                modeSectionBuilder: modeSectionBuilder,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

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
      observedFirstTokenLatencyMs: observedFirstTokenLatencyMs,
    );
    if (used == null || max == null || max <= 0) {
      return SessionContextMetrics(
        cumulativeTotal: common.cumulativeTotal,
        inputTokens: common.inputTokens,
        cacheReadTokens: common.cacheReadTokens,
        cacheWriteTokens: common.cacheWriteTokens,
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

String _contextTriggerText(SessionContextMetrics metrics) {
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

String _contextTriggerSemanticsLabel(
  Strings strings,
  SessionContextMetrics metrics,
) {
  final value = _contextTriggerSemanticValue(strings, metrics);
  return '${strings.chaContextUsageOpen}, $value';
}

/// Anchored context+mode control. Was two separate app-bar widgets (a
/// context-usage ring trigger plus a colored approval-mode pill); the
/// 1.2.11 redesign merges both into one compact floating pill — ring,
/// percentage, and (only when the mode isn't the plain default) a small
/// red-flag segment — that now lives below the composer instead of in
/// `actions:`. Still opens the same [showSessionContextPopover]; when
/// [modeSectionBuilder] is given, that popover also grows an approval-mode
/// section built from it, so mode selection is reachable from the same
/// surface without duplicating the mode-radio-list logic that already lives
/// in the chat screen.
class SessionContextPopoverButton extends StatefulWidget {
  const SessionContextPopoverButton({
    required this.metrics,
    required this.loadBreakdown,
    required this.onMetricsSnapshot,
    this.modeLabel,
    this.modeColor,
    this.modeSectionBuilder,
    this.compressionCount = 0,
    super.key,
  });

  final ValueListenable<SessionContextMetrics> metrics;
  final SessionContextBreakdownLoader loadBreakdown;
  final ValueChanged<SessionContextMetrics> onMetricsSnapshot;

  /// Non-null only when the approval mode is worth flagging (YOLO / read-only
  /// / a per-session override) — same "prominent" gate the old app-bar mode
  /// pill used. Null hides the mode segment entirely.
  final String? modeLabel;
  final Color? modeColor;
  final SessionContextModeSectionBuilder? modeSectionBuilder;

  /// How many times this session has ever been compacted (0 hides the
  /// segment). A durable fact of the session, unlike the transient
  /// in-progress/just-finished compaction dock — this is the only place that
  /// says so once the dock itself is long gone.
  final int compressionCount;

  @override
  State<SessionContextPopoverButton> createState() =>
      _SessionContextPopoverButtonState();
}

class _SessionContextPopoverButtonState
    extends State<SessionContextPopoverButton> {
  final GlobalKey _anchorKey = GlobalKey();
  bool _opening = false;

  Future<void> _open() async {
    if (_opening) return;
    final renderBox = _anchorKey.currentContext?.findRenderObject();
    if (renderBox is! RenderBox || !renderBox.hasSize) return;
    final topLeft = renderBox.localToGlobal(Offset.zero);
    final anchorRect = topLeft & renderBox.size;
    _opening = true;
    try {
      await showSessionContextPopover(
        context: context,
        anchorRect: anchorRect,
        metrics: widget.metrics,
        loadBreakdown: widget.loadBreakdown,
        onMetricsSnapshot: widget.onMetricsSnapshot,
        modeSectionBuilder: widget.modeSectionBuilder,
      );
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Padding(
      key: _anchorKey,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: ValueListenableBuilder<SessionContextMetrics>(
        valueListenable: widget.metrics,
        builder: (context, value, _) {
          final percent = value.percent;
          final semanticsLabel = [
            _contextTriggerSemanticsLabel(strings, value),
            ?widget.modeLabel,
            if (widget.compressionCount > 0)
              strings.chaSessionCompactedTooltip(widget.compressionCount),
          ].join(' · ');
          final modeLabel = widget.modeLabel;
          return Semantics(
            button: true,
            onTap: _open,
            label: semanticsLabel,
            excludeSemantics: true,
            child: Tooltip(
              message: strings.chaContextUsageOpen,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  key: const ValueKey('desktop-context-usage-status'),
                  onTap: _open,
                  customBorder: const StadiumBorder(),
                  child: Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: colors.surfaceVariant.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: colors.divider.withValues(alpha: 0.7),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.24),
                          blurRadius: 14,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SessionContextRing(
                          percent: percent,
                          size: 14,
                          strokeWidth: 2,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          _contextTriggerText(value),
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        if (modeLabel != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            height: 12,
                            width: 1,
                            color: colors.divider,
                          ),
                          const SizedBox(width: 6),
                          Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              color: widget.modeColor ?? colors.error,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            modeLabel,
                            style: TextStyle(
                              color: widget.modeColor ?? colors.error,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                        if (widget.compressionCount > 0) ...[
                          const SizedBox(width: 6),
                          Container(
                            height: 12,
                            width: 1,
                            color: colors.divider,
                          ),
                          const SizedBox(width: 6),
                          Tooltip(
                            message: strings.chaSessionCompactedTooltip(
                              widget.compressionCount,
                            ),
                            child: Icon(
                              Icons.compress_rounded,
                              size: 13,
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
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
          label: _contextTriggerSemanticsLabel(strings, value),
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
                            _contextTriggerText(value),
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
    super.key,
  });

  final int? percent;
  final double size;
  final double strokeWidth;

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
          color: colors.accentText,
          backgroundColor: colors.divider.withValues(alpha: 0.72),
        ),
      ),
    );
  }
}

/// Anchored mobile counterpart of Hermes Desktop's ContextUsagePanel.
///
/// The panel performs exactly one breakdown request per opening. It remains a
/// snapshot while open, matching Desktop, and never polls during streaming.
class SessionContextFloatingPanel extends StatefulWidget {
  const SessionContextFloatingPanel({
    required this.width,
    required this.maxHeight,
    required this.metrics,
    required this.loadBreakdown,
    required this.onMetricsSnapshot,
    required this.onClose,
    this.modeSectionBuilder,
    super.key,
  });

  final double width;
  final double maxHeight;
  final ValueListenable<SessionContextMetrics> metrics;
  final SessionContextBreakdownLoader loadBreakdown;
  final ValueChanged<SessionContextMetrics> onMetricsSnapshot;
  final VoidCallback onClose;
  final SessionContextModeSectionBuilder? modeSectionBuilder;

  @override
  State<SessionContextFloatingPanel> createState() =>
      _SessionContextFloatingPanelState();
}

class _SessionContextFloatingPanelState
    extends State<SessionContextFloatingPanel> {
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
    return ConstrainedBox(
      key: const ValueKey('desktop-context-usage-popover'),
      constraints: BoxConstraints(
        minWidth: widget.width,
        maxWidth: widget.width,
        maxHeight: widget.maxHeight,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final horizontal = constraints.maxWidth < 330 ? 14.0 : 16.0;
          return SingleChildScrollView(
            primary: false,
            padding: EdgeInsets.fromLTRB(horizontal, 12, horizontal, 18),
            child: ValueListenableBuilder<SessionContextMetrics>(
              valueListenable: widget.metrics,
              builder: (context, liveMetrics, _) {
                final metrics = _breakdown == null
                    ? liveMetrics
                    : SessionContextMetrics.fromBreakdown(
                        _breakdown!,
                        fallback: liveMetrics,
                      );
                return _PanelContents(
                  metrics: metrics,
                  breakdown: _breakdown,
                  loading: _loading,
                  error: _error,
                  onClose: widget.onClose,
                  modeSectionBuilder: widget.modeSectionBuilder,
                );
              },
            ),
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
    required this.onClose,
    this.modeSectionBuilder,
  });

  final SessionContextMetrics metrics;
  final DesktopContextBreakdown? breakdown;
  final bool loading;
  final Object? error;
  final VoidCallback onClose;
  final SessionContextModeSectionBuilder? modeSectionBuilder;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final categories = breakdown?.categories ?? const [];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  strings.chaContextUsageTitle,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: strings.commonClose,
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _ContextOverview(metrics: metrics),
        const SizedBox(height: 10),
        SessionContextPerformance(metrics: metrics),
        const SizedBox(height: 14),
        if (categories.isNotEmpty) ...[
          SessionContextBreakdown(categories: categories),
        ] else if (loading)
          _ContextNotice(
            icon: Icons.hourglass_top_rounded,
            text: strings.chaContextUsageLoading,
          )
        else if (error != null)
          _ContextNotice(
            icon: Icons.sync_problem_rounded,
            text: strings.chaContextUsageError,
          )
        else if (breakdown == null)
          _ContextNotice(
            icon: Icons.info_outline_rounded,
            text: strings.chaContextUsageUnavailable,
          )
        else
          _ContextNotice(
            icon: Icons.layers_clear_outlined,
            text: strings.chaContextUsageEmpty,
          ),
        if (modeSectionBuilder != null) ...[
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 10),
          modeSectionBuilder!(context, onClose),
        ],
      ],
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
    final cumulative = metrics.cumulativeTotal;
    final read = metrics.cacheReadTokens;
    final write = metrics.cacheWriteTokens;
    final latency = metrics.observedFirstTokenLatencyMs;
    final cachePercent = metrics.cacheReadPercent;
    return Semantics(
      container: true,
      child: Column(
        key: const ValueKey('session-context-performance'),
        children: [
          if (cumulative != null)
            _PerformanceRow(
              label: strings.chaContextTotal,
              value: compactSessionContextTokens(cumulative),
            ),
          _PerformanceRow(
            label: strings.chaContextObservedTtft,
            value: latency == null
                ? strings.chaContextNotMeasured
                : '$latency ms',
          ),
          _PerformanceRow(
            label: strings.chaContextCacheRead,
            value: read == null
                ? strings.chaContextNotPublished
                : compactSessionContextTokens(read),
          ),
          _PerformanceRow(
            label: strings.chaContextCacheWrite,
            value: write == null
                ? strings.chaContextNotPublished
                : compactSessionContextTokens(write),
          ),
          if (cachePercent != null)
            _PerformanceRow(
              label: strings.sesMetricCachePercent,
              value: '${cachePercent.toStringAsFixed(1)}%',
            ),
        ],
      ),
    );
  }
}

class _PerformanceRow extends StatelessWidget {
  const _PerformanceRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
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
    return Semantics(
      container: true,
      label: metrics.hasWindow && used != null && max != null && percent != null
          ? '${strings.chaContextUsageSummary(compactSessionContextTokens(used), compactSessionContextTokens(max))}. '
                '${strings.chaContextUsagePercent(percent)}'
          : strings.chaContextWindowUnavailable,
      excludeSemantics: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.surfaceVariant.withValues(alpha: 0.46),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: colors.divider.withValues(alpha: 0.78)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SessionContextRing(percent: percent, size: 40, strokeWidth: 3.4),
            const SizedBox(width: 12),
            Expanded(
              child:
                  metrics.hasWindow &&
                      used != null &&
                      max != null &&
                      percent != null
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$percent%',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                color: colors.textPrimary,
                                fontWeight: FontWeight.w700,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          strings.chaContextUsageSummary(
                            compactSessionContextTokens(used),
                            compactSessionContextTokens(max),
                          ),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.textSecondary),
                        ),
                      ],
                    )
                  : Text(
                      strings.chaContextWindowUnavailable,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.textSecondary,
                        height: 1.35,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class SessionContextBreakdown extends StatelessWidget {
  const SessionContextBreakdown({required this.categories, super.key});

  final List<DesktopContextUsageCategory> categories;

  @override
  Widget build(BuildContext context) {
    final total = categories.fold<int>(0, (sum, item) => sum + item.tokens);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SegmentedContextBar(categories: categories, total: total),
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
                borderRadius: BorderRadius.circular(3),
              ),
            );
            final labelWidget = Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
            );
            final valueWidget = Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
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
