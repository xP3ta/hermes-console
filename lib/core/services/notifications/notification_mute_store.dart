// Silenciado de notificaciones POR ELEMENTO CONCRETO (un cron job o una
// tarea de Kanban individual), independiente de los toggles globales
// `notifyCronResults` / `notifyKanbanResults` de [NotificationService].
//
// Mismo patrón de persistencia que el resto de ajustes de notificaciones de
// la app: SharedPreferences plano, sin ámbito por conexión (los toggles
// globales tampoco lo tienen), guardado como lista de ids opacos.
import 'package:shared_preferences/shared_preferences.dart';

class NotificationMuteStore {
  NotificationMuteStore(this._prefs);

  final SharedPreferences _prefs;

  static const _kMutedCronJobIds = 'notif_muted_cron_job_ids';
  static const _kMutedKanbanTaskIds = 'notif_muted_kanban_task_ids';

  Set<String> get mutedCronJobIds =>
      (_prefs.getStringList(_kMutedCronJobIds) ?? const <String>[]).toSet();

  Set<String> get mutedKanbanTaskIds =>
      (_prefs.getStringList(_kMutedKanbanTaskIds) ?? const <String>[])
          .toSet();

  bool isJobMuted(String jobId) => mutedCronJobIds.contains(jobId.trim());

  bool isTaskMuted(String taskId) =>
      mutedKanbanTaskIds.contains(taskId.trim());

  Future<void> setJobMuted(String jobId, bool muted) =>
      _setMembership(_kMutedCronJobIds, jobId, muted);

  Future<void> setTaskMuted(String taskId, bool muted) =>
      _setMembership(_kMutedKanbanTaskIds, taskId, muted);

  Future<void> _setMembership(String key, String rawId, bool present) async {
    final id = rawId.trim();
    if (id.isEmpty) return;
    final current = (_prefs.getStringList(key) ?? const <String>[]).toSet();
    final changed = present ? current.add(id) : current.remove(id);
    if (!changed) return;
    await _prefs.setStringList(key, current.toList(growable: false));
  }
}
