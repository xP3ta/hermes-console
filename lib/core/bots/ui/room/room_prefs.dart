import 'package:shared_preferences/shared_preferences.dart';

/// Room notification level (spec 070 S3 overflow → Notifications).
enum RoomNotificationLevel { all, mentions, muted }

/// Per-device Room UI state.
///
/// - `lastSeenSeq` feeds the "new since you left" divider (device-local by
///   nature, like a read marker).
/// - Notification level: Desktop has no shared per-room key in
///   `ui_meta['hermes-bots-groups']` and `groups.*` exposes none, so this is
///   stored locally. TODO(spec070-G?): move to a Desktop-compatible
///   `ui_meta` key once Hermes defines one.
abstract interface class RoomLocalPrefs {
  Future<int?> lastSeenSeq(String roomKey);
  Future<void> setLastSeenSeq(String roomKey, int seq);
  Future<RoomNotificationLevel> notificationLevel(String roomKey);
  Future<void> setNotificationLevel(
    String roomKey,
    RoomNotificationLevel level,
  );

  /// Failed-task cards the user dismissed on this device. The server keeps
  /// no "seen" flag for `pending_actions`, so the dismissal is local; it is
  /// keyed by the exact task id, so a later failure is never hidden.
  Future<Set<String>> dismissedTasks(String roomKey);
  Future<void> setDismissedTasks(String roomKey, Set<String> taskIds);
}

/// Dismissed task ids kept per room; bounded so it never grows forever.
const roomDismissedTasksLimit = 64;

final class SharedPreferencesRoomPrefs implements RoomLocalPrefs {
  final SharedPreferences prefs;
  const SharedPreferencesRoomPrefs(this.prefs);

  static String _seen(String key) => 'room.lastSeenSeq.$key';
  static String _notify(String key) => 'room.notifications.$key';
  static String _dismissed(String key) => 'room.dismissedTasks.$key';

  @override
  Future<int?> lastSeenSeq(String roomKey) async =>
      prefs.getInt(_seen(roomKey));

  @override
  Future<void> setLastSeenSeq(String roomKey, int seq) =>
      prefs.setInt(_seen(roomKey), seq);

  @override
  Future<RoomNotificationLevel> notificationLevel(String roomKey) async {
    final raw = prefs.getString(_notify(roomKey));
    return RoomNotificationLevel.values.firstWhere(
      (level) => level.name == raw,
      orElse: () => RoomNotificationLevel.all,
    );
  }

  @override
  Future<void> setNotificationLevel(
    String roomKey,
    RoomNotificationLevel level,
  ) => prefs.setString(_notify(roomKey), level.name);

  @override
  Future<Set<String>> dismissedTasks(String roomKey) async =>
      (prefs.getStringList(_dismissed(roomKey)) ?? const <String>[]).toSet();

  @override
  Future<void> setDismissedTasks(String roomKey, Set<String> taskIds) {
    final list = taskIds.toList();
    final bounded = list.length > roomDismissedTasksLimit
        ? list.sublist(list.length - roomDismissedTasksLimit)
        : list;
    return prefs.setStringList(_dismissed(roomKey), bounded);
  }
}

final class MemoryRoomPrefs implements RoomLocalPrefs {
  final Map<String, int> seen = {};
  final Map<String, RoomNotificationLevel> levels = {};
  final Map<String, Set<String>> dismissed = {};

  @override
  Future<int?> lastSeenSeq(String roomKey) async => seen[roomKey];

  @override
  Future<void> setLastSeenSeq(String roomKey, int seq) async =>
      seen[roomKey] = seq;

  @override
  Future<RoomNotificationLevel> notificationLevel(String roomKey) async =>
      levels[roomKey] ?? RoomNotificationLevel.all;

  @override
  Future<void> setNotificationLevel(
    String roomKey,
    RoomNotificationLevel level,
  ) async => levels[roomKey] = level;

  @override
  Future<Set<String>> dismissedTasks(String roomKey) async => {
    ...?dismissed[roomKey],
  };

  @override
  Future<void> setDismissedTasks(String roomKey, Set<String> taskIds) async =>
      dismissed[roomKey] = {...taskIds};
}
