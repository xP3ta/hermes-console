import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// One slim line pinned at the top of the transcript: the prompt of the turn
/// being read. Opaque on the screen background with a hairline below, so the
/// reply never shows through, and never taller than [maxHeight] at normal
/// text size.
class ChatPinnedPromptHeader extends StatelessWidget {
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

  static const double maxHeight = 36;

  final String youLabel;
  final String text;
  final int attachmentCount;
  final String semanticLabel;
  final String hideLabel;
  final VoidCallback onTap;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final secondary = TextStyle(
      fontSize: 11,
      height: 1.2,
      fontWeight: FontWeight.w600,
      color: colors.textSecondary,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(
          bottom: BorderSide(
            color: colors.divider.withValues(alpha: 0.6),
            width: 0.5,
          ),
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: maxHeight),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                label: semanticLabel,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onTap,
                  child: ExcludeSemantics(
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: 14,
                        top: 4,
                        bottom: 4,
                      ),
                      child: Row(
                        children: [
                          Text(youLabel, maxLines: 1, style: secondary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              text,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.2,
                                color: colors.textPrimary,
                              ),
                            ),
                          ),
                          if (attachmentCount > 0) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.attach_file,
                              size: 13,
                              color: colors.textSecondary,
                            ),
                            Text('$attachmentCount', style: secondary),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Semantics(
              button: true,
              label: hideLabel,
              child: Tooltip(
                message: hideLabel,
                child: GestureDetector(
                  key: const ValueKey('chat-pinned-prompt-dismiss'),
                  behavior: HitTestBehavior.opaque,
                  onTap: onHide,
                  child: SizedBox(
                    width: 40,
                    height: maxHeight,
                    child: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
