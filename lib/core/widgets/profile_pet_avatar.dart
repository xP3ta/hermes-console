import 'package:flutter/material.dart';

import '../companion/models/companion.dart';
import '../companion/models/companion_animation_state.dart';
import '../companion/render/spritesheet_renderer.dart';

/// A profile's pet identity: a still idle frame, with no presence or app size
/// preference. The floating app mascot retains its own animation renderer.
class ProfilePetAvatar extends StatelessWidget {
  const ProfilePetAvatar({super.key, required this.pet, required this.size});
  final Companion pet;
  final double size;

  @override
  Widget build(BuildContext context) => SpritesheetRenderer(
    key: ValueKey('profile-pet-${pet.slug}'),
    companion: pet,
    state: CompanionAnimationState.idle,
    size: size,
    animate: false,
  );
}
