import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'drawer_swipe_prefs.dart';

/// Reserva una franja pequeña del borde izquierdo para abrir el drawer.
///
/// Android limita estas exclusiones y puede recortarlas. La capa nativa usa
/// únicamente una banda central de 200 dp; nunca toca el borde derecho. Cada
/// ruta con drawer activa o desactiva la banda mediante [RouteAware].
///
/// Solo se reserva si además el lector activó «Abrir el menú deslizando»
/// ([DrawerSwipePrefs], apagado por defecto): sin él, el borde queda entero
/// para el gesto Atrás de Android.
class DrawerGestureExclusion {
  static const MethodChannel _channel = MethodChannel('hermes/system_gestures');

  /// Lo que pide la ruta visible (tiene drawer o no).
  static bool _routeWants = false;

  /// Lo último enviado a Android: ruta Y ajuste.
  static bool? _lastSent;

  static Future<void> setEnabled(bool enabled) {
    _routeWants = enabled;
    return _apply();
  }

  /// Vuelve a aplicar la banda cuando cambia el ajuste.
  static Future<void> refresh() => _apply();

  static Future<void> _apply() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final effective = _routeWants && DrawerSwipePrefs.shared.enabled;
    if (_lastSent == effective) return;
    _lastSent = effective;
    try {
      await _channel.invokeMethod<void>('setDrawerEdgeExclusion', {
        'enabled': effective,
      });
    } on MissingPluginException {
      // Tests y plataformas sin el adaptador nativo: el drawer conserva la
      // banda interior de Flutter como fallback.
    } on PlatformException catch (error) {
      debugPrint('[drawer-gesture] no se pudo aplicar la exclusión: $error');
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    _routeWants = false;
    _lastSent = null;
  }
}
