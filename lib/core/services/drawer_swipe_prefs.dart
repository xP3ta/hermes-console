import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'drawer_gesture_exclusion.dart';

/// «Abrir el menú deslizando» (Ajustes → Aspecto → Look & Feel).
///
/// Off unless the reader turned it on: with no stored choice — a new install
/// or an update from a version that always opened the menu from the edge —
/// the menu opens only from its button, and the left edge is left to
/// Android's Back gesture and to horizontal scrolling (user report:
/// Back on a Galaxy S25 and wide tables). A stored choice is kept.
class DrawerSwipePrefs extends ChangeNotifier {
  DrawerSwipePrefs._(this._prefs) : _enabled = _read(_prefs);

  static const String key = 'drawer_open_swipe_enabled';

  final SharedPreferences? _prefs;
  bool _enabled;

  static DrawerSwipePrefs? _shared;

  static DrawerSwipePrefs get shared => _shared ??= DrawerSwipePrefs._(null);

  static bool _read(SharedPreferences? prefs) {
    try {
      return prefs?.getBool(key) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<DrawerSwipePrefs> load([SharedPreferences? prefs]) async {
    final resolved = prefs ?? await SharedPreferences.getInstance();
    final store = DrawerSwipePrefs._(resolved);
    final previous = _shared;
    _shared = store;
    previous?.notifyListeners();
    unawaited(DrawerGestureExclusion.refresh());
    return store;
  }

  @visibleForTesting
  static void debugUse(DrawerSwipePrefs? store) => _shared = store;

  @visibleForTesting
  static DrawerSwipePrefs debugFrom(SharedPreferences? prefs) =>
      DrawerSwipePrefs._(prefs);

  bool get enabled => _enabled;

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    // The native Back-gesture exclusion follows the setting at once, not
    // at the next navigation.
    unawaited(DrawerGestureExclusion.refresh());
    await _prefs?.setBool(key, value);
  }
}

/// Rebuilds the screens that read [HermesDrawer.openDragEnabled] when the
/// setting changes, including routes covered by Settings.
class DrawerSwipeScope extends InheritedNotifier<DrawerSwipePrefs> {
  const DrawerSwipeScope({
    super.key,
    required DrawerSwipePrefs super.notifier,
    required super.child,
  });

  static bool enabledOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<DrawerSwipeScope>();
    return (scope?.notifier ?? DrawerSwipePrefs.shared).enabled;
  }
}
