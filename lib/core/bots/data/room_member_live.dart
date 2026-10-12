/// Live view of what a hosted room member is doing in its current turn.
///
/// A member turn runs on the member's hidden `Group: <room_id>` session,
/// which has no client attached. The server still stamps every event frame
/// of that runtime into its replay ring (`tui_gateway/event_replay.py`), so
/// Console reads the tail of that ring with `session.events.since` — the
/// same read-only method the member-prompt probe uses — after finding the
/// working runtime with `session.active_list` and the member's stored room
/// session with `session.list`. Nothing is attached, resumed or submitted.
///
/// Only members hosted by the room's own gateway can be read this way; a
/// peer member's activity reaches only server plugins
/// (`on_room_member_activity`), never clients.
///
/// Privacy: reasoning and message text are never kept, nor tool arguments;
/// a step carries the tool name and the server's short `context` preview
/// (the same preview the chat activity shows), cut to [_contextMax].
library;

import '../../models/hosted_groups.dart';
import 'room_member_prompts.dart'
    show RoomPromptRpc, roomMemberSessionTitle, roomPromptProbeLastSeen;

/// Frames read from the tail of the ring on each poll.
const int roomLiveFrameWindow = 40;

const int _stepsMax = 8;
const int _contextMax = 48;

enum RoomLiveStepKind { thinking, tool, writing }

final class RoomLiveStep {
  final RoomLiveStepKind kind;
  final String? tool;
  final String? toolId;
  final String? context;
  final bool done;

  const RoomLiveStep.thinking({this.done = false})
    : kind = RoomLiveStepKind.thinking,
      tool = null,
      toolId = null,
      context = null;

  const RoomLiveStep.writing({this.done = false})
    : kind = RoomLiveStepKind.writing,
      tool = null,
      toolId = null,
      context = null;

  const RoomLiveStep.tool(
    String this.tool, {
    this.context,
    this.toolId,
    this.done = false,
  }) : kind = RoomLiveStepKind.tool;

  RoomLiveStep closed() => switch (kind) {
    RoomLiveStepKind.thinking => const RoomLiveStep.thinking(done: true),
    RoomLiveStepKind.writing => const RoomLiveStep.writing(done: true),
    RoomLiveStepKind.tool => RoomLiveStep.tool(
      tool!,
      context: context,
      toolId: toolId,
      done: true,
    ),
  };
}

final class RoomMemberLive {
  final List<RoomLiveStep> steps;

  const RoomMemberLive({this.steps = const []});

  /// The open step, if the latest one is still running.
  RoomLiveStep? get current {
    if (steps.isEmpty) return null;
    final last = steps.last;
    return last.done ? null : last;
  }
}

String? _shortContext(Object? raw) {
  if (raw is! String) return null;
  final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return null;
  return text.length <= _contextMax
      ? text
      : '${text.substring(0, _contextMax - 1)}…';
}

/// Folds replay frames (`{type, payload}`) into ordered steps.
RoomMemberLive reduceRoomMemberFrames(Iterable<Object?> frames) {
  final steps = <RoomLiveStep>[];
  void closeOpen({bool toolsToo = true}) {
    if (steps.isEmpty || steps.last.done) return;
    if (!toolsToo && steps.last.kind == RoomLiveStepKind.tool) return;
    steps[steps.length - 1] = steps.last.closed();
  }

  for (final frame in frames) {
    if (frame is! Map) continue;
    final type = frame['type'];
    final rawPayload = frame['payload'];
    final payload = rawPayload is Map ? rawPayload : const {};
    switch (type) {
      case 'reasoning.delta' || 'thinking.delta':
        if (steps.isNotEmpty &&
            !steps.last.done &&
            steps.last.kind == RoomLiveStepKind.thinking) {
          continue;
        }
        closeOpen();
        steps.add(const RoomLiveStep.thinking());
      case 'message.delta':
        if (steps.isNotEmpty &&
            !steps.last.done &&
            steps.last.kind == RoomLiveStepKind.writing) {
          continue;
        }
        closeOpen();
        steps.add(const RoomLiveStep.writing());
      case 'tool.start':
        final name = payload['name'];
        if (name is! String || name.trim().isEmpty) continue;
        closeOpen();
        final id = payload['tool_id'];
        steps.add(
          RoomLiveStep.tool(
            name.trim(),
            context: _shortContext(payload['context']),
            toolId: id is String ? id : null,
          ),
        );
      case 'tool.complete':
        final id = payload['tool_id'];
        for (var i = steps.length - 1; i >= 0; i--) {
          final step = steps[i];
          if (step.kind != RoomLiveStepKind.tool || step.done) continue;
          if (id is String && step.toolId != null && step.toolId != id) {
            continue;
          }
          steps[i] = step.closed();
          break;
        }
      case 'message.complete':
        closeOpen();
    }
  }
  final tail = steps.length > _stepsMax
      ? steps.sublist(steps.length - _stepsMax)
      : steps;
  return RoomMemberLive(steps: List.unmodifiable(tail));
}

/// What the Room screen needs to show members' live turns.
abstract interface class RoomMemberLiveSource {
  /// Live activity of the room's working local members, by member id.
  Future<Map<String, RoomMemberLive>> read(HostedGroupRoom room);
}

final class GatewayRoomMemberLive implements RoomMemberLiveSource {
  final RoomPromptRpc rpc;

  /// Stored room session ids per member profile (they never change for a
  /// room), so a poll costs one `session.list` per member at most once.
  final Map<String, Set<String>> _stored = {};

  GatewayRoomMemberLive(this.rpc);

  @override
  Future<Map<String, RoomMemberLive>> read(HostedGroupRoom room) async {
    final local = [
      for (final m in room.members)
        if (m.owner.connectionId == room.authorityGatewayId) m,
    ];
    if (local.isEmpty) return const {};
    final active = await rpc('session.active_list', const {});
    final rows = active['sessions'];
    if (rows is! List) return const {};
    final working = <String, String>{}; // session_key -> runtime id
    for (final row in rows) {
      if (row is! Map || row['status'] != 'working') continue;
      final id = row['id'];
      final key = row['session_key'];
      if (id is String && id.isNotEmpty) {
        working[key is String && key.isNotEmpty ? key : id] = id;
      }
    }
    if (working.isEmpty) return const {};
    final out = <String, RoomMemberLive>{};
    for (final member in local) {
      final profile = member.owner.profile;
      final cacheKey = '${room.roomId}/$profile';
      final ids = _stored[cacheKey] ?? await _storedIds(room, profile);
      // A member whose room session does not exist yet is looked up again.
      if (ids.isNotEmpty) _stored[cacheKey] = ids;
      String? runtime;
      for (final id in ids) {
        runtime ??= working[id];
      }
      if (runtime == null) continue;
      final head = await rpc('session.events.since', {
        'session_id': runtime,
        'last_seen': roomPromptProbeLastSeen,
      });
      final latest = head['latest_seq'];
      final from = latest is int && latest > roomLiveFrameWindow
          ? latest - roomLiveFrameWindow
          : 0;
      final tail = await rpc('session.events.since', {
        'session_id': runtime,
        'last_seen': from,
      });
      final events = tail['events'];
      out[member.memberId] = reduceRoomMemberFrames(
        events is List ? events : const [],
      );
    }
    return Map.unmodifiable(out);
  }

  Future<Set<String>> _storedIds(HostedGroupRoom room, String profile) async {
    final listed = await rpc('session.list', {
      'profile': profile,
      'title': roomMemberSessionTitle(room.roomId),
      'include_hidden': true,
    });
    final sessions = listed['sessions'];
    if (sessions is! List || sessions.isEmpty || sessions.first is! Map) {
      return const {};
    }
    final first = sessions.first as Map;
    return {
      for (final k in const ['resolved_id', 'id'])
        if (first[k] is String && (first[k] as String).isNotEmpty)
          first[k] as String,
    };
  }
}
