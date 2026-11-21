import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../bots/data/room_driver_status.dart';
import 'bot_mode_v13.dart';

export '../bots/data/room_driver_status.dart';

enum GroupMethod {
  capabilities('groups.capabilities'),
  list('groups.list'),
  create('groups.create'),
  state('groups.state'),
  send('groups.send'),
  rename('groups.rename'),
  log('groups.log'),
  disband('groups.disband'),
  stop('groups.stop'),
  retry('groups.retry'),
  approve('groups.approve'),
  promote('groups.promote'),

  /// The room's own file store (`tui_gateway/methods_groups.py`
  /// `groups.attachment.upload` / `groups.attachment.download`, both handled
  /// by `gateway/session_hosted_attachments.py`).
  attachmentUpload('groups.attachment.upload'),
  attachmentDownload('groups.attachment.download');

  final String wire;
  const GroupMethod(this.wire);

  static GroupMethod? official(String wire) {
    for (final method in values) {
      // `send` is official: Console now proves a complete room log before
      // ever advertising it (see `HostedGroupLogPage.loadComplete` and
      // `docs/hosted_identity_transition_matrix.md`). `retry` and `promote`
      // stay retired for their own, unrelated reasons (no revision/log-
      // position/execution-generation binding for retry; gateway-authority
      // federation, not a client concern, for promote).
      if (method == promote || method == retry) continue;
      if (method.wire == wire) return method;
    }
    return null;
  }
}

/// Authenticated, generation-scoped evidence. Unknown and malformed envelopes
/// do not produce an instance, so callers have no permissive fallback.
final class GroupsCapabilities {
  final String connectionId;
  final int generation;
  final int protocolVersion;
  final bool driverReady;
  final int maxLogLimit;
  final Set<GroupMethod> methods;

  const GroupsCapabilities._({
    required this.connectionId,
    required this.generation,
    required this.protocolVersion,
    required this.driverReady,
    required this.maxLogLimit,
    required this.methods,
  });

  static GroupsCapabilities? tryParse(
    Object? value, {
    required String connectionId,
    required int generation,
  }) {
    if (value is! Map || connectionId.trim().isEmpty || generation < 0) {
      return null;
    }
    final raw = Map<String, dynamic>.from(value);
    final version = raw['protocol_version'];
    final driver = raw['driver'];
    final limit = raw['max_log_limit'];
    final methodValues = raw['methods'];
    if (version is! int ||
        version < 1 ||
        driver is! bool ||
        limit is! int ||
        limit < 1 ||
        limit > 500 ||
        methodValues is! List ||
        methodValues.any((entry) => entry is! String)) {
      return null;
    }
    final parsed = <GroupMethod>{};
    for (final entry in methodValues.cast<String>()) {
      final method = GroupMethod.official(entry);
      if (method != null) parsed.add(method);
    }
    if (!parsed.contains(GroupMethod.capabilities)) return null;
    return GroupsCapabilities._(
      connectionId: connectionId,
      generation: generation,
      protocolVersion: version,
      driverReady: driver,
      maxLogLimit: limit,
      methods: Set.unmodifiable(parsed),
    );
  }

  bool supports(GroupMethod method) =>
      method != GroupMethod.promote &&
      method != GroupMethod.retry &&
      methods.contains(method) &&
      (method == GroupMethod.capabilities ||
          method == GroupMethod.list ||
          method == GroupMethod.state ||
          method == GroupMethod.log ||
          // A read of a committed file: the server needs its room service,
          // not a running driver (`groups.attachment.download` has no
          // driver check), and Desktop offers it on the method list alone
          // (`canonical-group-capabilities.ts::offersGroupMethod`).
          method == GroupMethod.attachmentDownload ||
          driverReady);

  bool get hasSharedRoomSurface =>
      supports(GroupMethod.list) &&
      supports(GroupMethod.state) &&
      supports(GroupMethod.log);
}

final class GroupsCapabilityCache {
  /// [unsupported] tells a loader error that proves the server has no
  /// `groups.*` at all (JSON-RPC «method not found»). It is passed to the
  /// caller instead of being read as «no evidence», and never cached.
  GroupsCapabilityCache({this._unsupported});

  final bool Function(Object error)? _unsupported;
  String? _connectionId;
  int? _generation;
  GroupsCapabilities? _value;
  Future<GroupsCapabilities?>? _flight;

  Future<GroupsCapabilities?> resolve({
    required String connectionId,
    required int generation,
    required Future<Object?> Function() loader,
  }) {
    if (_connectionId != connectionId || _generation != generation) {
      _connectionId = connectionId;
      _generation = generation;
      _value = null;
      _flight = null;
    }
    final value = _value;
    if (value != null) return Future.value(value);
    final flight = _flight;
    if (flight != null) return flight;
    final next = _load(connectionId, generation, loader);
    _flight = next;
    return next;
  }

  Future<GroupsCapabilities?> _load(
    String connectionId,
    int generation,
    Future<Object?> Function() loader,
  ) async {
    GroupsCapabilities? parsed;
    try {
      parsed = GroupsCapabilities.tryParse(
        await loader(),
        connectionId: connectionId,
        generation: generation,
      );
    } catch (error) {
      if (_unsupported?.call(error) ?? false) {
        if (_connectionId == connectionId && _generation == generation) {
          _flight = null;
        }
        rethrow;
      }
      parsed = null;
    }
    if (_connectionId == connectionId && _generation == generation) {
      // Driver readiness is transient (startup/recovery), not a socket
      // capability. Do not freeze an unavailable driver for this generation.
      _value = parsed?.driverReady == true ? parsed : null;
      _flight = null;
    }
    return parsed;
  }

  void revoke() {
    _connectionId = null;
    _generation = null;
    _value = null;
    _flight = null;
  }
}

sealed class HostedGroupCreateTarget {
  const HostedGroupCreateTarget();

  Map<String, dynamic> toWire();
}

final class HostedGroupLocalCreateTarget extends HostedGroupCreateTarget {
  final String profile;

  HostedGroupLocalCreateTarget(String profile)
    : profile = _boundedString(profile, 'local target profile', 128);

  @override
  Map<String, dynamic> toWire() => {'kind': 'local', 'profile': profile};
}

final class HostedGroupPeerCreateTarget extends HostedGroupCreateTarget {
  final String peerId;
  final String installationId;
  final String profile;
  final String capabilityDigest;

  HostedGroupPeerCreateTarget({
    required String peerId,
    required String installationId,
    required String profile,
    required String capabilityDigest,
  }) : peerId = _boundedString(peerId, 'peer id', 128),
       installationId = _boundedString(installationId, 'installation id', 128),
       profile = _boundedString(profile, 'peer target profile', 128),
       capabilityDigest = _sha256Digest(capabilityDigest);

  @override
  Map<String, dynamic> toWire() => {
    'kind': 'peer',
    'peer_id': peerId,
    'installation_id': installationId,
    'profile': profile,
    'capability_digest': capabilityDigest,
  };
}

final class HostedGroupCreateMember {
  final String profile;
  final String handle;
  final HostedGroupCreateTarget target;

  HostedGroupCreateMember._({
    required String profile,
    required String handle,
    required this.target,
  }) : profile = _boundedString(profile, 'member profile', 128),
       handle = _boundedString(handle, 'member handle', 128) {
    final targetProfile = switch (target) {
      HostedGroupLocalCreateTarget value => value.profile,
      HostedGroupPeerCreateTarget value => value.profile,
    };
    if (targetProfile != this.profile) {
      throw const FormatException('member target profile mismatch');
    }
  }

  factory HostedGroupCreateMember.localProfile({
    required String profile,
    required String handle,
  }) => HostedGroupCreateMember._(
    profile: profile,
    handle: handle,
    target: HostedGroupLocalCreateTarget(profile),
  );

  factory HostedGroupCreateMember.peer({
    required String profile,
    required String handle,
    required String peerId,
    required String installationId,
    required String capabilityDigest,
  }) => HostedGroupCreateMember._(
    profile: profile,
    handle: handle,
    target: HostedGroupPeerCreateTarget(
      peerId: peerId,
      installationId: installationId,
      profile: profile,
      capabilityDigest: capabilityDigest,
    ),
  );

  Map<String, dynamic> toWire({required String memberId}) => {
    'member_id': _boundedString(memberId, 'member id', 128),
    'profile': profile,
    'handle': handle,
    'target': target.toWire(),
  };
}

/// Upstream `_REMOTE_MEMBER_FIELDS` (v0.23.1 hosted_room_discussion.py):
/// member-level fields that would name another gateway or route.
const Set<String> _remoteMemberFields = {
  'connectionId',
  'connectionKind',
  'connectionLabel',
  'connection_id',
  'connection_kind',
  'connection_label',
  'remoteSource',
  'route',
  'sourceMissing',
  'sourceReachable',
  'sourceScoped',
  'targetProfile',
  'target_profile',
};

final class HostedGroupMember {
  final String memberId;
  final String handle;
  final String? displayName;
  final AvatarOwner owner;

  const HostedGroupMember._({
    required this.memberId,
    required this.handle,
    required this.displayName,
    required this.owner,
  });

  factory HostedGroupMember.fromJson(
    Object? value, {
    required String authorityGatewayId,
  }) {
    final raw = _map(value, 'member');
    // An open row (stable 0.23.1 contracts/groups_bot_relay.py RoomMember:
    // «legacy rooms may carry pre-normalisation rows, so the set stays
    // open»): fields Console does not use are ignored, never kept or shown;
    // the ones it uses (below) are validated as before. Fields that would
    // place the member on another gateway stay rejected, exactly as upstream
    // `_validate_member` does (`_REMOTE_MEMBER_FIELDS`, v0.23.1
    // hosted_room_discussion.py): only `target` decides where a member is.
    if (raw.keys.any(_remoteMemberFields.contains)) {
      throw const FormatException('member carries cross-gateway fields');
    }
    final profile = _boundedString(raw['profile'], 'member profile', 128);
    // Upstream `_validate_member_target(None)` (hosted_room_discussion.py):
    // a row stored before `target` existed is a local member of its own
    // profile. Any present target, `{}` included, is still validated.
    final target = raw['target'] == null
        ? <String, dynamic>{'kind': 'local', 'profile': profile}
        : _map(raw['target'], 'member target');
    final kind = _boundedString(target['kind'], 'member target kind', 16);
    late final String connectionId;
    if (kind == 'local') {
      _requireExactFields(target, const {
        'kind',
        'profile',
      }, 'local member target');
      connectionId = authorityGatewayId;
    } else if (kind == 'peer') {
      _requireExactFields(target, const {
        'kind',
        'peer_id',
        'installation_id',
        'profile',
        'capability_digest',
      }, 'peer member target');
      connectionId = _boundedString(target['peer_id'], 'member peer id', 128);
      _boundedString(target['installation_id'], 'member installation id', 128);
      _sha256Digest(
        target['capability_digest'] is String
            ? target['capability_digest'] as String
            : '',
      );
    } else {
      throw const FormatException('invalid member target kind');
    }
    if (_boundedString(target['profile'], 'member target profile', 128) !=
        profile) {
      throw const FormatException('member target profile mismatch');
    }
    return HostedGroupMember._(
      memberId: _string(raw['member_id'], 'member id'),
      handle: _string(raw['handle'], 'member handle'),
      displayName: _optionalCanonicalString(
        raw,
        'display_name',
        'member display name',
        200,
      ),
      owner: AvatarOwner(connectionId: connectionId, profile: profile),
    );
  }
}

final class HostedGroupRoom {
  final String roomId;
  final String name;
  final List<HostedGroupMember> members;
  final String authorityGatewayId;
  final int authorityEpoch;
  final int revision;
  final int latestSeq;

  /// Whether the gateway sent `latest_seq`; older rows omit it and
  /// [latestSeq] then reads 0 without proving the log is empty.
  final bool latestSeqKnown;
  final bool disbanded;

  /// The room's last change (`updated_at`): its age and recency in the
  /// room list, as in Hermes Desktop (`canonical-group-registry.tsx`
  /// `GatewayGroupRoom.updatedAt`).
  final DateTime updatedAt;
  final Map<String, dynamic> _testJson;

  const HostedGroupRoom._({
    required this.roomId,
    required this.name,
    required this.members,
    required this.authorityGatewayId,
    required this.authorityEpoch,
    required this.revision,
    required this.latestSeq,
    required this.latestSeqKnown,
    required this.disbanded,
    required this.updatedAt,
    required this._testJson,
  });

  factory HostedGroupRoom.fromJson(Object? value) {
    final raw = _map(value, 'room');
    final rawMembers = raw['members'];
    if (rawMembers is! List || rawMembers.length > 128) {
      throw const FormatException('invalid room members');
    }
    final roomId = _string(raw['room_id'], 'room id');
    final authorityGatewayId = _string(
      raw['authority_gateway_id'],
      'room authority',
    );
    final epoch = _positiveInt(raw['authority_epoch'], 'authority epoch');
    final revision = _positiveInt(raw['revision'], 'room revision');
    final latest = raw['latest_seq'] ?? 0;
    if (latest is! int || latest < 0) {
      throw const FormatException('invalid latest sequence');
    }

    _number(raw['created_at'], 'room creation');
    final updated = _number(raw['updated_at'], 'room update');
    if (raw.containsKey('disbanded_at')) {
      _number(raw['disbanded_at'], 'room disband');
    }
    return HostedGroupRoom._(
      roomId: roomId,
      name: _boundedString(raw['name'], 'room name', 200),
      members: List.unmodifiable(
        rawMembers.map(
          (member) => HostedGroupMember.fromJson(
            member,
            authorityGatewayId: authorityGatewayId,
          ),
        ),
      ),
      authorityGatewayId: authorityGatewayId,
      authorityEpoch: epoch,
      revision: revision,
      latestSeq: latest,
      latestSeqKnown: raw['latest_seq'] != null,
      disbanded: raw['disbanded_at'] != null,
      // Epoch seconds; milliseconds tolerated, as for event times.
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (updated > 1e12 ? updated : updated * 1000).round(),
      ),
      testJson: Map.unmodifiable(raw),
    );
  }

  Map<String, dynamic> toJsonForTest() => Map.of(_testJson);
}

/// Why a listed room could not be shown.
enum HostedGroupUnreadableReason {
  /// The server sent data this Console does not accept (a malformed row,
  /// state or log).
  invalidData,

  /// The server answered this room's read with an error of its own.
  serverError,
}

/// A room the server listed but Console could not read. Only the room id
/// (when the row had a valid one) and, for a row that did parse, its name are
/// kept: nothing else from a rejected row is ever shown.
final class HostedGroupUnreadableRoom {
  final String? roomId;
  final String? name;
  final HostedGroupUnreadableReason reason;

  const HostedGroupUnreadableRoom({
    required this.roomId,
    required this.reason,
    this.name,
  });

  /// The room id of a rejected list row, when it is a valid identifier.
  static String? idOfRow(Object? row) {
    if (row is! Map) return null;
    try {
      return _string(row['room_id'], 'room id');
    } on FormatException {
      return null;
    }
  }
}

/// One typed page from the official `groups.list` offset protocol.
///
/// Completeness is deliberately not claimed here: only the loader that follows
/// every authenticated `next_offset` on one socket lease can publish a list.
///
/// A row that fails validation is kept apart in [unreadable] instead of
/// failing the page, so one room this Console cannot read never hides the
/// others. The page envelope itself stays strict.
final class HostedGroupListPage {
  final List<HostedGroupRoom> rooms;
  final List<HostedGroupUnreadableRoom> unreadable;
  final int? nextOffset;

  /// Rows the server sent on this page, readable or not (the offset
  /// protocol counts rows, not what Console could parse).
  final int rowCount;

  const HostedGroupListPage._({
    required this.rooms,
    required this.unreadable,
    required this.nextOffset,
    required this.rowCount,
  });

  factory HostedGroupListPage.fromJson(Object? value) {
    final raw = _map(value, 'room list page');
    final rows = raw['rooms'];
    final next = raw['next_offset'];
    if (rows is! List ||
        rows.length > 500 ||
        (next != null && (next is! int || next < 0))) {
      throw const FormatException('invalid room list page');
    }
    final rooms = <HostedGroupRoom>[];
    final unreadable = <HostedGroupUnreadableRoom>[];
    for (final row in rows) {
      try {
        rooms.add(HostedGroupRoom.fromJson(row));
      } on FormatException {
        unreadable.add(
          HostedGroupUnreadableRoom(
            roomId: HostedGroupUnreadableRoom.idOfRow(row),
            reason: HostedGroupUnreadableReason.invalidData,
          ),
        );
      }
    }
    return HostedGroupListPage._(
      rooms: List.unmodifiable(rooms),
      unreadable: List.unmodifiable(unreadable),
      nextOffset: next as int?,
      rowCount: rows.length,
    );
  }
}

/// Every room of a complete `groups.list` read: the ones Console can show and
/// the ones it could not read.
final class HostedGroupListing {
  final List<HostedGroupRoom> rooms;
  final List<HostedGroupUnreadableRoom> unreadable;

  const HostedGroupListing({
    required this.rooms,
    this.unreadable = const [],
  });
}

final class HostedGroupWorkspaceReadback {
  final HostedGroupRoom room;
  final HostedGroupLogPage? log;
  final int capabilityGeneration;

  /// Server driver evidence read with [room]; `null` on older gateways.
  final RoomDriverStatus? driverStatus;

  /// `groups.state.change_events`: the backend pushes `groups.changed`
  /// when this room moves, so an open view may poll only as a backstop.
  /// False on backends that do not say so.
  final bool changeEvents;

  const HostedGroupWorkspaceReadback({
    required this.room,
    required this.log,
    required this.capabilityGeneration,
    this.driverStatus,
    this.changeEvents = false,
  });
}

final class HostedGroupSendAttempt {
  final String clientEventId;
  final String threadId;

  const HostedGroupSendAttempt._({
    required this.clientEventId,
    required this.threadId,
  });

  factory HostedGroupSendAttempt.forClientEvent(
    String clientEventId, {
    String? threadId,
  }) {
    final client = _boundedString(clientEventId, 'client event id', 128);
    final thread = _boundedString(
      threadId ?? 'thread-$client',
      'thread id',
      128,
    );
    return HostedGroupSendAttempt._(clientEventId: client, threadId: thread);
  }

  /// The id Hermes gives the durable `message.user` event of this attempt,
  /// so a local pending message can be matched to its server event.
  String get durableEventId =>
      'user:${sha256.convert(utf8.encode(clientEventId))}';
}

final class HostedGroupActor {
  final String kind;
  final String id;
  final String? displayName;
  final String? profile;
  final String? connectionId;

  const HostedGroupActor._({
    required this.kind,
    required this.id,
    required this.displayName,
    required this.profile,
    required this.connectionId,
  });

  factory HostedGroupActor.fromJson(Object? value) {
    final raw = _map(value, 'event actor');
    _requireOnlyFields(raw, const {
      'kind',
      'id',
      'display_name',
      'profile',
      'connection_id',
    }, 'event actor');
    return HostedGroupActor._(
      kind: _string(raw['kind'], 'actor kind'),
      id: _boundedString(raw['id'], 'actor id', 128),
      displayName: _optionalCanonicalString(
        raw,
        'display_name',
        'actor display name',
        200,
      ),
      profile: _optionalCanonicalString(raw, 'profile', 'actor profile', 128),
      connectionId: _optionalCanonicalString(
        raw,
        'connection_id',
        'actor connection id',
        128,
      ),
    );
  }

  bool immutableEquals(HostedGroupActor other) =>
      kind == other.kind &&
      id == other.id &&
      displayName == other.displayName &&
      profile == other.profile &&
      connectionId == other.connectionId;

  /// The only actor identity permitted to cross the presentation boundary.
  String get publicLabel => displayName ?? kind;
}

final class HostedGroupAuthority {
  final String gatewayId;
  final int epoch;

  const HostedGroupAuthority._({required this.gatewayId, required this.epoch});

  factory HostedGroupAuthority.fromJson(Object? value) {
    final raw = _map(value, 'room log authority');
    return HostedGroupAuthority._(
      gatewayId: _string(raw['gateway_id'], 'authority gateway'),
      epoch: _positiveInt(raw['epoch'], 'authority epoch'),
    );
  }
}

final class _HostedGroupDeferredTurn {
  final String discussionEventId;
  final String memberId;
  final int memberIndex;
  final int roundIndex;
  final String taskId;
  final String threadId;
  final String turnId;
  final int seenThroughSeq;
  final int executionGeneration;
  final String reason;

  const _HostedGroupDeferredTurn._({
    required this.discussionEventId,
    required this.memberId,
    required this.memberIndex,
    required this.roundIndex,
    required this.taskId,
    required this.threadId,
    required this.turnId,
    required this.seenThroughSeq,
    required this.executionGeneration,
    required this.reason,
  });

  factory _HostedGroupDeferredTurn.fromJson(Map<String, dynamic> raw) {
    _requireExactFields(raw, const {
      'discussion_event_id',
      'member_id',
      'member_index',
      'round_index',
      'task_id',
      'thread_id',
      'turn_id',
      'seen_through_seq',
      'execution_generation',
      'reason',
    }, 'turn.deferred payload');
    final memberIndex = raw['member_index'];
    final roundIndex = raw['round_index'];
    if (memberIndex is! int ||
        memberIndex < 0 ||
        memberIndex > 5 ||
        roundIndex is! int ||
        // Upstream accepts any non-negative round: a room continued on
        // Desktop publishes rounds past the scheduling budget, and lowering
        // the budget must not invalidate them (hosted_room_discussion.py
        // `_validate_turn_coordinates`, main 491f984).
        roundIndex < 0) {
      throw const FormatException('invalid turn.deferred coordinates');
    }
    return _HostedGroupDeferredTurn._(
      discussionEventId: _boundedString(
        raw['discussion_event_id'],
        'discussion event id',
        128,
      ),
      memberId: _boundedString(raw['member_id'], 'deferred member id', 128),
      memberIndex: memberIndex,
      roundIndex: roundIndex,
      taskId: _boundedString(raw['task_id'], 'deferred task id', 128),
      threadId: _boundedString(raw['thread_id'], 'deferred thread id', 128),
      turnId: _boundedString(raw['turn_id'], 'deferred turn id', 128),
      seenThroughSeq: _positiveInt(
        raw['seen_through_seq'],
        'deferred seen through sequence',
      ),
      executionGeneration: _positiveInt(
        raw['execution_generation'],
        'deferred execution generation',
      ),
      reason: _boundedString(raw['reason'], 'deferred reason', 1024),
    );
  }
}

final class HostedGroupRetryAction {
  final String _roomId;
  final String _gatewayId;
  final int _authorityEpoch;
  final int _capabilityGeneration;
  final String _taskId;
  final int _roomRevision;
  final int _roomLatestSeq;
  final int _logCursor;
  final int _logLatestSeq;
  final String _deferredEventId;
  final int _deferredSequence;
  final int _seenThroughSeq;
  final int _executionGeneration;

  const HostedGroupRetryAction._({
    required this._roomId,
    required this._gatewayId,
    required this._authorityEpoch,
    required this._capabilityGeneration,
    required this._taskId,
    required this._roomRevision,
    required this._roomLatestSeq,
    required this._logCursor,
    required this._logLatestSeq,
    required this._deferredEventId,
    required this._deferredSequence,
    required this._seenThroughSeq,
    required this._executionGeneration,
  });

  String taskIdForTransport({
    required HostedGroupRoom room,
    required HostedGroupLogPage log,
    required GroupsCapabilities capabilities,
  }) {
    if (room.roomId != _roomId ||
        room.authorityGatewayId != _gatewayId ||
        room.authorityEpoch != _authorityEpoch ||
        room.revision != _roomRevision ||
        room.latestSeq != _roomLatestSeq ||
        log.authority.gatewayId != _gatewayId ||
        log.authority.epoch != _authorityEpoch ||
        log.cursor != _logCursor ||
        log.latestSeq != _logLatestSeq ||
        capabilities.generation != _capabilityGeneration ||
        !capabilities.supports(GroupMethod.retry) ||
        !log
            .retryActions(room: room, capabilities: capabilities)
            .any((candidate) => candidate._sameProof(this))) {
      throw StateError('hosted retry authority changed');
    }
    return _taskId;
  }

  bool _sameProof(HostedGroupRetryAction other) =>
      _roomId == other._roomId &&
      _gatewayId == other._gatewayId &&
      _authorityEpoch == other._authorityEpoch &&
      _capabilityGeneration == other._capabilityGeneration &&
      _taskId == other._taskId &&
      _roomRevision == other._roomRevision &&
      _roomLatestSeq == other._roomLatestSeq &&
      _logCursor == other._logCursor &&
      _logLatestSeq == other._logLatestSeq &&
      _deferredEventId == other._deferredEventId &&
      _deferredSequence == other._deferredSequence &&
      _seenThroughSeq == other._seenThroughSeq &&
      _executionGeneration == other._executionGeneration;
}

/// Public, bounded room activity coordinates. Never expose prompts, errors or
/// arbitrary payload fields through the presentation model.
final class HostedGroupActivityDetails {
  final String? memberId;
  final String? discussionId;
  final String? threadId;
  final String? taskId;
  final String? description;
  final String? status;
  final String? messageEventId;
  final String? reasonCode;
  final bool passed;

  /// Round of the discussion this turn belongs to (`round_index`, 0-based).
  final int? roundIndex;

  HostedGroupActivityDetails.fromJson(Map<String, dynamic> payload)
    : memberId = _text(payload['member_id']),
      discussionId = _text(payload['discussion_event_id']),
      threadId = _text(payload['thread_id']),
      taskId = _text(payload['task_id']),
      description =
          _text(payload['description']) ??
          _text(payload['task_title']) ??
          _text(payload['title']),
      status = _text(payload['status']),
      messageEventId = _text(payload['message_event_id']),
      // Only translated, recognized codes are rendered, never raw errors.
      reasonCode = _text(payload['reason_code']) ?? _text(payload['reason']),
      passed = payload['passed'] == true,
      roundIndex =
          payload['round_index'] is int && (payload['round_index'] as int) >= 0
          ? payload['round_index'] as int
          : null;

  static String? _text(Object? value) {
    if (value is! String || value.trim().isEmpty || value.length > 512) {
      return null;
    }
    return value.trim();
  }
}

/// One file of a room message: an entry of the `attachments` manifest
/// (`gateway/hosted_room_attachments.py::validate_manifest` upstream).
/// Metadata only; Console shows it but does not download room files.
/// Bidi controls (embeddings, overrides, isolates and marks). A name that
/// carries them could paint as something else (`invoice<RLO>fdp.exe` reads
/// `invoiceexe.pdf`); upstream accepts them in a file name, so Console keeps
/// the name as sent and drops them only where it paints it.
final RegExp _bidiControls = RegExp('[\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]');

/// [text] without bidi controls, for painting a server-supplied name.
String withoutBidiControls(String text) => text.replaceAll(_bidiControls, '');

final class HostedGroupAttachment {
  static const int maxPerMessage = 8;
  static const int maxBytes = 15000000;
  static const int maxMessageBytes = 25000000;
  static const int _maxNameChars = 255;
  static const int _maxMimeChars = 127;
  static const Set<String> kinds = {'image', 'pdf', 'file'};
  static const Set<String> _fields = {
    'attachment_id',
    'kind',
    'name',
    'size',
    'mime',
  };
  static final RegExp _id = RegExp(r'^att_[0-9a-f]{32}$');
  static final RegExp _mime = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*$',
  );

  final String attachmentId;

  /// `image`, `pdf` or `file`.
  final String kind;
  final String name;
  final int size;
  final String mime;

  const HostedGroupAttachment._({
    required this.attachmentId,
    required this.kind,
    required this.name,
    required this.size,
    required this.mime,
  });

  factory HostedGroupAttachment.fromJson(Object? value) {
    final raw = _map(value, 'attachment');
    _requireExactFields(raw, _fields, 'attachment');
    final id = raw['attachment_id'];
    if (id is! String || !_id.hasMatch(id)) {
      throw const FormatException('invalid attachment id');
    }
    final size = raw['size'];
    if (size is! int || size < 1 || size > maxBytes) {
      throw const FormatException('invalid attachment size');
    }
    final kind = raw['kind'];
    if (kind is! String || !kinds.contains(kind)) {
      throw const FormatException('invalid attachment kind');
    }
    final rawMime = raw['mime'];
    if (rawMime is! String) throw const FormatException('invalid attachment mime');
    final mime = rawMime.trim().toLowerCase();
    if (mime.isEmpty || mime.length > _maxMimeChars || !_mime.hasMatch(mime)) {
      throw const FormatException('invalid attachment mime');
    }
    if ((kind == 'image' && !mime.startsWith('image/')) ||
        (kind == 'pdf' && mime != 'application/pdf')) {
      throw const FormatException('attachment kind and mime disagree');
    }
    final rawName = raw['name'];
    if (rawName is! String) throw const FormatException('invalid attachment name');
    final name = rawName.trim();
    if (name.isEmpty ||
        name.runes.length > _maxNameChars ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains(r'\') ||
        name.contains('\x00') ||
        name.contains('\n') ||
        name.contains('\r')) {
      throw const FormatException('invalid attachment name');
    }
    return HostedGroupAttachment._(
      attachmentId: id,
      kind: kind,
      name: name,
      size: size,
      mime: mime,
    );
  }

  /// [name] as it may be painted: no bidi controls (see
  /// [withoutBidiControls]); the file kind when nothing else is left.
  String get displayName {
    final shown = withoutBidiControls(name).trim();
    return shown.isEmpty ? kind : shown;
  }

  /// This entry as a `groups.send` payload lists it: exactly the five
  /// fields the server compares with the stored row
  /// (`gateway/hosted_room_attachments.py::commit_message_with_receipt`).
  Map<String, Object> toManifest() => {
    'attachment_id': attachmentId,
    'kind': kind,
    'name': name,
    'size': size,
    'mime': mime,
  };

  /// A whole message manifest: a list of at most [maxPerMessage] entries
  /// with unique ids and at most [maxMessageBytes] in total.
  static List<HostedGroupAttachment> manifest(Object? value) {
    if (value is! List || value.length > maxPerMessage) {
      throw const FormatException('invalid attachment manifest');
    }
    final entries = [for (final entry in value) HostedGroupAttachment.fromJson(entry)];
    final ids = {for (final entry in entries) entry.attachmentId};
    final total = entries.fold<int>(0, (sum, entry) => sum + entry.size);
    if (ids.length != entries.length || total > maxMessageBytes) {
      throw const FormatException('invalid attachment manifest');
    }
    return List.unmodifiable(entries);
  }
}

final class HostedGroupEvent {
  final String roomId;
  final int sequence;
  final String eventId;
  final String kind;
  final HostedGroupActor actor;
  final int authorityEpoch;

  /// The message text of `message.user`/`message.member`, null for other
  /// kinds. Empty (never null) for an owner message that carries only
  /// [attachments].
  final String? publicText;
  final String? threadId;
  final num createdAt;
  final bool idempotent;
  final HostedGroupActivityDetails activity;

  /// Files of a `message.user` (validated manifest) or `message.member`
  /// (shown only when its manifest is valid).
  final List<HostedGroupAttachment> attachments;

  /// A `message.member` came with an `attachments` manifest Console does not
  /// accept: its files are not in [attachments], and the room says so
  /// instead of hiding them silently.
  final bool attachmentsRejected;
  final String _canonicalPayload;
  final _HostedGroupDeferredTurn? _deferredTurn;
  final String? _terminalTaskId;

  const HostedGroupEvent._({
    required this.roomId,
    required this.sequence,
    required this.eventId,
    required this.kind,
    required this.actor,
    required this.authorityEpoch,
    required this.publicText,
    required this.threadId,
    required this.createdAt,
    required this.idempotent,
    required this.activity,
    required this.attachments,
    this.attachmentsRejected = false,
    required this._canonicalPayload,
    required this._deferredTurn,
    required this._terminalTaskId,
  });

  factory HostedGroupEvent.fromJson(Object? value, {required String roomId}) {
    final raw = _map(value, 'event');
    final actualRoom = _string(raw['room_id'], 'event room');
    if (actualRoom != roomId) {
      throw const FormatException('event room mismatch');
    }
    final kind = _string(raw['kind'], 'event kind');
    final actor = HostedGroupActor.fromJson(raw['actor']);
    final epoch = _positiveInt(raw['authority_epoch'], 'event authority');
    final createdAt = _number(raw['created_at'], 'event creation');
    final idempotent = raw['idempotent'];
    if (idempotent is! bool) {
      throw const FormatException('invalid event idempotency');
    }
    final payload = _map(raw['payload'], 'event payload');
    String? text;
    String? thread;
    var attachments = const <HostedGroupAttachment>[];
    var attachmentsRejected = false;
    _HostedGroupDeferredTurn? deferredTurn;
    String? terminalTaskId;
    if (kind == 'message.user') {
      // Upstream `validate_user_payload`: {text, thread_id} plus the
      // optional `attachments` manifest, nothing else (closed schema).
      if (payload.containsKey('attachments')) {
        _requireExactFields(payload, const {
          'text',
          'thread_id',
          'attachments',
        }, 'message.user payload');
        attachments = HostedGroupAttachment.manifest(payload['attachments']);
      } else {
        _requireExactFields(payload, const {
          'text',
          'thread_id',
        }, 'message.user payload');
      }
      // Blank text only when the message carries files.
      text = attachments.isEmpty
          ? _messageText(payload['text'], 'message text')
          : _attachmentCaption(payload['text']);
      thread = _boundedString(payload['thread_id'], 'thread id', 128);
    } else if (kind == 'message.member') {
      text = _messageText(payload['text'], 'message text');
      thread = _boundedString(payload['thread_id'], 'thread id', 128);
      // Display-only: a member manifest Console cannot read hides the files,
      // never the message (this kind's other fields were never closed).
      final manifest = payload['attachments'];
      if (manifest != null) {
        try {
          attachments = HostedGroupAttachment.manifest(manifest);
        } on FormatException {
          attachments = const [];
          attachmentsRejected = true;
        }
      }
    } else if (kind == 'turn.deferred') {
      deferredTurn = _HostedGroupDeferredTurn.fromJson(payload);
      terminalTaskId = deferredTurn.taskId;
    } else if (kind == 'turn.settled' ||
        kind == 'turn.failed' ||
        kind == 'turn.cancelled') {
      final candidate = payload['task_id'];
      if (candidate is String) {
        try {
          terminalTaskId = _boundedString(candidate, 'terminal task id', 128);
        } on FormatException {
          terminalTaskId = null;
        }
      }
    }
    return HostedGroupEvent._(
      roomId: actualRoom,
      sequence: _positiveInt(raw['seq'], 'event sequence'),
      eventId: _boundedString(raw['event_id'], 'event id', 128),
      kind: kind,
      actor: actor,
      authorityEpoch: epoch,
      publicText: text,
      threadId: thread,
      createdAt: createdAt,
      idempotent: idempotent,
      activity: HostedGroupActivityDetails.fromJson(payload),
      attachments: attachments,
      attachmentsRejected: attachmentsRejected,
      canonicalPayload: jsonEncode(_canonicalJson(payload, 'event payload')),
      deferredTurn: deferredTurn,
      terminalTaskId: terminalTaskId,
    );
  }

  bool immutableEquals(HostedGroupEvent other) =>
      roomId == other.roomId &&
      sequence == other.sequence &&
      eventId == other.eventId &&
      kind == other.kind &&
      actor.immutableEquals(other.actor) &&
      authorityEpoch == other.authorityEpoch &&
      publicText == other.publicText &&
      threadId == other.threadId &&
      _canonicalPayload == other._canonicalPayload &&
      createdAt == other.createdAt;
}

/// Room event kinds the server publishes when a driver task leaves the
/// running state (`hosted_room_discussion.py::plan_publication`).
const _publishedTaskKinds = {
  'turn.settled',
  'turn.failed',
  'turn.cancelled',
  'turn.deferred',
};

/// Retry actions the server is still recovering on its own.
///
/// `driver_status.pending_actions` lists a `retry` for every task in
/// `indeterminate` or `deferred` (`hosted_room_service.py::status`), but only
/// a deferral is a verdict: the server publishes `turn.deferred`, with the
/// member id, once it gives up. An `indeterminate` attempt (gateway restart,
/// lost observation) has no room event at all while the running driver
/// probes it, and it either settles or is deferred within about a minute
/// (`hosted_room_driver.py::_reconcile_indeterminate`). Showing it as a
/// failure would raise a false alarm for an unnamed bot.
///
/// A retry counts as recovering only when the driver is running, no
/// terminal event for its task is in [events], and the server's own
/// `indeterminate` count covers every such retry; anything ambiguous (an old
/// deferral outside the loaded window) stays a failure.
Set<String> roomRecoveringRetryTasks(
  RoomDriverStatus? driver,
  Iterable<HostedGroupEvent> events,
) {
  if (driver == null || !driver.running) return const {};
  final indeterminate = driver.counts['indeterminate'] ?? 0;
  if (indeterminate <= 0) return const {};
  final published = {
    for (final e in events)
      if (_publishedTaskKinds.contains(e.kind) && e.activity.taskId != null)
        e.activity.taskId!,
  };
  final unpublished = {
    for (final retry in driver.retries)
      if (!published.contains(retry.taskId)) retry.taskId,
  };
  return unpublished.length <= indeterminate ? unpublished : const {};
}

final class HostedGroupLogPage {
  final List<HostedGroupEvent> events;
  final int cursor;
  final int latestSeq;
  final bool hasMore;
  final HostedGroupAuthority authority;

  const HostedGroupLogPage._({
    required this.events,
    required this.cursor,
    required this.latestSeq,
    required this.hasMore,
    required this.authority,
  });

  factory HostedGroupLogPage.fromJson(
    Object? value, {
    required String expectedRoomId,
    required int sinceSeq,
  }) {
    final raw = _map(value, 'room log');
    final rows = raw['events'];
    final cursor = raw['cursor'];
    final latest = raw['latest_seq'];
    final more = raw['has_more'];
    if (sinceSeq < 0 ||
        rows is! List ||
        cursor is! int ||
        cursor < 0 ||
        latest is! int ||
        latest < cursor ||
        more is! bool ||
        more != (cursor < latest)) {
      throw const FormatException('invalid room log');
    }
    final authority = HostedGroupAuthority.fromJson(raw['authority']);
    final events = rows
        .map((row) => HostedGroupEvent.fromJson(row, roomId: expectedRoomId))
        .toList(growable: false);
    var expectedSequence = sinceSeq + 1;
    final ids = <String>{};
    for (final event in events) {
      if (event.sequence != expectedSequence ||
          !ids.add(event.eventId) ||
          event.authorityEpoch > authority.epoch) {
        throw const FormatException('non-contiguous room log');
      }
      expectedSequence++;
    }
    final expectedCursor = events.isEmpty ? sinceSeq : events.last.sequence;
    if (cursor != expectedCursor) {
      throw const FormatException('invalid room log cursor');
    }
    return HostedGroupLogPage._(
      events: List.unmodifiable(events),
      cursor: cursor,
      latestSeq: latest,
      hasMore: more,
      authority: authority,
    );
  }

  /// Pages `loader` from the start of the room's log until it proves there is
  /// nothing left (`has_more == false`), the same completeness standard
  /// `groups.list` already holds itself to. Each page's own grammar is
  /// verified by [fromJson]; this only adds the cross-page invariants a
  /// single page can't see for itself: the continuation must advance
  /// (`cursor > sinceSeq` requested), no event id repeats across pages, and
  /// authority can't rotate mid-read (a rotation invalidates every page read
  /// under the old epoch, so restarting is the only safe move — see
  /// `docs/hosted_identity_transition_matrix.md`). Sending without this
  /// proof would let Console reply to a conversation it never actually
  /// finished loading.
  static Future<HostedGroupLogPage> loadComplete({
    required Future<HostedGroupLogPage> Function({
      required int sinceSeq,
      required int limit,
    })
    loader,
    required int pageLimit,
    int maxPages = 512,
  }) async {
    final events = <HostedGroupEvent>[];
    final ids = <String>{};
    var sinceSeq = 0;
    HostedGroupAuthority? authority;
    for (var page = 0; page < maxPages; page++) {
      final result = await loader(sinceSeq: sinceSeq, limit: pageLimit);
      if (authority != null &&
          (result.authority.gatewayId != authority.gatewayId ||
              result.authority.epoch != authority.epoch)) {
        throw const FormatException('room authority rotated mid-load');
      }
      authority = result.authority;
      for (final event in result.events) {
        if (!ids.add(event.eventId)) {
          throw const FormatException('duplicate event across log pages');
        }
      }
      events.addAll(result.events);
      if (!result.hasMore) {
        return HostedGroupLogPage._(
          events: List.unmodifiable(events),
          cursor: result.cursor,
          latestSeq: result.latestSeq,
          hasMore: false,
          authority: result.authority,
        );
      }
      if (result.cursor <= sinceSeq) {
        throw const FormatException('non-advancing log continuation');
      }
      sinceSeq = result.cursor;
    }
    throw const FormatException('room log pagination limit exceeded');
  }

  /// Appends an incremental `groups.log` delta (read with
  /// `since_seq == previous.cursor`) to an already proven prefix. The delta's
  /// own contiguity is verified by [fromJson]; this adds the cross-read
  /// invariants: same authority, no rewind and no duplicate event ids.
  /// [maxEvents] bounds memory on long rooms by keeping the newest tail.
  static HostedGroupLogPage append(
    HostedGroupLogPage previous,
    HostedGroupLogPage delta, {
    int maxEvents = 2000,
  }) {
    if (delta.authority.gatewayId != previous.authority.gatewayId ||
        delta.authority.epoch != previous.authority.epoch) {
      throw const FormatException('room authority rotated between reads');
    }
    if (delta.latestSeq < previous.latestSeq ||
        (delta.events.isNotEmpty &&
            delta.events.first.sequence != previous.cursor + 1)) {
      throw const FormatException('non-contiguous incremental room log');
    }
    final ids = {for (final event in previous.events) event.eventId};
    for (final event in delta.events) {
      if (!ids.add(event.eventId)) {
        throw const FormatException('duplicate event across log reads');
      }
    }
    var events = [...previous.events, ...delta.events];
    if (events.length > maxEvents) {
      events = events.sublist(events.length - maxEvents);
    }
    return HostedGroupLogPage._(
      events: List.unmodifiable(events),
      cursor: delta.cursor > previous.cursor ? delta.cursor : previous.cursor,
      latestSeq: delta.latestSeq,
      hasMore: delta.hasMore,
      authority: delta.authority,
    );
  }

  List<HostedGroupRetryAction> retryActions({
    required HostedGroupRoom room,
    required GroupsCapabilities capabilities,
  }) {
    if (!capabilities.supports(GroupMethod.retry) ||
        room.disbanded ||
        room.authorityGatewayId != authority.gatewayId ||
        room.authorityEpoch != authority.epoch ||
        room.latestSeq != latestSeq ||
        cursor != latestSeq ||
        hasMore) {
      return const [];
    }
    final actions = <HostedGroupRetryAction>[];
    final seenTasks = <String>{};
    for (final event in events.reversed) {
      final taskId = event._terminalTaskId;
      if (taskId == null || !seenTasks.add(taskId)) continue;
      final deferred = event._deferredTurn;
      if (deferred == null ||
          event.authorityEpoch != room.authorityEpoch ||
          event.actor.kind != 'gateway' ||
          event.actor.id != room.authorityGatewayId ||
          deferred.memberIndex >= room.members.length ||
          room.members[deferred.memberIndex].memberId != deferred.memberId ||
          actions.length >= 32) {
        continue;
      }
      actions.add(
        HostedGroupRetryAction._(
          roomId: room.roomId,
          gatewayId: room.authorityGatewayId,
          authorityEpoch: room.authorityEpoch,
          capabilityGeneration: capabilities.generation,
          taskId: deferred.taskId,
          roomRevision: room.revision,
          roomLatestSeq: room.latestSeq,
          logCursor: cursor,
          logLatestSeq: latestSeq,
          deferredEventId: event.eventId,
          deferredSequence: event.sequence,
          seenThroughSeq: deferred.seenThroughSeq,
          executionGeneration: deferred.executionGeneration,
        ),
      );
    }
    return List.unmodifiable(actions.reversed);
  }
}

/// One generation-coherent projection of the official shared-room surface.
/// Opaque identifiers are transport state, never presentation identity.
///
/// [rooms] is the server's room list (`groups.list`), as Hermes Desktop
/// lists rooms (`canonical-group-registry.tsx` `useGatewayGroupRooms`): no
/// room is read to be listed. A room's conversation and driver state are
/// known only once a view of that room read them in this app session (as a
/// Desktop row shows only what an open view of its room published,
/// `canonical-group-details.tsx` `$canonicalRoomLive`); for any other room
/// they are unknown, never empty.
final class HostedGroupsSnapshot {
  final GroupsCapabilities? capabilities;
  final List<HostedGroupRoom> rooms;

  /// The log of `rooms[i]` at index `i`, as its open view last read it. A
  /// null or missing entry is a room whose conversation Console has not
  /// read in this session: unknown, not empty, and not seen.
  final List<HostedGroupLogPage?> logs;

  /// `groups.state.driver_status` per room id, when a view of the room read
  /// it.
  final Map<String, RoomDriverStatus> driverStatuses;

  /// When each status of [driverStatuses] was read, per room id. A room
  /// with a status but no time here offers nothing that must be current.
  final Map<String, DateTime> driverReadAt;

  /// Rooms the server listed that Console could not read. They are not in
  /// [rooms]/[logs]; the rest of the snapshot is complete without them.
  final List<HostedGroupUnreadableRoom> unreadableRooms;

  const HostedGroupsSnapshot({
    this.capabilities,
    this.rooms = const [],
    this.logs = const [],
    this.driverStatuses = const {},
    this.driverReadAt = const {},
    this.unreadableRooms = const [],
  });

  RoomDriverStatus? driverStatusFor(String roomId) => driverStatuses[roomId];

  /// The log of [roomId] a view of it read, or null when none did.
  HostedGroupLogPage? logFor(String roomId) {
    final index = rooms.indexWhere((room) => room.roomId == roomId);
    return logAt(index);
  }

  /// The log of `rooms[index]`, or null when no view of it read one.
  HostedGroupLogPage? logAt(int index) =>
      index >= 0 && index < logs.length ? logs[index] : null;

  /// This snapshot with [capabilities] in place of its own.
  HostedGroupsSnapshot withCapabilities(GroupsCapabilities capabilities) =>
      HostedGroupsSnapshot(
        capabilities: capabilities,
        rooms: rooms,
        logs: logs,
        driverStatuses: driverStatuses,
        driverReadAt: driverReadAt,
        unreadableRooms: unreadableRooms,
      );

  /// This snapshot with what a view of `rooms[index]` just read: [room] in
  /// its place, [log] when the read brought one and [driverStatus] (read at
  /// [readAt]) when it brought one. Every other room keeps what it had. A
  /// disbanded [room] leaves the list.
  HostedGroupsSnapshot withRoomRead(
    int index, {
    required HostedGroupRoom room,
    HostedGroupLogPage? log,
    RoomDriverStatus? driverStatus,
    DateTime? readAt,
  }) {
    final nextRooms = [...rooms];
    final nextLogs = [
      for (var i = 0; i < rooms.length; i++) logAt(i),
    ];
    final nextDrivers = {...driverStatuses};
    final nextReadAt = {...driverReadAt};
    if (room.disbanded) {
      nextRooms.removeAt(index);
      nextLogs.removeAt(index);
      nextDrivers.remove(room.roomId);
      nextReadAt.remove(room.roomId);
    } else {
      nextRooms[index] = room;
      if (log != null) nextLogs[index] = log;
      if (driverStatus != null) {
        nextDrivers[room.roomId] = driverStatus;
        if (readAt != null) {
          nextReadAt[room.roomId] = readAt;
        } else {
          nextReadAt.remove(room.roomId);
        }
      }
    }
    return HostedGroupsSnapshot(
      capabilities: capabilities,
      rooms: List.unmodifiable(nextRooms),
      logs: List.unmodifiable(nextLogs),
      driverStatuses: Map.unmodifiable(nextDrivers),
      driverReadAt: Map.unmodifiable(nextReadAt),
      unreadableRooms: unreadableRooms,
    );
  }

  static const empty = HostedGroupsSnapshot();
}

Map<String, dynamic> _map(Object? value, String label) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('invalid $label');
  }
  return Map<String, dynamic>.from(value);
}

Object? _canonicalJson(Object? value, String label) {
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double) {
    if (!value.isFinite) throw FormatException('invalid $label');
    return value;
  }
  if (value is List) {
    return value.map((item) => _canonicalJson(item, label)).toList();
  }
  if (value is Map) {
    if (value.keys.any((key) => key is! String)) {
      throw FormatException('invalid $label');
    }
    final keys = value.keys.cast<String>().toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalJson(value[key], label),
    };
  }
  throw FormatException('invalid $label');
}

void _requireOnlyFields(
  Map<String, dynamic> raw,
  Set<String> fields,
  String label,
) {
  if (raw.keys.any((field) => !fields.contains(field))) {
    throw FormatException('invalid $label fields');
  }
}

void _requireExactFields(
  Map<String, dynamic> raw,
  Set<String> fields,
  String label,
) {
  if (raw.length != fields.length || !raw.keys.toSet().containsAll(fields)) {
    throw FormatException('invalid $label fields');
  }
}

String _sha256Digest(String value) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw const FormatException('invalid capability digest');
  }
  return value;
}

String _string(Object? value, String label) =>
    _boundedString(value, label, 256);

String _boundedString(Object? value, String label, int maximum) {
  if (value is! String ||
      value.trim().isEmpty ||
      value != value.trim() ||
      value.runes.length > maximum ||
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    throw FormatException('invalid $label');
  }
  return value;
}

String _messageText(Object? value, String label) {
  if (value is! String ||
      value.trim().isEmpty ||
      utf8.encode(value).length > 65536) {
    throw FormatException('invalid $label');
  }
  return value;
}

/// The text of an owner message that carries files: it may be blank
/// (upstream stores it stripped), and is bounded like any message text.
String _attachmentCaption(Object? value) {
  if (value is! String || utf8.encode(value).length > 65536) {
    throw const FormatException('invalid message text');
  }
  return value.trim().isEmpty ? '' : value;
}

String? _optionalCanonicalString(
  Map<String, dynamic> raw,
  String field,
  String label,
  int maximum,
) {
  if (!raw.containsKey(field)) return null;
  final value = raw[field];
  if (value is! String ||
      value.isEmpty ||
      value != value.trim() ||
      value.runes.length > maximum) {
    throw FormatException('invalid $label');
  }
  return value;
}

int _positiveInt(Object? value, String label) {
  if (value is! int || value < 1) throw FormatException('invalid $label');
  return value;
}

num _number(Object? value, String label) {
  if (value is! num || !value.isFinite) throw FormatException('invalid $label');
  return value;
}
