import 'package:shared_preferences/shared_preferences.dart';

/// Pantalla con la que arranca la app.
///
/// El valor por defecto es [home]: quien no toque el ajuste sigue viendo
/// exactamente lo de siempre.
enum StartupDestination {
  home('home'),
  bots('bots');

  const StartupDestination(this.storageKey);

  final String storageKey;

  static StartupDestination fromStorage(String? value) {
    for (final destination in StartupDestination.values) {
      if (destination.storageKey == value) return destination;
    }
    return StartupDestination.home;
  }
}

/// Preferencia de pantalla de arranque (issue #47).
///
/// Sólo se aplica al abrir la app en frío. Volver desde segundo plano restaura
/// la pantalla en la que estabas, como hasta ahora.
class StartupDestinationStore {
  static const _key = 'startup_destination';

  static Future<StartupDestination> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return StartupDestination.fromStorage(prefs.getString(_key));
    } catch (_) {
      // Almacenamiento no disponible (arranque muy temprano, tests): el
      // comportamiento por defecto nunca debe impedir que la app abra.
      return StartupDestination.home;
    }
  }

  static Future<void> save(StartupDestination destination) async {
    final prefs = await SharedPreferences.getInstance();
    if (destination == StartupDestination.home) {
      await prefs.remove(_key);
      return;
    }
    await prefs.setString(_key, destination.storageKey);
  }
}
