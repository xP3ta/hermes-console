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

class _DiffCount extends StatelessWidget {
  const _DiffCount(this.stats);
  final DiffStats stats;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final style = TextStyle(
      fontFamily: _mono,
      fontSize: 11,
      fontWeight: FontWeight.w600,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (stats.added > 0)
          Text('+${stats.added}', style: style.copyWith(color: colors.success)),
        if (stats.added > 0 && stats.removed > 0) const SizedBox(width: 5),
        if (stats.removed > 0)
          Text('−${stats.removed}', style: style.copyWith(color: colors.error)),
      ],
    );
  }
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
  });

  final IconData icon;
  final String label;
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
                  child: Text(
                    label,
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

/// One edited file: name with +/- counts; tap to unfold the unified diff.
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
            label: name,
            expanded: _expanded,
            semanticsLabel: s.tc1215DiffSemantics(
              name,
              file.stats.added,
              file.stats.removed,
            ),
            trailing: _DiffCount(file.stats),
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

Color? ansiPaletteColor(AnsiColorIndex? index, HermesThemeColors colors) {
  if (index == null) return null;
  return switch (index % 8) {
    0 => index >= 8 ? colors.textDisabled : colors.textSecondary,
    1 => colors.error,
    2 => colors.success,
    3 => colors.warning,
    4 => const Color(0xFF5B9BEA),
    5 => const Color(0xFFB57EDC),
    6 => const Color(0xFF4FB6BE),
    _ => colors.textPrimary,
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
  late List<String> _lines = _split(widget.output);

  static List<String> _split(String output) {
    final lines = output.split('\n');
    return lines.length > terminalMaxLines
        ? lines.sublist(lines.length - terminalMaxLines)
        : lines;
  }

  @override
  void didUpdateWidget(TerminalOutputCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.output != widget.output) _lines = _split(widget.output);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final exit = widget.exitCode;
    final failed = exit != null && exit != 0;
    final foldable = _lines.length > terminalPreviewLines;
    final shown = _expanded || !foldable
        ? _lines
        : _lines.sublist(_lines.length - terminalPreviewLines);
    final style = TextStyle(
      fontFamily: _mono,
      fontSize: _monoSize,
      height: _monoHeight,
      color: colors.textSecondary,
    );
    final label = foldable && !_expanded
        ? s.tc1215OutputShowAll(_lines.length)
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
                  text: shown.join('\n'),
                  style: style,
                  maxLines: math.max(1, shown.length),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
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
            trailing: _DiffCount(DiffStats(added, removed)),
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
