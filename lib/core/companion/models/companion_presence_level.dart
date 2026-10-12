/// Where the pet shows ("Presencia" in the Mascotas screen). The user picks
/// one of three that say where it is:
///
/// - `off` ("Apagada"): nowhere.
/// - `chat` ("Solo en el chat"): standing on the chat's island, and nowhere
///   else.
/// - `full` ("En toda la app"): on the chat's island and, outside chats, as
///   the floating mascot. The default.
///
/// `ambient` is never chosen or stored. It is what a chat reads
/// (`CompanionController.presenceLevel`) while the presence is on but the
/// profile has no pet of its own: the chat's island then keeps the face it
/// always had (the profile's own, or Hermes' sprite) instead of a stand-in.
///
/// Until 1.2.15 the choices were off / minimal / full. "Minimal" (the
/// default) promised Inicio and the voice mode, surfaces that no longer host
/// the pet, and "full" added the chat: both read as `full` now, the only
/// choice that shows the pet outside the chat as they promised.
enum CompanionPresenceLevel { off, ambient, chat, full }

extension CompanionPresenceLevelX on CompanionPresenceLevel {
  /// What is stored for a choice made now. `full` is stored as `app`: a
  /// stored `full` is the old "Completa" (see [companionPresenceIsLegacyFull]).
  String get id => switch (this) {
    CompanionPresenceLevel.full => 'app',
    _ => name,
  };

  /// The pet shows somewhere.
  bool get isVisible => this != CompanionPresenceLevel.off;

  /// The pet stands on the chat's island (and wherever a chat or a room
  /// shows a profile's state with its pet).
  bool get showsStatusPresence =>
      this == CompanionPresenceLevel.chat ||
      this == CompanionPresenceLevel.full;

  /// The pet floats on every screen that is not a chat.
  bool get showsEverywhere => this == CompanionPresenceLevel.full;
}

/// The user's choice stored as [id]. An unknown or missing id is [fallback]
/// (`full`), and so is the retired `minimal`; `ambient` is never a choice.
CompanionPresenceLevel companionPresenceLevelFromId(
  String? id, {
  CompanionPresenceLevel fallback = CompanionPresenceLevel.full,
}) => switch (id?.trim()) {
  'off' => CompanionPresenceLevel.off,
  'chat' => CompanionPresenceLevel.chat,
  'full' || 'app' || 'minimal' => CompanionPresenceLevel.full,
  _ => fallback,
};

/// True for the value 1.2.14 and earlier stored for "Completa". With it the
/// chat's island showed the pet's slot even for a profile without a pet
/// (its own face stood in); that is kept for whoever had it.
bool companionPresenceIsLegacyFull(String? id) => id?.trim() == 'full';
