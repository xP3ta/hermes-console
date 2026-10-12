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

  /// Where a device stored, until 1.2.15, whether it used "the dock with
  /// gestures" or the classic bar. There is one dock now, so the stored
  /// choice is not read; [ensureLoaded] removes it.
  static const gestureDockKey = 'feature_gesture_dock_v1';

  final ValueNotifier<bool> _gestureDock = ValueNotifier<bool>(true);

  /// Always true in the app: every screen mounts the one dock
  /// (`GestureDockHost`).
  ///
  /// It is still a notifier only as a seam for the suites written for the
  /// classic bar (`Dock._buildWithProfile`), which the app can no longer
  /// reach: they turn it off with [resetForTesting]. It goes away with that
  /// code.
  ValueListenable<bool> get gestureDock => _gestureDock;

  bool _loaded = false;

  /// Once per process: drops what an older version stored. Safe to call
  /// repeatedly. Nothing stored changes which dock the app mounts.
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(gestureDockKey)) await prefs.remove(gestureDockKey);
      _loaded = true;
    } catch (_) {
      // The next caller retries.
    }
  }

  /// Tests pick the dock they exercise; [gestureDock] defaults to the
  /// classic bar for the suites written for it (see [gestureDock]).
  @visibleForTesting
  void resetForTesting({bool gestureDock = false}) {
    _loaded = false;
    _gestureDock.value = gestureDock;
  }

  /// A fresh process: nothing read yet, the app's one dock in place.
  @visibleForTesting
  void resetToDefaultForTesting() {
    _loaded = false;
    _gestureDock.value = true;
  }
}
