import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/dock_config.dart';
import '../services/dock_preferences_store.dart';
import '../theme/app_theme.dart';
import 'chat_surface_coordinator.dart';
import 'dock_style.dart';

// Quien monta el dock necesita siempre estos dos para construir `actions`;
// se reexportan para que no haya que importar el modelo por separado.
export '../models/dock_config.dart' show DockItemId, DockProfileId;

/// Lo que UNA pantalla concreta ofrece para UN elemento del catálogo del dock.
///
/// La presencia de una entrada en el mapa [Dock.actions] es lo que decide si
/// ese elemento existe en esta pantalla; el `onTap` nulo es otra cosa muy
/// distinta (el elemento existe y se pinta, pero ahora mismo está inerte:
/// sección activa, o acción no disponible todavía). Ver [Dock.actions].
@immutable
class DockItemAction {
  /// Acción al tocar. `null` = elemento visible pero inerte (p. ej. el item
  /// de la pantalla en la que ya estamos, o una acción que aún no está
  /// disponible por falta de conexión/capacidad).
  final VoidCallback? onTap;

  /// Marca de "sección activa" (píldora de fondo + icono relleno).
  final bool selected;

  /// Key adicional SOLO para el nodo de semántica del elemento, cuando la
  /// pantalla ya tenía un contrato de accesibilidad propio para ese destino
  /// (Mission Control y sus `mission-destination-*`) que no debe cambiar por
  /// el hecho de que el dock ahora sea un componente compartido.
  final Key? semanticsKey;

  /// Cuando no es null, el tile se envuelve en un [KeyedSubtree] con esta
  /// key, para que quien monta el dock pueda localizar el `RenderBox` del
  /// elemento y anclarle algo encima (ver `showDockAnchoredPopover`: el "+"
  /// contextual de Cron y Tareas abre ahí su popover en vez de navegar).
  final GlobalKey? anchorKey;

  const DockItemAction({
    this.onTap,
    this.selected = false,
    this.semanticsKey,
    this.anchorKey,
  });
}

/// Una de las "órbitas de creación": los botones circulares que salen
/// despegándose del "+" del dock cuando ese "+" abre una bandeja en vez de
/// ejecutar una acción única.
///
/// Es la capa opcional del componente: un dock sin órbitas ([Dock.createOrbits]
/// vacío) usa el `onTap` normal de `DockItemId.create` y no monta nada de la
/// maquinaria de animación/foco/scrim.
@immutable
class DockCreateOrbit {
  final Key controlKey;
  final String label;
  final IconData icon;

  /// `null` = órbita visible pero deshabilitada (sin permisos/capacidad).
  final VoidCallback? onTap;

  const DockCreateOrbit({
    required this.controlKey,
    required this.label,
    required this.icon,
    this.onTap,
  });
}

/// EL dock flotante de la app. Uno solo, para todos los perfiles y todas las
/// pantallas.
///
/// Antes esto eran dos widgets hermanos (`BotModeDock` y `GeneralModeDock`)
/// con un `switch (DockItemId)` propio cada uno decidiendo icono, acción y
/// estado de cada elemento. Los dos switches ya habían divergido (uno excluía
/// `settings`, el otro `work`; uno ponía `semanticsKey`, el otro no) y cada
/// arreglo transversal había que aplicarlo dos veces (le pasó al "Atrás"
/// contextual). Aquí ese switch ya no existe:
///
///  * QUÉ elementos hay y en qué orden lo dice el [DockProfileConfig] del
///    perfil (Ajustes › Dock), igual que antes.
///  * QUÉ icono y qué etiqueta tiene cada elemento lo dice el catálogo
///    compartido (`dockItemVisual`/`dockItemLabel`/`dockItemIsAccent` en
///    `dock_style.dart`), que ya era único.
///  * QUÉ HACE cada elemento aquí y ahora lo dice [actions], que aporta quien
///    monta el dock (Mission Control, `GeneralDockShell`, Inicio). El dock no
///    sabe ni puede saber qué pantallas existen.
///
/// Con eso, este widget es "tonto": pinta lo que le dan. No hay ningún sitio
/// donde dos copias de la misma decisión puedan volver a separarse.
class Dock extends StatefulWidget {
  /// Qué perfil de [DockPreferences] usar. Determina catálogo, orden y estilo
  /// — y también el prefijo estable de las keys de widget
  /// ([DockProfileId.keyPrefix]).
  final DockProfileId profileId;

  /// Qué puede hacer cada elemento del catálogo EN ESTA PANTALLA.
  ///
  /// Un id que no está en el mapa no existe para esta pantalla: ni se pinta
  /// ni ocupa un hueco en la barra (antes cada dock llevaba su propia lista
  /// negra codificada a mano — `settings` en Bots, `work` en General — y
  /// había que acordarse de tocar las dos al añadir un elemento nuevo al
  /// catálogo; ese era el bug A5). Un id presente con `onTap: null` SÍ se
  /// pinta, inerte.
  final Map<DockItemId, DockItemAction> actions;

  /// True cuando esta pantalla es una subpantalla (ver `dockShowsBack`).
  /// Junto con el ajuste del perfil decide si se inserta el "Atrás"
  /// contextual.
  final bool showBackContext;
  final VoidCallback? onBack;

  /// Separación del borde inferior, sin contar el `lift` del estilo. Por
  /// defecto, el inset seguro del sistema + 12. Mission Control pasa aquí el
  /// inset que ya calcula su [ChatSurfaceCoordinator] para el cuerpo de la
  /// pantalla, para que dock y contenido no discrepen.
  final double? bottomInset;

  /// Capa opcional: si no está vacía, el "+" deja de ser una acción única y
  /// pasa a desplegar estas órbitas.
  final List<DockCreateOrbit> createOrbits;

  /// Solo relevante con [createOrbits]: coordina bandeja abierta, foco y
  /// ciclo de vida con el resto de la superficie que aloja el dock.
  final ChatSurfaceCoordinator? coordinator;

  const Dock({
    required this.profileId,
    required this.actions,
    this.showBackContext = false,
    this.onBack,
    this.bottomInset,
    this.createOrbits = const [],
    this.coordinator,
    super.key,
  });

  @override
  State<Dock> createState() => _DockState();
}

class _DockState extends State<Dock>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  ChatSurfaceCoordinator? _coordinator;
  bool _ownsCoordinator = false;
  final FocusNode _createFocus = FocusNode(debugLabel: 'Dock create');
  final FocusNode _firstOrbitFocus = FocusNode(debugLabel: 'Dock create orbit');
  bool _expanded = false;
  bool _actionsMounted = false;
  int _motionGeneration = 0;
  // Ancla real del "+": se mide el tile ya pintado (no una fórmula de
  // layout aproximada) para que las órbitas de creación arranquen siempre
  // exactamente del "+" tal como quedó dispuesto, sea cual sea su posición
  // en la fila (personalizable por el usuario) o el ancho del dock.
  final GlobalKey _createTileKey = GlobalKey();
  final GlobalKey _stackKey = GlobalKey();

  bool get _hasOrbits => widget.createOrbits.isNotEmpty;

  String get _prefix => widget.profileId.keyPrefix;

  Duration _duration(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 220);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: Duration.zero);
    if (_hasOrbits) _attachOrbitMachinery();
    unawaited(DockPreferencesController.instance.ensureLoaded());
  }

  /// Observador de ciclo de vida + coordinador: solo hacen falta con órbitas
  /// (bandeja abierta que debe cerrarse al irse la app a segundo plano y
  /// foco que devolver al "+"). Un dock sin órbitas no monta nada de esto.
  void _attachOrbitMachinery() {
    WidgetsBinding.instance.addObserver(this);
    _ownsCoordinator = widget.coordinator == null;
    _coordinator =
        widget.coordinator ??
        ChatSurfaceCoordinator(routeOwner: identityHashCode(this));
    _coordinator!.addListener(_onCoordinatorChanged);
  }

  void _detachOrbitMachinery() {
    WidgetsBinding.instance.removeObserver(this);
    _coordinator?.removeListener(_onCoordinatorChanged);
    if (_ownsCoordinator) _coordinator?.dispose();
    _coordinator = null;
    _ownsCoordinator = false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = _duration(context);
    _controller.reverseDuration = _duration(context);
  }

  @override
  void didUpdateWidget(covariant Dock oldWidget) {
    super.didUpdateWidget(oldWidget);
    final hadOrbits = oldWidget.createOrbits.isNotEmpty;
    if (hadOrbits != _hasOrbits) {
      if (hadOrbits) {
        _detachOrbitMachinery();
      } else {
        _attachOrbitMachinery();
      }
    } else if (_hasOrbits &&
        !identical(oldWidget.coordinator, widget.coordinator)) {
      _detachOrbitMachinery();
      _attachOrbitMachinery();
    }
    // Cambiar de sección cierra la bandeja de creación. Antes esto se
    // detectaba con un `selectedIndex` propio del dock de Bots; ahora la
    // señal genérica equivalente es "qué elementos dice el contexto que
    // están seleccionados", que vale para cualquier perfil.
    if (_hasOrbits && !setEquals(_selectedIds(oldWidget), _selectedIds(widget))) {
      unawaited(_close(returnFocus: false));
    }
  }

  Set<DockItemId> _selectedIds(Dock dock) => {
    for (final entry in dock.actions.entries)
      if (entry.value.selected) entry.key,
  };

  void _onCoordinatorChanged() {
    final coordinator = _coordinator;
    if (coordinator != null && !coordinator.createExpanded && _expanded) {
      unawaited(_close(returnFocus: false, updateCoordinator: false));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _coordinator?.handleLifecycle(state);
  }

  Future<void> _open() async {
    if (_expanded) {
      await _close();
      return;
    }
    final generation = ++_motionGeneration;
    _expanded = true;
    _actionsMounted = true;
    _coordinator?.openCreate();
    if (_controller.value == 0 && _duration(context) != Duration.zero) {
      // El primer frame pintado ya debe comunicar la salida desde el origen
      // del "+"; los siguientes ticks continúan desde este valor pintado.
      _controller.value = 0.001;
    }
    if (mounted) setState(() {});
    await _controller.animateTo(
      1,
      duration: _duration(context),
      curve: Curves.easeOutCubic,
    );
    if (mounted && _expanded && generation == _motionGeneration) {
      _claimFocus(_firstOrbitFocus);
    }
  }

  Future<void> _close({
    bool returnFocus = true,
    bool updateCoordinator = true,
  }) async {
    if (!_expanded && !_actionsMounted) return;
    final generation = ++_motionGeneration;
    _expanded = false;
    if (updateCoordinator) _coordinator?.closeCreate();
    if (mounted) setState(() {});
    await _controller.animateTo(
      0,
      duration: _duration(context),
      curve: Curves.easeInCubic,
    );
    if (!mounted || generation != _motionGeneration || _expanded) return;
    setState(() => _actionsMounted = false);
    if (returnFocus) _claimFocus(_createFocus);
  }

  /// Sin coordinador (dock montado suelto, p. ej. en tests o en una pantalla
  /// que no gestiona una superficie propia) el foco se pide directamente.
  void _claimFocus(FocusNode node) {
    final coordinator = _coordinator;
    if (coordinator != null) {
      coordinator.claimFocus(node);
    } else {
      node.requestFocus();
    }
  }

  void _toggleCreate() {
    if (_expanded) {
      unawaited(_close());
    } else {
      unawaited(_open());
    }
  }

  /// Toda acción del dock cierra antes la bandeja de creación si estaba
  /// abierta. Antes esto solo pasaba al cambiar de sección y al crear; tocar
  /// "Inicio" o un acceso directo con la bandeja abierta la dejaba colgando
  /// sobre la pantalla siguiente.
  void _run(VoidCallback? action) {
    if (action == null) return;
    if (_hasOrbits) unawaited(_close(returnFocus: false));
    action();
  }

  @override
  void dispose() {
    if (_hasOrbits || _coordinator != null) _detachOrbitMachinery();
    _controller.dispose();
    _createFocus.dispose();
    _firstOrbitFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: DockPreferencesController.instance.listenable,
    builder: (context, _) {
      final prefs = DockPreferencesController.instance.value;
      // Interruptor global "Usar dock flotante" (Ajustes): con él apagado
      // este widget no pinta NADA y no reserva hueco. Vive aquí, en el único
      // dock que hay, así que ninguna pantalla puede saltárselo montando el
      // dock por su cuenta (antes había que repetir esta guarda en los dos
      // widgets de dock y además en `GeneralDockShell`).
      if (!prefs.useDock) return const SizedBox.shrink();
      return _buildWithProfile(context, prefs.profile(widget.profileId));
    },
  );

  Widget _buildWithProfile(BuildContext context, DockProfileConfig profile) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    // El dock real siempre apila icono arriba y etiqueta debajo (ver
    // `DockItemTile.compact` en dock_style.dart): con 4+ items visibles
    // icono+etiqueta EN LÍNEA no cabe y Flutter corta el texto con "..."
    // (confirmado por captura real del dispositivo); apilar en vertical
    // mantiene la etiqueta visible sin ese recorte.
    const compact = true;
    final visual = resolveDockVisual(colors, profile.style);
    final showBack =
        widget.showBackContext &&
        profile.showBackOnSubscreens &&
        widget.onBack != null;
    // Un elemento del catálogo que esta pantalla no ofrece no ocupa hueco en
    // la barra. Antes cada dock llevaba una lista negra propia y codificada a
    // mano (`settings` aquí, `work` allí) que había que mantener sincronizada
    // con el catálogo; ahora la regla es genérica y se deduce de `actions`,
    // así que un elemento nuevo no puede volver a colarse ocupando un hueco
    // vacío en un perfil que no lo implementa (bug A5).
    final visibleItems = [
      for (final id in profile.visibleItemIds)
        if (widget.actions.containsKey(id)) id,
    ];
    final slots = resolveDockSlots(
      visibleItems: visibleItems,
      showBack: showBack,
    );
    final createIndex = slots.indexOf(DockItemId.create);

    final bar = DockBar(
      key: ValueKey('$_prefix-floating-dock'),
      style: profile.style,
      children: [
        for (final slot in slots)
          _tileForSlot(
            slot,
            innerRadius: visual.innerRadius,
            compact: compact,
            strings: strings,
          ),
      ],
    );

    // 20dp, no 16: el margen lateral del dock flotante tiene que calzar con
    // el de Inicio y Bots (`EdgeInsets.fromLTRB(20, ...)` en
    // `home_dashboard_screen.dart` / `mission_control_screen.dart`), que es
    // el contenido con el que comparte pantalla en la práctica. Con 16 el
    // dock se veía 4dp más ancho que el composer/la lista de arriba —
    // suficiente para que las dos superficies flotantes del mismo lenguaje
    // visual (mismo fondo, misma forma de píldora) no calzaran en el mismo
    // borde y se leyeran como dos sistemas sueltos en vez de una sola rejilla.
    const dockSideMargin = 20.0;
    Widget dock = LayoutBuilder(
      builder: (context, constraints) {
        final dockBottom =
            (widget.bottomInset ?? MediaQuery.paddingOf(context).bottom + 12) +
            visual.lift;
        // Solo hace falta medir el "+" cuando hay órbitas en pantalla; un
        // dock sin bandeja no toca las `GlobalKey` en cada build.
        Offset plusCenter() {
          final barWidth = (constraints.maxWidth - dockSideMargin * 2).clamp(
            0.0,
            constraints.maxWidth,
          );
          final itemWidth = slots.isEmpty ? 0.0 : barWidth / slots.length;
          // Se mide AQUÍ, antes de construir el `Stack`, no dentro del
          // `AnimatedBuilder` de las órbitas: al montarse la capa de órbitas
          // cambia la lista de hijos del `Stack`, así que el tile del "+"
          // (que lleva `GlobalKey`) se desactiva y se vuelve a inflar en su
          // nueva posición, y medirlo en ese instante revienta con "Cannot
          // get renderObject of inactive element". Desde fuera se mide el
          // árbol del frame anterior, que es justo lo que hace falta.
          return _resolvePlusCenter(
            Offset(
              createIndex == -1
                  ? constraints.maxWidth / 2
                  : dockSideMargin + itemWidth * (createIndex + 0.5),
              constraints.maxHeight - dockBottom - 24,
            ),
          );
        }

        return Stack(
          key: _stackKey,
          fit: StackFit.expand,
          children: [
            if (_actionsMounted) ..._orbitLayers(plusCenter()),
            Positioned(
              left: dockSideMargin,
              right: dockSideMargin,
              bottom: dockBottom,
              child: bar,
            ),
          ],
        );
      },
    );

    if (_hasOrbits) {
      dock = PopScope(
        canPop: !_expanded,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _expanded) unawaited(_close());
        },
        child: dock,
      );
    }
    // The dock's own bottom offset only accounts for the system safe area
    // (see `dockBottom` above), not the keyboard — Flutter's default
    // keyboard-avoidance instead shrinks the whole body (this widget's
    // parent Stack included), so a focused composer leaves the dock
    // floating just above the IME, detached from both the input above it
    // and the screen edge below it (confirmed live: Inicio's composer).
    // Hiding it while the keyboard is open is the native pattern (most
    // bottom navigation bars do the same) and avoids that orphaned bar
    // rather than trying to keep it pinned somewhere that never looks right.
    //
    // `MediaQuery.viewInsetsOf` reads whatever the nearest `MediaQuery`
    // publishes, and `Scaffold` (with the default `resizeToAvoidBottomInset:
    // true`) republishes a copy with the bottom inset already zeroed for its
    // own `body` — exactly the subtree the dock lives in, since it's a
    // sibling-in-a-Stack of the screen's content rather than outside the
    // Scaffold. Reading straight from the platform view sidesteps that
    // Scaffold-local override and sees the real keyboard height regardless
    // of where in the tree the dock is mounted (confirmed live: the
    // `MediaQuery`-based check never fired on Inicio).
    final keyboardOpen = View.of(context).viewInsets.bottom > 0;
    return IgnorePointer(
      ignoring: keyboardOpen,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        offset: keyboardOpen ? const Offset(0, 1.2) : Offset.zero,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 140),
          opacity: keyboardOpen ? 0 : 1,
          child: dock,
        ),
      ),
    );
  }

  /// Scrim + órbitas. Solo se montan mientras la bandeja está abierta o
  /// cerrándose; un dock sin órbitas nunca llega aquí.
  List<Widget> _orbitLayers(Offset plusCenter) => [
    Positioned.fill(
      child: GestureDetector(
        key: ValueKey('$_prefix-create-outside'),
        behavior: HitTestBehavior.translucent,
        onTap: _close,
      ),
    ),
    Positioned.fill(
      key: ValueKey('$_prefix-create-actions'),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final orbits = widget.createOrbits;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              for (var index = 0; index < orbits.length; index++)
                () {
                  final progress = Curves.easeOutCubic.transform(
                    _staggered(_controller.value, index * 38 / 220),
                  );
                  return _positionedOrb(
                    plusCenter: plusCenter,
                    // La órbita de arriba del todo es la primera de la
                    // lista: se apilan hacia arriba a 64dp de paso desde el
                    // "+".
                    finalCenterY:
                        plusCenter.dy - (68 + 64 * (orbits.length - 1 - index)),
                    value: progress,
                    child: _CreateOrb(
                      controlKey: orbits[index].controlKey,
                      label: orbits[index].label,
                      icon: orbits[index].icon,
                      enabled: orbits[index].onTap != null,
                      focusNode: index == 0 ? _firstOrbitFocus : null,
                      progress: progress,
                      onTap: () => _run(orbits[index].onTap),
                    ),
                  );
                }(),
            ],
          );
        },
      ),
    ),
  ];

  Widget _tileForSlot(
    DockItemId? slot, {
    required double innerRadius,
    required bool compact,
    required Strings strings,
  }) {
    if (slot == null) {
      return DockItemTile(
        controlKey: ValueKey('$_prefix-dock-back'),
        icon: dockBackIcon,
        label: strings.dockBackLabel,
        innerRadius: innerRadius,
        compact: compact,
        onTap: widget.onBack == null ? null : () => _run(widget.onBack),
      );
    }
    // `visibleItems` ya filtró los ids sin entrada, así que esto no debería
    // ocurrir; se deja defensivo en vez de romper el layout.
    final action = widget.actions[slot];
    if (action == null) return const SizedBox.shrink();
    final meta = dockItemVisual(slot);
    // El "+" con bandeja no delega su acción en el contexto: la abre y la
    // cierra este widget, que es quien tiene la animación y el foco.
    final ownsCreateTray = slot == DockItemId.create && _hasOrbits;
    final tile = DockItemTile(
      key: ownsCreateTray ? _createTileKey : null,
      controlKey: ValueKey('$_prefix-dock-${slot.name}'),
      semanticsKey: action.semanticsKey,
      icon: meta.icon,
      selectedIcon: meta.selectedIcon,
      label: dockItemLabel(strings, slot),
      compactLabel: dockItemCompactLabel(strings, slot),
      selected: action.selected,
      accent: dockItemIsAccent(slot),
      toggled: ownsCreateTray ? _expanded : null,
      innerRadius: innerRadius,
      compact: compact,
      focusNode: ownsCreateTray ? _createFocus : null,
      onTap: ownsCreateTray
          ? _toggleCreate
          : (action.onTap == null ? null : () => _run(action.onTap)),
    );
    return action.anchorKey == null
        ? tile
        : KeyedSubtree(key: action.anchorKey, child: tile);
  }

  /// Centro real del tile "Crear" ya pintado, en las coordenadas del propio
  /// `Stack` del dock. Cae a [fallback] (una estimación por fórmula) solo
  /// mientras el tile todavía no se ha pintado ninguna vez, lo que en la
  /// práctica nunca ocurre cuando esto se usa: las órbitas solo aparecen
  /// tras un toque, y para tocar el "+" ya tuvo que pintarse antes.
  Offset _resolvePlusCenter(Offset fallback) {
    final tileBox =
        _createTileKey.currentContext?.findRenderObject() as RenderBox?;
    final stackBox = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (tileBox == null ||
        stackBox == null ||
        !tileBox.attached ||
        !stackBox.attached) {
      return fallback;
    }
    final topLeft = tileBox.localToGlobal(Offset.zero, ancestor: stackBox);
    return Offset(topLeft.dx + tileBox.size.width / 2, fallback.dy);
  }

  Widget _positionedOrb({
    required Offset plusCenter,
    required double finalCenterY,
    required double value,
    required Widget child,
  }) => Positioned(
    left: plusCenter.dx - 24,
    top: finalCenterY - 28 + (plusCenter.dy - finalCenterY) * (1 - value),
    child: child,
  );

  double _staggered(double value, double delay) {
    if (_duration(context) == Duration.zero) return value == 0 ? 0 : 1;
    return ((value - delay) / (1 - delay)).clamp(0, 1);
  }
}

class _CreateOrb extends StatelessWidget {
  final Key controlKey;
  final String label;
  final IconData icon;
  final bool enabled;
  final double progress;
  final FocusNode? focusNode;
  final VoidCallback onTap;

  const _CreateOrb({
    required this.controlKey,
    required this.label,
    required this.icon,
    required this.enabled,
    required this.progress,
    required this.onTap,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Opacity(
      opacity: progress,
      child: Transform.scale(
        scale: 0.18 + (0.82 * progress),
        alignment: const Alignment(-2 / 3, 0),
        child: Semantics(
          button: true,
          enabled: enabled,
          label: label,
          excludeSemantics: true,
          child: Tooltip(
            message: label,
            child: SizedBox(
              width: 144,
              height: 56,
              child: Row(
                children: [
                  Material(
                    color: colors.surface,
                    elevation: 7,
                    shape: const CircleBorder(),
                    child: InkWell(
                      key: controlKey,
                      focusNode: focusNode,
                      customBorder: const CircleBorder(),
                      onTap: enabled ? onTap : null,
                      child: SizedBox.square(
                        dimension: 48,
                        child: Icon(
                          icon,
                          color: enabled
                              ? colors.accentText
                              : colors.textDisabled,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      key: const ValueKey('bot-mode-create-visible-label'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: enabled
                            ? colors.textPrimary
                            : colors.textDisabled,
                        fontSize: 13,
                        height: 1.05,
                        fontWeight: FontWeight.w700,
                        shadows: const [
                          Shadow(color: Colors.black87, blurRadius: 7),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
