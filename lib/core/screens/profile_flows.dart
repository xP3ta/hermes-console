import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../services/active_profile_scope.dart';
import '../services/bot_roster_store.dart';
import '../services/connection_manager.dart';
import '../services/tui_gateway_client.dart';
import '../theme/app_theme.dart';
import '../utils/api_error.dart';
import '../widgets/hermes_notice.dart';
import 'bot_create_screen.dart';
import 'lock_screen.dart';

/// The one create flow for a profile. Profiles and Bot Mode both open it:
/// a bot is a profile, so there is one form (Desktop's "New Bot" dialog,
/// with the Dashboard as fallback on Gateways without `profiles.create`).
/// Returns the new profile name, or null when cancelled.
Future<String?> openCreateProfile(
  BuildContext context, {
  required SavedConnection connection,
  required Set<String> existing,
  HermesDesktopBotCreationGateway? gateway,
  Future<List<ModelProvider>> Function(String profile)? modelOptionsLoader,
}) => Navigator.of(context).push<String>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => BotCreateScreen(
      connection: connection,
      existing: existing,
      gateway: gateway,
      modelOptionsLoader: modelOptionsLoader,
    ),
  ),
);

/// The one delete flow for a profile, from Profiles or from a bot in Bot
/// Mode: App Lock, the same confirmation, the server delete, the shared
/// roster and, when it was the active profile, back to the default one.
/// Returns true once the profile is gone.
Future<bool> deleteProfileFlow(
  BuildContext context, {
  required SavedConnection connection,
  required ConnectionManager connManager,
  required String profile,
  BotRosterRegistry? rosterRegistry,
  Future<void> Function(String name)? deleteRemote,
}) async {
  final name = profile.trim();
  if (connection.readOnly || name.isEmpty || name == 'default') return false;
  final str = Strings.of(context);
  final colors = Theme.of(context).hermes;
  final notice = HermesNotice.of(context);
  // Destructive server action: App Lock when enabled.
  final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
  if (lock != null && lock.enabled) {
    final ok = await LockScreen.verify(
      context,
      lock,
      reason: str.prfDeleteVerifyReason,
    );
    if (!ok || !context.mounted) return false;
  }
  final confirm = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final s = Strings.of(ctx);
      return AlertDialog(
        key: const ValueKey('profile-delete-confirm'),
        backgroundColor: colors.surface,
        title: Text(s.prfDeleteTitle),
        content: Text(
          s.prfDeleteContent(name),
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.prfCancel),
          ),
          TextButton(
            key: const ValueKey('profile-delete-confirm-yes'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              s.prfDeleteConfirm,
              style: TextStyle(color: colors.error),
            ),
          ),
        ],
      );
    },
  );
  if (confirm != true) return false;
  try {
    if (deleteRemote != null) {
      await deleteRemote(name);
    } else {
      final client = DashboardClient.lazy(connection);
      try {
        await client.deleteProfile(name);
      } finally {
        client.close();
      }
    }
  } catch (error) {
    notice.show(
      message: str.prfDeleteError(humanizeApiError(error)),
      kind: HermesNoticeKind.error,
    );
    return false;
  }
  (rosterRegistry ?? BotRosterRegistry.shared).profileDeleted(
    connection.id,
    name,
  );
  // The deleted profile cannot stay active: the app goes back to default.
  final scope = ActiveProfileScope.of(connManager, connection.id);
  if (scope.owner == name) await scope.switchTo('');
  notice.show(message: str.prfDeleted(name), kind: HermesNoticeKind.success);
  return true;
}
