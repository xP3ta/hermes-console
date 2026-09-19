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
    } catch (_) {
      // Un payload corrupto puede fallar con `FormatException` (JSON
      // inválido) o con un `TypeError` en cuanto `DockPreferences.fromJson`
      // encuentra un tipo inesperado en un campo (p.ej. un número donde se
      // esperaba un mapa): antes solo se capturaba el primer caso, así que
      // el segundo escapaba como una excepción async sin dueño desde
      // `unawaited(ensureLoaded())` (bug confirmado: C1). Cualquier fallo de
      // parseo debe fallar cerrado a los valores por defecto, igual que un
      // esquema desconocido.
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
    try {
      final prefs = await SharedPreferences.getInstance();
      _notifier.value = DockPreferencesStore(prefs).load();
      _initialized = true;
    } catch (_) {
      // No se marca `_initialized` en caso de fallo (p.ej.
      // `SharedPreferences.getInstance()` lanzando por un canal de
      // plataforma caído): antes se marcaba ANTES del `await`, así que un
      // fallo aquí dejaba la app entera atascada en la configuración por
      // defecto en memoria para el resto del proceso, sin ningún reintento
      // posible (bug confirmado: C2). El valor en memoria ya es
      // `DockPreferences.defaults()` desde la construcción del notifier;
      // la siguiente pantalla que instancie un dock reintentará solo.
    }
  }

  Future<void> updateBots(
    DockProfileConfig Function(DockProfileConfig) update, {
    bool persist = true,
  }) => _updateProfile(bots: update(value.bots), persist: persist);

  Future<void> updateGeneral(
    DockProfileConfig Function(DockProfileConfig) update, {
    bool persist = true,
  }) => _updateProfile(general: update(value.general), persist: persist);

  Future<void> resetBots() =>
      _updateProfile(bots: DockProfileConfig.defaultBots());

  Future<void> resetGeneral() =>
      _updateProfile(general: DockProfileConfig.defaultGeneral());

  /// Interruptor GLOBAL (no por perfil): apaga el dock flotante en toda la
  /// app. `GeneralDockShell` y el propio `Dock` reaccionan al
  /// instante vía `listenable`, igual que cualquier otro cambio de este
  /// controlador.
  Future<void> setUseDock(bool enabled) =>
      _updateProfile(useDock: enabled);

  /// `persist: false` solo actualiza el `ValueNotifier` en memoria (los
  /// docks/la vista previa reaccionan al instante vía `ListenableBuilder`)
  /// sin escribir a disco: antes CADA notificación (incluido cada frame de
  /// un arrastre de slider) también escribía en `SharedPreferences`, cientos
  /// de veces por segundo mientras se arrastraba (bug confirmado: C4). Quien
  /// llama con `persist: false` es responsable de volver a llamar con
  /// `persist: true` (el valor por defecto) al terminar el gesto para que el
  /// valor final sí quede guardado.
  Future<void> _updateProfile({
    DockProfileConfig? bots,
    DockProfileConfig? general,
    bool? useDock,
    bool persist = true,
  }) async {
    final next = value.copyWith(bots: bots, general: general, useDock: useDock);
    _notifier.value = next;
    if (!persist) return;
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
