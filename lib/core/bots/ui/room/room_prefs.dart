import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../models/hosted_groups.dart';
import '../../state/attention.dart';

/// Device-local key of one hosted room (authority + room id).
String roomPrefsKey(HostedGroupRoom room) =>
    '${room.authorityGatewayId}:${room.roomId}';

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
  /// Bumped whenever a seen marker or a dismissal is written, so surfaces
  /// that project attention (the Bots list, bot faces) refresh at once.
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  /// What the user already acknowledged in [room], read synchronously for
  /// attention projection.
  RoomAttentionAcks acksFor(HostedGroupRoom room);

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
  Future<void> setLastSeenSeq(String roomKey, int seq) async {
    await prefs.setInt(_seen(roomKey), seq);
    RoomLocalPrefs.changes.value++;
  }

  @override
  RoomAttentionAcks acksFor(HostedGroupRoom room) {
    final key = roomPrefsKey(room);
    return RoomAttentionAcks(
      seenSeq: prefs.getInt(_seen(key)),
      dismissedTasks: (prefs.getStringList(_dismissed(key)) ?? const [])
          .toSet(),
    );
  }

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
  Future<void> setDismissedTasks(String roomKey, Set<String> taskIds) async {
    final list = taskIds.toList();
    final bounded = list.length > roomDismissedTasksLimit
        ? list.sublist(list.length - roomDismissedTasksLimit)
        : list;
    await prefs.setStringList(_dismissed(roomKey), bounded);
    RoomLocalPrefs.changes.value++;
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

  @override
  RoomAttentionAcks acksFor(HostedGroupRoom room) {
    final key = roomPrefsKey(room);
    return RoomAttentionAcks(
      seenSeq: seen[key],
      dismissedTasks: {...?dismissed[key]},
    );
  }
}
