// What this phone keeps of the chats so that they are there before the server
// answers: the choice behind Settings → Data → Cache.
//
// Three things, all on this device only and never sent anywhere:
//  * the Chats list (titles, previews, dates),
//  * the newest messages of the chats opened last,
//  * how many chats keep their messages.
// Turning one off stops saving it; the screen also deletes what was kept.
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CacheSettings extends ChangeNotifier {
  CacheSettings(this._prefs);

  final SharedPreferences _prefs;

  static const chatListKey = 'cache_chat_list_v1';
  static const messagesKey = 'cache_messages_v1';
  static const maxChatsKey = 'cache_max_chats_v1';

  /// The limits the picker offers, and the one a fresh install starts with.
  static const List<int> limits = [10, 20, 50, 100];
  static const int defaultLimit = 20;

  bool get chatList => _prefs.getBool(chatListKey) ?? true;
  bool get messages => _prefs.getBool(messagesKey) ?? true;

  /// Chats that keep their newest messages; an unknown stored value reads as
  /// the default.
  int get maxChats {
    final stored = _prefs.getInt(maxChatsKey);
    return stored != null && limits.contains(stored) ? stored : defaultLimit;
  }

  Future<void> setChatList(bool value) async {
    await _prefs.setBool(chatListKey, value);
    notifyListeners();
  }

  Future<void> setMessages(bool value) async {
    await _prefs.setBool(messagesKey, value);
    notifyListeners();
  }

  Future<void> setMaxChats(int value) async {
    if (!limits.contains(value)) return;
    await _prefs.setInt(maxChatsKey, value);
    notifyListeners();
  }
}
