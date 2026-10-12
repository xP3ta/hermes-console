/// One unread model for every transcript: normal chats, bot chats and
/// rooms. Each surface classifies its own rows; the rules below decide what
/// the divider and the pill show, the same way everywhere.
///
/// * **News** is a visible message written by someone else. The reader's
///   own messages (from this device or another), tool/status/system rows,
///   internal rows and the deltas of a message being streamed are never
///   news (a streamed reply is one row, counted once).
/// * The **divider** ("new since you left") marks news that arrived while
///   the reader was away: the screen was closed, or hidden (app in the
///   background, another route or the App Lock on top) for at least
///   [UnreadPresence.leftAfter]. The screen opens, or re-opens, positioned
///   at the first such row. News that arrives while the reader is in the
///   chat never creates or moves the divider.
/// * The **pill** ("↓ N new") exists only while the reader is in the chat
///   and away from the bottom. It counts the news that arrived since they
///   left the bottom, or since the landing on the divider (which starts at
///   zero: the divider already shows that news).
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

/// What a transcript row is for the unread rules.
enum UnreadRowKind {
  /// A visible message from someone else.
  news,

  /// A message written by the reader.
  own,

  /// Everything else: tool, status, system, internal, dividers, typing.
  quiet,
}

/// Whether a row of [kind] counts for the divider and the pill.
bool unreadCounts(UnreadRowKind kind) => kind == UnreadRowKind.news;

/// Index (oldest first) of the first news row that arrived while the reader
/// was away: a row whose position is after the [seenThrough] watermark and
/// not after [arrivedThrough] (what was already there when the reader came
/// back). Null when there is no such row, or when nothing at or before the
/// watermark is loaded (then "new since" cannot be claimed).
int? unreadFirstAwayIndex<T>(
  List<T> oldestFirst, {
  required int seenThrough,
  required int arrivedThrough,
  required int Function(T row) positionOf,
  required UnreadRowKind Function(T row) kindOf,
}) {
  var hasOlder = false;
  for (var i = 0; i < oldestFirst.length; i++) {
    final row = oldestFirst[i];
    final at = positionOf(row);
    if (at <= seenThrough) {
      hasOlder = true;
      continue;
    }
    if (at > arrivedThrough) return null;
    if (hasOlder && unreadCounts(kindOf(row))) return i;
  }
  return null;
}

/// News rows positioned after [baseline]: the pill's count.
int unreadNewsAfter<T>(
  Iterable<T> rows, {
  required int baseline,
  required int Function(T row) positionOf,
  required UnreadRowKind Function(T row) kindOf,
}) {
  var count = 0;
  for (final row in rows) {
    if (positionOf(row) > baseline && unreadCounts(kindOf(row))) count++;
  }
  return count;
}

/// The pill shows only with something to count, while the reader is in the
/// chat (on screen) and reading away from the bottom.
bool unreadPillVisible({
  required bool present,
  required bool reading,
  required int count,
}) => present && reading && count > 0;

/// Whether the reader is in the chat, and whether an absence was long
/// enough to count as having left it.
final class UnreadPresence {
  UnreadPresence({this.clock});

  /// Test clock for presences created without one.
  @visibleForTesting
  static DateTime Function()? debugClock;

  /// A glance at another app or a notification is not leaving the chat.
  static const Duration leftAfter = Duration(minutes: 1);

  /// Clock of this presence (else [debugClock], else the wall clock).
  final DateTime Function()? clock;

  DateTime _now() => (clock ?? debugClock ?? DateTime.now)();
  DateTime? _hiddenAt;

  /// The chat is on screen with the app in the foreground.
  bool get present => _hiddenAt == null;

  /// The chat stopped being visible (background, covered, locked).
  void hide() => _hiddenAt ??= _now();

  /// The chat is visible again. True when the absence was long enough to
  /// count as having left: what arrived meanwhile belongs to the divider.
  bool show() {
    final at = _hiddenAt;
    if (at == null) return false;
    _hiddenAt = null;
    return _now().difference(at) >= leftAfter;
  }
}
