import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether the chat offers quick reply chips above the composer after a
/// finished turn. On by default: the default chips are local and free; only
/// the ✨ chip asks the model, and only when tapped.
class QuickReplyPrefs extends ChangeNotifier {
  QuickReplyPrefs._(this._prefs) : _enabled = _prefs?.getBool(key) ?? true;

  static const String key = 'chat_quick_replies_enabled';

  final SharedPreferences? _prefs;
  bool _enabled;

  static QuickReplyPrefs? _shared;

  static QuickReplyPrefs get shared => _shared ??= QuickReplyPrefs._(null);

  static Future<QuickReplyPrefs> load([SharedPreferences? prefs]) async {
    final resolved = prefs ?? await SharedPreferences.getInstance();
    final store = QuickReplyPrefs._(resolved);
    final previous = _shared;
    _shared = store;
    previous?.notifyListeners();
    return store;
  }

  @visibleForTesting
  static QuickReplyPrefs forTesting(SharedPreferences? prefs) =>
      QuickReplyPrefs._(prefs);

  @visibleForTesting
  static void debugUse(QuickReplyPrefs? store) => _shared = store;

  bool get enabled => _enabled;

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    await _prefs?.setBool(key, value);
  }
}
