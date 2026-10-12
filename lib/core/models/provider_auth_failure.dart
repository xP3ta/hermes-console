/// Provider credential failures of a turn or a compaction.
///
/// Port of Hermes Desktop `apps/desktop/src/lib/error-surface.ts`
/// (`parseErrorSurface`, `isOAuthReauthSurface`, `isApiKeyRejectedSurface`)
/// for the structured `error_surface` the gateway attaches to a failed
/// `message.complete` and to a resumed `inflight` turn
/// (agent/error_surface.py). Older backends, the standalone `error` event and
/// compaction warnings carry only text, so a narrow text fallback recognises
/// the provider's own 401 wording (`authentication_error`, "token has been
/// revoked", "invalid x-api-key").
library;

/// How the failing provider is credentialed, so the card offers the right fix.
enum ProviderAuthKind {
  /// Account sign-in (OAuth/subscription grant): sign in again.
  oauth('oauth'),

  /// Saved API key: replace the key.
  apiKey('api_key');

  final String wire;
  const ProviderAuthKind(this.wire);

  static ProviderAuthKind? fromWire(Object? value) => switch (value) {
    'oauth' => ProviderAuthKind.oauth,
    'api_key' => ProviderAuthKind.apiKey,
    _ => null,
  };
}

/// Where the rejection surfaced.
enum ProviderAuthOrigin {
  turn('turn'),
  compaction('compaction');

  final String wire;
  const ProviderAuthOrigin(this.wire);
}

/// Private row key that carries the classified failure on an
/// `assistant_error` message.
const providerAuthFailureKey = '_providerAuthFailure';

/// Layers a structured error surface may name (error-surface.ts).
const _errorSurfaceLayers = {
  'provider',
  'endpoint',
  'streaming',
  'auth',
  'billing',
  'gateway',
  'runtime',
  'disk',
};

final class ProviderAuthFailure {
  /// Provider slug as the gateway names it (`anthropic`, `openai-codex`).
  /// Empty when neither the surface nor the session names it.
  final String provider;

  /// Display name from the gateway (`provider_label`), else the slug.
  final String label;
  final ProviderAuthKind kind;
  final ProviderAuthOrigin origin;

  const ProviderAuthFailure({
    required this.provider,
    required this.label,
    required this.kind,
    this.origin = ProviderAuthOrigin.turn,
  });

  bool get isOAuth => kind == ProviderAuthKind.oauth;

  ProviderAuthFailure withOrigin(ProviderAuthOrigin value) =>
      ProviderAuthFailure(
        provider: provider,
        label: label,
        kind: kind,
        origin: value,
      );

  Map<String, String> toJson() => {
    'provider': provider,
    'label': label,
    'kind': kind.wire,
    'origin': origin.wire,
  };

  static ProviderAuthFailure? fromJson(Object? value) {
    if (value is! Map) return null;
    final kind = ProviderAuthKind.fromWire(value['kind']);
    if (kind == null) return null;
    final provider = _clean(value['provider']);
    return ProviderAuthFailure(
      provider: provider,
      label: _clean(value['label']).isEmpty ? provider : _clean(value['label']),
      kind: kind,
      origin: value['origin'] == ProviderAuthOrigin.compaction.wire
          ? ProviderAuthOrigin.compaction
          : ProviderAuthOrigin.turn,
    );
  }

  /// Classifies a failed turn.
  ///
  /// A valid [errorSurface] is authoritative, as in Desktop: only its `auth`
  /// layer is a credential failure. Its `auth_kind` decides the fix, except
  /// that a provider message naming an OAuth token wins over `api_key`
  /// (Hermes reports Anthropic as `api_key` even when the saved credential
  /// is a revoked Claude OAuth token). Without a surface the [errorText] is
  /// sniffed. [sessionProvider] names the provider when the surface does not.
  static ProviderAuthFailure? classify({
    Object? errorSurface,
    Object? errorText,
    String? sessionProvider,
    ProviderAuthOrigin origin = ProviderAuthOrigin.turn,
  }) {
    final text = errorText is String ? errorText : '';
    final surface = errorSurface is Map ? errorSurface : null;
    final layer = surface?['layer'];
    if (surface != null &&
        layer is String &&
        _errorSurfaceLayers.contains(layer)) {
      if (layer != 'auth') return null;
      final provider = _clean(surface['provider']).isNotEmpty
          ? _clean(surface['provider'])
          : _clean(sessionProvider);
      final declared = ProviderAuthKind.fromWire(surface['auth_kind']);
      final kind = _mentionsOAuth(text)
          ? ProviderAuthKind.oauth
          : declared ?? ProviderAuthKind.apiKey;
      final label = _clean(surface['provider_label']);
      return ProviderAuthFailure(
        provider: provider,
        label: label.isNotEmpty ? label : provider,
        kind: kind,
        origin: origin,
      );
    }
    if (!looksLikeProviderAuthRejection(text)) return null;
    final provider = _clean(sessionProvider);
    return ProviderAuthFailure(
      provider: provider,
      label: provider,
      kind: _mentionsOAuth(text)
          ? ProviderAuthKind.oauth
          : ProviderAuthKind.apiKey,
      origin: origin,
    );
  }
}

/// The provider's own wording for a rejected credential. Deliberately narrow:
/// a bare "401" or "unauthorized" can be the Hermes Dashboard itself.
bool looksLikeProviderAuthRejection(String text) {
  final lower = text.toLowerCase();
  if (lower.isEmpty) return false;
  return lower.contains('authentication_error') ||
      lower.contains('invalid x-api-key') ||
      lower.contains('incorrect api key') ||
      lower.contains('invalid api key') ||
      RegExp(
        r'(access|oauth|refresh|bearer)[ _-]?token (has been |was |is )?(revoked|expired)',
      ).hasMatch(lower) ||
      RegExp(r'\btoken (has been |was )?revoked\b').hasMatch(lower);
}

bool _mentionsOAuth(String text) {
  final lower = text.toLowerCase();
  return lower.contains('oauth') ||
      RegExp(r'(access|refresh) token').hasMatch(lower);
}

String _clean(Object? value) => value is String ? value.trim() : '';
