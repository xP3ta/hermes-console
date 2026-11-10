import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bot_character.dart';

/// Saved characters, one per profile of a connection. Local to the device:
/// nothing is sent to the gateway. A profile without an entry keeps the face
/// it already has.
///
/// Persisted as one JSON map under [key]; read synchronously after [load].
/// Damaged storage reads as "no characters" and is replaced on the next save.
class BotCharacterStore extends ChangeNotifier {
  BotCharacterStore._(this._prefs) {
    _entries.addAll(_decode(_prefs?.getString(key)));
  }

  /// A store that lives in memory only and never touches [shared]: an editor
  /// hands it to the Studio so a character picked there stays a draft until
  /// the editor saves. Same entries, same format; nothing is persisted.
  factory BotCharacterStore.detached() => BotCharacterStore._(null);

  static const String key = 'characters_by_profile_v1';

  final SharedPreferences? _prefs;
  final Map<String, BotCharacter> _entries = {};

  static BotCharacterStore? _shared;

  static BotCharacterStore get shared => _shared ??= BotCharacterStore._(null);

  static Future<BotCharacterStore> load([SharedPreferences? prefs]) async {
    final resolved = prefs ?? await SharedPreferences.getInstance();
    final store = BotCharacterStore._(resolved);
    final previous = _shared;
    _shared = store;
    previous?.notifyListeners();
    return store;
  }

  @visibleForTesting
  static void debugUse(BotCharacterStore? store) => _shared = store;

  static String entryKey(String? connectionId, String profileName) =>
      '${connectionId ?? ''}|${profileName.trim()}';

  static Map<String, BotCharacter> _decode(String? source) {
    if (source == null || source.isEmpty) return const {};
    try {
      final raw = jsonDecode(source);
      if (raw is! Map) return const {};
      final out = <String, BotCharacter>{};
      for (final entry in raw.entries) {
        final character = BotCharacter.fromJson(entry.value);
        if (entry.key is String && character != null) {
          out[entry.key as String] = character;
        }
      }
      return out;
    } on FormatException {
      return const {};
    }
  }

  /// The saved character of [profileName], or null when none was saved.
  BotCharacter? characterFor(String? connectionId, String profileName) =>
      _entries[entryKey(connectionId, profileName)];

  Future<void> save(
    String? connectionId,
    String profileName,
    BotCharacter character,
  ) async {
    final id = entryKey(connectionId, profileName);
    if (character.isStandard) {
      if (_entries.remove(id) == null) return;
    } else {
      if (_entries[id] == character) return;
      _entries[id] = character;
    }
    notifyListeners();
    await _persist();
  }

  Future<void> reset(String? connectionId, String profileName) =>
      save(connectionId, profileName, BotCharacter.standard);

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    if (_entries.isEmpty) {
      await prefs.remove(key);
      return;
    }
    await prefs.setString(
      key,
      jsonEncode({
        for (final entry in _entries.entries) entry.key: entry.value.toJson(),
      }),
    );
  }
}
