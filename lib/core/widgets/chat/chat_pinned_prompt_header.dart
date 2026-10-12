import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// The prompt of the turn being read, pinned under the floating header.
///
/// QA 9493 (owner): a small floating chip centred under the header pill,
/// not a full-width band: "Tú: prompt" on one truncated line and a ×,
/// on the header buttons' surface made opaque (the reply never shows
/// through it) with their hairline border. The transcript keeps scrolling
/// under it at both sides. Never taller than [maxHeight] at normal text
/// size, never wider than [maxWidth].
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

  static const double maxHeight = 32;
  static const double maxWidth = 300;

  /// The chip's fill: the header buttons' tint over the screen background.
  static Color surfaceOf(HermesThemeColors colors) => Color.alphaBlend(
    colors.surfaceVariant.withValues(alpha: 0.92),
    colors.background,
  );

  final String youLabel;
  final String text;
  final int attachmentCount;
  final String semanticLabel;
  final String hideLabel;
  final VoidCallback onTap;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final secondary = TextStyle(
      fontSize: 11.5,
      height: 1.2,
      fontWeight: FontWeight.w700,
      color: colors.textSecondary,
    );
    final radius = BorderRadius.circular(maxHeight / 2);
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: maxHeight,
        maxWidth: maxWidth,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: surfaceOf(colors),
          borderRadius: radius,
          border: Border.all(color: colors.divider.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
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
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('$youLabel:', maxLines: 1, style: secondary),
                          const SizedBox(width: 6),
                          Flexible(
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
                    width: 36,
                    height: maxHeight,
                    child: Icon(
                      Icons.close_rounded,
                      size: 15,
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
