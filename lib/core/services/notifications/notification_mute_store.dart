// Per-item notification preferences for a single Cron job or Kanban task,
// independent of the global `notifyCronResults` / `notifyKanbanResults`
// toggles of [NotificationService].
//
// Spec 080: preferences are scoped by `connId/profile/id` so equal job or task
// ids on two instances never collide, and they are read by the REAL delivery
// path (the background listener's discovery), not only by legacy helpers.
// SharedPreferences is available in the foreground-service isolate, which
// reloads it at the start of every poll.
import 'package:shared_preferences/shared_preferences.dart';

/// What a finished Cron run should raise.
enum CronNotifyPolicy {
  /// Notify results and failures (default; follows the global setting).
  all,

  /// Notify only failed runs.
  failuresOnly,

  /// Never notify for this job.
  off,
}

class NotificationMuteStore {
  NotificationMuteStore(this._prefs);

  final SharedPreferences _prefs;

  // Legacy, unscoped opt-out lists (pre-080). Still honoured as "off".
  static const _kMutedCronJobIds = 'notif_muted_cron_job_ids';
  static const _kMutedKanbanTaskIds = 'notif_muted_kanban_task_ids';

  // Scoped maps encoded as `scope=value` string lists.
  static const _kCronPolicies = 'notif_cron_job_policy_v2';
  static const _kKanbanDone = 'notif_kanban_task_done_v2';
  static const _kKanbanMuted = 'notif_kanban_task_muted_v2';

  /// Global default for "notify me when a task is done" (opt-in).
  static const kanbanDoneDefaultKey = 'notif_kanban_done_default';

  /// Kanban boards are watched per connection under the `default` profile.
  static const kanbanProfile = 'default';

  static String scope(String connId, String profile, String id) {
    final p = profile.trim().toLowerCase();
    return '${connId.trim()}/${p.isEmpty ? 'default' : p}/${id.trim()}';
  }

  Set<String> get mutedCronJobIds =>
      (_prefs.getStringList(_kMutedCronJobIds) ?? const <String>[]).toSet();

  Set<String> get mutedKanbanTaskIds =>
      (_prefs.getStringList(_kMutedKanbanTaskIds) ?? const <String>[]).toSet();

  bool isJobMuted(String jobId) => mutedCronJobIds.contains(jobId.trim());

  bool isTaskMuted(String taskId) => mutedKanbanTaskIds.contains(taskId.trim());

  Future<void> setJobMuted(String jobId, bool muted) =>
      _setMembership(_kMutedCronJobIds, jobId, muted);

  Future<void> setTaskMuted(String taskId, bool muted) =>
      _setMembership(_kMutedKanbanTaskIds, taskId, muted);

  // ── Cron ────────────────────────────────────────────────────────────────

  CronNotifyPolicy cronPolicy({
    required String connId,
    required String profile,
    required String jobId,
  }) {
    final id = jobId.trim();
    if (id.isEmpty) return CronNotifyPolicy.all;
    final raw = _map(_kCronPolicies)[scope(connId, profile, id)];
    if (raw != null) {
      return CronNotifyPolicy.values.firstWhere(
        (p) => p.name == raw,
        orElse: () => CronNotifyPolicy.all,
      );
    }
    return isJobMuted(id) ? CronNotifyPolicy.off : CronNotifyPolicy.all;
  }

  Future<void> setCronPolicy({
    required String connId,
    required String profile,
    required String jobId,
    required CronNotifyPolicy policy,
  }) async {
    final id = jobId.trim();
    if (id.isEmpty) return;
    final map = _map(_kCronPolicies);
    map[scope(connId, profile, id)] = policy.name;
    await _writeMap(_kCronPolicies, map);
    // The scoped value is authoritative from now on; drop the legacy opt-out
    // so turning notifications back on actually takes effect.
    if (isJobMuted(id)) await setJobMuted(id, false);
  }

  /// Whether a terminal Cron run with outcome [ok] should be delivered.
  bool shouldDeliverCron({
    required String connId,
    required String profile,
    required String jobId,
    required bool ok,
  }) => cronPolicyAllows(
    cronPolicy(connId: connId, profile: profile, jobId: jobId),
    ok: ok,
  );

  static bool cronPolicyAllows(CronNotifyPolicy policy, {required bool ok}) =>
      switch (policy) {
        CronNotifyPolicy.all => true,
        CronNotifyPolicy.failuresOnly => !ok,
        CronNotifyPolicy.off => false,
      };

  // ── Kanban ──────────────────────────────────────────────────────────────

  bool get kanbanDoneDefault => _prefs.getBool(kanbanDoneDefaultKey) ?? false;
  Future<void> setKanbanDoneDefault(bool value) =>
      _prefs.setBool(kanbanDoneDefaultKey, value);

  bool kanbanMuted({required String connId, required String taskId}) {
    final id = taskId.trim();
    if (id.isEmpty) return false;
    final raw = _map(_kKanbanMuted)[scope(connId, kanbanProfile, id)];
    if (raw != null) return raw == 'true';
    return isTaskMuted(id);
  }

  Future<void> setKanbanMuted({
    required String connId,
    required String taskId,
    required bool muted,
  }) async {
    final id = taskId.trim();
    if (id.isEmpty) return;
    final map = _map(_kKanbanMuted);
    map[scope(connId, kanbanProfile, id)] = '$muted';
    await _writeMap(_kKanbanMuted, map);
    if (!muted && isTaskMuted(id)) await setTaskMuted(id, false);
  }

  /// Opt-in "notify me when it is done". Unset follows [kanbanDoneDefault].
  bool kanbanNotifyDone({required String connId, required String taskId}) {
    final raw = _map(_kKanbanDone)[scope(connId, kanbanProfile, taskId)];
    if (raw != null) return raw == 'true';
    return kanbanDoneDefault;
  }

  Future<void> setKanbanNotifyDone({
    required String connId,
    required String taskId,
    required bool value,
  }) async {
    if (taskId.trim().isEmpty) return;
    final map = _map(_kKanbanDone);
    map[scope(connId, kanbanProfile, taskId)] = '$value';
    await _writeMap(_kKanbanDone, map);
  }

  /// Kanban statuses that raise a notification for this task.
  Set<String> kanbanNotifiableStatuses({
    required String connId,
    required String taskId,
  }) {
    if (kanbanMuted(connId: connId, taskId: taskId)) return const <String>{};
    return <String>{
      'blocked',
      'triage',
      if (kanbanNotifyDone(connId: connId, taskId: taskId)) 'done',
    };
  }

  // ── Storage helpers ─────────────────────────────────────────────────────

  Map<String, String> _map(String key) {
    final out = <String, String>{};
    for (final entry in _prefs.getStringList(key) ?? const <String>[]) {
      final split = entry.lastIndexOf('=');
      if (split <= 0) continue;
      out[entry.substring(0, split)] = entry.substring(split + 1);
    }
    return out;
  }

  Future<void> _writeMap(String key, Map<String, String> map) =>
      _prefs.setStringList(key, [
        for (final entry in map.entries) '${entry.key}=${entry.value}',
      ]);

  Future<void> _setMembership(String key, String rawId, bool present) async {
    final id = rawId.trim();
    if (id.isEmpty) return;
    final current = (_prefs.getStringList(key) ?? const <String>[]).toSet();
    final changed = present ? current.add(id) : current.remove(id);
    if (!changed) return;
    await _prefs.setStringList(key, current.toList(growable: false));
  }
}
