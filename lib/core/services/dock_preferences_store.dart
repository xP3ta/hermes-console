import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/dock_config.dart';

/// Persistencia local no sensible de la configuración del dock (perfiles
/// Bots/General: orden, visibilidad, destacado, estilo).
///
/// Sigue el mismo patrón que [ChatPreferenceStore]: una clave por dato,
/// JSON plano, sin datos sensibles.
class DockPreferencesStore {
  static const _key = 'dock_preferences_v1';
  static const _maxPayloadBytes = 8192;

  final SharedPreferences _prefs;

  const DockPreferencesStore(this._prefs);

  DockPreferences load() {
    final raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return DockPreferences.defaults();
    try {
      final value = jsonDecode(raw);
      if (value is! Map) return DockPreferences.defaults();
      final json = <String, Object?>{
        for (final entry in value.entries)
          if (entry.key is String) entry.key as String: entry.value,
      };
      return DockPreferences.fromJson(json);
    } on FormatException {
      return DockPreferences.defaults();
    }
  }

  Future<void> save(DockPreferences value) async {
    final encoded = jsonEncode(value.toJson());
    if (utf8.encode(encoded).length > _maxPayloadBytes) {
      throw const FormatException('Dock preferences exceed their size limit');
    }
    await _prefs.setString(_key, encoded);
  }

  Future<void> clear() => _prefs.remove(_key);
}

/// Controlador reactivo en memoria, compartido por todos los docks y por la
/// pantalla de personalización, para que un cambio en Ajustes › Dock se vea
/// reflejado al instante sin reiniciar la app (mismo patrón que los
/// `ValueNotifier` globales de tema/fuente/idioma en `main.dart`).
class DockPreferencesController {
  DockPreferencesController._();

  static final DockPreferencesController instance =
      DockPreferencesController._();

  final _notifier = _DockPreferencesNotifier(DockPreferences.defaults());

  /// Notifica cambios de configuración; escúchalo con `ListenableBuilder`.
  Listenable get listenable => _notifier;

  DockPreferences get value => _notifier.value;

  bool _initialized = false;

  /// Carga la configuración persistida. Segura de llamar más de una vez
  /// (por ejemplo, desde varias pantallas que instancian un dock); solo la
  /// primera llamada toca disco.
  Future<void> ensureLoaded() async {
    if (_initialized) return;
    _initialized = true;
    final prefs = await SharedPreferences.getInstance();
    _notifier.value = DockPreferencesStore(prefs).load();
  }

  Future<void> updateBots(
    DockProfileConfig Function(DockProfileConfig) update,
  ) => _updateProfile(bots: update(value.bots));

  Future<void> updateGeneral(
    DockProfileConfig Function(DockProfileConfig) update,
  ) => _updateProfile(general: update(value.general));

  Future<void> resetBots() =>
      _updateProfile(bots: DockProfileConfig.defaultBots());

  Future<void> resetGeneral() =>
      _updateProfile(general: DockProfileConfig.defaultGeneral());

  Future<void> _updateProfile({
    DockProfileConfig? bots,
    DockProfileConfig? general,
  }) async {
    final next = value.copyWith(bots: bots, general: general);
    _notifier.value = next;
    final prefs = await SharedPreferences.getInstance();
    await DockPreferencesStore(prefs).save(next);
  }
}

class _DockPreferencesNotifier extends ChangeNotifier {
  _DockPreferencesNotifier(this._value);

  DockPreferences _value;
  DockPreferences get value => _value;
  set value(DockPreferences next) {
    _value = next;
    notifyListeners();
  }
}
