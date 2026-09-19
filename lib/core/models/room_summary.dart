import 'hosted_groups.dart';
import 'kanban.dart';
import 'room_member_status.dart';

enum RoomSummaryKind {
  working,
  answered,
  passed,
  done,
  waiting,
  silent,
  deferred,
  failed,
  cancelled,
  unavailable,
  needsYou,
  stopped,
  bounded,
  settled,
}

final class RoomSummaryRow {
  final String id;
  final HostedGroupMember? member;
  final RoomSummaryKind kind;
  final String? detail;
  final String? reasonCode;
  final num at;
  final int sequence;
  const RoomSummaryRow({
    required this.id,
    required this.kind,
    this.member,
    this.detail,
    this.reasonCode,
    this.at = 0,
    this.sequence = 0,
  });
}

/// Complete sections are retained so “more” does not require another RPC.
final class RoomSummarySection {
  static const pageSize = 6;
  final List<RoomSummaryRow> rows;
  RoomSummarySection(Iterable<RoomSummaryRow> rows)
    : rows = List.unmodifiable(rows);
  List<RoomSummaryRow> get visible => rows.take(pageSize).toList();
  int get remaining => (rows.length - pageSize).clamp(0, rows.length);
}

final class RoomSummary {
  final String? topic;
  final RoomSummarySection now;
  final RoomSummarySection done;
  final RoomSummarySection pending;
  final RoomSummarySection recent;
  final Map<String, BotLiveStatus> statuses;
  RoomSummary({
    required this.topic,
    required this.now,
    required this.done,
    required this.pending,
    required this.recent,
    required Map<String, BotLiveStatus> statuses,
  }) : statuses = Map.unmodifiable(statuses);
  int get needsYouCount =>
      pending.rows.where((r) => r.kind == RoomSummaryKind.needsYou).length;
}

/// Durable log + the already loaded, connection-scoped Mission snapshot.
/// Pure: replaying the same inputs and clock yields the same rows/order/counts.
/// Events must belong to this room; localGatewayId scopes board assignments.
RoomSummary deriveRoomSummary({
  required List<HostedGroupEvent> events,
  required List<HostedGroupMember> members,
  Map<String, BotLiveStatus> statuses = const {},
  KanbanBoard? board,
  required String localGatewayId,
  required DateTime now,
}) {
  final ordered = [...events]..sort((a, b) => a.sequence.compareTo(b.sequence));
  final seconds = now.millisecondsSinceEpoch / 1000;
  final byId = {for (final e in ordered) e.eventId: e};
  final users = ordered.where((e) => e.kind == 'message.user').toList();
  final latestByThread = {for (final e in users) e.threadId: e};
  HostedGroupMember? memberOf(HostedGroupEvent e) => members
      .where(
        (m) => e.activity.memberId != null
            ? m.memberId == e.activity.memberId
            : m.memberId == e.actor.id ||
                  (m.owner.connectionId == e.actor.connectionId &&
                      m.owner.profile == e.actor.profile),
      )
      .firstOrNull;
  HostedGroupEvent? requestOf(HostedGroupEvent e) {
    final explicit = e.activity.discussionId;
    if (explicit != null) {
      final request = byId[explicit];
      return request?.kind == 'message.user' ? request : null;
    }
    return users
        .where(
          (u) =>
              u.sequence < e.sequence &&
              u.threadId == (e.activity.threadId ?? e.threadId),
        )
        .lastOrNull;
  }

  final live = <String, BotLiveStatus>{
    for (final m in members)
      m.memberId:
          statuses[m.memberId] ??
          BotLiveStatus.derive(member: m, events: ordered, now: now),
  };
  final working = <RoomSummaryRow>[];
  final done = <RoomSummaryRow>[];
  final pending = <RoomSummaryRow>[];
  for (final m in members) {
    final status = live[m.memberId]!;
    final last = ordered
        .where((e) => memberOf(e)?.memberId == m.memberId)
        .lastOrNull;
    if (status.presence == RoomPresence.working) {
      working.add(
        RoomSummaryRow(
          id: 'working:${m.memberId}',
          member: m,
          kind: RoomSummaryKind.working,
          detail: _excerpt(status.workingOn),
          at: last?.createdAt ?? 0,
          sequence: last?.sequence ?? 0,
        ),
      );
    }
    if (status.presence == RoomPresence.needsYou) {
      pending.add(
        RoomSummaryRow(
          id: 'needs:${m.memberId}',
          member: m,
          kind: RoomSummaryKind.needsYou,
          at: last?.createdAt ?? 0,
          sequence: last?.sequence ?? 0,
        ),
      );
    }
  }

  // One record per durable task. A deferred generation is replaced by its
  // retry/terminal. Legacy messages without task IDs remain real answers.
  final turns = <String, HostedGroupEvent>{};
  final messages = <String, HostedGroupEvent>{};
  String turnKey(HostedGroupEvent e, HostedGroupMember m) =>
      '${m.memberId}:${e.activity.taskId ?? e.activity.messageEventId ?? e.eventId}';
  const turnKinds = {
    'turn.started',
    'turn.settled',
    'turn.failed',
    'turn.cancelled',
    'turn.deferred',
    'member.unavailable',
    'message.member',
  };
  for (final e in ordered.where((e) => turnKinds.contains(e.kind))) {
    final m = memberOf(e);
    if (m == null) continue;
    final key = turnKey(e, m);
    turns[key] = e;
    if (e.kind == 'message.member') messages[key] = e;
  }
  final stop = ordered.where((e) => e.kind == 'room.stop_requested').lastOrNull;
  final covered = <(String, String)>{};
  for (final entry in turns.entries) {
    final e = entry.value;
    final m = memberOf(e)!;
    final request = requestOf(e);
    if (request != null) covered.add((request.eventId, m.memberId));
    final kind = switch (e.kind) {
      'message.member' => RoomSummaryKind.answered,
      'turn.settled' =>
        e.activity.passed ? RoomSummaryKind.passed : RoomSummaryKind.answered,
      'turn.failed' => RoomSummaryKind.failed,
      'turn.cancelled' => RoomSummaryKind.cancelled,
      'turn.deferred' => RoomSummaryKind.deferred,
      'member.unavailable' => RoomSummaryKind.unavailable,
      _ =>
        seconds - e.createdAt >= 120
            ? RoomSummaryKind.silent
            : RoomSummaryKind.waiting,
    };
    final completed =
        kind == RoomSummaryKind.answered || kind == RoomSummaryKind.passed;
    // Older requests in the same thread have been superseded. Their delivered
    // work stays in Done, but their unresolved placeholders are no longer live.
    if (!completed &&
        request != null &&
        latestByThread[request.threadId]?.eventId != request.eventId) {
      continue;
    }
    if (!completed &&
        e.kind == 'turn.started' &&
        live[m.memberId]!.presence == RoomPresence.working) {
      continue;
    }
    if (!completed && live[m.memberId]!.presence == RoomPresence.needsYou) {
      continue;
    }
    final stopped = !completed && stop != null && e.sequence < stop.sequence;
    final message = byId[e.activity.messageEventId] ?? messages[entry.key];
    final row = RoomSummaryRow(
      id: 'turn:${entry.key}',
      member: m,
      kind: stopped ? RoomSummaryKind.cancelled : kind,
      detail: _excerpt(
        completed && kind != RoomSummaryKind.passed
            ? message?.publicText ?? e.publicText ?? request?.publicText
            : request?.publicText,
      ),
      reasonCode: stopped ? 'room_stopped' : e.activity.reasonCode,
      at: e.createdAt,
      sequence: e.sequence,
    );
    (completed ? done : pending).add(row);
  }

  // Asking a member is evidence of an expected reply, not evidence they ran.
  for (final request in latestByThread.values) {
    final closed = ordered
        .where(
          (e) =>
              e.kind == 'room.activity' &&
              e.activity.discussionId == request.eventId &&
              const {'settled', 'bounded'}.contains(e.activity.status),
        )
        .lastOrNull;
    for (final m in resolveRoomRecipients(request.publicText ?? '', members)) {
      if (covered.contains((request.eventId, m.memberId)) ||
          live[m.memberId]!.presence == RoomPresence.needsYou) {
        continue;
      }
      final stopped = stop != null && stop.sequence > request.sequence;
      pending.add(
        RoomSummaryRow(
          id: 'waiting:${request.eventId}:${m.memberId}',
          member: m,
          kind: stopped
              ? RoomSummaryKind.cancelled
              : closed != null || seconds - request.createdAt >= 120
              ? RoomSummaryKind.silent
              : RoomSummaryKind.waiting,
          reasonCode: stopped
              ? 'room_stopped'
              : closed?.activity.status == 'bounded'
              ? 'bounded'
              : null,
          detail: _excerpt(request.publicText),
          at: request.createdAt,
          sequence: request.sequence,
        ),
      );
    }
  }

  // Board tasks are member work, not necessarily work commissioned by this
  // room. Never borrow a local task for a remote seat with the same profile.
  for (final task in board?.columns.expand((c) => c.tasks) ?? <KanbanTask>[]) {
    final m = members
        .where(
          (m) =>
              m.owner.connectionId == localGatewayId &&
              m.owner.profile == task.assignee,
        )
        .firstOrNull;
    if (m == null) continue;
    if (task.status == 'done' &&
        task.completedAt != null &&
        seconds - task.completedAt! >= 0 &&
        seconds - task.completedAt! <= 86400 * 7) {
      done.add(
        RoomSummaryRow(
          id: 'board:${task.id}',
          member: m,
          kind: RoomSummaryKind.done,
          detail: _excerpt(task.title),
          at: task.completedAt!,
        ),
      );
    }
    if (task.status == 'running' &&
        live[m.memberId]!.presence != RoomPresence.needsYou &&
        !working.any((r) => r.member?.memberId == m.memberId)) {
      // Reuse the shared status projection; a running board task is itself
      // evidence of assigned work when the profile has no fresher detail.
      live[m.memberId] = BotLiveStatus(
        RoomPresence.working,
        workingOn: task.title,
      );
      working.add(
        RoomSummaryRow(
          id: 'working:${m.memberId}',
          member: m,
          kind: RoomSummaryKind.working,
          detail: _excerpt(task.title),
          at: task.startedAt ?? 0,
        ),
      );
    }
  }
  final recent = <RoomSummaryRow>[];
  for (final e in ordered.reversed) {
    final kind = switch (e.kind) {
      'turn.started' => RoomSummaryKind.working,
      'message.member' =>
        roomMessageNeedsYou(e.publicText ?? '')
            ? RoomSummaryKind.needsYou
            : RoomSummaryKind.answered,
      'turn.settled' =>
        e.activity.passed ? RoomSummaryKind.passed : RoomSummaryKind.settled,
      'turn.failed' => RoomSummaryKind.failed,
      'turn.cancelled' => RoomSummaryKind.cancelled,
      'turn.deferred' => RoomSummaryKind.deferred,
      'member.unavailable' => RoomSummaryKind.unavailable,
      'room.stop_requested' => RoomSummaryKind.stopped,
      'room.activity' =>
        e.activity.status == 'bounded'
            ? RoomSummaryKind.bounded
            : e.activity.status == 'settled'
            ? RoomSummaryKind.settled
            : null,
      _ => null,
    };
    if (kind == null) continue;
    recent.add(
      RoomSummaryRow(
        id: e.eventId,
        member: memberOf(e),
        kind: kind,
        reasonCode: e.activity.reasonCode,
        at: e.createdAt,
        sequence: e.sequence,
      ),
    );
    if (recent.length == 50) break;
  }
  RoomSummarySection section(List<RoomSummaryRow> rows) {
    rows.sort((a, b) {
      final time = b.at.compareTo(a.at);
      if (time != 0) return time;
      final seq = b.sequence.compareTo(a.sequence);
      return seq != 0 ? seq : a.id.compareTo(b.id);
    });
    return RoomSummarySection(rows);
  }

  return RoomSummary(
    topic: _excerpt(users.lastOrNull?.publicText),
    now: section(working),
    done: section(done),
    pending: section(pending),
    recent: RoomSummarySection(recent),
    statuses: live,
  );
}

String? _excerpt(String? value) {
  if (value == null) return null;
  final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return null;
  return text.length > 140 ? '${text.substring(0, 139)}…' : text;
}
