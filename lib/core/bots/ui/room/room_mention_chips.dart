import '../../../models/agent_profile.dart';
import '../../../models/hosted_groups.dart';
import '../../../widgets/chat/mention_chips.dart';
import '../../../widgets/mission_profile_avatar.dart';
import '../../../widgets/room_team_row.dart' show RoomMemberAvatar;
import 'room_models.dart';

/// Mentions of a room, classified as Desktop's `classifyGroupMention`
/// (`group-mention-text.tsx`): `@user` is the human, `@all` / `@everyone`
/// the whole room, and a member's handle (case-insensitive, as the room's
/// routing reads it) that member. Anything else, e-mail addresses and paths
/// included, stays text. Only members Console can open take a tap (the
/// member's chat, as the room's mention links already did).
class RoomMentionChips extends MentionChipResolver {
  RoomMentionChips({
    required List<HostedGroupMember> members,
    required this._profileFor,
    required this.avatarCache,
    Iterable<String> openable = const [],
    this._onOpen,
  }) : _members = {for (final m in members) m.handle.toLowerCase(): m},
       _openable = {for (final h in openable) h.toLowerCase()};

  final Map<String, HostedGroupMember> _members;
  final AgentProfile? Function(HostedGroupMember member) _profileFor;
  final Set<String> _openable;
  final void Function(String handle)? _onOpen;
  final MissionProfileAvatarCache? avatarCache;

  // The room's mention token; never glued to a word, a path, an e-mail
  // address or a Markdown link label.
  static final RegExp _pattern = RegExp(
    r'(?<![\w/\\\[@.:+-])@([A-Za-z0-9][A-Za-z0-9._:-]*)',
  );

  @override
  RegExp get pattern => _pattern;

  // No trailing punctuation is trimmed: the room's routing
  // (`gateway/hosted_room_discussion.py` `resolve_mentions`, and the
  // composer's `firstUnknownRoomMention`) reads `@builder.` as the unknown
  // `builder.`, so it is no chip either (REVIEW-R5-B #8).

  @override
  MentionChipTarget? lookup(String token) {
    final key = token.toLowerCase();
    if (key == 'user') {
      return const MentionChipTarget(kind: MentionChipKind.human, name: '');
    }
    if (key == 'all' || key == 'everyone') {
      return const MentionChipTarget(
        kind: MentionChipKind.broadcast,
        name: '',
      );
    }
    final member = _members[key];
    if (member == null) return null;
    final profile = _profileFor(member);
    final display = member.displayName?.trim() ?? '';
    final onOpen = _onOpen;
    return MentionChipTarget(
      kind: MentionChipKind.agent,
      name: display.isNotEmpty ? display : member.handle,
      color: roomMemberColor(
        member.handle,
        profile: profile,
        avatarCache: avatarCache,
      ),
      avatar: (size) => RoomMemberAvatar(
        profileName: member.handle,
        profile: profile,
        avatarCache: avatarCache,
        size: size,
      ),
      onTap: onOpen != null && _openable.contains(key)
          ? () => onOpen(member.handle)
          : null,
    );
  }
}
