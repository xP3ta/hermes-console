import 'package:flutter/widgets.dart';

import '../floating_chat_header.dart';
import 'mascot_cluster.dart';
import 'mascot_identity.dart';
import 'mascot_sprite.dart';
import 'mascot_state.dart';

/// The floating header's mascot (#187 seam) drawn by the sprite engine
/// (#189): one [MascotSprite] on a chat's pill, a [MascotCluster] in rooms.
/// Mounted once above the navigator through [HeaderMascotScope].
Widget buildHeaderMascot(BuildContext context, HeaderMascotRequest request) {
  if (request.isRoom) {
    return FittedBox(
      // The slot is sized for overlapping faces; the cluster's "+N" chip
      // scales down into it instead of overflowing.
      fit: BoxFit.scaleDown,
      child: MascotCluster(
        key: const ValueKey('header-mascot-cluster'),
        size: request.size,
        members: [
          for (var i = 0; i < request.members.length; i++)
            MascotClusterMember(
              name: request.members[i],
              identity: MascotIdentity.forProfile(request.members[i]),
              state: mascotStateOfHeader(
                i < request.memberStates.length
                    ? request.memberStates[i]
                    : request.state,
              ),
            ),
        ],
      ),
    );
  }
  final activity = request.activity;
  return MascotSprite(
    key: const ValueKey('header-mascot'),
    state: activity == null
        ? mascotStateOfHeader(request.state)
        : mascotStateFor(
            activity,
            offline: request.state == HeaderMascotState.offline,
            error: request.error,
            justFinished: request.justFinished,
          ),
    identity: request.identity == 'hermes'
        ? MascotIdentity.hermes
        : MascotIdentity.forProfile(request.identity),
    size: request.size,
    name: request.name ?? request.identity,
    header: true,
  );
}

/// The header's coarse state as a mascot state (rooms, and chats without an
/// activity snapshot).
MascotState mascotStateOfHeader(HeaderMascotState state) => switch (state) {
  HeaderMascotState.idle => MascotState.idle,
  HeaderMascotState.thinking => MascotState.thinking,
  HeaderMascotState.speaking => MascotState.thinking,
  HeaderMascotState.working => MascotState.tool,
  HeaderMascotState.waiting => MascotState.needsYou,
  HeaderMascotState.offline => MascotState.offline,
};
