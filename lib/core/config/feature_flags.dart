import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-local switches for features that ship dark.
///
/// A flag that is off must leave the app exactly as it was before the
/// feature existed: callers branch on the flag at the outermost point and
/// mount nothing of the new feature while it is off.
class FeatureFlags {
  FeatureFlags._();

  static final FeatureFlags instance = FeatureFlags._();

  static const gestureDockKey = 'feature_gesture_dock_v1';

  final ValueNotifier<bool> _gestureDock = ValueNotifier<bool>(false);

  /// The floating gesture dock on non-chat screens. Off by default; only
  /// the experimental row in Settings turns it on.
  ValueListenable<bool> get gestureDock => _gestureDock;

  bool _loaded = false;

  /// Reads the persisted flags once per process. Safe to call repeatedly.
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getBool(gestureDockKey);
      if (stored != null) _gestureDock.value = stored;
      _loaded = true;
    } catch (_) {
      // Stay on the default (off); the next caller retries.
    }
  }

  Future<void> setGestureDock(bool enabled) async {
    _gestureDock.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    if (enabled) {
      await prefs.setBool(gestureDockKey, true);
    } else {
      // Off is the default: clear the key instead of storing it.
      await prefs.remove(gestureDockKey);
    }
  }

  @visibleForTesting
  void resetForTesting({bool gestureDock = false}) {
    _loaded = false;
    _gestureDock.value = gestureDock;
  }
}
