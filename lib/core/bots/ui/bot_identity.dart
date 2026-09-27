import 'package:flutter/painting.dart' show Color, HSLColor;

import '../../models/agent_profile.dart';
import '../../widgets/hermes_bot_face.dart' show HermesBlobatarFaceVisual;
import '../../widgets/mission_profile_avatar.dart'
    show MissionProfileAvatarCache;

/// Identity colour of a local bot: the colour of the face the user actually
/// sees for it (roster, room, Bot Chat). A procedural face uses its Blobatar
/// head colour; only a raster avatar that is really painted (explicit photo,
/// or loaded in [avatarCache]) uses the Bot's `ui_meta` colour. A profile
/// whose image never loads falls back to the Blobatar and so does its name.
Color botIdentityColor(
  AgentProfile profile, {
  MissionProfileAvatarCache? avatarCache,
}) {
  final hex = profile.botColorHex;
  final raster =
      profile.botPaintsPhoto &&
      (profile.botImageKind == 'photo' ||
          (avatarCache != null &&
              avatarCache.hasResolved(profile.name) &&
              avatarCache.resolved(profile.name) != null));
  if (raster && hex != null) return _fromHex(hex);
  final visual =
      HermesBlobatarFaceVisual.tryParse(
        shapeWire: profile.botFaceShape ?? 'blobatar',
        profileName: profile.name,
      ) ??
      HermesBlobatarFaceVisual.tryParse(
        shapeWire: 'blobatar',
        profileName: profile.name,
      );
  if (visual != null) return visual.headColor;
  if (hex != null) return _fromHex(hex);
  return HSLColor.fromAHSL(1, 140, 0.55, 0.64).toColor();
}

Color _fromHex(String hex) =>
    Color(int.parse('ff${hex.substring(1)}', radix: 16));
