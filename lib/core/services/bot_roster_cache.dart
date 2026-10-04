import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/agent_profile.dart';
import '../models/connection.dart';

/// Display-only offline inventory. Never stores chat pointers, credentials,
/// transcript previews, assets, or unknown profile metadata.
final class BotRosterCache {
  final SharedPreferences prefs;
  const BotRosterCache(this.prefs);
  String _key(SavedConnection c) =>
      'bots.roster.v1.${Uri.encodeComponent(c.id)}';
  String _endpoint(SavedConnection c) => sha256
      .convert(utf8.encode('${c.gatewayUrl}:${c.onDeviceLoopback}'))
      .toString();
  List<AgentProfile> read(SavedConnection c) {
    try {
      final raw = prefs.getString(_key(c));
      if (raw == null || raw.length > 262144) return [];
      final data = jsonDecode(raw);
      if (data is! Map ||
          data['endpoint'] != _endpoint(c) ||
          data['profiles'] is! List) {
        return [];
      }
      return (data['profiles'] as List)
          .take(512)
          .whereType<Map>()
          .map((row) => AgentProfile.fromJson(Map<String, dynamic>.from(row)))
          .where((p) => RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(p.name))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Start time (ms since epoch) of the read the stored roster came from;
  /// 0 when unknown or stored for another endpoint.
  int _observedAt(SavedConnection c) {
    try {
      final data = jsonDecode(prefs.getString(_key(c)) ?? '');
      if (data is Map && data['endpoint'] == _endpoint(c)) {
        final at = data['observed_at'];
        if (at is int) return at;
      }
    } catch (_) {}
    return 0;
  }

  /// Persists [profiles]. The app and the background monitor (another
  /// isolate) both write here, so with [observedAt] (when the read that
  /// produced it started) a roster older than the stored one is dropped.
  /// [reload] first picks up the other isolate's writes.
  Future<void> write(
    SavedConnection c,
    List<AgentProfile> profiles, {
    DateTime? observedAt,
    bool reload = false,
  }) async {
    if (reload) await prefs.reload();
    final at = observedAt?.millisecondsSinceEpoch;
    if (at != null && _observedAt(c) > at) return;
    final raw = jsonEncode({
      'endpoint': _endpoint(c),
      'observed_at': ?at,
      'profiles': [
        for (final p in profiles.take(512))
          {
            'name': p.name,
            // The profile's name as every surface shows it, so a cold
            // start never paints the generic default label first.
            if (p.isDefault) 'is_default': true,
            if (p.displayName.trim().isNotEmpty) 'display_name': p.displayName,
            'ui_meta': {
              'hermes-bots': {
                if (p.botTitle != null) 'title': p.botTitle,
                if (p.botShape != null) 'shape': p.botShape,
                if (p.botColorHex != null) 'color': p.botColorHex,
                'hidden': p.botHidden,
                'pinned': p.botPinned,
              },
            },
          },
      ],
    });
    // Every roster read lands here; skip rewriting an unchanged roster.
    if (raw.length <= 262144 && prefs.getString(_key(c)) != raw) {
      await prefs.setString(_key(c), raw);
    }
  }

  Future<void> remove(SavedConnection c) async {
    await prefs.remove(_key(c));
  }
}
