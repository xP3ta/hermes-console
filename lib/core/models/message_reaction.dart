/// Emoji reactions on a transcript row: at most one per author.
enum MessageReactionAuthor { user, agent }

/// Choices offered in the picker; the gateway accepts any emoji.
const List<String> kQuickReactions = ['👍', '❤️', '😂', '🎉', '👀'];

class MessageReaction {
  const MessageReaction({required this.emoji, required this.author});

  final String emoji;
  final MessageReactionAuthor author;

  @override
  bool operator ==(Object other) =>
      other is MessageReaction &&
      other.emoji == emoji &&
      other.author == author;

  @override
  int get hashCode => Object.hash(emoji, author);
}

/// Reads the gateway's `reactions` array; malformed rows are dropped and only
/// the first row of an author is kept.
List<MessageReaction> parseReactions(Object? raw) {
  if (raw is! List) return const [];
  final seen = <MessageReactionAuthor>{};
  final out = <MessageReaction>[];
  for (final row in raw) {
    if (row is! Map) continue;
    final emoji = row['emoji'];
    final author = switch (row['author']) {
      'user' => MessageReactionAuthor.user,
      'agent' => MessageReactionAuthor.agent,
      _ => null,
    };
    if (emoji is! String || emoji.isEmpty || author == null) continue;
    if (!seen.add(author)) continue;
    out.add(MessageReaction(emoji: emoji, author: author));
  }
  return out;
}

/// Result of [author] choosing [emoji]: replaces their reaction, retracts it
/// when it is the same emoji, clears it when [emoji] is null.
List<MessageReaction> applyReaction(
  List<MessageReaction> current,
  MessageReactionAuthor author,
  String? emoji,
) {
  final previous = current.where((r) => r.author == author).firstOrNull;
  final rest = [
    for (final r in current)
      if (r.author != author) r,
  ];
  if (emoji == null || emoji.isEmpty || previous?.emoji == emoji) return rest;
  return [...rest, MessageReaction(emoji: emoji, author: author)];
}

/// Optional gateway seam: sets, replaces or clears the user's reaction.
///
/// A persisted row names [rowId]; a live row that has no id yet names
/// [newestRole] (`user` or `assistant`). A null [emoji] clears.
abstract class HermesMessageReactionGateway {
  /// False once the server is known not to take reactions (or the connection
  /// is read-only); reactions are neither offered nor sent then.
  bool get messageReactionsAvailable;

  /// Learns whether the server has `message.react` without writing anything:
  /// the probe names only the session, which a server that has the method
  /// refuses with invalid params (-32602). Returns [messageReactionsAvailable]
  /// afterwards; a timeout or any other failure confirms nothing.
  Future<bool> confirmMessageReactions(String runtimeSessionId);

  Future<({int rowId, List<MessageReaction> reactions})> reactToMessage(
    String runtimeSessionId, {
    int? rowId,
    String? newestRole,
    String? emoji,
    String? profile,
  });
}
