import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart' show HermesAppState;
import '../screens/chat_screen.dart';
import '../screens/gesture_dock_settings_screen.dart';
import '../screens/mission_control_screen.dart';
import '../screens/projects_center_screen.dart';
import '../screens/settings_screen.dart';
import '../services/connection_manager.dart';
import '../services/new_session_factory.dart';
import '../services/dock_preferences_store.dart';
import '../services/global_activity_aggregate.dart';
import '../services/tui_gateway_client.dart';
import '../theme/app_theme.dart';
import '../widgets/dock.dart' show DockItemAction, DockItemId, dockRailMargin;
import '../widgets/dock_shortcuts.dart';
import '../widgets/dock_style.dart';
import '../widgets/owned_resource_host.dart';
import 'dock_activity_sheet.dart';
import 'dock_edit_sheet.dart';
import 'dock_mode.dart';
import 'gesture_dock.dart';
import 'gesture_dock_state.dart';

/// Wires the [GestureDock] to the app: where each item goes, the menu of
/// each one, the "Actividad" sheet, the edit mode and the "needs you" dot.
///
/// `Dock` mounts this on every screen that has a dock: the General Home,
/// the Bots home (Mission Control) and every screen wrapped by
/// `GeneralDockShell` show the same dock with the same items. An item goes
/// where it says, from every screen and in both modes:
///
/// | Item         | From General                | From Bots (the Bots home or |
/// |              |                             | a screen opened above it)   |
/// |--------------|-----------------------------|-----------------------------|
/// | Inicio       | the General Home            | the General Home            |
/// | Bots         | the Bots home               | the Bots home               |
/// | Chats        | the conversation list       | the conversation list       |
/// | Proyectos,   | that screen, above the      | that screen, above the Bots |
/// | Ajustes,     | General Home                | home                        |
/// | Herramientas,|                             |                             |
/// | Cron, Tareas |                             |                             |
/// | Nuevo        | a new chat                  | a new chat                  |
/// | Actividad    | its sheet                   | its sheet                   |
///
/// Places never pile up: from a screen that is not a home the stack goes
/// back to the home of the mode first. Only Inicio and Bots change mode.
///
/// On medium and expanded windows (`rail`) the same items, in the same
/// order and with the same icons, form the side rail.
class GestureDockHost extends StatefulWidget {
  final GestureDockTab? current;

  /// The host screen's dock actions; Inicio, Nuevo, Ajustes and the
  /// shortcuts (Cron, Tareas, Sesiones, Herramientas) reuse them where they
  /// exist (Home's keep its refresh-on-return behaviour).
  final Map<DockItemId, DockItemAction> actions;
  final SavedConnection? connection;
  final ConnectionManager? connManager;
  final VoidCallback? onNewChat;

  /// Extra creation shortcuts of "Nuevo" (the Bots home's New profile and
  /// New room).
  final List<DockShortcut> createShortcuts;

  /// Medium/expanded windows: the four tabs as a side rail.
  final bool rail;

  const GestureDockHost({
    required this.actions,
    this.current,
    this.connection,
    this.connManager,
    this.onNewChat,
    this.createShortcuts = const [],
    this.rail = false,
    super.key,
  });

  /// Replaces the app's "Actividad" feed in widget tests.
  @visibleForTesting
  static DockActivityFeed? debugFeed;

  /// Replaces the app's global activity aggregate in widget tests.
  @visibleForTesting
  static GlobalActivityAggregate? debugActivity;

  /// Replaces the screen a place opens (Proyectos, Ajustes, Chats, Cron,
  /// Tareas, Herramientas) and the Bots home, in widget tests.
  @visibleForTesting
  static Widget Function(BuildContext context, GestureDockTab tab)? debugPlace;

  /// Replaces "Nuevo" (a new chat), in widget tests.
  @visibleForTesting
  static VoidCallback? debugNewChat;

  @override
  State<GestureDockHost> createState() => _GestureDockHostState();
}

class _GestureDockHostState extends State<GestureDockHost> {
  HermesAppState? _app;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _app = context.findAncestorStateOfType<HermesAppState>();
  }

  ConnectionManager? get _connManager =>
      widget.connManager ?? _app?.connManager;

  SavedConnection? get _connection {
    final explicit = widget.connection;
    if (explicit != null) return explicit;
    final manager = _connManager;
    final id = manager?.activeConnectionId.value;
    if (manager == null || id == null) return null;
    for (final saved in manager.getConnections()) {
      if (saved.id == id) return saved;
    }
    return null;
  }

  GlobalActivityAggregate? get _activity =>
      GestureDockHost.debugActivity ?? _app?.activeChats.globalActivity;

  bool _needsYou() {
    final activity = _activity;
    if (activity == null) return false;
    return activity.activities.any(
      (a) => a.active && a.requiresAction && !a.stale,
    );
  }

  /// This screen is the General Home (the first route).
  bool get _onGeneralHome => widget.current == GestureDockTab.home;

  /// Pops back to the home of the current mode: the Bots home in Bot Mode,
  /// the first route (General Home) otherwise. Nothing moves on a home.
  void _popToModeHome(NavigatorState navigator) {
    final botsHome = DockModes.instance.botsHome;
    navigator.popUntil(
      (route) => botsHome == null ? route.isFirst : route == botsHome,
    );
  }

  /// Opens a place above the home of the current mode, so places never
  /// pile up.
  void _goPlace(WidgetBuilder builder) {
    final navigator = Navigator.of(context);
    _popToModeHome(navigator);
    unawaited(navigator.push(MaterialPageRoute<void>(builder: builder)));
  }

  /// What [tab] opens, or null when it cannot be opened now (no server).
  WidgetBuilder? _screenOf(GestureDockTab tab) {
    final debug = GestureDockHost.debugPlace;
    if (debug != null) return (context) => debug(context, tab);
    final conn = _connection;
    final manager = _connManager;
    if (manager == null) return null;
    if (tab == GestureDockTab.tools) return dockToolsBuilder(conn, manager);
    if (conn == null) return null;
    return switch (tab) {
      GestureDockTab.projects => (_) => OwnedResourceHost<TuiGatewayClient>(
        create: () => TuiGatewayClient(conn),
        release: (gateway) => gateway.close(),
        builder: (_, gateway) => ProjectsCenterScreen(
          connection: conn,
          connectionManager: manager,
          gateway: gateway,
        ),
      ),
      GestureDockTab.settings => (_) => SettingsScreen(
        connection: conn,
        connManager: manager,
      ),
      GestureDockTab.search => dockSessionsBuilder(conn, manager),
      GestureDockTab.cron => dockCronBuilder(conn, manager),
      GestureDockTab.tasks => dockTasksBuilder(conn, manager),
      GestureDockTab.bots => (_) => MissionControlScreen(
        connection: conn,
        connManager: manager,
      ),
      _ => null,
    };
  }

  /// A place: nothing to do on its own screen; from the General Home, the
  /// action Home declares for it (Home refreshes when it comes back);
  /// from anywhere else, its screen above the home of the current mode.
  VoidCallback? _place(GestureDockTab tab, [DockItemId? id]) {
    if (widget.current == tab) return null;
    if (_onGeneralHome && id != null && widget.actions.containsKey(id)) {
      return widget.actions[id]!.onTap;
    }
    final screen = _screenOf(tab);
    return screen == null ? null : () => _goPlace(screen);
  }

  /// Inicio is the General Home, from every screen and in both modes.
  VoidCallback? get _goHome => _onGeneralHome
      ? null
      : () => Navigator.of(context).popUntil((route) => route.isFirst);

  /// Bots is the Bots home: nothing to do on it, back to it from a screen
  /// opened above it, and from General it opens above the General Home.
  VoidCallback? get _goBots {
    if (widget.current == GestureDockTab.bots) return null;
    if (DockModes.instance.mode == DockMode.bots) {
      return () => _popToModeHome(Navigator.of(context));
    }
    if (_onGeneralHome && widget.actions.containsKey(DockItemId.bots)) {
      return widget.actions[DockItemId.bots]!.onTap;
    }
    final screen = _screenOf(GestureDockTab.bots);
    if (screen == null) return null;
    return () {
      final navigator = Navigator.of(context);
      navigator.popUntil((route) => route.isFirst);
      unawaited(navigator.push(MaterialPageRoute<void>(builder: screen)));
    };
  }

  VoidCallback? get _newChat {
    final explicit =
        GestureDockHost.debugNewChat ??
        widget.onNewChat ??
        widget.actions[DockItemId.create]?.onTap;
    if (explicit != null) return explicit;
    final conn = _connection;
    if (conn == null) return null;
    return () {
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
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ChatScreen(connection: conn, session: session),
          ),
        ),
      );
    };
  }

  Map<GestureDockTab, VoidCallback?> _tabs() => {
    GestureDockTab.home: _goHome,
    GestureDockTab.create: _newChat,
    GestureDockTab.projects: _place(GestureDockTab.projects),
    GestureDockTab.settings: _place(
      GestureDockTab.settings,
      DockItemId.settings,
    ),
    GestureDockTab.bots: _goBots,
    GestureDockTab.search: _place(GestureDockTab.search, DockItemId.sessions),
    GestureDockTab.cron: _place(GestureDockTab.cron, DockItemId.cron),
    GestureDockTab.tasks: _place(GestureDockTab.tasks, DockItemId.tasks),
    GestureDockTab.tools: _place(GestureDockTab.tools, DockItemId.tools),
    GestureDockTab.activity: _openActivity,
  };

  Map<GestureDockTab, List<DockShortcut>> _shortcuts(Strings s) {
    final tabs = _tabs();
    final onBar = GestureDockController.instance.value.tabs;
    final newChat = tabs[GestureDockTab.create];
    final sessions = tabs[GestureDockTab.search];
    final cron = tabs[GestureDockTab.cron];
    final tasks = tabs[GestureDockTab.tasks];
    final tools = tabs[GestureDockTab.tools];
    final projects = tabs[GestureDockTab.projects];
    final bots = tabs[GestureDockTab.bots];
    void push(Widget screen) => unawaited(
      Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => screen)),
    );
    // Every menu also reaches Actividad, the edit mode and "Esconder el
    // dock" (the only way the dock ever leaves the screen; its handle
    // brings it back).
    final common = [
      DockShortcut(
        label: s.gdActivityTitle,
        icon: Icons.bolt_rounded,
        onTap: _openActivity,
      ),
      DockShortcut(
        label: s.gdEditDock,
        icon: Icons.edit_outlined,
        onTap: _openEdit,
      ),
      DockShortcut(
        label: s.gdHideDock,
        icon: Icons.keyboard_arrow_down_rounded,
        onTap: () => GestureDockController.instance.setHidden(true),
      ),
    ];
    final menus = <GestureDockTab, List<DockShortcut>>{
      GestureDockTab.home: [
        // Inicio used to offer "the other home" here. It always is the
        // General Home now and Bots is an item of its own; a layout that
        // leaves Bots off the bar still reaches it from this menu.
        if (bots != null && !onBar.contains(GestureDockTab.bots))
          DockShortcut(
            label: s.missionBotsLabel,
            icon: gestureDockTabIcon(GestureDockTab.bots),
            onTap: bots,
          ),
        if (sessions != null)
          DockShortcut(
            label: s.dockSessionsLabel,
            icon: gestureDockTabIcon(GestureDockTab.search),
            onTap: sessions,
          ),
        if (cron != null)
          DockShortcut(
            label: s.gdShortCron,
            icon: gestureDockTabIcon(GestureDockTab.cron),
            onTap: cron,
          ),
      ],
      GestureDockTab.create: [
        if (newChat != null)
          DockShortcut(
            label: s.gdGotoNewChat,
            icon: Icons.add_rounded,
            onTap: newChat,
          ),
        ...widget.createShortcuts,
        if (sessions != null)
          DockShortcut(
            label: s.dockSessionsLabel,
            icon: gestureDockTabIcon(GestureDockTab.search),
            onTap: sessions,
          ),
      ],
      GestureDockTab.projects: [
        if (projects != null)
          DockShortcut(
            label: s.gdTabProjects,
            icon: Icons.folder_outlined,
            onTap: projects,
          ),
        if (tasks != null)
          DockShortcut(
            label: s.gdShortTasks,
            icon: gestureDockTabIcon(GestureDockTab.tasks),
            onTap: tasks,
          ),
      ],
      GestureDockTab.settings: [
        if (tools != null)
          DockShortcut(
            label: s.drawerTools,
            icon: gestureDockTabIcon(GestureDockTab.tools),
            onTap: tools,
          ),
        DockShortcut(
          label: s.gdSettingsTitle,
          icon: Icons.dashboard_customize_outlined,
          onTap: () => push(const GestureDockSettingsScreen()),
        ),
      ],
    };
    return {
      for (final tab in GestureDockTab.values) tab: [...?menus[tab], ...common],
    };
  }

  void _openActivity() => unawaited(
    showDockActivitySheet(context, feed: GestureDockHost.debugFeed),
  );

  void _openEdit() => unawaited(showDockEditSheet(context));

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // The mode decides which home a place opens above, and the layout
    // which menu entries are needed.
    listenable: Listenable.merge([
      DockModes.instance,
      GestureDockController.instance.settings,
    ]),
    builder: (context, _) {
      final strings = Strings.of(context);
      if (widget.rail) return _buildRail(context, strings);
      return GestureDock(
        current: widget.current,
        onTab: _tabs(),
        shortcuts: _shortcuts(strings),
        onActivity: _openActivity,
        onEdit: _openEdit,
        needsYou: _needsYou,
        attention: _activity,
      );
    },
  );

  /// Medium/expanded windows: the dock's four tabs, in the same order and
  /// with the same icons and labels, as the side rail.
  Widget _buildRail(BuildContext context, Strings strings) {
    final colors = Theme.of(context).hermes;
    final style = DockPreferencesController.instance.value.general.style;
    final visual = resolveDockVisual(colors, style);
    final tabs = _tabs();
    final current = widget.current;
    final layout = GestureDockController.instance.value.tabs;
    final selected =
        current == null || !current.isPlace || !layout.contains(current)
        ? null
        : layout.indexOf(current);
    final bar = DockBar(
      key: const ValueKey('gesture-dock-rail'),
      axis: Axis.vertical,
      style: style,
      selectedIndex: selected,
      children: [
        for (final tab in layout)
          DockItemTile(
            controlKey: ValueKey('gesture-dock-rail-${tab.name}'),
            icon: gestureDockTabIcon(tab),
            selectedIcon: gestureDockTabIcon(tab, selected: true),
            label: gestureDockTabLabel(strings, tab),
            selected: tab.isPlace && current == tab,
            accent: tab == GestureDockTab.create,
            innerRadius: visual.innerRadius,
            compact: true,
            selectionBackground: false,
            onTap: tabs[tab],
          ),
      ],
    );
    final safe = MediaQuery.paddingOf(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          left: safe.left + dockRailMargin,
          top: safe.top + dockRailMargin,
          bottom: safe.bottom + dockRailMargin,
          width: DockBar.railWidth,
          child: Align(
            alignment: Alignment.topCenter,
            child: SingleChildScrollView(child: RepaintBoundary(child: bar)),
          ),
        ),
        _railAttention(safe),
      ],
    );
  }

  /// The amber "needs you" dot on the rail's Inicio (first slot), as on
  /// the bar: only away from Inicio.
  Widget _railAttention(EdgeInsets safe) {
    if (widget.current == GestureDockTab.home) return const SizedBox.shrink();
    final colors = Theme.of(context).hermes;
    Widget dot() => _needsYou()
        ? Container(
            key: const ValueKey('gesture-dock-rail-attention'),
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: colors.warning,
              shape: BoxShape.circle,
              border: Border.all(color: colors.surface, width: 2),
            ),
          )
        : const SizedBox.shrink();
    final source = _activity;
    return Positioned(
      left: safe.left + dockRailMargin + DockBar.railWidth / 2 + 8,
      top: safe.top + dockRailMargin + 12,
      child: IgnorePointer(
        child: source == null
            ? dot()
            : ListenableBuilder(
                listenable: source,
                builder: (context, child) => dot(),
              ),
      ),
    );
  }
}
