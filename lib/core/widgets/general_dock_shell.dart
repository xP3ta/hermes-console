import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../config/feature_flags.dart';
import '../design/edges.dart';
import '../screens/chat_screen.dart';
import '../screens/mission_control_screen.dart';
import '../screens/app_settings_screen.dart';
import '../services/connection_manager.dart';
import '../services/new_session_factory.dart';
import '../services/dock_preferences_store.dart';
import '../shell/dock_screen.dart';
import '../shell/gesture_dock.dart' show gestureDockFootprint;
import '../shell/gesture_dock_state.dart' show GestureDockTab;
import '../utils/responsive.dart';
import 'dock.dart';
import 'dock_shortcuts.dart';
import 'dock_style.dart' show dockShowsBack;
import 'dock_scroll_clearance.dart';

/// Envuelve el `body` de una pantalla de navegación del perfil "General"
/// (fuera de una conversación abierta) con el mismo dock flotante que ya usa
/// `HomeDashboardScreen`: el componente único [Dock] con el perfil
/// `general`, gestionando por su cuenta el "Atrás" contextual y el mapa de
/// acciones para no duplicar esa lógica en cada pantalla que se sume
/// (Ajustes, lista de sesiones, Cron, Tareas, Agentes).
///
/// Deliberadamente NO se usa dentro de una conversación (`ChatScreen`): ahí
/// ya viven el composer y el pill flotante de subagentes; superponer el
/// dock los taparía/competiría con ellos.
class GeneralDockShell extends StatefulWidget {
  final Widget? body;

  /// Builds scrollable content across the dock's backdrop, reserving
  /// `bottomClearance` inside its scroll padding rather than its viewport.
  /// Plain [body] callers retain their existing protected viewport.
  final Widget Function(BuildContext context, double bottomClearance)?
  bodyBuilder;
  final SavedConnection connection;
  final ConnectionManager connManager;

  /// Acción de "Crear". Si es null, crea una conversación nueva genérica
  /// (mismo comportamiento que Inicio); algunas pantallas (p.ej. la lista de
  /// sesiones) ya tienen su propia creación con refresco de estado y la
  /// pasan aquí en vez de usar el fallback.
  final VoidCallback? onCreate;

  /// Variante contextual de [onCreate]: cuando no es null, tiene prioridad
  /// sobre `onCreate`/el fallback genérico. Recibe la `GlobalKey` ya anclada
  /// al tile "+" del dock (ver [DockItemAction.anchorKey]) para que
  /// quien la use pueda abrir un popover anclado a ese botón (p.ej. crear un
  /// cron job o una tarea directamente ahí) en vez de navegar.
  final void Function(GlobalKey anchorKey)? onCreateAnchored;

  /// False cuando esta pantalla YA ES Ajustes: evita apilar Ajustes sobre
  /// Ajustes al tocar el item "Ajustes" del dock.
  final bool includeSettingsAction;

  /// False cuando esta pantalla YA ES la lista de sesiones (solo aplica si
  /// el usuario activó el acceso opcional "Sesiones" del catálogo).
  final bool includeSessionsAction;

  /// Id del item del catálogo que representa la pantalla que YA ES esta
  /// (Cron/Tareas/Agentes): a diferencia de Ajustes/Sesiones, estos
  /// accesos no tenían forma de desactivarse al estar ya dentro, así que
  /// tocarlos apilaba una copia de la misma pantalla indefinidamente (bug
  /// confirmado: A3). Cuando coincide con un slot, ese item se pinta como
  /// sección activa (`selected: true`) sin acción propia en vez de navegar.
  final DockItemId? currentDestination;

  /// True when the screen lays out its own list-detail panes in an expanded
  /// window: the shell then gives it the full width beside the rail instead
  /// of centring it at [Responsive.maxContentWidth].
  final bool paneLayout;

  /// Gesture dock only: the tab this screen is when neither
  /// [currentDestination] nor the include flags say so (Proyectos).
  final GestureDockTab? gestureTab;

  /// False on the pure configuration screens (Ajustes, Perfiles, Voz, the
  /// Gateway manager): they have the dock, but the floating mascot does not
  /// stand on them.
  final bool pet;

  /// Away from a phone, narrower windows than this get no side rail (and no
  /// dock): the Chats screen on an open Fold, where the list, the chat and
  /// the workspace need the room (mock 134). Null: the rail as always.
  final double? railMinWidth;

  const GeneralDockShell({
    this.body,
    this.bodyBuilder,
    required this.connection,
    required this.connManager,
    this.onCreate,
    this.onCreateAnchored,
    this.includeSettingsAction = true,
    this.includeSessionsAction = true,
    this.currentDestination,
    this.paneLayout = false,
    this.gestureTab,
    this.pet = true,
    this.railMinWidth,
    super.key,
  }) : assert((body == null) != (bodyBuilder == null));

  @override
  State<GeneralDockShell> createState() => _GeneralDockShellState();
}

class _GeneralDockShellState extends State<GeneralDockShell> {
  final GlobalKey _bodyKey = GlobalKey(debugLabel: 'general-dock-body');

  Widget _body(double bottomClearance) => KeyedSubtree(
    key: _bodyKey,
    child: widget.bodyBuilder == null
        ? widget.body!
        : DockScrollClearance(
            bottom:
                !DockPreferencesController.instance.value.useDock ||
                    Responsive.sizeClassOf(context) == WindowSizeClass.compact
                ? bottomClearance
                : null,
            child: Builder(
              builder: (context) =>
                  widget.bodyBuilder!(context, bottomClearance),
            ),
          ),
  );

  // Ver el doc de `dockShowsBack` (dock_style.dart) para el porqué de este
  // criterio frente al RouteAware que usaba la versión anterior.
  bool get _isSubscreen => dockShowsBack(context);

  // Solo se instancia cuando `onCreateAnchored` está presente: el resto de
  // pantallas (Ajustes, Sesiones) no necesitan que el "+" cargue una key.
  final GlobalKey _createAnchorKey = GlobalKey(
    debugLabel: 'general-dock-create-anchor',
  );

  @override
  void initState() {
    super.initState();
    unawaited(DockPreferencesController.instance.ensureLoaded());
    unawaited(FeatureFlags.instance.ensureLoaded());
  }

  void _handleCreate() {
    final anchored = widget.onCreateAnchored;
    if (anchored != null) {
      anchored(_createAnchorKey);
      return;
    }
    (widget.onCreate ?? _defaultCreate)();
  }

  void _defaultCreate() {
    final session = Session(
      id: generateSessionId(),
      title: Strings.of(context).drawerNewChat,
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 0,
      isActive: true,
      preview: '',
      startedAt: DateTime.now().millisecondsSinceEpoch.toDouble() / 1000,
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ChatScreen(connection: widget.connection, session: session),
      ),
    );
  }

  void _openBots() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MissionControlScreen(
          connection: widget.connection,
          connManager: widget.connManager,
        ),
      ),
    );
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AppSettingsScreen(
          connection: widget.connection,
          connManager: widget.connManager,
        ),
      ),
    );
  }

  // Único criterio de "esta pantalla ya soy yo": lo declarado explícitamente
  // (Cron/Tareas/Agentes/Ajustes, vía `currentDestination`) o, si no, lo que ya
  // señalan los flags `include*Action` existentes (Ajustes/Sesiones), para
  // que ambos mecanismos alimenten la misma marca visual de sección activa
  // (ver B3) sin que Ajustes/Sesiones tengan que migrar de flag.
  DockItemId? get _currentDestination {
    final explicit = widget.currentDestination;
    if (explicit != null) return explicit;
    if (!widget.includeSettingsAction) return DockItemId.settings;
    if (!widget.includeSessionsAction) return DockItemId.sessions;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // The route carries the dock even when the bar is switched off below.
    return DockScreen(carriesPet: widget.pet, child: _buildShell(context));
  }

  Widget _buildShell(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        DockPreferencesController.instance.listenable,
        FeatureFlags.instance.gestureDock,
      ]),
      builder: (context, _) {
        // Interruptor global "Usar dock flotante" (Ajustes): cuando está
        // apagado, esta pantalla es simplemente su `body`, sin el `Stack`
        // ni el propio `Dock` de por medio — nada de dock
        // corriendo de fondo, ni un hueco vacío donde solía estar (pedido
        // explícito del usuario). El resto de acciones de la pantalla
        // (FAB nativo, back nativo del `AppBar`, etc.) nunca dependen de
        // este widget, así que la pantalla sigue siendo 100% funcional.
        if (!DockPreferencesController.instance.value.useDock) {
          return _body(0);
        }
        final railMin = widget.railMinWidth;
        if (railMin != null &&
            Responsive.sizeClassOf(context) != WindowSizeClass.compact &&
            MediaQuery.sizeOf(context).width < railMin) {
          return _body(0);
        }
        final current = _currentDestination;
        return Stack(
          fit: StackFit.expand,
          children: [
            _AdaptiveDockBody(
              paneLayout: widget.paneLayout,
              gestureDock: FeatureFlags.instance.gestureDock.value,
              body: _body,
              contentBehindDock: widget.bodyBuilder != null,
            ),
            Dock(
              profileId: DockProfileId.general,
              adaptive: true,
              gestureTab: widget.gestureTab,
              connection: widget.connection,
              connManager: widget.connManager,
              onNewChat: _defaultCreate,
              showBackContext: _isSubscreen,
              onBack: () => Navigator.of(context).maybePop(),
              // Qué sabe hacer el perfil "General" desde una pantalla
              // envuelta por este shell. Un id ausente de este mapa
              // sencillamente no existe aquí y ni se pinta ni ocupa hueco
              // (`work`, que no tiene destino propio fuera de Bots); un id
              // presente con `onTap: null` se pinta inerte (la pantalla en
              // la que ya estamos).
              actions: {
                DockItemId.home: DockItemAction(
                  onTap: () => Navigator.of(context).popUntil((r) => r.isFirst),
                ),
                DockItemId.create: DockItemAction(
                  onTap: _handleCreate,
                  anchorKey: widget.onCreateAnchored != null
                      ? _createAnchorKey
                      : null,
                ),
                DockItemId.bots: DockItemAction(onTap: _openBots),
                DockItemId.settings: DockItemAction(
                  onTap:
                      widget.includeSettingsAction &&
                          current != DockItemId.settings
                      ? _openSettings
                      : null,
                  selected: current == DockItemId.settings,
                ),
                DockItemId.cron: DockItemAction(
                  onTap: current == DockItemId.cron
                      ? null
                      : () => openDockCron(
                          context,
                          widget.connection,
                          widget.connManager,
                        ),
                  selected: current == DockItemId.cron,
                ),
                DockItemId.tasks: DockItemAction(
                  onTap: current == DockItemId.tasks
                      ? null
                      : () => openDockTasks(
                          context,
                          widget.connection,
                          widget.connManager,
                        ),
                  selected: current == DockItemId.tasks,
                ),
                DockItemId.sessions: DockItemAction(
                  onTap: widget.includeSessionsAction
                      ? () => openDockSessions(
                          context,
                          widget.connection,
                          widget.connManager,
                        )
                      : null,
                  selected: current == DockItemId.sessions,
                ),
                DockItemId.agents: DockItemAction(
                  onTap: current == DockItemId.agents
                      ? null
                      : () => openDockAgents(
                          context,
                          widget.connection,
                          widget.connManager,
                        ),
                  selected: current == DockItemId.agents,
                ),
              },
            ),
          ],
        );
      },
    );
  }
}

/// Places the body beside the dock in whichever form the window size class
/// gives it. Size-only dependencies (`Responsive`, `MediaQuery.*Of`): a
/// keyboard animation never rebuilds this (see #141).
class _AdaptiveDockBody extends StatelessWidget {
  final bool paneLayout;
  final bool gestureDock;
  final Widget Function(double bottomClearance) body;
  final bool contentBehindDock;

  const _AdaptiveDockBody({
    required this.paneLayout,
    required this.body,
    this.gestureDock = false,
    this.contentBehindDock = false,
  });

  @override
  Widget build(BuildContext context) {
    final sizeClass = Responsive.sizeClassOf(context);
    if (sizeClass == WindowSizeClass.compact) {
      final clearance = gestureDock
          ? gestureDockFootprint(context)
          : dockFootprint(context);
      final content = Stack(
        fit: StackFit.expand,
        children: [
          HermesOpenTopClip(child: body(contentBehindDock ? clearance : 0)),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: HermesBottomFade(key: ValueKey('dock-body-fade')),
          ),
        ],
      );
      // A builder keeps the last row above the bar with its own scroll
      // padding, while the viewport paints real content under the glass.
      // Legacy bodies keep their protected viewport. The system inset is
      // already in clearance and is never added a second time by SafeArea.
      return MediaQuery.removePadding(
        context: context,
        removeBottom: true,
        child: contentBehindDock
            ? content
            : Padding(
                padding: EdgeInsets.only(bottom: clearance),
                child: content,
              ),
      );
    }
    // Rail on the leading edge: the body starts after it. Single-pane
    // screens are centred at a readable width; a pane screen in an
    // expanded window lays out its own panes across the rest.
    final constrained = !(paneLayout && sizeClass == WindowSizeClass.expanded);
    return MediaQuery.removePadding(
      context: context,
      removeLeft: true,
      child: Padding(
        padding: EdgeInsets.only(left: dockRailFootprint(context)),
        child: constrained
            ? Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: Responsive.maxContentWidth,
                  ),
                  child: body(0),
                ),
              )
            : body(0),
      ),
    );
  }
}
