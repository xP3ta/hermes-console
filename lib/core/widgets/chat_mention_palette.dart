import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/bot_mention.dart';
import '../services/bot_mention_roster.dart';
import '../theme/app_theme.dart';
import 'mission_profile_avatar.dart';

({int start, int end, String query})? chatMentionQuery(TextEditingValue value) {
  if (!value.selection.isValid ||
      !value.selection.isCollapsed ||
      (value.composing.isValid && !value.composing.isCollapsed)) {
    return null;
  }
  final end = value.selection.extentOffset;
  if (end > value.text.length) return null;
  final prefix = value.text.substring(0, end);
  final match = RegExp(
    r'(^|\s)@([a-z0-9_-]*)$',
    caseSensitive: false,
  ).firstMatch(prefix);
  if (match == null) return null;
  // A caret inside a token must not splice a second handle into its suffix.
  if (end < value.text.length &&
      RegExp(r'[a-z0-9_-]', caseSensitive: false).hasMatch(value.text[end])) {
    return null;
  }
  final start = end - match.group(2)!.length - 1;
  final before = value.text.substring(0, start);
  if ('```'.allMatches(before).length.isOdd) return null;
  final line = before.substring(before.lastIndexOf('\n') + 1);
  if ('`'.allMatches(line).length.isOdd) return null;
  return (start: start, end: end, query: match.group(2)!);
}

class ChatMentionPalette extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String connectionId;
  final String profile;
  final BotMentionRoster? roster;

  const ChatMentionPalette({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.connectionId,
    required this.profile,
    this.roster,
  });

  @override
  Widget build(BuildContext context) {
    final source = roster ?? BotMentionRoster.shared;
    return ListenableBuilder(
      listenable: Listenable.merge([controller, focusNode, source]),
      builder: (context, _) {
        final query = chatMentionQuery(controller.value);
        if (!focusNode.hasFocus || query == null) {
          return const SizedBox.shrink();
        }
        final matches = source
            .resolver(connectionId, profile)
            .suggestions(query.query);
        if (matches.isEmpty) return const SizedBox.shrink();
        final colors = Theme.of(context).hermes;
        return Semantics(
          label: Strings.of(context).chaMentionSuggestions,
          child: Container(
            key: const ValueKey('chat-mention-palette'),
            margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 22,
                  offset: const Offset(0, 9),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(17),
              child: Material(
                color: Colors.transparent,
                child: SizedBox(
                  height: 52,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    children: [for (final bot in matches) _chip(context, bot)],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _chip(BuildContext context, BotMention bot) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
    child: InkWell(
      canRequestFocus: false,
      borderRadius: BorderRadius.circular(20),
      onTap: () {
        final query = chatMentionQuery(controller.value);
        if (query == null || !focusNode.hasFocus) return;
        final current = (roster ?? BotMentionRoster.shared)
            .resolver(connectionId, profile)
            .resolve('@${bot.handle}');
        if (current.length != 1 || current.single.identity != bot.identity) {
          return;
        }
        controller.value = TextEditingValue(
          text: controller.text.replaceRange(
            query.start,
            query.end,
            '@${bot.handle} ',
          ),
          selection: TextSelection.collapsed(
            offset: query.start + bot.handle.length + 2,
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 12, 4),
        child: Row(
          children: [
            MissionProfileAvatar(
              profileName: bot.profile,
              hasAvatar: false,
              cache: null,
              size: 24,
              shape: bot.avatarProfile?.botShape,
              colorHex: bot.avatarProfile?.botColorHex,
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                [
                  '@${bot.handle}',
                  if (bot.title.isNotEmpty)
                    botMentionProse(bot.title)
                  else if (bot.displayName.isNotEmpty)
                    botMentionProse(bot.displayName),
                  if (bot.remote)
                    botMentionProse(
                      bot.connectionLabel.isEmpty
                          ? bot.connectionId
                          : bot.connectionLabel,
                    ),
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
