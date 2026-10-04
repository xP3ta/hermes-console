/// Unified-diff helpers for file-edit tool cards (Desktop parity:
/// `apps/desktop/src/components/chat/diff-lines.tsx`,
/// `tool/fallback-model/index.ts` `countDiffLineStats`/`inlineDiffFromResult`).
///
/// Hermes' `tool.complete.inline_diff` is the CLI rendering of the edit: a
/// `┊ review diff` header, an `a/x → b/x` arrow line per file and ANSI colour
/// on every line. Everything here works on the cleaned text.
library;

import 'ansi_text.dart';

enum DiffLineKind { add, remove, context, hunk }

final class DiffLine {
  final DiffLineKind kind;
  final String text;
  const DiffLine(this.kind, this.text);
}

final class DiffStats {
  final int added;
  final int removed;
  const DiffStats(this.added, this.removed);
  bool get isEmpty => added == 0 && removed == 0;
}

/// One file's slice of a (possibly multi-file) diff.
/// Debug-only tally of the input scanned by tool-card derivations, by kind
/// (`diff.parse`, `diff.stats`, `terminal.lines`, `terminal.tail`). Fed from
/// `assert`s, so release builds pay nothing; tests reset it and bound the
/// bytes a mount or a scroll may scan.
abstract final class DebugToolCardWork {
  static final Map<String, int> bytes = {};

  static int get total => bytes.values.fold(0, (a, b) => a + b);

  static void reset() => bytes.clear();

  /// Always true, for use inside `assert`.
  static bool record(String kind, int length) {
    bytes[kind] = (bytes[kind] ?? 0) + length;
    return true;
  }
}

final class FileDiff {
  final String path;
  final String diff;
  final DiffStats stats;
  FileDiff(this.path, this.diff) : stats = countDiffLineStats(diff);

  String get name => fileBasename(path);
}

/// The CLI `┊ review diff` header. Hermes localizes its text
/// (`display.diff.review_header`: «  ┊ revisar diff», «  ┊ Review-Diff»…),
/// so only the `┊` gutter marks it. A single leading space is a diff
/// context line (` ┊ status rail`), never the header.
final RegExp _reviewHeader = RegExp(r'^(?:\s{2,})?┊');

/// Strips ANSI and the CLI `┊ review diff` header in any locale (Desktop
/// `stripInlineDiffChrome`). Only leading chrome goes: once the diff body
/// starts, a `┊` is source text. Returns '' for blank input.
String cleanInlineDiff(String raw) {
  if (raw.trim().isEmpty) return '';
  final lines = stripAnsi(raw).split('\n');
  var start = 0;
  while (start < lines.length &&
      (lines[start].trim().isEmpty || _reviewHeader.hasMatch(lines[start]))) {
    start++;
  }
  // trimRight only: a leading space is the first context line's prefix.
  return lines.sublist(start).join('\n').trimRight();
}

DiffStats countDiffLineStats(String diff) {
  assert(DebugToolCardWork.record('diff.stats', diff.length));
  var added = 0;
  var removed = 0;
  for (final line in diff.split('\n')) {
    if (line.startsWith('+') && !line.startsWith('+++')) {
      added++;
    } else if (line.startsWith('-') && !line.startsWith('---')) {
      removed++;
    }
  }
  return DiffStats(added, removed);
}

String fileBasename(String path) {
  final parts = path
      .replaceAll(r'\', '/')
      .trim()
      .split('/')
      .where((p) => p.isNotEmpty)
      .toList();
  return parts.isEmpty ? path.trim() : parts.last;
}

bool _isArrowHeader(String line) {
  final t = line.trim();
  return t.contains('→') &&
      RegExp(r'^\S.*→\s*\S+$').hasMatch(t) &&
      !RegExp(r'^[+\-@]').hasMatch(t);
}

String _stripGitPrefix(String path) {
  final p = path.trim();
  if (p == '/dev/null') return '';
  if (p.startsWith('a/') || p.startsWith('b/')) return p.substring(2);
  return p;
}

/// Splits a cleaned diff into per-file sections. Sections start at an
/// `a → b` arrow line or a `--- ` header; a diff without any header is one
/// section named [fallbackPath].
List<FileDiff> splitFileDiffs(String diff, {String fallbackPath = ''}) {
  final sections = <({String path, List<String> lines})>[];
  String? pendingFrom;
  for (final line in diff.split('\n')) {
    if (_isArrowHeader(line)) {
      final parts = line.split('→');
      final to = _stripGitPrefix(parts.last);
      final from = _stripGitPrefix(parts.first);
      sections.add((path: to.isNotEmpty ? to : from, lines: <String>[]));
      pendingFrom = null;
      continue;
    }
    if (line.startsWith('--- ')) {
      pendingFrom = _stripGitPrefix(line.substring(4));
      continue;
    }
    if (line.startsWith('+++ ')) {
      final to = _stripGitPrefix(line.substring(4));
      final path = to.isNotEmpty ? to : (pendingFrom ?? '');
      // An arrow header right before already opened this file's section.
      if (sections.isEmpty ||
          sections.last.lines.isNotEmpty ||
          sections.last.path != path) {
        sections.add((path: path, lines: <String>[]));
      }
      pendingFrom = null;
      continue;
    }
    if (line.startsWith('diff --git') || line.startsWith('index ')) continue;
    if (sections.isEmpty) {
      sections.add((path: fallbackPath, lines: <String>[]));
    }
    sections.last.lines.add(line);
  }
  return [
    for (final section in sections)
      if (section.lines.any((l) => l.trim().isNotEmpty))
        FileDiff(
          section.path.isEmpty ? fallbackPath : section.path,
          section.lines.join('\n').trim(),
        ),
  ];
}

/// Renderable lines of one file's diff: file headers dropped, hunk headers
/// kept as a separator kind. Markers stay so the text copies as a diff.
List<DiffLine> parseDiffLines(String diff) {
  assert(DebugToolCardWork.record('diff.parse', diff.length));
  final out = <DiffLine>[];
  for (final line in diff.split('\n')) {
    if (line.startsWith('+++ ') ||
        line.startsWith('--- ') ||
        line.startsWith('diff --git') ||
        line.startsWith('index ') ||
        line.startsWith(r'\') ||
        _isArrowHeader(line)) {
      continue;
    }
    final kind = line.startsWith('@@')
        ? DiffLineKind.hunk
        : line.startsWith('+')
        ? DiffLineKind.add
        : line.startsWith('-')
        ? DiffLineKind.remove
        : DiffLineKind.context;
    out.add(DiffLine(kind, line));
  }
  while (out.isNotEmpty && out.last.text.trim().isEmpty) {
    out.removeLast();
  }
  return out;
}
