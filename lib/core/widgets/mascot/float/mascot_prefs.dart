import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mascot_identity.dart';

/// Where the floating mascot lives.
enum MascotPlacement {
  /// Stands on the dock's top edge and wanders along it (default).
  dock,

  /// Stays wherever the user dropped it.
  float,
}

/// Per-device settings of the floating mascot (Ajustes → Mascota), stored
/// in SharedPreferences. Defaults are never written: switching back to a
/// default removes its key, so an untouched install stores nothing.
class MascotPrefs extends ChangeNotifier {
  MascotPrefs();

  static final MascotPrefs instance = MascotPrefs();

  static const enabledKey = 'mascot_float_enabled_v1';
  static const placementKey = 'mascot_float_placement_v1';
  static const spriteKey = 'mascot_float_sprite_v1';
  static const positionKey = 'mascot_float_position_v1';

  bool _enabled = true;
  MascotPlacement _placement = MascotPlacement.dock;
  MascotSpriteKind? _sprite;
  Offset? _position;
  bool _loaded = false;

  /// Shown at all. Off: nothing is lost, permissions stay as cards.
  bool get enabled => _enabled;
  MascotPlacement get placement => _placement;

  /// Chosen sprite; null follows the profile ([MascotIdentity.forProfile]).
  MascotSpriteKind? get sprite => _sprite;

  /// Floating position as fractions (0..1) of the screen, so it survives a
  /// rotation; null until the user drops it somewhere.
  Offset? get position => _position;

  bool get loaded => _loaded;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(enabledKey) ?? true;
      _placement = switch (prefs.getString(placementKey)) {
        'float' => MascotPlacement.float,
        _ => MascotPlacement.dock,
      };
      final sprite = prefs.getString(spriteKey);
      _sprite = MascotSpriteKind.values
          .where((kind) => kind.name == sprite)
          .firstOrNull;
      final raw = prefs.getStringList(positionKey);
      final x = raw == null || raw.length != 2 ? null : double.tryParse(raw[0]);
      final y = raw == null || raw.length != 2 ? null : double.tryParse(raw[1]);
      _position = x == null || y == null || !x.isFinite || !y.isFinite
          ? null
          : Offset(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
    } catch (_) {
      // Corrupt or unavailable storage: keep the defaults.
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (value == _enabled) return;
    _enabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    value
        ? await prefs.remove(enabledKey)
        : await prefs.setBool(enabledKey, false);
  }

  Future<void> setPlacement(MascotPlacement value) async {
    if (value == _placement) return;
    _placement = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    value == MascotPlacement.dock
        ? await prefs.remove(placementKey)
        : await prefs.setString(placementKey, value.name);
  }

  Future<void> setSprite(MascotSpriteKind? value) async {
    if (value == _sprite) return;
    _sprite = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    value == null
        ? await prefs.remove(spriteKey)
        : await prefs.setString(spriteKey, value.name);
  }

  /// Stores the floating position (fractions of the screen).
  Future<void> setPosition(Offset? value) async {
    _position = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    value == null
        ? await prefs.remove(positionKey)
        : await prefs.setStringList(positionKey, [
            value.dx.toStringAsFixed(4),
            value.dy.toStringAsFixed(4),
          ]);
  }

  @visibleForTesting
  void resetForTesting() {
    _enabled = true;
    _placement = MascotPlacement.dock;
    _sprite = null;
    _position = null;
    _loaded = false;
    notifyListeners();
  }
}
