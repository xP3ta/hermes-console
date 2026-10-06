import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart' show HermesAppState;
import '../navigation/chat_route.dart';
import '../screens/chat_screen.dart';
import '../screens/gesture_dock_settings_screen.dart';
import '../screens/projects_center_screen.dart';
import '../screens/session_list_screen.dart';
import '../screens/settings_screen.dart';
import '../services/active_profile_scope.dart';
import '../services/connection_manager.dart';
import '../services/global_activity_aggregate.dart';
import '../services/session_archive.dart';
import '../services/tui_gateway_client.dart';
import '../utils/home_recent_sessions.dart';
import '../utils/session_timestamp.dart';
import '../utils/session_title.dart';
import '../widgets/dock.dart' show DockItemAction, DockItemId;
import '../widgets/dock_shortcuts.dart';
import '../widgets/owned_resource_host.dart';
import 'dock_geometry.dart';
import 'gesture_dock.dart';
import 'gesture_dock_state.dart';
import 'goto_sheet.dart';

/// Wires the [GestureDock] to the app: which screen each tab opens, the
/// shortcuts of each tab, "Ir a" and the "needs you" dot.
///
/// The existing `Dock` mounts this instead of its bar for the General
/// profile while the gesture dock flag is on, so Home and every screen
/// wrapped by `GeneralDockShell` get it without touching those screens.
class GestureDockHost extends StatefulWidget {
  final GestureDockTab? current;

  /// The host screen's dock actions; Inicio, Nuevo and Ajustes reuse them
  /// where they exist (Home's keep its refresh-on-return behaviour).
  final Map<DockItemId, DockItemAction> actions;
  final SavedConnection? connection;
  final ConnectionManager? connManager;
  final VoidCallback? onNewChat;

  const GestureDockHost({
    required this.actions,
    this.current,
    this.connection,
    this.connManager,
    this.onNewChat,
    super.key,
  });

  /// Replaces the recents read in widget tests.
  @visibleForTesting
  static Future<List<GotoRecent>> Function()? debugRecentsLoader;

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

  GlobalActivityAggregate? get _activity => _app?.activeChats.globalActivity;

  bool _needsYou() {
    final activity = _activity;
    if (activity == null) return false;
    return activity.activities.any(
      (a) => a.active && a.requiresAction && !a.stale,
    );
  }

  /// Opens a top-level place: from a place other than Home the stack goes
  /// back to Home first, so tabs never pile up.
  void _goPlace(WidgetBuilder builder) {
    final navigator = Navigator.of(context);
    if (widget.current != GestureDockTab.home) {
      navigator.popUntil((route) => route.isFirst);
    }
    unawaited(navigator.push(MaterialPageRoute<void>(builder: builder)));
  }

  VoidCallback? get _newChat {
    final explicit =
        widget.onNewChat ?? widget.actions[DockItemId.create]?.onTap;
    if (explicit != null) return explicit;
    final conn = _connection;
    if (conn == null) return null;
    return () {
      final session = Session(
        id: GatewayChatClient.generateSessionId(),
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

  VoidCallback? get _openSessions {
    final conn = _connection;
    final manager = _connManager;
    if (conn == null || manager == null) return null;
    return () => openDockSessions(context, conn, manager);
  }

  Map<GestureDockTab, VoidCallback?> _tabs() {
    final conn = _connection;
    final manager = _connManager;
    final current = widget.current;
    VoidCallback? home() {
      if (current == GestureDockTab.home) return null;
      return widget.actions[DockItemId.home]?.onTap ??
          () => Navigator.of(context).popUntil((route) => route.isFirst);
    }

    VoidCallback? projects() {
      if (current == GestureDockTab.projects) return null;
      if (conn == null || manager == null) return null;
      return () => _goPlace(
        (_) => OwnedResourceHost<TuiGatewayClient>(
          create: () => TuiGatewayClient(conn),
          release: (gateway) => gateway.close(),
          builder: (_, gateway) => ProjectsCenterScreen(
            connection: conn,
            connectionManager: manager,
            gateway: gateway,
          ),
        ),
      );
    }

    VoidCallback? settings() {
      if (current == GestureDockTab.settings) return null;
      final own = widget.actions[DockItemId.settings]?.onTap;
      if (current == GestureDockTab.home && own != null) return own;
      if (conn == null || manager == null) return null;
      return () => _goPlace(
        (_) => SettingsScreen(connection: conn, connManager: manager),
      );
    }

    return {
      GestureDockTab.home: home(),
      GestureDockTab.create: _newChat,
      GestureDockTab.projects: projects(),
      GestureDockTab.settings: settings(),
    };
  }

  Map<GestureDockTab, List<DockShortcut>> _shortcuts(Strings s) {
    final conn = _connection;
    final manager = _connManager;
    final newChat = _newChat;
    final sessions = _openSessions;
    final tabs = _tabs();
    void push(Widget screen) => unawaited(
      Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => screen)),
    );
    return {
      GestureDockTab.home: [
        if (sessions != null)
          DockShortcut(
            label: s.gdShortSearch,
            icon: Icons.search_rounded,
            onTap: sessions,
          ),
        if (conn != null && manager != null)
          DockShortcut(
            label: s.gdShortCron,
            icon: Icons.schedule_rounded,
            onTap: () => openDockCron(context, conn, manager),
          ),
      ],
      GestureDockTab.create: [
        if (newChat != null)
          DockShortcut(
            label: s.gdGotoNewChat,
            icon: Icons.add_rounded,
            onTap: newChat,
          ),
        if (sessions != null)
          DockShortcut(
            label: s.gdShortSearch,
            icon: Icons.search_rounded,
            onTap: sessions,
          ),
      ],
      GestureDockTab.projects: [
        if (tabs[GestureDockTab.projects] != null)
          DockShortcut(
            label: s.gdTabProjects,
            icon: Icons.folder_outlined,
            onTap: tabs[GestureDockTab.projects]!,
          ),
        if (conn != null && manager != null)
          DockShortcut(
            label: s.gdShortTasks,
            icon: Icons.checklist_rounded,
            onTap: () => openDockTasks(context, conn, manager),
          ),
      ],
      GestureDockTab.settings: [
        DockShortcut(
          label: s.gdSettingsTitle,
          icon: Icons.dashboard_customize_outlined,
          onTap: () => push(const GestureDockSettingsScreen()),
        ),
        DockShortcut(
          label: s.gdTricksTitle,
          icon: Icons.touch_app_outlined,
          onTap: () => push(const GestureTricksScreen()),
        ),
      ],
    };
  }

  Future<List<GotoRecent>> _loadRecents() async {
    final override = GestureDockHost.debugRecentsLoader;
    if (override != null) return override();
    final conn = _connection;
    final manager = _connManager;
    if (conn == null || manager == null) return const [];
    // Nothing private is read while App Lock is engaged.
    if (_app?.appLock.locked.value == true) return const [];
    final strings = Strings.of(context);
    final profile = ActiveProfileScope.of(manager, conn.id).name;
    final client = ApiClient(
      baseUrl: conn.baseUrl,
      apiKey: conn.apiKey,
      profileDashboard: DashboardClient.lazy(conn),
    );
    SessionListRead? listRead;
    List<Session> read = const [];
    try {
      final archive = await SessionArchive.load(manager.prefs, conn.id);
      listRead = archive.beginListRead();
      bool shown(Session session) =>
          !archive.isSessionArchived(session) &&
          !archive.isSessionDeleted(session) &&
          !archive.isSessionHidden(session) &&
          !archive.isHidden(session.id) &&
          !session.isAutomation &&
          session.listsAsOwnRow;
      final sessions = await client.getSessions(
        profile: profile,
        pageSize: homeSessionPageSize,
        maxPages: 1,
      );
      read = sessions;
      sessions.sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
      return [
        for (final session in sessions.where(shown))
          GotoRecent(
            id: session.id,
            title: localizedSessionTitle(strings, session),
            subtitle: formatSessionRelativeTime(
              session.lastActivityAt,
              strings,
            ),
            onOpen: () => openChatWithParent<void>(
              context,
              parentBuilder: (_) =>
                  SessionListScreen(connection: conn, connManager: manager),
              builder: (_) => ChatScreen(connection: conn, session: session),
            ),
          ),
      ];
    } catch (_) {
      return const [];
    } finally {
      listRead?.end(rows: read);
      client.close();
    }
  }

  void _openGoto() {
    final tabs = _tabs();
    unawaited(
      showGotoSheet(
        context,
        origin: DockGeometry.instance.rect.value,
        actions: GotoSheetActions(
          loadRecents: _loadRecents,
          onNewChat: _newChat,
          onSearchAll: _openSessions,
          current: widget.current,
          places: {
            GestureDockTab.home: tabs[GestureDockTab.home],
            GestureDockTab.projects: tabs[GestureDockTab.projects],
            GestureDockTab.settings: tabs[GestureDockTab.settings],
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    GestureDockController.instance.needsYou = _needsYou;
    return GestureDock(
      current: widget.current,
      onTab: _tabs(),
      shortcuts: _shortcuts(strings),
      onGoto: _openGoto,
      needsYou: _needsYou,
      attention: _activity,
    );
  }
}
