/// Wire models of `/api/tools/toolsets*`: parsed defensively (optional fields
/// arrive as JSON `null`, a missing or wrong-typed part is absent). Credential
/// values never appear here: the server only says whether a key `is_set`.
library;

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

bool _flag(Object? value) => value == true;

List<String> _strings(Object? value) => value is List
    ? [
        for (final item in value)
          if (item is String && item.trim().isNotEmpty) item.trim(),
      ]
    : const [];

/// One row of `GET /api/tools/toolsets`.
final class ServerToolset {
  final String name;
  final String label;
  final String? description;
  final String? platformLabel;
  final bool enabled;
  final bool available;
  final bool configured;
  final List<String> tools;

  const ServerToolset({
    required this.name,
    required this.label,
    this.description,
    this.platformLabel,
    this.enabled = false,
    this.available = true,
    this.configured = true,
    this.tools = const [],
  });

  static ServerToolset? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final name = _text(raw['name']);
    if (name == null) return null;
    return ServerToolset(
      name: name,
      label: _text(raw['label']) ?? name,
      description: _text(raw['description']),
      platformLabel: _text(raw['platform_label']),
      enabled: _flag(raw['enabled']),
      available: raw['available'] != false,
      configured: raw['configured'] != false,
      tools: _strings(raw['tools']),
    );
  }
}

/// A credential a provider needs: its key and whether the server has it.
final class ToolsetEnvVar {
  final String key;
  final String? prompt;
  final String? url;
  final bool isSet;

  const ToolsetEnvVar({
    required this.key,
    this.prompt,
    this.url,
    this.isSet = false,
  });

  static ToolsetEnvVar? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final key = _text(raw['key']);
    if (key == null) return null;
    return ToolsetEnvVar(
      key: key,
      prompt: _text(raw['prompt']),
      url: _text(raw['url']),
      isSet: _flag(raw['is_set']),
    );
  }
}

final class ToolsetProvider {
  final String name;
  final String? badge;
  final String? tag;
  final String? status;
  final bool isActive;
  final bool requiresNousAuth;
  final List<ToolsetEnvVar> envVars;

  const ToolsetProvider({
    required this.name,
    this.badge,
    this.tag,
    this.status,
    this.isActive = false,
    this.requiresNousAuth = false,
    this.envVars = const [],
  });

  static ToolsetProvider? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final name = _text(raw['name']);
    if (name == null) return null;
    final vars = raw['env_vars'];
    return ToolsetProvider(
      name: name,
      badge: _text(raw['badge']),
      tag: _text(raw['tag']),
      status: _text(raw['status']),
      isActive: _flag(raw['is_active']),
      requiresNousAuth: _flag(raw['requires_nous_auth']),
      envVars: vars is List
          ? [for (final item in vars) ?ToolsetEnvVar.tryParse(item)]
          : const [],
    );
  }
}

/// `GET /api/tools/toolsets/{name}/config`.
final class ToolsetConfig {
  final String name;
  final bool hasCategory;
  final List<ToolsetProvider> providers;
  final String? activeProvider;

  const ToolsetConfig({
    required this.name,
    required this.hasCategory,
    this.providers = const [],
    this.activeProvider,
  });

  static ToolsetConfig parse(String name, Map<String, dynamic> raw) {
    final providers = raw['providers'];
    return ToolsetConfig(
      name: name,
      hasCategory: _flag(raw['has_category']),
      providers: providers is List
          ? [for (final item in providers) ?ToolsetProvider.tryParse(item)]
          : const [],
      activeProvider: _text(raw['active_provider']),
    );
  }

  /// Whether a provider lists [key] as set on the server.
  bool isKeySet(String key) => providers.any(
    (provider) => provider.envVars.any((v) => v.key == key && v.isSet),
  );

  @override
  String toString() => 'ToolsetConfig($name, $activeProvider)';
}

final class ToolsetModel {
  final String id;
  final String display;

  const ToolsetModel({required this.id, required this.display});

  static ToolsetModel? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = _text(raw['id']);
    if (id == null) return null;
    return ToolsetModel(id: id, display: _text(raw['display']) ?? id);
  }
}

/// `GET /api/tools/toolsets/{name}/models`.
final class ToolsetModels {
  final String name;
  final bool hasModels;
  final String? current;
  final List<ToolsetModel> models;

  const ToolsetModels({
    required this.name,
    required this.hasModels,
    this.current,
    this.models = const [],
  });

  static ToolsetModels parse(String name, Map<String, dynamic> raw) {
    final models = raw['models'];
    return ToolsetModels(
      name: name,
      hasModels: _flag(raw['has_models']),
      current: _text(raw['current']),
      models: models is List
          ? [for (final item in models) ?ToolsetModel.tryParse(item)]
          : const [],
    );
  }
}
