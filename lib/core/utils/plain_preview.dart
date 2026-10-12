import 'markdown_clipboard.dart';

/// rt1215: the one-line plain text of an agent/server string, for every
/// preview (session rows, room cards, notifications, subagent goals, job
/// prompts, task items, descriptions). Markdown is rendered away instead of
/// shown: `**`/`__`/backticks/headings vanish, links keep their label, list
/// and quote markers go, `MEDIA:` attachment lines are dropped and
/// whitespace collapses to single spaces. [maxChars] cuts on a character
/// boundary with an ellipsis.
String plainPreview(String? raw, {int? maxChars}) {
  if (raw == null || raw.trim().isEmpty) return '';
  final lines = <String>[];
  for (final line in raw.split(RegExp(r'\r?\n'))) {
    if (_mediaLine.hasMatch(line)) continue;
    lines.add(
      line
          .replaceFirst(_quoteMarker, '')
          .replaceFirst(_listMarker, '')
          .replaceFirst(_taskMarker, ''),
    );
  }
  // Previews flattened by the server keep `MEDIA:` mid-line.
  final text = markdownToCompactText(
    lines.join('\n'),
  ).replaceAll(_inlineMedia, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (maxChars == null) return text;
  final runes = text.runes.toList(growable: false);
  if (runes.length <= maxChars) return text;
  return '${String.fromCharCodes(runes.take(maxChars - 1)).trimRight()}…';
}

/// Whether [text] carries Markdown worth rendering (emphasis, code,
/// headings, links, lists, quotes, fences). Plain prose stays a plain
/// `Text`, byte for byte.
bool looksLikeMarkdown(String text) => _markdownHint.hasMatch(text);

/// The section of streaming reasoning the reader cares about now: from the
/// last heading (`**Title**` alone on its line, or `# Title`) to the end.
/// Text without headings is returned whole.
String latestReasoningSection(String text) {
  final matches = _sectionHeading.allMatches(text).toList(growable: false);
  if (matches.isEmpty) return text;
  return text.substring(matches.last.start).trimLeft();
}

final RegExp _inlineMedia = RegExp(r'(?<=^|\s)MEDIA:\S+');
final RegExp _mediaLine = RegExp(r'^\s*MEDIA:\S');
final RegExp _quoteMarker = RegExp(r'^\s*(?:>\s?)+');
final RegExp _listMarker = RegExp(r'^\s*(?:[-*+]|\d{1,3}[.)])\s+');
final RegExp _taskMarker = RegExp(r'^\[[ xX]\]\s+');
final RegExp _markdownHint = RegExp(
  r'\*\*|__\S|`|^\s{0,3}#{1,6}\s|\]\(|^\s*(?:[-*+]|\d{1,3}[.)])\s+\S|^\s*>|'
  r'(?:^|\s)[*_][^\s*_][^*_\n]*[*_](?:\s|$|[.,;:!?])',
  multiLine: true,
);
final RegExp _sectionHeading = RegExp(
  r'^[ \t]*(?:\*\*[^*\n]+\*\*|#{1,6}[ \t]+\S[^\n]*)[ \t]*$',
  multiLine: true,
);
