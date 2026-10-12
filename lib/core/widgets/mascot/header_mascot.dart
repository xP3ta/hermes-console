import 'package:flutter/widgets.dart';

import '../floating_chat_header.dart';
import 'mascot_identity.dart';
import 'mascot_sprite.dart';
import 'mascot_state.dart';

/// The floating header's mascot (#187 seam) drawn by the sprite engine
/// (#189). Mounted once above the navigator through [HeaderMascotScope].
///
/// QA 9493: the header asks the engine only when it has NO original face to
/// show (`HeaderMascotRequest.keepsOriginalFace` is false): the default
/// Hermes chat without a companion. Bots, rooms and profiles keep their own
/// faces, so the engine only ever draws Hermes' own sprite and never picks a
/// sprite for somebody else.
///
/// The sprite on the island is ALWAYS its resting drawing, still: it does
/// not run, hop or change colour while Hermes works, waits or is offline.
/// The island's dot and its line say what is going on.
Widget buildHeaderMascot(BuildContext context, HeaderMascotRequest request) {
  return MascotSprite(
    key: const ValueKey('header-mascot'),
    state: MascotState.idle,
    still: true,
    identity: MascotIdentity.hermes,
    size: request.size,
    name: request.name ?? request.identity,
    header: true,
  );
}

/// The header's coarse state as a mascot state, for surfaces that do let
/// their mascot move.
MascotState mascotStateOfHeader(HeaderMascotState state) => switch (state) {
  HeaderMascotState.idle => MascotState.idle,
  HeaderMascotState.thinking => MascotState.thinking,
  HeaderMascotState.speaking => MascotState.thinking,
  HeaderMascotState.working => MascotState.tool,
  HeaderMascotState.waiting => MascotState.needsYou,
  HeaderMascotState.offline => MascotState.offline,
};
