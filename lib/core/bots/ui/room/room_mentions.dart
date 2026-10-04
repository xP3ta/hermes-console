final RegExp roomMentionPattern = RegExp(
  r'@([A-Za-z0-9][A-Za-z0-9._:-]*)',
  caseSensitive: false,
);

/// Resolves room mentions with the same fallback rules as the hosted-room
/// driver. Returned handles retain roster spelling and order.
List<String> resolveRoomMentions(
  Iterable<String> texts,
  Iterable<String> members, {
  bool defaultAll = true,
}) {
  final roster = List<String>.unmodifiable(members);
  final byHandle = {for (final handle in roster) handle.toLowerCase(): handle};
  final mentioned = <String>{};
  var everyone = false;

  for (final text in texts) {
    for (final match in roomMentionPattern.allMatches(text)) {
      final handle = match.group(1)!.toLowerCase();
      if (handle == 'all' || handle == 'everyone') {
        everyone = true;
      } else if (byHandle.containsKey(handle)) {
        mentioned.add(handle);
      }
    }
  }

  if (everyone || (defaultAll && mentioned.isEmpty)) return roster;
  return [
    for (final handle in roster)
      if (mentioned.contains(handle.toLowerCase())) handle,
  ];
}

/// Returns the first typed token only when the text has mentions but none of
/// them addresses a room member or the broadcast aliases.
String? firstUnknownRoomMention(String text, Iterable<String> members) {
  final matches = roomMentionPattern.allMatches(text).toList();
  if (matches.isEmpty) return null;
  final tokens = [for (final match in matches) match.group(1)!];
  if (tokens.any((token) {
    final folded = token.toLowerCase();
    return folded == 'all' || folded == 'everyone';
  })) {
    return null;
  }
  if (resolveRoomMentions([text], members, defaultAll: false).isNotEmpty) {
    return null;
  }
  return tokens.first;
}
