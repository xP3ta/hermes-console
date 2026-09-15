import 'package:flutter/material.dart';

import '../screens/activity_screen.dart';
import '../screens/agent_center_screen.dart';
import '../screens/appearance_screen.dart';
import '../screens/chat_screen.dart';
import '../screens/cron_screen.dart';
import '../screens/extensions_center_screen.dart';
import '../screens/gateway_manager_screen.dart';
import '../screens/memory_screen.dart';
import '../screens/mission_control_screen.dart';
import '../screens/models_screen.dart';
import '../screens/profiles_screen.dart';
import '../screens/projects_center_screen.dart';
import '../screens/soul_screen.dart';
import '../screens/ssh_screen.dart';
import '../screens/session_list_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/voice_settings_screen.dart';
import '../screens/companion/mascotas_screen.dart';
import '../screens/skills_screen.dart';
import '../screens/task_center_screen.dart';
import '../screens/tasks_screen.dart';
import '../screens/tools_hub_screen.dart';
import '../services/connection_manager.dart';
import '../services/tui_gateway_client.dart';
import '../navigation/chat_route.dart';
import '../navigation/instance_route_guard.dart';
import '../theme/app_theme.dart';
import '../../l10n/app_localizations.dart';

/// Top-level app sections reachable from [HermesDrawer].
enum DrawerSection {
  home,
  missionControl,
  voice,
  appearance,
  mascotas,
  sessions,
  // A conversation is below the library, not the library itself.
  chat,
  projects,
  kanban,
  tools,
  gateways,
  models,
  ssh,
  providers,
  profiles,
  agents,
  skills,
  extensions,
  memory,
  soul,
  cron,
  taskCenter,
  activity,
  settings,
}

/// Shared navigation drawer. Used by the top-level screens (home dashboard,
/// session list); deeper screens keep plain back navigation.
///
/// Sections that need a gateway are disabled while [connection] is null.
/// Navigation pops back to the root first so drawer hops never stack
/// section screens on top of each other.
/// Catálogo de destinos de "Herramientas": extraído de [HermesDrawer] como
/// función de nivel superior (en vez de método privado) para que el acceso
/// directo opcional "Herramientas" del dock (ver `dock_shortcuts.dart`)
/// pueda abrir EXACTAMENTE la misma pantalla con los mismos criterios de
/// capacidades, sin duplicar esta lista.
List<HermesToolDestination> buildHermesToolDestinations({
  required BuildContext context,
  required SavedConnection? connection,
  required ConnectionManager connManager,
  required CapabilityMatrix capabilities,
}) {
  final strings = Strings.of(context);
  final conn = connection;

  bool enabled([CapState? capability]) =>
      conn != null && (capability == null || !capability.isNo);

  String? disabledReason([CapState? capability]) {
    if (conn == null) return strings.drawerNeedInstance;
    if (capability?.isNo ?? false) return strings.drawerUnsupported;
    return null;
  }

  return [
    HermesToolDestination(
      id: 'appearance',
      group: strings.drawerPersonalization,
      icon: Icons.palette_outlined,
      label: strings.setSecAppearance,
      enabled: enabled(),
      disabledReason: disabledReason(),
      builder: (_) => AppearanceScreen(connection: conn!),
    ),
    HermesToolDestination(
      id: 'mascotas',
      group: strings.drawerPersonalization,
      icon: Icons.pets_outlined,
      label: strings.drawerMascots,
      enabled: enabled(),
      disabledReason: disabledReason(),
      builder: (_) => const MascotasScreen(),
    ),
    HermesToolDestination(
      id: 'instances',
      group: strings.drawerGroupInstance,
      icon: Icons.router_outlined,
      label: strings.drawerInstances,
      builder: (_) => GatewayManagerScreen(connManager: connManager),
    ),
    HermesToolDestination(
      id: 'models',
      group: strings.drawerGroupInstance,
      icon: Icons.memory_outlined,
      label: strings.drawerModels,
      enabled: enabled(capabilities.modelsRead),
      disabledReason: disabledReason(capabilities.modelsRead),
      builder: (_) => ModelsScreen(connection: conn!),
    ),
    HermesToolDestination(
      id: 'ssh',
      group: strings.drawerGroupInstance,
      icon: Icons.terminal_outlined,
      label: strings.drawerSsh,
      enabled: enabled(),
      disabledReason: disabledReason(),
      builder: (_) => SshScreen(connection: conn!),
    ),
    HermesToolDestination(
      id: 'profiles',
      group: strings.drawerGroupAgent,
      icon: Icons.account_tree_outlined,
      label: strings.drawerProfiles,
      enabled: enabled(),
      disabledReason: disabledReason(),
      builder: (_) =>
          ProfilesScreen(connection: conn!, connManager: connManager),
    ),
    HermesToolDestination(
      id: 'agents',
      group: strings.drawerGroupAgent,
      icon: Icons.smart_toy_outlined,
      label: strings.drawerAgents,
      enabled: enabled(),
      disabledReason: disabledReason(),
      builder: (_) {
        final gateway = TuiGatewayClient(conn!);
        return AgentCenterScreen(
          gateway: gateway,
          readOnly: conn.readOnly,
          disposeGateway: gateway.close,
        );
      },
    ),
    HermesToolDestination(
      id: 'skills',
      group: strings.drawerGroupAgent,
      icon: Icons.extension_outlined,
      label: strings.drawerSkills,
      enabled: enabled(capabilities.skillsRead),
      disabledReason: disabledReason(capabilities.skillsRead),
      builder: (_) => SkillsScreen(connection: conn!),
    ),
    HermesToolDestination(
      id: 'extensions',
      group: strings.drawerGroupAgent,
      icon: Icons.extension_outlined,
      label: strings.drawerExtensions,
      enabled: enabled(),
      disabledReason: disabledReason(),
      builder: (_) {
        final gateway = TuiGatewayClient(conn!);
        return ExtensionsCenterScreen(
          gateway: gateway,
          readOnly: conn.readOnly,
          disposeGateway: gateway.close,
        );
      },
    ),
    HermesToolDestination(
      id: 'memory',
      group: strings.drawerGroupAgent,
      icon: Icons.psychology_outlined,
      label: strings.drawerMemory,
      enabled: enabled(capabilities.memoryRead),
      disabledReason: disabledReason(capabilities.memoryRead),
      builder: (_) => MemoryScreen(connection: conn!),
    ),
    HermesToolDestination(
      id: 'cron',
      group: strings.drawerGroupAgent,
      icon: Icons.schedule_outlined,
      label: strings.drawerCron,
      enabled: enabled(capabilities.cronRead),
      disabledReason: disabledReason(capabilities.cronRead),
      builder: (_) => CronScreen(connection: conn!),
    ),
    HermesToolDestination(
      id: 'soul',
      group: strings.drawerGroupAgent,
      icon: Icons.auto_awesome_outlined,
      label: strings.drawerSoul,
      enabled: enabled(),
      disabledReason: disabledReason(),
      builder: (_) => SoulScreen(connection: conn!),
    ),
    HermesToolDestination(
      id: 'task-center',
      group: strings.drawerGroupSystem,
      icon: Icons.rocket_launch_outlined,
      label: strings.drawerTaskCenter,
      enabled: enabled(),
      disabledReason: disabledReason(),
      builder: (_) => TaskCenterScreen(
        connection: conn!,
        profile: connManager.activeProfileFor(conn.id),
      ),
    ),
    HermesToolDestination(
      id: 'activity',
      group: strings.drawerGroupSystem,
      icon: Icons.receipt_long_outlined,
      label: strings.drawerActivity,
      enabled: enabled(capabilities.logsRead),
      disabledReason: disabledReason(capabilities.logsRead),
      builder: (_) => ActivityScreen(connection: conn!),
    ),
  ];
}

class HermesDrawer extends StatelessWidget {
  /// Añade una banda táctil propia después del borde reservado por Android.
  ///
  /// Con navegación por gestos, [MediaQueryData.systemGestureInsets] contiene
  /// la zona donde Android gana el gesto Atrás. Sumar 48 dp deja una franja
  /// interior fiable para abrir Hermes sin convertir toda la pantalla en
  /// detector horizontal.
  static double edgeDragWidth(BuildContext context) =>
      MediaQuery.systemGestureInsetsOf(context).left + 48;

  final SavedConnection? connection;
  final ConnectionManager connManager;
  final DrawerSection current;
  final bool connected;
  final bool checking;
  final ApiClient Function(SavedConnection connection)?
  recentSessionsClientFactory;

  /// Called after a pushed section screen pops (e.g. to reload settings
  /// that the section may have changed).
  final VoidCallback? onSectionReturn;

  const HermesDrawer({
    required this.connection,
    required this.connManager,
    required this.current,
    this.connected = false,
    this.checking = false,
    this.onSectionReturn,
    this.recentSessionsClientFactory,
    super.key,
  });

  void _go(
    BuildContext context,
    DrawerSection section,
    Widget Function() builder,
  ) {
    Navigator.pop(context); // close drawer
    if (section == current) return;
    final root = Navigator.of(context);
    if (current != DrawerSection.home) root.popUntil((r) => r.isFirst);
    root.push(MaterialPageRoute(builder: (_) => builder())).then((_) {
      onSectionReturn?.call();
    });
  }

  void _goHome(BuildContext context) {
    Navigator.pop(context);
    if (current == DrawerSection.home) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  void _goWithConnection(
    BuildContext context,
    DrawerSection section,
    Widget Function(SavedConnection connection) builder,
  ) {
    final active = InstanceRouteGuard.require(
      context,
      connection: connection,
      onBlocked: () => _showNeedsGateway(context),
    );
    if (active == null) return;
    _go(context, section, () => builder(active));
  }

  void _newChat(BuildContext context) {
    final conn = connection;
    if (conn == null) return;
    Navigator.pop(context);
    final session = Session(
      id: GatewayChatClient.generateSessionId(),
      // Título inicial localizado: 'New Chat' hardcodeado se veía en inglés
      // en recientes/appbar hasta que el servidor renombraba (spec 028 A-028).
      title: Strings.of(context).drawerNewChat,
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 0,
      isActive: true,
      preview: '',
      startedAt: DateTime.now().millisecondsSinceEpoch.toDouble() / 1000,
    );
    openChatWithParent<void>(
      context,
      parentBuilder: (_) =>
          SessionListScreen(connection: conn, connManager: connManager),
      builder: (_) => ChatScreen(connection: conn, session: session),
    );
  }

  Widget _projectsCenter(SavedConnection active) {
    final gateway = TuiGatewayClient(active);
    return ProjectsCenterScreen(
      connection: active,
      connectionManager: connManager,
      gateway: gateway,
      disposeGateway: gateway.close,
    );
  }

  List<HermesToolDestination> _toolDestinations(
    BuildContext context,
    CapabilityMatrix capabilities,
  ) => buildHermesToolDestinations(
    context: context,
    connection: connection,
    connManager: connManager,
    capabilities: capabilities,
  );

  void _openTools(BuildContext context, CapabilityMatrix capabilities) {
    final destinations = _toolDestinations(context, capabilities);
    _go(
      context,
      DrawerSection.tools,
      () => ToolsHubScreen(destinations: destinations),
    );
  }

  Future<void> _selectInstance(BuildContext context, String selectedId) async {
    final navigator = Navigator.of(context);
    final activeId =
        connManager.activeConnectionId.value ?? connection?.id ?? '';
    if (selectedId == activeId) return;
    if (!connManager.getConnections().any((saved) => saved.id == selectedId)) {
      return;
    }

    await connManager.setActiveConnection(selectedId);
    if (!context.mounted) return;
    navigator.pop(); // drawer
    navigator.popUntil((route) => route.isFirst);
  }

  void _showNeedsGateway(BuildContext context) {
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          Strings.of(context).drawerNeedInstance,
          style: const TextStyle(fontSize: 13),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showUnsupported(BuildContext context) {
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          Strings.of(context).drawerUnsupported,
          style: const TextStyle(fontSize: 13),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final conn = connection;
    final hasConn = conn != null;
    final savedConnections = connManager.getConnections();
    final capabilities = hasConn
        ? connManager.loadCapabilities(conn.id)
        : const CapabilityMatrix();

    bool supports(CapState state) => hasConn && !state.isNo;

    return Drawer(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(22)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                key: const ValueKey('drawer-scroll'),
                physics: const ClampingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                padding: const EdgeInsets.only(bottom: 12),
                children: [
                  _DrawerHeader(
                    connectionLabel: conn?.label,
                    connected: connected,
                    checking: checking,
                    connections: savedConnections,
                    activeConnectionId:
                        connManager.activeConnectionId.value ?? conn?.id,
                    onSelected: (id) => _selectInstance(context, id),
                  ),
                  _DrawerItem(
                    icon: Icons.home_outlined,
                    label: strings.drawerHome,
                    selected: current == DrawerSection.home,
                    onTap: () => _goHome(context),
                  ),
                  const SizedBox(height: 2),
                  _DrawerItem(
                    icon: Icons.forum_outlined,
                    label: strings.drawerSessions,
                    selected: current == DrawerSection.sessions,
                    enabled: supports(capabilities.sessionsRead),
                    disabledHint: hasConn
                        ? strings.drawerUnsupported
                        : strings.drawerNeedInstance,
                    onTap: () => !hasConn
                        ? _showNeedsGateway(context)
                        : capabilities.sessionsRead.isNo
                        ? _showUnsupported(context)
                        : _go(
                            context,
                            DrawerSection.sessions,
                            () => SessionListScreen(
                              connection: conn,
                              connManager: connManager,
                            ),
                          ),
                  ),
                  _DrawerItem(
                    icon: Icons.folder_copy_outlined,
                    label: strings.drawerProjects,
                    selected: current == DrawerSection.projects,
                    enabled: hasConn,
                    onTap: () => _goWithConnection(
                      context,
                      DrawerSection.projects,
                      _projectsCenter,
                    ),
                  ),
                  _DrawerItem(
                    icon: Icons.view_kanban_outlined,
                    label: strings.drawerKanban,
                    selected: current == DrawerSection.kanban,
                    enabled: hasConn,
                    onTap: () => hasConn
                        ? _go(
                            context,
                            DrawerSection.kanban,
                            () => TasksScreen(connection: conn),
                          )
                        : _showNeedsGateway(context),
                  ),
                  _DrawerItem(
                    icon: Icons.schedule_outlined,
                    label: strings.drawerCron,
                    selected: current == DrawerSection.cron,
                    enabled: supports(capabilities.cronRead),
                    disabledHint: hasConn
                        ? strings.drawerUnsupported
                        : strings.drawerNeedInstance,
                    onTap: () => !hasConn
                        ? _showNeedsGateway(context)
                        : capabilities.cronRead.isNo
                        ? _showUnsupported(context)
                        : _go(
                            context,
                            DrawerSection.cron,
                            () => CronScreen(connection: conn),
                          ),
                  ),
                  _DrawerItem(
                    icon: Icons.graphic_eq_rounded,
                    label: strings.voiceTitle,
                    selected: current == DrawerSection.voice,
                    enabled: hasConn,
                    onTap: () => _goWithConnection(
                      context,
                      DrawerSection.voice,
                      (active) => VoiceSettingsScreen(connection: active),
                    ),
                  ),
                  _DrawerItem(
                    icon: Icons.hub_outlined,
                    label: 'Bots',
                    selected: current == DrawerSection.missionControl,
                    enabled: hasConn,
                    disabledHint: strings.drawerNeedInstance,
                    onTap: () => !hasConn
                        ? _showNeedsGateway(context)
                        : _go(
                            context,
                            DrawerSection.missionControl,
                            () => MissionControlScreen(
                              connection: conn,
                              connManager: connManager,
                            ),
                          ),
                  ),
                  _DrawerItem(
                    icon: Icons.widgets_outlined,
                    label: strings.drawerTools,
                    selected: current == DrawerSection.tools,
                    onTap: () => _openTools(context, capabilities),
                  ),
                  if (conn != null && supports(capabilities.sessionsRead))
                    _DrawerRecentSessions(
                      connection: conn,
                      profile: connManager.activeProfileFor(conn.id),
                      clientFactory: recentSessionsClientFactory,
                      onOpen: (session) {
                        Navigator.pop(context);
                        openChatWithParent<void>(
                          context,
                          parentBuilder: (_) => SessionListScreen(
                            connection: conn,
                            connManager: connManager,
                          ),
                          builder: (_) =>
                              ChatScreen(connection: conn, session: session),
                        );
                      },
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 6),
                    child: Divider(
                      height: 1,
                      color: colors.divider.withValues(alpha: 0.44),
                    ),
                  ),
                  _DrawerItem(
                    icon: Icons.router_outlined,
                    label: strings.drawerInstances,
                    selected: current == DrawerSection.gateways,
                    onTap: () => _go(
                      context,
                      DrawerSection.gateways,
                      () => GatewayManagerScreen(connManager: connManager),
                    ),
                  ),
                  _DrawerItem(
                    icon: Icons.settings_outlined,
                    label: strings.drawerSettings,
                    selected: current == DrawerSection.settings,
                    enabled: hasConn,
                    onTap: () => _goWithConnection(
                      context,
                      DrawerSection.settings,
                      (active) => SettingsScreen(
                        connection: active,
                        connManager: connManager,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border(
                  top: BorderSide(
                    color: colors.divider.withValues(alpha: 0.52),
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 6, 0, 4),
                child: _NewChatItem(
                  enabled: supports(capabilities.chatSupported),
                  onTap: () => !hasConn
                      ? _showNeedsGateway(context)
                      : capabilities.chatSupported.isNo
                      ? _showUnsupported(context)
                      : _newChat(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerRecentSessions extends StatefulWidget {
  const _DrawerRecentSessions({
    required this.connection,
    required this.profile,
    required this.onOpen,
    this.clientFactory,
  });

  final SavedConnection connection;
  final String profile;
  final ValueChanged<Session> onOpen;
  final ApiClient Function(SavedConnection connection)? clientFactory;

  @override
  State<_DrawerRecentSessions> createState() => _DrawerRecentSessionsState();
}

class _DrawerRecentSessionsState extends State<_DrawerRecentSessions> {
  List<Session> _sessions = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _DrawerRecentSessions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connection.id != widget.connection.id ||
        oldWidget.profile != widget.profile) {
      _sessions = const [];
      _load();
    }
  }

  Future<void> _load() async {
    final requestedConnectionId = widget.connection.id;
    final client =
        widget.clientFactory?.call(widget.connection) ??
        ApiClient(
          baseUrl: widget.connection.baseUrl,
          apiKey: widget.connection.apiKey,
        );
    try {
      final sessions = await client.getSessions(profile: widget.profile);
      sessions.sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
      final visible = sessions
          .where(
            (session) =>
                !session.archived &&
                !session.isJob &&
                !session.isKanbanJob &&
                session.parentSessionId == null,
          )
          .take(4)
          .toList(growable: false);
      if (!mounted || widget.connection.id != requestedConnectionId) return;
      setState(() => _sessions = visible);
    } catch (_) {
      // El drawer sigue siendo navegación local si el servidor está offline o
      // no publica listado de sesiones (p. ej. un runtime local legacy).
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sessions.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).hermes;
    final rawLabel = Strings.of(context).drawerGroupRecent;
    final sectionLabel = rawLabel.isEmpty
        ? rawLabel
        : '${rawLabel[0].toUpperCase()}${rawLabel.substring(1)}';

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 18, 5),
            child: Semantics(
              header: true,
              child: Text(
                sectionLabel,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          for (final session in _sessions)
            Semantics(
              button: true,
              label: session.displayTitle,
              child: InkWell(
                key: ValueKey('drawer-recent-${session.id}'),
                onTap: () => widget.onOpen(session),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        session.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DrawerHeader extends StatelessWidget {
  final String? connectionLabel;
  final bool connected;
  final bool checking;
  final List<SavedConnection> connections;
  final String? activeConnectionId;
  final ValueChanged<String> onSelected;

  const _DrawerHeader({
    required this.connectionLabel,
    required this.connected,
    required this.checking,
    required this.connections,
    required this.activeConnectionId,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final dotColor = checking
        ? colors.warning
        : connected
        ? colors.success
        : colors.textDisabled;
    final statusWord = checking
        ? Strings.of(context).statusChecking
        : connected
        ? 'online'
        : 'offline';
    final canSwitch = connections.isNotEmpty;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return MenuAnchor(
      key: const ValueKey('drawer-instance-menu'),
      animated: !reduceMotion,
      crossAxisUnconstrained: false,
      alignmentOffset: const Offset(-10, 0),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(colors.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(10),
        minimumSize: const WidgetStatePropertyAll(Size(240, 0)),
        maximumSize: const WidgetStatePropertyAll(Size(280, double.infinity)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: colors.divider.withValues(alpha: 0.72)),
          ),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 6),
        ),
      ),
      menuChildren: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
          child: Text(
            Strings.of(context).drawerSwitchInstance,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: colors.textSecondary),
          ),
        ),
        for (final saved in connections)
          MenuItemButton(
            key: ValueKey('drawer-instance-option-${saved.id}'),
            leadingIcon: Icon(
              Icons.dns_outlined,
              size: 20,
              color: saved.id == activeConnectionId
                  ? colors.accent
                  : colors.textSecondary,
            ),
            trailingIcon: saved.id == activeConnectionId
                ? Icon(
                    Icons.check_rounded,
                    size: 20,
                    color: colors.accent,
                    semanticLabel: Strings.of(context).drawerActiveInstance,
                  )
                : const SizedBox(width: 20),
            style: const ButtonStyle(
              minimumSize: WidgetStatePropertyAll(Size(0, 48)),
              padding: WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
            ),
            onPressed: () => onSelected(saved.id),
            child: Text(
              saved.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
      builder: (context, controller, child) => Semantics(
        header: true,
        button: canSwitch,
        hint: canSwitch ? Strings.of(context).drawerSwitchInstance : null,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const ValueKey('drawer-instance-selector'),
            onTap: !canSwitch
                ? null
                : () {
                    if (controller.isOpen) {
                      controller.close();
                    } else {
                      controller.open();
                    }
                  },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 14, 13),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Hermes Console',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: dotColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          connectionLabel == null
                              ? Strings.of(context).drawerNoActiveInstance
                              : '$connectionLabel · $statusWord',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.2,
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                      if (canSwitch) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.expand_more_rounded,
                          size: 18,
                          color: colors.textSecondary,
                        ),
                      ],
                    ],
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

class _NewChatItem extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;

  const _NewChatItem({required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final accent = enabled ? colors.accent : colors.textDisabled;
    return Semantics(
      button: true,
      enabled: enabled,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(11),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 28,
                      child: Icon(Icons.edit_square, size: 20, color: accent),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        Strings.of(context).drawerNewChat,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: enabled
                              ? colors.textPrimary
                              : colors.textDisabled,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool enabled;
  final String? disabledHint;
  final VoidCallback onTap;

  const _DrawerItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.enabled = true,
    this.disabledHint,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final fg = !enabled
        ? colors.textDisabled
        : selected
        ? colors.accentHover
        : colors.textSecondary;
    final textColor = !enabled ? colors.textDisabled : colors.textPrimary;
    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      hint: enabled
          ? null
          : disabledHint ?? Strings.of(context).drawerNeedInstance,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1.5),
        child: Material(
          color: selected
              ? colors.surfaceVariant.withValues(alpha: 0.58)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 28,
                      child: Icon(icon, size: 20, color: fg),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: textColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
