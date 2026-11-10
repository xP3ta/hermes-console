/// The last words of a thought that is still being written, as clean prose:
/// the Markdown the model wrote around them (`**Title**`, `` `code` ``,
/// `# heading`, `- item`, `[label](url)`) never reaches the reader.
///
/// Only well-formed pairs are removed, so a lone `*` (2*3*4), a `snake_case`
/// name or `__init__` stay as written. Text still streaming often ends in an
/// opening mark that has no partner yet (`**Checking rou`): a leftover `**` or
/// backtick that sits at a word edge is dropped as well.
///
/// Pure and cheap: it reads at most [window] characters from the end, so a
/// long thought costs the same as a short one on every streamed token.
String cleanReasoningTail(String text, {int keep = 280, int window = 700}) {
  if (text.trim().isEmpty) return '';
  var start = text.length > window ? text.length - window : 0;
  if (start > 0) {
    // Begin on a line, or at least not in the middle of a surrogate pair.
    final newline = text.indexOf('\n', start);
    if (newline >= 0 && newline < start + window ~/ 4) {
      start = newline + 1;
    } else if (_isLowSurrogate(text.codeUnitAt(start))) {
      start += 1;
    }
  }
  final lines = <String>[];
  for (final raw in text.substring(start).split(RegExp(r'\r?\n'))) {
    final line = _cleanLine(raw);
    if (line.isNotEmpty) lines.add(line);
  }
  final clean = lines.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (clean.length <= keep) return clean;
  var cut = clean.length - keep;
  if (_isLowSurrogate(clean.codeUnitAt(cut))) cut += 1;
  return clean.substring(cut).trimLeft();
}

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

final RegExp _heading = RegExp(r'^\s{0,3}#{1,6}\s+');
final RegExp _quote = RegExp(r'^\s*>\s?');
final RegExp _bullet = RegExp(r'^\s*[-*+]\s+(?=\S)');
final RegExp _link = RegExp(r'\[([^\]\n]+)\]\([^)\s]*\)');
final RegExp _strongStars = RegExp(r'\*\*(?=\S)(.+?)(?<=\S)\*\*');
final RegExp _strongUnderscores = RegExp(
  r'(?<!\w)__(?=\S)([^_\n]*\s[^_\n]*)(?<=\S)__(?!\w)',
);
final RegExp _code = RegExp(r'`([^`\n]+)`');
// A `**` or a backtick left without a partner, at a word edge.
final RegExp _strayStars = RegExp(r'(?:^|(?<=\s))\*\*|\*\*(?=\s|$)');
final RegExp _strayTick = RegExp(r'(?:^|(?<=\s))`|`(?=\s|$)');
// `__` left alone on its line, opening a word.
final RegExp _strayUnderscores = RegExp(r'(?:^|(?<=\s))__(?=\S)');

String _cleanLine(String raw) {
  var line = raw
      .replaceFirst(_heading, '')
      .replaceFirst(_quote, '')
      .replaceFirst(_bullet, '');
  line = line
      .replaceAllMapped(_link, (m) => m.group(1)!)
      .replaceAllMapped(_strongStars, (m) => m.group(1)!)
      .replaceAllMapped(_strongUnderscores, (m) => m.group(1)!)
      .replaceAllMapped(_code, (m) => m.group(1)!);
  line = line.replaceAll(_strayStars, '').replaceAll(_strayTick, '');
  if ('__'.allMatches(line).length == 1) {
    line = line.replaceAll(_strayUnderscores, '');
  }
  line = line.trim();
  // A list mark with nothing after it.
  return const {'-', '*', '+'}.contains(line) ? '' : line;
}

/// A thought laid out to be read: a line that is only `**Title**` becomes a
/// paragraph of its own (a blank line before and after it), so Markdown shows
/// it as a bold subtitle instead of folding it into the sentence beside it.
/// Nothing else changes, and text without `**` comes back as it is.
///
/// Streaming-safe: a title still being written (`**Chec`) is not one yet, and
/// what is already laid out stays a prefix of what the next call returns,
/// except where a title that has just closed gets its blank line.
String structureReasoning(String text) {
  if (!text.contains('**')) return text;
  final lines = text.split('\n');
  final out = <String>[];
  var fenced = false;
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    if (_fence.hasMatch(line)) fenced = !fenced;
    final title = !fenced && _isTitleLine(line);
    if (title && out.isNotEmpty && out.last.trim().isNotEmpty) out.add('');
    out.add(line);
    if (title &&
        index < lines.length - 1 &&
        lines[index + 1].trim().isNotEmpty) {
      out.add('');
    }
  }
  return out.join('\n');
}

final RegExp _fence = RegExp(r'^\s{0,3}(?:```|~~~)');

bool _isTitleLine(String line) {
  final trimmed = line.trim();
  if (trimmed.length < 5 ||
      !trimmed.startsWith('**') ||
      !trimmed.endsWith('**')) {
    return false;
  }
  final inner = trimmed.substring(2, trimmed.length - 2);
  return inner.trim().isNotEmpty && !inner.contains('**');
}
