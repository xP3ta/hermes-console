import '../bots/data/room_log_cursor.dart';
import 'bot_roster_store.dart';
import 'dart:async';
import 'dart:math';

import '../models/agent_profile.dart';
import '../models/desktop_active_session.dart';
import '../models/hosted_groups.dart';
import '../models/kanban.dart';
import '../models/mission_control.dart';
import 'connection_manager.dart';
import 'kanban_client.dart';
import 'shared_gateway_pool.dart';
import 'tui_gateway_client.dart';

typedef MissionProfilesLoader = Future<List<AgentProfile>> Function();
typedef MissionSessionsLoader = Future<List<Session>> Function();
typedef MissionActiveSessionsLoader =
    Future<DesktopActiveSessionList> Function();
typedef MissionBoardLoader = Future<KanbanBoard> Function();
typedef MissionKanbanEventsLoader = Stream<KanbanEvent> Function(int since);
typedef MissionDashboardGet =
    Future<Map<String, dynamic>> Function(String endpoint);
typedef MissionProfileAvatarLoader =
    Future<AgentProfileAvatar?> Function(String profileName);

typedef MissionGroupsList =
    Future<List<HostedGroupRoom>> Function({required int generation});
typedef MissionGroupsState =
    Future<HostedGroupRoom> Function(String roomId, {required int generation});
typedef MissionGroupsLog =
    Future<HostedGroupLogPage> Function(
      String roomId, {
      required int generation,
    });
typedef MissionGroupsCreate =
    Future<HostedGroupRoom> Function({
      required String name,
      required List<HostedGroupCreateMember> members,
      required int generation,
    });
typedef MissionGroupsSend =
    Future<HostedGroupLogPage> Function(
      String roomId, {
      required String text,
      required HostedGroupSendAttempt attempt,
      required int generation,
    });
typedef MissionGroupsRename =
    Future<HostedGroupRoom> Function(
      String roomId, {
      required String name,
      required int generation,
    });
typedef MissionGroupsRoomMutation =
    Future<HostedGroupRoom> Function(String roomId, {required int generation});
typedef MissionGroupsRetry =
    Future<HostedGroupRoom> Function(
      String roomId, {
      required String taskId,
      required int generation,
    });

abstract interface class MissionHostedGroupsGateway {
  factory MissionHostedGroupsGateway.callbacks({
    required Future<GroupsCapabilities> Function() capabilities,
    required MissionGroupsList list,
    required MissionGroupsState state,
    required MissionGroupsLog log,
    MissionGroupsCreate? create,
    MissionGroupsSend? send,
    MissionGroupsRename? rename,
    MissionGroupsRoomMutation? stop,
    MissionGroupsRoomMutation? disband,
    MissionGroupsRetry? retry,
  }) = _CallbackMissionHostedGroupsGateway;

  Future<GroupsCapabilities> capabilities();
  Future<List<HostedGroupRoom>> list({required int generation});
  Future<HostedGroupRoom> state(String roomId, {required int generation});
  Future<HostedGroupLogPage> log(String roomId, {required int generation});
  Future<HostedGroupRoom> create({
    required String name,
    required List<HostedGroupCreateMember> members,
    required int generation,
  });
  Future<HostedGroupLogPage> send(
    String roomId, {
    required String text,
    required HostedGroupSendAttempt attempt,
    required int generation,
  });
  Future<HostedGroupRoom> rename(
    String roomId, {
    required String name,
    required int generation,
  });
  Future<HostedGroupRoom> stop(String roomId, {required int generation});
  Future<HostedGroupRoom> disband(String roomId, {required int generation});
  Future<HostedGroupRoom> retry(
    String roomId, {
    required String taskId,
    required int generation,
  });
}

/// Optional incremental surface (spec 070 T203/T204): `groups.state` with the
/// server `driver_status`, and `groups.log` windows by `since_seq` so a
/// refresh reads only the delta instead of the whole transcript.
abstract interface class MissionHostedGroupsIncrementalGateway {
  Future<({HostedGroupRoom room, RoomDriverStatus? driverStatus})>
  stateWithDriver(String roomId, {required int generation});

  Future<HostedGroupLogPage> logSince(
    String roomId, {
    required int sinceSeq,
    required int limit,
    required int generation,
  });
}

final class _CallbackMissionHostedGroupsGateway
    implements MissionHostedGroupsGateway {
  final Future<GroupsCapabilities> Function() _capabilities;
  final MissionGroupsList _list;
  final MissionGroupsState _state;
  final MissionGroupsLog _log;
  final MissionGroupsCreate? _create;
  final MissionGroupsSend? _send;
  final MissionGroupsRename? _rename;
  final MissionGroupsRoomMutation? _stop;
  final MissionGroupsRoomMutation? _disband;

  const _CallbackMissionHostedGroupsGateway({
    required Future<GroupsCapabilities> Function() capabilities,
    required MissionGroupsList list,
    required MissionGroupsState state,
    required MissionGroupsLog log,
    MissionGroupsCreate? create,
    MissionGroupsSend? send,
    MissionGroupsRename? rename,
    MissionGroupsRoomMutation? stop,
    MissionGroupsRoomMutation? disband,
    MissionGroupsRetry? retry,
  }) : // The public redirecting factory fixes these parameter names.
       // ignore: prefer_initializing_formals
       _capabilities = capabilities,
       // ignore: prefer_initializing_formals
       _list = list,
       // ignore: prefer_initializing_formals
       _state = state,
       // ignore: prefer_initializing_formals
       _log = log,
       // ignore: prefer_initializing_formals
       _create = create,
       // ignore: prefer_initializing_formals
       _send = send,
       // ignore: prefer_initializing_formals
       _rename = rename,
       // ignore: prefer_initializing_formals
       _stop = stop,
       // ignore: prefer_initializing_formals
       _disband = disband;

  Never _unsupported() =>
      throw StateError('unsupported hosted group operation');

  @override
  Future<GroupsCapabilities> capabilities() => _capabilities();
  @override
  Future<List<HostedGroupRoom>> list({required int generation}) =>
      _list(generation: generation);
  @override
  Future<HostedGroupRoom> state(String roomId, {required int generation}) =>
      _state(roomId, generation: generation);
  @override
  Future<HostedGroupLogPage> log(String roomId, {required int generation}) =>
      _log(roomId, generation: generation);
  @override
  Future<HostedGroupRoom> create({
    required String name,
    required List<HostedGroupCreateMember> members,
    required int generation,
  }) =>
      _create?.call(name: name, members: members, generation: generation) ??
      _unsupported();
  @override
  Future<HostedGroupLogPage> send(
    String roomId, {
    required String text,
    required HostedGroupSendAttempt attempt,
    required int generation,
  }) =>
      _send?.call(
        roomId,
        text: text,
        attempt: attempt,
        generation: generation,
      ) ??
      _unsupported();
  @override
  Future<HostedGroupRoom> rename(
    String roomId, {
    required String name,
    required int generation,
  }) =>
      _rename?.call(roomId, name: name, generation: generation) ??
      _unsupported();
  @override
  Future<HostedGroupRoom> stop(String roomId, {required int generation}) =>
      _stop?.call(roomId, generation: generation) ?? _unsupported();
  @override
  Future<HostedGroupRoom> disband(String roomId, {required int generation}) =>
      _disband?.call(roomId, generation: generation) ?? _unsupported();
  @override
  Future<HostedGroupRoom> retry(
    String roomId, {
    required String taskId,
    required int generation,
  }) => throw UnsupportedError(
    'groups.retry is retired until upstream provides atomic retry authority',
  );
}

final class _TuiMissionHostedGroupsGateway
    implements
        MissionHostedGroupsGateway,
        MissionHostedGroupsIncrementalGateway {
  final TuiGatewayClient client;

  const _TuiMissionHostedGroupsGateway(this.client);

  String _nonce(String prefix) {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return '$prefix-${bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join()}';
  }

  @override
  Future<GroupsCapabilities> capabilities() => client.groupCapabilities();
  @override
  Future<List<HostedGroupRoom>> list({required int generation}) =>
      client.listGroups(generation: generation);
  @override
  Future<HostedGroupRoom> state(String roomId, {required int generation}) =>
      client.groupState(roomId, generation: generation);
  @override
  Future<HostedGroupLogPage> log(String roomId, {required int generation}) =>
      client.groupLogComplete(roomId, generation: generation);
  @override
  Future<({HostedGroupRoom room, RoomDriverStatus? driverStatus})>
  stateWithDriver(String roomId, {required int generation}) =>
      client.groupStateWithDriver(roomId, generation: generation);
  @override
  Future<HostedGroupLogPage> logSince(
    String roomId, {
    required int sinceSeq,
    required int limit,
    required int generation,
  }) => client.groupLog(
    roomId,
    sinceSeq: sinceSeq,
    limit: limit,
    generation: generation,
  );
  @override
  Future<HostedGroupRoom> create({
    required String name,
    required List<HostedGroupCreateMember> members,
    required int generation,
  }) => client.createGroup(
    roomId: _nonce('room'),
    name: name,
    members: [
      for (final member in members) member.toWire(memberId: _nonce('member')),
    ],
    generation: generation,
  );
  @override
  Future<HostedGroupLogPage> send(
    String roomId, {
    required String text,
    required HostedGroupSendAttempt attempt,
    required int generation,
  }) => client.sendGroupText(
    roomId: roomId,
    text: text,
    threadId: attempt.threadId,
    eventId: attempt.clientEventId,
    generation: generation,
  );
  @override
  Future<HostedGroupRoom> rename(
    String roomId, {
    required String name,
    required int generation,
  }) => client.renameGroup(
    roomId: roomId,
    eventId: _nonce('event'),
    name: name,
    generation: generation,
  );
  @override
  Future<HostedGroupRoom> stop(String roomId, {required int generation}) =>
      client.stopGroup(
        roomId: roomId,
        cancelId: _nonce('cancel'),
        generation: generation,
      );
  @override
  Future<HostedGroupRoom> disband(String roomId, {required int generation}) =>
      client.disbandGroup(
        roomId: roomId,
        cancelId: _nonce('cancel'),
        generation: generation,
      );
  @override
  Future<HostedGroupRoom> retry(
    String roomId, {
    required String taskId,
    required int generation,
  }) => throw UnsupportedError(
    'groups.retry is retired until upstream provides atomic retry authority',
  );
}

Future<List<AgentProfile>> loadMissionControlProfiles({
  required MissionProfilesLoader desktopLoader,
  required MissionProfilesLoader legacyDashboardLoader,
}) async {
  try {
    return await desktopLoader();
  } on TuiGatewayRpcError catch (error) {
    if (error.code != -32601 && error.code != 404 && error.code != 405) {
      rethrow;
    }
    return legacyDashboardLoader();
  }
}

/// [loadMissionControlProfiles] published to [registry], the roster every
/// screen shares. Only the Gateway read asks for session projections, so
/// only it is authoritative for them; the legacy Dashboard list is not.
Future<List<AgentProfile>> loadSharedMissionProfiles({
  required BotRosterRegistry registry,
  required SavedConnection connection,
  required MissionProfilesLoader desktopLoader,
  required MissionProfilesLoader legacyDashboardLoader,
}) async {
  final ticket = registry.beginRead(connection.id);
  var withSessions = false;
  var legacy = false;
  final List<AgentProfile> profiles;
  try {
    profiles = await loadMissionControlProfiles(
      desktopLoader: () async {
        final profiles = await desktopLoader();
        withSessions = true;
        return profiles;
      },
      legacyDashboardLoader: () {
        legacy = true;
        return legacyDashboardLoader();
      },
    );
  } catch (error) {
    // The Dashboard is asked only once `profiles.list` proved unsupported;
    // if it lacks the list too, this server has no roster to show.
    if (legacy && BotRosterRegistry.isUnsupportedRead(error)) {
      registry.unsupported(connection.id, ticket: ticket);
    }
    rethrow;
  }
  // Shared with every screen; dropped if a newer roster already landed.
  registry.publish(
    connection.id,
    connection.label,
    profiles,
    ticket: ticket,
    sessions: withSessions,
  );
  return profiles;
}

/// Loads the same aggregate, profile-owned session surface used by Hermes
/// Desktop. Legacy Gateways are consulted only when the aggregate route is
/// structurally unsupported; auth, network and malformed responses fail
/// closed so a partial default-profile list cannot masquerade as complete.
Future<List<Session>> loadMissionControlSessions({
  required MissionDashboardGet dashboardGet,
  required MissionSessionsLoader legacyGatewayLoader,
}) async {
  final query = Uri(
    queryParameters: const {
      'profile': 'all',
      'limit': '200',
      'offset': '0',
      'min_messages': '0',
      'archived': 'exclude',
      'order': 'recent',
      'full': '1',
      'include_children': 'true',
    },
  ).query;
  late final Map<String, dynamic> data;
  try {
    data = await dashboardGet('profiles/sessions?$query');
  } on DashboardHttpException catch (error) {
    if (error.statusCode != 404 && error.statusCode != 405) rethrow;
    return legacyGatewayLoader();
  }
  final errors = data['errors'];
  final hasPartialErrors = switch (errors) {
    null => false,
    List value => value.isNotEmpty,
    Map value => value.isNotEmpty,
    String value => value.trim().isNotEmpty,
    _ => true,
  };
  if (hasPartialErrors) {
    throw const FormatException('Partial aggregate session response');
  }
  final raw = data['sessions'] ?? data['data'];
  if (raw is! List) {
    throw const FormatException('Malformed aggregate session response');
  }
  final sessions = <Session>[];
  for (final value in raw) {
    final session = Session.tryParse(value);
    if (session == null) {
      throw const FormatException('Malformed aggregate session row');
    }
    if ((session.profile ?? '').trim().isEmpty) {
      throw const FormatException('Aggregate session owner is missing');
    }
    if (!session.id.startsWith('mob-aux-')) sessions.add(session);
  }
  return List<Session>.unmodifiable(sessions);
}

abstract interface class MissionControlDataSource {
  Future<MissionBackendSnapshot> load();
  Stream<KanbanEvent>? watchKanban({required int since});
  void close();
}

/// Extensión opcional para identidades visuales de Bot Mode/Hermes Desktop.
/// Los fakes y Gateways antiguos pueden implementar sólo el snapshot base.
abstract interface class MissionProfileAvatarDataSource {
  Future<AgentProfileAvatar?> loadProfileAvatar(String profileName);
}

abstract interface class MissionHostedGroupsDataSource {
  Future<HostedGroupRoom> createHostedGroup({
    required String name,
    required List<HostedGroupCreateMember> members,
    required int generation,
  });
  Future<HostedGroupWorkspaceReadback> sendHostedGroupText(
    HostedGroupRoom room, {
    required String text,
    required HostedGroupSendAttempt attempt,
    required int generation,
  });
  Future<HostedGroupWorkspaceReadback> renameHostedGroup(
    HostedGroupRoom room, {
    required String name,
    required int generation,
  });
  Future<HostedGroupWorkspaceReadback> stopHostedGroup(
    HostedGroupRoom room, {
    required int generation,
  });
  Future<HostedGroupWorkspaceReadback> disbandHostedGroup(
    HostedGroupRoom room, {
    required int generation,
  });
}

/// Optional room-only refresh for replies arriving after groups.send's ack.
abstract interface class MissionHostedGroupsReadDataSource {
  Future<HostedGroupWorkspaceReadback> readHostedGroup(
    HostedGroupRoom room, {
    required int generation,
  });
}

/// The `groups.capabilities` live on the socket right now. An open room
/// reads it before each read so a reconnect (a new socket generation) never
/// leaves the room bound to the generation it was opened with.
abstract interface class MissionHostedGroupsCapabilitySource {
  Future<GroupsCapabilities> hostedGroupCapabilities();
}

/// Profiles and sessions read on their own, for a roster-only refresh.
final class MissionRosterRead {
  final List<AgentProfile> profiles;
  final List<Session> sessions;
  final MissionCapabilityState profilesCapability;
  final MissionCapabilityState sessionsCapability;
  final Object? profilesError;
  final Object? sessionsError;

  /// `session.active_list` read together with the roster.
  final List<DesktopActiveSession> activeSessions;
  final DateTime? activeSessionsObservedAt;

  /// See [MissionBackendSnapshot.activeSessionsAuthoritative].
  final bool activeSessionsAuthoritative;

  const MissionRosterRead({
    required this.profiles,
    required this.sessions,
    required this.profilesCapability,
    required this.sessionsCapability,
    this.profilesError,
    this.sessionsError,
    this.activeSessions = const [],
    this.activeSessionsObservedAt,
    this.activeSessionsAuthoritative = true,
  });
}

/// Optional partial refresh driven by the Gateway's change events.
///
/// While [liveChangesHealthy] holds, Mission Control can skip its periodic
/// full reload: `sessions.changed` refreshes only the roster
/// ([loadRoster]) and rooms are re-read only when `groups.list` shows they
/// moved or their last driver evidence was active ([refreshHostedGroups]).
abstract interface class MissionLiveRefreshDataSource {
  /// Global Gateway events (`sessions.changed`…); errors when the socket
  /// drops. Null when this source has no live channel.
  Stream<TuiGatewayEvent>? watchLiveChanges();

  /// The socket is up and the backend announced `change_events`.
  bool get liveChangesHealthy;

  Future<MissionRosterRead> loadRoster();

  /// [previous] with only the rooms that changed (or were active) re-read.
  /// Throws when the capability generation moved: the caller must reload.
  Future<HostedGroupsSnapshot> refreshHostedGroups(
    HostedGroupsSnapshot previous,
  );
}

/// One `session.active_list` read: its rows and whether it was an answer.
final class _ActiveSessionsRead {
  const _ActiveSessionsRead(this.rows, this.authoritative);

  final List<DesktopActiveSession> rows;
  final bool authoritative;
}

final class MissionControlRepository
    implements
        MissionControlDataSource,
        MissionProfileAvatarDataSource,
        MissionHostedGroupsDataSource,
        MissionHostedGroupsReadDataSource,
        MissionHostedGroupsCapabilitySource,
        MissionLiveRefreshDataSource {
  final MissionProfilesLoader profilesLoader;
  final MissionSessionsLoader sessionsLoader;
  final MissionBoardLoader boardLoader;

  /// `session.active_list` on the shared Desktop socket; read together with
  /// the roster, never on a timer of its own. Null on legacy sources.
  final MissionActiveSessionsLoader? activeSessionsLoader;
  final MissionKanbanEventsLoader? kanbanEventsLoader;
  final MissionProfileAvatarLoader? profileAvatarLoader;
  final MissionHostedGroupsGateway? hostedGroupsGateway;
  final void Function()? onClose;

  /// Global Gateway events and their health (see
  /// [MissionLiveRefreshDataSource]); both null without a live channel.
  final Stream<TuiGatewayEvent> Function()? liveChanges;
  final bool Function()? liveChangesAvailable;
  bool _closed = false;
  final Map<String, RoomLogCursor> _logCursors = {};
  final Map<String, HostedGroupLogPage> _logSeeds = {};
  int? _logCursorGeneration;

  /// Rooms read at once: enough to hide per-room latency, few enough not to
  /// flood the one shared Gateway socket.
  static const roomReadConcurrency = 4;

  MissionControlRepository({
    required this.profilesLoader,
    required this.sessionsLoader,
    required this.boardLoader,
    this.activeSessionsLoader,
    this.kanbanEventsLoader,
    this.profileAvatarLoader,
    this.hostedGroupsGateway,
    this.onClose,
    this.liveChanges,
    this.liveChangesAvailable,
  });

  factory MissionControlRepository.forConnection(SavedConnection connection) {
    final dashboard = DashboardClient.lazy(connection);
    final gateway = ApiClient(
      baseUrl: connection.baseUrl,
      apiKey: connection.apiKey,
      connectionId: connection.id,
    );
    final kanban = KanbanClient(connection, dashboardClient: dashboard);
    // One pooled Desktop socket per connection, shared with every Bot Mode
    // surface (spec 070 T202); released (close frame) with the last lease.
    final lease = SharedGatewayPool.instance.acquire(connection);
    final desktop = lease.client;
    return MissionControlRepository(
      profilesLoader: () => loadSharedMissionProfiles(
        registry: BotRosterRegistry.shared,
        connection: connection,
        // One profiles.list snapshot now carries Desktop's last/preferred
        // session projections and hidden worker liveness. Older Gateways
        // omit those optional fields and keep returning the same roster.
        desktopLoader: () => desktop.listProfiles(includeSessions: true),
        legacyDashboardLoader: dashboard.getProfiles,
      ),
      sessionsLoader: () => loadMissionControlSessions(
        dashboardGet: dashboard.apiGet,
        legacyGatewayLoader: () => gateway.getSessions(includeChildren: true),
      ),
      boardLoader: kanban.getCurrentBoard,
      // The same pooled socket: no extra connection for the live sessions.
      activeSessionsLoader: desktop.listActiveSessions,
      kanbanEventsLoader: (since) => kanban.events(since: since),
      profileAvatarLoader: desktop.profileAvatar,
      hostedGroupsGateway: _TuiMissionHostedGroupsGateway(desktop),
      liveChanges: () => desktop.events,
      liveChangesAvailable: () =>
          desktop.isConnected && desktop.changeEventsAvailable,
      onClose: () {
        lease.release();
        kanban.close();
        gateway.close();
      },
    );
  }

  @override
  Stream<KanbanEvent>? watchKanban({required int since}) {
    if (_closed) throw StateError('MissionControlRepository is closed');
    return kanbanEventsLoader?.call(since);
  }

  @override
  Future<AgentProfileAvatar?> loadProfileAvatar(String profileName) {
    if (_closed) throw StateError('MissionControlRepository is closed');
    final loader = profileAvatarLoader;
    if (loader == null) return Future.value();
    return loader(profileName);
  }

  @override
  Future<MissionBackendSnapshot> load() async {
    if (_closed) throw StateError('MissionControlRepository is closed');
    final activeObservedAt = DateTime.now();
    final results = await Future.wait<Object>([
      _capture(profilesLoader),
      _capture(sessionsLoader),
      _capture(boardLoader),
      _capture(_loadHostedGroups),
      _loadActiveSessions(),
    ]);
    final profilesResult = results[0] as _MissionLoadResult<List<AgentProfile>>;
    final sessionsResult = results[1] as _MissionLoadResult<List<Session>>;
    final boardResult = results[2] as _MissionLoadResult<KanbanBoard>;
    final groupsResult = results[3] as _MissionLoadResult<HostedGroupsSnapshot>;
    final active = results[4] as _ActiveSessionsRead;
    final failures = <String, Object>{
      'profiles': ?profilesResult.error,
      'sessions': ?sessionsResult.error,
      'kanban': ?boardResult.error,
      'hostedGroups': ?groupsResult.error,
    };
    return MissionBackendSnapshot(
      profiles: profilesResult.value ?? const [],
      sessions: sessionsResult.value ?? const [],
      board: boardResult.value,
      profilesCapability: _capability(profilesResult),
      sessionsCapability: _capability(sessionsResult),
      kanbanCapability: _capability(boardResult),
      hostedGroups: groupsResult.value ?? HostedGroupsSnapshot.empty,
      hostedGroupsCapability: hostedGroupsGateway == null
          ? MissionCapabilityState.unsupported
          : groupsResult.value?.capabilities?.hasSharedRoomSurface == false
          ? MissionCapabilityState.unsupported
          : _capability(groupsResult),
      failures: failures,
      loadedAt: DateTime.now(),
      activeSessions: active.rows,
      activeSessionsObservedAt: active.authoritative ? activeObservedAt : null,
      activeSessionsAuthoritative: active.authoritative,
    );
  }

  /// `session.active_list` of the read in progress, never an error of the
  /// read. An answer (even an empty one) and a server that lacks the method
  /// are authoritative; a timeout, a cut socket or any other failure proves
  /// nothing about absence, so the caller keeps what it last confirmed.
  Future<_ActiveSessionsRead> _loadActiveSessions() async {
    final loader = activeSessionsLoader;
    if (loader == null) return const _ActiveSessionsRead([], true);
    try {
      return _ActiveSessionsRead((await loader()).sessions, true);
    } catch (error) {
      // Only the typed «method not found» says the server lacks the method.
      // A 404 in a message, an HTTP status or any other code is a failed read.
      final missing = error is TuiGatewayRpcError && error.code == -32601;
      return _ActiveSessionsRead(const [], missing);
    }
  }

  @override
  Stream<TuiGatewayEvent>? watchLiveChanges() {
    if (_closed) throw StateError('MissionControlRepository is closed');
    return liveChanges?.call();
  }

  @override
  bool get liveChangesHealthy =>
      !_closed &&
      liveChanges != null &&
      (liveChangesAvailable?.call() ?? false);

  @override
  Future<MissionRosterRead> loadRoster() async {
    if (_closed) throw StateError('MissionControlRepository is closed');
    final activeObservedAt = DateTime.now();
    final results = await Future.wait<Object>([
      _capture(profilesLoader),
      _capture(sessionsLoader),
      _loadActiveSessions(),
    ]);
    final profiles = results[0] as _MissionLoadResult<List<AgentProfile>>;
    final sessions = results[1] as _MissionLoadResult<List<Session>>;
    final active = results[2] as _ActiveSessionsRead;
    return MissionRosterRead(
      profiles: profiles.value ?? const [],
      sessions: sessions.value ?? const [],
      profilesCapability: _capability(profiles),
      sessionsCapability: _capability(sessions),
      profilesError: profiles.error,
      sessionsError: sessions.error,
      activeSessions: active.rows,
      activeSessionsObservedAt: active.authoritative ? activeObservedAt : null,
      activeSessionsAuthoritative: active.authoritative,
    );
  }

  /// A room needs `groups.state` unless the list row proves it unchanged
  /// and its last driver evidence was quiet: an active room is always
  /// re-read so a finished turn never keeps showing as working.
  static bool _roomMoved(
    HostedGroupRoom listed,
    HostedGroupRoom? previous,
    RoomDriverStatus? driver,
  ) =>
      previous == null ||
      !listed.latestSeqKnown ||
      !previous.latestSeqKnown ||
      listed.latestSeq != previous.latestSeq ||
      listed.revision != previous.revision ||
      listed.authorityGatewayId != previous.authorityGatewayId ||
      listed.authorityEpoch != previous.authorityEpoch ||
      driver == null ||
      driver.running ||
      driver.working ||
      driver.blocked ||
      driver.needsUser;

  @override
  Future<HostedGroupsSnapshot> refreshHostedGroups(
    HostedGroupsSnapshot previous,
  ) async {
    if (_closed) throw StateError('MissionControlRepository is closed');
    final gateway = hostedGroupsGateway;
    final known = previous.capabilities;
    if (gateway == null || known == null) {
      throw StateError('hosted groups were not loaded');
    }
    final capabilities = await gateway.capabilities();
    if (capabilities.generation != known.generation ||
        !capabilities.hasSharedRoomSurface ||
        previous.rooms.length != previous.logs.length) {
      throw StateError('hosted groups capability changed');
    }
    final listed = await gateway.list(generation: capabilities.generation);
    final previousIndex = {
      for (var i = 0; i < previous.rooms.length; i++)
        previous.rooms[i].roomId: i,
    };
    final stale = <String>[
      for (final room in listed)
        if (_roomMoved(room, switch (previousIndex[room.roomId]) {
          final i? => previous.rooms[i],
          null => null,
        }, previous.driverStatuses[room.roomId]))
          room.roomId,
    ];
    final listedIds = {for (final room in listed) room.roomId};
    _logCursors.removeWhere((roomId, _) => !listedIds.contains(roomId));
    final reads = await _readRooms(
      gateway,
      stale,
      generation: capabilities.generation,
      skipLogAtTip: true,
    );
    final readById = {
      for (var i = 0; i < stale.length; i++) stale[i]: reads[i],
    };
    final states = <HostedGroupRoom>[];
    final logs = <HostedGroupLogPage>[];
    final driverStatuses = <String, RoomDriverStatus>{};
    for (final listedRoom in listed) {
      final read = readById[listedRoom.roomId];
      if (read == null) {
        final i = previousIndex[listedRoom.roomId]!;
        states.add(previous.rooms[i]);
        logs.add(previous.logs[i]);
        if (previous.driverStatuses[listedRoom.roomId] case final status?) {
          driverStatuses[listedRoom.roomId] = status;
        }
        continue;
      }
      final state = read.room;
      if (state.roomId != listedRoom.roomId ||
          state.revision < listedRoom.revision) {
        throw const FormatException('incoherent hosted room state');
      }
      states.add(state);
      logs.add(read.log);
      if (read.driverStatus case final status?) {
        driverStatuses[state.roomId] = status;
      }
    }
    return HostedGroupsSnapshot(
      capabilities: capabilities,
      rooms: List.unmodifiable(states),
      logs: List.unmodifiable(logs),
      driverStatuses: Map.unmodifiable(driverStatuses),
    );
  }

  /// Resumes each room log from [snapshot] (the last one this client showed)
  /// so reopening Bot Mode reads only what is new, not every transcript.
  void seedHostedLogs(HostedGroupsSnapshot snapshot) {
    if (snapshot.rooms.length != snapshot.logs.length) return;
    for (var i = 0; i < snapshot.rooms.length; i++) {
      final roomId = snapshot.rooms[i].roomId;
      if (_logCursors.containsKey(roomId)) continue;
      _logSeeds[roomId] = snapshot.logs[i];
    }
  }

  Future<HostedGroupsSnapshot> _loadHostedGroups() async {
    final gateway = hostedGroupsGateway;
    if (gateway == null) return HostedGroupsSnapshot.empty;
    final capabilities = await gateway.capabilities();
    if (!capabilities.hasSharedRoomSurface) {
      return HostedGroupsSnapshot(capabilities: capabilities);
    }
    final listed = await gateway.list(generation: capabilities.generation);
    final states = <HostedGroupRoom>[];
    final logs = <HostedGroupLogPage>[];
    final driverStatuses = <String, RoomDriverStatus>{};
    final listedIds = {for (final room in listed) room.roomId};
    _logCursors.removeWhere((roomId, _) => !listedIds.contains(roomId));
    final reads = await _readRooms(
      gateway,
      [for (final room in listed) room.roomId],
      generation: capabilities.generation,
    );
    for (var i = 0; i < listed.length; i++) {
      final listedRoom = listed[i];
      final read = reads[i];
      final state = read.room;
      if (state.roomId != listedRoom.roomId ||
          state.revision < listedRoom.revision) {
        throw const FormatException('incoherent hosted room state');
      }
      states.add(state);
      logs.add(read.log);
      if (read.driverStatus case final status?) {
        driverStatuses[state.roomId] = status;
      }
    }
    return HostedGroupsSnapshot(
      capabilities: capabilities,
      rooms: List.unmodifiable(states),
      logs: List.unmodifiable(logs),
      driverStatuses: Map.unmodifiable(driverStatuses),
    );
  }

  /// Reads every room with at most [roomReadConcurrency] in flight, keeping
  /// the listed order. Any failure fails the whole read, as before.
  Future<List<_RoomRead>> _readRooms(
    MissionHostedGroupsGateway gateway,
    List<String> roomIds, {
    required int generation,
    bool skipLogAtTip = false,
  }) async {
    final results = List<_RoomRead?>.filled(roomIds.length, null);
    var next = 0;
    Future<void> worker() async {
      while (next < roomIds.length) {
        final index = next++;
        results[index] = await _readRoom(
          gateway,
          roomIds[index],
          generation: generation,
          skipLogAtTip: skipLogAtTip,
        );
      }
    }

    await Future.wait([
      for (var i = 0; i < roomReadConcurrency && i < roomIds.length; i++)
        worker(),
    ]);
    return [for (final result in results) result!];
  }

  /// `groups.state` (+driver status) and the room log. Incremental gateways
  /// read only `since_seq = cursor`; legacy ones re-read the full log.
  Future<_RoomRead> _readRoom(
    MissionHostedGroupsGateway gateway,
    String roomId, {
    required int generation,
    bool skipLogAtTip = false,
  }) async {
    if (gateway is! MissionHostedGroupsIncrementalGateway) {
      final state = await gateway.state(roomId, generation: generation);
      final log = await gateway.log(roomId, generation: generation);
      return (room: state, log: log, driverStatus: null);
    }
    final incremental = gateway as MissionHostedGroupsIncrementalGateway;
    final state = await incremental.stateWithDriver(
      roomId,
      generation: generation,
    );
    final cursor = _cursorFor(incremental, roomId, generation);
    final held = cursor.log;
    if (skipLogAtTip && held != null && _cursorAtTip(held, state.room)) {
      // groups.state proves nothing was appended since the cursor's last
      // read under this authority: the log read would return no events.
      return (room: state.room, log: held, driverStatus: state.driverStatus);
    }
    final delta = await cursor.pull();
    return (room: state.room, log: delta.log, driverStatus: state.driverStatus);
  }

  /// True only when [room] (read after [log]) carries an explicit
  /// `latest_seq` equal to the log's tip, under the same authority, and the
  /// log is complete up to that tip. Anything else reads the log.
  static bool _cursorAtTip(HostedGroupLogPage log, HostedGroupRoom room) =>
      room.latestSeqKnown &&
      !log.hasMore &&
      log.cursor == log.latestSeq &&
      room.latestSeq == log.latestSeq &&
      room.authorityGatewayId == log.authority.gatewayId &&
      room.authorityEpoch == log.authority.epoch;

  RoomLogCursor _cursorFor(
    MissionHostedGroupsIncrementalGateway gateway,
    String roomId,
    int generation,
  ) {
    if (_logCursorGeneration != generation) {
      // A new socket generation (a reconnect) still serves the same room
      // history: each cursor resumes after the log it holds, and an
      // authority change or rewound log still restarts it from zero.
      for (final entry in _logCursors.entries) {
        final held = entry.value.log;
        if (held != null) _logSeeds[entry.key] = held;
      }
      _logCursors.clear();
      _logCursorGeneration = generation;
    }
    return _logCursors.putIfAbsent(
      roomId,
      () => RoomLogCursor(
        roomId: roomId,
        initial: _logSeeds.remove(roomId),
        load: ({required sinceSeq, required limit}) => gateway.logSince(
          roomId,
          sinceSeq: sinceSeq,
          limit: limit,
          generation: generation,
        ),
      ),
    );
  }

  /// The log after a rename/stop. Incremental gateways continue the room's
  /// cursor (the delta since the last read, or a complete paged read when
  /// none is open yet) instead of re-reading every page from seq 0; a
  /// rotated authority or rewound log still restarts the cursor from zero.
  Future<HostedGroupLogPage> _mutationLog(
    MissionHostedGroupsGateway gateway,
    String roomId,
    int generation,
  ) async {
    if (gateway is! MissionHostedGroupsIncrementalGateway) {
      return gateway.log(roomId, generation: generation);
    }
    final incremental = gateway as MissionHostedGroupsIncrementalGateway;
    return (await _cursorFor(incremental, roomId, generation).pull()).log;
  }

  Future<MissionHostedGroupsGateway> _requireHosted(
    GroupMethod method,
    int generation,
  ) async {
    if (_closed) throw StateError('MissionControlRepository is closed');
    final gateway = hostedGroupsGateway;
    if (gateway == null) throw StateError('hosted groups unsupported');
    final capabilities = await gateway.capabilities();
    if (capabilities.generation != generation ||
        !capabilities.supports(method)) {
      throw StateError('hosted group capability unavailable');
    }
    return gateway;
  }

  @override
  Future<GroupsCapabilities> hostedGroupCapabilities() async {
    if (_closed) throw StateError('MissionControlRepository is closed');
    final gateway = hostedGroupsGateway;
    if (gateway == null) throw StateError('hosted groups unsupported');
    return gateway.capabilities();
  }

  @override
  Future<HostedGroupRoom> createHostedGroup({
    required String name,
    required List<HostedGroupCreateMember> members,
    required int generation,
  }) async {
    final gateway = await _requireHosted(GroupMethod.create, generation);
    return gateway.create(name: name, members: members, generation: generation);
  }

  @override
  Future<HostedGroupWorkspaceReadback> readHostedGroup(
    HostedGroupRoom room, {
    required int generation,
  }) async {
    final gateway = await _requireHosted(GroupMethod.state, generation);
    final read = await _readRoom(
      gateway,
      room.roomId,
      generation: generation,
      skipLogAtTip: true,
    );
    return _verifiedWorkspaceReadback(
      previous: room,
      current: read.room,
      log: read.log,
      generation: generation,
      driverStatus: read.driverStatus,
    );
  }

  @override
  Future<HostedGroupWorkspaceReadback> sendHostedGroupText(
    HostedGroupRoom room, {
    required String text,
    required HostedGroupSendAttempt attempt,
    required int generation,
  }) async {
    final gateway = await _requireHosted(GroupMethod.send, generation);
    final tail = await gateway.send(
      room.roomId,
      text: text,
      attempt: attempt,
      generation: generation,
    );
    // send already verified its acknowledgement tail (the log since the
    // acknowledged event). When that tail carries this attempt's event and
    // continues the room's cursor exactly under the room's authority, it IS
    // the next delta: take it instead of reading groups.state and the log
    // again, and let the room poller bring the driver status.
    if (gateway is MissionHostedGroupsIncrementalGateway &&
        tail.authority.gatewayId == room.authorityGatewayId &&
        tail.authority.epoch == room.authorityEpoch &&
        tail.events.any(
          (e) =>
              e.eventId == attempt.durableEventId && e.kind == 'message.user',
        ) &&
        _logCursorGeneration == generation) {
      final merged = _logCursors[room.roomId]?.absorb(tail);
      if (merged != null) {
        return _verifiedWorkspaceReadback(
          previous: room,
          current: room,
          log: merged.log,
          generation: generation,
        );
      }
    }
    // Otherwise read it back like a refresh: incremental gateways fetch only
    // the delta after the room's cursor instead of the whole log again (a
    // long room made every send wait for dozens of log pages).
    final read = await _readRoom(gateway, room.roomId, generation: generation);
    return _verifiedWorkspaceReadback(
      previous: room,
      current: read.room,
      log: read.log,
      generation: generation,
      driverStatus: read.driverStatus,
    );
  }

  @override
  Future<HostedGroupWorkspaceReadback> renameHostedGroup(
    HostedGroupRoom room, {
    required String name,
    required int generation,
  }) async {
    final gateway = await _requireHosted(GroupMethod.rename, generation);
    final current = await gateway.rename(
      room.roomId,
      name: name,
      generation: generation,
    );
    final log = await _mutationLog(gateway, room.roomId, generation);
    return _verifiedWorkspaceReadback(
      previous: room,
      current: current,
      log: log,
      generation: generation,
    );
  }

  @override
  Future<HostedGroupWorkspaceReadback> stopHostedGroup(
    HostedGroupRoom room, {
    required int generation,
  }) async {
    final gateway = await _requireHosted(GroupMethod.stop, generation);
    final current = await gateway.stop(room.roomId, generation: generation);
    final log = await _mutationLog(gateway, room.roomId, generation);
    return _verifiedWorkspaceReadback(
      previous: room,
      current: current,
      log: log,
      generation: generation,
    );
  }

  @override
  Future<HostedGroupWorkspaceReadback> disbandHostedGroup(
    HostedGroupRoom room, {
    required int generation,
  }) async {
    final gateway = await _requireHosted(GroupMethod.disband, generation);
    final current = await gateway.disband(room.roomId, generation: generation);
    if (!current.disbanded ||
        current.roomId != room.roomId ||
        current.revision < room.revision ||
        current.authorityEpoch != room.authorityEpoch) {
      throw const FormatException('unverified hosted room disband readback');
    }
    return HostedGroupWorkspaceReadback(
      room: current,
      log: null,
      capabilityGeneration: generation,
    );
  }

  HostedGroupWorkspaceReadback _verifiedWorkspaceReadback({
    required HostedGroupRoom previous,
    required HostedGroupRoom current,
    required HostedGroupLogPage log,
    required int generation,
    RoomDriverStatus? driverStatus,
  }) {
    if (current.roomId != previous.roomId ||
        current.revision < previous.revision ||
        current.authorityEpoch != previous.authorityEpoch ||
        current.authorityGatewayId != previous.authorityGatewayId ||
        log.authority.gatewayId != current.authorityGatewayId ||
        log.authority.epoch != current.authorityEpoch) {
      throw const FormatException('incoherent hosted room mutation readback');
    }
    return HostedGroupWorkspaceReadback(
      room: current,
      log: log,
      capabilityGeneration: generation,
      driverStatus: driverStatus,
    );
  }

  static Future<_MissionLoadResult<T>> _capture<T>(
    Future<T> Function() action,
  ) async {
    try {
      return _MissionLoadResult<T>(value: await action());
    } catch (error) {
      return _MissionLoadResult<T>(error: error);
    }
  }

  static MissionCapabilityState _capability<T>(_MissionLoadResult<T> result) {
    if (result.value != null) return MissionCapabilityState.available;
    return _isUnsupported(result.error)
        ? MissionCapabilityState.unsupported
        : MissionCapabilityState.unavailable;
  }

  static bool _isUnsupported(Object? error) {
    if (error is TuiGatewayRpcError && error.code == -32601) return true;
    if (error is DashboardHttpException) {
      return error.statusCode == 404 || error.statusCode == 405;
    }
    final text = error.toString().toLowerCase();
    return text.contains('http 404') || text.contains('http 405');
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _logCursors.clear();
    _logSeeds.clear();
    onClose?.call();
  }
}

typedef _RoomRead = ({
  HostedGroupRoom room,
  HostedGroupLogPage log,
  RoomDriverStatus? driverStatus,
});

final class _MissionLoadResult<T> {
  final T? value;
  final Object? error;

  const _MissionLoadResult({this.value, this.error});
}
