import 'package:flutter/material.dart';

import '../../models/agent_profile.dart';
import '../../screens/chat_screen.dart';
import '../../services/connection_manager.dart';
import '../data/bot_mode_repository.dart';
import '../state/bot_chat_target.dart';

/// The Bot Chat of the teammate named [target], resolved the way Mission
/// Control opens a bot (`_openChat`): the profile's `canonical_session`, or
/// the registry row titled exactly «Bot Chat», or a draft that creates it.
/// Null when the teammate is not on this gateway's roster. A registry lookup
/// that fails throws: creating then could fork an existing canonical row.
Future<({AgentProfile profile, BotChatTarget target})?> resolveTeammateChat(
  BotModeGateway gateway,
  String target,
) async {
  final profiles = await gateway.listProfiles();
  final profile = profiles.where((p) => p.name == target).firstOrNull;
  if (profile == null) return null;
  AgentProfileSessionSummary? titleRow;
  if (profile.canonicalBotChatSessionId == null) {
    titleRow = await gateway.findBotChatByTitle(profile.name);
  }
  return (
    profile: profile,
    target: BotChatTarget.resolve(profile, titleLookup: titleRow),
  );
}

/// The route that fronts that Bot Chat on [connection].
Route<void> teammateChatRoute({
  required SavedConnection connection,
  required AgentProfile profile,
  required BotChatTarget target,
}) {
  final session = Session(
    id: 'mob-bot-${profile.name}',
    lineageRootId: target.sessionId,
    title: botChatTitle,
    model: profile.model.isEmpty ? 'hermes-agent' : profile.model,
    source: target.chatSource,
    messageCount: target.exists ? 1 : 0,
    isActive: true,
    preview: '',
    startedAt: target.exists
        ? 0
        : DateTime.now().millisecondsSinceEpoch.toDouble() / 1000,
    profile: profile.name,
    isDefaultProfile: profile.isDefault,
  );
  // The screen Mission Control opens for a bot (`buildBotChatDestination`).
  return MaterialPageRoute<void>(
    builder: (_) => ChatScreen(
      connection: connection,
      session: session,
      initialStoredSessionId: target.sessionId,
      missionBotProfile: profile,
    ),
  );
}
