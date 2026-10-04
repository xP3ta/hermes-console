import 'dart:async';

import '../models/server_toolset.dart';
import 'connection_manager.dart';
import 'server_config_repository.dart';

/// What a successful enable/disable returns: the list read back, and whether
/// the server started an installation (Console only says so, never follows it).
final class ToolsetEnableResult {
  final List<ServerToolset> toolsets;
  final bool postSetupStarted;

  const ToolsetEnableResult(this.toolsets, {required this.postSetupStarted});
}

final _toolsetName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$');
final _envKey = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$');

/// Reads and changes the server's toolsets through the Dashboard, and
/// confirms every write by reading the same thing back.
///
/// Borrows [dashboard]; the owner closes it. Credential values go out in one
/// request and are never read back, stored or logged.
final class ServerToolsetsRepository {
  final DashboardClient _dashboard;
  final bool _writable;
  final String? _profile;

  ServerToolsetsRepository._(this._dashboard, this._profile, this._writable);

  factory ServerToolsetsRepository(
    DashboardClient dashboard, {
    String? profile,
    bool writable = true,
  }) {
    // Same profile rules as the config repository.
    final normalized = ServerConfigRepository(dashboard, profile: profile);
    return ServerToolsetsRepository._(dashboard, normalized.profile, writable);
  }

  String? get profile => _profile;
  bool get isWritable => _writable;

  String get _query =>
      _profile == null ? '' : '?profile=${Uri.encodeQueryComponent(_profile)}';

  String _path(String name, [String tail = '']) {
    if (!_toolsetName.hasMatch(name)) {
      throw const ServerConfigException(ServerConfigFailureKind.rejected);
    }
    return 'tools/toolsets/$name$tail$_query';
  }

  void _requireWritable() {
    if (!_writable) {
      throw const ServerConfigException(ServerConfigFailureKind.readOnly);
    }
  }

  Future<T> _run<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (error) {
      throw serverConfigFailureOf(error);
    }
  }

  Future<List<ServerToolset>> list() => _run(() async {
    final rows = await _dashboard.apiGetList('tools/toolsets$_query');
    return [for (final row in rows) ?ServerToolset.tryParse(row)];
  });

  Future<ToolsetEnableResult> setEnabled(String name, bool enabled) => _run(
    () async {
      _requireWritable();
      final response = await _dashboard.apiPut(
        _path(name),
        body: {'enabled': enabled},
      );
      if (response['ok'] != true) {
        throw const ServerConfigException(ServerConfigFailureKind.rejected);
      }
      final started = response['post_setup_started'] != null;
      final List<ServerToolset> rows;
      try {
        rows = await list();
      } catch (_) {
        throw const ServerConfigException(ServerConfigFailureKind.unconfirmed);
      }
      final held = rows.where((row) => row.name == name).firstOrNull;
      if (held == null || held.enabled != enabled) {
        throw const ServerConfigException(ServerConfigFailureKind.notSaved);
      }
      return ToolsetEnableResult(rows, postSetupStarted: started);
    },
  );

  Future<ToolsetConfig> config(String name) => _run(() async {
    final raw = await _dashboard.apiGet(_path(name, '/config'));
    return ToolsetConfig.parse(name, raw);
  });

  Future<ToolsetModels> models(String name) => _run(() async {
    final raw = await _dashboard.apiGet(_path(name, '/models'));
    return ToolsetModels.parse(name, raw);
  });

  /// Chooses [provider] and returns the config read back.
  Future<ToolsetConfig> setProvider(String name, String provider) =>
      _run(() async {
        _requireWritable();
        await _put(_path(name, '/provider'), {'provider': provider});
        final config = await _reread(() => this.config(name));
        if (config.activeProvider != provider) {
          throw const ServerConfigException(ServerConfigFailureKind.notSaved);
        }
        return config;
      });

  /// Chooses [model] and returns the models read back.
  Future<ToolsetModels> setModel(String name, String model) => _run(() async {
    _requireWritable();
    await _put(_path(name, '/model'), {'model': model});
    final models = await _reread(() => this.models(name));
    if (models.current != model) {
      throw const ServerConfigException(ServerConfigFailureKind.notSaved);
    }
    return models;
  });

  /// Sends new credentials in one request and returns the config read back,
  /// which only says which keys are set.
  Future<ToolsetConfig> saveCredentials(
    String name,
    Map<String, String> values,
  ) => _run(() async {
    _requireWritable();
    final clean = {
      for (final entry in values.entries)
        if (_envKey.hasMatch(entry.key) && entry.value.trim().isNotEmpty)
          entry.key: entry.value,
    };
    if (clean.isEmpty) {
      throw const ServerConfigException(ServerConfigFailureKind.rejected);
    }
    await _put(_path(name, '/env'), {'env': clean});
    final config = await _reread(() => this.config(name));
    if (!clean.keys.every(config.isKeySet)) {
      throw const ServerConfigException(ServerConfigFailureKind.notSaved);
    }
    return config;
  });

  Future<void> _put(String endpoint, Map<String, dynamic> body) async {
    final response = await _dashboard.apiPut(endpoint, body: body);
    if (response['ok'] != true) {
      throw const ServerConfigException(ServerConfigFailureKind.rejected);
    }
  }

  Future<T> _reread<T>(Future<T> Function() read) async {
    try {
      return await read();
    } catch (_) {
      throw const ServerConfigException(ServerConfigFailureKind.unconfirmed);
    }
  }
}
