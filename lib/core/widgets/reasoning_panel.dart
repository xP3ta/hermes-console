import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../utils/plain_preview.dart';
import 'compact_markdown.dart';

/// Glyph of every reasoning block (the same one the activity pill uses for
/// «thinking»).
const IconData reasoningPanelIcon = Icons.psychology_alt_rounded;

/// rt1215: the model's thinking as its own labelled block, never text
/// squeezed into a step row. A header (icon · «Pensamiento» [· 12 s] · live
/// dot while it streams) that folds the block, then an inset surface with a
/// left accent rule holding the reasoning as compact Markdown.
///
/// Folded to a few lines with a fade and «Ver todo»; while [live] the box
/// shows the latest section and follows the newest tokens unless the reader
/// scrolled up. Used live in the activity view and for finished reasoning in
/// the chat trace, so both read the same.
class ReasoningPanel extends StatefulWidget {
  const ReasoningPanel({
    required this.text,
    this.live = false,
    this.meta,
    this.bodyKey,
    this.foldedLines = 6,
    super.key,
  });

  final String text;

  /// Still streaming: latest section, follow the tail, live dot.
  final bool live;

  /// Appended to the label (`Pensamiento · 12 s`).
  final String? meta;

  /// Key of the folded body box (the activity view keeps
  /// `activity-now-reasoning` for its scroll contract).
  final Key? bodyKey;

  final int foldedLines;

  static const double fontSize = 12.5;
  static const double lineHeight = 1.45;

  @override
  State<ReasoningPanel> createState() => _ReasoningPanelState();
}

class _ReasoningPanelState extends State<ReasoningPanel> {
  bool _open = true;
  bool _showAll = false;
  bool _overflows = false;

  final ScrollController _controller = ScrollController();
  bool _followEnd = true;
  bool _atTop = true;
  bool _atEnd = true;

  @override
  void initState() {
    super.initState();
    _afterLayout();
  }

  @override
  void didUpdateWidget(ReasoningPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.live != widget.live) {
      _afterLayout();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Live box: pin to the newest line unless the reader scrolled up, then
  /// refresh the edge fades and the «Ver todo» offer.
  void _afterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final position = _controller.position;
      if (widget.live &&
          _followEnd &&
          position.pixels != position.maxScrollExtent) {
        position.jumpTo(position.maxScrollExtent);
      }
      _syncEdges(position);
    });
  }

  void _syncEdges(ScrollMetrics metrics) {
    final overflows = metrics.maxScrollExtent > 0.5;
    final atTop = metrics.pixels <= 0.5;
    final atEnd = metrics.pixels >= metrics.maxScrollExtent - 0.5;
    if (overflows == _overflows && atTop == _atTop && atEnd == _atEnd) return;
    setState(() {
      _overflows = overflows;
      _atTop = atTop;
      _atEnd = atEnd;
    });
  }

  bool _onScroll(ScrollNotification notification) {
    final metrics = notification.metrics;
    if ((notification is ScrollUpdateNotification &&
            notification.dragDetails != null) ||
        notification is ScrollEndNotification) {
      _followEnd = metrics.pixels >= metrics.maxScrollExtent - 4;
    }
    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification) {
      _syncEdges(metrics);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final label = widget.meta == null
        ? s.rt1215Thinking
        : '${s.rt1215Thinking} · ${widget.meta}';
    return Column(
      key: const ValueKey('reasoning-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _header(context, colors, label),
        if (_open) _surface(context, colors, s),
      ],
    );
  }

  Widget _header(BuildContext context, HermesThemeColors colors, String label) {
    return Semantics(
      button: true,
      expanded: _open,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('reasoning-panel-header'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => _open = !_open),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                Icon(reasoningPanelIcon, size: 16, color: colors.accentText),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                if (widget.live) ...[
                  const SizedBox(width: 6),
                  Container(
                    key: const ValueKey('reasoning-panel-live'),
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: colors.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
                const Spacer(),
                AnimatedRotation(
                  turns: _open ? 0.5 : 0,
                  duration: Motion.duration(context, Motion.fast),
                  child: Icon(
                    Icons.expand_more_rounded,
                    size: 18,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _surface(BuildContext context, HermesThemeColors colors, Strings s) {
    final scaler = MediaQuery.textScalerOf(context);
    final line =
        scaler.scale(ReasoningPanel.fontSize) * ReasoningPanel.lineHeight;
    final maxHeight = line * widget.foldedLines;
    final shown = widget.live && !_showAll
        ? latestReasoningSection(widget.text)
        : widget.text;
    final markdown = CompactMarkdown(
      data: shown.trim(),
      fontSize: ReasoningPanel.fontSize,
      streaming: widget.live,
    );
    final Widget body;
    if (_showAll) {
      body = KeyedSubtree(key: widget.bodyKey, child: markdown);
    } else {
      final box = ConstrainedBox(
        key: widget.bodyKey,
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: SingleChildScrollView(
            controller: _controller,
            // Folded history does not scroll inside the page: «Ver todo»
            // opens it. The live box scrolls so the reader can look back.
            physics: widget.live ? null : const NeverScrollableScrollPhysics(),
            child: SizedBox(width: double.infinity, child: markdown),
          ),
        ),
      );
      body = EdgeFade(
        key: const ValueKey('reasoning-panel-fade'),
        top: _overflows && !_atTop,
        bottom: _overflows && !_atEnd,
        child: box,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          key: const ValueKey('reasoning-panel-surface'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            border: Border(
              left: BorderSide(
                color: colors.accent.withValues(alpha: 0.55),
                width: 3,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              body,
              if (_overflows || _showAll)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const ValueKey('reasoning-panel-toggle'),
                    onPressed: () => setState(() {
                      _showAll = !_showAll;
                      if (!_showAll) {
                        _followEnd = true;
                        _afterLayout();
                      }
                    }),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      foregroundColor: colors.accentText,
                      textStyle: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    child: Text(_showAll ? s.designShowLess : s.designShowAll),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
