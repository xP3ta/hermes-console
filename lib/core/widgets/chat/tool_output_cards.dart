import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../models/tool_output.dart';
import '../../theme/app_theme.dart';
import '../../utils/ansi_text.dart';
import '../../utils/unified_diff.dart';

/// Tool output cards for the chat transcript (Desktop parity:
/// `tool/fallback.tsx` FileDiffPanel + AnsiText, `thread/changed-files-card`).
///
/// Every card is collapsed by default and builds its heavy body (parsed diff
/// lines, ANSI spans) only once the user expands it, so a long transcript
/// with many edits pays for one row per card while scrolling.

const _mono = 'monospace';
const double _monoSize = 11.5;
const double _monoHeight = 1.4;

/// First page of diff lines, then one more page per «show more».
const int fileDiffPageLines = 80;

/// Lines of terminal output shown while folded.
const int terminalPreviewLines = 4;

/// Hard cap of rendered terminal lines once unfolded (tail kept).
const int terminalMaxLines = 400;

/// One count of a diff summary: at least two digits so stacked rows line up
/// (`+12 −03`).
String diffCountText(int value) => value.toString().padLeft(2, '0');

/// The one-line summary of a folded diff: `+12 −03 · file.dart`.
String diffSummaryText(DiffStats stats, String name) =>
    '+${diffCountText(stats.added)} −${diffCountText(stats.removed)} · $name';

/// Coloured `+12 −03` (both counts always shown, like the summary text).
TextSpan _diffCountSpan(DiffStats stats, HermesThemeColors colors) {
  const style = TextStyle(
    fontFamily: _mono,
    fontSize: 11,
    fontWeight: FontWeight.w600,
  );
  return TextSpan(
    children: [
      TextSpan(
        text: '+${diffCountText(stats.added)}',
        style: style.copyWith(color: colors.success),
      ),
      const TextSpan(text: ' '),
      TextSpan(
        text: '−${diffCountText(stats.removed)}',
        style: style.copyWith(color: colors.error),
      ),
    ],
  );
}

class _FoldRow extends StatelessWidget {
  const _FoldRow({
    required this.icon,
    required this.label,
    required this.expanded,
    required this.onTap,
    required this.semanticsLabel,
    this.trailing,
    this.rowKey,
    this.labelSpan,
  });

  final IconData icon;
  final String label;

  /// Styled label replacing [label]'s plain text (same text content).
  final InlineSpan? labelSpan;
  final bool expanded;
  final VoidCallback? onTap;
  final String semanticsLabel;
  final Widget? trailing;
  final Key? rowKey;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: onTap != null,
      expanded: onTap != null ? expanded : null,
      label: semanticsLabel,
      excludeSemantics: true,
      child: InkWell(
        key: rowKey,
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                Icon(icon, size: 14, color: colors.textSecondary),
                const SizedBox(width: 7),
                Flexible(
                  child: Text.rich(
                    labelSpan ?? TextSpan(text: label),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
                const Spacer(),
                if (onTap != null)
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 150),
                    child: Icon(
                      Icons.expand_more,
                      size: 16,
                      color: colors.textDisabled,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

BoxDecoration _boxDecoration(HermesThemeColors colors) => BoxDecoration(
  color: colors.background.withValues(alpha: 0.5),
  borderRadius: BorderRadius.circular(8),
  border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
);

/// Horizontally scrollable monospace block whose rows stretch to the widest
/// line, so add/remove tints run edge to edge.
class _HorizontalCode extends StatelessWidget {
  const _HorizontalCode({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        primary: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: IntrinsicWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// File edit diff
// ─────────────────────────────────────────────────────────────────────────────

/// One edited file folded to `+12 −03 · file.dart`; tap to unfold the
/// unified diff (Desktop FileDiffPanel header: DiffCount + basename).
class FileDiffCard extends StatefulWidget {
  const FileDiffCard({required this.file, super.key});

  final FileDiff file;

  @override
  State<FileDiffCard> createState() => _FileDiffCardState();
}

class _FileDiffCardState extends State<FileDiffCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final file = widget.file;
    final name = file.name.isEmpty ? '—' : file.name;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _FoldRow(
            rowKey: ValueKey('file-diff-row-${file.path}'),
            icon: Icons.difference_outlined,
            label: diffSummaryText(file.stats, name),
            labelSpan: TextSpan(
              children: [
                _diffCountSpan(file.stats, colors),
                TextSpan(text: ' · $name'),
              ],
            ),
            expanded: _expanded,
            semanticsLabel: s.tc1215DiffSemantics(
              name,
              file.stats.added,
              file.stats.removed,
            ),
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded) FileDiffBody(diff: file.diff),
        ],
      ),
    );
  }
}

/// The unfolded diff: parsed on first build, paged by [fileDiffPageLines].
class FileDiffBody extends StatefulWidget {
  const FileDiffBody({required this.diff, super.key});
  final String diff;

  @override
  State<FileDiffBody> createState() => _FileDiffBodyState();
}

class _FileDiffBodyState extends State<FileDiffBody> {
  late List<DiffLine> _lines = parseDiffLines(widget.diff);
  int _shown = fileDiffPageLines;

  @override
  void didUpdateWidget(FileDiffBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.diff != widget.diff) _lines = parseDiffLines(widget.diff);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final visible = _lines.take(_shown).toList(growable: false);
    final remaining = _lines.length - visible.length;
    final base = TextStyle(
      fontFamily: _mono,
      fontSize: _monoSize,
      height: _monoHeight,
      color: colors.textSecondary,
    );
    return Column(
      key: const ValueKey('file-diff-body'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: _boxDecoration(colors),
          clipBehavior: Clip.antiAlias,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _HorizontalCode(
            children: [
              for (final line in visible)
                Container(
                  color: switch (line.kind) {
                    DiffLineKind.add => colors.success.withValues(alpha: 0.12),
                    DiffLineKind.remove => colors.error.withValues(alpha: 0.12),
                    _ => null,
                  },
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    line.text.isEmpty ? ' ' : line.text,
                    softWrap: false,
                    style: switch (line.kind) {
                      DiffLineKind.add => base.copyWith(color: colors.success),
                      DiffLineKind.remove => base.copyWith(color: colors.error),
                      DiffLineKind.hunk => base.copyWith(
                        color: colors.textDisabled,
                      ),
                      DiffLineKind.context => base,
                    },
                  ),
                ),
            ],
          ),
        ),
        if (remaining > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('file-diff-show-more'),
              onPressed: () => setState(() => _shown += fileDiffPageLines * 2),
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 40),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                foregroundColor: colors.textSecondary,
                textStyle: const TextStyle(fontSize: 11.5),
              ),
              child: Text(s.tc1215DiffMoreLines(remaining)),
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Terminal output (ANSI)
// ─────────────────────────────────────────────────────────────────────────────

/// ANSI palette slot → theme colour (Desktop `lib/ansi.ts` maps the same
/// eight hues to its UI palette). Hues without a theme role are blended from
/// theme roles, so light/dark contrast follows the active theme.
Color? ansiPaletteColor(AnsiColorIndex? index, HermesThemeColors colors) {
  if (index == null) return null;
  final bright = index >= 8;
  return switch (index % 8) {
    0 => bright ? colors.textDisabled : colors.textSecondary,
    1 => colors.error,
    2 => colors.success,
    3 => colors.warning,
    4 => colors.accent,
    5 => colors.secondary,
    6 => Color.lerp(colors.accent, colors.success, 0.5),
    _ => bright ? colors.textPrimary : colors.textSecondary,
  };
}

/// Renders [text] with its ANSI SGR colours/bold; plain text skips parsing.
class AnsiTextView extends StatelessWidget {
  const AnsiTextView({
    required this.text,
    required this.style,
    this.maxLines,
    super.key,
  });

  final String text;
  final TextStyle style;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    if (!hasAnsi(text)) {
      return Text(text, softWrap: false, maxLines: maxLines, style: style);
    }
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          for (final segment in parseAnsi(text))
            TextSpan(
              text: segment.text,
              style: TextStyle(
                color: ansiPaletteColor(segment.fg, colors),
                fontWeight: segment.bold ? FontWeight.w700 : null,
              ),
            ),
        ],
      ),
      softWrap: false,
      maxLines: maxLines,
    );
  }
}

/// Terminal/execute_code output: folded it shows the last
/// [terminalPreviewLines] lines; unfolded the whole (tail-capped) output.
class TerminalOutputCard extends StatefulWidget {
  const TerminalOutputCard({required this.output, this.exitCode, super.key});

  final String output;
  final int? exitCode;

  @override
  State<TerminalOutputCard> createState() => _TerminalOutputCardState();
}

class _TerminalOutputCardState extends State<TerminalOutputCard> {
  bool _expanded = false;
  _TerminalLines _lines = _TerminalLines.empty;

  @override
  void initState() {
    super.initState();
    _lines = _TerminalLines(widget.output);
  }

  @override
  void didUpdateWidget(TerminalOutputCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.output != widget.output) {
      _lines = _TerminalLines(widget.output);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final exit = widget.exitCode;
    final failed = exit != null && exit != 0;
    final count = _lines.count;
    final foldable = count > terminalPreviewLines;
    final shown = _expanded || !foldable
        ? _lines.tail(terminalMaxLines)
        : _lines.tail(terminalPreviewLines);
    final style = TextStyle(
      fontFamily: _mono,
      fontSize: _monoSize,
      height: _monoHeight,
      color: colors.textSecondary,
    );
    final label = foldable && !_expanded
        ? s.tc1215OutputShowAll(math.min(count, terminalMaxLines))
        : s.tc1215TerminalOutput;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _FoldRow(
            rowKey: const ValueKey('terminal-output-row'),
            icon: Icons.terminal_rounded,
            label: label,
            expanded: _expanded,
            semanticsLabel: failed ? '$label, ${s.cevExitFailed(exit)}' : label,
            trailing: failed
                ? Text(
                    'exit $exit',
                    style: TextStyle(
                      fontFamily: _mono,
                      fontSize: 11,
                      color: colors.error,
                    ),
                  )
                : null,
            onTap: foldable
                ? () => setState(() => _expanded = !_expanded)
                : null,
          ),
          Container(
            key: ValueKey(
              _expanded ? 'terminal-output-full' : 'terminal-output-tail',
            ),
            decoration: _boxDecoration(colors),
            clipBehavior: Clip.antiAlias,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            child: _HorizontalCode(
              children: [
                AnsiTextView(
                  text: shown.text,
                  style: style,
                  maxLines: math.max(1, shown.lines),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Line view over a terminal output that never splits the whole string: the
/// folded card reads only its last lines (found from the end), so a long
/// output costs one newline count however often its row is rebuilt.
final class _TerminalLines {
  _TerminalLines(this.output) : count = '\n'.allMatches(output).length + 1;

  static final empty = _TerminalLines('');

  final String output;

  /// Number of lines of [output] (capped only when shown).
  final int count;

  final Map<int, ({String text, int lines})> _tails = {};

  /// The last [lines] lines (or all of them when fewer).
  ({String text, int lines}) tail(int lines) => _tails[lines] ??= () {
    if (count <= lines) return (text: output, lines: count);
    var start = output.length;
    for (var i = 0; i < lines; i++) {
      start = output.lastIndexOf('\n', start - 1);
    }
    return (text: output.substring(start + 1), lines: lines);
  }();
}

/// The card a finished tool contributes, or null when it has nothing to show.
Widget? toolOutputCard(ToolOutputRecord? record) {
  if (record == null) return null;
  if (record.hasDiff) {
    return Column(
      key: ValueKey('tool-output-${record.toolId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final file in record.files)
          FileDiffCard(key: ValueKey(file.path), file: file),
      ],
    );
  }
  if (record.hasOutput) {
    return TerminalOutputCard(
      key: ValueKey('tool-output-${record.toolId}'),
      output: record.output!,
      exitCode: record.exitCode,
    );
  }
  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Changed files per turn
// ─────────────────────────────────────────────────────────────────────────────

/// One row per edited file of a turn, first-touched order, edits of the same
/// file concatenated (Desktop `deriveChangedFiles`).
List<FileDiff> aggregateChangedFiles(Iterable<ToolOutputRecord?> records) {
  final byPath = <String, List<String>>{};
  for (final record in records) {
    if (record == null || !record.hasDiff) continue;
    for (final file in record.files) {
      if (file.path.isEmpty) continue;
      (byPath[file.path] ??= <String>[]).add(file.diff);
    }
  }
  return [
    for (final entry in byPath.entries)
      FileDiff(entry.key, entry.value.join('\n')),
  ];
}

/// «N files changed» closing out a turn; unfolds into per-file diff cards.
class ChangedFilesCard extends StatefulWidget {
  const ChangedFilesCard({required this.files, super.key});

  final List<FileDiff> files;

  @override
  State<ChangedFilesCard> createState() => _ChangedFilesCardState();
}

class _ChangedFilesCardState extends State<ChangedFilesCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final files = widget.files;
    if (files.isEmpty) return const SizedBox.shrink();
    var added = 0;
    var removed = 0;
    for (final file in files) {
      added += file.stats.added;
      removed += file.stats.removed;
    }
    final label = s.tc1215FilesChanged(files.length);
    return Container(
      key: const ValueKey('changed-files-card'),
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _FoldRow(
            rowKey: const ValueKey('changed-files-row'),
            icon: Icons.edit_note_rounded,
            label: label,
            expanded: _expanded,
            semanticsLabel: s.tc1215DiffSemantics(label, added, removed),
            trailing: Text.rich(
              _diffCountSpan(DiffStats(added, removed), colors),
              maxLines: 1,
            ),
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded)
            for (final file in files)
              FileDiffCard(key: ValueKey('changed-${file.path}'), file: file),
        ],
      ),
    );
  }
}
