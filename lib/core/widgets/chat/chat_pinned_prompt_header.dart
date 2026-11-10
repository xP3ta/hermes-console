import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/floating.dart';
import '../../theme/app_theme.dart';
import '../../theme/hermes_tokens.dart';

/// The off-screen prompt's small glass arrow. The screen owns visibility and
/// scrolling; this target briefly reveals the destination before shrinking.
class ChatPinnedPromptHeader extends StatefulWidget {
  const ChatPinnedPromptHeader({
    super.key,
    required this.youLabel,
    required this.text,
    required this.attachmentCount,
    required this.semanticLabel,
    required this.hideLabel,
    required this.onTap,
    required this.onHide,
  });

  static const double maxHeight = 48;
  static const double maxWidth = 300;
  static Color surfaceOf(HermesThemeColors colors) =>
      HermesChrome.of(colors).opaque;

  final String youLabel;
  final String text;
  final int attachmentCount;
  final String semanticLabel;
  final String hideLabel;
  final VoidCallback onTap;
  final VoidCallback onHide;

  @override
  State<ChatPinnedPromptHeader> createState() => _ChatPinnedPromptHeaderState();
}

class _ChatPinnedPromptHeaderState extends State<ChatPinnedPromptHeader> {
  Timer? _hold;
  bool _revealed = false;

  void _tap() {
    _hold?.cancel();
    setState(() => _revealed = true);
    _hold = Timer(HermesMotion.promptReveal, () {
      if (mounted) setState(() => _revealed = false);
    });
    widget.onTap();
  }

  @override
  void dispose() {
    _hold?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final button = ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: ChatPinnedPromptHeader.maxWidth,
      ),
      child: _button(context),
    );
    return Semantics(
      container: true,
      button: true,
      label:
          '${widget.semanticLabel}: ${widget.youLabel} · ${widget.text}'
          '${widget.attachmentCount > 0 ? ' · 📎 ${widget.attachmentCount}' : ''}',
      onLongPress: widget.onHide,
      onLongPressHint: widget.hideLabel,
      onTap: _tap,
      excludeSemantics: true,
      child: HermesMotion.reduced(context)
          ? button
          : AnimatedSize(
              duration: HermesMotion.base,
              curve: HermesMotion.size,
              alignment: AlignmentDirectional.centerEnd,
              child: button,
            ),
    );
  }

  Widget _button(BuildContext context) => SizedBox(
    key: const ValueKey('chat-jump-to-prompt'),
    width: _revealed ? ChatPinnedPromptHeader.maxWidth : 48,
    height: 48,
    child: HermesFloatingSurface(
      onTap: _tap,
      onLongPress: widget.onHide,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_revealed)
            Expanded(
              child: Padding(
                padding: const EdgeInsetsDirectional.only(start: 12),
                child: Text(
                  '${widget.youLabel} · ${widget.text}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).hermes.textSecondary,
                  ),
                ),
              ),
            ),
          if (_revealed && widget.attachmentCount > 0) ...[
            const Icon(Icons.attach_file, size: 16),
            Text('${widget.attachmentCount}'),
          ],
          const SizedBox.square(
            dimension: 48,
            child: Icon(Icons.arrow_upward_rounded, size: 18),
          ),
        ],
      ),
    ),
  );
}
