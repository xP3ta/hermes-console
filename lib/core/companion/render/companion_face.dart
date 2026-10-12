import 'package:flutter/material.dart';

import '../../bots/ui/roster/living_bot_face.dart';
import '../../models/agent_profile.dart';
import '../../widgets/mission_profile_avatar.dart';
import '../models/companion_mood.dart';

/// Name whose face is the standard Hermes face: the fallback when no profile
/// is known (no instance, no scope).
const kHermesFaceName = 'hermes';

/// Where the face shown in place of a missing companion pet comes from, in
/// priority order.
enum ProfileFaceSource {
  /// The user-set profile photo (only when it can actually be loaded).
  customAvatar,

  /// The bot's original face: its configured Blobatar shape, or the one
  /// derived from its name.
  botFace,

  /// The standard Hermes face.
  hermesDefault,
}

typedef ProfileFaceChoice = ({ProfileFaceSource source, String name});

/// The one rule for a profile's face when no custom pet is shown:
/// custom avatar > the bot's original face > the standard Hermes face.
/// Never a generic sprite.
ProfileFaceChoice profileFaceFor({
  String? profileName,
  AgentProfile? profile,
  MissionProfileAvatarCache? avatarCache,
}) {
  final name = (profile?.name ?? profileName ?? '').trim();
  if (name.isEmpty) {
    return (source: ProfileFaceSource.hermesDefault, name: kHermesFaceName);
  }
  if (profile != null && profile.botPaintsPhoto && avatarCache != null) {
    return (source: ProfileFaceSource.customAvatar, name: name);
  }
  return (source: ProfileFaceSource.botFace, name: name);
}

extension CompanionMoodFace on CompanionMood {
  /// State the original face expresses for this companion mood.
  BotFaceSignal get faceSignal => switch (this) {
    CompanionMood.idle || CompanionMood.offline => BotFaceSignal.idle,
    CompanionMood.thinking ||
    CompanionMood.connecting => BotFaceSignal.thinking,
    CompanionMood.waiting || CompanionMood.error => BotFaceSignal.attention,
    CompanionMood.success || CompanionMood.jump => BotFaceSignal.speaking,
  };
}

/// The profile's original face standing in for the companion pet, following
/// [profileFaceFor]. [animate] false paints a still face (history rows).
class CompanionFace extends StatelessWidget {
  final String? profileName;
  final AgentProfile? profile;
  final MissionProfileAvatarCache? avatarCache;
  final CompanionMood mood;
  final double size;
  final bool animate;

  const CompanionFace({
    super.key,
    this.profileName,
    this.profile,
    this.avatarCache,
    this.mood = CompanionMood.idle,
    this.size = 44,
    this.animate = true,
  });

  @override
  Widget build(BuildContext context) {
    final choice = profileFaceFor(
      profileName: profileName,
      profile: profile,
      avatarCache: avatarCache,
    );
    final known = choice.source != ProfileFaceSource.hermesDefault;
    return LivingBotFace(
      profileName: choice.name,
      profile: known ? profile : null,
      avatarCache: choice.source == ProfileFaceSource.customAvatar
          ? avatarCache
          : null,
      signal: animate ? mood.faceSignal : BotFaceSignal.idle,
      size: size,
      entrance: false,
    );
  }
}
