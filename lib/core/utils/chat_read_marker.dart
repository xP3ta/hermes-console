import 'chat_turn.dart';

/// Durable coordinate of a transcript row usable as a read marker, or null
/// for rows that only exist locally (optimistic prompt, live placeholder).
String? chatReadMarkerKey(Map<String, dynamic> message) {
  final messageId = canonicalTranscriptMessageId(message);
  if (messageId != null) return 'message:$messageId';
  final rowId = canonicalTranscriptRowId(message);
  return rowId == null ? null : 'row:$rowId';
}

/// Rows the user reads as "a message": real user turns and assistant replies
/// with text. Pipeline placeholders, runtime metadata and empty rows are not
/// news for the reader.
bool chatReadMarkerCountable(Map<String, dynamic> message) {
  if (message['_pipeline'] == true) return false;
  if (message['role'] == 'assistant') {
    final content = message['content'];
    return content is String && content.trim().isNotEmpty;
  }
  return isRealUserTurn(message);
}

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
