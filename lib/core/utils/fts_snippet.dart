/// Highlighted spans of a Hermes session-search snippet.
///
/// Hermes' FTS layer wraps every matched term in the literal SQLite
/// `snippet()` delimiters `>>>` and `<<<` (hermes_state_search.py). Desktop
/// strips them (`stripFtsMarkers`, apps/desktop/src/app/chat/sidebar); here
/// the matched terms are painted highlighted instead, and a marker is never
/// shown raw: a `>>>` with no `<<<` after it (or the reverse) is dropped,
/// nested pairs highlight as one run, and markers inside code spans are
/// treated like any other.
library;

const ftsOpenMarker = '>>>';
const ftsCloseMarker = '<<<';

/// Private-use stand-ins that survive markdown/whitespace cleaning, so the
/// highlight can be carried through the same preview pipeline as plain rows.
const _openSentinel = '\uE000';
const _closeSentinel = '\uE001';

/// One run of snippet text, highlighted when it is a matched term.
final class FtsSnippetSpan {
  const FtsSnippetSpan(this.text, {this.highlighted = false});

  final String text;
  final bool highlighted;

  @override
  bool operator ==(Object other) =>
      other is FtsSnippetSpan &&
      other.text == text &&
      other.highlighted == highlighted;

  @override
  int get hashCode => Object.hash(text, highlighted);

  @override
  String toString() => highlighted ? '[$text]' : text;
}

/// True when [text] carries any FTS delimiter.
bool hasFtsMarkers(String text) =>
    text.contains(ftsOpenMarker) || text.contains(ftsCloseMarker);

/// [snippet] without any delimiter (Desktop's `stripFtsMarkers`).
String stripFtsMarkers(String snippet) =>
    snippet.replaceAll(ftsOpenMarker, '').replaceAll(ftsCloseMarker, '');

/// Splits [snippet] into plain and highlighted runs. Only balanced pairs
/// highlight; every delimiter is removed from the text.
List<FtsSnippetSpan> parseFtsSnippet(String snippet) =>
    _spansFromSentinels(_toSentinels(snippet));

/// [snippet] with each balanced delimiter pair replaced by private-use
/// sentinels and every unbalanced delimiter dropped. Run the result through
/// any text cleaning, then read it back with [ftsSpansFromSentinels].
String ftsSnippetWithSentinels(String snippet) => _toSentinels(snippet);

/// Reads back text produced by [ftsSnippetWithSentinels] (possibly cleaned,
/// truncated or compacted since): an unclosed run ends at the end.
List<FtsSnippetSpan> ftsSpansFromSentinels(String text) =>
    _spansFromSentinels(text);

String _toSentinels(String snippet) {
  if (!hasFtsMarkers(snippet)) return snippet;
  // Tokenize into text and delimiters, then pair them like brackets.
  final tokens = <String>[];
  var i = 0;
  var start = 0;
  while (i < snippet.length) {
    if (snippet.startsWith(ftsOpenMarker, i) ||
        snippet.startsWith(ftsCloseMarker, i)) {
      if (i > start) tokens.add(snippet.substring(start, i));
      tokens.add(snippet.substring(i, i + 3));
      i += 3;
      start = i;
    } else {
      i++;
    }
  }
  if (start < snippet.length) tokens.add(snippet.substring(start));

  final keep = List<bool>.filled(tokens.length, false);
  final open = <int>[];
  for (var t = 0; t < tokens.length; t++) {
    if (tokens[t] == ftsOpenMarker) {
      open.add(t);
    } else if (tokens[t] == ftsCloseMarker && open.isNotEmpty) {
      keep[open.removeLast()] = true;
      keep[t] = true;
    }
  }
  final out = StringBuffer();
  for (var t = 0; t < tokens.length; t++) {
    final token = tokens[t];
    if (token == ftsOpenMarker) {
      if (keep[t]) out.write(_openSentinel);
    } else if (token == ftsCloseMarker) {
      if (keep[t]) out.write(_closeSentinel);
    } else {
      out.write(token);
    }
  }
  return out.toString();
}

List<FtsSnippetSpan> _spansFromSentinels(String text) {
  final spans = <FtsSnippetSpan>[];
  final run = StringBuffer();
  var depth = 0;
  var runHighlighted = false;
  void flush() {
    if (run.isEmpty) return;
    final value = run.toString();
    run.clear();
    if (spans.isNotEmpty && spans.last.highlighted == runHighlighted) {
      final previous = spans.removeLast();
      spans.add(
        FtsSnippetSpan(previous.text + value, highlighted: runHighlighted),
      );
    } else {
      spans.add(FtsSnippetSpan(value, highlighted: runHighlighted));
    }
  }

  for (final char in text.split('')) {
    if (char == _openSentinel || char == _closeSentinel) {
      depth = char == _openSentinel ? depth + 1 : (depth > 0 ? depth - 1 : 0);
      final highlighted = depth > 0;
      if (highlighted != runHighlighted) {
        flush();
        runHighlighted = highlighted;
      }
      continue;
    }
    run.write(char);
  }
  flush();
  return spans;
}
