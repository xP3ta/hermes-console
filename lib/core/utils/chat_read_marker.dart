import 'chat_turn.dart';
import 'unread_rules.dart';

/// Durable coordinate of a transcript row usable as a read marker, or null
/// for rows that only exist locally (optimistic prompt, live placeholder).
String? chatReadMarkerKey(Map<String, dynamic> message) {
  final messageId = canonicalTranscriptMessageId(message);
  if (messageId != null) return 'message:$messageId';
  final rowId = canonicalTranscriptRowId(message);
  return rowId == null ? null : 'row:$rowId';
}

/// What a chat row is for the shared unread rules (unread_rules.dart):
/// assistant replies with text are news; the reader's own turns (sent from
/// this device or another) are theirs; pipeline placeholders, tool rows,
/// runtime metadata and empty rows are quiet. A streamed reply is one row,
/// so its deltas count once.
UnreadRowKind chatUnreadRowKind(Map<String, dynamic> message) {
  if (message['_pipeline'] == true) return UnreadRowKind.quiet;
  if (message['role'] == 'assistant') {
    final content = message['content'];
    return content is String && content.trim().isNotEmpty
        ? UnreadRowKind.news
        : UnreadRowKind.quiet;
  }
  return isRealUserTurn(message) ? UnreadRowKind.own : UnreadRowKind.quiet;
}

/// Rows that count for the divider, the pill and the read marker: news
/// only (never the reader's own messages).
bool chatReadMarkerCountable(Map<String, dynamic> message) =>
    unreadCounts(chatUnreadRowKind(message));

/// Newest countable row of a newest-first transcript.
Map<String, dynamic>? chatNewestCountableMessage(
  List<Map<String, dynamic>> messagesNewestFirst,
) {
  for (final message in messagesNewestFirst) {
    if (chatReadMarkerCountable(message)) return message;
  }
  return null;
}

/// Where [marker] sits in a newest-first transcript: the number of countable
/// rows newer than it and the oldest of them. Null when the marker is not in
/// the loaded transcript (then nothing can be claimed as new).
///
/// The marker matches by identity first (the same in-memory row) and then by
/// its durable [key], so a reconciled copy of the row still counts.
({int count, Map<String, dynamic>? oldestNew})? chatMessagesNewerThanMarker(
  List<Map<String, dynamic>> messagesNewestFirst, {
  Map<String, dynamic>? marker,
  String? key,
}) {
  if (marker == null && key == null) return null;
  var count = 0;
  Map<String, dynamic>? oldestNew;
  for (final message in messagesNewestFirst) {
    if (identical(message, marker) ||
        (key != null && chatReadMarkerKey(message) == key)) {
      return (count: count, oldestNew: oldestNew);
    }
    if (chatReadMarkerCountable(message)) {
      count++;
      oldestNew = message;
    }
  }
  return null;
}

const _seenAfterSeparator = '|seen=';

/// Read marker stored when the reader leaves a newest-first transcript.
///
/// The newest rows are often still local projections (the prompt just sent,
/// the reply watched live) with no durable id yet. The marker is then the
/// newest countable row that has one, plus how many newer countable rows the
/// reader already saw, so their durable copies are not news on return.
/// Null when no countable row has a durable coordinate.
String? chatReadMarkerForLeaving(
  List<Map<String, dynamic>> messagesNewestFirst,
) {
  var seenAfter = 0;
  for (final message in messagesNewestFirst) {
    if (!chatReadMarkerCountable(message)) continue;
    final key = chatReadMarkerKey(message);
    if (key != null) {
      return seenAfter == 0 ? key : '$key$_seenAfterSeparator$seenAfter';
    }
    seenAfter++;
  }
  return null;
}

/// Unread rows of a newest-first transcript against a marker stored by
/// [chatReadMarkerForLeaving]: how many countable rows are new, the oldest of
/// them and the newest row the reader had already seen. Null when the marker
/// is not in the loaded transcript.
({int count, Map<String, dynamic>? oldestNew, Map<String, dynamic> newestRead})?
chatUnreadSinceStoredMarker(
  List<Map<String, dynamic>> messagesNewestFirst,
  String stored,
) {
  var key = stored;
  var seenAfter = 0;
  final separator = stored.lastIndexOf(_seenAfterSeparator);
  if (separator > 0) {
    final parsed = int.tryParse(
      stored.substring(separator + _seenAfterSeparator.length),
    );
    if (parsed != null && parsed > 0) {
      key = stored.substring(0, separator);
      seenAfter = parsed;
    }
  }
  final newer = <Map<String, dynamic>>[];
  for (final message in messagesNewestFirst) {
    if (chatReadMarkerKey(message) == key) {
      final unread = newer.length - seenAfter;
      if (unread <= 0) {
        return (
          count: 0,
          oldestNew: null,
          newestRead: newer.isEmpty ? message : newer.first,
        );
      }
      return (
        count: unread,
        oldestNew: newer[unread - 1],
        newestRead: seenAfter == 0 ? message : newer[unread],
      );
    }
    if (chatReadMarkerCountable(message)) newer.add(message);
  }
  return null;
}
