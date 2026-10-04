import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../design/modal.dart'
    show HermesDialogAction, HermesDialogActionStyle, showHermesDialog;
import '../models/provider_auth_failure.dart';
import '../screens/models_screen.dart';
import '../services/connection_manager.dart';
import '../theme/app_theme.dart';
import '../utils/api_error.dart';
import 'hermes_notice.dart';

/// Card title for a provider credential failure.
String providerAuthTitle(Strings s, ProviderAuthFailure failure) {
  final label = failure.label.trim();
  if (failure.origin == ProviderAuthOrigin.compaction) {
    // Only the summary step was refused; the chat itself keeps working.
    return label.isEmpty
        ? s.hr1215CompactionAuthTitleGeneric
        : s.hr1215CompactionAuthTitle(label);
  }
  if (failure.isOAuth) {
    return label.isEmpty
        ? s.hr1215AuthExpiredTitleGeneric
        : s.hr1215AuthExpiredTitle(label);
  }
  return label.isEmpty
      ? s.hr1215KeyRejectedTitleGeneric
      : s.hr1215KeyRejectedTitle(label);
}

/// One-line explanation under [providerAuthTitle].
String providerAuthBody(Strings s, ProviderAuthFailure failure) {
  if (failure.origin == ProviderAuthOrigin.compaction) {
    return s.hr1215CompactionOnlyAuthBody;
  }
  return failure.isOAuth ? s.hr1215AuthExpiredBody : s.hr1215KeyRejectedBody;
}

/// Label of the fix: sign in again (OAuth) or review the key (API key).
String providerAuthActionLabel(Strings s, ProviderAuthFailure failure) =>
    failure.isOAuth ? s.hr1215SignInAgain : s.hr1215CheckKey;

enum _ExternalSignInChoice { copy, done, cancel }

/// Accounts cards (`GET /api/providers/oauth` ids) whose `logged_in` proves
/// the credential a runtime provider actually uses, when that is not only
/// the card with the provider's own id.
///
/// Hermes' `anthropic` runtime falls back to Claude Code's
/// `~/.claude/.credentials.json` (agent/anthropic_credentials.py,
/// `resolve_anthropic_token` → `_resolve_claude_code_token_from_credentials`),
/// but the `anthropic` card deliberately ignores that file and reports it on
/// its own `claude-code` card (hermes_cli/web_server_oauth.py,
/// `_anthropic_oauth_status` / `_claude_code_only_status`). The catalog rows
/// carry no field linking the two, so the relation is declared here.
const Map<String, Set<String>> providerCredentialCards = {
  'anthropic': {'anthropic', 'claude-code'},
};

/// True when [rows] report a usable sign-in for runtime [provider].
bool providerSignedIn(List<Map<String, dynamic>> rows, String provider) {
  final accepted = providerCredentialCards[provider] ?? {provider};
  for (final row in rows) {
    final status = row['status'];
    if (accepted.contains(row['id']) &&
        status is Map &&
        status['logged_in'] == true &&
        status['free_tier'] != true) {
      return true;
    }
  }
  return false;
}

/// Runs the recovery for [failure] and returns true when the provider is
/// signed in again.
///
/// Mirrors Desktop's "Sign in again" (assistant-message.tsx →
/// `startManualProviderOAuth(provider, profile)`): it reads the Accounts
/// catalog of the chat's gateway [profile], starts the device-code flow when
/// the Dashboard offers one, and for providers Hermes only signs in from a
/// terminal (`flow: external`, e.g. Anthropic) shows the server command and
/// re-checks `status.logged_in`. An API key, or a provider missing from the
/// catalog, opens the Models screen where keys are edited.
Future<bool> runProviderReauth({
  required BuildContext context,
  required SavedConnection connection,
  required ProviderAuthFailure failure,
  required String? profile,
  DashboardClient Function(SavedConnection connection)? clientFactory,
}) async {
  final s = Strings.of(context);
  final provider = failure.provider.trim();
  Future<bool> openModels() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelsScreen(connection: connection),
      ),
    );
    return false;
  }

  if (!failure.isOAuth || provider.isEmpty) return openModels();
  final client = (clientFactory ?? DashboardClient.lazy)(connection);
  Map<String, dynamic>? row;
  try {
    final rows = await client.getOAuthProviders(profile: profile);
    for (final candidate in rows) {
      if (candidate['id'] == provider) row = candidate;
    }
  } catch (error) {
    if (!context.mounted) return false;
    HermesNotice.of(context).showSnackBar(
      SnackBar(
        content: Text(s.mdlOAuthStartError(localizedApiError(s, error))),
      ),
      kind: HermesNoticeKind.error,
    );
    return false;
  }
  if (!context.mounted) return false;
  if (row == null) return openModels();
  final label = failure.label.trim().isEmpty ? provider : failure.label.trim();
  final flow = (row['flow'] ?? '').toString().toLowerCase();
  if (flow == 'external') {
    final command = (row['cli_command'] ?? '').toString().trim();
    return _externalSignIn(
      context: context,
      client: client,
      provider: provider,
      label: label,
      command: command,
      profile: profile,
    );
  }

  Map<String, dynamic> start;
  try {
    start = await client.startOAuth(provider, profile: profile);
  } catch (error) {
    if (!context.mounted) return false;
    HermesNotice.of(context).showSnackBar(
      SnackBar(
        content: Text(s.mdlOAuthStartError(localizedApiError(s, error))),
      ),
      kind: HermesNoticeKind.error,
    );
    return false;
  }
  if (!context.mounted) return false;
  final sessionId = providerOAuthStartField(start, const [
    'session_id',
    'session',
    'poll_id',
    'device_code',
    'state',
  ]);
  final url = normalizeProviderOAuthBrowserUrl(
    providerOAuthStartField(start, const [
      'verification_uri_complete',
      'verification_url_complete',
      'auth_url',
      'authorization_url',
      'login_url',
      'verification_url',
      'verification_uri',
      'url',
    ]),
    connection: connection,
    dashboardBaseUrl: client.baseUrl,
  );
  if (sessionId.isEmpty || url.isEmpty) {
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(s.mdlOAuthNotAvailable(label))),
      kind: HermesNoticeKind.warning,
    );
    return false;
  }
  final ok = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ProviderOAuthLoginScreen(
        providerName: label,
        providerSlug: provider,
        url: url,
        code: providerOAuthStartField(start, const ['user_code', 'code']),
        expiresIn: (start['expires_in'] as num?)?.toInt() ?? 0,
        poll: () => client.pollOAuth(provider, sessionId, profile: profile),
      ),
    ),
  );
  return ok == true;
}

Future<bool> _externalSignIn({
  required BuildContext context,
  required DashboardClient client,
  required String provider,
  required String label,
  required String command,
  required String? profile,
}) async {
  final s = Strings.of(context);
  while (context.mounted) {
    final choice = await showHermesDialog<_ExternalSignInChoice>(
      context: context,
      surfaceKey: const ValueKey('hr1215-external-signin'),
      title: s.hr1215ExternalTitle(label),
      message: command.isEmpty
          ? s.hr1215ExternalBodyNoCommand
          : s.hr1215ExternalBody(command),
      actions: [
        HermesDialogAction(
          label: s.commonCancel,
          value: _ExternalSignInChoice.cancel,
          style: HermesDialogActionStyle.cancel,
        ),
        if (command.isNotEmpty)
          HermesDialogAction(
            key: const ValueKey('hr1215-copy-command'),
            label: s.hr1215CopyCommand,
            value: _ExternalSignInChoice.copy,
            style: HermesDialogActionStyle.cancel,
          ),
        HermesDialogAction(
          key: const ValueKey('hr1215-signed-in'),
          label: s.hr1215SignedInCheck,
          value: _ExternalSignInChoice.done,
        ),
      ],
    );
    if (!context.mounted) return false;
    switch (choice) {
      case _ExternalSignInChoice.copy:
        await Clipboard.setData(ClipboardData(text: command));
        if (!context.mounted) return false;
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(s.hr1215CommandCopied)),
          kind: HermesNoticeKind.success,
        );
        continue;
      case _ExternalSignInChoice.done:
        // The tap is acknowledged at once: the dialog has closed and the
        // server may take a while to answer.
        final notices = HermesNotice.of(context);
        final checking = notices.show(
          message: s.hr1215CheckingSignIn(label),
          sticky: true,
        );
        bool signedIn;
        try {
          final rows = await client.getOAuthProviders(profile: profile);
          signedIn = providerSignedIn(rows, provider);
        } catch (error) {
          checking?.dismiss();
          if (!context.mounted) return false;
          // Not knowing is not "still signed out".
          notices.showSnackBar(
            SnackBar(
              content: Text(
                s.hr1215SignInCheckFailed(label, localizedApiError(s, error)),
              ),
            ),
            kind: HermesNoticeKind.error,
          );
          continue;
        }
        checking?.dismiss();
        if (!context.mounted) return false;
        if (signedIn) return true;
        notices.showSnackBar(
          SnackBar(content: Text(s.hr1215StillSignedOut(label))),
          kind: HermesNoticeKind.warning,
        );
        continue;
      case _ExternalSignInChoice.cancel:
      case null:
        return false;
    }
  }
  return false;
}

/// Chat banner for a compaction the provider refused: the turn itself did
/// not fail, so there is no error bubble to carry the fix.
class ProviderAuthBanner extends StatelessWidget {
  const ProviderAuthBanner({
    required this.failure,
    required this.onAction,
    required this.onDismiss,
    super.key,
  });

  final ProviderAuthFailure failure;
  final VoidCallback? onAction;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final title = providerAuthTitle(s, failure);
    return Semantics(
      container: true,
      label: title,
      child: Container(
        key: const ValueKey('hr1215-provider-auth-banner'),
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
        decoration: BoxDecoration(
          color: colors.error.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colors.error.withValues(alpha: 0.18)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(Icons.key_off_rounded, size: 16, color: colors.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(
                      context,
                    ).textTheme.titleSmall?.copyWith(color: colors.error),
                  ),
                ),
                IconButton(
                  key: const ValueKey('hr1215-provider-auth-dismiss'),
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close_rounded, size: 20),
                  tooltip: s.commonClose,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                providerAuthBody(s, failure),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                key: const ValueKey('hr1215-provider-auth-action'),
                onPressed: onAction,
                icon: const Icon(Icons.key_rounded, size: 18),
                label: Text(providerAuthActionLabel(s, failure)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
