import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The one-line pinned prompt at the top of a chat: on by default, can be
/// switched off globally in Settings, or hidden for a single chat with its
/// × (remembered per chat).
class PinnedPromptPrefs extends ChangeNotifier {
  PinnedPromptPrefs._(this._prefs)
    : _enabled = _prefs?.getBool(key) ?? true,
      _hidden = [...?_prefs?.getStringList(hiddenKey)];

  static const String key = 'chat_pinned_prompt_enabled';
  static const String hiddenKey = 'chat_pinned_prompt_hidden_v1';

  /// Chats remembered as hidden; the oldest are forgotten past this.
  static const int maxHiddenChats = 300;

  final SharedPreferences? _prefs;
  bool _enabled;
  final List<String> _hidden;

  static PinnedPromptPrefs? _shared;

  static PinnedPromptPrefs get shared => _shared ??= PinnedPromptPrefs._(null);

  static Future<PinnedPromptPrefs> load([SharedPreferences? prefs]) async {
    final resolved = prefs ?? await SharedPreferences.getInstance();
    final store = PinnedPromptPrefs._(resolved);
    final previous = _shared;
    _shared = store;
    previous?.notifyListeners();
    return store;
  }

  @visibleForTesting
  static void debugUse(PinnedPromptPrefs? store) => _shared = store;

  bool get enabled => _enabled;

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    if (value) {
      await _prefs?.remove(key);
    } else {
      await _prefs?.setBool(key, false);
    }
  }

  /// [chatKey] identifies one conversation on one connection.
  bool isHiddenFor(String chatKey) => _hidden.contains(chatKey);

  Future<void> hideFor(String chatKey) async {
    if (_hidden.contains(chatKey)) return;
    _hidden.add(chatKey);
    while (_hidden.length > maxHiddenChats) {
      _hidden.removeAt(0);
    }
    notifyListeners();
    await _prefs?.setStringList(hiddenKey, List.of(_hidden));
  }
}
