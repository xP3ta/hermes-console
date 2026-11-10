// How long a finished turn worked, by the server's own clock.
//
// The chat measures a turn on this phone (first step to the moment it sees
// the end). When Android cut the socket in the background, that moment is
// when the app came back and reconciled, minutes later («Trabajó 186 s» for
// a 41 s turn). Once the durable rows of the turn are in the transcript the
// server already says when it began (the user's prompt) and ended (its final
// row): that is the turn's duration.
library;

import '../models/activity_snapshot.dart' show measuredActivityDuration;
import 'chat_turn.dart' show isRealUserTurn;
import 'session_timestamp.dart';

/// The duration of the turn whose newest assistant row sits at [assistant]
/// in [newestFirst], from the server timestamps of its durable rows: its
/// final row (the assistant row itself, or a later-stamped tool or assistant
/// row of the same turn) minus its prompt (the nearest older real user row).
///
/// Null, so the caller keeps its own measure, when the final row is still
/// the local live row (no server time), the prompt is the local copy or has
/// no time, or the result is not plausible (not positive, or a day or more).
/// Never mixes a server time with this phone's clock.
Duration? serverTurnDuration(
  List<Map<String, dynamic>> newestFirst,
  int assistant,
) {
  if (assistant < 0 || assistant >= newestFirst.length) return null;
  final last = newestFirst[assistant];
  if (last['role'] != 'assistant') return null;
  final lastAt = _serverSeconds(last);
  if (lastAt == null) return null;
  var end = lastAt;
  var user = -1;
  for (var i = assistant + 1; i < newestFirst.length; i++) {
    if (isRealUserTurn(newestFirst[i])) {
      user = i;
      break;
    }
  }
  if (user < 0) return null;
  final start = _serverSeconds(newestFirst[user]);
  if (start == null) return null;
  for (var i = assistant + 1; i < user; i++) {
    final row = newestFirst[i];
    if (row['role'] != 'assistant' && row['role'] != 'tool') continue;
    final at = _serverSeconds(row);
    if (at != null && at > end) end = at;
  }
  final ms = ((end - start) * 1000).round();
  if (ms <= 0) return null;
  return measuredActivityDuration(Duration(milliseconds: ms));
}

/// A durable row's server time in seconds; null for the local copies (the
/// optimistic prompt, the live assistant row) and rows without a time.
double? _serverSeconds(Map<String, dynamic> row) {
  if (row['_optimistic'] == true || row['_pipeline'] == true) return null;
  final at = normalizeEpochTimestamp(row['timestamp']);
  return at == null || at <= 0 ? null : at;
}
