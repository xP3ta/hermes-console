export '../widgets/session_status_tone.dart'
    show readableActivityTone, resolveActivityTone;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;

import '../app_header_title.dart';
import '../bots/state/attention.dart';
import '../bots/state/mission_live_chats.dart';
import '../bots/ui/room/room_launcher.dart';
import '../bots/ui/room/room_prefs.dart';
import '../design/schedule_builder.dart' show hermesFormatNextRun;
import '../home/home_now.dart';
import '../home/home_now_view.dart';
import '../home/home_sources.dart';
import '../models/agent_profile.dart';
import '../models/cron_job.dart';
import '../models/hosted_groups.dart';
import '../models/mission_control.dart';
import '../services/approval_policy.dart';
import '../services/cron_repository.dart';
import '../services/mission_snapshot_cache.dart';
import 'cron_detail_page.dart' show cronParseTime;
import 'cron_screen.dart';
import '../config/flavor.dart';
import '../models/core_read.dart';
import '../models/desktop_active_session.dart';
import '../models/home_widget_snapshot.dart';
import '../models/session_live_status.dart';
import '../navigation/chat_route.dart';
import '../navigation/enclosing_route.dart';
import '../services/active_profile_scope.dart';
import '../services/agent_runtime/agent_runtime.dart';
import '../services/agent_runtime/local_termux_agent_provider.dart';
import '../services/bot_roster_store.dart';
import '../services/bridge_update_service.dart';
import '../services/active_chat_service.dart';
import '../services/app_lock.dart';
import '../services/connection_manager.dart';
import '../services/chat_draft_store.dart';
import '../services/drawer_gesture_exclusion.dart';
import '../services/global_activity_aggregate.dart';
import '../services/home_widget_publisher.dart';
import '../services/platform/android_apps.dart';
import '../services/cold_start_store.dart';
import '../services/local_transcript_store.dart';
import '../services/session_archive.dart';
import '../services/session_repository.dart';
import '../services/session_deletion.dart';
import '../services/tui_gateway_client.dart';
import '../services/shared_gateway_pool.dart';
import '../services/mission_snapshot_prewarm.dart';
import '../theme/app_theme.dart';
import '../utils/home_recent_sessions.dart';
import '../utils/session_title.dart';
import '../widgets/onstage_gate.dart';
import '../widgets/attachment_source_sheet.dart';
import '../widgets/dock.dart';
import '../widgets/dock_shortcuts.dart';
import '../widgets/dock_style.dart' show dockShowsBack;
import '../widgets/hermes_drawer.dart';
import '../widgets/profile_scope.dart';
import '../widgets/profile_switcher.dart';
import 'profiles_screen.dart';
import '../widgets/hermes_notice.dart';
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

typedef HomeRoomApprove =
    Future<void> Function(
      SavedConnection connection, {
      required String roomId,
      required RoomApprovalAction action,
      required String choice,
    });

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
  final ActiveChatService? activeChatsOverride;
  final GlobalActivityAggregate? globalActivityOverride;
  final Future<DesktopActiveSessionList> Function()? activeSessionListLoader;
  final Stream<TuiGatewayEvent>? eventStreamOverride;

  /// Saved Dashboard login check (defaults to [checkSavedDashboardLogin]).
  final DashboardAuthProbe? dashboardAuthProbe;

  /// Bot Mode background first read (defaults to the shared one).
  final MissionSnapshotPrewarm? missionPrewarm;

  /// Writer of hidden/title/read state (defaults to
  /// [dashboardSessionStateWriter]).
  final SessionStateWriter Function(SavedConnection connection)?
  sessionStateWriterFactory;

  /// App Lock (defaults to the app's).
  final AppLockService? appLockOverride;

  /// Home screen widget writer (defaults to the app's publisher).
  final Future<void> Function(
    HermesHomeWidgetSnapshot Function(HermesHomeWidgetSnapshot current),
  )?
  homeWidgetUpdateOverride;

  /// Cron jobs for «Próximo» (defaults to the Dashboard's `cron/jobs` when
  /// Home builds its own clients).
  final Future<List<CronJob>> Function(
    SavedConnection connection,
    String profile,
  )?
  cronJobsLoader;

  /// Bots snapshot shared with Bot Mode (defaults to the shared cache).
  final MissionSnapshotCache? missionSnapshotCacheOverride;

  /// Bots roster shared with every screen (defaults to the shared one).
  final BotRosterRegistry? rosterRegistryOverride;

  /// Hosted-room approval answer (defaults to [pooledRoomApprove]).
  final HomeRoomApprove? roomApproveOverride;

  /// Opens a Bot Chat or room in Bot Mode (defaults to pushing it).
  final ValueChanged<MissionControlOpenTarget>? botsOpenOverride;

  /// Wall clock of the Home cards.
  final DateTime Function()? clockOverride;

  const HomeDashboardScreen({
    required this.connManager,
    this.clientFactory,
    this.onInitialLoadProgress,
    this.onInitialLoadComplete,
    @visibleForTesting this.activeChatsOverride,
    @visibleForTesting this.globalActivityOverride,
    @visibleForTesting this.activeSessionListLoader,
    @visibleForTesting this.eventStreamOverride,
    @visibleForTesting this.dashboardAuthProbe,
    @visibleForTesting this.missionPrewarm,
    @visibleForTesting this.sessionStateWriterFactory,
    @visibleForTesting this.appLockOverride,
    @visibleForTesting this.homeWidgetUpdateOverride,
    @visibleForTesting this.cronJobsLoader,
    @visibleForTesting this.missionSnapshotCacheOverride,
    @visibleForTesting this.rosterRegistryOverride,
    @visibleForTesting this.roomApproveOverride,
    @visibleForTesting this.botsOpenOverride,
    @visibleForTesting this.clockOverride,
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

  /// Connection whose last status check proved it online.
  String? _healthOkConnectionId;

  /// What the status line shows: «checking» only while nothing is known
  /// for the active connection (first check, after a failure, another
  /// connection). A background re-check of a healthy connection stays
  /// «online» until it fails (Desktop keeps its status too).
  bool get _statusChecking =>
      _checking &&
      !(_healthOk && _active != null && _healthOkConnectionId == _active!.id);
  bool _checking = false;

  /// Saved Dashboard login of a healthy remote instance; a rejected or
  /// missing login keeps the header pill from claiming the agent is online.
  DashboardAuthCheck _dashboardAuth = DashboardAuthCheck.unknown;
  List<Session> _recentSessions = [];

  /// The last read of the active profile's list failed while the connection
  /// answered: Home stays online and says so next to the list.
  bool _recentListFailed = false;
  SessionArchive? _archive;
  SessionListRead? _statusListRead;
  StreamSubscription<HistoryCleanupInvalidation>? _historyCleanupSubscription;
  PageRoute<dynamic>? _route;
  bool _statusRefreshOwed = false;
  bool _reloadOwed = false;
  bool _initialLoadComplete = false;
  double _initialLoadProgress = 0;
  int _reloadEpoch = 0;
  int _refreshStatusEpoch = 0;
  ActiveProfileScope? _profileScope;
  ProfileReadTicket? _statusTicket;
  final OnstageGate _activeIdsGate = OnstageGate();

  /// ss1215: an attached chat's live status changed (tool, waiting, done):
  /// repaint the recents in the same frame instead of on the next poll.
  final OnstageGate _liveStatusGate = OnstageGate();
  GlobalActivityAggregate? _listenedGlobalActivity;
  TuiGatewayClient? _ownedActivityClient;
  SharedGatewayLease? _activityLease;
  StreamSubscription<TuiGatewayEvent>? _activityEventSubscription;
  Timer? _activityEventRefreshTimer;
  Timer? _activityReconnectTimer;
  Timer? _activityStableTimer;
  Timer? _activityStaleExpiryTimer;
  final GatewayReconnectBackoff _activityReconnectBackoff =
      GatewayReconnectBackoff();
  DateTime? _lastActivityEventRefreshAt;
  String? _activityConnectionId;
  bool _foreground = true;
  bool _activityRebuildScheduled = false;

  // Inicio v3 sources (all already held by Console; see [_homeNowFor]).
  /// Bumped by every notification Home repaints for: the derived cards are
  /// recomputed only when it (or another input identity) changes.
  int _activityRevision = 0;
  List<CronJob>? _cronJobs;
  String? _cronScope;
  DateTime? _cronReadAt;
  int _cronEpoch = 0;
  List<DesktopActiveSession> _activeRoster = const [];
  DateTime? _activeRosterAt;
  final OnstageGate _homeSourcesGate = OnstageGate();
  Listenable? _homeSources;
  BotRosterStore? _homeSourcesStore;
  List<Object?>? _homeNowKey;
  HomeNow? _homeNow;
  bool _composerFocused = false;

  /// Room approvals answered from Home: hidden until a newer Bots read
  /// stops listing them (the cached snapshot does not see the answer).
  final Set<String> _answeredRoomApprovals = {};

  /// Room approvals older than this are not offered from Home: the cached
  /// Bots read could list a request already answered elsewhere.
  static const _roomApprovalMaxAge = Duration(minutes: 5);

  // Borrador del compositor de Inicio (chat nuevo sin sesión). Alcance:
  // conexión + perfil activo, como el resto de borradores v3.
  String? _homeDraftScope;
  String? _homeDraftRestoredText;
  String? _homeDraftPendingText;
  ({String connectionId, String profile})? _homeDraftPendingTarget;
  Timer? _homeDraftSaveTimer;
  int _homeDraftEpoch = 0;

  ActiveChatService? get _activeChats =>
      widget.activeChatsOverride ??
      context.findAncestorStateOfType<HermesAppState>()?.activeChats;

  AppLockService? get _appLock =>
      widget.appLockOverride ??
      context.findAncestorStateOfType<HermesAppState>()?.appLock;

  // Banner de operación local en curso (visible si el usuario salió durante install/uninstall).
  bool _installInProgress = false;
  bool _uninstallInProgress = false;

  // Arranque del agente local desde el home (cuando está instalado pero apagado).
  bool _localStarting = false;
  Timer? _localStartPoll;
  int _localStartTicks = 0;

  @override
  void dispose() {
    _flushHomeDraft();
    _missionPrewarm.cancel();
    hermesRouteObserver.unsubscribe(this);
    unawaited(DrawerGestureExclusion.setEnabled(false));
    _refreshStatusEpoch++;
    _activityEventRefreshTimer?.cancel();
    _activityReconnectTimer?.cancel();
    _activityStableTimer?.cancel();
    _activityStaleExpiryTimer?.cancel();
    unawaited(_activityEventSubscription?.cancel());
    _releaseActivityClient();
    unawaited(_historyCleanupSubscription?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    widget.connManager.activeConnectionId.removeListener(_onActiveConnChanged);
    _profileScope?.removeListener(_onActiveProfileChanged);
    _activeIdsGate.removeListener(_onActivityChanged);
    _activeIdsGate.dispose();
    _liveStatusGate.removeListener(_onActivityChanged);
    _liveStatusGate.dispose();
    _homeSourcesGate.removeListener(_onActivityChanged);
    _homeSourcesGate.dispose();
    _cronEpoch++;
    _listenedGlobalActivity?.removeListener(_onActivityChanged);
    _archive?.removeListener(_onActivityChanged);
    _archive?.removeListener(_dropDeletedRecents);
    _detachStateWriter();
    _statusListRead?.end();
    _localStartPoll?.cancel();
    _cancelColdStartUnlockRetry();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final activeChats = _activeChats;
    // `activeIds` is force-notified on every subagent event of a run. While a
    // chat covers Home, hold those notifications and deliver one on return.
    _activeIdsGate.bind(context, activeChats?.activeIds);
    _liveStatusGate.bind(context, activeChats?.liveStatusRevision);
    _bindHomeSources();
    final aggregate =
        widget.globalActivityOverride ?? activeChats?.globalActivity;
    if (!identical(_listenedGlobalActivity, aggregate)) {
      _listenedGlobalActivity?.removeListener(_onActivityChanged);
      _listenedGlobalActivity = aggregate;
      aggregate?.addListener(_onActivityChanged);
    }
  }

  /// The route arrives through [EnclosingRoute] instead of
  /// `ModalRoute.of(context)` here: that call made all of Home depend on the
  /// route status and rebuild in the first frame of every push over it and
  /// every pop back to it (the dock transitions).
  void _attachRoute(ModalRoute<Object?>? route) {
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
    // cs1215: Home is on screen again; a cold start opens Home.
    final connectionId = widget.connManager.activeConnectionId.value;
    if (connectionId != null) {
      unawaited(
        _activeChats?.coldStartStore
            ?.forgetRoute(connectionId)
            .catchError((Object _) {}),
      );
    }
    // Volver de cualquier pantalla empujada (Conversaciones, un chat, Bots…)
    // no refrescaba los recientes de Inicio por sí solo — solo lo hacían los
    // sitios que encadenaban `.then(() => _refreshStatus())` a su propio
    // `Navigator.push`, y el drawer (usado desde varias pantallas, no solo
    // Inicio) nunca lo encadenaba. Resultado: borrar una conversación en
    // Conversaciones no la quitaba de Inicio hasta forzar un refresco manual
    // (reportado en dispositivo real). `RouteAware.didPopNext` es justo el
    // gancho para esto — se dispara siempre que esta pantalla vuelve a ser
    // visible, sin depender de qué call site abrió la pantalla anterior.
    _refreshWhenUncovered();
    _scheduleActivityReconnect(immediate: true);
  }

  /// Refreshes Home once the screen above it has finished sliding away
  /// (see [runWhenUncovered]): refreshing when the pop started rebuilt all
  /// of Home inside the back transition, the stutter seen when returning
  /// through the dock. The triggers of one return (`didPopNext` and the
  /// `.then` of the push) are coalesced: one status refresh, or the full
  /// reload a screen asked for.
  void _refreshWhenUncovered({bool reload = false}) {
    if (!mounted) return;
    if (reload) {
      _reloadOwed = true;
    } else {
      _statusRefreshOwed = true;
    }
    // Each trigger waits on its own; the first to run takes what is owed.
    runWhenUncovered(context, _route, () {
      if (mounted) _runOwedRefresh();
    });
  }

  void _runOwedRefresh() {
    final reload = _reloadOwed;
    final refresh = _statusRefreshOwed;
    _reloadOwed = false;
    _statusRefreshOwed = false;
    // `_reload` ends with its own status refresh.
    if (reload) {
      _reload();
    } else if (refresh) {
      unawaited(_refreshStatus());
    }
  }

  @override
  void didPushNext() {
    _activityEventRefreshTimer?.cancel();
    _activityEventRefreshTimer = null;
    _activityReconnectTimer?.cancel();
    _activityReconnectTimer = null;
    _activityStableTimer?.cancel();
    _activityStableTimer = null;
    unawaited(DrawerGestureExclusion.setEnabled(false));
  }

  @override
  void didPop() => unawaited(DrawerGestureExclusion.setEnabled(false));

  @override
  void initState() {
    super.initState();
    _activeIdsGate.addListener(_onActivityChanged);
    _liveStatusGate.addListener(_onActivityChanged);
    _homeSourcesGate.addListener(_onActivityChanged);
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
    _missionPrewarm.cancel();
    if (mounted) _reload();
  }

  /// Follows the active profile of [connection]. A switch re-scopes Home the
  /// same way a connection change does: recents, draft and activity.
  void _followProfileScope(SavedConnection? connection) {
    final next = connection == null
        ? null
        : ActiveProfileScope.of(widget.connManager, connection.id);
    if (identical(next, _profileScope)) return;
    _profileScope?.removeListener(_onActiveProfileChanged);
    _profileScope = next;
    next?.addListener(_onActiveProfileChanged);
  }

  void _onActiveProfileChanged() {
    _missionPrewarm.cancel();
    if (!mounted) return;
    // The previous profile's recents (and its list error) leave at once;
    // the new ones follow.
    setState(() {
      _recentSessions = [];
      _recentListFailed = false;
      _cronJobs = null;
      _cronReadAt = null;
      _answeredRoomApprovals.clear();
    });
    _reload();
  }

  MissionSnapshotPrewarm get _missionPrewarm =>
      widget.missionPrewarm ?? MissionSnapshotPrewarm.shared;

  /// Once Home is healthy and idle, read Bot Mode in the background if the
  /// user has used it on this connection, so its first entry is instant.
  void _scheduleMissionPrewarm(SavedConnection conn) {
    _missionPrewarm.schedule(
      prefs: widget.connManager.prefs,
      connection: conn,
      stillIdle: () =>
          _activityRefreshAllowed && _healthOk && _active?.id == conn.id,
    );
  }

  void _onActivityChanged() {
    _activityRevision++;
    if (!mounted || _activityRebuildScheduled) return;
    // ss1215: outside a frame (a gateway event, a timer) repaint in the next
    // frame directly; only a notification raised while building is deferred.
    // The post-frame path used to wait for some unrelated frame, so Inicio
    // could keep a finished chat «working» until the user touched the screen.
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      setState(() {});
      return;
    }
    _activityRebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _activityRebuildScheduled = false;
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool get _activityRefreshAllowed =>
      mounted && _foreground && _route?.isCurrent != false;

  void _configureActivitySource(SavedConnection? connection) {
    if (_activityConnectionId == connection?.id) return;
    _activityConnectionId = connection?.id;
    _activityEventRefreshTimer?.cancel();
    _activityEventRefreshTimer = null;
    _activityReconnectTimer?.cancel();
    _activityReconnectTimer = null;
    _activityStableTimer?.cancel();
    _activityStableTimer = null;
    _activityReconnectBackoff.markHealthy();
    _lastActivityEventRefreshAt = null;
    unawaited(_activityEventSubscription?.cancel());
    _activityEventSubscription = null;
    _releaseActivityClient();
    if (connection == null) return;

    if (widget.clientFactory == null &&
        (widget.activeSessionListLoader == null ||
            widget.eventStreamOverride == null)) {
      final lease = SharedGatewayPool.instance.acquire(connection);
      _activityLease = lease;
      _ownedActivityClient = lease.client;
    }
    final stream = widget.eventStreamOverride ?? _ownedActivityClient?.events;
    _activityEventSubscription = stream?.listen(
      _onActivityEvent,
      onError: (_) => _markActivityTransportStale(connection.id),
    );
    final client = _ownedActivityClient;
    if (client != null) {
      unawaited(_connectActivityClient(client, connection.id));
    }
  }

  void _releaseActivityClient() {
    _activityLease?.release();
    _activityLease = null;
    _ownedActivityClient = null;
  }

  Future<void> _connectActivityClient(
    TuiGatewayClient client,
    String connectionId,
  ) async {
    try {
      await client.connect();
      if (_activityConnectionId != connectionId || !_activityRefreshAllowed) {
        return;
      }
      _activityStableTimer?.cancel();
      _activityStableTimer = Timer(GatewayReconnectBackoff.stableInterval, () {
        _activityStableTimer = null;
        if (_activityConnectionId == connectionId && _activityRefreshAllowed) {
          _activityReconnectBackoff.markHealthy();
        }
      });
      final connection = _active;
      // A good read does not reset the backoff: only [_activityStableTimer]
      // (30 s connected) does, so a socket that drops after each read keeps
      // growing its delay instead of reconnecting at 0-1 s forever.
      if (connection != null) {
        await _refreshRemoteActivity(
          connection,
          Session.profileOwner(
            widget.connManager.activeProfileFor(connection.id),
          ),
        );
      }
    } catch (_) {
      _markActivityTransportStale(connectionId);
    }
  }

  void _scheduleActivityReconnect({bool immediate = false}) {
    final client = _ownedActivityClient;
    final connectionId = _activityConnectionId;
    if (!_activityRefreshAllowed ||
        client == null ||
        connectionId == null ||
        client.isConnected ||
        _activityReconnectTimer != null) {
      return;
    }
    final ownDelay = immediate
        ? Duration.zero
        : _activityReconnectBackoff.nextDelay();
    final ownerDelay = client.reconnectBackoffRemaining;
    final delay = ownerDelay > ownDelay ? ownerDelay : ownDelay;
    _activityReconnectTimer = Timer(delay, () {
      _activityReconnectTimer = null;
      if (_activityRefreshAllowed && _activityConnectionId == connectionId) {
        unawaited(_connectActivityClient(client, connectionId));
      }
    });
  }

  void _markActivityTransportStale(String connectionId) {
    if (_activityConnectionId != connectionId) return;
    _activityStableTimer?.cancel();
    _activityStableTimer = null;
    final profile = Session.profileOwner(
      widget.connManager.activeProfileFor(connectionId),
    );
    _listenedGlobalActivity?.markTransportStale(connectionId, profile);
    _activityStaleExpiryTimer?.cancel();
    _activityStaleExpiryTimer = Timer(
      GlobalActivityAggregate.staleLivenessCeiling,
      () {
        _activityStaleExpiryTimer = null;
        if (mounted) setState(() {});
      },
    );
    _scheduleActivityReconnect();
  }

  void _onActivityEvent(TuiGatewayEvent event) {
    final connection = _active;
    if (connection == null || !_activityRefreshAllowed) return;
    final profile = Session.profileOwner(
      widget.connManager.activeProfileFor(connection.id),
    );
    final routed =
        _listenedGlobalActivity?.observeGatewayEvent(
          connectionId: connection.id,
          profile: profile,
          event: event,
        ) ??
        true;
    if (event.sessionId.isNotEmpty && !routed) {
      unawaited(_refreshRemoteActivity(connection, profile));
    }
    if (!isSessionLibraryRefreshEvent(event)) return;
    final now = DateTime.now();
    final last = _lastActivityEventRefreshAt;
    final elapsed = last == null
        ? sessionLibraryRefreshGap
        : now.difference(last);
    if (last == null || elapsed >= sessionLibraryRefreshGap) {
      _activityEventRefreshTimer?.cancel();
      _activityEventRefreshTimer = null;
      _lastActivityEventRefreshAt = now;
      unawaited(_refreshStatus());
      return;
    }
    _activityEventRefreshTimer ??= Timer(
      sessionLibraryRefreshGap - elapsed,
      () {
        _activityEventRefreshTimer = null;
        _lastActivityEventRefreshAt = DateTime.now();
        if (_activityRefreshAllowed) unawaited(_refreshStatus());
      },
    );
  }

  Future<bool> _refreshRemoteActivity(
    SavedConnection connection,
    String profile,
  ) async {
    final aggregate = _listenedGlobalActivity;
    final loader =
        widget.activeSessionListLoader ??
        (_ownedActivityClient == null
            ? null
            : () => _ownedActivityClient!.listActiveSessions());
    if (!_activityRefreshAllowed || aggregate == null || loader == null) {
      return false;
    }
    final generation = aggregate.beginRosterRequest(connection.id, profile);
    try {
      final roster = await loader();
      if (!_activityRefreshAllowed || _activityConnectionId != connection.id) {
        return false;
      }
      aggregate.applyRoster(
        connectionId: connection.id,
        profile: profile,
        replayEpoch: _ownedActivityClient?.currentReplayEpoch ?? 'current',
        requestGeneration: generation,
        roster: roster,
      );
      // The same read feeds the team faces (every live session of the
      // gateway process, whichever profile).
      if (!roster.hasMalformedRows && mounted) {
        setState(() {
          _activeRoster = roster.sessions;
          _activeRosterAt = DateTime.now();
          _activityRevision++;
        });
      }
      if (roster.hasMalformedRows) {
        _markActivityTransportStale(connection.id);
      } else {
        _activityStaleExpiryTimer?.cancel();
        _activityStaleExpiryTimer = null;
      }
      return true;
    } catch (_) {
      _markActivityTransportStale(connection.id);
      return false;
    }
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
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // Android puede matar el proceso en segundo plano: vuelca ya.
      _flushHomeDraft();
    }
    if (!_foreground) {
      _missionPrewarm.cancel();
      _activityEventRefreshTimer?.cancel();
      _activityEventRefreshTimer = null;
      _activityReconnectTimer?.cancel();
      _activityReconnectTimer = null;
      _activityStableTimer?.cancel();
      _activityStableTimer = null;
      _activityStaleExpiryTimer?.cancel();
      _activityStaleExpiryTimer = null;
      return;
    }
    // Al volver de segundo plano re-comprobamos la salud: una instancia que
    // sigue viva (p.ej. el agente local con wake-lock) vuelve a "online" sola,
    // sin obligar al usuario a reconectar a mano cada vez que reabre la app.
    if (_active != null && !_checking) _refreshStatus();
    _scheduleActivityReconnect(immediate: true);
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
      _followProfileScope(active);
      _configureActivitySource(active);
      _reportInitialLoadProgress(0.64);
      // cs1215: the last known recents paint while the network read runs;
      // neither waits for the other.
      final refresh = _refreshStatus();
      await _paintColdStartRecents(active, epoch);
      await refresh;
    } finally {
      if (epoch == _reloadEpoch) _completeInitialLoad();
    }
  }

  /// Ends the initial loading state once (lets the splash leave).
  void _completeInitialLoad() {
    if (!mounted || _initialLoadComplete) return;
    final epoch = _reloadEpoch;
    setState(() => _initialLoadComplete = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || epoch != _reloadEpoch) return;
      widget.onInitialLoadProgress?.call(1);
      widget.onInitialLoadComplete?.call();
    });
  }

  /// Rows on screen came from the cold-start snapshot, not a list read yet.
  bool _showingColdStartRecents = false;

  /// cs1215: a cold start paints the recents Home last showed for the
  /// persisted connection and profile (encrypted on disk), so first paint
  /// never waits for the network. The list read then replaces them.
  Future<void> _paintColdStartRecents(
    SavedConnection? connection,
    int epoch,
  ) async {
    final store = _activeChats?.coldStartStore;
    if (connection == null || store == null || _initialLoadComplete) return;
    _cancelColdStartUnlockRetry();
    final lock = _appLock;
    // Under App Lock nothing private is decrypted before unlock, and a
    // lock engaged during the reads discards what they returned (checked
    // again after the last await, right before painting; nothing is
    // published in between). Unlocking retries from the cache only; the
    // network read already in flight is not repeated.
    bool lockedOrStale(ProfileReadTicket ticket) {
      if (!mounted ||
          _initialLoadComplete ||
          epoch != _reloadEpoch ||
          _active?.id != connection.id ||
          !ticket.isCurrent) {
        return true;
      }
      if (lock?.locked.value != true) return false;
      _retryColdStartRecentsOnUnlock(lock!, connection, epoch);
      return true;
    }

    final ticket = ActiveProfileScope.of(
      widget.connManager,
      connection.id,
    ).capture();
    if (lockedOrStale(ticket)) return;
    List<Session>? cached;
    SessionArchive archive;
    try {
      cached = await store.loadRecents(
        connectionId: connection.id,
        profile: ticket.owner,
      );
      archive = await SessionArchive.load(
        widget.connManager.prefs,
        connection.id,
      );
    } catch (error) {
      debugPrint('[home-dashboard] cold-start recents (${error.runtimeType})');
      return;
    }
    if (lockedOrStale(ticket)) return;
    final rows = (cached ?? const <Session>[])
        .where((s) => _isHomeRecentCandidate(s, archive))
        .toList();
    if (rows.isEmpty) return;
    setState(() {
      _recentSessions = rows;
      _showingColdStartRecents = true;
    });
    _completeInitialLoad();
  }

  ValueNotifier<bool>? _coldStartLockWatched;
  VoidCallback? _coldStartUnlockRetry;

  /// Tries the cold-start recents again once App Lock is lifted;
  /// [_paintColdStartRecents] skips them if the first list landed or
  /// [epoch] is over by then.
  void _retryColdStartRecentsOnUnlock(
    AppLockService lock,
    SavedConnection connection,
    int epoch,
  ) {
    _cancelColdStartUnlockRetry();
    // Registered while locked, so the first change is the unlock.
    void retry() {
      _cancelColdStartUnlockRetry();
      if (mounted) unawaited(_paintColdStartRecents(connection, epoch));
    }

    _coldStartLockWatched = lock.locked..addListener(retry);
    _coldStartUnlockRetry = retry;
  }

  void _cancelColdStartUnlockRetry() {
    final retry = _coldStartUnlockRetry;
    if (retry != null) _coldStartLockWatched?.removeListener(retry);
    _coldStartLockWatched = null;
    _coldStartUnlockRetry = null;
  }

  /// Saves what Home just read from the server for the next cold start.
  void _saveColdStartRecents(
    SavedConnection connection,
    String owner,
    List<Session> listed,
    List<Session> recents,
    SessionArchive archive,
  ) {
    final store = _activeChats?.coldStartStore;
    if (store == null || connection.kind == InstanceKind.localhost) return;
    final listedIds = {for (final s in listed) s.id};
    final rows = recents
        .where(
          (s) => listedIds.contains(s.id) && _isHomeRecentCandidate(s, archive),
        )
        .take(ColdStartStore.maxRecentRows)
        .toList(growable: false);
    unawaited(
      store
          .saveRecents(
            connectionId: connection.id,
            profile: owner,
            sessions: rows,
          )
          .catchError((Object error) {
            debugPrint(
              '[home-dashboard] recents not saved (${error.runtimeType})',
            );
          }),
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

  /// A status refresh only paints while it is the newest one, for the same
  /// connection AND the same active profile: a list read for the previous
  /// profile must never land on the new one.
  bool _isCurrentStatusRefresh(int epoch, String? connectionId) =>
      mounted &&
      epoch == _refreshStatusEpoch &&
      _active?.id == connectionId &&
      (_statusTicket?.isCurrent ?? true);

  Future<void> _refreshStatus() async {
    final refreshEpoch = ++_refreshStatusEpoch;
    final conn = _active;
    final connectionId = conn?.id;
    _statusTicket = conn == null
        ? null
        : ActiveProfileScope.of(widget.connManager, conn.id).capture();
    final app = context.findAncestorStateOfType<HermesAppState>();
    final updateHomeWidget =
        widget.homeWidgetUpdateOverride ?? app?.updateHomeWidget;
    if (conn == null) {
      if (!_isCurrentStatusRefresh(refreshEpoch, connectionId)) return;
      setState(() {
        _healthOk = false;
        _healthOkConnectionId = null;
        _dashboardAuth = DashboardAuthCheck.unknown;
        _checking = false;
        _recentSessions = [];
        _recentListFailed = false;
      });
      unawaited(
        updateHomeWidget?.call(
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
    // The launcher widget follows the status line: a re-check of a
    // connection already proven online keeps it online and writes nothing
    // until the result lands, so the widget neither blinks nor redraws.
    if (_statusChecking) {
      unawaited(
        updateHomeWidget?.call(
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
    }
    final archive = await SessionArchive.load(
      widget.connManager.prefs,
      conn.id,
    );
    // Open until this refresh stores its rows, or a newer refresh or
    // dispose drops them (see SessionArchive.beginListRead).
    _statusListRead?.end();
    final listRead = _statusListRead = archive.beginListRead();
    if (!_isCurrentStatusRefresh(refreshEpoch, connectionId)) return;
    bool ok = false;
    // /health answered but the paged list did not (timeout, 5xx, reset).
    // The server is reachable: keep the last known list instead of flipping
    // Home to offline on every slow refresh (#1215).
    var listReadUnavailable = false;
    Future<DashboardAuthCheck>? dashboardAuthFuture;
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
        ApiClient(
          baseUrl: conn.baseUrl,
          apiKey: conn.apiKey,
          // A named profile's list comes from the Dashboard, as on Desktop.
          profileDashboard: DashboardClient.lazy(conn),
        );
    final ownerProfile =
        _statusTicket?.owner ??
        Session.profileOwner(widget.connManager.activeProfileFor(conn.id));
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
        // The paged session list below is an authenticated read, so it is
        // the auth proof: a rejected key throws and leaves Home offline.
        ok = await client.healthReachable();
        if (!_isCurrentStatusRefresh(refreshEpoch, connectionId)) return;
        if (ok) {
          dashboardAuthFuture =
              (widget.dashboardAuthProbe ??
                      (c) => checkSavedDashboardLogin(widget.connManager, c))
                  .call(conn);
          try {
            // Home shows the newest chats only: one Desktop-sized page
            // (`listSessions(limit = 40)`), plus a bounded follow-up when
            // automation rows fill it. Deep links, notifications and Bot
            // Mode resolve their session directly, never through this list.
            final wanted = _homeRecentLimit();
            sessions = await client.getSessions(
              profile: ownerProfile,
              pageSize: homeSessionPageSize,
              maxPages: homeSessionMaxPages,
              enough: (rows) =>
                  rows
                      .where((row) => _isHomeRecentCandidate(row, archive))
                      .length >=
                  wanted,
            );
          } on CoreReadException catch (error) {
            // A rejected key is a real outage of this connection. A named
            // profile's list has its own credentials (its Dashboard scope):
            // its refusal leaves the connection online with a list error.
            if ((error.kind == CoreReadErrorKind.auth ||
                    error.kind == CoreReadErrorKind.forbidden) &&
                ownerProfile == 'default') {
              rethrow;
            }
            listReadUnavailable = true;
          } on TimeoutException {
            listReadUnavailable = true;
          } on http.ClientException {
            listReadUnavailable = true;
          } on SocketException {
            listReadUnavailable = true;
          } catch (_) {
            // Any other refusal of a named profile's list (Dashboard login,
            // malformed page) is that profile's, not the connection's.
            if (ownerProfile == 'default') rethrow;
            listReadUnavailable = true;
          }
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
        // Los informes de cron y demás fuentes de automatización (kanban,
        // subagent, tool, acp, hermes_flow, vulcan_delegate, webhook) tienen
        // su propio apartado en Conversaciones > Automatización/Todo. Antes
        // solo se excluía `isJob` (cron), así que una tarea de Kanban o una
        // sesión de herramienta/subagente sí aparecía aquí pero no en la
        // pestaña "Chats" de Conversaciones (la que abre "Ver todas" por
        // defecto) — el "aparece en Inicio y luego no está" reportado en
        // dispositivo real. Mismo criterio que `SessionCategory.chats`.
        // Local archive/hidden state is applied when painting, from the
        // shared store, so a change made on another screen shows here at once.
        .where(_isHomeRecentKind)
        .toList();
    if (!_isCurrentStatusRefresh(refreshEpoch, connectionId)) return;
    // The login check can take seconds on a slow Dashboard: apply it when it
    // lands instead of holding the whole status refresh.
    if (ok && dashboardAuthFuture != null) {
      unawaited(
        dashboardAuthFuture.catchError((_) => DashboardAuthCheck.unknown).then((
          auth,
        ) {
          if (!_isCurrentStatusRefresh(refreshEpoch, connectionId)) return;
          setState(() => _dashboardAuth = auth);
        }),
      );
    }
    setState(() {
      _healthOk = ok;
      _healthOkConnectionId = ok ? conn.id : null;
      if (!ok) _dashboardAuth = DashboardAuthCheck.unknown;
      _checking = false;
      _listenArchive(archive, conn);
      // An unreachable server keeps the cold-start rows on screen instead
      // of an empty Home; the next good read replaces them.
      if (!listReadUnavailable && (ok || !_showingColdStartRecents)) {
        _recentSessions = recentSessions
            .where((s) => !archive.isSessionDeleted(s))
            .toList();
        _showingColdStartRecents = false;
      }
      _recentListFailed = ok && listReadUnavailable;
    });
    listRead.end(rows: listReadUnavailable ? const [] : sessions);
    if (ok && !listReadUnavailable) {
      _saveColdStartRecents(
        conn,
        ownerProfile,
        sessions,
        recentSessions,
        archive,
      );
    }
    // The recents are what the splash waits for; the live activity roster
    // below decorates them when it lands.
    _completeInitialLoad();
    if (ok) {
      _scheduleMissionPrewarm(conn);
      unawaited(_refreshCron(conn));
    }
    await _refreshRemoteActivity(conn, ownerProfile);
    if (!_isCurrentStatusRefresh(refreshEpoch, connectionId)) return;
    unawaited(
      updateHomeWidget?.call(
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
    if (listReadUnavailable) return;
  }

  bool _isHomeRecentCandidate(Session s, SessionArchive archive) =>
      _isHomeRecentKind(s) &&
      !archive.isSessionDeleted(s) &&
      !archive.isSessionHidden(s) &&
      !archive.isSessionArchived(s) &&
      !archive.isHidden(s.id);

  static bool _isHomeRecentKind(Session s) =>
      !s.isAutomation && s.listsAsOwnRow;

  /// Recents as painted: the retained page filtered by the shared local
  /// archive store (archive, hidden).
  List<Session> get _visibleRecentSessions {
    final archive = _archive;
    if (archive == null) return _recentSessions;
    return _recentSessions
        .where((s) => _isHomeRecentCandidate(s, archive))
        .toList(growable: false);
  }

  SessionStateWriter? _stateWriter;

  void _detachStateWriter() {
    final writer = _stateWriter;
    _stateWriter = null;
    if (writer != null) _archive?.detachRemoteState(writer);
  }

  /// Follows the connection's shared [SessionArchive]: a rename, archive or
  /// hide made on any screen repaints the recents without a network read.
  ///
  /// Also lends it a writer, so a hide, rename or read made from Home (or a
  /// chat opened from it) reaches the server as Desktop's would.
  void _listenArchive(SessionArchive archive, SavedConnection conn) {
    if (identical(_archive, archive)) return;
    _archive?.removeListener(_onActivityChanged);
    _archive?.removeListener(_dropDeletedRecents);
    _detachStateWriter();
    if (!conn.readOnly) {
      final writer = _stateWriter =
          (widget.sessionStateWriterFactory ?? dashboardSessionStateWriter)(
            conn,
          );
      archive.attachRemoteState(writer, httpStatusOf: dashboardHttpStatusOf);
    }
    _archive = archive;
    archive.addListener(_dropDeletedRecents);
    archive.addListener(_onActivityChanged);
  }

  /// A delete made on any screen leaves the retained page itself, not only
  /// the painted recents, so it cannot return once its tombstone goes.
  void _dropDeletedRecents() {
    final archive = _archive;
    if (archive == null || !_recentSessions.any(archive.isSessionDeleted)) {
      return;
    }
    _recentSessions = _recentSessions
        .where((s) => !archive.isSessionDeleted(s))
        .toList();
  }

  int _homeRecentLimit() {
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return homeRecentSessionLimit(
      viewportHeight: MediaQuery.sizeOf(context).height,
      textScale: textScale,
    );
  }

  GlobalActivity? _globalActivityFor(
    SavedConnection connection,
    Session session,
  ) {
    final aggregate = _listenedGlobalActivity;
    if (aggregate == null) return null;
    final profile = Session.profileOwner(session.profile);
    for (final id in <String>{session.id, session.logicalId}) {
      if (aggregate.isActive(connection.id, profile, id)) {
        return aggregate.activityFor(connection.id, profile, id);
      }
    }
    return null;
  }

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
    ).then((_) => _refreshWhenUncovered());
  }

  ({String connectionId, String profile})? _homeDraftTarget() {
    final conn = _active;
    if (conn == null) return null;
    return (
      connectionId: conn.id,
      profile: Session.profileOwner(
        widget.connManager.activeProfileFor(conn.id),
      ),
    );
  }

  /// Carga el borrador de Inicio cuando cambia conexión/perfil. Idempotente.
  void _ensureHomeDraftLoaded() {
    final target = _homeDraftTarget();
    final scope = target == null
        ? null
        : '${target.connectionId}\u0000${target.profile}';
    if (scope == _homeDraftScope) return;
    _flushHomeDraft();
    _homeDraftScope = scope;
    _homeDraftRestoredText = null;
    final epoch = ++_homeDraftEpoch;
    if (target == null) return;
    unawaited(() async {
      try {
        final draft = await ChatDraftStore(widget.connManager.prefs).load(
          target.connectionId,
          ChatDraftStore.newChatDraftSessionId,
          profile: target.profile,
        );
        if (!mounted || epoch != _homeDraftEpoch) return;
        if (draft.text.isEmpty) return;
        setState(() => _homeDraftRestoredText = draft.text);
      } catch (error) {
        debugPrint(
          '[home-dashboard] home draft load failed (${error.runtimeType})',
        );
      }
    }());
  }

  void _onHomeDraftChanged(String text) {
    final target = _homeDraftTarget();
    if (_homeDraftScope == null || target == null) return;
    // El destino se fija al escribir: un cambio de conexión/perfil posterior
    // no puede volcar este texto en el borrador de otra autoridad.
    _homeDraftPendingTarget = target;
    _homeDraftPendingText = text;
    _homeDraftSaveTimer?.cancel();
    if (text.isEmpty) {
      // Vaciar (o enviar) borra ya: no puede resucitar tras un kill.
      _flushHomeDraft();
      return;
    }
    _homeDraftSaveTimer = Timer(
      const Duration(milliseconds: 400),
      _flushHomeDraft,
    );
  }

  void _flushHomeDraft() {
    _homeDraftSaveTimer?.cancel();
    _homeDraftSaveTimer = null;
    final text = _homeDraftPendingText;
    final target = _homeDraftPendingTarget;
    if (text == null || target == null) return;
    _homeDraftPendingText = null;
    _homeDraftPendingTarget = null;
    final store = ChatDraftStore(widget.connManager.prefs);
    final Future<void> write = text.isEmpty
        ? store.clear(
            target.connectionId,
            ChatDraftStore.newChatDraftSessionId,
            profile: target.profile,
          )
        : store.save(
            target.connectionId,
            ChatDraftStore.newChatDraftSessionId,
            text,
            const [],
            profile: target.profile,
          );
    unawaited(
      write.catchError((Object error) {
        debugPrint(
          '[home-dashboard] home draft save failed (${error.runtimeType})',
        );
      }),
    );
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

  /// The calm card's «Pregunta a Hermes…»: the existing Home composer
  /// (draft, attachments, dictation, voice) that starts a new chat.
  Widget _buildComposer({required bool enabled, required bool dimmed}) {
    _ensureHomeDraftLoaded();
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      // While the user types, the card stays the composer (see
      // [_heroWhileTyping]); only a change of focus repaints Home.
      onFocusChange: (focused) {
        if (focused != _composerFocused) {
          setState(() => _composerFocused = focused);
        }
      },
      child: Opacity(
        opacity: dimmed ? 0.55 : 1,
        child: HomePromptComposer(
          key: ValueKey('home-prompt-composer-${_homeDraftScope ?? ''}'),
          restoredText: _homeDraftRestoredText,
          onTextChanged: _onHomeDraftChanged,
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
      ),
    );
  }

  /// The pet rests on the hero card, as it rested on the composer before.
  Widget _buildCompanionStage(Widget composer) {
    final colors = Theme.of(context).hermes;
    final app = context.findAncestorStateOfType<HermesAppState>();
    final controller = app?.companion;
    final presence = app?.companionPresence;
    final connectionMood = _statusChecking
        ? HermesSparkMood.connecting
        : _healthOk
        ? HermesSparkMood.idle
        : HermesSparkMood.offline;

    if (controller == null) return composer;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final reduceMotion = MediaQuery.disableAnimationsOf(context);
        final view = View.maybeOf(context);
        final rawKeyboardInset = view?.viewInsets.bottom ?? 0;
        final keyboardVisible =
            MediaQuery.viewInsetsOf(context).bottom > 0 || rawKeyboardInset > 0;
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

  /// Active profile as the chip names it (Desktop `profileLabel`), for the
  /// status line: the connection label would name the wrong profile.
  String _activeProfileLabel(BuildContext context) {
    final conn = _active;
    if (conn == null) return '';
    return activeProfileDisplayLabel(
      Strings.of(context),
      ActiveProfileScope.of(widget.connManager, conn.id).name,
      BotRosterRegistry.shared.store(conn.id).profiles,
    );
  }

  /// Rebuilds [builder] when the active profile or its roster changes.
  Widget _followsActiveProfile(WidgetBuilder builder) {
    final conn = _active;
    if (conn == null) return Builder(builder: builder);
    return ListenableBuilder(
      listenable: Listenable.merge([
        ActiveProfileScope.of(widget.connManager, conn.id),
        BotRosterRegistry.shared.store(conn.id),
      ]),
      builder: (context, _) => builder(context),
    );
  }

  DateTime _clock() => (widget.clockOverride ?? DateTime.now)();

  MissionSnapshotCache get _missionCache =>
      widget.missionSnapshotCacheOverride ?? MissionSnapshotCache.shared;

  BotRosterRegistry get _rosterRegistry =>
      widget.rosterRegistryOverride ?? BotRosterRegistry.shared;

  /// Home repaints when Bot Mode publishes a read, a room is marked seen or
  /// the shared roster changes; held while Home is covered.
  void _bindHomeSources() {
    final connectionId =
        _active?.id ?? widget.connManager.activeConnectionId.value;
    final store = connectionId == null
        ? null
        : _rosterRegistry.store(connectionId);
    if (_homeSources == null || !identical(store, _homeSourcesStore)) {
      _homeSourcesStore = store;
      _homeSources = Listenable.merge([
        _missionCache.revision,
        RoomLocalPrefs.changes,
        ?store,
      ]);
    }
    _homeSourcesGate.bind(context, _homeSources);
  }

  /// One cron list read per minute at most, for «Próximo».
  Future<void> _refreshCron(SavedConnection conn) async {
    final loader =
        widget.cronJobsLoader ??
        (widget.clientFactory == null ? _defaultCronLoader : null);
    if (loader == null || conn.kind == InstanceKind.localhost) return;
    final profile = widget.connManager.activeProfileFor(conn.id);
    final scope = '${conn.id}\u0000$profile';
    final now = DateTime.now();
    final last = _cronReadAt;
    if (scope == _cronScope &&
        last != null &&
        now.difference(last) < const Duration(minutes: 1)) {
      return;
    }
    _cronReadAt = now;
    final epoch = ++_cronEpoch;
    List<CronJob>? jobs;
    try {
      jobs = await loader(conn, profile);
    } catch (error) {
      debugPrint('[home-dashboard] cron list failed (${error.runtimeType})');
      jobs = null;
    }
    if (!mounted || epoch != _cronEpoch || _active?.id != conn.id) return;
    setState(() {
      _cronJobs = jobs;
      _cronScope = scope;
      _activityRevision++;
    });
  }

  static Future<List<CronJob>> _defaultCronLoader(
    SavedConnection conn,
    String profile,
  ) async {
    final client = DashboardClient.lazy(conn);
    try {
      return await CronRepository(client, profile: profile).listJobs();
    } finally {
      client.close();
    }
  }

  /// The light Home's derived state, recomputed only when one of its
  /// inputs changed (notification revision, list identities, approvals,
  /// the minute): a rebuild for anything else reuses it.
  HomeNow _homeNowFor(SavedConnection conn) {
    final service = _activeChats;
    final now = _clock();
    final readOnly = conn.readOnly;
    final ownerProfile = Session.profileOwner(
      widget.connManager.activeProfileFor(conn.id),
    );
    final snapshot = _missionCache.read(conn);
    final store = _rosterRegistry.store(conn.id);
    final recents = _recentSessions;
    final chats = service == null
        ? const <ActiveChat>[]
        : missionActiveChats(service, conn.id, recents).toList();
    final key = <Object?>[
      _activityRevision,
      conn.id,
      ownerProfile,
      readOnly,
      recents,
      _archive,
      _cronJobs,
      _activeRoster,
      snapshot,
      store.snapshot,
      _answeredRoomApprovals.length,
      service?.liveStatusRevision.value,
      service?.activeIds.value,
      RoomLocalPrefs.changes.value,
      now.millisecondsSinceEpoch ~/ Duration.millisecondsPerMinute,
      Localizations.localeOf(context),
      for (final chat in chats) chat.pendingApproval,
    ];
    final cached = _homeNow;
    if (cached != null && _sameKey(key, _homeNowKey)) return cached;
    final derived = _deriveHomeNow(
      conn,
      service: service,
      chats: chats,
      snapshot: snapshot,
      store: store,
      now: now,
      readOnly: readOnly,
    );
    _homeNowKey = key;
    _homeNow = derived;
    return derived;
  }

  static bool _sameKey(List<Object?> a, List<Object?>? b) {
    if (b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x is List || x is Map || x is Set) {
        if (!identical(x, y)) return false;
      } else if (x != y) {
        return false;
      }
    }
    return true;
  }

  HomeNow _deriveHomeNow(
    SavedConnection conn, {
    required ActiveChatService? service,
    required List<ActiveChat> chats,
    required MissionBackendSnapshot? snapshot,
    required BotRosterStore store,
    required DateTime now,
    required bool readOnly,
  }) {
    final strings = Strings.of(context);
    final archive = _archive;
    final recents = _visibleRecentSessions;

    // Chats: the Home recents with their live status (same derivation as
    // the chat pill and Conversaciones) and the server's unread flag.
    final chatItems = <HomeChatItem>[];
    final keyById = <String, String>{};
    for (final session in recents) {
      keyById[session.id] = session.logicalId;
      keyById[session.logicalId] = session.logicalId;
      final activeChat = service?.of(
        conn.id,
        session.id,
        profile: session.profile,
      );
      final status = resolveSessionLiveStatus(
        chat: activeChat?.liveStatus,
        chatAuthoritative:
            activeChat != null &&
            (activeChat.hasDesktopRuntime || activeChat.lastTerminalAt != null),
        chatSettledAt: activeChat?.lastTerminalAt,
        global: _globalActivityFor(conn, session),
      );
      // A stale roster can only preserve visual continuity while the
      // next read is pending; it is never current work for Inicio.
      final working =
          status.turnLive &&
          status.phase != SessionLivePhase.waitingForUser &&
          !status.stale;
      DateTime? since;
      if (working) {
        since = activeChat?.turnClockOrigin;
        if (since == null) {
          for (final row in _activeRoster) {
            final stored = row.storedSessionId;
            if (stored == session.id || stored == session.logicalId) {
              since = row.startedAt;
              break;
            }
          }
        }
      }
      final preview = sessionListPreview(session);
      chatItems.add(
        HomeChatItem(
          key: session.logicalId,
          title:
              archive?.titleForSession(session, strings: strings) ??
              localizedSessionTitle(strings, session),
          preview: session.hasLocalDraft
              ? [_sentenceCase(strings.slDraftBadge), ?preview].join(' · ')
              : preview ?? '',
          at: DateTime.fromMillisecondsSinceEpoch(
            (session.lastActivityAt * 1000).round(),
          ),
          unread:
              !working &&
              (archive?.isSessionUnread(session) ?? session.unread == true),
          working: working,
          workingSince: since,
          step: working && status.phase == SessionLivePhase.runningTool
              ? sessionLiveStatusLabel(strings, status)
              : null,
          ref: session,
        ),
      );
    }

    String? botName(String profile) {
      final info = store.profile(profile);
      final title = info?.botTitle?.trim();
      if (title != null && title.isNotEmpty) return title;
      return profile;
    }

    // Approvals: attached chats (any profile of this connection), then the
    // hosted rooms of the Bots read when it is recent enough.
    final approvals = <HomeApprovalItem>[
      ...homeChatApprovals(
        chats,
        readOnly: readOnly,
        chatKey: (chat) =>
            keyById[chat.storedSessionId ?? chat.sessionId] ??
            keyById[chat.sessionId],
        whereOf: (chat) => _isBotChat(chat) ? '' : chat.sessionTitle,
        actorOf: (chat) => _isBotChat(chat)
            ? botName(Session.profileOwner(chat.sessionProfile))
            : null,
      ),
    ];
    final groups = snapshot?.hostedGroups ?? HostedGroupsSnapshot.empty;
    String roomTitle(HostedGroupRoom room) =>
        snapshot?.roomIdentity(room)?.name ?? room.name;
    final roomPrefs = SharedPreferencesRoomPrefs(widget.connManager.prefs);
    if (snapshot != null &&
        now.difference(snapshot.loadedAt) <= _roomApprovalMaxAge) {
      approvals.addAll(
        homeRoomApprovals(
          groups,
          AttentionSummary.fromSnapshot(groups, acks: roomPrefs.acksFor),
          titleOf: roomTitle,
          readOnly: readOnly,
        ).where((item) => !_answeredRoomApprovals.contains(item.key)),
      );
    }

    final profiles = store.isLive
        ? store.profiles
        : (snapshot?.profiles ?? const <AgentProfile>[]);
    return HomeNow.derive(
      approvals: approvals,
      chats: chatItems,
      rooms: homeRoomNews(
        groups,
        acksFor: roomPrefs.acksFor,
        titleOf: roomTitle,
      ),
      team: homeTeam(
        profiles: profiles,
        activeSessions: _activeRoster,
        observedAt: _activeRosterAt,
        liveChats: service == null
            ? const []
            : missionLiveChats(service, conn.id, _recentSessions),
        now: now,
      ),
      automations: _cronJobs == null
          ? null
          : homeAutomations(_cronJobs!, parseTime: cronParseTime),
      now: now,
    );
  }

  static bool _isBotChat(ActiveChat chat) =>
      chat.sessionId.startsWith('mob-bot-');

  late final HomeNowActions _homeActions = HomeNowActions(
    answer: _answerApproval,
    viewApproval: _viewApproval,
    openChat: (chat) {
      if (chat.ref case final Session session) _openChat(session);
    },
    openRoom: (room) => _openInBots(
      MissionControlOpenTarget.room(sessionId: '', roomId: room.key),
    ),
    openBot: (bot) => _openInBots(
      MissionControlOpenTarget.bot(
        sessionId:
            (bot.ref is AgentProfile
                ? (bot.ref as AgentProfile).canonicalBotChatSessionId
                : null) ??
            '',
        profile: bot.profileName,
      ),
    ),
    openAutomation: (_) => _openAutomations(),
  );

  /// Answers with the request's own existing path: the attached chat's
  /// `resolveApproval`, or `groups.approve` for a room.
  Future<void> _answerApproval(
    HomeApprovalItem item, {
    required bool allow,
  }) async {
    final conn = _active;
    if (conn == null) return;
    if (conn.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    final choice = allow ? ApprovalScope.once.wire : ApprovalScope.deny.wire;
    try {
      switch (item.ref) {
        case final HomeChatApprovalRef ref:
          await ref.resolve(choice);
        case final HomeRoomApprovalRef ref:
          await (widget.roomApproveOverride ?? _pooledRoomApprove)(
            conn,
            roomId: ref.room.roomId,
            action: ref.action,
            choice: choice,
          );
          _answeredRoomApprovals.add(item.key);
      }
    } catch (error) {
      debugPrint(
        '[home-dashboard] approval answer failed (${error.runtimeType})',
      );
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(Strings.of(context).inicioApprovalFailed)),
          kind: HermesNoticeKind.error,
        );
      }
    }
    if (mounted) setState(() => _activityRevision++);
  }

  static Future<void> _pooledRoomApprove(
    SavedConnection connection, {
    required String roomId,
    required RoomApprovalAction action,
    required String choice,
  }) => pooledRoomApprove(
    connection,
    roomId: roomId,
    action: action,
    choice: choice,
  );

  void _viewApproval(HomeApprovalItem item) {
    switch (item.ref) {
      case final HomeRoomApprovalRef ref:
        _openInBots(
          MissionControlOpenTarget.room(sessionId: '', roomId: ref.room.roomId),
        );
      case final HomeChatApprovalRef ref:
        final chat = ref.chat;
        final profile = Session.profileOwner(chat.sessionProfile);
        if (_isBotChat(chat)) {
          _openInBots(
            MissionControlOpenTarget.bot(
              sessionId: chat.storedSessionId ?? '',
              profile: profile,
            ),
          );
          return;
        }
        final id = chat.storedSessionId ?? chat.sessionId;
        final session =
            _recentSessions
                .where((s) => s.id == id || s.logicalId == id)
                .firstOrNull ??
            Session(
              id: id,
              title: chat.sessionTitle,
              model: 'hermes-agent',
              source: 'mobile',
              messageCount: 1,
              isActive: true,
              preview: '',
              startedAt: 0,
              profile: profile,
            );
        _openChat(session);
    }
  }

  /// Bot Chats and rooms open through Bot Mode, as notifications do: the
  /// canonical chat or the room (landing on its «new» divider) on top.
  void _openInBots(MissionControlOpenTarget target) {
    final conn = _active;
    if (conn == null) return;
    final override = widget.botsOpenOverride;
    if (override != null) {
      override(target);
      return;
    }
    final navigator = Navigator.of(context);
    if (MissionControlScreen.openInExisting(navigator, conn.id, target)) {
      return;
    }
    navigator
        .push(
          MissionControlOwnerRoute<void>(
            builder: (_) => MissionControlScreen(
              connection: conn,
              connManager: widget.connManager,
              activeChats: _activeChats,
              initialOpenTarget: target,
            ),
          ),
        )
        .then((_) => _refreshWhenUncovered());
  }

  void _openAutomations() {
    final conn = _active;
    if (conn == null) return;
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) =>
                CronScreen(connection: conn, connManager: widget.connManager),
          ),
        )
        .then((_) {
          _cronReadAt = null;
          _refreshWhenUncovered();
        });
  }

  /// The hero while the user types in the calm composer: it stays the
  /// composer (an arriving card would take the half-typed text away).
  HomeHero _heroWhileTyping(HomeHero hero) =>
      _composerFocused && hero is! HomeHeroCalm ? const HomeHeroCalm([]) : hero;

  Widget _buildHomeNow(
    SavedConnection active, {
    required List<Widget> banners,
    required bool remoteOffline,
    required double bottomClearance,
  }) {
    final home = _homeNowFor(active);
    final clock = _clock();
    final strings = Strings.of(context);
    final status = HomeStatusBlock(
      now: home,
      clock: clock,
      onOpenBot: _homeActions.openBot,
    );
    final hero = _buildCompanionStage(
      HomeHeroCard(
        hero: _heroWhileTyping(home.hero),
        actions: _homeActions,
        clock: clock,
        now: _clock,
        composer: _buildComposer(
          enabled: !remoteOffline,
          dimmed: remoteOffline,
        ),
      ),
    );
    final proximo = home.proximo;
    final next = proximo?.automation.nextRun;
    final secondary = <Widget>[
      // A failed refresh keeps the last good list, but still says so and
      // offers the retry.
      if (_recentListFailed && !remoteOffline)
        _ProfileListErrorCard(
          profile: ProfileScopeLabel.display(
            strings,
            widget.connManager.activeProfileFor(active.id),
          ),
          onRetry: _refreshStatus,
        ),
      if (home.retomar.isNotEmpty)
        HomeRetomarSection(
          rows: home.retomar,
          actions: _homeActions,
          clock: clock,
        ),
      if (proximo != null)
        HomeProximoLine(
          proximo: proximo,
          when: next == null
              ? ''
              : hermesFormatNextRun(strings, next, now: clock),
          onTap: _homeActions.openAutomation,
        ),
    ];
    final primary = <Widget>[
      ...banners,
      status,
      const SizedBox(height: 22),
      hero,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        // Expanded width (tablet, unfolded): hero and status on the left,
        // Retomar and Próximo on the right.
        final wide = constraints.maxWidth >= 840;
        final padding = EdgeInsets.fromLTRB(
          wide ? 40 : 22,
          wide ? 28 : 18,
          wide ? 40 : 22,
          bottomClearance,
        );
        if (wide) {
          return ListView(
            key: const ValueKey('home-now-list'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: padding,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 5,
                    child: Column(
                      key: const ValueKey('home-now-primary'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: primary,
                    ),
                  ),
                  const SizedBox(width: 40),
                  Expanded(
                    flex: 4,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(
                        key: const ValueKey('home-now-secondary'),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: _spaced(secondary),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        }
        return ListView(
          key: const ValueKey('home-now-list'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: padding,
          children: [
            ...primary,
            if (secondary.isNotEmpty) const SizedBox(height: 28),
            ..._spaced(secondary),
          ],
        );
      },
    );
  }

  static List<Widget> _spaced(List<Widget> children) => [
    for (var i = 0; i < children.length; i++) ...[
      if (i > 0) const SizedBox(height: 14),
      children[i],
    ],
  ];

  @override
  Widget build(BuildContext context) =>
      EnclosingRoute(onRoute: _attachRoute, child: _buildScreen(context));

  Widget _buildScreen(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final dashboardLoginIssue =
        _healthOk &&
        (_dashboardAuth == DashboardAuthCheck.invalidCredentials ||
            _dashboardAuth == DashboardAuthCheck.loginRequired);
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
        // Active profile, one tap from Home (Desktop's profile rail).
        actions: [
          if (_active != null)
            ProfileSwitcherButton(
              connection: _active!,
              connManager: widget.connManager,
              compact: true,
              onManage: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ProfilesScreen(
                    connection: _active!,
                    connManager: widget.connManager,
                  ),
                ),
              ),
            ),
        ],
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
                          color: _statusChecking || dashboardLoginIssue
                              ? colors.warning
                              : _healthOk
                              ? colors.success
                              : colors.textDisabled,
                          boxShadow:
                              _healthOk &&
                                  !_statusChecking &&
                                  !dashboardLoginIssue
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
                      // Flexible: con el selector de perfil en la barra, la línea
                      // de estado debe recortarse en vez de desbordar.
                      Flexible(
                        child: _followsActiveProfile(
                          (context) => Text(
                            _statusChecking
                                ? Strings.of(context).homeStatusChecking(
                                    _active?.label ??
                                        Strings.of(
                                          context,
                                        ).homeStatusAgentConsole,
                                  )
                                : _healthOk &&
                                      _dashboardAuth ==
                                          DashboardAuthCheck.invalidCredentials
                                ? Strings.of(
                                    context,
                                  ).m1215HomeDashboardWrongPassword(
                                    _active?.label ?? '',
                                  )
                                : _healthOk &&
                                      _dashboardAuth ==
                                          DashboardAuthCheck.loginRequired
                                ? Strings.of(
                                    context,
                                  ).m1215HomeDashboardLoginRequired(
                                    _active?.label ?? '',
                                  )
                                : _healthOk
                                ? Strings.of(context).homeStatusOnline(
                                    _activeProfileLabel(context),
                                  )
                                : _active == null
                                ? Strings.of(context).homeStatusAgentConsole
                                : Strings.of(
                                    context,
                                  ).homeStatusOffline(_active!.label),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              // ≥11px: a 9.5px el estado era casi ilegible (A-110).
                              fontSize: 11,
                              letterSpacing: 0.6,
                              color: colors.textSecondary,
                            ),
                          ),
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
        checking: _statusChecking,
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
              // El dock flotante (`Dock`) se pinta como overlay
              // (Positioned) ENCIMA de esta lista, no reserva espacio por sí
              // mismo. Sin este margen extra, el último item de recientes
              // quedaba tapado/cortado por el dock (confirmado por captura
              // real del dispositivo). Reserva: alto del dock (48) + su
              // separación del borde (12) + el lift máximo de la profundidad
              // "Flotante" (6) + el inset seguro inferior del sistema +
              // un margen de aire adicional para que no quede pegado.
              final dockBottomClearance =
                  48 + 12 + 6 + MediaQuery.paddingOf(context).bottom + 16;
              final showChat = !kLocalAgentEnabled || !isLocalAndOffline;
              final banners = <Widget>[
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
              ];
              // El compositor y los avisos de estado viven fuera del área que
              // scrollea: solo la lista de conversaciones recientes se mueve
              // al hacer scroll, para que el compositor no "desaparezca" al
              // bajar por la lista (confirmado como bug real en dispositivo).
              // Sin gateway que responda (instancia local apagada) no hay
              // lista de conversaciones que mostrar: los avisos vuelven a
              // vivir en un `ListView` normal para conservar el pull-to-
              // refresh de esa pantalla.
              if (!showChat) {
                return RefreshIndicator(
                  color: colors.accent,
                  onRefresh: _refreshStatus,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                    children: banners,
                  ),
                );
              }
              final content = RefreshIndicator(
                color: colors.accent,
                onRefresh: _refreshStatus,
                child: _buildHomeNow(
                  active,
                  banners: banners,
                  remoteOffline: isRemoteAndOffline,
                  bottomClearance: dockBottomClearance,
                ),
              );
              return content;
            }(),
          ),
          Dock(
            profileId: DockProfileId.general,
            showBackContext: dockShowsBack(context),
            onBack: () => Navigator.of(context).maybePop(),
            actions: {
              // Este dock YA vive en Inicio: "Inicio" se pinta como sección
              // activa y sin acción propia, en vez de navegar a sí mismo.
              DockItemId.home: const DockItemAction(selected: true),
              DockItemId.create: DockItemAction(
                onTap: _active == null ? null : _newChat,
              ),
              DockItemId.bots: DockItemAction(
                onTap: _active == null
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => MissionControlScreen(
                            connection: _active!,
                            connManager: widget.connManager,
                          ),
                        ),
                      ).then((_) => _refreshWhenUncovered()),
              ),
              DockItemId.settings: DockItemAction(
                onTap: _active == null
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SettingsScreen(
                            connection: _active!,
                            connManager: widget.connManager,
                          ),
                        ),
                      ).then((_) => _refreshWhenUncovered(reload: true)),
              ),
              // Accesos directos opcionales (ocultos de fábrica en el
              // catálogo); mismas pantallas/criterios que ya usa HermesDrawer.
              DockItemId.cron: DockItemAction(
                onTap: _active == null
                    ? null
                    : () => openDockCron(context, _active!, widget.connManager),
              ),
              DockItemId.tasks: DockItemAction(
                onTap: _active == null
                    ? null
                    : () =>
                          openDockTasks(context, _active!, widget.connManager),
              ),
              DockItemId.sessions: DockItemAction(
                onTap: _active == null
                    ? null
                    : () => openDockSessions(
                        context,
                        _active!,
                        widget.connManager,
                      ),
              ),
              DockItemId.tools: DockItemAction(
                onTap: () =>
                    openDockTools(context, _active, widget.connManager),
              ),
            },
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
                            color: colors.textTertiary,
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
/// The active profile's list could not be read while the connection is up:
/// says so where the list goes, without turning Home offline.
class _ProfileListErrorCard extends StatelessWidget {
  final String profile;
  final VoidCallback onRetry;

  const _ProfileListErrorCard({required this.profile, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return HermesEmptyState(
      key: const ValueKey('home-profile-list-error'),
      compact: true,
      title: s.homeProfileListErrorTitle(profile),
      body: s.homeProfileListErrorBody,
      primaryLabel: s.commonRetry,
      primaryIcon: Icons.refresh_rounded,
      onPrimary: onRetry,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
    );
  }
}

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

String _sentenceCase(String value) =>
    value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';

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
