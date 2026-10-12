import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../models/hosted_groups.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/face_marks.dart';
import '../../../widgets/floating_chat_header.dart';
import '../../../widgets/hermes_notice.dart';
import '../../../widgets/island.dart';
import '../../../widgets/mission_profile_avatar.dart';
import 'room_models.dart';
import 'room_widgets.dart';

/// Room header in the floating style of 1.2.15: no app bar band, the
/// transcript scrolls under it. A round back button and, in the centre,
/// the room's ISLAND with 2–4 overlapping member faces (+N) standing on
/// it, still. At rest the island is the room's name after one state dot.
/// When someone starts working, waits for you or failed, it grows to say
/// that one line («Forja está respondiendo», amber with «Ver» when it needs
/// you) and shrinks back. The idle summary stays in the semantics label.
/// Tapping the island opens the room detail (round / members); a long
/// press opens the room menu.
///
/// Its extent ([FloatingChatHeader.insetFor]) never depends on the room
/// state, so a round starting or ending never moves the transcript.
class RoomHeaderBar extends StatelessWidget {
  static const int maxFaces = 4;

  final String title;

  /// The room's one status line, with its clock: for the screen reader.
  final String status;

  /// [status] without its clock: what the island says, once per change.
  /// Null: [status] itself.
  final String? line;

  /// How long the one replying member has been at it («0:42»), shown after
  /// the room's name while it replies.
  final String? elapsed;
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

  /// Say [status] on the island even while the room is idle, in the neutral
  /// tone: a confirmation, not a call to act.
  final bool showIdleStatus;

  const RoomHeaderBar({
    super.key,
    required this.title,
    required this.status,
    required this.members,
    required this.states,
    required this.profileFor,
    required this.avatarCache,
    required this.onMore,
    this.line,
    this.elapsed,
    this.roomAvatar,
    this.onOpenDetail,
    this.lineTone = FloatingHeaderTone.idle,
    this.showIdleStatus = false,
  });

  /// What the island's dot shows: who needs you or failed (amber), who
  /// works, or nothing while the room is idle.
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
    final waiting = !idle && tone == FloatingHeaderTone.waiting;
    final said = line ?? status;
    // How long the one replying has been at it: after the room's name at
    // rest, and at the end of the line that says who replies.
    final clock = elapsed == null || idle
        ? null
        : ExcludeSemantics(
            child: Text(
              elapsed!,
              key: const ValueKey('room-header-elapsed'),
              maxLines: 1,
              style: TextStyle(
                fontSize: 12,
                height: 1.2,
                fontWeight: FontWeight.w600,
                color: colors.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          );
    return FloatingChatHeader(
      key: const ValueKey('room-header-bar'),
      // QA 9493: a room keeps its members' ORIGINAL faces (the cluster
      // below, the same faces as the round sheet); the request only tells
      // the seam who is there.
      mascot: roomAvatar != null
          ? null
          : HeaderMascotRequest(
              identity: title,
              originalFace: true,
              members: [for (final m in members) m.memberId],
              state: HeaderMascotState.idle,
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
      // (rename, members, leave…) opens from the notch on the composer, and
      // still with a long press on the island.
      faces:
          roomAvatar ??
          RoomFaceCluster(
            members: members,
            states: states,
            profileFor: profileFor,
            avatarCache: avatarCache,
          ),
      pill: ChatIsland(
        key: const ValueKey('room-header'),
        name: name,
        status: idle ? IslandStatus.idle : tone.islandStatus,
        // Who is in the room and how the last round ended is for the screen
        // reader; the island keeps to the name.
        semanticsName: status.isEmpty ? name : '$name. $status',
        notices: HermesNotice.feedOf(context),
        trailing: clock,
        events: [
          if (said.isNotEmpty && (!idle || showIdleStatus))
            IslandEvent(
              id: 'room-status',
              // Each new line is said once.
              revision: Object.hash(said, tone),
              key: const ValueKey('room-header-status'),
              tone: waiting ? IslandTone.needsYou : IslandTone.info,
              icon: idle || waiting ? null : Icons.bolt_rounded,
              sticky: waiting,
              duration: const Duration(seconds: 3),
              line: said,
              trailing: waiting ? null : clock,
              action: waiting && onOpenDetail != null
                  ? IslandAction(label: s.islandSee, onPressed: onOpenDetail)
                  : null,
              onTap: onOpenDetail,
            ),
        ],
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
  /// Each face: as large as four of them fit standing on the island.
  static const double faceSize = 36;
  static const double _step = 23;

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
    // QA 9494: no separator ring and no ring around the dot (shared rule in
    // face_marks.dart). A ring in a theme colour read as a black halo on
    // the pill; the face in front simply covers the next one.
    return SizedBox.square(
      key: ValueKey('room-header-face-${member.memberId}'),
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
            // The same face as the round sheet's, at rest and still like
            // every face on an island: the dot on it and the island's line
            // say who works and who waits.
            still: true,
          ),
          if (_marked(state))
            Positioned(
              right: 0,
              bottom: 0,
              child: FaceStateDot(
                key: ValueKey(
                  'room-header-dot-${member.memberId}-${state!.name}',
                ),
                color: roomTurnDotColor(colors, state),
                size: 8,
              ),
            ),
        ],
      ),
    );
  }
}
