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

  Future<void> write(SavedConnection c, List<AgentProfile> profiles) async {
    final raw = jsonEncode({
      'endpoint': _endpoint(c),
      'profiles': [
        for (final p in profiles.take(512))
          {
            'name': p.name,
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
    if (raw.length <= 262144) await prefs.setString(_key(c), raw);
  }

  Future<void> remove(SavedConnection c) async {
    await prefs.remove(_key(c));
  }
}
