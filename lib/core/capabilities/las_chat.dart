import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import '../models/connection.dart';
import '../navigation/chat_route.dart';
import '../screens/chat_screen.dart' show ChatScreen;
import '../services/new_session_factory.dart';

/// Opens the chat that learns a skill and completes when it is closed.
typedef LasChatLauncher =
    Future<void> Function(BuildContext context, String prompt);

/// The "Learn a skill" chat of [profile] on [connection]: a NEW chat of that
/// profile (its own model and tools, no conversation of another chat) that
/// starts with the request already written. It is pushed over the hub, so
/// going back lands on the list of skills, which then reads the server again.
///
/// Null for a read-only connection. An empty [profile] is the connection's
/// own active profile, which is what the hub lists too.
LasChatLauncher? lasChatFor(SavedConnection connection, String profile) {
  if (connection.readOnly) return null;
  final owner = profile.trim();
  return (context, prompt) async {
    final session = NewSessionFactory().create(
      title: Strings.of(context).lasChatTitle,
    );
    await openChatFromSection<void>(
      context,
      builder: (_) => ChatScreen(
        connection: connection,
        session: owner.isEmpty ? session : session.copyWith(profile: owner),
        initialPrompt: prompt,
      ),
    );
  };
}
