import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../models/activity_snapshot.dart'
    show maskedGoalLine, sanitizeActivityDetail;
import '../../models/subagent_activity.dart';
import '../../models/tool_label.dart' show toolOrSkillStepTitle;
import '../../screens/subagent_detail_screen.dart'
    show subagentElapsed, subagentHumanStatus, subagentIsLive;
import '../../theme/app_theme.dart';
import '../activity_pill.dart' show ActivityTicker, formatTurnElapsed;
import 'delegated_icons.dart';

/// Design B: under the live row of the turn, one card per delegated child.
/// While it works: «⛓ Subagente 1 · 0:04», its goal in grey, and its real
/// status line with a thin progress bar at the right. When it finishes the
/// card folds into one line («✓ Subagente 1 · 412 archivos .md»); a failure
/// keeps its card with the public error text. Nothing here invents progress:
/// without data the bar is indeterminate and the line says «sin datos».
/// Only the live turn draws them; once it ends they stay in the summary.
class DelegatedChildCards extends StatelessWidget {
  const DelegatedChildCards({
    required this.subagents,
    required this.clock,
    super.key,
  });

  final List<SubagentActivity> subagents;
  final DateTime Function() clock;

  @override
  Widget build(BuildContext context) {
    if (subagents.isEmpty) return const SizedBox.shrink();
    return ActivityTicker(
      active: subagents.any(subagentIsLive),
      clock: clock,
      builder: (context, now) => Column(
        key: const ValueKey('delegated-child-cards'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (index, activity) in subagents.indexed)
            DelegatedChildCard(
              key: ValueKey('delegated-child-${activity.key.stableId}'),
              activity: activity,
              ordinal: index + 1,
              now: now,
            ),
        ],
      ),
    );
  }
}

/// The state a child's card draws: finished well, failed or stopped, not
/// known, or working.
DelegatedIconState delegatedChildState(SubagentActivity activity) {
  if (activity.phase == SubagentActivityPhase.unknown) {
    return DelegatedIconState.unknown;
  }
  if (activity.phase == SubagentActivityPhase.failed ||
      activity.phase == SubagentActivityPhase.cancelled) {
    return DelegatedIconState.failed;
  }
  return activity.isTerminal
      ? DelegatedIconState.done
      : DelegatedIconState.running;
}

/// The status line of a working child: its real tool in hand and a safe
/// target («Leyendo main.dart»), else its human phase, else «sin datos».
String delegatedChildStatusLine(Strings s, SubagentActivity activity) {
  final tool = activity.details.activeToolName?.trim();
  if (tool != null && tool.isNotEmpty) {
    final title = toolOrSkillStepTitle(s, tool, running: true);
    final detail = sanitizeActivityDetail(
      tool,
      activity.details.activeToolPreview,
    );
    return detail == null ? title : '$title $detail';
  }
  final hasData =
      activity.progress != null ||
      (activity.details.detailPreview?.trim().isNotEmpty ?? false);
  return hasData
      ? subagentHumanStatus(s, activity).label
      : s.delegatedChildNoData;
}

class DelegatedChildCard extends StatelessWidget {
  const DelegatedChildCard({
    required this.activity,
    required this.ordinal,
    required this.now,
    super.key,
  });

  final SubagentActivity activity;
  final int ordinal;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final state = delegatedChildState(activity);
    final title = '${s.subagentUiRowTitle} $ordinal';
    final tint = switch (state) {
      DelegatedIconState.failed => colors.error,
      DelegatedIconState.unknown => colors.textTertiary,
      _ => colors.accent,
    };
    // The icon keeps the timeline's one quiet ink; the bar keeps [tint].
    final ink = delegatedIconInk(colors, state);
    final elapsed = subagentElapsed(activity, now);
    final clock = elapsed == null ? null : formatTurnElapsed(elapsed);
    final titleStyle = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: colors.textPrimary,
    );
    final quiet = TextStyle(fontSize: 12.5, color: colors.textSecondary);

    // Finished well: one line, its result.
    if (state == DelegatedIconState.done) {
      final result =
          maskedGoalLine(activity.details.summaryPreview, max: 64) ??
          s.subagentUiStatusDone;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Semantics(
          container: true,
          label: '$title, $result',
          excludeSemantics: true,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 28),
            child: Row(
              children: [
                delegatedChildIcon(context, state, color: ink, size: 14),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$title · $result',
                    key: ValueKey(
                      'delegated-child-line-${activity.key.stableId}',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: quiet,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final goal = maskedGoalLine(activity.details.goalPreview);
    final failed = state == DelegatedIconState.failed;
    final status = switch (state) {
      DelegatedIconState.failed =>
        maskedGoalLine(
              activity.details.summaryPreview ?? activity.details.detailPreview,
            ) ??
            (activity.phase == SubagentActivityPhase.cancelled
                ? s.subagentUiStatusStopped
                : s.subagentUiStatusFailed),
      DelegatedIconState.unknown => s.subagentUiStatusUnconfirmed,
      _ => delegatedChildStatusLine(s, activity),
    };
    final fraction = state == DelegatedIconState.unknown
        ? 0.0
        : failed
        ? 1.0
        : activity.progress?.displayFraction;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Semantics(
        container: true,
        label: [title, ?clock, status].join(', '),
        liveRegion: !failed,
        excludeSemantics: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.divider),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    delegatedChildIcon(context, state, color: ink, size: 14),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        [title, ?clock].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: titleStyle,
                      ),
                    ),
                  ],
                ),
                if (goal != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    goal,
                    key: ValueKey(
                      'delegated-child-goal-${activity.key.stableId}',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: quiet,
                  ),
                ],
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        status,
                        key: ValueKey(
                          'delegated-child-status-${activity.key.stableId}',
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: failed
                            ? quiet.copyWith(color: colors.error)
                            : quiet,
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 56,
                      child: LinearProgressIndicator(
                        key: ValueKey(
                          'delegated-child-progress-${activity.key.stableId}',
                        ),
                        value: fraction ?? (reduced ? 0 : null),
                        minHeight: 3,
                        color: tint,
                        backgroundColor: colors.divider,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
