import '../models/agent_profile.dart';
import '../models/connection.dart';
import 'bot_roster_store.dart';
import 'session_deletion.dart';

/// The single re-read after a restore reached a terminal status: profiles
/// come from the server and replace the shared roster (never merged into it,
/// and a name the server repeats appears once), then the conversation lists
/// are told to re-read their authority.
///
/// Saved connections, credentials, drafts, the outbox and archive overlays
/// are not touched here or anywhere else in the restore.
Future<void> refreshAfterRestore({
  required SavedConnection connection,
  required Future<List<AgentProfile>> Function() readProfiles,
  required BotRosterRegistry roster,
  HistoryCleanupInvalidationBus? bus,
}) async {
  final ticket = roster.beginRead(connection.id);
  final read = await readProfiles();
  final seen = <String>{};
  final profiles = [
    for (final profile in read)
      if (seen.add(profile.name)) profile,
  ];
  roster.publish(connection.id, connection.label, profiles, ticket: ticket);
  (bus ?? historyCleanupInvalidations).publish(
    connectionId: connection.id,
    scope: HistoryCleanupScope.normalConversations,
  );
}
