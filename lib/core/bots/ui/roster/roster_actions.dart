import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/mission_profile_avatar.dart';
import '../bot_screen_access.dart';
import 'dots_home_model.dart' show isMainBot;
import 'living_bot_face.dart';
import 'roster_model.dart';

/// Long-press actions on a bot row (spec 070 S1/T402).
enum RosterBotAction { togglePin, section, toggleHidden, profile, chat, screen }

/// Compact floating sheet (Console's `showHermesFloatingSurface` style):
/// pin, section, hide and open profile. Mutations are hidden read-only.
class RosterBotActionsSheet extends StatelessWidget {
  final BotRosterEntry entry;
  final MissionProfileAvatarCache? avatarCache;
  final bool canMutate;
  final bool canSection;

  /// What the list knows about the bot's desktop. Null leaves the entry out
  /// (no way to open it from here); `none` shows it dimmed with the cause.
  final BotScreenState? screen;

  const RosterBotActionsSheet({
    super.key,
    required this.entry,
    required this.avatarCache,
    required this.canMutate,
    required this.canSection,
    this.screen,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final profile = entry.profile;
    Widget item(
      RosterBotAction action,
      IconData icon,
      String label, {
      bool accent = false,
      String? subtitle,
      bool enabled = true,
    }) => ListTile(
      key: ValueKey('roster-action-${action.name}'),
      enabled: enabled,
      leading: Icon(icon, color: accent ? colors.accentText : null),
      title: Text(
        label,
        style: TextStyle(color: accent ? colors.accentText : null),
      ),
      subtitle: subtitle == null ? null : Text(subtitle),
      onTap: enabled ? () => Navigator.pop(context, action) : null,
    );

    return SafeArea(
      top: false,
      child: ListView(
        key: const ValueKey('roster-bot-actions'),
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              children: [
                LivingBotFace(
                  profileName: profile.name,
                  profile: profile,
                  avatarCache: avatarCache,
                  signal: entry.signal,
                  size: 40,
                  entrance: false,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '@${profile.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          item(
            RosterBotAction.chat,
            Icons.chat_bubble_outline_rounded,
            s.botProfileChat,
            accent: true,
          ),
          if (canMutate)
            item(
              RosterBotAction.togglePin,
              profile.botPinned
                  ? Icons.push_pin_outlined
                  : Icons.push_pin_rounded,
              profile.botPinned ? s.rosterUnpin : s.rosterPin,
            ),
          if (canMutate && canSection)
            item(
              RosterBotAction.section,
              Icons.folder_outlined,
              s.rosterMoveToSection,
            ),
          // The main bot never leaves its own home (the layout always shows
          // it), so hiding it would be an action that visibly does nothing.
          if (canMutate && !isMainBot(profile))
            item(
              RosterBotAction.toggleHidden,
              profile.botHidden
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              profile.botHidden ? s.rosterUnhide : s.rosterHide,
            ),
          if (screen != null)
            item(
              RosterBotAction.screen,
              Icons.desktop_windows_outlined,
              s.bsaScreen,
              enabled: screen != BotScreenState.none,
              subtitle: screen == BotScreenState.none ? s.bsaNoDesktop : null,
            ),
          item(
            RosterBotAction.profile,
            Icons.account_circle_outlined,
            s.rosterOpenProfile,
          ),
        ],
      ),
    );
  }
}
