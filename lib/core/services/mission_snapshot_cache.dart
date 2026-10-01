import '../models/connection.dart';
import '../models/mission_control.dart';

/// Last Bot Mode snapshot per connection, in memory only.
///
/// Reopening Bot Mode paints what the user saw a moment ago and refreshes in
/// the background (like Desktop) instead of a blank "loading" state. Nothing
/// is written to disk: a killed process starts from a real read again.
final class MissionSnapshotCache {
  MissionSnapshotCache({this.capacity = 4});

  static final shared = MissionSnapshotCache();

  final int capacity;
  final Map<String, MissionBackendSnapshot> _entries = {};

  /// Same saved connection pointed at a different server is a different key.
  static String keyOf(SavedConnection connection) =>
      '${connection.id}|${connection.baseUrl}';

  MissionBackendSnapshot? read(SavedConnection connection) =>
      _entries[keyOf(connection)];

  void write(SavedConnection connection, MissionBackendSnapshot snapshot) {
    final key = keyOf(connection);
    _entries.remove(key);
    _entries[key] = snapshot;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  void clear() => _entries.clear();
}
