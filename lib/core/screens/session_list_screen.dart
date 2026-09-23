import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../models/session_category.dart';
import '../models/desktop_active_session.dart';
import '../models/desktop_control_center.dart';
import '../models/session_activity.dart';
import '../navigation/chat_route.dart';
import '../services/active_chat_service.dart';
import '../services/connection_manager.dart';
import '../services/connection_health_tracker.dart';
import '../services/dock_preferences_store.dart';
import '../services/global_activity_aggregate.dart';
import '../services/chat_draft_store.dart';
import '../services/drawer_gesture_exclusion.dart';
import '../services/session_archive.dart';
import '../services/session_deletion.dart';
import '../services/session_repository.dart';
import '../services/tui_gateway_client.dart';
import '../utils/home_recent_sessions.dart';
import '../utils/session_timestamp.dart';
import '../theme/app_theme.dart';
import '../widgets/accent_card.dart';
import '../widgets/general_dock_shell.dart';
import '../widgets/hermes_drawer.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/read_only.dart';
import '../widgets/session_deletion_dialogs.dart';
import '../widgets/session_title_editor_route.dart';
import '../widgets/session_row_stop_control.dart';
import 'chat_screen.dart';
import 'mission_control_screen.dart';
import 'session_detail_screen.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/session_status_tone.dart';

const sessionLibraryRefreshGap = Duration(seconds: 10);
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
  final SavedConnection connection;
  final ConnectionManager connManager;
  final ApiClient? clientOverride;
  final SessionRepository? repositoryOverride;
  final Stream<TuiGatewayEvent>? eventStreamOverride;
  final ActiveChatService? activeChatsOverride;
  final GlobalActivityAggregate? globalActivityOverride;
  final Future<DesktopActiveSessionList> Function()? activeSessionListLoader;
  final Future<void> Function()? eventReconnectOverride;
  final double Function()? eventReconnectRandomOverride;
  const SessionListScreen({
    required this.connection,
    required this.connManager,
    @visibleForTesting this.clientOverride,
    @visibleForTesting this.repositoryOverride,
    @visibleForTesting this.eventStreamOverride,
    @visibleForTesting this.activeChatsOverride,
    @visibleForTesting this.globalActivityOverride,
    @visibleForTesting this.activeSessionListLoader,
    @visibleForTesting this.eventReconnectOverride,
    @visibleForTesting this.eventReconnectRandomOverride,
    super.key,
  });

  @override
  State<SessionListScreen> createState() => _SessionListScreenState();
}

class _SessionListScreenState extends State<SessionListScreen>
    with WidgetsBindingObserver, RouteAware {
  late final ApiClient _client;
  late final SessionRepository? _repository;
  late final bool _ownsRepository;
  TuiGatewayClient? _ownedActivityClient;
  StreamSubscription<TuiGatewayEvent>? _eventSubscription;
  StreamSubscription<HistoryCleanupInvalidation>? _historyCleanupSubscription;
  StreamSubscription<ChatDraftChange>? _draftSubscription;
  Timer? _eventRefreshTimer;
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
  String? _error;
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
  SessionCategory _activeCategory = SessionCategory.chats;
  bool _showArchived = false;

  SessionArchive? _archive;
  SessionPinSync? _pinSync;
  bool _archiveReady = false;

  /// Servicio singleton de chats activos: observamos [ActiveChatService.activeIds]
  /// para pintar el indicador de "chat ejecutándose en segundo plano".
  ActiveChatService? _activeChats;
  GlobalActivityAggregate? _globalActivity;
  PageRoute<dynamic>? _route;
  // Fallback estable (sin chats activos) mientras se resuelve el servicio, para
  // no crear un ValueNotifier nuevo en cada build.
  final ValueNotifier<Set<String>> _noActiveChats = ValueNotifier<Set<String>>(
    const {},
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _activeChats ??=
        widget.activeChatsOverride ??
        context.findAncestorStateOfType<HermesAppState>()?.activeChats;
    _globalActivity ??=
        widget.globalActivityOverride ?? _activeChats?.globalActivity;
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
    unawaited(_fetchSessions(showLoader: false));
  }

  @override
  void didPushNext() => unawaited(DrawerGestureExclusion.setEnabled(false));

  @override
  void didPop() => unawaited(DrawerGestureExclusion.setEnabled(false));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _eventReconnectBackoff = GatewayReconnectBackoff(
      random: widget.eventReconnectRandomOverride,
    );
    _sessionSafetyTimer = Timer.periodic(
      sessionLibrarySafetyRefreshInterval,
      (_) {
        if (_libraryRefreshAllowed) unawaited(_fetchSessions(showLoader: false));
      },
    );
    _activeChats = widget.activeChatsOverride;
    _globalActivity = widget.globalActivityOverride;
    _client =
        widget.clientOverride ??
        ApiClient(
          baseUrl: widget.connection.baseUrl,
          apiKey: widget.connection.apiKey,
          connectionId: widget.connection.id,
        );
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
      final activityClient = TuiGatewayClient(widget.connection);
      _ownedActivityClient = activityClient;
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
    _loadPrefs();
    _checkHealth();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final archive = await SessionArchive.load(prefs, widget.connection.id);
    if (!mounted) return;
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
    setState(() {
      _archive = archive;
      _pinSync = pinSync;
      _archiveReady = true;
    });
    await _migrateLineagePreferences(_sessions);
    await pinSync.updateSessions(_sessions);
    if (mounted) setState(() {});
  }

  bool get _libraryRefreshAllowed =>
      mounted && _foreground && _route?.isCurrent != false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _checkHealth();
      _scheduleEventReconnect(immediate: true);
    } else {
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

  Future<void> _checkHealth() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!mounted) return;
    final generation = _health.beginProbe();
    setState(() {});
    final ok = await _client.healthCheck();
    if (!mounted || !_health.recordResult(generation, healthy: ok)) return;
    setState(() {});
    if (ok) {
      _fetchSessions();
      unawaited(_refreshRemoteActivity());
    } else {
      await _showLocalDrafts();
      _retryTimer = Timer(_health.retryDelay, _checkHealth);
    }
  }

  Future<List<Session>> _draftSessions({String? profile}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = await ChatDraftStore(
        prefs,
      ).listForConnection(widget.connection.id);
      if (!mounted) return const [];
      final fallback = Strings.of(context).drawerNewChat;
      final owner = Session.profileOwner(profile);
      return entries
          .where((entry) => Session.profileOwner(entry.profile) == owner)
          .map((entry) => entry.toSession(fallbackTitle: fallback))
          .toList();
    } catch (e) {
      debugPrint('[session-list] no se pudieron listar borradores: $e');
      return const [];
    }
  }

  Future<void> _showLocalDrafts() async {
    final fetchEpoch = _sessionFetchEpoch;
    final scope = _libraryQuery;
    final drafts = await _draftSessions(profile: scope.profile);
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
      _sessions = mergeRemoteSessionsWithDrafts(visibleRemote, drafts)
        ..sort(compareSessionsByRecentActivity);
      _loading = false;
      _error = null;
    });
  }

  @override
  void dispose() {
    hermesRouteObserver.unsubscribe(this);
    unawaited(DrawerGestureExclusion.setEnabled(false));
    _retryTimer?.cancel();
    _searchTimer?.cancel();
    _eventRefreshTimer?.cancel();
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
    unawaited(_ownedActivityClient?.close());
    _client.close();
    _noActiveChats.dispose();
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
      if (await _refreshRemoteActivity()) {
        _eventReconnectBackoff.markHealthy();
      }
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
      unawaited(_refreshRemoteActivity());
    } else if (routed) {
      _recoveringTransport = false;
    }
    if (!isSessionLibraryRefreshEvent(event)) return;
    _sessionChangeEpoch += 1;
    if (!_foreground) return;
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
      if (mounted && _foreground) unawaited(_refreshFromSessionEvent());
    });
  }

  Future<bool> _refreshRemoteActivity() async {
    final aggregate = _globalActivity;
    final loader =
        widget.activeSessionListLoader ??
        (_ownedActivityClient == null
            ? null
            : () => _ownedActivityClient!.listActiveSessions());
    if (aggregate == null || loader == null) return false;
    final profile = Session.profileOwner(_libraryQuery.profile);
    final generation = aggregate.beginRosterRequest(
      widget.connection.id,
      profile,
    );
    try {
      final roster = await loader();
      if (!mounted) return false;
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
      if (client != null && !roster.hasMalformedRows) {
        for (final row in roster.sessions) {
          final durable = row.storedSessionId;
          if (durable == null) continue;
          unawaited(
            _refreshProcessContinuity(
              aggregate: aggregate,
              client: client,
              scope: GlobalActivityScope(
                connectionId: widget.connection.id,
                profile: profile,
                durableSessionId: durable,
                runtimeSessionId: row.runtimeSessionId,
                replayEpoch: client.currentReplayEpoch,
              ),
            ),
          );
        }
      } else if (_recoveringTransport && !roster.hasMalformedRows) {
        for (final row in roster.sessions) {
          final durable = row.storedSessionId;
          if (durable == null) continue;
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
          );
        }
      }
      return true;
    } catch (_) {
      aggregate.markTransportStale(widget.connection.id, profile);
      _scheduleStaleExpiry();
      return false;
    }
  }

  Future<void> _refreshProcessContinuity({
    required GlobalActivityAggregate aggregate,
    required TuiGatewayClient client,
    required GlobalActivityScope scope,
  }) async {
    try {
      final snapshot = await client.agentCenterSnapshot(
        runtimeSessionId: scope.runtimeSessionId,
      );
      if (!mounted || !snapshot.processesFullyParsed) {
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
        );
      } else {
        aggregate.applyProcessList(
          scope: scope,
          activeProcessCount: activeProcessCount,
        );
      }
    } catch (_) {
      // Optional/legacy process.list cannot erase the last proven state.
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
      await _refreshRemoteActivity();
    }
  }

  Future<void> _refreshSessionsAndActivity() async {
    await _fetchSessions();
    await _refreshRemoteActivity();
  }

  // ── Data fetching ────────────────────────────────────────────────────────

  SessionLibraryQuery get _libraryQuery => SessionLibraryQuery(
    pageSize: 50,
    archived: _showArchived
        ? SessionArchiveMode.only
        : SessionArchiveMode.exclude,
    order: SessionLibraryOrder.recent,
    sources: _activeCategory.sources,
    excludeSources: _activeCategory.excludeSources,
    profile: widget.connManager.activeProfileFor(widget.connection.id),
  );

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
      _searching = query.isNotEmpty && _repository != null;
      _searchExhaustive = query.isEmpty || _repository == null;
    });
    // Categoría y archivo se resuelven en Agent antes de limit/offset. La
    // búsqueda se reinicia con el mismo scope para invalidar respuestas de la
    // categoría anterior aunque el texto no haya cambiado.
    unawaited(_fetchSessions());
    if (query.isNotEmpty && _repository != null) {
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

  Future<void> _loadNextPage() async {
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
        await _draftSessions(profile: scope.profile),
      );
      if (scope.fingerprint != _libraryQuery.fingerprint) return;
      await _migrateLineagePreferences(merged);
      await _pinSync?.updateSessions(merged, readFence: pinReadFence);
      if (!mounted) return;
      final sorted = merged.toList()..sort(compareSessionsByRecentActivity);
      setState(() {
        _sessions = sorted;
        _librarySource = snapshot.source;
        _libraryExhaustive = snapshot.exhaustive;
      });
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

  void _onSearchChanged(String value) {
    _searchTimer?.cancel();
    final query = value.trim();
    final requestEpoch = ++_searchRequestEpoch;
    setState(() {
      _searchQuery = value;
      _searchResults = null;
      _searching = query.isNotEmpty && _repository != null;
      _searchExhaustive = query.isEmpty || _repository == null;
    });
    if (query.isEmpty || _repository == null) return;
    _searchTimer = Timer(const Duration(milliseconds: 220), () {
      unawaited(_runSearch(query, requestEpoch, _libraryQuery));
    });
  }

  Future<void> _runSearch(
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
      final matchingDrafts = (await _draftSessions(profile: scope.profile))
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
      setState(() {
        _searchResults = sessions;
        _searchExhaustive = result.exhaustive;
        _searching = false;
      });
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

  Future<bool> _fetchSessions({bool showLoader = true}) async {
    // Puede invocarse desde un closure del drawer después de que la pantalla se
    // haya desmontado (HermesDrawer._go) → setState() after dispose(). Guard.
    if (!mounted) return false;
    final fetchEpoch = ++_sessionFetchEpoch;
    final invalidationEpoch = _appliedSessionChangeEpoch < _sessionChangeEpoch
        ? _sessionChangeEpoch
        : null;
    final previousSessions = List<Session>.of(_sessions);
    if (showLoader || _sessions.isEmpty) {
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
        await _draftSessions(profile: scope.profile),
      );
      if (scope.fingerprint != _libraryQuery.fingerprint ||
          fetchEpoch != _sessionFetchEpoch) {
        return false;
      }
      await _migrateLineagePreferences(sessions);
      await _pinSync?.updateSessions(sessions, readFence: pinReadFence);

      // Hermes Agent no publica `include_children` en este endpoint. La
      // biblioteca promete solo sesiones principales y filtra defensivamente
      // cualquier hija que devuelva un servidor legacy o intermediario.
      final visible = sessions.where(
        (s) => s.parentSessionId == null || s.parentSessionId!.isEmpty,
      );

      final sorted = visible.toList()..sort(compareSessionsByRecentActivity);

      if (!mounted || fetchEpoch != _sessionFetchEpoch) return false;
      setState(() {
        _sessions = sorted;
        _librarySource = library?.source ?? SessionLibrarySource.gateway;
        _libraryExhaustive = library?.exhaustive ?? false;
        _loading = false;
      });
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
          _error = e.toString();
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
      await _showLocalDrafts();
      return false;
    }
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
      _archive?.titleForSession(session) ?? session.displayTitle;

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
    HermesNotice.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        content: Text(
          localOnly
              ? (archived
                    ? strings.slArchivedLocalOnly
                    : strings.slRestoredLocalOnly)
              : (archived ? strings.slArchived : strings.slRestored),
        ),
      ),
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
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).slRenameEmpty)),
        kind: HermesNoticeKind.warning,
      );
      return;
    }

    await _archive!.setSessionTitle(session, trimmed);
    if (!mounted) return;
    setState(() {});
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(Strings.of(context).slRenamed)),
      kind: HermesNoticeKind.success,
    );
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
      });
      _showArchiveResult(archived, localOnly: false);
    } on DashboardHttpException catch (error) {
      final unsupported = error.statusCode == 404 || error.statusCode == 405;
      if (unsupported && (archived || !session.archived)) {
        await _setLocalArchived(session, archived);
        if (!mounted) return;
        setState(() {
          _pendingArchiveByLogicalId.remove(session.logicalId);
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
    });
    await _fetchSessions();
    if (!mounted) return;
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(Strings.of(context).slArchiveSyncFailed)),
      kind: HermesNoticeKind.error,
    );
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
      loadSessions: ({bool includeChildren = false}) => _client.getSessions(
        includeChildren: includeChildren,
        profile: ownerProfile,
      ),
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
      final colors = Theme.of(context).hermes;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(Strings.of(context).slDeleteTitle),
          content: Text(
            Strings.of(context).slDeleteContent(_titleFor(session)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(Strings.of(context).slCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                Strings.of(context).slDeleteConfirm,
                style: TextStyle(color: colors.error),
              ),
            ),
          ],
        ),
      );
      if (confirm != true) return false;
    }

    final result = await _deleteSessionAndLinkedCron(session, cronDeletion);
    switch (result.status) {
      case LinkedSessionDeleteStatus.deleted:
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
          HermesNotice.of(context).showSnackBar(
            SnackBar(
              content: Text(
                sessionDeletionFailureMessage(Strings.of(context), result),
              ),
            ),
            kind: HermesNoticeKind.error,
          );
        }
        return false;
      case LinkedSessionDeleteStatus.sessionDeleteFailed:
        if (mounted) {
          HermesNotice.of(context).showSnackBar(
            SnackBar(
              content: Text(
                sessionDeletionFailureMessage(Strings.of(context), result),
              ),
            ),
            kind: HermesNoticeKind.error,
          );
        }
        return false;
    }
  }

  /// El servidor respondió OK pero no borró la sesión (suele ser una sesión de
  /// un canal activo que se recrea). Ofrece ocultarla localmente — honesto.
  void _offerHideAfterFailedDelete(Session session, {String? message}) {
    final messenger = HermesNotice.of(context);
    final s = Strings.of(context);
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 5),
        content: Text(message ?? s.slOfferHideContent),
        action: SnackBarAction(
          label: s.slHideAction,
          onPressed: () async {
            await _archive?.hideSession(session);
            if (mounted) setState(() {});
          },
        ),
      ),
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
      _sessions.removeWhere((row) => !retained(row));
      _searchResults = _searchResults?.where(retained).toList();
      _searching = false;
    });
  }

  void _createNewSession() {
    final sessionId = GatewayChatClient.generateSessionId();
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
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).chaStopFailed)),
        kind: HermesNoticeKind.error,
      );
      return;
    }
    try {
      final result = await activeChats.stopSessionWork(
        connection: widget.connection,
        session: session,
      );
      if (!result.allBackgroundWorkStopped && mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Strings.of(
                context,
              ).chaBackgroundWorkRemaining(result.remainingBackgroundTasks),
            ),
          ),
          kind: HermesNoticeKind.warning,
        );
      }
    } catch (_) {
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).chaStopFailed)),
        kind: HermesNoticeKind.error,
      );
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
    final deleted = await openChatFromSection<bool>(
      context,
      builder: (_) =>
          ChatScreen(connection: widget.connection, session: session),
    );
    if (deleted == true && mounted) {
      _evictDeletedSessions([session]);
    }
  }

  Future<void> _openDetail(Session session) async {
    final deleted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => SessionDetailScreen(
          connection: widget.connection,
          session: session,
        ),
      ),
    );
    if (!mounted) return;
    if (deleted == true) {
      _evictDeletedSessions([session]);
    } else {
      // El detalle puede haber ramificado o reanudado: refrescar barato.
      _fetchSessions();
    }
  }

  // ── Context menu ─────────────────────────────────────────────────────────

  Future<void> _showSessionContextMenu(Session session) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final archived = _isArchived(session);
    final pinned = _isPinned(session);
    final hidden = _isHidden(session);
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
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(s.slMenuDetails),
              onTap: () {
                Navigator.pop(ctx);
                _openDetail(session);
              },
            ),
            ListTile(
              leading: Icon(
                hidden
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
              title: Text(hidden ? s.slMenuShow : s.slMenuHide),
              subtitle: hidden
                  ? null
                  : Text(
                      s.sesClearViewNote,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).hermes.textDisabled,
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
                HermesNotice.of(context).showSnackBar(
                  SnackBar(content: Text(Strings.of(context).slIdCopied)),
                  kind: HermesNoticeKind.success,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── Filtering ────────────────────────────────────────────────────────────

  List<Session> get _filteredSessions {
    final query = _searchQuery.trim().toLowerCase();
    final source = query.isNotEmpty && _repository != null
        ? (_searchResults ?? const <Session>[])
        : _sessions;

    final list = source.where((s) {
      // Las ocultas localmente nunca aparecen (se restauran desde "limpiar").
      if (_isHidden(s)) return false;

      final archived = _isArchived(s);
      if (_showArchived != archived) return false;
      if (!_activeCategory.includesSource(s.source)) return false;

      // Apply search query
      if (query.isEmpty || _repository != null) return true;
      return _titleFor(s).toLowerCase().contains(query) ||
          s.preview.toLowerCase().contains(query);
    }).toList();

    // Las fijadas suben al principio en cualquier categoría no archivada
    // (archivar desfija). El resto conserva el orden por actividad.
    if (!_showArchived) {
      list.sort((a, b) {
        final pa = _isPinned(a) ? 0 : 1;
        final pb = _isPinned(b) ? 0 : 1;
        if (pa != pb) return pa - pb;
        return compareSessionsByRecentActivity(a, b);
      });
    }
    return list;
  }

  /// Intercala cabeceras de sección entre las sesiones (Fijadas / Hoy / Ayer /
  /// Últimos 7 días / Anteriores) y marca la posición de cada fila dentro de su
  /// sección.
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
      return card(str.slFilterArchived, sessions, first: true);
    }
    final pinned = <Session>[];
    final rest = <Session>[];
    for (final s in sessions) {
      (_isPinned(s) ? pinned : rest).add(s);
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final week = today.subtract(const Duration(days: 6));
    String bucketOf(Session s) {
      final d = DateTime.fromMillisecondsSinceEpoch(
        (s.lastActivityAt * 1000).round(),
      );
      final day = DateTime(d.year, d.month, d.day);
      if (!day.isBefore(today)) return str.sesDateToday;
      if (!day.isBefore(yesterday)) return str.sesDateYesterday;
      if (!day.isBefore(week)) return str.sesDateLast7;
      return str.sesDateOlder;
    }

    final out = <Object>[];
    out.addAll(card(str.sesPinned, pinned, first: true));
    // Agrupa por día conservando el orden por actividad que ya trae la lista.
    final buckets = <String, List<Session>>{};
    final order = <String>[];
    for (final s in rest) {
      final bucket = bucketOf(s);
      final rows = buckets.putIfAbsent(bucket, () {
        order.add(bucket);
        return <Session>[];
      });
      rows.add(s);
    }
    for (final label in order) {
      out.addAll(card(label, buckets[label]!, first: out.isEmpty));
    }
    return out;
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: HermesAppBar(
        automaticallyImplyLeading: false,
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: Icon(Icons.menu, color: colors.textSecondary),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
            tooltip: s.slMenuTooltip,
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              s.drawerSessions,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 1),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ConnectionDot(
                  connected: _health.healthy,
                  checking: _health.checking,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    widget.connection.label.isNotEmpty
                        ? widget.connection.label
                        : widget.connection.host,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                ),
                if (widget.connection.readOnly) ...[
                  const SizedBox(width: 6),
                  const ReadOnlyBadge(compact: true),
                ],
              ],
            ),
          ],
        ),
        centerTitle: false,
        titleSpacing: 0,
        actions: [
          IconButton(
            icon: Icon(Icons.edit_square, color: colors.textPrimary),
            onPressed: _createNewSession,
            tooltip: s.slNewSession,
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: colors.textSecondary),
            tooltip: s.slMoreOptions,
            onSelected: (value) {
              switch (value) {
                case 'refresh':
                  if (!_loading) _fetchSessions();
              }
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'refresh',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.refresh),
                  title: Text(s.slMenuRefresh),
                ),
              ),
            ],
          ),
        ],
      ),
      drawerEnableOpenDragGesture: true,
      drawerEdgeDragWidth: HermesDrawer.edgeDragWidth(context),
      drawer: HermesDrawer(
        connection: widget.connection,
        connManager: widget.connManager,
        current: DrawerSection.sessions,
        connected: _health.healthy,
        checking: _health.checking,
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
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    if (_health.checking && !_health.healthy) {
      return _ConnectingState(host: widget.connection.host);
    }

    if (!_health.healthy) {
      return _ConnectionIssueState(
        baseUrl: widget.connection.baseUrl,
        onRetry: _checkHealth,
      );
    }

    if (_loading || !_archiveReady) {
      return const Center(child: TuiLoader());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: colors.warning),
            const SizedBox(height: 16),
            Text(
              s.slConnectionError,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _fetchSessions,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(s.slRetry),
            ),
          ],
        ),
      );
    }

    final filtered = _filteredSessions;
    // Entradas intercaladas con cabeceras de fecha (estilo Claude: Hoy / Ayer…).
    final entries = _groupedEntries(filtered);

    return Column(
      children: [
        _buildSearchField(),
        _buildFilterControl(),
        if (_searching)
          LinearProgressIndicator(
            minHeight: 1,
            color: colors.accent,
            backgroundColor: Colors.transparent,
          )
        else if (_searchQuery.trim().isNotEmpty && !_searchExhaustive)
          _LibraryScopeNotice(text: s.slSearchLoadedOnly),
        Expanded(
          child: RefreshIndicator(
            color: colors.accent,
            onRefresh: _refreshSessionsAndActivity,
            child: filtered.isEmpty
                ? (_searching
                      ? const Center(child: TuiLoader())
                      : _FilteredEmptyState(
                          archived: _showArchived,
                          automation:
                              _activeCategory == SessionCategory.automation,
                          searching: _searchQuery.isNotEmpty,
                          onCreateNew:
                              !_showArchived &&
                                  _searchQuery.trim().isEmpty &&
                                  _activeCategory != SessionCategory.automation
                              ? _createNewSession
                              : null,
                        ))
                : ListenableBuilder(
                    listenable: Listenable.merge([
                      _activeChats?.activeIds ?? _noActiveChats,
                      ?_globalActivity,
                      // La reserva inferior depende de si el dock está
                      // activado (interruptor global de Ajustes).
                      DockPreferencesController.instance.listenable,
                    ]),
                    builder: (context, _) => ListView.builder(
                      controller: _libraryScrollController,
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
                            child: Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
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
                          child: _sessionRow(session, s, colors),
                        );
                      },
                    ),
                  ),
          ),
        ),
      ],
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
    final localActivity = _localChatForSession(session)?.sessionActivity;
    final streamActive =
        localActivity?.active == true ||
        (_globalActivity?.isActive(
              widget.connection.id,
              Session.profileOwner(session.profile),
              session.id,
            ) ??
            false) ||
        (_globalActivity?.isActive(
              widget.connection.id,
              Session.profileOwner(session.profile),
              session.logicalId,
            ) ??
            false);
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
        title: _titleFor(session),
        formattedTime: _relativeTime(session.lastActivityAt, s),
        pinned: pinned,
        activity: _globalForSession(session),
        localActivity: localActivity,
        // Una compactación enciende la fila (punto + "Compactando") pero no
        // ofrece "Detener": no es un turno que se pueda parar.
        streamActive: streamActive || localActivity?.compacting == true,
        onStop: streamActive ? () => _stopSession(session) : null,
        onTap: () => _openChat(session),
        onLongPress: () => _showSessionContextMenu(session),
      ),
    );
  }

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: HermesSearchField(
        onChanged: _onSearchChanged,
        hintText: Strings.of(context).slSearchHint,
        clearTooltip: Strings.of(context).slClearSearch,
      ),
    );
  }

  Widget _buildFilterControl() {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
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
    final archiveButton = Semantics(
      button: true,
      selected: _showArchived,
      label: s.slFilterArchived,
      child: Tooltip(
        message: s.slFilterArchived,
        child: IconButton(
          key: const ValueKey('session-filter-archived'),
          onPressed: _toggleArchived,
          icon: const Icon(Icons.inventory_2_outlined, size: 20),
          color: _showArchived ? colors.textPrimary : colors.textSecondary,
          style: IconButton.styleFrom(
            minimumSize: const Size(50, 50),
            backgroundColor: _showArchived
                ? colors.surface
                : colors.surfaceVariant.withValues(alpha: 0.46),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 410) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(width: double.infinity, child: categories),
                const SizedBox(height: 6),
                archiveButton,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: categories),
              const SizedBox(width: 8),
              archiveButton,
            ],
          );
        },
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
    ? 48 + 12 + 6 + MediaQuery.paddingOf(context).bottom
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
    // La cabecera respira sobre su tarjeta y separa secciones sin necesidad de
    // una caja propia.
    return Semantics(
      header: true,
      child: Padding(
        padding: EdgeInsets.fromLTRB(4, header.first ? 6 : 26, 4, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                header.label.toUpperCase(),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                  color: colors.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${header.count}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: colors.textDisabled,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Una fila dentro de la tarjeta redondeada de su sección: redondea solo los
/// extremos y dibuja el separador fino salvo en la última.
class _SessionCardRow extends StatelessWidget {
  final bool first;
  final bool last;
  final Widget child;

  const _SessionCardRow({
    required this.first,
    required this.last,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final radius = Radius.circular(
      Theme.of(context).hermesComponents.profile.shape.groupRadius,
    );
    final shape = BorderRadius.vertical(
      top: first ? radius : Radius.zero,
      bottom: last ? radius : Radius.zero,
    );
    return DecoratedBox(
      decoration: BoxDecoration(color: colors.surface, borderRadius: shape),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // El recorte mantiene el deslizamiento dentro de las esquinas
          // redondeadas de la tarjeta.
          ClipRRect(borderRadius: shape, child: child),
          if (!last)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Divider(
                height: 1,
                thickness: 1,
                color: colors.divider.withValues(alpha: 0.55),
              ),
            ),
        ],
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

/// Punto "en vivo" con anillo que se expande: la conversación está corriendo
/// ahora mismo. El anillo se apaga cuando el sistema pide reducir movimiento.
class _LiveDot extends StatefulWidget {
  final Color color;

  const _LiveDot({required this.color, super.key});

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  AnimationController? _ring;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion) {
      _ring?.dispose();
      _ring = null;
      return;
    }
    _ring ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _ring?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    );
    final ring = _ring;
    if (ring == null) return dot;
    return SizedBox(
      width: 8,
      height: 8,
      child: AnimatedBuilder(
        animation: ring,
        builder: (context, child) {
          final t = Curves.easeOut.transform(ring.value);
          return Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Transform.scale(
                scale: 1 + 1.6 * t,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: widget.color.withValues(alpha: 0.55 * (1 - t)),
                      width: 1.5,
                    ),
                  ),
                ),
              ),
              ?child,
            ],
          );
        },
        child: dot,
      ),
    );
  }
}

/// Empty state contextual para cuando hay sesiones pero el filtro/búsqueda
/// las deja fuera.
class _FilteredEmptyState extends StatelessWidget {
  final bool archived;
  final bool automation;
  final bool searching;
  final VoidCallback? onCreateNew;

  const _FilteredEmptyState({
    required this.archived,
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
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: HermesEmptyState(
            compact: true,
            icon: icon,
            title: title,
            body: subtitle,
            primaryLabel: onCreateNew == null ? null : s.drawerNewChat,
            primaryIcon: Icons.edit_square,
            onPrimary: onCreateNew,
          ),
        ),
      ),
    );
  }
}

class _ConnectionDot extends StatelessWidget {
  final bool connected;
  final bool checking;

  const _ConnectionDot({required this.connected, required this.checking});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final color = checking
        ? colors.accent
        : connected
        ? colors.success
        : colors.error;
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
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
                    'connecting to ${widget.host}$dots',
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
                color: colors.textDisabled,
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
  final String title;
  final String formattedTime;
  final bool pinned;

  /// Hay un stream del chat en curso en segundo plano para esta sesión: la
  /// respuesta/ejecución sigue aunque saliste. Cuenta como "viva".
  final bool streamActive;
  final GlobalActivity? activity;
  final SessionActivity? localActivity;
  final Future<void> Function()? onStop;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _SessionTile({
    required this.session,
    required this.title,
    required this.formattedTime,
    this.pinned = false,
    this.streamActive = false,
    this.activity,
    this.localActivity,
    this.onStop,
    required this.onTap,
    required this.onLongPress,
  });

  /// Semantic state of the live row: the dot and the status line share its
  /// colour (green working, calm tint compacting, amber waiting, error
  /// failed, muted stale/idle), so the status never reads like the title.
  SessionStatusTone get _statusTone {
    final local = localActivity;
    if (local != null && local.showsActivity) {
      return sessionStatusToneFor(local.kind, stale: local.stale);
    }
    final global = activity;
    if (global != null) return globalStatusToneFor(global);
    return SessionStatusTone.working;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final preview =
        sessionListPreview(session) ?? strings.sessionPreviewUnavailable;
    final activityLabel = localActivity?.showsActivity == true
        ? _sessionActivityLabel(strings, localActivity!)
        : activity != null
        ? _globalActivityLabel(strings, activity!)
        : strings.slRunningBadge;
    // El borrador se cuenta como texto descriptivo hilado en la línea de
    // vista previa ("Borrador · Resume los cambios…"), no como una píldora
    // de color aparte: es lo que pide el mockup y lo que evita las "cajitas".
    final draftLabel = _sentenceCase(strings.slDraftBadge);
    final previewText = session.hasLocalDraft
        ? <String>[draftLabel, if (preview.isNotEmpty) preview].join(' · ')
        : preview;
    final liveTone = sessionStatusColor(colors, _statusTone);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ConstrainedBox(
        // 64dp es el alto de fila del mockup y deja el objetivo táctil muy por
        // encima del mínimo de 44dp.
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (streamActive) ...[
                          _LiveDot(
                            key: ValueKey('session-live-dot-${session.id}'),
                            color: liveTone,
                          ),
                          const SizedBox(width: 8),
                        ],
                        Flexible(
                          child: Text(
                            title.isNotEmpty ? title : strings.slNoTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                              letterSpacing: -0.2,
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                        // Punto de "te necesita": la señal de atención del
                        // mockup, sin robarle sitio al título.
                        if (!streamActive &&
                            activity?.requiresAction == true) ...[
                          const SizedBox(width: 7),
                          Container(
                            key: ValueKey('session-attention-${session.id}'),
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: colors.warning,
                              shape: BoxShape.circle,
                            ),
                          ),
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
                          // Smaller and lighter than the title, in the state's
                          // own colour (it used to be the title's white).
                          child: Text(
                            activityLabel,
                            key: ValueKey('session-running-${session.id}'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.25,
                              fontWeight: FontWeight.w500,
                              color: liveTone,
                            ),
                          ),
                        ),
                      )
                    else if (previewText.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          previewText,
                          key: session.hasLocalDraft
                              ? ValueKey('session-draft-${session.id}')
                              : null,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.25,
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (onStop != null) ...[
                const SizedBox(width: 8),
                SessionRowStopControl(onStop: onStop!),
              ],
              const SizedBox(width: 12),
              Text(
                formattedTime,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: colors.textDisabled,
                ),
              ),
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

String _sessionActivityLabel(Strings strings, SessionActivity activity) =>
    switch (activity.kind) {
      SessionActivityKind.preparing => strings.slActivityPreparing,
      SessionActivityKind.generating => strings.slActivityGenerating,
      SessionActivityKind.usingTools => strings.slActivityUsingTools,
      SessionActivityKind.responding => strings.chaPipelineStreaming,
      SessionActivityKind.waitingForUser => strings.slActivityWaiting,
      SessionActivityKind.compacting => strings.slActivityCompacting,
      SessionActivityKind.delegated => strings.slActivityDelegated,
      SessionActivityKind.backgroundProcess => activity.backgroundItemCount > 0
          ? strings.chaBackgroundActivityCount(activity.backgroundItemCount)
          : strings.slActivityBackground,
      SessionActivityKind.idle => strings.slActivityUnknown,
    };

String _globalActivityLabel(Strings strings, GlobalActivity activity) {
  final phase = switch (activity.phase) {
    GlobalActivityPhase.preparing => strings.slActivityPreparing,
    GlobalActivityPhase.generating => strings.slActivityGenerating,
    GlobalActivityPhase.usingTools => strings.slActivityUsingTools,
    GlobalActivityPhase.delegated => strings.slActivityDelegated,
    GlobalActivityPhase.backgroundWork => strings.slActivityBackground,
    GlobalActivityPhase.compacting => strings.slActivityCompacting,
    GlobalActivityPhase.waitingForUser => strings.slActivityWaiting,
    GlobalActivityPhase.completing => strings.slActivityCompleting,
    GlobalActivityPhase.completed ||
    GlobalActivityPhase.interrupted ||
    GlobalActivityPhase.failed ||
    GlobalActivityPhase.unknown => strings.slActivityUnknown,
  };
  return activity.stale ? '$phase · ${strings.slActivityStale}' : phase;
}

/// Tiempo relativo localizado para los tiles ("2h ago", "ahora", "14/6").
String _relativeTime(double ts, Strings s) => formatSessionRelativeTime(ts, s);
