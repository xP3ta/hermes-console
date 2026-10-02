import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/session.dart';
import '../utils/session_title.dart';
import '../services/session_deletion.dart';
import '../theme/app_theme.dart';

/// Único presentador de fallos para las superficies de borrado. Mantiene el
/// mensaje localizado y accionable sin filtrar excepciones técnicas del
/// transporte (`Bad state:`, `FormatException:`, etc.).
String sessionDeletionFailureMessage(
  Strings strings,
  LinkedSessionDeleteResult result,
) {
  if (result.cronDeleted) return strings.cronStoppedChatDeleteFailed;
  return switch (result.failure?.code) {
    SessionDeletionFailureCode.lineageUnavailable =>
      strings.sessionDeletionLineageUnavailable,
    SessionDeletionFailureCode.missingCronJobId =>
      strings.sessionDeletionCronLinkUnavailable,
    SessionDeletionFailureCode.cronManagerUnavailable =>
      strings.sessionDeletionCronManagerUnavailable,
    SessionDeletionFailureCode.cronDeleteFailed =>
      strings.sessionDeletionCronFailed,
    SessionDeletionFailureCode.sessionDeleteFailed ||
    null => strings.sessionDeletionSessionFailed,
  };
}

/// Elección explícita para informes programados. La primera acción conserva el
/// cron; detener futuras ejecuciones nunca comparte el botón genérico «Borrar».
Future<LinkedCronDeletionMode?> showCronConversationDeleteDialog(
  BuildContext context,
  Session session,
) async {
  return showDialog<LinkedCronDeletionMode>(
    context: context,
    builder: (dialogContext) {
      final strings = Strings.of(dialogContext);
      return AlertDialog(
        scrollable: true,
        title: Text(strings.cronDeleteChoiceTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              strings.cronDeleteChoiceBody(
                localizedSessionTitle(strings, session),
              ),
            ),
            const SizedBox(height: 16),
            _CronDeletionChoice(
              key: const ValueKey('cron_delete_conversation_only'),
              icon: Icons.chat_bubble_outline,
              title: strings.cronDeleteConversationOnly,
              subtitle: strings.cronDeleteConversationOnlyHelp,
              onTap: () => Navigator.pop(
                dialogContext,
                LinkedCronDeletionMode.keepSchedule,
              ),
            ),
            const SizedBox(height: 8),
            _CronDeletionChoice(
              key: const ValueKey('cron_delete_conversation_and_schedule'),
              icon: Icons.delete_outline,
              title: strings.cronDeleteConversationAndSchedule,
              subtitle: strings.cronDeleteConversationAndScheduleHelp,
              destructive: true,
              onTap: () => Navigator.pop(
                dialogContext,
                LinkedCronDeletionMode.deleteSchedule,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(strings.commonCancel),
          ),
        ],
      );
    },
  );
}

class _CronDeletionChoice extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool destructive;

  const _CronDeletionChoice({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.destructive = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final foreground = destructive ? colors.error : colors.textPrimary;
    return Material(
      color: destructive
          ? colors.error.withValues(alpha: 0.07)
          : colors.surfaceVariant.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 20, color: foreground),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: foreground,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: destructive
                              ? colors.error.withValues(alpha: 0.85)
                              : colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right, size: 18, color: foreground),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
