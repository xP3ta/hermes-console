import '../models/desktop_active_session.dart';
import '../models/session.dart';

/// Keeps only the roster rows whose stored session the profile knows.
///
/// `session.active_list` lists every live runtime of the gateway process and
/// carries no profile, so applying it whole stamps another profile's live
/// session onto this one. Desktop never builds rows from the roster (its
/// sidebar paints only the profile's own list); neither may Console.
DesktopActiveSessionList filterRosterToKnown(
  DesktopActiveSessionList roster,
  Set<String> knownIds,
) => DesktopActiveSessionList(
  sessions: [
    for (final row in roster.sessions)
      if (knownIds.contains(row.storedSessionId)) row,
  ],
  hasMalformedRows: roster.hasMalformedRows,
);

/// Ids the profile knows: loaded rows (id, lineage root, parent), pinned ids
/// and roster ids that have a local chat of the profile.
Set<String> knownSessionIds({
  required Iterable<Session> sessions,
  required Iterable<String> pinnedIds,
  required DesktopActiveSessionList roster,
  required bool Function(String id) hasLocalChat,
}) {
  final known = <String>{...pinnedIds};
  for (final session in sessions) {
    known
      ..add(session.id)
      ..add(session.logicalId)
      ..addAll([?session.parentSessionId]);
  }
  for (final row in roster.sessions) {
    final id = row.storedSessionId;
    if (id != null && hasLocalChat(id)) known.add(id);
  }
  return known;
}
