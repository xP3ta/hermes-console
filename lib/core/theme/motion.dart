import 'package:flutter/widgets.dart';

/// The motion scale of the app (audit 1.4.0, §3.6): a few durations and
/// curves, taken from the approved mocks (v25, 134, 136 v2-A) and from what
/// already moves well (the pill morph).
///
/// Every new animation takes its duration and curve from here, and passes
/// the duration through [duration] so that «reduce motion» turns it off.
abstract final class HermesMotion {
  /// Fades, an icon swap, a pressed state; also what a sheet or morph does
  /// instead of moving when motion is reduced.
  static const Duration fast = Duration(milliseconds: 120);

  /// A tab or segment change, folding and unfolding (v25 .2 s; 134 .2 s).
  static const Duration base = Duration(milliseconds: 200);

  /// A block of the live turn coming in: a slight slide with a fade.
  static const Duration enter = Duration(milliseconds: 450);

  /// Related turn steps delivered together, inside one display frame.
  static const Duration stagger = Duration(milliseconds: 50);

  /// Navigation between full pages.
  static const Duration page = Duration(milliseconds: 260);

  /// A sheet, the pill morph or the work pane coming in (v25 `.sheet`
  /// .32 s).
  static const Duration sheetOpen = Duration(milliseconds: 300);

  /// The same going out: a little quicker than coming in.
  static const Duration sheetClose = Duration(milliseconds: 260);

  /// A group of rows folding open or closed (height, not a jump): the
  /// subagent group's disclosure.
  static const Duration fold = Duration(milliseconds: 450);

  /// A chevron turning with the disclosure it belongs to.
  static const Duration chevron = Duration(milliseconds: 350);

  /// A small badge popping in once (the «done» dot of a finished subagent).
  static const Duration pop = Duration(milliseconds: 450);

  /// One turn of the ring that says a row is working.
  static const Duration spin = Duration(milliseconds: 850);

  /// One breath of the notch, the pulse of «running».
  static const Duration breath = Duration(milliseconds: 2000);

  /// Voice mode: the dock's cross-fade with the input row and between its
  /// own states.
  static const Duration voiceSwap = Duration(milliseconds: 250);

  /// Voice mode: the capsule's content swap and the live draft's fade.
  static const Duration voiceFade = Duration(milliseconds: 180);

  /// Voice mode: one breath of the thinking halo.
  static const Duration voiceBreath = Duration(milliseconds: 2400);

  /// One frame of the chat's pre-rendered live icons (about 30 fps).
  static const Duration liveIconFrame = Duration(milliseconds: 33);

  /// How long a live icon rests on its last frame before it plays back.
  static const Duration liveIconHold = Duration(milliseconds: 700);

  /// How long the jump-to-prompt arrow stays open after a tap.
  static const Duration promptReveal = Duration(milliseconds: 1200);

  /// Extra time a finger may stay down past the long-press timeout and still
  /// count as a tap for the haptic tick on a control.
  static const Duration tapGrace = Duration(milliseconds: 50);

  /// Pause between two haptic events that come from the app, not a finger.
  static const Duration hapticCooldown = Duration(milliseconds: 400);

  /// How long a load may take before its skeleton shows: a quicker read
  /// lands on the content with no flash of placeholder shapes.
  static const Duration skeletonGrace = Duration(milliseconds: 180);

  /// What comes in: v25's `cubic-bezier(.2, .8, .2, 1)`.
  static const Curve emphasized = Cubic(0.2, 0.8, 0.2, 1);

  /// Everything else; already the curve the app uses most.
  static const Curve standard = Curves.easeOutCubic;

  /// What goes out.
  static const Curve exit = Curves.easeInCubic;

  /// A change of size (folding and unfolding).
  static const Curve size = Curves.easeInOutCubic;

  /// True when the system asks to reduce motion (accessibility, battery).
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// The effective duration: [nominal], or zero when motion is reduced.
  static Duration duration(BuildContext context, Duration nominal) =>
      reduced(context) ? Duration.zero : nominal;
}

/// Catálogo de movimiento de la spec 041, ahora con los valores de
/// [HermesMotion] (una sola fuente). Sigue para el código que ya lo usa; lo
/// nuevo usa [HermesMotion].
class Motion {
  const Motion._();

  /// Cambios de estado pequeños (píldoras de estado, colores) y salidas.
  static const Duration fast = HermesMotion.fast;

  /// Entradas de contenido y listas, y plegado/desplegado.
  static const Duration base = HermesMotion.base;

  /// Transiciones de navegación entre pantallas.
  static const Duration page = HermesMotion.page;

  /// Curva de entrada (aparición de contenido).
  static const Curve enter = HermesMotion.standard;

  /// Curva de salida.
  static const Curve exit = HermesMotion.exit;

  /// Curva de cambio de tamaño (plegado/desplegado).
  static const Curve size = HermesMotion.size;

  /// True si el sistema pide reducir el movimiento (accesibilidad/ahorro).
  static bool reduced(BuildContext context) => HermesMotion.reduced(context);

  /// Duración efectiva: la nominal, o cero si hay que reducir el movimiento.
  static Duration duration(BuildContext context, Duration nominal) =>
      HermesMotion.duration(context, nominal);
}

/// A floating route's enter and exit curves, held for as long as its
/// transition is in the tree.
///
/// A route's `transitionsBuilder` runs on every tick of its animation. A
/// `CurvedAnimation(curve:, reverseCurve:)` created there is a new object on
/// every frame, so it cannot remember which curve the transition was on: a
/// surface closed before it had finished opening (a quick outside tap, Back,
/// a row tapped at once) left the enter curve for the exit curve at the
/// same route value. Half-way in, that is opacity 0.88 → 0.15 in one frame.
/// The one CurvedAnimation kept here stays on the curve it was following,
/// so that close retraces the opening.
class RouteCurves extends StatefulWidget {
  const RouteCurves({
    required this.animation,
    required this.builder,
    this.child,
    super.key,
  });

  /// The route's own (linear) animation.
  final Animation<double> animation;

  /// Builds the transition around [child] from the curved animation.
  final Widget Function(
    BuildContext context,
    Animation<double> curved,
    Widget? child,
  )
  builder;
  final Widget? child;

  @override
  State<RouteCurves> createState() => _RouteCurvesState();
}

class _RouteCurvesState extends State<RouteCurves> {
  late CurvedAnimation _curved = _curve();

  CurvedAnimation _curve() => CurvedAnimation(
    parent: widget.animation,
    curve: Motion.enter,
    reverseCurve: Motion.exit,
  );

  @override
  void didUpdateWidget(RouteCurves oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.animation, widget.animation)) {
      _curved.dispose();
      _curved = _curve();
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _curved, widget.child);
}

/// Keeps a route that is covered by an opaque route off the MediaQuery
/// stream.
///
/// The [Overlay] disables [TickerMode] for routes under an opaque route. Those
/// routes are not painted, but every widget in them that depends on the
/// MediaQuery is still rebuilt (and their layout boundaries laid out again)
/// whenever it changes. While the soft keyboard animates in a chat, Android
/// publishes a new `viewInsets` every frame, so the screens below the chat
/// (Home, Mission Control's Bots tab) rebuilt on every step: about 20 ms of UI
/// thread per frame on a Pixel.
///
/// While covered, this publishes the last MediaQueryData seen while the route
/// was visible. As soon as the route is uncovered (the pop starts, so the
/// TickerMode flips in that same frame) it publishes the live value again, so
/// insets, size and text scale changed meanwhile are applied in the first
/// visible frame.
class CoveredRouteMediaQueryFreeze extends StatefulWidget {
  final Widget child;

  const CoveredRouteMediaQueryFreeze({super.key, required this.child});

  @override
  State<CoveredRouteMediaQueryFreeze> createState() =>
      _CoveredRouteMediaQueryFreezeState();
}

class _CoveredRouteMediaQueryFreezeState
    extends State<CoveredRouteMediaQueryFreeze> {
  MediaQueryData? _visible;

  @override
  Widget build(BuildContext context) {
    final live = MediaQuery.maybeOf(context);
    if (live == null) return widget.child;
    final covered = !TickerMode.valuesOf(context).enabled;
    final data = covered ? (_visible ??= live) : (_visible = live);
    return MediaQuery(data: data, child: widget.child);
  }
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
    child = CoveredRouteMediaQueryFreeze(child: child);
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
