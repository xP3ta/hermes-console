import '../../models/hosted_groups.dart';
import '../../models/room_member_status.dart' show roomMessageNeedsYou;

enum AttentionKind { approval, retry, mention, failedTurn }

/// One thing that needs the user (spec 070 § Attention). Replaces the old
/// SharedPreferences unread watermark: attention is derived from server
/// state, so every client sees the same thing.
final class AttentionItem {
  final AttentionKind kind;
  final String roomId;
  final String? taskId;
  final String? memberId;

  /// The event that raised it (mentions and failed turns).
  final String? eventId;
  final int? sequence;

  /// For approvals: the exact server action to answer.
  final RoomApprovalAction? approval;

  const AttentionItem({
    required this.kind,
    required this.roomId,
    this.taskId,
    this.memberId,
    this.eventId,
    this.sequence,
    this.approval,
  });

  String get key =>
      '${kind.name}:$roomId:${taskId ?? ''}:${eventId ?? ''}:'
      '${approval?.requestId ?? ''}';

  @override
  bool operator ==(Object other) => other is AttentionItem && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// What this device already acknowledged for one room: the last sequence
/// the user saw in it and the failure cards they dismissed. Both are local
/// (the server keeps no read marker for rooms), so they only ever hide
/// things; a pending approval is never acknowledged this way.
final class RoomAttentionAcks {
  final int? seenSeq;
  final Set<String> dismissedTasks;

  const RoomAttentionAcks({this.seenSeq, this.dismissedTasks = const {}});

  static const none = RoomAttentionAcks();

  bool seen(HostedGroupEvent event) =>
      seenSeq != null && event.sequence <= seenSeq!;
}

final class RoomAttention {
  final String roomId;
  final List<AttentionItem> items;

  const RoomAttention(this.roomId, this.items);

  bool get needsUser => items.isNotEmpty;
  int get count => items.length;

  Iterable<AttentionItem> ofKind(AttentionKind kind) =>
      items.where((item) => item.kind == kind);

  /// Aggregates attention for one hosted room.
  ///
  /// * `pending_actions` approvals and retries come straight from the driver.
  /// * `@user` mentions in `message.member` events stay open until a later
  ///   `message.user` in the same thread answers them.
  /// * `turn.failed` stays open until a later event from the same member in
  ///   the same thread (a retry start, a message) or a user reply supersedes it.
  /// * [acks]: mentions and failures the user already saw in the room, and
  ///   failures they dismissed, no longer need them. Approvals always do.
  static RoomAttention derive({
    required HostedGroupRoom room,
    RoomDriverStatus? driverStatus,
    HostedGroupLogPage? log,
    RoomAttentionAcks acks = RoomAttentionAcks.none,
  }) {
    if (room.disbanded) return RoomAttention(room.roomId, const []);
    final items = <AttentionItem>[];
    final retries = <RoomRetryAction>[];
    for (final action in driverStatus?.pendingActions ?? const []) {
      switch (action) {
        case RoomApprovalAction():
          items.add(
            AttentionItem(
              kind: AttentionKind.approval,
              roomId: room.roomId,
              taskId: action.taskId,
              memberId: action.memberId,
              approval: action,
            ),
          );
        case RoomRetryAction():
          retries.add(action);
      }
    }
    final retryTasks = {for (final action in retries) action.taskId};
    final events = log?.events ?? const <HostedGroupEvent>[];
    final mentions = <String, HostedGroupEvent>{};
    final failures = <String, HostedGroupEvent>{};
    final failedAt = <String, HostedGroupEvent>{};
    String memberOf(HostedGroupEvent e) => e.activity.memberId ?? e.actor.id;
    String threadOf(HostedGroupEvent e) =>
        e.activity.threadId ?? e.threadId ?? '';
    for (final event in events) {
      if (event.roomId != room.roomId) continue;
      final thread = threadOf(event);
      if (event.kind == 'message.user') {
        mentions.removeWhere((_, m) => threadOf(m) == thread);
        failures.removeWhere((_, f) => threadOf(f) == thread);
        continue;
      }
      final member = memberOf(event);
      final slot = '$member|$thread';
      if (event.kind == 'message.member') {
        failures.remove(slot);
        if (roomMessageNeedsYou(event.publicText ?? '')) {
          mentions[slot] = event;
        } else {
          mentions.remove(slot);
        }
      } else if (event.kind == 'turn.failed') {
        failures[slot] = event;
        if (event.activity.taskId case final task?) failedAt[task] = event;
      } else if (event.kind == 'turn.started' || event.kind == 'turn.settled') {
        failures.remove(slot);
      }
    }
    for (final action in retries) {
      final failure = failedAt[action.taskId];
      if (acks.dismissedTasks.contains(action.taskId) ||
          (failure != null && acks.seen(failure))) {
        continue;
      }
      items.add(
        AttentionItem(
          kind: AttentionKind.retry,
          roomId: room.roomId,
          taskId: action.taskId,
        ),
      );
    }
    for (final event in mentions.values) {
      if (acks.seen(event)) continue;
      items.add(
        AttentionItem(
          kind: AttentionKind.mention,
          roomId: room.roomId,
          memberId: memberOf(event),
          eventId: event.eventId,
          sequence: event.sequence,
        ),
      );
    }
    for (final event in failures.values) {
      // A failure the driver already offers as retryable is one item.
      if (retryTasks.contains(event.activity.taskId)) continue;
      if (acks.seen(event) ||
          acks.dismissedTasks.contains(event.activity.taskId)) {
        continue;
      }
      items.add(
        AttentionItem(
          kind: AttentionKind.failedTurn,
          roomId: room.roomId,
          taskId: event.activity.taskId,
          memberId: memberOf(event),
          eventId: event.eventId,
          sequence: event.sequence,
        ),
      );
    }
    return RoomAttention(room.roomId, List.unmodifiable(items));
  }
}

/// Attention across every hosted room, plus the per-bot projection.
final class AttentionSummary {
  final Map<String, RoomAttention> rooms;

  const AttentionSummary(this.rooms);

  static const empty = AttentionSummary({});

  static AttentionSummary fromSnapshot(
    HostedGroupsSnapshot snapshot, {
    RoomAttentionAcks Function(HostedGroupRoom room)? acks,
  }) {
    final rooms = <String, RoomAttention>{};
    for (var i = 0; i < snapshot.rooms.length; i++) {
      final room = snapshot.rooms[i];
      if (room.disbanded) continue;
      final log = _logFor(snapshot, i, room);
      rooms[room.roomId] = RoomAttention.derive(
        room: room,
        driverStatus: snapshot.driverStatusFor(room.roomId),
        log: log,
        acks: acks?.call(room) ?? RoomAttentionAcks.none,
      );
    }
    return AttentionSummary(Map.unmodifiable(rooms));
  }

  int get total => rooms.values.fold(0, (sum, room) => sum + room.count);

  RoomAttention? room(String roomId) => rooms[roomId];

  /// Items raised by seats of [profile] owned by the room authority.
  List<AttentionItem> forProfile(
    String profile,
    HostedGroupsSnapshot snapshot,
  ) {
    final result = <AttentionItem>[];
    for (final room in snapshot.rooms) {
      final attention = rooms[room.roomId];
      if (attention == null) continue;
      final seats = {
        for (final member in room.members)
          if (member.owner.connectionId == room.authorityGatewayId &&
              member.owner.profile == profile)
            member.memberId,
      };
      result.addAll(
        attention.items.where(
          (item) => item.memberId != null && seats.contains(item.memberId),
        ),
      );
    }
    return result;
  }

  static HostedGroupLogPage? _logFor(
    HostedGroupsSnapshot snapshot,
    int index,
    HostedGroupRoom room,
  ) {
    if (index < snapshot.logs.length) {
      final log = snapshot.logs[index];
      if (log.events.isEmpty || log.events.first.roomId == room.roomId) {
        return log;
      }
    }
    for (final log in snapshot.logs) {
      if (log.events.isNotEmpty && log.events.first.roomId == room.roomId) {
        return log;
      }
    }
    return null;
  }
}
