// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors

/// One row of `GET /api/providers/oauth`: a provider that signs in with an
/// account instead of an API key, with the state the server reports for it.
/// The source of the Accounts block of the Models screen.
class OAuthAccount {
  const OAuthAccount({
    required this.id,
    required this.name,
    required this.flow,
    required this.connected,
    required this.disconnectable,
    this.freeTier = false,
    this.sourceLabel = '',
    this.accountTier = '',
    this.docsUrl = '',
    this.expiresAt,
    this.hasRefreshToken = false,
  });

  /// The id of the Nous Portal account card.
  static const nousId = 'nous';

  /// The id every account route takes (`start`, `poll`, `DELETE`).
  final String id;
  final String name;

  /// `device_code`, `pkce`, `loopback`, `external`…
  final String flow;

  /// `status.logged_in`, as the server sees it for the requested profile.
  final bool connected;

  /// Whether Hermes can clear the credential itself. An account owned by the
  /// provider's own CLI is removed there.
  final bool disconnectable;

  /// A token without an account: never shown as connected.
  final bool freeTier;

  /// `status.source_label`: where the credential comes from (for Nous Portal
  /// the portal address, for others a store path or a human label).
  final String sourceLabel;

  /// `status.account_tier` of a Nous Portal account (`pro`, …), empty when
  /// the server does not say.
  final String accountTier;

  /// `docs_url`: the provider's own site, as the server names it.
  final String docsUrl;

  /// `status.expires_at`: when the access token on the server runs out.
  /// Null when unknown.
  final DateTime? expiresAt;

  /// `status.has_refresh_token`: the server renews the access token by
  /// itself, so [expiresAt] is not when the account stops working.
  final bool hasRefreshToken;

  /// Signed in with a real account.
  bool get signedIn => connected && !freeTier;

  /// Whether this is the Nous Portal card.
  bool get isNous => id == nousId;

  /// The sign-in can be completed from this app. An `external` flow needs the
  /// provider's own CLI on the server.
  bool get canSignInHere => const {
    'device_code',
    'loopback',
    'minimax',
    'pkce',
  }.contains(flow.toLowerCase());

  /// Signed in, but with a credential that ran out and that the server
  /// cannot renew (no refresh token): it needs a new sign-in.
  bool expiredAt(DateTime now) {
    final expires = expiresAt;
    return signedIn &&
        !hasRefreshToken &&
        expires != null &&
        !expires.isAfter(now);
  }

  static List<OAuthAccount> listFromJson(Object? rows) => [
    if (rows is List)
      for (final row in rows)
        if (row is Map && (row['id'] ?? '').toString().trim().isNotEmpty)
          OAuthAccount.fromJson(row.cast<String, dynamic>()),
  ];

  factory OAuthAccount.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    final flow = (json['flow'] ?? '').toString();
    final id = (json['id'] ?? '').toString().trim();
    final name = (json['name'] ?? '').toString().trim();
    String text(Object? value) => value is String ? value.trim() : '';
    return OAuthAccount(
      id: id,
      name: name.isEmpty ? id : name,
      flow: flow,
      connected: status is Map && status['logged_in'] == true,
      // Older servers send no verdict: only an external flow is not theirs.
      disconnectable: json['disconnectable'] is bool
          ? json['disconnectable'] as bool
          : flow != 'external',
      freeTier: status is Map && status['free_tier'] == true,
      sourceLabel: status is Map ? text(status['source_label']) : '',
      accountTier: status is Map ? text(status['account_tier']) : '',
      docsUrl: text(json['docs_url']),
      expiresAt: status is Map ? _date(status['expires_at']) : null,
      hasRefreshToken: status is Map && status['has_refresh_token'] == true,
    );
  }

  static DateTime? _date(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return DateTime.tryParse(value.trim())?.toUtc();
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'flow': flow,
    'disconnectable': disconnectable,
    if (docsUrl.isNotEmpty) 'docs_url': docsUrl,
    'status': {
      'logged_in': connected,
      'free_tier': freeTier,
      if (sourceLabel.isNotEmpty) 'source_label': sourceLabel,
      if (accountTier.isNotEmpty) 'account_tier': accountTier,
      if (expiresAt != null) 'expires_at': expiresAt!.toIso8601String(),
      if (hasRefreshToken) 'has_refresh_token': true,
    },
  };
}
