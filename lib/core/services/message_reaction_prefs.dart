import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether the chat shows and offers message reactions. Off by default so a
/// release that ships the feature changes nothing until the user opts in.
class MessageReactionPrefs extends ChangeNotifier {
  MessageReactionPrefs._(this._prefs)
    : _enabled = _prefs?.getBool(key) ?? false;

  static const String key = 'chat_reactions_enabled';

  final SharedPreferences? _prefs;
  bool _enabled;

  static MessageReactionPrefs? _shared;

  static MessageReactionPrefs get shared =>
      _shared ??= MessageReactionPrefs._(null);

  static Future<MessageReactionPrefs> load([SharedPreferences? prefs]) async {
    final resolved = prefs ?? await SharedPreferences.getInstance();
    final store = MessageReactionPrefs._(resolved);
    final previous = _shared;
    _shared = store;
    previous?.notifyListeners();
    return store;
  }

  @visibleForTesting
  static MessageReactionPrefs forTesting(SharedPreferences? prefs) =>
      MessageReactionPrefs._(prefs);

  @visibleForTesting
  static void debugUse(MessageReactionPrefs? store) => _shared = store;

  bool get enabled => _enabled;

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    await _prefs?.setBool(key, value);
  }
}
