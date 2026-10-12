// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors

/// One row of `GET /api/providers/oauth`: a provider that signs in with an
/// account instead of an API key, with the state the server reports for it.
/// The source of Desktop's Settings → Providers → Accounts.
class OAuthAccount {
  const OAuthAccount({
    required this.id,
    required this.name,
    required this.flow,
    required this.connected,
    required this.disconnectable,
    this.freeTier = false,
  });

  /// The id every account route takes (`start`, `poll`, `DELETE`).
  final String id;
  final String name;

  /// `device_code`, `pkce`, `loopback`, `external`…
  final String flow;

  /// `status.logged_in`, as the server sees it for the requested profile.
  final bool connected;

  /// Whether Hermes can clear the credential itself. An account owned by the
  /// provider's own CLI is removed there (Desktop offers no button either).
  final bool disconnectable;

  /// A token without an account: never shown as connected (Desktop).
  final bool freeTier;

  /// Signed in with a real account.
  bool get signedIn => connected && !freeTier;

  /// The sign-in can be completed from this app. An `external` flow needs the
  /// provider's own CLI on the server.
  bool get canSignInHere => const {
    'device_code',
    'loopback',
    'minimax',
    'pkce',
  }.contains(flow.toLowerCase());

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
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'flow': flow,
    'disconnectable': disconnectable,
    'status': {'logged_in': connected, 'free_tier': freeTier},
  };
}
