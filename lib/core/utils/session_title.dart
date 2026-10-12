import '../../l10n/app_localizations.dart';
import '../models/session.dart';

/// [Session.displayTitle] with its generic fallbacks in the app language.
String localizedSessionTitle(Strings strings, Session session) =>
    session.titleWith(
      (kind) => switch (kind) {
        SessionGenericTitle.kanbanTask => strings.i18n1215KanbanTask,
        SessionGenericTitle.scheduledTask => strings.i18n1215ScheduledTask,
        SessionGenericTitle.conversation => strings.i18n1215Conversation,
      },
    );
