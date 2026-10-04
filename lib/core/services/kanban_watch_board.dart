import 'package:shared_preferences/shared_preferences.dart';

/// The Kanban board the user picked last in Tasks, per connection.
///
/// Desktop notifies terminal Kanban events for the board the user has open
/// (`plugins/kanban/completion-notify.ts` rides that board's `/events`
/// socket). Console's background listener has no socket, so it reads the
/// same board from this preference in its existing tick. Unset means the
/// server's current board (`GET /board` without `board`), which is also what
/// Tasks shows first.
abstract final class KanbanWatchBoard {
  static const String _prefix = 'kanban_watch_board.';

  static final RegExp _slug = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');

  static String key(String connId) => '$_prefix$connId';

  static String? normalize(String? slug) {
    final value = slug?.trim();
    if (value == null || !_slug.hasMatch(value)) return null;
    return value;
  }

  static String? read(SharedPreferences prefs, String connId) =>
      normalize(prefs.getString(key(connId)));

  static Future<void> write(
    SharedPreferences prefs,
    String connId,
    String? slug,
  ) async {
    final value = normalize(slug);
    if (value == null) {
      await prefs.remove(key(connId));
    } else {
      await prefs.setString(key(connId), value);
    }
  }
}
