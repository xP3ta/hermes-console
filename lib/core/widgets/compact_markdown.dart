import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../theme/app_theme.dart';
import 'chat/chat_markdown_body.dart';

/// Ink of a [CompactMarkdown] body.
enum CompactMarkdownTone {
  /// Secondary ink for the prose (reasoning, summaries); headings and bold
  /// keep the primary ink so the hierarchy reads at a glance.
  muted,

  /// Primary ink everywhere (a question the user must answer, a task body).
  body,
}

/// rt1215: the chat's own Markdown renderer ([ChatMarkdownBody]) with a
/// compact style sheet, for agent text outside the chat bubbles. A literal
/// `**Title**` line becomes a bold heading, inline code a mono pill, links
/// keep their label; the reader never sees Markdown syntax.
class CompactMarkdown extends StatelessWidget {
  const CompactMarkdown({
    required this.data,
    this.tone = CompactMarkdownTone.muted,
    this.fontSize = 13,
    this.streaming = false,
    this.onLinkTap,
    super.key,
  });

  final String data;
  final CompactMarkdownTone tone;
  final double fontSize;

  /// Closes half-written emphasis/fences of a text that is still growing.
  final bool streaming;

  final void Function(String? href)? onLinkTap;

  @override
  Widget build(BuildContext context) => ChatMarkdownBody(
    data: data,
    isStreaming: streaming,
    selectable: false,
    onLinkTap: onLinkTap,
    styleSheet: compactMarkdownStyleSheet(
      context,
      tone: tone,
      fontSize: fontSize,
    ),
  );
}

/// The compact sheet of [CompactMarkdown]: body at [fontSize] with a 1.45
/// line height, headings/bold in the primary ink, theme-driven colours only.
MarkdownStyleSheet compactMarkdownStyleSheet(
  BuildContext context, {
  CompactMarkdownTone tone = CompactMarkdownTone.muted,
  double fontSize = 13,
}) {
  final theme = Theme.of(context);
  final colors = theme.hermes;
  final ink = tone == CompactMarkdownTone.muted
      ? colors.textSecondary
      : colors.textPrimary;
  final body = (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
    fontSize: fontSize,
    height: 1.45,
    color: ink,
  );
  final heading = body.copyWith(
    color: colors.textPrimary,
    fontWeight: FontWeight.w700,
    height: 1.35,
  );
  return MarkdownStyleSheet(
    p: body,
    pPadding: EdgeInsets.zero,
    blockSpacing: 6,
    strong: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w700),
    em: const TextStyle(fontStyle: FontStyle.italic),
    del: const TextStyle(decoration: TextDecoration.lineThrough),
    code: TextStyle(
      backgroundColor: colors.surfaceVariant.withValues(alpha: 0.85),
      fontFamily: kChatCodeFontFamily,
      fontFamilyFallback: const ['monospace'],
      fontSize: fontSize - 1,
      letterSpacing: 0,
      color: colors.textPrimary,
    ),
    codeblockDecoration: BoxDecoration(
      color: colors.surfaceVariant,
      borderRadius: BorderRadius.circular(10),
    ),
    codeblockPadding: EdgeInsets.zero,
    a: TextStyle(
      color: colors.accentText,
      decoration: TextDecoration.underline,
      decorationColor: colors.accentText.withValues(alpha: 0.5),
    ),
    h1: heading.copyWith(fontSize: fontSize + 2),
    h2: heading.copyWith(fontSize: fontSize + 1.5),
    h3: heading.copyWith(fontSize: fontSize + 1),
    h4: heading,
    h5: heading,
    h6: heading,
    h1Padding: EdgeInsets.zero,
    h2Padding: EdgeInsets.zero,
    h3Padding: EdgeInsets.zero,
    listBullet: body,
    listIndent: 18,
    blockquote: body,
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: colors.divider, width: 2)),
    ),
    blockquotePadding: const EdgeInsets.only(left: 10),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: colors.divider)),
    ),
    tableBody: body,
    tableHead: heading,
  );
}

/// Fades the [top] and/or [bottom] edge of [child] to transparent over
/// [extent] logical pixels, so a clipped box never ends on a line cut in
/// half with a hard edge. With neither edge set it paints [child] as is.
class EdgeFade extends StatelessWidget {
  const EdgeFade({
    required this.child,
    this.top = false,
    this.bottom = false,
    this.extent = 18,
    super.key,
  });

  final Widget child;
  final bool top;
  final bool bottom;
  final double extent;

  @override
  Widget build(BuildContext context) {
    // Always a ShaderMask, even with no faded edge: toggling the wrapper
    // would remount the child and reset its scroll position.
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        final f = rect.height <= 0
            ? 0.0
            : (extent / rect.height).clamp(0.0, 0.5);
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            top ? Colors.transparent : Colors.black,
            Colors.black,
            Colors.black,
            bottom ? Colors.transparent : Colors.black,
          ],
          stops: [0, f, 1 - f, 1],
        ).createShader(rect);
      },
      child: child,
    );
  }
}

/// A box of at most [maxHeight] that shows the start of [child], clipped
/// with a bottom [EdgeFade] only when the child is taller; [onOverflow]
/// reports whether it is (to offer «Show all»).
class FoldedFadeBox extends StatefulWidget {
  const FoldedFadeBox({
    required this.maxHeight,
    required this.child,
    this.onOverflow,
    this.fadeKey,
    super.key,
  });

  final double maxHeight;
  final Widget child;
  final ValueChanged<bool>? onOverflow;
  final Key? fadeKey;

  @override
  State<FoldedFadeBox> createState() => _FoldedFadeBoxState();
}

class _FoldedFadeBoxState extends State<FoldedFadeBox> {
  final ScrollController _controller = ScrollController();
  bool _overflows = false;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  @override
  void didUpdateWidget(FoldedFadeBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    _measure();
  }

  void _measure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final overflows = _controller.position.maxScrollExtent > 0.5;
      if (overflows == _overflows) return;
      setState(() => _overflows = overflows);
      widget.onOverflow?.call(overflows);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final box = ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: SingleChildScrollView(
        controller: _controller,
        physics: const NeverScrollableScrollPhysics(),
        child: widget.child,
      ),
    );
    return EdgeFade(key: widget.fadeKey, bottom: _overflows, child: box);
  }
}
