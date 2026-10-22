export '../widgets/session_status_tone.dart'
    show readableActivityTone, resolveActivityTone;

import 'dart:async';
import '../bots/data/gateway_socket_meter.dart';
import '../services/app_lock_sensitive_read_fence.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;

import '../app_header_title.dart';
import '../bots/state/attention.dart';
import '../bots/state/mission_live_chats.dart';
import '../bots/ui/room/room_launcher.dart';
import '../bots/ui/room/room_prefs.dart';
import '../home/home_now.dart';
import '../home/board/home_board_data.dart';
import '../home/board/home_board_kit.dart';
import '../home/board/home_board_model.dart';
import '../home/board/home_board_store.dart';
import '../home/board/home_limits.dart' show homeWidgetLimits;
import '../home/board/home_board_view.dart';
import '../home/home_feed_cache.dart';
import '../home/home_sources.dart';
import '../models/account_usage_limits.dart';
import '../models/agent_profile.dart';
import '../models/cron_job.dart';
import '../models/hosted_groups.dart';
import '../models/kanban.dart';
import '../models/mission_control.dart';
import '../services/approval_policy.dart';
import '../services/connection_status.dart';
import '../services/cron_repository.dart';
import '../services/kanban_client.dart';
import '../services/kanban_watch_board.dart';
import '../services/launcher_widget_chats.dart';
import '../services/launcher_widget_cron.dart';
import '../services/launcher_widget_tasks.dart';
import '../services/mission_snapshot_cache.dart';
import 'cron_detail_page.dart' show cronParseTime;
import 'cron_screen.dart';
import '../config/feature_flags.dart';
import '../models/core_read.dart';
import '../models/desktop_active_session.dart';
import '../models/home_widget_snapshot.dart';
import '../models/session_live_status.dart';
import '../navigation/chat_route.dart';
import '../navigation/enclosing_route.dart';
import '../services/active_profile_scope.dart';
import '../services/bot_roster_store.dart';
import '../services/active_chat_service.dart';
import '../services/app_lock.dart';
import '../services/connection_manager.dart';
import 'dashboard_sign_in.dart';
import '../services/new_session_factory.dart';
import '../services/chat_draft_store.dart';
import '../services/drawer_gesture_exclusion.dart';
import '../services/global_activity_aggregate.dart';
import '../services/home_widget_publisher.dart';
import '../services/cold_start_store.dart';
import '../services/roster_known_filter.dart';
import '../services/session_archive.dart';
import '../services/session_repository.dart';
import '../services/session_deletion.dart';
import '../services/tui_gateway_client.dart';
import '../services/shared_gateway_pool.dart';
import '../services/mission_snapshot_prewarm.dart';
import '../services/model_picker_prewarm.dart';
import '../services/models_snapshot.dart';
import '../services/onboarding_arrival.dart';
import '../theme/app_theme.dart';
import '../utils/home_recent_sessions.dart';
import '../utils/session_title.dart';
import '../widgets/seasonal_mark.dart';
import '../widgets/onstage_gate.dart';
import '../widgets/attachment_source_sheet.dart';
import '../shell/gesture_dock.dart' show gestureDockFootprint;
import '../shell/dock_activity_sheet.dart' show DockActivityFeed;
import '../widgets/dock.dart';
import '../widgets/dock_shortcuts.dart';
import '../widgets/dock_style.dart' show dockShowsBack;
import '../widgets/hermes_drawer.dart';
import '../widgets/profile_scope.dart';
import '../widgets/profile_switcher.dart';
import '../widgets/profile_face.dart';
import 'profiles_screen.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart' show HermesPrimaryButton;
import '../../main.dart';
import '../companion/models/companion_presence_level.dart';
import '../companion/render/companion_view.dart';
import '../bots/ui/roster/dots_home_model.dart' show isMainBot;
import '../widgets/action_approval.dart';
import '../widgets/read_only.dart';
import '../widgets/hermes_update_card.dart' show HermesUpdatePresentation;
import 'chat_screen.dart';
import 'gateway_manager_screen.dart';
import 'mission_control_screen.dart';
import 'onboarding/manual_setup_page.dart';
import 'onboarding_screen.dart';
import 'session_list_screen.dart';
import 'settings_screen.dart';
import 'tasks_screen.dart';
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
  final VoidCallback? onInitialLoadComplete;
  final ActiveChatService? activeChatsOverride;
  final GlobalActivityAggregate? globalActivityOverride;
  final Future<DesktopActiveSessionList> Function()? activeSessionListLoader;
  final Stream<TuiGatewayEvent>? eventStreamOverride;

  /// Saved Dashboard login check (defaults to [checkSavedDashboardLogin]).
  final DashboardAuthProbe? dashboardAuthProbe;

  /// Bot Mode background first read (defaults to the shared one).
  final MissionSnapshotPrewarm? missionPrewarm;
  final ModelsSnapshotPrewarm? modelsPrewarm;
  final ModelPickerPrewarm? pickerPrewarm;

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

  /// Kanban board for «Tareas» (defaults to the board Tasks opens on,
  /// read from the Dashboard when Home builds its own clients).
  final Future<KanbanBoard> Function(SavedConnection connection)? tasksLoader;

  /// Last cron list and Kanban board, kept across rebuilds of Home
  /// (defaults to the shared cache).
  final HomeFeedCache? feedCacheOverride;

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

  /// Servidor widget: server version and update check (defaults to the
  /// Dashboard's `status` and `update/check` when Home builds its clients).
  final Future<({String? version, bool? update})> Function(
    SavedConnection connection,
  )?
  serverInfoLoader;

  /// Límites widget: plan limits (defaults to an attached chat's
  /// `session.usage`).
  final Future<AccountUsageLimits?> Function(SavedConnection connection)?
  limitsLoader;

  /// Opens the board in edit mode (renders and tests).
  final bool initiallyEditingBoard;

  const HomeDashboardScreen({
    required this.connManager,
    this.clientFactory,
    this.onInitialLoadComplete,
    @visibleForTesting this.activeChatsOverride,
    @visibleForTesting this.globalActivityOverride,
    @visibleForTesting this.activeSessionListLoader,
    @visibleForTesting this.eventStreamOverride,
    @visibleForTesting this.dashboardAuthProbe,
    @visibleForTesting this.missionPrewarm,
    @visibleForTesting this.modelsPrewarm,
    @visibleForTesting this.pickerPrewarm,
    @visibleForTesting this.sessionStateWriterFactory,
    @visibleForTesting this.appLockOverride,
    @visibleForTesting this.homeWidgetUpdateOverride,
    @visibleForTesting this.cronJobsLoader,
    @visibleForTesting this.tasksLoader,
    @visibleForTesting this.feedCacheOverride,
    @visibleForTesting this.missionSnapshotCacheOverride,
    @visibleForTesting this.rosterRegistryOverride,
    @visibleForTesting this.roomApproveOverride,
    @visibleForTesting this.botsOpenOverride,
    @visibleForTesting this.clockOverride,
    @visibleForTesting this.serverInfoLoader,
    @visibleForTesting this.limitsLoader,
    @visibleForTesting this.initiallyEditingBoard = false,
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

  /// The chat-lane socket's status (single source). While it is down Home never
  /// says «connected», whatever the REST probe answered.
  ConnectionStatus? get _link {
    final id = _active?.id;
    return id == null ? null : ConnectionStatusRegistry.instance.current(id);
  }

  bool get _socketDown => _link?.isConnected == false;

  void _onLinkChanged() {
    if (mounted) setState(() {});
  }

  /// Saved Dashboard login of a healthy remote instance; a rejected or
  /// missing login keeps the header pill from claiming the agent is online.
  DashboardAuthCheck _dashboardAuth = DashboardAuthCheck.unknown;
  List<Session> _recentSessions = [];

  /// The last read of the active profile's list failed while the connection
  /// answered: Home stays online and says so next to the list.
  bool _recentListFailed = false;
  bool _recentListLoginRefused = false;
  SessionArchive? _archive;
  SessionListRead? _statusListRead;
  StreamSubscription<HistoryCleanupInvalidation>? _historyCleanupSubscription;
  PageRoute<dynamic>? _route;
  bool _statusRefreshOwed = false;
  bool _reloadOwed = false;
  bool _initialLoadComplete = false;
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

  // Home board sources (all already held by Console; see [_boardDataFor]).
  /// Bumped by every notification Home repaints for: the derived cards are
  /// recomputed only when it (or another input identity) changes.
  int _activityRevision = 0;
  List<CronJob>? _cronJobs;
  String? _cronScope;
  DateTime? _cronReadAt;
  int _cronEpoch = 0;

  /// The last cron list read failed ([_cronJobs] keeps the read before).
  bool _cronFailed = false;

  /// «Tareas»: the Kanban board Tasks opens on, read only while the
  /// widget is on the board.
  KanbanBoard? _tasksBoard;
  String? _tasksScope;
  DateTime? _tasksReadAt;
  int _tasksEpoch = 0;
  bool _tasksFailed = false;
  static const _feedMinInterval = Duration(minutes: 1);

  /// The board on screen. While it is being edited its edit bar takes the
  /// header's place ([_boardEditing]).
  final GlobalKey<HomeBoardViewState> _boardViewKey = GlobalKey(
    debugLabel: 'home-board-view',
  );

  bool get _boardEditing =>
      _boardViewKey.currentState?.editing ?? widget.initiallyEditingBoard;
  List<DesktopActiveSession> _activeRoster = const [];
  DateTime? _activeRosterAt;
  final OnstageGate _homeSourcesGate = OnstageGate();
  Listenable? _homeSources;
  BotRosterStore? _homeSourcesStore;
  List<Object?>? _boardDataKey;
  HomeBoardData? _boardData;

  /// Widget board of the active connection + profile (on this device).
  HomeBoardStore? _boardStore;
  HomeBoardLayout? _boardLayout;
  String? _boardScope;

  /// [_boardLayout] is the user's own (stored), not a default.
  bool _boardArranged = false;

  /// Servidor widget: round trip of the last health check, and the server
  /// version / update check read at most every [_serverInfoMaxAge].
  int? _latencyMs;
  ({String? version, bool? update})? _serverInfo;
  DateTime? _serverInfoAt;
  String? _serverInfoScope;
  static const _serverInfoMaxAge = Duration(minutes: 10);

  /// Límites widget: the last plan limits read through an attached chat.
  AccountUsageLimits? _limits;
  DateTime? _limitsAt;
  String? _limitsScope;
  static const _limitsMinInterval = Duration(minutes: 1);

  /// Room approvals answered from Home: hidden until a newer Bots read
  /// stops listing them (the cached snapshot does not see the answer).
  final Set<String> _answeredRoomApprovals = {};

  /// Room approvals older than this are not offered from Home: the cached
  /// Bots read could list a request already answered elsewhere.
  static const _roomApprovalMaxAge = Duration(minutes: 5);

  ActiveChatService? get _activeChats =>
      widget.activeChatsOverride ??
      context.findAncestorStateOfType<HermesAppState>()?.activeChats;

  AppLockService? get _appLock =>
      widget.appLockOverride ??
      context.findAncestorStateOfType<HermesAppState>()?.appLock;

  @override
  void dispose() {
    ConnectionStatusRegistry.instance.changes.removeListener(_onLinkChanged);
    AppLockSensitiveReadFence.changes.removeListener(_onDraftDisclosureChanged);
    DockActivityFeed.instance.clear(this);
    _missionPrewarm.cancel();
    _modelsPrewarm.cancel();
    _pickerPrewarm.cancel();
    hermesRouteObserver.unsubscribe(this);
    unawaited(DrawerGestureExclusion.setEnabled(false));
    _refreshStatusEpoch++;
    _activityEventRefreshTimer?.cancel();
    _activityReconnectTimer?.cancel();
    _activityStableTimer?.cancel();
    _activityStaleExpiryTimer?.cancel();
    unawaited(_activityEventSubscription?.cancel());
    _releaseActivityClient();
    FeatureFlags.instance.gestureDock.removeListener(_onGestureDockFlag);
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
    _tasksEpoch++;
    _listenedGlobalActivity?.removeListener(_onActivityChanged);
    _archive?.removeListener(_onActivityChanged);
    _archive?.removeListener(_dropDeletedRecents);
    _detachStateWriter();
    _statusListRead?.end();
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

  void _onGestureDockFlag() {
    if (mounted) setState(() {});
  }

  int _draftDisclosureEpoch = 0;
  void _onDraftDisclosureChanged() {
    ++_draftDisclosureEpoch;

    if (!mounted) return;
    if (!AppLockSensitiveReadFence.capture(
      widget.connManager.prefs,
    ).isCurrent) {
      setState(() {
        _recentSessions = _recentSessions
            .where((s) => s.source != 'mobile-draft')
            .toList();
      });
    } else {
      // The lock route has not popped yet when its issuer revokes/notifies.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        runWhenUncovered(context, _route, () {
          if (_activityRefreshAllowed) unawaited(_refreshDraftsAfterUnlock());
        });
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  Future<void> _refreshDraftsAfterUnlock() async {
    final epoch = _draftDisclosureEpoch;
    final conn = _active;
    if (conn == null) return;
    final owner = ActiveProfileScope.of(widget.connManager, conn.id).capture();
    final ticket = AppLockSensitiveReadFence.capture(widget.connManager.prefs);
    try {
      final entries = await ChatDraftStore(
        widget.connManager.prefs,
      ).listForConnection(conn.id);

      if (!ticket.isCurrent ||
          !owner.isCurrent ||
          epoch != _draftDisclosureEpoch ||
          !_activityRefreshAllowed ||
          _active?.id != conn.id) {
        return;
      }
      if (!mounted) return;
      final merged = <String, Session>{
        for (final session in _recentSessions.where(
          (s) => s.source != 'mobile-draft',
        ))
          session.id: session,
      };
      for (final entry in entries.where(
        (e) => Session.profileOwner(e.profile) == owner.owner,
      )) {
        final existing = merged[entry.sessionId];
        merged[entry.sessionId] =
            existing?.copyWith(hasLocalDraft: true) ??
            entry.toSession(fallbackTitle: Strings.of(context).drawerNewChat);
      }
      setState(() {
        _recentSessions = merged.values.toList()
          ..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
      });
    } on SensitiveReadUnavailable {
      // Retired disclosure: the next current unlock performs a fresh read.
    } catch (error) {
      debugPrint('[home-dashboard] draft recovery ${error.runtimeType}');
    }
  }

  @override
  void initState() {
    super.initState();
    AppLockSensitiveReadFence.changes.addListener(_onDraftDisclosureChanged);
    ConnectionStatusRegistry.instance.changes.addListener(_onLinkChanged);
    _activeIdsGate.addListener(_onActivityChanged);
    _liveStatusGate.addListener(_onActivityChanged);
    _homeSourcesGate.addListener(_onActivityChanged);
    WidgetsBinding.instance.addObserver(this);
    // Si se activa otra instancia desde cualquier pantalla (no solo el drawer
    // del home), recargamos al instante. Antes el home se quedaba con la
    // instancia anterior hasta salir y volver a entrar.
    widget.connManager.activeConnectionId.addListener(_onActiveConnChanged);
    // The content's bottom clearance follows the dock this device uses.
    FeatureFlags.instance.gestureDock.addListener(_onGestureDockFlag);
    _historyCleanupSubscription = historyCleanupInvalidations.events.listen(
      _onHistoryCleanupInvalidation,
    );
    _primeFirstFrame();
    _reload();
  }

  /// The first frame is the real Home: the saved connections (in memory)
  /// and, when the lock is open, the recents snapshot bootstrap already
  /// decrypted. [_reload] then refreshes everything in the background.
  void _primeFirstFrame() {
    final connections = widget.connManager.getConnections();
    final lastId = widget.connManager.prefs.getString(_activeKey);
    final active =
        connections.where((c) => c.id == lastId).firstOrNull ??
        connections.firstOrNull;
    _connections = connections;
    _active = active;
    if (active == null) return;
    // The status check starts right away; say «checking», not «offline».
    _checking = true;
    // Under App Lock nothing private is painted (the caches stay unread).
    if (_appLock?.locked.value == true) return;
    _primeFeeds(active);
    final store = _activeChats?.coldStartStore;
    if (store == null) return;
    final owner = ActiveProfileScope.of(
      widget.connManager,
      active.id,
    ).capture().owner;
    final cached = store.peekRecents(connectionId: active.id, profile: owner);
    if (cached == null) return;
    final archive = SessionArchive.loadSync(
      widget.connManager.prefs,
      active.id,
    );
    final rows = cached
        .where((s) => _isHomeRecentCandidate(s, archive))
        .toList();
    if (rows.isEmpty) return;
    _recentSessions = rows;
    _showingColdStartRecents = true;
    _initialLoadComplete = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onInitialLoadComplete?.call();
    });
  }

  void _onActiveConnChanged() {
    _missionPrewarm.cancel();
    _modelsPrewarm.cancel();
    _pickerPrewarm.cancel();
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
    _modelsPrewarm.cancel();
    _pickerPrewarm.cancel();
    if (!mounted) return;
    // The previous profile's recents (and its list error) leave at once;
    // the new ones follow.
    setState(() {
      _recentSessions = [];
      _recentListFailed = false;
      _cronJobs = null;
      _cronScope = null;
      _cronReadAt = null;
      _cronFailed = false;
      _tasksBoard = null;
      _tasksScope = null;
      _tasksReadAt = null;
      _tasksFailed = false;
      _answeredRoomApprovals.clear();
      final conn = _active;
      if (conn != null && !_locked) _primeFeeds(conn);
    });
    _reload();
  }

  HomeFeedCache get _feedCache =>
      widget.feedCacheOverride ?? HomeFeedCache.shared;

  String _feedScope(SavedConnection conn) => HomeFeedCache.scopeOf(
    conn.id,
    Session.profileOwner(widget.connManager.activeProfileFor(conn.id)),
  );

  /// Paints the cron list and the Kanban board this process read last for
  /// [conn]'s active profile, before the read that refreshes them.
  void _primeFeeds(SavedConnection conn) {
    final scope = _feedScope(conn);
    if (_cronJobs == null) {
      final jobs = _feedCache.cron(scope);
      if (jobs != null) {
        _cronJobs = jobs;
        _cronScope = scope;
      }
    }
    if (_tasksBoard == null) {
      final board = _feedCache.tasks(scope);
      if (board != null) {
        _tasksBoard = board;
        _tasksScope = scope;
      }
    }
  }

  MissionSnapshotPrewarm get _missionPrewarm =>
      widget.missionPrewarm ?? MissionSnapshotPrewarm.shared;

  ModelsSnapshotPrewarm get _modelsPrewarm =>
      widget.modelsPrewarm ?? ModelsSnapshotPrewarm.shared;

  ModelPickerPrewarm get _pickerPrewarm =>
      widget.pickerPrewarm ?? ModelPickerPrewarm.shared;

  /// Same idle rule for the Models catalog, which the server can take
  /// seconds to build: Desktop loads it at startup for its model menu.
  void _scheduleModelsPrewarm(SavedConnection conn, String ownerProfile) {
    _modelsPrewarm.schedule(
      prefs: widget.connManager.prefs,
      connection: conn,
      profileOwner: ownerProfile,
      stillIdle: () =>
          _activityRefreshAllowed && _healthOk && _active?.id == conn.id,
    );
    // The chat model picker reads the same catalog over the socket Home
    // already holds; its first open after a cold start then paints at once.
    final chats = _activeChats;
    if (chats != null) {
      _pickerPrewarm.schedule(
        chats: chats,
        connection: conn,
        profileOwner: ownerProfile,
        stillIdle: () =>
            _activityRefreshAllowed && _healthOk && _active?.id == conn.id,
      );
    }
  }

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
    if (!mounted || _activityConnectionId != connectionId) return;
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
        // Only rows this profile knows become its activity; the team faces
        // below keep the whole roster.
        roster: filterRosterToKnown(
          roster,
          knownSessionIds(
            sessions: _recentSessions,
            pinnedIds: _archive?.pinnedIds ?? const [],
            roster: roster,
            hasLocalChat: (id) =>
                _activeChats?.of(connection.id, id, profile: profile) != null,
          ),
        ),
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _missionPrewarm.cancel();
      _modelsPrewarm.cancel();
      _pickerPrewarm.cancel();
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
  Future<void> _reload() async {
    final epoch = ++_reloadEpoch;
    try {
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
      setState(() {
        _connections = connections;
        _active = active;
      });
      _followProfileScope(active);
      _configureActivitySource(active);
      _openArrivalChat(active);
      // cs1215: the last known recents paint while the network read runs;
      // neither waits for the other.
      final refresh = _refreshStatus();
      await _paintColdStartRecents(active, epoch);
      await refresh;
    } finally {
      if (epoch == _reloadEpoch) _completeInitialLoad();
    }
  }

  /// The onboarding's «Open chat» left a one-shot request for this
  /// connection: open one new chat, once, if this Home is the screen in view.
  void _openArrivalChat(SavedConnection? active) {
    if (active == null || !OnboardingArrival.take(active.id)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
      _newChat();
    });
  }

  /// Ends the initial loading state once (the recents placeholder goes).
  void _completeInitialLoad() {
    if (!mounted || _initialLoadComplete) return;
    final epoch = _reloadEpoch;
    setState(() => _initialLoadComplete = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || epoch != _reloadEpoch) return;
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
    if (store == null) return;
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

  /// A status refresh only paints while it is the newest one, for the same
  /// connection AND the same active profile: a list read for the previous
  /// profile must never land on the new one.
  bool _isCurrentStatusRefresh(int epoch, String? connectionId) =>
      mounted &&
      epoch == _refreshStatusEpoch &&
      _active?.id == connectionId &&
      (_statusTicket?.isCurrent ?? true);

  /// The list failed because the Dashboard refused the saved login: the same
  /// sign-in the chat offers, then a fresh read.
  Future<void> _signInFromList() async {
    final conn = _active;
    if (conn == null) return;
    final signedIn = await signInToDashboard(
      Navigator.of(context),
      widget.connManager,
      conn,
    );
    if (signedIn && mounted) unawaited(_refreshStatus());
  }

  Future<void> _refreshStatus() =>
      GatewaySocketMeter.origin('home.observer', _refreshStatusLabelled);

  Future<void> _refreshStatusLabelled() async {
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
      return;
    }

    // Leer el estado del App Lock antes de los awaits de red evita conservar
    // BuildContext a través del hueco asíncrono.

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
    // The Dashboard liveness answered but the paged list did not (timeout, 5xx, reset).
    // The server is reachable: keep the last known list instead of flipping
    // Home to offline on every slow refresh (#1215).
    var listReadUnavailable = false;
    var listLoginRefused = false;
    Future<DashboardAuthCheck>? dashboardAuthFuture;
    List<Session> sessions = [];
    final draftTicket = AppLockSensitiveReadFence.capture(
      widget.connManager.prefs,
    );
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
      // The paged session list below is an authenticated read, so it is
      // the auth proof: a rejected key throws and leaves Home offline.
      final watch = Stopwatch()..start();
      ok = await client.healthReachable();
      watch.stop();
      if (!_isCurrentStatusRefresh(refreshEpoch, connectionId)) return;
      // Servidor widget: the round trip of this very check (no extra
      // request).
      _latencyMs = ok ? watch.elapsedMilliseconds : null;
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
          // The list comes from the Dashboard, which answered: a refused
          // login is «login required», never an outage of the connection.
          final refused =
              error.kind == CoreReadErrorKind.auth ||
              error.kind == CoreReadErrorKind.forbidden;
          // The session belongs to the connection, so any profile's card
          // offers the sign-in; only the default's header is corrected.
          listLoginRefused = refused;
          if (refused && ownerProfile == 'default') {
            dashboardAuthFuture = dashboardAuthFuture
                .catchError((_) => DashboardAuthCheck.unknown)
                .then(
                  (auth) => auth == DashboardAuthCheck.invalidCredentials
                      ? auth
                      : DashboardAuthCheck.loginRequired,
                );
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
    if (!draftTicket.isCurrent) drafts = [];
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
      ConnectionStatusRegistry.instance.reportRest(conn.id, reachable: ok);
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
      _recentListLoginRefused = _recentListFailed && listLoginRefused;
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
      // The Chats launcher widget shows these same rows (no request of its
      // own): opening the app at Home keeps it current, not only a visit to
      // the Chats screen.
      unawaited(
        LauncherWidgetChatsPublisher.instance.offer(
          connectionId: conn.id,
          sessions: recentSessions.where((s) => !archive.isSessionDeleted(s)),
        ),
      );
    }
    // The recents are what the placeholder stands for; the live activity
    // roster below decorates them when it lands.
    _completeInitialLoad();
    if (ok) {
      _scheduleMissionPrewarm(conn);
      _scheduleModelsPrewarm(conn, ownerProfile);
      unawaited(_refreshCron(conn));
      _layoutFor(conn);
      _refreshBoardExtras(conn);
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

  void _newChat({
    String? initialPrompt,
    AttachmentSourceChoice? initialAttachmentSource,
    bool initialDictation = false,
    bool initialVoiceMode = false,
  }) {
    _openChat(
      Session(
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
      ),
      initialPrompt: initialPrompt,
      initialAttachmentSource: initialAttachmentSource,
      initialDictation: initialDictation,
      initialVoiceMode: initialVoiceMode,
    );
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
    // Configure an existing server; Console never installs a local runtime.
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OnboardingScreen(
          connManager: widget.connManager,
          onDone: () {
            Navigator.of(context).popUntil((r) => r.isFirst);
          },
        ),
      ),
    ).then((_) async {
      if (!mounted) return;
      await _reload();
    });
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

  final _roomsReads = HomeRoomsReads();

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

  /// One cron list read per minute at most, for «Cron». A read that fails
  /// keeps the list before it and says so.
  Future<void> _refreshCron(SavedConnection conn, {bool force = false}) async {
    final loader =
        widget.cronJobsLoader ??
        (widget.clientFactory == null ? _defaultCronLoader : null);
    if (loader == null) return;
    final profile = widget.connManager.activeProfileFor(conn.id);
    final scope = _feedScope(conn);
    final now = DateTime.now();
    final last = _cronReadAt;
    if (!force &&
        scope == _cronScope &&
        last != null &&
        now.difference(last) < _feedMinInterval) {
      return;
    }
    _cronReadAt = now;
    _cronScope = scope;
    final epoch = ++_cronEpoch;
    List<CronJob>? jobs;
    try {
      jobs = await loader(conn, profile);
    } catch (error) {
      debugPrint('[home-dashboard] cron list failed (${error.runtimeType})');
      jobs = null;
    }
    if (!mounted || epoch != _cronEpoch || _active?.id != conn.id) return;
    if (jobs != null) {
      _feedCache.putCron(scope, jobs);
      // The Cron launcher widget shows this same listing (no request of its
      // own): this profile's jobs.
      unawaited(
        LauncherWidgetCronPublisher.instance.offer(
          connectionId: conn.id,
          jobs: jobs,
          profile: profile,
        ),
      );
    }
    setState(() {
      if (jobs != null) _cronJobs = jobs;
      _cronFailed = jobs == null;
      _activityRevision++;
    });
  }

  /// The Kanban board for «Tareas», the one Tasks opens on: at most once a
  /// minute, in the background, beside the cron list. A read that fails
  /// keeps the board before it and says so.
  Future<void> _refreshTasks(SavedConnection conn, {bool force = false}) async {
    final loader =
        widget.tasksLoader ??
        (widget.clientFactory == null ? _defaultTasksLoader : null);
    if (loader == null) return;
    final scope = _feedScope(conn);
    final now = DateTime.now();
    final last = _tasksReadAt;
    if (!force &&
        scope == _tasksScope &&
        last != null &&
        now.difference(last) < _feedMinInterval) {
      return;
    }
    _tasksReadAt = now;
    _tasksScope = scope;
    final epoch = ++_tasksEpoch;
    KanbanBoard? board;
    try {
      board = await loader(conn);
    } catch (error) {
      debugPrint('[home-dashboard] kanban board failed (${error.runtimeType})');
      board = null;
    }
    if (!mounted || epoch != _tasksEpoch || _active?.id != conn.id) return;
    if (board != null) {
      _feedCache.putTasks(scope, board);
      // The Tareas launcher widget shows this same board (no request of its
      // own).
      unawaited(
        LauncherWidgetTasksPublisher.instance.offer(
          connectionId: conn.id,
          tasks: [for (final column in board.columns) ...column.tasks],
        ),
      );
    }
    setState(() {
      if (board != null) _tasksBoard = board;
      _tasksFailed = board == null;
      _activityRevision++;
    });
  }

  Future<KanbanBoard> _defaultTasksLoader(SavedConnection conn) => KanbanClient(
    conn,
  ).getBoard(board: KanbanWatchBoard.read(widget.connManager.prefs, conn.id));

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

  /// The board's data, recomputed only when one of its inputs changed
  /// (notification revision, list identities, approvals, the minute): a
  /// rebuild for anything else reuses it.
  HomeBoardData _boardDataFor(SavedConnection conn) {
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
      _cronFailed,
      _tasksBoard,
      _tasksFailed,
      _initialLoadComplete,
      _activeProfileLabel(context),
      _activeRoster,
      snapshot,
      store.snapshot,
      _answeredRoomApprovals.length,
      service?.liveStatusRevision.value,
      service?.activeIds.value,
      RoomLocalPrefs.changes.value,
      now.millisecondsSinceEpoch ~/ Duration.millisecondsPerMinute,
      Localizations.localeOf(context),
      _healthOk,
      _link?.kind,
      _statusChecking,
      _latencyMs,
      _serverInfo,
      _limits,
      for (final chat in chats) chat.pendingApproval,
      for (final chat in chats) chat.pendingInteractivePrompt?.key,
      for (final chat in chats) chat.queueParked,
    ];
    final cached = _boardData;
    if (cached != null && _sameKey(key, _boardDataKey)) return cached;
    final derived = _deriveBoardData(
      conn,
      service: service,
      chats: chats,
      snapshot: snapshot,
      store: store,
      now: now,
      readOnly: readOnly,
    );
    _boardDataKey = key;
    _boardData = derived;
    // The dock's "Actividad" sheet shows this same summary on every screen.
    DockActivityFeed.instance.publish(
      this,
      derived.glance,
      _boardActions.openGlance,
    );
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

  HomeBoardData _deriveBoardData(
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
    String? botName(String profile) {
      final info = store.profile(profile);
      final title = info?.botTitle?.trim();
      if (title != null && title.isNotEmpty) return title;
      return profile;
    }

    final mainOwner = Session.profileOwner(
      widget.connManager.activeProfileFor(conn.id),
    );
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
      // A stale roster entry (one missed read) keeps the row as it was
      // until the next read settles, so a single absence never blinks
      // the working state; the aggregate drops it on the second absence.
      final live = status.turnLive;
      final working = live && status.phase != SessionLivePhase.waitingForUser;
      final waiting = live && status.phase == SessionLivePhase.waitingForUser;
      DateTime? since;
      if (working) {
        // The roster's started_at is the session's age, never this turn's.
        // Read the same origin as the chat; unknown means no clock.
        since = status.stale
            ? null
            : activeChat?.turnClockOrigin ??
                  activeChat?.provisionalTurnStartedAt;
      }
      final preview = sessionListPreview(session);
      final owner = Session.profileOwner(session.profile);
      final ownerProfile = store.profile(owner);
      final isMainProfile =
          owner == mainOwner ||
          (ownerProfile != null && isMainBot(ownerProfile));
      final paused = activeChat != null && activeChat.queueParked
          ? activeChat.queuedEntries.length
          : 0;
      chatItems.add(
        HomeChatItem(
          key: session.logicalId,
          title:
              archive?.titleForSession(session, strings: strings) ??
              localizedSessionTitle(strings, session),
          preview: preview ?? '',
          draft: session.hasLocalDraft,
          at: DateTime.fromMillisecondsSinceEpoch(
            (session.lastActivityAt * 1000).round(),
          ),
          unread:
              !working &&
              (archive?.isSessionUnread(session) ?? session.unread == true),
          working: working,
          workingSince: since,
          step: working ? homeStepLabel(strings, status) : null,
          waitingForUser: waiting,
          queuedPaused: paused,
          // A turn that ended in an error no later prompt replaced (the
          // chat's own retry token); only attached chats know it.
          failed: !working && activeChat?.currentFailedTurnToken != null,
          profileName: owner,
          agentName: isMainProfile ? null : botName(owner),
          ref: session,
        ),
      );
    }

    // Approvals: attached chats (any profile of this connection), then the
    // hosted rooms of the Bots read when it is recent enough. Answering one
    // here goes through the chat's own path, so the chat's card clears too.
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
    final questions = homeChatQuestions(
      chats,
      readOnly: readOnly,
      chatKey: (chat) =>
          keyById[chat.storedSessionId ?? chat.sessionId] ??
          keyById[chat.sessionId],
      whereOf: (chat) => _isBotChat(chat) ? '' : chat.sessionTitle,
      actorOf: (chat) => _isBotChat(chat)
          ? botName(Session.profileOwner(chat.sessionProfile))
          : null,
    );
    final groups = snapshot?.hostedGroups ?? HostedGroupsSnapshot.empty;
    final roomsState = _roomsReads.observe(
      MissionSnapshotCache.keyOf(conn),
      snapshot,
    );
    String roomTitle(HostedGroupRoom room) =>
        snapshot?.roomIdentity(room)?.name ?? room.name;
    final roomPrefs = SharedPreferencesRoomPrefs(widget.connManager.prefs);
    // The same attention as the Bots needs-you dot (approvals, replies to
    // the user, failed turns), with this device's acks applied.
    final attention = AttentionSummary.fromSnapshot(
      groups,
      acks: roomPrefs.acksFor,
    );
    if (snapshot != null &&
        now.difference(snapshot.loadedAt) <= _roomApprovalMaxAge) {
      approvals.addAll(
        homeRoomApprovals(
          groups,
          attention,
          titleOf: roomTitle,
          readOnly: readOnly,
        ).where((item) => !_answeredRoomApprovals.contains(item.key)),
      );
    }

    final profiles = store.isLive
        ? store.profiles
        : (snapshot?.profiles ?? const <AgentProfile>[]);
    final todayRows = [
      for (final s in recents)
        (
          lastActivityAt: s.lastActivityAt,
          messages: s.messageCount,
          tools: s.toolCallCount,
        ),
    ];
    final serverInfo = _serverInfo;
    final tasksBoard = _tasksBoard;
    return HomeBoardData(
      now: now,
      profiles: profiles,
      avatarCache: ProfileFace.cacheFor(conn, rosterTicket: store.ticket),
      approvals: approvals,
      questions: questions,
      chats: chatItems,
      chatsLoaded: _initialLoadComplete,
      mainName: _activeProfileLabel(context),
      bots: homeBoardBots(
        profiles: profiles,
        sessions: snapshot?.sessions ?? const [],
        strings: strings,
        activeSessions: _activeRoster,
        observedAt: _activeRosterAt,
        turnStartedAtOf: (id, profile) =>
            service?.of(conn.id, id, profile: profile)?.turnClockOrigin,
        liveChats: service == null
            ? const []
            : missionLiveChats(service, conn.id, _recentSessions),
        now: now,
      ),
      rooms: homeBoardRooms(
        groups,
        acksFor: roomPrefs.acksFor,
        titleOf: roomTitle,
        now: now,
        attention: attention,
      ),
      botsLoaded: snapshot != null || store.isLive,
      roomsState: roomsState,
      roomsFailedReads: _roomsReads.failedReads,
      botsKnown:
          store.isLive ||
          snapshot?.profilesCapability == MissionCapabilityState.available,
      automations: _cronJobs == null
          ? null
          : homeAutomations(_cronJobs!, parseTime: cronParseTime),
      automationsFailed: _cronFailed,
      tasks: tasksBoard == null ? null : homeTasks(tasksBoard),
      tasksFailed: _tasksFailed,
      limits: _limits,
      server: HomeBoardServer(
        label: conn.label,
        online: _healthOk,
        link: _link?.kind,
        checking: _statusChecking,
        latencyMs: _healthOk && !_socketDown ? _latencyMs : null,
        version: serverInfo?.version,
        updateAvailable: serverInfo?.update,
      ),
      today: _initialLoadComplete
          ? HomeBoardToday.fromSessions(todayRows, now: now)
          : null,
    ).withGlance();
  }

  static bool _isBotChat(ActiveChat chat) =>
      chat.sessionId.startsWith('mob-bot-');

  late final HomeBoardActions _boardActions = HomeBoardActions(
    answer: _answerApproval,
    answerQuestion: _answerQuestion,
    viewApproval: _viewApproval,
    viewQuestion: (question) {
      if (question.ref case final HomeChatQuestionRef ref) {
        _openAttachedChat(ref.chat);
      }
    },
    openTasks: (task) => _openTasks(
      taskId: switch (task?.ref) {
        final KanbanTask t => t.id,
        _ => null,
      },
    ),
    retry: () {
      final conn = _active;
      if (conn == null) return;
      unawaited(_refreshCron(conn, force: true));
      if (_boardLayout?.contains(HomeWidgetKind.tasks) ?? false) {
        unawaited(_refreshTasks(conn, force: true));
      }
    },
    openChat: (chat) {
      if (chat.ref case final Session session) _openChat(session);
    },
    openRoom: (roomKey) => _openInBots(
      MissionControlOpenTarget.room(sessionId: '', roomId: roomKey),
    ),
    openBot: (bot) => _openInBots(
      MissionControlOpenTarget.bot(
        sessionId: bot.profile?.canonicalBotChatSessionId ?? '',
        profile: bot.profileName,
      ),
    ),
    openAutomation: (automation) => _openAutomations(
      job: switch (automation?.ref) {
        final CronJob job => job,
        _ => null,
      },
    ),
    openServer: () {
      final conn = _active;
      if (conn != null) showInstanceStatusSheet(context, conn);
    },
    openSessions: () {
      final conn = _active;
      if (conn != null) openDockSessions(context, conn, widget.connManager);
    },
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
    // The chat's own rules: read-only mode blocks approving and approving
    // asks App Lock first; denying never does.
    final allowed = await approvalAnswerAllowed(
      context,
      choice: choice,
      readOnlyInstance: conn.readOnly,
      sessionId: switch (item.ref) {
        final HomeChatApprovalRef ref =>
          ref.chat.storedSessionId ?? ref.chat.sessionId,
        _ => null,
      },
      reason: Strings.of(context).chaApproveOnce,
      lock: _appLock,
    );
    if (!allowed || !mounted) return;
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

  /// Sends one of a question's own choices through the chat that asked
  /// (the chat's `clarify.respond`), only while it still waits on it.
  Future<void> _answerQuestion(HomeQuestionItem item, String choice) async {
    final conn = _active;
    if (conn == null) return;
    if (conn.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    try {
      switch (item.ref) {
        case final HomeChatQuestionRef ref:
          await ref.answer(choice);
      }
    } catch (error) {
      debugPrint(
        '[home-dashboard] question answer failed (${error.runtimeType})',
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
        _openAttachedChat(ref.chat);
    }
  }

  /// Opens the screen of an attached chat that asks something: its Bot
  /// Chat in Bot Mode, or the conversation.
  void _openAttachedChat(ActiveChat chat) {
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

  void _openTasks({String? taskId}) {
    final conn = _active;
    if (conn == null) return;
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => TasksScreen(
              connection: conn,
              connManager: widget.connManager,
              initialTaskId: taskId,
            ),
          ),
        )
        .then((_) {
          _tasksReadAt = null;
          _refreshWhenUncovered();
        });
  }

  void _openAutomations({CronJob? job}) {
    final conn = _active;
    if (conn == null) return;
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => CronScreen(
              connection: conn,
              connManager: widget.connManager,
              initialJobId: job?.id,
              profileOverride: job?.sourceProfile,
            ),
          ),
        )
        .then((_) {
          _cronReadAt = null;
          _refreshWhenUncovered();
        });
  }

  /// The board of the active connection + profile: the one the user
  /// arranged on this device, else the default (with bots or rooms: Ahora,
  /// Bots, Salas and Cron; one agent: Ahora, Chats, Cron and Tareas).
  ///
  /// Which default applies is remembered once a Bots read tells, so the
  /// first frame of the next launch already shows the right board.
  HomeBoardLayout _layoutFor(SavedConnection conn, {HomeBoardData? data}) {
    final owner = Session.profileOwner(
      widget.connManager.activeProfileFor(conn.id),
    );
    final scope = '${conn.id}\u0000$owner';
    final store = _boardStore ??= HomeBoardStore(widget.connManager.prefs);
    // With bots or rooms on screen it is the bots board; «one agent» only
    // once the server's own list says there are none.
    final bool? team = data == null
        ? null
        : data.bots.isNotEmpty || data.rooms.isNotEmpty
        ? true
        : data.botsKnown
        ? false
        : null;
    if (team != null) {
      if (store.team(conn.id, owner) != team) {
        unawaited(
          store.rememberTeam(conn.id, owner, team).catchError((Object error) {
            debugPrint('[home-board] default kept (${error.runtimeType})');
            return false;
          }),
        );
        if (!_boardArranged) _boardLayout = null;
      }
    }
    if (_boardLayout == null || _boardScope != scope) {
      _boardScope = scope;
      _boardArranged = store.read(conn.id, owner) != null;
      _boardLayout = store.load(conn.id, owner, team: team);
    }
    return _boardLayout!;
  }

  void _saveLayout(SavedConnection conn, HomeBoardLayout layout) {
    final owner = Session.profileOwner(
      widget.connManager.activeProfileFor(conn.id),
    );
    setState(() {
      _boardLayout = layout;
      _boardArranged = true;
      _boardScope = '${conn.id}\u0000$owner';
    });
    unawaited(
      (_boardStore ??= HomeBoardStore(
        widget.connManager.prefs,
      )).save(conn.id, owner, layout).catchError((Object error) {
        debugPrint('[home-board] save failed (${error.runtimeType})');
      }),
    );
    // A widget added now may need data Home does not read for the others.
    _refreshBoardExtras(conn);
  }

  bool get _locked => _appLock?.locked.value == true;

  /// Reads only what a widget on the board needs and Home does not already
  /// read: the server version/update (Servidor), the plan limits (Límites)
  /// and the Kanban board (Tareas). Runs on Home's own refresh cadence,
  /// never on a timer, and never while App Lock is locked.
  void _refreshBoardExtras(SavedConnection conn) {
    if (_locked || !_healthOk || _active?.id != conn.id) return;
    final layout = _boardLayout;
    if (layout == null) return;
    if (layout.contains(HomeWidgetKind.server)) {
      unawaited(_refreshServerInfo(conn));
    }
    if (layout.contains(HomeWidgetKind.planLimits)) {
      unawaited(_refreshLimits(conn));
    }
    if (layout.contains(HomeWidgetKind.tasks)) {
      unawaited(_refreshTasks(conn));
    }
  }

  Future<void> _refreshServerInfo(SavedConnection conn) async {
    final loader =
        widget.serverInfoLoader ??
        (widget.clientFactory == null ? _defaultServerInfo : null);
    if (loader == null) return;
    final now = DateTime.now();
    final at = _serverInfoAt;
    if (_serverInfoScope == conn.id &&
        at != null &&
        now.difference(at) < _serverInfoMaxAge) {
      return;
    }
    _serverInfoAt = now;
    _serverInfoScope = conn.id;
    ({String? version, bool? update})? info;
    try {
      info = await loader(conn);
    } catch (error) {
      debugPrint('[home-board] server info (${error.runtimeType})');
      info = null;
    }
    if (!mounted || _active?.id != conn.id || _locked || info == null) return;
    setState(() => _serverInfo = info);
  }

  static Future<({String? version, bool? update})> _defaultServerInfo(
    SavedConnection conn,
  ) async {
    final client = DashboardClient.lazy(conn);
    try {
      final status = await client.getServerStatus();
      final version = status['version']?.toString().trim();
      bool? update;
      try {
        final payload = await client.checkUpdate();
        update = HermesUpdatePresentation.fromPayload(
          payload,
          fallbackVersion: version ?? '',
        ).hasUpdate;
      } catch (_) {
        update = null;
      }
      return (
        version: version == null || version.isEmpty ? null : version,
        update: update,
      );
    } finally {
      client.close();
    }
  }

  /// Plan limits through an attached chat of this connection that already
  /// has a runtime (`session.usage`, as the model sheet reads them); Home
  /// never opens a runtime for it.
  Future<void> _refreshLimits(SavedConnection conn) async {
    final now = DateTime.now();
    final at = _limitsAt;
    if (_limitsScope == conn.id &&
        at != null &&
        now.difference(at) < _limitsMinInterval) {
      return;
    }
    final override = widget.limitsLoader;
    Future<AccountUsageLimits?> Function()? load;
    if (override != null) {
      load = () => override(conn);
    } else {
      final service = _activeChats;
      if (service == null) return;
      // The limits are those of the account behind the chat's model: the
      // active profile's own chat first, then any other with a runtime.
      final owner = Session.profileOwner(
        widget.connManager.activeProfileFor(conn.id),
      );
      ActiveChat? chosen;
      for (final chat in missionActiveChats(
        service,
        conn.id,
        _recentSessions,
      )) {
        if (!chat.hasDesktopRuntime) continue;
        chosen ??= chat;
        if (Session.profileOwner(chat.sessionProfile) == owner) {
          chosen = chat;
          break;
        }
      }
      load = chosen?.loadAccountUsage;
    }
    if (load == null) return;
    _limitsAt = now;
    _limitsScope = conn.id;
    AccountUsageLimits? limits;
    try {
      limits = await load();
    } catch (error) {
      debugPrint('[home-board] plan limits (${error.runtimeType})');
      limits = null;
    }
    if (!mounted || _active?.id != conn.id || _locked || limits == null) {
      return;
    }
    setState(() => _limits = limits);
    // The launcher widgets name the same subscription.
    final published = homeWidgetLimits(
      limits,
      Strings.of(context),
      languageCode: Localizations.localeOf(context).languageCode,
    );
    final app = context.findAncestorStateOfType<HermesAppState>();
    final update = widget.homeWidgetUpdateOverride ?? app?.updateHomeWidget;
    unawaited(
      update?.call((current) => current.copyWith(limits: published)) ??
          Future<void>.value(),
    );
  }

  /// What the keyboard takes from the page: the inset the Scaffold below
  /// shortens its body by. Looked up without depending on it, so Home is
  /// not rebuilt for the keyboard.
  double _keyboardInset() {
    if (!mounted) return 0;
    final query = context.getInheritedWidgetOfExactType<MediaQuery>();
    return query?.data.viewInsets.bottom ?? 0;
  }

  Widget _buildBoard(
    SavedConnection active, {
    required List<Widget> banners,
    required double bottomClearance,
  }) {
    final lock = _appLock?.locked;
    Widget board() {
      // App Lock: nothing private is derived or painted before unlock.
      if (_locked) {
        return ListView(
          key: const ValueKey('home-board-locked'),
          physics: const AlwaysScrollableScrollPhysics(),
        );
      }
      final data = _boardDataFor(active);
      final layout = _layoutFor(active, data: data);
      return HomeBoardSteady(
        keyboard: _keyboardInset,
        child: HomeBoardView(
          key: _boardViewKey,
          layout: layout,
          data: data,
          actions: _boardActions,
          newId: (_boardStore ??= HomeBoardStore(
            widget.connManager.prefs,
          )).newId,
          clock: _clock,
          onChanged: (next) => _saveLayout(active, next),
          // What is still unknown on a cold start waits inside its own
          // widget; the board keeps its rows.
          leading: [
            ...banners,
            if (_healthOk &&
                !active.readOnly &&
                data.chatsLoaded &&
                data.chats.isEmpty)
              HermesPrimaryButton(
                key: const ValueKey('home-first-chat'),
                label: Strings.of(context).o2FirstChat,
                icon: Icons.chat_bubble_outline,
                onTap: _newChat,
              ),
          ],
          bottomPadding: bottomClearance,
          initiallyEditing: widget.initiallyEditingBoard,
          onEditingChanged: (_) {
            // The header gives way to the edit bar, and comes back.
            if (mounted) setState(() {});
          },
        ),
      );
    }

    if (lock == null) return board();
    return ValueListenableBuilder<bool>(
      valueListenable: lock,
      builder: (context, _, _) => board(),
    );
  }

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
    final page = Scaffold(
      appBar: HermesAppBar(
        centerTitle: false,
        titleSpacing: 0,
        // Home's own header, as approved: a plain menu icon, the title block
        // as text at the start and the profile's round button standing
        // alone. Nothing scrolls under it, so nothing floats and no scrim.
        floatingLeading: false,
        titleInPill: false,
        actionsInPill: false,
        scrim: false,
        // Active profile, one tap from Home (Desktop's profile rail). Its
        // ring ends 16 dp from the screen edge, like the menu icon's side.
        actions: [
          if (_active != null)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 8, end: 14),
              child: ProfileSwitcherButton(
                connection: _active!,
                connManager: widget.connManager,
                compact: true,
                rosterRegistry: _rosterRegistry,
                onManage: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ProfilesScreen(
                      connection: _active!,
                      connManager: widget.connManager,
                    ),
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
                    builder: (context, title, _) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SeasonalMark(key: ValueKey('home-header-mark')),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            title,
                            key: const ValueKey('home-header-title'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.2,
                              fontSize: 18,
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                      ],
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
        connected: _healthOk && !_socketDown,
        link: _link?.kind,
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
              final isRemoteAndOffline =
                  _initialLoadComplete && !_healthOk && !_checking;
              // El dock flotante (`Dock`) se pinta como overlay
              // (Positioned) ENCIMA de esta lista, no reserva espacio por sí
              // mismo. Sin este margen extra, el último item de recientes
              // quedaba tapado/cortado por el dock (confirmado por captura
              // real del dispositivo). Reserva: alto del dock (48) + su
              // separación del borde (12) + el lift máximo de la profundidad
              // "Flotante" (6) + el inset seguro inferior del sistema +
              // un margen de aire adicional para que no quede pegado.
              // With the gesture dock (QA 9494 default) the clearance is
              // its own footprint: inset + gap + bar + breathing room.
              final dockBottomClearance =
                  FeatureFlags.instance.gestureDock.value
                  ? gestureDockFootprint(context)
                  : 48 + 12 + 6 + MediaQuery.paddingOf(context).bottom + 16;
              final banners = <Widget>[
                // A failed refresh keeps the last good list, but still says
                // so and offers the retry.
                if (_recentListFailed && !isRemoteAndOffline)
                  _ProfileListErrorCard(
                    profile: ProfileScopeLabel.display(
                      Strings.of(context),
                      widget.connManager.activeProfileFor(active.id),
                    ),
                    onRetry: _refreshStatus,
                    onSignIn: _recentListLoginRefused ? _signInFromList : null,
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
              final content = RefreshIndicator(
                color: colors.accent,
                onRefresh: _refreshStatus,
                child: _buildBoard(
                  active,
                  banners: banners,
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
    // Editing the board: the same page without its header, whose place
    // the board's edit bar takes.
    if (!_boardEditing || _active == null || _locked) return page;
    return Scaffold(
      drawerEnableOpenDragGesture: page.drawerEnableOpenDragGesture,
      drawerEdgeDragWidth: page.drawerEdgeDragWidth,
      drawer: page.drawer,
      body: page.body,
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
  final VoidCallback? onSignIn;

  const _ProfileListErrorCard({
    required this.profile,
    required this.onRetry,
    this.onSignIn,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return HermesEmptyState(
      key: const ValueKey('home-profile-list-error'),
      compact: true,
      title: s.homeProfileListErrorTitle(profile),
      body: onSignIn != null
          ? s.s2SessionExpiredBody
          : s.homeProfileListErrorBody,
      primaryLabel: onSignIn != null ? s.s2SessionExpiredSignIn : s.commonRetry,
      primaryIcon: onSignIn != null
          ? Icons.login_rounded
          : Icons.refresh_rounded,
      onPrimary: onSignIn ?? onRetry,
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
                      // A connection that only had the Gateway meets the
                      // Dashboard here: the official command, one tap away.
                      TextButton.icon(
                        key: const ValueKey('home-offline-dashboard-setup'),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ManualSetupPage(
                              connManager: context
                                  .findAncestorWidgetOfExactType<
                                    HomeDashboardScreen
                                  >()
                                  ?.connManager,
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.terminal_rounded, size: 18),
                        label: Text(s.homeOfflineDashboardSetup),
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
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CompanionProfileFace(
                          controller: controller,
                          size: 48,
                          animate: false,
                        ),
                        const SizedBox(height: 14),
                      ],
                    );
                  },
                );
              },
            ),
            // One plain sentence and one button: no ports, no jargon.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                Strings.of(context).homeNoInstances,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.4,
                  color: colors.textSecondary,
                ),
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

/// Add-instance dialog with live validation against the Dashboard before
/// saving.
/// Kept public so onboarding flows elsewhere can reuse it.
