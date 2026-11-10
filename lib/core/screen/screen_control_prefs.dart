import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted preferences for the display takeover controls.
///
/// Right now that is only whether the touch layer behaves as a touchpad
/// (relative pointer) or as a direct touch screen.
class ScreenControlPrefs extends ChangeNotifier {
  ScreenControlPrefs._(this._prefs) : _touchpad = _prefs?.getBool(touchpadKey);

  static const String touchpadKey = 'screen_touchpad_mode';

  final SharedPreferences? _prefs;
  bool? _touchpad;

  static ScreenControlPrefs? _shared;

  static ScreenControlPrefs get shared =>
      _shared ??= ScreenControlPrefs._(null);

  static Future<ScreenControlPrefs> load([SharedPreferences? prefs]) async {
    final resolved = prefs ?? await SharedPreferences.getInstance();
    final store = ScreenControlPrefs._(resolved);
    final previous = _shared;
    _shared = store;
    previous?.notifyListeners();
    return store;
  }

  @visibleForTesting
  static void debugUse(ScreenControlPrefs? store) => _shared = store;

  /// Whether the takeover screen moves a relative pointer (touchpad) instead
  /// of forwarding touches straight to the remote screen.
  bool get touchpadMode => _touchpad ?? false;

  Future<void> setTouchpad(bool value) async {
    if (_touchpad == value) return;
    _touchpad = value;
    notifyListeners();
    await _prefs?.setBool(touchpadKey, value);
  }
}
