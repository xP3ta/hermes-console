import 'package:flutter/material.dart';

import '../../models/agent_profile.dart';
import '../../theme/app_theme.dart';
import '../../widgets/hermes_bot_face.dart';
import '../../widgets/mission_profile_avatar.dart';

/// One member face shown in a [RoomAvatarTile].
final class RoomAvatarTileMember {
  final String handle;
  final AgentProfile? profile;

  const RoomAvatarTileMember(this.handle, this.profile);
}

/// Room avatar: a rounded-square tile holding up to four mini member faces
/// in a grid (the fourth cell becomes "+n" for bigger rooms). Faces never
/// overlap and are never clipped by cut-out borders, so squares, hexagons
/// and blobs all keep their silhouette. Used by room rows (48 dp) and the
/// room header (36 dp) so a room looks the same everywhere.
class RoomAvatarTile extends StatelessWidget {
  final List<RoomAvatarTileMember> members;
  final MissionProfileAvatarCache? avatarCache;
  final double size;

  const RoomAvatarTile({
    super.key,
    required this.members,
    required this.avatarCache,
    this.size = 48,
  });

  static const int maxCells = 4;

  /// Keys of the rendered cells, for tests: `room-avatar-cell-<i>` and
  /// `room-avatar-more`.
  static String cellKey(int index) => 'room-avatar-cell-$index';

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final count = members.length;
    final overflow = count > maxCells;
    final shown = members.take(overflow ? maxCells - 1 : maxCells).toList();
    final pad = size * .09;
    final gap = size * .04;
    final inner = size - pad * 2;
    // One member: a single big face; otherwise a 2×2 grid of cells.
    final cell = count <= 1 ? inner : (inner - gap) / 2;
    // Faces sit inside their cell with a hair of air so shapes breathe.
    final face = count <= 1 ? inner * .96 : cell * 1.04;

    Widget faceAt(int i) => SizedBox.square(
      key: ValueKey(cellKey(i)),
      dimension: cell,
      child: OverflowBox(
        minWidth: face,
        minHeight: face,
        maxWidth: face,
        maxHeight: face,
        child: _MiniFace(
          member: shown[i],
          avatarCache: avatarCache,
          size: face,
        ),
      ),
    );

    Widget more() => Container(
      key: const ValueKey('room-avatar-more'),
      width: cell,
      height: cell,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.background.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(cell * .3),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(
            '+${count - shown.length}',
            maxLines: 1,
            style: TextStyle(
              fontSize: size >= 44 ? 11 : 9.5,
              height: 1,
              fontWeight: FontWeight.w700,
              color: colors.textSecondary,
            ),
          ),
        ),
      ),
    );

    final Widget content;
    if (count == 0) {
      content = Icon(
        Icons.groups_2_outlined,
        size: size * .5,
        color: colors.textSecondary,
      );
    } else if (count == 1) {
      content = faceAt(0);
    } else {
      final cells = <Widget>[
        for (var i = 0; i < shown.length; i++) faceAt(i),
        if (overflow) more(),
      ];
      Widget row(List<Widget> items) => Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) SizedBox(width: gap),
            items[i],
          ],
        ],
      );
      content = switch (cells.length) {
        // Two: diagonal, so the tile still reads as a group at a glance.
        2 => SizedBox.square(
          dimension: inner,
          child: Stack(
            children: [
              Positioned(left: 0, top: 0, child: cells[0]),
              Positioned(right: 0, bottom: 0, child: cells[1]),
            ],
          ),
        ),
        _ => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            row(cells.sublist(0, 2)),
            SizedBox(height: gap),
            row(cells.sublist(2)),
          ],
        ),
      };
    }
    return ExcludeSemantics(
      child: Container(
        key: const ValueKey('room-avatar-tile'),
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(size * .3),
          border: Border.all(
            color: colors.divider.withValues(alpha: .35),
            width: .8,
          ),
        ),
        child: content,
      ),
    );
  }
}

class _MiniFace extends StatelessWidget {
  final RoomAvatarTileMember member;
  final MissionProfileAvatarCache? avatarCache;
  final double size;

  const _MiniFace({
    required this.member,
    required this.avatarCache,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final profile = member.profile;
    if (profile != null) {
      return MissionProfileAvatar(
        profileName: profile.name,
        hasAvatar: profile.botPaintsPhoto,
        cache: avatarCache,
        size: size,
        shape: profile.botFaceShape,
        colorHex: profile.botColorHex,
        imageKind: profile.botImageKind,
        privacySafeElementKeys: true,
      );
    }
    final visual = HermesBlobatarFaceVisual.tryParse(
      shapeWire: 'blobatar',
      profileName: member.handle,
    );
    return visual == null
        ? SizedBox.square(dimension: size)
        : HermesBotFace(visual: visual, size: size);
  }
}
