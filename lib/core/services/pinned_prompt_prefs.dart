import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The one-line pinned prompt at the top of a chat: on by default, can be
/// switched off globally in Settings, or hidden for a single chat with its
/// × (remembered per chat). A hidden chat gets it back from the chat menu,
/// the × SnackBar's Undo, or by switching the Settings toggle back on.
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

  /// Turning the switch back on also forgets every per-chat hide, so the
  /// Settings switch is a way back for a prompt hidden with ×.
  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    final clearHidden = value && _hidden.isNotEmpty;
    if (clearHidden) _hidden.clear();
    notifyListeners();
    if (value) {
      await _prefs?.remove(key);
      if (clearHidden) await _prefs?.remove(hiddenKey);
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

  /// Undoes [hideFor] for one chat.
  Future<void> showFor(String chatKey) async {
    if (!_hidden.remove(chatKey)) return;
    notifyListeners();
    if (_hidden.isEmpty) {
      await _prefs?.remove(hiddenKey);
    } else {
      await _prefs?.setStringList(hiddenKey, List.of(_hidden));
    }
  }
}
