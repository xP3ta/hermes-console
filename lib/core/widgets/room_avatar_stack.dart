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

  /// Perfil real del bot cuando es local a ESTA conexión (mismo `gatewayId`
  /// que la sala), para poder pintar su avatar/Blobatar de verdad en vez del
  /// círculo de color neutro. Null para miembros de otra conexión (salas
  /// federadas), de los que la app no tiene datos de avatar en caché — ahí
  /// el círculo neutro sigue siendo lo correcto, no un bug.
  final AgentProfile? profile;

  const RoomAvatarOfficialMember({
    required this.owner,
    required this.displayName,
    required this.handle,
    this.profile,
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
    this.avatarCache,
    super.key,
  }) : connectionId = null,
       profiles = const <AgentProfile>[],
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
    final label = Strings.of(context).roomAvatarMembers(owners.length);
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
                        decoration: const BoxDecoration(shape: BoxShape.circle),
                        // Antes tenía un anillo separador de 2px: primero en
                        // `colors.background` (leía como borde negro sólido),
                        // luego recoloreado a `colors.surface` (se fundía con
                        // la tarjeta, pero seguía siendo un anillo oscuro
                        // visible contra un avatar de color vivo — todavía
                        // "bordito negro" para el ojo, confirmado en
                        // dispositivo real). Sin decoración ni recorte aquí
                        // los avatares solapan directamente, transparentes de
                        // verdad, como se pidió.
                        child: _memberAvatar(
                          index: index,
                          member: official == null && officialMemberList == null
                              ? members[index]
                              : null,
                          // Un miembro "oficial" con perfil local adjunto (misma
                          // conexión que la sala) SÍ tiene datos de avatar reales
                          // — antes esta rama ignoraba `profile` por completo y
                          // pintaba el círculo de color neutro incluso para tus
                          // propios bots ("el equipo no mantiene los iconos
                          // propios, añade otros", confirmado en dispositivo
                          // real). El círculo neutro sigue siendo correcto solo
                          // para miembros de OTRA conexión (salas federadas),
                          // de los que de verdad no hay avatar en caché.
                          officialProfile: officialMemberList == null
                              ? null
                              : officialMemberList[index].profile,
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
                            color: colors.surface,
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

  Widget _memberAvatar({
    required int index,
    required RoomAvatarMember? member,
    required AgentProfile? officialProfile,
    required AvatarOwner owner,
  }) {
    final profile = member?.profile ?? officialProfile;
    if (profile != null) {
      return MissionProfileAvatar(
        profileName: profile.name,
        hasAvatar: profile.hasAvatar,
        cache: avatarCache,
        size: 30,
        shape: profile.botShape,
        colorHex: profile.botColorHex,
        imageKind: profile.botImageKind,
        privacySafeElementKeys: true,
      );
    }
    return _SourceQualifiedNeutralAvatar(owner: owner);
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
