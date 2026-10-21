// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

/// What Hermes' public `GET /api/status` says about one Dashboard.
///
/// The endpoint is public by design (`PUBLIC_API_PATHS`): version and the
/// shape of the auth gate, never session content or secrets. It is the only
/// thing the "find my Hermes" search reads before the owner signs in.
class HermesServerStatus {
  const HermesServerStatus({
    required this.version,
    required this.installId,
    required this.authRequired,
    required this.authProviders,
    required this.authFlows,
  });

  final String version;

  /// Stable per install. Groups the same server seen through several routes
  /// (LAN and Tailscale). It is public and copyable, so it only tells two
  /// routes apart; it never proves who is answering.
  final String? installId;
  final bool authRequired;
  final List<String> authProviders;
  final List<String> authFlows;

  bool get passwordSignIn => authProviders.contains('basic');

  /// The Dashboard brokers an RFC 8252 sign-in (system browser + PKCE).
  bool get nativeSignIn => authFlows.contains('native_pkce');

  /// Null when [json] is not a Hermes status payload. Old servers that lack
  /// the newer fields still parse; their absent facts read as unknown.
  static HermesServerStatus? tryParse(Object? json) {
    if (json is! Map) return null;
    final version = json['version'];
    final auth = json['auth_required'];
    if (version is! String || version.trim().isEmpty || auth is! bool) {
      return null;
    }
    return HermesServerStatus(
      version: version.trim(),
      installId: _text(json['install_id']),
      authRequired: auth,
      authProviders: _strings(json['auth_providers']),
      authFlows: _strings(json['auth_flows']),
    );
  }
}

String? _text(Object? value) {
  if (value is! String) return null;
  final t = value.trim();
  return t.isEmpty ? null : t;
}

List<String> _strings(Object? value) => value is List
    ? value
          .whereType<String>()
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(growable: false)
    : const [];
