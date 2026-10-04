/// Pure helpers and result types for side agents (`/btw`, `/bg`) and live
/// branching. They hold no state, so they can be tested without a chat.
library;

import 'dart:math' as math;

import 'chat_turn.dart';

/// How a typed `/btw` or `/bg` ended.
enum SideCommandOutcome {
  /// The request was accepted; its answer arrives as an event.
  started,

  /// The argument was empty: show the usage line, send nothing.
  usage,

  /// The server does not know the method (or the chat cannot use it): the
  /// caller falls back to the generic slash path, as Desktop does.
  unsupported,

  /// Read-only connection: nothing was sent.
  readOnly,

  /// The request failed for another reason.
  failed,
}

/// How a branch request ended.
enum BranchStatus {
  /// The child exists; open it by [BranchOutcome.storedSessionId].
  opened,

  /// A reply is streaming: Desktop refuses to branch then.
  busy,

  /// The chat has no live runtime to fork.
  noRuntime,

  /// Another branch of this chat is still pending.
  inFlight,

  /// The chosen message cannot be matched against the durable transcript.
  targetNotFound,

  /// The server answered 4008: there is no history yet.
  nothingToBranch,

  /// The server (or the chat) does not support branching.
  unsupported,

  /// Read-only connection.
  readOnly,

  /// Any other failure.
  failed,
}

final class BranchOutcome {
  final BranchStatus status;
  final String? storedSessionId;
  final String? title;
  final int messageCount;

  const BranchOutcome(
    this.status, {
    this.storedSessionId,
    this.title,
    this.messageCount = 0,
  });

  bool get opened => status == BranchStatus.opened;
}

/// True for a row the server counts in `_visible_branch_history`: a user or
/// assistant row with non-empty text. Rows the client synthesises itself
/// (pipeline placeholders, local notices) and hidden rows are not part of it.
bool isBranchHistoryRow(Map<String, dynamic> message) {
  final role = message['role'];
  if (role != 'user' && role != 'assistant') return false;
  if (message['_pipeline'] == true || message['_local'] == true) return false;
  if (message['display_kind'] == 'hidden') return false;
  final content = message['content'];
  return content is String && content.trim().isNotEmpty;
}

/// Where [target] sits in the branch history of [chronological] (oldest
/// first): its 1-based [count] in the user/assistant row space and whether it
/// is the last such row. Null when the target cannot be matched, never a guess.
///
/// Matching prefers the durable row id, then the durable message id, and only
/// then the text, which must identify exactly one row of the same role.
({int count, bool isLatest})? branchPositionOf(
  List<Map<String, dynamic>> chronological,
  Map<String, dynamic> target,
) {
  final history = chronological
      .where(isBranchHistoryRow)
      .toList(growable: false);
  if (!isBranchHistoryRow(target)) return null;
  int? index;
  final rowId = canonicalTranscriptRowId(target);
  if (rowId != null) {
    final matches = [
      for (var i = 0; i < history.length; i++)
        if (canonicalTranscriptRowId(history[i]) == rowId) i,
    ];
    if (matches.length == 1) index = matches.single;
  }
  if (index == null && rowId == null) {
    final messageId = canonicalTranscriptMessageId(target);
    if (messageId != null) {
      final matches = [
        for (var i = 0; i < history.length; i++)
          if (canonicalTranscriptMessageId(history[i]) == messageId) i,
      ];
      if (matches.length == 1) index = matches.single;
    }
  }
  if (index == null && canonicalTranscriptIdentity(target) == null) {
    final matches = [
      for (var i = 0; i < history.length; i++)
        if (history[i]['role'] == target['role'] &&
            history[i]['content'] == target['content'])
          i,
    ];
    if (matches.length == 1) index = matches.single;
  }
  if (index == null) return null;
  return (count: index + 1, isLatest: index == history.length - 1);
}

/// Random, single-use key for one branch action. It derives from nothing
/// secret: two keys only have to differ.
String newBranchIdempotencyKey([math.Random? random]) {
  final source = random ?? math.Random.secure();
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  return 'branch-${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}
