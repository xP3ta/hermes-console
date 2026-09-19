import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart' show HermesAppState;
import '../companion/render/companion_message_presence.dart';
import 'hermes_spark_mascot.dart';
import 'bot_avatar_motion.dart';
import '../models/agent_profile.dart';
import '../models/hosted_groups.dart';
import '../models/room_member_status.dart';
import '../theme/app_theme.dart';
import 'mission_profile_avatar.dart';
import 'hermes_premium_ui.dart';
import 'room_team_row.dart';

String roomPresenceLabel(Strings s, RoomPresence presence) =>
    switch (presence) {
      RoomPresence.working => s.roomPresenceWorking,
      RoomPresence.active => s.roomPresenceActive,
      RoomPresence.idle => s.roomPresenceIdle,
      RoomPresence.needsYou => s.roomPresenceNeedsYou,
      RoomPresence.unknown => s.roomPresenceUnknown,
    };
String roomResponseLabel(Strings s, RoomResponse response) =>
    switch (response) {
      RoomResponse.pending => s.roomResponsePending,
      RoomResponse.responded => s.roomResponseResponded,
      RoomResponse.passed => s.roomResponsePassed,
      RoomResponse.noResponse => s.roomResponseNone,
    };
Color roomPresenceColor(BuildContext context, RoomPresence presence) {
  final colors = Theme.of(context).hermes;
  return switch (presence) {
    RoomPresence.working => colors.accent,
    RoomPresence.active => colors.success,
    RoomPresence.needsYou => colors.accent,
    RoomPresence.idle => colors.textSecondary,
    RoomPresence.unknown => colors.textDisabled,
  };
}

/// Shared status presentation for Bots and room members, over the existing
/// avatar renderer. Working is motion, not a badge or a second identity.
class BotStatusAvatar extends StatelessWidget {
  final String identity;
  final String label;
  final AgentProfile? profile;
  final MissionProfileAvatarCache? avatarCache;
  final BotLiveStatus status;
  final double size;
  const BotStatusAvatar({
    super.key,
    required this.identity,
    required this.label,
    required this.profile,
    required this.avatarCache,
    required this.status,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    final detail = botStatusText(Strings.of(context), status);
    final app = context.findAncestorStateOfType<HermesAppState>();
    final manager = app?.widget.connManager;
    final connection = avatarCache?.connectionId;
    // Companion has a single loaded owner. Never borrow its pet for a peer
    // or another profile; use only the already loaded, scoped companion.
    final ownsPet =
        profile != null &&
        connection != null &&
        manager?.activeConnectionId.value == connection &&
        manager?.activeProfileFor(connection) == profile!.name;
    return Semantics(
      label: '$label: $detail',
      child: Tooltip(
        message: '$label: $detail',
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            RoomMemberAvatar(
              profileName: label.startsWith('@') ? label.substring(1) : label,
              profile: profile,
              avatarCache: avatarCache,
              size: size,
              working: status.presence == RoomPresence.working,
            ),
            if (status.presence == RoomPresence.working &&
                ownsPet &&
                app != null)
              Positioned(
                right: -2,
                bottom: -2,
                child: BotAvatarMotion(
                  enabled: true,
                  pet: true,
                  child: CompanionMessagePresence(
                    companion: app.companion,
                    mood: HermesSparkMood.thinking,
                    size: size * .45,
                  ),
                ),
              ),
            if (status.presence != RoomPresence.working)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  key: ValueKey(
                    'room-status-$identity-${status.presence.name}',
                  ),
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: roomPresenceColor(context, status.presence),
                    border: Border.all(
                      color: Theme.of(context).hermes.surface,
                      width: 1.5,
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

class RoomStatusAvatar extends StatelessWidget {
  final HostedGroupMember member;
  final AgentProfile? profile;
  final MissionProfileAvatarCache? avatarCache;
  final BotLiveStatus status;
  final double size;
  final bool showDetailsOnTap;
  const RoomStatusAvatar({
    super.key,
    required this.member,
    required this.profile,
    required this.avatarCache,
    required this.status,
    this.size = 24,
    this.showDetailsOnTap = false,
  });
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: !showDetailsOnTap
        ? null
        : () => showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('@${member.handle}'),
              content: Text(botStatusText(Strings.of(context), status)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    MaterialLocalizations.of(context).closeButtonLabel,
                  ),
                ),
              ],
            ),
          ),
    child: BotStatusAvatar(
      identity: member.memberId,
      label: '@${member.handle}',
      profile: profile,
      avatarCache: avatarCache,
      status: status,
      size: size,
    ),
  );
}

String botStatusText(Strings strings, BotLiveStatus status) =>
    '${roomPresenceLabel(strings, status.presence)}'
    '${status.workingOn == null ? '' : ' · ${status.workingOn}'}';

/// One unboxed, secondary line. Full text is available on tap and long press.
class BotStatusLine extends StatelessWidget {
  final BotLiveStatus status;
  final String? text;
  final bool interactive;
  const BotStatusLine({
    super.key,
    required this.status,
    this.text,
    this.interactive = true,
  });
  @override
  Widget build(BuildContext context) {
    final label = text ?? botStatusText(Strings.of(context), status);
    return InkWell(
      onTap: !interactive
          ? null
          : () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                content: SelectableText(label),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      MaterialLocalizations.of(context).closeButtonLabel,
                    ),
                  ),
                ],
              ),
            ),
      child: Tooltip(
        message: label,
        child: HermesShimmerText(
          label,
          enabled: status.presence == RoomPresence.working,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).hermes.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// Header seats are plain avatars and names; all members remain scrollable.
class RoomStatusMember extends StatelessWidget {
  final HostedGroupMember member;
  final BotLiveStatus status;
  final AgentProfile? profile;
  final MissionProfileAvatarCache? avatarCache;
  const RoomStatusMember({
    super.key,
    required this.member,
    required this.status,
    required this.profile,
    required this.avatarCache,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RoomStatusAvatar(
          member: member,
          profile: profile,
          avatarCache: avatarCache,
          status: status,
          size: 28,
        ),
        const SizedBox(height: 3),
        Text(
          '@${member.handle}',
          style: TextStyle(
            fontSize: 10,
            color: Theme.of(context).hermes.textSecondary,
          ),
        ),
      ],
    ),
  );
}
