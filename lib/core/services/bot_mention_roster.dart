import 'package:flutter/foundation.dart';

import '../models/agent_profile.dart';
import '../models/bot_mention.dart';
import 'bot_roster_store.dart';

abstract interface class BotMentionRosterGateway {
  Future<List<AgentProfile>> loadMentionProfiles();
}

/// Mention view over [BotRosterRegistry]. Only live snapshots (not the
/// offline cache) contribute routable identities; [profileFor] may also use
/// the cached roster for display.
final class BotMentionRoster extends ChangeNotifier {
  BotMentionRoster([BotRosterRegistry? registry])
    : registry = registry ?? BotRosterRegistry(),
      _ownsRegistry = registry == null {
    this.registry.addListener(notifyListeners);
  }

  static final shared = BotMentionRoster(BotRosterRegistry.shared);

  final BotRosterRegistry registry;
  final bool _ownsRegistry;

  /// Stamp for a read about to start; pass it back as `expectedGeneration`.
  int generation(String connectionId) => registry.beginRead(connectionId);

  bool contains(String connectionId) =>
      registry.peek(connectionId)?.isLive ?? false;

  /// Loaded profile [name] on [connectionId] (face shape/display name for
  /// notifications and widgets); null when not loaded yet.
  AgentProfile? profileFor(String connectionId, String name) =>
      registry.peek(connectionId)?.profile(name);

  void replace(
    String connectionId,
    String label,
    List<AgentProfile> profiles, {
    int? expectedGeneration,
  }) => registry.publish(
    connectionId,
    label,
    profiles,
    ticket: expectedGeneration,
  );

  void remove(String connectionId) => registry.forget(connectionId);

  @visibleForTesting
  void clear() => registry.clear();

  @override
  void dispose() {
    registry.removeListener(notifyListeners);
    if (_ownsRegistry) registry.dispose();
    super.dispose();
  }

  List<BotMention> bots(String focusedConnectionId) => [
    for (final store in registry.stores)
      if (store.isLive)
        for (final profile in store.profiles)
          BotMention(
            connectionId: store.connectionId,
            profile: profile.name,
            handle:
                profile.mentionHandle.isNotEmpty &&
                    profile.mentionHandle != profile.name
                ? profile.mentionHandle
                : store.connectionId != focusedConnectionId
                ? '${profile.name}-${store.connectionId}'.toLowerCase()
                : profile.name.toLowerCase() == 'default'
                ? 'hermes'
                : profile.name,
            title:
                profile.botModeUiMeta['title'] is String &&
                    (profile.botModeUiMeta['title'] as String).trim().isNotEmpty
                ? profile.botModeUiMeta['title'] as String
                : profile.mentionTitle,
            displayName: profile.displayName,
            alternateTitle: profile.mentionTitle,
            connectionLabel: store.snapshot!.label,
            remote: store.connectionId != focusedConnectionId,
            avatarProfile: profile,
          ),
  ];

  BotMentionResolver resolver(String connectionId, String profile) =>
      BotMentionResolver(
        bots(connectionId),
        connectionId: connectionId,
        profile: profile.isEmpty ? 'default' : profile,
      );
}
