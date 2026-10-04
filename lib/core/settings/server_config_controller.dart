import 'package:flutter/foundation.dart';

import '../services/server_config_repository.dart';

enum ServerConfigPhase { idle, loading, ready, failed }

/// State of one Advanced page: the config read when it opens, one save in
/// flight per field and the failure of the last one.
///
/// [isCurrent] says whether the profile this controller was made for is still
/// the active one: an answer that arrives after a switch, or after [dispose],
/// is dropped and notifies nobody.
class ServerConfigController extends ChangeNotifier {
  final ServerConfigStore store;
  final bool Function() isCurrent;

  ServerConfigController({required this.store, required this.isCurrent});

  ServerConfigPhase phase = ServerConfigPhase.idle;
  ServerConfigFailureKind? loadFailure;

  Map<String, dynamic> _config = const {};
  final Set<String> _saving = {};
  final Map<String, ServerConfigFailureKind> _errors = {};
  bool _disposed = false;

  bool get canWrite => store.isWritable;

  Object? valueOf(String path) => serverConfigValueAt(_config, path);
  bool isSaving(String path) => _saving.contains(path);
  ServerConfigFailureKind? errorOf(String path) => _errors[path];

  bool get _stale => _disposed || !isCurrent();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Reads the config: one request.
  Future<void> load() async {
    phase = ServerConfigPhase.loading;
    loadFailure = null;
    _notify();
    try {
      final config = await store.readConfig();
      if (_stale) return;
      _config = config;
      phase = ServerConfigPhase.ready;
    } on ServerConfigException catch (failure) {
      if (_stale) return;
      loadFailure = failure.kind;
      phase = ServerConfigPhase.failed;
    }
    _notify();
  }

  /// Saves one field and waits for the re-read. Returns whether the server
  /// now holds [value]. A field that is already saving, a read-only store
  /// and a stale controller do nothing.
  Future<bool> save(String path, Object? value) async {
    if (!canWrite || _stale || _saving.contains(path)) return false;
    _saving.add(path);
    _errors.remove(path);
    _notify();
    try {
      final held = await store.save(path, value);
      if (_stale) return false;
      _config = _assign(_config, path, held);
      return true;
    } on ServerConfigException catch (failure) {
      if (_stale) return false;
      if (failure.kind == ServerConfigFailureKind.notSaved) {
        // The row goes back to what the server holds.
        _config = _assign(_config, path, failure.serverValue);
      }
      _errors[path] = failure.kind;
      return false;
    } finally {
      _saving.remove(path);
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// A copy of [config] with [value] at the dotted [path].
Map<String, dynamic> _assign(
  Map<String, dynamic> config,
  String path,
  Object? value,
) {
  final steps = path.split('.');
  Map<String, dynamic> copy(Map<String, dynamic> from, int depth) {
    final next = Map<String, dynamic>.from(from);
    if (depth == steps.length - 1) {
      next[steps[depth]] = value;
    } else {
      final child = next[steps[depth]];
      next[steps[depth]] = copy(
        child is Map ? Map<String, dynamic>.from(child) : <String, dynamic>{},
        depth + 1,
      );
    }
    return next;
  }

  return copy(config, 0);
}
