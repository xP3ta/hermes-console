import '../bots/data/room_log_cursor.dart';
import 'bot_roster_store.dart';
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show Listenable, VoidCallback;

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

/// Optional `groups.state` that also says whether the backend pushes
/// `groups.changed` when the room moves (`change_events`).
abstract interface class MissionHostedGroupsChangeEventsGateway {
  Future<
    ({HostedGroupRoom room, RoomDriverStatus? driverStatus, bool changeEvents})
  >
  stateWithEvents(String roomId, {required int generation});
}

/// Optional `groups.list` surface that keeps the rows Console could not read
/// apart instead of failing the whole list (see [HostedGroupListing]).
abstract interface class MissionHostedGroupsListingGateway {
  Future<HostedGroupListing> listing({required int generation});
}

/// Optional `groups.attachment.download`: the verified bytes of one file of
/// a room's own store ([TuiGatewayClient.downloadGroupAttachment]).
abstract interface class MissionHostedGroupsAttachmentGateway {
  Future<Uint8List> downloadAttachment(
    String roomId, {
    required String eventId,
    required HostedGroupAttachment attachment,
    required int generation,
  });
}

/// Optional room file store: `groups.attachment.upload`
/// ([TuiGatewayClient.uploadGroupAttachment]) and a `groups.send` that lists
/// the uploaded files.
abstract interface class MissionHostedGroupsUploadGateway {
  Future<HostedGroupAttachment> uploadAttachment(
    String roomId, {
    required String uploadId,
    required String kind,
    required String name,
    required String mime,
    required Uint8List bytes,
    required int generation,
  });

  Future<HostedGroupLogPage> sendWithAttachments(
    String roomId, {
    required String text,
    required List<HostedGroupAttachment> attachments,
    required HostedGroupSendAttempt attempt,
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
        MissionHostedGroupsIncrementalGateway,
        MissionHostedGroupsChangeEventsGateway,
        MissionHostedGroupsListingGateway,
        MissionHostedGroupsAttachmentGateway,
        MissionHostedGroupsUploadGateway {
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
  Future<HostedGroupListing> listing({required int generation}) =>
      // Pages of 100, as Hermes Desktop reads it (`canonical-groups.ts`
      // `listCanonicalRooms`).
      client.listGroupsDetailed(limit: 100, generation: generation);
  @override
  Future<HostedGroupRoom> state(String roomId, {required int generation}) =>
      client.groupState(roomId, generation: generation);
  @override
  Future<Uint8List> downloadAttachment(
    String roomId, {
    required String eventId,
    required HostedGroupAttachment attachment,
    required int generation,
  }) => client.downloadGroupAttachment(
    roomId: roomId,
    eventId: eventId,
    attachment: attachment,
    generation: generation,
  );
  @override
  Future<HostedGroupAttachment> uploadAttachment(
    String roomId, {
    required String uploadId,
    required String kind,
    required String name,
    required String mime,
    required Uint8List bytes,
    required int generation,
  }) => client.uploadGroupAttachment(
    roomId: roomId,
    uploadId: uploadId,
    kind: kind,
    name: name,
    mime: mime,
    bytes: bytes,
    generation: generation,
  );
  @override
  Future<HostedGroupLogPage> sendWithAttachments(
    String roomId, {
    required String text,
    required List<HostedGroupAttachment> attachments,
    required HostedGroupSendAttempt attempt,
    required int generation,
  }) => client.sendGroupText(
    roomId: roomId,
    text: text,
    threadId: attempt.threadId,
    eventId: attempt.clientEventId,
    generation: generation,
    attachments: attachments,
  );
  @override
  Future<HostedGroupLogPage> log(String roomId, {required int generation}) =>
      client.groupLogComplete(roomId, generation: generation);
  @override
  Future<({HostedGroupRoom room, RoomDriverStatus? driverStatus})>
  stateWithDriver(String roomId, {required int generation}) =>
      client.groupStateWithDriver(roomId, generation: generation);
  @override
  Future<
    ({HostedGroupRoom room, RoomDriverStatus? driverStatus, bool changeEvents})
  >
  stateWithEvents(String roomId, {required int generation}) =>
      client.groupStateWithEvents(roomId, generation: generation);
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
/// Desktop (`listAllProfileSessions`, apps/desktop/src/api/sessions.ts). A
/// missing route, auth, network or malformed response fails closed so a
/// partial default-profile list cannot masquerade as complete.
///
/// Like Desktop it does not ask for `full` rows: those add each session's
/// rendered `system_prompt` and `model_config` (tens of KB per row,
/// hermes_cli/web_server_gateway.py `_SESSION_LIST_HEAVY_FIELDS`), which a
/// list never reads.
Future<List<Session>> loadMissionControlSessions({
  required MissionDashboardGet dashboardGet,
}) async {
  final query = Uri(
    queryParameters: const {
      'profile': 'all',
      'limit': '200',
      'offset': '0',
      'min_messages': '0',
      'archived': 'exclude',
      'order': 'recent',
      'include_children': 'true',
    },
  ).query;
  final data = await dashboardGet('profiles/sessions?$query');
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

/// Optional read of one file of a room's own store
/// (`groups.attachment.download`).
abstract interface class MissionHostedGroupsAttachmentDataSource {
  Future<Uint8List> downloadHostedGroupAttachment(
    HostedGroupRoom room, {
    required String eventId,
    required HostedGroupAttachment attachment,
  });
}

/// Optional room file store: a file kept with `groups.attachment.upload`
/// and an owner message that lists such files.
abstract interface class MissionHostedGroupsUploadDataSource {
  Future<HostedGroupAttachment> uploadHostedGroupAttachment(
    HostedGroupRoom room, {
    required String uploadId,
    required String kind,
    required String name,
    required String mime,
    required Uint8List bytes,
  });

  Future<HostedGroupWorkspaceReadback> sendHostedGroupMessage(
    HostedGroupRoom room, {
    required String text,
    required List<HostedGroupAttachment> attachments,
    required HostedGroupSendAttempt attempt,
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
/// ([loadRoster]) and the room list ([refreshHostedGroups]).
abstract interface class MissionLiveRefreshDataSource {
  /// Global Gateway events (`sessions.changed`…); errors when the socket
  /// drops. Null when this source has no live channel.
  Stream<TuiGatewayEvent>? watchLiveChanges();

  /// The socket is up and the backend announced `change_events`.
  bool get liveChangesHealthy;

  Future<MissionRosterRead> loadRoster();

  /// The room list read again (`groups.capabilities` + `groups.list`),
  /// with what views of its rooms read in this session. Throws when the
  /// read fails or the server no longer offers rooms: the caller keeps the
  /// list it shows, or reloads.
  Future<HostedGroupsSnapshot> refreshHostedGroups(
    HostedGroupsSnapshot previous,
  );
}

/// Optional signal of the socket the room list is read on: Mission Control
/// reads the list again as soon as it is back up, as Hermes Desktop does
/// when its gateway reopens (`canonical-group-registry.tsx`: the rooms
/// query is always stale and enabled only while the gateway is open).
abstract interface class MissionHostedRoomsLinkSource {
  /// Notifies when the socket comes up or goes down.
  Listenable get roomsLink;

  /// Whether the socket is up now.
  bool get roomsLinkUp;
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
        MissionHostedGroupsAttachmentDataSource,
        MissionHostedGroupsUploadDataSource,
        MissionLiveRefreshDataSource,
        MissionHostedRoomsLinkSource {
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

  /// Dials the shared socket now for a user action; null on sources without
  /// one. See [retryConnection].
  final Future<void> Function()? reconnect;

  /// Global Gateway events and their health (see
  /// [MissionLiveRefreshDataSource]); both null without a live channel.
  final Stream<TuiGatewayEvent> Function()? liveChanges;
  final bool Function()? liveChangesAvailable;
  bool _closed = false;
  final Map<String, RoomLogCursor> _logCursors = {};
  final Map<String, HostedGroupLogPage> _logSeeds = {};
  int? _logCursorGeneration;

  /// The socket the rooms are read on (see [MissionHostedRoomsLinkSource]);
  /// both null on sources without one.
  final Listenable? link;
  final bool Function()? linkUp;

  MissionControlRepository({
    required this.profilesLoader,
    required this.sessionsLoader,
    required this.boardLoader,
    this.activeSessionsLoader,
    this.kanbanEventsLoader,
    this.profileAvatarLoader,
    this.hostedGroupsGateway,
    this.onClose,
    this.reconnect,
    this.liveChanges,
    this.liveChangesAvailable,
    this.link,
    this.linkUp,
  });

  @override
  Listenable get roomsLink => link ?? const _NoLink();

  @override
  bool get roomsLinkUp => !_closed && (linkUp?.call() ?? false);

  /// The user asked for the read again (Retry, pull to refresh). A socket
  /// that stopped dialing (reconnect backoff, or "sign in again" latched)
  /// only looks again on an explicit Retry (`TuiGatewayClient
  /// .connectForeground`); a plain read would fail without a request. The
  /// read that follows joins this dial and reports its outcome.
  void retryConnection() {
    if (_closed) return;
    final dial = reconnect;
    if (dial == null) return;
    unawaited(dial().then<void>((_) {}, onError: (Object _) {}));
  }

  factory MissionControlRepository.forConnection(SavedConnection connection) {
    final dashboard = DashboardClient.lazy(connection);
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
      sessionsLoader: () =>
          loadMissionControlSessions(dashboardGet: dashboard.apiGet),
      boardLoader: kanban.getCurrentBoard,
      // The same pooled socket: no extra connection for the live sessions.
      activeSessionsLoader: desktop.listActiveSessions,
      kanbanEventsLoader: (since) => kanban.events(since: since),
      profileAvatarLoader: desktop.profileAvatar,
      hostedGroupsGateway: _TuiMissionHostedGroupsGateway(desktop),
      reconnect: desktop.connectForeground,
      liveChanges: () => desktop.events,
      liveChangesAvailable: () =>
          desktop.isConnected && desktop.changeEventsAvailable,
      link: desktop.linkListenable,
      linkUp: () => desktop.isConnected,
      onClose: () {
        lease.release();
        kanban.close();
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
    final rawGroups = results[3] as _MissionLoadResult<HostedGroupsSnapshot>;
    // A read that failed after `groups.capabilities` answered keeps those
    // capabilities: what the server can do (create a room) does not depend
    // on whether its rooms could be read just now.
    final readFailure = switch (rawGroups.error) {
      final _HostedGroupsReadFailure failure => failure,
      _ => null,
    };
    final groupsResult = readFailure == null
        ? rawGroups
        : _MissionLoadResult<HostedGroupsSnapshot>(error: readFailure.cause);
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
      hostedGroups:
          groupsResult.value ??
          (readFailure == null
              ? HostedGroupsSnapshot.empty
              : HostedGroupsSnapshot(capabilities: readFailure.capabilities)),
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

  /// The room list alone, as Hermes Desktop re-reads it
  /// (`canonical-group-registry.tsx` `useGatewayGroupRooms` over
  /// `canonical-groups.ts` `listCanonicalRooms`): `groups.capabilities` and
  /// `groups.list`, never a room's `groups.state` or `groups.log`. A new
  /// capability generation (a reconnect) is just the one this list was
  /// read under. [previous] only proves the rooms were loaded once.
  @override
  Future<HostedGroupsSnapshot> refreshHostedGroups(
    HostedGroupsSnapshot previous,
  ) async {
    if (_closed) throw StateError('MissionControlRepository is closed');
    final gateway = hostedGroupsGateway;
    if (gateway == null || previous.capabilities == null) {
      throw StateError('hosted groups were not loaded');
    }
    final capabilities = await gateway.capabilities();
    if (!capabilities.hasSharedRoomSurface) {
      throw StateError('hosted groups capability changed');
    }
    return _listRooms(gateway, capabilities);
  }

  /// The last read a view of each room made in this app session: the room
  /// screen's polls ([readHostedGroup]) and the read-backs of its sends and
  /// other actions. It is the only source of a room's conversation and
  /// driver state in the room list; a room no view read has neither. Hermes
  /// Desktop's rows show the same thing, what an open view of the room
  /// published (`canonical-group-details.tsx` `$canonicalRoomLive`, from
  /// `canonical-group-workspace.tsx`). Desktop drops it when the room's
  /// view closes because its list sits next to the open room; on a phone
  /// the list is never on screen while a room is, so it is kept for the
  /// session.
  final Map<String, _PublishedRoomRead> _published = {};

  /// The read that knows more of the room: the later log, then the later
  /// revision; [a] on a tie. A seed or a shown room newer than what this
  /// repository last read (a message just sent, a later snapshot) must not
  /// lose to it.
  static _PublishedRoomRead? _newest(
    _PublishedRoomRead? a,
    _PublishedRoomRead? b,
  ) {
    if (a == null || b == null) return a ?? b;
    if (a.room.authorityGatewayId != b.room.authorityGatewayId ||
        a.room.authorityEpoch != b.room.authorityEpoch) {
      return a.room.authorityEpoch >= b.room.authorityEpoch ? a : b;
    }
    if (a.log.latestSeq != b.log.latestSeq) {
      return a.log.latestSeq > b.log.latestSeq ? a : b;
    }
    return a.room.revision >= b.room.revision ? a : b;
  }

  /// `groups.list` with unreadable rows kept apart when the gateway can
  /// (see [MissionHostedGroupsListingGateway]); all-or-nothing otherwise.
  static Future<HostedGroupListing> _list(
    MissionHostedGroupsGateway gateway,
    int generation,
  ) async {
    if (gateway is MissionHostedGroupsListingGateway) {
      return (gateway as MissionHostedGroupsListingGateway).listing(
        generation: generation,
      );
    }
    return HostedGroupListing(rooms: await gateway.list(generation: generation));
  }

  /// The listed rooms, each with what a view of it read in this session
  /// (see [_published]); nothing else is read or invented.
  Future<HostedGroupsSnapshot> _listRooms(
    MissionHostedGroupsGateway gateway,
    GroupsCapabilities capabilities,
  ) async {
    final listing = await _list(gateway, capabilities.generation);
    if (_closed) throw StateError('MissionControlRepository is closed');
    final listed = listing.rooms;
    final listedIds = {for (final room in listed) room.roomId};
    _logCursors.removeWhere((roomId, _) => !listedIds.contains(roomId));
    _logSeeds.removeWhere((roomId, _) => !listedIds.contains(roomId));
    _published.removeWhere((roomId, _) => !listedIds.contains(roomId));
    final logs = <HostedGroupLogPage?>[];
    final drivers = <String, RoomDriverStatus>{};
    final readAt = <String, DateTime>{};
    for (final room in listed) {
      final read = _publishedFor(room);
      logs.add(read?.log);
      if (read?.driverStatus case final status?) {
        drivers[room.roomId] = status;
        if (read?.driverReadAt case final at?) readAt[room.roomId] = at;
      }
    }
    return HostedGroupsSnapshot(
      capabilities: capabilities,
      rooms: List.unmodifiable(listed),
      logs: List.unmodifiable(logs),
      driverStatuses: Map.unmodifiable(drivers),
      driverReadAt: Map.unmodifiable(readAt),
      unreadableRooms: List.unmodifiable(listing.unreadable),
    );
  }

  /// What a view read of [listed], when it was read under the authority
  /// the list names now. A room served by another authority since is a
  /// new history: what was read under the old one is dropped with its
  /// cursor.
  _PublishedRoomRead? _publishedFor(HostedGroupRoom listed) {
    final read = _published[listed.roomId];
    if (read == null) return null;
    if (read.room.authorityGatewayId == listed.authorityGatewayId &&
        read.room.authorityEpoch == listed.authorityEpoch) {
      return read;
    }
    _published.remove(listed.roomId);
    _logCursors.remove(listed.roomId);
    _logSeeds.remove(listed.roomId);
    return null;
  }

  /// Takes what views of the rooms in [snapshot] (the last one this client
  /// showed) read as this repository's own, unless it already holds newer
  /// reads, so the rooms opened in this session keep their conversation and
  /// state across Bot Mode screens, and an opened room's log resumes after
  /// what was read instead of from the start.
  void seedHostedLogs(HostedGroupsSnapshot snapshot) {
    for (var i = 0; i < snapshot.rooms.length; i++) {
      final log = snapshot.logAt(i);
      if (log == null) continue;
      final room = snapshot.rooms[i];
      final roomId = room.roomId;
      final shown = _PublishedRoomRead(
        room,
        log,
        snapshot.driverStatuses[roomId],
        snapshot.driverReadAt[roomId],
      );
      _published[roomId] = _newest(_published[roomId], shown)!;
      if (_logCursors.containsKey(roomId)) continue;
      _logSeeds[roomId] = log;
    }
  }

  /// [shown] with the last read a view made of each of its rooms in this
  /// session, without reading anything: the row of a room just closed
  /// shows what its view last read, as a Desktop row shows what the open
  /// view published (`canonical-group-details.tsx`
  /// `publishCanonicalRoomLive`). [shown] itself when there is nothing to
  /// add.
  HostedGroupsSnapshot withPublishedReads(HostedGroupsSnapshot shown) {
    if (_closed || _published.isEmpty) return shown;
    var changed = false;
    final rooms = <HostedGroupRoom>[];
    final logs = <HostedGroupLogPage?>[];
    final drivers = {...shown.driverStatuses};
    final readAt = {...shown.driverReadAt};
    for (var i = 0; i < shown.rooms.length; i++) {
      final room = shown.rooms[i];
      final read = _published[room.roomId];
      if (read == null ||
          read.room.authorityGatewayId != room.authorityGatewayId ||
          read.room.authorityEpoch != room.authorityEpoch) {
        rooms.add(room);
        logs.add(shown.logAt(i));
        continue;
      }
      changed = true;
      rooms.add(read.room.revision > room.revision ? read.room : room);
      logs.add(read.log);
      if (read.driverStatus case final status?) {
        drivers[room.roomId] = status;
        if (read.driverReadAt case final at?) {
          readAt[room.roomId] = at;
        } else {
          readAt.remove(room.roomId);
        }
      }
    }
    if (!changed) return shown;
    return HostedGroupsSnapshot(
      capabilities: shown.capabilities,
      rooms: List.unmodifiable(rooms),
      logs: List.unmodifiable(logs),
      driverStatuses: Map.unmodifiable(drivers),
      driverReadAt: Map.unmodifiable(readAt),
      unreadableRooms: shown.unreadableRooms,
    );
  }

  Future<HostedGroupsSnapshot> _loadHostedGroups() async {
    final gateway = hostedGroupsGateway;
    if (gateway == null) return HostedGroupsSnapshot.empty;
    final capabilities = await gateway.capabilities();
    if (!capabilities.hasSharedRoomSurface) {
      return HostedGroupsSnapshot(capabilities: capabilities);
    }
    try {
      return await _listRooms(gateway, capabilities);
    } catch (error) {
      throw _HostedGroupsReadFailure(capabilities, error);
    }
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
      return (
        room: state,
        log: log,
        driverStatus: null,
        changeEvents: false,
      );
    }
    final incremental = gateway as MissionHostedGroupsIncrementalGateway;
    final HostedGroupRoom room;
    final RoomDriverStatus? driverStatus;
    var changeEvents = false;
    if (gateway is MissionHostedGroupsChangeEventsGateway) {
      final state = await (gateway as MissionHostedGroupsChangeEventsGateway)
          .stateWithEvents(roomId, generation: generation);
      room = state.room;
      driverStatus = state.driverStatus;
      changeEvents = state.changeEvents;
    } else {
      final state = await incremental.stateWithDriver(
        roomId,
        generation: generation,
      );
      room = state.room;
      driverStatus = state.driverStatus;
    }
    final cursor = _cursorFor(incremental, roomId, generation);
    final held = cursor.log;
    if (skipLogAtTip && held != null && _cursorAtTip(held, room)) {
      // groups.state proves nothing was appended since the cursor's last
      // read under this authority: the log read would return no events.
      return (
        room: room,
        log: held,
        driverStatus: driverStatus,
        changeEvents: changeEvents,
      );
    }
    final delta = await cursor.pull();
    return (
      room: room,
      log: delta.log,
      driverStatus: driverStatus,
      changeEvents: changeEvents,
    );
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

  /// A read under the capabilities live on the socket now, like the open
  /// room's own reads: a file is not bound to the socket its room was
  /// listed on. A server that does not list the method is never asked.
  @override
  Future<Uint8List> downloadHostedGroupAttachment(
    HostedGroupRoom room, {
    required String eventId,
    required HostedGroupAttachment attachment,
  }) async {
    if (_closed) throw StateError('MissionControlRepository is closed');
    final gateway = hostedGroupsGateway;
    if (gateway == null || gateway is! MissionHostedGroupsAttachmentGateway) {
      throw StateError('hosted group capability unavailable');
    }
    final capabilities = await gateway.capabilities();
    if (!capabilities.supports(GroupMethod.attachmentDownload)) {
      throw StateError('hosted group capability unavailable');
    }
    return (gateway as MissionHostedGroupsAttachmentGateway).downloadAttachment(
      room.roomId,
      eventId: eventId,
      attachment: attachment,
      generation: capabilities.generation,
    );
  }

  /// An upload under the capabilities live on the socket now, like a
  /// download: a server that does not list the method is never asked, and
  /// says so (-32601). One that lists it while its room driver is down
  /// fails this upload only: the method is not missing.
  @override
  Future<HostedGroupAttachment> uploadHostedGroupAttachment(
    HostedGroupRoom room, {
    required String uploadId,
    required String kind,
    required String name,
    required String mime,
    required Uint8List bytes,
  }) async {
    if (_closed) throw StateError('MissionControlRepository is closed');
    final gateway = hostedGroupsGateway;
    if (gateway == null || gateway is! MissionHostedGroupsUploadGateway) {
      throw const TuiGatewayRpcError(
        'groups.attachment.upload',
        'Group operation is unavailable',
        code: -32601,
      );
    }
    final capabilities = await gateway.capabilities();
    if (!capabilities.methods.contains(GroupMethod.attachmentUpload)) {
      throw const TuiGatewayRpcError(
        'groups.attachment.upload',
        'Group operation is unavailable',
        code: -32601,
      );
    }
    if (!capabilities.supports(GroupMethod.attachmentUpload)) {
      throw StateError('hosted group capability unavailable');
    }
    return (gateway as MissionHostedGroupsUploadGateway).uploadAttachment(
      room.roomId,
      uploadId: uploadId,
      kind: kind,
      name: name,
      mime: mime,
      bytes: bytes,
      generation: capabilities.generation,
    );
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
      changeEvents: read.changeEvents,
    );
  }

  @override
  Future<HostedGroupWorkspaceReadback> sendHostedGroupText(
    HostedGroupRoom room, {
    required String text,
    required HostedGroupSendAttempt attempt,
    required int generation,
  }) => _sendHostedGroup(
    room,
    text: text,
    attachments: const [],
    attempt: attempt,
    generation: generation,
  );

  @override
  Future<HostedGroupWorkspaceReadback> sendHostedGroupMessage(
    HostedGroupRoom room, {
    required String text,
    required List<HostedGroupAttachment> attachments,
    required HostedGroupSendAttempt attempt,
    required int generation,
  }) => _sendHostedGroup(
    room,
    text: text,
    attachments: attachments,
    attempt: attempt,
    generation: generation,
  );

  Future<HostedGroupWorkspaceReadback> _sendHostedGroup(
    HostedGroupRoom room, {
    required String text,
    required List<HostedGroupAttachment> attachments,
    required HostedGroupSendAttempt attempt,
    required int generation,
  }) async {
    final gateway = await _requireHosted(GroupMethod.send, generation);
    final HostedGroupLogPage tail;
    if (attachments.isEmpty) {
      tail = await gateway.send(
        room.roomId,
        text: text,
        attempt: attempt,
        generation: generation,
      );
    } else if (gateway is MissionHostedGroupsUploadGateway) {
      tail = await (gateway as MissionHostedGroupsUploadGateway)
          .sendWithAttachments(
            room.roomId,
            text: text,
            attachments: attachments,
            attempt: attempt,
            generation: generation,
          );
    } else {
      throw StateError('hosted group capability unavailable');
    }
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
      changeEvents: read.changeEvents,
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
    _published.remove(room.roomId);
    _logCursors.remove(room.roomId);
    _logSeeds.remove(room.roomId);
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
    bool changeEvents = false,
  }) {
    if (current.roomId != previous.roomId ||
        current.revision < previous.revision ||
        current.authorityEpoch != previous.authorityEpoch ||
        current.authorityGatewayId != previous.authorityGatewayId ||
        log.authority.gatewayId != current.authorityGatewayId ||
        log.authority.epoch != current.authorityEpoch) {
      throw const FormatException('incoherent hosted room mutation readback');
    }
    // What the room's view shows from now on is also what its row in the
    // room list shows (see [_published]). A read-back without a driver
    // status keeps the one read before, with the time it was read.
    final kept = switch (_published[current.roomId]) {
      final read?
          when read.room.authorityGatewayId == current.authorityGatewayId &&
              read.room.authorityEpoch == current.authorityEpoch =>
        read,
      _ => null,
    };
    _published[current.roomId] = driverStatus == null
        ? _PublishedRoomRead(
            current,
            log,
            kept?.driverStatus,
            kept?.driverReadAt,
          )
        : _PublishedRoomRead(current, log, driverStatus, DateTime.now());
    return HostedGroupWorkspaceReadback(
      room: current,
      log: log,
      capabilityGeneration: generation,
      driverStatus: driverStatus,
      changeEvents: changeEvents,
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
    _published.clear();
    onClose?.call();
  }
}

typedef _RoomRead = ({
  HostedGroupRoom room,
  HostedGroupLogPage log,
  RoomDriverStatus? driverStatus,
  bool changeEvents,
});

/// What a view of one room last read (see
/// [MissionControlRepository._published]): its state, its log, and its
/// driver status with the moment that was read (null when unknown).
final class _PublishedRoomRead {
  final HostedGroupRoom room;
  final HostedGroupLogPage log;
  final RoomDriverStatus? driverStatus;
  final DateTime? driverReadAt;
  const _PublishedRoomRead(
    this.room,
    this.log,
    this.driverStatus,
    this.driverReadAt,
  );
}

/// [MissionHostedRoomsLinkSource.roomsLink] of a source without a socket.
final class _NoLink implements Listenable {
  const _NoLink();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

/// A rooms read that failed after `groups.capabilities` answered.
final class _HostedGroupsReadFailure implements Exception {
  final GroupsCapabilities capabilities;
  final Object cause;
  const _HostedGroupsReadFailure(this.capabilities, this.cause);

  @override
  String toString() => '$cause';
}

final class _MissionLoadResult<T> {
  final T? value;
  final Object? error;

  const _MissionLoadResult({this.value, this.error});
}
