import 'package:flutter/material.dart';

import '../../design/modal.dart' show HermesAction, showHermesMenu;
import '../../models/message_reaction.dart';

/// Reaction chips under a message plus one button to add the user's own.
///
/// [onPick] receives the emoji that was tapped; choosing the user's current
/// emoji again retracts it, which the caller resolves. A null [onPick] makes
/// the row read-only.
class MessageReactionBar extends StatelessWidget {
  const MessageReactionBar({
    super.key,
    required this.reactions,
    required this.onPick,
    this.addTooltip = 'React',
  });

  final List<MessageReaction> reactions;
  final ValueChanged<String>? onPick;
  final String addTooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final reaction in reactions)
          _Chip(
            reaction: reaction,
            selected: reaction.author == MessageReactionAuthor.user,
            onTap: onPick == null ? null : () => onPick!(reaction.emoji),
            scheme: scheme,
          ),
        if (onPick != null)
          Builder(
            builder: (context) => IconButton(
              key: const ValueKey('message-react-add'),
              tooltip: addTooltip,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Icons.add_reaction_outlined,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
              onPressed: () async {
                final emoji = await showHermesMenu<String>(
                  context: context,
                  actions: [
                    for (final e in kQuickReactions)
                      HermesAction(value: e, label: e),
                  ],
                );
                if (emoji != null) onPick?.call(emoji);
              },
            ),
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.reaction,
    required this.selected,
    required this.onTap,
    required this.scheme,
  });

  final MessageReaction reaction;
  final bool selected;
  final VoidCallback? onTap;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? scheme.primaryContainer : scheme.surfaceContainerHigh,
      shape: StadiumBorder(
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
        ),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Text(reaction.emoji, style: const TextStyle(fontSize: 15)),
        ),
      ),
    );
  }
}
