import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../models/agent_profile.dart';
import '../models/room_mirror.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/room_mirror_avatar.dart';
import '../models/hosted_groups.dart';
import '../models/room_member_status.dart';
import '../models/kanban.dart';
import '../models/mission_control.dart';
import '../navigation/chat_route.dart';
import '../services/active_chat_service.dart';
import '../services/chat_draft_store.dart';
import '../services/connection_manager.dart';
import '../bots/data/desktop_projection_rooms.dart';
import '../bots/state/attention.dart';
import '../bots/ui/room/room_dictation.dart';
import '../bots/ui/room/room_gateway.dart';
import '../bots/ui/room/room_launcher.dart';
import '../bots/ui/room/room_prefs.dart';
import '../bots/ui/room/room_screen.dart';
import '../bots/ui/room/room_sheets.dart' show showRoomMembersSheet;
import '../bots/state/bot_presence.dart';
import '../bots/state/bot_roster_meta.dart';
import '../bots/ui/profile/bot_profile_screen.dart';
import '../bots/ui/roster/bots_roster_view.dart';
import '../bots/ui/roster/projection_room_sheet.dart';
import '../bots/ui/roster/roster_actions.dart';
import '../bots/ui/roster/roster_model.dart';
import '../bots/state/bot_chat_target.dart';
import '../services/shared_gateway_pool.dart';
import '../services/mission_control_repository.dart';
import '../services/mission_bot_chat_store.dart';
import '../services/mission_organization_store.dart';
import '../services/notifications/background_listener.dart';
import '../services/tui_gateway_client.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_drawer.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/dock.dart';
import '../widgets/dock_style.dart' show dockShowsBack;
import '../widgets/chat_surface_coordinator.dart';
import '../widgets/dock_shortcuts.dart';
import '../widgets/mission_profile_avatar.dart';
import '../widgets/remote_bot_roster.dart';
import 'bot_create_screen.dart';
import 'bot_profile_settings_screen.dart';
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
import '../design/hermes_design.dart'
    show HermesDialogAction, HermesDialogActionStyle, showHermesDialog;

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

/// Canonical Bot Chat target (spec 070 T206). Desktop's invariant: the only
/// identity is the profile's session titled exactly "Bot Chat", reported as
/// `canonical_session` (or found by `session.list {title}`). Legacy
/// `ui_meta['hermes-bots'].chat` pins and Console-local pins are ignored.
@visibleForTesting
({String? sessionId, String source, bool valid}) resolveBotChatTarget(
  AgentProfile profile, {
  AgentProfileSessionSummary? titleLookup,
}) {
  final target = BotChatTarget.resolve(profile, titleLookup: titleLookup);
  return (sessionId: target.sessionId, source: target.chatSource, valid: true);
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

  /// Bot Chat registry lookup override (tests); defaults to the gateway.
  final BotChatTitleLookup? botChatTitleLookup;
  @visibleForTesting
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

  /// Per-bot model catalog/reasoning (tests); defaults to the gateway.
  final BotModelGateway? botModelGateway;
  @visibleForTesting
  final Future<List<ModelProvider>> Function(String profile)?
  modelOptionsLoader;

  const MissionControlScreen({
    required this.connection,
    required this.connManager,
    this.dataSource,
    this.organizationStore,
    this.botChatStore,
    this.botChatTitleLookup,
    this.activeChats,
    this.initialOpenTarget,
    this.botChatOpenObserver,
    this.remoteBotLoader,
    this.botCreateGateway,
    this.profileAssetsGateway,
    this.botProfileGateway,
    this.botModelGateway,
    this.modelOptionsLoader,
    super.key,
  });

  @override
  State<MissionControlScreen> createState() => _MissionControlScreenState();
}

class _MissionControlScreenState extends State<MissionControlScreen>
    with WidgetsBindingObserver {
  late final MissionControlDataSource _dataSource;
  late final MissionProfileAvatarCache? _profileAvatarCache;
  late final MissionOrganizationStoreContract _organizationStore;
  late final MissionBotChatStore _botChatStore;
  SharedGatewayLease? _profileAssetsLease;
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
  bool _lifecyclePaused = false;
  bool _disposed = false;
  bool _initialOpenDispatched = false;
  late final ChatSurfaceCoordinator _surfaceCoordinator;

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
    final injectedAssets = widget.profileAssetsGateway;
    if (injectedAssets != null) {
      _profileAssetsGateway = injectedAssets;
    } else {
      final lease = SharedGatewayPool.instance.acquire(widget.connection);
      _profileAssetsLease = lease;
      _profileAssetsGateway = lease.client;
    }
    _organizations = _organizationStore.load(widget.connection.id);
    WidgetsBinding.instance.addObserver(this);
    _scheduleRosterRefresh();
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
    _rosterTimer?.cancel();
    _rosterSearchOpen.dispose();
    _statusRevision.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _activeChats?.activeIds.removeListener(_onActiveIdsChanged);
    _cancelLiveSubscriptions();
    _kanbanRefreshDebounce?.cancel();
    _kanbanReconnectTimer?.cancel();
    unawaited(_kanbanSubscription?.cancel());
    _kanbanSubscription = null;
    _profileAvatarCache?.clear();
    _profileAssetsLease?.release();
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

  /// Header search toggle of the Bots roster.
  final _rosterSearchOpen = ValueNotifier<bool>(false);

  /// Roster refresh while visible (spec 070 plan: roster every 30 s).
  static const rosterRefreshInterval = Duration(seconds: 30);
  Timer? _rosterTimer;

  void _scheduleRosterRefresh() {
    _rosterTimer?.cancel();
    _rosterTimer = Timer.periodic(rosterRefreshInterval, (_) {
      if (_disposed || !mounted || _lifecyclePaused) return;
      if (ModalRoute.of(context)?.isCurrent == false) return;
      if (_loading || _refreshing) return;
      unawaited(_load(refresh: true));
    });
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
              onSend: (text, attempt) => _kickRoomWatchAfter(
                _mutateHostedGroup(
                  rooms[index],
                  (source, room, generation) => source.sendHostedGroupText(
                    room,
                    text: text,
                    attempt: attempt,
                    generation: generation,
                  ),
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

  Future<void> _saveBotRosterMeta(
    MissionAgent agent, {
    bool? hidden,
    bool? pinned,
  }) async {
    if (widget.connection.readOnly) return;
    final copy = MissionControlCopy.of(context);
    try {
      // ui_meta['hermes-bots'] read-modify-write, Desktop keys (T208).
      final gateway = _botProfileGateway;
      if (gateway != null) {
        final writer = BotRosterMetaWriter(gateway);
        if (pinned != null) await writer.setPinned(agent.profile.name, pinned);
        if (hidden != null) await writer.setHidden(agent.profile.name, hidden);
      } else {
        await _profileAssetsGateway.saveProfileBotMeta(
          profile: agent.profile.name,
          hidden: hidden,
          pinned: pinned,
        );
      }
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
    // Sections live in ui_meta (sectionId/sectionName) like Desktop's
    // user-sections.ts; every write drops the legacy `chat` pointer.
    final writer = BotRosterMetaWriter(gateway);
    final failed = <String, BotSectionChange>{};
    for (final entry in changes.entries) {
      try {
        await writer.setSection(entry.key, id: entry.value.id, name: entry.value.name);
      } catch (_) {
        failed[entry.key] = entry.value;
      }
    }
    final result = (failed: failed);
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

  Future<void> _sectionMenu(String sectionId, String sectionName) async {
    if (_sectionBusy || widget.connection.readOnly) return;
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
      final name = await botSectionNameDialog(context, initial: sectionName);
      if (name == null || !mounted) return;
      await _applySections(BotSectionService.members(profiles, sectionId,
        BotSectionChange(sectionId, name)));
    } else {
      final undo = <String, BotSectionChange>{
        for (final profile in profiles)
          if (profile.botSectionId == sectionId)
            profile.name: BotSectionChange(sectionId, profile.botSectionName ?? sectionName),
      };
      await _applySections(BotSectionService.members(profiles, sectionId,
        const BotSectionChange(null, null)), deletion: true, undo: undo);
    }
  }

  Future<void> _openRemoteBot(
    SavedConnection connection,
    AgentProfile profile,
  ) async {
    SharedGatewayLease? lease;
    try {
      final loader = widget.remoteBotLoader;
      if (loader != null) {
        profile = (await loader(connection))
            .singleWhere((candidate) => candidate.name == profile.name);
      } else {
        lease = SharedGatewayPool.instance.acquire(connection);
        profile = (await lease.client.listProfiles(includeSessions: true))
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
      lease?.release();
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
    final confirmed = await showHermesDialog<bool>(
      context: context,
      title: copy.deleteOrganizationTitle,
      message: copy.deleteOrganizationBody,
      actions: [
        HermesDialogAction(
          label: copy.cancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          label: copy.delete,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
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
    // Console-local pins are a retired compatibility tier: retire them
    // best-effort so no later build can resurrect a stale pointer.
    if (!widget.connection.readOnly) {
      try {
        await _botChatStore.clear(
          connectionId: widget.connection.id,
          profile: agent.profile.name,
        );
      } catch (error) {
        debugPrint(
          'Mission Control: could not retire the local Bot Chat pin '
          'for ${agent.profile.name}: $error',
        );
      }
    }
    AgentProfileSessionSummary? titleRow;
    if (agent.profile.canonicalBotChatSessionId == null) {
      final lookup =
          widget.botChatTitleLookup ??
          (_profileAssetsGateway is BotChatTitleLookup
              ? _profileAssetsGateway as BotChatTitleLookup
              : null);
      if (lookup != null) {
        try {
          titleRow = await lookup.findBotChatByTitle(agent.profile.name);
        } catch (error) {
          // Fail closed: creating now could fork an existing canonical row.
          debugPrint(
            'Mission Control: Bot Chat registry lookup failed for '
            '${agent.profile.name}: $error',
          );
          _showBotChatPinUnavailable();
          return;
        }
      }
    }
    if (!mounted) return;
    final target = resolveBotChatTarget(agent.profile, titleLookup: titleRow);
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

  MissionAgent _currentAgent(MissionAgent agent) =>
      _roomAgents()
          .where((a) => a.profile.name == agent.profile.name)
          .firstOrNull ??
      agent;

  BotModelGateway? get _botModelGateway =>
      widget.botModelGateway ??
      (_profileAssetsGateway is BotModelGateway
          ? _profileAssetsGateway as BotModelGateway
          : null);

  /// Live **Now** items of a bot (spec 070 S4), server evidence only:
  /// fresh worker session, the bot's live chats, and hosted rooms where its
  /// seat works or needs the user. Stop is offered where the server allows
  /// it (`session.interrupt` via the live chat, `groups.stop`).
  BotProfileData _profileData(MissionAgent original) {
    final agent = _currentAgent(original);
    final profile = agent.profile;
    final snapshot = _snapshot;
    final groups = snapshot?.hostedGroups ?? HostedGroupsSnapshot.empty;
    final now = DateTime.now();
    final strings = Strings.of(context);
    final items = <BotNowItem>[];
    final worker = profile.workerSession;
    if (worker != null &&
        BotPresence.workerIsFresh(worker, now) &&
        worker.title.trim().isNotEmpty) {
      items.add(BotNowItem(label: strings.botProfileWorkingOn(worker.title.trim())));
    }
    final service = _activeChats;
    if (service != null) {
      for (final chat in _resolveActiveChats(service)) {
        if (Session.profileOwner(chat.sessionProfile) != profile.name) continue;
        final phase = _missionPhase(chat);
        final label = switch (phase) {
          MissionLivePhase.thinking => strings.botProfileLiveThinking,
          MissionLivePhase.working => strings.botProfileLiveWorking,
          MissionLivePhase.responding => strings.botProfileLiveReplying,
          MissionLivePhase.approvalRequired => strings.botProfileLiveApproval,
          _ => null,
        };
        if (label == null) continue;
        items.add(
          BotNowItem(
            label: label,
            detail: chat.sessionTitle,
            attention: phase == MissionLivePhase.approvalRequired,
            onStop: widget.connection.readOnly
                ? null
                : () async {
                    await chat.stopSessionWork();
                  },
          ),
        );
      }
    }
    final attention = AttentionSummary.fromSnapshot(groups);
    final canStop =
        !widget.connection.readOnly &&
        (groups.capabilities?.supports(GroupMethod.stop) ?? false);
    var roomCount = 0;
    for (final room in groups.rooms) {
      if (room.disbanded) continue;
      final seats = {
        for (final member in room.members)
          if (member.owner.connectionId == room.authorityGatewayId &&
              member.owner.profile == profile.name)
            member.memberId,
      };
      if (seats.isEmpty) continue;
      roomCount++;
      final needs = (attention.room(room.roomId)?.items ?? const [])
          .any((item) => seats.contains(item.memberId));
      final seatWorking = BotRoomSeat.forProfile(profile.name, groups).any(
        (seat) => seat.roomId == room.roomId && seat.running,
      );
      if (needs) {
        items.add(
          BotNowItem(
            label: strings.botProfileNeedsYouInRoom(room.name),
            attention: true,
          ),
        );
      } else if (seatWorking) {
        items.add(
          BotNowItem(
            label: strings.botProfileWorkingInRoom(room.name),
            onStop: canStop
                ? () async {
                    await _mutateHostedGroup(
                      room,
                      (source, current, generation) => source.stopHostedGroup(
                        current,
                        generation: generation,
                      ),
                    );
                  }
                : null,
          ),
        );
      }
    }
    final live = BotLiveStatus.forAgent(agent: agent, now: now, rooms: groups);
    return BotProfileData(
      profile: profile,
      signal: BotRosterEntry.from(
        agent: agent,
        live: live,
        hasAttention: attention.forProfile(profile.name, groups).isNotEmpty,
        now: now,
      ).signal,
      now: items,
      roomCount: roomCount,
      taskCount: [
        for (final column in snapshot?.board?.columns ?? const <KanbanColumn>[])
          for (final task in column.tasks)
            if (task.assignee?.trim() == profile.name) task,
      ].length,
    );
  }

  /// Bot profile (spec 070 S4) as a full route.
  Future<void> _openBotProfile(MissionAgent agent) async {
    final name = agent.profile.name;
    final readOnly = widget.connection.readOnly;
    final gateway = _botProfileGateway;
    final strings = Strings.of(context);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BotProfileScreen(
          key: ValueKey('bot-profile-$name'),
          data: () => _profileData(agent),
          refresh: _statusRevision,
          avatarCache: _profileAvatarCache,
          modelGateway: _botModelGateway,
          profileGateway: gateway,
          readOnly: readOnly,
          machineLabel: widget.connection.label,
          onChat: () => unawaited(_openChat(_currentAgent(agent))),
          onRooms: () => unawaited(_manageBotRooms(_currentAgent(agent))),
          onRoutines: () => _openRoutines(profile: name),
          onSoul: gateway == null || readOnly
              ? _openSoul
              : () => _openAdvancedSettings(name),
          onSkills: () => _openSkills(profile: name),
          onMemory: () => _openMemory(profile: name),
          onTasks: () => unawaited(_openTasks(assignee: name)),
          onEditIdentity: readOnly
              ? null
              : () => unawaited(_openProfileEditor(_currentAgent(agent).profile)),
          onChanged: () => unawaited(_load(refresh: true)),
          moreActions: [
            BotProfileAction(
              key: const ValueKey('bot-profile-recent'),
              icon: Icons.history,
              label: strings.botRecentSession,
              onTap: () => unawaited(_openRecentSession(_currentAgent(agent))),
            ),
            if (!readOnly && gateway != null) ...[
              BotProfileAction(
                key: const ValueKey('bot-profile-advanced'),
                icon: Icons.tune,
                label: strings.botAdvanced,
                onTap: () => _openAdvancedSettings(name),
              ),
              BotProfileAction(
                key: const ValueKey('bot-profile-duplicate'),
                icon: Icons.copy_outlined,
                label: strings.botDuplicate,
                onTap: () => unawaited(_duplicateBot(_currentAgent(agent))),
              ),
            ],
            if (!readOnly && !agent.profile.isDefault && name != 'default')
              BotProfileAction(
                key: const ValueKey('bot-profile-delete'),
                icon: Icons.delete_outline,
                label: strings.prfDeleteTitle,
                onTap: () => unawaited(_deleteBot(name)),
              ),
          ],
        ),
      ),
    );
    if (mounted) await _load(refresh: true);
  }

  void _openAdvancedSettings(String profile) {
    final gateway = _botProfileGateway;
    if (gateway == null) return;
    unawaited(
      Navigator.of(context)
          .push<bool>(
            MaterialPageRoute(
              builder: (_) =>
                  BotProfileSettingsScreen(profile: profile, gateway: gateway),
            ),
          )
          .then((saved) {
            if (saved == true && mounted) unawaited(_load(refresh: true));
          }),
    );
  }

  Future<void> _deleteBot(String profile) async {
    if (widget.connection.readOnly || profile == 'default') return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProfilesScreen(
          connection: widget.connection,
          connManager: widget.connManager,
          initialDeleteProfile: profile,
        ),
      ),
    );
    if (mounted) await _load(refresh: true);
  }

  /// Long-press actions on a roster row (spec 070 T402): pin, section,
  /// hide and open profile, written to `ui_meta` like Desktop.
  Future<void> _openRosterActions(BotRosterEntry entry) async {
    _surfaceCoordinator.setRouteActive(false);
    final action =
        await showHermesFloatingSurface<RosterBotAction>(
          context: context,
          surfaceKey: ValueKey('roster-bot-actions-${entry.profile.name}'),
          maxWidth: 420,
          maxHeightFactor: 0.6,
          builder: (_) => RosterBotActionsSheet(
            entry: entry,
            avatarCache: _profileAvatarCache,
            canMutate: !widget.connection.readOnly,
            canSection: _botProfileGateway != null,
          ),
        ).whenComplete(() {
          if (mounted) _surfaceCoordinator.setRouteActive(true);
        });
    if (!mounted || action == null) return;
    final agent = _currentAgent(entry.agent);
    switch (action) {
      case RosterBotAction.chat:
        await _openChat(agent);
      case RosterBotAction.togglePin:
        await _saveBotRosterMeta(agent, pinned: !agent.profile.botPinned);
      case RosterBotAction.toggleHidden:
        await _saveBotRosterMeta(agent, hidden: !agent.profile.botHidden);
      case RosterBotAction.section:
        await _moveBotToSection(agent.profile);
      case RosterBotAction.profile:
        await _openBotProfile(agent);
    }
  }

  Future<void> _openRosterRoom(RoomRosterEntry entry) async {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    final roomId = entry.hostedRoomId;
    if (roomId != null) {
      await _openInitialTarget(
        MissionControlOpenTarget.room(sessionId: '', roomId: roomId),
        snapshot,
      );
      return;
    }
    final projection = entry.projection;
    if (projection == null) return;
    await showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: ValueKey('roster-projection-${entry.publicKey}'),
      maxWidth: 560,
      maxHeightFactor: 0.86,
      builder: (_) => ProjectionRoomSheet(room: projection),
    );
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
        unawaited(_openBotProfile(agent));
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
    SharedGatewayLease? remoteLease;
    try {
      var profiles = snapshot.profiles;
      TuiGatewayClient? remote;
      if (target.id != widget.connection.id) {
        remoteLease = SharedGatewayPool.instance.acquire(target);
        remote = remoteLease.client;
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
    } finally { remoteLease?.release(); }
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

  /// "Needs you" summary row: with one pending approval it opens that
  /// Bot's chat directly; otherwise a small chooser lists the approvals
  /// (each opens its Bot's chat) and the shared task board for blocked work.
  Future<void> _openAttention() async {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    final projection = _projection(snapshot);
    final approvals = projection.approvals;
    Future<void> openApproval(MissionApproval approval) async {
      for (final agent in projection.agents) {
        if (agent.profile.name == approval.profileName) {
          await _openChat(agent);
          return;
        }
      }
    }

    if (approvals.length == 1 && projection.blockedCount == 0) {
      await openApproval(approvals.single);
      return;
    }
    final strings = Strings.of(context);
    final choice = await showHermesFloatingSurface<Object>(
      context: context,
      surfaceKey: const ValueKey('mission-attention-sheet'),
      maxWidth: 420,
      builder: (sheetContext) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final approval in approvals)
            ListTile(
              key: ValueKey(
                'mission-attention-approval-${approval.profileName}',
              ),
              leading: const Icon(Icons.approval_outlined),
              title: Text(strings.missionApprovalPending),
              subtitle: Text('@${approval.profileName}'),
              onTap: () => Navigator.pop(sheetContext, approval),
            ),
          if (projection.blockedCount > 0)
            ListTile(
              key: const ValueKey('mission-attention-board'),
              leading: const Icon(Icons.view_kanban_outlined),
              title: Text(strings.missionTaskBoardLabel),
              onTap: () => Navigator.pop(sheetContext, 'board'),
            ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice is MissionApproval) {
      await openApproval(choice);
    } else if (choice == 'board') {
      await _openTasks();
    }
  }

  /// Long-press actions on a room row: open, members, rename, stop and
  /// disband, with the same authority checks the room screen uses.
  Future<void> _openRoomActions(RoomRosterEntry entry) async {
    final snapshot = _snapshot;
    final roomId = entry.hostedRoomId;
    if (snapshot == null || roomId == null) {
      await _openRosterRoom(entry);
      return;
    }
    final room = snapshot.hostedGroups.rooms
        .where((r) => r.roomId == roomId && !r.disbanded)
        .firstOrNull;
    if (room == null) return;
    final capabilities = snapshot.hostedGroups.capabilities;
    final enabled =
        !widget.connection.readOnly &&
        _hostedGroupsDataSource != null &&
        snapshot.hostedGroupsCapability == MissionCapabilityState.available;
    bool can(GroupMethod method) =>
        enabled && (capabilities?.supports(method) ?? false);
    final copy = MissionControlCopy.of(context);
    final strings = Strings.of(context);
    _surfaceCoordinator.setRouteActive(false);
    final action =
        await showHermesFloatingSurface<String>(
          context: context,
          surfaceKey: ValueKey('roster-room-actions-${entry.publicKey}'),
          maxWidth: 420,
          maxHeightFactor: 0.6,
          builder: (sheetContext) {
            Widget item(String value, IconData icon, String label,
                    {bool destructive = false}) =>
                ListTile(
                  key: ValueKey('roster-room-action-$value'),
                  leading: Icon(
                    icon,
                    color: destructive
                        ? Theme.of(sheetContext).hermes.error
                        : null,
                  ),
                  title: Text(
                    label,
                    style: destructive
                        ? TextStyle(color: Theme.of(sheetContext).hermes.error)
                        : null,
                  ),
                  onTap: () => Navigator.pop(sheetContext, value),
                );
            return SafeArea(
              top: false,
              child: ListView(
                key: const ValueKey('roster-room-actions'),
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                    child: Text(
                      entry.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  item('open', Icons.forum_outlined, strings.missionOpenRoom),
                  item('members', Icons.group_outlined, strings.roomMenuMembers),
                  if (can(GroupMethod.rename))
                    item('rename', Icons.edit_outlined, copy.renameSharedRoom),
                  if (can(GroupMethod.stop))
                    item(
                      'stop',
                      Icons.stop_circle_outlined,
                      copy.stopSharedRoomAction,
                    ),
                  if (can(GroupMethod.disband))
                    item(
                      'disband',
                      Icons.block_rounded,
                      copy.disbandSharedRoomAction,
                      destructive: true,
                    ),
                ],
              ),
            );
          },
        ).whenComplete(() {
          if (mounted) _surfaceCoordinator.setRouteActive(true);
        });
    if (!mounted || action == null) return;
    Future<void> mutate(
      Future<HostedGroupWorkspaceReadback> Function(
        MissionHostedGroupsDataSource source,
        HostedGroupRoom room,
        int generation,
      )
      run,
    ) async {
      try {
        await _mutateHostedGroup(room, run);
      } catch (_) {
        // _mutateHostedGroup already showed the localized failure notice.
      }
    }

    switch (action) {
      case 'open':
        await _openRosterRoom(entry);
      case 'members':
        final profiles = {for (final p in snapshot.profiles) p.name: p};
        await showRoomMembersSheet(
          context,
          room: room,
          unavailable: const {},
          round: null,
          profileFor: (member) =>
              member.owner.connectionId == room.authorityGatewayId
              ? profiles[member.owner.profile]
              : null,
          avatarCache: _profileAvatarCache,
          onOpenMember: (member) => _openRoomMember(member.owner.profile),
        );
      case 'rename':
        final name = await _promptRoomName(room.name);
        if (name == null || !mounted) return;
        await mutate(
          (source, room, generation) =>
              source.renameHostedGroup(room, name: name, generation: generation),
        );
      case 'stop':
        if (!await _confirmRoomAction(copy.stopSharedRoom)) return;
        await mutate(
          (source, room, generation) =>
              source.stopHostedGroup(room, generation: generation),
        );
      case 'disband':
        if (!await _confirmRoomAction(copy.disbandSharedRoom)) return;
        await mutate(
          (source, room, generation) =>
              source.disbandHostedGroup(room, generation: generation),
        );
    }
  }

  Future<String?> _promptRoomName(String initial) async {
    final copy = MissionControlCopy.of(context);
    var value = initial;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('roster-room-rename-dialog'),
        title: Text(copy.renameSharedRoom),
        content: TextFormField(
          key: const ValueKey('roster-room-rename-field'),
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
            key: const ValueKey('roster-room-rename-save'),
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

  Future<bool> _confirmRoomAction(String title) async {
    final copy = MissionControlCopy.of(context);
    final confirmed = await showHermesDialog<bool>(
      context: context,
      title: title,
      actions: [
        HermesDialogAction(
          label: copy.cancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('roster-room-confirm'),
          label: copy.confirm,
          value: true,
        ),
      ],
    );
    return mounted && confirmed == true;
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
      final lease = SharedGatewayPool.instance.acquire(connection);
      final client = lease.client;
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
      finally { lease.release(); }
    }
    return result;
  }

  Future<void> _attachRoomPeers(HostedGroupRoom room, List<_RoomPeerCandidate> peers) async {
    final home = _profileAssetsGateway;
    if (home is! BotRoomLinkGateway || widget.connection.readOnly) return;
    final failed = <_RoomPeerCandidate>[];
    for (final peer in peers) {
      final lease = SharedGatewayPool.instance.acquire(peer.connection);
      final client = lease.client;
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
      finally { lease.release(); }
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
        title: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Column(
            key: const ValueKey('mission-title'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                copy.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              if (_selectedOrganization case final organization?)
                Text(
                  organization.name,
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
        actions: _headerActions(copy),
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

  /// Header actions (spec 070 S1): round search and round "New" button
  /// (New bot / New room / task board + roster management) — no floating
  /// action button, so nothing competes with the dock.
  List<Widget> _headerActions(MissionControlCopy copy) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final round = IconButton.styleFrom(
      backgroundColor: colors.surfaceVariant.withValues(alpha: 0.44),
      minimumSize: const Size.square(48),
      shape: const CircleBorder(),
    );
    return [
      if (_refreshing)
        const Padding(
          padding: EdgeInsets.all(14),
          child: SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ValueListenableBuilder<bool>(
          valueListenable: _rosterSearchOpen,
          builder: (context, open, _) => Padding(
            padding: const EdgeInsetsDirectional.only(end: 6),
            child: IconButton(
              key: const ValueKey('roster-search'),
              tooltip: strings.rosterSearch,
              style: round,
              icon: Icon(
                open ? Icons.close_rounded : Icons.search_rounded,
                size: 21,
              ),
              onPressed: () => _rosterSearchOpen.value = !open,
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsetsDirectional.only(end: 10),
        child: IconButton(
          key: const ValueKey('mission-create-agent'),
          tooltip: strings.rosterNew,
          style: round,
          icon: const Icon(Icons.add_rounded, size: 22),
          onPressed: _hasNewMenu ? () => unawaited(_showNewMenu()) : null,
        ),
      ),
    ];
  }

  bool get _canCreateBot =>
      !widget.connection.readOnly &&
      _snapshot?.profilesCapability == MissionCapabilityState.available;

  bool get _canManageSections =>
      !widget.connection.readOnly && _botProfileGateway != null;

  bool get _hasNewMenu =>
      _canCreateBot || _canCreateHostedRoom || _canManageSections ||
      _snapshot != null;

  Future<void> _showNewMenu() async {
    final strings = Strings.of(context);
    final profiles = _snapshot?.profiles ?? const <AgentProfile>[];
    final sections = <String, String>{};
    for (final profile in profiles) {
      final id = profile.botSectionId;
      final name = profile.botSectionName;
      if (id != null && name != null) sections.putIfAbsent(id, () => name);
    }
    final choice = await showHermesFloatingSurface<String>(
      context: context,
      surfaceKey: const ValueKey('mission-create-chooser'),
      maxWidth: 420,
      builder: (sheetContext) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (_canCreateBot)
            ListTile(
              key: const ValueKey('mission-create-chooser-bot'),
              leading: const Icon(Icons.smart_toy_outlined),
              title: Text(strings.missionCreateBotLabel),
              onTap: () => Navigator.pop(sheetContext, 'bot'),
            ),
          if (_canCreateHostedRoom)
            ListTile(
              key: const ValueKey('mission-create-chooser-room'),
              leading: const Icon(Icons.groups_2_outlined),
              title: Text(strings.missionCreateRoomLabel),
              onTap: () => Navigator.pop(sheetContext, 'room'),
            ),
          if (_canManageSections) ...[
            const Divider(height: 1),
            ListTile(
              key: const ValueKey('mission-create-chooser-section'),
              leading: const Icon(Icons.create_new_folder_outlined),
              title: Text(strings.botSectionNew),
              onTap: () => Navigator.pop(sheetContext, 'section'),
            ),
            for (final entry in sections.entries)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(entry.value),
                trailing: const Icon(Icons.more_horiz),
                onTap: () =>
                    Navigator.pop(sheetContext, 'section:${entry.key}'),
              ),
          ],
          ListTile(
            leading: const Icon(Icons.forum_outlined),
            title: Text(strings.botManageRooms),
            onTap: () => Navigator.pop(sheetContext, 'rooms'),
          ),
          ListTile(
            key: const ValueKey('mission-create-chooser-board'),
            leading: const Icon(Icons.view_kanban_outlined),
            title: Text(strings.missionTaskBoardLabel),
            onTap: () => Navigator.pop(sheetContext, 'board'),
          ),
          ListTile(
            key: const ValueKey('mission-create-chooser-workspaces'),
            leading: const Icon(Icons.hub_outlined),
            title: Text(MissionControlCopy.of(sheetContext).workspaces),
            subtitle: _selectedOrganization == null
                ? null
                : Text(_selectedOrganization!.name),
            onTap: () => Navigator.pop(sheetContext, 'workspaces'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'bot':
        await _createAgentFromMission();
      case 'room':
        await _createHostedRoom();
      case 'section':
        await _moveBotToSection();
      case 'rooms':
        await _manageBotRooms();
      case 'board':
        await _openTasks();
      case 'workspaces':
        await _showWorkspaceSelector();
      default:
        if (choice.startsWith('section:')) {
          final id = choice.substring(8);
          await _sectionMenu(id, sections[id] ?? '');
        }
    }
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
    return {
      // "Inicio" saca de Bots al dashboard general: el catálogo de Bots lo
      // incluye por defecto (antes no había forma de volver a Inicio desde
      // aquí, bug confirmado en dispositivo real).
      DockItemId.home: DockItemAction(
        onTap: () => Navigator.of(context).popUntil((r) => r.isFirst),
      ),
      DockItemId.bots: DockItemAction(
        onTap: () {},
        selected: true,
        semanticsKey: const ValueKey('mission-destination-bots'),
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
          child: _BotsTab(
            prefs: widget.connManager.prefs,
            connectionId: widget.connection.id,
            snapshot: snapshot,
            projection: projection,
            copy: copy,
            avatarCache: _profileAvatarCache,
            searchOpen: _rosterSearchOpen,
            onOpenChat: (agent) => unawaited(_openChat(agent)),
            onBotActions: (entry) => unawaited(_openRosterActions(entry)),
            onOpenRoom: (entry) => unawaited(_openRosterRoom(entry)),
            onRoomActions: (entry) => unawaited(_openRoomActions(entry)),
            otherConnections: widget.connManager
                .getConnections()
                .where((c) => c.id != widget.connection.id)
                .toList(),
            remoteBotLoader: widget.remoteBotLoader,
            onRemoteOpen: _openRemoteBot,
            onRemoteDetails: _remoteBotDetails,
            onSectionMenu: _canManageSections ? _sectionMenu : null,
            onAttention:
                projection.approvals.isNotEmpty ||
                    projection.blockedCount > 0
                ? () => unawaited(_openAttention())
                : null,
            attentionSummary: copy.attentionSummary(
              projection.approvals.length,
              projection.blockedCount,
            ),
            onCreateAgent: _canCreateBot ? _createAgentFromMission : null,
            onRefresh: () => _load(refresh: true),
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

/// Bots roster (spec 070 S1) over [BotsRosterView]: server-sourced rows for
/// bots (presence, canonical preview/time, `ui_meta` pins/sections/hidden)
/// and rooms (hosted `groups.*` plus read-only Desktop projection).
class _BotsTab extends StatefulWidget {
  final SharedPreferences prefs;
  final String connectionId;
  final MissionBackendSnapshot snapshot;
  final MissionProjection projection;
  final MissionControlCopy copy;
  final MissionProfileAvatarCache? avatarCache;
  final ValueNotifier<bool> searchOpen;
  final ValueChanged<MissionAgent> onOpenChat;
  final ValueChanged<BotRosterEntry> onBotActions;
  final ValueChanged<RoomRosterEntry> onOpenRoom;
  final ValueChanged<RoomRosterEntry>? onRoomActions;
  final List<SavedConnection> otherConnections;
  final RemoteBotLoader? remoteBotLoader;
  final void Function(SavedConnection, AgentProfile) onRemoteOpen;
  final void Function(SavedConnection, AgentProfile) onRemoteDetails;
  final void Function(String sectionId, String name)? onSectionMenu;
  final VoidCallback? onAttention;
  final String? attentionSummary;
  final VoidCallback? onCreateAgent;
  final Future<void> Function() onRefresh;

  const _BotsTab({
    required this.prefs,
    required this.connectionId,
    required this.snapshot,
    required this.projection,
    required this.copy,
    required this.avatarCache,
    required this.searchOpen,
    required this.onOpenChat,
    required this.onBotActions,
    required this.onOpenRoom,
    this.onRoomActions,
    required this.otherConnections,
    required this.onRemoteOpen,
    required this.onRemoteDetails,
    required this.onRefresh,
    this.remoteBotLoader,
    this.onSectionMenu,
    this.onAttention,
    this.attentionSummary,
    this.onCreateAgent,
  });

  @override
  State<_BotsTab> createState() => _BotsTabState();
}

class _BotsTabState extends State<_BotsTab> {
  (HostedGroupsSnapshot, AttentionSummary)? _attentionCache;

  AttentionSummary get _attention {
    final groups = widget.snapshot.hostedGroups;
    final cached = _attentionCache;
    if (cached != null && identical(cached.$1, groups)) return cached.$2;
    final summary = AttentionSummary.fromSnapshot(groups);
    _attentionCache = (groups, summary);
    return summary;
  }

  List<BotRosterEntry> _bots() {
    final groups = widget.snapshot.hostedGroups;
    final attention = _attention;
    final now = DateTime.now();
    return [
      for (final agent in widget.projection.agents)
        BotRosterEntry.from(
          agent: agent,
          live: BotLiveStatus.forAgent(agent: agent, now: now, rooms: groups),
          hasAttention: attention
              .forProfile(agent.profile.name, groups)
              .isNotEmpty,
          now: now,
        ),
    ];
  }

  List<RoomRosterEntry> _rooms() {
    final snapshot = widget.snapshot;
    final hosted = snapshot.hostedGroups;
    final defaults = snapshot.profiles.where(
      (p) => p.isDefault || p.name == 'default',
    );
    return RoomRosterEntry.build(
      hosted: hosted,
      attention: _attention,
      projection: defaults.isEmpty
          ? DesktopProjectionRooms.empty
          : DesktopProjectionRooms.parse(
              defaults.first.groupsProjection,
              hostedRoomIds: {for (final r in hosted.rooms) r.roomId},
            ),
      localProfiles: {for (final p in snapshot.profiles) p.name: p},
      identityFor: snapshot.roomIdentity,
    );
  }

  @override
  Widget build(BuildContext context) {
    final copy = widget.copy;
    final unsupported =
        widget.snapshot.profilesCapability ==
        MissionCapabilityState.unsupported;
    return BotsRosterView(
      bots: unsupported ? const [] : _bots(),
      rooms: _rooms(),
      avatarCache: widget.avatarCache,
      searchOpen: widget.searchOpen,
      prefs: widget.prefs,
      connectionId: widget.connectionId,
      onOpenBot: (entry) => widget.onOpenChat(entry.agent),
      onBotActions: widget.onBotActions,
      onOpenRoom: widget.onOpenRoom,
      onRoomActions: widget.onRoomActions,
      onSectionMenu: widget.onSectionMenu,
      onAttention: widget.onAttention,
      attentionSummary: widget.attentionSummary,
      onRefresh: widget.onRefresh,
      header: [
        if (unsupported) _MessageCard(text: copy.profilesUnavailable),
      ],
      emptyState: _LoungeEmptyState(
        icon: Icons.smart_toy_outlined,
        message: copy.noBots,
        actionLabel: copy.newAgent,
        onAction: widget.onCreateAgent,
      ),
      footer: [
        if (widget.otherConnections.isNotEmpty)
          RemoteBotRoster(
            connections: widget.otherConnections,
            prefs: widget.prefs,
            query: '',
            showHidden: false,
            refreshedAt: widget.snapshot.loadedAt,
            onOpen: widget.onRemoteOpen,
            onDetails: widget.onRemoteDetails,
            loader: widget.remoteBotLoader,
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

/// Hosted room workspace: delegates to the spec 070 [RoomScreen] (group
/// layout, round panel, approvals, activity, shared composer). Mission
/// Control keeps owning the authority checks for mutations (`onSend`,
/// `onRename`, `onStop`, `onDisband`) and the incremental room read
/// (`onRead`: `groups.state` + driver status + `RoomLogCursor`).
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

  /// Local profiles of this connection by name: a member owned by the
  /// room's authority that matches one is one of your own Bots (real face,
  /// profile link). Federated members never resolve here.
  final Map<String, AgentProfile> localProfiles;

  /// See `_RoomsTab.onOpenMember`.
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

class _HostedRoomWorkspaceState extends State<_HostedRoomWorkspace> {
  SavedConnection? _connection;
  VoiceRoomDictation? _dictation;
  RoomLocalPrefs? _prefs;
  bool _resolved = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_resolved) return;
    _resolved = true;
    // The room route lives under the app Navigator, not under Mission
    // Control: resolve the connection and voice engine from the app.
    final app = context.findAncestorStateOfType<HermesAppState>();
    if (app != null) {
      for (final connection in app.connManager.getConnections()) {
        if (connection.id == widget.draftScope.connectionId) {
          _connection = connection;
          break;
        }
      }
      _prefs = SharedPreferencesRoomPrefs(app.connManager.prefs);
      final connection = _connection;
      if (connection != null && !connection.readOnly && widget.canSend) {
        _dictation = VoiceRoomDictation(
          voice: app.voice,
          connection: connection,
          profile: widget.draftScope.profile,
        );
      }
    }
  }

  @override
  void dispose() {
    _dictation?.dispose();
    super.dispose();
  }

  AgentProfile? _profileFor(HostedGroupMember member) =>
      member.owner.connectionId == widget.room.authorityGatewayId
      ? widget.localProfiles[member.owner.profile]
      : null;

  @override
  Widget build(BuildContext context) {
    final connection = _connection;
    final read = widget.onRead;
    final identity = widget.identityFor(widget.room);
    final scope = widget.draftScope;
    final writable = connection != null && !connection.readOnly;
    return RoomScreen(
      key: const ValueKey('mission-hosted-room-workspace'),
      room: widget.room,
      log: widget.log,
      gateway: CallbackRoomGateway(
        onRead:
            read ?? (_) => Future.error(StateError('room refresh unavailable')),
        onSend: widget.onSend,
        onRename: widget.onRename,
        onStop: widget.onStop,
        onDisband: widget.onDisband,
        onApprove: writable
            ? (action, choice) => pooledRoomApprove(
                connection,
                roomId: widget.room.roomId,
                action: action,
                choice: choice,
              )
            : null,
      ),
      capabilities: RoomCapabilities(
        canSend: widget.canSend,
        canRename: widget.canRename,
        canStop: widget.canStop,
        canDisband: widget.canDisband,
        // `groups.approve` is checked against live capabilities on the
        // pooled socket; the server matches the exact `request_id`.
        canApprove: writable && widget.canSend,
        // `groups.retry` stays retired in Console until upstream binds it
        // to revision/log position (docs/hosted_identity_transition_matrix).
        canRetry: false,
      ),
      profileFor: _profileFor,
      avatarCache: widget.avatarCache,
      prefs: _prefs ?? MemoryRoomPrefs(),
      drafts: ChatDraftRoomStore(
        store: scope.store,
        connectionId: scope.connectionId,
        profile: scope.profile,
        sessionId:
            'mob-room-${base64Url.encode(utf8.encode(jsonEncode([widget.room.authorityGatewayId, widget.room.roomId])))}',
      ),
      uploader: writable ? DashboardRoomAttachmentUploader(connection) : null,
      attachmentActions: connection == null
          ? null
          : DashboardRoomAttachmentActions(
              connection: connection,
              profile: scope.profile,
            ),
      dictation: _dictation,
      displayName: identity?.name,
      roomAvatar: identity?.image == null
          ? null
          : RoomMirrorAvatar(
              image: identity!.image!,
              size: 28,
              fallback: const Icon(Icons.groups_outlined, size: 28),
            ),
      onOpenMember: (member) {
        if (_profileFor(member) != null) {
          widget.onOpenMember(member.owner.profile);
        }
      },
    );
  }
}

final class _RoomsAreaCopy {
  final bool _english;

  const _RoomsAreaCopy._(this._english);

  factory _RoomsAreaCopy.of(BuildContext context) => _RoomsAreaCopy._(
    Localizations.localeOf(context).languageCode.toLowerCase() == 'en',
  );

  String get removeMember => _english ? 'Remove' : 'Quitar';
  String get noMembersChosen => _english
      ? 'Tap a bot to add it to the room.'
      : 'Toca un bot para añadirlo a la sala.';
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

/// A room message was accepted: wake the background listener now so the
/// round's Live Update and its finished card do not wait for the idle tick.
Future<T> _kickRoomWatchAfter<T>(Future<T> send) async {
  final result = await send;
  unawaited(BackgroundListener.kickRoomWatch());
  return result;
}
