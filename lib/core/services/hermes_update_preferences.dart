import 'package:shared_preferences/shared_preferences.dart';

/// Hermes-only opt-in. Historical shared-component consent remains valid for
/// Hermes; an orphaned companion-only toggle is not permission to mutate it.
abstract final class HermesUpdatePreferences {
  static Future<bool> enabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('hermes_auto_update') ??
        prefs.getBool('components_auto_update') ??
        false;
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('hermes_auto_update', value);
  }
}
