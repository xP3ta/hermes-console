import 'dart:async';

import '../settings/server_config_pages.dart';
import 'connection_manager.dart';

/// Why a read or write of the server config did not happen.
enum ServerConfigFailure { readOnly, auth, unsupported, unavailable, invalid }

/// A sanitized failure: no body, URL or value of the server survives.
final class ServerConfigException implements Exception {
  const ServerConfigException(this.kind);

  final ServerConfigFailure kind;

  @override
  String toString() => 'ServerConfigException($kind)';
}

/// One editable field read from the schema and the config tree.
final class ServerConfigField {
  const ServerConfigField({
    required this.path,
    required this.type,
    required this.description,
    required this.options,
    required this.value,
    required this.page,
  });

  final String path;

  /// `boolean`, `number`, `string`, `list` or `select`.
  final String type;
  final String description;
  final List<String> options;
  final Object? value;
  final ServerConfigPage page;
}

/// The editable fields of the server, in schema order.
final class ServerConfigSnapshot {
  ServerConfigSnapshot(List<ServerConfigField> fields)
    : fields = List.unmodifiable(fields) {
    for (final field in this.fields) {
      (byPage[field.page] ??= []).add(field);
    }
  }

  final List<ServerConfigField> fields;
  final Map<ServerConfigPage, List<ServerConfigField>> byPage = {};

  ServerConfigField? field(String path) {
    for (final field in fields) {
      if (field.path == path) return field;
    }
    return null;
  }
}

enum ServerConfigSaveOutcome { confirmed, mismatch, stale }

/// What a save ended in. [serverValue] is what the re-read showed.
final class ServerConfigSaveResult {
  const ServerConfigSaveResult(this.outcome, [this.serverValue]);

  final ServerConfigSaveOutcome outcome;
  final Object? serverValue;
}

/// Reads and writes the server config fields of Settings › Advanced.
///
/// Every write is the minimal nested branch of the edited path (the server
/// deep-merges it), followed by a re-read: the row is only saved when the
/// server shows the value. Nothing is read or written for a path outside the
/// editable table, and a read-only repository never reaches the network.
final class ServerConfigRepository {
  ServerConfigRepository(
    this._dashboard, {
    String? profile,
    this._writable = true,
  }) : _profile = (profile == null || profile.trim().isEmpty)
           ? null
           : profile.trim();

  final DashboardClient _dashboard;
  final String? _profile;
  final bool _writable;
  final Map<String, Future<void>> _inFlight = {};

  bool get isWritable => _writable;

  /// Null when [isCurrent] turned false while the reads were in flight (the
  /// profile changed): that answer belongs to nobody.
  Future<ServerConfigSnapshot?> load({bool Function()? isCurrent}) async {
    try {
      final schema = await _dashboard.getServerConfigSchema(profile: _profile);
      final config = await _dashboard.getServerConfig(profile: _profile);
      if (isCurrent != null && !isCurrent()) return null;
      final fields = schema['fields'];
      if (fields is! Map) {
        throw const ServerConfigException(ServerConfigFailure.invalid);
      }
      final out = <ServerConfigField>[];
      fields.forEach((path, raw) {
        if (path is! String || raw is! Map) return;
        final type = raw['type'];
        if (type is! String || !isEditableServerConfigField(path, type)) return;
        final page = serverConfigPageForField(path);
        if (page == null) return;
        final options = raw['options'];
        final description = raw['description'];
        out.add(
          ServerConfigField(
            path: path,
            type: type,
            description: description is String ? description : path,
            options: options is List
                ? [for (final o in options) o.toString()]
                : const [],
            value: _valueAt(config, path),
            page: page,
          ),
        );
      });
      return ServerConfigSnapshot(out);
    } on ServerConfigException {
      rethrow;
    } catch (error) {
      throw _failure(error);
    }
  }

  /// Writes [value] at [path] and re-reads the server to confirm it. Saves of
  /// one path run one after the other; there is no queue of values.
  Future<ServerConfigSaveResult> save(
    String path,
    Object? value, {
    bool Function()? isCurrent,
  }) async {
    if (!_writable) {
      throw const ServerConfigException(ServerConfigFailure.readOnly);
    }
    // The schema type is not known here; the path alone must be editable.
    if (!isEditableServerConfigField(path, 'string')) {
      throw const ServerConfigException(ServerConfigFailure.invalid);
    }
    final previous = _inFlight[path] ?? Future<void>.value();
    final result = previous
        .catchError((Object _) {})
        .then((_) => _saveNow(path, value, isCurrent));
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _inFlight[path] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_inFlight[path], tail)) _inFlight.remove(path);
      }),
    );
    return result;
  }

  Future<ServerConfigSaveResult> _saveNow(
    String path,
    Object? value,
    bool Function()? isCurrent,
  ) async {
    try {
      await _dashboard.putServerConfigPatch(
        _branch(path, value),
        profile: _profile,
      );
      if (isCurrent != null && !isCurrent()) {
        return const ServerConfigSaveResult(ServerConfigSaveOutcome.stale);
      }
      final config = await _dashboard.getServerConfig(profile: _profile);
      if (isCurrent != null && !isCurrent()) {
        return const ServerConfigSaveResult(ServerConfigSaveOutcome.stale);
      }
      final seen = _valueAt(config, path);
      return _same(seen, value)
          ? ServerConfigSaveResult(ServerConfigSaveOutcome.confirmed, seen)
          : ServerConfigSaveResult(ServerConfigSaveOutcome.mismatch, seen);
    } on ServerConfigException {
      rethrow;
    } catch (error) {
      throw _failure(error);
    }
  }

  static ServerConfigException _failure(Object error) {
    if (error is DashboardHttpException) {
      return ServerConfigException(switch (error.statusCode) {
        401 || 403 => ServerConfigFailure.auth,
        404 || 405 => ServerConfigFailure.unsupported,
        _ => ServerConfigFailure.unavailable,
      });
    }
    return const ServerConfigException(ServerConfigFailure.unavailable);
  }

  /// `a.b.c` and `v` as `{a: {b: {c: v}}}`: only the edited branch.
  static Map<String, dynamic> _branch(String path, Object? value) {
    final parts = path.split('.');
    Object? node = value;
    for (final part in parts.reversed) {
      node = <String, dynamic>{part: node};
    }
    return node as Map<String, dynamic>;
  }

  static Object? _valueAt(Map<String, dynamic> config, String path) {
    // Desktop flattens some branches (`model`), but never the dotted fields
    // of the table.
    Object? node = config;
    for (final part in path.split('.')) {
      if (node is! Map) return null;
      node = node[part];
    }
    return node;
  }

  static bool _same(Object? a, Object? b) {
    if (a is num && b is num) return a == b;
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_same(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }
}
