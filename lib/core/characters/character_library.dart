import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bot_character.dart';
import 'studio_catalog.dart';

/// A character the user saved under a name.
@immutable
final class SavedCharacter {
  final String id;
  final String name;
  final BotCharacter character;

  const SavedCharacter({
    required this.id,
    required this.name,
    required this.character,
  });

  SavedCharacter copyWith({String? name, BotCharacter? character}) =>
      SavedCharacter(
        id: id,
        name: name ?? this.name,
        character: character ?? this.character,
      );

  @override
  bool operator ==(Object other) =>
      other is SavedCharacter &&
      other.id == id &&
      other.name == name &&
      other.character == character;

  @override
  int get hashCode => Object.hash(id, name, character);
}

/// The user's saved characters: a named collection kept on this device,
/// separate from the character each profile wears ([BotCharacterStore]).
///
/// Persisted as one JSON document under [key]. Damaged storage reads as an
/// empty collection and is replaced on the next save.
class BotCharacterLibrary extends ChangeNotifier {
  BotCharacterLibrary._(this._prefs, this._newId) {
    _items.addAll(_decode(_read(_prefs)));
  }

  /// The stored document; a value of the wrong type reads as none.
  static String? _read(SharedPreferences? prefs) {
    try {
      return prefs?.getString(key);
    } on Object {
      return null;
    }
  }

  static const String key = 'character_library_v1';

  /// Most characters kept; the oldest go first.
  static const int maxItems = 60;

  final SharedPreferences? _prefs;
  final String Function() _newId;
  final List<SavedCharacter> _items = [];
  int _counter = 0;

  static BotCharacterLibrary? _shared;

  static BotCharacterLibrary get shared =>
      _shared ??= BotCharacterLibrary._(null, _clockId);

  static String _clockId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  static Future<BotCharacterLibrary> load([
    SharedPreferences? prefs,
    String Function()? newId,
  ]) async {
    final resolved = prefs ?? await SharedPreferences.getInstance();
    final library = BotCharacterLibrary._(resolved, newId ?? _clockId);
    final previous = _shared;
    _shared = library;
    previous?.notifyListeners();
    return library;
  }

  /// A library with no storage, for tests.
  @visibleForTesting
  factory BotCharacterLibrary.memory({String Function()? newId}) =>
      BotCharacterLibrary._(null, newId ?? _clockId);

  @visibleForTesting
  static void debugUse(BotCharacterLibrary? library) => _shared = library;

  List<SavedCharacter> get items => List.unmodifiable(_items);

  SavedCharacter? byId(String? id) {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  static String cleanName(String raw) {
    final text = raw.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ').trim();
    final collapsed = text.replaceAll(RegExp(r'\s+'), ' ');
    return collapsed.length > BotStudioLimits.maxNameLength
        ? collapsed.substring(0, BotStudioLimits.maxNameLength).trimRight()
        : collapsed;
  }

  String _fresh() {
    var id = '${_newId()}${(_counter++).toRadixString(36)}';
    while (byId(id) != null) {
      id = '${_newId()}${(_counter++).toRadixString(36)}';
    }
    return id;
  }

  /// Saves [character] as a new entry named [name]; an empty name becomes
  /// [fallbackName].
  Future<SavedCharacter> add(
    String name,
    BotCharacter character, {
    String fallbackName = '',
  }) async {
    final clean = cleanName(name);
    final item = SavedCharacter(
      id: _fresh(),
      name: clean.isEmpty ? cleanName(fallbackName) : clean,
      character: character,
    );
    _items.add(item);
    while (_items.length > maxItems) {
      _items.removeAt(0);
    }
    notifyListeners();
    await _persist();
    return item;
  }

  /// Updates the entry [id] (renaming and/or replacing its character).
  Future<SavedCharacter?> update(
    String id, {
    String? name,
    BotCharacter? character,
  }) async {
    final index = _items.indexWhere((item) => item.id == id);
    if (index < 0) return null;
    final clean = name == null ? null : cleanName(name);
    final next = _items[index].copyWith(
      name: clean == null || clean.isEmpty ? null : clean,
      character: character,
    );
    if (next == _items[index]) return next;
    _items[index] = next;
    notifyListeners();
    await _persist();
    return next;
  }

  /// A copy of [id] right after it, named [copyName].
  Future<SavedCharacter?> duplicate(String id, String copyName) async {
    final index = _items.indexWhere((item) => item.id == id);
    if (index < 0) return null;
    final copy = SavedCharacter(
      id: _fresh(),
      name: cleanName(copyName),
      character: _items[index].character,
    );
    _items.insert(index + 1, copy);
    notifyListeners();
    await _persist();
    return copy;
  }

  Future<void> remove(String id) async {
    final before = _items.length;
    _items.removeWhere((item) => item.id == id);
    if (_items.length == before) return;
    notifyListeners();
    await _persist();
  }

  static List<SavedCharacter> _decode(String? source) {
    if (source == null || source.isEmpty) return const [];
    try {
      final raw = jsonDecode(source);
      final list = raw is Map ? raw['items'] : null;
      if (list is! List) return const [];
      final out = <SavedCharacter>[];
      final seen = <String>{};
      for (final entry in list) {
        try {
          if (entry is! Map) continue;
          final id = entry['id'];
          final name = entry['name'];
          final character = BotCharacter.fromJson(entry['character']);
          if (id is! String || id.isEmpty || id.length > 64) continue;
          if (character == null || !seen.add(id)) continue;
          out.add(
            SavedCharacter(
              id: id,
              name: name is String ? cleanName(name) : '',
              character: character,
            ),
          );
        } on Object {
          continue; // one damaged entry does not cost the others
        }
        if (out.length >= maxItems) break;
      }
      return out;
    } on FormatException {
      return const [];
    }
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    if (_items.isEmpty) {
      await prefs.remove(key);
      return;
    }
    await prefs.setString(
      key,
      jsonEncode({
        'v': 1,
        'items': [
          for (final item in _items)
            {
              'id': item.id,
              'name': item.name,
              'character': item.character.toJson(),
            },
        ],
      }),
    );
  }
}
