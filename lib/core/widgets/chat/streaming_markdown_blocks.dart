import 'package:flutter/material.dart';

import '../../utils/streaming_normalizer.dart';
import '../markdown_table.dart';

/// F1 of the fluidity plan (REPORT-AUDITORIA-FLUIDEZ §2.3.6): the closed
/// prefix of a live answer as a list of blocks, each projected once and
/// drawn in its own [RepaintBoundary].
///
/// Before, the prefix was one Markdown body: every paragraph that closed
/// re-parsed and re-laid out the whole prefix (audit §1.4, P2). Now closing
/// a paragraph adds one block and the ones before keep their widget, as
/// Desktop's `lib/markdown-blocks.ts` does with its append cache. The
/// boundaries live inside the live bubble, so the viewport lock still
/// measures the bubble as a whole.
///
/// [data] is the prepared and escaped prefix; each block is repaired on its
/// own ([normalizeStableStreamingPrefix] repairs the same cuts), so the text
/// drawn is the one the single body drew. Blocks that only draw the same
/// together stay together ([streamingMarkdownGroups]: loose lists, link
/// references), and one body puts the same 10 dp between its blocks as
/// [blockSpacing], so the column is as tall as the single body. A table
/// keeps the 4 dp the single body leaves around it ([streamingBlockGap]).
class StreamingMarkdownBlocks extends StatefulWidget {
  const StreamingMarkdownBlocks({
    required this.data,
    required this.markdown,
    this.onProjected,
    super.key,
  });

  final String data;
  final Widget Function(String data) markdown;

  /// Called once per block projected (parsed and built anew).
  final VoidCallback? onProjected;

  /// The space Markdown puts between two blocks of one body.
  static const double blockSpacing = 10;

  @override
  State<StreamingMarkdownBlocks> createState() =>
      _StreamingMarkdownBlocksState();
}

class _StreamingMarkdownBlocksState extends State<StreamingMarkdownBlocks> {
  final List<_Block> _blocks = [];
  ThemeData? _theme;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Theme.of can return a value-equal localized instance after the SDK's
    // global theme cache evicts it. Only a real theme change drops the blocks.
    if (!identical(theme, _theme) && theme != _theme) {
      _blocks.clear();
    }
    _theme = theme;
    final sources = [
      for (final block in streamingMarkdownGroups(widget.data))
        if (block.trim().isNotEmpty) block,
    ];
    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
      if (index < _blocks.length && _blocks[index].source == source) continue;
      widget.onProjected?.call();
      // The whole block is kept, key included: rebuilding the column hands
      // Flutter the same widget instance, so a block already drawn is not
      // even visited (gint48: a new KeyedSubtree around the cached child on
      // every build was a new widget each time).
      final drawn = normalizeStableStreamingPrefix(source);
      final block = (
        source: source,
        apartTop: _drawnApart(drawn, last: false),
        apartBottom: _drawnApart(drawn, last: true),
        widget: KeyedSubtree(
          key: ValueKey(('streaming-block', index)),
          child: RepaintBoundary(child: widget.markdown(drawn)),
        ),
      );
      if (index < _blocks.length) {
        _blocks[index] = block;
      } else {
        _blocks.add(block);
      }
    }
    if (_blocks.length > sources.length) {
      _blocks.removeRange(sources.length, _blocks.length);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < _blocks.length; index++) ...[
          if (index > 0)
            SizedBox(
              height: _blocks[index - 1].apartBottom || _blocks[index].apartTop
                  ? _segmentGap
                  : StreamingMarkdownBlocks.blockSpacing,
            ),
          _blocks[index].widget,
        ],
      ],
    );
  }
}

typedef _Block = ({
  String source,
  bool apartTop,
  bool apartBottom,
  Widget widget,
});

/// The space [chatAnswerSegmentWidgets] leaves around a table or a list of
/// sources, which are drawn on their own and not by the Markdown body.
const double _segmentGap = 4;

/// The space a live reply puts between the closed text [before] and the
/// text [after] it: [StreamingMarkdownBlocks.blockSpacing] between two
/// stretches of prose, as one Markdown body does, and the 4 dp the whole
/// reply leaves when either side is a table. With 10 there, the table
/// moved 6 dp when a long reply was split in two and moved back when it
/// finished.
///
/// Both sides are read as they are drawn: [before] is the closed text as
/// received, whose last paragraph is repaired here the way
/// [StreamingMarkdownBlocks] repairs it; [after] is the tail already
/// repaired for drawing.
double streamingBlockGap(String before, String after) {
  final closed = normalizeStableStreamingPrefix(_edge(before, last: true));
  return _apart(closed, last: true) || _drawnApart(after, last: false)
      ? _segmentGap
      : StreamingMarkdownBlocks.blockSpacing;
}

/// Whether the [last] (or first) block of [text] is a table (or the frame
/// of one still arriving), drawn on its own rather than as Markdown.
bool _drawnApart(String text, {required bool last}) =>
    _apart(_edge(text, last: last), last: last);

/// The paragraph at the end (or start) of [text], without the blank space
/// around it. A table holds no blank line, so that paragraph is enough;
/// the rest of [text] is not copied.
String _edge(String text, {required bool last}) {
  bool blank(int unit) =>
      unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D;
  if (last) {
    var end = text.length;
    while (end > 0 && blank(text.codeUnitAt(end - 1))) {
      end--;
    }
    final cut = end == 0 ? -1 : text.lastIndexOf('\n\n', end - 1);
    return text.substring(cut < 0 ? 0 : cut + 2, end);
  }
  var start = 0;
  while (start < text.length && blank(text.codeUnitAt(start))) {
    start++;
  }
  final cut = text.indexOf('\n\n', start);
  return text.substring(start, cut < 0 ? text.length : cut);
}

bool _apart(String edge, {required bool last}) {
  if (!edge.contains('|')) return false;
  final segments = splitAnswerTables(edge, live: true);
  if (segments.isEmpty) return false;
  return (last ? segments.last : segments.first) is! MarkdownSegment;
}
