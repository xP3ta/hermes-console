// Failed delegations the server persists (`subagent.list` → `delegations`)
// shown as terminal rows next to the live roster, as the official app does.
// The live roster forgets ended children, so a delegation that failed before
// it produced a child (a provider error, "delegation unavailable") would
// otherwise leave only a count with no row, goal or error.
import '../models/subagent_activity.dart';
import 'tui_gateway_client.dart' show DesktopFailedDelegation;

/// One terminal, failed row for [failed]. It has no child session, no live
/// identity and no controls: it only reports what went wrong.
SubagentActivity failedDelegationActivity(
  DesktopFailedDelegation failed,
  SubagentActivityScope scope,
) {
  final cancelled =
      failed.status == 'cancelled' || failed.status == 'interrupted';
  return SubagentActivity(
    key: SubagentActivityKey(
      scope: scope,
      identityKind: SubagentIdentityKind.delegation,
      stableId: failed.stableId,
    ),
    source: SubagentActivitySource.native,
    phase: cancelled
        ? SubagentActivityPhase.cancelled
        : SubagentActivityPhase.failed,
    delegationId: failed.delegationId,
    details: SubagentActivityDetails(
      goalPreview: failed.goal.isEmpty ? null : failed.goal,
      detailPreview: failed.error,
      summaryPreview: failed.error,
      durationSeconds: failed.duration == null
          ? null
          : failed.duration!.inMilliseconds / 1000,
      startedAt: failed.dispatchedAt,
      completedAt: failed.completedAt,
    ),
  );
}

/// [roster] plus a row for every failed delegation the roster does not
/// already show. A roster child counts as the same task when it carries the
/// delegation id and either the same goal or no goal at all.
List<SubagentActivity> withFailedDelegations(
  List<SubagentActivity> roster,
  List<DesktopFailedDelegation> failed,
  SubagentActivityScope? scope,
) {
  if (failed.isEmpty || scope == null) return roster;
  final extra = <SubagentActivity>[];
  for (final row in failed) {
    final goal = row.goal.trim();
    final shown = roster.any((a) {
      if (a.delegationId != row.delegationId) return false;
      final shownGoal = a.goalPreview?.trim() ?? '';
      return a.isTerminal && (shownGoal.isEmpty || shownGoal == goal);
    });
    if (!shown) extra.add(failedDelegationActivity(row, scope));
  }
  if (extra.isEmpty) return roster;
  return List.unmodifiable([...roster, ...extra]);
}
