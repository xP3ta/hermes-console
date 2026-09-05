// App bar chrome for the room, bot and profile variants of the screen.
part of 'chat_screen.dart';

class _MissionRoomAppBarTitle extends StatelessWidget {
  final MissionRoom room;

  const _MissionRoomAppBarTitle({required this.room});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final english = Localizations.localeOf(context).languageCode == 'en';
    final memberCount = room.memberProfiles.length;
    return Padding(
      key: const ValueKey('mission-room-header'),
      padding: const EdgeInsetsDirectional.only(start: 4, end: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '#${room.name}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 17.5,
              letterSpacing: -0.15,
            ),
          ),
          Text(
            '@${room.managerProfile} · manager · $memberCount '
            '${english ? (memberCount == 1 ? 'member' : 'members') : (memberCount == 1 ? 'miembro' : 'miembros')}',
            key: const ValueKey('mission-room-header-subtitle'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 11.5,
              height: 1.15,
            ),
          ),
        ],
      ),
    );
  }
}

enum _MissionRoomHeaderAction { model, controls }

/// Cabecera del Bot Chat: avatar + nombre del bot + estado vivo, con el mismo
/// protagonismo que la cabecera de una Room. El modelo y los controles viven
/// en el overflow, siguiendo el patrón del plugin oficial Hermes Bot Mode.
class _BotChatAppBarTitle extends StatelessWidget {
  final AgentProfile? profile;
  final String fallbackName;
  final ChatActivityKind? activity;
  final MissionProfileAvatarCache? avatarCache;

  const _BotChatAppBarTitle({
    required this.profile,
    required this.fallbackName,
    required this.activity,
    required this.avatarCache,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final english = Localizations.localeOf(context).languageCode == 'en';
    final profile = this.profile;
    final name = profile != null && profile.name.isNotEmpty
        ? profile.name
        : fallbackName;
    final displayName = profile?.botTitle ?? name;
    final statusLabel = switch (activity) {
      ChatActivityKind.thinking => english ? 'Thinking' : 'Pensando',
      ChatActivityKind.usingTools => english ? 'Working' : 'Trabajando',
      ChatActivityKind.responding => english ? 'Responding' : 'Respondiendo',
      ChatActivityKind.awaitingApproval =>
        english ? 'Approval required' : 'Aprobación requerida',
      null => null,
    };
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 4, end: 4),
      child: Row(
        children: [
          MissionProfileAvatar(
            key: ValueKey('bot-chat-avatar-$name'),
            profileName: name,
            hasAvatar: profile?.hasAvatar ?? false,
            cache: avatarCache,
            size: 30,
            shape: profile?.botShape,
            colorHex: profile?.botColorHex,
            imageKind: profile?.botImageKind,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 17.5,
                    letterSpacing: -0.15,
                  ),
                ),
                Text(
                  [
                    if (displayName != name || statusLabel == null) '@$name',
                    ?statusLabel,
                  ].join(' · '),
                  key: const ValueKey('bot-chat-header-subtitle'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 11.5,
                    height: 1.15,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Tira fina bajo el AppBar del chat que indica el perfil de agente activo.
/// Puramente informativa: el gateway sirve un único home, así que el perfil se
/// refleja en el chat por su modelo (aplicado al activarlo en Perfiles); el chip
/// recuerda al usuario qué perfil está en contexto.
class _ProfileContextChip extends StatelessWidget
    implements PreferredSizeWidget {
  const _ProfileContextChip({required this.label, required this.colors});

  final String label;
  final HermesThemeColors colors;

  @override
  Size get preferredSize => const Size.fromHeight(30);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      alignment: Alignment.center,
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: colors.accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: colors.accent.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.layers_rounded, size: 12, color: colors.accent),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: colors.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
