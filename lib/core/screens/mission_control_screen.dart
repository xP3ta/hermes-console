import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../main.dart';
import '../models/agent_profile.dart';
import '../models/kanban.dart';
import '../models/mission_control.dart';
import '../models/mission_room.dart';
import '../models/mission_room_projection.dart';
import '../navigation/chat_route.dart';
import '../services/active_chat_service.dart';
import '../services/chat_draft_store.dart';
import '../services/connection_manager.dart';
import '../services/mission_control_repository.dart';
import '../services/mission_bot_activity_store.dart';
import '../services/mission_bot_chat_store.dart';
import '../services/mission_organization_store.dart';
import '../services/mission_room_store.dart';
import '../services/notifications/notification_service.dart';
import '../services/tui_gateway_client.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_drawer.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/mission_profile_avatar.dart';
import 'bot_create_screen.dart';
import 'chat_screen.dart';
import 'cron_screen.dart';
import 'memory_screen.dart';
import 'mission_control_copy.dart';
import 'profile_editor_screen.dart';
import 'profiles_screen.dart';
import 'skills_screen.dart';
import 'soul_screen.dart';
import 'tasks_screen.dart';

/// Mobile composition surface over Hermes profiles, sessions and native Kanban.
///
/// This screen never dispatches agents itself. It projects server state and
/// sends the user to the existing authoritative surfaces for chat, approvals,
/// profile management and task mutations.
enum MissionControlOwnedSurface { bot, room }

final class MissionControlOpenTarget {
  final MissionControlOwnedSurface surface;
  final String sessionId;
  final String? profile;
  final String? roomId;

  const MissionControlOpenTarget.bot({
    required this.sessionId,
    required this.profile,
  }) : surface = MissionControlOwnedSurface.bot,
       roomId = null;

  const MissionControlOpenTarget.room({
    required this.sessionId,
    required this.roomId,
    this.profile,
  }) : surface = MissionControlOwnedSurface.room;
}

class MissionControlScreen extends StatefulWidget {
  final SavedConnection connection;
  final ConnectionManager connManager;
  final MissionControlDataSource? dataSource;
  final MissionOrganizationStoreContract? organizationStore;
  final MissionRoomStoreContract? roomStore;
  @visibleForTesting
  final MissionBotChatStore? botChatStore;
  @visibleForTesting
  final MissionBotActivityStore? botActivityStore;
  @visibleForTesting
  final ChatDraftStore? chatDraftStore;
  final ActiveChatService? activeChats;
  final MissionControlOpenTarget? initialOpenTarget;
  @visibleForTesting
  final void Function(MissionRoom room, Session session)? roomOpenObserver;
  @visibleForTesting
  final ValueChanged<MissionRoomTaskLink>? roomTaskOpenObserver;
  @visibleForTesting
  final ValueChanged<Session>? botChatOpenObserver;
  @visibleForTesting
  final HermesDesktopBotCreationGateway? botCreateGateway;
  @visibleForTesting
  final HermesDesktopProfileAssetsGateway? profileAssetsGateway;
  @visibleForTesting
  final Future<List<ModelProvider>> Function(String profile)?
  modelOptionsLoader;

  const MissionControlScreen({
    required this.connection,
    required this.connManager,
    this.dataSource,
    this.organizationStore,
    this.roomStore,
    this.botChatStore,
    this.botActivityStore,
    this.chatDraftStore,
    this.activeChats,
    this.initialOpenTarget,
    this.roomOpenObserver,
    this.roomTaskOpenObserver,
    this.botChatOpenObserver,
    this.botCreateGateway,
    this.profileAssetsGateway,
    this.modelOptionsLoader,
    super.key,
  });

  @override
  State<MissionControlScreen> createState() => _MissionControlScreenState();
}

enum _MissionDestination { bots, work }

class _MissionControlScreenState extends State<MissionControlScreen>
    with WidgetsBindingObserver {
  late final MissionControlDataSource _dataSource;
  late final MissionProfileAvatarCache? _profileAvatarCache;
  late final MissionOrganizationStoreContract _organizationStore;
  late final MissionRoomStoreContract _roomStore;
  late final MissionBotChatStore _botChatStore;
  late final MissionBotActivityStore _botActivityStore;
  late final ChatDraftStore _chatDraftStore;
  TuiGatewayClient? _ownedProfileAssetsGateway;
  late final HermesDesktopProfileAssetsGateway _profileAssetsGateway;
  MissionBackendSnapshot? _snapshot;
  List<MissionOrganization> _organizations = const [];
  List<MissionRoom> _rooms = const [];
  String? _selectedOrganizationId;
  Object? _loadFailure;
  bool _loading = true;
  bool _refreshing = false;
  ActiveChatService? _activeChats;
  final Map<ActiveChat, StreamSubscription<ActiveChatEvent>>
  _liveSubscriptions = {};
  Timer? _liveRefreshDebounce;
  StreamSubscription<KanbanEvent>? _kanbanSubscription;
  Timer? _kanbanRefreshDebounce;
  Timer? _kanbanReconnectTimer;
  Duration _kanbanReconnectDelay = const Duration(seconds: 3);
  int _kanbanEventCursor = 0;
  int _loadGeneration = 0;
  bool _botActivityInitialized = false;
  bool _lifecyclePaused = false;
  bool _disposed = false;
  bool _initialOpenDispatched = false;
  _MissionDestination _destination = _MissionDestination.bots;

  MissionOrganization? get _selectedOrganization {
    final id = _selectedOrganizationId;
    if (id == null) return null;
    for (final organization in _organizations) {
      if (organization.id == id) return organization;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _dataSource =
        widget.dataSource ??
        MissionControlRepository.forConnection(widget.connection);
    final avatarSource = _dataSource;
    _profileAvatarCache = avatarSource is MissionProfileAvatarDataSource
        ? MissionProfileAvatarCache(
            loader: (avatarSource as MissionProfileAvatarDataSource)
                .loadProfileAvatar,
          )
        : null;
    _organizationStore =
        widget.organizationStore ??
        MissionOrganizationStore(widget.connManager.prefs);
    _roomStore = widget.roomStore ?? MissionRoomStore(widget.connManager.prefs);
    _botChatStore =
        widget.botChatStore ?? MissionBotChatStore(widget.connManager.prefs);
    _botActivityStore =
        widget.botActivityStore ??
        MissionBotActivityStore(widget.connManager.prefs);
    _chatDraftStore =
        widget.chatDraftStore ?? ChatDraftStore(widget.connManager.prefs);
    final injectedAssets = widget.profileAssetsGateway;
    if (injectedAssets != null) {
      _profileAssetsGateway = injectedAssets;
    } else {
      final gateway = TuiGatewayClient(widget.connection);
      _ownedProfileAssetsGateway = gateway;
      _profileAssetsGateway = gateway;
    }
    _organizations = _organizationStore.load(widget.connection.id);
    _rooms = _roomStore.load(widget.connection.id);
    if (widget.initialOpenTarget?.surface == MissionControlOwnedSurface.room) {
      _destination = _MissionDestination.work;
    }
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final service =
        widget.activeChats ??
        context.findAncestorStateOfType<HermesAppState>()?.activeChats;
    if (identical(service, _activeChats)) return;
    _activeChats?.activeIds.removeListener(_onActiveIdsChanged);
    _cancelLiveSubscriptions();
    _liveRefreshDebounce?.cancel();
    _activeChats = service;
    _activeChats?.activeIds.addListener(_onActiveIdsChanged);
    _syncLiveSubscriptions();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _activeChats?.activeIds.removeListener(_onActiveIdsChanged);
    _cancelLiveSubscriptions();
    _kanbanRefreshDebounce?.cancel();
    _kanbanReconnectTimer?.cancel();
    unawaited(_kanbanSubscription?.cancel());
    _kanbanSubscription = null;
    _profileAvatarCache?.clear();
    unawaited(_ownedProfileAssetsGateway?.close());
    if (widget.dataSource == null) _dataSource.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (!_lifecyclePaused) return;
        _lifecyclePaused = false;
        _kanbanReconnectDelay = const Duration(seconds: 3);
        unawaited(_load(refresh: true));
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _lifecyclePaused = true;
        _kanbanRefreshDebounce?.cancel();
        _kanbanReconnectTimer?.cancel();
        unawaited(_kanbanSubscription?.cancel());
        _kanbanSubscription = null;
    }
  }

  Future<void> _load({bool refresh = false}) async {
    final generation = ++_loadGeneration;
    if (mounted) {
      setState(() {
        if (refresh && _snapshot != null) {
          _refreshing = true;
        } else {
          _loading = true;
        }
        _loadFailure = null;
      });
    }
    try {
      final incoming = await _dataSource.load();
      if (!mounted || generation != _loadGeneration) return;
      final snapshot = _retainLastGoodSources(incoming);
      await _initializeBotActivity(snapshot);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
        _refreshing = false;
      });
      _kanbanEventCursor = incoming.board?.latestEventId ?? _kanbanEventCursor;
      _syncLiveSubscriptions();
      _subscribeKanban(incoming);
      _scheduleInitialOpen(snapshot);
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loadFailure = error;
        _loading = false;
        _refreshing = false;
      });
    }
  }

  Future<void> _initializeBotActivity(MissionBackendSnapshot snapshot) async {
    final profiles = snapshot.profiles.map((profile) => profile.name).toSet();
    try {
      if (!_botActivityInitialized) {
        _botActivityInitialized = true;
        final existing = _botActivityStore.watermarks(widget.connection.id);
        if (existing.isEmpty) {
          final agents = _projection(snapshot).agents;
          await Future.wait(
            agents.map((agent) {
              final activityAtMs = _missionBotActivityMs(agent);
              if (activityAtMs <= 0) return Future<void>.value();
              return _botActivityStore.markRead(
                connectionId: widget.connection.id,
                profile: agent.profile.name,
                activityAtMs: activityAtMs,
              );
            }),
          );
        }
      }
      await _botActivityStore.prune(widget.connection.id, profiles);
    } catch (error) {
      debugPrint(
        'Mission Control: could not initialize Bot activity watermarks: '
        '$error',
      );
    }
  }

  void _scheduleInitialOpen(MissionBackendSnapshot snapshot) {
    final target = widget.initialOpenTarget;
    if (target == null || _initialOpenDispatched) return;
    _initialOpenDispatched = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_openInitialTarget(target, snapshot));
    });
  }

  Future<void> _openInitialTarget(
    MissionControlOpenTarget target,
    MissionBackendSnapshot snapshot,
  ) async {
    switch (target.surface) {
      case MissionControlOwnedSurface.bot:
        final profile = target.profile;
        if (profile == null || profile.isEmpty) return;
        MissionAgent? agent;
        for (final candidate in _projection(snapshot).agents) {
          if (candidate.profile.name == profile) {
            agent = candidate;
            break;
          }
        }
        if (agent != null) await _openChat(agent);
        return;
      case MissionControlOwnedSurface.room:
        final roomId = target.roomId;
        if (roomId == null || roomId.isEmpty) return;
        MissionRoom? room;
        for (final candidate in _rooms) {
          if (candidate.id == roomId) {
            room = candidate;
            break;
          }
        }
        if (room != null) await _openRoomChat(room);
        return;
    }
  }

  MissionBackendSnapshot _retainLastGoodSources(
    MissionBackendSnapshot incoming,
  ) {
    final previous = _snapshot;
    if (previous == null) return incoming;
    final profilesFailed =
        incoming.failures.containsKey('profiles') &&
        incoming.profilesCapability == MissionCapabilityState.unavailable;
    final sessionsFailed =
        incoming.failures.containsKey('sessions') &&
        incoming.sessionsCapability == MissionCapabilityState.unavailable;
    final kanbanFailed =
        incoming.failures.containsKey('kanban') &&
        incoming.kanbanCapability == MissionCapabilityState.unavailable;
    return MissionBackendSnapshot(
      profiles: profilesFailed ? previous.profiles : incoming.profiles,
      sessions: sessionsFailed ? previous.sessions : incoming.sessions,
      board: kanbanFailed ? previous.board : incoming.board,
      profilesCapability: incoming.profilesCapability,
      sessionsCapability: incoming.sessionsCapability,
      kanbanCapability: incoming.kanbanCapability,
      failures: incoming.failures,
      loadedAt: incoming.loadedAt,
    );
  }

  void _subscribeKanban(MissionBackendSnapshot snapshot) {
    if (_disposed ||
        _lifecyclePaused ||
        _kanbanSubscription != null ||
        snapshot.kanbanCapability != MissionCapabilityState.available) {
      return;
    }
    final events = _dataSource.watchKanban(since: _kanbanEventCursor);
    if (events == null) return;
    _kanbanSubscription = events.listen(
      (event) {
        if (event.id > _kanbanEventCursor) _kanbanEventCursor = event.id;
        _kanbanReconnectDelay = const Duration(seconds: 3);
        _kanbanRefreshDebounce?.cancel();
        _kanbanRefreshDebounce = Timer(const Duration(milliseconds: 350), () {
          if (!_disposed && !_lifecyclePaused) unawaited(_load(refresh: true));
        });
      },
      onError: (_) => _scheduleKanbanReconnect(),
      onDone: _scheduleKanbanReconnect,
      cancelOnError: true,
    );
  }

  void _scheduleKanbanReconnect() {
    if (_disposed || _lifecyclePaused) return;
    _kanbanSubscription = null;
    if (_kanbanReconnectTimer?.isActive ?? false) return;
    final delay = _kanbanReconnectDelay;
    final nextSeconds = (delay.inSeconds * 2).clamp(3, 60);
    _kanbanReconnectDelay = Duration(seconds: nextSeconds);
    _kanbanReconnectTimer = Timer(delay, () {
      _kanbanReconnectTimer = null;
      final snapshot = _snapshot;
      if (snapshot != null) _subscribeKanban(snapshot);
    });
  }

  void _onActiveIdsChanged() {
    _syncLiveSubscriptions();
    _scheduleLiveRefresh();
  }

  void _syncLiveSubscriptions() {
    final service = _activeChats;
    if (service == null) return;
    final current = _resolveActiveChats(service).toSet();
    for (final entry in _liveSubscriptions.entries.toList()) {
      if (current.contains(entry.key)) continue;
      unawaited(entry.value.cancel());
      _liveSubscriptions.remove(entry.key);
    }
    for (final chat in current) {
      if (_liveSubscriptions.containsKey(chat)) continue;
      _liveSubscriptions[chat] = chat.changes.listen(
        (_) => _scheduleLiveRefresh(),
      );
    }
  }

  void _scheduleLiveRefresh() {
    if (_disposed || !mounted) return;
    _liveRefreshDebounce?.cancel();
    _liveRefreshDebounce = Timer(const Duration(milliseconds: 80), () {
      if (!_disposed && mounted) setState(() {});
    });
  }

  void _cancelLiveSubscriptions() {
    for (final subscription in _liveSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    _liveSubscriptions.clear();
  }

  Iterable<ActiveChat> _resolveActiveChats(ActiveChatService service) sync* {
    final seen = <ActiveChat>{};
    for (final rawId in service.activeIds.value) {
      try {
        final decoded = jsonDecode(rawId);
        if (decoded is! List || decoded.length != 3) continue;
        final connectionId = decoded[0];
        final profile = decoded[1];
        final sessionId = decoded[2];
        if (connectionId != widget.connection.id ||
            profile is! String ||
            sessionId is! String) {
          continue;
        }
        final chat = service.of(
          widget.connection.id,
          sessionId,
          profile: profile,
        );
        if (chat != null && seen.add(chat)) yield chat;
      } catch (_) {
        // Active ids are internal opaque identities. Ignore a malformed value
        // instead of letting observability take down the existing chat path.
      }
    }
    for (final session in _snapshot?.sessions ?? const <Session>[]) {
      final owner = session.profile?.trim();
      if (owner == null || owner.isEmpty) continue;
      final chat = service.of(widget.connection.id, session.id, profile: owner);
      if (chat != null && seen.add(chat)) yield chat;
    }
  }

  List<MissionLiveChat> _liveChats() {
    final service = _activeChats;
    if (service == null) return const [];
    final sessions = _snapshot?.sessions ?? const <Session>[];
    final sessionByIdentity = <String, Session>{};
    final sessionsById = <String, List<Session>>{};
    for (final session in sessions) {
      final owner = session.profile?.trim();
      if (owner != null && owner.isNotEmpty) {
        sessionByIdentity['$owner\u0000${session.id}'] = session;
        sessionByIdentity['$owner\u0000${session.logicalId}'] = session;
      }
      sessionsById.putIfAbsent(session.id, () => []).add(session);
      sessionsById.putIfAbsent(session.logicalId, () => []).add(session);
    }
    return _resolveActiveChats(service)
        .map((chat) {
          final profile = Session.profileOwner(chat.sessionProfile);
          final storedId = chat.storedSessionId;
          final lookupId = storedId ?? chat.sessionId;
          final idMatches = sessionsById[lookupId] ?? const <Session>[];
          final session =
              sessionByIdentity['$profile\u0000$lookupId'] ??
              sessionByIdentity['$profile\u0000${chat.sessionId}'] ??
              (idMatches.length == 1 ? idMatches.single : null);
          return MissionLiveChat(
            profileName: profile,
            sessionId: storedId ?? chat.sessionId,
            title: chat.sessionTitle,
            phase: _missionPhase(chat),
            approval: chat.pendingApproval,
            model: session?.model,
          );
        })
        .toList(growable: false);
  }

  MissionLivePhase _missionPhase(ActiveChat chat) {
    if (chat.pendingApproval != null) {
      return MissionLivePhase.approvalRequired;
    }
    if (chat.state == ChatPipelineState.failed) return MissionLivePhase.error;
    return switch (chat.activityKind) {
      ChatActivityKind.thinking => MissionLivePhase.thinking,
      ChatActivityKind.usingTools => MissionLivePhase.working,
      ChatActivityKind.responding => MissionLivePhase.responding,
      ChatActivityKind.awaitingApproval => MissionLivePhase.approvalRequired,
      null => MissionLivePhase.idle,
    };
  }

  MissionProjection _projection(MissionBackendSnapshot snapshot) =>
      MissionProjector.build(
        snapshot: snapshot,
        liveChats: _liveChats(),
        organization: _selectedOrganization,
      );

  Future<void> _saveBotRosterMeta(
    MissionAgent agent, {
    bool? hidden,
    bool? pinned,
  }) async {
    if (widget.connection.readOnly) return;
    final copy = MissionControlCopy.of(context);
    try {
      await _profileAssetsGateway.saveProfileBotMeta(
        profile: agent.profile.name,
        hidden: hidden,
        pinned: pinned,
      );
      if (!mounted) return;
      await _load(refresh: true);
    } catch (error) {
      debugPrint(
        'Mission Control: could not update Bot roster metadata for '
        '${agent.profile.name}: $error',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(copy.botRosterUpdateFailed)));
    }
  }

  Future<void> _markBotRead(MissionAgent agent) async {
    try {
      await _botActivityStore.markRead(
        connectionId: widget.connection.id,
        profile: agent.profile.name,
        activityAtMs: _missionBotActivityMs(agent),
      );
      if (mounted) setState(() {});
    } catch (error) {
      debugPrint(
        'Mission Control: could not persist Bot read watermark for '
        '${agent.profile.name}: $error',
      );
    }
  }

  Future<void> _editOrganization([MissionOrganization? existing]) async {
    if (widget.connection.readOnly) return;
    final result = await showHermesFloatingSurface<_OrganizationDraft>(
      context: context,
      surfaceKey: const ValueKey('mission-organization-editor'),
      maxWidth: 540,
      maxHeightFactor: 0.9,
      builder: (context) => _OrganizationEditor(
        copy: MissionControlCopy.of(context),
        profiles: _snapshot?.profiles ?? const [],
        existing: existing,
      ),
    );
    if (result == null) return;
    final saved = await _organizationStore.save(
      connectionId: widget.connection.id,
      name: result.name,
      profileNames: result.profileNames,
      managerProfile: result.managerProfile,
      existing: existing,
    );
    if (!mounted) return;
    setState(() {
      _organizations = _organizationStore.load(widget.connection.id);
      _selectedOrganizationId = saved.id;
    });
  }

  Future<void> _deleteOrganization(MissionOrganization organization) async {
    if (widget.connection.readOnly) return;
    final copy = MissionControlCopy.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(copy.deleteOrganizationTitle),
        content: Text(copy.deleteOrganizationBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(copy.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(copy.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // Unlink first: if that durable write fails, the Organization remains and
    // no Room can become orphaned. If the later delete fails, the remaining
    // Organization is merely empty and can be retried safely.
    await _roomStore.unlinkOrganization(widget.connection.id, organization.id);
    await _organizationStore.delete(widget.connection.id, organization.id);
    if (!mounted) return;
    setState(() {
      _organizations = _organizationStore.load(widget.connection.id);
      _rooms = _roomStore.load(widget.connection.id);
      if (_selectedOrganizationId == organization.id) {
        _selectedOrganizationId = null;
      }
    });
  }

  /// Abre el Bot Chat del agente. [kickoffPrompt] reproduce el nacimiento del
  /// chat canónico de Bot Mode: el bot se presenta solo en su primer turno
  /// (Desktop envía el mismo texto al crear el agente).
  Future<void> _openChat(MissionAgent agent, {String? kickoffPrompt}) async {
    final officialPin = agent.profile.botChatSessionId;
    final officialMetadata =
        agent.profile.botModeMetadataPublished || officialPin != null;
    if (agent.profile.hasInvalidBotChatPin) {
      debugPrint(
        'Mission Control: Bot Chat unavailable for ${agent.profile.name} '
        '(malformed canonical pin: '
        'chat=${agent.profile.botModeUiMeta['chat']}, '
        'invalidMetadata=${agent.profile.hasInvalidBotModeMetadata})',
      );
      _showBotChatPinUnavailable();
      return;
    }
    String? localPin;
    if (officialMetadata) {
      if (!widget.connection.readOnly) {
        try {
          // Once Desktop publishes the namespace it is authoritative,
          // including an explicit absence of `chat`. Removing this fallback
          // prevents an older Console-only conversation from resurrecting
          // after a repin. Read-only mode must not mutate local state.
          await _botChatStore.clear(
            connectionId: widget.connection.id,
            profile: agent.profile.name,
          );
        } catch (error) {
          debugPrint(
            'Mission Control: could not retire the stale local Bot Chat pin '
            'for ${agent.profile.name}: $error',
          );
          _showBotChatPinUnavailable();
          return;
        }
      }
    } else {
      final lookup = await _botChatStore.lookup(
        widget.connection.id,
        agent.profile.name,
        migrateLegacy: !widget.connection.readOnly,
      );
      if (lookup.state == MissionBotChatPinState.corrupt ||
          lookup.state == MissionBotChatPinState.unavailable) {
        debugPrint(
          'Mission Control: local Bot Chat pin for ${agent.profile.name} '
          'is ${lookup.state.name}',
        );
        _showBotChatPinUnavailable();
        return;
      }
      localPin = lookup.sessionId;
    }
    if (!mounted) return;
    final pinnedId = officialPin ?? localPin;
    final session = Session(
      id: 'mob-bot-${agent.profile.name}',
      lineageRootId: pinnedId,
      title: 'Bot Chat',
      model: agent.profile.model.isEmpty ? 'hermes-agent' : agent.profile.model,
      source: pinnedId == null
          ? 'mobile-bot'
          : officialPin != null
          ? 'bot-mode'
          : 'bot-mode-local',
      messageCount: pinnedId == null ? 0 : 1,
      isActive: true,
      preview: '',
      startedAt: pinnedId == null
          ? DateTime.now().millisecondsSinceEpoch.toDouble() / 1000
          : 0,
      profile: agent.profile.name,
      isDefaultProfile: agent.profile.isDefault,
    );
    await _markBotRead(agent);
    if (!mounted) return;
    final observer = widget.botChatOpenObserver;
    if (observer != null) {
      observer(session);
    } else {
      await openChatFromSection<void>(
        context,
        builder: (_) => ChatScreen(
          connection: widget.connection,
          session: session,
          initialStoredSessionId: pinnedId,
          initialPrompt: kickoffPrompt,
          requestComposerFocus: true,
          missionBotProfile: agent.profile,
          missionAvatarCache: _profileAvatarCache,
        ),
      );
    }
    // Bot Chat can publish its canonical pin while the route is open. Refresh
    // before the next tap so a stale authoritative-null profile cannot dispose
    // the live canonical binding and reopen an empty conversation.
    if (mounted) await _load(refresh: true);
  }

  void _showBotChatPinUnavailable() {
    if (!mounted) return;
    final english = Localizations.localeOf(context).languageCode == 'en';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          english
              ? 'Bot Chat metadata could not be verified. Refresh the team before sending.'
              : 'No se pudo verificar el Bot Chat. Actualiza el equipo antes de enviar.',
        ),
      ),
    );
  }

  Future<void> _reviewApproval(MissionApproval approval) async {
    final live = _activeChats?.of(
      widget.connection.id,
      approval.sessionId,
      profile: approval.profileName,
    );
    if (live?.notificationSurface == NotificationChatSurface.room) {
      final roomId = live?.notificationRoomId;
      for (final room in _rooms) {
        if (room.id != roomId) continue;
        if (_destination != _MissionDestination.work) {
          setState(() => _destination = _MissionDestination.work);
        }
        await _openRoomChat(room);
        return;
      }
    }

    final snapshot = _snapshot;
    MissionAgent? agent;
    if (snapshot != null) {
      for (final candidate in _projection(snapshot).agents) {
        if (candidate.profile.name == approval.profileName) {
          agent = candidate;
          break;
        }
      }
    }
    if (live?.notificationSurface == NotificationChatSurface.bot &&
        agent != null) {
      if (_destination != _MissionDestination.bots) {
        setState(() => _destination = _MissionDestination.bots);
      }
      await _openChat(agent);
      return;
    }

    // Tras process death no queda ActiveChat, pero los pins duraderos siguen
    // identificando de forma inequívoca la superficie propietaria.
    for (final room in _rooms) {
      if (room.managerProfile == approval.profileName &&
          room.managerSessionId == approval.sessionId) {
        if (_destination != _MissionDestination.work) {
          setState(() => _destination = _MissionDestination.work);
        }
        await _openRoomChat(room);
        return;
      }
    }
    if (agent != null) {
      var botSessionId = agent.profile.botChatSessionId;
      if (botSessionId == null && !agent.profile.botModeMetadataPublished) {
        final lookup = await _botChatStore.lookup(
          widget.connection.id,
          agent.profile.name,
          migrateLegacy: !widget.connection.readOnly,
        );
        if (!mounted) return;
        botSessionId = lookup.sessionId;
      }
      if (botSessionId == approval.sessionId) {
        if (_destination != _MissionDestination.bots) {
          setState(() => _destination = _MissionDestination.bots);
        }
        await _openChat(agent);
        return;
      }
    }

    Session? match;
    for (final session in _snapshot?.sessions ?? const <Session>[]) {
      if (session.profile?.trim() == approval.profileName &&
          (session.id == approval.sessionId ||
              session.logicalId == approval.sessionId)) {
        match = session;
        break;
      }
    }
    match ??= Session(
      id: approval.sessionId,
      title: approval.sessionTitle,
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 0,
      isActive: true,
      preview: '',
      startedAt: DateTime.now().millisecondsSinceEpoch.toDouble() / 1000,
      profile: approval.profileName,
    );
    if (!mounted) return;
    await openChatFromSection<void>(
      context,
      builder: (_) =>
          ChatScreen(connection: widget.connection, session: match!),
    );
  }

  void _openAgent(MissionAgent agent) {
    showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('mission-agent-detail'),
      maxWidth: 560,
      maxHeightFactor: 0.9,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.72,
        child: _AgentDetail(
          agent: agent,
          assignedTasks: [
            for (final column
                in _snapshot?.board?.columns ?? const <KanbanColumn>[])
              for (final task in column.tasks)
                if (task.assignee?.trim() == agent.profile.name) task,
          ],
          copy: MissionControlCopy.of(sheetContext),
          avatarCache: _profileAvatarCache,
          onChat: () {
            Navigator.pop(sheetContext);
            _openChat(agent);
          },
          onEditProfile: widget.connection.readOnly
              ? null
              : () {
                  Navigator.pop(sheetContext);
                  _openProfileEditor(agent.profile);
                },
          onRoutines: () {
            Navigator.pop(sheetContext);
            _openRoutines(profile: agent.profile.name);
          },
          onTasks: () {
            Navigator.pop(sheetContext);
            _openTasks(assignee: agent.profile.name);
          },
          onMemory: () {
            Navigator.pop(sheetContext);
            _openMemory(profile: agent.profile.name);
          },
          onSkills: () {
            Navigator.pop(sheetContext);
            _openSkills(profile: agent.profile.name);
          },
          onSoul: () {
            Navigator.pop(sheetContext);
            _openSoul();
          },
          onTogglePinned: widget.connection.readOnly
              ? null
              : () {
                  Navigator.pop(sheetContext);
                  unawaited(
                    _saveBotRosterMeta(agent, pinned: !agent.profile.botPinned),
                  );
                },
          onToggleHidden: widget.connection.readOnly
              ? null
              : () {
                  Navigator.pop(sheetContext);
                  unawaited(
                    _saveBotRosterMeta(agent, hidden: !agent.profile.botHidden),
                  );
                },
        ),
      ),
    );
  }

  Future<void> _editRoom([MissionRoom? existing]) async {
    if (widget.connection.readOnly) return;
    if (existing != null && await _roomMutationBlocked(existing)) return;
    if (!mounted) return;
    final snapshot = _snapshot;
    if (snapshot == null) return;
    if (snapshot.profilesCapability != MissionCapabilityState.available) {
      _showRoomRosterUnavailable();
      return;
    }
    final organization = _selectedOrganization;
    final scopedProfiles = organization == null
        ? snapshot.profiles
        : snapshot.profiles
              .where(
                (profile) => organization.profileNames.contains(profile.name),
              )
              .toList(growable: false);
    if (scopedProfiles.isEmpty ||
        (existing != null &&
            !scopedProfiles.any(
              (profile) => profile.name == existing.managerProfile,
            ))) {
      _showRoomRosterUnavailable();
      return;
    }
    if (existing == null && scopedProfiles.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(MissionControlCopy.of(context).needTwoAgents)),
      );
      return;
    }
    final result = await showHermesFloatingSurface<_RoomDraft>(
      context: context,
      surfaceKey: const ValueKey('mission-room-editor'),
      maxWidth: 540,
      maxHeightFactor: 0.92,
      barrierDismissible: false,
      systemDismissible: false,
      builder: (context) => _RoomEditor(
        copy: MissionControlCopy.of(context),
        profiles: scopedProfiles,
        avatarCache: _profileAvatarCache,
        suggestedManager: organization?.managerProfile,
        existing: existing,
        onManageProfiles: () {
          Navigator.pop(context);
          unawaited(_openProfiles());
        },
      ),
    );
    if (result == null) return;
    if (existing != null && await _roomMutationBlocked(existing)) return;
    final fresh = await _loadAuthoritativeRoomSnapshot();
    if (fresh == null) return;
    final freshScopedProfiles = organization == null
        ? fresh.profiles
        : fresh.profiles
              .where(
                (profile) => organization.profileNames.contains(profile.name),
              )
              .toList(growable: false);
    final freshNames = freshScopedProfiles
        .map((profile) => profile.name)
        .toSet();
    if (!freshNames.contains(result.managerProfile) ||
        !freshNames.containsAll(result.memberProfiles)) {
      _showRoomRosterUnavailable();
      return;
    }
    final previousOrganizationId = existing?.organizationId;
    final knownOrganizationIds = _organizations.map((item) => item.id).toSet();
    final saved = await _roomStore.save(
      connectionId: widget.connection.id,
      name: result.name,
      purposeLabel: result.purposeLabel,
      managerProfile: result.managerProfile,
      memberProfiles: result.memberProfiles,
      organizationId:
          organization?.id ??
          (knownOrganizationIds.contains(previousOrganizationId)
              ? previousOrganizationId
              : null),
      existing: existing,
    );
    if (!mounted) return;
    setState(() {
      _rooms = _roomStore.load(widget.connection.id);
    });
    if (existing == null) unawaited(_openRoomDetail(saved));
  }

  Future<void> _deleteRoom(MissionRoom room) async {
    if (widget.connection.readOnly) return;
    if (await _roomMutationBlocked(room)) return;
    if (!mounted) return;
    final copy = MissionControlCopy.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(copy.deleteRoomTitle),
        content: Text(copy.deleteRoomBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(copy.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(copy.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (await _roomMutationBlocked(room)) return;
    await _roomStore.delete(widget.connection.id, room.id);
    if (mounted) {
      setState(() => _rooms = _roomStore.load(widget.connection.id));
    }
  }

  Future<bool> _roomMutationBlocked(MissionRoom room) async {
    try {
      final draft = await _chatDraftStore.load(
        widget.connection.id,
        'mob-room-${room.id}',
        profile: room.managerProfile,
        claimUnscopedLegacy: true,
      );
      if (!draft.hasMissionRoomOperation) return false;
    } catch (_) {
      // A storage failure is ambiguous: mutating the Room could still orphan a
      // recoverable operation, so fail closed until the draft can be read.
    }
    if (mounted) {
      final copy = MissionControlCopy.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(copy.roomOperationPending)));
    }
    return true;
  }

  void _showRoomRosterUnavailable() {
    if (!mounted) return;
    final english = Localizations.localeOf(context).languageCode == 'en';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          english
              ? 'The authoritative profile roster is unavailable or this manager no longer exists. Refresh or manage profiles first.'
              : 'El roster autoritativo no está disponible o este manager ya no existe. Actualiza o gestiona los perfiles primero.',
        ),
      ),
    );
  }

  Future<MissionBackendSnapshot?> _loadAuthoritativeRoomSnapshot() async {
    try {
      final fresh = await _dataSource.load();
      if (!mounted) return null;
      if (fresh.profilesCapability != MissionCapabilityState.available) {
        _showRoomRosterUnavailable();
        return null;
      }
      return fresh;
    } catch (_) {
      if (mounted) _showRoomRosterUnavailable();
      return null;
    }
  }

  _RoomDetailData? _roomDetailData(String roomId) {
    final snapshot = _snapshot;
    if (snapshot == null) return null;
    MissionRoom? room;
    for (final candidate in _rooms) {
      if (candidate.id == roomId) {
        room = candidate;
        break;
      }
    }
    if (room == null) return null;
    final projection = _projection(snapshot);
    final roomWork = MissionRoomWorkProjector.build(
      rooms: _rooms,
      snapshot: snapshot,
      mission: projection,
      ownershipRooms: _rooms,
    ).forRoom(roomId);
    if (roomWork == null) return null;
    return _RoomDetailData(room: room, snapshot: snapshot, work: roomWork);
  }

  Future<void> _openRoomDetail(MissionRoom room) async {
    if (!mounted) return;
    var data = _roomDetailData(room.id);
    if (data == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => StatefulBuilder(
          builder: (context, setDetailState) {
            Future<void> refreshDetail({bool remote = true}) async {
              if (remote) await _load(refresh: true);
              if (!routeContext.mounted) return;
              final refreshed = _roomDetailData(room.id);
              if (refreshed == null) {
                Navigator.of(routeContext).pop();
                return;
              }
              setDetailState(() => data = refreshed);
            }

            final current = data!;
            return _MissionRoomDetailScreen(
              room: current.room,
              snapshot: current.snapshot,
              roomWork: current.work,
              copy: MissionControlCopy.of(context),
              avatarCache: _profileAvatarCache,
              readOnly: widget.connection.readOnly,
              canOpenChat:
                  current.snapshot.profilesCapability ==
                  MissionCapabilityState.available,
              onRefresh: refreshDetail,
              onOpenChat: () async {
                await _openRoomChat(current.room);
                await refreshDetail(remote: false);
              },
              onOpenTask: (link) async {
                await _openRoomTask(link);
                await refreshDetail();
              },
              onOpenKanban: () async {
                await _openTasks();
                await refreshDetail();
              },
              onEdit: widget.connection.readOnly
                  ? null
                  : () async {
                      await _editRoom(current.room);
                      await refreshDetail(remote: false);
                    },
              onDelete: widget.connection.readOnly
                  ? null
                  : () async {
                      await _deleteRoom(current.room);
                      await refreshDetail(remote: false);
                    },
            );
          },
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _rooms = _roomStore.load(widget.connection.id));
  }

  Future<void> _openRoomChat(MissionRoom room) async {
    final snapshot = await _loadAuthoritativeRoomSnapshot();
    if (!mounted || snapshot == null) return;
    final freshProfiles = snapshot.profiles
        .map((profile) => profile.name)
        .toSet();
    if (!freshProfiles.contains(room.managerProfile) ||
        !freshProfiles.containsAll(room.memberProfiles)) {
      _showRoomRosterUnavailable();
      return;
    }
    final roomProfiles = Map<String, AgentProfile>.unmodifiable({
      for (final profile in snapshot.profiles)
        if (room.memberProfiles.contains(profile.name)) profile.name: profile,
    });
    Session? existing;
    if (room.hasDurableManagerSession) {
      for (final session in snapshot.sessions) {
        if (session.profile?.trim() != room.managerProfile) continue;
        if (session.id == room.managerSessionId ||
            session.logicalId == room.managerSessionId) {
          existing = session;
          break;
        }
      }
    }
    // Stable local identity for encrypted drafts/outbox only. It is never
    // persisted in the Room as a Hermes session id; the first canonical
    // `session.create` must replace it with the opaque stored id.
    final draftId = 'mob-room-${room.id}';
    final session = Session(
      id: draftId,
      lineageRootId: room.hasDurableManagerSession
          ? room.managerSessionId
          : null,
      title: existing?.title ?? '#${room.name}',
      model: existing?.model ?? 'hermes-agent',
      source: room.hasDurableManagerSession ? 'room-local' : 'mobile-room',
      messageCount: existing?.messageCount ?? 0,
      isActive: existing?.isActive ?? false,
      preview: existing?.preview ?? '',
      startedAt:
          existing?.startedAt ??
          DateTime.now().millisecondsSinceEpoch.toDouble() / 1000,
      profile: room.managerProfile,
      isDefaultProfile: room.managerProfile == 'default',
    );
    final observer = widget.roomOpenObserver;
    if (observer != null) {
      observer(room, session);
      return;
    }
    await openChatFromSection<void>(
      context,
      builder: (_) => ChatScreen(
        connection: widget.connection,
        session: session,
        initialStoredSessionId: room.hasDurableManagerSession
            ? room.managerSessionId
            : null,
        missionRoom: room,
        missionRoomStore: _roomStore,
        missionRoomProfiles: roomProfiles,
        missionAvatarCache: _profileAvatarCache,
        requestComposerFocus: true,
      ),
    );
    if (!mounted) return;
    setState(() => _rooms = _roomStore.load(widget.connection.id));
    await _load(refresh: true);
  }

  Future<void> _openRoomTask(MissionRoomTaskLink link) async {
    final observer = widget.roomTaskOpenObserver;
    if (observer != null) {
      observer(link);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TasksScreen(
          connection: widget.connection,
          initialBoard: link.boardId == MissionRoomTaskLink.legacyCurrentBoard
              ? null
              : link.boardId,
          initialTaskId: link.taskId,
        ),
      ),
    );
  }

  Future<void> _openTasks({String? assignee}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TasksScreen(
          connection: widget.connection,
          initialAssignee: assignee,
        ),
      ),
    );
  }

  void _openRoutines({String? profile}) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          CronScreen(connection: widget.connection, profileOverride: profile),
    ),
  );

  void _openMemory({String? profile}) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          MemoryScreen(connection: widget.connection, profileOverride: profile),
    ),
  );

  void _openSkills({String? profile}) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          SkillsScreen(connection: widget.connection, profileOverride: profile),
    ),
  );

  void _openSoul() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SoulScreen(connection: widget.connection),
    ),
  );

  Future<void> _openProfiles() async {
    if (widget.connection.readOnly) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProfilesScreen(
          connection: widget.connection,
          connManager: widget.connManager,
        ),
      ),
    );
    if (mounted) await _load(refresh: true);
  }

  /// Edición de la identidad visible del bot (nombre, cara, sprite). Al
  /// guardar se invalida el caché de avatares y se relee el roster para que
  /// la ficha y las listas pinten el sprite nuevo al volver.
  Future<void> _openProfileEditor(AgentProfile profile) async {
    if (widget.connection.readOnly) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ProfileEditorScreen(
          connection: widget.connection,
          profile: profile,
        ),
      ),
    );
    if (saved == true && mounted) {
      _profileAvatarCache?.clear();
      await _load(refresh: true);
    }
  }

  /// Creación con paridad Bot Mode: el diálogo materializa el profile con
  /// `profiles.create` y, como Desktop, el bot recién creado abre su Bot Chat
  /// con el prompt kickoff para presentarse (primer turno que además
  /// materializa y fija el chat canónico oculto).
  Future<void> _createAgentFromMission() async {
    if (widget.connection.readOnly) return;
    final snapshot = _snapshot;
    if (snapshot == null) return;
    final created = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => BotCreateScreen(
          connection: widget.connection,
          existing: snapshot.profiles.map((profile) => profile.name).toSet(),
          gateway: widget.botCreateGateway,
          modelOptionsLoader: widget.modelOptionsLoader,
        ),
      ),
    );
    if (!mounted || created == null) return;
    await _load(refresh: true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(MissionControlCopy.of(context).agentCreated(created)),
      ),
    );
    final freshSnapshot = _snapshot;
    if (freshSnapshot == null) return;
    final projection = _projection(freshSnapshot);
    for (final agent in projection.agents) {
      if (agent.profile.name != created) continue;
      // Sin pin canónico todavía: este nacimiento lleva kickoff. Un bot
      // importado que Desktop ya hubiera nacido abre su chat normal.
      await _openChat(
        agent,
        kickoffPrompt: agent.profile.botChatSessionId == null
            ? kBotChatKickoffPrompt
            : null,
      );
      return;
    }
  }

  Future<void> _showWorkspaceSelector() async {
    final copy = MissionControlCopy.of(context);
    final action = await showHermesFloatingSurface<_WorkspaceAction>(
      context: context,
      surfaceKey: const ValueKey('mission-workspace-selector'),
      maxWidth: 520,
      maxHeightFactor: 0.84,
      builder: (sheetContext) => _WorkspaceSheet(
        copy: copy,
        organizations: _organizations,
        selectedId: _selectedOrganizationId,
        readOnly: widget.connection.readOnly,
      ),
    );
    if (!mounted || action == null) return;
    switch (action.kind) {
      case _WorkspaceActionKind.select:
        setState(() => _selectedOrganizationId = action.organization?.id);
      case _WorkspaceActionKind.create:
        await _editOrganization();
      case _WorkspaceActionKind.edit:
        final organization = action.organization;
        if (organization != null) await _editOrganization(organization);
      case _WorkspaceActionKind.delete:
        final organization = action.organization;
        if (organization != null) await _deleteOrganization(organization);
    }
  }

  void _openAttentionOverview() {
    setState(() => _destination = _MissionDestination.work);
  }

  @override
  Widget build(BuildContext context) {
    final copy = MissionControlCopy.of(context);
    final snapshot = _snapshot;
    final connected =
        snapshot?.profilesCapability == MissionCapabilityState.available ||
        snapshot?.sessionsCapability == MissionCapabilityState.available ||
        snapshot?.kanbanCapability == MissionCapabilityState.available;
    return Scaffold(
      drawerEnableOpenDragGesture: true,
      drawerEdgeDragWidth: HermesDrawer.edgeDragWidth(context),
      drawer: HermesDrawer(
        connection: widget.connection,
        connManager: widget.connManager,
        current: DrawerSection.missionControl,
        connected: connected,
        checking: _loading,
        onSectionReturn: () => _load(refresh: true),
      ),
      appBar: HermesAppBar(
        titleSpacing: 0,
        title: Semantics(
          button: true,
          label: copy.chooseWorkspace,
          child: InkWell(
            key: const ValueKey('mission-workspace-button'),
            onTap: _showWorkspaceSelector,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selectedOrganization?.name ?? copy.allAgents,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          copy.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Theme.of(context).hermes.textSecondary,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 3),
                  const Icon(Icons.expand_more_rounded, size: 19),
                ],
              ),
            ),
          ),
        ),
        actions: [
          if (_refreshing)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              tooltip: copy.refresh,
              onPressed: () => _load(refresh: true),
              icon: const Icon(Icons.refresh_rounded),
              style: IconButton.styleFrom(
                backgroundColor: Theme.of(
                  context,
                ).hermes.surfaceVariant.withValues(alpha: 0.44),
                minimumSize: const Size.square(44),
                shape: const CircleBorder(),
              ),
            ),
        ],
      ),
      body: _buildBody(copy),
      bottomNavigationBar: _MissionNavigationBar(
        selectedIndex: _destination.index,
        onDestinationSelected: (index) =>
            setState(() => _destination = _MissionDestination.values[index]),
        copy: copy,
      ),
    );
  }

  Widget _buildBody(MissionControlCopy copy) {
    if (_loading && _snapshot == null) {
      return _CenteredState(
        icon: Icons.hub_outlined,
        text: copy.loading,
        loading: true,
      );
    }
    if (_loadFailure != null && _snapshot == null) {
      return _CenteredState(
        icon: Icons.cloud_off_outlined,
        text: copy.offline,
        actionLabel: copy.retry,
        onAction: _load,
      );
    }
    final snapshot = _snapshot;
    if (snapshot == null) return const SizedBox.shrink();
    final projection = _projection(snapshot);
    final unavailableSources = [
      if (snapshot.failures.containsKey('profiles') &&
          snapshot.profilesCapability == MissionCapabilityState.unavailable)
        'profiles',
      if (snapshot.failures.containsKey('sessions') &&
          snapshot.sessionsCapability == MissionCapabilityState.unavailable)
        'sessions',
      if (snapshot.failures.containsKey('kanban') &&
          snapshot.kanbanCapability == MissionCapabilityState.unavailable)
        'kanban',
    ];
    return Column(
      children: [
        if (_loadFailure != null || unavailableSources.length == 3)
          _InlineNotice(icon: Icons.cloud_off_outlined, text: copy.offline)
        else if (unavailableSources.isNotEmpty)
          _InlineNotice(
            icon: Icons.history_toggle_off_outlined,
            text: copy.staleData,
          ),
        if (projection.missingProfileCount > 0)
          _InlineNotice(
            icon: Icons.person_off_outlined,
            text: copy.staleProfiles,
          ),
        if (projection.unattributedSessionCount > 0)
          _InlineNotice(
            icon: Icons.link_off_outlined,
            text: copy.unattributedSessions(
              projection.unattributedSessionCount,
            ),
          ),
        Expanded(
          child: IndexedStack(
            index: _destination.index,
            children: [
              _BotsTab(
                connectionId: widget.connection.id,
                snapshot: snapshot,
                projection: projection,
                copy: copy,
                avatarCache: _profileAvatarCache,
                activityStore: _botActivityStore,
                onOpenChat: _openChat,
                onDetails: _openAgent,
                onAttention:
                    projection.approvals.isNotEmpty ||
                        projection.blockedCount > 0
                    ? _openAttentionOverview
                    : null,
                onCreateAgent:
                    widget.connection.readOnly ||
                        snapshot.profilesCapability !=
                            MissionCapabilityState.available
                    ? null
                    : _createAgentFromMission,
              ),
              _RoomsTab(
                rooms: _rooms,
                organization: _selectedOrganization,
                snapshot: snapshot,
                projection: projection,
                copy: copy,
                avatarCache: _profileAvatarCache,
                onOpen: _openRoomDetail,
                onOpenTask: _openRoomTask,
                onApproval: _reviewApproval,
                onRefresh: () => _load(refresh: true),
                onOpenKanban: _openTasks,
                onCreateRoom:
                    widget.connection.readOnly ||
                        snapshot.profilesCapability !=
                            MissionCapabilityState.available ||
                        projection.agents.length < 2
                    ? null
                    : _editRoom,
                onEdit:
                    widget.connection.readOnly ||
                        snapshot.profilesCapability !=
                            MissionCapabilityState.available
                    ? null
                    : _editRoom,
                onDelete: widget.connection.readOnly ? null : _deleteRoom,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MissionNavigationBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final MissionControlCopy copy;

  const _MissionNavigationBar({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.copy,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final compact =
        MediaQuery.sizeOf(context).width < 360 ||
        MediaQuery.textScalerOf(context).scale(14) > 19;
    final destinations =
        <({IconData icon, IconData selectedIcon, String label})>[
          (
            icon: Icons.smart_toy_outlined,
            selectedIcon: Icons.smart_toy_rounded,
            label: copy.bots,
          ),
          (
            icon: Icons.work_outline_rounded,
            selectedIcon: Icons.work_rounded,
            label: copy.work,
          ),
        ];
    return ColoredBox(
      color: colors.background,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(16, 7, 16, 10),
        child: Center(
          heightFactor: 1,
          child: Material(
            color: colors.surface.withValues(alpha: 0.98),
            shape: StadiumBorder(
              side: BorderSide(color: colors.divider.withValues(alpha: 0.72)),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var index = 0; index < destinations.length; index++)
                    _MissionDockDestination(
                      controlKey: ValueKey(
                        'mission-destination-${_MissionDestination.values[index].name}',
                      ),
                      icon: destinations[index].icon,
                      selectedIcon: destinations[index].selectedIcon,
                      label: destinations[index].label,
                      selected: selectedIndex == index,
                      compact: compact,
                      onTap: () => onDestinationSelected(index),
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

class _MissionDockDestination extends StatelessWidget {
  final Key controlKey;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  const _MissionDockDestination({
    required this.controlKey,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: Material(
          color: selected
              ? colors.accent.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
          child: InkWell(
            key: controlKey,
            onTap: onTap,
            borderRadius: BorderRadius.circular(22),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              child: AnimatedSize(
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: !compact ? 14 : 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        selected ? selectedIcon : icon,
                        size: 21,
                        color: selected
                            ? colors.accentText
                            : colors.textSecondary,
                      ),
                      if (!compact) ...[
                        const SizedBox(width: 7),
                        Text(
                          label,
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _WorkspaceActionKind { select, create, edit, delete }

final class _WorkspaceAction {
  final _WorkspaceActionKind kind;
  final MissionOrganization? organization;

  const _WorkspaceAction(this.kind, [this.organization]);
}

class _WorkspaceSheet extends StatelessWidget {
  final MissionControlCopy copy;
  final List<MissionOrganization> organizations;
  final String? selectedId;
  final bool readOnly;

  const _WorkspaceSheet({
    required this.copy,
    required this.organizations,
    required this.selectedId,
    required this.readOnly,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return SafeArea(
      top: false,
      child: ListView(
        key: const ValueKey('mission-workspace-sheet'),
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 14),
            child: Text(
              copy.workspaces,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.25,
              ),
            ),
          ),
          Material(
            color: selectedId == null
                ? colors.accent.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            child: ListTile(
              key: const ValueKey('mission-workspace-all'),
              leading: const Icon(Icons.hub_outlined),
              title: Text(copy.allAgents),
              subtitle: Text(copy.title),
              trailing: selectedId == null
                  ? Icon(Icons.check_rounded, color: colors.accentText)
                  : null,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              onTap: () => Navigator.pop(
                context,
                const _WorkspaceAction(_WorkspaceActionKind.select),
              ),
            ),
          ),
          for (final organization in organizations)
            Builder(
              builder: (context) {
                final manager = organization.managerProfile?.trim();
                final agentCount = copy.workspaceAgentCount(
                  organization.profileNames.length,
                );
                final subtitle = manager == null || manager.isEmpty
                    ? agentCount
                    : '@$manager · $agentCount';
                return Material(
                  color: organization.id == selectedId
                      ? colors.accent.withValues(alpha: 0.08)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                  child: ListTile(
                    key: ValueKey('mission-workspace-${organization.id}'),
                    leading: CircleAvatar(
                      backgroundColor: colors.surfaceVariant,
                      child: Text(
                        organization.name.characters.first.toUpperCase(),
                      ),
                    ),
                    title: Text(organization.name),
                    subtitle: Text(subtitle),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (organization.id == selectedId)
                          Icon(Icons.check_rounded, color: colors.accentText),
                        if (!readOnly)
                          PopupMenuButton<_WorkspaceActionKind>(
                            key: ValueKey(
                              'mission-workspace-menu-${organization.id}',
                            ),
                            icon: const Icon(Icons.more_horiz_rounded),
                            onSelected: (kind) => Navigator.pop(
                              context,
                              _WorkspaceAction(kind, organization),
                            ),
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: _WorkspaceActionKind.edit,
                                child: Text(copy.editOrganization),
                              ),
                              PopupMenuItem(
                                value: _WorkspaceActionKind.delete,
                                child: Text(
                                  copy.delete,
                                  style: TextStyle(color: colors.error),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    onTap: () => Navigator.pop(
                      context,
                      _WorkspaceAction(
                        _WorkspaceActionKind.select,
                        organization,
                      ),
                    ),
                  ),
                );
              },
            ),
          if (!readOnly) ...[
            const SizedBox(height: 8),
            Divider(color: colors.divider.withValues(alpha: 0.55)),
            ListTile(
              key: const ValueKey('mission-workspace-create'),
              leading: const Icon(Icons.add_rounded),
              title: Text(copy.createOrganization),
              onTap: () => Navigator.pop(
                context,
                const _WorkspaceAction(_WorkspaceActionKind.create),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _WorkActivityGroup extends StatelessWidget {
  final List<MissionActivity> activity;
  final MissionControlCopy copy;

  const _WorkActivityGroup({
    required this.activity,
    required this.copy,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (activity.isEmpty) return _MessageCard(text: copy.noActivity);
    final colors = Theme.of(context).hermes;
    return HermesCard(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 2),
      child: Column(
        children: [
          for (var index = 0; index < activity.length; index++) ...[
            _WorkActivityEvent(
              key: ValueKey(
                'mission-work-activity-event-${activity[index].stableId}',
              ),
              event: activity[index],
              copy: copy,
            ),
            if (index != activity.length - 1)
              Divider(height: 1, color: colors.divider.withValues(alpha: 0.62)),
          ],
        ],
      ),
    );
  }
}

class _WorkActivityEvent extends StatelessWidget {
  final MissionActivity event;
  final MissionControlCopy copy;

  const _WorkActivityEvent({
    required this.event,
    required this.copy,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final color = _workActivityColor(colors, event.kind);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.11),
              shape: BoxShape.circle,
            ),
            child: Icon(_workActivityIcon(event.kind), size: 16, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    copy.activityLabel(event.kind.name),
                    event.profileName ?? copy.unknown,
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _clock(event.timestamp),
            style: TextStyle(
              color: colors.textDisabled,
              fontSize: 11,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

Color _workActivityColor(HermesThemeColors colors, MissionActivityKind kind) =>
    switch (kind) {
      MissionActivityKind.taskBlocked => colors.error,
      MissionActivityKind.taskStarted => colors.success,
      MissionActivityKind.taskCompleted => colors.accentText,
      MissionActivityKind.taskCreated => colors.warning,
      MissionActivityKind.sessionUpdated => colors.textSecondary,
    };

IconData _workActivityIcon(MissionActivityKind kind) => switch (kind) {
  MissionActivityKind.sessionUpdated => Icons.chat_bubble_outline_rounded,
  MissionActivityKind.taskCreated => Icons.add_task_rounded,
  MissionActivityKind.taskStarted => Icons.play_arrow_rounded,
  MissionActivityKind.taskCompleted => Icons.check_rounded,
  MissionActivityKind.taskBlocked => Icons.block_rounded,
};

class _BotsTab extends StatefulWidget {
  final String connectionId;
  final MissionBackendSnapshot snapshot;
  final MissionProjection projection;
  final MissionControlCopy copy;
  final MissionProfileAvatarCache? avatarCache;
  final MissionBotActivityStore activityStore;
  final ValueChanged<MissionAgent> onOpenChat;
  final ValueChanged<MissionAgent> onDetails;
  final VoidCallback? onAttention;
  final VoidCallback? onCreateAgent;

  const _BotsTab({
    required this.connectionId,
    required this.snapshot,
    required this.projection,
    required this.copy,
    required this.avatarCache,
    required this.activityStore,
    required this.onOpenChat,
    required this.onDetails,
    required this.onAttention,
    required this.onCreateAgent,
  });

  @override
  State<_BotsTab> createState() => _BotsTabState();
}

class _BotsTabState extends State<_BotsTab> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  bool _showHidden = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Preview del Bot Chat pineado usando solo el snapshot ya cargado. Los pins
  /// locales viven en secure storage; resolverlos por fila añadiría lecturas
  /// asíncronas al scroll, así que solo se proyecta el pin oficial de Desktop.
  Session? _pinnedBotChat(MissionAgent agent) {
    final pin = agent.profile.botChatSessionId;
    if (pin == null) return null;
    for (final session in widget.snapshot.sessions) {
      if (session.id == pin || session.logicalId == pin) return session;
    }
    return null;
  }

  /// Actividad del bot como en Bot Mode de Desktop (`activityOf`): el máximo
  /// entre el sello `created` publicado en `ui_meta` (un bot recién creado
  /// encabeza la lista) y su último mensaje. Los empates se resuelven por
  /// nombre para que el orden sea estable entre refrescos.
  /// "needs you": el bot espera al usuario (aprobación viva publicada por el
  /// gateway vía ActiveChatService, o tarea Kanban bloqueada). Si el gateway
  /// no expone ninguna de las dos señales, el badge simplemente no aparece —
  /// degradación silenciosa, nunca un falso positivo.
  static bool _needsYou(MissionAgent agent) =>
      agent.approval != null ||
      agent.status == MissionAgentStatus.approvalRequired ||
      agent.status == MissionAgentStatus.blocked;

  static bool _activeNow(MissionAgent agent) => switch (agent.status) {
    MissionAgentStatus.thinking ||
    MissionAgentStatus.working ||
    MissionAgentStatus.responding => true,
    _ => false,
  };

  bool _matches(MissionAgent agent) {
    final query = _foldBotSearch(_query);
    if (query.isEmpty) return true;
    return [
      agent.profile.name,
      agent.profile.botTitle,
      agent.profile.botGroup,
      agent.profile.description,
      agent.model,
      agent.provider,
    ].whereType<String>().any((value) => _foldBotSearch(value).contains(query));
  }

  List<Widget> _botRows(BuildContext context, List<MissionAgent> agents) {
    final widgets = <Widget>[];
    for (var index = 0; index < agents.length; index++) {
      final agent = agents[index];
      final activityAtMs = _missionBotActivityMs(agent);
      widgets.add(
        _BotRow(
          key: ValueKey('mission-bot-row-${agent.profile.name}'),
          agent: agent,
          pinnedChat: _pinnedBotChat(agent),
          needsYou: _needsYou(agent),
          unread: widget.activityStore.isUnread(
            widget.connectionId,
            agent.profile.name,
            activityAtMs,
          ),
          copy: widget.copy,
          avatarCache: widget.avatarCache,
          onOpen: () => widget.onOpenChat(agent),
          onDetails: () => widget.onDetails(agent),
        ),
      );
      if (index != agents.length - 1) {
        widgets.add(
          Divider(
            height: 1,
            indent: 58,
            color: Theme.of(context).hermes.divider.withValues(alpha: 0.5),
          ),
        );
      }
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final copy = widget.copy;
    final allAgents = [...widget.projection.agents]
      ..sort((left, right) {
        final byPinned = (right.profile.botPinned ? 1 : 0).compareTo(
          left.profile.botPinned ? 1 : 0,
        );
        if (byPinned != 0) return byPinned;
        final byActivity = _missionBotActivityMs(
          right,
        ).compareTo(_missionBotActivityMs(left));
        return byActivity != 0
            ? byActivity
            : left.profile.name.compareTo(right.profile.name);
      });
    final hiddenCount = allAgents
        .where((agent) => agent.profile.botHidden)
        .length;
    final agents = allAgents
        .where((agent) => _showHidden || !agent.profile.botHidden)
        .where(_matches)
        .toList(growable: false);
    final active = _query.trim().isEmpty
        ? agents.where(_activeNow).toList(growable: false)
        : const <MissionAgent>[];
    final resting = _query.trim().isEmpty
        ? agents.where((agent) => !_activeNow(agent)).toList(growable: false)
        : agents;
    return ListView(
      key: const ValueKey('mission-bots'),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
      children: [
        if (widget.projection.approvals.isNotEmpty ||
            widget.projection.blockedCount > 0) ...[
          Material(
            color: Colors.transparent,
            child: InkWell(
              key: const ValueKey('mission-attention'),
              onTap: widget.onAttention,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).hermes.warning.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).hermes.warning.withValues(alpha: 0.24),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.notifications_active_outlined,
                      size: 18,
                      color: Theme.of(context).hermes.warning,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            copy.needsYou,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            copy.attentionSummary(
                              widget.projection.approvals.length,
                              widget.projection.blockedCount,
                            ),
                            style: TextStyle(
                              color: Theme.of(context).hermes.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (widget.onAttention != null)
                      const Icon(Icons.chevron_right_rounded),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 22),
        ],
        _LoungeSectionHeader(
          title: copy.bots,
          subtitle: copy.botCount(allAgents.length),
          actionKey: const ValueKey('mission-create-agent'),
          actionLabel: copy.newAgent,
          actionIcon: Icons.person_add_alt_1_rounded,
          onAction: widget.onCreateAgent,
        ),
        const SizedBox(height: 14),
        if (widget.snapshot.profilesCapability ==
            MissionCapabilityState.unsupported)
          _MessageCard(text: copy.profilesUnavailable)
        else if (allAgents.isEmpty)
          _LoungeEmptyState(
            icon: Icons.smart_toy_outlined,
            message: copy.noBots,
            actionLabel: copy.newAgent,
            onAction: widget.onCreateAgent,
          )
        else ...[
          HermesSearchField(
            key: const ValueKey('mission-bot-search'),
            controller: _searchController,
            hintText: copy.searchAgents,
            clearTooltip: copy.clearSearch,
            onChanged: (value) => setState(() => _query = value),
          ),
          if (hiddenCount > 0) ...[
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('mission-show-hidden'),
                onPressed: () => setState(() => _showHidden = !_showHidden),
                icon: Icon(
                  _showHidden
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 17,
                ),
                label: Text(
                  _showHidden
                      ? copy.hideHiddenBots
                      : copy.showHiddenBots(hiddenCount),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).hermes.textSecondary,
                  minimumSize: const Size(44, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          if (agents.isEmpty)
            _MessageCard(text: copy.noMatchingAgents)
          else ...[
            if (active.isNotEmpty) ...[
              _BotSectionLabel(
                key: const ValueKey('mission-active-now'),
                title: copy.activeNow,
                count: active.length,
              ),
              const SizedBox(height: 4),
              ..._botRows(context, active),
              if (resting.isNotEmpty) const SizedBox(height: 18),
            ],
            if (resting.isNotEmpty) ...[
              _BotSectionLabel(
                title: _query.trim().isNotEmpty
                    ? copy.searchResults
                    : active.isNotEmpty
                    ? copy.otherBots
                    : copy.allBots,
                count: resting.length,
              ),
              const SizedBox(height: 4),
              ..._botRows(context, resting),
            ],
          ],
        ],
      ],
    );
  }
}

int _missionBotActivityMs(MissionAgent agent) {
  final created = agent.profile.botModeUiMeta['created'];
  final createdMs = created is num && created > 0 ? created.toInt() : 0;
  final lastMs = agent.lastActivityAt?.millisecondsSinceEpoch ?? 0;
  return createdMs > lastMs ? createdMs : lastMs;
}

String _foldBotSearch(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[áàäâãå]'), 'a')
    .replaceAll(RegExp(r'[éèëê]'), 'e')
    .replaceAll(RegExp(r'[íìïî]'), 'i')
    .replaceAll(RegExp(r'[óòöôõ]'), 'o')
    .replaceAll(RegExp(r'[úùüû]'), 'u')
    .replaceAll('ñ', 'n')
    .replaceAll(RegExp(r'\s+'), ' ');

class _BotSectionLabel extends StatelessWidget {
  final String title;
  final int count;

  const _BotSectionLabel({required this.title, required this.count, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Text(
          '$count',
          style: TextStyle(
            color: colors.textDisabled,
            fontSize: 12,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

final class _RoomDetailData {
  final MissionRoom room;
  final MissionBackendSnapshot snapshot;
  final MissionRoomWorkProjection work;

  const _RoomDetailData({
    required this.room,
    required this.snapshot,
    required this.work,
  });
}

class _MissionRoomDetailScreen extends StatelessWidget {
  final MissionRoom room;
  final MissionBackendSnapshot snapshot;
  final MissionRoomWorkProjection roomWork;
  final MissionControlCopy copy;
  final MissionProfileAvatarCache? avatarCache;
  final bool readOnly;
  final bool canOpenChat;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onOpenChat;
  final Future<void> Function(MissionRoomTaskLink) onOpenTask;
  final Future<void> Function() onOpenKanban;
  final Future<void> Function()? onEdit;
  final Future<void> Function()? onDelete;

  const _MissionRoomDetailScreen({
    required this.room,
    required this.snapshot,
    required this.roomWork,
    required this.copy,
    required this.avatarCache,
    required this.readOnly,
    required this.canOpenChat,
    required this.onRefresh,
    required this.onOpenChat,
    required this.onOpenTask,
    required this.onOpenKanban,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final profiles = <String, AgentProfile>{
      for (final profile in snapshot.profiles) profile.name: profile,
    };
    final hasApproval = roomWork.approvals.isNotEmpty;
    final stateColor = roomWork.spineState == MissionRoomSpineState.blocked
        ? colors.error
        : hasApproval
        ? colors.warning
        : switch (roomWork.spineState) {
            MissionRoomSpineState.active => colors.success,
            MissionRoomSpineState.warning => colors.warning,
            MissionRoomSpineState.neutral => colors.divider,
            MissionRoomSpineState.blocked => colors.error,
          };
    final stateLabel = roomWork.spineState == MissionRoomSpineState.blocked
        ? copy.roomBlocked
        : hasApproval
        ? copy.needsYou
        : switch (roomWork.spineState) {
            MissionRoomSpineState.active => copy.roomActive,
            MissionRoomSpineState.warning => copy.roomReview,
            MissionRoomSpineState.neutral => null,
            MissionRoomSpineState.blocked => copy.roomBlocked,
          };
    return Scaffold(
      appBar: HermesAppBar(
        title: Text('#${room.name}'),
        actions: [
          if (!readOnly && (onEdit != null || onDelete != null))
            PopupMenuButton<String>(
              key: ValueKey('room-detail-menu-${room.id}'),
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (value) async {
                if (value == 'edit') {
                  await onEdit?.call();
                }
                if (value == 'delete') {
                  await onDelete?.call();
                }
              },
              itemBuilder: (_) => [
                if (onEdit != null)
                  PopupMenuItem(value: 'edit', child: Text(copy.editRoom)),
                if (onDelete != null)
                  PopupMenuItem(value: 'delete', child: Text(copy.delete)),
              ],
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: RefreshIndicator(
            onRefresh: onRefresh,
            child: ListView(
              key: ValueKey('mission-room-detail-${room.id}'),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                _RoomDetailSection(
                  title: copy.roomSummary,
                  child: Container(
                    decoration: BoxDecoration(
                      color: colors.surface,
                      border: Border.all(
                        color: colors.divider.withValues(alpha: 0.6),
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(width: 4, color: stateColor),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                14,
                                14,
                                14,
                                15,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      _RoomMemberStack(
                                        room: room,
                                        profiles: profiles,
                                        avatarCache: avatarCache,
                                      ),
                                      const SizedBox(width: 11),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            if (stateLabel != null) ...[
                                              Text(
                                                stateLabel,
                                                style: TextStyle(
                                                  color: stateColor,
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 12,
                                                ),
                                              ),
                                              const SizedBox(height: 3),
                                            ],
                                            Text(
                                              room.purposeLabel.isEmpty
                                                  ? copy.roomNoPurpose
                                                  : room.purposeLabel,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                height: 1.35,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 13),
                                  Wrap(
                                    spacing: 18,
                                    runSpacing: 8,
                                    children: [
                                      _RoomInlineFact(
                                        label: copy.roomCoordinatorShort,
                                        value: '@${room.managerProfile}',
                                      ),
                                      _RoomInlineFact(
                                        label: copy.roomTeam,
                                        value: copy.roomMemberCount(
                                          room.memberProfiles.length,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (roomWork.approvals.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  for (final approval in roomWork.approvals.take(3))
                    _GlobalWorkAction(
                      key: ValueKey(
                        'room-approval-${approval.sessionId}-${approval.requestId ?? ''}',
                      ),
                      icon: Icons.approval_outlined,
                      color: colors.warning,
                      title: approval.description,
                      subtitle: copy.needsYou,
                      onTap: () => unawaited(onOpenChat()),
                    ),
                ],
                const SizedBox(height: 14),
                FilledButton.icon(
                  key: ValueKey('room-open-chat-${room.id}'),
                  onPressed: canOpenChat ? () => unawaited(onOpenChat()) : null,
                  icon: const Icon(Icons.chat_bubble_outline_rounded, size: 19),
                  label: Text(copy.talkToCoordinator(room.managerProfile)),
                ),
                const SizedBox(height: 24),
                _RoomDetailSection(
                  title: copy.roomTasks,
                  child: roomWork.linkedTasks.isEmpty
                      ? _MessageCard(text: copy.roomNoLinkedWork)
                      : Column(
                          children: [
                            for (final entry in roomWork.linkedTasks)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: entry.task != null
                                    ? _RoomTaskLine(
                                        key: ValueKey(
                                          'room-detail-task-${entry.link.boardId}-${entry.link.taskId}',
                                        ),
                                        task: entry.task!,
                                        copy: copy,
                                        onTap: () =>
                                            unawaited(onOpenTask(entry.link)),
                                      )
                                    : _RoomUnavailableTaskLine(
                                        key: ValueKey(
                                          'room-detail-task-${entry.link.boardId}-${entry.link.taskId}',
                                        ),
                                        link: entry.link,
                                        copy: copy,
                                        onTap: () =>
                                            unawaited(onOpenTask(entry.link)),
                                      ),
                              ),
                          ],
                        ),
                ),
                const SizedBox(height: 24),
                _RoomDetailSection(
                  title: copy.roomActivity,
                  child: roomWork.activity.isEmpty
                      ? _MessageCard(text: copy.roomNoActivity)
                      : _WorkActivityGroup(
                          key: ValueKey('room-activity-${room.id}'),
                          activity: roomWork.activity,
                          copy: copy,
                        ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton.icon(
                    key: ValueKey('room-open-kanban-${room.id}'),
                    onPressed: () => unawaited(onOpenKanban()),
                    icon: const Icon(Icons.view_kanban_outlined, size: 17),
                    label: Text(copy.openKanban),
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

class _RoomDetailSection extends StatelessWidget {
  final String title;
  final Widget child;

  const _RoomDetailSection({required this.title, required this.child});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      child,
    ],
  );
}

class _RoomsTab extends StatelessWidget {
  final List<MissionRoom> rooms;
  final MissionOrganization? organization;
  final MissionBackendSnapshot snapshot;
  final MissionProjection projection;
  final MissionControlCopy copy;
  final MissionProfileAvatarCache? avatarCache;
  final ValueChanged<MissionRoom> onOpen;
  final ValueChanged<MissionRoomTaskLink> onOpenTask;
  final ValueChanged<MissionApproval> onApproval;
  final Future<void> Function() onRefresh;
  final VoidCallback onOpenKanban;
  final VoidCallback? onCreateRoom;
  final ValueChanged<MissionRoom>? onEdit;
  final ValueChanged<MissionRoom>? onDelete;

  const _RoomsTab({
    required this.rooms,
    required this.organization,
    required this.snapshot,
    required this.projection,
    required this.copy,
    required this.avatarCache,
    required this.onOpen,
    required this.onOpenTask,
    required this.onApproval,
    required this.onRefresh,
    required this.onOpenKanban,
    required this.onCreateRoom,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scoped = organization == null
        ? rooms
        : rooms
              .where((room) => room.organizationId == organization!.id)
              .toList(growable: false);
    final profiles = <String, AgentProfile>{
      for (final profile in snapshot.profiles) profile.name: profile,
    };
    final workSet = MissionRoomWorkProjector.build(
      rooms: scoped,
      snapshot: snapshot,
      mission: projection,
      ownershipRooms: rooms,
    );
    final canOpen =
        snapshot.profilesCapability == MissionCapabilityState.available;
    final roomRows = scoped
        .map((room) {
          final roomWork = workSet.forRoom(room.id)!;
          return _RoomFirstCard(
            key: ValueKey('mission-room-${room.id}'),
            room: room,
            work: roomWork,
            copy: copy,
            profiles: profiles,
            avatarCache: avatarCache,
            onOpen: () => onOpen(room),
            onOpenTask: onOpenTask,
            onEdit: onEdit == null ? null : () => onEdit!(room),
            onDelete: onDelete == null ? null : () => onDelete!(room),
          );
        })
        .toList(growable: false);
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        key: const ValueKey('mission-work-feed'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
        children: [
          KeyedSubtree(
            key: const ValueKey('mission-rooms'),
            child: _LoungeSectionHeader(
              title: copy.rooms,
              subtitle: copy.roomCount(scoped.length),
              actionKey: const ValueKey('mission-create-room'),
              actionLabel: copy.createRoom,
              actionIcon: Icons.add_rounded,
              onAction: onCreateRoom,
            ),
          ),
          const SizedBox(height: 7),
          if (!canOpen) ...[
            _InlineNotice(
              icon: Icons.visibility_outlined,
              text: copy.roomsBrowseOnly,
            ),
            const SizedBox(height: 6),
          ],
          if (scoped.isEmpty)
            _RoomsEmptyState(
              message: projection.agents.length < 2
                  ? copy.needMoreBots
                  : copy.noRooms,
              actionLabel: copy.createRoom,
              onCreate: projection.agents.length < 2 ? null : onCreateRoom,
            )
          else
            ...roomRows,
          const SizedBox(height: 12),
          if (snapshot.kanbanCapability != MissionCapabilityState.available)
            _MessageCard(text: copy.kanbanUnavailable),
          _GlobalWorkTray(
            work: workSet.unscoped,
            copy: copy,
            onApproval: onApproval,
            onOpenKanban: onOpenKanban,
            onOpenTask: onOpenTask,
          ),
        ],
      ),
    );
  }
}

class _GlobalWorkTray extends StatelessWidget {
  final UnscopedMissionWorkProjection work;
  final MissionControlCopy copy;
  final ValueChanged<MissionApproval> onApproval;
  final VoidCallback onOpenKanban;
  final ValueChanged<MissionRoomTaskLink> onOpenTask;

  const _GlobalWorkTray({
    required this.work,
    required this.copy,
    required this.onApproval,
    required this.onOpenKanban,
    required this.onOpenTask,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final activeTasks = work.tasks
        .where(
          (entry) => const {
            'ready',
            'running',
            'blocked',
            'review',
          }.contains(entry.task?.status),
        )
        .length;
    final visibleTasks =
        work.tasks
            .where(
              (entry) => const {
                'ready',
                'running',
                'blocked',
                'review',
              }.contains(entry.task?.status),
            )
            .toList(growable: true)
          ..sort(
            (left, right) => _globalTaskPriority(
              left.task?.status,
            ).compareTo(_globalTaskPriority(right.task?.status)),
          );
    if (work.approvals.isEmpty && activeTasks == 0) {
      return Align(
        alignment: AlignmentDirectional.centerEnd,
        child: TextButton.icon(
          key: const ValueKey('mission-open-global-kanban'),
          onPressed: onOpenKanban,
          icon: const Icon(Icons.view_kanban_outlined, size: 18),
          label: Text(copy.openKanban),
        ),
      );
    }
    return Semantics(
      container: true,
      label: copy.globalWorkTray,
      child: HermesCard(
        key: const ValueKey('mission-global-work-tray'),
        padding: const EdgeInsets.fromLTRB(14, 13, 10, 9),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.surfaceVariant.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.inbox_outlined,
                    size: 18,
                    color: work.approvals.isNotEmpty
                        ? colors.warning
                        : colors.accentText,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        copy.globalWorkTray,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final approval in work.approvals.take(3))
              _GlobalWorkAction(
                key: ValueKey(
                  'mission-global-approval-${approval.sessionId}-${approval.requestId ?? ''}',
                ),
                icon: Icons.approval_outlined,
                color: colors.warning,
                title: approval.description,
                subtitle: '@${approval.profileName}',
                onTap: () => onApproval(approval),
              ),
            for (final entry in visibleTasks.take(
              work.approvals.length >= 3 ? 0 : 3 - work.approvals.length,
            ))
              _GlobalWorkAction(
                key: ValueKey(
                  'mission-global-task-${entry.link.boardId}-${entry.link.taskId}',
                ),
                icon: switch (entry.task?.status) {
                  'blocked' => Icons.block_outlined,
                  'running' => Icons.play_arrow_rounded,
                  'review' => Icons.rate_review_outlined,
                  _ => Icons.schedule_outlined,
                },
                color: switch (entry.task?.status) {
                  'blocked' => colors.error,
                  'running' => colors.success,
                  'review' => colors.warning,
                  _ => colors.accentText,
                },
                title: entry.task?.title ?? copy.unavailableLinkedWork,
                subtitle: copy.taskStatus(entry.task?.status ?? 'blocked'),
                onTap: () => onOpenTask(entry.link),
              ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                key: const ValueKey('mission-open-global-kanban'),
                onPressed: onOpenKanban,
                icon: const Icon(Icons.view_kanban_outlined, size: 18),
                label: Text(copy.openKanban),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static int _globalTaskPriority(String? status) => switch (status) {
    'blocked' => 0,
    'running' => 1,
    'review' => 2,
    'ready' => 3,
    _ => 4,
  };
}

class _GlobalWorkAction extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _GlobalWorkAction({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
          child: Row(
            children: [
              Icon(icon, size: 17, color: color),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: colors.textDisabled,
                size: 19,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoomFirstCard extends StatelessWidget {
  final MissionRoom room;
  final MissionRoomWorkProjection work;
  final MissionControlCopy copy;
  final Map<String, AgentProfile> profiles;
  final MissionProfileAvatarCache? avatarCache;
  final VoidCallback? onOpen;
  final ValueChanged<MissionRoomTaskLink> onOpenTask;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _RoomFirstCard({
    required this.room,
    required this.work,
    required this.copy,
    required this.profiles,
    required this.avatarCache,
    required this.onOpen,
    required this.onOpenTask,
    required this.onEdit,
    required this.onDelete,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final available = work.linkedTasks.where((entry) => entry.task != null);
    final primary =
        work.primaryTask ?? (available.isEmpty ? null : available.first);
    final unresolved = work.linkedTasks.where((entry) => entry.task == null);
    final hasApproval = work.approvals.isNotEmpty;
    final stateColor = work.spineState == MissionRoomSpineState.blocked
        ? colors.error
        : hasApproval
        ? colors.warning
        : switch (work.spineState) {
            MissionRoomSpineState.active => colors.success,
            MissionRoomSpineState.warning => colors.warning,
            MissionRoomSpineState.neutral => colors.divider,
            MissionRoomSpineState.blocked => colors.error,
          };
    final stateLabel = work.spineState == MissionRoomSpineState.blocked
        ? copy.roomBlocked
        : hasApproval
        ? copy.needsYou
        : switch (work.spineState) {
            MissionRoomSpineState.active => copy.roomActive,
            MissionRoomSpineState.warning => copy.roomReview,
            MissionRoomSpineState.neutral => null,
            MissionRoomSpineState.blocked => copy.roomBlocked,
          };
    return Semantics(
      container: true,
      explicitChildNodes: true,
      button: onOpen != null,
      label: [
        '#${room.name}',
        ?stateLabel,
        room.purposeLabel,
        '@${room.managerProfile}',
      ].where((part) => part.isNotEmpty).join(', '),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: colors.surface,
          borderRadius: BorderRadius.circular(13),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            excludeFromSemantics: true,
            onTap: onOpen,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    key: ValueKey('room-spine-${room.id}'),
                    width: 4,
                    color: stateColor,
                  ),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(
                            color: colors.divider.withValues(alpha: 0.58),
                          ),
                          bottom: BorderSide(
                            color: colors.divider.withValues(alpha: 0.58),
                          ),
                          right: BorderSide(
                            color: colors.divider.withValues(alpha: 0.58),
                          ),
                        ),
                        borderRadius: const BorderRadiusDirectional.horizontal(
                          end: Radius.circular(13),
                        ),
                      ),
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        13,
                        12,
                        7,
                        12,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ExcludeSemantics(
                                child: _RoomMemberStack(
                                  room: room,
                                  profiles: profiles,
                                  avatarCache: avatarCache,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '#${room.name}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 16,
                                        letterSpacing: -0.2,
                                      ),
                                    ),
                                    if (stateLabel != null) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        stateLabel,
                                        style: TextStyle(
                                          color: stateColor,
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              if (onEdit != null || onDelete != null)
                                PopupMenuButton<String>(
                                  tooltip: onEdit != null
                                      ? copy.editRoom
                                      : copy.deleteRoomTitle,
                                  icon: const Icon(
                                    Icons.more_horiz_rounded,
                                    size: 21,
                                  ),
                                  onSelected: (value) {
                                    if (value == 'edit') onEdit?.call();
                                    if (value == 'delete') onDelete?.call();
                                  },
                                  itemBuilder: (_) => [
                                    if (onEdit != null)
                                      PopupMenuItem(
                                        value: 'edit',
                                        child: Text(copy.editRoom),
                                      ),
                                    if (onDelete != null)
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: Text(copy.delete),
                                      ),
                                  ],
                                ),
                            ],
                          ),
                          const SizedBox(height: 11),
                          Text(
                            room.purposeLabel.isEmpty
                                ? copy.roomNoPurpose
                                : room.purposeLabel,
                            key: ValueKey('room-purpose-${room.id}'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: room.purposeLabel.isEmpty
                                  ? colors.textSecondary
                                  : colors.textPrimary,
                              fontSize: 13.5,
                              height: 1.32,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Container(
                            key: ValueKey('room-work-${room.id}'),
                            alignment: AlignmentDirectional.centerStart,
                            child: primary != null
                                ? _RoomTaskLine(
                                    key: ValueKey(
                                      'room-task-${primary.link.boardId}-${primary.link.taskId}',
                                    ),
                                    task: primary.task!,
                                    copy: copy,
                                    onTap: () => onOpenTask(primary.link),
                                  )
                                : unresolved.isNotEmpty
                                ? _RoomUnavailableTaskLine(
                                    link: unresolved.first.link,
                                    copy: copy,
                                    onTap: () =>
                                        onOpenTask(unresolved.first.link),
                                  )
                                : Text(
                                    copy.roomNoLinkedWork,
                                    style: TextStyle(
                                      color: colors.textSecondary,
                                      fontSize: 12.5,
                                    ),
                                  ),
                          ),
                          const SizedBox(height: 9),
                          Container(
                            key: ValueKey('room-footer-${room.id}'),
                            padding: const EdgeInsetsDirectional.only(top: 9),
                            decoration: BoxDecoration(
                              border: Border(
                                top: BorderSide(
                                  color: colors.divider.withValues(alpha: 0.46),
                                ),
                              ),
                            ),
                            child: Wrap(
                              spacing: 18,
                              runSpacing: 8,
                              children: [
                                _RoomInlineFact(
                                  label: copy.roomCoordinatorShort,
                                  value: '@${room.managerProfile}',
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
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

class _RoomInlineFact extends StatelessWidget {
  final String label;
  final String value;

  const _RoomInlineFact({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Wrap(
      spacing: 6,
      runSpacing: 2,
      children: [
        Text(
          label,
          style: TextStyle(color: colors.textDisabled, fontSize: 11.5),
        ),
        Text(
          value,
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _RoomUnavailableTaskLine extends StatelessWidget {
  final MissionRoomTaskLink link;
  final MissionControlCopy copy;
  final VoidCallback onTap;

  const _RoomUnavailableTaskLine({
    required this.link,
    required this.copy,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      key: ValueKey('room-task-${link.boardId}-${link.taskId}'),
      button: true,
      label: copy.unavailableTaskLink(link.boardId, link.taskId),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              Icon(
                Icons.work_outline_rounded,
                size: 14,
                color: colors.textDisabled,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  copy.unavailableLinkedWork,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textSecondary, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoungeSectionHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final Key actionKey;
  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback? onAction;

  const _LoungeSectionHeader({
    required this.title,
    required this.subtitle,
    required this.actionKey,
    required this.actionLabel,
    required this.actionIcon,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final compactAction = MediaQuery.textScalerOf(context).scale(1) > 1.5;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                subtitle,
                style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
              ),
            ],
          ),
        ),
        if (onAction != null && compactAction)
          Tooltip(
            message: actionLabel,
            child: IconButton(
              key: actionKey,
              onPressed: onAction,
              icon: Icon(actionIcon, size: 21),
              style: IconButton.styleFrom(
                foregroundColor: colors.accentText,
                backgroundColor: colors.surfaceVariant.withValues(alpha: 0.5),
                minimumSize: const Size.square(44),
                shape: const CircleBorder(),
              ),
            ),
          ),
        if (onAction != null && !compactAction)
          TextButton.icon(
            key: actionKey,
            onPressed: onAction,
            icon: Icon(actionIcon, size: 19),
            label: Text(actionLabel),
          ),
      ],
    );
  }
}

class _LoungeEmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  final String actionLabel;
  final VoidCallback? onAction;

  const _LoungeEmptyState({
    required this.icon,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 21, color: colors.textDisabled),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 13.5,
                    height: 1.35,
                  ),
                ),
                if (onAction != null) ...[
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: onAction,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(44, 40),
                      alignment: AlignmentDirectional.centerStart,
                    ),
                    child: Text(actionLabel),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Fila única de bot para todo Mission Control: tap abre su Bot Chat y el
/// overflow/long-press abre la ficha. Cuando el snapshot ya contiene la sesión
/// pineada oficialmente, la fila muestra su preview y hora como en Bot Mode.
class _BotRow extends StatelessWidget {
  final MissionAgent agent;
  final Session? pinnedChat;
  final bool needsYou;
  final bool unread;
  final MissionControlCopy copy;
  final MissionProfileAvatarCache? avatarCache;
  final VoidCallback onOpen;
  final VoidCallback onDetails;

  const _BotRow({
    required this.agent,
    required this.copy,
    required this.avatarCache,
    required this.onOpen,
    required this.onDetails,
    this.pinnedChat,
    this.needsYou = false,
    this.unread = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final profile = agent.profile;
    final displayName = profile.botTitle ?? profile.name;
    final hasLiveStatus = agent.status != MissionAgentStatus.idle;
    final preview = pinnedChat?.preview.trim() ?? '';
    final currentTaskTitle = agent.currentTask?.title.trim() ?? '';
    final subtitle = [
      if (displayName != profile.name) '@${profile.name}',
      if (hasLiveStatus && currentTaskTitle.isNotEmpty)
        '${copy.status(agent.status.name)} · $currentTaskTitle'
      else if (preview.isNotEmpty)
        preview
      else if (hasLiveStatus)
        copy.status(agent.status.name)
      else
        copy.botChat,
    ].join(' · ');
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('mission-bot-${profile.name}'),
          onTap: onDetails,
          onLongPress: onDetails,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(4, 10, 0, 10),
            child: Row(
              children: [
                _AgentAvatar(
                  profile: profile,
                  status: agent.status,
                  avatarCache: avatarCache,
                  size: 44,
                  showStatusIndicator: hasLiveStatus,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.1,
                              ),
                            ),
                          ),
                          if (needsYou) ...[
                            const SizedBox(width: 8),
                            Container(
                              key: ValueKey(
                                'mission-bot-needs-you-${profile.name}',
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: colors.warning.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: colors.warning.withValues(alpha: 0.4),
                                ),
                              ),
                              child: Text(
                                copy.botNeedsYou,
                                maxLines: 1,
                                style: TextStyle(
                                  color: colors.warning,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                          if (profile.botPinned) ...[
                            const SizedBox(width: 7),
                            Icon(
                              Icons.push_pin_rounded,
                              size: 13,
                              color: colors.textDisabled,
                            ),
                          ],
                          if (profile.botHidden) ...[
                            const SizedBox(width: 7),
                            Icon(
                              Icons.visibility_off_outlined,
                              size: 14,
                              color: colors.textDisabled,
                            ),
                          ],
                          if (unread) ...[
                            const SizedBox(width: 8),
                            Container(
                              key: ValueKey(
                                'mission-bot-unread-${profile.name}',
                              ),
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: colors.accentText,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
                if (hasLiveStatus)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 92),
                    child: Text(
                      copy.status(agent.status.name),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _statusColor(context, agent.status),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                else if (preview.isNotEmpty)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: 8),
                    child: Text(
                      _clock(
                        DateTime.fromMillisecondsSinceEpoch(
                          (pinnedChat!.lastActivityAt * 1000).toInt(),
                        ),
                      ),
                      style: TextStyle(
                        color: colors.textDisabled,
                        fontSize: 11,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                IconButton(
                  key: ValueKey('mission-bot-details-${profile.name}'),
                  tooltip: copy.botDetails,
                  onPressed: onDetails,
                  icon: const Icon(Icons.more_horiz_rounded, size: 21),
                  color: colors.textSecondary,
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
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

class _RoomsEmptyState extends StatelessWidget {
  final String message;
  final String actionLabel;
  final VoidCallback? onCreate;

  const _RoomsEmptyState({
    required this.message,
    required this.actionLabel,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 12),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.forum_outlined,
              color: colors.accentText,
              size: 23,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 14,
              height: 1.4,
            ),
          ),
          if (onCreate != null) ...[
            const SizedBox(height: 14),
            TextButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(actionLabel),
            ),
          ],
        ],
      ),
    );
  }
}

class _RoomMemberStack extends StatelessWidget {
  final MissionRoom room;
  final Map<String, AgentProfile> profiles;
  final MissionProfileAvatarCache? avatarCache;

  const _RoomMemberStack({
    required this.room,
    required this.profiles,
    required this.avatarCache,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final others =
        room.memberProfiles
            .where((profile) => profile != room.managerProfile)
            .toList(growable: false)
          ..sort();
    final members = <String>[
      room.managerProfile,
      ...others,
    ].take(3).toList(growable: false);
    return SizedBox(
      width: 38,
      height: 38,
      child: Stack(
        children: [
          for (var index = 0; index < members.length; index++)
            PositionedDirectional(
              start: index.isEven ? 0 : 16,
              top: index < 2 ? 0 : 16,
              child: Container(
                key: ValueKey('room-member-avatar-$index-${members[index]}'),
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.background, width: 2),
                ),
                child: MissionProfileAvatar(
                  profileName: members[index],
                  hasAvatar: profiles[members[index]]?.hasAvatar ?? false,
                  cache: avatarCache,
                  size: 18,
                  manager: members[index] == room.managerProfile,
                  shape: profiles[members[index]]?.botShape,
                  colorHex: profiles[members[index]]?.botColorHex,
                  imageKind: profiles[members[index]]?.botImageKind,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RoomTaskLine extends StatelessWidget {
  final KanbanTask task;
  final MissionControlCopy copy;
  final VoidCallback onTap;

  const _RoomTaskLine({
    required this.task,
    required this.copy,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final color = task.status == 'blocked'
        ? colors.error
        : task.status == 'running'
        ? colors.success
        : colors.warning;
    return Semantics(
      container: true,
      button: true,
      label: '${task.id}, ${copy.taskStatus(task.status)}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '@${task.assignee ?? '—'} · ${copy.taskStatus(task.status)} · ${task.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textSecondary, fontSize: 11.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoomDraft {
  final String name;
  final String purposeLabel;
  final String managerProfile;
  final Set<String> memberProfiles;

  const _RoomDraft({
    required this.name,
    required this.purposeLabel,
    required this.managerProfile,
    required this.memberProfiles,
  });
}

class _RoomEditor extends StatefulWidget {
  final MissionControlCopy copy;
  final List<AgentProfile> profiles;
  final MissionProfileAvatarCache? avatarCache;
  final String? suggestedManager;
  final MissionRoom? existing;
  final VoidCallback onManageProfiles;

  const _RoomEditor({
    required this.copy,
    required this.profiles,
    required this.avatarCache,
    this.suggestedManager,
    this.existing,
    required this.onManageProfiles,
  });

  @override
  State<_RoomEditor> createState() => _RoomEditorState();
}

class _RoomEditorState extends State<_RoomEditor> {
  static const _maxNewRoomMembers = 6;

  late final TextEditingController _name;
  late final TextEditingController _purpose;
  late final TextEditingController _search;
  late final Set<String> _members;
  String? _manager;
  bool _nameWasEdited = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _purpose = TextEditingController(text: widget.existing?.purposeLabel ?? '');
    _search = TextEditingController();
    _nameWasEdited = widget.existing != null;
    final authoritativeNames = widget.profiles
        .map((profile) => profile.name)
        .toSet();
    _members = {
      ...?widget.existing?.memberProfiles.where(authoritativeNames.contains),
    };
    final existingManager = widget.existing?.managerProfile;
    final suggestedManager = widget.suggestedManager;
    _manager =
        (existingManager != null && authoritativeNames.contains(existingManager)
            ? existingManager
            : null) ??
        (suggestedManager != null &&
                authoritativeNames.contains(suggestedManager)
            ? suggestedManager
            : null) ??
        (widget.profiles.isEmpty ? null : widget.profiles.first.name);
    if (_manager != null) _members.add(_manager!);
  }

  @override
  void dispose() {
    _name.dispose();
    _purpose.dispose();
    _search.dispose();
    super.dispose();
  }

  String get _normalizedName =>
      _name.text.trim().replaceFirst(RegExp(r'^#+'), '').trim();

  bool get _nameOnlyHashes =>
      _name.text.trim().isNotEmpty && _normalizedName.isEmpty;

  bool get _canSave =>
      _normalizedName.isNotEmpty &&
      _normalizedName.runes.length <= 64 &&
      _purpose.text.trim().runes.length <= MissionRoom.maxPurposeLabelRunes &&
      _manager != null &&
      _members.contains(_manager) &&
      (widget.existing != null || _members.length >= 2) &&
      (widget.existing != null || _members.length <= _maxNewRoomMembers);

  String _displayName(AgentProfile profile) =>
      profile.botTitle?.trim().isNotEmpty == true
      ? profile.botTitle!.trim()
      : profile.name;

  void _syncSuggestedName() {
    if (_nameWasEdited || widget.existing != null) return;
    final selected = widget.profiles
        .where((profile) => _members.contains(profile.name))
        .map(_displayName)
        .toList(growable: false);
    final suggestion = selected.join(' + ');
    _name.value = TextEditingValue(
      text: suggestion.characters.take(64).toString(),
      selection: TextSelection.collapsed(
        offset: suggestion.characters.take(64).length,
      ),
    );
  }

  void _setMember(String profile, bool selected) {
    if (selected) {
      if (_members.length >= _maxNewRoomMembers &&
          !_members.contains(profile)) {
        return;
      }
      _members.add(profile);
    } else if (profile != _manager) {
      _members.remove(profile);
    }
    _syncSuggestedName();
  }

  void _save() {
    if (!_canSave) return;
    Navigator.pop(
      context,
      _RoomDraft(
        name: _normalizedName,
        purposeLabel: _purpose.text.trim(),
        managerProfile: _manager!,
        memberProfiles: Set.unmodifiable(_members),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final titleStyle = theme.textTheme.titleMedium?.copyWith(
      color: colors.textPrimary,
      fontWeight: FontWeight.w700,
      letterSpacing: 0,
    );
    final dropdownStyle = theme.textTheme.bodyLarge?.copyWith(
      color: colors.textPrimary,
      fontWeight: FontWeight.w500,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height * 0.8;
        return SizedBox(
          height: height,
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  key: const ValueKey('room-editor-scroll'),
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        widget.existing == null
                            ? widget.copy.createRoom
                            : widget.copy.editRoom,
                        key: const ValueKey('room-editor-title'),
                        style: titleStyle,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.copy.roomSelectionHint,
                        key: const ValueKey('room-editor-intro'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey('room-name'),
                        controller: _name,
                        maxLength: 64,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          labelText: widget.copy.roomName,
                          hintText: widget.copy.roomHint,
                          prefixText: '#',
                          errorText: _nameOnlyHashes
                              ? widget.copy.roomNameInvalid
                              : null,
                        ),
                        onChanged: (_) => setState(() => _nameWasEdited = true),
                      ),
                      TextField(
                        key: const ValueKey('room-purpose'),
                        controller: _purpose,
                        minLines: 2,
                        maxLines: 3,
                        maxLength: MissionRoom.maxPurposeLabelRunes,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          labelText: widget.copy.roomPurpose,
                          hintText: widget.copy.roomPurposeHint,
                          alignLabelWithHint: true,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 4),
                      DropdownButtonFormField<String>(
                        key: const ValueKey('room-manager'),
                        initialValue: _manager,
                        isExpanded: true,
                        style: dropdownStyle,
                        decoration: InputDecoration(
                          labelText: widget.copy.roomCoordinator,
                        ),
                        items: widget.profiles
                            .map(
                              (profile) => DropdownMenuItem(
                                value: profile.name,
                                child: Text(
                                  _displayName(profile) == profile.name
                                      ? '@${profile.name}'
                                      : '${_displayName(profile)} · @${profile.name}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(growable: false),
                        onChanged: (value) => setState(() {
                          _manager = value;
                          if (value != null) _members.add(value);
                          _syncSuggestedName();
                        }),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 12,
                        runSpacing: 3,
                        children: [
                          Text(
                            widget.copy.roomMembers,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            widget.copy.roomSelectionCount(_members.length),
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      if (_members.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          key: const ValueKey('room-selected-members'),
                          spacing: 7,
                          runSpacing: 7,
                          children: [
                            ...widget.profiles
                                .where(
                                  (profile) => _members.contains(profile.name),
                                )
                                .take(_maxNewRoomMembers)
                                .map(
                                  (profile) => InputChip(
                                    key: ValueKey(
                                      'room-selected-${profile.name}',
                                    ),
                                    avatar: SizedBox.square(
                                      key: ValueKey(
                                        'room-selected-avatar-${profile.name}',
                                      ),
                                      dimension: 24,
                                      child: MissionProfileAvatar(
                                        profileName: profile.name,
                                        hasAvatar: profile.hasAvatar,
                                        cache: widget.avatarCache,
                                        size: 24,
                                        shape: profile.botShape,
                                        colorHex: profile.botColorHex,
                                        imageKind: profile.botImageKind,
                                      ),
                                    ),
                                    label: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 140,
                                      ),
                                      child: Text(
                                        _displayName(profile) == profile.name
                                            ? '@${profile.name}'
                                            : '${_displayName(profile)} · @${profile.name}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    onDeleted: profile.name == _manager
                                        ? null
                                        : () => setState(
                                            () =>
                                                _setMember(profile.name, false),
                                          ),
                                  ),
                                ),
                            if (_members.length > _maxNewRoomMembers)
                              Chip(
                                label: Text(
                                  '+${_members.length - _maxNewRoomMembers}',
                                ),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey('room-member-search'),
                        controller: _search,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: widget.copy.searchAgents,
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(
                                  onPressed: () => setState(_search.clear),
                                  icon: const Icon(Icons.close_rounded),
                                ),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          key: const ValueKey('room-manage-profiles'),
                          onPressed: widget.onManageProfiles,
                          icon: const Icon(
                            Icons.person_add_alt_1_outlined,
                            size: 18,
                          ),
                          label: Text(widget.copy.manageProfiles),
                        ),
                      ),
                      Builder(
                        builder: (context) {
                          final query = _search.text.trim().toLowerCase();
                          final visible = widget.profiles
                              .where(
                                (profile) =>
                                    query.isEmpty ||
                                    profile.name.toLowerCase().contains(
                                      query,
                                    ) ||
                                    _displayName(
                                      profile,
                                    ).toLowerCase().contains(query) ||
                                    profile.description.toLowerCase().contains(
                                      query,
                                    ),
                              )
                              .toList(growable: false);
                          if (visible.isEmpty) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              child: Text(
                                widget.copy.noMatchingAgents,
                                textAlign: TextAlign.center,
                                style: TextStyle(color: colors.textSecondary),
                              ),
                            );
                          }
                          return ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: visible.length,
                            itemBuilder: (context, index) {
                              final profile = visible[index];
                              final isManager = profile.name == _manager;
                              final selected = _members.contains(profile.name);
                              final atLimit =
                                  _members.length >= _maxNewRoomMembers &&
                                  !selected;
                              return CheckboxListTile(
                                key: ValueKey('room-member-${profile.name}'),
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                secondary: SizedBox.square(
                                  key: ValueKey(
                                    'room-member-choice-avatar-${profile.name}',
                                  ),
                                  dimension: 40,
                                  child: MissionProfileAvatar(
                                    profileName: profile.name,
                                    hasAvatar: profile.hasAvatar,
                                    cache: widget.avatarCache,
                                    size: 40,
                                    shape: profile.botShape,
                                    colorHex: profile.botColorHex,
                                    imageKind: profile.botImageKind,
                                  ),
                                ),
                                value: selected,
                                onChanged: isManager || atLimit
                                    ? null
                                    : (value) => setState(
                                        () => _setMember(
                                          profile.name,
                                          value == true,
                                        ),
                                      ),
                                title: Text(_displayName(profile)),
                                subtitle: Text(
                                  isManager
                                      ? '@${profile.name} · ${widget.copy.managerLabel}'
                                      : '@${profile.name}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                decoration: BoxDecoration(
                  color: colors.surface,
                  border: Border(
                    top: BorderSide(
                      color: colors.divider.withValues(alpha: 0.58),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(widget.copy.cancel),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        key: const ValueKey('room-save'),
                        onPressed: _canSave ? _save : null,
                        child: Text(
                          widget.existing == null
                              ? widget.copy.createRoom
                              : widget.copy.save,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _OrganizationDraft {
  final String name;
  final Set<String> profileNames;
  final String? managerProfile;

  const _OrganizationDraft({
    required this.name,
    required this.profileNames,
    this.managerProfile,
  });
}

class _OrganizationEditor extends StatefulWidget {
  final MissionControlCopy copy;
  final List<AgentProfile> profiles;
  final MissionOrganization? existing;

  const _OrganizationEditor({
    required this.copy,
    required this.profiles,
    this.existing,
  });

  @override
  State<_OrganizationEditor> createState() => _OrganizationEditorState();
}

class _OrganizationEditorState extends State<_OrganizationEditor> {
  late final TextEditingController _name;
  late final Set<String> _selected;
  String? _manager;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _selected = {...?widget.existing?.profileNames};
    _manager = widget.existing?.managerProfile;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty || name.runes.length > 64) return;
    Navigator.pop(
      context,
      _OrganizationDraft(
        name: name,
        profileNames: Set.unmodifiable(_selected),
        managerProfile: _selected.contains(_manager) ? _manager : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.existing == null
                  ? widget.copy.createOrganization
                  : widget.copy.editOrganization,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 18),
            TextField(
              key: const ValueKey('organization-name'),
              controller: _name,
              maxLength: 64,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: widget.copy.organizationName,
                hintText: widget.copy.organizationHint,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Text(widget.copy.chooseProfiles),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: widget.profiles.map((profile) {
                final selected = _selected.contains(profile.name);
                return FilterChip(
                  label: Text(profile.name),
                  selected: selected,
                  onSelected: (value) => setState(() {
                    if (value) {
                      _selected.add(profile.name);
                    } else {
                      _selected.remove(profile.name);
                      if (_manager == profile.name) _manager = null;
                    }
                  }),
                );
              }).toList(),
            ),
            if (_selected.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _manager,
                decoration: InputDecoration(
                  labelText: widget.copy.managerLabel,
                ),
                items: [
                  const DropdownMenuItem(value: '', child: Text('—')),
                  ..._selected.map(
                    (profile) =>
                        DropdownMenuItem(value: profile, child: Text(profile)),
                  ),
                ],
                onChanged: (value) => setState(
                  () =>
                      _manager = value == null || value.isEmpty ? null : value,
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(widget.copy.cancel),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _name.text.trim().isEmpty ? null : _save,
                    child: Text(widget.copy.save),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Ficha única del bot: toda acción cuelga del bot (chat primario, edición del
/// profile, rutinas, tareas y contexto de memoria/skills/SOUL), siguiendo la
/// organización del plugin oficial Hermes Bot Mode.
class _AgentDetail extends StatelessWidget {
  final MissionAgent agent;
  final List<KanbanTask> assignedTasks;
  final MissionControlCopy copy;
  final MissionProfileAvatarCache? avatarCache;
  final VoidCallback onChat;
  final VoidCallback? onEditProfile;
  final VoidCallback onRoutines;
  final VoidCallback onTasks;
  final VoidCallback onMemory;
  final VoidCallback onSkills;
  final VoidCallback onSoul;
  final VoidCallback? onTogglePinned;
  final VoidCallback? onToggleHidden;

  const _AgentDetail({
    required this.agent,
    required this.assignedTasks,
    required this.copy,
    required this.avatarCache,
    required this.onChat,
    required this.onEditProfile,
    required this.onRoutines,
    required this.onTasks,
    required this.onMemory,
    required this.onSkills,
    required this.onSoul,
    required this.onTogglePinned,
    required this.onToggleHidden,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final model = [
      agent.provider,
      agent.model,
    ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        Center(
          child: Container(
            width: 42,
            height: 4,
            decoration: BoxDecoration(
              color: colors.divider,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            _AgentAvatar(
              profile: agent.profile,
              status: agent.status,
              avatarCache: avatarCache,
              size: 48,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    agent.profile.botTitle ?? agent.profile.name,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  Text(
                    copy.status(agent.status.name),
                    style: TextStyle(
                      color: _statusColor(context, agent.status),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (agent.profile.description.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(agent.profile.description),
        ],
        const SizedBox(height: 18),
        _DetailLine(label: copy.profileLabel, value: agent.profile.name),
        _DetailLine(
          label: copy.modelLabel,
          value: model.isEmpty ? copy.modelUnavailable : model,
        ),
        if (agent.currentSession != null)
          _DetailLine(
            label: copy.recentSessions,
            value: agent.currentSession!.displayTitle,
          ),
        if (assignedTasks.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            copy.assignedTasks(assignedTasks.length),
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          for (final task in assignedTasks)
            _DetailLine(label: task.status, value: task.title),
        ],
        const SizedBox(height: 12),
        _UsageCard(usage: agent.usage, copy: copy),
        const SizedBox(height: 16),
        HermesPrimaryButton(
          key: const ValueKey('bot-detail-chat'),
          label: copy.openChat,
          icon: Icons.chat_bubble_outline,
          onTap: onChat,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: HermesSecondaryButton(
                key: const ValueKey('bot-detail-edit-profile'),
                label: copy.editProfile,
                icon: Icons.tune,
                onTap: onEditProfile,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: HermesSecondaryButton(
                key: const ValueKey('bot-detail-routines'),
                label: copy.routines,
                icon: Icons.schedule_outlined,
                onTap: onRoutines,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: HermesSecondaryButton(
                key: const ValueKey('bot-detail-tasks'),
                label: copy.tasks,
                icon: Icons.view_kanban_outlined,
                onTap: onTasks,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: HermesSecondaryButton(
                key: const ValueKey('bot-detail-memory'),
                label: copy.memory,
                icon: Icons.psychology_outlined,
                onTap: onMemory,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: HermesSecondaryButton(
                key: const ValueKey('bot-detail-skills'),
                label: copy.skills,
                icon: Icons.extension_outlined,
                onTap: onSkills,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: HermesSecondaryButton(
                key: const ValueKey('bot-detail-soul'),
                label: copy.soul,
                icon: Icons.auto_awesome_outlined,
                onTap: onSoul,
              ),
            ),
          ],
        ),
        if (onTogglePinned != null || onToggleHidden != null) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: HermesSecondaryButton(
                  key: const ValueKey('bot-detail-toggle-pinned'),
                  label: agent.profile.botPinned ? copy.unpinBot : copy.pinBot,
                  icon: agent.profile.botPinned
                      ? Icons.push_pin_outlined
                      : Icons.push_pin_rounded,
                  onTap: onTogglePinned,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: HermesSecondaryButton(
                  key: const ValueKey('bot-detail-toggle-hidden'),
                  label: agent.profile.botHidden ? copy.showBot : copy.hideBot,
                  icon: agent.profile.botHidden
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  onTap: onToggleHidden,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _AgentAvatar extends StatelessWidget {
  final AgentProfile profile;
  final MissionAgentStatus status;
  final MissionProfileAvatarCache? avatarCache;
  final double size;
  final bool showStatusIndicator;

  const _AgentAvatar({
    required this.profile,
    required this.status,
    required this.avatarCache,
    this.size = 40,
    this.showStatusIndicator = true,
  });

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      MissionProfileAvatar(
        profileName: profile.name,
        hasAvatar: profile.hasAvatar,
        cache: avatarCache,
        size: size,
        shape: profile.botShape,
        colorHex: profile.botColorHex,
        imageKind: profile.botImageKind,
      ),
      if (showStatusIndicator)
        PositionedDirectional(
          end: -1,
          bottom: -1,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: _statusColor(context, status),
              shape: BoxShape.circle,
              border: Border.all(
                color: Theme.of(context).hermes.surface,
                width: 2,
              ),
            ),
          ),
        ),
    ],
  );
}

class _UsageCard extends StatelessWidget {
  final MissionUsage usage;
  final MissionControlCopy copy;

  const _UsageCard({required this.usage, required this.copy});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final cost = usage.actualCostUsd ?? usage.estimatedCostUsd;
    final tokenValues = <Widget>[
      if (usage.inputTokens != null)
        _UsageValue(label: copy.input, value: _compact(usage.inputTokens!)),
      if (usage.outputTokens != null)
        _UsageValue(label: copy.output, value: _compact(usage.outputTokens!)),
      if (usage.cacheReadTokens != null)
        _UsageValue(
          label: copy.cached,
          value: _compact(usage.cacheReadTokens!),
        ),
      if (usage.reasoningTokens != null)
        _UsageValue(
          label: copy.reasoning,
          value: _compact(usage.reasoningTokens!),
        ),
    ];
    return HermesCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (tokenValues.isEmpty)
            Text(
              copy.tokensUnavailable,
              style: TextStyle(color: colors.textSecondary, fontSize: 12),
            )
          else
            Wrap(spacing: 16, runSpacing: 8, children: tokenValues),
          const SizedBox(height: 12),
          Text(
            cost == null
                ? copy.costUnavailable
                : '\$${cost.toStringAsFixed(4)}${usage.costCoverage == MissionCostCoverage.partial ? ' · ${copy.partialCost}' : ''}',
            style: TextStyle(color: colors.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _UsageValue extends StatelessWidget {
  final String label;
  final String value;

  const _UsageValue({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(value, style: Theme.of(context).textTheme.titleMedium),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class _MessageCard extends StatelessWidget {
  final String text;

  const _MessageCard({required this.text});

  @override
  Widget build(BuildContext context) => HermesCard(child: Text(text));
}

class _InlineNotice extends StatelessWidget {
  final IconData icon;
  final String text;

  const _InlineNotice({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      color: colors.warning.withValues(alpha: 0.08),
      child: Row(
        children: [
          Icon(icon, size: 17, color: colors.warning),
          const SizedBox(width: 9),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }
}

class _CenteredState extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool loading;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _CenteredState({
    required this.icon,
    required this.text,
    this.loading = false,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const CircularProgressIndicator()
            else
              Icon(icon, size: 42, color: colors.textDisabled),
            const SizedBox(height: 14),
            Text(text, textAlign: TextAlign.center),
            if (actionLabel != null) ...[
              const SizedBox(height: 14),
              TextButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  final String label;
  final String value;

  const _DetailLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 90, child: Text(label)),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

Color _statusColor(BuildContext context, MissionAgentStatus status) {
  final colors = Theme.of(context).hermes;
  return switch (status) {
    MissionAgentStatus.approvalRequired => colors.warning,
    MissionAgentStatus.error || MissionAgentStatus.blocked => colors.error,
    MissionAgentStatus.working ||
    MissionAgentStatus.responding ||
    MissionAgentStatus.thinking => colors.success,
    MissionAgentStatus.idle => colors.textDisabled,
  };
}

String _compact(int value) {
  if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
  if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}K';
  return '$value';
}

String _clock(DateTime time) {
  final local = time.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}
