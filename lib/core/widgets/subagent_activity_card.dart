import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../models/subagent_activity.dart';
import '../screens/subagent_detail_screen.dart';
import '../services/delegation_control.dart';
import '../theme/app_theme.dart';
import 'activity_pill.dart' show formatTurnElapsed;

/// Display-safe result returned by the owner-scoped tail callback.
final class SubagentTailView {
  final bool available;
  final String content;
  final bool truncated;

  const SubagentTailView({
    required this.available,
    required this.content,
    required this.truncated,
  });
}

/// Display-safe disposition for a steering request.
final class SubagentSteerView {
  final String status;

  const SubagentSteerView({required this.status});

  bool get queued => status == 'queued';
}

typedef SubagentTailLoader =
    Future<SubagentTailView> Function(SubagentActivity activity);
typedef SubagentSteerSender =
    Future<SubagentSteerView> Function(SubagentActivity activity, String text);
typedef SubagentStopRequester =
    Future<bool> Function(SubagentActivity activity);
typedef SubagentTailScheduler =
    VoidCallback Function(Duration delay, VoidCallback callback);

/// Lets the unified activity panel open a subagent (detail page, or the
/// floating list when several and none is preselected).
class SubagentActivityController {
  void Function(SubagentActivity? selected)? _opener;

  void open([SubagentActivity? activity]) => _opener?.call(activity);
}

/// Spec 080 `HermesActivityRow` for delegated work: one flat transcript row
/// (no elevation, no pill). One subagent → "Subagente · goal" + status; tap
/// opens its detail page. Several → "3 subagentes · 2 trabajando"; tap opens
/// a floating list, each row opening the detail page.
///
/// It also owns the live roster notifier the detail page follows, so the
/// page updates in place while it is open.
class SubagentActivityCard extends StatefulWidget {
  final List<SubagentActivity> activities;
  final bool Function(SubagentActivity activity)? canInterrupt;
  final bool Function(SubagentActivity activity)? canSteer;
  final bool Function(SubagentActivity activity)? canTail;
  final bool Function(SubagentActivity activity)? isInterruptPending;
  final bool Function(SubagentActivity activity)? isOpenPending;
  final ValueChanged<SubagentActivity>? onOpenConversation;

  /// Legacy immediate stop (no confirmation); prefer [onStopRequested].
  final ValueChanged<SubagentActivity>? onInterrupt;
  final SubagentStopRequester? onStopRequested;
  final SubagentSteerSender? onSteer;
  final SubagentTailLoader? onTail;
  final SubagentTailScheduler? scheduleTailPoll;

  /// Server-wide pause switch, handed to the detail's overflow.
  final HermesDelegationGateway? delegationControl;
  final DateTime? now;
  final bool background;
  final bool appForeground;
  final int safeChildCount;
  final VoidCallback? onDismiss;

  /// Title of the delegating chat for the detail's "Belongs to" row.
  final String parentTitle;

  /// Keeps the chat's subagent presentation lease while a detail is open.
  final VoidCallback Function()? acquirePresentation;

  /// The unified activity pill owns the in-chat presentation: render nothing
  /// and only serve [controller].
  final bool hidden;
  final SubagentActivityController? controller;

  const SubagentActivityCard({
    required this.activities,
    this.canInterrupt,
    this.canSteer,
    this.canTail,
    this.isInterruptPending,
    this.isOpenPending,
    this.onOpenConversation,
    this.onInterrupt,
    this.onStopRequested,
    this.onSteer,
    this.onTail,
    this.scheduleTailPoll,
    this.delegationControl,
    this.now,
    this.background = false,
    this.appForeground = true,
    this.safeChildCount = 0,
    this.onDismiss,
    this.parentTitle = '',
    this.acquirePresentation,
    this.hidden = false,
    this.controller,
    super.key,
  });

  @override
  State<SubagentActivityCard> createState() => _SubagentActivityCardState();
}

class _SubagentActivityCardState extends State<SubagentActivityCard> {
  late final ValueNotifier<List<SubagentActivity>> _roster = ValueNotifier(
    widget.activities,
  );
  bool _surfaceOpen = false;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    widget.controller?._opener = _openFromController;
    _syncClock();
  }

  @override
  void didUpdateWidget(covariant SubagentActivityCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller?._opener == _openFromController) {
        oldWidget.controller?._opener = null;
      }
      widget.controller?._opener = _openFromController;
    }
    if (!identical(oldWidget.activities, widget.activities)) {
      // Deferred: listeners (an open detail route) must not rebuild mid-build.
      final next = widget.activities;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _roster.value = next;
      });
    }
    _syncClock();
  }

  @override
  void dispose() {
    if (widget.controller?._opener == _openFromController) {
      widget.controller?._opener = null;
    }
    _clock?.cancel();
    _roster.dispose();
    super.dispose();
  }

  void _syncClock() {
    final live =
        !widget.hidden &&
        widget.now == null &&
        widget.appForeground &&
        widget.activities.length == 1 &&
        subagentIsLive(widget.activities.single);
    if (live && _clock == null) {
      _clock = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!live) {
      _clock?.cancel();
      _clock = null;
    }
  }

  void _openFromController(SubagentActivity? activity) {
    if (!mounted) return;
    if (activity != null &&
        widget.activities.any((candidate) => candidate.key == activity.key)) {
      unawaited(_openDetail(activity));
    } else if (widget.activities.length == 1) {
      unawaited(_openDetail(widget.activities.single));
    } else if (widget.activities.isNotEmpty) {
      unawaited(_openList());
    }
  }

  SubagentStopRequester? get _stopRequester {
    if (widget.onStopRequested != null) return widget.onStopRequested;
    final legacy = widget.onInterrupt;
    if (legacy == null) return null;
    return (activity) async {
      legacy(activity);
      return true;
    };
  }

  /// Goals are bounded public-display metadata, but only the owner-wired live
  /// surface (the chat that holds the lease) may reveal them.
  bool get _ownerWired => widget.canSteer != null;

  Future<void> _openDetail(SubagentActivity activity) async {
    if (!mounted) return;
    _roster.value = widget.activities;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SubagentDetailScreen(
          roster: _roster,
          activityKey: activity.key,
          parentTitle: widget.parentTitle,
          canInterrupt: widget.canInterrupt,
          isInterruptPending: widget.isInterruptPending,
          onStopRequested: _stopRequester,
          canSteer: widget.canSteer,
          onSteer: widget.onSteer,
          canTail: widget.canTail,
          onTail: widget.onTail,
          onOpenConversation: widget.onOpenConversation,
          isOpenPending: widget.isOpenPending,
          acquirePresentation: widget.acquirePresentation,
          scheduleTailPoll: widget.scheduleTailPoll,
          delegationControl: widget.delegationControl,
          clock: widget.now == null ? null : () => widget.now!,
          hideGoal: !_ownerWired,
        ),
      ),
    );
  }

  Future<void> _openList() async {
    if (_surfaceOpen || !mounted) return;
    _surfaceOpen = true;
    final s = Strings.of(context);
    try {
      final picked = await showHermesSurface<SubagentActivity>(
        context: context,
        surfaceKey: const ValueKey('subagent-panel'),
        maxWidth: 480,
        originRect: widget.hidden ? null : hermesOriginOf(context),
        builder: (surfaceContext) => ValueListenableBuilder(
          valueListenable: _roster,
          builder: (context, roster, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HermesSurfaceHeader(
                title: s.subagentUiListTitle,
                subtitle: s.subagentUiListSubtitle,
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [
                    for (final activity in roster)
                      _SubagentListRow(
                        key: ValueKey(activity.key),
                        activity: activity,
                        now: widget.now ?? DateTime.now(),
                        showGoal: _ownerWired,
                        stopping:
                            widget.isInterruptPending?.call(activity) ?? false,
                        onTap: () => Navigator.of(surfaceContext).pop(activity),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
      if (picked != null && mounted) await _openDetail(picked);
    } finally {
      _surfaceOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.hidden) {
      return const SizedBox.shrink(key: ValueKey('subagent-card-hidden'));
    }
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final activities = widget.activities;
    final safeChildCount = widget.safeChildCount.clamp(0, 6);
    final count = activities.length > safeChildCount
        ? activities.length
        : safeChildCount;
    if (!widget.background && count == 0) {
      return const SizedBox.shrink(key: ValueKey('session-activity-idle'));
    }
    final now = widget.now ?? DateTime.now();
    final genericOnly = activities.isEmpty;
    final live = activities.where(subagentIsLive).length;
    final failed = activities
        .where((a) => a.phase == SubagentActivityPhase.failed)
        .length;
    final unknown = activities
        .where((a) => a.phase == SubagentActivityPhase.unknown)
        .length;

    String title;
    String statusLabel;
    HermesStatusTone tone;
    String? meta;
    if (activities.length == 1) {
      final a = activities.single;
      final goal = _ownerWired ? subagentTitle(s, a, maxChars: 60) : null;
      title = goal == null || goal == s.subagentUiRowTitle
          ? s.subagentUiRowTitle
          : '${s.subagentUiRowTitle} · $goal';
      final status = subagentHumanStatus(
        s,
        a,
        stopping: widget.isInterruptPending?.call(a) ?? false,
      );
      statusLabel = status.label;
      tone = status.tone;
      final elapsed = subagentElapsed(a, now);
      meta = elapsed == null ? null : formatTurnElapsed(elapsed);
    } else {
      title = s.subagentUiGroupTitle(count);
      if (genericOnly) {
        statusLabel = s.subagentUiWorkingCount(count);
        tone = HermesStatusTone.active;
      } else if (live > 0) {
        statusLabel = s.subagentUiWorkingCount(live);
        tone = HermesStatusTone.active;
        if (failed > 0) meta = s.subagentUiFailedCount(failed);
      } else if (failed > 0) {
        statusLabel = s.subagentUiFailedCount(failed);
        tone = HermesStatusTone.error;
      } else if (unknown > 0) {
        statusLabel = s.subagentUiStatusUnknown;
        tone = HermesStatusTone.neutral;
      } else {
        statusLabel = s.subagentUiAllDone;
        tone = HermesStatusTone.ok;
      }
    }
    final canDismiss =
        !genericOnly && live == 0 && unknown == 0 && widget.onDismiss != null;

    return Semantics(
      container: true,
      button: !genericOnly,
      label: '$title, $statusLabel${meta == null ? '' : ', $meta'}',
      excludeSemantics: true,
      child: Material(
        key: const ValueKey('subagent-disclosure'),
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(HermesRadius.control),
          onTap: genericOnly
              ? null
              : () => activities.length == 1
                    ? _openDetail(activities.single)
                    : _openList(),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: HermesSpace.tap),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 0, 6),
              child: Row(
                children: [
                  Icon(
                    Icons.account_tree_outlined,
                    size: 18,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          key: const ValueKey('subagent-row-title'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HermesType.body.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        HermesStatusText(
                          key: const ValueKey('subagent-row-status'),
                          label: statusLabel,
                          tone: tone,
                          meta: meta,
                          maxLines: 1,
                        ),
                      ],
                    ),
                  ),
                  if (canDismiss)
                    IconButton(
                      tooltip: s.inAppDismiss,
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      iconSize: 18,
                      color: colors.textSecondary,
                      onPressed: widget.onDismiss,
                      icon: const Icon(Icons.close_rounded),
                    )
                  else if (!genericOnly)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: colors.textDisabled,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SubagentListRow extends StatelessWidget {
  final SubagentActivity activity;
  final DateTime now;
  final bool showGoal;
  final bool stopping;
  final VoidCallback onTap;

  const _SubagentListRow({
    required this.activity,
    required this.now,
    required this.showGoal,
    required this.stopping,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final status = subagentHumanStatus(s, activity, stopping: stopping);
    final elapsed = subagentElapsed(activity, now);
    final title = showGoal
        ? subagentTitle(s, activity, maxChars: 90)
        : s.subagentUiRowTitle;
    return Semantics(
      button: true,
      label: '$title, ${status.label}',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('subagent-row-${activity.key.stableId}'),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: HermesType.body.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      HermesStatusText(
                        label: status.label,
                        tone: status.tone,
                        meta: elapsed == null
                            ? null
                            : formatTurnElapsed(elapsed),
                        maxLines: 1,
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: colors.textDisabled,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Read-only projection of a durable delegation completion marker, as the
/// same flat transcript row. No callbacks, no identifiers, no payloads.
class SubagentCompletionCard extends StatelessWidget {
  final SubagentCompletionCardData data;

  const SubagentCompletionCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final completed = data.completedCount;
    final failed = data.failedCount;
    final total =
        data.taskCount ??
        ((completed ?? 0) + (failed ?? 0) == 0
            ? null
            : (completed ?? 0) + (failed ?? 0));
    final duration = data.durationSeconds;
    final meta = <String>[
      if (completed != null && (failed ?? 0) > 0)
        s.subagentActivityAggregateCompleted(completed),
      if (duration != null && duration.isFinite && duration >= 0)
        formatTurnElapsed(Duration(milliseconds: (duration * 1000).round())),
    ];
    final (String label, HermesStatusTone tone) = (failed ?? 0) > 0
        ? (s.subagentActivityAggregateFailed(failed!), HermesStatusTone.error)
        : completed != null
        ? (s.subagentActivityAggregateCompleted(completed), HermesStatusTone.ok)
        : (s.subagentActivityUnknown, HermesStatusTone.neutral);
    final title = total == null
        ? s.subagentActivityTitle
        : s.subagentUiGroupTitle(total);
    return Semantics(
      container: true,
      label: '${s.subagentActivityTitle}, $label',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 0, 6),
        child: Row(
          children: [
            Icon(
              Icons.account_tree_outlined,
              size: 18,
              color: colors.textSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HermesType.body.copyWith(color: colors.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  HermesStatusText(
                    label: label,
                    tone: tone,
                    meta: meta.isEmpty ? null : meta.join(' · '),
                    maxLines: 1,
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
