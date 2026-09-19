import 'dart:convert';

import 'bot_mode_v13.dart';

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
  promote('groups.promote');

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
          driverReady);

  bool get hasSharedRoomSurface =>
      supports(GroupMethod.list) &&
      supports(GroupMethod.state) &&
      supports(GroupMethod.log);
}

final class GroupsCapabilityCache {
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
    } catch (_) {
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
    _requireOnlyFields(raw, const {
      'member_id',
      'profile',
      'handle',
      'display_name',
      'target',
    }, 'member');
    final profile = _boundedString(raw['profile'], 'member profile', 128);
    final target = _map(raw['target'], 'member target');
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
  final bool disbanded;
  final Map<String, dynamic> _testJson;

  const HostedGroupRoom._({
    required this.roomId,
    required this.name,
    required this.members,
    required this.authorityGatewayId,
    required this.authorityEpoch,
    required this.revision,
    required this.latestSeq,
    required this.disbanded,
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
    _number(raw['updated_at'], 'room update');
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
      disbanded: raw['disbanded_at'] != null,
      testJson: Map.unmodifiable(raw),
    );
  }

  Map<String, dynamic> toJsonForTest() => Map.of(_testJson);
}

/// One typed page from the official `groups.list` offset protocol.
///
/// Completeness is deliberately not claimed here: only the loader that follows
/// every authenticated `next_offset` on one socket lease can publish a list.
final class HostedGroupListPage {
  final List<HostedGroupRoom> rooms;
  final int? nextOffset;

  const HostedGroupListPage._({required this.rooms, required this.nextOffset});

  factory HostedGroupListPage.fromJson(Object? value) {
    final raw = _map(value, 'room list page');
    final rows = raw['rooms'];
    final next = raw['next_offset'];
    if (rows is! List ||
        rows.length > 500 ||
        (next != null && (next is! int || next < 0))) {
      throw const FormatException('invalid room list page');
    }
    return HostedGroupListPage._(
      rooms: List.unmodifiable(rows.map(HostedGroupRoom.fromJson)),
      nextOffset: next as int?,
    );
  }
}

final class HostedGroupWorkspaceReadback {
  final HostedGroupRoom room;
  final HostedGroupLogPage? log;
  final int capabilityGeneration;

  const HostedGroupWorkspaceReadback({
    required this.room,
    required this.log,
    required this.capabilityGeneration,
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
        roundIndex < 0 ||
        roundIndex > 2) {
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
      passed = payload['passed'] == true;

  static String? _text(Object? value) {
    if (value is! String || value.trim().isEmpty || value.length > 512) {
      return null;
    }
    return value.trim();
  }
}

final class HostedGroupEvent {
  final String roomId;
  final int sequence;
  final String eventId;
  final String kind;
  final HostedGroupActor actor;
  final int authorityEpoch;
  final String? publicText;
  final String? threadId;
  final num createdAt;
  final bool idempotent;
  final HostedGroupActivityDetails activity;
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
    _HostedGroupDeferredTurn? deferredTurn;
    String? terminalTaskId;
    if (kind == 'message.user') {
      _requireExactFields(payload, const {
        'text',
        'thread_id',
      }, 'message.user payload');
      text = _messageText(payload['text'], 'message text');
      thread = _boundedString(payload['thread_id'], 'thread id', 128);
    } else if (kind == 'message.member') {
      text = _messageText(payload['text'], 'message text');
      thread = _boundedString(payload['thread_id'], 'thread id', 128);
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
final class HostedGroupsSnapshot {
  final GroupsCapabilities? capabilities;
  final List<HostedGroupRoom> rooms;
  final List<HostedGroupLogPage> logs;

  const HostedGroupsSnapshot({
    this.capabilities,
    this.rooms = const [],
    this.logs = const [],
  });

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
