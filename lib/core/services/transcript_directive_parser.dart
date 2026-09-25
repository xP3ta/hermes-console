/// Transcript directives — the Desktop contract, mirrored.
///
/// The model addresses a renderer by emitting a paragraph of the form
/// `::name{key="value"}`. Only the ENTIRE trimmed paragraph counts as a
/// directive, so `std::vector` in prose or a directive glued to a sentence
/// stays prose. Which names are honoured is the caller's decision: an
/// unclaimed name (`::foo{a="b"}`) is rendered as the literal text it always
/// was. Attributes are untrusted model output; consumers validate their own.
///
/// Mirrors `apps/desktop/src/lib/transcript-directives.ts`
/// (`parseTranscriptDirective`, `DIRECTIVE_RE`, `ATTR_RE`).
library;

class ParsedTranscriptDirective {
  final String name;
  final Map<String, String> attrs;
  final String source;

  const ParsedTranscriptDirective({
    required this.name,
    required this.attrs,
    required this.source,
  });
}

/// Whole paragraph, nothing else: `::name` or `::name{...}`. Length caps bound
/// the attribute scan on adversarial input.
final RegExp _directiveRe = RegExp(
  r'^::([a-z][a-z0-9-]{0,63})(?:\{([^{}]{0,1024})\})?$',
);

/// `key="value"` pairs; single quotes accepted for model sloppiness.
final RegExp _attrRe = RegExp(
  r'''([a-z][\w-]{0,63})=(?:"([^"]*)"|'([^']*)')''',
  caseSensitive: false,
);

/// Parses [text] as a transcript directive. Returns null unless the ENTIRE
/// trimmed text is one directive. Pure and synchronous.
ParsedTranscriptDirective? parseTranscriptDirective(String text) {
  final trimmed = text.trim();
  // Cheap reject before the regex: directives are short single lines.
  if (!trimmed.startsWith('::') ||
      trimmed.length > 1200 ||
      trimmed.contains('\n')) {
    return null;
  }
  final match = _directiveRe.firstMatch(trimmed);
  if (match == null) return null;

  final attrs = <String, String>{};
  final body = match.group(2);
  if (body != null && body.isNotEmpty) {
    for (final pair in _attrRe.allMatches(body)) {
      attrs[pair.group(1)!.toLowerCase()] =
          pair.group(2) ?? pair.group(3) ?? '';
    }
  }
  return ParsedTranscriptDirective(
    name: match.group(1)!,
    attrs: Map<String, String>.unmodifiable(attrs),
    source: trimmed,
  );
}
