import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../models/hosted_groups.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/mission_profile_avatar.dart';
import 'room_models.dart';
import 'room_widgets.dart';

/// Room header in the Dots chat style: ONE calm layer. A round back button,
/// a centred cluster of overlapping member faces next to the room name with
/// one grey status line, and a round overflow button. Tapping the cluster or
/// the status opens the room detail (round / members).
///
/// While the reader is up in the history it collapses to the name only.
/// Its height depends only on [collapsed], never on the room state, so a
/// round starting or ending never moves the transcript.
class RoomHeaderBar extends StatelessWidget implements PreferredSizeWidget {
  static const double expandedHeight = 64;
  static const double collapsedHeight = 48;
  static const int maxFaces = 4;

  final String title;
  final String status;
  final List<HostedGroupMember> members;
  final Map<String, RoomTurnState> states;
  final RoomProfileResolver profileFor;
  final MissionProfileAvatarCache? avatarCache;

  /// Room picture published by Desktop (`ui_meta`); replaces the cluster.
  final Widget? roomAvatar;
  final bool collapsed;
  final VoidCallback? onOpenDetail;
  final VoidCallback onMore;

  const RoomHeaderBar({
    super.key,
    required this.title,
    required this.status,
    required this.members,
    required this.states,
    required this.profileFor,
    required this.avatarCache,
    required this.onMore,
    this.roomAvatar,
    this.collapsed = false,
    this.onOpenDetail,
  });

  @override
  Size get preferredSize =>
      Size.fromHeight(collapsed ? collapsedHeight : expandedHeight);

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final canPop = Navigator.of(context).canPop();
    final name = colors.uppercaseTitles ? title.toUpperCase() : title;
    final semantics = collapsed || status.isEmpty ? name : '$name. $status';
    return AppBar(
      toolbarHeight: preferredSize.height,
      automaticallyImplyLeading: false,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleSpacing: 0,
      leadingWidth: 56,
      leading: canPop
          ? Center(
              child: _RoundButton(
                key: const ValueKey('room-back'),
                icon: Icons.arrow_back_rounded,
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            )
          : null,
      actions: [
        _RoundButton(
          key: const ValueKey('room-overflow'),
          icon: Icons.more_horiz_rounded,
          tooltip: s.roomMoreActions,
          onPressed: onMore,
        ),
        const SizedBox(width: 8),
      ],
      // AppBar clamps its title's text scale (to about 1.34×), which keeps
      // the two lines inside the 64 dp bar at 2×; the full name and status
      // stay in the semantics label.
      title: Semantics(
        button: onOpenDetail != null,
        label: semantics,
        hint: onOpenDetail == null ? null : s.rhdrOpenDetailHint,
        excludeSemantics: true,
        child: InkWell(
          key: const ValueKey('room-header'),
          onTap: onOpenDetail,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!collapsed) ...[
                  roomAvatar ??
                      RoomFaceCluster(
                        members: members,
                        states: states,
                        profileFor: profileFor,
                        avatarCache: avatarCache,
                      ),
                  const SizedBox(width: 10),
                ],
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: collapsed
                        ? CrossAxisAlignment.center
                        : CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        key: const ValueKey('room-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15.5,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                          color: colors.textPrimary,
                        ),
                      ),
                      if (!collapsed && status.isNotEmpty)
                        Text(
                          status,
                          key: const ValueKey('room-header-status'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.25,
                            color: colors.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Up to [RoomHeaderBar.maxFaces] overlapping member faces plus "+N". Who
/// needs you leads, then who is replying, then who is next. Only states that
/// matter get a small dot (needs you, replying, failed); idle faces are
/// plain so the header stays calm.
class RoomFaceCluster extends StatelessWidget {
  static const double faceSize = 28;
  static const double _step = 18;

  final List<HostedGroupMember> members;
  final Map<String, RoomTurnState> states;
  final RoomProfileResolver profileFor;
  final MissionProfileAvatarCache? avatarCache;

  const RoomFaceCluster({
    super.key,
    required this.members,
    required this.states,
    required this.profileFor,
    required this.avatarCache,
  });

  static int _rank(RoomTurnState? state) => switch (state) {
    RoomTurnState.needsYou => 0,
    RoomTurnState.working => 1,
    RoomTurnState.failed => 2,
    RoomTurnState.queued => 3,
    _ => 4,
  };

  static bool _marked(RoomTurnState? state) =>
      state == RoomTurnState.needsYou ||
      state == RoomTurnState.working ||
      state == RoomTurnState.failed;

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).hermes;
    final ordered = [...members]
      ..sort(
        (a, b) =>
            _rank(states[a.memberId]).compareTo(_rank(states[b.memberId])),
      );
    final shown = ordered.take(RoomHeaderBar.maxFaces).toList();
    final more = members.length - shown.length;
    final width = faceSize + _step * (shown.length - 1);
    return Row(
      key: const ValueKey('room-header-cluster'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: width + 2,
          height: faceSize + 2,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Painted right to left so the leading face sits on top.
              for (var i = shown.length - 1; i >= 0; i--)
                Positioned(
                  left: i * _step,
                  top: 0,
                  child: _face(colors, shown[i]),
                ),
            ],
          ),
        ),
        if (more > 0)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4),
            child: Text(
              '+$more',
              key: const ValueKey('room-header-more'),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: colors.textSecondary,
              ),
            ),
          ),
      ],
    );
  }

  Widget _face(HermesThemeColors colors, HostedGroupMember member) {
    final state = states[member.memberId];
    return DecoratedBox(
      key: ValueKey('room-header-face-${member.memberId}'),
      // A ring in the bar colour separates the overlapping faces.
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: colors.background, width: 1),
      ),
      child: SizedBox.square(
        dimension: faceSize,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            RoomMemberFace(
              member: member,
              fallbackName: member.handle,
              profile: profileFor(member),
              avatarCache: avatarCache,
              size: faceSize,
              // Still on purpose: an endless animation here would repaint
              // the room every frame for as long as a bot works.
              working: false,
            ),
            if (_marked(state))
              Positioned(
                right: -1,
                bottom: -1,
                child: SizedBox.square(
                  key: ValueKey(
                    'room-header-dot-${member.memberId}-${state!.name}',
                  ),
                  dimension: 10,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: roomTurnDotColor(colors, state),
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.background, width: 2),
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

/// Round side button of the Dots header: a 40 dp filled circle inside a
/// 48 dp target.
class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _RoundButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      style: IconButton.styleFrom(
        fixedSize: const Size.square(40),
        minimumSize: const Size.square(40),
        tapTargetSize: MaterialTapTargetSize.padded,
        backgroundColor: colors.surfaceVariant,
        foregroundColor: colors.textPrimary,
        shape: const CircleBorder(),
      ),
    );
  }
}
