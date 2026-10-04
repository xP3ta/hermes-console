import '../utils/session_timestamp.dart';
import 'session.dart';

/// How the Conversations list is ordered. A view preference kept on this
/// device: it never touches the server or the shared session archive.
///
/// Desktop's other keys (status) need live state this list does not keep.
enum SessionListSort {
  /// Last activity, newest first. The default and the list's original order.
  activity('activity'),

  /// Start of the conversation, newest first.
  created('created'),

  /// Input tokens, most first.
  tokens('tokens'),

  /// Estimated cost, most expensive first; rows without a cost go last.
  cost('cost');

  final String wire;
  const SessionListSort(this.wire);

  /// Unknown or missing values read as [activity].
  static SessionListSort fromWire(Object? value) {
    for (final sort in values) {
      if (sort.wire == value) return sort;
    }
    return activity;
  }

  /// Epoch seconds the date sections of [row] are cut on, or null when this
  /// key has no date sections (tokens and cost show a single section).
  double? dateFor(Session row) => switch (this) {
    SessionListSort.activity => row.lastActivityAt,
    SessionListSort.created => row.startedAt,
    SessionListSort.tokens || SessionListSort.cost => null,
  };

  int compare(Session a, Session b) {
    final primary = switch (this) {
      SessionListSort.activity => 0,
      SessionListSort.created => b.startedAt.compareTo(a.startedAt),
      SessionListSort.tokens => b.inputTokens.compareTo(a.inputTokens),
      SessionListSort.cost => (b.estimatedCostUsd ?? -1).compareTo(
        a.estimatedCostUsd ?? -1,
      ),
    };
    return primary != 0 ? primary : compareSessionsByRecentActivity(a, b);
  }
}

/// [rows] ordered by [sort]; ties fall back to recent activity. With
/// [pinnedFirst] the rows [isPinned] names stay on top whatever the key.
/// Returns a new list.
List<Session> sortSessionList(
  Iterable<Session> rows,
  SessionListSort sort, {
  required bool Function(Session) isPinned,
  bool pinnedFirst = true,
}) {
  final list = rows.toList();
  list.sort((a, b) {
    if (pinnedFirst) {
      final pa = isPinned(a) ? 0 : 1;
      final pb = isPinned(b) ? 0 : 1;
      if (pa != pb) return pa - pb;
    }
    return sort.compare(a, b);
  });
  return list;
}
