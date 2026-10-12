import 'package:shared_preferences/shared_preferences.dart';

/// Preference keys of features that no longer exist. They are removed at
/// start-up so an updated install keeps no orphan state.
const List<String> retiredPrefKeys = [
  // Quick reply chips (removed in 1.2.15).
  'chat_quick_replies_enabled',
];

Future<void> clearRetiredPrefs(SharedPreferences prefs) async {
  for (final key in retiredPrefKeys) {
    if (prefs.containsKey(key)) await prefs.remove(key);
  }
}
