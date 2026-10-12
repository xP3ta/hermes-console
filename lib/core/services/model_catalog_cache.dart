import '../models/desktop_model_catalog.dart';

/// Per-connection cache of the `model.options` catalog for the chat model
/// picker.
///
/// Desktop keeps the catalog in its query cache between picker opens; Console
/// used to re-read the whole catalog on every open, which made switching
/// models feel slow. Entries are scoped to the connection and profile, expire
/// after [ttl], and are dropped whenever a model change is accepted or the
/// caller asks for a refresh.
final class ModelCatalogCache {
  ModelCatalogCache({
    this.ttl = const Duration(minutes: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration ttl;
  final DateTime Function() _now;
  final Map<String, ({DateTime at, DesktopModelCatalog catalog})> _entries = {};

  static String _key(String connectionId, String profile) =>
      '$connectionId\u0000$profile';

  DesktopModelCatalog? read(String connectionId, String profile) {
    final key = _key(connectionId, profile);
    final entry = _entries[key];
    if (entry == null) return null;
    if (_now().difference(entry.at) >= ttl) {
      _entries.remove(key);
      return null;
    }
    return entry.catalog;
  }

  void write(String connectionId, String profile, DesktopModelCatalog catalog) {
    _entries[_key(connectionId, profile)] = (at: _now(), catalog: catalog);
  }

  void invalidate(String connectionId, String profile) {
    _entries.remove(_key(connectionId, profile));
  }
}
