import 'dart:convert';

import '../../models/mission_control.dart';
import '../../models/session.dart';
import '../../services/active_chat_service.dart';

/// Chats of [connectionId] attached in [service] that Bots (and Home) read
/// live state from: the service's active ids, then the attached chats of
/// the listed [sessions]. Each chat once.
Iterable<ActiveChat> missionActiveChats(
  ActiveChatService service,
  String connectionId,
  Iterable<Session> sessions,
) sync* {
  final seen = <ActiveChat>{};
  for (final rawId in service.activeIds.value) {
    try {
      final decoded = jsonDecode(rawId);
      if (decoded is! List || decoded.length != 3) continue;
      final chatConnection = decoded[0];
      final profile = decoded[1];
      final sessionId = decoded[2];
      if (chatConnection != connectionId ||
          profile is! String ||
          sessionId is! String) {
        continue;
      }
      final chat = service.of(connectionId, sessionId, profile: profile);
      if (chat != null && seen.add(chat)) yield chat;
    } catch (_) {
      // Active ids are internal opaque identities. Ignore a malformed value
      // instead of letting observability take down the existing chat path.
    }
  }
  for (final session in sessions) {
    final owner = session.profile?.trim();
    if (owner == null || owner.isEmpty) continue;
    final chat = service.of(connectionId, session.id, profile: owner);
    if (chat != null && seen.add(chat)) yield chat;
  }
}

/// The phase Bots shows for an attached chat.
MissionLivePhase missionPhaseOf(ActiveChat chat) {
  if (chat.pendingApproval != null) {
    return MissionLivePhase.approvalRequired;
  }
  if (chat.state == ChatPipelineState.failed) return MissionLivePhase.error;
  return switch (chat.activityKind) {
    ChatActivityKind.thinking => MissionLivePhase.thinking,
    ChatActivityKind.usingTools => MissionLivePhase.working,
    ChatActivityKind.responding => MissionLivePhase.responding,
    ChatActivityKind.awaitingApproval => MissionLivePhase.approvalRequired,
    null => MissionLivePhase.idle,
  };
}

/// [missionActiveChats] as [MissionLiveChat]s for [MissionProjector.build].
List<MissionLiveChat> missionLiveChats(
  ActiveChatService service,
  String connectionId,
  List<Session> sessions,
) {
  final sessionByIdentity = <String, Session>{};
  final sessionsById = <String, List<Session>>{};
  for (final session in sessions) {
    final owner = session.profile?.trim();
    if (owner != null && owner.isNotEmpty) {
      sessionByIdentity['$owner\u0000${session.id}'] = session;
      sessionByIdentity['$owner\u0000${session.logicalId}'] = session;
    }
    sessionsById.putIfAbsent(session.id, () => []).add(session);
    sessionsById.putIfAbsent(session.logicalId, () => []).add(session);
  }
  return missionActiveChats(service, connectionId, sessions)
      .map((chat) {
        final profile = Session.profileOwner(chat.sessionProfile);
        final storedId = chat.storedSessionId;
        final lookupId = storedId ?? chat.sessionId;
        final idMatches = sessionsById[lookupId] ?? const <Session>[];
        final session =
            sessionByIdentity['$profile\u0000$lookupId'] ??
            sessionByIdentity['$profile\u0000${chat.sessionId}'] ??
            (idMatches.length == 1 ? idMatches.single : null);
        return MissionLiveChat(
          profileName: profile,
          sessionId: storedId ?? chat.sessionId,
          title: chat.sessionTitle,
          phase: missionPhaseOf(chat),
          approval: chat.pendingApproval,
          model: session?.model,
          settledAt: chat.lastTerminalAt,
          botChat: chat.sessionId == 'mob-bot-$profile',
          subagentCount: chat.safeActiveSubagentCount,
        );
      })
      .toList(growable: false);
}
