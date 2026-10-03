import 'dart:async';
import 'dart:math';

import '../../models/agent_profile.dart';
import '../../models/connection.dart';
import '../../models/desktop_active_session.dart';
import '../../models/hosted_groups.dart';
import '../../services/bot_roster_store.dart';
import '../../services/shared_gateway_pool.dart';
import '../../services/tui_gateway_client.dart';
import '../state/attention.dart';
import '../state/bot_chat_target.dart';
import '../state/bot_presence.dart';
import 'desktop_projection_rooms.dart';
import 'room_log_cursor.dart';

/// Gateway surface Bot Mode reads. [TuiGatewayClient] implements it through
/// [TuiBotModeGateway]; tests use a fake.
abstract interface class BotModeGateway {
  Future<List<AgentProfile>> listProfiles();
  Future<DesktopActiveSessionList> listActiveSessions();
  Future<GroupsCapabilities> groupCapabilities();
  Future<List<HostedGroupRoom>> listGroups({required int generation});
  Future<({HostedGroupRoom room, RoomDriverStatus? driverStatus})> groupState(
    String roomId, {
    required int generation,
  });
  Future<HostedGroupLogPage> groupLog(
    String roomId, {
    required int sinceSeq,
    required int limit,
    required int generation,
  });
  Future<HostedGroupRoom> stopGroup(String roomId, {required int generation});
  Future<HostedGroupRoom> retryGroupTask(
    String roomId, {
    required String taskId,
    required int generation,
  });
  Future<HostedGroupRoom> approveGroupTask(
    String roomId, {
    required RoomApprovalAction action,
    required String choice,
    required int generation,
  });
  Future<AgentProfileSessionSummary?> findBotChatByTitle(String profile);
}

final class TuiBotModeGateway implements BotModeGateway {
  final TuiGatewayClient client;
  const TuiBotModeGateway(this.client);

  static String _nonce(String prefix) {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return '$prefix-${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  @override
  Future<List<AgentProfile>> listProfiles() =>
      client.listProfiles(includeSessions: true);
  @override
  Future<DesktopActiveSessionList> listActiveSessions() =>
      client.listActiveSessions();
  @override
  Future<GroupsCapabilities> groupCapabilities() => client.groupCapabilities();
  @override
  Future<List<HostedGroupRoom>> listGroups({required int generation}) =>
      client.listGroups(generation: generation);
  @override
  Future<({HostedGroupRoom room, RoomDriverStatus? driverStatus})> groupState(
    String roomId, {
    required int generation,
  }) => client.groupStateWithDriver(roomId, generation: generation);
  @override
  Future<HostedGroupLogPage> groupLog(
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
  Future<HostedGroupRoom> stopGroup(String roomId, {required int generation}) =>
      client.stopGroup(
        roomId: roomId,
        cancelId: _nonce('cancel'),
        generation: generation,
      );
  @override
  Future<HostedGroupRoom> retryGroupTask(
    String roomId, {
    required String taskId,
    required int generation,
  }) => client.retryGroupTask(
    roomId: roomId,
    taskId: taskId,
    generation: generation,
  );
  @override
  Future<HostedGroupRoom> approveGroupTask(
    String roomId, {
    required RoomApprovalAction action,
    required String choice,
    required int generation,
  }) => client.approveGroupTask(
    roomId: roomId,
    memberId: action.memberId,
    taskId: action.taskId,
    executionGeneration: action.executionGeneration,
    choice: choice,
    requestId: action.requestId,
    generation: generation,
  );
  @override
  Future<AgentProfileSessionSummary?> findBotChatByTitle(String profile) =>
      client.findBotChatByTitle(profile);
}

/// One hosted room as Bot Mode sees it.
final class BotModeRoom {
  final HostedGroupRoom room;
  final RoomDriverStatus? driverStatus;
  final HostedGroupLogPage? log;
  final RoomAttention attention;

  const BotModeRoom({
    required this.room,
    required this.driverStatus,
    required this.log,
    required this.attention,
  });
}

final class BotModeRow {
  final AgentProfile profile;
  final BotPresence presence;
  final BotChatTarget chat;
  final List<AttentionItem> attention;

  const BotModeRow({
    required this.profile,
    required this.presence,
    required this.chat,
    required this.attention,
  });
}

final class BotModeSnapshot {
  final List<BotModeRow> bots;
  final List<BotModeRoom> rooms;
  final DesktopProjectionRooms projectionRooms;
  final GroupsCapabilities? capabilities;
  final DateTime loadedAt;

  const BotModeSnapshot({
    required this.bots,
    required this.rooms,
    required this.projectionRooms,
    required this.capabilities,
    required this.loadedAt,
  });

  HostedGroupsSnapshot get hostedGroups => HostedGroupsSnapshot(
    capabilities: capabilities,
    rooms: [for (final r in rooms) r.room],
    logs: [for (final r in rooms) ?r.log],
    driverStatuses: {
      for (final r in rooms)
        r.room.roomId: ?r.driverStatus,
    },
  );

  int get attentionCount =>
      rooms.fold(0, (sum, room) => sum + room.attention.count);
}

/// Bot Mode data layer (spec 070 T202): one pooled socket per connection,
/// incremental room logs and server-derived presence/attention.
///
/// Owns a [SharedGatewayLease]; [close] releases it (the pool sends the
/// WebSocket close frame when the last lease goes away).
final class BotModeRepository {
  final BotModeGateway gateway;
  final void Function()? onClose;
  final DateTime Function() _now;
  final int logPageLimit;
  final Map<String, RoomLogCursor> _cursors = {};
  int? _cursorGeneration;
  bool _closed = false;

  /// When set, every roster read is published to the connection's shared
  /// [BotRosterStore] ([rosterRegistry], else the shared registry).
  final SavedConnection? connection;
  final BotRosterRegistry? rosterRegistry;

  BotModeRepository({
    required this.gateway,
    this.onClose,
    this.connection,
    this.rosterRegistry,
    DateTime Function()? now,
    this.logPageLimit = 100,
  }) : _now = now ?? DateTime.now;

  factory BotModeRepository.pooled(
    SavedConnection connection, {
    SharedGatewayPool? pool,
    TuiGatewayClient Function(SavedConnection)? factory,
  }) {
    final lease = (pool ?? SharedGatewayPool.instance).acquire(
      connection,
      factory: factory,
    );
    return BotModeRepository(
      gateway: TuiBotModeGateway(lease.client),
      onClose: lease.release,
      connection: connection,
    );
  }

  bool get isClosed => _closed;

  /// Cursor for [roomId] (created lazily). Exposed for room views that poll
  /// one room with [RoomLogPoller].
  RoomLogCursor cursorFor(String roomId, {required int generation}) {
    if (_cursorGeneration != generation) {
      _cursors.clear();
      _cursorGeneration = generation;
    }
    return _cursors.putIfAbsent(
      roomId,
      () => RoomLogCursor(
        roomId: roomId,
        pageLimit: logPageLimit,
        load: ({required sinceSeq, required limit}) => gateway.groupLog(
          roomId,
          sinceSeq: sinceSeq,
          limit: limit,
          generation: generation,
        ),
      ),
    );
  }

  Future<BotModeSnapshot> load() async {
    _requireOpen();
    final connection = this.connection;
    final roster = connection == null
        ? null
        : rosterRegistry ?? BotRosterRegistry.shared;
    final rosterTicket = roster?.beginRead(connection!.id);
    final profilesFuture = gateway.listProfiles();
    final activeFuture = gateway.listActiveSessions().then<List<DesktopActiveSession>>(
      (list) => list.sessions,
      onError: (Object _) => const <DesktopActiveSession>[],
    );
    final roomsFuture = _loadRooms().then<({GroupsCapabilities? caps, List<BotModeRoom> rooms})>(
      (value) => value,
      onError: (Object _) => (caps: null, rooms: const <BotModeRoom>[]),
    );
    var profiles = await profilesFuture;
    final active = await activeFuture;
    final hosted = await roomsFuture;
    _requireOpen();
    if (roster != null) {
      // A bot created, renamed or deleted while this read was on the wire
      // stays as the store has it: an older roster never wins.
      final accepted = roster.publish(
        connection!.id,
        connection.label,
        profiles,
        ticket: rosterTicket,
        // [BotModeGateway.listProfiles] asks for session projections.
        sessions: true,
      );
      final store = roster.store(connection.id);
      if (!accepted && store.isLive) profiles = store.profiles;
    }
    final snapshot = HostedGroupsSnapshot(
      capabilities: hosted.caps,
      rooms: [for (final r in hosted.rooms) r.room],
      logs: [for (final r in hosted.rooms) ?r.log],
      driverStatuses: {
        for (final r in hosted.rooms)
          r.room.roomId: ?r.driverStatus,
      },
    );
    final attention = AttentionSummary.fromSnapshot(snapshot);
    final now = _now();
    final bots = [
      for (final profile in profiles)
        BotModeRow(
          profile: profile,
          presence: BotPresence.derive(
            profile: profile,
            now: now,
            liveSessions: active,
            roomSeats: BotRoomSeat.forProfile(profile.name, snapshot),
          ),
          chat: BotChatTarget.resolve(profile, now: now),
          attention: attention.forProfile(profile.name, snapshot),
        ),
    ];
    final hostedIds = {for (final r in hosted.rooms) r.room.roomId};
    final defaults = profiles.where((p) => p.isDefault || p.name == 'default');
    return BotModeSnapshot(
      bots: List.unmodifiable(bots),
      rooms: hosted.rooms,
      projectionRooms: defaults.isEmpty
          ? DesktopProjectionRooms.empty
          : DesktopProjectionRooms.parse(
              defaults.first.groupsProjection,
              hostedRoomIds: hostedIds,
            ),
      capabilities: hosted.caps,
      loadedAt: now,
    );
  }

  Future<({GroupsCapabilities? caps, List<BotModeRoom> rooms})>
  _loadRooms() async {
    final caps = await gateway.groupCapabilities();
    if (!caps.hasSharedRoomSurface) return (caps: caps, rooms: const <BotModeRoom>[]);
    final listed = await gateway.listGroups(generation: caps.generation);
    final rooms = <BotModeRoom>[];
    for (final listedRoom in listed) {
      rooms.add(await refreshRoom(listedRoom.roomId, generation: caps.generation));
    }
    return (caps: caps, rooms: List<BotModeRoom>.unmodifiable(rooms));
  }

  /// One room refresh: `groups.state` (with driver status) plus an
  /// incremental `groups.log` from the room's cursor. No new socket.
  Future<BotModeRoom> refreshRoom(
    String roomId, {
    required int generation,
  }) async {
    _requireOpen();
    final state = await gateway.groupState(roomId, generation: generation);
    final cursor = cursorFor(roomId, generation: generation);
    final delta = await cursor.pull();
    return BotModeRoom(
      room: state.room,
      driverStatus: state.driverStatus,
      log: delta.log,
      attention: RoomAttention.derive(
        room: state.room,
        driverStatus: state.driverStatus,
        log: delta.log,
      ),
    );
  }

  Future<HostedGroupRoom> stop(String roomId, {required int generation}) {
    _requireOpen();
    return gateway.stopGroup(roomId, generation: generation);
  }

  /// Only retries a task the server itself lists as retryable.
  Future<HostedGroupRoom> retry(
    BotModeRoom room, {
    required String taskId,
    required int generation,
  }) {
    _requireOpen();
    if (room.driverStatus?.offersRetry(taskId) != true) {
      throw StateError('task is not retryable');
    }
    return gateway.retryGroupTask(
      room.room.roomId,
      taskId: taskId,
      generation: generation,
    );
  }

  /// Answers a pending approval with one of the server-offered choices.
  Future<HostedGroupRoom> approve(
    BotModeRoom room, {
    required RoomApprovalAction action,
    required String choice,
    required int generation,
  }) {
    _requireOpen();
    final current = room.driverStatus?.approvalFor(
      taskId: action.taskId,
      requestId: action.requestId,
    );
    if (current == null || !current.offers(choice)) {
      throw StateError('approval is not pending or choice not offered');
    }
    return gateway.approveGroupTask(
      room.room.roomId,
      action: current,
      choice: choice,
      generation: generation,
    );
  }

  /// Canonical Bot Chat target, falling back to Desktop's title lookup
  /// when `profiles.list` did not carry `canonical_session`.
  Future<BotChatTarget> resolveBotChat(AgentProfile profile) async {
    _requireOpen();
    final direct = BotChatTarget.resolve(profile, now: _now());
    if (direct.exists) return direct;
    final found = await gateway.findBotChatByTitle(profile.name);
    return BotChatTarget.resolve(profile, titleLookup: found, now: _now());
  }

  void _requireOpen() {
    if (_closed) throw StateError('BotModeRepository is closed');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _cursors.clear();
    onClose?.call();
  }
}
