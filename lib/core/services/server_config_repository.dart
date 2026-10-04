import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../settings/server_config_pages.dart';
import 'connection_manager.dart';

/// Why a read or a write of the server config did not complete. Carries no
/// body, token or value: only what the screen needs to word the failure.
enum ServerConfigFailureKind {
  readOnly,
  closed,
  invalidProfile,
  unsupported,
  authentication,
  permissionDenied,
  rejected,
  remote,
  transport,
  invalidResponse,

  /// The write was answered `ok` but the re-read shows another value.
  notSaved,

  /// The write was answered `ok` but the re-read could not be done.
  unconfirmed,
}

final class ServerConfigException implements Exception {
  final ServerConfigFailureKind kind;
  final int? statusCode;

  /// The value the server holds, for [ServerConfigFailureKind.notSaved].
  final Object? serverValue;

  const ServerConfigException(this.kind, {this.statusCode, this.serverValue});

  @override
  String toString() => 'ServerConfigException(${kind.name})';
}

/// The config tree and the schema read together, for one profile.
final class ServerConfigSnapshot {
  final String? profile;
  final Map<String, dynamic> config;
  final Map<String, dynamic> schema;

  const ServerConfigSnapshot({
    required this.profile,
    required this.config,
    required this.schema,
  });

  /// The value at a dotted [path], or null when any step is missing.
  Object? valueAt(String path) => serverConfigValueAt(config, path);
}

/// The value at a dotted [path] of a nested config tree.
Object? serverConfigValueAt(Map<String, dynamic> config, String path) {
  Object? node = config;
  for (final step in path.split('.')) {
    if (node is! Map) return null;
    node = node[step];
  }
  return node;
}

/// Reads and writes single fields of the server config through the
/// Dashboard's deep-merge, and confirms every write by reading the value
/// back. Never sends the record it read: only the branch of the edited path.
///
/// Borrows [dashboard]; the owner closes it.
final class ServerConfigRepository {
  final DashboardClient _dashboard;
  final bool _writable;
  final String? _profile;

  bool _closed = false;
  final Map<String, Future<void>> _tails = {};

  factory ServerConfigRepository(
    DashboardClient dashboard, {
    String? profile,
    bool writable = true,
  }) =>
      ServerConfigRepository._(dashboard, _normalizeProfile(profile), writable);

  ServerConfigRepository._(this._dashboard, this._profile, this._writable);

  String? get profile => _profile;
  bool get isWritable => _writable;

  /// Stops new work; a write already sent still finishes its re-read.
  void close() => _closed = true;

  /// Config and schema, one read each.
  Future<ServerConfigSnapshot> load() async {
    _requireOpen();
    try {
      final config = await _dashboard.getServerConfig(profile: _profile);
      final schema = await _dashboard.getServerConfigSchema(profile: _profile);
      if (schema['fields'] is! Map) {
        throw const ServerConfigException(
          ServerConfigFailureKind.invalidResponse,
        );
      }
      return ServerConfigSnapshot(
        profile: _profile,
        config: config,
        schema: schema,
      );
    } catch (error) {
      throw serverConfigFailureOf(error);
    }
  }

  /// Writes [value] at [path], re-reads the config and returns the value the
  /// server now holds. Throws [ServerConfigFailureKind.notSaved] (with the
  /// server's value) when the re-read differs, and
  /// [ServerConfigFailureKind.unconfirmed] when it could not be done.
  ///
  /// A second save of the same field waits for the first; other fields do
  /// not wait for each other.
  Future<Object?> save(String path, Object? value) {
    if (_closed) {
      return Future.error(
        const ServerConfigException(ServerConfigFailureKind.closed),
      );
    }
    if (!_writable) {
      return Future.error(
        const ServerConfigException(ServerConfigFailureKind.readOnly),
      );
    }
    // Only fields a page owns: never the model, a secret or anything else.
    if (serverConfigPagesOf(path).isEmpty) {
      return Future.error(
        const ServerConfigException(ServerConfigFailureKind.rejected),
      );
    }
    final previous = _tails[path];
    final done = Completer<Object?>();
    late final Future<void> mine;
    mine = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      try {
        done.complete(await _saveNow(path, value));
      } catch (error, stack) {
        done.completeError(serverConfigFailureOf(error), stack);
      } finally {
        if (identical(_tails[path], mine)) _tails.remove(path);
      }
    }();
    _tails[path] = mine;
    return done.future;
  }

  Future<Object?> _saveNow(String path, Object? value) async {
    final response = await _dashboard.putServerConfigPatch(
      _branch(path, value),
      profile: _profile,
    );
    if (response['ok'] != true) {
      throw const ServerConfigException(ServerConfigFailureKind.rejected);
    }
    final Map<String, dynamic> reread;
    try {
      reread = await _dashboard.getServerConfig(profile: _profile);
    } catch (_) {
      throw const ServerConfigException(ServerConfigFailureKind.unconfirmed);
    }
    final held = serverConfigValueAt(reread, path);
    if (!_same(held, value)) {
      throw ServerConfigException(
        ServerConfigFailureKind.notSaved,
        serverValue: held,
      );
    }
    return held;
  }

  void _requireOpen() {
    if (_closed) {
      throw const ServerConfigException(ServerConfigFailureKind.closed);
    }
  }
}

/// `a.b.c` and 1 → `{a: {b: {c: 1}}}`.
Map<String, dynamic> _branch(String path, Object? value) {
  final steps = path.split('.');
  Object? tree = value;
  for (final step in steps.reversed) {
    tree = <String, dynamic>{step: tree};
  }
  return tree as Map<String, dynamic>;
}

bool _same(Object? a, Object? b) {
  if (a is num && b is num) return a == b;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_same(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_same(a[key], b[key])) return false;
    }
    return true;
  }
  return a == b;
}

String? _normalizeProfile(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty || value == 'default') return null;
  if (!RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(value)) {
    throw const ServerConfigException(ServerConfigFailureKind.invalidProfile);
  }
  return value;
}

/// Any failure of a Dashboard call as the sanitized exception of the screen.
ServerConfigException serverConfigFailureOf(Object error) {
  if (error is ServerConfigException) return error;
  if (error is DashboardAuthException) {
    return ServerConfigException(
      ServerConfigFailureKind.authentication,
      statusCode: error.statusCode,
    );
  }
  if (error is DashboardHttpException) {
    final kind = switch (error.statusCode) {
      401 => ServerConfigFailureKind.authentication,
      403 => ServerConfigFailureKind.permissionDenied,
      404 || 405 => ServerConfigFailureKind.unsupported,
      400 || 409 || 422 => ServerConfigFailureKind.rejected,
      _ => ServerConfigFailureKind.remote,
    };
    return ServerConfigException(kind, statusCode: error.statusCode);
  }
  if (error is TimeoutException ||
      error is SocketException ||
      error is http.ClientException) {
    return const ServerConfigException(ServerConfigFailureKind.transport);
  }
  if (error is FormatException || error is TypeError) {
    return const ServerConfigException(ServerConfigFailureKind.invalidResponse);
  }
  return const ServerConfigException(ServerConfigFailureKind.remote);
}
