import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_header_title.dart';
import '../config/flavor.dart';
import '../models/home_widget_snapshot.dart';
import '../navigation/chat_route.dart';
import '../services/agent_runtime/agent_runtime.dart';
import '../services/agent_runtime/local_termux_agent_provider.dart';
import '../services/bridge_update_service.dart';
import '../services/active_chat_service.dart';
import '../services/connection_manager.dart';
import '../services/chat_draft_store.dart';
import '../services/drawer_gesture_exclusion.dart';
import '../services/home_widget_publisher.dart';
import '../services/platform/android_apps.dart';
import '../services/local_transcript_store.dart';
import '../services/session_archive.dart';
import '../services/session_deletion.dart';
import '../services/turn_outbox_store.dart';
import '../theme/app_theme.dart';
import '../utils/home_recent_sessions.dart';
import '../utils/assistant_operational_artifacts.dart';
import '../utils/relative_time.dart';
import '../widgets/attachment_source_sheet.dart';
import '../widgets/dock_shortcuts.dart';
import '../widgets/general_mode_dock.dart';
import '../widgets/hermes_drawer.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/home_prompt_composer.dart';
import '../../main.dart';
import '../companion/models/companion_presence_level.dart';
import '../companion/render/companion_home_mascot.dart';
import '../companion/render/companion_roaming_overlay.dart';
import 'companion/mascotas_screen.dart';
import '../widgets/hermes_spark_mascot.dart';
import '../widgets/read_only.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/session_deletion_dialogs.dart';
import '../widgets/session_title_editor_route.dart';
import 'chat_screen.dart';
import 'gateway_manager_screen.dart';
import 'local_instance_control_screen.dart';
import 'mission_control_screen.dart';
import 'onboarding/local_install_screen.dart';
import 'onboarding/local_uninstall_screen.dart';
import 'onboarding/welcome_mode_screen.dart';
import 'session_list_screen.dart';
import 'settings_screen.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/instance_status_panel.dart';
import '../../l10n/app_localizations.dart';

/// App home: clean dashboard around the active gateway.
///
/// Replaces the old behaviour (connection list that auto-navigated into the
/// session list). Sessions live behind the drawer / quick access; home only
/// shows the active instance, its health, and the primary actions.
class HomeDashboardScreen extends StatefulWidget {
  final ConnectionManager connManager;
  final ApiClient Function(SavedConnection connection)? clientFactory;
  final ValueChanged<double>? onInitialLoadProgress;
  final VoidCallback? onInitialLoadComplete;

  const HomeDashboardScreen({
    required this.connManager,
    this.clientFactory,
    this.onInitialLoadProgress,
    this.onInitialLoadComplete,
    super.key,
  });

  @override
  State<HomeDashboardScreen> createState() => _HomeDashboardScreenState();
}

class _HomeDashboardScreenState extends State<HomeDashboardScreen>
    with WidgetsBindingObserver, RouteAware {
  static const String _activeKey = 'last_connection_id';

  List<SavedConnection> _connections = [];
  SavedConnection? _active;
  bool _healthOk = false;
  bool _checking = false;
  List<Session> _recentSessions = [];
  SessionArchive? _archive;
  final Map<String, ({double activityAt, String? user, String? assistant})>
  _turnPreviews = {};
  int _previewHydrationEpoch = 0;
  StreamSubscription<HistoryCleanupInvalidation>? _historyCleanupSubscription;
  PageRoute<dynamic>? _route;
  bool _initialLoadComplete = false;
  double _initialLoadProgress = 0;
  int _reloadEpoch = 0;
  int _refreshStatusEpoch = 0;

  // Banner de operación local en curso (visible si el usuario salió durante install/uninstall).
  bool _installInProgress = false;
  bool _uninstallInProgress = false;

  // Arranque del agente local desde el home (cuando está instalado pero apagado).
  bool _localStarting = false;
  Timer? _localStartPoll;
  int _localStartTicks = 0;

  // Dock flotante (perfil "General"): true cuando hay una subpantalla
  // abierta encima de Home, para mostrar su "Atrás" contextual.
  bool _hasSubscreenAbove = false;

  @override
  void dispose() {
    hermesRouteObserver.unsubscribe(this);
    unawaited(DrawerGestureExclusion.setEnabled(false));
    _refreshStatusEpoch++;
    _previewHydrationEpoch++;
    unawaited(_historyCleanupSubscription?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    widget.connManager.activeConnectionId.removeListener(_onActiveConnChanged);
    _localStartPoll?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && !identical(route, _route)) {
      hermesRouteObserver.unsubscribe(this);
      _route = route;
      hermesRouteObserver.subscribe(this, route);
      if (route.isCurrent) {
        unawaited(DrawerGestureExclusion.setEnabled(true));
      }
    }
  }

  @override
  void didPush() => unawaited(DrawerGestureExclusion.setEnabled(true));

  @override
  void didPopNext() {
    unawaited(DrawerGestureExclusion.setEnabled(true));
    if (mounted) setState(() => _hasSubscreenAbove = false);
  }

  @override
  void didPushNext() {
    unawaited(DrawerGestureExclusion.setEnabled(false));
    if (mounted) setState(() => _hasSubscreenAbove = true);
  }

  @override
  void didPop() => unawaited(DrawerGestureExclusion.setEnabled(false));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Si se activa otra instancia desde cualquier pantalla (no solo el drawer
    // del home), recargamos al instante. Antes el home se quedaba con la
    // instancia anterior hasta salir y volver a entrar.
    widget.connManager.activeConnectionId.addListener(_onActiveConnChanged);
    _historyCleanupSubscription = historyCleanupInvalidations.events.listen(
      _onHistoryCleanupInvalidation,
    );
    _reload();
  }

  void _onActiveConnChanged() {
    if (mounted) _reload();
  }

  void _onHistoryCleanupInvalidation(HistoryCleanupInvalidation event) {
    if (!mounted || event.connectionId != _active?.id) return;
    unawaited(_refreshStatus());
  }

  void _reportInitialLoadProgress(double value) {
    if (_initialLoadComplete || value <= _initialLoadProgress) return;
    _initialLoadProgress = value;
    widget.onInitialLoadProgress?.call(value);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Al volver de segundo plano re-comprobamos la salud: una instancia que
    // sigue viva (p.ej. el agente local con wake-lock) vuelve a "online" sola,
    // sin obligar al usuario a reconectar a mano cada vez que reabre la app.
    if (state == AppLifecycleState.resumed && _active != null && !_checking) {
      _refreshStatus();
    }
  }

  /// Re-resolve connections + active gateway from storage, then refresh
  /// health and recent sessions. Called on init and whenever a screen that
  /// can change the active gateway pops.
  /// Sincroniza el token de la instancia local on-device con el token canónico
  /// (el UUID con el que la app arranca el agente, persistido en SecureStorage).
  /// Sin esto, una conexión local creada con el token fijo antiguo queda con un
  /// apiKey que el dashboard real rechaza (401 en /api/sessions) → la instancia
  /// aparece "offline" pese a responder /health, y el chat/modelo local falla.
  Future<void> _syncLocalTokenIfNeeded() async {
    final localConnections = widget.connManager
        .getConnections()
        .where((connection) => connection.onDeviceLoopback)
        .toList(growable: false);
    if (localConnections.isEmpty) return;

    final canon = await AgentRuntimeConsts.getOrGenerateLocalToken();
    for (final c in localConnections) {
      if (c.apiKey != canon) {
        await widget.connManager.updateApiKey(c.id, canon);
      }
    }
  }

  Future<void> _reload() async {
    final epoch = ++_reloadEpoch;
    _reportInitialLoadProgress(0.42);
    try {
      await _syncLocalTokenIfNeeded();
      if (!mounted || epoch != _reloadEpoch) return;
      _reportInitialLoadProgress(0.50);

      final connections = widget.connManager.getConnections();
      final lastId = widget.connManager.prefs.getString(_activeKey);
      SavedConnection? active = connections
          .where((c) => c.id == lastId)
          .firstOrNull;
      active ??= connections.firstOrNull;
      if (active != null && active.id != lastId) {
        // Vía setActiveConnection (no escritura directa de prefs) para que el
        // notifier de instancia activa no quede desincronizado (spec 028).
        await widget.connManager.setActiveConnection(active.id);
        if (!mounted || epoch != _reloadEpoch) return;
      }
      var installInProgress =
          widget.connManager.prefs.getBool('local_install_in_progress') == true;
      if (installInProgress) {
        // Auto-saneo: el flag puede quedar OBSOLETO (instalación fallida, matada o
        // una desinstalación posterior) y dejar un «Retomar» fantasma para siempre.
        // Sólo es real si el wrapper de instalación sigue vivo (sirve :8643). Si no,
        // limpiamos el flag para que el banner desaparezca.
        final live = await LocalTermuxAgentProvider(
          apps: const AndroidApps(),
        ).isInstallRunning();
        if (!live) {
          await widget.connManager.prefs.remove('local_install_in_progress');
          installInProgress = false;
        }
        if (!mounted || epoch != _reloadEpoch) return;
      }
      final uninstallInProgress =
          widget.connManager.prefs.getBool('local_uninstall_in_progress') ==
          true;
      if (!mounted || epoch != _reloadEpoch) return;
      setState(() {
        _connections = connections;
        _active = active;
        _installInProgress = installInProgress;
        _uninstallInProgress = uninstallInProgress;
      });
      _reportInitialLoadProgress(0.64);
      await _refreshStatus();
    } finally {
      if (mounted && epoch == _reloadEpoch && !_initialLoadComplete) {
        setState(() => _initialLoadComplete = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || epoch != _reloadEpoch) return;
          widget.onInitialLoadProgress?.call(1);
          widget.onInitialLoadComplete?.call();
        });
      }
    }
  }

  /// Borra un chat directamente desde recientes. Para instancias locales limpia
  /// el transcript guardado (el bridge no expone /api/sessions); para remotas
  /// borra en el servidor y, si éste no la borra (sesión de canal activo), la
  /// oculta para que no reaparezca aquí.
  Future<void> _deleteRecent(Session session) async {
    final conn = _active;
    if (conn == null) return;
    final ownerProfile = Session.profileOwner(session.profile);
    if (conn.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final title = _archive?.titleForSession(session) ?? session.displayTitle;
    final isLocal =
        conn.kind == InstanceKind.localhost || session.source == 'mobile-local';
    var cronDeletion = LinkedCronDeletionMode.keepSchedule;
    if (session.isJob && !isLocal) {
      final choice = await showCronConversationDeleteDialog(context, session);
      if (choice == null) return;
      cronDeletion = choice;
    } else {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(s.homeDeleteChatTitle),
          content: Text(s.homeDeleteChatBody(title)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(s.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                s.commonDelete,
                style: TextStyle(color: colors.error),
              ),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

    var removed = false;
    if (isLocal) {
      await LocalTranscriptStore.clear(
        conn.id,
        session.id,
        profile: ownerProfile,
      );
      removed = true;
    } else {
      final client = ApiClient(
        baseUrl: conn.baseUrl,
        apiKey: conn.apiKey,
        connectionId: conn.id,
      );
      late final LinkedSessionDeleteResult result;
      try {
        result = await deleteSessionWithResolvedLineage(
          session,
          loadSessions: ({bool includeChildren = false}) => client.getSessions(
            includeChildren: includeChildren,
            profile: ownerProfile,
          ),
          deleteSession: (sessionId) =>
              client.deleteSession(sessionId, profile: ownerProfile),
          cronDeletion: cronDeletion,
          deleteCronJob:
              !session.isJob ||
                  cronDeletion == LinkedCronDeletionMode.keepSchedule
              ? null
              : (jobId) => widget.connManager.deleteLinkedCronJob(
                  conn,
                  jobId,
                  profile: ownerProfile,
                ),
        );
      } finally {
        client.close();
      }
      if (!mounted) return;
      switch (result.status) {
        case LinkedSessionDeleteStatus.deleted:
          removed = true;
          break;
        case LinkedSessionDeleteStatus.cancelled:
          break;
        case LinkedSessionDeleteStatus.sessionRejected:
          if (mounted) {
            _offerHideRecent(
              session,
              message: result.cronDeleted ? s.cronStoppedChatKept : null,
            );
          }
          return;
        case LinkedSessionDeleteStatus.cronDeleteFailed:
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(sessionDeletionFailureMessage(s, result))),
            );
          }
          return;
        case LinkedSessionDeleteStatus.sessionDeleteFailed:
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(sessionDeletionFailureMessage(s, result))),
            );
          }
          return;
      }
      if (!removed) return;
    }
    if (!mounted || !removed) return;
    final aggregate = context
        .findAncestorStateOfType<HermesAppState>()
        ?.activeChats
        .globalActivity;
    aggregate?.clearSession(conn.id, ownerProfile, session.id);
    await aggregate?.flushJournal();
    if (!mounted) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await ChatDraftStore(
        prefs,
      ).clear(conn.id, session.id, profile: ownerProfile);
      await TurnOutboxStore().deleteForChat(
        conn.id,
        session.id,
        profile: ownerProfile,
      );
    } catch (error) {
      debugPrint(
        '[home-dashboard] recovery cleanup failed (${error.runtimeType})',
      );
    }
    if (!mounted) return;
    setState(() {
      _recentSessions = _recentSessions
          .where(
            (x) =>
                x.id != session.id ||
                Session.profileOwner(x.profile) != ownerProfile,
          )
          .toList();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(s.homeChatDeleted, style: const TextStyle(fontSize: 13)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _renameRecent(Session session) async {
    final archive = _archive;
    if (archive == null) return;
    final currentTitle = archive.titleForSession(session);
    final newTitle = await showSessionTitleEditorRoute(
      context,
      initialTitle: currentTitle,
    );
    if (!mounted || newTitle == null) return;
    final trimmed = newTitle.trim();
    if (trimmed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).slRenameEmpty)),
      );
      return;
    }
    await archive.setSessionTitle(session, trimmed);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(Strings.of(context).slRenamed)));
  }

  Future<void> _showRecentActions(Session session) async {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final readOnly = _active?.readOnly == true;
    final action = await showHermesFloatingSurface<_RecentAction>(
      context: context,
      surfaceKey: const ValueKey('home-recent-actions'),
      maxWidth: 420,
      maxHeightFactor: 0.72,
      builder: (surfaceContext) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 18, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text(
                _archive?.titleForSession(session) ?? session.displayTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ListTile(
              key: const ValueKey('home-recent-action-rename'),
              leading: const Icon(Icons.edit_outlined),
              title: Text(strings.slMenuRename),
              onTap: () => Navigator.pop(surfaceContext, _RecentAction.rename),
            ),
            if (!readOnly)
              ListTile(
                key: const ValueKey('home-recent-action-delete'),
                leading: Icon(Icons.delete_outline, color: colors.error),
                title: Text(
                  strings.slMenuDelete,
                  style: TextStyle(color: colors.error),
                ),
                onTap: () =>
                    Navigator.pop(surfaceContext, _RecentAction.delete),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(surfaceContext),
                child: Text(strings.commonCancel),
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case _RecentAction.rename:
        await _renameRecent(session);
        break;
      case _RecentAction.delete:
        await _deleteRecent(session);
        break;
      case null:
        break;
    }
  }

  void _offerHideRecent(Session session, {String? message}) {
    final messenger = ScaffoldMessenger.of(context);
    final s = Strings.of(context);
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(message ?? s.slOfferHideContent),
        action: SnackBarAction(
          label: s.slHideAction,
          onPressed: () async {
            await _archive?.hide(session.id);
            if (!mounted) return;
            setState(() {
              _recentSessions = _recentSessions
                  .where((item) => item.id != session.id)
                  .toList();
            });
          },
        ),
      ),
    );
  }

  /// Instancias locales cuyo bridge ya intentamos refrescar en esta sesión, para
  /// no relanzar el redeploy en cada `_refreshStatus` (resume, foco, etc.).
  final Set<String> _freshBridgeTried = {};

  /// Asegura, en segundo plano, que el bridge local corre la versión esperada.
  /// No bloquea la UI: si estaba desactualizado, lo redespliega y al terminar
  /// refresca el estado. Idempotente y barato cuando ya está fresco.
  void _ensureLocalBridgeFresh(SavedConnection conn) {
    if (!_freshBridgeTried.add(conn.id)) return; // ya intentado esta sesión
    LocalTermuxAgentProvider(apps: const AndroidApps())
        .ensureFreshBridge(conn.derivedBridgeUrl)
        .then<void>((fresh) {
          if (fresh && mounted && _active?.id == conn.id) _refreshStatus();
        })
        .catchError((Object _) {
          // Si falló, permite reintentar en el próximo refresh.
          _freshBridgeTried.remove(conn.id);
        });
  }

  bool _isCurrentStatusRefresh(int epoch, String? connectionId) =>
      mounted && epoch == _refreshStatusEpoch && _active?.id == connectionId;

  Future<void> _refreshStatus() async {
    final refreshEpoch = ++_refreshStatusEpoch;
    final conn = _active;
    final connectionId = conn?.id;
    final app = context.findAncestorStateOfType<HermesAppState>();
    if (conn == null) {
      if (!_isCurrentStatusRefresh(refreshEpoch, connectionId)) return;
      setState(() {
        _healthOk = false;
        _checking = false;
        _recentSessions = [];
      });
      unawaited(
        app?.updateHomeWidget(
          (current) => _isCurrentStatusRefresh(refreshEpoch, connectionId)
              ? const HermesHomeWidgetSnapshot(
                  configured: false,
                  connectionState: HomeWidgetConnectionState.unconfigured,
                  agentState: HomeWidgetAgentState.disconnected,
                )
              : current,
        ),
      );
      if (_isCurrentStatusRefresh(refreshEpoch, connectionId)) {
        _reportInitialLoadProgress(0.92);
      }
      return;
    }

    // Leer el estado del App Lock antes de los awaits de red evita conservar
    // BuildContext a través del hueco asíncrono.
    final appLockEnabled = app?.appLock.enabled == true;

    if (!_isCurrentStatusRefresh(refreshEpoch, connectionId)) return;
    setState(() => _checking = true);
    unawaited(
      app?.updateHomeWidget(
        (current) => _isCurrentStatusRefresh(refreshEpoch, connectionId)
            ? mergeHomeWidgetBaseSnapshot(
                current: current,
                configured: true,
                instanceId: conn.id,
                instanceLabel: conn.label,
                connectionState: HomeWidgetConnectionState.connecting,
                agentState: HomeWidgetAgentState.idle,
                theme: current.theme,
              )
            : current,
      ),
    );
    final archive = await SessionArchive.load(
      widget.connManager.prefs,
      conn.id,
    );
    if (!_isCurrentStatusRefresh(refreshEpoch, connectionId)) return;
    bool ok = false;
    List<Session> sessions = [];
    List<ChatDraftEntry> drafts = [];
    // Los borradores viven en el Keystore. Un fallo puntual al desbloquearlo no
    // debe convertir un servidor sano en «offline»: son dos fuentes separadas.
    try {
      drafts = await ChatDraftStore(
        widget.connManager.prefs,
      ).listForConnection(conn.id);
    } catch (e) {
      debugPrint('[home-dashboard] no se pudieron listar borradores: $e');
    }
    if (!_isCurrentStatusRefresh(refreshEpoch, connectionId)) return;
    final client =
        widget.clientFactory?.call(conn) ??
        ApiClient(baseUrl: conn.baseUrl, apiKey: conn.apiKey);
    final ownerProfile = Session.profileOwner(
      widget.connManager.activeProfileFor(conn.id),
    );
    try {
      if (conn.kind == InstanceKind.localhost) {
        // El agente local sirve dashboard en :9119; su health es /api/status,
        // no /health (gateway :8642, que en local no existe). healthCheck()
        // daría 404 → falso «offline» aunque el agente esté vivo. Usamos el
        // mismo sondeo que la pantalla de setup para que ambas coincidan.
        ok = await LocalTermuxAgentProvider(
          apps: const AndroidApps(),
        ).isAgentRunning();
        if (!_isCurrentStatusRefresh(refreshEpoch, connectionId)) return;
        if (ok) {
          // Tras actualizar el APK, el bridge desplegado en el dispositivo puede
          // ser uno VIEJO que sirve endpoints antiguos → modelos/skills/info del
          // servidor salen vacíos. Si el agente está vivo, auto-actualizamos el
          // bridge a la versión esperada (en segundo plano, una vez por sesión).
          _ensureLocalBridgeFresh(conn);
          // El bridge local no expone /api/sessions — usamos el transcript
          // guardado en SharedPreferences por LocalTranscriptStore.
          sessions = await LocalTranscriptStore.listForConnection(
            conn.id,
            profile: ownerProfile,
          );
          if (!_isCurrentStatusRefresh(refreshEpoch, connectionId)) return;
        }
      } else {
        ok = await client.healthCheck();
        if (!_isCurrentStatusRefresh(refreshEpoch, connectionId)) return;
        if (ok) {
          sessions = await client.getSessions(profile: ownerProfile);
          if (!_isCurrentStatusRefresh(refreshEpoch, connectionId)) return;
          sessions.sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
          // La comprobación del bridge ya no depende de abrir Chat/Ajustes.
          // Con App Lock activo no iniciamos una mutación automática que el
          // usuario no acaba de autorizar; la acción manual permanece visible.
          if (!appLockEnabled) {
            unawaited(BridgeUpdateService.maintainIfEnabled(conn));
          }
        }
      }
    } catch (e) {
      debugPrint(
        '[home-dashboard] excepción silenciada (fallback: ok = false): $e',
      );
      ok = false;
    } finally {
      client.close();
    }
    if (!_isCurrentStatusRefresh(refreshEpoch, connectionId)) return;
    if (!mounted) return;
    final merged = <String, Session>{};
    for (final session in sessions) {
      final published = session.profile?.trim();
      if (published != null && published.isNotEmpty) {
        if (published == ownerProfile) merged[session.id] = session;
        continue;
      }
      final captured = session.copyWith(profile: ownerProfile);
      merged[captured.id] = captured;
    }
    for (final draft in drafts.where(
      (draft) => Session.profileOwner(draft.profile) == ownerProfile,
    )) {
      final localDraft = draft.toSession(
        fallbackTitle: Strings.of(context).drawerNewChat,
      );
      final authoritativeSession = merged[draft.sessionId];
      merged[draft.sessionId] = authoritativeSession == null
          ? localDraft
          : authoritativeSession.copyWith(hasLocalDraft: true);
    }
    final visibleSessions = merged.values.toList()
      ..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
    final recentSessions = visibleSessions
        // Los informes generados por cron tienen su apartado propio en
        // Conversaciones > Resultados cron. No desplazan chats reales en Inicio.
        .where((s) => !s.isJob && !archive.isHidden(s.id))
        .toList();
    final recentLimit = _homeRecentLimit();
    if (!_isCurrentStatusRefresh(refreshEpoch, connectionId)) return;
    setState(() {
      _healthOk = ok;
      _checking = false;
      _archive = archive;
      _recentSessions = recentSessions;
    });
    unawaited(
      app?.updateHomeWidget(
        (current) => _isCurrentStatusRefresh(refreshEpoch, connectionId)
            ? current.copyWith(
                configured: true,
                instanceId: conn.id,
                instanceLabel: conn.label,
                connectionState: ok
                    ? HomeWidgetConnectionState.connected
                    : HomeWidgetConnectionState.disconnected,
                agentState: ok
                    ? current.agentState == HomeWidgetAgentState.disconnected ||
                              current.agentState == HomeWidgetAgentState.error
                          ? HomeWidgetAgentState.idle
                          : current.agentState
                    : HomeWidgetAgentState.disconnected,
              )
            : current,
      ),
    );
    if (!_isCurrentStatusRefresh(refreshEpoch, connectionId)) return;
    _reportInitialLoadProgress(0.92);
    if (!_isCurrentStatusRefresh(refreshEpoch, connectionId)) return;
    unawaited(
      _hydrateTurnPreviews(
        conn,
        recentSessions.take(recentLimit).toList(growable: false),
      ),
    );
  }

  int _homeRecentLimit() {
    final media = MediaQuery.of(context);
    final textScale = media.textScaler.scale(14) / 14;
    return homeRecentSessionLimit(
      viewportHeight: media.size.height,
      textScale: textScale,
    );
  }

  String _turnPreviewKey(SavedConnection connection, Session session) =>
      '${connection.id}\u001f${session.id}';

  Future<void> _hydrateTurnPreviews(
    SavedConnection connection,
    List<Session> sessions,
  ) async {
    final epoch = ++_previewHydrationEpoch;
    final activeChats = context
        .findAncestorStateOfType<HermesAppState>()
        ?.activeChats;
    var changed = false;

    for (final session in sessions) {
      final key = _turnPreviewKey(connection, session);
      final activityAt = session.lastActivityAt;
      final inMemory = activeChats?.of(
        connection.id,
        session.id,
        profile: session.profile,
      );
      final user = inMemory == null
          ? session.lastUserPreview
          : latestUserPreview(inMemory.messages, newestFirst: true) ??
                session.lastUserPreview;
      final assistant = inMemory == null
          ? session.lastAssistantPreview
          : latestAssistantPreview(inMemory.messages, newestFirst: true) ??
                session.lastAssistantPreview;
      final cached = _turnPreviews[key];
      if (cached?.activityAt == activityAt &&
          cached?.user == user &&
          cached?.assistant == assistant) {
        continue;
      }
      _turnPreviews[key] = (
        activityAt: activityAt,
        user: user,
        assistant: assistant,
      );
      changed = true;
    }

    if (changed && mounted && epoch == _previewHydrationEpoch) {
      setState(() {});
    }
  }

  String _recentGroupLabel(HomeRecentDateGroup group) => switch (group) {
    HomeRecentDateGroup.today => Strings.of(context).homeRecentToday,
    HomeRecentDateGroup.yesterday => Strings.of(context).homeRecentYesterday,
    HomeRecentDateGroup.earlier => Strings.of(context).homeRecentEarlier,
  };

  List<Widget> _buildRecentRows(SavedConnection connection, int limit) {
    final rows = <Widget>[];
    final now = DateTime.now();
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final activeChats = context
        .findAncestorStateOfType<HermesAppState>()
        ?.activeChats;
    HomeRecentDateGroup? previousGroup;
    final visible = _recentSessions.take(limit).toList(growable: false);

    for (var index = 0; index < visible.length; index++) {
      final session = visible[index];
      final group = homeRecentDateGroup(session.lastActivityAt, now);
      if (group != previousGroup) {
        rows.add(
          _RecentGroupHeader(
            key: ValueKey('home-recent-group-${group.name}'),
            label: _recentGroupLabel(group),
            first: index == 0,
          ),
        );
        previousGroup = group;
      }

      final title = _archive?.titleForSession(session) ?? session.displayTitle;
      final cached = _turnPreviews[_turnPreviewKey(connection, session)];
      final summary = homeRecentSummary(
        title: title,
        session: session,
        userPreview: cached?.activityAt == session.lastActivityAt
            ? cached?.user
            : null,
        assistantPreview: cached?.activityAt == session.lastActivityAt
            ? cached?.assistant
            : null,
      );
      final activeChat = activeChats?.of(
        connection.id,
        session.id,
        profile: session.profile,
      );

      Widget recentTile(ChatActivityKind? activity) => _RecentSessionTile(
        session: session,
        title: title,
        summary: summary,
        activityLabel: _activityLabel(activity),
        relativeTime: relativeTime(
          session.lastActivityAt,
          languageCode: Localizations.localeOf(context).languageCode,
        ),
        onTap: () => _openChat(session),
        onManage: () => _showRecentActions(session),
      );

      rows.add(
        FadeSlideIn(
          delayMs: reduceMotion ? 0 : 30 + (index.clamp(0, 3)) * 20,
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 220),
          child: activeChat == null
              ? recentTile(null)
              : StreamBuilder<ActiveChatEvent>(
                  stream: activeChat.changes,
                  builder: (_, _) => recentTile(activeChat.activityKind),
                ),
        ),
      );
    }
    return rows;
  }

  String? _activityLabel(ChatActivityKind? activity) => switch (activity) {
    ChatActivityKind.thinking => Strings.of(context).chaPipelineThinking,
    ChatActivityKind.usingTools => Strings.of(context).chaPipelineExecuting,
    ChatActivityKind.responding => Strings.of(context).chaPipelineStreaming,
    ChatActivityKind.awaitingApproval => Strings.of(
      context,
    ).homeActivityAwaitingApproval,
    null => null,
  };

  void _openChat(
    Session session, {
    String? initialPrompt,
    AttachmentSourceChoice? initialAttachmentSource,
    bool initialDictation = false,
    bool initialVoiceMode = false,
  }) {
    final conn = _active;
    if (conn == null) return;
    openChatWithParent<void>(
      context,
      parentBuilder: (_) =>
          SessionListScreen(connection: conn, connManager: widget.connManager),
      builder: (_) => ChatScreen(
        connection: conn,
        session: session,
        initialPrompt: initialPrompt,
        initialAttachmentSource: initialAttachmentSource,
        initialDictation: initialDictation,
        initialVoiceMode: initialVoiceMode,
      ),
    ).then((_) => _refreshStatus());
  }

  void _newChat({
    String? initialPrompt,
    AttachmentSourceChoice? initialAttachmentSource,
    bool initialDictation = false,
    bool initialVoiceMode = false,
  }) {
    _openChat(
      Session(
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
      ),
      initialPrompt: initialPrompt,
      initialAttachmentSource: initialAttachmentSource,
      initialDictation: initialDictation,
      initialVoiceMode: initialVoiceMode,
    );
  }

  void _selectHomeAttachment(AttachmentSourceChoice source) {
    FocusManager.instance.primaryFocus?.unfocus();
    _newChat(initialAttachmentSource: source);
  }

  void _openSessions() {
    final conn = _active;
    if (conn == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SessionListScreen(
          connection: conn,
          connManager: widget.connManager,
        ),
      ),
    ).then((_) => _refreshStatus());
  }

  /// Envía el comando de arranque al agente local (Termux background) y sondea
  /// hasta que responde. Cuando arranca, refresca el estado del home.
  Future<void> _startLocalAgent() async {
    setState(() {
      _localStarting = true;
      _localStartTicks = 0;
    });
    final termux = LocalTermuxAgentProvider(apps: const AndroidApps());
    await termux.startAgent();
    _localStartPoll?.cancel();
    _localStartPoll = Timer.periodic(const Duration(seconds: 2), (_) async {
      _localStartTicks++;
      final running = await termux.isAgentRunning();
      if (running || _localStartTicks >= 30) {
        _localStartPoll?.cancel();
        termux.dispose();
        if (mounted) {
          setState(() => _localStarting = false);
          await _refreshStatus();
        }
      }
    });
  }

  Future<void> _openLocalControl() async {
    final conn = _active;
    if (conn == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LocalInstanceControlScreen(
          connection: conn,
          connManager: widget.connManager,
        ),
      ),
    );
    if (mounted) await _reload();
  }

  /// Abre el gestor de instancias (editar/activar otra) desde la tarjeta de
  /// instancia remota caída (spec 028 A-025).
  Future<void> _openInstances() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GatewayManagerScreen(connManager: widget.connManager),
      ),
    );
    if (mounted) await _reload();
  }

  void _showAddDialog() {
    // Ofrece ambos modos: agente local en este móvil o cliente remoto.
    var completed = false;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WelcomeModeScreen(
          connManager: widget.connManager,
          onDone: () {
            completed = true;
            Navigator.of(context).popUntil((r) => r.isFirst);
          },
        ),
      ),
    ).then((_) async {
      if (!mounted) return;
      await _reload();
      // Alta completada (no cancelada con atrás): directo a un chat de la
      // instancia recién emparejada —que _save dejó como ACTIVA—, en vez de
      // devolver al usuario a las pantallas de instalación (spec 028 U-32).
      if (completed && mounted && _active != null) _newChat();
    });
  }

  Widget _buildPromptStage({required bool enabled, required bool dimmed}) {
    final colors = Theme.of(context).hermes;
    final app = context.findAncestorStateOfType<HermesAppState>();
    final controller = app?.companion;
    final presence = app?.companionPresence;
    final connectionMood = _checking
        ? HermesSparkMood.connecting
        : _healthOk
        ? HermesSparkMood.idle
        : HermesSparkMood.offline;

    final composer = Opacity(
      opacity: dimmed ? 0.55 : 1,
      child: HomePromptComposer(
        hintText: Strings.of(context).homeAskHermes,
        attachmentTooltip: Strings.of(context).chaAttachTooltip,
        dictationTooltip: Strings.of(context).chaVoiceDictationTooltip,
        voiceTooltip: Strings.of(context).chaVoiceModeTooltip,
        sendTooltip: Strings.of(context).chaSendTooltip,
        enabled: enabled,
        onAttachmentSelected: _selectHomeAttachment,
        onDictationPressed: () => _newChat(initialDictation: true),
        onVoicePressed: () => _newChat(initialVoiceMode: true),
        onSubmitted: (prompt) => _newChat(initialPrompt: prompt),
      ),
    );

    if (controller == null) return composer;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final media = MediaQuery.of(context);
        final reduceMotion = media.disableAnimations;
        final view = View.maybeOf(context);
        final rawKeyboardInset = view?.viewInsets.bottom ?? 0;
        final keyboardVisible =
            media.viewInsets.bottom > 0 || rawKeyboardInset > 0;
        final showCompanion =
            controller.isInitialized &&
            controller.enabled &&
            controller.showOnHome &&
            controller.presenceLevel.isVisible &&
            !keyboardVisible;
        const basePetSize = 60.0;
        final petExtent = basePetSize * controller.sizeMultiplier;
        // El atlas conserva aire transparente bajo el sprite. Un solape óptico
        // de 14 dp hace que parezca apoyado sin moverlo fuera de su pista.
        final trackHeight = showCompanion ? petExtent - 14 : 0.0;
        void openMascotas() {
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const MascotasScreen()),
          );
        }

        Widget stationaryMascot(HermesSparkMood mood) {
          return CompanionHomeMascot(
            controller: controller,
            baseMood: mood,
            size: basePetSize,
            accent: colors.accent,
            onOpenMascotas: openMascotas,
            semanticLabel: Strings.of(context).homePetShortcut,
          );
        }

        Widget fixedMascot = stationaryMascot(connectionMood);
        if (presence != null) {
          fixedMascot = ListenableBuilder(
            listenable: presence,
            builder: (context, _) {
              final mood = presence.mood;
              final reactive =
                  controller.presenceLevel != CompanionPresenceLevel.off;
              final busy =
                  reactive &&
                  (mood == HermesSparkMood.thinking ||
                      mood == HermesSparkMood.success ||
                      mood == HermesSparkMood.error ||
                      mood == HermesSparkMood.waiting);
              return stationaryMascot(busy ? mood : connectionMood);
            },
          );
        }

        return CompanionRoamingOverlay(
          controller: controller,
          presence: presence,
          baseMood: connectionMood,
          accent: colors.accent,
          size: basePetSize,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
          onPetTap: () => showCompanionActionsSheet(
            context: context,
            controller: controller,
            onOpenMascotas: openMascotas,
          ),
          petSemanticLabel: Strings.of(context).homePetShortcut,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              AnimatedPadding(
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                padding: EdgeInsets.only(top: trackHeight),
                child: composer,
              ),
              if (showCompanion)
                Positioned(top: 0, right: 10, child: fixedMascot),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final recentLimit = _homeRecentLimit();
    if (!_initialLoadComplete) {
      return Scaffold(
        backgroundColor: colors.background,
        body: const Center(
          child: TuiLoader(key: ValueKey('home-initial-loading')),
        ),
      );
    }
    return Scaffold(
      appBar: HermesAppBar(
        centerTitle: false,
        titleSpacing: 0,
        // Todo el bloque de título abre la hoja de estado: la línea de 16dp
        // sola quedaba lejísimos del target mínimo de 48dp, y el gesto no
        // tenía rol de botón ni pista de qué abre (spec 028 A-110).
        title: Semantics(
          button: _active != null,
          hint: _active == null ? null : Strings.of(context).homeOpenStatusHint,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _active == null
                ? null
                : () => showInstanceStatusSheet(context, _active!),
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              alignment: Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Título configurable (Ajustes › Título del header), REACTIVO:
                  // el notifier global lo refleja al instante al volver de Ajustes.
                  ValueListenableBuilder<String>(
                    valueListenable: headerTitleNotifier,
                    builder: (context, title, _) => Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.1,
                        fontSize: 18,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 1),
                  // Línea de estado → hoja con el detalle de la instancia
                  // (gateway/dashboard/bridge/notificaciones). Solo si hay instancia.
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        duration: reduceMotion
                            ? Duration.zero
                            : const Duration(milliseconds: 180),
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _checking
                              ? colors.warning
                              : _healthOk
                              ? colors.success
                              : colors.textDisabled,
                          boxShadow: _healthOk && !_checking
                              ? [
                                  BoxShadow(
                                    color: colors.success.withValues(
                                      alpha: 0.5,
                                    ),
                                    blurRadius: 6,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _checking
                            ? Strings.of(context).homeStatusChecking(
                                _active?.label ??
                                    Strings.of(context).homeStatusAgentConsole,
                              )
                            : _healthOk
                            ? Strings.of(
                                context,
                              ).homeStatusOnline(_active?.label ?? '')
                            : _active == null
                            ? Strings.of(context).homeStatusAgentConsole
                            : Strings.of(
                                context,
                              ).homeStatusOffline(_active!.label),
                        style: TextStyle(
                          // ≥11px: a 9.5px el estado era casi ilegible (A-110).
                          fontSize: 11,
                          letterSpacing: 0.6,
                          color: colors.textSecondary,
                        ),
                      ),
                      if (_active != null) ...[
                        const SizedBox(width: 3),
                        Icon(
                          Icons.expand_more,
                          size: 13,
                          color: colors.textDisabled,
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
      drawerEnableOpenDragGesture: true,
      drawerEdgeDragWidth: HermesDrawer.edgeDragWidth(context),
      drawer: HermesDrawer(
        connection: _active,
        connManager: widget.connManager,
        current: DrawerSection.home,
        connected: _healthOk,
        checking: _checking,
        onSectionReturn: _reload,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: () {
              final active = _active;
              if (_connections.isEmpty || active == null) {
                return _EmptyHomeState(onAdd: _showAddDialog);
              }
              // Instancia local sin gateway en marcha: el chat no es usable, así que
              // se oculta y solo se muestra el card de estado/arranque del agente.
              final isLocalAndOffline =
                  active.kind == InstanceKind.localhost &&
                  !_healthOk &&
                  !_checking;
              // Instancia remota caída: la única señal era el punto del appbar; el
              // cuerpo necesita un estado visible con reintento, equivalente a la
              // tarjeta de la instancia local apagada (spec 028 A-025).
              final isRemoteAndOffline =
                  active.kind != InstanceKind.localhost &&
                  !_healthOk &&
                  !_checking;
              // El dock flotante (`GeneralModeDock`) se pinta como overlay
              // (Positioned) ENCIMA de esta lista, no reserva espacio por sí
              // mismo. Sin este margen extra, el último item de recientes
              // quedaba tapado/cortado por el dock (confirmado por captura
              // real del dispositivo). Reserva: alto del dock (48) + su
              // separación del borde (12) + el lift máximo de la profundidad
              // "Flotante" (6) + el inset seguro inferior del sistema +
              // un margen de aire adicional para que no quede pegado.
              final dockBottomClearance =
                  48 + 12 + 6 + MediaQuery.paddingOf(context).bottom + 16;
              final content = RefreshIndicator(
                color: colors.accent,
                onRefresh: _refreshStatus,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(20, 20, 20, dockBottomClearance),
                  children: [
                    // U-13 (spec 028): la instancia local está retirada de la UI
                    // para el lanzamiento (kLocalAgentEnabled, default false).
                    if (kLocalAgentEnabled &&
                        (_installInProgress || _uninstallInProgress))
                      _LocalOpBanner(
                        colors: colors,
                        isInstall: _installInProgress,
                        connManager: widget.connManager,
                        onDismiss: () => setState(() {
                          _installInProgress = false;
                          _uninstallInProgress = false;
                        }),
                        onResume: () async {
                          if (_installInProgress) {
                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => LocalInstallScreen(
                                  connManager: widget.connManager,
                                ),
                              ),
                            );
                          } else {
                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => LocalUninstallScreen(
                                  connManager: widget.connManager,
                                ),
                              ),
                            );
                          }
                          _reload();
                        },
                      ),
                    if (kLocalAgentEnabled && isLocalAndOffline)
                      _LocalAgentOfflineCard(
                        colors: colors,
                        starting: _localStarting,
                        onStart: _startLocalAgent,
                        onManage: _openLocalControl,
                      ),
                    if (isRemoteAndOffline)
                      _RemoteInstanceOfflineCard(
                        colors: colors,
                        label: active.label,
                        onRetry: _refreshStatus,
                        onEditInstance: _openInstances,
                      ),
                    // El chat solo tiene sentido si hay un gateway que responde. Con
                    // la instancia local apagada se oculta por completo y solo queda
                    // el card de arranque de arriba.
                    if (!kLocalAgentEnabled || !isLocalAndOffline) ...[
                      const SizedBox(height: 8),
                      // La mascota vive únicamente sobre la pista del compositor.
                      // Sin Companion o con teclado, el input recupera ese espacio.
                      FadeSlideIn(
                        delayMs: reduceMotion ? 0 : 30,
                        duration: reduceMotion
                            ? Duration.zero
                            : const Duration(milliseconds: 220),
                        child: _buildPromptStage(
                          enabled: !isRemoteAndOffline,
                          dimmed: isRemoteAndOffline,
                        ),
                      ),
                      if (_recentSessions.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        Padding(
                          padding: const EdgeInsets.only(left: 4, bottom: 2),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  Strings.of(context).homeChatsSection,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: colors.textSecondary,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: _openSessions,
                                style: TextButton.styleFrom(
                                  minimumSize: const Size(48, 44),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  foregroundColor: colors.accentHover,
                                ),
                                child: Text(
                                  Strings.of(context).homeSearch,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: colors.accentHover,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        ..._buildRecentRows(active, recentLimit),
                      ] else if (!isRemoteAndOffline) ...[
                        const SizedBox(height: 10),
                        HermesEmptyState(
                          key: const ValueKey('home-empty-conversations'),
                          compact: true,
                          title: Strings.of(
                            context,
                          ).homeEmptyConversationsTitle,
                          body: Strings.of(context).homeEmptyConversationsBody,
                          padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
                        ),
                      ],
                    ],
                  ],
                ),
              );
              return content;
            }(),
          ),
          GeneralModeDock(
            onCreate: _active == null ? null : _newChat,
            onOpenBots: _active == null
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MissionControlScreen(
                        connection: _active!,
                        connManager: widget.connManager,
                      ),
                    ),
                  ).then((_) => _refreshStatus()),
            onOpenSettings: _active == null
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SettingsScreen(
                        connection: _active!,
                        connManager: widget.connManager,
                      ),
                    ),
                  ).then((_) => _reload()),
            showBackContext: _hasSubscreenAbove,
            onBack: () => Navigator.of(context).maybePop(),
            // Accesos directos opcionales (ocultos de fábrica en el
            // catálogo); mismas pantallas/criterios que ya usa HermesDrawer.
            onOpenCron: _active == null
                ? null
                : () => openDockCron(context, _active!),
            onOpenTasks: _active == null
                ? null
                : () => openDockTasks(context, _active!),
            onOpenSessions: _active == null
                ? null
                : () => openDockSessions(context, _active!, widget.connManager),
            onOpenTools: () =>
                openDockTools(context, _active, widget.connManager),
          ),
        ],
      ),
    );
  }
}

/// Banner compacto que aparece en el home cuando el usuario salió durante una
/// instalación o desinstalación local. El script de Termux sigue corriendo;
/// esto le avisa al usuario y le permite retomar el seguimiento.
class _LocalOpBanner extends StatelessWidget {
  final HermesThemeColors colors;
  final bool isInstall;
  final ConnectionManager connManager;
  final VoidCallback onDismiss;
  final VoidCallback onResume;

  const _LocalOpBanner({
    required this.colors,
    required this.isInstall,
    required this.connManager,
    required this.onDismiss,
    required this.onResume,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final label = isInstall
        ? s.homeInstallInProgress
        : s.homeUninstallInProgress;
    final sub = isInstall ? s.homeInstallingSub : s.homeUninstallingSub;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        decoration: BoxDecoration(
          color: colors.warning.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: colors.warning.withValues(alpha: 0.28),
            width: 0.75,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                Icons.hourglass_top_rounded,
                size: 18,
                color: colors.warning,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colors.warning,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sub,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: onResume,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  s.homeResume,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: colors.warning,
                  ),
                ),
              ),
              IconButton(
                onPressed: onDismiss,
                icon: Icon(Icons.close, size: 16, color: colors.textDisabled),
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(6),
                tooltip: s.homeHide,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tarjeta que aparece en el home cuando el agente local está instalado pero
/// no está corriendo. Ofrece arrancarlo con un toque o abrir el panel de control.
class _LocalAgentOfflineCard extends StatelessWidget {
  final HermesThemeColors colors;
  final bool starting;
  final VoidCallback onStart;
  final VoidCallback onManage;

  const _LocalAgentOfflineCard({
    required this.colors,
    required this.starting,
    required this.onStart,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        decoration: BoxDecoration(
          color: colors.surfaceVariant.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: colors.divider.withValues(alpha: 0.28),
            width: 0.75,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.terminal_rounded,
                        size: 18,
                        color: colors.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        Strings.of(context).lasConnectionLabel,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: colors.textPrimary,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: colors.textDisabled.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          s.homeLocalAgentOff,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: colors.textDisabled,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    starting
                        ? s.homeLocalAgentStarting
                        : s.homeLocalAgentInstalledNotRunning,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: colors.textSecondary,
                    ),
                  ),
                  if (starting) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      color: colors.accent,
                      backgroundColor: colors.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ],
                  if (!starting) ...[
                    const SizedBox(height: 14),
                    HermesPrimaryButton(
                      label: s.homeStartAgent,
                      icon: Icons.play_arrow_rounded,
                      onTap: onStart,
                    ),
                  ],
                ],
              ),
            ),
            Divider(
              height: 1,
              thickness: 0.5,
              color: colors.divider.withValues(alpha: 0.22),
            ),
            TextButton.icon(
              onPressed: onManage,
              icon: Icon(
                Icons.settings_rounded,
                size: 14,
                color: colors.textSecondary,
              ),
              label: Text(
                s.homeAgentControlPanel,
                style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
              ),
              style: TextButton.styleFrom(
                minimumSize: const Size(double.infinity, 44),
                padding: const EdgeInsets.symmetric(horizontal: 18),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(
                    bottom: Radius.circular(16),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Estado editorial de la instancia remota. Diagnóstico y acciones permanecen
/// visibles; la explicación secundaria se pliega para no dominar el Home.
class _RemoteInstanceOfflineCard extends StatefulWidget {
  final HermesThemeColors colors;
  final String label;
  final VoidCallback onRetry;
  final VoidCallback onEditInstance;

  const _RemoteInstanceOfflineCard({
    required this.colors,
    required this.label,
    required this.onRetry,
    required this.onEditInstance,
  });

  @override
  State<_RemoteInstanceOfflineCard> createState() =>
      _RemoteInstanceOfflineCardState();
}

class _RemoteInstanceOfflineCardState
    extends State<_RemoteInstanceOfflineCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = widget.colors;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        color: colors.surfaceVariant.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.cloud_off_rounded,
                        size: 18,
                        color: colors.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.circle, size: 7, color: colors.textDisabled),
                      const SizedBox(width: 6),
                      Text(
                        Strings.of(context).homeOfflineChip,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: colors.textSecondary,
                          letterSpacing: 0.25,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 4,
                    runSpacing: 2,
                    children: [
                      TextButton.icon(
                        key: const ValueKey('home-offline-retry'),
                        onPressed: widget.onRetry,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: Text(s.commonRetry),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          foregroundColor: colors.accentHover,
                        ),
                      ),
                      TextButton.icon(
                        key: const ValueKey('home-offline-details'),
                        onPressed: () => setState(() => _expanded = !_expanded),
                        icon: AnimatedRotation(
                          turns: _expanded ? 0.5 : 0,
                          duration: reduceMotion
                              ? Duration.zero
                              : const Duration(milliseconds: 160),
                          curve: Curves.easeOutCubic,
                          child: const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 19,
                          ),
                        ),
                        label: Text(
                          _expanded ? s.chaErrHideDetails : s.chaErrViewDetails,
                        ),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          foregroundColor: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            AnimatedSize(
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: !_expanded
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            Strings.of(
                              context,
                            ).homeInstanceDownBody(widget.label),
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.4,
                              color: colors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          TextButton.icon(
                            onPressed: widget.onEditInstance,
                            icon: Icon(
                              Icons.settings_rounded,
                              size: 16,
                              color: colors.textSecondary,
                            ),
                            label: Text(
                              Strings.of(context).homeEditInstance,
                              style: TextStyle(
                                color: colors.textSecondary,
                                fontSize: 12.5,
                              ),
                            ),
                            style: TextButton.styleFrom(
                              minimumSize: const Size(48, 48),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
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

class _RecentGroupHeader extends StatelessWidget {
  const _RecentGroupHeader({
    required this.label,
    required this.first,
    super.key,
  });

  final String label;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      header: true,
      child: Padding(
        padding: EdgeInsets.fromLTRB(6, first ? 2 : 14, 6, 5),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.9,
            color: colors.textSecondary.withValues(alpha: 0.86),
          ),
        ),
      ),
    );
  }
}

class _RecentSessionTile extends StatelessWidget {
  final Session session;
  final String title;
  final HomeRecentSummary summary;
  final String? activityLabel;
  final String relativeTime;
  final VoidCallback onTap;
  final VoidCallback? onManage;

  const _RecentSessionTile({
    required this.session,
    required this.title,
    required this.summary,
    required this.activityLabel,
    required this.relativeTime,
    required this.onTap,
    this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final userPreview = summary.user;
    final assistantPreview = summary.assistant;
    final assistantOrActivity =
        activityLabel ??
        (assistantPreview == null
            ? null
            : projectAssistantOperationalArtifacts(
                assistantPreview,
                subagentLabel: strings.subagentActivityItem,
                resultLabel: strings.commonResult,
              ).visibleMarkdown);
    final visualPreview = assistantOrActivity ?? userPreview;

    // Fila ligera: jerarquía por texto y divisor, sin cards pesadas.
    // Semantics compone una descripción legible para TalkBack (título, turno
    // reciente y estado); ExcludeSemantics evita repeticiones.
    final tile = Semantics(
      button: true,
      onLongPress: onManage,
      label: [
        strings.homeSemanticChat(title, session.messageCount),
        ?userPreview,
        ?assistantOrActivity,
        if (session.hasLocalDraft) strings.slDraftBadge,
      ].join(', '),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onManage,
        child: ExcludeSemantics(
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: colors.divider.withValues(alpha: 0.55),
                ),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 13),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: AnimatedSize(
                    duration: reduceMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topLeft,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w500,
                            fontSize: 15,
                            color: colors.textPrimary,
                          ),
                        ),
                        AnimatedSwitcher(
                          duration: reduceMotion
                              ? Duration.zero
                              : const Duration(milliseconds: 160),
                          switchInCurve: Curves.easeOut,
                          switchOutCurve: Curves.easeIn,
                          child: visualPreview == null
                              ? const SizedBox.shrink()
                              : Padding(
                                  key: ValueKey(
                                    '${activityLabel == null ? 'preview' : 'activity'}'
                                    '-$visualPreview',
                                  ),
                                  padding: const EdgeInsets.only(top: 3),
                                  child: Text(
                                    visualPreview,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      height: 1.2,
                                      fontWeight: activityLabel == null
                                          ? FontWeight.w400
                                          : FontWeight.w600,
                                      color: activityLabel == null
                                          ? colors.textSecondary
                                          : colors.secondary,
                                    ),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (session.hasLocalDraft) ...[
                  const SizedBox(width: 8),
                  HermesPill(
                    key: ValueKey('home-draft-${session.id}'),
                    color: colors.accent,
                    label: Strings.of(context).slDraftBadge,
                    showDot: false,
                  ),
                ],
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    relativeTime,
                    // WCAG AA: el tiempo es información real → textSecondary (≥4.5:1).
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (onManage == null) return tile;
    return Dismissible(
      key: ValueKey('home-recent-swipe-${session.id}'),
      direction: DismissDirection.endToStart,
      dismissThresholds: const {DismissDirection.endToStart: 0.32},
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 18),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              strings.slSwipeManage,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(width: 7),
            Icon(Icons.tune_rounded, size: 20, color: colors.textSecondary),
          ],
        ),
      ),
      confirmDismiss: (_) async {
        onManage?.call();
        // El arrastre abre acciones; nunca modifica ni elimina por sí solo.
        return false;
      },
      child: tile,
    );
  }
}

enum _RecentAction { rename, delete }

/// Console-style welcome shown when no Gateway connections exist yet.
class _EmptyHomeState extends StatelessWidget {
  final VoidCallback onAdd;

  const _EmptyHomeState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - t)),
            child: child,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Builder(
              builder: (context) {
                final controller = context
                    .findAncestorStateOfType<HermesAppState>()
                    ?.companion;
                if (controller == null) return const SizedBox.shrink();
                return AnimatedBuilder(
                  animation: controller,
                  builder: (context, _) {
                    if (!controller.isInitialized ||
                        !controller.enabled ||
                        !controller.presenceLevel.isVisible) {
                      return const SizedBox.shrink();
                    }
                    return const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        HermesSparkMascot(mood: HermesSparkMood.idle, size: 48),
                        SizedBox(height: 14),
                      ],
                    );
                  },
                );
              },
            ),
            Text(
              Strings.of(context).homeNoInstances,
              style: TextStyle(
                fontSize: 13,
                color: colors.textSecondary,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              Strings.of(context).homePort8642,
              style: TextStyle(
                fontSize: 11,
                // Hint informativo → textSecondary (WCAG AA 4.5:1); no hay
                // nada deshabilitado aquí (spec 028 A-112).
                color: colors.textSecondary,
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(height: 14),
            TextButton.icon(
              onPressed: onAdd,
              icon: Icon(Icons.add, size: 18, color: colors.accent),
              label: Text(
                Strings.of(context).homeAddInstance,
                style: TextStyle(color: colors.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Add-gateway dialog with live validation against /health before saving.
/// Kept public so onboarding flows elsewhere can reuse it.
