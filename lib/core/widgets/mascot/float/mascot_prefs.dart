import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the floating mascot lives.
enum MascotPlacement {
  /// Stands on the dock's top edge (default): at its right end, or where
  /// along it the user dropped it.
  dock,

  /// Stays wherever the user dropped it.
  free,
}

/// What this device remembers about the floating mascot: where the user put
/// it and which suggestions he never wants again. Stored in
/// SharedPreferences. Defaults are never written: going back to a default
/// removes its key, so an untouched install stores nothing.
///
/// Whether the mascot shows at all is NOT here: that is the one "Presencia"
/// setting of the Mascotas screen.
class MascotPrefs extends ChangeNotifier {
  MascotPrefs();

  static final MascotPrefs instance = MascotPrefs();

  static const placementKey = 'mascot_float_placement_v1';
  static const positionKey = 'mascot_float_position_v1';
  static const dockAlongKey = 'mascot_float_dock_along_v1';
  static const mutedKey = 'mascot_float_muted_suggestions_v1';
  static const suggestedKey = 'mascot_float_suggested_v1';

  /// Written by QA builds of the flagged feature (its own on/off switch and
  /// sprite picker). Neither exists any more: [ensureLoaded] drops them.
  static const retiredKeys = [
    'mascot_float_enabled_v1',
    'mascot_float_sprite_v1',
  ];

  MascotPlacement _placement = MascotPlacement.dock;
  Offset? _position;
  double? _dockAlong;
  Set<String> _muted = const {};
  Map<String, int> _suggested = const {};
  bool _loaded = false;
  Future<void>? _loading;

  MascotPlacement get placement => _placement;

  /// Free position as fractions (0..1) of the screen, so it survives a
  /// rotation; null until the user drops it somewhere.
  Offset? get position => _position;

  /// Where along the dock (0..1) the user dropped it; null is the default,
  /// the right end.
  double? get dockAlong => _dockAlong;

  /// Suggestions the user answered with "No sugerirme esto".
  Set<String> get mutedSuggestions => _muted;

  bool get loaded => _loaded;

  /// True when the mascot is not at its default home.
  bool get moved => _placement == MascotPlacement.free || _dockAlong != null;

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // A stored 'float' is the flagged build's name for the same thing.
      _placement = switch (prefs.getString(placementKey)) {
        'free' || 'float' => MascotPlacement.free,
        _ => MascotPlacement.dock,
      };
      final raw = prefs.getStringList(positionKey);
      final x = raw == null || raw.length != 2 ? null : double.tryParse(raw[0]);
      final y = raw == null || raw.length != 2 ? null : double.tryParse(raw[1]);
      _position = x == null || y == null || !x.isFinite || !y.isFinite
          ? null
          : Offset(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
      final along = prefs.getDouble(dockAlongKey);
      _dockAlong = along == null || !along.isFinite
          ? null
          : along.clamp(0.0, 1.0);
      _muted = {...?prefs.getStringList(mutedKey)};
      _suggested = {
        for (final entry in prefs.getStringList(suggestedKey) ?? const [])
          if (entry.split('|') case [final id, final day])
            id: ?int.tryParse(day),
      };
      // A free mascot without a spot has nowhere to be: it is on the dock.
      if (_placement == MascotPlacement.free && _position == null) {
        _placement = MascotPlacement.dock;
      }
      for (final key in retiredKeys) {
        if (prefs.containsKey(key)) await prefs.remove(key);
      }
    } catch (_) {
      // Corrupt or unavailable storage: keep the defaults.
    }
    _loaded = true;
    notifyListeners();
  }

  /// Dropped at [position] (fractions of the screen): it stays there.
  Future<void> placeFree(Offset position) async {
    final next = Offset(
      position.dx.clamp(0.0, 1.0),
      position.dy.clamp(0.0, 1.0),
    );
    if (_placement == MascotPlacement.free && _position == next) return;
    _placement = MascotPlacement.free;
    _position = next;
    _dockAlong = null;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(placementKey, MascotPlacement.free.name);
      await prefs.setStringList(positionKey, [
        next.dx.toStringAsFixed(4),
        next.dy.toStringAsFixed(4),
      ]);
      await prefs.remove(dockAlongKey);
    } catch (_) {
      // The in-memory spot stays; the next drop retries the write.
    }
  }

  /// Dropped on the dock at [along] (0..1 along the bar), or sent back to
  /// its default home, the right end ([along] null: "Volver al dock").
  Future<void> placeOnDock({double? along}) async {
    final next = along?.clamp(0.0, 1.0);
    if (_placement == MascotPlacement.dock &&
        _dockAlong == next &&
        _position == null) {
      return;
    }
    _placement = MascotPlacement.dock;
    _position = null;
    _dockAlong = next;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(placementKey);
      await prefs.remove(positionKey);
      next == null
          ? await prefs.remove(dockAlongKey)
          : await prefs.setDouble(dockAlongKey, next);
    } catch (_) {
      // As above.
    }
  }

  /// "No sugerirme esto": [id] is never suggested again on this device.
  Future<void> muteSuggestion(String id) async {
    if (_muted.contains(id)) return;
    _muted = {..._muted, id};
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(mutedKey, _muted.toList()..sort());
    } catch (_) {
      // As above.
    }
  }

  static int _day(DateTime now) =>
      now.toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

  /// Whether the mascot may bring up suggestion [id] by itself at [now]:
  /// never once muted, and not again for a week after it was shown.
  bool maySuggest(String id, DateTime now, {int againAfterDays = 7}) {
    if (_muted.contains(id)) return false;
    final shown = _suggested[id];
    return shown == null || _day(now) - shown >= againAfterDays;
  }

  /// The mascot brought up suggestion [id] by itself at [now].
  Future<void> markSuggested(String id, DateTime now) async {
    final day = _day(now);
    if (_suggested[id] == day) return;
    _suggested = {..._suggested, id: day};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(suggestedKey, [
        for (final entry in _suggested.entries) '${entry.key}|${entry.value}',
      ]);
    } catch (_) {
      // As above.
    }
  }

  @visibleForTesting
  void resetForTesting() {
    _placement = MascotPlacement.dock;
    _position = null;
    _dockAlong = null;
    _muted = const {};
    _suggested = const {};
    _loaded = false;
    _loading = null;
    notifyListeners();
  }
}
