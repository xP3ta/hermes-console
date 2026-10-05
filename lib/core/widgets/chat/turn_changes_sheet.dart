import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/modal.dart';
import '../../theme/app_theme.dart';
import '../../utils/unified_diff.dart';
import '../projects/project_file_icons.dart';
import 'tool_output_cards.dart' show turnChangeTotals;

/// «Review its work»: every file a finished turn changed, in one surface.
///
/// The data is the turn's own file-edit tool outputs (`patch`, `write_file`,
/// `edit_file` diffs, see `aggregateChangedFiles`), so the review shows
/// exactly what this turn did, not the workspace's accumulated state.
///
/// Performance: each file is a sliver group whose rows are a fixed-extent
/// lazy list, so a 5,000-line diff builds only the rows on screen; each
/// file keeps its own fold/viewed state, so toggling one file rebuilds only
/// that file's header and list.

const _mono = 'monospace';
const double _monoSize = 12;
const double _monoHeight = 1.35;

/// Longest line rendered; longer lines are cut so one minified line cannot
/// make the whole review kilometres wide.
const int turnChangesMaxLineChars = 1000;

const double _barWidth = 3;
const double _gutterGap = 10;
const double _fileHeaderExtent = 48;

/// `+6 −1`, added in green and removed in red.
TextSpan _countSpan(DiffStats stats, HermesThemeColors colors, double size) {
  final style = TextStyle(
    fontFamily: _mono,
    fontSize: size,
    fontWeight: FontWeight.w600,
  );
  return TextSpan(
    children: [
      TextSpan(
        text: '+${stats.added}',
        style: style.copyWith(color: colors.success),
      ),
      const TextSpan(text: ' '),
      TextSpan(
        text: '−${stats.removed}',
        style: style.copyWith(color: colors.error),
      ),
    ],
  );
}

/// The compact «Δ N files · +a −b» entry point closing a finished turn.
/// Renders nothing when the turn changed no file.
class TurnChangesChip extends StatelessWidget {
  const TurnChangesChip({required this.files, super.key});

  final List<FileDiff> files;

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) return const SizedBox.shrink();
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final totals = turnChangeTotals(files);
    final label = s.tc1215TurnChangesChip(files.length);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Semantics(
          button: true,
          label: s.tc1215DiffSemantics(
            s.tc1215FilesChanged(files.length),
            totals.added,
            totals.removed,
          ),
          excludeSemantics: true,
          child: Material(
            color: colors.surface,
            shape: StadiumBorder(
              side: BorderSide(color: colors.divider.withValues(alpha: 0.7)),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('turn-changes-chip'),
              onTap: () => showTurnChangesSheet(context, files),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 36),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Center(
                    widthFactor: 1,
                    child: Text.rich(
                      TextSpan(
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: colors.textSecondary,
                        ),
                        children: [
                          TextSpan(text: 'Δ $label · '),
                          _countSpan(totals, colors, 12),
                        ],
                      ),
                      maxLines: 1,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the review over the chat with the app's floating surface, at full
/// height (spec 080: no bottom sheets). Drag the handle down to close.
Future<void> showTurnChangesSheet(BuildContext context, List<FileDiff> files) =>
    showHermesSurface<void>(
      context: context,
      surfaceKey: const ValueKey('turn-changes-sheet'),
      maxWidth: 960,
      maxHeightFactor: 1,
      builder: (_) => TurnChangesSheet(files: files),
    );

class TurnChangesSheet extends StatefulWidget {
  const TurnChangesSheet({required this.files, super.key});

  final List<FileDiff> files;

  @override
  State<TurnChangesSheet> createState() => _TurnChangesSheetState();
}

class _TurnChangesSheetState extends State<TurnChangesSheet> {
  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();
  late int _widestLine = _longestLine(widget.files);
  double _drag = 0;

  static int _longestLine(List<FileDiff> files) {
    var widest = 0;
    for (final file in files) {
      var start = 0;
      final diff = file.diff;
      while (start <= diff.length) {
        var end = diff.indexOf('\n', start);
        if (end < 0) end = diff.length;
        widest = math.max(widest, end - start);
        start = end + 1;
      }
    }
    return math.min(widest, turnChangesMaxLineChars + 1);
  }

  @override
  void didUpdateWidget(TurnChangesSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.files, widget.files)) {
      _widestLine = _longestLine(widget.files);
    }
  }

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _onDragEnd(DragEndDetails details) {
    final fling = (details.primaryVelocity ?? 0) > 700;
    if (_drag > 80 || fling) {
      Navigator.of(context).maybePop();
    } else {
      setState(() => _drag = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final files = widget.files;
    final totals = turnChangeTotals(files);
    final scaler = MediaQuery.textScalerOf(context);
    final codeStyle = TextStyle(
      fontFamily: _mono,
      fontSize: _monoSize,
      height: _monoHeight,
      color: colors.textPrimary,
    );
    final probe = TextPainter(
      text: TextSpan(text: '0000000000', style: codeStyle),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final metrics = _CodeMetrics(
      charWidth: probe.width / 10,
      rowExtent: math.max(20, probe.height + 4).ceilToDouble(),
      style: codeStyle,
    );
    probe.dispose();

    return Transform.translate(
      offset: Offset(0, _drag),
      child: SizedBox.expand(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (d) =>
                  setState(() => _drag = math.max(0, _drag + d.delta.dy)),
              onVerticalDragEnd: _onDragEnd,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 8),
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colors.divider,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                s.tc1215FilesChanged(files.length),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                  color: colors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text.rich(_countSpan(totals, colors, 12)),
                            ],
                          ),
                        ),
                        TextButton(
                          key: const ValueKey('turn-changes-done'),
                          onPressed: () => Navigator.of(context).maybePop(),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(64, 44),
                            foregroundColor: colors.accent,
                          ),
                          child: Text(
                            s.tc1215TurnChangesDone,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.divider.withValues(alpha: 0.6)),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final viewport = constraints.maxWidth;
                  // Gutter digits are sized per file; budget 6 here.
                  final codeWidth =
                      _barWidth +
                      metrics.charWidth * 6 +
                      _gutterGap * 2 +
                      metrics.charWidth * (_widestLine + 1);
                  final width = math.max(viewport, codeWidth);
                  return Scrollbar(
                    controller: _horizontal,
                    notificationPredicate: (n) => n.depth == 0,
                    child: SingleChildScrollView(
                      controller: _horizontal,
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: width,
                        height: constraints.maxHeight,
                        child: CustomScrollView(
                          key: const ValueKey('turn-changes-list'),
                          controller: _vertical,
                          slivers: [
                            for (var i = 0; i < files.length; i++)
                              _FileSection(
                                key: ValueKey('turn-changes-section-$i'),
                                index: i,
                                file: files[i],
                                metrics: metrics,
                                viewport: viewport,
                                horizontal: _horizontal,
                              ),
                            const SliverToBoxAdapter(
                              child: SizedBox(height: 24),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _CodeMetrics {
  const _CodeMetrics({
    required this.charWidth,
    required this.rowExtent,
    required this.style,
  });

  final double charWidth;
  final double rowExtent;
  final TextStyle style;
}

/// Keeps [child] on screen while the code under it scrolls sideways.
class _PinnedLeft extends StatelessWidget {
  const _PinnedLeft({
    required this.horizontal,
    required this.width,
    required this.child,
  });

  final ScrollController horizontal;
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: AnimatedBuilder(
        animation: horizontal,
        builder: (context, child) => Transform.translate(
          offset: Offset(horizontal.hasClients ? horizontal.offset : 0, 0),
          child: child,
        ),
        child: SizedBox(width: width, child: child),
      ),
    );
  }
}

/// One file: a sticky header and, unless folded, its lazy rows.
class _FileSection extends StatefulWidget {
  const _FileSection({
    required this.index,
    required this.file,
    required this.metrics,
    required this.viewport,
    required this.horizontal,
    super.key,
  });

  final int index;
  final FileDiff file;
  final _CodeMetrics metrics;
  final double viewport;
  final ScrollController horizontal;

  @override
  State<_FileSection> createState() => _FileSectionState();
}

class _FileSectionState extends State<_FileSection> {
  bool _collapsed = false;
  bool _viewed = false;
  List<NumberedDiffLine>? _lines;
  int _gutterDigits = 1;

  List<NumberedDiffLine> get _parsed => _lines ??= () {
    final lines = numberDiffLines(widget.file.diff);
    var widest = 0;
    for (final line in lines) {
      widest = math.max(widest, line.gutter ?? 0);
    }
    _gutterDigits = math.max(2, '$widest'.length);
    return lines;
  }();

  @override
  void didUpdateWidget(_FileSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.diff != widget.file.diff) _lines = null;
  }

  @override
  Widget build(BuildContext context) {
    final lines = _collapsed ? null : _parsed;
    return SliverMainAxisGroup(
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _FileHeaderDelegate(
            child: _PinnedLeft(
              horizontal: widget.horizontal,
              width: widget.viewport,
              child: _FileHeader(
                index: widget.index,
                file: widget.file,
                collapsed: _collapsed,
                viewed: _viewed,
                onToggle: () => setState(() => _collapsed = !_collapsed),
                onViewed: (value) => setState(() {
                  _viewed = value;
                  // Marking viewed folds the file; un-marking leaves it.
                  if (value) _collapsed = true;
                }),
              ),
            ),
          ),
        ),
        if (lines != null)
          SliverFixedExtentList(
            itemExtent: widget.metrics.rowExtent,
            delegate: SliverChildBuilderDelegate(
              (context, j) => _DiffRow(
                fileIndex: widget.index,
                rowIndex: j,
                line: lines[j],
                metrics: widget.metrics,
                gutterDigits: _gutterDigits,
                viewport: widget.viewport,
                horizontal: widget.horizontal,
              ),
              childCount: lines.length,
              addAutomaticKeepAlives: false,
            ),
          ),
      ],
    );
  }
}

class _FileHeaderDelegate extends SliverPersistentHeaderDelegate {
  _FileHeaderDelegate({required this.child});

  final Widget child;

  @override
  double get minExtent => _fileHeaderExtent;

  @override
  double get maxExtent => _fileHeaderExtent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => child;

  @override
  bool shouldRebuild(_FileHeaderDelegate oldDelegate) => true;
}

class _FileHeader extends StatelessWidget {
  const _FileHeader({
    required this.index,
    required this.file,
    required this.collapsed,
    required this.viewed,
    required this.onToggle,
    required this.onViewed,
  });

  final int index;
  final FileDiff file;
  final bool collapsed;
  final bool viewed;
  final VoidCallback onToggle;
  final ValueChanged<bool> onViewed;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final path = file.path.isEmpty ? '—' : file.path;
    return Material(
      color: Theme.of(context).dialogTheme.backgroundColor ?? colors.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: colors.divider.withValues(alpha: 0.5)),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                expanded: !collapsed,
                label: s.tc1215DiffSemantics(
                  path,
                  file.stats.added,
                  file.stats.removed,
                ),
                excludeSemantics: true,
                child: InkWell(
                  key: ValueKey('turn-changes-file-$index'),
                  onTap: onToggle,
                  child: SizedBox(
                    height: _fileHeaderExtent,
                    child: Row(
                      children: [
                        const SizedBox(width: 8),
                        AnimatedRotation(
                          turns: collapsed ? -0.25 : 0,
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 150),
                          child: Icon(
                            Icons.expand_more,
                            size: 18,
                            color: colors.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          projectFileIcon(file.name),
                          size: 16,
                          color: colors.textSecondary,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: _mono,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: viewed
                                  ? colors.textSecondary
                                  : colors.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text.rich(_countSpan(file.stats, colors, 12)),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Semantics(
              label: s.tc1215DiffViewedSemantics(file.name),
              child: Checkbox(
                key: ValueKey('turn-changes-viewed-$index'),
                value: viewed,
                onChanged: (value) => onViewed(value ?? false),
              ),
            ),
            ExcludeSemantics(
              child: Text(
                s.tc1215DiffViewed,
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
            ),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

class _DiffRow extends StatelessWidget {
  const _DiffRow({
    required this.fileIndex,
    required this.rowIndex,
    required this.line,
    required this.metrics,
    required this.gutterDigits,
    required this.viewport,
    required this.horizontal,
  });

  final int fileIndex;
  final int rowIndex;
  final NumberedDiffLine line;
  final _CodeMetrics metrics;
  final int gutterDigits;
  final double viewport;
  final ScrollController horizontal;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    if (line.kind == DiffLineKind.hunk) {
      final start = line.hunkStart;
      final end = line.hunkEnd;
      final label = start == null || end == null
          ? line.text
          : start == end
          ? s.tc1215DiffHunkLine(start)
          : s.tc1215DiffHunkLines(start, end);
      return ColoredBox(
        key: ValueKey('turn-changes-hunk-$fileIndex-$rowIndex'),
        color: colors.accent.withValues(alpha: 0.14),
        child: _PinnedLeft(
          horizontal: horizontal,
          width: viewport,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: metrics.style.copyWith(
                color: colors.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      );
    }
    final (Color tint, Color bar, Color mark) = switch (line.kind) {
      DiffLineKind.add => (
        colors.success.withValues(alpha: 0.12),
        colors.success,
        colors.success.withValues(alpha: 0.38),
      ),
      DiffLineKind.remove => (
        colors.error.withValues(alpha: 0.12),
        colors.error,
        colors.error.withValues(alpha: 0.38),
      ),
      _ => (Colors.transparent, Colors.transparent, Colors.transparent),
    };
    final number = line.gutter;
    return ColoredBox(
      key: ValueKey('turn-changes-line-$fileIndex-$rowIndex'),
      color: tint,
      child: Row(
        children: [
          SizedBox(
            width: _barWidth,
            child: ColoredBox(color: bar),
          ),
          SizedBox(
            width: metrics.charWidth * gutterDigits + _gutterGap,
            child: Text(
              number == null ? '' : '$number',
              key: ValueKey('turn-changes-gutter-$fileIndex-$rowIndex'),
              textAlign: TextAlign.right,
              maxLines: 1,
              style: metrics.style.copyWith(color: colors.textDisabled),
            ),
          ),
          const SizedBox(width: _gutterGap),
          Expanded(
            child: Text.rich(
              _codeSpan(line, mark, colors),
              softWrap: false,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: metrics.style.copyWith(
                color: line.kind == DiffLineKind.context
                    ? colors.textSecondary
                    : colors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The line's text, with the changed span (if any) on a stronger tint.
TextSpan _codeSpan(NumberedDiffLine line, Color mark, HermesThemeColors c) {
  var text = line.text;
  var cut = false;
  if (text.length > turnChangesMaxLineChars) {
    text = text.substring(0, turnChangesMaxLineChars);
    cut = true;
  }
  final change = line.change;
  if (change == null || change.start >= text.length) {
    return TextSpan(text: cut ? '$text…' : (text.isEmpty ? ' ' : text));
  }
  final end = math.min(change.end, text.length);
  return TextSpan(
    children: [
      if (change.start > 0) TextSpan(text: text.substring(0, change.start)),
      if (end > change.start)
        TextSpan(
          text: text.substring(change.start, end),
          style: TextStyle(backgroundColor: mark),
        ),
      if (end < text.length) TextSpan(text: text.substring(end)),
      if (cut) const TextSpan(text: '…'),
    ],
  );
}
