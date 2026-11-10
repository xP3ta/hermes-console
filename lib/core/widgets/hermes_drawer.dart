import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bots/ui/profile/profile_hub_screen.dart';
import '../capabilities/capabilities_screen.dart';
import '../capabilities/las_chat.dart';
import '../screens/app_settings_screen.dart';
import '../screens/artifacts_screen.dart';
import '../screens/chat_screen.dart';
import '../screens/cron_screen.dart';
import '../screens/gateway_manager_screen.dart';
import '../screens/herdr_agents_screen.dart';
import '../screens/mission_control_screen.dart';
import '../screens/profiles_screen.dart';
import '../screens/projects_center_screen.dart';
import '../screens/session_list_screen.dart';
import '../screens/voice_settings_screen.dart';
import '../screens/tasks_screen.dart';
import '../services/active_profile_scope.dart';
import '../services/connection_manager.dart';
import '../services/connection_status.dart';
import '../services/new_session_factory.dart';
import '../services/session_archive.dart';
import '../services/tui_gateway_client.dart';
import '../navigation/chat_route.dart';
import '../navigation/instance_route_guard.dart';
import '../design/glass_strip.dart';
import '../design/tokens.dart' show HermesRadius;
import '../theme/app_theme.dart';
import '../utils/home_recent_sessions.dart';
import '../utils/session_timestamp.dart';
import '../utils/session_title.dart';
import '../../l10n/app_localizations.dart';
import '../config/feature_flags.dart';
import 'instance_kind_picker.dart';
import 'menu_back_guard.dart';
import 'mission_profile_avatar.dart';
import 'owned_resource_host.dart';
import 'profile_switcher.dart';
import '../feedback/feedback_policy.dart';
import 'seasonal_mark.dart';

/// Top-level app sections reachable from [HermesDrawer].
enum DrawerSection {
  home,
  missionControl,
  voice,
  appearance,
  mascotas,
  sessions,
  artifacts,
  // A conversation is below the library, not the library itself.
  chat,
  projects,
  kanban,
  profileHub,
  gateways,
  models,
  ssh,
  providers,
  profiles,
  agents,
  capabilities,
  memory,
  soul,
  cron,
  taskCenter,
  activity,
  settings,
}

/// The Extensions screen (Skills · Plugins · MCP) for [connection], shared by
/// the profile hub, the chat `/skills` command and Mission Control so every
/// entry opens the same screen with the same options.
///
/// [initialTab] picks the tab; the legacy [initialSegment] still redirects to
/// the right one. [profileOverride] fixes the profile (a profile's own hub);
/// without it the active profile of the connection is used.
CapabilitiesHub buildCapabilitiesHub({
  required SavedConnection connection,
  required ConnectionManager connManager,
  // Unused since the bridge-only classic skills screen was retired; kept so
  // the call sites do not change in this cleanup.
  required CapabilityMatrix capabilities,
  String? profileOverride,
  ExtensionsTab? initialTab,
  CapabilitiesSegment initialSegment = CapabilitiesSegment.installed,
  String runtimeSessionId = '',
}) {
  final fixedProfile = profileOverride?.trim();
  final scoped = fixedProfile != null && fixedProfile.isNotEmpty;
  final profile = scoped
      ? fixedProfile
      : connManager.activeProfileFor(connection.id);
  return CapabilitiesHub(
    initialTab: initialTab,
    initialSegment: initialSegment,
    connection: connection,
    profile: profile,
    learnLauncher: lasChatFor(connection, profile),
    runtimeSessionId: runtimeSessionId,
  );
}

/// Shared navigation drawer. Used by the top-level screens (home dashboard,
/// session list); deeper screens keep plain back navigation.
///
/// Sections that need a gateway are disabled while [connection] is null.
/// Navigation pops back to the root first so drawer hops never stack
/// section screens on top of each other.
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

  /// The chat-lane socket's status; names the state when it is not connected.
  final ConnectionStatusKind? link;
  final ApiClient Function(SavedConnection connection)?
  recentSessionsClientFactory;

  /// Called after a pushed section screen pops (e.g. to reload settings
  /// that the section may have changed).
  final VoidCallback? onSectionReturn;

  /// Builds the gateway client owned by a drawer section screen.
  final TuiGatewayClient Function(SavedConnection connection) gatewayFactory;

  /// Reads a profile's custom avatar for the profile faces (tests).
  final MissionAvatarLoader? profileAvatarLoader;

  /// App Lock state for the profile faces (tests); defaults to the app's.
  final ValueListenable<bool>? profileFacesLocked;

  const HermesDrawer({
    this.profileAvatarLoader,
    this.profileFacesLocked,
    required this.connection,
    required this.connManager,
    required this.current,
    this.connected = false,
    this.checking = false,
    this.link,
    this.onSectionReturn,
    this.recentSessionsClientFactory,
    this.gatewayFactory = TuiGatewayClient.new,
    super.key,
  });

  void _go(
    BuildContext context,
    DrawerSection section,
    Widget Function() builder,
  ) {
    Navigator.pop(context); // close drawer
    if (section == current) return;
    // The root navigator, not the nearest one: inside a tablet detail pane the
    // nearest navigator is the pane's, and a section pushed there nests a whole
    // second screen (app bar, rail, drawer) inside the first.
    final root = Navigator.of(context, rootNavigator: true);
    if (current != DrawerSection.home) root.popUntil((r) => r.isFirst);
    root.push(MaterialPageRoute(builder: (_) => builder())).then((_) {
      onSectionReturn?.call();
    });
  }

  void _goHome(BuildContext context) {
    Navigator.pop(context);
    if (current == DrawerSection.home) return;
    Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
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
      id: generateSessionId(),
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

  Widget _projectsCenter(SavedConnection active) =>
      OwnedResourceHost<TuiGatewayClient>(
        create: () => gatewayFactory(active),
        release: (gateway) => gateway.close(),
        builder: (_, gateway) => ProjectsCenterScreen(
          connection: active,
          connectionManager: connManager,
          gateway: gateway,
        ),
      );

  /// The active profile's page: what is of that bot in one place.
  Widget _profileHub(SavedConnection active) {
    final name = connManager.activeProfileFor(active.id).trim();
    return ProfileHubScreen(
      connection: active,
      connManager: connManager,
      profile: name.isEmpty ? 'default' : name,
    );
  }

  Future<void> _selectInstance(BuildContext context, String selectedId) async {
    final drawer = Navigator.of(context);
    final navigator = Navigator.of(context, rootNavigator: true);
    final activeId =
        connManager.activeConnectionId.value ?? connection?.id ?? '';
    if (selectedId == activeId) return;
    if (!connManager.getConnections().any((saved) => saved.id == selectedId)) {
      return;
    }

    await connManager.setActiveConnection(selectedId);
    if (!context.mounted) return;
    drawer.pop(); // drawer
    navigator.popUntil((route) => route.isFirst);
  }

  void _showNeedsGateway(BuildContext context) {
    Navigator.pop(context);
    AppFeedback.of(context).notify(
      FeedbackKind.error,
      Strings.of(context).drawerNeedInstance,
      warning: true,
      duration: const Duration(seconds: 2),
    );
  }

  void _showUnsupported(BuildContext context) {
    Navigator.pop(context);
    AppFeedback.of(context).notify(
      FeedbackKind.error,
      Strings.of(context).drawerUnsupported,
      warning: true,
      duration: const Duration(seconds: 3),
    );
  }

  /// The selected row's tint, under the ink of the row (see [_DrawerItem]).
  static Color _selectedTint(HermesThemeColors colors) =>
      colors.surfaceVariant.withValues(alpha: 0.58);

  /// The drawer is real glass (the smoked tone of a text-heavy panel, one
  /// blur) where its inks read on it, for every ink of the panel and the
  /// selected row; otherwise, and without blur, the opaque surface of
  /// before.
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final tint = _selectedTint(colors);
    return HermesGlassPanel(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(
          right: Radius.circular(HermesRadius.card),
        ),
      ),
      fallbackFill: colors.surface,
      overs: [(colors.textPrimary, tint), (colors.accentHover, tint)],
      builder: (context, fill, glass) => _buildDrawer(context, fill, glass),
    );
  }

  Widget _buildDrawer(BuildContext context, Color fill, bool glass) {
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
      backgroundColor: fill,
      surfaceTintColor: Colors.transparent,
      elevation: glass ? 0 : 12,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(
          right: Radius.circular(HermesRadius.card),
        ),
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
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  _DrawerHeader(
                    connectionLabel: conn?.label,
                    connected: connected,
                    checking: checking,
                    link: link,
                    connections: savedConnections,
                    activeConnectionId:
                        connManager.activeConnectionId.value ?? conn?.id,
                    onSelected: (id) => _selectInstance(context, id),
                  ),
                  // Active profile, one tap from the drawer (Desktop rail).
                  if (conn != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: ProfileSwitcherButton(
                        connection: conn,
                        connManager: connManager,
                        avatarLoader: profileAvatarLoader,
                        facesLocked: profileFacesLocked,
                        onManage: () => _go(
                          context,
                          DrawerSection.profiles,
                          () => ProfilesScreen(
                            connection: conn,
                            connManager: connManager,
                          ),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
                    child: Divider(
                      height: 1,
                      color: colors.divider.withValues(alpha: 0.44),
                    ),
                  ),
                  // Antes vivía anclado al fondo del drawer. La maqueta aprobada
                  // lo pone como primera fila de la lista, justo bajo la
                  // cabecera: sigue siendo lo primero que se ve al abrir el
                  // drawer, sin necesitar una franja fija aparte.
                  _NewChatItem(
                    enabled: supports(capabilities.chatSupported),
                    onTap: () => !hasConn
                        ? _showNeedsGateway(context)
                        : capabilities.chatSupported.isNo
                        ? _showUnsupported(context)
                        : _newChat(context),
                  ),
                  _DrawerItem(
                    icon: Icons.home_outlined,
                    label: strings.drawerHome,
                    selected: current == DrawerSection.home,
                    onTap: () => _goHome(context),
                  ),
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
                  _DrawerSectionLabel(strings.drawerSectionWork),
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
                            () => TasksScreen(
                              connection: conn,
                              connManager: connManager,
                            ),
                          )
                        : _showNeedsGateway(context),
                  ),
                  // Desktop's sidebar «Artefactos» («Explora salidas
                  // generadas»): what the recent conversations produced.
                  _DrawerItem(
                    key: const ValueKey('drawer-artifacts'),
                    icon: Icons.view_in_ar_outlined,
                    label: strings.chaArtifactsAction,
                    detail: strings.artGlobalDetail,
                    selected: current == DrawerSection.artifacts,
                    enabled: supports(capabilities.sessionsRead),
                    disabledHint: hasConn
                        ? strings.drawerUnsupported
                        : strings.drawerNeedInstance,
                    onTap: () => !hasConn
                        ? _showNeedsGateway(context)
                        : capabilities.sessionsRead.isNo
                        ? _showUnsupported(context)
                        : _goWithConnection(
                            context,
                            DrawerSection.artifacts,
                            (active) => ArtifactsScreen(connection: active),
                          ),
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
                            () => CronScreen(
                              connection: conn,
                              connManager: connManager,
                            ),
                          ),
                  ),
                  _DrawerSectionLabel(strings.drawerSectionAgents),
                  _DrawerItem(
                    icon: Icons.hub_outlined,
                    label: strings.missionBotsLabel,
                    selected: current == DrawerSection.missionControl,
                    enabled: hasConn,
                    disabledHint: strings.drawerNeedInstance,
                    // `connected` es la misma señal de salud de gateway que ya
                    // muestra la cabecera; no es un estado por-bot, pero es la
                    // mejor aproximación disponible sin datos nuevos.
                    trailing: hasConn && connected
                        ? _StatusDot(color: colors.success)
                        : null,
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
                  // Herdr's agents on the SSH servers: a section of its own,
                  // not tied to a chat (it reads its servers itself).
                  if (FeatureFlags.instance.agentsSection)
                    _DrawerItem(
                      key: const ValueKey('drawer-agents'),
                      icon: Icons.smart_toy_outlined,
                      label: strings.hdaTitle,
                      selected: current == DrawerSection.agents,
                      enabled: hasConn,
                      disabledHint: strings.drawerNeedInstance,
                      onTap: () => !hasConn
                          ? _showNeedsGateway(context)
                          : _go(
                              context,
                              DrawerSection.agents,
                              () => const AgentsHomeScreen(),
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
                  // «Herramientas» was split: what is of the app and the server
                  // is in Ajustes, what is of a bot is in its profile. The
                  // drawer opens the active profile's.
                  _DrawerItem(
                    key: const ValueKey('drawer-profile'),
                    icon: Icons.account_circle_outlined,
                    label: strings.botProfileProfileSection,
                    selected: current == DrawerSection.profileHub,
                    enabled: hasConn,
                    trailing: Icon(
                      Icons.chevron_right_rounded,
                      size: 19,
                      color: colors.textDisabled,
                    ),
                    onTap: () => _goWithConnection(
                      context,
                      DrawerSection.profileHub,
                      _profileHub,
                    ),
                  ),
                  if (conn != null && supports(capabilities.sessionsRead))
                    // Recents follow the active profile, even when it is
                    // switched while the drawer is open.
                    ListenableBuilder(
                      listenable: ActiveProfileScope.of(connManager, conn.id),
                      builder: (context, _) => _DrawerRecentSessions(
                        connection: conn,
                        prefs: connManager.prefs,
                        profile: ActiveProfileScope.of(
                          connManager,
                          conn.id,
                        ).name,
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
                    ),
                ],
              ),
            ),
            // Instancias/Ajustes fijos abajo: con las secciones nuevas
            // (Trabajo/Agentes/Recientes) la lista ya no cabe entera en una
            // pantalla de teléfono y estos dos quedaban fuera de la vista
            // inicial, requiriendo scroll para llegar a ellos — se reportó
            // como un problema real tras probar el rediseño en el Pixel.
            DecoratedBox(
              decoration: BoxDecoration(
                color: glass ? Colors.transparent : colors.surface,
                border: Border(
                  top: BorderSide(
                    color: colors.divider.withValues(alpha: 0.44),
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: _DrawerItem(
                        icon: Icons.router_outlined,
                        label: strings.drawerInstances,
                        selected: current == DrawerSection.gateways,
                        dense: true,
                        onTap: () => _go(
                          context,
                          DrawerSection.gateways,
                          () => GatewayManagerScreen(connManager: connManager),
                        ),
                      ),
                    ),
                    Expanded(
                      child: _DrawerItem(
                        icon: Icons.settings_outlined,
                        label: strings.drawerSettings,
                        selected: current == DrawerSection.settings,
                        dense: true,
                        onTap: () => _go(
                          context,
                          DrawerSection.settings,
                          () => AppSettingsScreen(
                            connection: conn,
                            connManager: connManager,
                          ),
                        ),
                      ),
                    ),
                  ],
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
    required this.prefs,
    required this.profile,
    required this.onOpen,
    this.clientFactory,
  });

  final SavedConnection connection;
  final SharedPreferences prefs;
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
    final requestedProfile = widget.profile;
    final client =
        widget.clientFactory?.call(widget.connection) ??
        ApiClient(
          baseUrl: widget.connection.baseUrl,
          apiKey: widget.connection.apiKey,
          // A named profile's list comes from the Dashboard, as on Desktop.
          profileDashboard: DashboardClient.lazy(widget.connection),
        );
    SessionListRead? listRead;
    List<Session> read = const [];
    try {
      // Local-only archives (servers without a writable archived flag) must
      // leave the drawer too, as they leave Conversations.
      final archive = await SessionArchive.load(
        widget.prefs,
        requestedConnectionId,
      );
      // A delete recorded while this page is in flight keeps its tombstone
      // until the page has been filtered and stored.
      listRead = archive.beginListRead();
      bool shown(Session session) =>
          !archive.isSessionArchived(session) &&
          !archive.isSessionDeleted(session) &&
          !archive.isSessionHidden(session) &&
          !archive.isHidden(session.id) &&
          !session.isAutomation &&
          session.listsAsOwnRow;
      // Four rows need one Desktop-sized page, not the whole history.
      final sessions = await client.getSessions(
        profile: widget.profile,
        pageSize: homeSessionPageSize,
        maxPages: homeSessionMaxPages,
        enough: (rows) => rows.where(shown).length >= 4,
      );
      read = sessions;
      sessions.sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
      final visible = sessions.where(shown).take(4).toList(growable: false);
      // Only a read for the current connection and profile paints: a list
      // of the previous profile must never land after a switch.
      if (!mounted ||
          widget.connection.id != requestedConnectionId ||
          widget.profile != requestedProfile) {
        return;
      }
      setState(() => _sessions = visible);
    } catch (_) {
      // El drawer sigue siendo navegación local si el servidor está offline o
      // no publica listado de sesiones (p. ej. un runtime local legacy).
    } finally {
      listRead?.end(rows: read);
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sessions.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DrawerSectionLabel(strings.drawerGroupRecent),
        for (final session in _sessions)
          Semantics(
            button: true,
            label: localizedSessionTitle(strings, session),
            child: InkWell(
              key: ValueKey('drawer-recent-${session.id}'),
              onTap: () => widget.onOpen(session),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      // Solo `isActive` viene en el listado plano de
                      // sesiones — no hay aquí una señal live de "esperando
                      // aprobación" como en la maqueta (eso vive en el
                      // stream de actividad de cada chat, no en este
                      // endpoint). Sesión inactiva: sin punto, no uno gris.
                      SizedBox(
                        width: 7,
                        child: session.isActive
                            ? _StatusDot(color: colors.success)
                            : null,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          localizedSessionTitle(strings, session),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatSessionRelativeTime(
                          session.lastActivityAt,
                          strings,
                        ),
                        style: TextStyle(
                          color: colors.textTertiary,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _DrawerHeader extends StatelessWidget {
  final String? connectionLabel;
  final bool connected;
  final bool checking;
  final ConnectionStatusKind? link;
  final List<SavedConnection> connections;
  final String? activeConnectionId;
  final ValueChanged<String> onSelected;

  const _DrawerHeader({
    required this.connectionLabel,
    required this.connected,
    required this.checking,
    this.link,
    required this.connections,
    required this.activeConnectionId,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final linkDown = link != null && link != ConnectionStatusKind.connected;
    final dotColor = linkDown
        ? ((link == ConnectionStatusKind.reconnecting ||
                  link == ConnectionStatusKind.connecting ||
                  link == ConnectionStatusKind.starting)
              ? colors.warning
              : colors.textDisabled)
        : checking
        ? colors.warning
        : connected
        ? colors.success
        : colors.textDisabled;
    final statusWord = linkDown
        ? connectionStatusWord(Strings.of(context), link!).toLowerCase()
        : checking
        ? Strings.of(context).statusChecking
        : connected
        ? Strings.of(context).i18n1215StatusOnline
        : Strings.of(context).statusOffline;
    final canSwitch = connections.isNotEmpty;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    // Back closes the open instance menu only, not the drawer.
    return MenuBackGuard(
      builder: (context, menuController, onOpen, onClose) => MenuAnchor(
        key: const ValueKey('drawer-instance-menu'),
        controller: menuController,
        onOpen: onOpen,
        onClose: onClose,
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
                instanceKindIcon(saved.kind),
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
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // The same logo as Home's title, seasons included.
                        const SeasonalMark(
                          size: 23,
                          key: ValueKey('drawer-header-mark'),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Console',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                      ],
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
  final Widget? trailing;

  /// What the destination is for, read by TalkBack after the label
  /// (Desktop shows it beside the entry in its command palette).
  final String? detail;
  // Para filas que comparten la mitad del ancho (el pie fijo
  // Instancias/Ajustes): icono, huecos y tipografía más pequeños para que
  // "Instancias" quepa sin recortarse en un ~185px de ancho disponible.
  final bool dense;

  const _DrawerItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.enabled = true,
    this.disabledHint,
    this.trailing,
    this.detail,
    this.dense = false,
    super.key,
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
          ? detail
          : disabledHint ?? Strings.of(context).drawerNeedInstance,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1.5),
        child: Material(
          color: selected
              ? HermesDrawer._selectedTint(colors)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: dense ? 44 : 52),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: dense ? 10 : 14,
                  vertical: dense ? 8 : 10,
                ),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: dense ? 22 : 28,
                      child: Icon(icon, size: dense ? 18 : 20, color: fg),
                    ),
                    SizedBox(width: dense ? 8 : 12),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: dense ? 13 : 14.5,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: textColor,
                        ),
                      ),
                    ),
                    if (trailing != null) ...[
                      const SizedBox(width: 8),
                      trailing!,
                    ],
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

/// Uppercase group caption ("TRABAJO", "AGENTES") above a run of
/// [_DrawerItem]s — same idiom as the existing "Recientes" section header,
/// just applied consistently to every group instead of only the last one.
class _DrawerSectionLabel extends StatelessWidget {
  final String label;

  const _DrawerSectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 18, 6),
      child: Semantics(
        header: true,
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            color: colors.textTertiary,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}

/// Small live-status dot for a [_DrawerItem]'s trailing slot. `null` color
/// renders nothing (not even a dim placeholder) — absence of signal isn't
/// itself a status worth showing.
class _StatusDot extends StatelessWidget {
  final Color? color;

  const _StatusDot({required this.color});

  @override
  Widget build(BuildContext context) {
    final dotColor = color;
    if (dotColor == null) return const SizedBox.shrink();
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
    );
  }
}
