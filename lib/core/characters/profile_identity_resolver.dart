import '../companion/models/companion.dart';
import '../models/agent_profile.dart';
import '../models/profile_identity.dart';
import 'bot_character.dart';
import 'bot_character_store.dart';

/// Where a profile's face comes from.
enum ProfileIdentitySource { pet, photo, character, face }

/// What a profile looks like, decided once for every surface of the app.
class ResolvedProfileIdentity {
  const ResolvedProfileIdentity._(this.source, {this.pet, this.character});

  final ProfileIdentitySource source;

  /// Set when [source] is [ProfileIdentitySource.pet].
  final Companion? pet;

  /// The saved character: set when [source] is
  /// [ProfileIdentitySource.character] (and kept under a pet).
  final BotCharacter? character;
}

/// The ONE resolver of a profile's visual identity. Perfiles, the switcher,
/// the drawer, Inicio, Bots, the hub and the editor all go through it (by way
/// of `MissionProfileAvatar` or `LivingBotFace`), so a profile cannot look
/// different from one list to the next.
///
/// Priority: its own pet, then its photo (only when [canLoadPhoto]: a cache
/// to read it from), then the character saved in the Studio, then the
/// configured face. [connectionId] keys the pet and the saved character: a
/// surface that does not pass it cannot see them.
ResolvedProfileIdentity resolveProfileIdentity({
  required String profileName,
  String? connectionId,
  AgentProfile? profile,
  bool? hasAvatar,
  String? imageKind,
  String? shape,
  bool canLoadPhoto = true,
  BotCharacterStore? characters,
}) {
  final base = profileIdentityFor(
    profileName: profileName,
    connectionId: connectionId,
    profile: profile,
    hasAvatar: hasAvatar,
    imageKind: imageKind,
    shape: shape,
  );
  // Looked up first: a surface that cannot show the pet (App Lock) still
  // wants the character under it.
  final character = (characters ?? BotCharacterStore.shared).characterFor(
    connectionId,
    profileName,
  );
  final pet = base.pet;
  if (pet != null) {
    return ResolvedProfileIdentity._(
      ProfileIdentitySource.pet,
      pet: pet,
      character: character,
    );
  }
  if (base.kind == ProfileIdentityKind.image && canLoadPhoto) {
    return const ResolvedProfileIdentity._(ProfileIdentitySource.photo);
  }
  if (character != null) {
    return ResolvedProfileIdentity._(
      ProfileIdentitySource.character,
      character: character,
    );
  }
  return const ResolvedProfileIdentity._(ProfileIdentitySource.face);
}
