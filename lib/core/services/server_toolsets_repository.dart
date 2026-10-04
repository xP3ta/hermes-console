import 'dart:async';

import 'connection_manager.dart';
import 'server_config_repository.dart';

/// One toolset of `GET /api/tools/toolsets`.
final class ServerToolset {
  const ServerToolset({
    required this.name,
    required this.label,
    required this.description,
    required this.enabled,
    required this.available,
    required this.configured,
  });

  final String name;
  final String label;
  final String? description;
  final bool enabled;
  final bool available;
  final bool configured;

  static ServerToolset? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final label = raw['label'];
    final description = raw['description'];
    return ServerToolset(
      name: name,
      label: label is String && label.trim().isNotEmpty ? label : name,
      description: description is String && description.trim().isNotEmpty
          ? description
          : null,
      enabled: raw['enabled'] == true,
      available: raw['available'] != false,
      configured: raw['configured'] == true,
    );
  }
}

/// A credential a provider asks for. Only whether it is set is ever known.
final class ToolsetEnvVar {
  const ToolsetEnvVar({
    required this.key,
    required this.prompt,
    required this.isSet,
  });

  final String key;
  final String? prompt;
  final bool isSet;
}

final class ToolsetProvider {
  const ToolsetProvider({
    required this.name,
    required this.badge,
    required this.status,
    required this.isActive,
    required this.requiresNousAuth,
    required this.envVars,
  });

  final String name;
  final String? badge;
  final String? status;
  final bool isActive;
  final bool requiresNousAuth;
  final List<ToolsetEnvVar> envVars;
}

final class ToolsetConfig {
  const ToolsetConfig({
    required this.name,
    required this.hasCategory,
    required this.providers,
    required this.activeProvider,
  });

  final String name;
  final bool hasCategory;
  final List<ToolsetProvider> providers;
  final String? activeProvider;
}

final class ToolsetModel {
  const ToolsetModel({required this.id, required this.display});

  final String id;
  final String display;
}

final class ToolsetModels {
  const ToolsetModels({
    required this.hasModels,
    required this.models,
    required this.current,
  });

  final bool hasModels;
  final List<ToolsetModel> models;
  final String? current;
}

final class ToolsetEnableResult {
  const ToolsetEnableResult(
    this.outcome, {
    this.enabled,
    this.postSetupStarted,
  });

  final ServerConfigSaveOutcome outcome;

  /// What the re-read showed.
  final bool? enabled;

  /// The server started an installation for it; it is never tracked here.
  final String? postSetupStarted;
}

final class ToolsetChoiceResult {
  const ToolsetChoiceResult(this.outcome, {this.needsNousAuth = false});

  final ServerConfigSaveOutcome outcome;
  final bool needsNousAuth;
}

/// Reads and changes the server's toolsets. Every change is confirmed by
/// re-reading the list, config or models; credentials go out once and their
/// values are never read back or kept.
final class ServerToolsetsRepository {
  ServerToolsetsRepository(
    this._dashboard, {
    String? profile,
    this.writable = true,
  }) : _profile = (profile == null || profile.trim().isEmpty)
           ? null
           : profile.trim();

  final DashboardClient _dashboard;
  final String? _profile;
  final bool writable;

  String _url(String path) => _profile == null
      ? 'tools/toolsets$path'
      : 'tools/toolsets$path?profile=${Uri.encodeQueryComponent(_profile)}';

  void _requireWritable() {
    if (!writable) {
      throw const ServerConfigException(ServerConfigFailure.readOnly);
    }
  }

  static String _segment(String name) {
    if (name.isEmpty || name.contains('/') || name.contains('\\')) {
      throw const ServerConfigException(ServerConfigFailure.invalid);
    }
    return Uri.encodeComponent(name);
  }

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on ServerConfigException {
      rethrow;
    } catch (error) {
      throw _failure(error);
    }
  }

  static ServerConfigException _failure(Object error) {
    final status = error is DashboardHttpException ? error.statusCode : null;
    return ServerConfigException(switch (status) {
      401 || 403 => ServerConfigFailure.auth,
      404 || 405 => ServerConfigFailure.unsupported,
      400 || 422 => ServerConfigFailure.invalid,
      _ => ServerConfigFailure.unavailable,
    });
  }

  /// Null when [isCurrent] turned false while the read was in flight.
  Future<List<ServerToolset>?> list({bool Function()? isCurrent}) =>
      _guard(() async {
        final body = await _dashboard.apiGet(_url(''));
        if (isCurrent != null && !isCurrent()) return null;
        final rows = body['data'] ?? body['toolsets'];
        if (rows is! List) {
          throw const ServerConfigException(ServerConfigFailure.invalid);
        }
        return [for (final row in rows) ?ServerToolset.tryParse(row)];
      });

  Future<ToolsetEnableResult> setEnabled(
    String name,
    bool enabled, {
    bool Function()? isCurrent,
  }) => _guard(() async {
    _requireWritable();
    final segment = _segment(name);
    final answer = await _dashboard.apiPut(
      _url('/$segment'),
      body: {'enabled': enabled},
    );
    if (isCurrent != null && !isCurrent()) {
      return const ToolsetEnableResult(ServerConfigSaveOutcome.stale);
    }
    final started = answer['post_setup_started'];
    final rows = await list(isCurrent: isCurrent);
    if (rows == null) {
      return const ToolsetEnableResult(ServerConfigSaveOutcome.stale);
    }
    final seen = rows.where((t) => t.name == name).firstOrNull?.enabled;
    return ToolsetEnableResult(
      seen == enabled
          ? ServerConfigSaveOutcome.confirmed
          : ServerConfigSaveOutcome.mismatch,
      enabled: seen,
      postSetupStarted: started is String && started.isNotEmpty
          ? started
          : null,
    );
  });

  Future<ToolsetConfig?> config(String name, {bool Function()? isCurrent}) =>
      _guard(() async {
        final body = await _dashboard.apiGet(_url('/${_segment(name)}/config'));
        if (isCurrent != null && !isCurrent()) return null;
        final rawProviders = body['providers'];
        final providers = <ToolsetProvider>[];
        if (rawProviders is List) {
          for (final raw in rawProviders) {
            if (raw is! Map || raw['name'] is! String) continue;
            final env = raw['env_vars'];
            providers.add(
              ToolsetProvider(
                name: raw['name'] as String,
                badge: raw['badge'] is String ? raw['badge'] as String : null,
                status: raw['status'] is String
                    ? raw['status'] as String
                    : null,
                isActive: raw['is_active'] == true,
                requiresNousAuth: raw['requires_nous_auth'] == true,
                envVars: [
                  if (env is List)
                    for (final e in env)
                      if (e is Map && e['key'] is String)
                        ToolsetEnvVar(
                          key: e['key'] as String,
                          prompt: e['prompt'] is String
                              ? e['prompt'] as String
                              : null,
                          isSet: e['is_set'] == true,
                        ),
                ],
              ),
            );
          }
        }
        final active = body['active_provider'];
        return ToolsetConfig(
          name: name,
          hasCategory: body['has_category'] == true,
          providers: providers,
          activeProvider: active is String ? active : null,
        );
      });

  Future<ToolsetChoiceResult> setProvider(
    String name,
    String provider, {
    bool Function()? isCurrent,
  }) => _guard(() async {
    _requireWritable();
    final segment = _segment(name);
    final answer = await _dashboard.apiPut(
      _url('/$segment/provider'),
      body: {'provider': provider},
    );
    final needsAuth = answer['needs_nous_auth'] == true;
    if (isCurrent != null && !isCurrent()) {
      return const ToolsetChoiceResult(ServerConfigSaveOutcome.stale);
    }
    final fresh = await config(name, isCurrent: isCurrent);
    if (fresh == null) {
      return const ToolsetChoiceResult(ServerConfigSaveOutcome.stale);
    }
    return ToolsetChoiceResult(
      fresh.activeProvider == provider
          ? ServerConfigSaveOutcome.confirmed
          : ServerConfigSaveOutcome.mismatch,
      needsNousAuth: needsAuth,
    );
  });

  Future<ToolsetModels?> models(String name, {bool Function()? isCurrent}) =>
      _guard(() async {
        final body = await _dashboard.apiGet(_url('/${_segment(name)}/models'));
        if (isCurrent != null && !isCurrent()) return null;
        final rows = body['models'];
        final current = body['current'];
        return ToolsetModels(
          hasModels: body['has_models'] == true,
          models: [
            if (rows is List)
              for (final row in rows)
                if (row is Map && row['id'] is String)
                  ToolsetModel(
                    id: row['id'] as String,
                    display: row['display'] is String
                        ? row['display'] as String
                        : row['id'] as String,
                  ),
          ],
          current: current is String ? current : null,
        );
      });

  Future<ToolsetChoiceResult> setModel(
    String name,
    String model, {
    bool Function()? isCurrent,
  }) => _guard(() async {
    _requireWritable();
    final segment = _segment(name);
    await _dashboard.apiPut(_url('/$segment/model'), body: {'model': model});
    if (isCurrent != null && !isCurrent()) {
      return const ToolsetChoiceResult(ServerConfigSaveOutcome.stale);
    }
    final fresh = await models(name, isCurrent: isCurrent);
    if (fresh == null) {
      return const ToolsetChoiceResult(ServerConfigSaveOutcome.stale);
    }
    return ToolsetChoiceResult(
      fresh.current == model
          ? ServerConfigSaveOutcome.confirmed
          : ServerConfigSaveOutcome.mismatch,
    );
  });

  /// Sends credential values once. Only which keys are now set comes back;
  /// the values are neither read nor kept.
  Future<Map<String, bool>> saveEnv(String name, Map<String, String> env) =>
      _guard(() async {
        _requireWritable();
        final segment = _segment(name);
        final answer = await _dashboard.apiPut(
          _url('/$segment/env'),
          body: {'env': env},
        );
        final isSet = answer['is_set'];
        return {
          if (isSet is Map)
            for (final entry in isSet.entries)
              if (entry.key is String) entry.key as String: entry.value == true,
        };
      });
}
