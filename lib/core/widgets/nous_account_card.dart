// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// The Nous Portal account as one card: its state in plain words (connected,
// with what tier and until when; free tier; not connected; not offered by
// this server) and the one action that follows from it.

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/tokens.dart';
import '../models/oauth_account.dart';
import '../theme/app_theme.dart';
import 'hermes_premium_ui.dart' show HermesListSection;
import 'hermes_ui.dart' show HermesPrimaryButton;
import 'provider_logo.dart';

/// The status line of a Nous Portal [account] (null: the server lists no
/// such card).
String nousAccountStatusLine(
  Strings s,
  OAuthAccount? account, {
  required MaterialLocalizations dates,
  DateTime? now,
}) {
  if (account == null) return s.nacCardUnsupported;
  if (!account.connected) return s.nacCardNotConnected;
  if (account.freeTier) return s.nacCardFreeTier;
  // The server renews a credential that has a refresh token by itself: its
  // date is not news. Without one, the date is when it stops working.
  if (account.expiredAt(now ?? DateTime.now())) return s.nacCardExpired;
  final expires = account.expiresAt;
  final tier = account.accountTier;
  final head = tier.isEmpty
      ? s.nacCardConnected
      : s.nacCardConnectedTier(_tierLabel(tier));
  if (expires == null || account.hasRefreshToken) return head;
  return '$head · ${s.nacCardValidUntil(dates.formatShortDate(expires.toLocal()))}';
}

String _tierLabel(String tier) =>
    tier.isEmpty ? tier : tier[0].toUpperCase() + tier.substring(1);

/// One card for the Nous Portal account. [account] is the server's row
/// (null when the server has no Accounts route or no Nous card).
class NousAccountCard extends StatelessWidget {
  const NousAccountCard({
    required this.account,
    required this.onConnect,
    this.onManage,
    this.enabled = true,
    this.margin = EdgeInsets.zero,
    this.compact = false,
    super.key,
  });

  final OAuthAccount? account;

  /// Starts (or restarts) the sign-in. Null hides the button.
  final VoidCallback? onConnect;

  /// Opens the actions of a connected account (switch, disconnect).
  final VoidCallback? onManage;
  final bool enabled;
  final EdgeInsetsGeometry margin;

  /// Without the pitch line: inside a page that already explains it.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final expired = account?.expiredAt(DateTime.now()) == true;
    final signedIn = account?.signedIn == true && !expired;
    final supported = account != null;
    final status = nousAccountStatusLine(
      s,
      account,
      dates: MaterialLocalizations.of(context),
    );
    final name = account?.name.isNotEmpty == true
        ? account!.name
        : 'Nous Portal';
    return HermesListSection(
      key: const ValueKey('nac-card'),
      margin: margin,
      showDividers: false,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HermesSpace.x4,
            HermesSpace.x4,
            HermesSpace.x4,
            HermesSpace.x4,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ProviderLogo(
                    provider: OAuthAccount.nousId,
                    providerName: name,
                    size: 28,
                  ),
                  const SizedBox(width: HermesSpace.x3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          key: const ValueKey('nac-card-title'),
                          style: HermesType.style(
                            HermesType.title,
                            colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Icon(
                              signedIn
                                  ? Icons.check_circle_rounded
                                  : Icons.radio_button_unchecked,
                              size: 14,
                              color: signedIn
                                  ? colors.success
                                  : colors.textSecondary,
                            ),
                            const SizedBox(width: HermesSpace.x1),
                            Expanded(
                              child: Text(
                                status,
                                key: const ValueKey('nac-card-status'),
                                style: HermesType.style(
                                  HermesType.support,
                                  signedIn
                                      ? colors.textPrimary
                                      : colors.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (signedIn && onManage != null)
                    IconButton(
                      key: const ValueKey('nac-card-manage'),
                      tooltip: s.nacCardManage,
                      onPressed: enabled ? onManage : null,
                      icon: const Icon(Icons.more_horiz_rounded),
                      constraints: const BoxConstraints(
                        minWidth: HermesSpace.tap,
                        minHeight: HermesSpace.tap,
                      ),
                    ),
                ],
              ),
              if (!compact) ...[
                const SizedBox(height: HermesSpace.x3),
                Text(
                  supported ? s.nacCardPitch : s.nacCardUnsupportedBody,
                  key: const ValueKey('nac-card-pitch'),
                  style: HermesType.style(
                    HermesType.text,
                    colors.textSecondary,
                  ),
                ),
              ],
              if (supported && !signedIn && onConnect != null) ...[
                const SizedBox(height: HermesSpace.x4),
                HermesPrimaryButton(
                  key: const ValueKey('nac-card-connect'),
                  label: s.nacCardConnect,
                  icon: Icons.login_rounded,
                  onTap: enabled ? onConnect : null,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
