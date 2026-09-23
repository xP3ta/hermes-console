import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../models/agent_profile.dart';
import '../models/bot_mode_v13.dart';
import '../models/bot_sections.dart';
import '../models/room_mirror.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/room_mirror_avatar.dart';
import '../models/hosted_groups.dart';
import '../models/room_member_status.dart';
import '../models/room_summary.dart';
import '../models/kanban.dart';
import '../models/mission_control.dart';
import '../navigation/chat_route.dart';
import '../services/active_chat_service.dart';
import '../services/chat_draft_store.dart';
import '../services/connection_manager.dart';
import '../services/mission_control_repository.dart';
import '../services/mission_bot_activity_store.dart';
import '../services/mission_bot_chat_store.dart';
import '../services/mission_organization_store.dart';
import '../services/notifications/notification_service.dart';
import '../services/tui_gateway_client.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_drawer.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/dock.dart';
import '../widgets/dock_style.dart' show dockShowsBack;
import '../widgets/chat_surface_coordinator.dart';
import '../widgets/dock_shortcuts.dart';
import '../widgets/mission_profile_avatar.dart';
import '../widgets/room_avatar_stack.dart';
import '../widgets/room_team_row.dart';
import '../widgets/room_member_status.dart';
import '../widgets/room_summary_pill.dart';
import '../widgets/remote_bot_roster.dart';
import 'bot_create_screen.dart';
import 'bot_sections_editor.dart';
import '../services/bot_profile_client.dart';
import '../services/bot_section_service.dart';
import '../services/bot_room_link.dart';
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

/// Bot Chat is a normal writable chat destination, backed by the same
/// canonical history as any other session. It reuses ChatScreen with the
/// caller's own connection, so composer, dictation and voice submission are
/// available exactly as they are for any other chat — the connection is only
/// forced read-only when the underlying instance itself is marked read-only
/// (see [SavedConnection.readOnly] in Instance Settings), never as a
/// Bot-Chat-specific restriction.
@visibleForTesting
ChatScreen buildBotChatDestination({
  required SavedConnection connection,
  required Session session,
  required String? initialStoredSessionId,
  required AgentProfile profile,
  MissionProfileAvatarCache? avatarCache,
}) => ChatScreen(
  connection: connection,
  session: session,
  initialStoredSessionId: initialStoredSessionId,
  missionBotProfile: profile,
  missionAvatarCache: avatarCache,
);

@visibleForTesting
({String? sessionId, String source, bool valid}) resolveBotChatTarget(
  AgentProfile profile, {
  String? localCompatibilityPin,
}) {
  final canonical = profile.canonicalBotChatSessionId;
  if (canonical != null) {
    return (sessionId: canonical, source: 'bot-mode-canonical', valid: true);
  }
  if (profile.hasInvalidBotChatPin) {
    return (sessionId: null, source: 'mobile-bot', valid: false);
  }
  final official = profile.botChatSessionId;
  if (official != null) {
    return (sessionId: official, source: 'bot-mode', valid: true);
  }
  if (localCompatibilityPin != null) {
    return (
      sessionId: localCompatibilityPin,
      source: 'bot-mode-local',
      valid: true,
    );
  }
  return (sessionId: null, source: 'mobile-bot', valid: true);
}

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

  // La sala local ya no existe: un aviso de tipo "room" siempre apunta a una
  // sala compartida real (`HostedGroupRoom`, identificada por `roomId`), la
  // única sala que sigue existiendo en la app.
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
  @visibleForTesting
  final MissionBotChatStore? botChatStore;
  @visibleForTesting
  final MissionBotActivityStore? botActivityStore;
  @visibleForTesting
  final ActiveChatService? activeChats;
  final MissionControlOpenTarget? initialOpenTarget;
  @visibleForTesting
  final ValueChanged<Session>? botChatOpenObserver;
  @visibleForTesting
  final RemoteBotLoader? remoteBotLoader;
  @visibleForTesting
  final HermesDesktopBotCreationGateway? botCreateGateway;
  @visibleForTesting
  final HermesDesktopProfileAssetsGateway? profileAssetsGateway;
  final BotProfileGateway? botProfileGateway;
  @visibleForTesting
  final Future<List<ModelProvider>> Function(String profile)?
  modelOptionsLoader;

  const MissionControlScreen({
    required this.connection,
    required this.connManager,
    this.dataSource,
    this.organizationStore,
    this.botChatStore,
    this.botActivityStore,
    this.activeChats,
    this.initialOpenTarget,
    this.botChatOpenObserver,
    this.remoteBotLoader,
    this.botCreateGateway,
    this.profileAssetsGateway,
    this.botProfileGateway,
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
  late final MissionBotChatStore _botChatStore;
  late final MissionBotActivityStore _botActivityStore;
  TuiGatewayClient? _ownedProfileAssetsGateway;
  late final HermesDesktopProfileAssetsGateway _profileAssetsGateway;
  MissionBackendSnapshot? _snapshot;
  List<MissionOrganization> _organizations = const [];
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
  late final ChatSurfaceCoordinator _surfaceCoordinator;
  final Map<WorkItem, int> _workItemGenerations = Map.identity();
  final Map<String, WorkDestination> _validatedWorkDestinations = {};

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
    _surfaceCoordinator = ChatSurfaceCoordinator(routeOwner: widget);
    _dataSource =
        widget.dataSource ??
        MissionControlRepository.forConnection(widget.connection);
    final avatarSource = _dataSource;
    _profileAvatarCache = avatarSource is MissionProfileAvatarDataSource
        ? MissionProfileAvatarCache(
            connectionId: widget.connection.id,
            loader: (avatarSource as MissionProfileAvatarDataSource)
                .loadProfileAvatar,
          )
        : null;
    _organizationStore =
        widget.organizationStore ??
        MissionOrganizationStore(widget.connManager.prefs);
    _botChatStore =
        widget.botChatStore ?? MissionBotChatStore(widget.connManager.prefs);
    _botActivityStore =
        widget.botActivityStore ??
        MissionBotActivityStore(widget.connManager.prefs);
    final injectedAssets = widget.profileAssetsGateway;
    if (injectedAssets != null) {
      _profileAssetsGateway = injectedAssets;
    } else {
      final gateway = TuiGatewayClient(widget.connection);
      _ownedProfileAssetsGateway = gateway;
      _profileAssetsGateway = gateway;
    }
    _organizations = _organizationStore.load(widget.connection.id);
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
    _statusRevision.dispose();
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
    _surfaceCoordinator.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _surfaceCoordinator.handleLifecycle(state);
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

  final _statusRevision = ValueNotifier<int>(0);

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
      _statusRevision.value++;
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
        final rooms = snapshot.hostedGroups.rooms;
        final index = rooms.indexWhere((room) => room.roomId == roomId);
        if (index == -1) return;
        final capabilities = snapshot.hostedGroups.capabilities;
        final enabled = !widget.connection.readOnly;
        setState(() => _destination = _MissionDestination.work);
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _HostedRoomWorkspace(
              draftScope: (
                store: ChatDraftStore(widget.connManager.prefs),
                connectionId: widget.connection.id,
                profile: widget.connManager.activeProfileFor(
                  widget.connection.id,
                ),
              ),
              agents: _roomAgents,
              board: () => _snapshot?.board,
              refreshPresence: () => _load(refresh: true),
              identityFor: (room) => _snapshot?.roomIdentity(room),
              room: rooms[index],
              onRead:
                  _dataSource is MissionHostedGroupsReadDataSource &&
                      capabilities != null
                  ? (room) => (_dataSource as MissionHostedGroupsReadDataSource)
                        .readHostedGroup(
                          room,
                          generation: capabilities.generation,
                        )
                  : null,
              log: index < snapshot.hostedGroups.logs.length
                  ? snapshot.hostedGroups.logs[index]
                  : null,
              copy: MissionControlCopy.of(context),
              avatarCache: _profileAvatarCache,
              localProfiles: {
                for (final profile in snapshot.profiles) profile.name: profile,
              },
              onOpenMember: _openRoomMember,
              canSend:
                  enabled &&
                  (capabilities?.supports(GroupMethod.send) ?? false),
              canRename:
                  enabled &&
                  (capabilities?.supports(GroupMethod.rename) ?? false),
              canStop:
                  enabled &&
                  (capabilities?.supports(GroupMethod.stop) ?? false),
              canDisband:
                  enabled &&
                  (capabilities?.supports(GroupMethod.disband) ?? false),
              onSend: (text, attempt) => _mutateHostedGroup(
                rooms[index],
                (source, room, generation) => source.sendHostedGroupText(
                  room,
                  text: text,
                  attempt: attempt,
                  generation: generation,
                ),
              ),
              onRename: (name) => _mutateHostedGroup(
                rooms[index],
                (source, room, generation) => source.renameHostedGroup(
                  room,
                  name: name,
                  generation: generation,
                ),
              ),
              onStop: () => _mutateHostedGroup(
                rooms[index],
                (source, room, generation) =>
                    source.stopHostedGroup(room, generation: generation),
              ),
              onDisband: () => _mutateHostedGroup(
                rooms[index],
                (source, room, generation) =>
                    source.disbandHostedGroup(room, generation: generation),
              ),
            ),
          ),
        );
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
    final hostedGroupsFailed =
        incoming.failures.containsKey('hostedGroups') &&
        incoming.hostedGroupsCapability == MissionCapabilityState.unavailable;
    return MissionBackendSnapshot(
      profiles: profilesFailed ? previous.profiles : incoming.profiles,
      sessions: sessionsFailed ? previous.sessions : incoming.sessions,
      board: kanbanFailed ? previous.board : incoming.board,
      profilesCapability: incoming.profilesCapability,
      sessionsCapability: incoming.sessionsCapability,
      kanbanCapability: incoming.kanbanCapability,
      hostedGroups: hostedGroupsFailed
          ? previous.hostedGroups
          : incoming.hostedGroups,
      hostedGroupsCapability: incoming.hostedGroupsCapability,
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

  // Huella de todo lo que el build lee de los chats vivos (ver `_liveChats`,
  // `_missionPhase` y `_approvalRoute`), capturada en el último build.
  //
  // `chat.changes` emite en cada token del stream; con el debounce de 80 ms
  // eso eran ~12 reconstrucciones por segundo de TODO Mission Control
  // (proyección, ordenación del roster, las dos pestañas del IndexedStack)
  // mientras cualquier bot escribía, aunque en pantalla no cambiara nada: la
  // fase, la aprobación pendiente o el título solo cambian en transiciones.
  // Se repinta únicamente cuando alguno de esos campos, o el conjunto de
  // chats vivos, difiere de lo ya pintado.
  List<Object?>? _renderedLiveFingerprint;

  List<Object?> _liveFingerprint() {
    final service = _activeChats;
    if (service == null) return const [];
    return [
      for (final chat in _resolveActiveChats(service)) ...[
        chat,
        chat.state,
        chat.activityKind,
        chat.pendingApproval,
        chat.sessionTitle,
        chat.sessionId,
        chat.storedSessionId,
        chat.sessionProfile,
      ],
    ];
  }

  void _scheduleLiveRefresh() {
    if (_disposed || !mounted) return;
    _liveRefreshDebounce?.cancel();
    _liveRefreshDebounce = Timer(const Duration(milliseconds: 80), () {
      if (_disposed || !mounted) return;
      if (listEquals(_liveFingerprint(), _renderedLiveFingerprint)) return;
      setState(() {});
      _statusRevision.value++;
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

  List<MissionAgent> _roomAgents() => _snapshot == null
      ? const []
      : MissionProjector.build(
          snapshot: _snapshot!,
          liveChats: _liveChats(),
        ).agents;

  RouteCapabilities _workCapabilities(MissionBackendSnapshot snapshot) {
    final availability = <OfficialCapability, CapabilityAvailability>{};
    final kanbanRead = switch (snapshot.kanbanCapability) {
      MissionCapabilityState.available => CapabilityAvailability.available,
      MissionCapabilityState.unavailable
          when snapshot.failures.containsKey('kanban') =>
        CapabilityAvailability.stale,
      MissionCapabilityState.unavailable => CapabilityAvailability.offline,
      MissionCapabilityState.unsupported => CapabilityAvailability.unsupported,
    };
    availability[OfficialCapability.kanbanRead] = kanbanRead;
    availability[OfficialCapability.kanbanTaskCrud] =
        !widget.connection.readOnly &&
            kanbanRead == CapabilityAvailability.available
        ? CapabilityAvailability.available
        : CapabilityAvailability.readOnly;
    availability[OfficialCapability.kanbanBoardCrud] =
        availability[OfficialCapability.kanbanTaskCrud]!;
    availability[OfficialCapability.approvalRespond] =
        widget.connection.readOnly
        ? CapabilityAvailability.readOnly
        : CapabilityAvailability.available;
    return RouteCapabilities(
      connectionId: widget.connection.id,
      generation: _loadGeneration,
      availabilityByCapability: availability,
    );
  }

  CanonicalHandoffRoute? _approvalRoute(
    MissionApproval approval,
    int generation,
  ) {
    final requestId = approval.requestId;
    if (requestId == null || requestId.isEmpty) return null;
    final live = _activeChats?.of(
      widget.connection.id,
      approval.sessionId,
      profile: approval.profileName,
    );
    final pending = live?.pendingApproval;
    final pendingRequest =
        pending?['request_id'] ?? pending?['approval_id'] ?? pending?['id'];
    if (live == null || pendingRequest != requestId) return null;
    return CanonicalHandoffRoute(
      connectionId: widget.connection.id,
      profile: approval.profileName,
      runtimeSessionId: approval.sessionId,
      requestId: requestId,
      kind: HandoffKind.approval,
      sourceGeneration: generation,
    );
  }

  List<WorkItem> _projectWorkItems(
    MissionBackendSnapshot snapshot,
    MissionProjection mission,
  ) {
    final generation = _loadGeneration;
    final capabilities = _workCapabilities(snapshot);
    final items = <WorkItem>[];
    final currentKeys = <String>{};
    for (final approval in mission.approvals) {
      final route = _approvalRoute(approval, generation);
      final source = ApprovalSourcePrivate(
        approval: approval,
        candidateRoute: route,
        sourceGeneration: generation,
      );
      final view = projectApprovalPublic(source);
      final stableKey =
          'approval:${approval.profileName}:${approval.sessionId}:${approval.requestId}';
      final draft = WorkItem.approval(stableKey: stableKey, view: view);
      final destination = resolveWorkDestination(
        item: draft,
        privateSource: source,
        snapshot: snapshot,
        mission: mission,
        capabilities: capabilities,
        liveHandoffs: route == null ? const [] : [route],
        previouslyValidatedDestination: _validatedWorkDestinations[stableKey],
      );
      if (destination == null) continue;
      final item = WorkItem.approval(
        stableKey: stableKey,
        view: view,
        destination: destination,
      );
      items.add(item);
      currentKeys.add(stableKey);
      _validatedWorkDestinations[stableKey] = destination;
      _workItemGenerations[item] = generation;
    }
    final boardId = snapshot.board == null ? null : snapshot.currentBoardId;
    if (boardId != null && boardId.trim().isNotEmpty) {
      for (final task in snapshot.tasks) {
        if (!const {
          'ready',
          'running',
          'blocked',
          'review',
        }.contains(task.status)) {
          continue;
        }
        final stableKey = 'task:$boardId:${task.id}';
        final attention = switch (task.status) {
          'blocked' => WorkAttention.blocked,
          'review' => WorkAttention.review,
          'running' => WorkAttention.running,
          _ => WorkAttention.ready,
        };
        final source = BoardTaskSourcePrivate(
          connectionId: widget.connection.id,
          boardId: boardId,
          taskId: task.id,
          sourceGeneration: generation,
        );
        final draft = WorkItem.task(
          stableKey: stableKey,
          title: task.title,
          decisionCopy: MissionControlCopy.of(context).taskStatus(task.status),
          attention: attention,
          taskRef: BoardTaskRef(boardId: boardId, taskId: task.id),
        );
        final destination = resolveWorkDestination(
          item: draft,
          privateSource: source,
          snapshot: snapshot,
          mission: mission,
          capabilities: capabilities,
          liveHandoffs: const [],
          previouslyValidatedDestination: _validatedWorkDestinations[stableKey],
        );
        if (destination == null) continue;
        final item = WorkItem.task(
          stableKey: stableKey,
          title: draft.title,
          decisionCopy: draft.decisionCopy,
          attention: attention,
          taskRef: draft.taskRef!,
          destination: destination,
        );
        items.add(item);
        currentKeys.add(stableKey);
        _validatedWorkDestinations[stableKey] = destination;
        _workItemGenerations[item] = generation;
      }
      final boardKey = 'board:$boardId';
      final boardSource = BoardSourcePrivate(
        connectionId: widget.connection.id,
        boardId: boardId,
        sourceGeneration: generation,
      );
      final boardDraft = WorkItem.board(
        stableKey: boardKey,
        title: MissionControlCopy.of(context).openKanban,
        decisionCopy: MissionControlCopy.of(context).work,
        attention: WorkAttention.ready,
        boardRef: BoardRef(boardId: boardId),
      );
      final boardDestination = resolveWorkDestination(
        item: boardDraft,
        privateSource: boardSource,
        snapshot: snapshot,
        mission: mission,
        capabilities: capabilities,
        liveHandoffs: const [],
        previouslyValidatedDestination: _validatedWorkDestinations[boardKey],
      );
      if (boardDestination != null) {
        final item = WorkItem.board(
          stableKey: boardKey,
          title: boardDraft.title,
          decisionCopy: boardDraft.decisionCopy,
          attention: WorkAttention.ready,
          boardRef: boardDraft.boardRef!,
          destination: boardDestination,
        );
        items.add(item);
        currentKeys.add(boardKey);
        _validatedWorkDestinations[boardKey] = boardDestination;
        _workItemGenerations[item] = generation;
      }
    }
    _validatedWorkDestinations.removeWhere(
      (key, _) => !currentKeys.contains(key),
    );
    _workItemGenerations.removeWhere(
      (item, itemGeneration) =>
          itemGeneration != generation || !items.contains(item),
    );
    return List.unmodifiable(items);
  }

  Future<void> _openWorkItem(WorkItem item, WorkDestination destination) async {
    if (!identical(item.destination, destination) ||
        _workItemGenerations[item] != _loadGeneration) {
      return;
    }
    switch (destination) {
      case ApprovalDestination():
        await _openApprovalWorkDestination(destination);
      case TaskDestination():
        final snapshot = _snapshot;
        if (snapshot == null ||
            snapshot.currentBoardId != destination.boardId ||
            !snapshot.tasks.any((task) => task.id == destination.taskId)) {
          return;
        }
        final connection = destination.mode == WorkRouteMode.read
            ? widget.connection.copyWith(readOnly: true)
            : widget.connection;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => TasksScreen(
              connection: connection,
              initialBoard: destination.boardId,
              initialTaskId: destination.taskId,
            ),
          ),
        );
      case BoardDestination():
        if (_snapshot?.currentBoardId != destination.boardId) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => TasksScreen(
              connection: destination.mode == WorkRouteMode.read
                  ? widget.connection.copyWith(readOnly: true)
                  : widget.connection,
              initialBoard: destination.boardId,
            ),
          ),
        );
    }
  }

  Future<void> _openApprovalWorkDestination(
    ApprovalDestination destination,
  ) async {
    final route = destination.route;
    if (route.sourceGeneration != _loadGeneration ||
        route.connectionId != widget.connection.id) {
      return;
    }
    if (destination.mode == WorkRouteMode.read) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(Strings.of(context).missionApprovalPending),
          content: Text(Strings.of(context).missionApprovalDecisionHint),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(MaterialLocalizations.of(context).closeButtonLabel),
            ),
          ],
        ),
      );
      return;
    }
    final live = _activeChats?.of(
      route.connectionId,
      route.runtimeSessionId,
      profile: route.profile,
    );
    final pending = live?.pendingApproval;
    final pendingRequest =
        pending?['request_id'] ?? pending?['approval_id'] ?? pending?['id'];
    if (live == null || pendingRequest != route.requestId) return;
    if (live.notificationSurface == NotificationChatSurface.bot) {
      final snapshot = _snapshot;
      if (snapshot == null) return;
      for (final agent in _projection(snapshot).agents) {
        if (agent.profile.name == route.profile) {
          setState(() => _destination = _MissionDestination.bots);
          await _openChat(agent);
          return;
        }
      }
    }
  }

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
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(copy.botRosterUpdateFailed)),
        kind: HermesNoticeKind.error,
      );
    }
  }

  BotProfileGateway? get _botProfileGateway => widget.botProfileGateway ??
      (_profileAssetsGateway is BotProfileGateway ? _profileAssetsGateway as BotProfileGateway : null);
  bool _sectionBusy = false;

  Future<void> _applySections(Map<String, BotSectionChange> changes,
      {bool deletion = false, Map<String, BotSectionChange>? undo}) async {
    final gateway = _botProfileGateway;
    if (gateway == null || widget.connection.readOnly || _sectionBusy) return;
    setState(() => _sectionBusy = true);
    final service = BotSectionService(widget.connection.id, gateway);
    final result = await service.apply(widget.connection.id, changes);
    if (!mounted) return;
    setState(() => _sectionBusy = false);
    await _load(refresh: true);
    if (!mounted) return;
    final strings = Strings.of(context);
    if (result.failed.isNotEmpty) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            strings.botSectionPartial(result.failed.keys.join(', ')),
          ),
          action: SnackBarAction(
            label: strings.botRetry,
            onPressed: () =>
                _applySections(result.failed, deletion: deletion, undo: undo),
          ),
        ),
        kind: HermesNoticeKind.warning,
      );
    } else if (deletion && undo != null) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(strings.botSectionDeleted),
          action: SnackBarAction(
            label: strings.botUndo,
            onPressed: () => _applySections(undo),
          ),
        ),
        kind: HermesNoticeKind.success,
      );
    }
  }

  Future<void> _moveBotToSection([AgentProfile? profile]) async {
    if (_sectionBusy || _botProfileGateway == null || widget.connection.readOnly) return;
    final profiles = _snapshot?.profiles ?? const <AgentProfile>[];
    if (profile != null && !profiles.any((p) => identical(p, profile))) return;
    final changes = await chooseBotSection(context, profiles, bot: profile);
    if (changes != null && mounted) await _applySections(changes);
  }

  Future<void> _sectionMenu(BotSectionGroup group) async {
    if (_sectionBusy || widget.connection.readOnly || group.id == null) return;
    final action = await showHermesFloatingSurface<String>(context: context,
      builder: (context) {
        final s = Strings.of(context);
        return Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(s.botSectionRename), leading: const Icon(Icons.edit_outlined),
            onTap: () => Navigator.pop(context, 'rename')),
          ListTile(title: Text(s.botSectionDelete), leading: const Icon(Icons.delete_outline),
            onTap: () => Navigator.pop(context, 'delete')),
        ]);
      });
    if (action == null || !mounted) return;
    final profiles = _snapshot?.profiles ?? const <AgentProfile>[];
    if (action == 'rename') {
      final name = await botSectionNameDialog(context, initial: group.name ?? '');
      if (name == null || !mounted) return;
      await _applySections(BotSectionService.members(profiles, group.id!,
        BotSectionChange(group.id, name)));
    } else {
      final undo = <String, BotSectionChange>{
        for (final profile in profiles)
          if (profile.botSectionId == group.id)
            profile.name: BotSectionChange(group.id, profile.botSectionName ?? group.name),
      };
      await _applySections(BotSectionService.members(profiles, group.id!,
        const BotSectionChange(null, null)), deletion: true, undo: undo);
    }
  }

  Future<void> _openRemoteBot(
    SavedConnection connection,
    AgentProfile profile,
  ) async {
    TuiGatewayClient? client;
    try {
      final loader = widget.remoteBotLoader;
      if (loader != null) {
        profile = (await loader(connection))
            .singleWhere((candidate) => candidate.name == profile.name);
      } else {
        client = TuiGatewayClient(connection);
        profile = (await client.listProfiles(includeSessions: true))
            .singleWhere((candidate) => candidate.name == profile.name);
      }
    } catch (_) {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(Strings.of(context).botProfileFailed)),
          kind: HermesNoticeKind.error,
        );
      }
      return;
    } finally {
      await client?.close();
    }
    if (!mounted) return;
    final target = resolveBotChatTarget(profile);
    if (!target.valid) {
      _showBotChatPinUnavailable();
      return;
    }
    final session = Session(
      id: 'mob-bot-${profile.name}',
      lineageRootId: target.sessionId,
      title: 'Bot Chat',
      model: profile.model,
      source: target.source,
      messageCount: target.sessionId == null ? 0 : 1,
      isActive: true,
      preview: '',
      startedAt: 0,
      profile: profile.name,
      isDefaultProfile: profile.isDefault,
    );
    final observer = widget.botChatOpenObserver;
    if (observer != null) {
      observer(session);
      return;
    }
    await openChatFromSection<void>(
      context,
      builder: (_) => buildBotChatDestination(
        connection: connection,
        session: session,
        initialStoredSessionId: target.sessionId,
        profile: profile,
      ),
    );
  }

  void _remoteBotDetails(SavedConnection connection, AgentProfile profile) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => MissionControlScreen(
      connection: connection, connManager: widget.connManager)));
  }

  Future<void> _openRecentSession(MissionAgent agent) async {
    final recent = agent.profile.lastSession;
    if (recent == null) { await _openChat(agent); return; }
    final session = Session(id: recent.id, title: recent.title,
      profile: agent.profile.name, isDefaultProfile: agent.profile.isDefault,
      model: agent.profile.model, source: 'desktop',
      messageCount: recent.messageCount, isActive: true, preview: recent.preview,
      startedAt: recent.startedAt ?? 0);
    final observer = widget.botChatOpenObserver;
    if (observer != null) { observer(session); return; }
    await openChatFromSection<void>(context, builder: (_) => ChatScreen(
      connection: widget.connection, session: session, initialStoredSessionId: recent.id));
  }

  Future<void> _duplicateBot(MissionAgent agent) async {
    final gateway = _botProfileGateway;
    if (gateway == null || widget.connection.readOnly || _sectionBusy) return;
    setState(() => _sectionBusy = true);
    try {
      final name = await gateway.duplicateBotProfile(agent.profile.name);
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).botDuplicated(name))),
        kind: HermesNoticeKind.success,
      );
    } on BotDuplicateIncomplete catch (error) {
      if (mounted) {
        final strings = Strings.of(context);
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(strings.botDuplicateIncomplete(error.name)),
            action: SnackBarAction(
              label: strings.botRetry,
              onPressed: () => _duplicateBot(agent),
            ),
          ),
          kind: HermesNoticeKind.warning,
        );
      }
    } catch (_) {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(Strings.of(context).botProfileFailed)),
          kind: HermesNoticeKind.error,
        );
      }
    } finally {
      if (mounted) { setState(() => _sectionBusy = false); await _load(refresh: true); }
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
    await _organizationStore.delete(widget.connection.id, organization.id);
    if (!mounted) return;
    setState(() {
      _organizations = _organizationStore.load(widget.connection.id);
      if (_selectedOrganizationId == organization.id) {
        _selectedOrganizationId = null;
      }
    });
  }

  /// Opens the agent's canonical Bot Chat, writable like any other chat.
  Future<void> _openChat(MissionAgent agent) async {
    final canonicalPin = agent.profile.canonicalBotChatSessionId;
    final officialMetadata = agent.profile.botModeUiMeta.containsKey('chat');
    if (canonicalPin == null && agent.profile.hasInvalidBotChatPin) {
      debugPrint(
        'Mission Control: Bot Chat unavailable for ${agent.profile.name} '
        '(malformed compatibility pin: '
        'chat=${agent.profile.botModeUiMeta['chat']}, '
        'invalidMetadata=${agent.profile.hasInvalidBotModeMetadata})',
      );
      _showBotChatPinUnavailable();
      return;
    }
    String? localPin;
    var localPinClearFailed = false;
    final retireLocalPin = officialMetadata || canonicalPin != null;
    if (retireLocalPin) {
      if (!widget.connection.readOnly) {
        try {
          await _botChatStore.clear(
            connectionId: widget.connection.id,
            profile: agent.profile.name,
          );
        } catch (error) {
          debugPrint(
            'Mission Control: could not retire the stale local Bot Chat pin '
            'for ${agent.profile.name}: $error',
          );
          localPinClearFailed = true;
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
    if (localPinClearFailed && canonicalPin == null) {
      _showBotChatPinUnavailable();
      return;
    }
    if (!mounted) return;
    final target = resolveBotChatTarget(
      agent.profile,
      localCompatibilityPin: localPin,
    );
    if (!target.valid) {
      _showBotChatPinUnavailable();
      return;
    }
    final pinnedId = target.sessionId;
    final source = target.source;
    final session = Session(
      id: 'mob-bot-${agent.profile.name}',
      lineageRootId: pinnedId,
      title: 'Bot Chat',
      model: agent.profile.model.isEmpty ? 'hermes-agent' : agent.profile.model,
      source: source,
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
        builder: (_) => buildBotChatDestination(
          connection: widget.connection,
          session: session,
          initialStoredSessionId: pinnedId,
          profile: agent.profile,
          avatarCache: _profileAvatarCache,
        ),
      );
    }
    // Refresh after the route closes so the next read uses current metadata.
    if (mounted) await _load(refresh: true);
  }

  void _showBotChatPinUnavailable() {
    if (!mounted) return;
    HermesNotice.of(context).showSnackBar(
      SnackBar(
        content: Text(Strings.of(context).missionBotChatMetadataUnavailable),
      ),
      kind: HermesNoticeKind.warning,
    );
  }

  void _openAgent(MissionAgent agent) {
    _surfaceCoordinator.setRouteActive(false);
    unawaited(
      showHermesFloatingSurface<void>(
        context: context,
        surfaceKey: const ValueKey('mission-agent-detail'),
        maxWidth: 560,
        maxHeightFactor: 0.9,
        // Sin alto fijo: la ficha se mide por su contenido (su `ListView` va
        // en `shrinkWrap`) y solo llega al 90 % de la pantalla cuando de
        // verdad hace falta. El 72 % fijo anterior dejaba la hoja siempre del
        // mismo tamaño, así que un bot sin descripción ni tareas salía con
        // media ventana vacía debajo de los botones.
        builder: (sheetContext) => ValueListenableBuilder<int>(
          valueListenable: _statusRevision,
          builder: (sheetContext, _, _) {
            final current =
                _roomAgents()
                    .where((a) => a.profile.name == agent.profile.name)
                    .firstOrNull ??
                agent;
            return SafeArea(
              top: false,
              child: _AgentDetail(
                agent: current,
                live: BotLiveStatus.forAgent(
                  agent: current,
                  now: DateTime.now(),
                  rooms: _snapshot?.hostedGroups ?? HostedGroupsSnapshot.empty,
                ),
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
                          _saveBotRosterMeta(
                            agent,
                            pinned: !agent.profile.botPinned,
                          ),
                        );
                      },
                onToggleHidden: widget.connection.readOnly
                    ? null
                    : () {
                        Navigator.pop(sheetContext);
                        unawaited(
                          _saveBotRosterMeta(
                            agent,
                            hidden: !agent.profile.botHidden,
                          ),
                        );
                      },
              ),
            );
          },
        ),
      ).whenComplete(() {
        if (mounted) _surfaceCoordinator.setRouteActive(true);
      }),
    );
  }

  /// Hoja compacta de acciones rápidas de una tarjeta de bot (mantener
  /// pulsado o tocar el ⋯): fijar/dejar de fijar, ocultar/mostrar y accesos
  /// directos a abrir el chat o la ficha completa (`_openAgent`). El swipe
  /// se descartó en el diseño más reciente (compite con los gestos
  /// horizontales de Android y no se descubre); esta hoja es su sustituto.
  Future<void> _openBotQuickActions(MissionAgent agent) async {
    _surfaceCoordinator.setRouteActive(false);
    final action =
        await showHermesFloatingSurface<_BotQuickAction>(
          context: context,
          surfaceKey: ValueKey(
            'mission-bot-quick-actions-${agent.profile.name}',
          ),
          maxWidth: 420,
          maxHeightFactor: 0.5,
          builder: (sheetContext) => ValueListenableBuilder<int>(
            valueListenable: _statusRevision,
            builder: (sheetContext, _, _) {
              final current =
                  _roomAgents()
                      .where((a) => a.profile.name == agent.profile.name)
                      .firstOrNull ??
                  agent;
              return _BotQuickActionsSheet(
                agent: current,
                live: BotLiveStatus.forAgent(
                  agent: current,
                  now: DateTime.now(),
                  rooms: _snapshot?.hostedGroups ?? HostedGroupsSnapshot.empty,
                ),
                copy: MissionControlCopy.of(sheetContext),
                avatarCache: _profileAvatarCache,
                canMutate: !widget.connection.readOnly,
                canManage: _botProfileGateway != null,
              );
            },
          ),
        ).whenComplete(() {
          if (mounted) _surfaceCoordinator.setRouteActive(true);
        });
    if (!mounted || action == null) return;
    switch (action) {
      case _BotQuickAction.togglePinned:
        unawaited(_saveBotRosterMeta(agent, pinned: !agent.profile.botPinned));
      case _BotQuickAction.toggleHidden:
        unawaited(_saveBotRosterMeta(agent, hidden: !agent.profile.botHidden));
      case _BotQuickAction.openChat:
        unawaited(_openChat(agent));
      case _BotQuickAction.groups:
        await _manageBotRooms(agent);
      case _BotQuickAction.details:
        _openAgent(agent);
      case _BotQuickAction.section:
        await _moveBotToSection(agent.profile);
      case _BotQuickAction.recent:
        await _openRecentSession(agent);
      case _BotQuickAction.duplicate:
        await _duplicateBot(agent);
      case _BotQuickAction.delete:
        if (widget.connection.readOnly || agent.profile.isDefault || agent.profile.name == 'default') return;
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProfilesScreen(
          connection: widget.connection, connManager: widget.connManager,
          initialDeleteProfile: agent.profile.name)));
        if (mounted) await _load(refresh: true);
    }
  }

  Future<void> _manageBotRooms([MissionAgent? agent]) async {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    final rooms = snapshot.hostedGroups.rooms.where((r) => !r.disbanded && (agent == null || r.members.any((m) =>
      m.owner.connectionId == r.authorityGatewayId && m.owner.profile == agent.profile.name))).toList();
    final selected = await showHermesFloatingSurface<String>(context: context,
      builder: (context) => ListView(shrinkWrap: true, children: [
        for (final room in rooms) ListTile(title: Text(room.name), leading: const Icon(Icons.forum_outlined),
          trailing: !widget.connection.readOnly && _profileAssetsGateway is BotRoomLinkGateway && room.members.any((m) => m.owner.connectionId != room.authorityGatewayId)
            ? IconButton(icon: const Icon(Icons.link), tooltip: Strings.of(context).botReconnectRoom,
                onPressed: () => Navigator.pop(context, 'link:${room.roomId}')) : null,
          onTap: () => Navigator.pop(context, room.roomId)),
        if (_canCreateHostedRoom) ListTile(title: Text(MissionControlCopy.of(context).createSharedRoom),
          leading: const Icon(Icons.add), onTap: () => Navigator.pop(context, 'new')),
        Padding(padding: const EdgeInsets.all(20), child: Text(Strings.of(context).botRoomMembersUnavailable)),
      ]));
    if (!mounted || selected == null) return;
    if (selected == 'new') { await _createHostedRoom(initialProfile: agent?.profile.name); }
    else if (selected.startsWith('link:')) {
      try {
        final peers = await _loadRoomPeers();
        final room = _snapshot!.hostedGroups.rooms.singleWhere((r) => r.roomId == selected.substring(5) && !r.disbanded);
        final matches = peers.where((p) => room.members.any((m) => m.owner.connectionId == p.catalog['installation_id'] && m.owner.profile == p.profile.name)).toList();
        if (matches.isEmpty) throw StateError('No reachable room peers');
        await _attachRoomPeers(room, matches);
      } catch (_) {
        if (mounted) {
          HermesNotice.of(context).showSnackBar(
            SnackBar(content: Text(Strings.of(context).botRoomLinkUnavailable)),
            kind: HermesNoticeKind.warning,
          );
        }
      }
    }
    else if (_snapshot case final current?) {
      await _openInitialTarget(MissionControlOpenTarget.room(sessionId: '', roomId: selected), current);
    }
  }

  void _openRoomMember(String profileName) {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    for (final agent in _projection(snapshot).agents) {
      if (agent.profile.name == profileName) {
        _openAgent(agent);
        return;
      }
    }
    for (final profile in snapshot.profiles) {
      if (profile.name == profileName) {
        unawaited(
          _openChat(
            MissionAgent(
              profile: profile,
              status: MissionAgentStatus.idle,
              statusEvidence: '',
              usage: const MissionUsage(),
            ),
          ),
        );
        return;
      }
    }
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
          CronScreen(connection: widget.connection, profileOverride: profile, botRoutines: profile != null),
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
          onOpenSkills: () => _openSkills(profile: profile.name),
        ),
      ),
    );
    if (saved == true && mounted) {
      _profileAvatarCache?.clear();
      await _load(refresh: true);
    }
  }

  /// Creates the profile and opens its empty, writable Bot Chat history.
  Future<void> _createAgentFromMission() async {
    if (widget.connection.readOnly) return;
    final snapshot = _snapshot;
    if (snapshot == null) return;
    var target = widget.connection;
    final connections = widget.connManager.getConnections().where((c) => !c.readOnly).toList();
    if (connections.length > 1) {
      final selected = await showHermesFloatingSurface<SavedConnection>(context: context,
        builder: (context) => ListView(shrinkWrap: true, children: [
          ListTile(title: Text(Strings.of(context).botCreateOn)),
          for (final connection in connections) ListTile(
            title: Text(connection.label), leading: const Icon(Icons.dns_outlined),
            onTap: () => Navigator.pop(context, connection)),
        ]));
      if (selected == null || !mounted) return;
      target = selected;
    }
    TuiGatewayClient? remote;
    try {
      var profiles = snapshot.profiles;
      if (target.id != widget.connection.id) {
        remote = TuiGatewayClient(target);
        profiles = await remote.listProfiles();
      }
      if (!mounted) return;
      final created = await Navigator.of(context).push<String>(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => BotCreateScreen(connection: target,
          existing: profiles.map((profile) => profile.name).toSet(),
          gateway: target.id == widget.connection.id ? widget.botCreateGateway : null,
          modelOptionsLoader: target.id == widget.connection.id ? widget.modelOptionsLoader : null),
      ));
      if (!mounted || created == null) return;
      if (remote != null) {
        final profile = (await remote.listProfiles()).where((p) => p.name == created).single;
        if (!mounted) return;
        final session = Session(id: 'mob-bot-$created', title: 'Bot Chat',
          model: profile.model, source: 'mobile-bot', messageCount: 0,
          isActive: true, preview: '', startedAt: DateTime.now().millisecondsSinceEpoch / 1000,
          profile: created, isDefaultProfile: false);
        await openChatFromSection<void>(context, builder: (_) => buildBotChatDestination(
          connection: target, session: session, initialStoredSessionId: null, profile: profile));
        return;
      }
      await _load(refresh: true);
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(MissionControlCopy.of(context).agentCreated(created)),
        ),
        kind: HermesNoticeKind.success,
      );
      final freshSnapshot = _snapshot;
      if (freshSnapshot == null) return;
      for (final agent in _projection(freshSnapshot).agents) {
        if (agent.profile.name == created) { await _openChat(agent); return; }
      }
    } catch (_) {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(Strings.of(context).botProfileFailed)),
          kind: HermesNoticeKind.error,
        );
      }
    } finally { await remote?.close(); }
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

  /// Cuántas salas oficiales vivas se ven en el destino "Trabajo".
  int _visibleRoomCount(MissionBackendSnapshot snapshot) {
    return snapshot.hostedGroups.rooms.where((room) => !room.disbanded).length;
  }

  MissionHostedGroupsDataSource? get _hostedGroupsDataSource {
    final source = _dataSource;
    return source is MissionHostedGroupsDataSource
        ? source as MissionHostedGroupsDataSource
        : null;
  }

  bool get _canCreateHostedRoom {
    final snapshot = _snapshot;
    final capabilities = snapshot?.hostedGroups.capabilities;
    return !widget.connection.readOnly &&
        _hostedGroupsDataSource != null &&
        snapshot?.hostedGroupsCapability == MissionCapabilityState.available &&
        capabilities?.supports(GroupMethod.create) == true;
  }

  Future<List<_RoomPeerCandidate>> _loadRoomPeers() async {
    final home = _profileAssetsGateway;
    if (home is! BotRoomLinkGateway || widget.connection.readOnly) return [];
    final capabilities = await (home as BotRoomLinkGateway).roomLinkRequest('groups.capabilities', {});
    if (capabilities['driver'] != true || capabilities['methods'] is! List ||
        !(capabilities['methods'] as List).contains('groups.peer.register')) { return []; }
    final result = <_RoomPeerCandidate>[];
    for (final connection in widget.connManager.getConnections()) {
      if (connection.id == widget.connection.id || connection.readOnly) continue;
      final client = TuiGatewayClient(connection);
      try {
        for (final profile in await client.listProfiles(includeSessions: false)) {
          final caps = await client.roomLinkRequest('groups.capabilities', {'profile': profile.name});
          final catalog = BotRoomLink.catalog(caps, profile.name);
          if (catalog != null && catalog['installation_id'] != capabilities['authority_gateway_id'] &&
              caps['methods'] is List && (caps['methods'] as List).contains('groups.peer.invite')) {
            final candidate = _RoomPeerCandidate(connection, profile, catalog);
            if (!result.any((p) => p.key == candidate.key)) result.add(candidate);
          }
        }
      } catch (_) { /* Unavailable connections never become selectable peers. */ }
      finally { await client.close(); }
    }
    return result;
  }

  Future<void> _attachRoomPeers(HostedGroupRoom room, List<_RoomPeerCandidate> peers) async {
    final home = _profileAssetsGateway;
    if (home is! BotRoomLinkGateway || widget.connection.readOnly) return;
    final failed = <_RoomPeerCandidate>[];
    for (final peer in peers) {
      final client = TuiGatewayClient(peer.connection);
      try {
        if (!widget.connManager.getConnections().any((c) => c.id == peer.connection.id &&
            !c.readOnly && c.gatewayUrl == peer.connection.gatewayUrl && c.apiKey == peer.connection.apiKey)) {
          throw StateError('Room connection changed');
        }
        final member = room.members.singleWhere((m) =>
          m.owner.connectionId == peer.catalog['installation_id'] && m.owner.profile == peer.profile.name);
        await BotRoomLink((home as BotRoomLinkGateway).roomLinkRequest).attach(
          room: room, memberId: member.memberId, profile: peer.profile.name,
          target: client.roomLinkRequest, expectedCatalog: peer.catalog);
      } catch (_) { failed.add(peer); }
      finally { await client.close(); }
    }
    if (mounted && failed.isNotEmpty) {
      final s = Strings.of(context);
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(
            s.botRoomLinkFailed(
              failed
                  .map((p) => '${p.profile.name} · ${p.connection.label}')
                  .join(', '),
            ),
          ),
          action: SnackBarAction(
            label: s.botRetry,
            onPressed: () => _attachRoomPeers(room, failed),
          ),
        ),
        kind: HermesNoticeKind.error,
      );
    }
  }

  Future<void> _createHostedRoom({String? initialProfile}) async {
    final snapshot = _snapshot;
    final source = _hostedGroupsDataSource;
    final capabilities = snapshot?.hostedGroups.capabilities;
    if (!_canCreateHostedRoom ||
        snapshot == null ||
        source == null ||
        capabilities == null ||
        !mounted) {
      return;
    }
    final draft = await showHermesFloatingSurface<_HostedGroupDraft>(
      context: context,
      surfaceKey: const ValueKey('mission-hosted-create-dialog'),
      maxWidth: 480,
      maxHeightFactor: 0.84,
      builder: (dialogContext) => _HostedGroupCreateDialog(
        copy: MissionControlCopy.of(dialogContext),
        connectionId: widget.connection.id,
        profiles: snapshot.profiles,
        initialProfile: initialProfile,
        loadPeers: _profileAssetsGateway is BotRoomLinkGateway && widget.connManager.getConnections().any((c) => c.id != widget.connection.id && !c.readOnly) ? _loadRoomPeers : null,
        avatarCache: _profileAvatarCache,
      ),
    );
    if (draft == null || !mounted) return;
    final current = _snapshot;
    final currentCapabilities = current?.hostedGroups.capabilities;
    if (current == null ||
        currentCapabilities == null ||
        currentCapabilities.generation != capabilities.generation ||
        !currentCapabilities.supports(GroupMethod.create)) {
      return;
    }
    try {
      final created = await source.createHostedGroup(
        name: draft.name,
        members: draft.members,
        generation: currentCapabilities.generation,
      );
      if (created.disbanded) return;
      if (draft.peers.isNotEmpty) await _attachRoomPeers(created, draft.peers);
      if (!mounted) return;
      // The create response acknowledges the mutation, but groups.list/state is
      // the authority for membership, revision, and lifecycle. Never project an
      // optimistic local Room as though it were the shared hosted Room.
      await _load(refresh: true);
    } catch (error) {
      debugPrint(
        'Mission Control: hosted-room action failed (${error.runtimeType})',
      );
      if (!mounted) return;
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(MissionControlCopy.of(context).hostedActionFailed),
        ),
        kind: HermesNoticeKind.error,
      );
    }
  }

  Future<HostedGroupWorkspaceReadback> _mutateHostedGroup(
    HostedGroupRoom expectedRoom,
    Future<HostedGroupWorkspaceReadback> Function(
      MissionHostedGroupsDataSource source,
      HostedGroupRoom room,
      int generation,
    )
    action,
  ) async {
    final snapshot = _snapshot;
    final source = _hostedGroupsDataSource;
    final capabilities = snapshot?.hostedGroups.capabilities;
    final index =
        snapshot?.hostedGroups.rooms.indexWhere(
          (room) =>
              room.roomId == expectedRoom.roomId &&
              room.authorityGatewayId == expectedRoom.authorityGatewayId &&
              room.authorityEpoch == expectedRoom.authorityEpoch &&
              !room.disbanded,
        ) ??
        -1;
    if (!mounted ||
        widget.connection.readOnly ||
        snapshot == null ||
        source == null ||
        capabilities == null ||
        index < 0 ||
        index >= snapshot.hostedGroups.rooms.length) {
      throw StateError('hosted room authority unavailable');
    }
    try {
      final result = await action(
        source,
        snapshot.hostedGroups.rooms[index],
        capabilities.generation,
      );
      if (!mounted ||
          !identical(snapshot, _snapshot) ||
          result.capabilityGeneration != capabilities.generation ||
          result.room.roomId != snapshot.hostedGroups.rooms[index].roomId ||
          result.room.authorityEpoch !=
              snapshot.hostedGroups.rooms[index].authorityEpoch ||
          result.room.revision < snapshot.hostedGroups.rooms[index].revision) {
        throw StateError('hosted room authority changed');
      }
      final rooms = [...snapshot.hostedGroups.rooms];
      final logs = [...snapshot.hostedGroups.logs];
      if (result.room.disbanded) {
        rooms.removeAt(index);
        if (index < logs.length) logs.removeAt(index);
      } else {
        rooms[index] = result.room;
        if (result.log != null && index < logs.length) {
          logs[index] = result.log!;
        }
      }
      setState(() {
        _snapshot = MissionBackendSnapshot(
          profiles: snapshot.profiles,
          sessions: snapshot.sessions,
          board: snapshot.board,
          profilesCapability: snapshot.profilesCapability,
          sessionsCapability: snapshot.sessionsCapability,
          kanbanCapability: snapshot.kanbanCapability,
          hostedGroups: HostedGroupsSnapshot(
            capabilities: capabilities,
            rooms: List.unmodifiable(rooms),
            logs: List.unmodifiable(logs),
          ),
          hostedGroupsCapability: snapshot.hostedGroupsCapability,
          failures: snapshot.failures,
          loadedAt: snapshot.loadedAt,
        );
      });
      return HostedGroupWorkspaceReadback(
        room: result.room,
        log: result.log,
        capabilityGeneration: result.capabilityGeneration,
      );
    } catch (error) {
      debugPrint(
        'Mission Control: hosted-room action failed (${error.runtimeType})',
      );
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(MissionControlCopy.of(context).hostedActionFailed),
          ),
          kind: HermesNoticeKind.error,
        );
      }
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    _renderedLiveFingerprint = _liveFingerprint();
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
                minimumSize: const Size.square(48),
                shape: const CircleBorder(),
              ),
            ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final media = MediaQuery.of(context);
          _surfaceCoordinator.updateViewport(
            postLayoutSize: constraints.biggest,
            safePadding: media.padding,
            viewInsets: media.viewInsets,
            textScale: media.textScaler.scale(1),
            reducedMotion: media.disableAnimations,
          );
          return Stack(
            fit: StackFit.expand,
            children: [
              Padding(
                padding: EdgeInsets.only(
                  bottom: _surfaceCoordinator.scrollReservation,
                ),
                child: _buildBody(copy),
              ),
              AnimatedBuilder(
                animation: _surfaceCoordinator,
                builder: (context, _) => _surfaceCoordinator.dockVisible
                    ? Dock(
                        profileId: DockProfileId.bots,
                        coordinator: _surfaceCoordinator,
                        // Mismo inset que reserva el cuerpo de esta pantalla
                        // (`scrollReservation`), para que dock y contenido no
                        // discrepen.
                        bottomInset: _surfaceCoordinator.bottomInset,
                        showBackContext: dockShowsBack(context),
                        onBack: () => Navigator.of(context).maybePop(),
                        // El "+" de Bots no ejecuta una acción única: abre la
                        // bandeja con estas dos órbitas de creación (capa
                        // opcional del dock; el perfil General no la usa).
                        createOrbits: _botDockCreateOrbits(copy),
                        actions: _botDockActions(),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Qué sabe hacer cada elemento del catálogo del dock DESDE Mission
  /// Control. El dock (`widgets/dock.dart`) es genérico y no conoce ninguna
  /// pantalla: estas son las acciones que le da esta.
  ///
  /// `settings` no está en el mapa a propósito: el perfil Bots no ofrece un
  /// destino de Ajustes propio, así que ese elemento ni se pinta ni ocupa un
  /// hueco en la barra aunque una configuración antigua/corrupta lo traiga
  /// visible.
  Map<DockItemId, DockItemAction> _botDockActions() {
    void selectDestination(_MissionDestination value) {
      if (_destination == value) return;
      setState(() => _destination = value);
    }

    return {
      // "Inicio" saca de Bots al dashboard general: el catálogo de Bots lo
      // incluye por defecto (antes no había forma de volver a Inicio desde
      // aquí, bug confirmado en dispositivo real).
      DockItemId.home: DockItemAction(
        onTap: () => Navigator.of(context).popUntil((r) => r.isFirst),
      ),
      DockItemId.bots: DockItemAction(
        onTap: () => selectDestination(_MissionDestination.bots),
        selected: _destination == _MissionDestination.bots,
        semanticsKey: const ValueKey('mission-destination-bots'),
      ),
      DockItemId.work: DockItemAction(
        onTap: () => selectDestination(_MissionDestination.work),
        selected: _destination == _MissionDestination.work,
        semanticsKey: const ValueKey('mission-destination-work'),
      ),
      // El "+" lo gobierna el propio dock mientras tenga órbitas (abre y
      // cierra la bandeja); aquí solo se declara que el elemento existe en
      // esta pantalla.
      DockItemId.create: const DockItemAction(),
      // Accesos directos opcionales (ocultos de fábrica); mismas
      // pantallas/criterios que ya usa HermesDrawer.
      DockItemId.cron: DockItemAction(
        onTap: () =>
            openDockCron(context, widget.connection, widget.connManager),
      ),
      DockItemId.tasks: DockItemAction(
        onTap: () =>
            openDockTasks(context, widget.connection, widget.connManager),
      ),
      DockItemId.sessions: DockItemAction(
        onTap: () =>
            openDockSessions(context, widget.connection, widget.connManager),
      ),
      DockItemId.tools: DockItemAction(
        onTap: () =>
            openDockTools(context, widget.connection, widget.connManager),
      ),
    };
  }

  /// Las dos órbitas de creación del perfil Bots. `onTap: null` deja la
  /// órbita visible pero deshabilitada (sin permisos o sin capacidad en el
  /// gateway), igual que antes.
  List<DockCreateOrbit> _botDockCreateOrbits(MissionControlCopy copy) {
    final strings = Strings.of(context);
    final snapshot = _snapshot;
    return [
      DockCreateOrbit(
        controlKey: const ValueKey('bot-mode-create-bot'),
        label: strings.missionCreateBotLabel,
        icon: Icons.smart_toy_outlined,
        onTap:
            widget.connection.readOnly ||
                snapshot?.profilesCapability != MissionCapabilityState.available
            ? null
            : () => unawaited(_createAgentFromMission()),
      ),
      // Antes, sin la capacidad `hosted_groups`, este mismo botón creaba una
      // "sala local" (un chat de 1 bot con una lista de colaboradores
      // habituales, sin interacción de equipo real) haciéndose pasar por
      // sala. Eso ya no ocurre: una sala de verdad necesita la
      // infraestructura de turnos multi-bot que solo el servidor tiene
      // (igual que Desktop). Sin esa capacidad, el botón simplemente se
      // deshabilita en vez de fingir un sustituto.
      DockCreateOrbit(
        controlKey: const ValueKey('bot-mode-create-room'),
        label: strings.missionCreateRoomLabel,
        icon: Icons.groups_2_outlined,
        onTap: _canCreateHostedRoom
            ? () => unawaited(_createHostedRoom())
            : null,
      ),
    ];
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
                prefs: widget.connManager.prefs,
                connectionId: widget.connection.id,
                snapshot: snapshot,
                projection: projection,
                copy: copy,
                avatarCache: _profileAvatarCache,
                activityStore: _botActivityStore,
                onOpenDetail: _openAgent,
                onQuickActions: _openBotQuickActions,
                otherConnections: widget.connManager.getConnections().where((c) => c.id != widget.connection.id).toList(),
                remoteBotLoader: widget.remoteBotLoader,
                onRemoteOpen: _openRemoteBot,
                onRemoteDetails: _remoteBotDetails,
                onManageRooms: () => _manageBotRooms(),
                onNewSection: !widget.connection.readOnly && _botProfileGateway != null ? _moveBotToSection : null,
                onSectionMenu: !widget.connection.readOnly && _botProfileGateway != null ? _sectionMenu : null,
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
                onCreateHostedRoom: _canCreateHostedRoom
                    ? _createHostedRoom
                    : null,
                roomCount: _visibleRoomCount(snapshot),
                onOpenWork: _destination == _MissionDestination.bots
                    ? () => setState(
                        () => _destination = _MissionDestination.work,
                      )
                    : null,
              ),
              _RoomsTab(
                identityFor: (room) => _snapshot?.roomIdentity(room),
                draftScope: (
                  store: ChatDraftStore(widget.connManager.prefs),
                  connectionId: widget.connection.id,
                  profile: widget.connManager.activeProfileFor(
                    widget.connection.id,
                  ),
                ),
                roomAgents: _roomAgents,
                roomBoard: () => _snapshot?.board,
                refreshPresence: () => _load(refresh: true),
                onOpenBots: _destination == _MissionDestination.work
                    ? () => setState(
                        () => _destination = _MissionDestination.bots,
                      )
                    : null,
                snapshot: snapshot,
                projection: projection,
                copy: copy,
                avatarCache: _profileAvatarCache,
                hostedGroupsDataSource: _hostedGroupsDataSource,
                roomReader: _dataSource is MissionHostedGroupsReadDataSource
                    ? _dataSource as MissionHostedGroupsReadDataSource
                    : null,
                readOnly: widget.connection.readOnly,
                onHostedMutation: _mutateHostedGroup,
                onCreateHostedRoom: _canCreateHostedRoom
                    ? _createHostedRoom
                    : null,
                onOpenMember: _openRoomMember,
                workItems: _projectWorkItems(snapshot, projection),
                onOpenWorkItem: _openWorkItem,
                onRefresh: () => _load(refresh: true),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

final class _RoomPeerCandidate {
  final SavedConnection connection;
  final AgentProfile profile;
  final Map<String, dynamic> catalog;
  const _RoomPeerCandidate(this.connection, this.profile, this.catalog);
  String get key => '${catalog['installation_id']}::${profile.name}';
}

final class _HostedGroupDraft {
  final String name;
  final List<HostedGroupCreateMember> members;

  final List<_RoomPeerCandidate> peers;
  const _HostedGroupDraft({required this.name, required this.members, this.peers = const []});
}

class _HostedGroupCreateDialog extends StatefulWidget {
  final MissionControlCopy copy;
  final String connectionId;
  final String? initialProfile;
  final List<AgentProfile> profiles;
  final MissionProfileAvatarCache? avatarCache;
  final Future<List<_RoomPeerCandidate>> Function()? loadPeers;

  const _HostedGroupCreateDialog({
    required this.copy,
    required this.connectionId,
    required this.profiles,
    required this.avatarCache,
    this.loadPeers,
    this.initialProfile,
  });

  @override
  State<_HostedGroupCreateDialog> createState() =>
      _HostedGroupCreateDialogState();
}

class _HostedGroupCreateDialogState extends State<_HostedGroupCreateDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _filter = TextEditingController();
  final Set<String> _selected = {};
  List<_RoomPeerCandidate>? _peers;
  final Set<String> _selectedPeers = {};
  bool _peersLoading = false;
  Future<void> _readPeers() async {
    setState(() => _peersLoading = true);
    try {
      final peers = await widget.loadPeers!();
      if (mounted) setState(() { _peers = peers; _selectedPeers.retainAll(peers.map((p) => p.key)); });
    } catch (_) { if (mounted) setState(() => _peers = []); }
    finally { if (mounted) setState(() => _peersLoading = false); }
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialProfile != null && widget.profiles.any((p) => p.name == widget.initialProfile)) {
      _selected.add(widget.initialProfile!);
    }
  }

  /// Umbral a partir del cual la lista de bots deja de caber de un vistazo y
  /// el buscador deja de ser adorno. Por debajo, un campo más solo añade
  /// ruido a un diálogo que ya tiene nombre + lista + botones.
  static const int _filterThreshold = 8;

  bool get _canFilter => widget.profiles.length > _filterThreshold;

  @override
  void dispose() {
    _name.dispose();
    _filter.dispose();
    super.dispose();
  }

  /// Solo filtra lo que se PINTA. `_submit` sigue recorriendo
  /// `widget.profiles`, así que un bot ya elegido que el filtro esconda sigue
  /// entrando en la sala: el filtro no puede perder selección.
  List<AgentProfile> get _visibleProfiles {
    final query = _filter.text.trim().toLowerCase();
    if (!_canFilter || query.isEmpty) return widget.profiles;
    return widget.profiles
        .where(
          (profile) =>
              profile.name.toLowerCase().contains(query) ||
              (profile.botTitle ?? '').toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty || (_selected.isEmpty && _selectedPeers.isEmpty)) return;
    final members = <HostedGroupCreateMember>[
      for (final profile in widget.profiles)
        if (_selected.contains(profile.name)) HostedGroupCreateMember.localProfile(profile: profile.name, handle: profile.name),
    ];
    final peers = [for (final peer in _peers ?? <_RoomPeerCandidate>[]) if (_selectedPeers.contains(peer.key)) peer];
    final handles = members.map((m) => m.handle).toSet();
    for (final peer in peers) {
      var suffix = 1;
      var handle = peer.profile.name;
      while (!handles.add(handle)) { handle = '${peer.profile.name}-${suffix++}'; }
      members.add(HostedGroupCreateMember.peer(profile: peer.profile.name, handle: handle,
        peerId: peer.catalog['installation_id'] as String,
        installationId: peer.catalog['installation_id'] as String,
        capabilityDigest: peer.catalog['catalog_digest'] as String));
    }
    Navigator.pop(context, _HostedGroupDraft(name: name, members: List.unmodifiable(members), peers: peers));
  }

  void _toggle(String profileName) => setState(() {
    if (_selected.contains(profileName)) {
      _selected.remove(profileName);
    } else {
      _selected.add(profileName);
    }
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final extra = _RoomsAreaCopy.of(context);
    final visibleProfiles = _visibleProfiles;
    final canSubmit = _name.text.trim().isNotEmpty && (_selected.isNotEmpty || _selectedPeers.isNotEmpty);
    // El inset del teclado NO se vuelve a sumar aquí. La superficie flotante
    // (`_HermesFloatingSurfaceFrame`, `hermes_premium_ui.dart`) ya lo aplica
    // dos veces por su cuenta: desplaza el diálogo con
    // `padding.bottom = viewInsets.bottom` Y le recorta esa misma cantidad al
    // `maxHeight`. Un `20 + viewInsets.bottom` interno contaba el teclado por
    // tercera vez DENTRO de una caja ya encogida: con un teclado real de
    // ~280-320 px la altura utilizable caía a unos pocos píxeles, así que
    // título, campo y lista quedaban aplastados/invisibles y los botones
    // fuera de la superficie. Eso es el diálogo "trabado" reportado en
    // dispositivo real DESPUÉS de arreglar el desbordamiento de la lista (el
    // parche anterior movió todo a un único scroll, pero el inset doble
    // seguía dejando ese scroll con 0 px de alto útil, y con `autofocus` el
    // teclado se abre solo al entrar, así que el diálogo nacía ya trabado).
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Todo el bloque de arriba (título, nombre, lista de miembros) va
          // en un único scroll: antes la lista tenía su propio tope fijo de
          // 320px vía `Flexible`+`ConstrainedBox` sin que nada por encima
          // pudiera ceder espacio, así que en cuanto el teclado se abría (el
          // `maxHeight` del surface flotante ya descuenta `viewInsets.bottom`,
          // ver `_HermesFloatingSurfaceFrame`) el contenido fijo ya no cabía
          // y desbordaba (barra de overflow amarilla/negra, confirmado en
          // dispositivo real). Los botones quedan fuera del scroll para que
          // sigan siempre visibles.
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.copy.createSharedRoom,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    key: const ValueKey('mission-hosted-create-name'),
                    controller: _name,
                    // El `autofocus` abría el teclado nada más entrar, y con
                    // el diálogo ya sin margen vertical (ver el comentario de
                    // `build()` sobre el inset del surface flotante) eso
                    // dejaba la lista de bots reducida a una rendija de
                    // media fila — "se ve todo cortito" / "cuando se abre el
                    // teclado es terrible", confirmado en dispositivo real.
                    // Sin autofocus el diálogo nace con el teclado cerrado y
                    // la lista entera visible; el teclado solo aparece si el
                    // usuario toca el campo a propósito.
                    maxLength: 200,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => FocusScope.of(context).unfocus(),
                    decoration: InputDecoration(
                      labelText: widget.copy.sharedRoomName,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 18),
                  // Cabecera de la selección: instrucción + cuántos van
                  // elegidos ahora mismo. Sin este recuento la única señal de
                  // que la lista es multi-selección era el propio estado de
                  // las filas, y no se leía como algo que haya que completar
                  // antes de poder guardar.
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.copy.chooseSharedMembers,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                      if (_selected.isNotEmpty || _selectedPeers.isNotEmpty)
                        Text(
                          widget.copy.roomMemberCount(_selected.length + _selectedPeers.length),
                          key: const ValueKey(
                            'mission-hosted-create-selected-count',
                          ),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: colors.accentText,
                          ),
                        ),
                    ],
                  ),
                  // Los elegidos suben arriba como pills quitables. Es la
                  // respuesta directa al "todos aparecen apilados en un
                  // montón": lo que llevas hecho deja de estar escondido
                  // dentro de N filas casi idénticas y se ve como una lista
                  // corta, propia y editable.
                  const SizedBox(height: 10),
                  _HostedGroupChosenStrip(
                    profiles: widget.profiles,
                    selected: _selected,
                    avatarCache: widget.avatarCache,
                    extra: extra,
                    onRemove: _toggle,
                  ),
                  if (_canFilter) ...[
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('mission-hosted-create-filter'),
                      controller: _filter,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.search_rounded, size: 19),
                        hintText: widget.copy.searchAgents,
                        suffixIcon: _filter.text.isEmpty
                            ? null
                            : IconButton(
                                key: const ValueKey(
                                  'mission-hosted-create-filter-clear',
                                ),
                                tooltip: widget.copy.clearSearch,
                                onPressed: () =>
                                    setState(() => _filter.clear()),
                                icon: const Icon(Icons.close_rounded, size: 18),
                              ),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ],
                  const SizedBox(height: 10),
                  if (visibleProfiles.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        widget.copy.noMatchingAgents,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.textSecondary,
                        ),
                      ),
                    )
                  else
                    for (final profile in visibleProfiles)
                      _HostedGroupMemberOption(
                        key: ValueKey(
                          'mission-hosted-create-member-${profile.name}',
                        ),
                        profile: profile,
                        avatarCache: widget.avatarCache,
                        selected: _selected.contains(profile.name),
                        onTap: () => _toggle(profile.name),
                      ),
                  if (widget.loadPeers != null) ...[
                    TextButton.icon(onPressed: _peersLoading ? null : _readPeers,
                      icon: const Icon(Icons.public), label: Text(Strings.of(context).botOtherConnections)),
                    if (_peersLoading) const LinearProgressIndicator(),
                    if (_peers != null && _peers!.isEmpty) Text(Strings.of(context).botRoomLinkUnavailable),
                    for (final peer in _peers ?? <_RoomPeerCandidate>[])
                      CheckboxListTile(contentPadding: EdgeInsets.zero,
                        title: Text(peer.profile.botTitle ?? peer.profile.name),
                        subtitle: Text(peer.connection.label),
                        value: _selectedPeers.contains(peer.key),
                        onChanged: (v) => setState(() { if (v == true) { _selectedPeers.add(peer.key); } else { _selectedPeers.remove(peer.key); } })),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
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
                  key: const ValueKey('mission-hosted-create-confirm'),
                  onPressed: canSubmit ? _submit : null,
                  child: Text(widget.copy.save),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Pills de los bots ya elegidos para la sala compartida.
///
/// Sube arriba, junto al recuento, lo que ya llevas hecho. Sin esto la única
/// forma de saber a quién habías elegido era volver a recorrer la lista
/// entera buscando círculos marcados, que es exactamente la sensación de
/// "montón" que se reportó en dispositivo real. Cada pill se puede tocar
/// para quitar a ese bot, así que corregir un toque mal dado no obliga a
/// buscar su fila.
class _HostedGroupChosenStrip extends StatelessWidget {
  final List<AgentProfile> profiles;
  final Set<String> selected;
  final MissionProfileAvatarCache? avatarCache;
  final _RoomsAreaCopy extra;
  final ValueChanged<String> onRemove;

  const _HostedGroupChosenStrip({
    required this.profiles,
    required this.selected,
    required this.avatarCache,
    required this.extra,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final chosen = profiles
        .where((profile) => selected.contains(profile.name))
        .toList(growable: false);
    if (chosen.isEmpty) {
      return Text(
        extra.noMembersChosen,
        key: const ValueKey('mission-hosted-create-chosen-empty'),
        style: TextStyle(fontSize: 12.5, color: colors.textDisabled),
      );
    }
    return Wrap(
      key: const ValueKey('mission-hosted-create-chosen'),
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final profile in chosen)
          Semantics(
            button: true,
            label: '${extra.removeMember} @${profile.name}',
            excludeSemantics: true,
            child: Material(
              key: ValueKey('mission-hosted-create-chosen-${profile.name}'),
              color: colors.accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => onRemove(profile.name),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(4, 4, 9, 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MissionProfileAvatar(
                        profileName: profile.name,
                        hasAvatar: profile.hasAvatar,
                        cache: avatarCache,
                        size: 22,
                        shape: profile.botShape,
                        colorHex: profile.botColorHex,
                        imageKind: profile.botImageKind,
                      ),
                      const SizedBox(width: 7),
                      Text(
                        profile.botTitle ?? profile.name,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: colors.accentText,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Icon(
                        Icons.close_rounded,
                        size: 14,
                        color: colors.accentText,
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

/// Fila de elección de un bot para la sala compartida.
///
/// Cada fila es su propia tarjeta separada, no un renglón de una lista
/// continua: fondo propio, esquinas redondeadas y 8 px de aire entre filas.
/// La versión anterior las apilaba con 2 px y sin fondo, así que N bots se
/// leían como un solo bloque gris indistinguible — el "montón" reportado en
/// dispositivo real.
///
/// El estado elegido no se juega a un detalle: tinte de acento en todo el
/// fondo, borde de acento, nombre en negrita y círculo relleno con check.
/// Sin elegir, el círculo queda vacío sobre un fondo neutro.
class _HostedGroupMemberOption extends StatelessWidget {
  final AgentProfile profile;
  final MissionProfileAvatarCache? avatarCache;
  final bool selected;
  final VoidCallback onTap;

  const _HostedGroupMemberOption({
    required this.profile,
    required this.avatarCache,
    required this.selected,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final title = profile.botTitle ?? profile.name;
    final radius = BorderRadius.circular(18);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        selected: selected,
        child: Material(
          color: selected
              ? colors.accent.withValues(alpha: 0.16)
              : colors.surfaceVariant.withValues(alpha: 0.5),
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(
                  color: selected ? colors.accent : Colors.transparent,
                  width: 1.5,
                ),
              ),
              constraints: const BoxConstraints(minHeight: 56),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              child: Row(
                children: [
                  MissionProfileAvatar(
                    profileName: profile.name,
                    hasAvatar: profile.hasAvatar,
                    cache: avatarCache,
                    size: 38,
                    shape: profile.botShape,
                    colorHex: profile.botColorHex,
                    imageKind: profile.botImageKind,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w600,
                            color: selected
                                ? colors.accentText
                                : colors.textPrimary,
                          ),
                        ),
                        if (title != profile.name)
                          Text(
                            '@${profile.name}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: selected ? colors.accent : Colors.transparent,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected
                            ? colors.accent
                            : colors.divider.withValues(alpha: 0.9),
                        width: 1.6,
                      ),
                    ),
                    child: selected
                        ? Icon(
                            Icons.check_rounded,
                            size: 15,
                            color: colors.accentText,
                          )
                        : null,
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

class _BotsTab extends StatefulWidget {
  final SharedPreferences prefs;
  final String connectionId;
  final MissionBackendSnapshot snapshot;
  final MissionProjection projection;
  final MissionControlCopy copy;
  final MissionProfileAvatarCache? avatarCache;
  final MissionBotActivityStore activityStore;
  final ValueChanged<MissionAgent> onOpenDetail;
  final ValueChanged<MissionAgent> onQuickActions;
  final List<SavedConnection> otherConnections;
  final RemoteBotLoader? remoteBotLoader;
  final void Function(SavedConnection, AgentProfile) onRemoteOpen;
  final void Function(SavedConnection, AgentProfile) onRemoteDetails;
  final VoidCallback? onManageRooms;
  final VoidCallback? onNewSection;
  final ValueChanged<BotSectionGroup>? onSectionMenu;
  final VoidCallback? onAttention;
  final VoidCallback? onCreateAgent;

  /// Sin esto, "crear sala" solo era alcanzable desde la bandeja del dock
  /// flotante (`_botDockCreateOrbits`) — con el dock apagado (interruptor
  /// global de Ajustes), la cabecera de esta pestaña seguía ofreciendo
  /// únicamente "Nuevo agente", así que crear una sala se volvía imposible
  /// sin el dock (bug confirmado, pedido explícito del usuario). Null
  /// cuando la capacidad no está disponible, igual que `onCreateAgent`.
  final VoidCallback? onCreateHostedRoom;

  /// Cuántas salas hay ahora en el destino "Trabajo" y cómo ir allí. Ver
  /// [_MissionDestinationPill]: el dock es opcional y configurable, así que
  /// el cambio de destino necesita una afordancia propia de la pantalla.
  final int roomCount;

  /// Null cuando este destino no es el activo: el `IndexedStack` construye
  /// las dos pestañas a la vez, y una pestaña oculta no debe ofrecer (ni
  /// duplicar en el árbol) la navegación de la que sí se ve.
  final VoidCallback? onOpenWork;

  const _BotsTab({
    required this.prefs,
    required this.connectionId,
    required this.snapshot,
    required this.projection,
    required this.copy,
    required this.avatarCache,
    required this.activityStore,
    required this.onOpenDetail,
    required this.onQuickActions,
    required this.otherConnections,
    this.remoteBotLoader,
    required this.onRemoteOpen,
    required this.onRemoteDetails,
    this.onManageRooms,
    this.onNewSection,
    this.onSectionMenu,
    required this.onAttention,
    required this.onCreateAgent,
    required this.onCreateHostedRoom,
    required this.roomCount,
    required this.onOpenWork,
  });

  @override
  State<_BotsTab> createState() => _BotsTabState();
}

class _BotsTabState extends State<_BotsTab> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  bool _showHidden = false;

  String get _foldKey =>
      'mission.bot-section-folds.v1.${Uri.encodeComponent(widget.connectionId)}';

  Set<String> get _folded =>
      (widget.prefs.getStringList(_foldKey) ?? const <String>[]).toSet();

  void _toggleSection(String key) {
    final folded = _folded;
    if (!folded.remove(key)) folded.add(key);
    setState(() {
      unawaited(
        widget.prefs
            .setStringList(_foldKey, folded.take(256).toList())
            .catchError((Object _) => false),
      );
    });
  }

  List<Widget> _sectionRows(
    BuildContext context,
    List<BotSectionGroup> groups,
  ) {
    final colors = Theme.of(context).hermes;
    final folded = _folded;
    return [
      for (final group in groups) ...[
        Builder(
          builder: (context) {
            final key = group.id == null ? 'unassigned' : 'section:${group.id}';
            final collapsed = folded.contains(key);
            return Semantics(
              expanded: !collapsed,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  key: ValueKey('mission-bot-section-$key'),
                  onTap: () => _toggleSection(key),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      children: [
                        Icon(
                          collapsed ? Icons.chevron_right : Icons.expand_more,
                          size: 18,
                          color: colors.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            group.name ??
                                Strings.of(context).missionBotsUnassigned,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.textSecondary,
                            ),
                          ),
                        ),
                        Text(
                          '${group.agents.length}',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textSecondary,
                          ),
                        ),
                        if (group.id != null && widget.onSectionMenu != null)
                          IconButton(tooltip: Strings.of(context).botSectionRename,
                            icon: const Icon(Icons.more_horiz, size: 18),
                            onPressed: () => widget.onSectionMenu!(group)),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        if (!folded.contains(
          group.id == null ? 'unassigned' : 'section:${group.id}',
        ))
          ..._botRows(context, group.agents, showPinBadge: true),
        Divider(height: 1, color: colors.divider.withValues(alpha: 0.5)),
      ],
    ];
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Botón "+" de la cabecera: mismas dos opciones que la bandeja de
  /// creación del dock (`_botDockCreateOrbits`), para que crear una sala
  /// nunca dependa solo de que el dock flotante esté encendido. Si alguna
  /// opción no está disponible ahora mismo (permisos, capacidad), su fila
  /// simplemente no se pinta en vez de aparecer deshabilitada.
  Future<void> _showSectionList() async {
    final groups = groupBotSections(widget.projection.agents, widget.projection.agents).where((g) => g.id != null).toList();
    final group = await showHermesFloatingSurface<BotSectionGroup>(context: context,
      builder: (context) => ListView(shrinkWrap: true, children: [
        for (final group in groups) ListTile(title: Text(group.name ?? ''),
          onTap: () => Navigator.pop(context, group)),
      ]));
    if (mounted && group != null) widget.onSectionMenu?.call(group);
  }

  Future<void> _showCreateChooser(BuildContext context) async {
    final onCreateAgent = widget.onCreateAgent;
    final onCreateHostedRoom = widget.onCreateHostedRoom;
    final strings = Strings.of(context);
    if (onCreateAgent == null && onCreateHostedRoom == null) return;
    await showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('mission-create-chooser'),
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onCreateAgent != null)
              ListTile(
                key: const ValueKey('mission-create-chooser-bot'),
                leading: const Icon(Icons.smart_toy_outlined),
                title: Text(strings.missionCreateBotLabel),
                onTap: () {
                  Navigator.pop(sheetContext);
                  onCreateAgent();
                },
              ),
            if (widget.onSectionMenu != null && widget.projection.agents.any((a) => a.profile.botSectionId != null))
              ListTile(leading: const Icon(Icons.folder_outlined), title: Text(strings.botSectionsManage),
                onTap: () { Navigator.pop(sheetContext); _showSectionList(); }),
            if (widget.onManageRooms != null)
            ListTile(leading: const Icon(Icons.forum_outlined), title: Text(strings.botManageRooms),
              onTap: () { Navigator.pop(sheetContext); widget.onManageRooms!(); }),
          if (widget.onNewSection != null)
              ListTile(leading: const Icon(Icons.create_new_folder_outlined),
                title: Text(strings.botSectionNew), onTap: () {
                  Navigator.pop(sheetContext); widget.onNewSection!();
                }),
            if (onCreateHostedRoom != null)
              ListTile(
                key: const ValueKey('mission-create-chooser-room'),
                leading: const Icon(Icons.groups_2_outlined),
                title: Text(strings.missionCreateRoomLabel),
                onTap: () {
                  Navigator.pop(sheetContext);
                  onCreateHostedRoom();
                },
              ),
          ],
        ),
      ),
    );
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
  BotLiveStatus _liveStatus(MissionAgent agent) => BotLiveStatus.forAgent(
    agent: agent,
    now: DateTime.now(),
    rooms: widget.snapshot.hostedGroups,
  );
  bool _needsYou(MissionAgent agent) =>
      _liveStatus(agent).presence == RoomPresence.needsYou;

  bool _activeNow(MissionAgent agent) => const {
    RoomPresence.working,
    RoomPresence.active,
  }.contains(_liveStatus(agent).presence);

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

  /// [showPinBadge] controla el indicador de fijado junto al nombre: se omite
  /// dentro de la propia sección "Fijados" y, fuera de ella, es gris apagado
  /// con secciones (Activos ahora / Otros bots) o acento sin ellas (búsqueda
  /// activa), según la especificación del mockup más reciente.
  List<Widget> _botRows(
    BuildContext context,
    List<MissionAgent> agents, {
    required bool showPinBadge,
  }) {
    final colors = Theme.of(context).hermes;
    final widgets = <Widget>[];
    for (var index = 0; index < agents.length; index++) {
      final agent = agents[index];
      final activityAtMs = _missionBotActivityMs(agent);
      widgets.add(
        _BotRow(
          key: ValueKey('mission-bot-row-${agent.profile.name}'),
          agent: agent,
          live: _liveStatus(agent),
          pinnedChat: _pinnedBotChat(agent),
          needsYou: _needsYou(agent),
          unread: widget.activityStore.isUnread(
            widget.connectionId,
            agent.profile.name,
            activityAtMs,
          ),
          copy: widget.copy,
          avatarCache: widget.avatarCache,
          onOpen: () => widget.onOpenDetail(agent),
          onQuickActions: () => widget.onQuickActions(agent),
          pinBadgeColor: !showPinBadge || !agent.profile.botPinned
              ? null
              : (_query.trim().isEmpty
                    ? colors.textDisabled
                    : colors.accentText),
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

  /// Fila horizontal con scroll lateral para "Fijados": avatares de 64px con
  /// anillo de estado y nombre debajo, en vez de la lista vertical que usan
  /// el resto de secciones. Especificación confirmada con el usuario tras
  /// una ronda de mockups contradictorios (ver PR #29): la primera versión
  /// de este parche probó una sección vertical y no era la acordada.
  Widget _pinnedStrip(BuildContext context, List<MissionAgent> agents) =>
      SizedBox(
        height: 88 + MediaQuery.textScalerOf(context).scale(25),
        child: ListView.separated(
          key: const ValueKey('mission-pinned-strip'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          clipBehavior: Clip.none,
          itemCount: agents.length,
          separatorBuilder: (_, _) => const SizedBox(width: 18),
          itemBuilder: (context, index) {
            final agent = agents[index];
            final activityAtMs = _missionBotActivityMs(agent);
            return _PinnedBotTile(
              key: ValueKey('mission-pinned-tile-${agent.profile.name}'),
              agent: agent,
              needsYou: _needsYou(agent),
              live: _liveStatus(agent),
              unread: widget.activityStore.isUnread(
                widget.connectionId,
                agent.profile.name,
                activityAtMs,
              ),
              avatarCache: widget.avatarCache,
              onOpen: () => widget.onOpenDetail(agent),
              onQuickActions: () => widget.onQuickActions(agent),
            );
          },
        ),
      );

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
    final searching = _query.trim().isNotEmpty;
    // Fuera de búsqueda los bots fijados se agrupan en su propia sección
    // ("Fijados"), estén activos o en reposo, así que no aparecen también en
    // "Activos ahora" u "Otros bots". Con búsqueda activa no hay secciones:
    // el pin vuelve a leerse como badge en línea (ver _botRows).
    final pinned = searching
        ? const <MissionAgent>[]
        : agents
              .where((agent) => agent.profile.botPinned)
              .toList(growable: false);
    final unpinned = searching
        ? agents
        : agents.where((agent) => !agent.profile.botPinned);
    final active = searching
        ? const <MissionAgent>[]
        : unpinned.where(_activeNow).toList(growable: false);
    final resting = searching
        ? agents
        : unpinned.where((agent) => !_activeNow(agent)).toList(growable: false);
    final hasSections =
        !searching &&
        agents.any(
          (agent) =>
              agent.profile.botSectionId != null &&
              agent.profile.botSectionName != null,
        );
    return ListView(
      key: const ValueKey('mission-bots'),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
      children: [
        if (widget.onOpenWork != null) ...[
          _MissionDestinationPill(
            controlKey: const ValueKey('mission-goto-work'),
            icon: Icons.groups_2_outlined,
            label: widget.copy.work,
            detail: widget.copy.roomCount(widget.roomCount),
            onTap: widget.onOpenWork!,
          ),
          const SizedBox(height: 14),
        ],
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
          actionLabel: Strings.of(context).missionCreateLabel,
          actionIcon: Icons.add_rounded,
          onAction:
              widget.onCreateAgent == null && widget.onCreateHostedRoom == null
              ? null
              : () => unawaited(_showCreateChooser(context)),
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
          if (hiddenCount > 0 || widget.otherConnections.isNotEmpty) ...[
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
                      : hiddenCount == 0 ? Strings.of(context).botShowHidden : copy.showHiddenBots(hiddenCount),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).hermes.textSecondary,
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          if (agents.isEmpty)
            _MessageCard(text: copy.noMatchingAgents)
          else ...[
            if (pinned.isNotEmpty) ...[
              _BotSectionLabel(
                key: const ValueKey('mission-pinned'),
                title: copy.pinnedBots,
                count: pinned.length,
                icon: Icons.push_pin_rounded,
              ),
              const SizedBox(height: 9),
              _pinnedStrip(context, pinned),
              if (active.isNotEmpty || resting.isNotEmpty)
                const SizedBox(height: 18),
            ],
            if (active.isNotEmpty) ...[
              _BotSectionLabel(
                key: const ValueKey('mission-active-now'),
                title: copy.activeNow,
                count: active.length,
              ),
              const SizedBox(height: 4),
              ..._botRows(context, active, showPinBadge: true),
              if (resting.isNotEmpty) const SizedBox(height: 18),
            ],
            if (resting.isNotEmpty) ...[
              _BotSectionLabel(
                title: _query.trim().isNotEmpty
                    ? copy.searchResults
                    : active.isNotEmpty || pinned.isNotEmpty
                    ? copy.otherBots
                    : copy.allBots,
                count: resting.length,
              ),
              const SizedBox(height: 4),
              if (hasSections)
                ..._sectionRows(context, groupBotSections(resting, agents))
              else
                ..._botRows(context, resting, showPinBadge: true),
            ],
          ],
        ],
        if (widget.otherConnections.isNotEmpty)
          RemoteBotRoster(connections: widget.otherConnections, prefs: widget.prefs, query: _query,
            showHidden: _showHidden, refreshedAt: widget.snapshot.loadedAt,
            onOpen: widget.onRemoteOpen, onDetails: widget.onRemoteDetails,
            loader: widget.remoteBotLoader),
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

// Compiladas una sola vez: con búsqueda activa `_matches` pliega hasta seis
// campos por bot en cada build de la pestaña, y la pestaña se reconstruye con
// cada refresco de Mission Control.
final RegExp _foldSearchA = RegExp(r'[áàäâãå]');
final RegExp _foldSearchE = RegExp(r'[éèëê]');
final RegExp _foldSearchI = RegExp(r'[íìïî]');
final RegExp _foldSearchO = RegExp(r'[óòöôõ]');
final RegExp _foldSearchU = RegExp(r'[úùüû]');
final RegExp _foldSearchSpaces = RegExp(r'\s+');

String _foldBotSearch(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll(_foldSearchA, 'a')
    .replaceAll(_foldSearchE, 'e')
    .replaceAll(_foldSearchI, 'i')
    .replaceAll(_foldSearchO, 'o')
    .replaceAll(_foldSearchU, 'u')
    .replaceAll('ñ', 'n')
    .replaceAll(_foldSearchSpaces, ' ');

class _BotSectionLabel extends StatelessWidget {
  final String title;
  final int count;
  final IconData? icon;

  const _BotSectionLabel({
    required this.title,
    required this.count,
    this.icon,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: colors.accentText),
          const SizedBox(width: 6),
        ],
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

typedef _RoomDraftScope = ({
  ChatDraftStore store,
  String connectionId,
  String profile,
});

class _RoomsTab extends StatelessWidget {
  final RoomMirrorIdentity? Function(HostedGroupRoom) identityFor;
  final _RoomDraftScope draftScope;
  final List<MissionAgent> Function() roomAgents;
  final KanbanBoard? Function() roomBoard;
  final Future<void> Function() refreshPresence;
  final MissionBackendSnapshot snapshot;
  final MissionProjection projection;
  final MissionControlCopy copy;
  final MissionProfileAvatarCache? avatarCache;
  final MissionHostedGroupsDataSource? hostedGroupsDataSource;
  final MissionHostedGroupsReadDataSource? roomReader;
  final bool readOnly;
  final Future<HostedGroupWorkspaceReadback> Function(
    HostedGroupRoom expectedRoom,
    Future<HostedGroupWorkspaceReadback> Function(
      MissionHostedGroupsDataSource source,
      HostedGroupRoom room,
      int generation,
    )
    action,
  )
  onHostedMutation;
  final VoidCallback? onCreateHostedRoom;
  final ValueChanged<String> onOpenMember;
  final List<WorkItem> workItems;
  final Future<void> Function(WorkItem, WorkDestination) onOpenWorkItem;
  final Future<void> Function() onRefresh;
  final VoidCallback? onOpenBots;

  const _RoomsTab({
    required this.identityFor,
    required this.draftScope,
    required this.snapshot,
    required this.roomAgents,
    required this.roomBoard,
    required this.refreshPresence,
    required this.projection,
    required this.copy,
    required this.avatarCache,
    required this.hostedGroupsDataSource,
    required this.roomReader,
    required this.readOnly,
    required this.onHostedMutation,
    required this.onCreateHostedRoom,
    required this.onOpenMember,
    required this.workItems,
    required this.onOpenWorkItem,
    required this.onRefresh,
    required this.onOpenBots,
  });

  @override
  Widget build(BuildContext context) {
    final extra = _RoomsAreaCopy.of(context);
    final boardItems = workItems
        .where((item) => item.destination is BoardDestination)
        .toList(growable: false);
    final boardItem = boardItems.isEmpty ? null : boardItems.first;
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        key: const ValueKey('mission-work-feed'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
        children: [
          if (onOpenBots != null) ...[
            _MissionDestinationPill(
              controlKey: const ValueKey('mission-goto-bots'),
              icon: Icons.smart_toy_outlined,
              label: copy.bots,
              detail: '${projection.agents.length}',
              onTap: onOpenBots!,
            ),
            const SizedBox(height: 4),
          ],
          // Los miembros locales de una sala se resuelven contra
          // `snapshot.profiles` (para pintar avatar real y abrir su ficha);
          // sin esa capacidad las salas guardadas se siguen viendo, pero solo
          // en modo consulta (sin poder verificar quién es cada miembro).
          if (snapshot.profilesCapability == MissionCapabilityState.unsupported)
            _MessageCard(text: copy.roomsBrowseOnly),
          _HostedRoomsSection(
            identityFor: identityFor,
            draftScope: draftScope,
            roomAgents: roomAgents,
            roomBoard: roomBoard,
            refreshPresence: refreshPresence,
            roomReader: roomReader,
            snapshot: snapshot,
            copy: copy,
            extra: extra,
            avatarCache: avatarCache,
            first: onOpenBots == null,
            enabled:
                !readOnly &&
                hostedGroupsDataSource != null &&
                snapshot.hostedGroupsCapability ==
                    MissionCapabilityState.available,
            onMutation: onHostedMutation,
            onCreate: onCreateHostedRoom,
            onOpenMember: onOpenMember,
          ),
          if (snapshot.kanbanCapability != MissionCapabilityState.available)
            _MessageCard(text: copy.kanbanUnavailable),
          _GlobalWorkTray(
            items: workItems,
            copy: copy,
            onDestination: (item, destination) =>
                unawaited(onOpenWorkItem(item, destination)),
          ),
          if (boardItem != null)
            _BoardSection(
              item: boardItem,
              extra: extra,
              onOpen: (destination) =>
                  unawaited(onOpenWorkItem(boardItem, destination)),
            ),
        ],
      ),
    );
  }
}

/// Acceso nativo entre los dos destinos de esta pantalla (Bots ↔ Trabajo).
class _MissionDestinationPill extends StatelessWidget {
  /// Va en la pill en sí (no en el `Align` que la alinea a la derecha), para
  /// que la clave identifique el área que de verdad recibe el toque.
  final Key controlKey;
  final IconData icon;
  final String label;
  final String detail;
  final VoidCallback onTap;

  const _MissionDestinationPill({
    required this.controlKey,
    required this.icon,
    required this.label,
    required this.detail,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    // Con tipografías muy grandes la pill se queda solo con la etiqueta: el
    // recuento es contexto, no navegación, y a 2x no cabe en 320 dp.
    final compact = MediaQuery.textScalerOf(context).scale(1) > 1.5;
    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: Material(
        key: controlKey,
        color: colors.surfaceVariant.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 14, end: 8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 17, color: colors.accentText),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (!compact) ...[
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 17,
                    color: colors.textDisabled,
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

class _HostedRoomsSection extends StatelessWidget {
  final RoomMirrorIdentity? Function(HostedGroupRoom) identityFor;
  final _RoomDraftScope draftScope;
  final List<MissionAgent> Function() roomAgents;
  final KanbanBoard? Function() roomBoard;
  final Future<void> Function() refreshPresence;
  final MissionBackendSnapshot snapshot;
  final MissionHostedGroupsReadDataSource? roomReader;
  final MissionControlCopy copy;
  final _RoomsAreaCopy extra;
  final MissionProfileAvatarCache? avatarCache;
  final bool first;
  final bool enabled;
  final Future<HostedGroupWorkspaceReadback> Function(
    HostedGroupRoom expectedRoom,
    Future<HostedGroupWorkspaceReadback> Function(
      MissionHostedGroupsDataSource source,
      HostedGroupRoom room,
      int generation,
    )
    action,
  )
  onMutation;
  final VoidCallback? onCreate;

  /// Ver `_RoomsTab.onOpenMember`.
  final ValueChanged<String> onOpenMember;

  const _HostedRoomsSection({
    required this.identityFor,
    required this.draftScope,
    required this.snapshot,
    required this.roomAgents,
    required this.roomBoard,
    required this.refreshPresence,
    required this.roomReader,
    required this.copy,
    required this.extra,
    required this.avatarCache,
    required this.first,
    required this.enabled,
    required this.onMutation,
    required this.onCreate,
    required this.onOpenMember,
  });

  Future<String?> _promptText(
    BuildContext context, {
    required String title,
    String initial = '',
  }) async {
    var value = initial;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: initial,
          autofocus: true,
          maxLength: 200,
          onChanged: (next) => value = next,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(copy.cancel),
          ),
          TextButton(
            onPressed: () {
              final result = value.trim();
              if (result.isNotEmpty) Navigator.pop(dialogContext, result);
            },
            child: Text(copy.save),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirm(BuildContext context, String title) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(copy.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(copy.confirm),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _consumePresentedMutation(
    Future<HostedGroupWorkspaceReadback> Function() mutation,
  ) async {
    try {
      await mutation();
    } catch (_) {
      // The owning screen has already surfaced the generic localized failure.
      // A tap callback must not leak that deliberately rethrown failure into
      // Flutter's uncaught asynchronous error channel.
    }
  }

  Future<void> _renameRoom(
    BuildContext context,
    HostedGroupRoom expectedRoom,
    String currentName,
  ) async {
    final name = await _promptText(
      context,
      title: copy.renameSharedRoom,
      initial: currentName,
    );
    if (name == null || !context.mounted) return;
    await _consumePresentedMutation(
      () => onMutation(
        expectedRoom,
        (source, room, generation) =>
            source.renameHostedGroup(room, name: name, generation: generation),
      ),
    );
  }

  Future<void> _stopRoom(
    BuildContext context,
    HostedGroupRoom expectedRoom,
  ) async {
    if (!await _confirm(context, copy.stopSharedRoom) || !context.mounted) {
      return;
    }
    await _consumePresentedMutation(
      () => onMutation(
        expectedRoom,
        (source, room, generation) =>
            source.stopHostedGroup(room, generation: generation),
      ),
    );
  }

  Future<void> _disbandRoom(
    BuildContext context,
    HostedGroupRoom expectedRoom,
  ) async {
    if (!await _confirm(context, copy.disbandSharedRoom) || !context.mounted) {
      return;
    }
    await _consumePresentedMutation(
      () => onMutation(
        expectedRoom,
        (source, room, generation) =>
            source.disbandHostedGroup(room, generation: generation),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final capabilities = snapshot.hostedGroups.capabilities;
    final rooms = snapshot.hostedGroups.rooms;
    final logs = snapshot.hostedGroups.logs;
    final activeRooms =
        <({int sourceIndex, HostedGroupRoom room, HostedGroupLogPage? log})>[
          for (var sourceIndex = 0; sourceIndex < rooms.length; sourceIndex++)
            if (!rooms[sourceIndex].disbanded)
              (
                sourceIndex: sourceIndex,
                room: rooms[sourceIndex],
                log: sourceIndex < logs.length ? logs[sourceIndex] : null,
              ),
        ];
    final visible =
        snapshot.hostedGroupsCapability == MissionCapabilityState.available &&
        capabilities?.hasSharedRoomSurface == true;
    return Semantics(
      container: true,
      label: copy.sharedRooms,
      child: Column(
        key: const ValueKey('mission-shared-rooms'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RoomsSectionLabel(
            icon: Icons.cloud_outlined,
            label: copy.sharedRooms,
            count: visible ? activeRooms.length : null,
            caption: visible
                ? capabilities!.driverReady
                      ? extra.sharedRoomsExplanation
                      : copy.roomDriverUnavailable
                : copy.sharedRoomsUnavailable,
            first: first,
            actionKey: const ValueKey('mission-hosted-create'),
            actionLabel: copy.createSharedRoom,
            actionIcon: Icons.add_rounded,
            onAction: capabilities?.supports(GroupMethod.create) == true
                ? onCreate
                : null,
          ),
          if (visible)
            _RoomsCardGroup(
              rows: [
                if (activeRooms.isEmpty)
                  _RoomsCardNote(text: copy.noSharedRooms)
                else
                  for (var index = 0; index < activeRooms.length; index++)
                    _hostedRoomCard(context, capabilities, activeRooms, index),
              ],
            ),
        ],
      ),
    );
  }

  Widget _hostedRoomCard(
    BuildContext context,
    GroupsCapabilities? capabilities,
    List<({int sourceIndex, HostedGroupRoom room, HostedGroupLogPage? log})>
    activeRooms,
    int index,
  ) => _HostedRoomCard(
    key: ValueKey('mission-hosted-room-$index'),
    identity: identityFor(activeRooms[index].room),
    room: activeRooms[index].room,
    log: activeRooms[index].log,
    copy: copy,
    avatarCache: avatarCache,
    localProfiles: {
      for (final profile in snapshot.profiles) profile.name: profile,
    },
    canSend: enabled && capabilities!.supports(GroupMethod.send),
    canRename: enabled && capabilities!.supports(GroupMethod.rename),
    canStop: enabled && capabilities!.supports(GroupMethod.stop),
    canDisband: enabled && capabilities!.supports(GroupMethod.disband),
    onOpen: () => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _HostedRoomWorkspace(
          identityFor: identityFor,
          draftScope: draftScope,
          agents: roomAgents,
          board: roomBoard,
          refreshPresence: refreshPresence,
          room: activeRooms[index].room,
          onRead: roomReader == null
              ? null
              : (room) => roomReader!.readHostedGroup(
                  room,
                  generation: capabilities!.generation,
                ),
          log: activeRooms[index].log,
          copy: copy,
          avatarCache: avatarCache,
          localProfiles: {
            for (final profile in snapshot.profiles) profile.name: profile,
          },
          onOpenMember: onOpenMember,
          canSend: enabled && capabilities!.supports(GroupMethod.send),
          canRename: enabled && capabilities!.supports(GroupMethod.rename),
          canStop: enabled && capabilities!.supports(GroupMethod.stop),
          canDisband: enabled && capabilities!.supports(GroupMethod.disband),
          onSend: (text, attempt) => onMutation(
            activeRooms[index].room,
            (source, room, generation) => source.sendHostedGroupText(
              room,
              text: text,
              attempt: attempt,
              generation: generation,
            ),
          ),
          onRename: (name) => onMutation(
            activeRooms[index].room,
            (source, room, generation) => source.renameHostedGroup(
              room,
              name: name,
              generation: generation,
            ),
          ),
          onStop: () => onMutation(
            activeRooms[index].room,
            (source, room, generation) =>
                source.stopHostedGroup(room, generation: generation),
          ),
          onDisband: () => onMutation(
            activeRooms[index].room,
            (source, room, generation) =>
                source.disbandHostedGroup(room, generation: generation),
          ),
        ),
      ),
    ),
    onSend: () async {
      final text = await _promptText(context, title: copy.sendSharedMessage);
      if (text == null || !context.mounted) return;
      final attempt = HostedGroupSendAttempt.forClientEvent(const Uuid().v4());
      await _consumePresentedMutation(
        () => onMutation(
          activeRooms[index].room,
          (source, room, generation) => source.sendHostedGroupText(
            room,
            text: text,
            attempt: attempt,
            generation: generation,
          ),
        ),
      );
    },
    onRename: () => _renameRoom(
      context,
      activeRooms[index].room,
      activeRooms[index].room.name,
    ),
    onStop: () => _stopRoom(context, activeRooms[index].room),
    onDisband: () => _disbandRoom(context, activeRooms[index].room),
  );
}

class _HostedRoomWorkspace extends StatefulWidget {
  final RoomMirrorIdentity? Function(HostedGroupRoom) identityFor;
  final _RoomDraftScope draftScope;
  final List<MissionAgent> Function() agents;
  final KanbanBoard? Function() board;
  final Future<void> Function() refreshPresence;
  final HostedGroupRoom room;
  final Future<HostedGroupWorkspaceReadback> Function(HostedGroupRoom)? onRead;
  final HostedGroupLogPage? log;
  final MissionControlCopy copy;
  final MissionProfileAvatarCache? avatarCache;

  // Perfiles LOCALES a esta conexión, por nombre, con el mismo criterio que
  // `_HostedRoomCard.localProfiles`: un miembro que coincide aquí es uno de
  // tus propios bots y puede pintar su avatar real y abrir su ficha. Los que
  // no coinciden son miembros de otra conexión (sala federada) y de ellos la
  // app no tiene ficha ninguna.
  final Map<String, AgentProfile> localProfiles;

  /// Ver `_RoomsTab.onOpenMember`.
  final ValueChanged<String> onOpenMember;
  final bool canSend;
  final bool canRename;
  final bool canStop;
  final bool canDisband;

  final Future<HostedGroupWorkspaceReadback> Function(
    String text,
    HostedGroupSendAttempt attempt,
  )
  onSend;
  final Future<HostedGroupWorkspaceReadback> Function(String name) onRename;
  final Future<HostedGroupWorkspaceReadback> Function() onStop;
  final Future<HostedGroupWorkspaceReadback> Function() onDisband;

  const _HostedRoomWorkspace({
    required this.identityFor,
    required this.draftScope,
    required this.room,
    required this.agents,
    required this.board,
    required this.refreshPresence,
    this.onRead,
    required this.log,
    required this.copy,
    required this.avatarCache,
    required this.localProfiles,
    required this.onOpenMember,
    required this.canSend,
    required this.canRename,
    required this.canStop,
    required this.canDisband,

    required this.onSend,
    required this.onRename,
    required this.onStop,
    required this.onDisband,
  });

  @override
  State<_HostedRoomWorkspace> createState() => _HostedRoomWorkspaceState();
}

class _HostedRoomWorkspaceState extends State<_HostedRoomWorkspace>
    with WidgetsBindingObserver {
  Timer? _refreshTimer;
  bool _refreshingRoom = false;
  DateTime? _presenceRefreshedAt;
  Map<String, MissionAgent> _presenceAgents = const {};
  final Map<(String, String?), BotLiveStatus> _statusCache = {};
  DateTime _presenceNow = DateTime.now();
  bool _paused = false;
  String? _roomError;

  void _scheduleRoomRefresh() {
    _refreshTimer?.cancel();
    if (!mounted || _paused || widget.onRead == null) return;
    _refreshTimer = Timer(const Duration(seconds: 3), _refreshRoom);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _paused = state != AppLifecycleState.resumed;
    if (_paused) {
      _refreshTimer?.cancel();
      _flushRoomDraft();
    } else {
      _scheduleRoomRefresh();
    }
  }

  Future<void> _refreshRoom() async {
    if (!mounted || _paused) return;
    if (_sending ||
        _refreshingRoom ||
        ModalRoute.of(context)?.isCurrent != true) {
      _scheduleRoomRefresh();
      return;
    }
    final read = widget.onRead;
    if (read == null) return;
    _refreshingRoom = true;
    final previous = _room;
    try {
      final now = DateTime.now();
      _presenceRefreshedAt ??= now;
      if (now.difference(_presenceRefreshedAt!).inSeconds >= 30) {
        _presenceRefreshedAt = now;
        await widget.refreshPresence();
      }
      final result = await read(previous);
      if (!mounted || _paused || _sending || !identical(previous, _room)) {
        return;
      }
      if (result.room.roomId != previous.roomId ||
          result.room.authorityGatewayId != previous.authorityGatewayId ||
          result.room.authorityEpoch != previous.authorityEpoch ||
          result.room.revision < previous.revision ||
          result.log == null ||
          result.log!.latestSeq < (_log?.latestSeq ?? 0)) {
        throw const FormatException('Room refresh authority changed');
      }
      setState(() {
        _room = result.room;
        _log = result.log;
        _roomError = null;
      });
    } catch (_) {
      if (mounted && !_paused) {
        setState(() => _roomError = widget.copy.roomRefreshFailed);
      }
    } finally {
      _refreshingRoom = false;
      _scheduleRoomRefresh();
    }
  }

  Timer? _draftTimer;
  bool _draftDirty = false;
  bool _restoringRoomDraft = false;
  late final String _draftSessionId;

  Future<void> _restoreRoomDraft() async {
    try {
      final scope = widget.draftScope;
      final draft = await scope.store.load(
        scope.connectionId,
        _draftSessionId,
        profile: scope.profile,
      );
      if (!mounted || _draftDirty) return;
      _restoringRoomDraft = true;
      _threadId = draft.replyThreadId;
      _composer.text = draft.text;
      _restoringRoomDraft = false;
    } catch (_) {
      // Never replace an unreadable encrypted draft with an empty snapshot.
    }
  }

  void _scheduleRoomDraft() {
    if (_restoringRoomDraft) return;
    _draftDirty = true;
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 350), _flushRoomDraft);
  }

  void _flushRoomDraft() {
    _draftTimer?.cancel();
    if (!_draftDirty) return;
    final scope = widget.draftScope;
    unawaited(
      scope.store
          .save(
            scope.connectionId,
            _draftSessionId,
            _composer.text,
            const [],
            profile: scope.profile,
            replyThreadId: _threadId,
            preparedTurnClientTurnId: _pendingAttempt?.clientEventId,
          )
          .then<void>((_) {}, onError: (Object _) {}),
    );
  }

  final TextEditingController _composer = TextEditingController();
  final FocusNode _composerFocus = FocusNode();
  late HostedGroupRoom _room;
  HostedGroupLogPage? _log;
  String? _threadId;
  bool _sending = false;
  HostedGroupSendAttempt? _pendingAttempt;
  String? _pendingText;
  String? _pendingThreadId;

  // El backend real ya resuelve @menciones del texto plano del mensaje
  // (`resolve_mentions` en el gateway, confirmado leyendo el código del
  // servidor) — @all/@everyone incluidos. Esto es solo el autocompletado:
  // pura UX de cliente sobre algo que el protocolo ya entiende, no un
  // invento de Console.
  String? _mentionQuery;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleRoomRefresh();
    _room = widget.room;
    _draftSessionId =
        'mob-room-${base64Url.encode(utf8.encode(jsonEncode([_room.authorityGatewayId, _room.roomId])))}';
    _composer.addListener(_scheduleRoomDraft);
    unawaited(_restoreRoomDraft());
    _log = widget.log;
    _composer.addListener(_retireChangedAttempt);
    _composer.addListener(_updateMentionQuery);
    _composer.addListener(_onComposerEmptinessChange);
    _composerFocus.addListener(_onComposerFocusChange);
  }

  void _onComposerFocusChange() => setState(() {});

  /// El botón de envío se atenúa con el campo vacío, así que la transición
  /// vacío ↔ con texto tiene que repintar. `_updateMentionQuery` solo
  /// reconstruye cuando cambia la mención en curso, que no es lo mismo.
  void _onComposerEmptinessChange() {
    setState(() {});
  }

  void _retireChangedAttempt() {
    if (_pendingAttempt != null && _composer.text.trim() != _pendingText) {
      _pendingAttempt = null;
      _pendingText = null;
      _pendingThreadId = null;
    }
  }

  void _updateMentionQuery() {
    final text = _composer.text;
    final cursor = _composer.selection.baseOffset;
    if (cursor < 0 || cursor > text.length) {
      if (_mentionQuery != null) setState(() => _mentionQuery = null);
      return;
    }
    final upToCursor = text.substring(0, cursor);
    final at = upToCursor.lastIndexOf('@');
    if (at == -1 || (at > 0 && !RegExp(r'\s').hasMatch(upToCursor[at - 1]))) {
      if (_mentionQuery != null) setState(() => _mentionQuery = null);
      return;
    }
    final fragment = upToCursor.substring(at + 1);
    // Un espacio cierra la mención en curso — coincide con cómo el propio
    // servidor extrae handles del texto (`@([A-Za-z0-9][A-Za-z0-9._:-]*)`).
    if (fragment.contains(RegExp(r'\s'))) {
      if (_mentionQuery != null) setState(() => _mentionQuery = null);
      return;
    }
    setState(() => _mentionQuery = fragment);
  }

  List<HostedGroupMember> _mentionMatches() {
    final query = _mentionQuery;
    if (query == null) return const [];
    final lower = query.toLowerCase();
    return _room.members
        .where((member) => member.handle.toLowerCase().startsWith(lower))
        .toList(growable: false);
  }

  void _applyMention(String handle) {
    final text = _composer.text;
    final cursor = _composer.selection.baseOffset;
    if (cursor < 0 || cursor > text.length) return;
    final upToCursor = text.substring(0, cursor);
    final at = upToCursor.lastIndexOf('@');
    if (at == -1) return;
    final replaced =
        '${text.substring(0, at)}@$handle ${text.substring(cursor)}';
    final newOffset = at + handle.length + 2;
    _composer.value = TextEditingValue(
      text: replaced,
      selection: TextSelection.collapsed(offset: newOffset),
    );
    setState(() => _mentionQuery = null);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    _flushRoomDraft();
    _composer.removeListener(_scheduleRoomDraft);
    _composer.removeListener(_retireChangedAttempt);
    _composer.removeListener(_updateMentionQuery);
    _composer.removeListener(_onComposerEmptinessChange);
    _composer.dispose();
    _composerFocus.removeListener(_onComposerFocusChange);
    _composerFocus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _sending || !widget.canSend) return;
    if (_pendingAttempt == null ||
        _pendingText != text ||
        _pendingThreadId != _threadId) {
      _pendingAttempt = HostedGroupSendAttempt.forClientEvent(
        const Uuid().v4(),
        threadId: _threadId,
      );
      _pendingText = text;
      _pendingThreadId = _threadId;
    }
    final attempt = _pendingAttempt!;
    _flushRoomDraft();
    final draftScope = widget.draftScope;
    final submittedThread = _threadId;
    setState(() => _sending = true);
    try {
      final result = await widget.onSend(text, attempt);
      try {
        await draftScope.store.clear(
          draftScope.connectionId,
          _draftSessionId,
          profile: draftScope.profile,
          onlyPreparedTurnClientTurnId: attempt.clientEventId,
        );
      } catch (_) {
        // A storage failure must not turn an acknowledged send into a retry.
      }
      if (!mounted) return;
      setState(() {
        _room = result.room;
        _log = result.log;
        _sending = false;
        _roomError = null;
        _pendingAttempt = null;
        _pendingText = null;
        _pendingThreadId = null;
        if (_composer.text.trim() == text && _threadId == submittedThread) {
          _composer.clear();
          _threadId = null;
          _flushRoomDraft();
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _sending = false;
          _roomError = widget.copy.hostedActionFailed;
        });
      }
    }
  }

  Future<String?> _promptName() async {
    var value = _room.name;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(widget.copy.renameSharedRoom),
        content: TextFormField(
          initialValue: value,
          autofocus: true,
          maxLength: 200,
          onChanged: (next) => value = next,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(widget.copy.cancel),
          ),
          TextButton(
            onPressed: () {
              final name = value.trim();
              if (name.isNotEmpty) Navigator.pop(dialogContext, name);
            },
            child: Text(widget.copy.save),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirm(String title) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(widget.copy.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(widget.copy.confirm),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _rename() async {
    final name = await _promptName();
    if (name == null || !mounted) return;
    try {
      final result = await widget.onRename(name);
      if (mounted) {
        setState(() {
          _room = result.room;
          _log = result.log;
        });
      }
    } catch (_) {}
  }

  Future<void> _stop() async {
    if (!await _confirm(widget.copy.stopSharedRoom) || !mounted) {
      return;
    }
    try {
      final result = await widget.onStop();
      if (mounted) {
        setState(() {
          _room = result.room;
          _log = result.log;
        });
      }
    } catch (_) {}
  }

  Future<void> _disband() async {
    if (!await _confirm(widget.copy.disbandSharedRoom) || !mounted) {
      return;
    }
    try {
      final result = await widget.onDisband();
      if (!mounted || !result.room.disbanded) return;
      Navigator.of(context).pop();
    } catch (_) {}
  }

  RoomMemberStatus _status(
    HostedGroupMember member, {
    HostedGroupEvent? message,
  }) => _statusCache.putIfAbsent(
    (member.memberId, message?.eventId),
    () => BotLiveStatus.derive(
      member: member,
      events: _log?.events ?? const [],
      now: _presenceNow,
      agent: member.owner.connectionId == _room.authorityGatewayId
          ? _presenceAgents[member.owner.profile]
          : null,
      addressedMessage: message,
    ),
  );

  Widget _buildRecipients() {
    final members = resolveRoomRecipients(_composer.text, _room.members);
    final strings = Strings.of(context);
    final all = members.length == _room.members.length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 340;
        final label = compact
            ? all
                  ? strings.roomEveryone
                  : strings.roomRecipientsShort(
                      members.length,
                      _room.members.length,
                    )
            : all
            ? strings.roomRecipientsAll(members.length)
            : strings.roomRecipientsSome(members.length, _room.members.length);
        return ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              height: 36,
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              color: Theme.of(
                context,
              ).hermes.surfaceVariant.withValues(alpha: .65),
              key: const ValueKey('room-recipients-preview'),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).hermes.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final member in members)
                          Padding(
                            padding: const EdgeInsets.all(4),
                            child: RoomStatusAvatar(
                              showDetailsOnTap: true,
                              member: member,
                              status: _status(member),
                              profile: _hostedRoomMemberProfile(
                                member,
                                _room,
                                widget.localProfiles,
                              ),
                              avatarCache: widget.avatarCache,
                            ),
                          ),
                      ],
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

  /// Pending recipients live where their replies will arrive. Real replies
  /// replace their placeholder; terminal silence leaves only a muted line.
  Widget _buildPendingTurns(HostedGroupEvent? message) {
    if (message == null) return const SizedBox.shrink();
    final strings = Strings.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final member in resolveRoomRecipients(
          message.publicText ?? '',
          _room.members,
        ))
          Builder(
            builder: (context) {
              final status = _status(member, message: message);
              final response = status.response!;
              if (response == RoomResponse.responded) {
                return const SizedBox.shrink();
              }
              final pending = response == RoomResponse.pending;
              return Padding(
                key: ValueKey(
                  'room-turn-${message.eventId}-${member.memberId}',
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 5,
                ),
                child: AnimatedSwitcher(
                  duration: Duration(
                    milliseconds: MediaQuery.disableAnimationsOf(context)
                        ? 0
                        : 200,
                  ),
                  child: pending
                      ? Row(
                          key: ValueKey(
                            'room-response-${message.eventId}-${member.memberId}-${response.name}',
                          ),
                          children: [
                            RoomStatusAvatar(
                              member: member,
                              status: status,
                              profile: _hostedRoomMemberProfile(
                                member,
                                _room,
                                widget.localProfiles,
                              ),
                              avatarCache: widget.avatarCache,
                              size: 28,
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '@${member.handle}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  BotStatusLine(
                                    status: status,
                                    text:
                                        status.presence ==
                                                RoomPresence.working ||
                                            status.presence ==
                                                RoomPresence.needsYou
                                        ? null
                                        : strings.roomResponsePending,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        )
                      : Align(
                          key: ValueKey(
                            'room-response-${message.eventId}-${member.memberId}-${response.name}',
                          ),
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            response == RoomResponse.passed
                                ? strings.roomMemberPassed(member.handle)
                                : strings.roomMemberNoResponse(member.handle),
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).hermes.textDisabled,
                            ),
                          ),
                        ),
                ),
              );
            },
          ),
      ],
    );
  }

  /// Sugerencias de `@mención` flotando sobre el composer, con el mismo
  /// lenguaje que la paleta de comandos del chat (`_SlashPalette`): tarjeta
  /// redondeada sobre `surfaceVariant`, borde de divisor y sombra. Antes eran
  /// `ActionChip`s de Material a pelo con un icono `@` genérico — no se
  /// parecían a nada más de la app y no decían a quién estabas mencionando.
  /// Ahora cada sugerencia lleva la misma cara que ese miembro tiene en el
  /// transcript y en la tira de equipo.
  Widget _buildMentionPalette(HermesThemeColors colors) {
    final matches = _mentionMatches();
    final broadcasts = _mentionQuery == null
        ? const <String>[]
        : ['everyone', 'all']
              .where(
                (handle) => handle.startsWith(_mentionQuery!.toLowerCase()),
              )
              .toList();
    if (matches.isEmpty && broadcasts.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('mission-hosted-mention-suggestions'),
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(18),

        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 22,
            offset: const Offset(0, 9),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(17),
        child: Material(
          color: Colors.transparent,
          child: SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              children: [
                for (final handle in broadcasts)
                  TextButton.icon(
                    key: ValueKey('mission-hosted-mention-$handle'),
                    onPressed: () => _applyMention(handle),
                    icon: const Icon(Icons.groups_outlined, size: 16),
                    label: Text('@$handle'),
                  ),
                for (final member in matches)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 6,
                    ),
                    child: InkWell(
                      key: ValueKey('mission-hosted-mention-${member.handle}'),
                      borderRadius: BorderRadius.circular(20),
                      onTap: () => _applyMention(member.handle),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(6, 4, 12, 4),
                        child: Row(
                          children: [
                            RoomStatusAvatar(
                              member: member,
                              status: _status(member),
                              profile: _hostedRoomMemberProfile(
                                member,
                                _room,
                                widget.localProfiles,
                              ),
                              avatarCache: widget.avatarCache,
                              size: 24,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '@${member.handle}',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: colors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Aviso de que el próximo envío va a un hilo concreto. Antes, tras tocar
  /// "Responder en hilo", el único indicio era que cambiaba el texto de
  /// sugerencia del campo, y no había ninguna forma de salir del hilo salvo
  /// enviar el mensaje. Esto lo hace visible y reversible.
  Widget _buildThreadBanner(HermesThemeColors colors) {
    if (_threadId == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Container(
          key: const ValueKey('mission-hosted-thread-banner'),
          padding: const EdgeInsetsDirectional.fromSTEB(10, 4, 4, 4),
          decoration: BoxDecoration(
            color: colors.accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: colors.accent.withValues(alpha: 0.28)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.reply_rounded, size: 14, color: colors.accentText),
              const SizedBox(width: 6),
              Text(
                widget.copy.replyingInThread,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: colors.accentText,
                ),
              ),
              const SizedBox(width: 2),
              Semantics(
                button: true,
                label: widget.copy.stopReplyingInThread,
                excludeSemantics: true,
                child: Tooltip(
                  message: widget.copy.stopReplyingInThread,
                  child: InkWell(
                    key: const ValueKey('mission-hosted-thread-cancel'),
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() {
                      _threadId = null;
                      _pendingAttempt = null;
                      _pendingText = null;
                      _pendingThreadId = null;
                    }),
                    child: Padding(
                      padding: const EdgeInsets.all(5),
                      child: Icon(
                        Icons.close_rounded,
                        size: 14,
                        color: colors.accentText,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Composer de la sala, con la misma huella que el de `ChatScreen`: la misma
  /// cápsula flotante (`HermesComposerSurface`), el mismo relleno del host
  /// (`14/4/14/10` sobre el fondo de la pantalla), el mismo inset horizontal
  /// que se cierra al enfocar, el mismo `contentPadding` del campo y el mismo
  /// botón primario (flecha arriba de 42 dp en una caja táctil de 48).
  ///
  /// Sin botón de adjuntos a propósito: el evento de una sala compartida solo
  /// admite `text` y `thread_id` (validación del gateway, replicada en
  /// `HostedGroupEvent.fromJson`), así que un "+" ahí sería un botón muerto.
  /// La sala vacía lo dice una vez en voz baja en vez de fingirlo.
  Widget _buildComposerHost(HermesThemeColors colors) {
    // En horizontal el IME ocupa más de media pantalla, y un composer de
    // varias líneas más su safe area puede no caber en lo que queda. Mismo
    // tratamiento compacto que `ChatScreen`.
    return Builder(
      builder: (imeContext) {
        final compactIme =
            MediaQuery.viewInsetsOf(imeContext).bottom > 0 &&
            MediaQuery.orientationOf(imeContext) == Orientation.landscape;
        final hasText = _composer.text.trim().isNotEmpty;
        return Container(
          padding: compactIme
              ? const EdgeInsets.fromLTRB(12, 2, 12, 3)
              : const EdgeInsets.fromLTRB(14, 4, 14, 10),
          color: colors.background,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasText) _buildRecipients(),
              _buildMentionPalette(colors),
              _buildThreadBanner(colors),
              HermesComposerSurface(
                focused: _composerFocus.hasFocus,
                unfocusedHorizontalInset: 12,
                // Sin botón de adjuntos a la izquierda, el campo necesita su
                // propio margen dentro de la cápsula: 12 aquí + 4 del
                // `contentPadding` dejan el texto a 16 dp del borde.
                padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 0, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('mission-hosted-composer'),
                        controller: _composer,
                        focusNode: _composerFocus,
                        minLines: 1,
                        maxLines: compactIme ? 2 : 4,
                        textCapitalization: TextCapitalization.sentences,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        decoration: InputDecoration(
                          // El estado de hilo ya lo dice la tira de arriba, y
                          // además se puede deshacer desde ahí. Antes el
                          // único indicio era que este texto de sugerencia se
                          // reescribía a "Responder en hilo", que como
                          // marcador de posición leía raro y era además la
                          // única señal. Decirlo en los dos sitios sería
                          // ruido: el campo mantiene su etiqueta.
                          hintText: widget.copy.sendSharedMessage,
                          hintStyle: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 14,
                          ),
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          contentPadding: EdgeInsets.fromLTRB(
                            4,
                            compactIme ? 10 : 12,
                            4,
                            compactIme ? 10 : 12,
                          ),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    SizedBox.square(
                      dimension: 48,
                      child: Center(
                        child: _sending
                            ? SizedBox.square(
                                key: const ValueKey(
                                  'mission-hosted-composer-sending',
                                ),
                                dimension: 42,
                                child: Padding(
                                  padding: const EdgeInsets.all(11),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: colors.textSecondary,
                                  ),
                                ),
                              )
                            : HermesTactileAction(
                                key: const ValueKey(
                                  'mission-hosted-composer-send',
                                ),
                                // Misma flecha que el chat real, no el avión
                                // de papel genérico de Material.
                                icon: Icons.arrow_upward,
                                semanticLabel: widget.copy.sendSharedMessage,
                                // Con el campo vacío la flecha se pinta
                                // atenuada y no responde, en vez de lucir
                                // activa sobre un tap que no hacía nada
                                // (mismo criterio que `_SendButton`).
                                onPressed: hasText ? _send : null,
                                enabled: hasText,
                                size: 42,
                                iconSize: 19,
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

  @override
  Widget build(BuildContext context) {
    _presenceNow = DateTime.now();
    _presenceAgents = {
      for (final agent in widget.agents()) agent.profile.name: agent,
    };
    _statusCache.clear();
    final events =
        _log?.events
            .where((event) => event.publicText != null)
            .toList(growable: false) ??
        const <HostedGroupEvent>[];

    final latestSend = events.where((e) => e.kind == 'message.user').lastOrNull;
    final management = <String>[
      if (widget.canRename) 'rename',
      if (widget.canStop) 'stop',
      if (widget.canDisband) 'disband',
    ];
    final colors = Theme.of(context).hermes;
    final identity = widget.identityFor(_room);
    return Scaffold(
      key: const ValueKey('mission-hosted-room-workspace'),
      appBar: HermesAppBar(
        title: identity?.image == null
            ? Text(identity?.name ?? _room.name)
            : Row(
                children: [
                  RoomMirrorAvatar(
                    image: identity!.image!,
                    size: 32,
                    fallback: const Icon(Icons.groups_outlined, size: 32),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      identity.name ?? _room.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
        // Misma cabecera plana que `ChatScreen`: sin línea ni sombra de
        // elevación cuando el transcript pasa por debajo, para que la sala se
        // funda con la conversación en vez de cortarla con un borde.
        scrolledUnderElevation: 0,
        actions: [
          if (widget.onRead != null)
            IconButton(
              key: const ValueKey('mission-hosted-room-refresh'),
              tooltip: widget.copy.refresh,
              onPressed: _refreshRoom,
              icon: const Icon(Icons.refresh_rounded),
            ),
          if (management.isNotEmpty)
            PopupMenuButton<String>(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onSelected: (value) {
                if (value == 'rename') unawaited(_rename());
                if (value == 'stop') unawaited(_stop());
                if (value == 'disband') unawaited(_disband());
              },
              itemBuilder: (_) => [
                if (widget.canRename)
                  PopupMenuItem(
                    value: 'rename',
                    child: Text(widget.copy.renameSharedRoom),
                  ),
                if (widget.canStop)
                  PopupMenuItem(
                    value: 'stop',
                    child: Text(widget.copy.stopSharedRoomAction),
                  ),
                if (widget.canDisband)
                  PopupMenuItem(
                    value: 'disband',
                    child: Text(widget.copy.disbandSharedRoomAction),
                  ),
              ],
            ),
        ],
      ),
      body: SafeArea(
        // El alto disponible de verdad (ya descontados AppBar, safe area y el
        // IME) es lo que decide cuánto puede ocupar el equipo desplegado.
        // Leerlo aquí, en vez de estimarlo con `MediaQuery`, es lo que permite
        // que la tira de equipo NO sea un hijo flexible de esta columna.
        //
        // Por qué importa: un `Flexible(flex: 1)` junto al `Expanded(flex: 1)`
        // del transcript se reparte el hueco libre al 50 %, y el `Flexible`
        // solo usa lo que necesita. Con el equipo plegado (una cabecera de
        // ~68 dp) los ~250 dp de su mitad que no usaba no volvían al
        // transcript: `RenderFlex` los deja como espacio sobrante *al final*
        // de la columna, es decir, un vacío negro DEBAJO del composer. Medido
        // en un viewport de 360×800: 258 dp. Era el "no se puede ver así"
        // reportado en dispositivo real (el `MainAxisSize.min` anterior no lo
        // arregló: movió el vacío de dentro de la sección a debajo del
        // composer). Con la tira fuera del reparto flexible, el `Expanded` del
        // transcript absorbe todo el hueco y el composer queda pegado abajo,
        // como en `ChatScreen`.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final available = constraints.hasBoundedHeight
                ? constraints.maxHeight
                : double.infinity;
            // Techo de la tira de equipo: ni más del 45 % del alto
            // disponible, ni tanto que el composer no quepa debajo. Por debajo
            // de lo que mide su propia cabecera no se pinta media cabecera
            // recortada: se retira entera (solo pasa en horizontal con el
            // teclado abierto, donde el cuerpo se queda en <130 dp).
            final summaryVisible = available > 360;
            final summaryCompact =
                MediaQuery.viewInsetsOf(context).bottom > 0 ||
                _composer.text.trim().isNotEmpty;
            final summaryHeight = summaryCompact
                ? math.max(
                    44.0,
                    MediaQuery.textScalerOf(context).scale(12) * 1.5 + 20,
                  )
                : math.min(300.0, available * .38);
            final activityReserve = summaryVisible ? summaryHeight + 8 : 0.0;
            final composerReserve = _composer.text.trim().isNotEmpty
                ? 200.0
                : 96.0;
            final rawCeiling = available.isFinite
                ? math.min(
                    available * 0.45,
                    math.max(
                      0.0,
                      available - composerReserve - activityReserve,
                    ),
                  )
                : double.infinity;
            final teamCeiling = rawCeiling < 56 ? 0.0 : rawCeiling;
            return Column(
              children: [
                // Antes esto era un `ExpansionTile` "Ver miembros" con un
                // `ListTile` por miembro: icono genérico de persona y
                // `@handle`, sin avatar, sin nombre, sin estado y sin nada que
                // tocar. Es literalmente el "entro en la sala, voy al equipo y
                // no sale nada" reportado en dispositivo real.
                //
                // El scroll no es decorativo: es lo que hace que esta tira no
                // pueda desbordar NUNCA, con cualquier viewport y cualquier
                // escala de texto. La sección es una `Column` de alto natural;
                // acotarla con `maxHeight` a secas la haría desbordar en
                // cuanto el techo bajara de su contenido (una `Column` no se
                // recorta sola), y era justo lo que pasaba en horizontal con
                // el teclado abierto. Plegada (el caso normal) el contenido
                // cabe de sobra y no hay desplazamiento ninguno.
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: teamCeiling),
                  child: SingleChildScrollView(
                    child: _HostedRoomTeamSection(
                      key: const ValueKey('mission-hosted-members'),
                      room: _room,
                      copy: widget.copy,
                      avatarCache: widget.avatarCache,
                      localProfiles: widget.localProfiles,
                      onOpenMember: widget.onOpenMember,
                      statuses: {
                        for (final m in _room.members) m.memberId: _status(m),
                      },
                    ),
                  ),
                ),
                if (summaryVisible)
                  RoomSummaryPill(
                    summary: deriveRoomSummary(
                      events: _log?.events ?? const [],
                      members: _room.members,
                      statuses: {
                        for (final m in _room.members) m.memberId: _status(m),
                      },
                      board: widget.board(),
                      localGatewayId: _room.authorityGatewayId,
                      now: _presenceNow,
                    ),
                    localGatewayId: _room.authorityGatewayId,
                    profiles: widget.localProfiles,
                    avatarCache: widget.avatarCache,
                    maxHeight: summaryHeight,
                    compact: summaryCompact,
                  ),
                if (widget.canSend) ...[
                  // Antes aquí había un título de sección "Conversación" en
                  // `titleMedium` negrita. Ningún chat real rotula su propio
                  // transcript: leía como una pantalla de ajustes y además
                  // robaba ~44 dp al hilo. La frontera entre la identidad de
                  // la sala y la conversación la marca la línea de la tira de
                  // equipo, igual que la cabecera de `ChatScreen`.
                  Expanded(
                    child: events.isEmpty
                        ? _HostedRoomEmptyTranscript(
                            roomName: _room.name,
                            copy: widget.copy,
                          )
                        : ListView.builder(
                            // Reversed: a short conversation hugs the composer
                            // like every real chat, instead of leaving the
                            // empty remainder dangling below the last message.
                            // `index` stays the original chronological
                            // position (what keys and tests already address) —
                            // only the visual order flips.
                            reverse: true,
                            // Mismo aire que `ChatScreen` deja bajo la última
                            // respuesta: con 4 dp el cierre del texto quedaba
                            // pegado al composer.
                            padding: const EdgeInsets.only(bottom: 12),
                            itemCount: events.length + 1,
                            itemBuilder: (context, reversedPosition) {
                              if (reversedPosition == 0) {
                                return _buildPendingTurns(latestSend);
                              }
                              final index = events.length - reversedPosition;
                              final event = events[index];
                              final bubble = _HostedRoomMessage(
                                key: ValueKey('mission-hosted-message-$index'),
                                event: event,
                                room: _room,
                                localProfiles: widget.localProfiles,
                                avatarCache: widget.avatarCache,

                                reply: event.threadId == null
                                    ? null
                                    : _HostedRoomThreadAction(
                                        key: ValueKey(
                                          'mission-hosted-reply-$index',
                                        ),
                                        label: widget.copy.replyInThread,
                                        active:
                                            _threadId != null &&
                                            _threadId == event.threadId,
                                        onPressed: () => setState(() {
                                          _threadId = event.threadId;
                                          _pendingAttempt = null;
                                          _pendingText = null;
                                          _pendingThreadId = null;
                                        }),
                                      ),
                              );
                              return event.kind == 'message.user' &&
                                      event != latestSend
                                  ? Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        bubble,
                                        _buildPendingTurns(event),
                                      ],
                                    )
                                  : bubble;
                            },
                          ),
                  ),
                  if (_roomError != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text(
                        _roomError!,
                        key: const ValueKey('mission-hosted-room-error'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: math.max(
                        0,
                        available - teamCeiling - activityReserve,
                      ),
                    ),
                    child: SingleChildScrollView(
                      reverse: true,
                      child: _buildComposerHost(colors),
                    ),
                  ),
                ] else
                  // Antes esta rama no existía: la sala se quedaba en blanco
                  // bajo el desplegable de miembros, sin conversación ni
                  // composer y sin decir por qué — "si entro en una sala no
                  // hace nada", confirmado en dispositivo real.
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          _RoomsAreaCopy.of(context).cannotSendInRoom,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colors.textSecondary),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Sala sin mensajes todavía. Antes era un `Text` centrado a pelo con el
/// estilo por defecto, que en una pantalla por lo demás vacía leía como un
/// error de carga. Mismo esqueleto que `_EmptyChatState` del chat real:
/// identidad en acento, línea de invitación en secundario.
///
/// Es también el único sitio donde se dice que la sala es solo de texto: el
/// protocolo no tiene campo de adjunto, y decirlo una vez aquí es más honesto
/// que un botón "+" que no puede funcionar o un aviso permanente sobre el
/// composer.
class _HostedRoomEmptyTranscript extends StatelessWidget {
  final String roomName;
  final MissionControlCopy copy;

  const _HostedRoomEmptyTranscript({
    required this.roomName,
    required this.copy,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    // Con el equipo desplegado y el teclado abierto al transcript le pueden
    // quedar <100 dp (medido: 92 en 360×640 con 300 px de IME y 14 miembros
    // abiertos). Un `Column` suelto ahí desbordaba; el scroll se lo come sin
    // recortar texto y, cuando sobra alto, sigue centrado igual.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              roomName,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w500,
                color: colors.accent,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              copy.noRoomMessages,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: colors.textSecondary,
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              copy.roomTextOnly,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: colors.textDisabled,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Responder en hilo" bajo un mensaje. Antes era un `TextButton.icon` con los
/// valores por defecto de Material: ~48 dp de alto y 64 dp de ancho mínimo
/// debajo de CADA mensaje con hilo, lo que convertía el transcript en una
/// lista de botones. Ahora es una acción discreta de 34 dp que además marca
/// cuál es el hilo activo, para que la tira de "Respondiendo en el hilo" del
/// composer tenga a qué mensaje referirse.
class _HostedRoomThreadAction extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onPressed;

  const _HostedRoomThreadAction({
    required this.label,
    required this.active,
    required this.onPressed,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final foreground = active ? colors.accentText : colors.textSecondary;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Semantics(
        button: true,
        selected: active,
        label: label,
        excludeSemantics: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(17),
            onTap: onPressed,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 34),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.reply_rounded, size: 14, color: foreground),
                    const SizedBox(width: 5),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: foreground,
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

// Only members owned by this room's authority can resolve to local profiles.
AgentProfile? _hostedRoomMemberProfile(
  HostedGroupMember member,
  HostedGroupRoom room,
  Map<String, AgentProfile> localProfiles,
) => member.owner.connectionId == room.authorityGatewayId
    ? localProfiles[member.owner.profile]
    : null;

/// Room-scoped presentation using the same spacing and colors as ChatScreen.
class _HostedRoomMessage extends StatelessWidget {
  final HostedGroupEvent event;
  final HostedGroupRoom room;
  final Map<String, AgentProfile> localProfiles;
  final MissionProfileAvatarCache? avatarCache;
  final Widget? reply;

  const _HostedRoomMessage({
    super.key,
    required this.event,
    required this.room,
    required this.localProfiles,
    required this.avatarCache,
    required this.reply,
  });

  HostedGroupMember? get _member {
    final actor = event.actor;
    for (final member in room.members) {
      if (member.memberId == actor.id) return member;
    }
    // Profile names alone are not identities in federated rooms.
    for (final member in room.members) {
      if (member.owner.connectionId == actor.connectionId &&
          member.owner.profile == actor.profile) {
        return member;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final isUser = event.actor.kind == 'user';
    final member = isUser ? null : _member;
    final name =
        member?.displayName ?? member?.handle ?? event.actor.publicLabel;
    final body = SelectableText(
      event.publicText!,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: colors.textPrimary,
        fontSize: isUser ? null : 15,
        height: isUser ? 1.4 : 1.5,
      ),
    );
    return Padding(
      padding: isUser
          ? const EdgeInsets.only(left: 56, right: 12, top: 11, bottom: 3)
          : const EdgeInsets.only(left: 12, right: 16, top: 11, bottom: 3),
      child: Column(
        crossAxisAlignment: isUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (isUser)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              decoration: BoxDecoration(
                color: colors.surfaceVariant.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(20),
              ),
              child: body,
            )
          else ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  RoomMemberAvatar(
                    profileName: member?.handle ?? name,
                    profile: member == null
                        ? null
                        : _hostedRoomMemberProfile(member, room, localProfiles),
                    avatarCache: avatarCache,
                    size: 32,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '>_ ${name.toUpperCase()}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: colors.accent,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            body,
          ],
          ?reply,
        ],
      ),
    );
  }
}

/// Sección "Equipo" de una sala compartida: cabecera plegada con la pila de
/// avatares de la sala y, al desplegarla, una fila real por miembro.
///
/// Las salas compartidas no tienen coordinador (eso es cosa de las salas
/// locales), así que aquí no hay rol ni anillo de manager: inventarse uno por
/// el orden de la lista sería mentir. Un miembro que resuelve a un perfil
/// local de esta conexión abre su ficha; uno federado (sin perfil local) no
/// lleva a ningún sitio y lo dice en su subtítulo en vez de fingir destino.
class _HostedRoomTeamSection extends StatefulWidget {
  final Map<String, RoomMemberStatus> statuses;
  final HostedGroupRoom room;
  final MissionControlCopy copy;
  final MissionProfileAvatarCache? avatarCache;
  final Map<String, AgentProfile> localProfiles;
  final ValueChanged<String> onOpenMember;

  const _HostedRoomTeamSection({
    required this.room,
    required this.statuses,
    required this.copy,
    required this.avatarCache,
    required this.localProfiles,
    required this.onOpenMember,
    super.key,
  });

  @override
  State<_HostedRoomTeamSection> createState() => _HostedRoomTeamSectionState();
}

class _HostedRoomTeamSectionState extends State<_HostedRoomTeamSection> {
  /// El modelo admite hasta 128 miembros por sala. La caché de avatares
  /// guarda 64 entradas y resuelve 4 a la vez
  /// (`MissionProfileAvatarCache.maxEntries`/`maxConcurrent`), así que pintar
  /// las 128 filas de golpe dentro de esta columna no cabría en pantalla y
  /// además pediría más avatares de los que la caché retiene. Una docena es
  /// lo que entra de verdad en el desplegable; el resto se ve en su propia
  /// pantalla, con lista perezosa.
  static const int _inlineLimit = 12;

  bool _expanded = false;

  List<RoomAvatarOfficialMember> get _members =>
      sortedOfficialRoomAvatarMembers([
        for (final member in widget.room.members)
          RoomAvatarOfficialMember(
            owner: member.owner,
            // Cadena de respaldo exacta para la que se añadió `display_name`
            // al modelo: el nombre publicado por el servidor si lo hay, y si
            // no el handle, que siempre existe.
            displayName: member.displayName ?? member.handle,
            handle: member.handle,
            profile: _hostedRoomMemberProfile(
              member,
              widget.room,
              widget.localProfiles,
            ),
          ),
      ]);

  /// Miembros de los que el servidor sí publica `display_name`.
  Set<AvatarOwner> get _namedOwners => {
    for (final member in widget.room.members)
      if (member.displayName != null) member.owner,
  };

  Widget _row(RoomAvatarOfficialMember member, Set<AvatarOwner> named) {
    final profile = member.profile;
    final extra = _RoomsAreaCopy.of(context);
    final original = widget.room.members.firstWhere(
      (m) => m.owner == member.owner,
    );
    final status = widget.statuses[original.memberId]!;
    return RoomTeamRow(
      key: ValueKey(
        'mission-hosted-member-'
        '${member.owner.connectionId}-${member.owner.profile}',
      ),
      profileName: member.handle,
      handle: member.handle,
      displayName: member.displayName,
      profile: profile,
      avatarCache: widget.avatarCache,
      roleLabel: null,
      avatar: RoomStatusAvatar(
        member: original,
        profile: profile,
        avatarCache: widget.avatarCache,
        status: status,
        size: 38,
      ),
      activityLine: BotStatusLine(status: status),
      activityLabel: botStatusText(Strings.of(context), status),
      subtitle: profile == null ? extra.federatedMember : null,
      // Un miembro federado del que el servidor sí publica nombre no está
      // "no disponible", solo es de otra conexión. El tratamiento apagado se
      // reserva a quien no tiene ni perfil local ni nombre publicado: de ese
      // no hay literalmente nada que mostrar más allá de su handle.
      unavailable: profile == null && !named.contains(member.owner),
      onTap: profile == null
          ? null
          : () => widget.onOpenMember(member.owner.profile),
    );
  }

  void _openAllMembers(
    List<RoomAvatarOfficialMember> members,
    Set<AvatarOwner> named,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          key: const ValueKey('mission-hosted-members-screen'),
          appBar: HermesAppBar(title: Text(widget.copy.roomTeam)),
          body: SafeArea(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: members.length,
              itemBuilder: (_, index) => _row(members[index], named),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final members = _members;
    final named = _namedOwners;
    final inline = members.take(_inlineLimit).toList(growable: false);
    final extra = _RoomsAreaCopy.of(context);
    return Column(
      // `Column`'s default `mainAxisSize` is `max`: wrapped in the outer
      // `Flexible`, it was claiming its whole loose allocation (roughly half
      // the screen) even collapsed, when its only child is a ~68dp header —
      // the empty void reported live on device between the team header and
      // "Conversación". `min` sizes it to its actual children instead.
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.statuses.values.any(
          (s) => s.presence == RoomPresence.working,
        ))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: InkWell(
              onTap: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  content: SizedBox(
                    width: 360,
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: widget.room.members.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 12, thickness: .5),
                      itemBuilder: (context, i) {
                        final m = widget.room.members[i];
                        return Text(
                          '@${m.handle} · ${botStatusText(Strings.of(context), widget.statuses[m.memberId]!)}',
                        );
                      },
                    ),
                  ),
                ),
              ),
              child: HermesShimmerText(
                widget.room.members
                            .where(
                              (m) =>
                                  widget.statuses[m.memberId]!.presence ==
                                  RoomPresence.working,
                            )
                            .length ==
                        1
                    ? botStatusText(
                        Strings.of(context),
                        widget.statuses.values.firstWhere(
                          (s) => s.presence == RoomPresence.working,
                        ),
                      )
                    : Strings.of(context).roomMembersWorking(
                        widget.room.members
                            .where(
                              (m) =>
                                  widget.statuses[m.memberId]!.presence ==
                                  RoomPresence.working,
                            )
                            .map((m) => m.handle)
                            .join(', '),
                      ),
                style: TextStyle(fontSize: 11, color: colors.textSecondary),
              ),
            ),
          ),
        Semantics(
          container: true,
          button: true,
          label: [
            widget.copy.roomTeam,
            widget.copy.roomMemberCount(widget.room.members.length),
          ].join(', '),
          excludeSemantics: true,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: const ValueKey('mission-hosted-members-header'),
              onTap: () => setState(() => _expanded = !_expanded),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height:
                              40 +
                              MediaQuery.textScalerOf(context).scale(10) * 1.4,
                          child: ListView(
                            key: const ValueKey('room-live-members'),
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            children: [
                              for (final m in widget.room.members)
                                RoomStatusMember(
                                  member: m,
                                  status: widget.statuses[m.memberId]!,
                                  profile: _hostedRoomMemberProfile(
                                    m,
                                    widget.room,
                                    widget.localProfiles,
                                  ),
                                  avatarCache: widget.avatarCache,
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 95,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.copy.roomTeam,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15.5,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.copy.roomMemberCount(
                                widget.room.members.length,
                              ),
                              style: TextStyle(
                                color: colors.textSecondary,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        _expanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        color: colors.textSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_expanded)
          // Sin techo propio: el cuerpo de la sala ya acota esta sección y la
          // hace desplazable (ver el `ConstrainedBox` + `SingleChildScrollView`
          // de `_HostedRoomWorkspaceState.build`). Antes el techo se estimaba
          // con `MediaQuery` al 38 % de la pantalla, que no es lo mismo que el
          // alto que de verdad le queda a esta columna.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(
              children: [
                for (final member in inline) _row(member, named),
                if (members.length > inline.length)
                  _RoomsCardAction(
                    key: const ValueKey('mission-hosted-members-all'),
                    label: extra.allMembers(members.length),
                    onTap: () => _openAllMembers(members, named),
                  ),
              ],
            ),
          ),
        // Frontera entre la identidad de la sala y la conversación: la misma
        // línea de pelo que separa la cabecera del transcript en el chat real,
        // en lugar del título de sección "Conversación" que había antes. Hace
        // que esta tira lea como cromo de la pantalla y no como la primera
        // fila de la lista de mensajes.
        Divider(
          height: 1,
          thickness: 1,
          color: colors.divider.withValues(alpha: 0.55),
        ),
      ],
    );
  }
}

/// Fila de acción dentro de una tarjeta de sección (salto a una lista
/// completa). Misma altura mínima y mismo relleno que las filas de contenido.
class _RoomsCardAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _RoomsCardAction({required this.label, required this.onTap, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: colors.accentText,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: colors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HostedRoomCard extends StatelessWidget {
  final RoomMirrorIdentity? identity;
  final HostedGroupRoom room;
  final HostedGroupLogPage? log;
  final MissionControlCopy copy;
  final MissionProfileAvatarCache? avatarCache;
  // Perfiles LOCALES a esta conexión, por nombre. Un miembro cuyo nombre
  // coincida aquí es (con certeza suficiente para una miniatura, no para
  // autorización) uno de tus propios bots, así que puede pintar su avatar
  // real en vez del círculo de color neutro reservado a miembros de otra
  // conexión (salas federadas) de los que no hay avatar en caché.
  final Map<String, AgentProfile> localProfiles;
  final bool canSend;
  final bool canRename;
  final bool canStop;
  final bool canDisband;
  final VoidCallback onOpen;
  final VoidCallback onSend;
  final VoidCallback onRename;
  final VoidCallback onStop;
  final VoidCallback onDisband;

  const _HostedRoomCard({
    this.identity,
    required this.room,
    required this.log,
    required this.copy,
    required this.avatarCache,
    required this.localProfiles,
    required this.canSend,
    required this.canRename,
    required this.canStop,
    required this.canDisband,
    required this.onOpen,
    required this.onSend,
    required this.onRename,
    required this.onStop,
    required this.onDisband,
    super.key,
  });

  Widget _avatarStack() => RoomAvatarStack.official(
    avatarCache: avatarCache,
    members: room.members.map(
      (member) => RoomAvatarOfficialMember(
        owner: member.owner,
        displayName: member.handle,
        handle: member.handle,
        profile: member.owner.connectionId == room.authorityGatewayId
            ? localProfiles[member.owner.profile]
            : null,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final management = <String>[
      if (canRename) 'rename',
      if (canStop) 'stop',
      if (canDisband) 'disband',
    ];
    return Semantics(
      container: true,
      label: copy.sharedRoomSemantics(
        identity?.name ?? room.name,
        room.members.length,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 6, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (identity?.image case final image?)
                  RoomMirrorAvatar(image: image, fallback: _avatarStack())
                else
                  _avatarStack(),
                const SizedBox(width: 12),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              identity?.name ?? room.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              copy.roomMemberCount(room.members.length),
                              style: TextStyle(
                                color: Theme.of(context).hermes.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (canSend)
                        IconButton(
                          key: ValueKey(
                            'mission-hosted-send-${_indexFromKey()}',
                          ),
                          tooltip: copy.sendSharedMessage,
                          constraints: const BoxConstraints.tightFor(
                            width: 48,
                            height: 48,
                          ),
                          onPressed: onSend,
                          icon: const Icon(Icons.send_outlined),
                        ),
                      if (management.isNotEmpty)
                        PopupMenuButton<String>(
                          key: ValueKey(
                            'mission-hosted-more-${_indexFromKey()}',
                          ),
                          tooltip: MaterialLocalizations.of(
                            context,
                          ).moreButtonTooltip,
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                          onSelected: (value) {
                            if (value == 'rename') onRename();
                            if (value == 'stop') onStop();
                            if (value == 'disband') onDisband();
                          },
                          itemBuilder: (_) => [
                            if (canRename)
                              PopupMenuItem(
                                key: ValueKey(
                                  'mission-hosted-rename-${_indexFromKey()}',
                                ),
                                value: 'rename',
                                child: Text(copy.renameSharedRoom),
                              ),
                            if (canStop)
                              PopupMenuItem(
                                key: ValueKey(
                                  'mission-hosted-stop-${_indexFromKey()}',
                                ),
                                value: 'stop',
                                child: Text(copy.stopSharedRoomAction),
                              ),
                            if (canDisband)
                              PopupMenuItem(
                                key: ValueKey(
                                  'mission-hosted-disband-${_indexFromKey()}',
                                ),
                                value: 'disband',
                                child: Text(copy.disbandSharedRoomAction),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _indexFromKey() {
    final value = key;
    if (value is ValueKey<String>) return value.value.split('-').last;
    return 'unknown';
  }
}

class _GlobalWorkTray extends StatelessWidget {
  final List<WorkItem> items;
  final MissionControlCopy copy;
  final void Function(WorkItem, WorkDestination) onDestination;

  const _GlobalWorkTray({
    required this.items,
    required this.copy,
    required this.onDestination,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final approvalItems = items
        .where((item) => item.destination is ApprovalDestination)
        .take(3)
        .toList(growable: false);
    final taskItems =
        items
            .where((item) => item.destination is TaskDestination)
            .toList(growable: false)
          ..sort(
            (left, right) => _globalTaskPriority(
              left.attention,
            ).compareTo(_globalTaskPriority(right.attention)),
          );
    // El tablero NO es un pendiente: vive en su propia sección explicada
    // (`_BoardSection`) y ya no cuelga de la cola de esta bandeja. Colgado
    // aquí era un enlace suelto llamado "Tablero completo" al final de una
    // lista de cosas que reclaman atención, que es justo lo que no se
    // entendía en dispositivo real.
    if (approvalItems.isEmpty && taskItems.isEmpty) {
      return const SizedBox.shrink();
    }
    final taskLimit = approvalItems.length >= 3 ? 0 : 3 - approvalItems.length;
    return Semantics(
      container: true,
      label: copy.globalWorkTray,
      child: Column(
        key: const ValueKey('mission-global-work-tray'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RoomsSectionLabel(
            icon: Icons.inbox_outlined,
            iconColor: approvalItems.isNotEmpty ? colors.warning : null,
            label: copy.globalWorkTray,
            count: approvalItems.length + taskItems.take(taskLimit).length,
            first: false,
          ),
          _RoomsCardGroup(
            rows: [
              for (var index = 0; index < approvalItems.length; index++)
                MissionWorkItemAction(
                  key: ValueKey('mission-global-approval-$index'),
                  item: approvalItems[index],
                  icon: Icons.approval_outlined,
                  color: colors.warning,
                  onDestination: (destination) =>
                      onDestination(approvalItems[index], destination),
                ),
              for (final item in taskItems.take(taskLimit))
                MissionWorkItemAction(
                  key: ValueKey(
                    'mission-global-task-${item.taskRef!.boardId}-${item.taskRef!.taskId}',
                  ),
                  item: item,
                  icon: switch (item.attention) {
                    WorkAttention.blocked => Icons.block_outlined,
                    WorkAttention.running => Icons.play_arrow_rounded,
                    WorkAttention.review => Icons.rate_review_outlined,
                    _ => Icons.schedule_outlined,
                  },
                  color: switch (item.attention) {
                    WorkAttention.blocked => colors.error,
                    WorkAttention.running => colors.success,
                    WorkAttention.review => colors.warning,
                    _ => colors.accentText,
                  },
                  onDestination: (destination) =>
                      onDestination(item, destination),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static int _globalTaskPriority(WorkAttention attention) =>
      switch (attention) {
        WorkAttention.blocked => 0,
        WorkAttention.running => 1,
        WorkAttention.review => 2,
        WorkAttention.ready => 3,
        _ => 4,
      };
}

class MissionWorkItemAction extends StatelessWidget {
  final WorkItem item;
  final IconData icon;
  final Color color;
  final ValueChanged<WorkDestination> onDestination;

  const MissionWorkItemAction({
    required this.item,
    required this.icon,
    required this.color,
    required this.onDestination,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final destination = item.destination;
    if (destination == null) return const SizedBox.shrink();
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      label: '${item.title}, ${item.decisionCopy}',
      excludeSemantics: true,
      child: InkWell(
        onTap: () => onDestination(destination),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            // Estas filas ahora viven dentro de una tarjeta redondeada
            // (`_RoomsCardGroup`), así que el texto necesita el mismo margen
            // interno que el resto de las filas de la tarjeta.
            padding: const EdgeInsets.fromLTRB(14, 9, 10, 9),
            child: Row(
              children: [
                Icon(icon, size: 17, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        item.decisionCopy,
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
      ),
    );
  }
}

final class _RoomsAreaCopy {
  final bool _english;

  const _RoomsAreaCopy._(this._english);

  factory _RoomsAreaCopy.of(BuildContext context) => _RoomsAreaCopy._(
    Localizations.localeOf(context).languageCode.toLowerCase() == 'en',
  );

  String get sharedRoomsExplanation => _english
      ? 'The whole team sees it, from any device — for working together '
            'in the open.'
      : 'La ve todo el equipo, desde cualquier dispositivo — para '
            'trabajar juntos a la vista de todos.';

  /// Antes, si `canSend` era falso (conexión de solo lectura, o el servidor
  /// aún no soporta el método `send` de salas compartidas), la sala entera
  /// se quedaba en blanco tras el desplegable de miembros — ni conversación,
  /// ni composer, ni ningún aviso. Eso es justo el "si entro en una sala no
  /// hace nada" reportado en dispositivo real. Ahora se explica por qué.
  String get cannotSendInRoom => _english
      ? "You can't send messages in this room right now — the connection "
            'is read-only or the server doesn\'t support it yet.'
      : 'No puedes enviar mensajes en esta sala ahora mismo — la conexión '
            'es de solo lectura o el servidor todavía no lo soporta.';

  /// El tablero se llamaba solo "Tablero completo" y aparecía como un enlace
  /// suelto al final de la lista de pendientes, sin decir qué abría.
  String get boardSection => _english ? 'Task board' : 'Tablero de tareas';
  String get boardTitle =>
      _english ? 'Open the shared board' : 'Abrir el tablero compartido';
  String get boardExplanation => _english
      ? 'All of the team\'s tasks in one board, by column.'
      : 'Todas las tareas del equipo en un tablero, por columnas.';

  /// Un miembro de una sala compartida que NO es un perfil local de esta
  /// conexión (sala federada): la app no tiene su ficha, así que su fila no
  /// lleva a ningún sitio. El subtítulo lo dice en vez de dejar una fila muda
  /// que parece tocable y no responde.
  String get federatedMember =>
      _english ? 'Another connection' : 'Otra conexión';

  /// Salto a la lista completa de miembros cuando la sala trae más de los que
  /// se pintan en línea (el modelo admite hasta 128).
  String allMembers(int count) =>
      _english ? 'See all $count members' : 'Ver los $count miembros';

  /// Cabecera de los bots ya elegidos en el diálogo de sala compartida.
  String get selectedMembers => _english ? 'Chosen' : 'Elegidos';
  String get removeMember => _english ? 'Remove' : 'Quitar';
  String get noMembersChosen => _english
      ? 'Tap a bot to add it to the room.'
      : 'Toca un bot para añadirlo a la sala.';
}

/// Cabecera de sección del área de salas, en el mismo lenguaje que el
/// rediseño de Conversaciones (`session_list_screen.dart`): etiqueta en
/// mayúsculas, recuento discreto a la derecha y la tarjeta redondeada de la
/// sección justo debajo.
///
/// Añade dos cosas que aquí hacían falta y `_LoungeSectionHeader` no daba:
/// un icono de ámbito (nube para las compartidas, dispositivo para las
/// locales) y una línea de explicación, para que se vea de un golpe qué
/// salas son de este móvil y cuáles viven en el servidor. Antes las dos
/// secciones eran títulos de 19 px idénticos y la única diferencia era el
/// texto.
class _RoomsSectionLabel extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String label;
  final int? count;
  final String? caption;
  final bool first;
  final Key? actionKey;
  final String? actionLabel;
  final IconData? actionIcon;
  final VoidCallback? onAction;

  const _RoomsSectionLabel({
    required this.icon,
    required this.label,
    required this.first,
    this.iconColor,
    this.count,
    this.caption,
    this.actionKey,
    this.actionLabel,
    this.actionIcon,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final accent = iconColor ?? colors.accentText;
    return Padding(
      padding: EdgeInsets.fromLTRB(4, first ? 8 : 26, 4, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 14, color: accent),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    label.toUpperCase(),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ),
              if (count != null)
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: colors.textDisabled,
                  ),
                ),
              if (onAction != null) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: actionLabel ?? '',
                  child: Semantics(
                    button: true,
                    label: actionLabel,
                    child: InkWell(
                      key: actionKey,
                      onTap: onAction,
                      borderRadius: BorderRadius.circular(22),
                      child: SizedBox(
                        width: 44,
                        height: 44,
                        child: Icon(
                          actionIcon ?? Icons.add_rounded,
                          size: 20,
                          color: colors.accentText,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (caption != null && caption!.isNotEmpty)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(33, 3, 0, 0),
              child: Text(
                caption!,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.3,
                  color: colors.textDisabled,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Tarjeta redondeada de una sección de salas: agrupa sus filas sobre una
/// superficie propia y dibuja separadores finos entre ellas, como las
/// secciones de Conversaciones. Es lo que hace que "local" y "compartida"
/// se lean como dos bloques distintos y no como una lista continua.
///
/// Deliberadamente NO usa `HermesCard`: las filas de salas compartidas se
/// verifican por contrato como no anidadas en una `HermesCard`.
class _RoomsCardGroup extends StatelessWidget {
  final List<Widget> rows;

  const _RoomsCardGroup({required this.rows});

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).hermes;
    final radius = BorderRadius.circular(
      Theme.of(context).hermesComponents.profile.shape.groupRadius,
    );
    return DecoratedBox(
      decoration: BoxDecoration(color: colors.surface, borderRadius: radius),
      child: ClipRRect(
        borderRadius: radius,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var index = 0; index < rows.length; index++) ...[
              if (index > 0)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 14),
                  child: Divider(
                    height: 1,
                    thickness: 1,
                    color: colors.divider.withValues(alpha: 0.55),
                  ),
                ),
              rows[index],
            ],
          ],
        ),
      ),
    );
  }
}

/// Fila de texto dentro de una tarjeta de sección (sección vacía o aviso).
class _RoomsCardNote extends StatelessWidget {
  final String text;

  const _RoomsCardNote({required this.text});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        height: 1.35,
        color: Theme.of(context).hermes.textSecondary,
      ),
    ),
  );
}

/// El tablero, con su propia sección explicada.
///
/// Antes era un `TextButton` alineado a la derecha llamado "Tablero completo"
/// colgado del final de "Otros pendientes". Dos problemas: no decía qué abría
/// y estaba dentro de una lista de cosas que reclaman atención, cuando el
/// tablero no es un pendiente sino un destino. Aquí es una sección propia con
/// nombre, explicación y una fila tocable con chevron, igual que el resto del
/// área. La capacidad no cambia: mismo `WorkItem.board`, mismo destino, misma
/// clave `mission-open-global-kanban`.
class _BoardSection extends StatelessWidget {
  final WorkItem item;
  final _RoomsAreaCopy extra;
  final ValueChanged<WorkDestination> onOpen;

  const _BoardSection({
    required this.item,
    required this.extra,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final destination = item.destination;
    if (destination == null) return const SizedBox.shrink();
    final colors = Theme.of(context).hermes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RoomsSectionLabel(
          icon: Icons.view_kanban_outlined,
          label: extra.boardSection,
          caption: extra.boardExplanation,
          first: false,
        ),
        _RoomsCardGroup(
          rows: [
            Semantics(
              button: true,
              label: '${extra.boardTitle}, ${extra.boardExplanation}',
              excludeSemantics: true,
              child: InkWell(
                key: const ValueKey('mission-open-global-kanban'),
                onTap: () => onOpen(destination),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 56),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.view_kanban_outlined,
                          size: 19,
                          color: colors.accentText,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            extra.boardTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 19,
                          color: colors.textDisabled,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
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
                minimumSize: const Size.square(48),
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
                      minimumSize: const Size(48, 48),
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

/// Fila única de bot para todo Mission Control: tap abre la ficha del bot
/// (`_AgentDetail`) y mantener pulsado/el overflow abre la hoja de acciones
/// rápidas (fijar, ocultar, abrir chat, ver detalles). Cuando el snapshot ya
/// contiene la sesión pineada oficialmente, la fila muestra su preview y hora
/// como en Bot Mode.
class _BotRow extends StatelessWidget {
  final MissionAgent agent;
  final BotLiveStatus live;
  final Session? pinnedChat;
  final bool needsYou;
  final bool unread;
  final MissionControlCopy copy;
  final MissionProfileAvatarCache? avatarCache;
  final VoidCallback onOpen;
  final VoidCallback onQuickActions;

  /// Color del indicador de fijado junto al nombre, o `null` para no
  /// mostrarlo. Se omite dentro de la sección "Fijados" (la propia sección
  /// ya lo dice) y cambia de gris apagado a acento cuando no hay secciones
  /// (resultados de búsqueda), para que se lea como estado sin depender del
  /// agrupado.
  final Color? pinBadgeColor;

  const _BotRow({
    required this.agent,
    required this.live,
    required this.copy,
    required this.avatarCache,
    required this.onOpen,
    required this.onQuickActions,
    this.pinnedChat,
    this.needsYou = false,
    this.unread = false,
    this.pinBadgeColor,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final profile = agent.profile;
    final displayName = profile.botTitle ?? profile.name;
    final preview = pinnedChat?.preview.trim() ?? '';
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('mission-bot-${profile.name}'),
          onTap: onOpen,
          onLongPress: onQuickActions,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(4, 10, 0, 10),
            child: Row(
              children: [
                BotStatusAvatar(
                  identity: profile.name,
                  label: displayName,
                  profile: profile,
                  status: live,
                  avatarCache: avatarCache,
                  size: 44,
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
                          if (pinBadgeColor != null) ...[
                            const SizedBox(width: 7),
                            Icon(
                              Icons.push_pin_rounded,
                              size: 13,
                              color: pinBadgeColor,
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
                      BotStatusLine(
                        status: live,
                        interactive: false,
                        text:
                            preview.isNotEmpty &&
                                live.presence == RoomPresence.idle
                            ? '${botStatusText(Strings.of(context), live)} · $preview'
                            : null,
                      ),
                    ],
                  ),
                ),
                if (preview.isNotEmpty)
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
                  onPressed: onQuickActions,
                  icon: const Icon(Icons.more_horiz_rounded, size: 21),
                  color: colors.textSecondary,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
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

/// Columna de 72px de una fila "Fijados": avatar de 64px con anillo de
/// estado (verde si activo, rojo si error, sin anillo si inactivo) y nombre
/// debajo. Mismas acciones que [_BotRow] (tap abre el detalle, mantener
/// pulsado abre la hoja de acciones rápidas): solo cambia la presentación.
class _PinnedBotTile extends StatelessWidget {
  final MissionAgent agent;
  final BotLiveStatus live;
  final bool needsYou;
  final bool unread;
  final MissionProfileAvatarCache? avatarCache;
  final VoidCallback onOpen;
  final VoidCallback onQuickActions;

  const _PinnedBotTile({
    required this.agent,
    required this.live,
    required this.needsYou,
    required this.unread,
    required this.avatarCache,
    required this.onOpen,
    required this.onQuickActions,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final profile = agent.profile;
    final displayName = profile.botTitle ?? profile.name;
    return Semantics(
      container: true,
      button: true,
      label: displayName,
      child: InkWell(
        onTap: onOpen,
        onLongPress: onQuickActions,
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: 72,
          child: Column(
            children: [
              SizedBox(
                width: 64,
                height: 64,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    BotStatusAvatar(
                      identity: profile.name,
                      label: displayName,
                      profile: profile,
                      avatarCache: avatarCache,
                      status: live,
                      size: 64,
                    ),
                    if (needsYou)
                      PositionedDirectional(
                        top: -4,
                        end: -4,
                        child: Container(
                          width: 22,
                          height: 22,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: colors.warning,
                            shape: BoxShape.circle,
                            border: Border.all(color: colors.surface, width: 3),
                          ),
                          child: const Text(
                            '!',
                            style: TextStyle(
                              // Texto oscuro fijo sobre el ámbar del badge,
                              // como en el mockup: no depende del tema.
                              color: Color(0xFF1A1200),
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                              height: 1,
                            ),
                          ),
                        ),
                      )
                    else if (unread)
                      PositionedDirectional(
                        top: -2,
                        end: -2,
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            color: colors.accent,
                            shape: BoxShape.circle,
                            border: Border.all(color: colors.surface, width: 3),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 9),
              Text(
                displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: needsYou || unread
                      ? colors.textPrimary
                      : colors.textSecondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.1,
                ),
              ),
              BotStatusLine(status: live, interactive: false),
            ],
          ),
        ),
      ),
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
    // Sin `+ viewInsets.bottom`: ver el comentario largo en
    // `_HostedGroupCreateDialogState.build`. La superficie flotante ya
    // descuenta el teclado dos veces (desplazamiento + `maxHeight`), y
    // sumarlo aquí dentro dejaba el formulario sin altura útil con el
    // teclado abierto.
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
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

enum _BotQuickAction { togglePinned, toggleHidden, openChat, details, section, recent, duplicate, delete, groups }

/// Hoja de acciones rápidas de una tarjeta de bot: mantener pulsada la fila
/// o tocar su ⋯ abre esto en vez de saltar directo a la ficha completa
/// (`_AgentDetail`), que sigue accesible como "Detalles del bot". Sustituye
/// al swipe explorado en rondas de diseño anteriores.
class _BotQuickActionsSheet extends StatelessWidget {
  final MissionAgent agent;
  final BotLiveStatus live;
  final MissionControlCopy copy;
  final MissionProfileAvatarCache? avatarCache;
  final bool canMutate;
  final bool canManage;

  const _BotQuickActionsSheet({
    required this.agent,
    required this.live,
    required this.copy,
    required this.avatarCache,
    required this.canMutate,
    this.canManage = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final profile = agent.profile;
    return SafeArea(
      top: false,
      child: ListView(
        key: const ValueKey('mission-bot-quick-actions'),
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
            child: Row(
              children: [
                BotStatusAvatar(
                  identity: profile.name,
                  label: profile.botTitle ?? profile.name,
                  profile: profile,
                  status: live,
                  avatarCache: avatarCache,
                  size: 40,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.botTitle ?? profile.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '@${profile.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                      BotStatusLine(status: live),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.divider.withValues(alpha: 0.5)),
          const SizedBox(height: 4),
          if (canMutate)
            _BotQuickActionItem(
              key: const ValueKey('bot-quick-toggle-pinned'),
              icon: profile.botPinned
                  ? Icons.push_pin_outlined
                  : Icons.push_pin_rounded,
              label: profile.botPinned ? copy.unpinBot : copy.pinBot,
              primary: true,
              onTap: () => Navigator.pop(context, _BotQuickAction.togglePinned),
            ),
          if (canMutate)
            _BotQuickActionItem(
              key: const ValueKey('bot-quick-toggle-hidden'),
              icon: profile.botHidden
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              label: profile.botHidden ? copy.showBot : copy.hideBot,
              onTap: () => Navigator.pop(context, _BotQuickAction.toggleHidden),
            ),
          _BotQuickActionItem(
            key: const ValueKey('bot-quick-open-chat'),
            icon: Icons.chat_bubble_outline,
            label: copy.openChat,
            onTap: () => Navigator.pop(context, _BotQuickAction.openChat),
          ),
          _BotQuickActionItem(icon: Icons.forum_outlined,
            label: Strings.of(context).botManageRooms,
            onTap: () => Navigator.pop(context, _BotQuickAction.groups)),
          _BotQuickActionItem(icon: Icons.history,
            label: Strings.of(context).botRecentSession,
            onTap: () => Navigator.pop(context, _BotQuickAction.recent)),
          if (canMutate && canManage) ...[
            _BotQuickActionItem(icon: Icons.folder_outlined,
              label: Strings.of(context).botSectionMove,
              onTap: () => Navigator.pop(context, _BotQuickAction.section)),
            _BotQuickActionItem(icon: Icons.copy_outlined,
              label: Strings.of(context).botDuplicate,
              onTap: () => Navigator.pop(context, _BotQuickAction.duplicate)),
          ],
          if (canMutate && !profile.isDefault && profile.name != 'default')
            _BotQuickActionItem(icon: Icons.delete_outline,
              label: Strings.of(context).prfDeleteTitle,
              onTap: () => Navigator.pop(context, _BotQuickAction.delete)),
          _BotQuickActionItem(
            key: const ValueKey('bot-quick-details'),
            icon: Icons.info_outline,
            label: copy.botDetails,
            onTap: () => Navigator.pop(context, _BotQuickAction.details),
          ),
        ],
      ),
    );
  }
}

class _BotQuickActionItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  const _BotQuickActionItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final color = primary ? colors.accentText : colors.textPrimary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SizedBox(
            height: 52,
            child: Row(
              children: [
                Icon(icon, size: 22, color: primary ? colors.accent : color),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
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

/// Ficha única del bot: toda acción cuelga del bot (chat primario, edición del
/// profile, rutinas, tareas y contexto de memoria/skills/SOUL), siguiendo la
/// organización del plugin oficial Hermes Bot Mode.
class _AgentDetail extends StatelessWidget {
  final MissionAgent agent;
  final BotLiveStatus live;
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
    required this.live,
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
    final profile = agent.profile;
    final model = [
      agent.provider,
      agent.model,
    ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');
    final session = agent.currentSession;
    return ListView(
      // `shrinkWrap`: la hoja se ajusta al contenido (ver `_openAgent`) y
      // sigue haciendo scroll cuando el contenido supera el alto máximo.
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
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
        const SizedBox(height: 16),
        // 1. Identidad. Una sola línea de jerarquía: nombre visible, handle y
        // el estado como pill (antes era texto de color suelto, que se leía
        // como una frase más dentro del muro de texto).
        Row(
          children: [
            BotStatusAvatar(
              identity: profile.name,
              label: profile.botTitle ?? profile.name,
              profile: profile,
              status: live,
              avatarCache: avatarCache,
              size: 52,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.botTitle ?? profile.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 1),
                  // El `@handle` sustituye a la fila "Profile · nombre": es el
                  // mismo dato, en el sitio donde ya se lee como identidad.
                  Text(
                    '@${profile.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: BotStatusLine(status: live),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (profile.description.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            profile.description,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 13.5,
              height: 1.35,
            ),
          ),
        ],
        // 2. Acción principal, arriba: antes quedaba enterrada debajo de las
        // filas de datos y del bloque de tokens.
        const SizedBox(height: 16),
        HermesPrimaryButton(
          key: const ValueKey('bot-detail-chat'),
          label: copy.openChat,
          icon: Icons.chat_bubble_outline,
          onTap: onChat,
        ),
        // 3. Contexto técnico: dos líneas tenues de una sola línea cada una,
        // en vez de la columna de etiquetas de 90 px ("Profile", "Modelo",
        // "Sesiones recientes") que convertía la ficha en un muro de texto.
        const SizedBox(height: 14),
        _BotDetailMetaLine(
          icon: Icons.memory_rounded,
          text: model.isEmpty ? copy.modelUnavailable : model,
        ),
        if (session != null)
          _BotDetailMetaLine(
            icon: Icons.history_rounded,
            text: session.displayTitle,
          ),
        // 4. Trabajo asignado, si hay: agrupado bajo su propio encabezado en
        // vez de mezclado con las filas de datos del bot.
        if (assignedTasks.isNotEmpty) ...[
          HermesSectionHeader(copy.assignedTasks(assignedTasks.length)),
          HermesGroup(
            children: [
              for (final task in assignedTasks)
                _BotDetailTaskLine(title: task.title, status: task.status),
            ],
          ),
        ],
        // 5. Acciones, agrupadas por lo que hacen (no en una parrilla de 8
        // botones iguales): lo que configura al bot en un grupo, y lo que solo
        // afecta a cómo se ve en la lista de Bots en otro.
        const SizedBox(height: 16),
        HermesGroup(
          children: [
            _BotDetailActionRow(
              key: const ValueKey('bot-detail-edit-profile'),
              icon: Icons.tune,
              label: copy.editProfile,
              onTap: onEditProfile,
            ),
            _BotDetailActionRow(
              key: const ValueKey('bot-detail-routines'),
              icon: Icons.schedule_outlined,
              label: copy.routines,
              onTap: onRoutines,
            ),
            _BotDetailActionRow(
              key: const ValueKey('bot-detail-tasks'),
              icon: Icons.view_kanban_outlined,
              label: copy.tasks,
              trailing: assignedTasks.isEmpty
                  ? null
                  : '${assignedTasks.length}',
              onTap: onTasks,
            ),
            _BotDetailActionRow(
              key: const ValueKey('bot-detail-memory'),
              icon: Icons.psychology_outlined,
              label: copy.memory,
              onTap: onMemory,
            ),
            _BotDetailActionRow(
              key: const ValueKey('bot-detail-skills'),
              icon: Icons.extension_outlined,
              label: copy.skills,
              onTap: onSkills,
            ),
            _BotDetailActionRow(
              key: const ValueKey('bot-detail-soul'),
              icon: Icons.auto_awesome_outlined,
              label: copy.soul,
              onTap: onSoul,
            ),
          ],
        ),
        if (onTogglePinned != null || onToggleHidden != null) ...[
          const SizedBox(height: 10),
          HermesGroup(
            children: [
              if (onTogglePinned != null)
                _BotDetailActionRow(
                  key: const ValueKey('bot-detail-toggle-pinned'),
                  icon: profile.botPinned
                      ? Icons.push_pin_outlined
                      : Icons.push_pin_rounded,
                  label: profile.botPinned ? copy.unpinBot : copy.pinBot,
                  showChevron: false,
                  onTap: onTogglePinned,
                ),
              if (onToggleHidden != null)
                _BotDetailActionRow(
                  key: const ValueKey('bot-detail-toggle-hidden'),
                  icon: profile.botHidden
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  label: profile.botHidden ? copy.showBot : copy.hideBot,
                  showChevron: false,
                  onTap: onToggleHidden,
                ),
            ],
          ),
        ],
        // 6. Uso: una sola línea tenue al final. El desglose input/output/
        // caché/reasoning ya no ocupa media ficha con cifras en grande — sigue
        // disponible manteniendo pulsado (tooltip), que es donde importa.
        const SizedBox(height: 16),
        _BotUsageFooter(usage: agent.usage, copy: copy),
      ],
    );
  }
}

/// Línea tenue de contexto (modelo, última sesión) dentro de la ficha del bot.
class _BotDetailMetaLine extends StatelessWidget {
  final IconData icon;
  final String text;

  const _BotDetailMetaLine({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 15, color: colors.textDisabled),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fila de acción de la ficha del bot, para usar dentro de un [HermesGroup].
///
/// `onTap` nulo = acción no disponible en esta conexión (instancia en modo
/// consulta): la fila sigue visible pero apagada, como antes hacía el botón
/// deshabilitado, para no cambiar en silencio lo que el usuario ve según los
/// permisos.
class _BotDetailActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? trailing;
  final bool showChevron;
  final VoidCallback? onTap;

  const _BotDetailActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
    this.showChevron = true,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final enabled = onTap != null;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: enabled ? colors.textSecondary : colors.textDisabled,
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: enabled ? colors.textPrimary : colors.textDisabled,
                ),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              Text(
                trailing!,
                style: TextStyle(
                  fontSize: 12.5,
                  color: colors.textSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
            if (showChevron) ...[
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: colors.textDisabled,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Tarea asignada dentro de la ficha del bot: título + estado tenue, sin la
/// columna de etiquetas que usaba la versión anterior.
class _BotDetailTaskLine extends StatelessWidget {
  final String title;
  final String status;

  const _BotDetailTaskLine({required this.title, required this.status});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color: colors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.textDisabled, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

/// Pie de uso de la ficha del bot: total de tokens y coste en UNA línea
/// tenue. El desglose por tipo (input/output/caché/reasoning) vive en el
/// tooltip, no en la ficha: ocupaba media pantalla con cifras en grande que
/// competían con las acciones del bot.
class _BotUsageFooter extends StatelessWidget {
  final MissionUsage usage;
  final MissionControlCopy copy;

  const _BotUsageFooter({required this.usage, required this.copy});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final cost = usage.actualCostUsd ?? usage.estimatedCostUsd;
    final total = usage.totalTokens;
    final breakdown = [
      if (usage.inputTokens != null)
        '${copy.input} ${_compact(usage.inputTokens!)}',
      if (usage.outputTokens != null)
        '${copy.output} ${_compact(usage.outputTokens!)}',
      if (usage.cacheReadTokens != null)
        '${copy.cached} ${_compact(usage.cacheReadTokens!)}',
      if (usage.reasoningTokens != null)
        '${copy.reasoning} ${_compact(usage.reasoningTokens!)}',
    ];
    final parts = [
      if (total != null) '${_compact(total)} ${copy.tokens}',
      if (cost != null)
        '\$${cost.toStringAsFixed(4)}${usage.costCoverage == MissionCostCoverage.partial ? ' · ${copy.partialCost}' : ''}',
    ];
    final line = parts.isEmpty
        ? (breakdown.isEmpty ? copy.tokensUnavailable : breakdown.join(' · '))
        : parts.join(' · ');
    final text = Text(
      line,
      key: const ValueKey('bot-detail-usage'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: colors.textDisabled, fontSize: 11.5),
    );
    return breakdown.isEmpty
        ? text
        : Tooltip(message: breakdown.join(' · '), child: text);
  }
}

class _MessageCard extends StatelessWidget {
  final String text;

  const _MessageCard({required this.text});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 12),
    child: Text(text),
  );
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

String _compact(int value) {
  if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
  if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}K';
  return '$value';
}

String _clock(DateTime time) {
  final local = time.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}
