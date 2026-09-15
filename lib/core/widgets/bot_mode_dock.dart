import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/dock_config.dart';
import '../services/dock_preferences_store.dart';
import '../theme/app_theme.dart';
import 'chat_surface_coordinator.dart';
import 'dock_style.dart';

/// Dock flotante del perfil "Bots": Bots/Trabajo + Crear (con las dos
/// órbitas de creación), personalizable desde Ajustes › Dock (orden,
/// visibilidad, destacado, estilo) y con un elemento "Atrás" contextual que
/// aparece al entrar en una subpantalla (ver [showBackContext]).
class BotModeDock extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback? onCreateBot;
  final VoidCallback? onCreateRoom;
  final String? createRoomLabel;
  final ChatSurfaceCoordinator? coordinator;

  /// True cuando hay una subpantalla abierta encima de este dock. Junto con
  /// el ajuste "Mostrar Atrás en subpantallas" del perfil, decide si se
  /// inserta el elemento contextual "Atrás".
  final bool showBackContext;
  final VoidCallback? onBack;

  /// Vuelve al dashboard general ("Inicio"). El perfil Bots incluye "Inicio"
  /// en su catálogo por defecto: sin esta acción, el elemento no tendría
  /// forma de sacar al usuario de Bots (bug confirmado en dispositivo real).
  final VoidCallback? onOpenHome;

  // Accesos directos opcionales del catálogo (ocultos por defecto): solo se
  // pintan con una acción real si el perfil los tiene visibles.
  final VoidCallback? onOpenCron;
  final VoidCallback? onOpenTasks;
  final VoidCallback? onOpenSessions;
  final VoidCallback? onOpenTools;

  const BotModeDock({
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.onCreateBot,
    this.onCreateRoom,
    this.createRoomLabel,
    this.coordinator,
    this.showBackContext = false,
    this.onBack,
    this.onOpenHome,
    this.onOpenCron,
    this.onOpenTasks,
    this.onOpenSessions,
    this.onOpenTools,
    super.key,
  });

  @override
  State<BotModeDock> createState() => _BotModeDockState();
}

class _BotModeDockState extends State<BotModeDock>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  late ChatSurfaceCoordinator _coordinator;
  late bool _ownsCoordinator;
  final FocusNode _createFocus = FocusNode(debugLabel: 'Bot Mode create');
  final FocusNode _botFocus = FocusNode(debugLabel: 'Create bot');
  bool _expanded = false;
  bool _actionsMounted = false;
  int _motionGeneration = 0;
  // Ancla real del "+": se mide el tile ya pintado (no una fórmula de
  // layout aproximada) para que las órbitas de creación arranquen siempre
  // exactamente del "+" tal como quedó dispuesto, sea cual sea su posición
  // en la fila (personalizable por el usuario) o el ancho del dock.
  final GlobalKey _createTileKey = GlobalKey();
  final GlobalKey _stackKey = GlobalKey();

  Duration _duration(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 220);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ownsCoordinator = widget.coordinator == null;
    _coordinator =
        widget.coordinator ??
        ChatSurfaceCoordinator(routeOwner: identityHashCode(this));
    _coordinator.addListener(_onCoordinatorChanged);
    _controller = AnimationController(vsync: this, duration: Duration.zero);
    unawaited(DockPreferencesController.instance.ensureLoaded());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = _duration(context);
    _controller.reverseDuration = _duration(context);
  }

  @override
  void didUpdateWidget(covariant BotModeDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.coordinator, widget.coordinator)) {
      _coordinator.removeListener(_onCoordinatorChanged);
      if (_ownsCoordinator) _coordinator.dispose();
      _ownsCoordinator = widget.coordinator == null;
      _coordinator =
          widget.coordinator ??
          ChatSurfaceCoordinator(routeOwner: identityHashCode(this));
      _coordinator.addListener(_onCoordinatorChanged);
    }
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      unawaited(_close(returnFocus: false));
    }
  }

  void _onCoordinatorChanged() {
    if (!_coordinator.createExpanded && _expanded) {
      unawaited(_close(returnFocus: false, updateCoordinator: false));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _coordinator.handleLifecycle(state);
  }

  Future<void> _open() async {
    if (_expanded) {
      await _close();
      return;
    }
    final generation = ++_motionGeneration;
    _expanded = true;
    _actionsMounted = true;
    _coordinator.openCreate();
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
      _coordinator.claimFocus(_botFocus);
    }
  }

  Future<void> _close({
    bool returnFocus = true,
    bool updateCoordinator = true,
  }) async {
    if (!_expanded && !_actionsMounted) return;
    final generation = ++_motionGeneration;
    _expanded = false;
    if (updateCoordinator) _coordinator.closeCreate();
    if (mounted) setState(() {});
    await _controller.animateTo(
      0,
      duration: _duration(context),
      curve: Curves.easeInCubic,
    );
    if (!mounted || generation != _motionGeneration || _expanded) return;
    setState(() => _actionsMounted = false);
    if (returnFocus) _coordinator.claimFocus(_createFocus);
  }

  void _toggleCreate() {
    if (_expanded) {
      unawaited(_close());
    } else {
      unawaited(_open());
    }
  }

  void _select(int index) {
    unawaited(_close(returnFocus: false));
    if (index != widget.selectedIndex) widget.onDestinationSelected(index);
  }

  void _runCreate(VoidCallback? action) {
    if (action == null) return;
    unawaited(_close(returnFocus: false));
    action();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _coordinator.removeListener(_onCoordinatorChanged);
    if (_ownsCoordinator) _coordinator.dispose();
    _controller.dispose();
    _createFocus.dispose();
    _botFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: DockPreferencesController.instance.listenable,
    builder: (context, _) => _buildWithProfile(
      context,
      DockPreferencesController.instance.value.bots,
    ),
  );

  Widget _buildWithProfile(BuildContext context, DockProfileConfig profile) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final compact = MediaQuery.textScalerOf(context).scale(14) > 17;
    final visual = resolveDockVisual(colors, profile.style);
    final showBack =
        widget.showBackContext &&
        profile.showBackOnSubscreens &&
        widget.onBack != null;
    final slots = resolveDockSlots(
      visibleItems: profile.visibleItemIds,
      pinnedItemId: profile.pinnedItemId,
      showBack: showBack,
    );
    final createIndex = slots.indexOf(DockItemId.create);

    return PopScope(
      canPop: !_expanded,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _expanded) unawaited(_close());
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final dockBottom = _coordinator.bottomInset + visual.lift;
          final barWidth = (constraints.maxWidth - 32).clamp(
            0.0,
            constraints.maxWidth,
          );
          final itemWidth = slots.isEmpty ? 0.0 : barWidth / slots.length;
          final fallbackPlusCenter = Offset(
            createIndex == -1
                ? constraints.maxWidth / 2
                : 16 + itemWidth * (createIndex + 0.5),
            constraints.maxHeight - dockBottom - 24,
          );
          final plusCenter = _resolvePlusCenter(fallbackPlusCenter);
          return Stack(
            key: _stackKey,
            fit: StackFit.expand,
            children: [
              if (_actionsMounted)
                Positioned.fill(
                  child: GestureDetector(
                    key: const ValueKey('bot-mode-create-outside'),
                    behavior: HitTestBehavior.translucent,
                    onTap: _close,
                  ),
                ),
              if (_actionsMounted)
                Positioned.fill(
                  key: const ValueKey('bot-mode-create-actions'),
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) {
                      final botValue = Curves.easeOutCubic.transform(
                        _staggered(_controller.value, 0),
                      );
                      final roomValue = Curves.easeOutCubic.transform(
                        _staggered(_controller.value, 38 / 220),
                      );
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          _positionedOrb(
                            plusCenter: plusCenter,
                            finalCenterY: plusCenter.dy - 132,
                            value: botValue,
                            child: _CreateOrb(
                              controlKey: const ValueKey('bot-mode-create-bot'),
                              label: strings.missionCreateBotLabel,
                              icon: Icons.smart_toy_outlined,
                              enabled: widget.onCreateBot != null,
                              focusNode: _botFocus,
                              progress: botValue,
                              onTap: () => _runCreate(widget.onCreateBot),
                            ),
                          ),
                          _positionedOrb(
                            plusCenter: plusCenter,
                            finalCenterY: plusCenter.dy - 68,
                            value: roomValue,
                            child: _CreateOrb(
                              controlKey: const ValueKey(
                                'bot-mode-create-room',
                              ),
                              label:
                                  widget.createRoomLabel ??
                                  strings.missionCreateRoomLabel,
                              icon: Icons.groups_2_outlined,
                              enabled: widget.onCreateRoom != null,
                              progress: roomValue,
                              onTap: () => _runCreate(widget.onCreateRoom),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              Positioned(
                left: 16,
                right: 16,
                bottom: dockBottom,
                child: DockBar(
                  key: const ValueKey('bot-mode-floating-dock'),
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
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _tileForSlot(
    DockItemId? slot, {
    required double innerRadius,
    required bool compact,
    required Strings strings,
  }) {
    if (slot == null) {
      return DockItemTile(
        controlKey: const ValueKey('bot-mode-dock-back'),
        icon: dockBackIcon,
        label: strings.dockBackLabel,
        innerRadius: innerRadius,
        compact: compact,
        onTap: widget.onBack,
      );
    }
    switch (slot) {
      case DockItemId.bots:
        final visualMeta = dockItemVisual(DockItemId.bots);
        return DockItemTile(
          controlKey: const ValueKey('bot-mode-dock-bots'),
          semanticsKey: const ValueKey('mission-destination-bots'),
          icon: visualMeta.icon,
          selectedIcon: visualMeta.selectedIcon,
          label: dockItemLabel(strings, DockItemId.bots),
          selected: widget.selectedIndex == 0,
          innerRadius: innerRadius,
          compact: compact,
          onTap: () => _select(0),
        );
      case DockItemId.work:
        final visualMeta = dockItemVisual(DockItemId.work);
        return DockItemTile(
          controlKey: const ValueKey('bot-mode-dock-work'),
          semanticsKey: const ValueKey('mission-destination-work'),
          icon: visualMeta.icon,
          selectedIcon: visualMeta.selectedIcon,
          label: dockItemLabel(strings, DockItemId.work),
          selected: widget.selectedIndex == 1,
          innerRadius: innerRadius,
          compact: compact,
          onTap: () => _select(1),
        );
      case DockItemId.create:
        return DockItemTile(
          key: _createTileKey,
          controlKey: const ValueKey('bot-mode-dock-create'),
          icon: Icons.add_rounded,
          label: dockItemLabel(strings, DockItemId.create),
          accent: true,
          toggled: _expanded,
          innerRadius: innerRadius,
          compact: compact,
          focusNode: _createFocus,
          onTap: _toggleCreate,
        );
      case DockItemId.home:
        final visualMeta = dockItemVisual(DockItemId.home);
        return DockItemTile(
          controlKey: const ValueKey('bot-mode-dock-home'),
          icon: visualMeta.icon,
          selectedIcon: visualMeta.selectedIcon,
          label: dockItemLabel(strings, DockItemId.home),
          innerRadius: innerRadius,
          compact: compact,
          onTap: widget.onOpenHome,
        );
      case DockItemId.cron:
        final visualMeta = dockItemVisual(DockItemId.cron);
        return DockItemTile(
          controlKey: const ValueKey('bot-mode-dock-cron'),
          icon: visualMeta.icon,
          selectedIcon: visualMeta.selectedIcon,
          label: dockItemLabel(strings, DockItemId.cron),
          innerRadius: innerRadius,
          compact: compact,
          onTap: widget.onOpenCron,
        );
      case DockItemId.tasks:
        final visualMeta = dockItemVisual(DockItemId.tasks);
        return DockItemTile(
          controlKey: const ValueKey('bot-mode-dock-tasks'),
          icon: visualMeta.icon,
          selectedIcon: visualMeta.selectedIcon,
          label: dockItemLabel(strings, DockItemId.tasks),
          innerRadius: innerRadius,
          compact: compact,
          onTap: widget.onOpenTasks,
        );
      case DockItemId.sessions:
        final visualMeta = dockItemVisual(DockItemId.sessions);
        return DockItemTile(
          controlKey: const ValueKey('bot-mode-dock-sessions'),
          icon: visualMeta.icon,
          selectedIcon: visualMeta.selectedIcon,
          label: dockItemLabel(strings, DockItemId.sessions),
          innerRadius: innerRadius,
          compact: compact,
          onTap: widget.onOpenSessions,
        );
      case DockItemId.tools:
        final visualMeta = dockItemVisual(DockItemId.tools);
        return DockItemTile(
          controlKey: const ValueKey('bot-mode-dock-tools'),
          icon: visualMeta.icon,
          selectedIcon: visualMeta.selectedIcon,
          label: dockItemLabel(strings, DockItemId.tools),
          innerRadius: innerRadius,
          compact: compact,
          onTap: widget.onOpenTools,
        );
      case DockItemId.settings:
        // No forma parte del catálogo del perfil "bots"; si llegara a
        // aparecer (config corrupta o migración futura) se ignora en vez de
        // reventar el layout.
        return const SizedBox.shrink();
    }
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
                      key: ValueKey('bot-mode-create-visible-label'),
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
