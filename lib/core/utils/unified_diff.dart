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

/// The CLI review header, exactly as Hermes emits it: `_emit_inline_diff`
/// in `agent/display.py` prints `t("display.diff.review_header")`, one value
/// per `locales/<lang>.yaml`. Keep in sync with those files. Matching the
/// exact text (not a `┊` pattern) keeps body lines such as `  ┊ indented
/// source` (context space + source) or ` ┊ status rail`.
const List<String> kInlineDiffReviewHeaders = [
  '  ┊ hersien diff', // af
  '  ┊ مراجعة الفرق (diff)', // ar
  '  ┊ Review-Diff', // de
  '  ┊ review diff', // en
  '  ┊ revisar diff', // es
  '  ┊ diff de revue', // fr
  '  ┊ diff athbhreithnithe', // ga
  '  ┊ diff áttekintése', // hu
  '  ┊ diff della revisione', // it
  '  ┊ レビュー diff', // ja
  '  ┊ 리뷰 변경 사항', // ko
  '  ┊ diff de revisão', // pt
  '  ┊ проверить diff', // ru
  '  ┊ inceleme farkı', // tr
  '  ┊ diff перевірки', // uk
  '  ┊ 檢閱差異', // zh-hant
  '  ┊ 审查 diff', // zh
];

/// Exact headers, plus their unindented form (no diff body line starts
/// with `┊`), compared after trimRight.
final Set<String> _reviewHeaders = {
  for (final h in kInlineDiffReviewHeaders) ...[h, h.trimLeft()],
};

bool _isReviewHeader(String line) => _reviewHeaders.contains(line.trimRight());

/// Strips ANSI and the CLI review header in any locale (Desktop
/// `stripInlineDiffChrome`). Only leading chrome goes: once the diff body
/// starts, a `┊` is source text. Returns '' for blank input.
String cleanInlineDiff(String raw) {
  if (raw.trim().isEmpty) return '';
  final lines = stripAnsi(raw).split('\n');
  var start = 0;
  while (start < lines.length &&
      (lines[start].trim().isEmpty || _isReviewHeader(lines[start]))) {
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

/// Half-open character range `[start, end)` inside a line's text.
typedef DiffSpan = ({int start, int end});

/// A diff line placed in its file: the text without its `+`/`-`/space
/// marker, the old/new line numbers taken from the hunk headers and, on
/// paired `-`/`+` lines, the span that actually changed.
final class NumberedDiffLine {
  final DiffLineKind kind;

  /// Source text without the marker; the raw `@@` header for hunk rows.
  final String text;
  final int? oldLine;
  final int? newLine;

  /// New-side line range a hunk row covers (null when the header has none).
  final int? hunkStart;
  final int? hunkEnd;

  /// Changed span on a paired removed/added line (null: no highlight).
  final DiffSpan? change;

  const NumberedDiffLine(
    this.kind,
    this.text, {
    this.oldLine,
    this.newLine,
    this.hunkStart,
    this.hunkEnd,
    this.change,
  });

  /// The number shown in the gutter: removed lines keep their old number,
  /// everything else shows where it sits in the new file.
  int? get gutter => switch (kind) {
    DiffLineKind.remove => oldLine,
    DiffLineKind.hunk => null,
    _ => newLine,
  };
}

final RegExp _hunkRange = RegExp(
  r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@',
);

/// [parseDiffLines] with line numbers and intra-line change spans. Lines
/// before any numbered hunk header get no numbers.
List<NumberedDiffLine> numberDiffLines(String diff) {
  final raw = parseDiffLines(diff);
  final out = <NumberedDiffLine>[];
  int? oldNo;
  int? newNo;
  var i = 0;
  while (i < raw.length) {
    final line = raw[i];
    if (line.kind == DiffLineKind.hunk) {
      final m = _hunkRange.firstMatch(line.text);
      int? start;
      int? end;
      if (m != null) {
        oldNo = int.parse(m.group(1)!);
        newNo = int.parse(m.group(3)!);
        final count = int.parse(m.group(4) ?? '1');
        start = newNo;
        end = newNo + (count > 0 ? count - 1 : 0);
      } else {
        oldNo = null;
        newNo = null;
      }
      out.add(
        NumberedDiffLine(
          DiffLineKind.hunk,
          line.text,
          hunkStart: start,
          hunkEnd: end,
        ),
      );
      i++;
      continue;
    }
    if (line.kind == DiffLineKind.context) {
      out.add(
        NumberedDiffLine(
          DiffLineKind.context,
          line.text.startsWith(' ') ? line.text.substring(1) : line.text,
          oldLine: oldNo,
          newLine: newNo,
        ),
      );
      if (oldNo != null) oldNo++;
      if (newNo != null) newNo++;
      i++;
      continue;
    }
    // A block of removed lines followed by added lines: pair them in order
    // for the intra-line highlight.
    final removed = <String>[];
    while (i < raw.length && raw[i].kind == DiffLineKind.remove) {
      removed.add(raw[i].text.substring(1));
      i++;
    }
    final added = <String>[];
    while (i < raw.length && raw[i].kind == DiffLineKind.add) {
      added.add(raw[i].text.substring(1));
      i++;
    }
    final changes = <int, ({DiffSpan a, DiffSpan b})>{};
    for (var k = 0; k < removed.length && k < added.length; k++) {
      final c = intraLineChange(removed[k], added[k]);
      if (c != null) changes[k] = c;
    }
    for (var k = 0; k < removed.length; k++) {
      out.add(
        NumberedDiffLine(
          DiffLineKind.remove,
          removed[k],
          oldLine: oldNo,
          change: changes[k]?.a,
        ),
      );
      if (oldNo != null) oldNo++;
    }
    for (var k = 0; k < added.length; k++) {
      out.add(
        NumberedDiffLine(
          DiffLineKind.add,
          added[k],
          newLine: newNo,
          change: changes[k]?.b,
        ),
      );
      if (newNo != null) newNo++;
    }
  }
  return out;
}

/// The differing middle of two versions of a line (common prefix and
/// suffix trimmed). Null when the lines are equal or share nothing, where
/// a highlight would only repeat the row colour.
({DiffSpan a, DiffSpan b})? intraLineChange(String a, String b) {
  if (a == b) return null;
  final shorter = a.length < b.length ? a.length : b.length;
  var prefix = 0;
  while (prefix < shorter && a.codeUnitAt(prefix) == b.codeUnitAt(prefix)) {
    prefix++;
  }
  // Never split a surrogate pair.
  if (prefix > 0 && _isHighSurrogate(a.codeUnitAt(prefix - 1))) prefix--;
  var suffix = 0;
  while (suffix < shorter - prefix &&
      a.codeUnitAt(a.length - 1 - suffix) ==
          b.codeUnitAt(b.length - 1 - suffix)) {
    suffix++;
  }
  if (suffix > 0 && _isLowSurrogate(a.codeUnitAt(a.length - suffix))) {
    suffix--;
  }
  if (prefix == 0 && suffix == 0) return null;
  return (
    a: (start: prefix, end: a.length - suffix),
    b: (start: prefix, end: b.length - suffix),
  );
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;
