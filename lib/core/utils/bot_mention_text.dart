const botMentionPrefix = '\n\n[@mentions resolved from the Bot Mode roster — ';
final _mentionNote = RegExp(
  r'\n\n\[@mentions resolved from the Bot Mode roster — [\s\S]*\]$',
);

String stripBotMentionNote(String text) {
  final match = _mentionNote.firstMatch(text);
  return match != null && match.end == text.length
      ? text.substring(0, match.start)
      : text;
}

String botMentionNote(String text) =>
    text.substring(stripBotMentionNote(text).length);

String appendBotMentionNote(String text, String note) =>
    note.isEmpty ? text : '${stripBotMentionNote(text)}$note';
