import 'package:flutter/material.dart';

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
          PopupMenuButton<String>(
            key: const ValueKey('message-react-add'),
            tooltip: addTooltip,
            padding: EdgeInsets.zero,
            icon: Icon(
              Icons.add_reaction_outlined,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            onSelected: onPick,
            itemBuilder: (_) => [
              for (final emoji in kQuickReactions)
                PopupMenuItem<String>(value: emoji, child: Text(emoji)),
            ],
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
