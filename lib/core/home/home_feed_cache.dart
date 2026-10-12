import '../models/cron_job.dart';
import '../models/kanban.dart';

/// The last cron list and Kanban board Home read, per connection and
/// profile, in memory only (like the Bots snapshot cache).
///
/// Home paints them at once when it is built again (a profile switched
/// back, the screen recreated) and refreshes behind; a failed refresh
/// keeps them. Nothing is written to disk: a killed process reads again.
final class HomeFeedCache {
  HomeFeedCache({this.capacity = 6});

  static final shared = HomeFeedCache();

  final int capacity;
  final Map<String, List<CronJob>> _cron = {};
  final Map<String, KanbanBoard> _tasks = {};

  static String scopeOf(String connectionId, String profile) =>
      '$connectionId\u0000$profile';

  List<CronJob>? cron(String scope) => _cron[scope];
  KanbanBoard? tasks(String scope) => _tasks[scope];

  void putCron(String scope, List<CronJob> jobs) => _put(_cron, scope, jobs);
  void putTasks(String scope, KanbanBoard board) => _put(_tasks, scope, board);

  void _put<T>(Map<String, T> entries, String scope, T value) {
    entries.remove(scope);
    entries[scope] = value;
    while (entries.length > capacity) {
      entries.remove(entries.keys.first);
    }
  }

  void clear() {
    _cron.clear();
    _tasks.clear();
  }
}
