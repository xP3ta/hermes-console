// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// "Accounts" of the Models screen: Desktop's Settings → Providers → Accounts
// (`providers-settings.tsx`, `OAuthPicker`). The rows and their state are
// the server's `GET /api/providers/oauth` for the profile on screen: the
// accounts that are signed in and that Hermes itself can sign in again or
// sign out. Signing in to another one is offered with the other providers
// still to set up.
//
// An account that belongs to another program on the server (the Claude Code
// or GitHub login) has nothing Hermes can do to it. Desktop offers to run
// the server's `disconnect_command` in its terminal for those; this app
// never runs, offers or shows it: it deletes that program's login file. The
// provider such a login connects is removed from its own group instead.

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart' show HermesAction, showHermesMenu;
import '../models/oauth_account.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_premium_ui.dart'
    show HermesListRow, HermesListSection;
import '../widgets/provider_logo.dart';
import 'models_look.dart';

enum _AccountAction { signIn, disconnect }

class ModelsAccountsSection extends StatelessWidget {
  const ModelsAccountsSection({
    required this.accounts,
    required this.onSignIn,
    required this.onDisconnect,
    this.enabled = true,
    super.key,
  });

  final List<OAuthAccount> accounts;
  final ValueChanged<OAuthAccount> onSignIn;
  final ValueChanged<OAuthAccount> onDisconnect;
  final bool enabled;

  Future<void> _openMenu(BuildContext context, OAuthAccount account) async {
    final s = Strings.of(context);
    final action = await showHermesMenu<_AccountAction>(
      context: context,
      title: account.name,
      actions: [
        if (account.canSignInHere)
          HermesAction(
            key: ValueKey('models-account-signin-${account.id}'),
            value: _AccountAction.signIn,
            label: s.mdlAccountSignInAgain,
          ),
        if (account.disconnectable)
          HermesAction(
            key: ValueKey('models-account-disconnect-${account.id}'),
            value: _AccountAction.disconnect,
            label: s.mdlRemove,
            destructive: true,
          ),
      ],
    );
    switch (action) {
      case _AccountAction.signIn:
        onSignIn(account);
      case _AccountAction.disconnect:
        onDisconnect(account);
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final connected = [
      for (final account in accounts)
        if (account.signedIn &&
            (account.canSignInHere || account.disconnectable))
          account,
    ];
    if (connected.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const ValueKey('models-accounts'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ModelsSectionLabel(s.mdlSectionAccounts),
        HermesListSection(
          margin: const EdgeInsets.only(bottom: 8),
          children: [
            for (final account in connected)
              Builder(
                builder: (context) => HermesListRow(
                  key: ValueKey('models-account-${account.id}'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  leading: SizedBox.square(
                    dimension: HermesListRow.leadingExtent,
                    child: Center(
                      child: ProviderLogo(
                        provider: account.id,
                        providerName: account.name,
                        size: 20,
                      ),
                    ),
                  ),
                  title: account.name,
                  subtitle: s.commonConnected,
                  trailing: Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: colors.textDisabled,
                  ),
                  onTap: enabled ? () => _openMenu(context, account) : null,
                ),
              ),
          ],
        ),
      ],
    );
  }
}
