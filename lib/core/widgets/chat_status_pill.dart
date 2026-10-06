import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/compaction_progress.dart';
import '../theme/app_theme.dart';
import 'compaction_dock.dart';
import 'session_context_usage.dart';

/// How close the most used subscription window is to its limit. Drives the
/// small dot next to the model name in [ChatStatusPill].
enum SubscriptionLimitLevel {
  /// No data, or every window below 80 %.
  none,

  /// The fullest window is at 80 % or more.
  near,

  /// A window is at 100 %.
  reached,
}

/// Colour of the context ring and its percentage: the accent below 75 %,
/// amber from 75 % and red from 90 %.
Color contextLevelColor(int? percent, HermesThemeColors colors) {
  final value = percent ?? 0;
  if (value >= 90) return colors.error;
  if (value >= 75) return colors.warning;
  return colors.accentText;
}

/// The status pill under the composer: `45% ⤓ | Sonnet 5 ▾ | 🛡`.
///
/// Three zones, each opening its own sheet: context usage, model and
/// session, and the permissions of this session. The capsule itself is 30 px
/// tall; every zone's hit area is at least 40 px so a thumb can reach it.
/// Only the context zone listens to live usage, so a new percentage never
/// rebuilds the transcript.
class ChatStatusPill extends StatelessWidget {
  const ChatStatusPill({
    required this.metrics,
    required this.onOpenContext,
    this.compaction,
    this.compressionCount = 0,
    this.clock,
    this.modelLabel,
    this.onOpenModel,
    this.modelLeading,
    this.modelTrailing,
    this.limitLevel = SubscriptionLimitLevel.none,
    this.permissionsLabel,
    this.permissionsFlag,
    this.permissionsColor,
    this.onOpenPermissions,
    super.key,
  });

  final ValueListenable<SessionContextMetrics> metrics;
  final VoidCallback onOpenContext;

  /// A compaction running now or just finished. While non-null it takes the
  /// place of the ring and the percentage.
  final CompactionProgress? compaction;

  /// How many times this session was compacted (0 hides the mark).
  final int compressionCount;

  /// Injectable clock for the compaction elapsed time (tests).
  final DateTime Function()? clock;

  /// Friendly name of the model; null hides the model zone.
  final String? modelLabel;
  final VoidCallback? onOpenModel;

  /// Shown before / after the model name (e.g. the provider logo and a
  /// "change pending" mark), so the pill carries what the header's model
  /// chip used to show.
  final Widget? modelLeading;
  final Widget? modelTrailing;
  final SubscriptionLimitLevel limitLevel;

  /// Effective permission mode, always announced. Null hides the zone.
  final String? permissionsLabel;

  /// Text shown next to the shield only when the mode is worth flagging
  /// (YOLO, read-only, or a per-session override); null shows the shield
  /// alone and announces the mode as the global one.
  final String? permissionsFlag;
  final Color? permissionsColor;
  final VoidCallback? onOpenPermissions;

  static const double capsuleHeight = 30;
  static const double minTouchHeight = 40;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final zones = <Widget>[
      _ContextZone(
        metrics: metrics,
        onTap: onOpenContext,
        compaction: compaction,
        compressionCount: compressionCount,
        clock: clock,
      ),
      if (modelLabel != null && onOpenModel != null)
        Flexible(
          child: _Zone(
            key: const ValueKey('status-pill-model'),
            onTap: onOpenModel!,
            semanticsLabel: [
              strings.sp1215ModelZone(modelLabel!),
              if (limitLevel == SubscriptionLimitLevel.near)
                strings.sp1215LimitNear,
              if (limitLevel == SubscriptionLimitLevel.reached)
                strings.sp1215LimitReached,
            ].join(' · '),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (modelLeading case final leading?) ...[
                  leading,
                  const SizedBox(width: 4),
                ],
                Flexible(
                  child: Text(
                    modelLabel!,
                    // Keyed by the name: a model swap paints a new label.
                    key: ValueKey(modelLabel),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (modelTrailing case final trailing?) ...[
                  const SizedBox(width: 4),
                  trailing,
                ],
                if (limitLevel != SubscriptionLimitLevel.none) ...[
                  const SizedBox(width: 4),
                  Container(
                    key: const ValueKey('status-pill-limit-dot'),
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: limitLevel == SubscriptionLimitLevel.reached
                          ? colors.error
                          : colors.warning,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
                const SizedBox(width: 1),
                Icon(
                  Icons.arrow_drop_down_rounded,
                  size: 16,
                  color: colors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      if (permissionsLabel != null && onOpenPermissions != null)
        Flexible(
          child: _Zone(
            key: const ValueKey('status-pill-permissions'),
            onTap: onOpenPermissions!,
            semanticsLabel: permissionsFlag == null
                ? strings.sp1215PermissionsZoneGlobal(permissionsLabel!)
                : strings.sp1215PermissionsZone(permissionsLabel!),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.shield_outlined,
                  size: 14,
                  color: permissionsFlag == null
                      ? colors.textSecondary
                      : permissionsColor ?? colors.error,
                ),
                if (permissionsFlag != null) ...[
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      permissionsFlag!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: permissionsColor ?? colors.error,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
    ];
    final children = <Widget>[];
    for (var i = 0; i < zones.length; i++) {
      if (i > 0) children.add(_Divider(color: colors.divider));
      children.add(zones[i]);
    }
    return Stack(
      alignment: Alignment.center,
      children: [
        // The visible capsule: slim, centred in the taller hit area.
        Positioned(
          left: 0,
          right: 0,
          child: Container(
            key: const ValueKey('status-pill-capsule'),
            height: capsuleHeight,
            decoration: BoxDecoration(
              color: colors.surfaceVariant.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: colors.divider.withValues(alpha: 0.7)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.24),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
          ),
        ),
        Row(mainAxisSize: MainAxisSize.min, children: children),
      ],
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 12, color: color);
}

/// One tappable zone of the pill: a 40 px tall, labelled button.
class _Zone extends StatelessWidget {
  const _Zone({
    required this.onTap,
    required this.semanticsLabel,
    required this.child,
    this.liveRegion = false,
    super.key,
  });

  final VoidCallback onTap;
  final String semanticsLabel;
  final Widget child;
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      onTap: onTap,
      label: semanticsLabel,
      liveRegion: liveRegion,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          customBorder: const StadiumBorder(),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: ChatStatusPill.minTouchHeight,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9),
              child: Center(widthFactor: 1, heightFactor: 1, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

class _ContextZone extends StatelessWidget {
  const _ContextZone({
    required this.metrics,
    required this.onTap,
    required this.compaction,
    required this.compressionCount,
    required this.clock,
  });

  final ValueListenable<SessionContextMetrics> metrics;
  final VoidCallback onTap;
  final CompactionProgress? compaction;
  final int compressionCount;
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return ValueListenableBuilder<SessionContextMetrics>(
      valueListenable: metrics,
      builder: (context, value, _) {
        final compaction = this.compaction;
        final percent = value.percent;
        final level = contextLevelColor(percent, colors);
        final label = [
          if (compaction != null)
            compactionStatusText(
              strings,
              compaction,
              Localizations.localeOf(context).languageCode,
            ),
          sessionContextTriggerSemanticsLabel(strings, value),
          if (compressionCount > 0 && compaction == null)
            strings.chaSessionCompactedTooltip(compressionCount),
        ].join(' · ');
        final Widget lead = compaction == null
            ? Row(
                key: const ValueKey('context-pill-usage'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  SessionContextRing(
                    percent: percent,
                    size: 14,
                    strokeWidth: 2,
                    color: level,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    sessionContextTriggerText(value),
                    style: TextStyle(
                      color: percent != null && percent >= 75
                          ? level
                          : colors.textPrimary,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              )
            : CompactionPillSegment(
                key: const ValueKey('context-pill-compaction'),
                compaction: compaction,
                clock: clock,
              );
        return _Zone(
          key: const ValueKey('desktop-context-usage-status'),
          onTap: onTap,
          semanticsLabel: label,
          // Announces compaction start/end: the label changes only then.
          liveRegion: compaction != null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // No AnimatedSize: this pill sits in the composer footer,
              // which relayouts while the transcript streams.
              AnimatedSwitcher(
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                layoutBuilder: (current, previous) => Stack(
                  alignment: Alignment.centerLeft,
                  children: [...previous, ?current],
                ),
                child: lead,
              ),
              if (compressionCount > 0 && compaction == null) ...[
                const SizedBox(width: 5),
                Icon(
                  Icons.compress_rounded,
                  size: 12,
                  color: colors.textSecondary,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
