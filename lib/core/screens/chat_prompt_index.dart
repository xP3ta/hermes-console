/// Chat prompt index (jump to a prompt). Pure functions: they derive the
/// entries from the transcript that is already loaded, with no I/O or state.
///
/// Rules ported from Desktop's `deriveTimelineEntries`/`timelinePreview`: one
/// entry per user message with non-empty text, a preview with collapsed
/// whitespace and at most 120 characters ending in `…`, and the active entry =
/// the last prompt at or above the top edge (8 px of slack) or, if there is none,
/// the first painted one.
library;

import '../utils/chat_turn.dart';

const int chatPromptPreviewMax = 120;
const double chatPromptActiveSlack = 8;

class ChatPromptEntry {
  const ChatPromptEntry({
    required this.message,
    required this.messageIndex,
    required this.preview,
  });

  /// Transcript message (identity, used to find its anchor).
  final Map<String, dynamic> message;

  /// Position in the received list (newest first).
  final int messageIndex;
  final String preview;
}

String chatPromptPreview(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final runes = flat.runes.toList(growable: false);
  if (runes.length <= chatPromptPreviewMax) return flat;
  final head = String.fromCharCodes(runes.take(chatPromptPreviewMax - 1))
      .trimRight();
  return '$head…';
}

// A complete process notification: the whole row is one bracketed
// `[IMPORTANT: Background process …]`. A prompt that merely starts with those
// words (no closing bracket at the end of the row) is not matched.
final RegExp _completeProcessNotification = RegExp(
  r'^\[IMPORTANT: Background process [\s\S]*\]$',
);

/// True when [message] is a user row with text: the rows that open a turn and
/// appear in the prompt list.
///
/// Process-notification carriers (Hermes writes them as user rows) are not
/// prompts: Desktop's timeline skips them too. Only a row that is entirely the
/// notification is dropped (the structured carrier through the visible-content
/// projection, any other complete bracketed row through the anchored pattern),
/// so a real prompt that merely starts with the same words stays a prompt.
/// [isSystemRow] drops other rows the transcript paints as system chips
/// instead of prompts.
bool isChatPromptMessage(
  Map<String, dynamic> message, {
  bool Function(Map<String, dynamic> message)? isSystemRow,
}) {
  if (message['role'] != 'user') return false;
  final content = message['content'];
  if (content is! String || content.trim().isEmpty) return false;
  if (_completeProcessNotification.hasMatch(content.trim())) return false;
  if (projectedUserVisibleContent(message).trim().isEmpty) return false;
  return isSystemRow == null || !isSystemRow(message);
}

/// Index, in [newestFirst], of the prompt that opened the turn the row
/// [topIndex] belongs to (the one crossing the viewport's top edge). The prompt
/// is the nearest user row going back in time; the scan covers only the length of
/// that turn.
int? stickyPromptIndex(
  List<Map<String, dynamic>> newestFirst,
  int topIndex, {
  bool Function(Map<String, dynamic> message)? isSystemRow,
}) {
  if (topIndex < 0 || topIndex >= newestFirst.length) return null;
  for (var i = topIndex; i < newestFirst.length; i++) {
    if (isChatPromptMessage(newestFirst[i], isSystemRow: isSystemRow)) return i;
  }
  return null;
}

/// Entries of [newestFirst] (the chat transcript order), newest first.
List<ChatPromptEntry> deriveChatPromptEntries(
  List<Map<String, dynamic>> newestFirst, {
  bool Function(Map<String, dynamic> message)? isSystemRow,
}) {
  final entries = <ChatPromptEntry>[];
  for (var i = 0; i < newestFirst.length; i++) {
    final message = newestFirst[i];
    if (!isChatPromptMessage(message, isSystemRow: isSystemRow)) continue;
    entries.add(
      ChatPromptEntry(
        message: message,
        messageIndex: i,
        preview: chatPromptPreview(message['content'] as String),
      ),
    );
  }
  return entries;
}

/// Index of the active entry given each prompt's top edge relative to the
/// viewport (`null` if it is not painted). The order of [tops] is free.
int? activeChatPromptIndex(
  List<double?> tops, {
  double slack = chatPromptActiveSlack,
}) {
  int? atOrAbove;
  double? atOrAboveTop;
  int? first;
  double? firstTop;
  for (var i = 0; i < tops.length; i++) {
    final top = tops[i];
    if (top == null) continue;
    if (top <= slack && (atOrAboveTop == null || top > atOrAboveTop)) {
      atOrAbove = i;
      atOrAboveTop = top;
    }
    if (firstTop == null || top < firstTop) {
      first = i;
      firstTop = top;
    }
  }
  return atOrAbove ?? first;
}

/// Durable row id of the message (never the text). Same keys the transcript
/// service uses to identify rows.
int? chatPromptRowId(Map<String, dynamic> message) {
  for (final key in const ['_desktopRowId', 'row_id', '_row_id', 'id']) {
    final value = message[key];
    if (value is int) return value;
  }
  return null;
}

/// One row of the prompt list: loaded in the transcript ([message] not null)
/// or known only from the server index.
class ChatPromptItem {
  const ChatPromptItem({required this.preview, this.message, this.rowId});

  final String preview;

  /// Already loaded message; null if earlier pages must be fetched to reach it.
  final Map<String, dynamic>? message;

  /// Durable row id (`null` if the loaded message does not carry one).
  final int? rowId;
}

/// Merges the loaded prompts (newest first) with those of the server index.
/// Only index rows older than the oldest loaded prompt (or than
/// [oldestLoadedRowId] when known) are taken: the rest are already loaded.
/// Without a durable anchor nothing can be deduplicated and the index is
/// ignored. The result goes from newest to oldest.
List<ChatPromptItem> mergeChatPromptItems(
  List<ChatPromptEntry> loaded,
  Iterable<({int rowId, String preview})> remote, {
  int? oldestLoadedRowId,
}) {
  final items = <ChatPromptItem>[
    for (final entry in loaded)
      ChatPromptItem(
        preview: entry.preview,
        message: entry.message,
        rowId: chatPromptRowId(entry.message),
      ),
  ];
  var anchor = oldestLoadedRowId;
  for (final item in items) {
    final id = item.rowId;
    if (id != null && (anchor == null || id < anchor)) anchor = id;
  }
  if (anchor == null) return items;
  final older = [
    for (final entry in remote)
      if (entry.rowId < anchor) entry,
  ]..sort((a, b) => b.rowId.compareTo(a.rowId));
  final seen = <int>{};
  for (final entry in older) {
    if (!seen.add(entry.rowId)) continue;
    items.add(
      ChatPromptItem(
        preview: chatPromptPreview(entry.preview),
        rowId: entry.rowId,
      ),
    );
  }
  return items;
}
