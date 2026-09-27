import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/mission_profile_avatar.dart';
import 'living_bot_face.dart';
import 'roster_model.dart';

/// Long-press actions on a bot row (spec 070 S1/T402).
enum RosterBotAction { togglePin, section, toggleHidden, profile, chat }

/// Compact floating sheet (Console's `showHermesFloatingSurface` style):
/// pin, section, hide and open profile. Mutations are hidden read-only.
class RosterBotActionsSheet extends StatelessWidget {
  final BotRosterEntry entry;
  final MissionProfileAvatarCache? avatarCache;
  final bool canMutate;
  final bool canSection;

  const RosterBotActionsSheet({
    super.key,
    required this.entry,
    required this.avatarCache,
    required this.canMutate,
    required this.canSection,
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
    }) => ListTile(
      key: ValueKey('roster-action-${action.name}'),
      leading: Icon(icon, color: accent ? colors.accentText : null),
      title: Text(
        label,
        style: TextStyle(color: accent ? colors.accentText : null),
      ),
      onTap: () => Navigator.pop(context, action),
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
          if (canMutate)
            item(
              RosterBotAction.toggleHidden,
              profile.botHidden
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              profile.botHidden ? s.rosterUnhide : s.rosterHide,
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
