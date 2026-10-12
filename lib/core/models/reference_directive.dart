/// `@file:` / `@folder:` / `@url:` references inside sent message text, read
/// the way Hermes Desktop reads them (`reference-kinds.ts::REFERENCE_PATTERN`,
/// `directive-text.tsx::refChipLabel`) so a bubble can show a chip instead of
/// the raw directive with its backtick fence.
library;

import 'composer_reference.dart';

/// Hermes `agent/context_references.py::REFERENCE_PATTERN` for the kinds
/// Console renders: a quoted value (optionally with `:start[-end]`) is tried
/// before a bare `\S+` so a quoted path with spaces stays whole.
final RegExp _referencePattern = RegExp(
  r'''(?<![\w/])@(file|folder|url):((?:`[^`\n]+`|"[^"\n]+"|'[^'\n]+')(?::\d+(?:-\d+)?)?|\S+)''',
);

final RegExp _quotedValue = RegExp(
  r'''^(?:`([^`\n]+)`|"([^"\n]+)"|'([^'\n]+)')(?::(\d+)(?:-(\d+))?)?$''',
);
final RegExp _bareLineRange = RegExp(r'^(.+?):(\d+)(?:-(\d+))?$');

/// Prose punctuation after a bare value is not part of it (Hermes
/// `TRAILING_PUNCTUATION`).
const String _trailingPunctuation = ',.;!?';

/// One reference found in message text.
final class ReferenceDirective {
  final ComposerReferenceKind kind;

  /// Path or link without its quotes or line range.
  final String value;
  final int? lineStart;
  final int? lineEnd;

  /// Offsets of [raw] in the scanned text.
  final int start;
  final int end;

  /// The directive exactly as written, e.g. ``@file:`a.dart`:3-9``.
  final String raw;

  const ReferenceDirective({
    required this.kind,
    required this.value,
    required this.start,
    required this.end,
    required this.raw,
    this.lineStart,
    this.lineEnd,
  });

  String get label =>
      referenceChipLabel(kind, value, lineStart: lineStart, lineEnd: lineEnd);
}

/// References in [text], in order. Bare values lose trailing prose
/// punctuation, which stays in the surrounding text.
Iterable<ReferenceDirective> findReferenceDirectives(String text) sync* {
  if (!text.contains('@')) return;
  for (final match in _referencePattern.allMatches(text)) {
    final kind = composerReferenceKindFromWire(match.group(1)!);
    if (kind == null) continue;
    var rawValue = match.group(2)!;
    String value;
    int? lineStart;
    int? lineEnd;
    final quoted = _quotedValue.firstMatch(rawValue);
    if (quoted != null) {
      value = quoted.group(1) ?? quoted.group(2) ?? quoted.group(3)!;
      lineStart = int.tryParse(quoted.group(4) ?? '');
      lineEnd = int.tryParse(quoted.group(5) ?? '');
    } else {
      var cut = rawValue.length;
      while (cut > 0 && _trailingPunctuation.contains(rawValue[cut - 1])) {
        cut--;
      }
      if (cut == 0) continue;
      rawValue = rawValue.substring(0, cut);
      value = rawValue;
      if (kind != ComposerReferenceKind.url) {
        final ranged = _bareLineRange.firstMatch(rawValue);
        if (ranged != null) {
          value = ranged.group(1)!;
          lineStart = int.tryParse(ranged.group(2)!);
          lineEnd = int.tryParse(ranged.group(3) ?? '');
        }
      }
    }
    if (value.trim().isEmpty) continue;
    final raw = '@${match.group(1)}:$rawValue';
    yield ReferenceDirective(
      kind: kind,
      value: value,
      lineStart: lineStart,
      lineEnd: lineEnd,
      start: match.start,
      end: match.start + raw.length,
      raw: raw,
    );
  }
}

/// The chip text for a reference: host plus a short path for links,
/// basename plus line range for files and folders. Never the `@kind:` prefix
/// or a quote.
String referenceChipLabel(
  ComposerReferenceKind kind,
  String value, {
  int? lineStart,
  int? lineEnd,
}) {
  if (kind == ComposerReferenceKind.url) return _urlLabel(value);
  final trimmed = value.replaceFirst(RegExp(r'/+$'), '');
  final base = trimmed.isEmpty
      ? value
      : trimmed.substring(trimmed.lastIndexOf('/') + 1);
  final name = base.isEmpty ? value : base;
  if (lineStart == null) return name;
  return lineEnd == null ? '$name:$lineStart' : '$name:$lineStart-$lineEnd';
}

const int _maxUrlPathLength = 24;

String _urlLabel(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || uri.host.isEmpty) return value;
  final host = uri.host.replaceFirst(
    RegExp(r'^www\.', caseSensitive: false),
    '',
  );
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  var path = segments.join('/');
  if (uri.hasQuery) path = '$path?${uri.query}';
  if (path.isEmpty) return host;
  if (segments.length <= 2 && path.length <= _maxUrlPathLength) {
    return '$host/$path';
  }
  final first = segments.isEmpty ? path : segments.first;
  final head = first.length > _maxUrlPathLength
      ? first.substring(0, _maxUrlPathLength)
      : first;
  return '$host/$head/…';
}

/// [text] with every reference replaced by its chip label, for one-line
/// previews (session list, queued rows) that cannot render a chip.
String plainReferencePreview(String text) {
  final refs = findReferenceDirectives(text).toList();
  if (refs.isEmpty) return text;
  final out = StringBuffer();
  var cursor = 0;
  for (final ref in refs) {
    out
      ..write(text.substring(cursor, ref.start))
      ..write(ref.label);
    cursor = ref.end;
  }
  out.write(text.substring(cursor));
  return out.toString();
}
