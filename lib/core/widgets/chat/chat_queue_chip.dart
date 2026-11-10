import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/floating.dart';
import '../../theme/app_theme.dart';
import 'chat_live_icon.dart';

/// Queued input above the composer. ActiveChat continues to own delivery.
class ChatQueueChip extends StatelessWidget {
  const ChatQueueChip({
    required this.text,
    required this.onOpen,
    required this.onRemove,
    super.key,
  });

  final String text;
  final VoidCallback onOpen;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SizedBox(
          key: const ValueKey('chat-queue-chip'),
          height: 48,
          child: Stack(
            alignment: Alignment.center,
            children: [
              const Positioned(
                left: 0,
                right: 0,
                top: 10,
                bottom: 10,
                child: IgnorePointer(
                  child: HermesFloatingSurface(
                    key: ValueKey('chat-queue-glass'),
                    shadow: false,
                    child: SizedBox.expand(),
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Semantics(
                      button: true,
                      label: '${s.rp1215BubbleQueued} · $text',
                      onTap: onOpen,
                      excludeSemantics: true,
                      child: InkWell(
                        key: const ValueKey('chat-queue-open'),
                        onTap: onOpen,
                        child: Padding(
                          padding: const EdgeInsetsDirectional.only(
                            start: 12,
                            end: 4,
                          ),
                          child: SizedBox(
                            height: 48,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ChatLiveIcon(
                                  ChatLiveGlyph.queued,
                                  size: 16,
                                  color: colors.textSecondary,
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    '${s.rp1215BubbleQueued} · $text',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: colors.textSecondary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('chat-queue-remove'),
                    onPressed: onRemove,
                    tooltip: s.chaQueueDelete,
                    constraints: const BoxConstraints.tightFor(
                      width: 48,
                      height: 48,
                    ),
                    icon: Icon(
                      Icons.close_rounded,
                      size: 15,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
