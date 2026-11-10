import 'package:shared_preferences/shared_preferences.dart';

/// Remembers, per saved connection, that the one-line "plain http" note was
/// already shown, so it never comes back for that connection. The key ends
/// with the connection id, which is what `ConnectionManager` needs to wipe it
/// when the connection is deleted.
class CleartextNoticeMemory {
  const CleartextNoticeMemory(this._prefs);

  /// Prefix of the per-connection key (also listed in the connection manager's
  /// connection-scoped prefixes).
  static const String keyPrefix = 'krh_http_seen_';

  final SharedPreferences _prefs;

  static String keyFor(String connectionId) => '$keyPrefix$connectionId';

  bool seen(String connectionId) =>
      _prefs.getBool(keyFor(connectionId)) ?? false;

  Future<void> markSeen(String connectionId) =>
      _prefs.setBool(keyFor(connectionId), true);
}
