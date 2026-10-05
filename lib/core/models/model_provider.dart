/// Proveedor de modelos retornado por GET /api/model/options (Dashboard).
class ModelProvider {
  final String slug;
  final String name;
  final bool isCurrent;
  final bool authenticated;
  final bool freeTier;
  final String authType;
  final String oauthProviderId;
  final String keyEnv;
  final String warning;
  final List<String> models;

  /// URL base del proveedor (solo disponible en custom_providers / proveedores
  /// externos configurados vía ExternalProviderScreen). Vacío para proveedores
  /// nativos (OpenAI, Nous, etc.).
  final String baseUrl;

  /// Lower-cased identities Hermes accepts for a user-defined endpoint
  /// (`aliases` in `/api/model/options`): `/api/model/info` names it
  /// `custom:<key>` while [slug] is the bare key. Empty when not published.
  final Set<String> aliases;

  const ModelProvider({
    required this.slug,
    required this.name,
    required this.isCurrent,
    required this.authenticated,
    this.freeTier = false,
    required this.authType,
    required this.oauthProviderId,
    required this.keyEnv,
    required this.warning,
    required this.models,
    this.baseUrl = '',
    this.aliases = const {},
  });

  ModelProvider copyWith({List<String>? models}) => ModelProvider(
    slug: slug,
    name: name,
    isCurrent: isCurrent,
    authenticated: authenticated,
    freeTier: freeTier,
    authType: authType,
    oauthProviderId: oauthProviderId,
    keyEnv: keyEnv,
    warning: warning,
    models: models ?? this.models,
    baseUrl: baseUrl,
    aliases: aliases,
  );

  factory ModelProvider.fromJson(Map<String, dynamic> json) => ModelProvider(
    slug: _string(json['slug'] ?? json['id'] ?? json['provider']),
    name: _string(json['name'] ?? json['label'] ?? json['title']),
    isCurrent: _bool(json['is_current'] ?? json['current'] ?? json['active']),
    authenticated:
        _bool(
          json['authenticated'] ?? json['configured'] ?? json['available'],
        ) &&
        !_bool(json['free_tier']),
    freeTier: _bool(json['free_tier']),
    authType: _string(json['auth_type'] ?? json['auth'] ?? json['type']),
    oauthProviderId:
        (json['oauth_provider'] ??
                json['oauth_provider_id'] ??
                json['auth_provider'] ??
                json['auth_provider_id'] ??
                '')
            .toString(),
    keyEnv: _string(json['key_env'] ?? json['env_key'] ?? json['api_key_env']),
    warning: _string(json['warning'] ?? json['message'] ?? json['reason']),
    models: _parseModels(
      json['models'] ??
          json['available_models'] ??
          json['model_ids'] ??
          json['catalog'],
    ),
    baseUrl: _string(json['base_url'] ?? json['url'] ?? json['endpoint'] ?? ''),
    aliases: _parseAliases(json['aliases']),
  );

  static Set<String> _parseAliases(Object? value) {
    if (value is! List) return const {};
    return {
      for (final raw in value.take(32))
        if (raw is String && raw.trim().isNotEmpty) raw.trim().toLowerCase(),
    };
  }

  static List<String> _parseModels(Object? value) {
    final seen = <String>{};
    void add(String id) {
      final normalized = id.trim();
      if (normalized.isNotEmpty) seen.add(normalized);
    }

    if (value is List) {
      for (final item in value) {
        if (item is String) {
          add(item);
        } else if (item is Map) {
          add(
            _string(
              item['id'] ??
                  item['model'] ??
                  item['name'] ??
                  item['slug'] ??
                  item['value'],
            ),
          );
        }
      }
      return seen.toList();
    }
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key is String) add(entry.key as String);
        final item = entry.value;
        if (item is Map) {
          add(
            _string(
              item['id'] ??
                  item['model'] ??
                  item['name'] ??
                  item['slug'] ??
                  item['value'],
            ),
          );
        } else if (item is String) {
          add(item);
        }
      }
      return seen.toList();
    }
    return [];
  }

  static String _string(Object? value) {
    if (value == null) return '';
    if (value is String) return value.trim();
    return value.toString().trim();
  }

  static bool _bool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      return const {
        '1',
        'true',
        'yes',
        'y',
        'on',
        'configured',
        'available',
      }.contains(value.trim().toLowerCase());
    }
    return false;
  }
}

/// Projects the already-loaded Hermes catalog for a model picker search.
///
/// This mirrors Hermes Desktop: a case-insensitive substring match across the
/// model id, provider name and provider slug, while preserving the backend's
/// curated provider/model order and performing no I/O.
List<ModelProvider> filterModelProviders(
  List<ModelProvider> providers,
  String query,
) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return providers;

  final filtered = <ModelProvider>[];
  for (final provider in providers) {
    final providerMatches =
        provider.name.toLowerCase().contains(normalized) ||
        provider.slug.toLowerCase().contains(normalized);
    final models = provider.models
        .where(
          (model) =>
              providerMatches || model.toLowerCase().contains(normalized),
        )
        .toList();
    if (models.isNotEmpty) {
      filtered.add(provider.copyWith(models: models));
    }
  }
  return filtered;
}
