import 'package:flutter/foundation.dart';

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

  /// Bumped on every write or clear, so readers outside Bot Mode (Home's
  /// team and room approvals) repaint when Bots publishes a new read.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

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
    revision.value++;
  }

  void clear() {
    _entries.clear();
    revision.value++;
  }
}
