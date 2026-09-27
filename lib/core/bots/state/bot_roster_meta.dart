import '../../models/agent_profile.dart';
import '../../services/bot_profile_client.dart';

/// Desktop-compatible roster metadata for one bot, read from and written to
/// `ui_meta['hermes-bots']` (spec 070 T208). Keys match the Desktop plugin:
/// `pinned`, `hidden` (hidden-bots.ts) and `sectionId`/`sectionName`
/// (user-sections.ts). The legacy `chat` pointer is ignored and dropped on
/// every write, per Desktop's canonical Bot Chat invariant.
final class BotRosterMeta {
  final bool pinned;
  final bool hidden;
  final String? sectionId;
  final String? sectionName;

  const BotRosterMeta({
    this.pinned = false,
    this.hidden = false,
    this.sectionId,
    this.sectionName,
  });

  factory BotRosterMeta.of(AgentProfile profile) => BotRosterMeta(
    pinned: profile.botPinned,
    hidden: profile.botHidden,
    sectionId: profile.botSectionId,
    sectionName: profile.botSectionName,
  );

  static const legacyKeys = {'chat'};
}

/// Writes roster metadata through `profiles.configure` read-modify-write
/// (`BotProfileGateway.patchBotMetadata`), so Desktop and Console share one
/// server-sourced state instead of per-device SharedPreferences.
final class BotRosterMetaWriter {
  final BotProfileGateway gateway;

  const BotRosterMetaWriter(this.gateway);

  Future<void> setPinned(String profile, bool pinned) =>
      _patch(profile, {'pinned': pinned});

  Future<void> setHidden(String profile, bool hidden) =>
      _patch(profile, {'hidden': hidden});

  Future<void> setSection(String profile, {String? id, String? name}) =>
      _patch(profile, {'sectionId': id, 'sectionName': name});

  Future<void> _patch(String profile, Map<String, dynamic> patch) =>
      gateway.patchBotMetadata(
        profile,
        patch,
        remove: BotRosterMeta.legacyKeys,
      );
}
