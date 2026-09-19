import 'package:flutter/foundation.dart';

import '../models/agent_profile.dart';
import '../models/bot_mention.dart';

abstract interface class BotMentionRosterGateway {
  Future<List<AgentProfile>> loadMentionProfiles();
}

/// Only snapshots already loaded by Console contribute remote identities.
final class BotMentionRoster extends ChangeNotifier {
  static final shared = BotMentionRoster();
  final Map<String, ({String label, List<AgentProfile> profiles})> _sources =
      {};

  final Map<String, int> _generations = {};
  int generation(String connectionId) => _generations[connectionId] ?? 0;

  bool contains(String connectionId) => _sources.containsKey(connectionId);

  void replace(
    String connectionId,
    String label,
    List<AgentProfile> profiles, {
    int? expectedGeneration,
  }) {
    if (expectedGeneration != null &&
        expectedGeneration != generation(connectionId)) {
      return;
    }
    _sources[connectionId] = (
      label: label,
      profiles: List.unmodifiable(profiles),
    );
    notifyListeners();
  }

  void remove(String connectionId) {
    _generations[connectionId] = generation(connectionId) + 1;
    if (_sources.remove(connectionId) != null) notifyListeners();
  }

  @visibleForTesting
  void clear() {
    _sources.clear();
    notifyListeners();
  }

  List<BotMention> bots(String focusedConnectionId) => [
    for (final entry in _sources.entries)
      for (final profile in entry.value.profiles)
        BotMention(
          connectionId: entry.key,
          profile: profile.name,
          handle:
              profile.mentionHandle.isNotEmpty &&
                  profile.mentionHandle != profile.name
              ? profile.mentionHandle
              : entry.key != focusedConnectionId
              ? '${profile.name}-${entry.key}'.toLowerCase()
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
          connectionLabel: entry.value.label,
          remote: entry.key != focusedConnectionId,
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
