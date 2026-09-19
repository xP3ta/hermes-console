import 'package:flutter/widgets.dart';

/// Catálogo único de movimiento de la app (spec 041).
///
/// Un solo punto de verdad para duraciones y curvas de animación, más el
/// apagado por accesibilidad ("reducir movimiento" / ahorro de batería). Ningún
/// widget debe declarar duraciones o curvas de animación fuera de aquí, para que
/// el lenguaje de movimiento sea coherente y auditable.
class Motion {
  const Motion._();

  /// Cambios de estado pequeños (píldoras de estado, colores) y salidas.
  static const Duration fast = Duration(milliseconds: 120);

  /// Entradas de contenido y listas, y plegado/desplegado.
  static const Duration base = Duration(milliseconds: 200);

  /// Transiciones de navegación entre pantallas.
  static const Duration page = Duration(milliseconds: 260);

  /// Curva de entrada (aparición de contenido).
  static const Curve enter = Curves.easeOutCubic;

  /// Curva de salida.
  static const Curve exit = Curves.easeInCubic;

  /// Curva de cambio de tamaño (plegado/desplegado).
  static const Curve size = Curves.easeInOutCubic;

  /// True si el sistema pide reducir el movimiento (accesibilidad/ahorro).
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  /// Duración efectiva: la nominal, o cero si hay que reducir el movimiento.
  static Duration duration(BuildContext context, Duration nominal) =>
      reduced(context) ? Duration.zero : nominal;
}

/// Transición de navegación de la app: fade + un leve deslizamiento ascendente,
/// con la curva y duración del catálogo. Respeta "reducir movimiento": si está
/// activo, la pantalla aparece sin animación.
class HermesPageTransitionsBuilder extends PageTransitionsBuilder {
  const HermesPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (Motion.reduced(context)) return child;
    final curved = CurvedAnimation(
      parent: animation,
      curve: Motion.enter,
      reverseCurve: Motion.exit,
    );
    // La pantalla entrante se desliza desde la derecha (estilo iOS/push) y la
    // saliente se desplaza un poco a la izquierda (parallax). Sin fade: un
    // FadeTransition sobre una ruta a pantalla completa obliga a repintarla
    // en una capa offscreen en cada frame de la transición.
    final outgoing = CurvedAnimation(
      parent: secondaryAnimation,
      curve: Motion.enter,
      reverseCurve: Motion.exit,
    );
    return SlideTransition(
      position: Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(-0.25, 0),
      ).animate(outgoing),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}
