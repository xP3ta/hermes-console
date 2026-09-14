import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/agent_profile.dart';
import '../models/bot_mode_v13.dart';
import '../theme/app_theme.dart';
import 'mission_profile_avatar.dart';

final class RoomAvatarMember {
  final AvatarOwner owner;
  final AgentProfile profile;
  final String displayName;

  const RoomAvatarMember({
    required this.owner,
    required this.profile,
    required this.displayName,
  });
}

final class RoomAvatarOfficialMember {
  final AvatarOwner owner;
  final String displayName;
  final String handle;

  const RoomAvatarOfficialMember({
    required this.owner,
    required this.displayName,
    required this.handle,
  });
}

List<RoomAvatarOfficialMember> sortedOfficialRoomAvatarMembers(
  Iterable<RoomAvatarOfficialMember> source,
) {
  final byOwner = <AvatarOwner, RoomAvatarOfficialMember>{
    for (final member in source)
      if (member.owner.isValid &&
          member.displayName.trim().isNotEmpty &&
          member.handle.trim().isNotEmpty)
        member.owner: member,
  };
  final result = byOwner.values.toList(growable: false)
    ..sort((left, right) {
      final byDisplay = _fold(
        left.displayName,
      ).compareTo(_fold(right.displayName));
      if (byDisplay != 0) return byDisplay;
      final byConnection = left.owner.connectionId.compareTo(
        right.owner.connectionId,
      );
      return byConnection != 0
          ? byConnection
          : left.owner.profile.compareTo(right.owner.profile);
    });
  return List.unmodifiable(result);
}

List<RoomAvatarMember> sortedRoomAvatarMembers({
  required String connectionId,
  required Iterable<AgentProfile> profiles,
}) {
  final byOwner = <AvatarOwner, RoomAvatarMember>{};
  for (final profile in profiles) {
    final owner = AvatarOwner(
      connectionId: connectionId,
      profile: profile.name,
    );
    if (!owner.isValid) continue;
    final display = profile.botTitle?.trim();
    byOwner[owner] = RoomAvatarMember(
      owner: owner,
      profile: profile,
      displayName: display == null || display.isEmpty ? profile.name : display,
    );
  }
  final result = byOwner.values.toList(growable: false);
  result.sort((left, right) {
    final byName = _fold(left.displayName).compareTo(_fold(right.displayName));
    if (byName != 0) return byName;
    final byConnection = left.owner.connectionId.compareTo(
      right.owner.connectionId,
    );
    return byConnection != 0
        ? byConnection
        : left.owner.profile.compareTo(right.owner.profile);
  });
  return List.unmodifiable(result);
}

String _fold(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[áàäâãå]'), 'a')
    .replaceAll(RegExp(r'[éèëê]'), 'e')
    .replaceAll(RegExp(r'[íìïî]'), 'i')
    .replaceAll(RegExp(r'[óòöôõ]'), 'o')
    .replaceAll(RegExp(r'[úùüû]'), 'u')
    .replaceAll('ñ', 'n');

class RoomAvatarStack extends StatelessWidget {
  final String? connectionId;
  final Iterable<AgentProfile> profiles;
  final Iterable<AvatarOwner>? officialOwners;
  final Iterable<RoomAvatarOfficialMember>? officialMembers;
  final MissionProfileAvatarCache? avatarCache;

  const RoomAvatarStack({
    required this.connectionId,
    required this.profiles,
    this.avatarCache,
    this.officialOwners,
    this.officialMembers,
    super.key,
  });

  const RoomAvatarStack.official({
    Iterable<AvatarOwner>? owners,
    Iterable<RoomAvatarOfficialMember>? members,
    super.key,
  }) : connectionId = null,
       profiles = const <AgentProfile>[],
       avatarCache = null,
       officialOwners = owners,
       officialMembers = members,
       assert(owners != null || members != null);

  @override
  Widget build(BuildContext context) {
    final official = officialOwners;
    final officialMemberList = officialMembers == null
        ? null
        : sortedOfficialRoomAvatarMembers(officialMembers!);
    final members = official == null && officialMemberList == null
        ? sortedRoomAvatarMembers(
            connectionId: connectionId!,
            profiles: profiles,
          )
        : const <RoomAvatarMember>[];
    final owners = officialMemberList != null
        ? officialMemberList
              .map((member) => member.owner)
              .toList(growable: false)
        : official == null
        ? members.map((member) => member.owner).toList(growable: false)
        : _sortedOwners(official);
    final visibleOwners = owners.take(3).toList(growable: false);
    final overflow = owners.length - visibleOwners.length;
    final colors = Theme.of(context).hermes;
    final label = Strings.of(context).missionRoomAvatarMembers(owners.length);
    return Semantics(
      key: const ValueKey('room-avatar-stack'),
      image: true,
      label: label,
      excludeSemantics: true,
      child: SizedBox(
        width: 58,
        height: 48,
        child: owners.isEmpty
            ? Center(
                child: Icon(
                  Icons.groups_2_outlined,
                  key: const ValueKey('room-avatar-neutral-group'),
                  size: 30,
                  color: colors.textSecondary,
                ),
              )
            : Stack(
                clipBehavior: Clip.none,
                children: [
                  for (var index = 0; index < visibleOwners.length; index++)
                    PositionedDirectional(
                      start: index * 12,
                      top: 7,
                      child: Container(
                        key: official == null && officialMemberList == null
                            ? ValueKey('room-avatar-member-$index')
                            : _RoomAvatarOwnerKey(visibleOwners[index]),
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colors.background,
                            width: 2,
                          ),
                        ),
                        child: official == null && officialMemberList == null
                            ? MissionProfileAvatar(
                                profileName: members[index].profile.name,
                                hasAvatar: members[index].profile.hasAvatar,
                                cache: avatarCache,
                                size: 30,
                                shape: members[index].profile.botShape,
                                colorHex: members[index].profile.botColorHex,
                                imageKind: members[index].profile.botImageKind,
                                privacySafeElementKeys: true,
                              )
                            : _SourceQualifiedNeutralAvatar(
                                owner: visibleOwners[index],
                              ),
                      ),
                    ),
                  if (owners.length == 1)
                    PositionedDirectional(
                      key: const ValueKey('room-avatar-incomplete'),
                      start: 28,
                      bottom: 2,
                      child: Icon(
                        Icons.group_add_outlined,
                        size: 18,
                        color: colors.textSecondary,
                      ),
                    ),
                  if (overflow > 0)
                    PositionedDirectional(
                      key: const ValueKey('room-avatar-overflow'),
                      end: 0,
                      bottom: 0,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.surfaceVariant,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colors.background,
                            width: 1.5,
                          ),
                        ),
                        child: SizedBox.square(
                          dimension: 22,
                          child: Center(
                            child: Text(
                              '+$overflow',
                              style: TextStyle(
                                color: colors.textPrimary,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                              ),
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

List<AvatarOwner> _sortedOwners(Iterable<AvatarOwner> source) {
  final unique = <AvatarOwner>{
    for (final owner in source)
      if (owner.isValid) owner,
  };
  final result = unique.toList(growable: false)
    ..sort((left, right) {
      final byName = _fold(left.profile).compareTo(_fold(right.profile));
      if (byName != 0) return byName;
      final byConnection = left.connectionId.compareTo(right.connectionId);
      return byConnection != 0
          ? byConnection
          : left.profile.compareTo(right.profile);
    });
  return result;
}

final class _RoomAvatarOwnerKey extends LocalKey {
  final AvatarOwner _owner;

  const _RoomAvatarOwnerKey(this._owner);

  @override
  bool operator ==(Object other) =>
      other is _RoomAvatarOwnerKey && other._owner == _owner;

  @override
  int get hashCode => _owner.hashCode;

  @override
  String toString() => '[room avatar owner]';
}

class _SourceQualifiedNeutralAvatar extends StatelessWidget {
  final AvatarOwner owner;

  const _SourceQualifiedNeutralAvatar({required this.owner});

  @override
  Widget build(BuildContext context) {
    var hash = 0x811c9dc5;
    for (final unit
        in '${owner.connectionId}\u0000${owner.profile}'.codeUnits) {
      hash = (hash ^ unit) * 0x01000193;
    }
    final hue = (hash & 0x7fffffff) % 360;
    final color = HSLColor.fromAHSL(1, hue.toDouble(), 0.38, 0.54).toColor();
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.84),
          shape: BoxShape.circle,
        ),
        child: const SizedBox.square(
          dimension: 30,
          child: Icon(Icons.circle_outlined, size: 13, color: Colors.white70),
        ),
      ),
    );
  }
}
