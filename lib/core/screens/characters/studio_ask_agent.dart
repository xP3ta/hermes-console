import '../../../l10n/app_localizations.dart';
import '../../models/connection.dart';
import '../../navigation/chat_route.dart';
import '../../services/new_session_factory.dart';
import '../chat_screen.dart' show ChatScreen;
import 'studio_panels.dart' show StudioAskAgent;

/// The "Generate" request of the character editor for [profile] on
/// [connection]: a NEW chat of that profile (so it runs the bot's own model,
/// with no conversation or memory of another chat) that starts with the
/// prompt already written.
///
/// It is pushed over the editor (never `openChatFromHome`, which would drop
/// the editor and its draft), so going back lands on the draft, where
/// "Paste reply" takes the answer. Null for a read-only connection or without
/// an active profile: the editor then leaves the block off.
StudioAskAgent? studioAskAgentFor(SavedConnection connection, String profile) {
  final owner = profile.trim();
  if (connection.readOnly || owner.isEmpty) return null;
  return (context, prompt) => openChatFromSection<void>(
    context,
    builder: (_) => ChatScreen(
      connection: connection,
      session: NewSessionFactory()
          .create(title: Strings.of(context).sagChatTitle)
          .copyWith(profile: owner),
      initialPrompt: prompt,
    ),
  );
}
