import 'session.dart';

/// Write gate for cron run sessions, ported from Hermes Desktop
/// `apps/desktop/src/app/cron/open-cron-run.ts` (#88443).
///
/// A cron run is an autonomous scheduled execution, never an interactive chat
/// target. It may be written to only while the scheduler still owns it, or
/// once it was properly closed (`ended_at` stamped). A run that never got its
/// `end_session` and that the scheduler no longer owns is a zombie: a message
/// sent into it would run under the cron identity, so it opens view-only.
abstract final class CronRunWriteGate {
  /// The backend activity window (`sessions.py::_ACTIVE_WINDOW_S`), used only
  /// against an older backend that predates `scheduler_owned`.
  static const Duration activityWindow = Duration(seconds: 300);

  /// `cron/scheduler.py::run_job` names every agent run
  /// `cron_{job_id}_{YYYYmmdd_HHMMSS}`.
  static final RegExp _runId = RegExp(r'^cron_.+_\d{8}_\d{6}$');

  static bool isRunSessionId(String? id) {
    final value = id?.trim();
    return value != null && value.isNotEmpty && _runId.hasMatch(value);
  }

  /// Whether [session] is a cron run the gate applies to.
  static bool appliesTo(Session session) =>
      session.source.trim() == 'cron' || isRunSessionId(session.id);

  /// Desktop `isResumableCronRun`: closed, or owned by the scheduler. An
  /// older backend without `scheduler_owned` falls back to its `is_active`,
  /// then to the activity window over `last_active`.
  static bool isResumable(Session run, {DateTime? now}) {
    if (run.endedAt != null) return true;
    final owned = run.schedulerOwned;
    if (owned != null) return owned;
    if (run.isActivePublished) return run.isActive;
    final lastActive = run.updatedAt;
    if (lastActive == null) return false;
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return nowMs - lastActive * 1000 < activityWindow.inMilliseconds;
  }

  /// Verdict for a freshly read authoritative row: true means view-only.
  /// A row whose source is not `cron` is an ordinary chat.
  static bool readOnlyFor(Session row, {DateTime? now}) {
    final source = row.source.trim();
    if (source.isNotEmpty && source != 'cron') return false;
    return !isResumable(row, now: now);
  }
}
