import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../models/session_category.dart';
import '../navigation/chat_route.dart';
import '../services/active_chat_service.dart';
import '../services/connection_manager.dart';
import '../services/connection_health_tracker.dart';
import '../services/chat_draft_store.dart';
import '../services/drawer_gesture_exclusion.dart';
import '../services/session_archive.dart';
import '../services/session_deletion.dart';
import '../services/session_repository.dart';
import '../services/tui_gateway_client.dart';
import '../utils/session_timestamp.dart';
import '../theme/app_theme.dart';
import '../widgets/accent_card.dart';
import '../widgets/hermes_drawer.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/read_only.dart';
import '../widgets/session_deletion_dialogs.dart';
import '../widgets/session_title_editor_route.dart';
import 'chat_screen.dart';
import 'session_detail_screen.dart';
import '../widgets/hermes_app_bar.dart';

@visibleForTesting
const sessionLibraryRefreshGap = Duration(seconds: 10);

@visibleForTesting
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
    byId[identity(session)] = session;
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

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

class SessionListScreen extends StatefulWidget {
  final SavedConnection connection;
  final ConnectionManager connManager;
  final ApiClient? clientOverride;
  final SessionRepository? repositoryOverride;
  final HermesDesktopSessionActivityGateway? activityGatewayOverride;
  final Stream<TuiGatewayEvent>? eventStreamOverride;
  const SessionListScreen({
    required this.connection,
    required this.connManager,
    @visibleForTesting this.clientOverride,
    @visibleForTesting this.repositoryOverride,
    @visibleForTesting this.activityGatewayOverride,
    @visibleForTesting this.eventStreamOverride,
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
  late final HermesDesktopSessionActivityGateway? _activityGateway;
  TuiGatewayClient? _ownedActivityClient;
  StreamSubscription<TuiGatewayEvent>? _eventSubscription;
  StreamSubscription<HistoryCleanupInvalidation>? _historyCleanupSubscription;
  Timer? _eventRefreshTimer;
  DateTime? _lastEventRefreshAt;
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
  Set<String> _remoteActiveSessionIds = const {};
  final Map<String, bool> _pendingArchiveByLogicalId = {};
  SessionCategory _activeCategory = SessionCategory.chats;
  bool _showArchived = false;

  SessionArchive? _archive;
  SessionPinSync? _pinSync;
  bool _archiveReady = false;

  /// Servicio singleton de chats activos: observamos [ActiveChatService.activeIds]
  /// para pintar el indicador de "chat ejecutándose en segundo plano".
  ActiveChatService? _activeChats;
  PageRoute<dynamic>? _route;
  // Fallback estable (sin chats activos) mientras se resuelve el servicio, para
  // no crear un ValueNotifier nuevo en cada build.
  final ValueNotifier<Set<String>> _noActiveChats = ValueNotifier<Set<String>>(
    const {},
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _activeChats ??= context
        .findAncestorStateOfType<HermesAppState>()
        ?.activeChats;
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
  void didPopNext() => unawaited(DrawerGestureExclusion.setEnabled(true));

  @override
  void didPushNext() => unawaited(DrawerGestureExclusion.setEnabled(false));

  @override
  void didPop() => unawaited(DrawerGestureExclusion.setEnabled(false));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    if (widget.activityGatewayOverride != null) {
      _activityGateway = widget.activityGatewayOverride;
    } else if (widget.clientOverride == null) {
      final activityClient = TuiGatewayClient(widget.connection);
      _ownedActivityClient = activityClient;
      _activityGateway = activityClient;
    } else {
      _activityGateway = null;
    }
    _startEventUpdates();
    _historyCleanupSubscription = historyCleanupInvalidations.events.listen(
      _onHistoryCleanupInvalidation,
    );
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _checkHealth();
      unawaited(_refreshRemoteActivity());
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
    final scope = _libraryQuery;
    final drafts = await _draftSessions(profile: scope.profile);
    if (scope.fingerprint != _libraryQuery.fingerprint) return;
    if (!mounted || drafts.isEmpty) return;
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
    unawaited(_eventSubscription?.cancel());
    unawaited(_historyCleanupSubscription?.cancel());
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
        // Refresh manual, lifecycle y estado conservado siguen disponibles.
      },
    );
    if (_ownedActivityClient != null) unawaited(_connectEventClient());
  }

  Future<void> _connectEventClient() async {
    final client = _ownedActivityClient;
    if (client == null || client.isConnected) return;
    try {
      await client.connect();
    } catch (_) {
      // Gateway legacy/offline: REST y refresh manual conservan su contrato.
    }
  }

  void _onSessionLibraryEvent(TuiGatewayEvent event) {
    if (!_foreground || !isSessionLibraryRefreshEvent(event)) return;
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
    // El snapshot activo es pequeño y actualiza el indicador enseguida; la
    // lista REST pesada queda agrupada al trailing edge oficial de 10 s.
    unawaited(_refreshRemoteActivity());
    _eventRefreshTimer ??= Timer(sessionLibraryRefreshGap - elapsed, () {
      _eventRefreshTimer = null;
      _lastEventRefreshAt = DateTime.now();
      if (mounted && _foreground) unawaited(_refreshFromSessionEvent());
    });
  }

  void _onHistoryCleanupInvalidation(HistoryCleanupInvalidation event) {
    if (!mounted ||
        !_foreground ||
        event.connectionId != widget.connection.id) {
      return;
    }
    unawaited(_refreshFromSessionEvent());
  }

  Future<void> _refreshFromSessionEvent() async {
    await _refreshRemoteActivity();
    if (mounted && _foreground) {
      await _fetchSessions(refreshRemoteActivity: false, showLoader: false);
    }
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

  Future<void> _refreshRemoteActivity() async {
    final activity = _activityGateway;
    if (activity == null) return;
    try {
      await _connectEventClient();
      final inventory = await activity.listActiveSessions();
      if (!mounted) return;
      final nextActiveIds = {
        for (final row in inventory.sessions)
          if (row.status == 'working' || row.status == 'waiting')
            ?row.storedSessionId,
      };
      if (setEquals(nextActiveIds, _remoteActiveSessionIds)) return;
      setState(() {
        _remoteActiveSessionIds = nextActiveIds;
      });
    } catch (_) {
      // Un fallo no prueba que las sesiones terminaran: conserva el último set.
    }
  }

  bool _isRemoteActive(Session session) =>
      _remoteActiveSessionIds.contains(session.id) ||
      _remoteActiveSessionIds.contains(session.logicalId) ||
      (session.parentSessionId != null &&
          _remoteActiveSessionIds.contains(session.parentSessionId));

  bool _isLocalActive(Session session) {
    final activeChats = _activeChats;
    if (activeChats == null) return false;
    return activeChats.isActive(
          widget.connection.id,
          session.id,
          profile: session.profile,
        ) ||
        activeChats.isActive(
          widget.connection.id,
          session.logicalId,
          profile: session.profile,
        ) ||
        (session.parentSessionId != null &&
            activeChats.isActive(
              widget.connection.id,
              session.parentSessionId!,
              profile: session.profile,
            ));
  }

  Set<String> get _sessionKeepIds {
    final keep = <String>{...?_archive?.pinnedIds, ..._remoteActiveSessionIds};
    for (final session in _sessions) {
      if (_isRemoteActive(session) || _isLocalActive(session)) {
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

  Future<void> _fetchSessions({
    bool refreshRemoteActivity = true,
    bool showLoader = true,
  }) async {
    // Puede invocarse desde un closure del drawer después de que la pantalla se
    // haya desmontado (HermesDrawer._go) → setState() after dispose(). Guard.
    if (!mounted) return;
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
          library?.sessions ?? await _client.getSessions();
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
      if (scope.fingerprint != _libraryQuery.fingerprint) return;
      await _migrateLineagePreferences(sessions);
      await _pinSync?.updateSessions(sessions, readFence: pinReadFence);

      // Hermes Agent no publica `include_children` en este endpoint. La
      // biblioteca promete solo sesiones principales y filtra defensivamente
      // cualquier hija que devuelva un servidor legacy o intermediario.
      final visible = sessions.where(
        (s) => s.parentSessionId == null || s.parentSessionId!.isEmpty,
      );

      final sorted = visible.toList()..sort(compareSessionsByRecentActivity);

      if (!mounted) return;
      setState(() {
        _sessions = sorted;
        _librarySource = library?.source ?? SessionLibrarySource.gateway;
        _libraryExhaustive = library?.exhaustive ?? false;
        _loading = false;
      });
      if (refreshRemoteActivity) unawaited(_refreshRemoteActivity());
    } catch (e) {
      if (!mounted) return;
      if (_sessions.isEmpty) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
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
    ScaffoldMessenger.of(context).showSnackBar(
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).slRenameEmpty)),
      );
      return;
    }

    await _archive!.setSessionTitle(session, trimmed);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(Strings.of(context).slRenamed)));
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(Strings.of(context).slArchiveSyncFailed)),
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
  ) => deleteSessionWithResolvedLineage(
    session,
    loadSessions: ({bool includeChildren = false}) =>
        _client.getSessions(includeChildren: includeChildren),
    deleteSession: _client.deleteSession,
    cronDeletion: cronDeletion,
    deleteCronJob:
        !session.isJob || cronDeletion == LinkedCronDeletionMode.keepSchedule
        ? null
        : (jobId) => widget.connManager.deleteLinkedCronJob(
            widget.connection,
            jobId,
            profile: widget.connManager.activeProfileFor(widget.connection.id),
          ),
  );

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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                sessionDeletionFailureMessage(Strings.of(context), result),
              ),
            ),
          );
        }
        return false;
      case LinkedSessionDeleteStatus.sessionDeleteFailed:
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                sessionDeletionFailureMessage(Strings.of(context), result),
              ),
            ),
          );
        }
        return false;
    }
  }

  /// El servidor respondió OK pero no borró la sesión (suele ser una sesión de
  /// un canal activo que se recrea). Ofrece ocultarla localmente — honesto.
  void _offerHideAfterFailedDelete(Session session, {String? message}) {
    final messenger = ScaffoldMessenger.of(context);
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

  // ── Limpieza de sesiones antiguas (PRIORIDAD 4) ───────────────────────────

  /// Sesiones "antiguas" según el filtro homónimo: stale o unknown, ni
  /// archivadas ni ya ocultas.
  List<Session> get _oldSessions => _sessions
      .where(
        (s) =>
            !AutomationSessionSources.contains(s.source) &&
            (s.state == SessionState.stale ||
                s.state == SessionState.unknown) &&
            !_isArchived(s) &&
            !_isHidden(s),
      )
      .toList();

  Future<bool> _confirmStrong(
    String title,
    String message,
    String confirmLabel,
  ) async {
    final colors = Theme.of(context).hermes;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(Strings.of(context).slCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel, style: TextStyle(color: colors.error)),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// Borra una lista de sesiones secuencialmente mostrando progreso. Devuelve
  /// cuántas se borraron y los IDs que fallaron (para ofrecer ocultarlos).
  Future<({int deleted, List<String> failed})> _bulkDelete(
    List<Session> targets,
  ) async {
    // Las limpiezas masivas nunca eliminan informes cron: cada uno requiere el
    // flujo individual que identifica y detiene antes su programación.
    final conversations = sessionsSafeForBulkDelete(targets);
    final progress = ValueNotifier<int>(0);
    final failed = <String>[];
    int deleted = 0;

    if (mounted) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          content: ValueListenableBuilder<int>(
            valueListenable: progress,
            builder: (_, done, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 16),
                Flexible(
                  child: Text(
                    Strings.of(
                      context,
                    ).slDeletingProgress('$done', '${conversations.length}'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    for (final s in conversations) {
      try {
        final ok = await _client.deleteSession(s.id);
        if (ok) {
          try {
            await _activeChats?.clearCancelledTurnsForSession(
              connectionId: widget.connection.id,
              profile: s.profile ?? '',
              sessionId: s.id,
            );
          } catch (error) {
            debugPrint(
              '[session-list] cancelled-turn cleanup queued: '
              '${error.runtimeType}',
            );
          }
          await _archive?.unarchiveSession(s);
          await _archive?.unhideSession(s);
          deleted++;
        } else {
          // El servidor respondió OK pero no la borró (sesión activa/recreada).
          failed.add(s.id);
        }
      } catch (e) {
        debugPrint(
          '[session-list] excepción silenciada (se continúa sin propagar): $e',
        );
        failed.add(s.id);
      }
      progress.value = deleted + failed.length;
    }

    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    progress.dispose();
    return (deleted: deleted, failed: failed);
  }

  /// Tras un borrado, ofrece ocultar localmente las que el servidor rechazó.
  Future<void> _reportDeleteResult(int deleted, List<String> failed) async {
    final messenger = ScaffoldMessenger.of(context);
    await _fetchSessions();
    if (!mounted) return;

    final s = Strings.of(context);
    if (failed.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(s.slDeletedSome(deleted))));
      return;
    }

    final hide = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(s.slSomeDeleteFailed),
        content: Text(s.slSomeDeleteFailedContent(failed.length, deleted)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(s.slNo),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(s.slHide),
          ),
        ],
      ),
    );
    if (hide == true) {
      final failedIds = failed.toSet();
      await _archive?.hideAll(
        _sessions
            .where((session) => failedIds.contains(session.id))
            .map((session) => session.logicalId),
      );
    }
    if (mounted) setState(() {});
  }

  Future<void> _promptCleanup() async {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final old = _oldSessions;
    final hiddenN = _archive?.hiddenCount ?? 0;
    final hiddenDeletable = sessionsSafeForBulkDelete(
      _sessions.where(_isHidden),
    );

    await showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('session-cleanup-surface'),
      maxWidth: 480,
      maxHeightFactor: 0.82,
      builder: (ctx) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  s.slCleanupTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            if (old.isEmpty)
              ListTile(
                leading: const Icon(Icons.check_circle_outline),
                title: Text(s.slNoOldTitle),
                subtitle: Text(s.slNoOldSubtitle),
              )
            else ...[
              ListTile(
                leading: Icon(Icons.delete_sweep_outlined, color: colors.error),
                title: Text(
                  s.slDeleteCount('${old.length}'),
                  style: TextStyle(color: colors.error),
                ),
                subtitle: Text(s.slDeleteCountSubtitle),
                onTap: () async {
                  Navigator.pop(ctx);
                  final ok = await _confirmStrong(
                    s.slDeleteStrongTitle('${old.length}'),
                    s.slDeleteStrongMessage('${old.length}'),
                    s.slDeleteConfirm,
                  );
                  if (!ok || !mounted) return;
                  final r = await _bulkDelete(old);
                  if (!mounted) return;
                  await _reportDeleteResult(r.deleted, r.failed);
                },
              ),
              ListTile(
                leading: const Icon(Icons.visibility_off_outlined),
                title: Text(s.slHideAll('${old.length}')),
                subtitle: Text(s.slHideAllSubtitle),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _archive?.hideAll(old.map((s) => s.logicalId));
                  if (mounted) setState(() {});
                },
              ),
            ],
            if (hiddenN > 0) ...[
              Divider(height: 0, color: colors.divider),
              ListTile(
                leading: const Icon(Icons.restore),
                title: Text(s.slRestoreHidden('$hiddenN')),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _archive?.clearHidden();
                  if (mounted) setState(() {});
                },
              ),
              if (hiddenDeletable.isNotEmpty)
                ListTile(
                  leading: Icon(Icons.delete_outline, color: colors.error),
                  title: Text(
                    s.slDeleteHiddenTitle,
                    style: TextStyle(color: colors.error),
                  ),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final targets = hiddenDeletable;
                    final ok = await _confirmStrong(
                      s.slDeleteHiddenTitle,
                      s.slDeleteHiddenMessage,
                      s.slDeleteConfirm,
                    );
                    if (!ok || !mounted) return;
                    final r = await _bulkDelete(targets);
                    if (!mounted) return;
                    await _reportDeleteResult(r.deleted, r.failed);
                  },
                ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Navigation ───────────────────────────────────────────────────────────

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

  Future<void> _openChat(Session session) async {
    final deleted = await openChatFromSection<bool>(
      context,
      builder: (_) =>
          ChatScreen(connection: widget.connection, session: session),
    );
    if (deleted == true && mounted) {
      setState(() => _sessions.removeWhere((item) => item.id == session.id));
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
      setState(() => _sessions.removeWhere((s) => s.id == session.id));
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
                  final deleted = await _confirmAndDeleteSession(session);
                  if (deleted && mounted) {
                    setState(
                      () => _sessions.removeWhere((s) => s.id == session.id),
                    );
                  }
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
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(Strings.of(context).slIdCopied)),
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

  /// Intercala cabeceras de fecha entre las sesiones (estilo Claude:
  /// Fijadas / Hoy / Ayer / Últimos 7 días / Anteriores). Devuelve una lista
  /// mixta de `String` (cabecera) y `Session`.
  List<Object> _groupedEntries(List<Session> sessions) {
    if (_showArchived) {
      return List<Object>.from(sessions);
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
    final str = Strings.of(context);
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
    if (pinned.isNotEmpty) {
      out.add(str.sesPinned);
      out.addAll(pinned);
    }
    String? current;
    for (final s in rest) {
      final b = bucketOf(s);
      if (b != current) {
        out.add(b);
        current = b;
      }
      out.add(s);
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
                case 'cleanup':
                  if (!_loading && _health.healthy) _promptCleanup();
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
              if (!widget.connection.readOnly)
                PopupMenuItem(
                  value: 'cleanup',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.cleaning_services_outlined),
                    title: Text(s.slMenuCleanOld),
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
      body: _buildBody(),
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
          _LibraryScopeNotice(text: s.slSearchLoadedOnly)
        else if (_searchQuery.trim().isEmpty &&
            _librarySource != SessionLibrarySource.dashboard)
          _LibraryScopeNotice(text: s.slLibraryLimited),
        Expanded(
          child: RefreshIndicator(
            color: colors.accent,
            onRefresh: _fetchSessions,
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
                : ValueListenableBuilder<Set<String>>(
                    valueListenable: _activeChats?.activeIds ?? _noActiveChats,
                    builder: (context, activeIds, _) => ListView.builder(
                      controller: _libraryScrollController,
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
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
                        if (entry is String) {
                          return Padding(
                            padding: EdgeInsets.fromLTRB(
                              6,
                              index == 0 ? 8 : 20,
                              6,
                              8,
                            ),
                            child: Text(
                              entry,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: colors.textSecondary,
                              ),
                            ),
                          );
                        }
                        final session = entry as Session;
                        final archived = _isArchived(session);
                        return Dismissible(
                          key: ValueKey('${session.id}-$archived'),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            margin: const EdgeInsets.only(bottom: 5),
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 18),
                            decoration: BoxDecoration(
                              color: colors.background,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  s.slSwipeManage,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: colors.textSecondary,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  Icons.tune_rounded,
                                  color: colors.textSecondary,
                                  size: 20,
                                ),
                              ],
                            ),
                          ),
                          confirmDismiss: (_) async {
                            await _showSessionContextMenu(session);
                            // El gesto abre las acciones; nunca borra por arrastre.
                            return false;
                          },
                          child: _SessionTile(
                            session: session,
                            title: _titleFor(session),
                            formattedTime: _relativeTime(
                              session.lastActivityAt,
                              s,
                            ),
                            pinned: _isPinned(session),
                            streamActive:
                                _isLocalActive(session) ||
                                _isRemoteActive(session),
                            onTap: () => _openChat(session),
                            // El deslizamiento es la entrada visible al menú.
                            // Long-press se conserva como alternativa para
                            // TalkBack, teclado y usuarios que ya lo conocían.
                            onLongPress: () => _showSessionContextMenu(session),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ),
      ],
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
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _SessionTile({
    required this.session,
    required this.title,
    required this.formattedTime,
    this.pinned = false,
    this.streamActive = false,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final hasPreview = session.cleanPreview.trim().isNotEmpty;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title.isNotEmpty
                              ? title
                              : Strings.of(context).slNoTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w500,
                            fontSize: 15,
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      if (session.hasLocalDraft) ...[
                        const SizedBox(width: 6),
                        HermesPill(
                          key: ValueKey('session-draft-${session.id}'),
                          color: colors.accent,
                          label: Strings.of(context).slDraftBadge,
                          showDot: false,
                        ),
                      ],
                      if (streamActive) ...[
                        const SizedBox(width: 6),
                        HermesPill(
                          key: ValueKey('session-running-${session.id}'),
                          color: colors.success,
                          label: Strings.of(context).slRunningBadge,
                          showDot: false,
                        ),
                      ],
                      if (session.isJob) ...[
                        const SizedBox(width: 6),
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
                            Strings.of(context).slReportBadge,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: colors.accent,
                            ),
                          ),
                        ),
                      ],
                      if (pinned) ...[
                        const SizedBox(width: 6),
                        Icon(
                          Icons.push_pin,
                          size: 13,
                          color: colors.textDisabled,
                        ),
                      ],
                    ],
                  ),
                  if (hasPreview) ...[
                    const SizedBox(height: 3),
                    Text(
                      session.cleanPreview.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.3,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                formattedTime,
                style: TextStyle(fontSize: 11, color: colors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Separador "·" del pie del tile (modelo · tiempo).

/// Tiempo relativo localizado para los tiles ("2h ago", "ahora", "14/6").
String _relativeTime(double ts, Strings s) => formatSessionRelativeTime(ts, s);
