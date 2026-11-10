import 'dart:async';
import '../bots/data/gateway_socket_meter.dart';
import '../services/app_lock_sensitive_read_fence.dart';
import '../services/connection_status.dart';
import '../services/cold_start_store.dart';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../models/calendar_bucket.dart';
import 'recover_access_page.dart';
import '../models/project_move_targets.dart';
import '../models/session_category.dart';
import '../models/session_list_sort.dart';
import '../models/desktop_active_session.dart';
import '../models/desktop_control_center.dart';
import '../models/session_live_status.dart';
import '../navigation/chat_route.dart';
import '../navigation/enclosing_route.dart';
import '../models/agent_profile.dart';
import '../services/active_profile_scope.dart';
import '../services/bot_roster_store.dart';
import '../widgets/mission_profile_avatar.dart';
import '../widgets/profile_face.dart';
import '../widgets/profile_scope.dart';
import '../services/active_chat_service.dart';
import '../models/core_read.dart';
import '../services/connection_manager.dart';
import 'dashboard_sign_in.dart';
import '../services/new_session_factory.dart';
import '../services/connection_health_tracker.dart';
import '../services/desktop_control_gateway.dart'
    show DesktopControlFailure, DesktopControlFailureKind;
import '../services/dock_preferences_store.dart';
import '../services/global_activity_aggregate.dart';
import '../services/launcher_widget_chats.dart';
import '../services/chat_draft_store.dart';
import '../services/drawer_gesture_exclusion.dart';
import '../services/roster_known_filter.dart';
import '../services/session_archive.dart';
import '../services/session_export_service.dart';
import '../services/session_deletion.dart';
import '../services/session_repository.dart';
import '../services/tui_gateway_client.dart';
import '../services/shared_gateway_pool.dart';
import '../utils/home_recent_sessions.dart';
import '../utils/session_title.dart';
import '../utils/session_timestamp.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import '../theme/text_scale.dart';
import '../widgets/onstage_gate.dart';
import '../widgets/working_ring.dart';
import '../widgets/accent_card.dart';
import '../utils/responsive.dart';
import '../widgets/adaptive_list_detail.dart';
import '../widgets/calendar_bucket_label.dart';
import '../widgets/general_dock_shell.dart';
import '../widgets/dock_scroll_clearance.dart';
import '../widgets/workspace/chat_workspace.dart';
import '../widgets/workspace/chat_workspace_host.dart' show ChatWorkspaceScope;
import '../widgets/workspace/chat_switcher.dart';
import '../widgets/workspace/profile_rail_chats.dart';
import '../widgets/hermes_drawer.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_premium_ui.dart';
import '../design/ambient_backdrop.dart' show HermesGlassLook;
import '../widgets/hermes_ui.dart';
import '../widgets/loading_skeleton.dart';
import '../widgets/read_only.dart';
import '../widgets/session_deletion_dialogs.dart';
import '../widgets/session_title_editor_route.dart';
import '../widgets/session_row_stop_control.dart';
import 'chat_screen.dart';
import 'cron_screen.dart';
import 'mission_control_screen.dart';
import '../services/session_pull_requests.dart';
import '../widgets/session_pull_request_row.dart';
import 'foreign_session_import_screen.dart';
import 'session_branches_screen.dart';
import 'session_detail_screen.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/session_status_tone.dart';
import '../widgets/console_loader.dart';
import '../design/hermes_design.dart'
    show
        HermesControlsScroll,
        HermesAction,
        HermesDialogAction,
        HermesDialogActionStyle,
        HermesMenuButton,
        showHermesDialog;
import '../feedback/feedback_policy.dart';

const sessionLibraryRefreshGap = Duration(seconds: 10);

/// Roster refreshes driven by events of runtimes the aggregate does not route
/// are coalesced to one per 30 s, like Desktop's event-driven `active_list`.
const sessionLibraryActivityRefreshGap = Duration(seconds: 30);
const sessionLibrarySafetyRefreshInterval = Duration(seconds: 60);

bool isSessionLibraryRefreshEvent(TuiGatewayEvent event) =>
    event.type == 'sessions.changed';

// ─────────────────────────────────────────────────────────────────────────────
// Filter enum
// ─────────────────────────────────────────────────────────────────────────────

extension _SessionCategoryLabel on SessionCategory {
  String label(Strings s) => switch (this) {
    SessionCategory.chats => s.slFilterAll,
    SessionCategory.automation => s.slFilterAutomation,
    SessionCategory.all => s.slFilterEverything,
  };
}

/// Combina la vista autoritativa del servidor con borradores que todavía no
/// existen allí. Un borrador local nunca debe eclipsar metadatos remotos (por
/// ejemplo, [Session.parentSessionId]) aunque tenga una fecha más reciente.
@visibleForTesting
List<Session> mergeRemoteSessionsWithDrafts(
  Iterable<Session> authoritative,
  Iterable<Session> drafts,
) {
  (String, String) identity(Session session) =>
      (Session.profileOwner(session.profile), session.id);
  final byId = <(String, String), Session>{};
  for (final session in authoritative) {
    byId[identity(session)] = session.hasLocalDraft
        ? session.copyWith(hasLocalDraft: false)
        : session;
  }
  for (final draft in drafts) {
    final key = identity(draft);
    final authoritativeSession = byId[key];
    byId[key] = authoritativeSession == null
        ? draft.copyWith(hasLocalDraft: true)
        : authoritativeSession.copyWith(hasLocalDraft: true);
  }
  return byId.values.toList(growable: false);
}

/// Desktop `sessionMatchesSearch` (`lib/session-search.ts`): case-insensitive
/// substring over the fields a loaded row carries. Hermes' search endpoint
/// only matches ids and FTS5 message tokens by prefix (never titles), so
/// Desktop finds a chat titled "QA 9485" by "9485" only through this.
@visibleForTesting
bool sessionMatchesSearchText(
  Session session,
  String needle, {
  required String title,
}) {
  if (needle.isEmpty) return true;
  return <String>[
    session.id,
    session.lineageRootId ?? '',
    title,
    session.preview,
    session.cwd ?? '',
    session.gitBranch ?? '',
    session.source,
  ].any((value) => value.toLowerCase().contains(needle));
}

/// Desktop `mergeSearchResults`: the ranked server hits keep their order and
/// loaded rows the server did not return follow, in list order, once per
/// owner and lineage. When several loaded segments of one lineage match, the
/// newest one (the lineage tip) takes the slot of the first; on equal
/// timestamps the segment that continues the other one wins, so the tip is
/// shown whatever the input order.
@visibleForTesting
List<Session> appendLoadedSearchMatches(
  List<Session> hits,
  Iterable<Session> loadedMatches,
) {
  Iterable<(String, String)> keys(Session row) {
    final owner = Session.profileOwner(row.profile);
    return row.identityIds.map((id) => (owner, id));
  }

  // `row` continues `earlier` when its chain names `earlier` before itself.
  bool continues(Session row, Session earlier) {
    if (row.id == earlier.id) return false;
    if (earlier.id == row.lineageRootId) return true;
    if (earlier.id == row.parentSessionId) return true;
    final at = row.lineageIds.indexOf(earlier.id);
    final self = row.lineageIds.indexOf(row.id);
    return at >= 0 && (self < 0 || at < self);
  }

  bool supersedes(Session row, Session current) {
    final delta = row.lastActivityAt.compareTo(current.lastActivityAt);
    if (delta != 0) return delta > 0;
    return continues(row, current) && !continues(current, row);
  }

  final seen = <(String, String)>{for (final hit in hits) ...keys(hit)};
  final appended = <Session>[];
  final slotByKey = <(String, String), int>{};
  for (final row in loadedMatches) {
    final rowKeys = keys(row).toList(growable: false);
    if (rowKeys.any(seen.contains)) continue;
    final slot = rowKeys.map((key) => slotByKey[key]).nonNulls.firstOrNull;
    if (slot == null) {
      appended.add(row);
    } else if (supersedes(row, appended[slot])) {
      appended[slot] = row;
    }
    for (final key in rowKeys) {
      slotByKey[key] = slot ?? appended.length - 1;
    }
  }
  return [...hits, ...appended];
}

/// Identifica filas cuyo estado durable cambió dentro del mismo owner y
/// lineage. `sessions.changed` no promete un session id en el payload, por lo
/// que esta comparación se hace después de la lectura REST autoritativa.
@visibleForTesting
List<Session> changedDurableSessions(
  Iterable<Session> previous,
  Iterable<Session> current,
) {
  (String, String) identity(Session session) =>
      (Session.profileOwner(session.profile), session.logicalId);
  final before = <(String, String), Session>{
    for (final session in previous.where((session) => !session.isDraftOnly))
      identity(session): session,
  };
  bool sameRevision(Session left, Session right) =>
      left.id == right.id &&
      left.messageCount == right.messageCount &&
      left.lastActivityAt == right.lastActivityAt &&
      left.endedAt == right.endedAt &&
      left.isActive == right.isActive &&
      left.preview == right.preview &&
      left.lastUserPreview == right.lastUserPreview &&
      left.lastAssistantPreview == right.lastAssistantPreview;

  return current
      .where((session) => !session.isDraftOnly)
      .where((session) {
        final prior = before[identity(session)];
        return prior == null || !sameRevision(prior, session);
      })
      .toList(growable: false);
}

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

class SessionListScreen extends StatefulWidget {
  /// How many times the filtered/sorted session view was recomputed.
  @visibleForTesting
  static int debugFilterPasses = 0;

  /// Forgets which connections answered method-not-found to a workspace move.
  @visibleForTesting
  static void debugResetMoveSupport() =>
      _SessionListScreenState._moveUnsupported.clear();

  final SavedConnection connection;
  final ConnectionManager connManager;
  final ApiClient? clientOverride;
  final SessionRepository? repositoryOverride;
  final Stream<TuiGatewayEvent>? eventStreamOverride;
  final ActiveChatService? activeChatsOverride;
  final GlobalActivityAggregate? globalActivityOverride;
  final Future<DesktopActiveSessionList> Function()? activeSessionListLoader;
  final Future<AgentCenterSnapshot> Function(String runtimeSessionId)?
  agentCenterSnapshotLoader;
  final Future<void> Function()? eventReconnectOverride;
  final double Function()? eventReconnectRandomOverride;

  /// Wall clock for the date sections, and the gateway and exporter the
  /// "move to project" and "export" row actions use.
  final DateTime Function()? clockOverride;
  final TuiGatewayClient Function(SavedConnection connection)? gatewayFactory;
  final SessionExportService? sessionExporter;

  /// The rail's cache of the other profiles' chats (tests: their own, with
  /// no pause between requests). Defaults to the connection's shared one.
  final ProfileRailChats? railChatsOverride;
  const SessionListScreen({
    required this.connection,
    required this.connManager,
    @visibleForTesting this.clientOverride,
    @visibleForTesting this.repositoryOverride,
    @visibleForTesting this.eventStreamOverride,
    @visibleForTesting this.activeChatsOverride,
    @visibleForTesting this.globalActivityOverride,
    @visibleForTesting this.activeSessionListLoader,
    @visibleForTesting this.agentCenterSnapshotLoader,
    @visibleForTesting this.eventReconnectOverride,
    @visibleForTesting this.eventReconnectRandomOverride,
    @visibleForTesting this.clockOverride,
    @visibleForTesting this.gatewayFactory,
    @visibleForTesting this.sessionExporter,
    @visibleForTesting this.chatScreenBuilderOverride,
    @visibleForTesting this.railChatsOverride,
    this.autofocusSearch = false,
    super.key,
  });

  /// Opens with the search field focused (the chat notch's "Buscar chats").
  final bool autofocusSearch;

  /// Builds the conversation instead of [ChatScreen] (widget tests: the real
  /// chat needs the whole app around it).
  final Widget Function(Session session)? chatScreenBuilderOverride;

  @override
  State<SessionListScreen> createState() => _SessionListScreenState();
}

class _SessionListScreenState extends State<SessionListScreen>
    with WidgetsBindingObserver, RouteAware {
  late final ApiClient _client;
  late final SessionRepository? _repository;
  late final bool _ownsRepository;
  TuiGatewayClient? _ownedActivityClient;
  PullRequestTagService? _pullRequests;
  SharedGatewayLease? _activityLease;
  StreamSubscription<TuiGatewayEvent>? _eventSubscription;
  StreamSubscription<HistoryCleanupInvalidation>? _historyCleanupSubscription;
  StreamSubscription<ChatDraftChange>? _draftSubscription;
  Timer? _eventRefreshTimer;
  Timer? _activityRefreshTimer;
  Timer? _activityPollTimer;
  DateTime? _lastActivityRefreshAt;

  /// A roster read dropped rows the list had not loaded yet; the next list
  /// load re-reads it so those rows are coloured at once, not 30 s later.
  bool _rosterRowsDeferred = false;

  void _replayDeferredRoster() {
    if (!_rosterRowsDeferred) return;
    _rosterRowsDeferred = false;
    unawaited(_refreshRemoteActivity());
  }

  /// A roster refresh was skipped while the list sat under another route; it
  /// runs once in [didPopNext].
  bool _remoteActivityDirty = false;

  /// Runtimes whose first unrouted event already forced a discovery read; the
  /// rest of their events wait for the coalesced refresh.
  final Set<String> _discoveredRuntimes = <String>{};

  /// Durable ids where a probe saw live background processes: those rows are
  /// still probed after the turn ends (Desktop's hollow dot).
  final Set<String> _rowsWithLiveProcesses = <String>{};
  Timer? _eventReconnectTimer;
  Timer? _eventStableTimer;
  Timer? _sessionSafetyTimer;
  Timer? _staleExpiryTimer;
  late final GatewayReconnectBackoff _eventReconnectBackoff;
  bool _recoveringTransport = false;
  DateTime? _lastEventRefreshAt;
  int _sessionChangeEpoch = 0;
  int _appliedSessionChangeEpoch = 0;
  int _sessionFetchEpoch = 0;
  bool _foreground = true;
  List<Session> _sessions = [];
  bool _loading = true;
  Object? _error;
  final ConnectionHealthTracker _health = ConnectionHealthTracker();
  Timer? _retryTimer;
  Timer? _searchTimer;
  int _searchRequestEpoch = 0;
  String _searchQuery = '';
  List<Session>? _searchResults;
  bool _searching = false;
  bool _searchExhaustive = true;
  bool _loadingMore = false;
  bool _libraryExhaustive = false;
  SessionLibrarySource _librarySource = SessionLibrarySource.local;
  final ScrollController _libraryScrollController = ScrollController();

  final Map<String, bool> _pendingArchiveByLogicalId = {};

  /// Bumped by in-place mutations of [_sessions], [_searchResults] or
  /// [_pendingArchiveByLogicalId]; reassignments are caught by identity.
  int _listRevision = 0;
  Object? _filteredKey;
  List<Session> _filteredCache = const [];
  SessionCategory _activeCategory = SessionCategory.chats;
  bool _showArchived = false;

  /// Archive shows the hidden chats instead of the archived ones. Hermes'
  /// listing omits hidden rows and Desktop has no hidden view, so this is
  /// the one place to find them and show them again.
  bool _showHiddenInArchive = false;
  bool get _hiddenView => _showArchived && _showHiddenInArchive;

  /// View order of the list (a per-connection preference of this device).
  SessionListSort _sort = SessionListSort.activity;

  /// The project tree, once a "move to project" loaded it in this screen
  /// session. The menu never loads it just to paint itself.
  ProjectTreeSnapshot? _projectTree;

  /// Folder of the project the list is narrowed to, or null for all.
  String? _projectFilterFolder;

  /// Connections whose server answered `session.workspace.move` with
  /// method-not-found: the entry stays hidden for them (memory only).
  static final Set<String> _moveUnsupported = {};

  String get _sortPrefKey => 'session_list_sort:${widget.connection.id}';
  DateTime _now() => (widget.clockOverride ?? DateTime.now)();

  SessionArchive? _archive;
  SessionPinSync? _pinSync;

  /// This screen's writer of hidden/title/read state on the shared store
  /// (detached on dispose, when [_repository] may close).
  SessionStateWriter? _stateWriter;
  bool _archiveReady = false;

  /// Servicio singleton de chats activos: observamos [ActiveChatService.activeIds]
  /// para pintar el indicador de "chat ejecutándose en segundo plano".
  ActiveChatService? _activeChats;
  GlobalActivityAggregate? _globalActivity;
  PageRoute<dynamic>? _route;
  final OnstageGate _activeIdsGate = OnstageGate();

  /// ss1215: repaints the rows in the same frame an attached chat's live
  /// status changes (tool, waiting, done), held while a chat covers the list.
  final OnstageGate _liveStatusGate = OnstageGate();

  /// The Chats list the last run saved, painted while the server answers
  /// (what Nous calls «Chat List» caching). It stands only for the default
  /// view (Chats, not archived) of one profile, and only until a read lands.
  bool _coldListChecked = false;
  bool _showingColdList = false;
  String _coldListOwner = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _activeChats ??=
        widget.activeChatsOverride ??
        context.findAncestorStateOfType<HermesAppState>()?.activeChats;
    _paintColdStartList();
    _globalActivity ??=
        widget.globalActivityOverride ?? _activeChats?.globalActivity;
    // `activeIds` is force-notified on every subagent event of a run. While a
    // chat covers this list, hold those notifications and deliver one on
    // return instead of rebuilding the hidden ListView each time.
    _activeIdsGate.bind(context, _activeChats?.activeIds);
    _liveStatusGate.bind(context, _activeChats?.liveStatusRevision);
  }

  /// The route arrives through [EnclosingRoute] instead of
  /// `ModalRoute.of(context)` here: that call made the whole list depend on
  /// the route status and rebuild in the first frame of every push over it
  /// and every pop back to it.
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
    // After the back transition, not inside it (see [runWhenUncovered]).
    runWhenUncovered(context, _route, () {
      if (!mounted) return;
      if (_healthCheckOwed) {
        _healthCheckOwed = false;
        unawaited(_checkHealth());
      }
      unawaited(_fetchSessions(showLoader: false));
      if (_remoteActivityDirty) {
        _remoteActivityDirty = false;
        unawaited(_refreshRemoteActivity());
      }
    });
  }

  @override
  void didPushNext() => unawaited(DrawerGestureExclusion.setEnabled(false));

  @override
  void didPop() => unawaited(DrawerGestureExclusion.setEnabled(false));

  void _onDraftDisclosureChanged() {
    if (!mounted) return;
    ++_sessionFetchEpoch;
    if (!AppLockSensitiveReadFence.capture(
      widget.connManager.prefs,
    ).isCurrent) {
      setState(() {
        _sessions = _sessions.where((s) => s.source != 'mobile-draft').toList();
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        runWhenUncovered(context, _route, () {
          if (_libraryRefreshAllowed) {
            unawaited(_fetchSessions(showLoader: false));
          }
        });
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  @override
  void initState() {
    super.initState();
    AppLockSensitiveReadFence.changes.addListener(_onDraftDisclosureChanged);
    ConnectionStatusRegistry.instance.changes.addListener(_onLinkChanged);
    _health.link = ConnectionStatusRegistry.instance.current(
      widget.connection.id,
    );
    WidgetsBinding.instance.addObserver(this);
    _eventReconnectBackoff = GatewayReconnectBackoff(
      random: widget.eventReconnectRandomOverride,
    );
    _armSessionSafetyTimer();
    _activeChats = widget.activeChatsOverride;
    _globalActivity = widget.globalActivityOverride;
    _client =
        widget.clientOverride ?? ApiClient.forConnection(widget.connection);
    _ownsRepository =
        widget.repositoryOverride == null && widget.clientOverride == null;
    _repository =
        widget.repositoryOverride ??
        (widget.clientOverride == null
            ? SessionRepository.forConnection(
                widget.connection,
                gateway: _client,
              )
            : null);
    if (widget.clientOverride == null) {
      final lease = SharedGatewayPool.instance.acquire(widget.connection);
      _activityLease = lease;
      _ownedActivityClient = lease.client;
      unawaited(_confirmForeignImport(lease.client));
    }
    _startEventUpdates();
    unawaited(_refreshRemoteActivity());
    _historyCleanupSubscription = historyCleanupInvalidations.events.listen(
      _onHistoryCleanupInvalidation,
    );
    _draftSubscription = ChatDraftStore.changes.listen((change) {
      if (!mounted ||
          !_foreground ||
          _route?.isCurrent == false ||
          change.connectionId != widget.connection.id ||
          change.profile != Session.profileOwner(_libraryQuery.profile)) {
        return;
      }
      unawaited(_fetchSessions(showLoader: false));
    });
    _libraryScrollController.addListener(_onLibraryScroll);
    _profileScope.addListener(_onActiveProfileChanged);
    _loadPrefs();
    _checkHealth();
  }

  late final ProfileRailChats _railChats =
      widget.railChatsOverride ?? ProfileRailChats.of(widget.connection.id);
  bool _railReadScheduled = false;

  late final ActiveProfileScope _profileScope = ActiveProfileScope.of(
    widget.connManager,
    widget.connection.id,
  );

  /// A profile switch is a workspace switch: read the new profile's list
  /// (behind the loader). Reads still on the wire for the previous profile
  /// are dropped by the query fingerprint and the fetch epoch.
  void _onActiveProfileChanged() {
    if (!mounted) return;
    _refreshLibraryScope();
    unawaited(_refreshRemoteActivity());
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final archive = await SessionArchive.load(prefs, widget.connection.id);
    if (!mounted) return;
    final storedSort = SessionListSort.fromWire(prefs.getString(_sortPrefKey));
    final repository = _repository;
    final pinSync = SessionPinSync(
      archive,
      writeRemote: repository == null || widget.connection.readOnly
          ? null
          : (id, pinned, profile) =>
                repository.setPinned(id, pinned, profile: profile),
      isUnsupported: (error) =>
          error is DashboardHttpException &&
          (error.statusCode == 404 || error.statusCode == 405),
    );
    if (repository != null && !widget.connection.readOnly) {
      final writer = _stateWriter = repository.patchSessionState;
      archive.attachRemoteState(writer, httpStatusOf: dashboardHttpStatusOf);
    }
    setState(() {
      // Shared per-connection store: a rename, archive, pin or hide made on
      // another screen (Home, chat auto-title, detail) repaints this list.
      _archive?.removeListener(_onArchiveChanged);
      _archive = archive;
      archive.addListener(_onArchiveChanged);
      _pinSync = pinSync;
      _sort = storedSort;
      _archiveReady = true;
    });
    await _migrateLineagePreferences(_sessions);
    await pinSync.updateSessions(_sessions);
    if (mounted) setState(() {});
  }

  /// Safety refresh while the app is visible. Cancelled in background (its
  /// ticks would only wake the isolate to find refresh disallowed) and re-armed
  /// on resume, whose health check already refreshes the library at once.
  void _armSessionSafetyTimer() {
    _sessionSafetyTimer?.cancel();
    _sessionSafetyTimer = Timer.periodic(sessionLibrarySafetyRefreshInterval, (
      _,
    ) {
      if (_libraryRefreshAllowed) unawaited(_fetchSessions(showLoader: false));
    });
  }

  bool get _libraryRefreshAllowed =>
      mounted && _foreground && _route?.isCurrent != false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      if (_sessionSafetyTimer == null) _armSessionSafetyTimer();
      // Covered by a chat, the list's probe waits for `didPopNext`: on a
      // resume it would only compete with the chat's own recovery.
      if (_listVisible) {
        _checkHealth();
      } else {
        _healthCheckOwed = true;
      }
      _scheduleEventReconnect(immediate: true);
    } else {
      if (state != AppLifecycleState.inactive) {
        _sessionSafetyTimer?.cancel();
        _sessionSafetyTimer = null;
        // In the background the rail reads no other profile.
        _railChats.cancel(this);
      }
      _eventReconnectTimer?.cancel();
      _eventReconnectTimer = null;
      _eventStableTimer?.cancel();
      _eventStableTimer = null;
      _staleExpiryTimer?.cancel();
      _staleExpiryTimer = null;
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.detached) {
        unawaited(_globalActivity?.flushJournal());
      }
    }
  }

  void _onLinkChanged() {
    if (!mounted) return;
    setState(
      () => _health.link = ConnectionStatusRegistry.instance.current(
        widget.connection.id,
      ),
    );
  }

  Future<void> _checkHealth() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!mounted) return;
    final generation = _health.beginProbe();
    setState(() {});
    final ok = await _client.healthCheck();
    if (!mounted || !_health.recordResult(generation, healthy: ok)) return;
    ConnectionStatusRegistry.instance.reportRest(
      widget.connection.id,
      reachable: ok,
    );
    setState(() {});
    if (ok) {
      // Rows already on screen stay while the read lands (Desktop's way).
      unawaited(_fetchSessions(showLoader: false));
      unawaited(_refreshRemoteActivity());
    } else {
      await _showLocalDrafts();
      _retryTimer = Timer(_health.retryDelay, _checkHealth);
    }
  }

  Future<List<Session>?> _draftSessions({String? profile}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ticket = AppLockSensitiveReadFence.capture(prefs);
      final entries = await ChatDraftStore(
        prefs,
      ).listForConnection(widget.connection.id);
      if (!mounted) return const [];
      ticket.ensureCurrent();
      final fallback = Strings.of(context).drawerNewChat;
      final owner = Session.profileOwner(profile);
      return entries
          .where((entry) => Session.profileOwner(entry.profile) == owner)
          .map((entry) => entry.toSession(fallbackTitle: fallback))
          .toList();
    } catch (e) {
      debugPrint(
        '[session-list] no se pudieron listar borradores: ${e.runtimeType}',
      );
      return null;
    }
  }

  Future<void> _showLocalDrafts() async {
    final fetchEpoch = _sessionFetchEpoch;
    final scope = _libraryQuery;
    final ticket = AppLockSensitiveReadFence.capture(widget.connManager.prefs);
    final drafts = await _draftSessions(profile: scope.profile);
    if (!ticket.isCurrent || drafts == null) return;
    if (fetchEpoch != _sessionFetchEpoch ||
        scope.fingerprint != _libraryQuery.fingerprint) {
      return;
    }
    if (!mounted || (drafts.isEmpty && _sessions.isEmpty)) return;
    final owner = Session.profileOwner(scope.profile);
    setState(() {
      final visibleRemote = _sessions.where(
        (session) =>
            session.source != 'mobile-draft' &&
            Session.profileOwner(session.profile) == owner,
      );
      _sessions = _withoutDeleted(
        mergeRemoteSessionsWithDrafts(visibleRemote, drafts),
      )..sort(compareSessionsByRecentActivity);
      _loading = false;
      _error = null;
    });
  }

  void _onArchiveChanged() {
    if (!mounted) return;
    // A delete made on another screen leaves what this screen keeps (the
    // repository page and search results), not only what it paints.
    final archive = _archive;
    if (archive != null) {
      final deleted = <Session>[
        ..._sessions.where(archive.isSessionDeleted),
        ...?_searchResults?.where(archive.isSessionDeleted),
      ];
      if (deleted.isNotEmpty) {
        _repository?.evictSessions(deleted);
        _sessions = _withoutDeleted(_sessions);
        final results = _searchResults;
        if (results != null) _searchResults = _withoutDeleted(results);
      }
    }
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      setState(() {});
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _views.dispose();
    _railChats.cancel(this);
    ConnectionStatusRegistry.instance.changes.removeListener(_onLinkChanged);
    AppLockSensitiveReadFence.changes.removeListener(_onDraftDisclosureChanged);
    _profileScope.removeListener(_onActiveProfileChanged);
    _archive?.removeListener(_onArchiveChanged);
    final stateWriter = _stateWriter;
    if (stateWriter != null) _archive?.detachRemoteState(stateWriter);
    hermesRouteObserver.unsubscribe(this);
    unawaited(DrawerGestureExclusion.setEnabled(false));
    // A move still choosing or running gives its socket lease back.
    _moveLease?.release();
    _moveLease = null;
    _retryTimer?.cancel();
    _searchTimer?.cancel();
    _eventRefreshTimer?.cancel();
    _activityRefreshTimer?.cancel();
    _activityPollTimer?.cancel();
    _eventReconnectTimer?.cancel();
    _eventStableTimer?.cancel();
    _sessionSafetyTimer?.cancel();
    _staleExpiryTimer?.cancel();
    unawaited(_eventSubscription?.cancel());
    unawaited(_historyCleanupSubscription?.cancel());
    unawaited(_draftSubscription?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    _libraryScrollController.dispose();
    if (_ownsRepository) _repository?.close();
    _activityLease?.release();
    _activityLease = null;
    _ownedActivityClient = null;
    _client.close();
    _activeIdsGate.dispose();
    _liveStatusGate.dispose();
    super.dispose();
  }

  void _startEventUpdates() {
    final stream = widget.eventStreamOverride ?? _ownedActivityClient?.events;
    _eventSubscription = stream?.listen(
      _onSessionLibraryEvent,
      onError: (_) {
        _eventStableTimer?.cancel();
        _eventStableTimer = null;
        // Preserve the last authoritative projection while reconnect/refresh
        // rebuilds the roster cut; never flash a false idle state.
        _globalActivity?.beginRecovery(
          widget.connection.id,
          Session.profileOwner(_libraryQuery.profile),
        );
        _recoveringTransport = true;
        _scheduleStaleExpiry();
        _scheduleEventReconnect();
      },
    );
    if (_ownedActivityClient != null) unawaited(_connectEventClient());
  }

  Future<void> _connectEventClient() async {
    final client = _ownedActivityClient;
    final reconnect = widget.eventReconnectOverride;
    if (client == null && reconnect == null) return;
    if (client?.isConnected == true && reconnect == null) return;
    try {
      if (reconnect != null) {
        await reconnect();
      } else {
        await client!.connect();
      }
      _eventStableTimer?.cancel();
      _eventStableTimer = Timer(GatewayReconnectBackoff.stableInterval, () {
        _eventStableTimer = null;
        if (mounted && _foreground) _eventReconnectBackoff.markHealthy();
      });
      // Only 30 s of stable connection resets the backoff, never one read.
      await _refreshRemoteActivityIfVisible();
    } catch (_) {
      _eventStableTimer?.cancel();
      _eventStableTimer = null;
      _globalActivity?.beginRecovery(
        widget.connection.id,
        Session.profileOwner(_libraryQuery.profile),
      );
      _recoveringTransport = true;
      _scheduleEventReconnect();
    }
  }

  void _scheduleEventReconnect({bool immediate = false}) {
    if (!mounted || !_foreground || _eventReconnectTimer != null) return;
    if (_ownedActivityClient == null && widget.eventReconnectOverride == null) {
      return;
    }
    final delay = immediate
        ? Duration.zero
        : _eventReconnectBackoff.nextDelay();
    _eventReconnectTimer = Timer(delay, () {
      _eventReconnectTimer = null;
      if (mounted && _foreground) unawaited(_connectEventClient());
    });
  }

  void _scheduleStaleExpiry() {
    _staleExpiryTimer?.cancel();
    _staleExpiryTimer = Timer(GlobalActivityAggregate.staleLivenessCeiling, () {
      _staleExpiryTimer = null;
      if (mounted) setState(() {});
    });
  }

  void _onSessionLibraryEvent(TuiGatewayEvent event) {
    final routed =
        _globalActivity?.observeGatewayEvent(
          connectionId: widget.connection.id,
          profile: Session.profileOwner(_libraryQuery.profile),
          event: event,
        ) ??
        true;
    if (event.sessionId.isNotEmpty && !routed && _foreground) {
      _requestEventActivityRefresh(event.sessionId);
    } else if (routed) {
      _recoveringTransport = false;
    }
    if (!isSessionLibraryRefreshEvent(event)) return;
    _sessionChangeEpoch += 1;
    if (!_foreground) return;
    if (!_listVisible) {
      _remoteActivityDirty = true;
      return;
    }
    final now = DateTime.now();
    final last = _lastEventRefreshAt;
    final elapsed = last == null
        ? sessionLibraryRefreshGap
        : now.difference(last);
    if (last == null || elapsed >= sessionLibraryRefreshGap) {
      _eventRefreshTimer?.cancel();
      _eventRefreshTimer = null;
      _lastEventRefreshAt = now;
      unawaited(_refreshFromSessionEvent());
      return;
    }
    _eventRefreshTimer ??= Timer(sessionLibraryRefreshGap - elapsed, () {
      _eventRefreshTimer = null;
      _lastEventRefreshAt = DateTime.now();
      if (!mounted || !_foreground) return;
      if (!_listVisible) {
        _remoteActivityDirty = true;
        return;
      }
      unawaited(_refreshFromSessionEvent());
    });
  }

  /// False while another route covers the list (a chat pushed over it keeps
  /// the list mounted). Without a route (tests, embedding) it counts visible.
  bool get _listVisible => _route?.isCurrent != false;

  /// A resume arrived while covered: the health probe runs on `didPopNext`.
  bool _healthCheckOwed = false;

  Future<void> _refreshRemoteActivityIfVisible() async {
    if (!_listVisible) {
      _remoteActivityDirty = true;
      return;
    }
    await _refreshRemoteActivity();
  }

  /// A busy row learnt from the roster only returns to rest on a later
  /// roster read: its turn's terminal goes to the socket of the chat that
  /// runs it, and after a force-stop there is none. While this list shows a
  /// live row it re-reads the roster [sessionLibraryActivityRefreshGap]
  /// after its last read; at rest, covered or in background it reads
  /// nothing.
  void _scheduleActivityPoll() {
    _activityPollTimer?.cancel();
    _activityPollTimer = null;
    if (!mounted || !_listHasLiveActivity) return;
    _activityPollTimer = Timer(sessionLibraryActivityRefreshGap, () {
      _activityPollTimer = null;
      // A coalesced event read is already due; it re-arms this poll.
      if (!mounted || !_foreground || _activityRefreshTimer != null) return;
      unawaited(_refreshRemoteActivityIfVisible());
    });
  }

  bool get _listHasLiveActivity {
    final aggregate = _globalActivity;
    if (aggregate == null) return false;
    final profile = Session.profileOwner(_libraryQuery.profile);
    return aggregate.activities.any(
      (activity) =>
          activity.scope.connectionId == widget.connection.id &&
          activity.scope.profile == profile &&
          aggregate.isActive(
            activity.scope.connectionId,
            activity.scope.profile,
            activity.scope.durableSessionId,
          ),
    );
  }

  /// An event of a runtime the aggregate does not route: coalesce to one
  /// roster read per [sessionLibraryActivityRefreshGap]. A covered list reads
  /// nothing and refreshes once when it is uncovered.
  void _requestEventActivityRefresh(String runtimeSessionId) {
    if (!_listVisible) {
      _remoteActivityDirty = true;
      _activityRefreshTimer?.cancel();
      _activityRefreshTimer = null;
      return;
    }
    if (_activityRefreshTimer != null) return;
    if (_discoveredRuntimes.length >= 64) _discoveredRuntimes.clear();
    if (_discoveredRuntimes.add(runtimeSessionId)) {
      unawaited(_refreshRemoteActivity());
      return;
    }
    final last = _lastActivityRefreshAt;
    final elapsed = last == null
        ? sessionLibraryActivityRefreshGap
        : DateTime.now().difference(last);
    if (elapsed >= sessionLibraryActivityRefreshGap) {
      unawaited(_refreshRemoteActivity());
      return;
    }
    _activityRefreshTimer = Timer(
      sessionLibraryActivityRefreshGap - elapsed,
      () {
        _activityRefreshTimer = null;
        if (!mounted || !_foreground) return;
        unawaited(_refreshRemoteActivityIfVisible());
      },
    );
  }

  Future<bool> _refreshRemoteActivity() async {
    final aggregate = _globalActivity;
    final loader =
        widget.activeSessionListLoader ??
        (_ownedActivityClient == null
            ? null
            : () => GatewaySocketMeter.origin(
                'list.activity',
                () => _ownedActivityClient!.listActiveSessions(),
              ));
    if (aggregate == null || loader == null) return false;
    _lastActivityRefreshAt = DateTime.now();
    final profile = Session.profileOwner(_libraryQuery.profile);
    final generation = aggregate.beginRosterRequest(
      widget.connection.id,
      profile,
    );
    try {
      final fullRoster = await loader();
      if (!mounted) return false;
      // The roster has no profile field: only rows this profile knows may
      // become activity (Desktop never builds rows from the roster).
      final roster = filterRosterToKnown(
        fullRoster,
        knownSessionIds(
          sessions: _sessions,
          pinnedIds: _archive?.pinnedIds ?? const [],
          roster: fullRoster,
          hasLocalChat: (id) =>
              _activeChats?.of(widget.connection.id, id, profile: profile) !=
              null,
        ),
      );
      _rosterRowsDeferred = roster.sessions.length < fullRoster.sessions.length;
      aggregate.applyRoster(
        connectionId: widget.connection.id,
        profile: profile,
        replayEpoch: _ownedActivityClient?.currentReplayEpoch ?? 'current',
        requestGeneration: generation,
        roster: roster,
      );
      _staleExpiryTimer?.cancel();
      _staleExpiryTimer = null;
      final client = _ownedActivityClient;
      final processLoader =
          widget.agentCenterSnapshotLoader ??
          (client == null
              ? null
              : (String runtimeSessionId) => GatewaySocketMeter.origin(
                  'list.agentCenter',
                  () => client.agentCenterSnapshot(
                    runtimeSessionId: runtimeSessionId,
                  ),
                ));
      // Solo una fila busy del roster prueba un turno vivo (igual que el
      // sidebar de Desktop). Una fila idle —turno terminado, sin lease— se
      // sigue consultando, pero solo puede crear actividad si process.list
      // prueba procesos en segundo plano vivos (el «punto hueco» de Desktop,
      // `$backgroundRunningSessionIds`); nunca resucita como «trabajando».
      if (processLoader != null && !roster.hasMalformedRows) {
        for (final row in roster.sessions) {
          final durable = row.storedSessionId;
          if (durable == null) continue;
          // Only a busy row or one with live processes already known can
          // change; probing every idle row was most of the list's traffic.
          if (!rosterStatusIsBusy(row.status) &&
              !_rowsWithLiveProcesses.contains(durable) &&
              !aggregate.isActive(widget.connection.id, profile, durable)) {
            continue;
          }
          unawaited(
            _refreshProcessContinuity(
              aggregate: aggregate,
              loadSnapshot: processLoader,
              rosterStatus: row.status,
              scope: GlobalActivityScope(
                connectionId: widget.connection.id,
                profile: profile,
                durableSessionId: durable,
                runtimeSessionId: row.runtimeSessionId,
                replayEpoch: client?.currentReplayEpoch ?? 'current',
              ),
            ),
          );
        }
      } else if (_recoveringTransport && !roster.hasMalformedRows) {
        for (final row in roster.sessions) {
          final durable = row.storedSessionId;
          if (durable == null || !rosterStatusIsBusy(row.status)) continue;
          aggregate.applyRecoverySnapshot(
            scope: GlobalActivityScope(
              connectionId: widget.connection.id,
              profile: profile,
              durableSessionId: durable,
              runtimeSessionId: row.runtimeSessionId,
              replayEpoch: 'current',
            ),
            running: true,
            waitingForUser: row.status?.trim().toLowerCase() == 'waiting',
            replayTruncated: true,
            processCount: 0,
            rosterStatus: row.status,
          );
        }
      }
      return true;
    } catch (_) {
      aggregate.markTransportStale(widget.connection.id, profile);
      _scheduleStaleExpiry();
      return false;
    } finally {
      _scheduleActivityPoll();
    }
  }

  Future<void> _refreshProcessContinuity({
    required GlobalActivityAggregate aggregate,
    required Future<AgentCenterSnapshot> Function(String runtimeSessionId)
    loadSnapshot,
    required String? rosterStatus,
    required GlobalActivityScope scope,
  }) async {
    final rosterBusy = rosterStatusIsBusy(rosterStatus);
    try {
      final snapshot = await loadSnapshot(scope.runtimeSessionId);
      if (!mounted || !snapshot.processesFullyParsed) {
        // Una fila idle no tenía nada que conservar: no se marca stale.
        if (!rosterBusy) return;
        aggregate.markTransportStale(scope.connectionId, scope.profile);
        return;
      }
      const terminal = <AgentCenterStatus>{
        AgentCenterStatus.completed,
        AgentCenterStatus.failed,
        AgentCenterStatus.cancelled,
        AgentCenterStatus.stopped,
      };
      final activeProcessCount = snapshot.processes
          .where((process) => !terminal.contains(process.status))
          .length;
      if (activeProcessCount > 0) {
        _rowsWithLiveProcesses.add(scope.durableSessionId);
      } else {
        _rowsWithLiveProcesses.remove(scope.durableSessionId);
      }
      if (!rosterBusy) {
        // Turno terminado: solo los procesos vivos justifican el indicador
        // (fase backgroundWork, nunca «trabajando»). process.list es la
        // autoridad, así que crea/renueva la fila aunque no haya recuperación.
        if (activeProcessCount <= 0) return;
        aggregate.applyRecoverySnapshot(
          scope: scope,
          running: true,
          waitingForUser: false,
          replayTruncated: false,
          processCount: activeProcessCount,
        );
        return;
      }
      if (_recoveringTransport) {
        final current = aggregate.activityFor(
          scope.connectionId,
          scope.profile,
          scope.durableSessionId,
        );
        aggregate.applyRecoverySnapshot(
          scope: scope,
          running: true,
          waitingForUser: current?.requiresAction == true,
          replayTruncated: true,
          processCount: activeProcessCount,
          rosterStatus: rosterStatus,
        );
      } else {
        aggregate.applyProcessList(
          scope: scope,
          activeProcessCount: activeProcessCount,
        );
      }
    } catch (_) {
      // Optional/legacy process.list cannot erase the last proven state.
      if (!rosterBusy) return;
      aggregate.markTransportStale(scope.connectionId, scope.profile);
    }
  }

  void _onHistoryCleanupInvalidation(HistoryCleanupInvalidation event) {
    if (!mounted ||
        !_foreground ||
        event.connectionId != widget.connection.id) {
      return;
    }
    unawaited(_fetchSessions(showLoader: false));
  }

  Future<void> _refreshFromSessionEvent() async {
    if (mounted &&
        _foreground &&
        _appliedSessionChangeEpoch < _sessionChangeEpoch) {
      await _fetchSessions(showLoader: false);
      await _refreshRemoteActivityIfVisible();
    }
  }

  Future<void> _refreshSessionsAndActivity() async {
    // No loader swap: it would unmount the RefreshIndicator mid-gesture and
    // replace the rows with the skeleton (an empty list still shows it).
    await _fetchSessions(showLoader: false);
    await _refreshRemoteActivity();
  }

  // ── Data fetching ────────────────────────────────────────────────────────

  SessionLibraryQuery get _libraryQuery =>
      _libraryQueryFor(_profileScope.name, pageSize: 50);

  /// The list's query (category, archived view, order) for [profile]: the
  /// list reads the active profile with it, the agent rail the first page
  /// of the others.
  SessionLibraryQuery _libraryQueryFor(
    String? profile, {
    required int pageSize,
  }) => SessionLibraryQuery(
    pageSize: pageSize,
    archived: _showArchived
        ? SessionArchiveMode.only
        : SessionArchiveMode.exclude,
    order: SessionLibraryOrder.recent,
    sources: _activeCategory.sources,
    excludeSources: _activeCategory.excludeSources,
    profile: profile,
  );

  void _openScheduledJobs() {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => CronScreen(
            connection: widget.connection,
            connManager: widget.connManager,
          ),
        ),
      ),
    );
  }

  void _selectCategory(SessionCategory value) {
    if (value == _activeCategory) return;
    setState(() => _activeCategory = value);
    _refreshLibraryScope();
  }

  void _toggleArchived() {
    setState(() => _showArchived = !_showArchived);
    _refreshLibraryScope();
  }

  void _refreshLibraryScope() {
    _searchTimer?.cancel();
    final query = _searchQuery.trim();
    final requestEpoch = ++_searchRequestEpoch;
    final scope = _libraryQuery;
    setState(() {
      _searchResults = null;
      _searching = query.isNotEmpty && _searchesServer;
      _searchExhaustive = query.isEmpty || !_searchesServer;
    });
    // Categoría y archivo se resuelven en Agent antes de limit/offset. La
    // búsqueda se reinicia con el mismo scope para invalidar respuestas de la
    // categoría anterior aunque el texto no haya cambiado.
    unawaited(_fetchSessions());
    if (query.isNotEmpty && _searchesServer) {
      unawaited(_runSearch(query, requestEpoch, scope));
    }
  }

  void _onLibraryScroll() {
    if (!_libraryScrollController.hasClients ||
        _libraryScrollController.position.extentAfter > 600 ||
        _searchQuery.trim().isNotEmpty ||
        _loadingMore ||
        _librarySource != SessionLibrarySource.dashboard ||
        _libraryExhaustive) {
      return;
    }
    unawaited(_loadNextPage());
  }

  Future<void> _loadNextPage() => _underListRead(_loadNextPageRead);

  Future<void> _loadNextPageRead(SessionListRead listRead) async {
    final repository = _repository;
    if (repository == null ||
        _loadingMore ||
        _librarySource != SessionLibrarySource.dashboard ||
        _libraryExhaustive) {
      return;
    }
    setState(() => _loadingMore = true);
    final scope = _libraryQuery;
    final pinReadFence = _pinSync?.beginRemoteRead();
    try {
      final snapshot = await repository.loadNext();
      final merged = mergeRemoteSessionsWithDrafts(
        snapshot.sessions,
        await _draftSessions(profile: scope.profile) ?? const [],
      );
      if (scope.fingerprint != _libraryQuery.fingerprint) return;
      await _migrateLineagePreferences(merged);
      await _pinSync?.updateSessions(merged, readFence: pinReadFence);
      if (!mounted) return;
      final sorted = _withoutDeleted(merged)
        ..sort(compareSessionsByRecentActivity);
      setState(() {
        _sessions = sorted;
        _librarySource = snapshot.source;
        _libraryExhaustive = snapshot.exhaustive;
      });
      _replayDeferredRoster();
      listRead.end(rows: snapshot.sessions);
    } catch (_) {
      // Mantén la página visible y permite reintentar al volver a hacer scroll.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _migrateLineagePreferences(Iterable<Session> sessions) async {
    final archive = _archive;
    if (archive == null) return;
    final physicalByRoot = <String, Set<String>>{};
    for (final session in sessions) {
      physicalByRoot.putIfAbsent(session.logicalId, () => {}).add(session.id);
    }
    for (final session in sessions) {
      if (session.lineageRootId == null) continue;
      await archive.migrateLogicalIdentity(
        session,
        knownPhysicalIds: physicalByRoot[session.logicalId] ?? const {},
      );
    }
  }

  ActiveChat? _localChatForSession(Session session) {
    final activeChats = _activeChats;
    if (activeChats == null) return null;
    for (final id in <String>{
      session.id,
      session.logicalId,
      ?session.parentSessionId,
    }) {
      final chat = activeChats.of(
        widget.connection.id,
        id,
        profile: session.profile,
      );
      if (chat != null) return chat;
    }
    return null;
  }

  bool _isLocalActive(Session session) =>
      _localChatForSession(session)?.sessionActivity.active == true;

  /// ss1215: the one status this row shows — the attached chat's own state
  /// when it has proof, the roster otherwise (see
  /// [resolveSessionLiveStatus]); the same value the chat pill and Inicio
  /// read.
  SessionLiveStatus _liveStatusFor(Session session) {
    final chat = _localChatForSession(session);
    final profile = Session.profileOwner(session.profile);
    final aggregate = _globalActivity;
    final globalActive =
        aggregate != null &&
        (aggregate.isActive(widget.connection.id, profile, session.id) ||
            aggregate.isActive(
              widget.connection.id,
              profile,
              session.logicalId,
            ));
    return resolveSessionLiveStatus(
      chat: chat?.liveStatus,
      chatAuthoritative:
          chat != null &&
          (chat.hasDesktopRuntime || chat.lastTerminalAt != null),
      chatSettledAt: chat?.lastTerminalAt,
      global: globalActive ? _globalForSession(session) : null,
    );
  }

  GlobalActivity? _globalForSession(Session session) {
    final aggregate = _globalActivity;
    if (aggregate == null) return null;
    final profile = Session.profileOwner(session.profile);
    return aggregate.activityFor(widget.connection.id, profile, session.id) ??
        aggregate.activityFor(widget.connection.id, profile, session.logicalId);
  }

  Set<String> get _sessionKeepIds {
    final keep = <String>{...?_archive?.pinnedIds};
    for (final session in _sessions) {
      if (_isLocalActive(session)) {
        keep.add(session.id);
        keep.add(session.logicalId);
      }
    }
    return keep;
  }

  /// Archive > Hidden filters its own list locally: no server search runs
  /// there (its hits would also be applied as list reads).
  bool get _searchesServer => _repository != null && !_hiddenView;

  void _onSearchChanged(String value) {
    _searchTimer?.cancel();
    final query = value.trim();
    final requestEpoch = ++_searchRequestEpoch;
    setState(() {
      _searchQuery = value;
      _searchResults = null;
      _searching = query.isNotEmpty && _searchesServer;
      _searchExhaustive = query.isEmpty || !_searchesServer;
    });
    if (query.isEmpty || !_searchesServer) return;
    _searchTimer = Timer(const Duration(milliseconds: 220), () {
      unawaited(_runSearch(query, requestEpoch, _libraryQuery));
    });
  }

  Future<void> _runSearch(
    String query,
    int requestEpoch,
    SessionLibraryQuery scope,
  ) => _underListRead(
    (listRead) => _runSearchRead(listRead, query, requestEpoch, scope),
  );

  Future<void> _runSearchRead(
    SessionListRead listRead,
    String query,
    int requestEpoch,
    SessionLibraryQuery scope,
  ) async {
    final repository = _repository;
    if (repository == null) return;
    try {
      final result = await repository.search(query, libraryQuery: scope);
      if (!mounted ||
          requestEpoch != _searchRequestEpoch ||
          query != _searchQuery.trim() ||
          scope.fingerprint != _libraryQuery.fingerprint) {
        return;
      }
      final needle = query.toLowerCase();
      final matchingDrafts =
          (await _draftSessions(profile: scope.profile) ?? const <Session>[])
              .where(
                (session) =>
                    _titleFor(session).toLowerCase().contains(needle) ||
                    session.preview.toLowerCase().contains(needle),
              );
      final sessions = mergeRemoteSessionsWithDrafts(
        result.sessions,
        matchingDrafts,
      );
      await _migrateLineagePreferences(sessions);
      if (!mounted || requestEpoch != _searchRequestEpoch) return;
      final withLoaded = appendLoadedSearchMatches(
        sessions,
        _sessions.where(
          (session) => sessionMatchesSearchText(
            session,
            needle,
            title: _titleFor(session),
          ),
        ),
      );
      setState(() {
        _searchResults = _withoutDeleted(withLoaded);
        _searchExhaustive = result.exhaustive;
        _searching = false;
      });
      listRead.end(rows: result.sessions);
    } catch (_) {
      if (!mounted ||
          requestEpoch != _searchRequestEpoch ||
          query != _searchQuery.trim() ||
          scope.fingerprint != _libraryQuery.fingerprint) {
        return;
      }
      final needle = query.toLowerCase();
      setState(() {
        _searchResults = _sessions
            .where(
              (session) =>
                  _titleFor(session).toLowerCase().contains(needle) ||
                  session.preview.toLowerCase().contains(needle),
            )
            .toList(growable: false);
        _searchExhaustive = false;
        _searching = false;
      });
    }
  }

  /// The shared store this screen filters with; loaded on demand so a read
  /// started before [_loadPrefs] finishes is still registered.
  Future<SessionArchive> _sharedArchive() async =>
      _archive ??
      (_listArchive ??= await SessionArchive.load(
        await SharedPreferences.getInstance(),
        widget.connection.id,
      ));
  SessionArchive? _listArchive;

  /// Runs [read] as a session list read of the shared store (see
  /// [SessionArchive.beginListRead]): a deletion recorded meanwhile keeps
  /// its tombstone until this result has been stored or dropped. [read]
  /// ends it with the server rows once they are stored.
  Future<T> _underListRead<T>(
    Future<T> Function(SessionListRead listRead) read,
  ) async {
    final listRead = (await _sharedArchive()).beginListRead();
    try {
      return await read(listRead);
    } finally {
      listRead.end();
    }
  }

  /// Rows the server confirmed deleted never enter what this screen keeps.
  List<Session> _withoutDeleted(Iterable<Session> rows) {
    final archive = _archive ?? _listArchive;
    return archive == null
        ? rows.toList()
        : rows.where((row) => !archive.isSessionDeleted(row)).toList();
  }

  /// First frame: the list the last run left on disk. Nothing private is
  /// painted while App Lock is locked, and a list read that already landed
  /// (or a view other than the default one) is never overwritten.
  void _paintColdStartList() {
    if (_coldListChecked) return;
    final store = _activeChats?.coldStartStore;
    if (store == null) return;
    _coldListChecked = true;
    if (_activeCategory != SessionCategory.chats || _showArchived) return;
    if (context
            .findAncestorStateOfType<HermesAppState>()
            ?.appLock
            .locked
            .value ==
        true) {
      return;
    }
    final owner = Session.profileOwner(_profileScope.name);
    final cached = store.peekList(
      connectionId: widget.connection.id,
      profile: owner,
    );
    if (cached != null) {
      _applyColdStartList(cached, owner);
    } else {
      unawaited(_loadColdStartList(store, owner));
    }
  }

  Future<void> _loadColdStartList(ColdStartStore store, String owner) async {
    final ticket = AppLockSensitiveReadFence.capture(widget.connManager.prefs);
    try {
      final cached = await store.loadList(
        connectionId: widget.connection.id,
        profile: owner,
      );
      if (cached == null || !mounted || !ticket.isCurrent) return;
      _applyColdStartList(cached, owner);
    } catch (error) {
      debugPrint('[session-list] cold-start list (${error.runtimeType})');
    }
  }

  void _applyColdStartList(List<Session> cached, String owner) {
    // Only before the first list of this run: a server read, a draft merge
    // or another view already own the rows.
    if (!mounted ||
        !_loading ||
        _sessions.isNotEmpty ||
        _activeCategory != SessionCategory.chats ||
        _showArchived ||
        Session.profileOwner(_profileScope.name) != owner) {
      return;
    }
    final rows = _withoutDeleted(
      cached.where((s) => s.listsAsOwnRow && s.source != 'mobile-draft'),
    )..sort(compareSessionsByRecentActivity);
    if (rows.isEmpty) return;
    setState(() {
      _sessions = rows;
      _showingColdList = true;
      _coldListOwner = owner;
      _loading = false;
    });
  }

  /// Saves what the server just listed (default view only) for the next
  /// cold start. Local drafts are not the server's and never leave the
  /// device's own draft store.
  void _saveColdStartList(List<Session> listed, String owner) {
    final store = _activeChats?.coldStartStore;
    if (store == null ||
        _activeCategory != SessionCategory.chats ||
        _showArchived) {
      return;
    }
    unawaited(
      store
          .saveList(
            connectionId: widget.connection.id,
            profile: owner,
            sessions: [
              for (final s in listed)
                if (s.source != 'mobile-draft') s,
            ],
          )
          .catchError((Object error) {
            debugPrint('[session-list] list not saved (${error.runtimeType})');
          }),
    );
  }

  /// The painted cold list stops standing in for the list as soon as the
  /// view it belongs to changes.
  bool get _coldListStands =>
      _showingColdList &&
      _activeCategory == SessionCategory.chats &&
      !_showArchived &&
      Session.profileOwner(_profileScope.name) == _coldListOwner;

  Future<bool> _fetchSessions({bool showLoader = true}) => _underListRead(
    (listRead) => _fetchSessionsRead(listRead, showLoader: showLoader),
  );

  Future<bool> _fetchSessionsRead(
    SessionListRead listRead, {
    bool showLoader = true,
  }) async {
    // Puede invocarse desde un closure del drawer después de que la pantalla se
    // haya desmontado (HermesDrawer._go) → setState() after dispose(). Guard.
    if (!mounted) return false;
    final fetchEpoch = ++_sessionFetchEpoch;
    final invalidationEpoch = _appliedSessionChangeEpoch < _sessionChangeEpoch
        ? _sessionChangeEpoch
        : null;
    final previousSessions = List<Session>.of(_sessions);
    // A cold list on screen is not hidden behind the loader: the read
    // replaces it when it lands.
    if (!_coldListStands) _showingColdList = false;
    if ((showLoader && !_showingColdList) || _sessions.isEmpty) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final pinReadFence = _pinSync?.beginRemoteRead();
    final scope = _libraryQuery;
    try {
      final repository = _repository;
      final SessionLibrarySnapshot? library = repository == null
          ? null
          : await repository.refresh(scope, keepIds: _sessionKeepIds);
      final rawRemoteSessions =
          library?.sessions ??
          await _client.getSessions(profile: scope.profile);
      final requestedOwner = Session.profileOwner(scope.profile);
      final remoteSessions = library != null
          ? rawRemoteSessions
          : rawRemoteSessions
                .where((session) {
                  final published = session.profile?.trim();
                  if (published == null || published.isEmpty) {
                    return requestedOwner == 'default';
                  }
                  return published == requestedOwner;
                })
                .map(
                  (session) => session.profile?.trim().isNotEmpty == true
                      ? session
                      : session.copyWith(profile: 'default'),
                );
      final sessions = mergeRemoteSessionsWithDrafts(
        remoteSessions,
        await _draftSessions(profile: scope.profile) ?? const [],
      );
      if (scope.fingerprint != _libraryQuery.fingerprint ||
          fetchEpoch != _sessionFetchEpoch) {
        return false;
      }
      await _migrateLineagePreferences(sessions);
      await _pinSync?.updateSessions(sessions, readFence: pinReadFence);

      // Real branches are their own rows, as in the Desktop sidebar; delegate
      // runs and automation children that a legacy or intermediary server
      // still returns stay folded (the same rule as Home and the drawer).
      final visible = sessions.where((s) => s.listsAsOwnRow);

      final sorted = _withoutDeleted(visible)
        ..sort(compareSessionsByRecentActivity);

      if (!mounted || fetchEpoch != _sessionFetchEpoch) return false;
      if (!_showArchived && _activeCategory == SessionCategory.chats) {
        // The Chats launcher widget shows this same list (no request of
        // its own).
        unawaited(
          LauncherWidgetChatsPublisher.instance.offer(
            strings: Strings.of(context),
            connectionId: widget.connection.id,
            sessions: sorted,
          ),
        );
      }
      setState(() {
        _sessions = sorted;
        _librarySource = library?.source ?? SessionLibrarySource.gateway;
        _libraryExhaustive = library?.exhaustive ?? false;
        _loading = false;
        _showingColdList = false;
      });
      _saveColdStartList(sorted, requestedOwner);
      _replayDeferredRoster();
      // Every page of the gateway's default listing for this profile: what
      // a deletion tombstone may be confirmed against. A Dashboard page or
      // filtered scope is not complete and only reports the rows it saw.
      final complete = library == null
          ? remoteSessions
          : library.completeGatewayListing;
      listRead.end(
        rows: complete ?? remoteSessions,
        completeProfile: complete == null ? null : requestedOwner,
      );
      if (invalidationEpoch != null) {
        final activeChats = _activeChats;
        if (activeChats != null) {
          for (final session in changedDurableSessions(
            previousSessions,
            sorted,
          )) {
            unawaited(
              activeChats.invalidateDurableSession(
                connectionId: widget.connection.id,
                profile: Session.profileOwner(
                  session.profile,
                  fallback: scope.profile,
                ),
                sessionId: session.id,
                logicalSessionId: session.logicalId,
              ),
            );
          }
        }
        if (invalidationEpoch > _appliedSessionChangeEpoch) {
          _appliedSessionChangeEpoch = invalidationEpoch;
        }
      }
      return true;
    } catch (e) {
      if (!mounted || fetchEpoch != _sessionFetchEpoch) return false;
      if (_sessions.isEmpty) {
        setState(() {
          _error = e;
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
      await _showLocalDrafts();
      return false;
    }
  }

  /// The Dashboard refused the saved login (an expired browser session
  /// included), as opposed to any other way the list can fail.
  static bool _isLoginRefusal(Object error) => switch (error) {
    CoreReadException(:final kind) =>
      kind == CoreReadErrorKind.auth || kind == CoreReadErrorKind.forbidden,
    DashboardAuthException(:final code) =>
      code == DashboardAuthFailureCode.loginRequired,
    DashboardHttpException(:final statusCode) =>
      statusCode == 401 || statusCode == 403,
    _ => false,
  };

  Future<void> _signIn() async {
    final signedIn = await signInToDashboard(
      Navigator.of(context),
      widget.connManager,
      widget.connection,
    );
    if (signedIn && mounted) unawaited(_fetchSessions());
  }

  // ── Archive helpers ──────────────────────────────────────────────────────

  bool _isArchived(Session session) =>
      _pendingArchiveByLogicalId[session.logicalId] ??
      _archive?.isSessionArchived(session) ??
      session.archived;
  bool _isPinned(Session session) =>
      _archive?.isSessionPinned(session) ?? false;
  bool _isHidden(Session session) =>
      _archive?.isSessionHidden(session) ?? false;
  String _titleFor(Session session) =>
      _archive?.titleForSession(session, strings: Strings.of(context)) ??
      localizedSessionTitle(Strings.of(context), session);

  void _replaceSessionArchived(Session session, bool archived) {
    _sessions = [
      for (final row in _sessions)
        if (row.id == session.id) row.copyWith(archived: archived) else row,
    ];
    final searchResults = _searchResults;
    if (searchResults != null) {
      _searchResults = [
        for (final row in searchResults)
          if (row.id == session.id) row.copyWith(archived: archived) else row,
      ];
    }
  }

  Future<void> _setLocalArchived(Session session, bool archived) async {
    if (archived) {
      await _archive!.archiveSession(session);
    } else {
      await _archive!.unarchiveSession(session);
    }
  }

  void _showArchiveResult(bool archived, {required bool localOnly}) {
    final strings = Strings.of(context);
    AppFeedback.notify(
      context,
      localOnly ? FeedbackKind.error : FeedbackKind.routine,
      localOnly
          ? (archived
                ? strings.slArchivedLocalOnly
                : strings.slRestoredLocalOnly)
          : (archived ? strings.slArchived : strings.slRestored),
      warning: true,
    );
  }

  Future<void> _showRenameSessionDialog(Session session) async {
    if (_archive == null) return;
    final newTitle = await showSessionTitleEditorRoute(
      context,
      initialTitle: _titleFor(session),
    );

    final trimmed = newTitle?.trim();
    if (trimmed == null) return;
    if (trimmed.isEmpty) {
      if (!mounted) return;
      AppFeedback.of(context).notify(
        FeedbackKind.error,
        Strings.of(context).slRenameEmpty,
        warning: true,
      );
      return;
    }

    try {
      await _archive!.renameSession(session, trimmed);
    } catch (_) {
      if (!mounted) return;
      AppFeedback.of(
        context,
      ).notify(FeedbackKind.error, Strings.of(context).slRenameFailed);
      return;
    }
    if (!mounted) return;
    setState(() {});
    AppFeedback.of(
      context,
    ).notify(FeedbackKind.routine, Strings.of(context).slRenamed);
  }

  Future<void> _toggleArchive(Session session) async {
    if (_archive == null) return;
    final wasArchived = _isArchived(session);
    final archived = !wasArchived;
    final repository = _repository;

    // En servidores legacy (o cuando la biblioteca ya tuvo que caer al
    // Gateway) el archivo sigue siendo una preferencia local explícita.
    if (repository == null ||
        _librarySource != SessionLibrarySource.dashboard) {
      await _setLocalArchived(session, archived);
      if (!mounted) return;
      setState(() {});
      _showArchiveResult(archived, localOnly: true);
      return;
    }

    setState(() {
      _pendingArchiveByLogicalId[session.logicalId] = archived;
      _listRevision++;
    });
    try {
      await repository.setArchived(
        session,
        archived,
        profile: widget.connManager.activeProfileFor(widget.connection.id),
      );
      // El servidor pasa a ser autoritativo. Retiramos cualquier bandera local
      // legacy para que un desarchivo remoto no quede tapado por ella.
      await _archive!.unarchiveSession(session);
      if (archived) await _archive!.unpinSession(session);
      if (!mounted) return;
      setState(() {
        _replaceSessionArchived(session, archived);
        _pendingArchiveByLogicalId.remove(session.logicalId);
        _listRevision++;
      });
      _showArchiveResult(archived, localOnly: false);
    } on DashboardHttpException catch (error) {
      final unsupported = error.statusCode == 404 || error.statusCode == 405;
      if (unsupported && (archived || !session.archived)) {
        await _setLocalArchived(session, archived);
        if (!mounted) return;
        setState(() {
          _pendingArchiveByLogicalId.remove(session.logicalId);
          _listRevision++;
        });
        _showArchiveResult(archived, localOnly: true);
        return;
      }
      await _rollbackArchiveChange(session);
    } catch (_) {
      // Un timeout es ambiguo: nunca afirmamos éxito. Quitamos el optimismo y
      // refrescamos para observar el valor realmente persistido en el servidor.
      await _rollbackArchiveChange(session);
    }
  }

  Future<void> _rollbackArchiveChange(Session session) async {
    if (!mounted) return;
    setState(() {
      _pendingArchiveByLogicalId.remove(session.logicalId);
      _listRevision++;
    });
    await _fetchSessions(showLoader: false);
    if (!mounted) return;
    AppFeedback.of(
      context,
    ).notify(FeedbackKind.error, Strings.of(context).slArchiveSyncFailed);
  }

  Future<void> _togglePin(Session session) async {
    if (_archive == null) return;
    final wasPinned = _isPinned(session);
    final sync = _pinSync;
    if (sync != null) {
      await sync.setLocalPinned(session, !wasPinned);
    } else if (wasPinned) {
      await _archive!.unpinSession(session);
    } else {
      await _archive!.pinSession(session);
    }
    if (mounted) setState(() {});
  }

  Future<void> _toggleUnread(Session session) async {
    final archive = _archive;
    if (archive == null) return;
    try {
      await archive.setSessionUnread(
        session,
        !archive.isSessionUnread(session),
      );
    } catch (_) {
      if (!mounted) return;
      AppFeedback.of(
        context,
      ).notify(FeedbackKind.error, Strings.of(context).slUnreadFailed);
    }
  }

  void _selectArchiveView(bool hidden) {
    if (hidden == _showHiddenInArchive) return;
    setState(() => _showHiddenInArchive = hidden);
    // Entering Hidden drops a pending search; leaving it searches the text.
    _onSearchChanged(_searchQuery);
  }

  /// Archive > Hidden: the chats hidden from this device, filtered by the
  /// search text.
  List<Session> _hiddenSessionsView() {
    final archive = _archive;
    if (archive == null) return const [];
    final query = _searchQuery.trim().toLowerCase();
    return [
      for (final session in archive.hiddenSessions)
        if (!archive.isSessionDeleted(session) &&
            (query.isEmpty ||
                _titleFor(session).toLowerCase().contains(query) ||
                session.preview.toLowerCase().contains(query)))
          session,
    ];
  }

  Future<void> _toggleHidden(Session session) async {
    if (_archive == null) return;
    if (_isHidden(session)) {
      await _archive!.unhideSession(session);
    } else {
      await _archive!.hideSession(session);
    }
    if (mounted) setState(() {});
  }

  // ── Delete helpers ───────────────────────────────────────────────────────

  Future<LinkedSessionDeleteResult> _deleteSessionAndLinkedCron(
    Session session,
    LinkedCronDeletionMode cronDeletion,
  ) {
    final ownerProfile = Session.profileOwner(session.profile);
    return deleteSessionWithResolvedLineage(
      session,
      deleteSession: (sessionId) =>
          _client.deleteSession(sessionId, profile: ownerProfile),
      cronDeletion: cronDeletion,
      deleteCronJob:
          !session.isJob || cronDeletion == LinkedCronDeletionMode.keepSchedule
          ? null
          : (jobId) => widget.connManager.deleteLinkedCronJob(
              widget.connection,
              jobId,
              profile: ownerProfile,
            ),
    );
  }

  Future<bool> _confirmAndDeleteSession(Session session) async {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return false;
    }
    var cronDeletion = LinkedCronDeletionMode.keepSchedule;
    if (session.isJob) {
      final choice = await showCronConversationDeleteDialog(context, session);
      if (choice == null) return false;
      cronDeletion = choice;
    } else {
      final confirm = await showHermesDialog<bool>(
        context: context,
        title: Strings.of(context).slDeleteTitle,
        message: Strings.of(context).slDeleteContent(_titleFor(session)),
        actions: [
          HermesDialogAction(
            label: Strings.of(context).slCancel,
            value: false,
            style: HermesDialogActionStyle.cancel,
          ),
          HermesDialogAction(
            label: Strings.of(context).slDeleteConfirm,
            value: true,
            style: HermesDialogActionStyle.destructive,
          ),
        ],
      );
      if (confirm != true) return false;
    }

    final result = await _deleteSessionAndLinkedCron(session, cronDeletion);
    switch (result.status) {
      case LinkedSessionDeleteStatus.deleted:
        // Shared store first: Home, drawer and detail drop it in this frame.
        unawaited(_archive?.markSessionDeleted(session));
        _globalActivity?.clearSession(
          widget.connection.id,
          Session.profileOwner(session.profile),
          session.id,
        );
        await _globalActivity?.flushJournal();
        try {
          await _activeChats?.clearCancelledTurnsForSession(
            connectionId: widget.connection.id,
            profile: session.profile ?? '',
            sessionId: session.id,
          );
        } catch (error) {
          debugPrint(
            '[session-list] cancelled-turn cleanup queued: '
            '${error.runtimeType}',
          );
        }
        _evictDeletedSessions([session]);
        // Sin esto, Inicio (que ya escucha este mismo bus para refrescarse
        // solo — ver `home_dashboard_screen.dart`) no se enteraba de que una
        // conversación borrada aquí debía desaparecer también de sus
        // recientes hasta que algo más forzara un refresco manual (reportado
        // en dispositivo real: "las conversaciones se borran de
        // Conversaciones pero no de Inicio").
        historyCleanupInvalidations.publish(
          connectionId: widget.connection.id,
          scope: HistoryCleanupScope.normalConversations,
        );
        return true;
      case LinkedSessionDeleteStatus.cancelled:
        return false;
      case LinkedSessionDeleteStatus.sessionRejected:
        if (mounted) {
          _offerHideAfterFailedDelete(
            session,
            message: result.cronDeleted
                ? Strings.of(context).cronStoppedChatKept
                : null,
          );
        }
        return false;
      case LinkedSessionDeleteStatus.cronDeleteFailed:
        if (mounted) {
          AppFeedback.of(context).notify(
            FeedbackKind.error,
            sessionDeletionFailureMessage(Strings.of(context), result),
          );
        }
        return false;
      case LinkedSessionDeleteStatus.sessionDeleteFailed:
        if (mounted) {
          AppFeedback.of(context).notify(
            FeedbackKind.error,
            sessionDeletionFailureMessage(Strings.of(context), result),
          );
        }
        return false;
    }
  }

  /// El servidor respondió OK pero no borró la sesión (suele ser una sesión de
  /// un canal activo que se recrea). Ofrece ocultarla localmente — honesto.
  void _offerHideAfterFailedDelete(Session session, {String? message}) {
    final messenger = AppFeedback.of(context);
    final s = Strings.of(context);
    messenger.notify(
      FeedbackKind.undo,
      message ?? s.slOfferHideContent,
      action: HermesNoticeAction(
        label: s.slHideAction,
        onPressed: () async {
          await _archive?.hideSession(session);
          if (mounted) setState(() {});
        },
      ),
      duration: const Duration(seconds: 5),
    );
  }

  // ── Navigation ───────────────────────────────────────────────────────────

  void _evictDeletedSessions(Iterable<Session> deleted) {
    final rows = deleted.toList(growable: false);
    if (rows.isEmpty) return;
    final aliases = <String>{
      for (final row in rows) row.id,
      for (final row in rows) row.logicalId,
    };
    _repository?.evictSessions(rows);
    ++_searchRequestEpoch;
    if (!mounted) return;
    setState(() {
      bool retained(Session row) =>
          !aliases.contains(row.id) && !aliases.contains(row.logicalId);
      _sessions = _sessions.where(retained).toList();
      _searchResults = _searchResults?.where(retained).toList();
      _searching = false;
    });
  }

  void _createNewSession() {
    final sessionId = generateSessionId();
    final session = Session(
      id: sessionId,
      title: Strings.of(context).drawerNewChat,
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 0,
      isActive: true,
      preview: '',
      startedAt: DateTime.now().millisecondsSinceEpoch.toDouble() / 1000,
    );
    _openChat(session);
  }

  Future<void> _stopSession(Session session) async {
    final activeChats = _activeChats;
    if (activeChats == null) {
      AppFeedback.of(
        context,
      ).notify(FeedbackKind.error, Strings.of(context).chaStopFailed);
      return;
    }
    try {
      final result = await activeChats.stopSessionWork(
        connection: widget.connection,
        session: session,
      );
      if (!result.allBackgroundWorkStopped && mounted) {
        AppFeedback.of(context).notify(
          FeedbackKind.critical,
          Strings.of(
            context,
          ).chaBackgroundWorkRemaining(result.remainingBackgroundTasks),
          warning: true,
        );
      }
    } catch (_) {
      if (!mounted) return;
      AppFeedback.of(
        context,
      ).notify(FeedbackKind.error, Strings.of(context).chaStopFailed);
    }
  }

  Future<void> _openChat(Session session) async {
    final ownedTarget = missionControlTargetForSession(session);
    if (ownedTarget != null) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute<void>(
          builder: (_) => MissionControlScreen(
            connection: widget.connection,
            connManager: widget.connManager,
            activeChats: _activeChats,
            initialOpenTarget: ownedTarget,
          ),
        ),
      );
      return;
    }
    final panes = _panes.currentState;
    if (panes != null && panes.active) {
      // The chat is the view in use (and the list over it goes).
      _views.chatOpened();
      await _openChatInPane(panes, session);
      return;
    }
    final deleted = await openChatFromSection<bool>(
      context,
      builder: (_) => _chatScreenFor(session),
    );
    if (deleted == true && mounted) {
      _evictDeletedSessions([session]);
    }
  }

  final GlobalKey<AdaptiveListDetailState> _panes =
      GlobalKey<AdaptiveListDetailState>(debugLabel: 'session-list-panes');

  /// The views of this screen on a tablet or an open Fold: the list, the
  /// open chat and its workspace (mock 134). The chat in the pane uses this
  /// same controller ([ChatWorkspaceScope]).
  late final ChatWorkspaceController _views = ChatWorkspaceController(
    prefs: widget.connManager.prefs,
    screen: ChatWorkspaceScreen.chats,
  );

  /// The conversation open in the tablet pane. One source of truth: the
  /// pane shows the same [ChatScreen] a phone would push, and that screen
  /// binds the session through `ActiveChatService.attach`, so a deep link or
  /// notification for the same session reuses the very same chat.
  Session? _paneSession;

  Future<void> _openChatInPane(
    AdaptiveListDetailState panes,
    Session session,
  ) async {
    if (_paneSession?.id == session.id && panes.hasDetail) return;
    // The list marks the conversation open beside it.
    setState(() => _paneSession = session);
    final deleted = await panes.show<bool>(
      MaterialPageRoute<bool>(
        settings: RouteSettings(name: 'session-pane:${session.id}'),
        builder: (_) => _chatScreenFor(session),
      ),
    );
    if (identical(_paneSession, session) && mounted) {
      setState(() => _paneSession = null);
    }
    if (deleted == true && mounted) _evictDeletedSessions([session]);
  }

  /// The window became phone-sized with a conversation open in the pane:
  /// continue it with the phone flow instead of dropping the user back on
  /// the list.
  void _reopenPaneChatFullScreen() {
    final session = _paneSession;
    _paneSession = null;
    if (session == null || !mounted) return;
    unawaited(_openChat(session));
  }

  Widget _chatScreenFor(Session session) =>
      widget.chatScreenBuilderOverride?.call(session) ??
      ChatScreen(connection: widget.connection, session: session);

  Future<void> _openDetail(Session session) async {
    final deleted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => SessionDetailScreen(
          connection: widget.connection,
          session: session,
          knownSessions: _sessions,
        ),
      ),
    );
    if (!mounted) return;
    if (deleted == true) {
      _evictDeletedSessions([session]);
    } else {
      // El detalle puede haber ramificado o reanudado: refrescar barato.
      unawaited(_fetchSessions(showLoader: false));
    }
  }

  /// The PR read behind the session menu: on demand, never on list build.
  Future<PullRequestInfo?> Function()? _pullRequestLoader(Session session) {
    final client = _ownedActivityClient;
    if (client == null || session.gitRepoRoot?.trim().isNotEmpty != true) {
      return null;
    }
    return () async {
      var service = _pullRequests;
      if (service == null) {
        final prefs = await SharedPreferences.getInstance();
        service = _pullRequests ??= PullRequestTagService(
          gateway: client,
          connectionId: widget.connection.id,
          prefs: prefs,
        );
      }
      return service.tagFor(session);
    };
  }

  void _openForeignImport() {
    final client = _ownedActivityClient;
    if (client == null) return;
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ForeignSessionImportScreen(
          gateway: client,
          profile: Session.profileOwner(_libraryQuery.profile),
          onOpenSession: _openImportedSession,
        ),
      ),
    );
  }

  /// One list refresh, then the imported (or already imported) session.
  Future<void> _openImportedSession(String sessionId) async {
    await _fetchSessions(showLoader: false);
    if (!mounted) return;
    final known = _sessions.where(
      (row) => row.id == sessionId || row.lineageIds.contains(sessionId),
    );
    final session = known.isNotEmpty
        ? known.first
        : Session(
            id: sessionId,
            title: '',
            model: '',
            source: 'mobile',
            messageCount: 0,
            isActive: false,
            preview: '',
            startedAt: 0,
            profile: _libraryQuery.profile,
          );
    await _openChat(session);
  }

  Future<void> _confirmForeignImport(TuiGatewayClient client) async {
    final offered = await client.confirmForeignSessions();
    if (offered && mounted && identical(client, _ownedActivityClient)) {
      setState(() {});
    }
  }

  bool get _branchesMayHaveMore =>
      _repository != null &&
      _librarySource == SessionLibrarySource.dashboard &&
      !_libraryExhaustive;

  Future<void> _openBranches(Session session) {
    final canLoadMore = _branchesMayHaveMore;
    return Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SessionBranchesScreen(
          sessions: _sessions,
          currentId: session.id,
          titleOf: _titleFor,
          onOpen: (row) {
            Navigator.pop(context);
            _openChat(row);
          },
          onLoadMore: canLoadMore
              ? () async {
                  await _loadNextPage();
                  return _sessions;
                }
              : null,
        ),
      ),
    );
  }

  // ── Context menu ─────────────────────────────────────────────────────────

  Future<void> _showSessionContextMenu(Session session) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final archived = _isArchived(session);
    final pinned = _isPinned(session);
    final hidden = _isHidden(session);
    final unread = _archive?.isSessionUnread(session) ?? false;
    return showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('session-actions-surface'),
      maxWidth: 480,
      maxHeightFactor: 0.82,
      builder: (ctx) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Encabezado: título de la sesión, para saber sobre qué se actúa.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _titleFor(session),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ),
            Divider(height: 1, color: colors.divider),
            // Fijar y archivar son las acciones de organización principales.
            ListTile(
              leading: Icon(
                pinned ? Icons.push_pin : Icons.push_pin_outlined,
                color: pinned ? colors.accent : null,
              ),
              title: Text(pinned ? s.slMenuUnpin : s.slMenuPin),
              onTap: () async {
                Navigator.pop(ctx);
                await _togglePin(session);
              },
            ),
            ListTile(
              leading: Icon(
                archived ? Icons.unarchive_outlined : Icons.archive_outlined,
              ),
              title: Text(archived ? s.slMenuUnarchive : s.slMenuArchive),
              onTap: () async {
                Navigator.pop(ctx);
                await _toggleArchive(session);
              },
            ),
            // Cambiar título es un alias LOCAL (no toca el servidor), por eso
            // está disponible incluso en modo solo lectura.
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(s.slMenuRename),
              onTap: () async {
                Navigator.pop(ctx);
                await _showRenameSessionDialog(session);
              },
            ),
            // Desktop's row toggle; only when the server keeps read state.
            if (_archive?.canToggleUnread(session) ?? false)
              ListTile(
                key: const ValueKey('session-menu-unread'),
                leading: Icon(
                  unread
                      ? Icons.mark_email_read_outlined
                      : Icons.mark_email_unread_outlined,
                ),
                title: Text(unread ? s.slMenuMarkRead : s.slMenuMarkUnread),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _toggleUnread(session);
                },
              ),
            if (_pullRequestLoader(session) case final load?)
              SessionPullRequestRow(
                key: ValueKey('session-menu-pr-${session.id}'),
                load: load,
                builder: (context, label, onTap) => ListTile(
                  leading: const Icon(Icons.merge_type_rounded),
                  title: Text(label),
                  onTap: () {
                    Navigator.pop(ctx);
                    onTap();
                  },
                ),
              ),
            if (SessionBranchesScreen.isAvailable(
              _sessions,
              session.id,
              mayHaveMore: _branchesMayHaveMore,
            ))
              ListTile(
                key: const ValueKey('session-menu-branches'),
                leading: const Icon(Icons.account_tree_outlined),
                title: Text(s.sesBranchesTitle),
                onTap: () {
                  Navigator.pop(ctx);
                  _openBranches(session);
                },
              ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(s.slMenuDetails),
              onTap: () {
                Navigator.pop(ctx);
                _openDetail(session);
              },
            ),
            // Re-homes the stored session's workspace; a write, and only when
            // the server answered the method.
            if (!widget.connection.readOnly &&
                !_moveUnsupported.contains(widget.connection.id))
              ListTile(
                key: const ValueKey('session-menu-move'),
                leading: const Icon(Icons.drive_file_move_outlined),
                title: Text(s.se1215MenuMove),
                onTap: () {
                  Navigator.pop(ctx);
                  unawaited(_moveToProject(session));
                },
              ),
            ListTile(
              key: const ValueKey('session-menu-export'),
              leading: const Icon(Icons.ios_share_outlined),
              title: Text(s.se1215MenuExport),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_exportSession(session));
              },
            ),
            ListTile(
              leading: Icon(
                hidden
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
              title: Text(
                hidden
                    ? s.slMenuShow
                    : (_archive?.hidesOnServer(session) ?? false)
                    ? s.slMenuHideSynced
                    : s.slMenuHide,
              ),
              subtitle: hidden
                  ? null
                  : Text(
                      s.sesClearViewNote,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).hermes.textTertiary,
                      ),
                    ),
              onTap: () async {
                Navigator.pop(ctx);
                await _toggleHidden(session);
              },
            ),
            if (!widget.connection.readOnly)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(s.slMenuDelete),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _confirmAndDeleteSession(session);
                },
              ),
            ListTile(
              leading: const Icon(Icons.content_copy_outlined),
              title: Text(s.slMenuCopyId),
              subtitle: Text(
                session.id,
                style: const TextStyle(fontSize: 11),
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                Clipboard.setData(ClipboardData(text: session.id));
                Navigator.pop(ctx);
                AppFeedback.of(
                  context,
                ).notify(FeedbackKind.routine, Strings.of(context).slIdCopied);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── Move to project ──────────────────────────────────────────────────────

  /// "Mover a proyecto": reads the project tree and moves the STORED session
  /// to the chosen folder over the shared socket. One lease for the whole
  /// flow, always released; nothing is retried.
  Future<void> _moveToProject(Session session) async {
    final feedback = AppFeedback.of(context);
    final s = Strings.of(context);
    void say(String text, FeedbackKind kind) {
      if (!mounted) return;
      feedback.notify(kind, text);
    }

    SharedGatewayLease? lease;
    try {
      lease = _moveLease = SharedGatewayPool.instance.acquire(
        widget.connection,
        factory: widget.gatewayFactory,
      );
      final tree = await lease.client.projectTree();
      if (!mounted) return;
      setState(() => _projectTree = tree);
      final targets = projectMoveTargets(
        tree,
        sessionCwd: session.cwd,
        sessionGitRepoRoot: session.gitRepoRoot,
      );
      if (targets.isEmpty) {
        say(s.se1215MoveNoProjects, FeedbackKind.error);
        return;
      }
      final target = await _pickProject(targets, title: s.se1215MenuMove);
      if (target == null || !mounted) return;
      final result = await lease.client.moveSessionWorkspace(
        sessionKey: session.id,
        cwd: target.cwd,
        profile: session.profile,
      );
      if (!mounted) return;
      _replaceSession(
        session.id,
        (row) => row.copyWith(
          cwd: result.cwd,
          gitRepoRoot: result.gitRepoRoot,
          clearGitRepoRoot: result.gitRepoRoot == null,
          gitBranch: result.branch,
          clearGitBranch: result.branch == null,
        ),
      );
      say(s.se1215MovedTo(target.label), FeedbackKind.routine);
    } on DesktopControlFailure catch (failure) {
      if (failure.kind == DesktopControlFailureKind.unsupported) {
        if (mounted) setState(() => _moveUnsupported.add(widget.connection.id));
      } else {
        say(s.se1215MoveFailed, FeedbackKind.error);
      }
    } catch (_) {
      say(s.se1215MoveFailed, FeedbackKind.error);
    } finally {
      lease?.release();
      if (identical(_moveLease, lease)) _moveLease = null;
    }
  }

  SharedGatewayLease? _moveLease;

  /// Applies [change] to the row [id] in the lists this screen holds, without
  /// reloading the library.
  void _replaceSession(String id, Session Function(Session row) change) {
    Session pick(Session row) => row.id == id ? change(row) : row;
    setState(() {
      _sessions = [for (final row in _sessions) pick(row)];
      final results = _searchResults;
      if (results != null) {
        _searchResults = [for (final row in results) pick(row)];
      }
      _listRevision++;
    });
  }

  Future<ProjectMoveTarget?> _pickProject(
    List<ProjectMoveTarget> targets, {
    required String title,
    bool withAll = false,
  }) {
    final s = Strings.of(context);
    return showHermesFloatingSurface<ProjectMoveTarget?>(
      context: context,
      surfaceKey: const ValueKey('session-project-surface'),
      maxWidth: 480,
      maxHeightFactor: 0.7,
      builder: (ctx) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: Theme.of(context).hermes.textPrimary,
                  ),
                ),
              ),
            ),
            Divider(height: 1, color: Theme.of(context).hermes.divider),
            if (withAll)
              ListTile(
                title: Text(s.se1215ProjectAll),
                onTap: () => Navigator.pop(
                  ctx,
                  const ProjectMoveTarget(id: '', label: '', cwd: ''),
                ),
              ),
            for (final target in targets)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(target.label),
                onTap: () => Navigator.pop(ctx, target),
              ),
          ],
        ),
      ),
    );
  }

  /// "Filtrar por proyecto": only offered once the tree was loaded.
  Future<void> _chooseProjectFilter() async {
    final tree = _projectTree;
    if (tree == null) return;
    final s = Strings.of(context);
    final choice = await _pickProject(
      projectMoveTargets(tree),
      title: s.se1215ProjectFilter,
      withAll: true,
    );
    if (choice == null || !mounted) return;
    setState(
      () => _projectFilterFolder = choice.cwd.isEmpty ? null : choice.cwd,
    );
  }

  // ── Export ───────────────────────────────────────────────────────────────

  SessionExportService? _exporter;

  /// "Exportar (JSON)": reads the transcript, writes the Desktop shaped file
  /// and opens the share sheet. The notice is the non-blocking progress;
  /// leaving the screen drops the result.
  Future<void> _exportSession(Session session) async {
    final notices = AppFeedback.of(context);
    final s = Strings.of(context);
    final title = _titleFor(session);
    final exporter =
        widget.sessionExporter ??
        (_exporter ??= SessionExportService(readMessages: _client.getMessages));
    // Long operation with no other on-screen progress: kept on purpose.
    final progress = notices.notify(
      FeedbackKind.critical,
      s.se1215ExportPreparing,
      duration: const Duration(minutes: 2),
    );
    final result = await exporter.export(
      session,
      title: title,
      isCancelled: () => !mounted,
    );
    progress?.dismiss();
    if (!mounted) return;
    final text = switch (result) {
      SessionExportResult.tooLarge => s.se1215ExportTooLarge,
      SessionExportResult.notFound ||
      SessionExportResult.unavailable ||
      SessionExportResult.failed => s.se1215ExportFailed,
      SessionExportResult.shared || SessionExportResult.cancelled => null,
    };
    if (text != null) {
      notices.notify(FeedbackKind.error, text);
    }
  }

  // ── Sort ─────────────────────────────────────────────────────────────────

  Future<void> _setSort(SessionListSort sort) async {
    if (sort == _sort) return;
    setState(() => _sort = sort);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sortPrefKey, sort.wire);
  }

  String _sortLabel(Strings s, SessionListSort sort) => switch (sort) {
    SessionListSort.activity => s.se1215SortActivity,
    SessionListSort.created => s.se1215SortCreated,
    SessionListSort.tokens => s.se1215SortTokens,
    SessionListSort.cost => s.se1215SortCost,
  };

  // ── Filtering ────────────────────────────────────────────────────────────

  /// [_computeFilteredSessions] memoized on every input it reads: list
  /// identities and in-place revision, local archive state (pin/archive/
  /// hidden/titles), query, category, archived toggle and locale.
  List<Session> get _filteredSessions {
    final key = (
      _sessions,
      _searchResults,
      _listRevision,
      _archive,
      _archive?.revision,
      _searchQuery,
      _activeCategory,
      _showArchived,
      Localizations.localeOf(context),
      _sort,
      _projectFilterFolder,
    );
    final previous = _filteredKey;
    if (previous is _FilterKey && _sameFilterKey(previous, key)) {
      return _filteredCache;
    }
    _filteredKey = key;
    return _filteredCache = List<Session>.unmodifiable(
      _computeFilteredSessions(),
    );
  }

  static bool _sameFilterKey(_FilterKey a, _FilterKey b) =>
      identical(a.$1, b.$1) &&
      identical(a.$2, b.$2) &&
      a.$3 == b.$3 &&
      identical(a.$4, b.$4) &&
      a.$5 == b.$5 &&
      a.$6 == b.$6 &&
      a.$7 == b.$7 &&
      a.$8 == b.$8 &&
      a.$9 == b.$9 &&
      a.$10 == b.$10 &&
      a.$11 == b.$11;

  List<Session> _computeFilteredSessions() {
    SessionListScreen.debugFilterPasses++;
    final query = _searchQuery.trim().toLowerCase();
    final searching = query.isNotEmpty;
    final loaded = searching && _repository != null
        ? (_searchResults ?? const <Session>[])
        : _sessions;
    // A chat just shown again, until a list read made after the server
    // confirmed carries it.
    final revealed = searching
        ? const <Session>[]
        : (_archive?.revealedSessions ?? const <Session>[]);
    final source = revealed.isEmpty
        ? loaded
        : [
            ...loaded,
            for (final row in revealed)
              if (!loaded.any((s) => s.logicalId == row.logicalId)) row,
          ];

    final list = source.where((s) {
      if (!_passesListFilters(s, searching: searching)) return false;

      // Apply search query
      if (query.isEmpty || _repository != null) return true;
      return _titleFor(s).toLowerCase().contains(query) ||
          s.preview.toLowerCase().contains(query);
    }).toList();

    // Las fijadas suben al principio en cualquier categoría no archivada
    // (archivar desfija). El resto sigue el orden elegido (por defecto, la
    // actividad reciente).
    // The archive keeps the server's order unless a key was chosen.
    if (_showArchived && _sort == SessionListSort.activity) return list;
    return sortSessionList(
      list,
      _sort,
      isPinned: _isPinned,
      pinnedFirst: !_showArchived,
    );
  }

  /// The list's own filters on one row, the search text aside: hidden,
  /// deleted, the archived view, the category and the project folder. The
  /// agent rail applies them to the other profiles' pages too.
  bool _passesListFilters(Session s, {required bool searching}) {
    // Hidden chats stay out of the lists (Archive > Hidden lists them);
    // a search still finds them, as on Desktop, to show them again.
    if (!searching && _isHidden(s)) return false;
    // Deleted on the server (from any screen): never painted again.
    if (_archive?.isSessionDeleted(s) ?? false) return false;

    final archived = _isArchived(s);
    if (_showArchived != archived) return false;
    if (!_activeCategory.includesSource(s.source)) return false;
    final folder = _projectFilterFolder;
    if (folder != null &&
        !sessionInProjectFolder(
          folder,
          cwd: s.cwd,
          gitRepoRoot: s.gitRepoRoot,
        )) {
      return false;
    }
    return true;
  }

  /// Intercala cabeceras de sección entre las sesiones (Fijadas, luego Hoy /
  /// Ayer / Esta semana / Semana pasada / Este mes / cada mes, según el orden
  /// elegido) y marca la posición de cada fila dentro de su sección.
  ///
  /// El mockup pinta UNA tarjeta redondeada por sección, con las filas
  /// separadas por líneas finas, en vez de una caja por conversación. Se
  /// devuelve una lista plana (cabecera / fila posicionada) en lugar de una
  /// lista de grupos para que `ListView.builder` siga construyendo filas de
  /// forma perezosa: la tarjeta se dibuja redondeando solo los extremos de
  /// cada sección.
  List<Object> _groupedEntries(List<Session> sessions) {
    final str = Strings.of(context);
    List<Object> card(String label, List<Session> rows, {required bool first}) {
      if (rows.isEmpty) return const <Object>[];
      return <Object>[
        _SessionGroupHeader(label: label, count: rows.length, first: first),
        for (var i = 0; i < rows.length; i++)
          _GroupedSessionRow(
            rows[i],
            first: i == 0,
            last: i == rows.length - 1,
          ),
      ];
    }

    if (_showArchived) {
      return card(
        _hiddenView ? str.slArchiveViewHidden : str.slFilterArchived,
        sessions,
        first: true,
      );
    }
    final pinned = <Session>[];
    final rest = <Session>[];
    for (final s in sessions) {
      (_isPinned(s) ? pinned : rest).add(s);
    }
    final out = <Object>[];
    out.addAll(card(str.sesPinned, pinned, first: true));
    // Tokens and cost have no date: one section named after the key.
    if (_sort == SessionListSort.tokens || _sort == SessionListSort.cost) {
      out.addAll(
        card(
          _sort == SessionListSort.tokens
              ? str.se1215SortTokens
              : str.se1215SortCost,
          rest,
          first: out.isEmpty,
        ),
      );
      return out;
    }
    // Human days (04:00 rollover) and the locale's weeks, months and years,
    // cut on the date of the chosen key and kept in the order the list has.
    final now = _now();
    final locale = Localizations.localeOf(context);
    final firstDay = MaterialLocalizations.of(context).firstDayOfWeekIndex;
    final weekStartsOn = firstDay == 0 ? DateTime.sunday : firstDay;
    final buckets = <CalendarBucketKey, List<Session>>{};
    final order = <CalendarBucketKey>[];
    for (final s in rest) {
      final key = calendarBucket(
        _sort.dateFor(s) ?? s.lastActivityAt,
        now,
        weekStartsOn: weekStartsOn,
      );
      final rows = buckets.putIfAbsent(key, () {
        order.add(key);
        return <Session>[];
      });
      rows.add(s);
    }
    for (final key in order) {
      out.addAll(
        card(
          calendarBucketLabel(str, key, locale),
          buckets[key]!,
          first: out.isEmpty,
        ),
      );
    }
    return out;
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) =>
      EnclosingRoute(onRoute: _attachRoute, child: _buildScreen(context));

  /// The Chats screen's header: «≡», «Conversaciones», the connection's
  /// state, new chat and the menu. Across the screen on a phone; on a wide
  /// window (mock 134) over the list only.
  /// The connection's state in words. A down socket names its state and
  /// overrides what REST said.
  String _connectionWord(Strings s) {
    final link = _health.link?.kind;
    if (link != null && link != ConnectionStatusKind.connected) {
      return connectionStatusWord(s, link);
    }
    if (_health.showsChecking) return s.hwServerChecking;
    return _health.online ? s.hwServerOnline : s.hwServerOffline;
  }

  /// The header's second line: «1 en vivo · 5 hoy». Only when the list is
  /// loaded and the text is not so large that two lines would not fit the
  /// bar (the count is secondary; the title is not).
  String? _chatsSubtitle(Strings s) {
    if (_loading ||
        !_archiveReady ||
        _error != null ||
        !_health.healthy ||
        _showArchived ||
        MediaQuery.textScalerOf(context).scale(1) > 1.3) {
      return null;
    }
    final now = _now();
    final firstDay = MaterialLocalizations.of(context).firstDayOfWeekIndex;
    final weekStartsOn = firstDay == 0 ? DateTime.sunday : firstDay;
    const today = CalendarBucketKey(CalendarBucket.today);
    var live = 0;
    var todayCount = 0;
    for (final session in _filteredSessions) {
      if (_liveStatusFor(session).isLive) live++;
      final bucket = calendarBucket(
        _sort.dateFor(session) ?? session.lastActivityAt,
        now,
        weekStartsOn: weekStartsOn,
      );
      if (bucket == today) todayCount++;
    }
    final parts = <String>[
      if (live > 0) s.screenChatsSubtitleLive(live),
      if (todayCount > 0) s.screenChatsSubtitleToday(todayCount),
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// «Conversaciones» and, under it, the day's count. It follows the live
  /// state, which the screen's own rebuilds do not carry.
  Widget _buildHeaderTitle(Strings s, HermesThemeColors colors) =>
      ListenableBuilder(
        listenable: Listenable.merge([_activeIdsGate, _liveStatusGate]),
        builder: (context, _) {
          final title = Text(
            s.drawerSessions,
            semanticsLabel: '${s.drawerSessions}, ${_connectionWord(s)}',
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
            ),
          );
          final subtitle = _chatsSubtitle(s);
          if (subtitle == null) return title;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title,
              Text(
                subtitle,
                key: const ValueKey('session-list-subtitle'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HermesType.caption.copyWith(color: colors.textTertiary),
              ),
            ],
          );
        },
      );

  PreferredSizeWidget _buildHeader(Strings s, HermesThemeColors colors) =>
      HermesAppBar(
        automaticallyImplyLeading: false,
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: Icon(Icons.menu, color: colors.textSecondary),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
            tooltip: s.slMenuTooltip,
          ),
        ),
        // the owner (gint72): no state dot of colour in the title pill. The
        // connection's state is said with the name to a screen reader; on
        // screen, a server that does not answer is the list's own state
        // (connecting, the issue), and the socket's is in the ≡ menu.
        title: _buildHeaderTitle(s, colors),
        // The instance is not named again here. Read-only, when it is: its
        // words while they fit beside the title, its icon when the header is
        // narrow or the text large, down to only said (gint51, gint67).
        titleBadge: widget.connection.readOnly
            ? const ReadOnlyBadge(compact: true, fitWidth: true)
            : null,
        centerTitle: false,
        titleSpacing: 0,
        actions: [
          // Mock 134-A: a pencil drawn in outline (audit 2.1).
          IconButton(
            icon: Icon(Icons.edit_outlined, color: colors.textPrimary),
            onPressed: _createNewSession,
            tooltip: s.slNewSession,
          ),
          // Ola 4 (audit 2.1, P2): under the filters «Archivo» took a row of
          // its own below 410 dp. Mock 134-A has no «Archivo»; of the
          // audit's two places (the ⋮ menu or an icon in the header) it is
          // in the header: one tap, as a filter is.
          _buildArchiveToggle(),
          HermesMenuButton<String>(
            icon: Icon(Icons.more_vert, color: colors.textSecondary),
            tooltip: s.slMoreOptions,
            onSelected: (value) {
              if (value.startsWith('sort:')) {
                unawaited(
                  _setSort(SessionListSort.fromWire(value.substring(5))),
                );
                return;
              }
              switch (value) {
                case 'refresh':
                  if (!_loading) _fetchSessions();
                case 'project-filter':
                  unawaited(_chooseProjectFilter());
                case 'import':
                  _openForeignImport();
              }
            },
            actions: (ctx) => [
              HermesAction(
                value: 'refresh',
                label: s.slMenuRefresh,
                icon: Icons.refresh,
              ),
              for (final sort in SessionListSort.values)
                HermesAction(
                  value: 'sort:${sort.wire}',
                  label: _sortLabel(s, sort),
                  selected: _sort == sort,
                  section: sort == SessionListSort.values.first
                      ? s.se1215SortBy
                      : null,
                ),
              if (_projectTree != null)
                HermesAction(
                  value: 'project-filter',
                  label: s.se1215ProjectFilter,
                  divided: true,
                ),
              if (_ownedActivityClient?.foreignSessionsAvailable == true)
                HermesAction(
                  value: 'import',
                  label: s.fsImportMenu,
                  icon: Icons.download_for_offline_outlined,
                  divided: _projectTree == null,
                ),
            ],
          ),
        ],
      );

  Widget _buildScreen(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    // Away from a phone (an open Fold either way up, a tablet; mock 134)
    // the header is the list's: over the list column beside a chat, gone
    // with the list when a chat takes the pane. No bar runs across a chat.
    final phone = Responsive.sizeClassOf(context) == WindowSizeClass.compact;
    final header = _buildHeader(s, colors);
    return Scaffold(
      appBar: phone ? header : null,
      drawerEnableOpenDragGesture: true,
      drawerEdgeDragWidth: HermesDrawer.edgeDragWidth(context),
      drawer: HermesDrawer(
        connection: widget.connection,
        connManager: widget.connManager,
        current: DrawerSection.sessions,
        connected: _health.online,
        checking: _health.showsChecking,
        link: _health.link?.kind,
        onSectionReturn: _fetchSessions,
      ),
      // "Ver todas" es alcanzable en 1 salto desde Inicio: sin el dock aquí
      // el usuario lo veía "desaparecer" al salir de Inicio (bug confirmado
      // en dispositivo real). `includeSessionsAction: false` evita apilar
      // esta misma pantalla si el usuario activó el acceso opcional
      // "Sesiones" del catálogo del dock.
      body: GeneralDockShell(
        connection: widget.connection,
        connManager: widget.connManager,
        onCreate: _createNewSession,
        includeSessionsAction: false,
        paneLayout: true,
        // Tablets only: on an open Fold the list, the chat and the
        // workspace need the room (mock 134); «≡» has the same places.
        railMinWidth: kChatWorkspaceNavigationMinWidth,
        // Tablets: the open conversation lives beside the list (expanded)
        // or in place of it (medium) instead of on a route of its own.
        // Which of the list, the chat and the workspace show is the
        // screen's one views controller, shared with the open chat.
        bodyBuilder: (_, _) => ChatWorkspaceScope(
          controller: _views,
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (_views.updateWindowWidth(constraints.maxWidth)) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _views.viewsChanged();
                });
              }
              return ListenableBuilder(
                listenable: _views,
                builder: (context, _) => AdaptiveListDetail(
                  key: _panes,
                  visibilityObserver: hermesRouteObserver,
                  placeholder: const _ChatPanePlaceholder(),
                  onCollapsedWithDetail: _reopenPaneChatFullScreen,
                  listWidth: ChatWorkspaceController.listWidth,
                  listVisible: _views.listVisible,
                  listOverlay: _views.listOverlay,
                  onDismissListOverlay: _views.dismissListOverlay,
                  listOverlayDismissLabel: s.cwsCloseList,
                  // Mock 134 state A: a short, faint line between the list
                  // and the chat, not a full-height rule.
                  dividerMargin: EdgeInsets.only(
                    top: MediaQuery.paddingOf(context).top + 6,
                    bottom: 14,
                  ),
                  dividerOpacity: 0.55,
                  // The list folded beside an open chat leaves its agents
                  // on a rail: one face per agent, its chats in a panel.
                  foldedListRail: phone ? null : _buildChatSwitcher,
                  list: phone
                      ? _buildBody()
                      : _ListColumn(
                          header: header,
                          selectedId: _paneSession?.id,
                          child: _buildBody(),
                        ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// The rail of agents beside [pane] while the list is folded (expanded
  /// window, a chat open): a view of the sessions this screen already
  /// holds, grouped by agent, with the live status and unread the rows
  /// show. It follows the same gates as the rows.
  Widget _buildChatSwitcher(Widget pane) {
    final roster = BotRosterRegistry.shared.store(widget.connection.id);
    return ListenableBuilder(
      listenable: Listenable.merge([
        _activeIdsGate,
        _liveStatusGate,
        ?_globalActivity,
        ?_archive,
        roster,
        _railChats,
      ]),
      builder: (context, _) {
        _scheduleRailRead(roster);
        return _buildChatSwitcherRail(context, roster, pane);
      },
    );
  }

  /// The scope the rail's pages of other profiles are read and kept under:
  /// the list's category and archived view, whichever profile is active.
  String get _railScope =>
      _libraryQueryFor(null, pageSize: ChatSwitcherRail.pageSize).fingerprint;

  /// After this frame, asks [_railChats] for the first page of every other
  /// profile that may have chats (it reads at most once a minute per scope,
  /// one request at a time; a repeat call is free).
  ///
  /// Server side effect, known and accepted: Hermes runs its session
  /// auto-archive on a list read (off by default; when on, at most once per
  /// 24 h per profile), so this read can trigger it for the other profiles
  /// too and opens their database for writing, as opening that profile's
  /// list would. Nothing else is written; it never runs under App Lock or in
  /// the background.
  void _scheduleRailRead(BotRosterStore roster) {
    if (_railReadScheduled) return;
    _railReadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _railReadScheduled = false;
      final repository = _repository;
      if (!mounted || repository == null || !_foreground) return;
      final owners = _railOwnersToRead(roster);
      _railChats.refresh(
        scope: _railScope,
        owners: owners,
        locked: ProfileFace.appLocked,
        requester: this,
        load: (owner) async {
          final page = await repository.peekFirstPage(
            _libraryQueryFor(
              owner == 'default' ? null : owner,
              pageSize: ChatSwitcherRail.pageSize,
            ),
          );
          return ProfileRailPage(sessions: page.sessions, more: page.more);
        },
      );
    });
  }

  /// The roster's profiles other than the active one, most recently active
  /// first. A roster read with sessions says which profiles have any: only
  /// those are read. A roster without them says nothing, so all are.
  List<String> _railOwnersToRead(BotRosterStore roster) {
    final active = Session.profileOwner(_profileScope.name);
    double? lastHint(AgentProfile profile) {
      double? best;
      for (final summary in [
        profile.lastSession,
        profile.preferredSession,
        profile.canonicalSession,
      ]) {
        if (summary == null) continue;
        final at = summary.lastActive ?? summary.startedAt ?? 0;
        if (best == null || at > best) best = at;
      }
      return best;
    }

    final hinted = roster.profiles.any((profile) => lastHint(profile) != null);
    final wanted = [
      for (final profile in roster.profiles)
        if (_profileOwner(profile) != active &&
            (!hinted || lastHint(profile) != null))
          (owner: _profileOwner(profile), at: lastHint(profile) ?? 0),
    ]..sort((a, b) => b.at.compareTo(a.at));
    return [for (final entry in wanted) entry.owner];
  }

  Widget _buildChatSwitcherRail(
    BuildContext context,
    BotRosterStore roster,
    Widget pane,
  ) => ChatSwitcherRail(
    agents: _switcherAgents(Strings.of(context), roster),
    currentChatId: _paneSession?.id,
    avatarCache: ProfileFace.cacheFor(
      widget.connection,
      rosterTicket: roster.ticket,
    ),
    connectionId: widget.connection.id,
    onOpenChat: _openChatById,
    onNewChat: (agent) => agent == null
        ? _createNewSession()
        : _createNewSessionWith(agent.owner),
    onOpenList: _views.toggleList,
    child: pane,
  );

  /// Every profile's chats as the agent rail lists and counts them, and
  /// whether the server has more of them («N+»). The one source of the
  /// rail's faces and panels and of the profile strip's counts (an open
  /// Fold, a tablet, a phone on its side): the same rows, the same rule.
  ///
  /// The active profile's are the list's own; the others' the first pages
  /// [_railChats] read, through the list's own predicate. While searching
  /// (the rail only) the active profile's are every row the search loaded,
  /// and the other profiles' pages are left out.
  ({Map<String, List<Session>> byOwner, Map<String, bool> more})
  _railChatsByOwner(BotRosterStore roster, {required bool searching}) {
    final source = searching ? _sessions : _filteredSessions;
    final byOwner = <String, List<Session>>{};
    final seen = <String>{};
    void add(Session session) {
      if (!seen.add(session.id)) return;
      byOwner
          .putIfAbsent(Session.profileOwner(session.profile), () => [])
          .add(session);
    }

    for (final session in source) {
      if (session.listsAsOwnRow) add(session);
    }
    final pane = _paneSession;
    if (pane != null) add(pane);
    // The other profiles' first pages (the list reads the active one only),
    // through the list's own filters. Every count is of the chats the
    // panel lists, by the list's own predicate, «N+» while the server has
    // pages not read: never the server's `total`, which also counts rows no
    // list shows (Fold, 9960: «Forja · 7 chats» over two).
    final active = Session.profileOwner(_profileScope.name);
    final more = <String, bool>{
      if (!searching && _branchesMayHaveMore) active: true,
    };
    if (!searching) {
      final scope = _railScope;
      // While the active profile's own read is pending its list is empty:
      // its last known rail page stands in for the count, not 0.
      final activeStandIn = _loading && (byOwner[active]?.isEmpty ?? true);
      for (final profile in roster.profiles) {
        final owner = _profileOwner(profile);
        if (owner == active && !activeStandIn) continue;
        final page = _railChats.page(scope, owner);
        if (page == null) continue;
        for (final session in page.sessions) {
          if (Session.profileOwner(session.profile) == owner &&
              session.listsAsOwnRow &&
              _passesListFilters(session, searching: false)) {
            add(session);
          }
        }
        if (page.more) more[owner] = true;
      }
    }
    for (final chats in byOwner.values) {
      chats.sort(compareSessionsByRecentActivity);
    }
    return (byOwner: byOwner, more: more);
  }

  /// The one order of the agents, for the rail's faces and the profile
  /// strip's: those with chats, newest chat first, then the roster's others
  /// in the roster's order (QA 9980 SC11: the strip kept the roster's order
  /// while the rail sorted by activity).
  List<String> _agentOwnerOrder(
    BotRosterStore roster,
    Map<String, List<Session>> byOwner,
  ) {
    final owners = byOwner.keys.toList()
      ..sort(
        (a, b) => byOwner[b]!.first.lastActivityAt.compareTo(
          byOwner[a]!.first.lastActivityAt,
        ),
      );
    for (final profile in roster.profiles) {
      final owner = _profileOwner(profile);
      if (!byOwner.containsKey(owner)) owners.add(owner);
    }
    return owners;
  }

  /// The rail's agents: those with chats in the list, newest chat first,
  /// then the roster's others (a new chat with them is one tap away). The
  /// chat open in the pane is always listed, even before the list carries
  /// it (a chat just created).
  List<ChatSwitcherAgent> _switcherAgents(Strings s, BotRosterStore roster) {
    final (:byOwner, :more) = _railChatsByOwner(
      roster,
      searching: _searchQuery.trim().isNotEmpty,
    );
    final owners = _agentOwnerOrder(roster, byOwner);
    final profiles = <String, AgentProfile>{
      for (final profile in roster.profiles) _profileOwner(profile): profile,
    };
    return [
      for (final owner in owners)
        ChatSwitcherAgent(
          owner: owner,
          // The name Bots and Inicio give the face beside it (its title
          // first: «Forja», not «console-builder»).
          name:
              profiles[owner]?.visibleName ??
              activeProfileDisplayLabel(
                s,
                owner == 'default' ? '' : owner,
                roster.profiles,
              ),
          profile: profiles[owner],
          more: more[owner] ?? false,
          chats: [
            for (final session in byOwner[owner] ?? const <Session>[])
              ChatSwitcherChat(
                id: session.id,
                title: _titleFor(session),
                time: _relativeTime(session.lastActivityAt, s),
                mark: _switcherMark(session),
              ),
          ],
        ),
    ];
  }

  /// The one mark of a chat on the rail, as the row shows it: a live turn
  /// is working (or waiting, when it needs the user); otherwise unread.
  ChatSwitcherMark _switcherMark(Session session) {
    final status = _liveStatusFor(session);
    if (status.phase == SessionLivePhase.waitingForUser) {
      return ChatSwitcherMark.waiting;
    }
    if (status.isLive) return ChatSwitcherMark.working;
    if (_archive?.isSessionUnread(session) ?? false) {
      return ChatSwitcherMark.unread;
    }
    return ChatSwitcherMark.none;
  }

  /// A row of the rail's panel: the chat by its id, through the same path
  /// a row of the list takes (the pane keeps the screen).
  void _openChatById(String id) {
    final pane = _paneSession;
    final session = pane != null && pane.id == id
        ? pane
        : _sessions.where((row) => row.id == id).firstOrNull ??
              _railChats
                  .pages(_railScope)
                  .expand((page) => page.sessions)
                  .where((row) => row.id == id)
                  .firstOrNull;
    if (session == null) return;
    unawaited(_openChat(session));
  }

  /// «Nueva conversación con …»: a fresh chat bound to [owner] (the main
  /// profile stays unnamed, as [_createNewSession] leaves it).
  void _createNewSessionWith(String owner) {
    final session = Session(
      id: generateSessionId(),
      title: Strings.of(context).drawerNewChat,
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 0,
      isActive: true,
      preview: '',
      startedAt: DateTime.now().millisecondsSinceEpoch.toDouble() / 1000,
      profile: owner == 'default' ? null : owner,
    );
    unawaited(_openChat(session));
  }

  Widget _buildBody() {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    if (_health.checking && !_health.healthy && !_showingColdList) {
      return _ConnectingState(host: widget.connection.host);
    }

    // The first check of the run is still on the wire and the cold list is
    // on screen: that is not «no connection» yet.
    if (!_health.healthy && !(_health.checking && _showingColdList)) {
      return _ConnectionIssueState(
        baseUrl: widget.connection.baseUrl,
        onRetry: _checkHealth,
      );
    }

    if (_loading || !_archiveReady) {
      // Ola 7 (AUDITORIA-PULIDO §4.2): the shape of the list that is
      // coming, where its rows will be, instead of «Cargando…».
      return HermesControlsScroll(
        controls: const [],
        slivers: [
          HermesControlsScroll.children(const [
            _SessionListSkeleton(),
          ], padding: _listPadding),
        ],
      );
    }

    if (_error != null) {
      final loginRefused = _isLoginRefusal(_error!);
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: colors.warning),
            const SizedBox(height: 16),
            Text(
              loginRefused ? s.s2SessionExpiredLine : s.slConnectionError,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                loginRefused ? s.s2SessionExpiredBody : s.slListNotLoaded,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: loginRefused ? _signIn : _fetchSessions,
              icon: Icon(
                loginRefused ? Icons.login_rounded : Icons.refresh_rounded,
                size: 18,
              ),
              label: Text(loginRefused ? s.s2SessionExpiredSignIn : s.slRetry),
            ),
            if (loginRefused)
              TextButton(
                key: const ValueKey('session-list-recover-access'),
                onPressed: () => unawaited(openRecoverAccess(context)),
                child: Text(s.dashboardSetupForgotPassword),
              ),
          ],
        ),
      );
    }

    final filtered = _hiddenView ? _hiddenSessionsView() : _filteredSessions;
    // Entradas intercaladas con cabeceras de fecha (estilo Claude: Hoy / Ayer…).
    final entries = _groupedEntries(filtered);

    // One scroll for the whole page: the search field, the category switch
    // and the notices are its first rows and leave with the conversations,
    // which pass under the floating header. They keep their place in the
    // tree whatever follows them, so the field keeps the focus while its
    // results change.
    return HermesControlsScroll(
      controller: _libraryScrollController,
      refreshColor: colors.accent,
      onRefresh: _refreshSessionsAndActivity,
      controls: [
        _buildSearchField(),
        _buildBotFilterRow(),
        _buildFilterControl(),
        // Script-only scheduled jobs never create a session: their runs live
        // under each job (Desktop's sidebar cron section). The Automation tab
        // leads there instead of looking empty while jobs keep running.
        if (_activeCategory == SessionCategory.automation && !_showArchived)
          ScheduledJobsEntry(onTap: _openScheduledJobs),
        if (_showArchived) _buildArchiveViewControl(),
        if (_searching && !_hiddenView)
          LinearProgressIndicator(
            minHeight: 1,
            color: colors.accent,
            backgroundColor: Colors.transparent,
          )
        else if (_searchQuery.trim().isNotEmpty && !_searchExhaustive)
          _LibraryScopeNotice(text: s.slSearchLoadedOnly),
      ],
      slivers: [
        if (filtered.isEmpty)
          HermesControlsScroll.fill(
            _searching
                ? const Center(child: TuiLoader())
                : _FilteredEmptyState(
                    archived: _showArchived,
                    hidden: _hiddenView,
                    automation: _activeCategory == SessionCategory.automation,
                    searching: _searchQuery.isNotEmpty,
                    onCreateNew:
                        !_showArchived &&
                            _searchQuery.trim().isEmpty &&
                            _activeCategory != SessionCategory.automation
                        ? _createNewSession
                        : null,
                  ),
          )
        else
          ListenableBuilder(
            listenable: Listenable.merge([
              _activeIdsGate,
              _liveStatusGate,
              ?_globalActivity,
              // The bots' sprites follow the roster.
              BotRosterRegistry.shared.store(widget.connection.id),
              // La reserva inferior depende de si el dock está
              // activado (interruptor global de Ajustes).
              DockPreferencesController.instance.listenable,
            ]),
            builder: (context, _) => HermesControlsScroll.list(
              // El dock se pinta ENCIMA de esta lista (overlay del
              // `GeneralDockShell`) y no reserva hueco: sin esta
              // reserva la última conversación queda detrás de la
              // barra (bug confirmado en dispositivo real).
              padding: EdgeInsets.fromLTRB(
                16,
                4,
                16,
                12 + _dockBottomReservation(context),
              ),
              itemCount: entries.length + (_loadingMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == entries.length) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Center(child: ConsoleLoader.small(dimension: 20)),
                  );
                }
                final entry = entries[index];
                if (entry is _SessionGroupHeader) {
                  return _SessionSectionLabel(header: entry);
                }
                final row = entry as _GroupedSessionRow;
                final session = row.session;
                return _SessionCardRow(
                  first: row.first,
                  last: row.last,
                  sessionId: session.id,
                  child: _hiddenView
                      ? _hiddenSessionRow(session, s)
                      : _sessionRow(session, s, colors),
                );
              },
            ),
          ),
      ],
    );
  }

  /// The bot's own small sprite for [session]'s row: its silhouette, static.
  Widget _botSprite(Session session, {bool working = false}) {
    final owner = Session.profileOwner(session.profile);
    final roster = BotRosterRegistry.shared.store(widget.connection.id);
    AgentProfile? profile;
    for (final candidate in roster.profiles) {
      if (_profileOwner(candidate) == owner) profile = candidate;
    }
    return ProfileFace(
      profileName: owner,
      profile: profile,
      avatarCache: ProfileFace.cacheFor(
        widget.connection,
        rosterTicket: roster.ticket,
      ),
      size: _sessionSpriteSize,
      working: working,
    );
  }

  /// Fila deslizable de una conversación.
  ///
  /// Dos gestos, ninguno destructivo:
  ///  - hacia la derecha: "Fijar arriba" / "Desfijar", la acción del mockup.
  ///  - hacia la izquierda: "Gestionar", la entrada al menú de acciones que ya
  ///    existía (y que sigue siendo la única vía a borrar, archivar, renombrar,
  ///    detalles, ocultar y copiar ID).
  /// Long-press se conserva como alternativa accesible para TalkBack y teclado.
  Widget _sessionRow(Session session, Strings s, HermesThemeColors colors) {
    final archived = _isArchived(session);
    final pinned = _isPinned(session);
    final status = _liveStatusFor(session);
    // Una compactación enciende la fila (punto + «Compactando») pero no
    // ofrece «Detener»: no es un turno que se pueda parar.
    final streamActive = status.isLive;
    final stoppable =
        streamActive && status.phase != SessionLivePhase.compacting;
    return Dismissible(
      key: ValueKey('${session.id}-$archived'),
      direction: DismissDirection.horizontal,
      background: _SwipeAffordance(
        alignment: Alignment.centerLeft,
        icon: pinned ? Icons.push_pin_outlined : Icons.push_pin,
        label: pinned ? s.slMenuUnpin : s.slMenuPin,
      ),
      secondaryBackground: _SwipeAffordance(
        alignment: Alignment.centerRight,
        icon: Icons.tune_rounded,
        label: s.slSwipeManage,
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          await _togglePin(session);
        } else {
          await _showSessionContextMenu(session);
        }
        // El gesto abre acciones o fija; nunca borra por arrastre.
        return false;
      },
      child: _SessionTile(
        session: session,
        leading: _botSprite(session, working: streamActive),
        title: _titleFor(session),
        formattedTime: _relativeTime(session.lastActivityAt, s),
        pinned: pinned,
        unread: _archive?.isSessionUnread(session) ?? false,
        status: status,
        streamActive: streamActive,
        onStop: stoppable ? () => _stopSession(session) : null,
        onTap: () => _openChat(session),
        onLongPress: () => _showSessionContextMenu(session),
      ),
    );
  }

  /// A row of Archive > Hidden: where it is hidden, and a direct Show.
  Widget _hiddenSessionRow(Session session, Strings s) {
    final onServer = _archive?.isSessionHiddenOnServer(session) ?? false;
    return _SessionTile(
      session: session,
      leading: _botSprite(session),
      title: _titleFor(session),
      formattedTime: _relativeTime(session.lastActivityAt, s),
      hiddenNote: onServer ? s.slHiddenOnServerNote : s.slHiddenLocalNote,
      onShow: () => _toggleHidden(session),
      onTap: () => _openChat(session),
      onLongPress: () => _showSessionContextMenu(session),
    );
  }

  /// Archive's two views; only shown inside Archive.
  Widget _buildArchiveViewControl() {
    final s = Strings.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: HermesSegmentedControl<bool>(
        value: _showHiddenInArchive,
        onChanged: _selectArchiveView,
        segments: [
          HermesSegment(
            key: const ValueKey('archive-view-archived'),
            value: false,
            label: s.slArchiveViewArchived,
          ),
          HermesSegment(
            key: const ValueKey('archive-view-hidden'),
            value: true,
            label: s.slArchiveViewHidden,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: HermesSearchField(
        onChanged: _onSearchChanged,
        autofocus: widget.autofocusSearch,
        hintText: Strings.of(context).slSearchHint,
        clearTooltip: Strings.of(context).slClearSearch,
      ),
    );
  }

  /// One chip per bot of the roster, its sprite and name: the profile
  /// switcher's own logic (the active profile scopes this list), one tap
  /// away from the list. Nothing to choose between with a single bot.
  ///
  /// Away from a phone held upright (an open Fold, a tablet, a phone on its
  /// side: the windows where the agent rail stands in for a folded list)
  /// each face also wears the rail's count, from the rail's own source and
  /// rule ([_railChatsByOwner]): the strip and the rail never disagree
  /// (QA 9970 SC11, Pixel on its side: faces with no number). Not while
  /// searching: the other profiles' pages are not searched.
  Widget _buildBotFilterRow() {
    final roster = BotRosterRegistry.shared.store(widget.connection.id);
    final counted =
        Responsive.sizeClassOf(context) != WindowSizeClass.compact;
    return ListenableBuilder(
      listenable: Listenable.merge([
        _profileScope,
        roster,
        if (counted) _railChats,
        if (counted && _archive != null) _archive!,
      ]),
      builder: (context, _) {
        final profiles = roster.profiles;
        if (profiles.length < 2) return const SizedBox.shrink();
        final s = Strings.of(context);
        final faces = ProfileFace.cacheFor(
          widget.connection,
          rosterTicket: roster.ticket,
        );
        final searching = _searchQuery.trim().isNotEmpty;
        final railChats = counted
            ? _railChatsByOwner(roster, searching: false)
            : null;
        final counts = searching ? null : railChats;
        // Where the rail exists the faces keep its order (and only the
        // roster's profiles are drawn); elsewhere, the roster's.
        final byOwner = {
          for (final profile in profiles) _profileOwner(profile): profile,
        };
        final ordered = railChats == null
            ? profiles
            : [
                for (final owner in _agentOwnerOrder(roster, railChats.byOwner))
                  if (byOwner[owner] != null) byOwner[owner]!,
              ];
        if (counted) _scheduleRailRead(roster);
        return Padding(
          padding: const EdgeInsets.only(bottom: HermesSpace.x2),
          child: Semantics(
            container: true,
            label: s.screenChatsBotFilter,
            child: SingleChildScrollView(
              key: const ValueKey('session-bot-filter'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final profile in ordered)
                    _BotFilterChip(
                      profile: profile,
                      label: profileDisplayLabel(s, profile),
                      count: counts == null
                          ? null
                          : counts.byOwner[_profileOwner(profile)]?.length ?? 0,
                      more: counts?.more[_profileOwner(profile)] ?? false,
                      cache: faces,
                      selected: _profileOwner(profile) == _profileScope.owner,
                      onTap: () => unawaited(
                        _profileScope.switchTo(
                          profile.isDefault ? '' : profile.name,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildFilterControl() {
    final s = Strings.of(context);
    final categories = HermesSegmentedControl<SessionCategory>(
      value: _activeCategory,
      onChanged: _selectCategory,
      segments: [
        HermesSegment(
          key: const ValueKey('session-filter-all'),
          value: SessionCategory.chats,
          label: SessionCategory.chats.label(s),
          flex: 5,
          horizontalPadding: 6,
        ),
        HermesSegment(
          key: const ValueKey('session-filter-automation'),
          value: SessionCategory.automation,
          label: SessionCategory.automation.label(s),
          flex: 12,
          horizontalPadding: 6,
        ),
        HermesSegment(
          key: const ValueKey('session-filter-everything'),
          value: SessionCategory.all,
          label: SessionCategory.all.label(s),
          flex: 4,
          horizontalPadding: 6,
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      child: SizedBox(width: double.infinity, child: categories),
    );
  }

  /// The archive's toggle, in the header: a 48 dp target around the icon,
  /// filled while the archive shows.
  Widget _buildArchiveToggle() {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      selected: _showArchived,
      label: s.slFilterArchived,
      // excludeSemantics drops the IconButton's own tap: the node carries
      // it, or TalkBack reads a button a double tap does nothing on.
      onTap: _toggleArchived,
      excludeSemantics: true,
      child: Tooltip(
        message: s.slFilterArchived,
        child: IconButton(
          key: const ValueKey('session-filter-archived'),
          onPressed: _toggleArchived,
          icon: const Icon(Icons.inventory_2_outlined, size: HermesIcon.md),
          color: _showArchived ? colors.textPrimary : colors.textSecondary,
          style: IconButton.styleFrom(
            minimumSize: const Size.square(HermesSpace.tap),
            backgroundColor: _showArchived ? colors.surface : null,
            shape: const CircleBorder(),
          ),
        ),
      ),
    );
  }
}

/// Automation tab entry to the scheduled jobs, each listing its runs newest
/// first (agent runs open their read-only transcript).
@visibleForTesting
class ScheduledJobsEntry extends StatelessWidget {
  final VoidCallback onTap;

  const ScheduledJobsEntry({required this.onTap, super.key});

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: ListTile(
        key: const ValueKey('session-library-scheduled-jobs'),
        dense: true,
        leading: Icon(Icons.schedule_rounded, color: colors.accent),
        title: Text(s.crnTitle),
        trailing: Icon(Icons.chevron_right, color: colors.textSecondary),
        onTap: onTap,
      ),
    );
  }
}

class _LibraryScopeNotice extends StatelessWidget {
  final String text;

  const _LibraryScopeNotice({required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
        child: HermesInfoBanner(
          text,
          key: const ValueKey('session-library-scope-notice'),
          icon: Icons.info_outline,
          tone: colors.textSecondary,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Private widgets
// ─────────────────────────────────────────────────────────────────────────────

/// Reserva inferior para que el dock flotante no tape el final de la lista.
/// Alto de la barra (48) + su separación del borde (12) + el `lift` máximo del
/// estilo "Flotante" (6) + el inset seguro del sistema. Con el interruptor
/// global apagado el dock no existe y no se reserva nada.
double _dockBottomReservation(BuildContext context) =>
    DockPreferencesController.instance.value.useDock
    ? DockScrollClearance.maybeOf(context) ??
          48 + 12 + 6 + MediaQuery.paddingOf(context).bottom
    : 0;

/// Cabecera de sección del listado: etiqueta en mayúsculas + cuenta.
class _SessionGroupHeader {
  final String label;
  final int count;
  final bool first;

  const _SessionGroupHeader({
    required this.label,
    required this.count,
    required this.first,
  });
}

/// Una conversación y su posición dentro de la tarjeta de su sección.
class _GroupedSessionRow {
  final Session session;
  final bool first;
  final bool last;

  const _GroupedSessionRow(
    this.session, {
    required this.first,
    required this.last,
  });
}

class _SessionSectionLabel extends StatelessWidget {
  final _SessionGroupHeader header;

  const _SessionSectionLabel({required this.header});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final style = HermesType.caption.copyWith(color: colors.textTertiary);
    // La cabecera respira sobre su tarjeta y separa secciones sin necesidad de
    // una caja propia.
    return Semantics(
      header: true,
      child: Padding(
        padding: EdgeInsets.fromLTRB(4, header.first ? 6 : 26, 4, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // The label in small caps on the left, its count on the right,
            // both in the quiet tone.
            Expanded(
              child: Text(
                header.label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
            const SizedBox(width: HermesSpace.x2),
            Text('${header.count}', style: style),
          ],
        ),
      ),
    );
  }
}

/// A row of the list at rest (the mockup's 64 dp).
const double _sessionRowHeight = 64;

/// The bot's sprite at the start of a row.
const double _sessionSpriteSize = 36;

String _profileOwner(AgentProfile profile) =>
    profile.isDefault ? 'default' : profile.name;

/// A bot of the filter row: its small sprite over its name. The selected one
/// wears the accent ring the profile switcher gives the active profile.
/// With a [count] (windows where the agent rail exists), the rail's badge
/// sits on the face and the face is read as the rail's is.
class _BotFilterChip extends StatelessWidget {
  const _BotFilterChip({
    required this.profile,
    required this.label,
    required this.cache,
    required this.selected,
    required this.onTap,
    this.count,
    this.more = false,
  });

  /// The face of the strip, a touch smaller than a row's tap target.
  static const double faceSize = 40;

  final AgentProfile profile;
  final String label;
  final MissionProfileAvatarCache cache;
  final bool selected;
  final VoidCallback onTap;

  /// The chats the agent rail counts for the profile; null where the rail
  /// does not exist (a phone held upright) or while searching.
  final int? count;

  /// «N+»: the server has chats past [count].
  final bool more;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final count = this.count;
    final face = ProfileFace(
      profileName: _profileOwner(profile),
      profile: profile,
      avatarCache: cache,
      active: selected,
      size: faceSize,
    );
    return Semantics(
      button: true,
      selected: selected,
      label: count == null
          ? label
          : chatSwitcherCountLabel(
              Strings.of(context),
              label,
              count,
              more: more,
            ),
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('session-bot-filter-${profile.name}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(HermesRadius.control),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: HermesSpace.tap,
            maxWidth: 72,
            minHeight: HermesSpace.tap,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HermesSpace.x1,
              vertical: HermesSpace.x1,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (count == null || count == 0)
                  face
                else
                  // The badge stays within the face's height (the name
                  // sits 2 px under it) and leans into the chip's own
                  // padding sideways, never past it: no wider than the
                  // face and that padding (a «10+» in large text over a
                  // short name's chip shrinks rather than cover the next).
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      face,
                      Positioned(
                        right: -HermesSpace.x1,
                        bottom: 0,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: faceSize + HermesSpace.x1,
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: ChatSwitcherCountBadge(
                              key: ValueKey(
                                'session-bot-filter-count-${profile.name}',
                              ),
                              count: count,
                              more: more,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: HermesType.caption.copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? colors.textPrimary : colors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Around the rows of the list, as the loaded list has them.
const EdgeInsets _listPadding = EdgeInsets.fromLTRB(
  HermesSpace.x4,
  HermesSpace.x1,
  HermesSpace.x4,
  HermesSpace.x3,
);

/// Ola 7: the list's first load, four rows of the shape that is coming, in
/// the same cards as the rows. Static.
class _SessionListSkeleton extends StatelessWidget {
  const _SessionListSkeleton();

  static const int _rows = 4;

  @override
  Widget build(BuildContext context) => SkeletonSemantics(
    child: Column(
      key: const ValueKey('session-list-skeleton'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _rows; i++)
          _SessionCardRow(
            first: i == 0,
            last: i == _rows - 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: _sessionRowHeight),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: HermesSpace.x4,
                  vertical: HermesSpace.x3,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SkeletonBar(widthFactor: i.isEven ? 0.58 : 0.44),
                    const SizedBox(height: HermesSpace.x2),
                    SkeletonBar(
                      widthFactor: i.isEven ? 0.82 : 0.7,
                      height: HermesSpace.gap,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// Una conversación como píldora propia: relleno de cristal, el mismo
/// acabado que los botones a escala de caja (contorno en dos tonos, filo de
/// luz arriba y sombra corta) y separación entre filas. Sin blur sobre el
/// contenido: todo se pinta, así que una lista larga no cuesta más.
class _SessionCardRow extends StatelessWidget {
  /// How much of the card is its surface; the rest lets the backdrop through.
  static const double _cardGlass = 0.58;

  final bool first;
  final bool last;
  final String? sessionId;
  final Widget child;

  const _SessionCardRow({
    required this.first,
    required this.last,
    required this.child,
    this.sessionId,
  });

  /// Air between two pills and the corner radius of each.
  static const double gap = 8;
  static const double radius = HermesRadius.card;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    final wide = _WideListScope.maybeOf(context);
    // Every conversation is ONE pill of its own: its own glass fill, a hair
    // of border and air between rows, never a line of text on the page and
    // never a slab of joined rows. No blur over the content: the fill, the
    // rims and the short compact shadow are painted.
    final selected =
        wide != null && sessionId != null && wide.selectedId == sessionId;
    final shape = BorderRadius.circular(radius);
    final glass = HermesGlassLook.of(context);
    // Beside the chat the open conversation is the lifted one.
    final body = ClipRRect(
      borderRadius: shape,
      // El recorte mantiene el deslizamiento dentro de las esquinas
      // redondeadas de la tarjeta.
      child: Material(type: MaterialType.transparency, child: child),
    );
    final Widget pill;
    if (glass != null) {
      pill = HermesGlassLook.body(
        glass,
        shape,
        fill: glass.cardFill,
        line: selected ? glass.selectedLine : null,
        lifted: true,
        compact: true,
        child: body,
      );
    } else {
      pill = DecoratedBox(
        decoration: BoxDecoration(
          color: selected
              ? colors.surface
              : HermesSoftLight.solid(context)
              ? HermesSoftLight.cardFill(context, colors)
              : colors.surface.withValues(alpha: _cardGlass),
          borderRadius: shape,
          border: Border.all(color: selected ? colors.accent : chrome.line),
          boxShadow: selected ? chrome.shadow : null,
        ),
        child: body,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: gap),
      child: KeyedSubtree(
        key: selected ? const ValueKey('session-row-selected') : null,
        child: pill,
      ),
    );
  }
}

/// Fondo revelado al deslizar una fila: icono + etiqueta sobre la superficie
/// de la tarjeta, sin tintes de alarma (ninguna de las dos acciones borra).
class _SwipeAffordance extends StatelessWidget {
  final AlignmentGeometry alignment;
  final IconData icon;
  final String label;

  const _SwipeAffordance({
    required this.alignment,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return ColoredBox(
      color: colors.surfaceVariant,
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: colors.textPrimary),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Empty state contextual para cuando hay sesiones pero el filtro/búsqueda
/// las deja fuera.
class _FilteredEmptyState extends StatelessWidget {
  final bool archived;
  final bool hidden;
  final bool automation;
  final bool searching;
  final VoidCallback? onCreateNew;

  const _FilteredEmptyState({
    required this.archived,
    this.hidden = false,
    required this.automation,
    required this.searching,
    this.onCreateNew,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final IconData icon;
    final String title;
    final String subtitle;
    if (searching) {
      icon = Icons.search_off_rounded;
      title = s.slEmptySearchTitle;
      subtitle = s.slEmptySearchSubtitle;
    } else if (hidden) {
      icon = Icons.visibility_off_outlined;
      title = s.slEmptyHiddenTitle;
      subtitle = s.slEmptyHiddenSubtitle;
    } else if (archived) {
      icon = Icons.archive_outlined;
      title = s.slEmptyArchivedTitle;
      subtitle = s.slEmptyArchivedSubtitle;
    } else if (automation) {
      icon = Icons.schedule_outlined;
      title = s.slEmptyAutomationTitle;
      subtitle = s.slEmptyAutomationSubtitle;
    } else {
      icon = Icons.chat_bubble_outline;
      title = s.slEmptyTitle;
      subtitle = s.slEmptySubtitle;
    }
    // The page's own scroll carries it (and the pull to refresh): it fills
    // what the controls leave free.
    return Center(
      child: HermesEmptyState(
        compact: true,
        icon: icon,
        title: title,
        body: subtitle,
        primaryLabel: onCreateNew == null ? null : s.drawerNewChat,
        primaryIcon: Icons.edit_square,
        onPrimary: onCreateNew,
      ),
    );
  }
}

class _ConnectingState extends StatefulWidget {
  final String host;

  const _ConnectingState({required this.host});

  @override
  State<_ConnectingState> createState() => _ConnectingStateState();
}

class _ConnectingStateState extends State<_ConnectingState>
    with TickerProviderStateMixin {
  late final AnimationController _dotCtrl;
  late final AnimationController _pulseCtrl;
  late final AnimationController _spinCtrl;

  @override
  void initState() {
    super.initState();
    _dotCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _spinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
  }

  @override
  void dispose() {
    _dotCtrl.dispose();
    _pulseCtrl.dispose();
    _spinCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Center(
      child: AnimatedBuilder(
        animation: _pulseCtrl,
        builder: (context, child) {
          final pulse = Curves.easeInOut.transform(_pulseCtrl.value);
          return AccentCard(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            accent: colors.accent.withValues(alpha: 0.55 + 0.45 * pulse),
            background: colors.surfaceVariant.withValues(alpha: 0.55),
            borderColor: colors.divider,
            boxShadow: [
              BoxShadow(
                color: colors.accent.withValues(alpha: 0.04 + 0.08 * pulse),
                blurRadius: 12,
              ),
            ],
            child: Opacity(opacity: 0.7 + 0.3 * pulse, child: child),
          );
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RotationTransition(
              turns: _spinCtrl,
              child: Icon(Icons.sync_rounded, size: 18, color: colors.accent),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: AnimatedBuilder(
                animation: _dotCtrl,
                builder: (context, child) {
                  final dots = '.' * ((_dotCtrl.value * 3).floor() + 1);
                  return Text(
                    '${Strings.of(context).i18n131P6ConnectingHost(widget.host)}$dots',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.accent,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionIssueState extends StatelessWidget {
  final String baseUrl;
  final VoidCallback onRetry;

  const _ConnectionIssueState({required this.baseUrl, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: colors.warning.withValues(alpha: 0.10),
                shape: BoxShape.circle,
                border: Border.all(
                  color: colors.warning.withValues(alpha: 0.35),
                ),
              ),
              child: Icon(Icons.cloud_off_rounded, color: colors.warning),
            ),
            const SizedBox(height: 16),
            Text(
              Strings.of(context).slNoGateway,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              baseUrl,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 10),
            Text(
              Strings.of(context).slGatewayHelp,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.textTertiary,
              ),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(Strings.of(context).slRetry),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  final Session session;

  /// The bot's sprite, at the start of the row.
  final Widget? leading;
  final String title;
  final String formattedTime;
  final bool pinned;

  /// The server's read state (Desktop's unread dot).
  final bool unread;

  /// Hay un stream del chat en curso en segundo plano para esta sesión: la
  /// respuesta/ejecución sigue aunque saliste. Cuenta como "viva".
  final bool streamActive;

  /// ss1215: the session's single derived status (chat, list and Home).
  final SessionLiveStatus status;
  final Future<void> Function()? onStop;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// Archive > Hidden: where the chat is hidden (in place of the preview)
  /// and the Show action (in place of the time).
  final String? hiddenNote;
  final VoidCallback? onShow;

  const _SessionTile({
    required this.session,
    this.leading,
    required this.title,
    required this.formattedTime,
    this.pinned = false,
    this.unread = false,
    this.streamActive = false,
    this.status = SessionLiveStatus.idle,
    this.onStop,
    required this.onTap,
    required this.onLongPress,
    this.hiddenNote,
    this.onShow,
  });

  /// Semantic state of the live row: the dot and the status line share its
  /// colour (green working, calm tint compacting, amber waiting, muted
  /// stale/idle), so the status never reads like the title.
  SessionStatusTone get _statusTone =>
      sessionStatusToneFor(sessionLiveStatusKind(status), stale: status.stale);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    // Desktop's sidebar paints the session's own preview or no line at all
    // (session-row.tsx); no placeholder stands in for a missing preview.
    final preview = sessionListPreview(session) ?? '';
    final activityLabel = status.isLive
        ? sessionLiveStatusLabel(strings, status)
        : strings.slRunningBadge;
    // El borrador se cuenta como texto descriptivo hilado en la línea de
    // vista previa ("Borrador · Resume los cambios…"), no como una píldora
    // de color aparte: es lo que pide el mockup y lo que evita las "cajitas".
    final draftLabel = _sentenceCase(strings.slDraftBadge);
    final previewText =
        hiddenNote ??
        (session.hasLocalDraft
            ? <String>[draftLabel, if (preview.isNotEmpty) preview].join(' · ')
            : preview);
    // A search hit paints its matched terms (Hermes' FTS delimiters), never
    // the raw markers.
    final highlights = session.hasLocalDraft || hiddenNote != null
        ? null
        : sessionSearchHighlights(session);
    final liveTone = sessionStatusColor(colors, _statusTone);
    final showUnread =
        unread &&
        !streamActive &&
        status.phase != SessionLivePhase.waitingForUser;
    final unreadDot = Semantics(
      label: strings.slUnreadDot,
      child: Container(
        key: ValueKey('session-unread-${session.id}'),
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: colors.accent, shape: BoxShape.circle),
      ),
    );
    // Mock 134-A: beside the chat the time closes the preview line («… · 20
    // h»), so the title keeps the column's width (audit 2.1, P1: a column
    // of its own took 90-120 dp of a 300 dp list).
    final wide = _WideListScope.maybeOf(context) != null;
    final timeInPreview = wide && onShow == null && formattedTime.isNotEmpty;
    final previewStyle = HermesType.support.copyWith(
      height: 1.25,
      color: colors.textSecondary,
    );
    final timeStyle = HermesType.support.copyWith(
      fontWeight: FontWeight.w500,
      color: colors.textTertiary,
    );
    Widget previewLine(Widget preview) => !timeInPreview
        ? preview
        : Row(
            children: [
              Flexible(child: preview),
              Text(
                ' · $formattedTime',
                key: ValueKey('session-time-${session.id}'),
                maxLines: 1,
                style: timeStyle,
              ),
            ],
          );

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ConstrainedBox(
        // 64dp es el alto de fila del mockup y deja el objetivo táctil muy por
        // encima del mínimo de 44dp.
        constraints: const BoxConstraints(minHeight: _sessionRowHeight),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: wide ? HermesSpace.inset : HermesSpace.x4,
            vertical: 11,
          ),
          child: Row(
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: HermesSpace.x3),
              ],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title.isNotEmpty ? title : strings.slNoTitle,
                            // Beside the chat (≥ 300 dp) a long title takes
                            // a second line instead of «Comprobar proble…».
                            maxLines: _WideListScope.maybeOf(context) == null
                                ? 1
                                : 2,
                            overflow: TextOverflow.ellipsis,
                            style: HermesType.body.copyWith(
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.2,
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                        // Punto de "te necesita": la señal de atención del
                        // mockup, sin robarle sitio al título.
                        if (!streamActive &&
                            status.phase ==
                                SessionLivePhase.waitingForUser) ...[
                          const SizedBox(width: 7),
                          // TalkBack reads what the dot means (audit 2.1).
                          Semantics(
                            label: sessionLiveStatusLabel(strings, status),
                            child: Container(
                              key: ValueKey('session-attention-${session.id}'),
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: colors.warning,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ],
                        if (showUnread && timeInPreview) ...[
                          const SizedBox(width: 7),
                          unreadDot,
                        ],
                        if (session.isJob) ...[
                          const SizedBox(width: 7),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: colors.accent.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              strings.slReportBadge,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: colors.accent,
                              ),
                            ),
                          ),
                        ],
                        if (pinned) ...[
                          const SizedBox(width: 7),
                          Icon(
                            Icons.push_pin,
                            size: 13,
                            color: colors.textDisabled,
                          ),
                        ],
                      ],
                    ),
                    if (streamActive)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Semantics(
                          container: true,
                          excludeSemantics: true,
                          label: activityLabel,
                          // The state is told once, here: a ring turning
                          // beside its text, not a dot before the title.
                          child: Row(
                            children: [
                              HermesWorkingRing(
                                key: ValueKey(
                                  'session-live-ring-${session.id}',
                                ),
                                color: liveTone,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                // Smaller and lighter than the title, in the
                                // state's own colour (it used to be the
                                // title's white).
                                child: Text(
                                  activityLabel,
                                  key: ValueKey(
                                    'session-running-${session.id}',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: HermesType.support.copyWith(
                                    height: 1.25,
                                    fontWeight: FontWeight.w500,
                                    color: liveTone,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else if (highlights != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: previewLine(
                          Text.rich(
                            TextSpan(
                              children: [
                                for (final span in highlights)
                                  TextSpan(
                                    text: span.text,
                                    style: span.highlighted
                                        ? TextStyle(
                                            fontWeight: FontWeight.w700,
                                            color: colors.textPrimary,
                                          )
                                        : null,
                                  ),
                              ],
                            ),
                            key: ValueKey('session-snippet-${session.id}'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: previewStyle,
                          ),
                        ),
                      )
                    else if (previewText.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: previewLine(
                          Text(
                            previewText,
                            key: session.hasLocalDraft
                                ? ValueKey('session-draft-${session.id}')
                                : null,
                            // Ola 8: two lines once the text is enlarged.
                            maxLines: labelMaxLines(context),
                            overflow: TextOverflow.ellipsis,
                            style: previewStyle,
                          ),
                        ),
                      )
                    else if (timeInPreview)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          formattedTime,
                          key: ValueKey('session-time-${session.id}'),
                          maxLines: 1,
                          style: timeStyle,
                        ),
                      ),
                  ],
                ),
              ),
              if (onStop != null) ...[
                const SizedBox(width: 8),
                SessionRowStopControl(onStop: onStop!),
              ],
              if (onShow != null) ...[
                const SizedBox(width: 12),
                TextButton.icon(
                  key: ValueKey('session-show-${session.id}'),
                  onPressed: onShow,
                  icon: const Icon(Icons.visibility_outlined, size: 18),
                  label: Text(strings.slHiddenShowAction),
                ),
              ] else if (!timeInPreview) ...[
                const SizedBox(width: 12),
                // The time at the end of the row and, under it, the unread
                // dot.
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(formattedTime, style: timeStyle),
                    if (showUnread) ...[const SizedBox(height: 6), unreadDot],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _sentenceCase(String value) =>
    value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';

/// Separador "·" del pie del tile (modelo · tiempo).

/// Tiempo relativo localizado para los tiles ("2h ago", "ahora", "14/6").
String _relativeTime(double ts, Strings s) => formatSessionRelativeTime(ts, s);

typedef _FilterKey = (
  List<Session>,
  List<Session>?,
  int,
  SessionArchive?,
  int?,
  String,
  SessionCategory,
  bool,
  Locale,
  SessionListSort,
  String?,
);

/// Detail pane of an expanded window before any conversation is opened.
class _ChatPanePlaceholder extends StatelessWidget {
  const _ChatPanePlaceholder();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return ColoredBox(
      color: Theme.of(context).hermes.background,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.forum_outlined, size: 40, color: colors.textSecondary),
              const SizedBox(height: 12),
              Text(
                Strings.of(context).tabletPickConversation,
                key: const ValueKey('chat-pane-placeholder'),
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The list of chats with its own header, beside a chat (mock 134): the
/// header covers the list only. The list starts under it, so it takes no
/// status bar inset of its own.
class _ListColumn extends StatelessWidget {
  const _ListColumn({
    required this.header,
    required this.selectedId,
    required this.child,
  });

  final PreferredSizeWidget header;

  /// The conversation open beside the list.
  final String? selectedId;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(
        height: MediaQuery.paddingOf(context).top + header.preferredSize.height,
        child: header,
      ),
      Expanded(
        // the owner (ronda Fold 2): the list scrolls under a phone's floating
        // header without clipping; here the header is the column's own, so
        // the rows stopped at its edge would paint over its round buttons.
        child: ClipRect(
          key: const ValueKey('session-list-column-body'),
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: _WideListScope(selectedId: selectedId, child: child),
          ),
        ),
      ),
    ],
  );
}

/// The list as the column beside the chat on a wide window (mock 134 state
/// A), and the conversation open beside it. Its rows sit on the page's own
/// background like the chat, and titles take two lines.
class _WideListScope extends InheritedWidget {
  const _WideListScope({required this.selectedId, required super.child});

  final String? selectedId;

  static _WideListScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_WideListScope>();

  @override
  bool updateShouldNotify(_WideListScope oldWidget) =>
      oldWidget.selectedId != selectedId;
}
