import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../models/hosted_groups.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/floating_chat_header.dart';
import '../../../widgets/mission_profile_avatar.dart';
import 'room_models.dart';
import 'room_widgets.dart';

/// Room header in the floating style of 1.2.15: no app bar band, the
/// transcript scrolls under it. A round back button and, in the centre,
/// the room's activity pill with 2–4 overlapping member faces (+N) sitting
/// on its top edge. Idle, the pill shows the room name; while someone
/// works, waits for you or failed it shows that one line («Forja está
/// respondiendo · 0:42», amber when it needs you). The idle summary stays
/// in the semantics label. Tapping the pill opens the room detail (round /
/// members); a long press opens the room menu.
///
/// Its extent ([FloatingChatHeader.insetFor]) never depends on the room
/// state, so a round starting or ending never moves the transcript.
class RoomHeaderBar extends StatelessWidget {
  static const int maxFaces = 4;

  final String title;
  final String status;
  final List<HostedGroupMember> members;
  final Map<String, RoomTurnState> states;
  final RoomProfileResolver profileFor;
  final MissionProfileAvatarCache? avatarCache;

  /// Room picture published by Desktop (`ui_meta`); replaces the cluster.
  final Widget? roomAvatar;
  final VoidCallback? onOpenDetail;
  final VoidCallback onMore;

  /// The tone of the room's own status line when no member state decides
  /// it (an approval, a blocked or recovering reply, the room working).
  final FloatingHeaderTone lineTone;

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
    this.onOpenDetail,
    this.lineTone = FloatingHeaderTone.idle,
  });

  /// What the pill's second line shows: who needs you or failed (amber),
  /// who works, or nothing while the room is idle.
  static FloatingHeaderTone toneOf(Map<String, RoomTurnState> states) {
    final values = states.values;
    if (values.any(
      (s) => s == RoomTurnState.needsYou || s == RoomTurnState.failed,
    )) {
      return FloatingHeaderTone.waiting;
    }
    if (values.any((s) => s == RoomTurnState.working)) {
      return FloatingHeaderTone.working;
    }
    return FloatingHeaderTone.idle;
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final navigator = Navigator.of(context);
    final name = colors.uppercaseTitles ? title.toUpperCase() : title;
    final memberTone = toneOf(states);
    final tone = memberTone == FloatingHeaderTone.idle ? lineTone : memberTone;
    final idle = tone == FloatingHeaderTone.idle || status.isEmpty;
    return FloatingChatHeader(
      key: const ValueKey('room-header-bar'),
      // Seam for the mascot engine's MascotCluster (review/1215-mascot).
      mascot: roomAvatar != null
          ? null
          : HeaderMascotRequest(
              identity: title,
              members: [for (final m in members) m.memberId],
              state: switch (tone) {
                FloatingHeaderTone.idle => HeaderMascotState.idle,
                FloatingHeaderTone.working => HeaderMascotState.working,
                FloatingHeaderTone.waiting => HeaderMascotState.waiting,
                FloatingHeaderTone.offline => HeaderMascotState.offline,
              },
            ),
      leading: navigator.canPop()
          ? FloatingHeaderButton(
              key: const ValueKey('room-back'),
              icon: Icons.arrow_back_rounded,
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => navigator.maybePop(),
            )
          : null,
      // A room cannot start a new chat: nothing on the right. Its menu
      // (rename, members, leave…) opens with a long press on the pill until
      // the notch sheet takes it over.
      faces:
          roomAvatar ??
          RoomFaceCluster(
            members: members,
            states: states,
            profileFor: profileFor,
            avatarCache: avatarCache,
          ),
      pill: FloatingHeaderPill(
        key: const ValueKey('room-header'),
        text: idle ? name : status,
        tone: idle ? FloatingHeaderTone.idle : tone,
        semanticsLabel: status.isEmpty ? name : '$name. $status',
        hint: onOpenDetail == null ? null : s.rhdrOpenDetailHint,
        onTap: onOpenDetail,
        onLongPress: onMore,
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
