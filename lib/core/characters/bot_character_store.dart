import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bot_character.dart';

/// Saved characters, one per profile of a connection. The device keeps its
/// own copy; `CharacterSync` carries it to and from the profile on the
/// server, so every device shows the same face. A profile without an entry
/// keeps the face it already has.
///
/// Persisted as one JSON map under [key]; read synchronously after [load].
/// Damaged storage reads as "no characters" and is replaced on the next save.
class BotCharacterStore extends ChangeNotifier {
  BotCharacterStore._(this._prefs) {
    _entries.addAll(_decode(_prefs?.getString(key)));
    _dirty.addAll(_prefs?.getStringList(dirtyKey) ?? const []);
    _synced.addAll(_prefs?.getStringList(syncedKey) ?? const []);
  }

  static const String dirtyKey = 'characters_dirty_v1';
  static const String syncedKey = 'characters_synced_v1';

  /// Entries changed here and not yet confirmed by the server.
  final Set<String> _dirty = {};

  /// Entries the server is known to hold as this device has them.
  final Set<String> _synced = {};

  /// Called after a change made on this device (never for [applyRemote]).
  static void Function(String? connectionId, String profileName)? onLocalChange;

  bool isDirty(String? connectionId, String profileName) =>
      _dirty.contains(entryKey(connectionId, profileName));

  bool isSynced(String? connectionId, String profileName) =>
      _synced.contains(entryKey(connectionId, profileName));

  /// The server now holds this entry as the device has it (or, when the
  /// device has none, holds none).
  Future<void> markSynced(String? connectionId, String profileName) async {
    final id = entryKey(connectionId, profileName);
    final had = _dirty.remove(id);
    final changed = _entries.containsKey(id)
        ? _synced.add(id)
        : _synced.remove(id);
    if (had || changed) await _persistMarks();
  }

  /// Takes the server's character (null: the server has none) without
  /// marking it as a change of this device.
  Future<void> applyRemote(
    String? connectionId,
    String profileName,
    BotCharacter? character,
  ) async {
    final id = entryKey(connectionId, profileName);
    final value = character == null || character.isStandard ? null : character;
    var changed = false;
    if (value == null) {
      changed = _entries.remove(id) != null;
      _synced.remove(id);
    } else {
      if (_entries[id] != value) {
        _entries[id] = value;
        changed = true;
      }
      _synced.add(id);
    }
    _dirty.remove(id);
    if (changed) {
      notifyListeners();
      await _persist();
    }
    await _persistMarks();
  }

  Future<void> _persistMarks() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setStringList(dirtyKey, _dirty.toList()..sort());
    await prefs.setStringList(syncedKey, _synced.toList()..sort());
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
    if (_prefs != null) {
      _dirty.add(id);
      await _persistMarks();
      onLocalChange?.call(connectionId, profileName);
    }
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
