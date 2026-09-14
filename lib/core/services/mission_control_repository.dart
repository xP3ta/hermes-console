import 'dart:async';
import 'dart:math';

import '../models/agent_profile.dart';
import '../models/hosted_groups.dart';
import '../models/kanban.dart';
import '../models/mission_control.dart';
import 'connection_manager.dart';
import 'kanban_client.dart';
import 'tui_gateway_client.dart';

typedef MissionProfilesLoader = Future<List<AgentProfile>> Function();
typedef MissionSessionsLoader = Future<List<Session>> Function();
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
    implements MissionHostedGroupsGateway {
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
      client.groupLog(roomId, generation: generation);
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

final class MissionControlRepository
    implements
        MissionControlDataSource,
        MissionProfileAvatarDataSource,
        MissionHostedGroupsDataSource {
  final MissionProfilesLoader profilesLoader;
  final MissionSessionsLoader sessionsLoader;
  final MissionBoardLoader boardLoader;
  final MissionKanbanEventsLoader? kanbanEventsLoader;
  final MissionProfileAvatarLoader? profileAvatarLoader;
  final MissionHostedGroupsGateway? hostedGroupsGateway;
  final void Function()? onClose;
  bool _closed = false;

  MissionControlRepository({
    required this.profilesLoader,
    required this.sessionsLoader,
    required this.boardLoader,
    this.kanbanEventsLoader,
    this.profileAvatarLoader,
    this.hostedGroupsGateway,
    this.onClose,
  });

  factory MissionControlRepository.forConnection(SavedConnection connection) {
    final dashboard = DashboardClient.lazy(connection);
    final gateway = ApiClient(
      baseUrl: connection.baseUrl,
      apiKey: connection.apiKey,
      connectionId: connection.id,
    );
    final kanban = KanbanClient(connection, dashboardClient: dashboard);
    final desktop = TuiGatewayClient(connection, dashboard: dashboard);
    return MissionControlRepository(
      profilesLoader: () => loadMissionControlProfiles(
        // One profiles.list snapshot now carries Desktop's last/preferred
        // session projections and hidden worker liveness. Older Gateways omit
        // those optional fields and keep returning the same profile roster.
        desktopLoader: () => desktop.listProfiles(includeSessions: true),
        legacyDashboardLoader: dashboard.getProfiles,
      ),
      sessionsLoader: () => loadMissionControlSessions(
        dashboardGet: dashboard.apiGet,
        legacyGatewayLoader: () => gateway.getSessions(includeChildren: true),
      ),
      boardLoader: kanban.getCurrentBoard,
      kanbanEventsLoader: (since) => kanban.events(since: since),
      profileAvatarLoader: desktop.profileAvatar,
      hostedGroupsGateway: _TuiMissionHostedGroupsGateway(desktop),
      onClose: () {
        unawaited(desktop.close());
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
    final results = await Future.wait<Object>([
      _capture(profilesLoader),
      _capture(sessionsLoader),
      _capture(boardLoader),
      _capture(_loadHostedGroups),
    ]);
    final profilesResult = results[0] as _MissionLoadResult<List<AgentProfile>>;
    final sessionsResult = results[1] as _MissionLoadResult<List<Session>>;
    final boardResult = results[2] as _MissionLoadResult<KanbanBoard>;
    final groupsResult = results[3] as _MissionLoadResult<HostedGroupsSnapshot>;
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
          : _capability(groupsResult),
      failures: failures,
      loadedAt: DateTime.now(),
    );
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
    for (final listedRoom in listed) {
      final state = await gateway.state(
        listedRoom.roomId,
        generation: capabilities.generation,
      );
      if (state.roomId != listedRoom.roomId ||
          state.revision < listedRoom.revision) {
        throw const FormatException('incoherent hosted room state');
      }
      final log = await gateway.log(
        state.roomId,
        generation: capabilities.generation,
      );
      states.add(state);
      logs.add(log);
    }
    return HostedGroupsSnapshot(
      capabilities: capabilities,
      rooms: List.unmodifiable(states),
      logs: List.unmodifiable(logs),
    );
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
  Future<HostedGroupRoom> createHostedGroup({
    required String name,
    required List<HostedGroupCreateMember> members,
    required int generation,
  }) async {
    final gateway = await _requireHosted(GroupMethod.create, generation);
    return gateway.create(name: name, members: members, generation: generation);
  }

  @override
  Future<HostedGroupWorkspaceReadback> sendHostedGroupText(
    HostedGroupRoom room, {
    required String text,
    required HostedGroupSendAttempt attempt,
    required int generation,
  }) async {
    final gateway = await _requireHosted(GroupMethod.send, generation);
    final log = await gateway.send(
      room.roomId,
      text: text,
      attempt: attempt,
      generation: generation,
    );
    final current = await gateway.state(room.roomId, generation: generation);
    return _verifiedWorkspaceReadback(
      previous: room,
      current: current,
      log: log,
      generation: generation,
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
    final log = await gateway.log(room.roomId, generation: generation);
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
    final log = await gateway.log(room.roomId, generation: generation);
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
  }) {
    if (current.roomId != previous.roomId ||
        current.revision < previous.revision ||
        current.authorityEpoch != previous.authorityEpoch ||
        log.authority.epoch != current.authorityEpoch) {
      throw const FormatException('incoherent hosted room mutation readback');
    }
    return HostedGroupWorkspaceReadback(
      room: current,
      log: log,
      capabilityGeneration: generation,
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
    onClose?.call();
  }
}

final class _MissionLoadResult<T> {
  final T? value;
  final Object? error;

  const _MissionLoadResult({this.value, this.error});
}
